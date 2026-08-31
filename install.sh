#!/usr/bin/env bash
# Установка wolbot на Debian/Ubuntu. Запускать от root на целевой машине.
#
#   из клона:  sudo ./install.sh
#   одной строкой:
#     curl -fsSL https://raw.githubusercontent.com/youenmy/WOL_Bot/main/install.sh | sudo bash
set -euo pipefail

APP_DIR=/opt/wolbot
ENV_FILE=/etc/wolbot.env
RAW_URL=${WOLBOT_RAW_URL:-https://raw.githubusercontent.com/youenmy/WOL_Bot/main}
FILES=(wolbot.py wolbot-cli.sh wolbot.service install.sh requirements.txt .env.example README.md)

if [[ $EUID -ne 0 ]]; then
    echo "Запускать от root: sudo ./install.sh" >&2
    exit 1
fi

# При запуске через `curl | bash` рядом со скриптом файлов нет — качаем их сами.
SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-.}")" 2>/dev/null && pwd || echo .)"
if [[ ! -f "$SRC_DIR/wolbot.py" ]]; then
    echo "==> Качаю исходники из $RAW_URL"
    if ! command -v curl >/dev/null; then
        apt-get update -qq || true
        apt-get install -y -qq curl
    fi
    SRC_DIR=$(mktemp -d)
    trap 'rm -rf "$SRC_DIR"' EXIT
    for f in "${FILES[@]}"; do
        curl -fsSL "$RAW_URL/$f" -o "$SRC_DIR/$f" \
            || { echo "Не удалось скачать $f" >&2; exit 1; }
    done
fi

echo "==> Пакеты"
# На хосте Proxmox без подписки apt-get update возвращает ошибку по
# enterprise-репозиторию, поэтому ставим пакеты только если их правда нет.
missing=()
command -v python3 >/dev/null || missing+=(python3)
python3 -c 'import venv' 2>/dev/null || missing+=(python3-venv)
command -v ping >/dev/null || missing+=(iputils-ping)
command -v ssh >/dev/null || missing+=(openssh-client)
if [[ ${#missing[@]} -gt 0 ]]; then
    echo "    ставлю: ${missing[*]}"
    apt-get update -qq || echo "    (apt-get update с ошибками, продолжаю)"
    apt-get install -y -qq "${missing[@]}"
else
    echo "    всё уже установлено"
fi

echo "==> Пользователь wolbot"
id -u wolbot &>/dev/null || useradd --system --no-create-home --shell /usr/sbin/nologin wolbot

echo "==> Файлы в $APP_DIR"
install -d -o wolbot -g wolbot "$APP_DIR"
install -o wolbot -g wolbot -m 644 "$SRC_DIR/wolbot.py" "$APP_DIR/wolbot.py"
install -o wolbot -g wolbot -m 644 "$SRC_DIR/requirements.txt" "$APP_DIR/requirements.txt"

# Копия исходников рядом с приложением — из неё работает `wolbot update`.
if [[ "$SRC_DIR" != "$APP_DIR/src" ]]; then
    install -d -m 755 "$APP_DIR/src"
    for f in "${FILES[@]}"; do
        [[ -f "$SRC_DIR/$f" ]] && install -m 644 "$SRC_DIR/$f" "$APP_DIR/src/$f"
    done
    chmod 755 "$APP_DIR/src/wolbot-cli.sh" "$APP_DIR/src/install.sh"
fi

echo "==> Команда wolbot"
install -m 755 "$SRC_DIR/wolbot-cli.sh" "$APP_DIR/wolbot-cli.sh"
ln -sfn "$APP_DIR/wolbot-cli.sh" /usr/local/bin/wolbot

echo "==> venv"
if [[ ! -x "$APP_DIR/venv/bin/python" ]]; then
    python3 -m venv "$APP_DIR/venv"
fi
"$APP_DIR/venv/bin/pip" install --quiet --upgrade pip
"$APP_DIR/venv/bin/pip" install --quiet -r "$APP_DIR/requirements.txt"
chown -R wolbot:wolbot "$APP_DIR/venv"

echo "==> Конфиг $ENV_FILE"
if [[ ! -f "$ENV_FILE" ]]; then
    install -o root -g wolbot -m 640 "$SRC_DIR/.env.example" "$ENV_FILE"
    echo "    создан из шаблона — заполните его в меню"
else
    echo "    уже существует, не трогаю"
fi

echo "==> ICMP-ping без root"
# Позволяет непривилегированному процессу открывать ICMP-датаграммы,
# иначе ping внутри юнита с NoNewPrivileges не работает.
echo 'net.ipv4.ping_group_range = 0 2147483647' > /etc/sysctl.d/99-wolbot-ping.conf
sysctl -q -p /etc/sysctl.d/99-wolbot-ping.conf

echo "==> systemd"
install -m 644 "$SRC_DIR/wolbot.service" /etc/systemd/system/wolbot.service
systemctl daemon-reload
systemctl enable wolbot.service

cat <<MSG

Готово. Дальше просто:

    wolbot

Меню сделает остальное: токен, MAC и адрес компьютера, список ID, запуск.
MSG
