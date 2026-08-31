#!/usr/bin/env python3
"""Telegram-бот для включения домашнего ПК через Wake-on-LAN.

Запускается на Ubuntu в той же локальной сети, что и целевой компьютер.
Настройки читаются из переменных окружения (см. .env.example).
"""

from __future__ import annotations

import asyncio
import html
import json
import logging
import os
import re
import socket
import sys
import time
from dataclasses import dataclass, field
from pathlib import Path

from telegram import (
    BotCommand,
    InlineKeyboardButton,
    InlineKeyboardMarkup,
    KeyboardButton,
    ReplyKeyboardMarkup,
    Update,
)
from telegram.constants import ParseMode
from telegram.ext import (
    Application,
    CallbackQueryHandler,
    CommandHandler,
    ContextTypes,
    MessageHandler,
    filters,
)

__version__ = "1.0"

log = logging.getLogger("wolbot")

# systemd задаёт STATE_DIRECTORY через StateDirectory= в юните; значение может
# быть списком через двоеточие. Вне systemd падаем на путь по умолчанию.
STATE_DIR = Path(os.environ.get("STATE_DIRECTORY", "/var/lib/wolbot").split(":")[0])
REQUESTS_FILE = STATE_DIR / "requests.json"


# --------------------------------------------------------------------------- #
# Конфигурация
# --------------------------------------------------------------------------- #


class ConfigError(RuntimeError):
    pass


def _env(name: str, default: str | None = None) -> str:
    value = os.environ.get(name, default)
    if value is None or value.strip() == "":
        raise ConfigError(f"Не задана переменная окружения {name}")
    return value.strip()


def _env_int_list(name: str, default: str) -> list[int]:
    raw = os.environ.get(name, default)
    result: list[int] = []
    for chunk in re.split(r"[,\s]+", raw or ""):
        if not chunk:
            continue
        try:
            result.append(int(chunk))
        except ValueError as exc:
            raise ConfigError(f"{name}: {chunk!r} не является числом") from exc
    return result


def normalize_mac(mac: str) -> str:
    """Приводит MAC к виду AA:BB:CC:DD:EE:FF, попутно проверяя корректность."""
    clean = re.sub(r"[^0-9A-Fa-f]", "", mac)
    if len(clean) != 12:
        raise ConfigError(f"Некорректный MAC-адрес: {mac!r}")
    clean = clean.upper()
    return ":".join(clean[i : i + 2] for i in range(0, 12, 2))


@dataclass
class Config:
    token: str
    mac: str
    host: str
    name: str = "Домашний ПК"
    broadcast: str = "255.255.255.255"
    wol_ports: list[int] = field(default_factory=lambda: [9, 7])
    check_ports: list[int] = field(default_factory=lambda: [3389, 445])
    allowed_users: set[int] = field(default_factory=set)
    wake_timeout: int = 180
    poll_interval: int = 5
    # Команда, усыпляющая ПК. Пустая — кнопка сна отвечает «не настроено».
    sleep_command: str = ""
    sleep_timeout: int = 90

    @classmethod
    def from_env(cls) -> "Config":
        allowed = set(_env_int_list("ALLOWED_USERS", ""))
        if not allowed:
            # Не падаем: с пустым белым списком бот отвечает только на /id,
            # иначе свой Telegram ID было бы неоткуда взять.
            log.warning(
                "ALLOWED_USERS пуст — доступна только команда /id. "
                "Впишите свой ID в конфиг и перезапустите бота."
            )
        return cls(
            token=_env("BOT_TOKEN"),
            mac=normalize_mac(_env("PC_MAC")),
            host=_env("PC_HOST"),
            name=os.environ.get("PC_NAME", "").strip() or "Домашний ПК",
            broadcast=os.environ.get("BROADCAST_IP", "").strip() or "255.255.255.255",
            wol_ports=_env_int_list("WOL_PORTS", "9,7"),
            check_ports=_env_int_list("CHECK_PORTS", "3389,445"),
            allowed_users=allowed,
            wake_timeout=int(os.environ.get("WAKE_TIMEOUT", "180")),
            poll_interval=int(os.environ.get("POLL_INTERVAL", "5")),
            sleep_command=os.environ.get("SLEEP_COMMAND", "").strip(),
            sleep_timeout=int(os.environ.get("SLEEP_TIMEOUT", "90")),
        )


