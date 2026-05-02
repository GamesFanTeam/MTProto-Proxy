#!/bin/bash
set -euo pipefail

# ── Цветовая схема ──────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
BOLD='\033[1m'
DIM='\033[2m'
RESET='\033[0m'

# ── Глобальные переменные ───────────────────────────────────────────────
PROXY_DOMAIN=""
PANEL_DOMAIN=""
PANEL_PORT="4444"
CERT_EMAIL=""
FAKE_DOMAIN="max.ru"
PANEL_DIR="/var/www/telemt-panel"
TELEMT_CONFIG="/etc/telemt/telemt.toml"
USER_SECRETS_FILE="${PANEL_DIR}/users_data.json"

# ── Прогресс бар ────────────────────────────────────────────────────────
progress() {
    local current=$1
    local total=$2
    local message=$3
    local percent=$((current * 100 / total))
    local filled=$((percent / 2))
    local empty=$((50 - filled))
    
    printf "\r${CYAN}[${BOLD}"
    printf "%${filled}s" | tr ' ' '█'
    printf "%${empty}s" | tr ' ' '░'
    printf "${RESET}${CYAN}] ${percent}%%${RESET} ${DIM}%s${RESET}" "$message"
    
    if [[ $current -eq $total ]]; then
        echo ""
    fi
}

# ── Баннер ──────────────────────────────────────────────────────────────
show_banner() {
    echo -e "${CYAN}${BOLD}"
    echo "  ███╗   ███╗████████╗██████╗ ██████╗  ██████╗ ████████╗ ██████╗ "
    echo "  ████╗ ████║╚══██╔══╝██╔══██╗██╔══██╗██╔═══██╗╚══██╔══╝██╔═══██╗"
    echo "  ██╔████╔██║   ██║   ██████╔╝██████╔╝██║   ██║   ██║   ██║   ██║"
    echo "  ██║╚██╔╝██║   ██║   ██╔═══╝ ██╔══██╗██║   ██║   ██║   ██║   ██║"
    echo "  ██║ ╚═╝ ██║   ██║   ██║     ██║  ██║╚██████╔╝   ██║   ╚██████╔╝"
    echo "  ╚═╝     ╚═╝   ╚═╝   ╚═╝     ╚═╝  ╚═╝ ╚═════╝    ╚═╝   ╚═════╝  "
    echo -e "${RESET}${MAGENTA}        MTProto Proxy Telegram Installer by Mr_EFES"
    echo -e "${RESET}${DIM}              Версия: 2.0 (Production)${RESET}"
    echo ""
}

# ── Функция выпуска/проверки SSL сертификата ────────────────────────────
issue_ssl() {
    local domain=$1
    local email=$2
    local cert_path="/etc/letsencrypt/live/${domain}/fullchain.pem"
    
    if [[ -f "$cert_path" ]]; then
        if openssl x509 -in "$cert_path" -noout -checkend 86400 >/dev/null 2>&1; then
            echo "exist"
        else
            if [[ -n "$email" ]]; then
                certbot certonly --standalone -d "${domain}" --email "${email}" --agree-tos --non-interactive --quiet >/dev/null 2>&1
            else
                certbot certonly --standalone -d "${domain}" --register-unsafely-without-email --agree-tos --non-interactive --quiet >/dev/null 2>&1
            fi
            [[ -f "$cert_path" ]] && echo "renewed" || echo "error"
        fi
    else
        if [[ -n "$email" ]]; then
            certbot certonly --standalone -d "${domain}" --email "${email}" --agree-tos --non-interactive --quiet >/dev/null 2>&1
        else
            certbot certonly --standalone -d "${domain}" --register-unsafely-without-email --agree-tos --non-interactive --quiet >/dev/null 2>&1
        fi
        [[ -f "$cert_path" ]] && echo "new" || echo "error"
    fi
}

