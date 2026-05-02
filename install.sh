#!/bin/bash
set -euo pipefail

# ── Настройки логирования и UI ──────────────────────────────────────────
LOG_FILE="/var/log/telemt_install.log"
exec 3>&1 4>&2
trap 'exec 2>&4 1>&3' 0 1 2 3
exec 1> >(tee -a "$LOG_FILE") 2> >(tee -a "$LOG_FILE" >&2)

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

draw_progress() {
    local step=$1 total=$2 text=$3
    local pct=$((step * 100 / total))
    local filled=$((pct / 2))
    local empty=$((50 - filled))
    printf "\r\033[K${CYAN}[${RESET}${GREEN}%-${filled}s${RESET}${YELLOW}%-${empty}s${RESET}${CYAN}]${RESET} ${BOLD}%3d%%${RESET} - %s" \
        "$(printf '#%.0s' $(seq 1 $filled))" "$(printf '-%.0s' $(seq 1 $empty))" "$pct" "$text"
}

# ── Баннер ──────────────────────────────────────────────────────────────
clear
echo -e "${CYAN}${BOLD}"
echo "  ███╗   ███╗████████╗██████╗ ██████╗  ██████╗ ████████╗ ██████╗ "
echo "  ████╗ ████║╚══██╔══╝██╔══██╗██╔══██╗██╔═══██╗╚══██╔══╝██╔═══██╗"
echo "  ██╔████╔██║   ██║   ██████╔╝██████╔╝██║   ██║   ██║   ██║   ██║"
echo "  ██║╚██╔╝██║   ██║   ██╔═══╝ ██╔══██╗██║   ██║   ██║   ██║   ██║"
echo "  ██║ ╚═╝ ██║   ██║   ██║     ██║  ██║╚██████╔╝   ██║   ╚██████╔╝"
echo "  ╚═╝     ╚═╝   ╚═╝   ╚═╝     ╚═╝  ╚═╝ ╚═════╝    ╚═╝   ╚═════╝  "
echo -e "${RESET}${BLUE}        MTProto Proxy Telegram Installer 2026 by Mr_EFES${RESET}\n"

if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}Ошибка: запустите скрипт от имени root.${RESET}"
    exit 1
fi

# ==========================================
# ВВОД ДАННЫХ
# ==========================================
echo -e "${BOLD}--- НАСТРОЙКА ---${RESET}"
read -rp "1. Домен ПРОКСИ (напр. tg.example.com): " PROXY_DOMAIN
read -rp "2. Домен ПАНЕЛИ (напр. admin.example.com): " PANEL_DOMAIN
read -rp "3. Укажите порт ПАНЕЛИ [По умолчанию 4444]: " PANEL_PORT_INPUT
PANEL_PORT=${PANEL_PORT_INPUT:-4444}

echo -e "\n${BOLD}Выберите домен для Fake TLS маскировки:${RESET}"
echo "  1) ads.x5.ru"
echo "  2) 1c.ru"
echo "  3) ozon.ru"
echo "  4) vk.com"
echo "  5) max.ru"
echo "  6) Свой вариант (просто введите домен)"
read -rp "Ваш выбор: " FAKE_CHOICE

case "${FAKE_CHOICE}" in
    1) FAKE_DOMAIN="ads.x5.ru" ;;
    2) FAKE_DOMAIN="1c.ru" ;;
    3) FAKE_DOMAIN="ozon.ru" ;;
    4) FAKE_DOMAIN="vk.com" ;;
    5) FAKE_DOMAIN="max.ru" ;;
    "") FAKE_DOMAIN="max.ru" ;;
    *) FAKE_DOMAIN="${FAKE_CHOICE}" ;;
esac

echo -e "\n${GREEN}Ожидайте, идет автоматическая установка...${RESET}\n"

# ==========================================
# УСТАНОВКА
# ==========================================
TOTAL_STEPS=10
STEP=0

# Шаг 1
((STEP++)); draw_progress $STEP $TOTAL_STEPS "Обновление системных пакетов..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -y -qq >/dev/null 2>&1
apt-get install -y -qq curl wget jq openssl certbot xxd socat ufw python3 python3-pip python3-venv iproute2 net-tools qrencode >/dev/null 2>&1

# Шаг 2
((STEP++)); draw_progress $STEP $TOTAL_STEPS "Выпуск SSL сертификатов..."
certbot certonly --standalone -d "${PROXY_DOMAIN}" --register-unsafely-without-email --agree-tos --non-interactive --quiet >/dev/null 2>&1 || true
certbot certonly --standalone -d "${PANEL_DOMAIN}" --register-unsafely-without-email --agree-tos --non-interactive --quiet >/dev/null 2>&1 || true

# Шаг 3 (и далее остальные шаги установки...)
# [Здесь идет остальная часть кода из предыдущего ответа, включая Backend, Frontend и настройки]
# ...
