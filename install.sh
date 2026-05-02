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
RESET='\033[0m'

# ── Баннер ──────────────────────────────────────────────────────────────
show_banner() {
    clear
    echo -e "${CYAN}${BOLD}"
    echo "  ███╗   ███╗████████╗██████╗ ██████╗  ██████╗ ████████╗ ██████╗ "
    echo "  ████╗ ████║╚══██╔══╝██╔══██╗██╔══██╗██╔═══██╗╚══██╔══╝██╔═══██╗"
    echo "  ██╔████╔██║   ██║   ██████╔╝██████╔╝██║   ██║   ██║   ██║   ██║"
    echo "  ██║╚██╔╝██║   ██║   ██╔═══╝ ██╔══██╗██║   ██║   ██║   ██║   ██║"
    echo "  ██║ ╚═╝ ██║   ██║   ██║     ██║  ██║╚██████╔╝   ██║   ╚██████╔╝"
    echo "  ╚═╝     ╚═╝   ╚═╝   ╚═╝     ╚═╝  ╚═╝ ╚═════╝    ╚═╝   ╚═════╝  "
    echo -e "${RESET}${MAGENTA}        MTProto Proxy Telegram Installer by Mr_EFES"
    echo -e "${RESET}"
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
            if [[ -f "$cert_path" ]]; then
                echo "renewed"
            else
                echo "error"
            fi
        fi
    else
        if [[ -n "$email" ]]; then
            certbot certonly --standalone -d "${domain}" --email "${email}" --agree-tos --non-interactive --quiet >/dev/null 2>&1
        else
            certbot certonly --standalone -d "${domain}" --register-unsafely-without-email --agree-tos --non-interactive --quiet >/dev/null 2>&1
        fi
        if [[ -f "$cert_path" ]]; then
            echo "new"
        else
            echo "error"
        fi
    fi
}

# ── Прогресс-шаг ────────────────────────────────────────────────────────
step() {
    echo -e "\n${BLUE}${BOLD}[$1]${RESET} $2"
}
info() {
    echo -e "${CYAN}$1${RESET}"
}
success() {
    echo -e "${GREEN}$1${RESET}"
}
error() {
    echo -e "${RED}$1${RESET}"
}

show_banner

if [[ $EUID -ne 0 ]]; then
    error "Ошибка: запустите скрипт от имени root."
    exit 1
fi

step "1/13" "Установка системных зависимостей..."
apt-get update -qq >/dev/null 2>&1
apt-get install -y -qq curl wget jq openssl certbot xxd socat ufw python3 python3-pip python3-venv iproute2 net-tools qrencode >/dev/null 2>&1
success "Системные пакеты установлены."

systemctl stop nginx apache2 2>/dev/null || true

# ==========================================
# СБОР ВВОДНЫХ ДАННЫХ
# ==========================================
step "2/13" "Сбор параметров установки..."

echo -e "${YELLOW}1. Укажите Домен ПРОКСИ (напр. tg.example.com):${RESET}"
read -rp "> " PROXY_DOMAIN
if [[ -z "${PROXY_DOMAIN}" ]]; then
    error "Домен для прокси обязателен!"
    exit 1
fi

echo -e "${YELLOW}2. Укажите Домен ПАНЕЛИ (напр. admin.example.com):${RESET}"
read -rp "> " PANEL_DOMAIN
if [[ -z "${PANEL_DOMAIN}" ]]; then
    error "Домен для панели обязателен!"
    exit 1
fi

echo -e "${YELLOW}3. Укажите порт для панели управления [по умолчанию 4444]:${RESET}"
read -rp "> " PANEL_PORT_INPUT
PANEL_PORT=${PANEL_PORT_INPUT:-4444}

echo -e "${YELLOW}4. Введите Email для SSL-сертификатов Let's Encrypt (необязательно):${RESET}"
read -rp "> " CERT_EMAIL

echo ""
info "Параметры установки:"
echo -e "  Прокси домен: ${PROXY_DOMAIN} (порт 443)"
echo -e "  Панель домен: ${PANEL_DOMAIN} (порт ${PANEL_PORT})"
if [[ -n "${CERT_EMAIL}" ]]; then
    echo -e "  Email для сертификатов: ${CERT_EMAIL}"
else
    echo -e "  Email: не указан"
fi

# ==========================================
# SSL СЕРТИФИКАТЫ
# ==========================================
step "3/13" "Выпуск SSL сертификатов..."

ssl_proxy_status=$(issue_ssl "$PROXY_DOMAIN" "$CERT_EMAIL")
case "$ssl_proxy_status" in
    "exist") success "Прокси: сертификат существует и действителен" ;;
    "new") success "Прокси: сертификат выпущен" ;;
    "renewed") success "Прокси: сертификат обновлён" ;;
    *) error "Ошибка выпуска SSL для прокси. Проверьте A-запись домена."; exit 1 ;;
esac

