#!/usr/bin/env bash
# Интерактивное меню управления wolbot. Живёт в /opt/wolbot/wolbot-cli.sh,
# вызывается как `wolbot` (симлинк из /usr/local/bin).
# Без аргументов открывает меню, с аргументом работает как обычная команда.
# Намеренно без set -e: меню должно переживать неудачную команду.
set -uo pipefail

ENV_FILE=/etc/wolbot.env
APP_DIR=/opt/wolbot
SRC_DIR=/opt/wolbot/src
REQ_FILE=/var/lib/wolbot/requests.json   # заявки на доступ, пишет сам бот
PY="$APP_DIR/venv/bin/python"
SERVICE=wolbot

if [[ -t 1 ]]; then
    B=$'\e[1m'; DIM=$'\e[2m'; R=$'\e[0m'; REV=$'\e[7m'
    RED=$'\e[31m'; GREEN=$'\e[32m'; YELLOW=$'\e[33m'; CYAN=$'\e[36m'
else
    B=""; DIM=""; R=""; REV=""; RED=""; GREEN=""; YELLOW=""; CYAN=""
fi

die() { echo "${RED}$*${R}" >&2; exit 1; }
pause() { read -rsn1 -p "$(printf '\n%sНажмите любую клавишу…%s' "$DIM" "$R")"; echo; }

[[ $EUID -eq 0 ]] || die "Нужны права root: sudo wolbot"
[[ -f $ENV_FILE ]] || die "Не найден $ENV_FILE — бот не установлен?"

# --------------------------------------------------------------------------- #
# Работа с конфигом
# --------------------------------------------------------------------------- #

cfg_get() {
    local val
    val=$(grep -E "^$1=" "$ENV_FILE" 2>/dev/null | tail -1 | cut -d= -f2-)
    val=${val#\"}; val=${val%\"}
    printf '%s' "$val"
}

# Переписывает файл построчно: sed сломался бы на спецсимволах в значении.
cfg_set() {
    local key=$1 value=$2 tmp found=0 line
    [[ $value == *[[:space:]]* ]] && value="\"$value\""
    tmp=$(mktemp)
    while IFS= read -r line || [[ -n $line ]]; do
        if [[ $line == "$key="* ]]; then
            printf '%s=%s\n' "$key" "$value" >> "$tmp"
            found=1
        else
            printf '%s\n' "$line" >> "$tmp"
        fi
    done < "$ENV_FILE"
    (( found )) || printf '%s=%s\n' "$key" "$value" >> "$tmp"
    cat "$tmp" > "$ENV_FILE"   # именно cat, чтобы сохранить владельца и права 640
    rm -f "$tmp"
}

# Запускает код на wolbot.py с загруженным конфигом.
# Пустые BOT_TOKEN/ALLOWED_USERS подменяются заглушкой: для локальных
# проверок токен не нужен, а Config.from_env без него падает.
py_run() {
    (
        cd "$APP_DIR" || exit 1
        set -a; . "$ENV_FILE"; set +a
        # PYTHONDONTWRITEBYTECODE — чтобы root не насорил __pycache__ в /opt/wolbot
        BOT_TOKEN="${BOT_TOKEN:-cli-stub}" ALLOWED_USERS="${ALLOWED_USERS:-0}" \
            PYTHONDONTWRITEBYTECODE=1 "$PY" -c "$1"
    )
}

restart_if_running() {
    if systemctl is-active --quiet "$SERVICE"; then
        echo "${DIM}Перезапускаю службу…${R}"
        systemctl restart "$SERVICE"
        sleep 2
        systemctl is-active --quiet "$SERVICE" \
            && echo "${GREEN}Служба работает.${R}" \
            || { echo "${RED}Служба не поднялась:${R}"; journalctl -u "$SERVICE" -n 10 --no-pager -o cat; }
    else
        read -rp "Служба не запущена. Запустить сейчас? [y/N] " a
        [[ ${a,,} == y ]] && { systemctl start "$SERVICE"; sleep 2; act_status; }
    fi
}

# --------------------------------------------------------------------------- #
# Действия
# --------------------------------------------------------------------------- #

act_status() {
    local state enabled token users
    state=$(systemctl is-active "$SERVICE")
    enabled=$(systemctl is-enabled "$SERVICE" 2>/dev/null)
    token=$(cfg_get BOT_TOKEN); users=$(cfg_get ALLOWED_USERS)

    echo "${B}Служба${R}"
    case $state in
        active) echo "  состояние : ${GREEN}работает${R}" ;;
        failed) echo "  состояние : ${RED}сбой${R}" ;;
        *)      echo "  состояние : ${YELLOW}$state${R}" ;;
    esac
    echo "  автозапуск: $enabled"
    [[ -n $token ]] && echo "  токен     : ${GREEN}задан${R}" \
                    || echo "  токен     : ${RED}не задан${R}"
    [[ -n $users ]] && echo "  доступ    : $users" \
                    || echo "  доступ    : ${RED}список пуст (работает только /id)${R}"

    echo
    echo "${B}Целевой компьютер${R}"
    echo "  $(cfg_get PC_NAME)  $(cfg_get PC_HOST)  $(cfg_get PC_MAC)"
    printf '  проверяю… '
    if py_run 'import asyncio,wolbot; raise SystemExit(0 if asyncio.run(wolbot.is_online(wolbot.Config.from_env())) else 1)' 2>/dev/null; then
        echo "${GREEN}включён${R}"
    else
        echo "${RED}выключен / не отвечает${R}"
    fi

    if [[ $state == failed ]]; then
        echo
        echo "${B}Последние строки журнала${R}"
        journalctl -u "$SERVICE" -n 8 --no-pager -o cat | sed 's/^/  /'
    fi
}