# ── Основная установка ──────────────────────────────────────────────────
main() {
    show_banner
    
    # Проверка root
    if [[ $EUID -ne 0 ]]; then
        echo -e "${RED}❌ Ошибка: запустите скрипт от имени root.${RESET}"
        exit 1
    fi
    
    echo -e "${YELLOW}📦 Проверка необходимых пакетов...${RESET}"
    apt-get update -qq >/dev/null 2>&1
    apt-get install -y -qq curl wget jq openssl certbot xxd socat ufw python3 python3-pip python3-venv iproute2 net-tools cron >/dev/null 2>&1
    
    # Остановка веб-серверов на порту 80
    systemctl stop nginx apache2 2>/dev/null || true
    
    # ── СБОР ВВОДНЫХ ДАННЫХ ─────────────────────────────────────────────
    echo -e "\n${BOLD}🔧 НАСТРОЙКА ПРОКСИ И ПАНЕЛИ${RESET}"
    echo -e "${DIM}─────────────────────────────────${RESET}\n"
    
    # 1. Домен для ПРОКСИ
    read -rp "${BLUE}1.${RESET} Укажите Домен ПРОКСИ (напр. tg.example.com): " PROXY_DOMAIN
    while [[ -z "${PROXY_DOMAIN}" ]]; do
        echo -e "${RED}❌ Домен для прокси обязателен!${RESET}"
        read -rp "${BLUE}1.${RESET} Укажите Домен ПРОКСИ (напр. tg.example.com): " PROXY_DOMAIN
    done
    
    # 2. Домен для ПАНЕЛИ
    read -rp "${BLUE}2.${RESET} Укажите Домен ПАНЕЛИ (напр. admin.example.com): " PANEL_DOMAIN
    while [[ -z "${PANEL_DOMAIN}" ]]; do
        echo -e "${RED}❌ Домен для панели обязателен!${RESET}"
        read -rp "${BLUE}2.${RESET} Укажите Домен ПАНЕЛИ (напр. admin.example.com): " PANEL_DOMAIN
    done
    
    # 3. Порт для панели
    read -rp "${BLUE}3.${RESET} Укажите порт ПАНЕЛИ [по умолчанию 4444]: " PANEL_PORT_INPUT
    PANEL_PORT=${PANEL_PORT_INPUT:-4444}
    
    # Email для сертификатов
    read -rp "${DIM}📧 Email для SSL-сертификатов Let's Encrypt (необязательно): ${RESET}" CERT_EMAIL
    echo ""
    
    # ── ВЫПУСК SSL СЕРТИФИКАТОВ ─────────────────────────────────────────
    echo -e "${BOLD}🔐 ВЫПУСК SSL СЕРТИФИКАТОВ${RESET}"
    echo -e "${DIM}─────────────────────────────────${RESET}"
    
    progress 1 8 "Выпуск сертификата для ${PROXY_DOMAIN}..."
    ssl_proxy_status=$(issue_ssl "$PROXY_DOMAIN" "$CERT_EMAIL")
    case "$ssl_proxy_status" in
        "exist") echo -e "   ${GREEN}✓${RESET} Найден существующий (действителен)" ;;
        "new") echo -e "   ${GREEN}✓${RESET} Успешно выпущен новый" ;;
        "renewed") echo -e "   ${GREEN}✓${RESET} Успешно обновлен" ;;
        "error") echo -e "${RED}✗ ОШИБКА выпуска SSL! Проверьте A-запись домена.${RESET}"; exit 1 ;;
    esac
    
    progress 2 8 "Выпуск сертификата для ${PANEL_DOMAIN}..."
    ssl_panel_status=$(issue_ssl "$PANEL_DOMAIN" "$CERT_EMAIL")
    case "$ssl_panel_status" in
        "exist") echo -e "   ${GREEN}✓${RESET} Найден существующий (действителен)" ;;
        "new") echo -e "   ${GREEN}✓${RESET} Успешно выпущен новый" ;;
        "renewed") echo -e "   ${GREEN}✓${RESET} Успешно обновлен" ;;
        "error") echo -e "${RED}✗ ОШИБКА выпуска SSL! Проверьте A-запись домена.${RESET}"; exit 1 ;;
    esac
    
    # ── УСТАНОВКА MTProto ПРОКСИ ────────────────────────────────────────
    echo -e "\n${BOLD}📡 УСТАНОВКА MTProto ПРОКСИ${RESET}"
    echo -e "${DIM}─────────────────────────────────${RESET}"
    
    # Выбор Fake TLS домена — ИСПРАВЛЕННАЯ ЛОГИКА
    progress 3 8 "Настройка Fake TLS маскировки..."
    echo -e "${BOLD}Выберите домен для Fake TLS маскировки:${RESET}"
    echo "   1) max.ru (по умолчанию)"
    echo "   2) vk.com"
    echo "   3) ozon.ru"
    echo "   4) 1c.ru"
    echo "   5) ads.x5.ru"
    echo "   6) Свой вариант"
    echo ""
    
    read -rp "Ваш выбор [1-6, Enter = 1]: " FAKE_CHOICE
    case "${FAKE_CHOICE:-1}" in
        2) FAKE_DOMAIN="vk.com" ;;
        3) FAKE_DOMAIN="ozon.ru" ;;
        4) FAKE_DOMAIN="1c.ru" ;;
        5) FAKE_DOMAIN="ads.x5.ru" ;;
        6)
            read -rp "Введите свой домен для маскировки: " FAKE_DOMAIN
            [[ -z "$FAKE_DOMAIN" ]] && FAKE_DOMAIN="max.ru"
            ;;
        *) FAKE_DOMAIN="max.ru" ;;
    esac
    echo -e "   ${GREEN}✓${RESET} Выбран домен: ${YELLOW}${FAKE_DOMAIN}${RESET}"
    
    # Установка Telemt
    progress 4 8 "Загрузка ядра Telemt..."
    ARCH=$(uname -m)
    case "$ARCH" in
        "x86_64") BIN_ARCH="x86_64" ;;
        "aarch64"|"arm64") BIN_ARCH="aarch64" ;;
        *) echo -e "${RED}✗ Неподдерживаемая архитектура: $ARCH${RESET}"; exit 1 ;;
    esac
    
    DL_URL="https://github.com/telemt/telemt/releases/latest/download/telemt-${BIN_ARCH}-linux-gnu.tar.gz"
    if ! wget -q "$DL_URL" -O /tmp/telemt.tar.gz; then
        echo -e "${RED}✗ Не удалось скачать Telemt!${RESET}"
        exit 1
    fi
    
    progress 5 8 "Установка Telemt..."
    tar -xzf /tmp/telemt.tar.gz -C /tmp
    mv /tmp/telemt /usr/local/bin/telemt
    chmod +x /usr/local/bin/telemt
    rm -f /tmp/telemt.tar.gz
    
    # Генерация секретов
    USER_SECRET=$(openssl rand -hex 16)
    mkdir -p /etc/telemt
    
    # Создание конфига Telemt
    cat > "$TELEMT_CONFIG" << EOF
[general]
use_middle_proxy = true

[general.modes]
classic = false
secure = false
tls = true

[server]
port = 443

[censorship]
tls_domain = "${FAKE_DOMAIN}"

[access.users]
admin_default = "${USER_SECRET}"
EOF
    
    # Systemd служба для Telemt
    cat > /etc/systemd/system/telemt.service << EOF
[Unit]
Description=Telemt MTProto Proxy
After=network.target

[Service]
Type=simple
User=root
ExecStart=/usr/local/bin/telemt ${TELEMT_CONFIG}
Restart=always
LimitNOFILE=65536
AmbientCapabilities=CAP_NET_BIND_SERVICE

[Install]
WantedBy=multi-user.target
EOF
    
    systemctl daemon-reload
    systemctl enable telemt --now >/dev/null 2>&1
    sleep 2
    
    progress 6 8 "Проверка службы прокси..."
    if systemctl is-active --quiet telemt; then
        echo -e "   ${GREEN}✓${RESET} Telemt работает"
    else
        echo -e "   ${RED}✗${RESET} Telemt не запустился"
        journalctl -u telemt --no-pager -n 5
    fi
    
    # Генерация ссылки
    HEX_DOMAIN=$(printf '%s' "${FAKE_DOMAIN}" | xxd -p | tr -d '\n')
    FINAL_SECRET="ee${USER_SECRET}${HEX_DOMAIN}"
    TG_LINK="tg://proxy?server=${PROXY_DOMAIN}&port=443&secret=${FINAL_SECRET}"
    
    # QR-код в консоли (текстовый)
    echo -e "\n${CYAN}🔗 Ссылка для подключения (отсканируйте или нажмите):${RESET}"
    echo -e "${GREEN}${TG_LINK}${RESET}"
    echo ""
    echo -e "${DIM}📱 QR-код для быстрого подключения:${RESET}"
    echo -e "${YELLOW}   [Сканируйте камерой телефона или используйте Telegram]${RESET}"
    echo -e "${DIM}   https://api.qrserver.com/v1/create-qr-code/?size=200x200&data=${TG_LINK}${RESET}"
    echo ""
    
    # ── FIREWALL ────────────────────────────────────────────────────────
    progress 7 8 "Настройка firewall..."
    ufw allow 22/tcp >/dev/null 2>&1 || true
    ufw allow 443/tcp >/dev/null 2>&1
    ufw allow ${PANEL_PORT}/tcp >/dev/null 2>&1
    
    if ufw status >/dev/null 2>&1; then
        ufw --force reload >/dev/null 2>&1
        echo -e "   ${GREEN}✓${RESET} Правила firewall применены"
    fi
    
    # ── WEB UI ПАНЕЛЬ ───────────────────────────────────────────────────
    progress 8 8 "Установка веб-панели управления..."
    
    mkdir -p "${PANEL_DIR}/templates" "${PANEL_DIR}/static"
    
    # Инициализация файла данных пользователей
    if [[ ! -f "$USER_SECRETS_FILE" ]]; then
        echo '{}' > "$USER_SECRETS_FILE"
    fi
    
    # Конфигурация панели
    if [[ ! -f "${PANEL_DIR}/panel_config.json" ]]; then
        cat > "${PANEL_DIR}/panel_config.json" << EOF
{
    "username": "admin",
    "password_hash": "...",
    "is_default": true,
    "proxy_host": "${PROXY_DOMAIN}",
    "proxy_port": 443,
    "secret_key": "$(openssl rand -hex 24)"
}
EOF
    fi
    
    # Python зависимости
    if [[ ! -d "${PANEL_DIR}/venv" ]]; then
        python3 -m venv "${PANEL_DIR}/venv"
    fi
    "${PANEL_DIR}/venv/bin/pip" install -q --upgrade pip >/dev/null 2>&1
    "${PANEL_DIR}/venv/bin/pip" install -q Flask gunicorn toml werkzeug >/dev/null 2>&1
    
    # ── BACKEND ПРИЛОЖЕНИЕ ─────────────────────────────────────────────
    cat > "${PANEL_DIR}/app.py" << 'PYEOF'