ssl_panel_status=$(issue_ssl "$PANEL_DOMAIN" "$CERT_EMAIL")
case "$ssl_panel_status" in
    "exist") success "Панель: сертификат существует и действителен" ;;
    "new") success "Панель: сертификат выпущен" ;;
    "renewed") success "Панель: сертификат обновлён" ;;
    *) error "Ошибка выпуска SSL для панели. Проверьте A-запись домена."; exit 1 ;;
esac

# ==========================================
# FAKE TLS
# ==========================================
step "4/13" "Выбор Fake TLS маскировки..."
echo -e "${BOLD}Выберите домен для Fake TLS маскировки:${RESET}"
echo "  1) ads.x5.ru"
echo "  2) 1c.ru"
echo "  3) ozon.ru"
echo "  4) vk.com"
echo "  5) max.ru"
echo "  6) Свой вариант"
read -rp "Ваш выбор [1-6, Enter = 5]: " FAKE_CHOICE
case "${FAKE_CHOICE:-5}" in
    1) FAKE_DOMAIN="ads.x5.ru" ;;
    2) FAKE_DOMAIN="1c.ru" ;;
    3) FAKE_DOMAIN="ozon.ru" ;;
    4) FAKE_DOMAIN="vk.com" ;;
    5) FAKE_DOMAIN="max.ru" ;;
    6)
        read -rp "Введите свой домен для маскировки: " CUSTOM_FAKE
        FAKE_DOMAIN=${CUSTOM_FAKE:-max.ru}
        ;;
    *) FAKE_DOMAIN="max.ru" ;;
esac
success "Fake TLS домен: ${FAKE_DOMAIN}"

# ==========================================
# УСТАНОВКА ПРОКСИ
# ==========================================
step "5/13" "Установка ядра Telemt..."
ARCH=$(uname -m)
case "$ARCH" in
    "x86_64") BIN_ARCH="x86_64" ;;
    "aarch64"|"arm64") BIN_ARCH="aarch64" ;;
    *)
        error "Неподдерживаемая архитектура: $ARCH"
        exit 1
        ;;
esac

DL_URL="https://github.com/telemt/telemt/releases/latest/download/telemt-${BIN_ARCH}-linux-gnu.tar.gz"
if ! wget -q "$DL_URL" -O /tmp/telemt.tar.gz; then
    error "Не удалось скачать Telemt!"
    exit 1
fi

tar -xzf /tmp/telemt.tar.gz -C /tmp
mv /tmp/telemt /usr/local/bin/telemt
chmod +x /usr/local/bin/telemt
rm -f /tmp/telemt.tar.gz

USER_SECRET=$(openssl rand -hex 16)
mkdir -p /etc/telemt

cat > /etc/telemt/telemt.toml << EOF
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

cat > /etc/systemd/system/telemt.service << EOF
[Unit]
Description=Telemt MTProto Proxy
After=network.target

[Service]
Type=simple
User=root
ExecStart=/usr/local/bin/telemt /etc/telemt/telemt.toml
Restart=always
LimitNOFILE=65536
AmbientCapabilities=CAP_NET_BIND_SERVICE

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable telemt --now >/dev/null 2>&1
sleep 2

if systemctl is-active --quiet telemt; then
    success "Служба Telemt запущена"
else
    error "Служба Telemt не запустилась! Логи:"
    journalctl -u telemt --no-pager -n 5
fi

if ss -tulpen 2>/dev/null | grep -q ":443" || netstat -tulpen 2>/dev/null | grep -q ":443"; then
    success "Порт 443 прослушивается"
else
    info "Порт 443 не обнаружен в ss, но это может быть нормально."
fi

HEX_DOMAIN=$(printf '%s' "${FAKE_DOMAIN}" | xxd -p | tr -d '\n')
FINAL_SECRET="ee${USER_SECRET}${HEX_DOMAIN}"
TG_LINK="tg://proxy?server=${PROXY_DOMAIN}&port=443&secret=${FINAL_SECRET}"

echo ""
info "Ссылка для подключения:"
echo -e "${GREEN}${TG_LINK}${RESET}"
echo ""
info "QR-код для подключения:"
qrencode -t ANSIUTF8 "$TG_LINK"

# ==========================================
# FIREWALL
# ==========================================
step "6/13" "Настройка файрвола..."
ufw allow 22/tcp >/dev/null 2>&1 || true
ufw allow 443/tcp >/dev/null 2>&1
ufw allow ${PANEL_PORT}/tcp >/dev/null 2>&1
if ufw status >/dev/null 2>&1; then
    ufw --force reload >/dev/null 2>&1
    success "Правила UFW применены (22, 443, ${PANEL_PORT})"
else
    info "UFW не активен, порты будут открыты при включении"
fi

# ==========================================
# WEB ПАНЕЛЬ
# ==========================================
step "7/13" "Подготовка структуры панели..."
PANEL_DIR="/var/www/telemt-panel"
mkdir -p "$PANEL_DIR/templates" "$PANEL_DIR/static"