act_wake() {
    echo "Отправляю magic packet на $(cfg_get PC_MAC) → $(cfg_get BROADCAST_IP)…"
    py_run '
import asyncio, time, wolbot
cfg = wolbot.Config.from_env()
if asyncio.run(wolbot.is_online(cfg)):
    print("Компьютер уже включён.")
    raise SystemExit(0)
wolbot.send_magic_packet(cfg)
started = time.monotonic()
while time.monotonic() - started < cfg.wake_timeout:
    time.sleep(cfg.poll_interval)
    elapsed = int(time.monotonic() - started)
    if asyncio.run(wolbot.is_online(cfg)):
        print("\nВключился за ~%d с." % elapsed)
        raise SystemExit(0)
    print("\r  жду загрузки… %d с" % elapsed, end="", flush=True)
print("\nНе ответил за %d с. Проверьте WOL в BIOS и настройки сетевой карты." % cfg.wake_timeout)
raise SystemExit(1)
' 2>&1 | grep -v "^Magic packet"
}

# Переиспользует run_sleep из wolbot.py: логика сна живёт в одном месте.
# edit-шим срезает HTML-теги и печатает каждое обновление отдельной строкой.
act_sleep() {
    if [[ -z $(cfg_get SLEEP_COMMAND) ]]; then
        echo "${YELLOW}SLEEP_COMMAND не задан в $ENV_FILE — сон не настроен.${R}"
        echo "${DIM}Как его получить — см. раздел «Сон» в $SRC_DIR/README.md${R}"
        return
    fi
    py_run '
import asyncio, html, re, wolbot
async def edit(text):
    text = re.sub(r"<[^>]+>", "", text)
    print(html.unescape(text).replace("\n", " ").strip(), flush=True)
asyncio.run(wolbot.run_sleep(wolbot.Config.from_env(), edit))
'
}

act_set_token() {
    local token
    read -rsp "Токен от @BotFather (ввод скрыт): " token; echo
    [[ -z $token ]] && { echo "${YELLOW}Пусто, ничего не менял.${R}"; return; }
    if [[ ! $token =~ ^[0-9]+:[A-Za-z0-9_-]+$ ]]; then
        read -rp "${YELLOW}Не похоже на токен Telegram. Всё равно записать? [y/N]${R} " a
        [[ ${a,,} == y ]] || return
    fi
    cfg_set BOT_TOKEN "$token"
    echo "${GREEN}Токен записан.${R}"
    restart_if_running
}