# --------------------------------------------------------------------------- #
# Wake-on-LAN
# --------------------------------------------------------------------------- #


def build_magic_packet(mac: str) -> bytes:
    payload = bytes.fromhex(re.sub(r"[^0-9A-Fa-f]", "", mac))
    return b"\xff" * 6 + payload * 16


def send_magic_packet(cfg: Config) -> None:
    packet = build_magic_packet(cfg.mac)
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
        for port in cfg.wol_ports:
            sock.sendto(packet, (cfg.broadcast, port))
            log.info("Magic packet -> %s:%s (mac=%s)", cfg.broadcast, port, cfg.mac)


# --------------------------------------------------------------------------- #
# Проверка доступности
# --------------------------------------------------------------------------- #


async def _tcp_open(host: str, port: int, timeout: float = 1.5) -> bool:
    try:
        reader, writer = await asyncio.wait_for(
            asyncio.open_connection(host, port), timeout
        )
    except (OSError, asyncio.TimeoutError):
        return False
    writer.close()
    try:
        await writer.wait_closed()
    except OSError:
        pass
    return True


async def _icmp_ping(host: str, timeout: int = 1) -> bool:
    try:
        proc = await asyncio.create_subprocess_exec(
            "ping",
            "-c",
            "1",
            "-W",
            str(timeout),
            host,
            stdout=asyncio.subprocess.DEVNULL,
            stderr=asyncio.subprocess.DEVNULL,
        )
    except (FileNotFoundError, OSError):
        return False
    return await proc.wait() == 0


async def is_online(cfg: Config) -> bool:
    """ПК считается включённым, если отвечает хотя бы одна проверка.

    Windows по умолчанию режет ICMP в профиле «Общедоступная сеть»,
    поэтому ping — не единственный и не главный признак.
    """
    checks = [_tcp_open(cfg.host, port) for port in cfg.check_ports]
    checks.append(_icmp_ping(cfg.host))
    results = await asyncio.gather(*checks, return_exceptions=True)
    return any(r is True for r in results)


# --------------------------------------------------------------------------- #
# Хелперы Telegram
# --------------------------------------------------------------------------- #


BTN_WAKE = "⚡ Включить"
BTN_STATUS = "📊 Статус"
BTN_SLEEP = "😴 Усыпить"
BTN_HELP = "ℹ️ Помощь"


def reply_keyboard() -> ReplyKeyboardMarkup:
    """Панель кнопок под полем ввода — видна всегда, набирать команды не нужно."""
    return ReplyKeyboardMarkup(
        [
            [KeyboardButton(BTN_WAKE), KeyboardButton(BTN_STATUS)],
            [KeyboardButton(BTN_SLEEP), KeyboardButton(BTN_HELP)],
        ],
        resize_keyboard=True,
        is_persistent=True,
        input_field_placeholder="Нажмите кнопку ниже",
    )


def main_keyboard() -> InlineKeyboardMarkup:
    """Кнопки под самим сообщением — обновляют его на месте, без новых сообщений."""
    return InlineKeyboardMarkup(
        [
            [
                InlineKeyboardButton(BTN_WAKE, callback_data="wake"),
                InlineKeyboardButton("🔄 Обновить", callback_data="status"),
            ],
            [InlineKeyboardButton(BTN_SLEEP, callback_data="sleep")],
        ]
    )


def confirm_keyboard() -> InlineKeyboardMarkup:
    """Сон рвёт сессии и может стоить несохранённой работы — спрашиваем явно."""
    return InlineKeyboardMarkup(
        [
            [
                InlineKeyboardButton("😴 Да, усыпить", callback_data="sleep_yes"),
                InlineKeyboardButton("✖️ Отмена", callback_data="cancel"),
            ]
        ]
    )