if [[ ! -f "$PANEL_DIR/panel_config.json" ]]; then
    cat > "$PANEL_DIR/panel_config.json" << EOF
{
    "username": "admin",
    "password_hash": "...",
    "is_default": true,
    "proxy_host": "${PROXY_DOMAIN}",
    "proxy_port": 443,
    "secret_key": "$(openssl rand -hex 24)"
}
EOF
else
    python3 -c "
import json
with open('$PANEL_DIR/panel_config.json', 'r') as f:
    config = json.load(f)
config['proxy_host'] = '${PROXY_DOMAIN}'
config['proxy_port'] = 443
with open('$PANEL_DIR/panel_config.json', 'w') as f:
    json.dump(config, f, indent=4)
" 2>/dev/null || true
fi

# Файл состояний пользователей
if [[ ! -f "$PANEL_DIR/users_state.json" ]]; then
    echo "{}" > "$PANEL_DIR/users_state.json"
fi

step "8/13" "Настройка Python окружения..."
if [[ ! -d "$PANEL_DIR/venv" ]]; then
    python3 -m venv "$PANEL_DIR/venv"
fi
"$PANEL_DIR/venv/bin/pip" install -q --upgrade pip >/dev/null 2>&1
"$PANEL_DIR/venv/bin/pip" install -q Flask gunicorn toml werkzeug qrcode[pil] >/dev/null 2>&1
success "Зависимости Python установлены"

step "9/13" "Создание backend приложения..."

cat > "$PANEL_DIR/app.py" << 'PYEOF'
import os, json, secrets, toml, subprocess, datetime, time
from io import BytesIO
from flask import Flask, render_template, request, redirect, url_for, session, flash, send_file
from werkzeug.security import generate_password_hash, check_password_hash
import qrcode

app = Flask(__name__)
CONFIG_PATH = 'panel_config.json'
TELEMT_TOML = '/etc/telemt/telemt.toml'
USERS_STATE_PATH = 'users_state.json'

def load_config():
    with open(CONFIG_PATH, 'r') as f:
        return json.load(f)

def save_config(data):
    with open(CONFIG_PATH, 'w') as f:
        json.dump(data, f, indent=4)

def load_users_state():
    if not os.path.exists(USERS_STATE_PATH):
        return {}
    with open(USERS_STATE_PATH, 'r') as f:
        return json.load(f)

def save_users_state(data):
    with open(USERS_STATE_PATH, 'w') as f:
        json.dump(data, f, indent=4)

def restart_telemt():
    try:
        subprocess.run(['systemctl', 'restart', 'telemt'], check=False, timeout=10)
    except Exception:
        pass

def get_telemt_users_toml():
    if not os.path.exists(TELEMT_TOML):
        return {}
    with open(TELEMT_TOML, 'r') as f:
        config = toml.load(f)
    return config.get('access', {}).get('users', {})

def update_telemt_users_toml(users_dict):
    with open(TELEMT_TOML, 'r') as f:
        config = toml.load(f)
    if 'access' not in config:
        config['access'] = {}
    config['access']['users'] = users_dict
    with open(TELEMT_TOML, 'w') as f:
        toml.dump(config, f)
    restart_telemt()