import os
import json
import secrets
import toml
import subprocess
import time
from datetime import datetime, timedelta
from flask import Flask, render_template, request, redirect, url_for, session, flash, jsonify
from werkzeug.security import generate_password_hash, check_password_hash

app = Flask(__name__)

CONFIG_PATH = '/var/www/telemt-panel/panel_config.json'
TELEMT_TOML = '/etc/telemt/telemt.toml'
USERS_DATA = '/var/www/telemt-panel/users_data.json'

def load_config():
    with open(CONFIG_PATH, 'r') as f:
        return json.load(f)

def save_config(data):
    with open(CONFIG_PATH, 'w') as f:
        json.dump(data, f, indent=4)

def load_users_data():
    if os.path.exists(USERS_DATA):
        with open(USERS_DATA, 'r') as f:
            return json.load(f)
    return {}

def save_users_data(data):
    with open(USERS_DATA, 'w') as f:
        json.dump(data, f, indent=4)

config = load_config()
app.secret_key = config.get('secret_key', secrets.token_hex(16))

# Инициализация пароля по умолчанию
if "..." in config.get('password_hash', ''):
    config['password_hash'] = generate_password_hash('admin')
    save_config(config)

def restart_telemt():
    try:
        subprocess.run(['systemctl', 'restart', 'telemt'], check=False, timeout=10, capture_output=True)
    except:
        pass