act_set_users() {
    echo "${DIM}Текущий список: $(cfg_get ALLOWED_USERS)"
    echo "Свой ID можно узнать, отправив боту /id — он отвечает всем.${R}"
    local users
    read -rp "Telegram ID через запятую: " users
    users=${users// /}
    [[ -z $users ]] && { echo "${YELLOW}Пусто, ничего не менял.${R}"; return; }
    if [[ ! $users =~ ^[0-9]+(,[0-9]+)*$ ]]; then
        echo "${RED}Ожидаются только числа через запятую.${R}"; return
    fi
    cfg_set ALLOWED_USERS "$users"
    echo "${GREEN}Список обновлён: $users${R}"
    restart_if_running
}

act_show_config() {
    echo "${B}$ENV_FILE${R}"
    # Токен маскируется: журнал сессии может попасть куда угодно.
    sed -E 's/^(BOT_TOKEN=)(.{0,8}).*/\1\2… (скрыт)/' "$ENV_FILE" \
        | grep -vE '^\s*(#|$)' | sed 's/^/  /'
}

act_update() {
    [[ -d $SRC_DIR ]] || { echo "${RED}Нет каталога $SRC_DIR${R}"; return; }
    install -o wolbot -g wolbot -m 644 "$SRC_DIR/wolbot.py" "$APP_DIR/wolbot.py" || return
    if ! "$PY" -c "import ast;ast.parse(open('$APP_DIR/wolbot.py',encoding='utf-8').read())"; then
        echo "${RED}В новом коде синтаксическая ошибка, службу не трогаю.${R}"; return
    fi
    [[ -f $SRC_DIR/requirements.txt ]] && "$APP_DIR/venv/bin/pip" install -q -r "$SRC_DIR/requirements.txt"
    if [[ -f $SRC_DIR/wolbot.service ]]; then
        install -m 644 "$SRC_DIR/wolbot.service" /etc/systemd/system/wolbot.service
        systemctl daemon-reload
    fi
    [[ -f $SRC_DIR/wolbot-cli.sh ]] && install -m 755 "$SRC_DIR/wolbot-cli.sh" "$APP_DIR/wolbot-cli.sh"
    echo "${GREEN}Код обновлён.${R}"
    restart_if_running
}

act_toggle_enabled() {
    if systemctl is-enabled --quiet "$SERVICE"; then
        systemctl disable "$SERVICE" && echo "${YELLOW}Автозапуск выключен.${R}"
    else
        systemctl enable "$SERVICE" && echo "${GREEN}Автозапуск включён.${R}"
    fi
}

# --------------------------------------------------------------------------- #
# Заявки на доступ
# --------------------------------------------------------------------------- #

declare -a REQ_ID REQ_LABEL
REQ_TOP=5
REQ_SEL=0

req_count() {
    [[ -f $REQ_FILE ]] || { echo 0; return; }
    "$PY" -c 'import json,sys
try: print(len(json.load(open(sys.argv[1],encoding="utf-8"))))
except Exception: print(0)' "$REQ_FILE" 2>/dev/null || echo 0
}

req_load() {
    REQ_ID=(); REQ_LABEL=()
    [[ -f $REQ_FILE ]] || return 0
    local id label
    while IFS=$'\t' read -r id label; do
        [[ -n $id ]] || continue
        REQ_ID+=("$id"); REQ_LABEL+=("$label")
    done < <("$PY" - "$REQ_FILE" <<'PY' 2>/dev/null
import json, sys, time
try:
    data = json.load(open(sys.argv[1], encoding="utf-8"))
except Exception:
    sys.exit(0)
for e in sorted(data.values(), key=lambda x: x.get("last_seen", 0), reverse=True):
    who = e.get("name") or "без имени"
    tag = "@" + e["username"] if e.get("username") else "без username"
    when = time.strftime("%d.%m %H:%M", time.localtime(e.get("last_seen", 0)))
    print("%s\t%-12s %s · %s · обращений: %d · %s"
          % (e["id"], e["id"], who, tag, e.get("count", 1), when))
PY
)
}

req_forget() {
    "$PY" - "$REQ_FILE" "$1" <<'PY' 2>/dev/null
import json, sys
path, uid = sys.argv[1], sys.argv[2]
try:
    data = json.load(open(path, encoding="utf-8"))
except Exception:
    sys.exit(0)
data.pop(uid, None)
json.dump(data, open(path, "w", encoding="utf-8"), ensure_ascii=False, indent=1)
PY
}

req_approve() {
    local id=$1 cur new
    cur=$(cfg_get ALLOWED_USERS)
    if [[ ",$cur," == *",$id,"* ]]; then
        new=$cur
        echo "${YELLOW}$id уже в списке.${R}"
    elif [[ -z $cur ]]; then
        new=$id
    else
        new="$cur,$id"
    fi
    cfg_set ALLOWED_USERS "$new"
    req_forget "$id"
    echo "${GREEN}Доступ выдан: $id${R}"
    echo "${DIM}ALLOWED_USERS=$new${R}"
}

req_draw_line() {
    local i=$1
    printf '\e[%d;1H\e[2K' $((REQ_TOP + i))
    if (( i == REQ_SEL )); then
        printf '  %s▸ %s %s' "$REV" "${REQ_LABEL[i]}" "$R"
    else
        printf '    %s' "${REQ_LABEL[i]}"
    fi
}

req_draw_all() {
    printf '\e[H\e[2J'
    printf '\e[2;1H  %sЗапросы доступа%s' "$B$CYAN" "$R"
    printf '\e[3;1H  %s────────────────────────────────────%s' "$DIM" "$R"

    if (( ${#REQ_ID[@]} == 0 )); then
        printf '\e[5;1H  %sЗаявок нет.%s' "$DIM" "$R"
        printf '\e[7;1H  Откройте бота в Telegram и нажмите Start —'
        printf '\e[8;1H  заявка появится здесь.'
        printf '\e[10;1H  %sr — обновить · 0 — назад%s' "$DIM" "$R"
        return
    fi

    local i foot
    for i in "${!REQ_ID[@]}"; do req_draw_line "$i"; done
    foot=$((REQ_TOP + ${#REQ_ID[@]} + 1))
    printf '\e[%d;1H  %sсейчас доступ у: %s%s' "$foot" "$DIM" "$(cfg_get ALLOWED_USERS)" "$R"
    printf '\e[%d;1H  %sклик или Enter — выдать доступ · d — удалить заявку%s' \
           $((foot + 2)) "$DIM" "$R"
    printf '\e[%d;1H  %sr — обновить · 0 — назад%s' $((foot + 3)) "$DIM" "$R"
}

req_move() {
    local n=${#REQ_ID[@]} prev=$REQ_SEL
    (( n )) || return
    REQ_SEL=$(( (REQ_SEL + $1 + n) % n ))
    req_draw_line "$prev"; req_draw_line "$REQ_SEL"
}

req_do_approve() {
    (( ${#REQ_ID[@]} )) || return
    local id=${REQ_ID[REQ_SEL]}
    tui_off
    req_approve "$id"
    restart_if_running
    pause
    tui_on
    req_load; REQ_SEL=0; req_draw_all
}

req_do_delete() {
    (( ${#REQ_ID[@]} )) || return
    req_forget "${REQ_ID[REQ_SEL]}"
    req_load
    (( REQ_SEL >= ${#REQ_ID[@]} )) && REQ_SEL=0
    req_draw_all
}

act_requests() {
    req_load
    REQ_SEL=0
    req_draw_all
    local idx prev
    while true; do
        read_key || continue
        case $KEY in
            up)    req_move -1 ;;
            down)  req_move 1 ;;
            enter) req_do_approve ;;
            click) idx=$((CLICK_ROW - REQ_TOP))
                   if (( idx >= 0 && idx < ${#REQ_ID[@]} )); then
                       prev=$REQ_SEL; REQ_SEL=$idx
                       req_draw_line "$prev"; req_draw_line "$REQ_SEL"
                       req_do_approve
                   fi ;;
            d)     req_do_delete ;;
            r)     req_load; REQ_SEL=0; req_draw_all ;;
            0|q|esc) return ;;
        esac
    done
}

# Неинтерактивный вывод заявок — для `wolbot requests`.
act_requests_list() {
    req_load
    if (( ${#REQ_ID[@]} == 0 )); then
        echo "Заявок нет."
        return
    fi
    echo "${B}Заявки на доступ${R}"
    local i
    for i in "${!REQ_ID[@]}"; do echo "  ${REQ_LABEL[i]}"; done
    echo
    echo "${DIM}Выдать доступ: wolbot approve <id>${R}"
}

usage() {
    cat <<EOF
${B}wolbot${R} — управление Telegram-ботом Wake-on-LAN

  wolbot              интерактивное меню (мышь + клавиатура)
  wolbot status       состояние службы и целевого ПК
  wolbot wake         разбудить компьютер
  wolbot sleep        усыпить компьютер
  wolbot requests     показать заявки на доступ
  wolbot approve ID   выдать доступ пользователю
  wolbot logs [-f]    журнал (-f — в реальном времени)
  wolbot start|stop|restart
  wolbot config       показать настройки (токен скрыт)
  wolbot edit         открыть настройки в редакторе
  wolbot update       забрать код из $SRC_DIR и перезапустить
EOF
}

# --------------------------------------------------------------------------- #
# Меню: мышь + клавиатура
# --------------------------------------------------------------------------- #

MENU_TOP=6          # экранная строка, с которой начинается список (1-based)
MOUSE=1             # включён ли захват мыши
SEL=0               # индекс выбранного пункта в M_TEXT

declare -a M_TEXT M_KEY

mi()   { M_KEY+=("$1"); M_TEXT+=("$1) $2"); }
msep() { M_KEY+=("");   M_TEXT+=(""); }

menu_build() {
    M_TEXT=(); M_KEY=()
    mi 1 "Состояние (служба + компьютер)"
    mi 2 "Разбудить компьютер"
    mi s "Усыпить компьютер"
    msep
    mi 3 "Журнал — последние 50 строк"
    mi 4 "Журнал — в реальном времени"
    msep
    mi 5 "Запустить / перезапустить службу"
    mi 6 "Остановить службу"
    mi a "Автозапуск вкл/выкл"
    msep
    mi r "Запросы доступа"
    mi 7 "Задать токен бота"
    mi 8 "Задать список разрешённых ID"
    mi 9 "Показать настройки"
    mi e "Редактировать настройки"
    mi u "Обновить код из $SRC_DIR"
    msep
    mi 0 "Выход"
}

# Захват мыши: 1000 — клики, 1006 — SGR-формат (нужен при ширине > 95 колонок).
mouse_on()  { (( MOUSE )) && printf '\e[?1000h\e[?1006h'; }
mouse_off() { printf '\e[?1000l\e[?1006l'; }
tui_on()    { printf '\e[?1049h\e[?25l'; mouse_on; }
tui_off()   { mouse_off; printf '\e[?25h\e[?1049l'; }

menu_draw_line() {
    local i=$1
    printf '\e[%d;1H\e[2K' $((MENU_TOP + i))
    [[ -z ${M_KEY[i]} ]] && return
    if (( i == SEL )); then
        printf '  %s▸ %s %s' "$REV" "${M_TEXT[i]}" "$R"
    else
        printf '    %s' "${M_TEXT[i]}"
    fi
}

menu_draw_all() {
    local state dot i
    state=$(systemctl is-active "$SERVICE")
    case $state in
        active) dot="${GREEN}●${R} работает" ;;
        failed) dot="${RED}●${R} сбой" ;;
        *)      dot="${YELLOW}●${R} $state" ;;
    esac

    printf '\e[H\e[2J'
    printf '\e[2;1H  %sWolBot%s %s— Wake-on-LAN из Telegram%s' "$B$CYAN" "$R" "$DIM" "$R"
    printf '\e[3;1H  %s────────────────────────────────────%s' "$DIM" "$R"
    printf '\e[4;1H\e[2K  служба: %s     цель: %s' "$dot" "$(cfg_get PC_HOST)"
    local pending; pending=$(req_count)
    (( pending > 0 )) && printf '     %sзаявок: %s%s' "$YELLOW" "$pending" "$R"

    for i in "${!M_TEXT[@]}"; do menu_draw_line "$i"; done

    local foot=$((MENU_TOP + ${#M_TEXT[@]} + 1))
    printf '\e[%d;1H  %sклик мышью · ↑↓ и Enter · клавиша пункта%s' "$foot" "$DIM" "$R"
    if (( MOUSE )); then
        printf '\e[%d;1H  %sm — отключить мышь, если нужно выделить текст%s' \
               $((foot + 1)) "$DIM" "$R"
    else
        printf '\e[%d;1H  %sm — включить мышь обратно%s' $((foot + 1)) "$DIM" "$R"
    fi
}

menu_move() {
    local step=$1 next=$SEL n=${#M_TEXT[@]} guard=0
    while (( guard++ < n )); do
        next=$(( (next + step + n) % n ))
        if [[ -n ${M_KEY[next]} ]]; then
            local prev=$SEL
            SEL=$next
            menu_draw_line "$prev"
            menu_draw_line "$SEL"
            return
        fi
    done
}

# Выполняет действие на обычном экране, чтобы у вывода была прокрутка.
run_action() {
    tui_off
    "$@"
    pause
    tui_on
    menu_draw_all
}

menu_dispatch() {
    case $1 in
        1) run_action act_status ;;
        2) run_action act_wake ;;
        s) run_action act_sleep ;;
        3) run_action journalctl -u "$SERVICE" -n 50 --no-pager ;;
        4) tui_off
           echo "${DIM}Ctrl+C — назад в меню${R}"
           journalctl -u "$SERVICE" -f
           tui_on; menu_draw_all ;;
        5) run_action bash -c "systemctl restart $SERVICE; sleep 2; systemctl status $SERVICE --no-pager -n 5" ;;
        6) run_action bash -c "systemctl stop $SERVICE; echo Остановлено." ;;
        a) run_action act_toggle_enabled ;;
        r) act_requests; menu_draw_all ;;
        7) run_action act_set_token ;;
        8) run_action act_set_users ;;
        9) run_action act_show_config ;;
        e) tui_off; "${EDITOR:-nano}" "$ENV_FILE"; restart_if_running; pause; tui_on; menu_draw_all ;;
        u) run_action act_update ;;
        0|q) return 1 ;;
    esac
    return 0
}

# Клик: строка экрана → индекс пункта. Промах по разделителю игнорируется.
menu_click() {
    local row=$1 idx=$((row - MENU_TOP))
    (( idx >= 0 && idx < ${#M_TEXT[@]} )) || return 0
    [[ -n ${M_KEY[idx]} ]] || return 0
    local prev=$SEL
    SEL=$idx
    menu_draw_line "$prev"
    menu_draw_line "$SEL"
    menu_dispatch "${M_KEY[idx]}"
}

# Читает одно событие ввода и кладёт его в KEY в нормализованном виде:
# up / down / enter / esc / click (строка экрана — в CLICK_ROW) / ignore / символ.
# Понимает SGR-мышь (\e[<b;x;yM) и стрелки (\e[A..B).
KEY=""; CLICK_ROW=0
read_key() {
    KEY=""; CLICK_ROW=0
    local c c2 c3 seq="" ch btn row
    IFS= read -rsn1 c || return 1
    if [[ $c != $'\e' ]]; then
        [[ -z $c ]] && KEY=enter || KEY=$c
        return 0
    fi
    read -rsn1 -t 0.1 c2 || { KEY=esc; return 0; }
    [[ $c2 == "[" || $c2 == "O" ]] || { KEY=esc; return 0; }
    read -rsn1 -t 0.1 c3 || { KEY=esc; return 0; }

    if [[ $c3 == "<" ]]; then
        while read -rsn1 -t 0.2 ch; do
            seq+="$ch"
            [[ $ch == [Mm] ]] && break
        done
        [[ ${seq: -1} == "M" ]] || { KEY=ignore; return 0; }   # только нажатие
        seq=${seq%M}
        IFS=';' read -r btn _ row <<< "$seq"
        case $btn in
            0)  KEY=click; CLICK_ROW=$row ;;
            64) KEY=up ;;
            65) KEY=down ;;
            *)  KEY=ignore ;;
        esac
        return 0
    fi

    case $c3 in
        A) KEY=up ;;
        B) KEY=down ;;
        *) KEY=ignore ;;
    esac
    return 0
}