def server_uptime():
    try:
        with open('/proc/uptime', 'r') as f:
            uptime_seconds = float(f.readline().split()[0])
        days = int(uptime_seconds // 86400)
        hours = int((uptime_seconds % 86400) // 3600)
        minutes = int((uptime_seconds % 3600) // 60)
        return f"{days} дн. {hours} ч. {minutes} мин."
    except:
        return "неизвестно"

def server_status():
    try:
        subprocess.run(['systemctl', 'is-active', '--quiet', 'telemt'], check=True)
        return "Работает"
    except:
        return "Отключен"

def check_and_update_users_state():
    state = load_users_state()
    now = datetime.datetime.now()
    changed = False
    for username, data in list(state.items()):
        if 'expired_at' in data and data['expired_at']:
            expired = datetime.datetime.fromisoformat(data['expired_at'])
            if not data.get('paused', False) and now >= expired:
                # Срок истёк, ставим на паузу
                data['paused'] = True
                data['paused_remaining_seconds'] = 0
                data['expired_at'] = None
                changed = True
                # Удалить из toml
                users = get_telemt_users_toml()
                if username in users:
                    del users[username]
                    update_telemt_users_toml(users)
        if data.get('paused') and data.get('paused_remaining_seconds') == 0:
            # Проверить, прошло ли больше суток после автоматической паузы (по метке)
            # Добавим метку auto_paused_at, если нет - используем прошлое expired_at
            auto_pause_str = data.get('auto_paused_at')
            if auto_pause_str:
                auto_paused = datetime.datetime.fromisoformat(auto_pause_str)
            else:
                # Если нет, считаем от expired_at (текущая логика)
                if 'expired_at' in data and data['expired_at']:
                    auto_paused = datetime.datetime.fromisoformat(data['expired_at'])
                else:
                    auto_paused = now
            if (now - auto_paused) > datetime.timedelta(days=1):
                # Удалить пользователя
                del state[username]
                changed = True
                users = get_telemt_users_toml()
                if username in users:
                    del users[username]
                    update_telemt_users_toml(users)
    if changed:
        save_users_state(state)
    return state

config = load_config()
app.secret_key = config.get('secret_key', secrets.token_hex(16))

if "..." in config.get('password_hash', ''):
    config['password_hash'] = generate_password_hash('admin')
    save_config(config)

@app.before_request
def require_login():
    allowed = ['login', 'static']
    if request.endpoint in allowed or (request.endpoint is None):
        return
    if 'user' not in session:
        return redirect(url_for('login'))
    cfg = load_config()
    if cfg.get('is_default') and request.endpoint not in ['admin', 'login']:
        return redirect(url_for('admin'))

@app.route('/login', methods=['GET', 'POST'])
def login():
    if request.method == 'POST':
        cfg = load_config()
        if request.form['username'] == cfg['username'] and check_password_hash(cfg['password_hash'], request.form['password']):
            session['user'] = cfg['username']
            return redirect(url_for('dashboard'))
        flash('Неверный логин или пароль', 'danger')
    return render_template('login.html')

@app.route('/logout')
def logout():
    session.pop('user', None)
    return redirect(url_for('login'))

@app.route('/admin', methods=['GET', 'POST'])
def admin():
    if request.method == 'POST':
        new_username = request.form.get('new_username', '').strip()
        new_password = request.form.get('new_password', '')
        cfg = load_config()
        changed = False
        if new_username and new_username != cfg['username']:
            cfg['username'] = new_username
            changed = True
        if new_password:
            cfg['password_hash'] = generate_password_hash(new_password)
            cfg['is_default'] = False
            changed = True
        if changed:
            save_config(cfg)
            flash('Учётные данные обновлены!', 'success')
        else:
            flash('Нет изменений', 'info')
        return redirect(url_for('admin'))
    cfg = load_config()
    return render_template('admin.html', username=cfg['username'])

@app.route('/settings', methods=['GET', 'POST'])
def settings():
    if request.method == 'POST':
        new_fake = request.form.get('fake_tls', '').strip()
        if new_fake:
            # Обновить в toml
            with open(TELEMT_TOML, 'r') as f:
                tconfig = toml.load(f)
            tconfig['censorship']['tls_domain'] = new_fake
            with open(TELEMT_TOML, 'w') as f:
                toml.dump(tconfig, f)
            restart_telemt()
            flash(f'Fake TLS домен изменён на {new_fake}', 'success')
        return redirect(url_for('settings'))
    with open(TELEMT_TOML, 'r') as f:
        tconfig = toml.load(f)
    current_fake = tconfig.get('censorship', {}).get('tls_domain', 'max.ru')
    status = server_status()
    uptime = server_uptime()
    return render_template('settings.html', fake_domain=current_fake, server_status=status, uptime=uptime)

@app.route('/', methods=['GET', 'POST'])
def dashboard():
    cfg = load_config()
    state = check_and_update_users_state()  # актуализация и удаление просроченных

    # Получить пользователей из toml
    tom_users = get_telemt_users_toml()
    tls_domain = ""
    try:
        with open(TELEMT_TOML, 'r') as f:
            tconfig = toml.load(f)
        tls_domain = tconfig.get('censorship', {}).get('tls_domain', 'max.ru')
    except:
        tls_domain = "max.ru"
    hex_domain = tls_domain.encode('utf-8').hex()

    # Объединить с состоянием для отображения таймера
    users_info = {}
    for uname, secret in tom_users.items():
        user_state = state.get(uname, {})
        paused = user_state.get('paused', False)
        created_at = user_state.get('created_at', '')
        expired_at_str = user_state.get('expired_at')
        paused_rem = user_state.get('paused_remaining_seconds', 0)
        remaining_str = ""
        if not paused and expired_at_str:
            expired = datetime.datetime.fromisoformat(expired_at_str)
            now = datetime.datetime.now()
            diff = expired - now
            if diff.total_seconds() > 0:
                days = diff.days
                hours, rem = divmod(diff.seconds, 3600)
                minutes = rem // 60
                remaining_str = f"{days}д {hours}ч {minutes}м"
            else:
                remaining_str = "0д 0ч 0м"
        elif paused and paused_rem > 0:
            days = paused_rem // 86400
            hours = (paused_rem % 86400) // 3600
            minutes = (paused_rem % 3600) // 60
            remaining_str = f"{days}д {hours}ч {minutes}м (пауза)"
        elif paused and paused_rem == 0:
            remaining_str = "0д 0ч 0м (пауза)"
        else:
            remaining_str = "—"

        final_secret = f"ee{secret}{hex_domain}"
        link = f"tg://proxy?server={cfg['proxy_host']}&port={cfg.get('proxy_port', 443)}&secret={final_secret}"
        users_info[uname] = {
            'secret': secret,
            'link': link,
            'paused': paused,
            'remaining': remaining_str
        }

    if request.method == 'POST':
        nickname = request.form.get('nickname', '').strip().replace(' ', '_')
        device = request.form.get('device', 'Phone')
        if not nickname:
            flash('Укажите никнейм!', 'danger')
            return redirect(url_for('dashboard'))

        user_key = f"{nickname}_{device}"
        new_secret = secrets.token_hex(16)

        # Добавить в toml
        tom_users = get_telemt_users_toml()
        tom_users[user_key] = new_secret
        update_telemt_users_toml(tom_users)

        # Запись в state
        now = datetime.datetime.now()
        expired = now + datetime.timedelta(days=30)
        state = load_users_state()
        state[user_key] = {
            'secret': new_secret,
            'expired_at': expired.isoformat(),
            'paused': False,
            'paused_remaining_seconds': None,
            'created_at': now.isoformat(),
            'auto_paused_at': None
        }
        save_users_state(state)
        flash(f'Доступ для {user_key} создан!', 'success')
        return redirect(url_for('dashboard'))

    # Статистика активных подключений
    def get_active_ips():
        try:
            result = subprocess.run(['ss', '-tn', 'state', 'established'], capture_output=True, text=True, timeout=5)
            lines = result.stdout.splitlines()
            ips = set()
            for line in lines:
                if ':443' in line:
                    parts = line.split()
                    if len(parts) >= 5:
                        peer = parts[4]
                        ip = peer.rsplit(':', 1)[0].replace('::ffff:', '').strip('[]')
                        if ip and ip not in ('127.0.0.1', '0.0.0.0'):
                            ips.add(ip)
            return list(ips)
        except:
            return []
    active_ips = get_active_ips()
    total_users = len(users_info)

    status = server_status()
    uptime = server_uptime()
    return render_template('dashboard.html',
                           users=users_info,
                           host=cfg['proxy_host'],
                           stats=active_ips,
                           total_users=total_users,
                           server_status=status,
                           uptime=uptime)

@app.route('/pause/<username>')
def pause_user(username):
    state = load_users_state()
    if username not in state:
        flash('Пользователь не найден', 'danger')
        return redirect(url_for('dashboard'))
    user_state = state[username]
    if user_state.get('paused', False):
        flash('Уже на паузе', 'info')
        return redirect(url_for('dashboard'))
    # Вычислить оставшееся время
    remaining = 30*24*3600  # def
    if user_state.get('expired_at'):
        expired = datetime.datetime.fromisoformat(user_state['expired_at'])
        now = datetime.datetime.now()
        remaining = max(0, int((expired - now).total_seconds()))
    # Обновить состояние
    user_state['paused'] = True
    user_state['paused_remaining_seconds'] = remaining
    user_state['expired_at'] = None
    state[username] = user_state
    # Удалить из toml
    users = get_telemt_users_toml()
    if username in users:
        del users[username]
        update_telemt_users_toml(users)
    save_users_state(state)
    flash(f'{username} поставлен на паузу', 'success')
    return redirect(url_for('dashboard'))

@app.route('/resume/<username>')
def resume_user(username):
    state = load_users_state()
    if username not in state:
        flash('Пользователь не найден', 'danger')
        return redirect(url_for('dashboard'))
    user_state = state[username]
    if not user_state.get('paused', False):
        flash('Не на паузе', 'info')
        return redirect(url_for('dashboard'))
    remaining = user_state.get('paused_remaining_seconds', 30*24*3600)
    now = datetime.datetime.now()
    new_expired = now + datetime.timedelta(seconds=remaining)
    user_state['paused'] = False
    user_state['expired_at'] = new_expired.isoformat()
    user_state['paused_remaining_seconds'] = None
    # Добавить обратно в toml
    secret = user_state.get('secret')
    if not secret:
        flash('Ошибка: отсутствует секрет!', 'danger')
        return redirect(url_for('dashboard'))
    users = get_telemt_users_toml()
    users[username] = secret
    update_telemt_users_toml(users)
    save_users_state(state)
    flash(f'{username} возобновлён', 'success')
    return redirect(url_for('dashboard'))

@app.route('/delete/<username>')
def delete_user(username):
    state = load_users_state()
    if username in state:
        del state[username]
        save_users_state(state)
    users = get_telemt_users_toml()
    if username in users:
        del users[username]
        update_telemt_users_toml(users)
    flash(f'Пользователь {username} удалён', 'success')
    return redirect(url_for('dashboard'))

@app.route('/qr/<username>')
def qr_user(username):
    users = get_telemt_users_toml()
    if username not in users:
        return "Not found", 404
    secret = users[username]
    cfg = load_config()
    with open(TELEMT_TOML, 'r') as f:
        tconfig = toml.load(f)
    tls_domain = tconfig.get('censorship', {}).get('tls_domain', 'max.ru')
    hex_domain = tls_domain.encode('utf-8').hex()
    final_secret = f"ee{secret}{hex_domain}"
    link = f"tg://proxy?server={cfg['proxy_host']}&port={cfg.get('proxy_port', 443)}&secret={final_secret}"
    img = qrcode.make(link)
    buf = BytesIO()
    img.save(buf, 'PNG')
    buf.seek(0)
    return send_file(buf, mimetype='image/png')

if __name__ == '__main__':
    port = int(os.environ.get('PANEL_PORT', 4444))
    app.run(host='0.0.0.0', port=port)
PYEOF

success "Backend создан"

step "10/13" "Создание HTML шаблонов..."

# Шаблон layout.html с футером
cat > "$PANEL_DIR/templates/layout.html" << 'HTMLEOF'
<!DOCTYPE html>
<html lang="ru">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>MTProto Proxy Panel</title>
    <link href="https://cdn.jsdelivr.net/npm/bootstrap@5.3.0/dist/css/bootstrap.min.css" rel="stylesheet">
    <link href="https://cdnjs.cloudflare.com/ajax/libs/font-awesome/6.4.0/css/all.min.css" rel="stylesheet">
    <style>
        body {
            background: #f4f6f9;
            font-family: 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif;
        }
        .navbar { background: #fff; box-shadow: 0 2px 10px rgba(0,0,0,0.05); }
        .card { border: none; border-radius: 12px; box-shadow: 0 4px 20px rgba(0,0,0,0.05); }
        .btn { border-radius: 8px; }
        .footer { text-align: center; padding: 1rem; font-size: 0.85rem; color: #6c757d; }
        @media (max-width: 768px) {
            .container { padding: 10px; }
        }
    </style>
</head>
<body>
    <nav class="navbar navbar-expand-lg navbar-light mb-4">
        <div class="container">
            <a class="navbar-brand fw-bold" href="/"><i class="fas fa-shield-alt"></i> Proxy Panel</a>
            <div class="navbar-nav ms-auto">
                {% if session.user %}
                <a class="nav-link" href="/"><i class="fas fa-tachometer-alt"></i> Главная</a>
                <a class="nav-link" href="/settings"><i class="fas fa-cog"></i> Настройки</a>
                <a class="nav-link" href="/admin"><i class="fas fa-user-shield"></i> Аккаунт</a>
                <a class="nav-link" href="/logout"><i class="fas fa-sign-out-alt"></i> Выход</a>
                {% endif %}
            </div>
        </div>
    </nav>
    <div class="container">
        {% with messages = get_flashed_messages(with_categories=true) %}
            {% if messages %}
                {% for category, message in messages %}
                    <div class="alert alert-{{ category }} alert-dismissible fade show" role="alert">
                        {{ message }}
                        <button type="button" class="btn-close" data-bs-dismiss="alert"></button>
                    </div>
                {% endfor %}
            {% endif %}
        {% endwith %}
        {% block content %}{% endblock %}
    </div>
    <footer class="footer">MTProto Proxy Panel 2026 by Mr_EFES</footer>
    <script src="https://cdn.jsdelivr.net/npm/bootstrap@5.3.0/dist/js/bootstrap.bundle.min.js"></script>
    {% block scripts %}{% endblock %}
</body>
</html>
HTMLEOF

cat > "$PANEL_DIR/templates/login.html" << 'HTMLEOF'
{% extends "layout.html" %}
{% block content %}
<div class="row justify-content-center">
    <div class="col-md-5">
        <div class="card p-4">
            <h3 class="mb-3"><i class="fas fa-lock"></i> Вход</h3>
            <form method="POST">
                <div class="mb-3">
                    <label>Логин</label>
                    <input type="text" name="username" class="form-control" required>
                </div>
                <div class="mb-3">
                    <label>Пароль</label>
                    <input type="password" name="password" class="form-control" required>
                </div>
                <button type="submit" class="btn btn-primary w-100">Войти</button>
            </form>
        </div>
    </div>
</div>
{% endblock %}

HTMLEOF

cat > "$PANEL_DIR/templates/admin.html" << 'HTMLEOF'
{% extends "layout.html" %}
{% block content %}
<div class="row justify-content-center">
    <div class="col-md-6">
        <div class="card p-4">
            <h4><i class="fas fa-user-cog"></i> Настройки аккаунта</h4>
            <form method="POST">
                <div class="mb-3">
                    <label>Логин</label>
                    <input type="text" name="new_username" class="form-control" value="{{ username }}">
                </div>
                <div class="mb-3">
                    <label>Новый пароль</label>
                    <input type="password" name="new_password" class="form-control" placeholder="Оставьте пустым, чтобы не менять">
                </div>
                <button type="submit" class="btn btn-warning">Сохранить</button>
            </form>
        </div>
    </div>
</div>
{% endblock %}
HTMLEOF

cat > "$PANEL_DIR/templates/settings.html" << 'HTMLEOF'
{% extends "layout.html" %}
{% block content %}
<div class="row">
    <div class="col-lg-6">
        <div class="card mb-3 p-3">
            <h5><i class="fas fa-server"></i> Статус сервера</h5>
            <p>Прокси: <span class="badge {% if server_status == 'Работает' %}bg-success{% else %}bg-danger{% endif %}">{{ server_status }}</span></p>
            <p>Uptime: {{ uptime }}</p>
        </div>
        <div class="card p-3">
            <h5><i class="fas fa-mask"></i> Fake TLS маскировка</h5>
            <form method="POST">
                <div class="mb-2">
                    <label>Текущий SNI</label>
                    <input type="text" name="fake_tls" class="form-control" value="{{ fake_domain }}">
                </div>
                <div class="mb-2">
                    <small>Быстрый выбор:</small>
                    <div class="d-flex flex-wrap gap-1">
                        <button type="button" class="btn btn-sm btn-outline-secondary preset-btn" data-domain="ads.x5.ru">ads.x5.ru</button>
                        <button type="button" class="btn btn-sm btn-outline-secondary preset-btn" data-domain="1c.ru">1c.ru</button>
                        <button type="button" class="btn btn-sm btn-outline-secondary preset-btn" data-domain="ozon.ru">ozon.ru</button>
                        <button type="button" class="btn btn-sm btn-outline-secondary preset-btn" data-domain="vk.com">vk.com</button>
                        <button type="button" class="btn btn-sm btn-outline-secondary preset-btn" data-domain="max.ru">max.ru</button>
                    </div>
                </div>
                <button type="submit" class="btn btn-primary">Применить</button>
            </form>
        </div>
    </div>
</div>
{% endblock %}
{% block scripts %}
<script>
    document.querySelectorAll('.preset-btn').forEach(btn => {
        btn.addEventListener('click', () => {
            document.querySelector('input[name="fake_tls"]').value = btn.dataset.domain;
        });
    });
</script>
{% endblock %}
HTMLEOF

# Шаблон dashboard — ключевой с двухколоночным макетом
cat > "$PANEL_DIR/templates/dashboard.html" << 'HTMLEOF'
{% extends "layout.html" %}
{% block content %}
<div class="row">
    <div class="col-lg-7">
        <!-- Статус сервера -->
        <div class="card mb-3 p-3 d-flex flex-row align-items-center">
            <div class="me-3">
                <span class="badge fs-6 {% if server_status == 'Работает' %}bg-success{% else %}bg-danger{% endif %}">{{ server_status }}</span>
            </div>
            <div>
                <strong>Uptime:</strong> {{ uptime }}
            </div>
        </div>

        <!-- Создание доступа -->
        <div class="card mb-3 p-3">
            <h5><i class="fas fa-plus-circle text-success"></i> Создать доступ</h5>
            <form method="POST" class="row g-2">
                <div class="col-md-5">
                    <input type="text" name="nickname" class="form-control" placeholder="Никнейм" required>
                </div>
                <div class="col-md-4">
                    <select name="device" class="form-select">
                        <option value="Phone">📱 Телефон</option>
                        <option value="PC">💻 Компьютер</option>
                        <option value="Tablet">📟 Планшет</option>
                    </select>
                </div>
                <div class="col-md-3">
                    <button type="submit" class="btn btn-success w-100">Создать</button>
                </div>
            </form>
        </div>

        <!-- Статистика -->
        <div class="card mb-3 p-3">
            <h5><i class="fas fa-chart-bar"></i> Статистика</h5>
            <p>Всего доступов: <strong>{{ total_users }}</strong></p>
            <p>Активных IP (443): <strong>{{ stats|length }}</strong></p>
            <div class="d-flex flex-wrap gap-1">
                {% for ip in stats %}
                    <span class="badge bg-secondary">{{ ip }}</span>
                {% endfor %}
            </div>
        </div>
    </div>

    <!-- Список доступов (правая колонка) -->
    <div class="col-lg-5">
        <div class="card p-3">
            <h5><i class="fas fa-users"></i> Список доступов</h5>
            {% if users %}
                <div class="table-responsive">
                    <table class="table table-hover align-middle">
                        <thead>
                            <tr><th>Пользователь</th><th>Таймер</th><th>Действия</th></tr>
                        </thead>
                        <tbody>
                        {% for uname, data in users.items() %}
                            <tr>
                                <td>
                                    <strong>{{ uname }}</strong>
                                    <br><small class="text-muted">{{ data.remaining }}</small>
                                </td>
                                <td>
                                    {% if data.paused %}
                                        <span class="text-danger">Пауза</span>
                                    {% else %}
                                        <span class="text-success">Активен</span>
                                        <br><small>{{ data.remaining }}</small>
                                    {% endif %}
                                </td>
                                <td>
                                    <div class="btn-group btn-group-sm">
                                        <button class="btn btn-outline-secondary" onclick="copyLink('{{ data.link }}')"><i class="fas fa-copy"></i></button>
                                        <button class="btn btn-outline-info" onclick="showQR('{{ uname }}')"><i class="fas fa-qrcode"></i></button>
                                        {% if data.paused %}
                                            <a href="{{ url_for('resume_user', username=uname) }}" class="btn btn-outline-success" title="Возобновить"><i class="fas fa-play"></i></a>
                                        {% else %}
                                            <a href="{{ url_for('pause_user', username=uname) }}" class="btn btn-outline-warning" title="Пауза"><i class="fas fa-pause"></i></a>
                                        {% endif %}
                                        <a href="{{ url_for('delete_user', username=uname) }}" class="btn btn-outline-danger" onclick="return confirm('Удалить {{ uname }}?')"><i class="fas fa-trash"></i></a>
                                    </div>
                                </td>
                            </tr>
                        {% endfor %}
                        </tbody>
                    </table>
                </div>
            {% else %}
                <p class="text-muted">Нет созданных доступов.</p>
            {% endif %}
        </div>
    </div>
</div>

<!-- Модальное окно QR -->
<div class="modal fade" id="qrModal" tabindex="-1">
  <div class="modal-dialog modal-sm modal-dialog-centered">
    <div class="modal-content">
      <div class="modal-header">
        <h5 class="modal-title">QR-код</h5>
        <button type="button" class="btn-close" data-bs-dismiss="modal"></button>
      </div>
      <div class="modal-body text-center">
        <img id="qrImage" src="" class="img-fluid">
      </div>
    </div>
  </div>
</div>
{% endblock %}
{% block scripts %}
<script>
function copyLink(link) {
    navigator.clipboard.writeText(link);
    alert('Ссылка скопирована!');
}
function showQR(username) {
    document.getElementById('qrImage').src = '/qr/' + username;
    new bootstrap.Modal(document.getElementById('qrModal')).show();
}
</script>
{% endblock %}
HTMLEOF

success "HTML шаблоны созданы"

step "11/13" "Создание службы панели..."

cat > /etc/systemd/system/telemt-panel.service << EOF
[Unit]
Description=MTProto Proxy Web Panel
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

if systemctl is-active --quiet telemt-panel; then
    success "Панель управления запущена"
else
    error "Панель НЕ запустилась. Логи:"
    journalctl -u telemt-panel --no-pager -n 10
fi

# ==========================================
# АВТООБНОВЛЕНИЕ
# ==========================================
step "12/13" "Настройка автообновлений..."

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

(crontab -l 2>/dev/null | grep -v "telemt-updater" | grep -v "certbot renew") | crontab - 2>/dev/null || true
(crontab -l 2>/dev/null 2>/dev/null; echo "0 4 * * * /usr/local/bin/telemt-updater.sh") | crontab - 2>/dev/null || true
(crontab -l 2>/dev/null 2>/dev/null; echo "0 3 * * * certbot renew --post-hook 'systemctl restart telemt telemt-panel' >/dev/null 2>&1") | crontab - 2>/dev/null || true
success "Автообновление настроено (Telemt: 04:00, сертификаты: 03:00)"

# ==========================================
# ФИНАЛЬНЫЙ ОТЧЕТ
# ==========================================
step "13/13" "Установка завершена!"
echo -e "${CYAN}${BOLD}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "           🎉 УСТАНОВКА ЗАВЕРШЕНА УСПЕШНО! 🎉"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo -e "${RESET}"
echo -e "${BOLD}📡 ПРОКСИ:${RESET}"
echo -e "   Домен: ${GREEN}${PROXY_DOMAIN}${RESET}"
echo -e "   Порт: ${GREEN}443${RESET}"
echo -e "   Fake TLS: ${YELLOW}${FAKE_DOMAIN}${RESET}"
echo ""
echo -e "${BOLD}🖥️ ПАНЕЛЬ УПРАВЛЕНИЯ:${RESET}"
echo -e "   URL: ${GREEN}https://${PANEL_DOMAIN}:${PANEL_PORT}${RESET}"
echo -e "   Логин: ${YELLOW}admin${RESET}"
echo -e "   Пароль: ${YELLOW}admin${RESET}"
echo -e "   ${RED}⚠️ Смените пароль при первом входе!${RESET}"
echo ""
echo -e "${BOLD}🔗 ССЫЛКА ДЛЯ ПОДКЛЮЧЕНИЯ:${RESET}"
echo -e "${GREEN}${TG_LINK}${RESET}"
echo ""
echo -e "QR-код (консоль):"
qrencode -t ANSIUTF8 "$TG_LINK"
echo ""
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