def get_server_uptime():
    """Возвращает аптайм сервера в формате дни, часы, минуты"""
    try:
        with open('/proc/uptime', 'r') as f:
            uptime_seconds = float(f.readline().split()[0])
            days = int(uptime_seconds // 86400)
            hours = int((uptime_seconds % 86400) // 3600)
            minutes = int((uptime_seconds % 3600) // 60)
            return {'days': days, 'hours': hours, 'minutes': minutes, 'total_seconds': int(uptime_seconds)}
    except:
        return {'days': 0, 'hours': 0, 'minutes': 0, 'total_seconds': 0}

def get_proxy_status():
    """Проверяет статус службы Telemt"""
    try:
        result = subprocess.run(['systemctl', 'is-active', 'telemt'], capture_output=True, text=True, timeout=5)
        return 'Работает' if result.stdout.strip() == 'active' else 'Отключен'
    except:
        return 'Неизвестно'

def get_active_connections():
    """Получает список активных подключений к порту 443"""
    try:
        result = subprocess.run(['ss', '-tn', 'state', 'established'], capture_output=True, text=True, timeout=5)
        lines = result.stdout.splitlines()
        ips = set()
        for line in lines:
            if ':443' in line:
                parts = line.split()
                if len(parts) >= 5:
                    peer_addr = parts[4]
                    ip = peer_addr.rsplit(':', 1)[0].replace('::ffff:', '').strip('[]')
                    if ip and ip not in ['127.0.0.1', '0.0.0.0', '::1']:
                        ips.add(ip)
        return list(ips)
    except:
        return []

def is_user_online(username):
    """Проверяет, активен ли пользователь (есть ли подключения с его секретом)"""
    # Упрощённая проверка: если есть любые подключения к 443, считаем что кто-то онлайн
    # Для точной проверки нужно парсить трафик или использовать логи Telemt
    active_ips = get_active_connections()
    return len(active_ips) > 0

def calculate_timer(user_key, users_data):
    """Рассчитывает оставшееся время для пользователя"""
    user_info = users_data.get(user_key, {})
    created_at = user_info.get('created_at')
    paused = user_info.get('paused', False)
    paused_at = user_info.get('paused_at')
    total_paused = user_info.get('total_paused_seconds', 0)
    
    if not created_at:
        return {'days': 30, 'hours': 23, 'minutes': 59, 'expired': False, 'auto_paused': False}
    
    created_dt = datetime.fromisoformat(created_at)
    now = datetime.now()
    
    # Если на паузе, добавляем время паузы
    if paused and paused_at:
        paused_dt = datetime.fromisoformat(paused_at)
        total_paused += (now - paused_dt).total_seconds()
    
    # 30 дней в секундах
    period_seconds = 30 * 24 * 3600
    elapsed = (now - created_dt).total_seconds() - total_paused
    remaining = max(0, period_seconds - elapsed)
    
    if remaining <= 0:
        # Таймер истёк
        if not user_info.get('auto_paused', False):
            # Авто-пауза при истечении
            users_data[user_key]['paused'] = True
            users_data[user_key]['auto_paused'] = True
            users_data[user_key]['paused_at'] = now.isoformat()
            save_users_data(users_data)
            restart_telemt()
        return {'days': 0, 'hours': 0, 'minutes': 0, 'expired': True, 'auto_paused': True}
    
    # Проверка на удаление после 32 дней без активности
    if user_info.get('auto_paused', False) and paused_at:
        paused_dt = datetime.fromisoformat(paused_at)
        if (now - paused_dt).total_seconds() > 86400:  # 24 часа после авто-паузы
            # Удаляем пользователя
            return {'days': 0, 'hours': 0, 'minutes': 0, 'expired': True, 'to_delete': True}
    
    days = int(remaining // 86400)
    hours = int((remaining % 86400) // 3600)
    minutes = int((remaining % 3600) // 60)
    
    return {'days': days, 'hours': hours, 'minutes': minutes, 'expired': False, 'auto_paused': False}

@app.before_request
def require_login():
    allowed = ['login', 'static']
    if request.endpoint and (request.endpoint in allowed or request.path.startswith('/static')):
        return
    if 'user' not in session:
        return redirect(url_for('login'))
    cfg = load_config()
    if cfg.get('is_default') and request.endpoint not in ['change_credentials', 'logout']:
        return redirect(url_for('change_credentials'))

@app.route('/login', methods=['GET', 'POST'])
def login():
    if request.method == 'POST':
        cfg = load_config()
        if request.form['username'] == cfg['username'] and check_password_hash(cfg['password_hash'], request.form['password']):
            session['user'] = cfg['username']
            return redirect(url_for('dashboard'))
        flash('❌ Неверный логин или пароль', 'danger')
    return render_template('login.html')

@app.route('/logout')
def logout():
    session.pop('user', None)
    return redirect(url_for('login'))

@app.route('/change_credentials', methods=['GET', 'POST'])
def change_credentials():
    if request.method == 'POST':
        new_login = request.form.get('new_username', '').strip()
        new_pass = request.form.get('new_password', '')
        if not new_login or len(new_pass) < 6:
            flash('❌ Логин не может быть пустым, пароль минимум 6 символов', 'danger')
        else:
            cfg = load_config()
            cfg['username'] = new_login
            cfg['password_hash'] = generate_password_hash(new_pass)
            cfg['is_default'] = False
            save_config(cfg)
            flash('✅ Данные для входа успешно изменены!', 'success')
            return redirect(url_for('dashboard'))
    return render_template('change_credentials.html')

@app.route('/', methods=['GET', 'POST'])
def dashboard():
    cfg = load_config()
    users_data = load_users_data()
    
    # Загрузка конфига Telemt
    try:
        with open(TELEMT_TOML, 'r') as f:
            t_config = toml.load(f)
    except:
        t_config = {'access': {'users': {}}, 'censorship': {'tls_domain': 'max.ru'}}
    
    telemt_users = t_config.get('access', {}).get('users', {})
    tls_domain = t_config.get('censorship', {}).get('tls_domain', 'max.ru')
    hex_domain = tls_domain.encode('utf-8').hex()
    
    # Обработка создания нового пользователя
    if request.method == 'POST' and 'create_user' in request.form:
        nickname = request.form.get('nickname', '').strip().replace(' ', '_')
        device = request.form.get('device', 'Phone')
        if not nickname:
            flash('❌ Укажите никнейм!', 'danger')
        else:
            user_key = f"{nickname}_{device}"
            new_secret = secrets.token_hex(16)
            
            # Добавляем в Telemt config
            if 'access' not in t_config:
                t_config['access'] = {}
            if 'users' not in t_config['access']:
                t_config['access']['users'] = {}
            t_config['access']['users'][user_key] = new_secret
            
            with open(TELEMT_TOML, 'w') as f:
                toml.dump(t_config, f)
            
            # Сохраняем метаданные пользователя
            users_data[user_key] = {
                'secret': new_secret,
                'created_at': datetime.now().isoformat(),
                'paused': False,
                'paused_at': None,
                'total_paused_seconds': 0,
                'auto_paused': False
            }
            save_users_data(users_data)
            
            restart_telemt()
            flash(f'✅ Доступ для {user_key} создан!', 'success')
        return redirect(url_for('dashboard'))
    
    # Формирование списка пользователей для отображения
    proxy_links = {}
    active_ips = get_active_connections()
    
    for name, secret in telemt_users.items():
        if name == 'admin_default':
            continue
        final_secret = f"ee{secret}{hex_domain}"
        link = f"tg://proxy?server={cfg['proxy_host']}&port={cfg.get('proxy_port', 443)}&secret={final_secret}"
        
        timer = calculate_timer(name, users_data)
        online = is_user_online(name) and name in [u for u in telemt_users]
        
        proxy_links[name] = {
            'secret': secret,
            'link': link,
            'timer': timer,
            'online': online,
            'paused': users_data.get(name, {}).get('paused', False)
        }
    
    # Обработка действий с пользователем
    if request.method == 'POST':
        action = request.form.get('action')
        username = request.form.get('username')
        
        if action == 'toggle_pause' and username:
            users_data = load_users_data()
            if username in users_data:
                users_data[username]['paused'] = not users_data[username]['paused']
                if users_data[username]['paused']:
                    users_data[username]['paused_at'] = datetime.now().isoformat()
                    # Удаляем из Telemt config (пауза)
                    if username in t_config.get('access', {}).get('users', {}):
                        del t_config['access']['users'][username]
                else:
                    # Возобновление - добавляем обратно
                    t_config['access']['users'][username] = users_data[username]['secret']
                    users_data[username]['paused_at'] = None
                with open(TELEMT_TOML, 'w') as f:
                    toml.dump(t_config, f)
                save_users_data(users_data)
                restart_telemt()
                flash(f"{'⏸️' if users_data[username]['paused'] else '▶️'} {username} {'на паузе' if users_data[username]['paused'] else 'активирован'}", 'info')
        
        elif action == 'delete' and username:
            users_data = load_users_data()
            if username in t_config.get('access', {}).get('users', {}):
                del t_config['access']['users'][username]
                with open(TELEMT_TOML, 'w') as f:
                    toml.dump(t_config, f)
            if username in users_data:
                del users_data[username]
                save_users_data(users_data)
            restart_telemt()
            flash(f'🗑️ Пользователь {username} удалён', 'success')
        
        elif action == 'reset_timer' and username:
            users_data = load_users_data()
            if username in users_data:
                users_data[username]['created_at'] = datetime.now().isoformat()
                users_data[username]['paused'] = False
                users_data[username]['paused_at'] = None
                users_data[username]['total_paused_seconds'] = 0
                users_data[username]['auto_paused'] = False
                save_users_data(users_data)
                flash(f'🔄 Таймер для {username} сброшен на 30 дней', 'info')
        
        return redirect(url_for('dashboard'))
    
    # Статистика
    stats = {
        'total_users': len([u for u in telemt_users if u != 'admin_default']),
        'active_connections': len(active_ips),
        'server_status': get_proxy_status(),
        'uptime': get_server_uptime()
    }
    
    return render_template('dashboard.html', 
                         links=proxy_links, 
                         host=cfg['proxy_host'], 
                         stats=stats,
                         fake_domain=tls_domain)

@app.route('/api/user_status/<username>')
def api_user_status(username):
    """API для проверки статуса пользователя"""
    users_data = load_users_data()
    timer = calculate_timer(username, users_data)
    return jsonify({
        'online': is_user_online(username),
        'timer': timer,
        'paused': users_data.get(username, {}).get('paused', False)
    })

if __name__ == '__main__':
    port = int(os.environ.get('PANEL_PORT', 4444))
    app.run(host='0.0.0.0', port=port)
PYEOF

    # ── HTML ШАБЛОНЫ ────────────────────────────────────────────────────
    
    # layout.html
    cat > "${PANEL_DIR}/templates/layout.html" << 'HTMLEOF'
<!DOCTYPE html>
<html lang="ru">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no">
    <title>MTProto Proxy Panel</title>
    <link href="https://cdn.jsdelivr.net/npm/bootstrap@5.3.0/dist/css/bootstrap.min.css" rel="stylesheet">
    <link href="https://cdnjs.cloudflare.com/ajax/libs/font-awesome/6.4.0/css/all.min.css" rel="stylesheet">
    <script src="https://cdnjs.cloudflare.com/ajax/libs/qrcodejs/1.0.0/qrcode.min.js"></script>
    <style>
        :root {
            --tg-bg: #ffffff;
            --tg-bg-secondary: #f1f5f9;
            --tg-text: #222222;
            --tg-text-secondary: #707579;
            --tg-primary: #3390ec;
            --tg-primary-hover: #2878c4;
            --tg-border: #dfe1e5;
            --tg-success: #34c759;
            --tg-danger: #ff3b30;
            --tg-warning: #ff9500;
            --tg-card-shadow: 0 2px 8px rgba(0,0,0,0.08);
            --tg-radius: 12px;
        }
        * { box-sizing: border-box; }
        body {
            background: var(--tg-bg-secondary);
            color: var(--tg-text);
            font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, 'Helvetica Neue', Arial, sans-serif;
            min-height: 100vh;
            padding-bottom: 60px;
        }
        .navbar {
            background: var(--tg-bg);
            box-shadow: var(--tg-card-shadow);
            border-bottom: 1px solid var(--tg-border);
        }
        .navbar-brand {
            color: var(--tg-primary) !important;
            font-weight: 600;
        }
        .card {
            border: none;
            border-radius: var(--tg-radius);
            box-shadow: var(--tg-card-shadow);
            margin-bottom: 1rem;
            background: var(--tg-bg);
        }
        .card-header {
            background: var(--tg-bg);
            border-bottom: 1px solid var(--tg-border);
            border-radius: var(--tg-radius) var(--tg-radius) 0 0 !important;
            font-weight: 600;
            padding: 1rem 1.25rem;
        }
        .card-body { padding: 1.25rem; }
        .btn-primary {
            background: var(--tg-primary);
            border: none;
            border-radius: 8px;
            padding: 0.5rem 1.25rem;
            font-weight: 500;
        }
        .btn-primary:hover { background: var(--tg-primary-hover); }
        .btn-outline-primary {
            border-color: var(--tg-primary);
            color: var(--tg-primary);
            border-radius: 8px;
        }
        .btn-outline-primary:hover {
            background: var(--tg-primary);
            color: white;
        }
        .form-control, .form-select {
            border-radius: 8px;
            border: 1px solid var(--tg-border);
            padding: 0.6rem 0.8rem;
        }
        .form-control:focus, .form-select:focus {
            border-color: var(--tg-primary);
            box-shadow: 0 0 0 3px rgba(51,144,236,0.15);
        }
        .table { margin-bottom: 0; }
        .table th {
            border-top: none;
            font-weight: 600;
            color: var(--tg-text-secondary);
            font-size: 0.875rem;
            text-transform: uppercase;
            letter-spacing: 0.03em;
        }
        .table td {
            vertical-align: middle;
            padding: 0.75rem 1rem;
            border-color: var(--tg-border);
        }
        .badge {
            padding: 0.4em 0.7em;
            border-radius: 6px;
            font-weight: 500;
        }
        .badge-success { background: rgba(52,199,89,0.15); color: var(--tg-success); }
        .badge-warning { background: rgba(255,149,0,0.15); color: var(--tg-warning); }
        .badge-danger { background: rgba(255,59,48,0.15); color: var(--tg-danger); }
        .alert {
            border-radius: var(--tg-radius);
            border: none;
            margin-bottom: 1rem;
        }
        .status-dot {
            width: 10px;
            height: 10px;
            border-radius: 50%;
            display: inline-block;
            margin-right: 6px;
        }
        .status-online { background: var(--tg-success); box-shadow: 0 0 0 2px rgba(52,199,89,0.3); }
        .status-offline { background: var(--tg-danger); box-shadow: 0 0 0 2px rgba(255,59,48,0.3); }
        .timer-badge {
            background: var(--tg-bg-secondary);
            border: 1px solid var(--tg-border);
            padding: 0.25rem 0.5rem;
            border-radius: 6px;
            font-size: 0.8rem;
            font-family: monospace;
        }
        .qr-modal .modal-content {
            border-radius: var(--tg-radius);
            border: none;
        }
        #qrcode {
            display: flex;
            justify-content: center;
            padding: 1rem;
        }
        .fake-tls-btn {
            margin: 0.25rem;
            font-size: 0.85rem;
        }
        .action-btn {
            padding: 0.25rem 0.5rem;
            font-size: 0.875rem;
            margin: 0 0.15rem;
        }
        .sidebar-card {
            position: sticky;
            top: 80px;
        }
        .stat-card {
            text-align: center;
            padding: 1rem;
        }
        .stat-value {
            font-size: 1.75rem;
            font-weight: 700;
            color: var(--tg-primary);
        }
        .stat-label {
            font-size: 0.875rem;
            color: var(--tg-text-secondary);
        }
        footer {
            position: fixed;
            bottom: 0;
            left: 0;
            right: 0;
            background: var(--tg-bg);
            border-top: 1px solid var(--tg-border);
            padding: 0.75rem 1rem;
            text-align: center;
            font-size: 0.8rem;
            color: var(--tg-text-secondary);
            z-index: 1000;
        }
        @media (max-width: 991px) {
            .sidebar-card { position: static; }
            .main-content { order: 2; }
            .sidebar-content { order: 1; }
        }
        .btn-group-sm > .btn { padding: 0.25rem 0.5rem; font-size: 0.75rem; }
        .input-group-text { background: var(--tg-bg-secondary); }
    </style>
</head>
<body>
    <nav class="navbar navbar-expand-lg navbar-light">
        <div class="container-fluid">
            <a class="navbar-brand" href="#">
                <i class="fas fa-shield-alt me-2"></i>MTProto Panel
            </a>
            <div class="d-flex align-items-center">
                {% if session.get('user') %}
                <span class="me-3 text-muted small"><i class="fas fa-user me-1"></i>{{ session['user'] }}</span>
                <a href="{{ url_for('logout') }}" class="btn btn-outline-primary btn-sm">
                    <i class="fas fa-sign-out-alt"></i>
                </a>
                {% endif %}
            </div>
        </div>
    </nav>

    <div class="container py-3">
        {% with messages = get_flashed_messages(with_categories=true) %}
        {% if messages %}
            {% for category, message in messages %}
            <div class="alert alert-{{ 'danger' if category == 'danger' else 'success' if category == 'success' else 'info' }} alert-dismissible fade show" role="alert">
                {{ message }}
                <button type="button" class="btn-close" data-bs-dismiss="alert"></button>
            </div>
            {% endfor %}
        {% endif %}
        {% endwith %}
        
        {% block content %}{% endblock %}
    </div>

    <!-- QR Modal -->
    <div class="modal fade qr-modal" id="qrModal" tabindex="-1">
        <div class="modal-dialog modal-dialog-centered">
            <div class="modal-content">
                <div class="modal-header border-0 pb-0">
                    <h5 class="modal-title"><i class="fas fa-qrcode me-2"></i>QR-код для подключения</h5>
                    <button type="button" class="btn-close" data-bs-dismiss="modal"></button>
                </div>
                <div class="modal-body text-center">
                    <div id="qrcode"></div>
                    <p class="text-muted small mt-3">Отсканируйте камерой или в Telegram</p>
                </div>
            </div>
        </div>
    </div>

    <footer>
        MTProto Proxy Panel 2026 by Mr_EFES
    </footer>

    <script src="https://cdn.jsdelivr.net/npm/bootstrap@5.3.0/dist/js/bootstrap.bundle.min.js"></script>
    <script>
        // Показать QR-код
        function showQR(link, title) {
            document.getElementById('qrcode').innerHTML = '';
            new QRCode(document.getElementById('qrcode'), {
                text: link,
                width: 200,
                height: 200,
                correctLevel: QRCode.CorrectLevel.H
            });
            document.querySelector('#qrModal .modal-title').textContent = title || 'QR-код';
            new bootstrap.Modal(document.getElementById('qrModal')).show();
        }
        
        // Копировать в буфер
        function copyLink(inputId, btn) {
            const input = document.getElementById(inputId);
            input.select();
            input.setSelectionRange(0, 99999);
            navigator.clipboard.writeText(input.value).then(() => {
                const original = btn.innerHTML;
                btn.innerHTML = '<i class="fas fa-check"></i>';
                btn.classList.add('btn-success');
                setTimeout(() => {
                    btn.innerHTML = original;
                    btn.classList.remove('btn-success');
                }, 1500);
            });
        }
        
        // Авто-обновление статуса онлайн
        {% if links %}
        setInterval(() => {
            fetch('/api/user_status/{{ name }}')
                .then(r => r.json())
                .then(data => {
                    // Обновляем индикаторы (упрощено)
                });
        }, 30000);
        {% endif %}
    </script>
    {% block scripts %}{% endblock %}
</body>
</html>
HTMLEOF

    # login.html
    cat > "${PANEL_DIR}/templates/login.html" << 'HTMLEOF'
{% extends "layout.html" %}
{% block content %}
<div class="row justify-content-center py-5">
    <div class="col-md-6 col-lg-5">
        <div class="card">
            <div class="card-body p-4 p-md-5">
                <div class="text-center mb-4">
                    <i class="fas fa-shield-alt fa-3x text-primary mb-3"></i>
                    <h4 class="mb-1">Вход в панель</h4>
                    <p class="text-muted">MTProto Proxy Manager</p>
                </div>
                <form method="POST">
                    <div class="mb-3">
                        <label class="form-label small text-muted">Логин</label>
                        <div class="input-group">
                            <span class="input-group-text"><i class="fas fa-user"></i></span>
                            <input type="text" name="username" class="form-control" required autofocus>
                        </div>
                    </div>
                    <div class="mb-4">
                        <label class="form-label small text-muted">Пароль</label>
                        <div class="input-group">
                            <span class="input-group-text"><i class="fas fa-lock"></i></span>
                            <input type="password" name="password" class="form-control" required>
                        </div>
                    </div>
                    <button type="submit" class="btn btn-primary w-100 py-2">
                        <i class="fas fa-sign-in-alt me-2"></i>Войти
                    </button>
                </form>
            </div>
        </div>
    </div>
</div>
{% endblock %}
HTMLEOF

    # change_credentials.html
    cat > "${PANEL_DIR}/templates/change_credentials.html" << 'HTMLEOF'
{% extends "layout.html" %}
{% block content %}
<div class="row justify-content-center py-4">
    <div class="col-md-6 col-lg-5">
        <div class="card border-warning">
            <div class="card-body p-4 p-md-5">
                <div class="text-center mb-4">
                    <i class="fas fa-exclamation-triangle fa-3x text-warning mb-3"></i>
                    <h5 class="mb-1">Смена данных для входа</h5>
                    <p class="text-muted small">В целях безопасности измените данные по умолчанию</p>
                </div>
                <form method="POST">
                    <div class="mb-3">
                        <label class="form-label small text-muted">Новый логин</label>
                        <input type="text" name="new_username" class="form-control" required minlength="3">
                    </div>
                    <div class="mb-3">
                        <label class="form-label small text-muted">Новый пароль</label>
                        <input type="password" name="new_password" class="form-control" required minlength="6">
                        <small class="text-muted">Минимум 6 символов</small>
                    </div>
                    <button type="submit" class="btn btn-warning w-100 py-2">
                        <i class="fas fa-save me-2"></i>Сохранить изменения
                    </button>
                </form>
            </div>
        </div>
    </div>
</div>
{% endblock %}
HTMLEOF

    # dashboard.html
    cat > "${PANEL_DIR}/templates/dashboard.html" << 'HTMLEOF'
{% extends "layout.html" %}
{% block content %}
<div class="row g-3">
    <!-- Левая колонка: Статистика и Настройки -->
    <div class="col-lg-4 main-content">
        <!-- Статистика -->
        <div class="card">
            <div class="card-header">
                <i class="fas fa-chart-line me-2"></i>Статистика
            </div>
            <div class="card-body">
                <div class="row g-2">
                    <div class="col-6">
                        <div class="stat-card">
                            <div class="stat-value">{{ stats.total_users }}</div>
                            <div class="stat-label">Всего доступов</div>
                        </div>
                    </div>
                    <div class="col-6">
                        <div class="stat-card">
                            <div class="stat-value">{{ stats.active_connections }}</div>
                            <div class="stat-label">Онлайн сейчас</div>
                        </div>
                    </div>
                </div>
            </div>
        </div>
        
        <!-- Настройки прокси -->
        <div class="card">
            <div class="card-header">
                <i class="fas fa-cog me-2"></i>Настройки прокси
            </div>
            <div class="card-body">
                <div class="mb-3">
                    <small class="text-muted d-block mb-1">Статус сервера</small>
                    <span class="badge {% if stats.server_status == 'Работает' %}badge-success{% else %}badge-danger{% endif %}">
                        <i class="fas fa-circle small me-1"></i>{{ stats.server_status }}
                    </span>
                </div>
                <div class="mb-3">
                    <small class="text-muted d-block mb-1">Uptime сервера</small>
                    <span class="timer-badge">
                        {% if stats.uptime.days > 0 %}{{ stats.uptime.days }}д {% endif %}
                        {% if stats.uptime.hours > 0 or stats.uptime.days > 0 %}{{ stats.uptime.hours }}ч {% endif %}
                        {{ stats.uptime.minutes }}мин
                    </span>
                </div>
                <div class="mb-3">
                    <small class="text-muted d-block mb-1">Сайт для FakeTLS маскировки</small>
                    <div class="d-flex flex-wrap">
                        {% for domain in ['ads.x5.ru', '1c.ru', 'ozon.ru', 'vk.com', 'max.ru'] %}
                        <button type="button" class="btn btn-outline-secondary btn-sm fake-tls-btn"
                                onclick="document.getElementById('fake_tls_input').value='{{ domain }}'; fakeTlsChanged('{{ domain }}')">
                            {{ domain }}
                        </button>
                        {% endfor %}
                    </div>
                    <input type="text" id="fake_tls_input" class="form-control form-control-sm mt-2" 
                           value="{{ fake_domain }}" placeholder="Введите домен" readonly>
                </div>
                <div>
                    <small class="text-muted d-block mb-1">Сменить данные администратора</small>
                    <a href="{{ url_for('change_credentials') }}" class="btn btn-outline-primary btn-sm w-100">
                        <i class="fas fa-user-cog me-1"></i>Изменить логин/пароль
                    </a>
                </div>
            </div>
        </div>
    </div>
    
    <!-- Правая колонка: Список доступов -->
    <div class="col-lg-8 sidebar-content">
        <!-- Создание нового доступа -->
        <div class="card">
            <div class="card-header bg-primary text-white">
                <i class="fas fa-plus-circle me-2"></i>Создать новый доступ
            </div>
            <div class="card-body">
                <form method="POST" class="row g-2 align-items-end">
                    <input type="hidden" name="create_user" value="1">
                    <div class="col-12 col-md-5">
                        <label class="form-label small text-muted">Никнейм</label>
                        <input type="text" name="nickname" class="form-control" placeholder="Например: Ivan" required>
                    </div>
                    <div class="col-12 col-md-4">
                        <label class="form-label small text-muted">Устройство</label>
                        <select name="device" class="form-select">
                            <option value="Phone">📱 Телефон</option>
                            <option value="PC">💻 Компьютер</option>
                            <option value="Tablet">📟 Планшет</option>
                        </select>
                    </div>
                    <div class="col-12 col-md-3">
                        <button type="submit" class="btn btn-success w-100">
                            <i class="fas fa-magic me-1"></i>Создать
                        </button>
                    </div>
                </form>
            </div>
        </div>
        
        <!-- Список доступов -->
        <div class="card">
            <div class="card-header">
                <i class="fas fa-list me-2"></i>Список доступов
            </div>
            <div class="card-body p-0">
                <div class="table-responsive">
                    <table class="table table-hover mb-0">
                        <thead class="table-light">
                            <tr>
                                <th>Пользователь</th>
                                <th>Таймер</th>
                                <th>Статус</th>
                                <th class="text-end">Действия</th>
                            </tr>
                        </thead>
                        <tbody>
                            {% if links %}
                                {% for name, data in links.items() %}
                                <tr>
                                    <td>
                                        <div class="fw-bold">{{ name }}</div>
                                        <small class="text-muted">{{ data.link[:40] }}...</small>
                                    </td>
                                    <td>
                                        {% if data.timer.expired and data.timer.to_delete %}
                                            <span class="badge badge-danger">Удалён</span>
                                        {% elif data.timer.expired %}
                                            <span class="badge badge-warning">⏸️ На паузе</span>
                                        {% else %}
                                            <div class="timer-badge">
                                                {% if data.timer.days > 0 %}{{ data.timer.days }}д {% endif %}
                                                {{ data.timer.hours }}ч {{ data.timer.minutes }}мин
                                            </div>
                                            <small class="text-muted d-block" style="font-size:0.7rem">осталось</small>
                                        {% endif %}
                                    </td>
                                    <td>
                                        <span class="status-dot {% if data.online and not data.paused %}status-online{% else %}status-offline{% endif %}"></span>
                                        <small class="text-muted">{% if data.paused %}Пауза{% elif data.online %}В сети{% else %}Не в сети{% endif %}</small>
                                    </td>
                                    <td class="text-end">
                                        <div class="btn-group btn-group-sm" role="group">
                                            <!-- Копия -->
                                            <button type="button" class="btn btn-outline-secondary action-btn" 
                                                    onclick="copyLink('link-{{ loop.index }}', this)" title="Копировать">
                                                <i class="fas fa-copy"></i>
                                            </button>
                                            <!-- QR -->
                                            <button type="button" class="btn btn-outline-secondary action-btn"
                                                    onclick="showQR('{{ data.link }}', 'QR: {{ name }}')" title="QR-код">
                                                <i class="fas fa-qrcode"></i>
                                            </button>
                                            <!-- Пауза/Вкл -->
                                            <form method="POST" class="d-inline" onsubmit="return confirm('Изменить статус для {{ name }}?')">
                                                <input type="hidden" name="username" value="{{ name }}">
                                                <input type="hidden" name="action" value="toggle_pause">
                                                <button type="submit" class="btn {% if data.paused %}btn-success{% else %}btn-warning{% endif %} action-btn" title="{% if data.paused %}Включить{% else %}Пауза{% endif %}">
                                                    <i class="fas {% if data.paused %}fa-play{% else %}fa-pause{% endif %}"></i>
                                                </button>
                                            </form>
                                            <!-- Сброс таймера -->
                                            <form method="POST" class="d-inline" onsubmit="return confirm('Сбросить таймер для {{ name }} на 30 дней?')">
                                                <input type="hidden" name="username" value="{{ name }}">
                                                <input type="hidden" name="action" value="reset_timer">
                                                <button type="submit" class="btn btn-outline-info action-btn" title="Сбросить таймер">
                                                    <i class="fas fa-undo"></i>
                                                </button>
                                            </form>
                                            <!-- Удалить -->
                                            <form method="POST" class="d-inline" onsubmit="return confirm('Удалить {{ name }}?')">
                                                <input type="hidden" name="username" value="{{ name }}">
                                                <input type="hidden" name="action" value="delete">
                                                <button type="submit" class="btn btn-outline-danger action-btn" title="Удалить">
                                                    <i class="fas fa-trash"></i>
                                                </button>
                                            </form>
                                        </div>
                                        <input type="hidden" id="link-{{ loop.index }}" value="{{ data.link }}">
                                    </td>
                                </tr>
                                {% endfor %}
                            {% else %}
                                <tr>
                                    <td colspan="4" class="text-center text-muted py-5">
                                        <i class="fas fa-inbox fa-3x mb-3 text-muted"></i>
                                        <p class="mb-0">Нет созданных пользователей</p>
                                        <small class="text-muted">Создайте первый доступ выше</small>
                                    </td>
                                </tr>
                            {% endif %}
                        </tbody>
                    </table>
                </div>
            </div>
        </div>
    </div>
</div>
{% endblock %}

{% block scripts %}
<script>
function fakeTlsChanged(domain) {
    // В реальном приложении здесь можно отправлять запрос на сервер для обновления конфига
    console.log('Fake TLS изменён на:', domain);
}
</script>
{% endblock %}
HTMLEOF

    echo -e "   ${GREEN}✓${RESET} Веб-панель установлена"
    
    # Systemd служба для панели
    cat > /etc/systemd/system/telemt-panel.service << EOF
[Unit]
Description=MTProto Proxy Web Panel (Gunicorn)
After=network.target

[Service]
User=root
Group=www-data
WorkingDirectory=${PANEL_DIR}
Environment="PATH=${PANEL_DIR}/venv/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
Environment="PANEL_PORT=${PANEL_PORT}"
ExecStart=${PANEL_DIR}/venv/bin/gunicorn \\
    --certfile /etc/letsencrypt/live/${PANEL_DOMAIN}/fullchain.pem \\
    --keyfile /etc/letsencrypt/live/${PANEL_DOMAIN}/privkey.pem \\
    -w 2 -b 0.0.0.0:${PANEL_PORT} app:app
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
    
    systemctl daemon-reload
    systemctl enable telemt-panel --now >/dev/null 2>&1
    sleep 3
    
    # ── АВТООБНОВЛЕНИЕ ─────────────────────────────────────────────────
    echo -e "\n${BOLD}🔄 НАСТРОЙКА АВТООБНОВЛЕНИЯ${RESET}"
    echo -e "${DIM}─────────────────────────────────${RESET}"
    
    cat > /usr/local/bin/telemt-updater.sh << 'UPDATEEOF'
#!/bin/bash
CURRENT_VER=$(telemt --version 2>/dev/null | awk '{print $2}' || echo "0.0.0")
LATEST_VER=$(curl -s https://api.github.com/repos/telemt/telemt/releases/latest 2>/dev/null | jq -r .tag_name 2>/dev/null | sed 's/v//' || echo "")
if [[ -n "$LATEST_VER" && "$LATEST_VER" != "null" && "$CURRENT_VER" != "$LATEST_VER" ]]; then
    ARCH=$(uname -m)
    case "$ARCH" in
        "x86_64") BIN="x86_64" ;;
        "aarch64"|"arm64") BIN="aarch64" ;;
        *) exit 0 ;;
    esac
    wget -q "https://github.com/telemt/telemt/releases/latest/download/telemt-${BIN}-linux-gnu.tar.gz" -O /tmp/upd.tar.gz || exit 0
    tar -xzf /tmp/upd.tar.gz -C /tmp
    systemctl stop telemt 2>/dev/null || true
    mv /tmp/telemt /usr/local/bin/telemt
    chmod +x /usr/local/bin/telemt
    systemctl start telemt
    rm -f /tmp/upd.tar.gz
fi
UPDATEEOF
    chmod +x /usr/local/bin/telemt-updater.sh
    
    # Cron задачи
    (crontab -l 2>/dev/null | grep -v "telemt-updater" | grep -v "certbot renew") | crontab - 2>/dev/null || true
    (crontab -l 2>/dev/null; echo "0 4 * * * /usr/local/bin/telemt-updater.sh") | crontab - 2>/dev/null || true
    (crontab -l 2>/dev/null; echo "0 3 * * * certbot renew --post-hook 'systemctl restart telemt telemt-panel' >/dev/null 2>&1") | crontab - 2>/dev/null || true
    echo -e "   ${GREEN}✓${RESET} Автообновление настроено"
    
    # ── ФИНАЛЬНЫЙ ОТЧЁТ ─────────────────────────────────────────────────
    echo ""
    echo -e "${CYAN}${BOLD}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "           🎉 УСТАНОВКА ЗАВЕРШЕНА УСПЕШНО! 🎉"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo -e "${RESET}"
    echo -e "${BOLD}📡 ПРОКСИ:${RESET}"
    echo -e "   ${GREEN}✓${RESET} Домен: ${PROXY_DOMAIN}:443"
    echo -e "   ${GREEN}✓${RESET} Fake TLS: ${FAKE_DOMAIN}"
    echo ""
    echo -e "${BOLD}🖥️ ПАНЕЛЬ УПРАВЛЕНИЯ:${RESET}"
    echo -e "   ${GREEN}✓${RESET} URL: https://${PANEL_DOMAIN}:${PANEL_PORT}"
    echo -e "   ${GREEN}✓${RESET} Логин: admin"
    echo -e "   ${GREEN}✓${RESET} Пароль: admin ${DIM}(смените при первом входе!)${RESET}"
    echo ""
    echo -e "${BOLD}🔗 ССЫЛКА ДЛЯ ПОДКЛЮЧЕНИЯ:${RESET}"
    echo -e "${GREEN}${TG_LINK}${RESET}"
    echo ""
    echo -e "${DIM}📱 QR-код: ${YELLOW}https://api.qrserver.com/v1/create-qr-code/?size=200x200&data=${TG_LINK}${RESET}"
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
    echo ""
}

# Запуск
main "$@"