menu() {
    [[ -t 0 && -t 1 ]] || die "Меню требует терминала. Список команд: wolbot help"
    menu_build
    SEL=0
    trap 'tui_off' EXIT TERM
    trap ':' INT          # Ctrl+C выходит из journalctl -f, но не из меню
    tui_on
    menu_draw_all

    while true; do
        read_key || continue
        case $KEY in
            up)     menu_move -1 ;;
            down)   menu_move 1 ;;
            enter)  menu_dispatch "${M_KEY[SEL]}" || break ;;
            click)  menu_click "$CLICK_ROW" || break ;;
            esc|ignore) ;;
            m)      MOUSE=$(( ! MOUSE )); (( MOUSE )) && mouse_on || mouse_off
                    menu_draw_all ;;
            q)      break ;;
            *)      if [[ " ${M_KEY[*]} " == *" $KEY "* ]]; then
                        menu_dispatch "$KEY" || break
                    fi ;;
        esac
    done
    tui_off
}

case "${1:-}" in
    "")             menu ;;
    status)         act_status ;;
    wake)           act_wake ;;
    sleep)          act_sleep ;;
    requests)       act_requests_list ;;
    approve)        [[ ${2:-} =~ ^[0-9]+$ ]] || die "Нужен числовой Telegram ID: wolbot approve 123456789"
                    req_approve "$2"; systemctl is-active --quiet "$SERVICE" && systemctl restart "$SERVICE" ;;
    logs)           [[ ${2:-} == -f ]] && journalctl -u "$SERVICE" -f \
                                       || journalctl -u "$SERVICE" -n 50 --no-pager ;;
    start|stop|restart) systemctl "$1" "$SERVICE" && sleep 1 && systemctl is-active "$SERVICE" ;;
    config)         act_show_config ;;
    edit)           "${EDITOR:-nano}" "$ENV_FILE"; restart_if_running ;;
    update)         act_update ;;
    -h|--help|help) usage ;;
    *)              usage; exit 1 ;;
esac