def record_request(user) -> None:
    """Складывает заявку на доступ в файл состояния — её видно в меню `wolbot`.

    Любая ошибка записи не должна ронять обработку апдейта, поэтому глушим всё.
    """
    try:
        try:
            data = json.loads(REQUESTS_FILE.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            data = {}
        now = int(time.time())
        entry = data.get(str(user.id), {})
        entry.update(
            {
                "id": user.id,
                "username": user.username or "",
                "name": user.full_name,
                "last_seen": now,
                "count": entry.get("count", 0) + 1,
            }
        )
        entry.setdefault("first_seen", now)
        data[str(user.id)] = entry
        REQUESTS_FILE.parent.mkdir(parents=True, exist_ok=True)
        tmp = REQUESTS_FILE.with_suffix(".tmp")
        tmp.write_text(json.dumps(data, ensure_ascii=False, indent=1), encoding="utf-8")
        tmp.replace(REQUESTS_FILE)
    except OSError as exc:
        log.warning("Не удалось записать заявку на доступ: %s", exc)


def authorized(update: Update, cfg: Config) -> bool:
    user = update.effective_user
    if user is None:
        return False
    if user.id in cfg.allowed_users:
        return True
    log.warning("Отказано в доступе: id=%s username=%s", user.id, user.username or "-")
    record_request(user)
    return False


async def deny(update: Update) -> None:
    user = update.effective_user
    uid = user.id if user else "?"
    if update.callback_query:
        await update.callback_query.answer("Доступ запрещён", show_alert=True)
    elif update.effective_message:
        await update.effective_message.reply_html(
            f"Доступ запрещён. Ваш Telegram ID: <code>{uid}</code>\n\n"
            "Заявка отправлена владельцу бота — она появится на сервере "
            "в меню <code>wolbot</code>, пункт «Запросы доступа»."
        )


# --------------------------------------------------------------------------- #
# Команды
# --------------------------------------------------------------------------- #


async def cmd_start(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    cfg: Config = context.bot_data["cfg"]
    if not authorized(update, cfg):
        await deny(update)
        return
    # Сначала закрепляем панель кнопок, затем карточку с инлайн-кнопками:
    # два разных вида клавиатур в одном сообщении Telegram не отдаёт.
    await update.effective_message.reply_html(
        f"<b>🖥 {html.escape(cfg.name)}</b>\n"
        "Управление — кнопками ниже.",
        reply_markup=reply_keyboard(),
    )
    await update.effective_message.reply_html(
        await status_card(cfg), reply_markup=main_keyboard()
    )


async def cmd_id(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    user = update.effective_user
    await update.effective_message.reply_html(
        f"Ваш Telegram ID: <code>{user.id if user else '?'}</code>"
    )


async def status_card(cfg: Config) -> str:
    online = await is_online(cfg)
    mark = "🟢 <b>Включён</b>" if online else "🔴 <b>Выключен</b>"
    return (
        f"<b>🖥 {html.escape(cfg.name)}</b>\n"
        f"{mark}\n\n"
        f"<pre>адрес   {html.escape(cfg.host)}\n"
        f"MAC     {cfg.mac}\n"
        f"проверка {time.strftime('%H:%M:%S')}</pre>"
    )


async def cmd_status(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    cfg: Config = context.bot_data["cfg"]
    if not authorized(update, cfg):
        await deny(update)
        return
    msg = await update.effective_message.reply_html("⏳ Проверяю…")
    await msg.edit_text(
        await status_card(cfg), parse_mode=ParseMode.HTML, reply_markup=main_keyboard()
    )


def progress_bar(elapsed: int, total: int, width: int = 14) -> str:
    filled = min(width, round(width * elapsed / total)) if total else 0
    return "▰" * filled + "▱" * (width - filled)


async def run_wake(cfg: Config, edit) -> None:
    """Шлёт magic-пакет и ждёт отклика хоста. `edit` — корутина-редактор сообщения."""
    if await is_online(cfg):
        await edit(f"<b>🖥 {html.escape(cfg.name)}</b>\n🟢 <b>Уже включён</b>")
        return

    try:
        send_magic_packet(cfg)
    except OSError as exc:
        log.exception("Не удалось отправить magic packet")
        await edit(f"Ошибка отправки пакета: <code>{html.escape(str(exc))}</code>")
        return

    started = time.monotonic()
    last_text = ""
    while time.monotonic() - started < cfg.wake_timeout:
        await asyncio.sleep(cfg.poll_interval)
        elapsed = int(time.monotonic() - started)
        if await is_online(cfg):
            await edit(
                f"<b>🖥 {html.escape(cfg.name)}</b>\n"
                f"🟢 <b>Включился</b> за {elapsed} с"
            )
            return
        text = (
            f"<b>🖥 {html.escape(cfg.name)}</b>\n"
            f"⚡ Пакет отправлен, жду загрузки…\n\n"
            f"<code>{progress_bar(elapsed, cfg.wake_timeout)}</code>  {elapsed} с"
        )
        if text != last_text:
            await edit(text)
            last_text = text

    await edit(
        f"<b>🖥 {html.escape(cfg.name)}</b>\n"
        f"⚠️ Пакет отправлен, но ответа нет уже {cfg.wake_timeout} с.\n\n"
        "Либо компьютер ещё грузится, либо Wake-on-LAN выключен "
        "в BIOS или в настройках сетевой карты."
    )


async def run_sleep(cfg: Config, edit) -> None:
    """Выполняет SLEEP_COMMAND и ждёт, пока хост перестанет отвечать."""
    if not cfg.sleep_command:
        await edit(
            "😴 <b>Сон не настроен</b>\n\n"
            "Задайте <code>SLEEP_COMMAND</code> в <code>/etc/wolbot.env</code> — "
            "команду, которая усыпляет компьютер. Как её получить — в README."
        )
        return

    if not await is_online(cfg):
        await edit(f"<b>🖥 {html.escape(cfg.name)}</b>\n🔴 Уже выключен")
        return

    await edit(f"<b>🖥 {html.escape(cfg.name)}</b>\n😴 Отправляю команду сна…")
    try:
        proc = await asyncio.create_subprocess_shell(
            cfg.sleep_command,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.STDOUT,
        )
    except OSError as exc:
        log.exception("Не удалось запустить SLEEP_COMMAND")
        await edit(f"⚠️ Не удалось выполнить команду:\n<code>{html.escape(str(exc))}</code>")
        return

    try:
        out, _ = await asyncio.wait_for(proc.communicate(), timeout=30)
    except asyncio.TimeoutError:
        proc.kill()
        await edit("⚠️ Команда сна не завершилась за 30 с — прервал.")
        return

    if proc.returncode != 0:
        tail = (out or b"").decode("utf-8", "replace").strip()[-500:]
        log.warning("SLEEP_COMMAND вернула %s: %s", proc.returncode, tail)
        await edit(
            f"⚠️ Команда сна завершилась с кодом {proc.returncode}."
            + (f"\n<pre>{html.escape(tail)}</pre>" if tail else "")
        )
        return

    started = time.monotonic()
    last_text = ""
    while time.monotonic() - started < cfg.sleep_timeout:
        await asyncio.sleep(cfg.poll_interval)
        elapsed = int(time.monotonic() - started)
        if not await is_online(cfg):
            await edit(
                f"<b>🖥 {html.escape(cfg.name)}</b>\n"
                f"😴 <b>Уснул</b> за {elapsed} с"
            )
            return
        text = (
            f"<b>🖥 {html.escape(cfg.name)}</b>\n"
            f"😴 Команда отправлена, засыпает…\n\n"
            f"<code>{progress_bar(elapsed, cfg.sleep_timeout)}</code>  {elapsed} с"
        )
        if text != last_text:
            await edit(text)
            last_text = text

    await edit(
        f"<b>🖥 {html.escape(cfg.name)}</b>\n"
        f"⚠️ Команда прошла без ошибок, но компьютер всё ещё отвечает "
        f"({cfg.sleep_timeout} с).\n\n"
        "Возможно, сон блокирует какое-то приложение или активная сессия."
    )


async def cmd_sleep(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    cfg: Config = context.bot_data["cfg"]
    if not authorized(update, cfg):
        await deny(update)
        return
    await update.effective_message.reply_html(
        f"<b>🖥 {html.escape(cfg.name)}</b>\n"
        "Усыпить компьютер? Все открытые сессии оборвутся.",
        reply_markup=confirm_keyboard(),
    )


async def cmd_wake(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    cfg: Config = context.bot_data["cfg"]
    if not authorized(update, cfg):
        await deny(update)
        return
    msg = await update.effective_message.reply_html("⚡ Отправляю magic packet…")

    async def edit(text: str) -> None:
        await msg.edit_text(text, parse_mode=ParseMode.HTML, reply_markup=main_keyboard())

    await run_wake(cfg, edit)


async def on_button(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    cfg: Config = context.bot_data["cfg"]
    query = update.callback_query
    if not authorized(update, cfg):
        await deny(update)
        return
    await query.answer()

    async def edit(text: str) -> None:
        await query.edit_message_text(
            text, parse_mode=ParseMode.HTML, reply_markup=main_keyboard()
        )

    if query.data == "wake":
        await edit("⚡ Отправляю magic packet…")
        await run_wake(cfg, edit)
    elif query.data == "status":
        await edit("⏳ Проверяю…")
        await edit(await status_card(cfg))
    elif query.data == "sleep":
        await query.edit_message_text(
            f"<b>🖥 {html.escape(cfg.name)}</b>\n"
            "Усыпить компьютер? Все открытые сессии оборвутся.",
            parse_mode=ParseMode.HTML,
            reply_markup=confirm_keyboard(),
        )
    elif query.data == "sleep_yes":
        await run_sleep(cfg, edit)
    elif query.data == "cancel":
        await edit(await status_card(cfg))


async def on_text(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    """Нажатия на кнопки нижней панели приходят как обычный текст."""
    text = (update.effective_message.text or "").strip()
    if text == BTN_WAKE:
        await cmd_wake(update, context)
    elif text == BTN_STATUS:
        await cmd_status(update, context)
    elif text == BTN_SLEEP:
        await cmd_sleep(update, context)
    else:
        await cmd_start(update, context)


async def on_error(update: object, context: ContextTypes.DEFAULT_TYPE) -> None:
    log.error("Ошибка при обработке апдейта", exc_info=context.error)


async def post_init(app: Application) -> None:
    await app.bot.set_my_commands(
        [
            BotCommand("wake", "Включить компьютер"),
            BotCommand("sleep", "Усыпить компьютер"),
            BotCommand("status", "Проверить состояние"),
            BotCommand("id", "Показать мой Telegram ID"),
            BotCommand("start", "Меню"),
        ]
    )


def main() -> int:
    logging.basicConfig(
        format="%(asctime)s %(levelname)-8s %(name)s: %(message)s",
        level=os.environ.get("LOG_LEVEL", "INFO").upper(),
    )
    logging.getLogger("httpx").setLevel(logging.WARNING)

    try:
        cfg = Config.from_env()
    except (ConfigError, ValueError) as exc:
        log.error("Ошибка конфигурации: %s", exc)
        return 1

    log.info(
        "wolbot %s | цель: %s (%s / %s); доступ разрешён %d пользователю(ям)",
        __version__,
        cfg.name,
        cfg.host,
        cfg.mac,
        len(cfg.allowed_users),
    )

    app = Application.builder().token(cfg.token).post_init(post_init).build()
    app.bot_data["cfg"] = cfg
    app.add_handler(CommandHandler(["start", "help"], cmd_start))
    app.add_handler(CommandHandler("wake", cmd_wake))
    app.add_handler(CommandHandler("sleep", cmd_sleep))
    app.add_handler(CommandHandler(["status", "ping"], cmd_status))
    app.add_handler(CommandHandler("id", cmd_id))
    app.add_handler(CallbackQueryHandler(on_button))
    app.add_handler(MessageHandler(filters.TEXT & ~filters.COMMAND, on_text))
    app.add_error_handler(on_error)

    app.run_polling(drop_pending_updates=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
