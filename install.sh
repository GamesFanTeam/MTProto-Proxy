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
    echo -e "${RESET}${MAGENTA}        MTProto Proxy Telegram Installer by Mr_EFES (Extended)"
    echo -e "${RESET}"
}

# Функция выпуска/проверки SSL сертификата с email
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
            if [[ -f "$cert_path" ]]; then echo "renewed"; else echo "error"; fi
        fi
    else
        if [[ -n "$email" ]]; then
            certbot certonly --standalone -d "${domain}" --email "${email}" --agree-tos --non-interactive --quiet >/dev/null 2>&1
        else
            certbot certonly --standalone -d "${domain}" --register-unsafely-without-email --agree-tos --non-interactive --quiet >/dev/null 2>&1
        fi
        if [[ -f "$cert_path" ]]; then echo "new"; else echo "error"; fi
    fi
}

show_banner

if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}Ошибка: запустите скрипт от имени root.${RESET}"
    exit 1
fi

echo -e "${YELLOW}Проверка необходимых пакетов...${RESET}"
apt-get update -qq >/dev/null 2>&1
apt-get install -y -qq curl wget jq openssl certbot xxd socat ufw python3 python3-pip python3-venv iproute2 net-tools procps >/dev/null 2>&1

systemctl stop nginx apache2 2>/dev/null || true

# ==========================================
# ЧАСТЬ 1: СБОР ВВОДНЫХ ДАННЫХ
# ==========================================
echo -e "${BOLD}--- НАСТРОЙКА ПРОКСИ И ПАНЕЛИ ---${RESET}"
echo ""

read -rp "Введите домен для ПРОКСИ (напр. tg.example.com): " PROXY_DOMAIN
if [[ -z "${PROXY_DOMAIN}" ]]; then echo -e "${RED}Домен для прокси обязателен!${RESET}"; exit 1; fi

read -rp "Введите домен для ПАНЕЛИ УПРАВЛЕНИЯ (напр. admin.example.com): " PANEL_DOMAIN
if [[ -z "${PANEL_DOMAIN}" ]]; then echo -e "${RED}Домен для панели обязателен!${RESET}"; exit 1; fi

read -rp "Введите порт для панели управления [по умолчанию 4444]: " PANEL_PORT_INPUT
PANEL_PORT=${PANEL_PORT_INPUT:-4444}

read -rp "Введите Email для SSL-сертификатов Let's Encrypt (необязательно): " CERT_EMAIL

echo ""
echo -e "${CYAN}Параметры установки:${RESET}"
echo -e "  ${BLUE}Прокси домен:${RESET} ${PROXY_DOMAIN} (порт 443)"
echo -e "  ${BLUE}Панель домен:${RESET} ${PANEL_DOMAIN} (порт ${PANEL_PORT})"
echo ""

# ==========================================
# ЧАСТЬ 2: ВЫПУСК SSL СЕРТИФИКАТОВ
# ==========================================
echo -e "${BOLD}--- ВЫПУСК SSL СЕРТИФИКАТОВ ---${RESET}"

echo -ne "${YELLOW}Проверка/выпуск сертификата для ${PROXY_DOMAIN}... ${RESET}"
ssl_proxy_status=$(issue_ssl "$PROXY_DOMAIN" "$CERT_EMAIL")
case "$ssl_proxy_status" in
    "exist") echo -e "${GREEN}Найден существующий (действителен)${RESET}" ;;
    "new") echo -e "${GREEN}Успешно выпущен новый${RESET}" ;;
    "renewed") echo -e "${GREEN}Успешно обновлен${RESET}" ;;
    "error") echo -e "${RED}ОШИБКА выпуска SSL! Проверьте A-запись домена.${RESET}"; exit 1 ;;
esac

echo -ne "${YELLOW}Проверка/выпуск сертификата для ${PANEL_DOMAIN}... ${RESET}"
ssl_panel_status=$(issue_ssl "$PANEL_DOMAIN" "$CERT_EMAIL")
case "$ssl_panel_status" in
    "exist") echo -e "${GREEN}Найден существующий (действителен)${RESET}" ;;
    "new") echo -e "${GREEN}Успешно выпущен новый${RESET}" ;;
    "renewed") echo -e "${GREEN}Успешно обновлен${RESET}" ;;
    "error") echo -e "${RED}ОШИБКА выпуска SSL! Проверьте A-запись домена.${RESET}"; exit 1 ;;
esac
echo ""

# ==========================================
# ЧАСТЬ 3: УСТАНОВКА ПРОКСИ
# ==========================================
echo -e "${BOLD}--- УСТАНОВКА MTProto ПРОКСИ ---${RESET}"

echo -e "${BOLD}Выберите домен для Fake TLS маскировки:${RESET}"
echo "1) max.ru (по умолчанию)"
echo "2) vk.com"
echo "3) ozon.ru"
echo "4) Свой вариант"
read -rp "Ваш выбор [1-4, Enter = 1]: " FAKE_CHOICE
case "${FAKE_CHOICE:-1}" in
    2) FAKE_DOMAIN="vk.com" ;;
    3) FAKE_DOMAIN="ozon.ru" ;;
    4)
        read -rp "Введите свой домен для маскировки: " FAKE_DOMAIN
        if [[ -z "$FAKE_DOMAIN" ]]; then FAKE_DOMAIN="max.ru"; fi
        ;;
    *) FAKE_DOMAIN="max.ru" ;;
esac

echo -e "${YELLOW}Установка ядра Telemt...${RESET}"
ARCH=$(uname -m)
case "$ARCH" in
    "x86_64") BIN_ARCH="x86_64" ;;
    "aarch64"|"arm64") BIN_ARCH="aarch64" ;;
    *) echo -e "${RED}Неподдерживаемая архитектура: $ARCH${RESET}"; exit 1 ;;
esac

DL_URL="https://github.com/telemt/telemt/releases/latest/download/telemt-${BIN_ARCH}-linux-gnu.tar.gz"
if ! wget -q "$DL_URL" -O /tmp/telemt.tar.gz; then echo -e "${RED}Не удалось скачать Telemt!${RESET}"; exit 1; fi

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
RestartSec=3
LimitNOFILE=65536
AmbientCapabilities=CAP_NET_BIND_SERVICE

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable telemt --now >/dev/null 2>&1
sleep 2

HEX_DOMAIN=$(printf '%s' "${FAKE_DOMAIN}" | xxd -p | tr -d '\n')
FINAL_SECRET="ee${USER_SECRET}${HEX_DOMAIN}"
TG_LINK="tg://proxy?server=${PROXY_DOMAIN}&port=443&secret=${FINAL_SECRET}"

echo -e "${CYAN}${BOLD}Ссылка для подключения к прокси:${RESET}"
echo -e "${GREEN}${TG_LINK}${RESET}"
echo ""

# ==========================================
# ЧАСТЬ 4: НАСТРОЙКА FIREWALL
# ==========================================
echo -e "${BOLD}--- НАСТРОЙКА FIREWALL (UFW) ---${RESET}"
ufw allow 22/tcp >/dev/null 2>&1 || true
ufw allow 443/tcp >/dev/null 2>&1
ufw allow ${PANEL_PORT}/tcp >/dev/null 2>&1

if ufw status >/dev/null 2>&1; then
    ufw --force reload >/dev/null 2>&1
    echo -e "${GREEN}Правила firewall применены${RESET}"
fi
echo ""

# ==========================================
# ЧАСТЬ 5: УСТАНОВКА WEB UI ПАНЕЛИ
# ==========================================
echo -e "${BOLD}--- УСТАНОВКА WEB UI ПАНЕЛИ ---${RESET}"

PANEL_DIR="/var/www/telemt-panel"
mkdir -p "$PANEL_DIR/templates"

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
with open('$PANEL_DIR/panel_config.json', 'r') as f: config = json.load(f)
config['proxy_host'] = '${PROXY_DOMAIN}'; config['proxy_port'] = 443
with open('$PANEL_DIR/panel_config.json', 'w') as f: json.dump(config, f, indent=4)
" 2>/dev/null || true
fi

echo -e "${YELLOW}Настройка Python окружения...${RESET}"
if [[ ! -d "$PANEL_DIR/venv" ]]; then
    python3 -m venv "$PANEL_DIR/venv"
fi

"$PANEL_DIR/venv/bin/pip" install -q --upgrade pip >/dev/null 2>&1
"$PANEL_DIR/venv/bin/pip" install -q Flask gunicorn toml werkzeug >/dev/null 2>&1

cat > "$PANEL_DIR/app.py" << 'PYEOF'
import os, json, secrets, toml, subprocess
from datetime import datetime
from flask import Flask, render_template, request, redirect, url_for, session, flash
from werkzeug.security import generate_password_hash, check_password_hash

app = Flask(__name__)
CONFIG_PATH = 'panel_config.json'
USERS_META_PATH = 'users_meta.json'
TELEMT_TOML = '/etc/telemt/telemt.toml'

def load_json(path, default=None):
    if os.path.exists(path):
        with open(path, 'r') as f: return json.load(f)
    return default if default is not None else {}

def save_json(path, data):
    with open(path, 'w') as f: json.dump(data, f, indent=4)

config = load_json(CONFIG_PATH)
app.secret_key = config.get('secret_key', secrets.token_hex(16))

if "..." in config.get('password_hash', ''):
    config['password_hash'] = generate_password_hash('admin')
    save_json(CONFIG_PATH, config)

def restart_telemt():
    try: subprocess.run(['systemctl', 'restart', 'telemt'], check=False, timeout=10)
    except: pass

def get_proxy_stats():
    try:
        result = subprocess.run(['ss', '-tn', 'state', 'established'], capture_output=True, text=True, timeout=5)
        ips = set()
        for line in result.stdout.splitlines():
            if ':443' in line:
                parts = line.split()
                if len(parts) >= 5:
                    ip = parts[4].rsplit(':', 1)[0].replace('::ffff:', '').strip('[]')
                    if ip and ip not in ['127.0.0.1', '0.0.0.0']: ips.add(ip)
        return list(ips)
    except: return []

def get_service_status():
    try:
        status = subprocess.run(['systemctl', 'is-active', 'telemt'], capture_output=True, text=True).stdout.strip()
        if status == 'active':
            pid = subprocess.run(['systemctl', 'show', '-p', 'MainPID', 'telemt'], capture_output=True, text=True).stdout.strip().split('=')[1]
            uptime = subprocess.run(['ps', '-o', 'etime=', '-p', pid], capture_output=True, text=True).stdout.strip()
            return "Работает", uptime, "success"
        return "Упал", "-", "danger"
    except:
        return "Ошибка", "-", "danger"

@app.before_request
def require_login():
    if request.endpoint not in ['login'] and 'user' not in session and not request.path.startswith('/static'):
        return redirect(url_for('login'))
    config = load_json(CONFIG_PATH)
    if config.get('is_default') and request.endpoint not in ['change_password', 'login', 'logout'] and 'user' in session:
        return redirect(url_for('change_password'))

@app.route('/login', methods=['GET', 'POST'])
def login():
    if request.method == 'POST':
        cfg = load_json(CONFIG_PATH)
        if request.form['username'] == cfg['username'] and check_password_hash(cfg['password_hash'], request.form['password']):
            session['user'] = cfg['username']
            return redirect(url_for('dashboard'))
        flash('Неверный логин или пароль', 'danger')
    return render_template('login.html')

@app.route('/logout')
def logout():
    session.pop('user', None)
    return redirect(url_for('login'))

@app.route('/change_password', methods=['GET', 'POST'])
def change_password():
    if request.method == 'POST':
        cfg = load_json(CONFIG_PATH)
        cfg['password_hash'] = generate_password_hash(request.form['new_password'])
        cfg['is_default'] = False
        save_json(CONFIG_PATH, cfg)
        flash('Пароль успешно изменен!', 'success')
        return redirect(url_for('dashboard'))
    return render_template('change_password.html')

@app.route('/', methods=['GET', 'POST'])
def dashboard():
    cfg = load_json(CONFIG_PATH)
    meta = load_json(USERS_META_PATH)
    try:
        with open(TELEMT_TOML, 'r') as f: t_config = toml.load(f)
    except: t_config = {'access': {'users': {}}, 'censorship': {'tls_domain': 'max.ru'}}

    toml_users = t_config.get('access', {}).get('users', {})
    tls_domain = t_config.get('censorship', {}).get('tls_domain', 'max.ru')
    hex_domain = tls_domain.encode('utf-8').hex()

    # Sync and build user list
    proxy_links = {}
    now = datetime.now()
    
    # Check users in meta
    for name, m_data in list(meta.items()):
        secret = m_data.get('secret')
        status = m_data.get('status', 'active')
        created_at = datetime.fromisoformat(m_data.get('created_at', now.isoformat()))
        days_left = max(0, 30 - (now - created_at).days)

        final_secret = f"ee{secret}{hex_domain}"
        link = f"tg://proxy?server={cfg['proxy_host']}&port={cfg.get('proxy_port', 443)}&secret={final_secret}"
        
        proxy_links[name] = {
            'secret': secret, 'link': link, 'status': status, 
            'days_left': days_left, 'traffic': 'Н/Д'
        }

    # Add TOML users missing in meta (e.g. admin_default)
    for name, secret in toml_users.items():
        if name not in meta:
            meta[name] = {'secret': secret, 'created_at': now.isoformat(), 'status': 'active'}
            save_json(USERS_META_PATH, meta)
            final_secret = f"ee{secret}{hex_domain}"
            link = f"tg://proxy?server={cfg['proxy_host']}&port={cfg.get('proxy_port', 443)}&secret={final_secret}"
            proxy_links[name] = {'secret': secret, 'link': link, 'status': 'active', 'days_left': 30, 'traffic': 'Н/Д'}

    if request.method == 'POST':
        nickname = request.form.get('nickname', '').strip().replace(' ', '_')
        device = request.form.get('device', 'Phone')
        if not nickname:
            flash('Укажите никнейм!', 'danger')
            return redirect(url_for('dashboard'))

        user_key = f"{nickname}_{device}"
        new_secret = secrets.token_hex(16)

        t_config.setdefault('access', {}).setdefault('users', {})[user_key] = new_secret
        with open(TELEMT_TOML, 'w') as f: toml.dump(t_config, f)

        meta[user_key] = {'secret': new_secret, 'created_at': datetime.now().isoformat(), 'status': 'active'}
        save_json(USERS_META_PATH, meta)

        restart_telemt()
        flash(f'Доступ для {user_key} создан!', 'success')
        return redirect(url_for('dashboard'))

    stats = get_proxy_stats()
    srv_status, srv_uptime, srv_color = get_service_status()
    
    return render_template('dashboard.html', links=proxy_links, host=cfg['proxy_host'], 
                           stats=stats, current_tls=tls_domain, 
                           srv_status=srv_status, srv_uptime=srv_uptime, srv_color=srv_color)

@app.route('/update_faketls', methods=['POST'])
def update_faketls():
    new_domain = request.form.get('faketls_domain', '').strip()
    if new_domain:
        with open(TELEMT_TOML, 'r') as f: t_config = toml.load(f)
        t_config.setdefault('censorship', {})['tls_domain'] = new_domain
        with open(TELEMT_TOML, 'w') as f: toml.dump(t_config, f)
        restart_telemt()
        flash(f'Домен FakeTLS изменен на {new_domain} (Сервер перезапущен)', 'success')
    return redirect(url_for('dashboard'))

@app.route('/restart_proxy')
def restart_proxy():
    restart_telemt()
    flash('Прокси-сервер успешно перезапущен', 'success')
    return redirect(url_for('dashboard'))

@app.route('/toggle/<username>')
def toggle_user(username):
    meta = load_json(USERS_META_PATH)
    if username in meta:
        with open(TELEMT_TOML, 'r') as f: t_config = toml.load(f)
        users_node = t_config.setdefault('access', {}).setdefault('users', {})
        
        if meta[username].get('status') == 'disabled':
            users_node[username] = meta[username]['secret']
            meta[username]['status'] = 'active'
            flash(f'Доступ для {username} включен', 'success')
        else:
            if username in users_node: del users_node[username]
            meta[username]['status'] = 'disabled'
            flash(f'Доступ для {username} приостановлен', 'warning')
            
        with open(TELEMT_TOML, 'w') as f: toml.dump(t_config, f)
        save_json(USERS_META_PATH, meta)
        restart_telemt()
    return redirect(url_for('dashboard'))

@app.route('/delete/<username>')
def delete_user(username):
    meta = load_json(USERS_META_PATH)
    if username in meta: del meta[username]
    save_json(USERS_META_PATH, meta)

    try:
        with open(TELEMT_TOML, 'r') as f: t_config = toml.load(f)
        if username in t_config.get('access', {}).get('users', {}):
            del t_config['access']['users'][username]
            with open(TELEMT_TOML, 'w') as f: toml.dump(t_config, f)
            restart_telemt()
        flash(f'Пользователь {username} удален', 'success')
    except Exception as e:
        flash(f'Ошибка: {str(e)}', 'danger')
    return redirect(url_for('dashboard'))

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=int(os.environ.get('PANEL_PORT', 4444)))
PYEOF

echo -e "${GREEN}Backend панели обновлен${RESET}"

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
        body { background: linear-gradient(135deg, #1f1c2c 0%, #928dab 100%); min-height: 100vh; font-family: 'Segoe UI', sans-serif; }
        .container { max-width: 1100px; margin-top: 2rem; margin-bottom: 2rem; }
        .card { border: none; border-radius: 12px; box-shadow: 0 8px 30px rgba(0,0,0,0.15); margin-bottom: 1.5rem; }
        .card-header { border-radius: 12px 12px 0 0 !important; font-weight: 600; }
        .table { margin-bottom: 0; }
        .badge { font-weight: 500; }
        .btn-action { width: 34px; height: 34px; padding: 0; line-height: 34px; text-align: center; border-radius: 8px; }
    </style>
</head>
<body>
    <div class="container">
        {% with messages = get_flashed_messages(with_categories=true) %}
            {% if messages %}
                {% for category, message in messages %}
                    <div class="alert alert-{{ category }} alert-dismissible fade show shadow-sm">
                        <i class="fas fa-info-circle me-2"></i>{{ message }}
                        <button type="button" class="btn-close" data-bs-dismiss="alert"></button>
                    </div>
                {% endfor %}
            {% endif %}
        {% endwith %}
        {% block content %}{% endblock %}
    </div>
    <script src="https://cdn.jsdelivr.net/npm/bootstrap@5.3.0/dist/js/bootstrap.bundle.min.js"></script>
    <script src="https://cdnjs.cloudflare.com/ajax/libs/qrcodejs/1.0.0/qrcode.min.js"></script>
</body>
</html>
HTMLEOF

cat > "$PANEL_DIR/templates/login.html" << 'HTMLEOF'
{% extends "layout.html" %}
{% block content %}
<div class="row justify-content-center align-items-center" style="min-height: 80vh;">
    <div class="col-md-5">
        <div class="card p-4">
            <h3 class="text-center mb-4"><i class="fas fa-shield-alt text-primary"></i> MTProto Panel</h3>
            <form method="POST">
                <input type="text" name="username" class="form-control mb-3" placeholder="Логин" required autofocus>
                <input type="password" name="password" class="form-control mb-4" placeholder="Пароль" required>
                <button type="submit" class="btn btn-primary w-100">Войти</button>
            </form>
        </div>
    </div>
</div>
{% endblock %}
HTMLEOF

cat > "$PANEL_DIR/templates/change_password.html" << 'HTMLEOF'
{% extends "layout.html" %}
{% block content %}
<div class="row justify-content-center">
    <div class="col-md-5">
        <div class="card p-4 border-warning">
            <h4 class="text-center text-warning mb-4"><i class="fas fa-key"></i> Смена пароля</h4>
            <form method="POST">
                <input type="password" name="new_password" class="form-control mb-3" placeholder="Новый пароль" required minlength="6">
                <button type="submit" class="btn btn-warning w-100">Сохранить</button>
            </form>
        </div>
    </div>
</div>
{% endblock %}
HTMLEOF

cat > "$PANEL_DIR/templates/dashboard.html" << 'HTMLEOF'
{% extends "layout.html" %}
{% block content %}
<div class="d-flex justify-content-between align-items-center mb-3">
    <h3 class="text-white"><i class="fas fa-server me-2"></i>Панель управления</h3>
    <a href="{{ url_for('logout') }}" class="btn btn-sm btn-outline-light"><i class="fas fa-sign-out-alt"></i> Выход</a>
</div>

<div class="row">
    <!-- Левая колонка (Создание и настройки) -->
    <div class="col-lg-4">
        <div class="card">
            <div class="card-header bg-success text-white"><i class="fas fa-user-plus me-1"></i> Создать доступ</div>
            <div class="card-body">
                <form method="POST">
                    <div class="mb-2"><input type="text" name="nickname" class="form-control" placeholder="Никнейм" required></div>
                    <div class="mb-3">
                        <select name="device" class="form-select">
                            <option value="Phone">📱 Телефон</option><option value="PC">💻 ПК</option><option value="Tablet">📟 Планшет</option>
                        </select>
                    </div>
                    <button type="submit" class="btn btn-success w-100"><i class="fas fa-plus"></i> Сгенерировать</button>
                </form>
            </div>
        </div>

        <div class="card">
            <div class="card-header bg-warning text-dark"><i class="fas fa-cogs me-1"></i> Настройки прокси</div>
            <div class="card-body">
                <form action="{{ url_for('update_faketls') }}" method="POST" class="mb-3">
                    <label class="form-label small text-muted">Сайт для FakeTLS маскировки</label>
                    <div class="input-group">
                        <input type="text" name="faketls_domain" class="form-control" value="{{ current_tls }}" required>
                        <button type="submit" class="btn btn-outline-dark"><i class="fas fa-save"></i></button>
                    </div>
                </form>
                <hr>
                <a href="{{ url_for('restart_proxy') }}" class="btn btn-danger w-100" onclick="return confirm('Сервер будет перезапущен. Продолжить?')">
                    <i class="fas fa-sync-alt"></i> Перезапустить прокси
                </a>
            </div>
        </div>
        
        <div class="card">
            <div class="card-header bg-info text-white"><i class="fas fa-heartbeat me-1"></i> Активные подключения</div>
            <div class="card-body">
                <div class="d-flex justify-content-between mb-2 border-bottom pb-2">
                    <span class="text-muted">Статус сервера:</span>
                    <span class="badge bg-{{ srv_color }}">{{ srv_status }}</span>
                </div>
                <div class="d-flex justify-content-between mb-3 border-bottom pb-2">
                    <span class="text-muted">Uptime:</span>
                    <span class="fw-bold">{{ srv_uptime }}</span>
                </div>
                <div class="mb-2"><span class="text-muted">Онлайн IP ({{ stats|length }}):</span></div>
                {% if stats %}
                    <div class="d-flex flex-wrap gap-1">
                        {% for ip in stats %}<span class="badge bg-secondary"><i class="fas fa-globe"></i> {{ ip }}</span>{% endfor %}
                    </div>
                {% else %}
                    <small class="text-muted">Подключений нет</small>
                {% endif %}
            </div>
        </div>
    </div>

    <!-- Правая колонка (Список) -->
    <div class="col-lg-8">
        <div class="card h-100">
            <div class="card-header bg-primary text-white"><i class="fas fa-list me-1"></i> Список доступов</div>
            <div class="card-body p-0">
                <div class="table-responsive">
                    <table class="table table-hover align-middle mb-0">
                        <thead class="table-light">
                            <tr>
                                <th class="ps-3">Пользователь</th>
                                <th>Трафик</th>
                                <th class="text-end pe-3">Действия</th>
                            </tr>
                        </thead>
                        <tbody>
                            {% for name, data in links.items() %}
                            <tr class="{% if data.status == 'disabled' %}table-secondary opacity-75{% endif %}">
                                <td class="ps-3">
                                    <div class="fw-bold">
                                        {{ name }}
                                        {% if data.status == 'disabled' %}<span class="badge bg-danger ms-1" style="font-size:0.6rem;">Выкл</span>{% endif %}
                                    </div>
                                    <span class="badge {% if data.days_left > 5 %}bg-success{% else %}bg-warning text-dark{% endif %}" style="font-size:0.7rem;">
                                        <i class="far fa-clock"></i> Осталось: {{ data.days_left }} дн.
                                    </span>
                                </td>
                                <td><span class="text-muted small">{{ data.traffic }}</span></td>
                                <td class="text-end pe-3 text-nowrap">
                                    <div class="btn-group shadow-sm">
                                        <button class="btn btn-light btn-action text-primary border" onclick="showQR('{{ data.link }}')" title="QR Код"><i class="fas fa-qrcode"></i></button>
                                        <button class="btn btn-light btn-action text-secondary border" onclick="navigator.clipboard.writeText('{{ data.link }}'); alert('Скопировано!');" title="Копировать ссылку"><i class="fas fa-copy"></i></button>
                                        <a href="{{ url_for('toggle_user', username=name) }}" class="btn btn-light btn-action border {% if data.status == 'active' %}text-warning{% else %}text-success{% endif %}" title="Вкл/Выкл">
                                            <i class="fas {% if data.status == 'active' %}fa-pause{% else %}fa-play{% endif %}"></i>
                                        </a>
                                        <a href="{{ url_for('delete_user', username=name) }}" class="btn btn-light btn-action text-danger border" onclick="return confirm('Точно удалить?')" title="Удалить"><i class="fas fa-trash"></i></a>
                                    </div>
                                </td>
                            </tr>
                            {% else %}
                            <tr><td colspan="3" class="text-center py-4 text-muted">Нет созданных доступов</td></tr>
                            {% endfor %}
                        </tbody>
                    </table>
                </div>
            </div>
        </div>
    </div>
</div>

<!-- Modal QR -->
<div class="modal fade" id="qrModal" tabindex="-1">
  <div class="modal-dialog modal-sm modal-dialog-centered">
    <div class="modal-content border-0 shadow">
      <div class="modal-header border-0 pb-0">
        <button type="button" class="btn-close" data-bs-dismiss="modal"></button>
      </div>
      <div class="modal-body text-center pb-4">
        <h5 class="mb-3 text-dark">QR для подключения</h5>
        <div id="qrcode" class="d-flex justify-content-center p-3 bg-white rounded shadow-sm border"></div>
      </div>
    </div>
  </div>
</div>

<script>
function showQR(link) {
    document.getElementById('qrcode').innerHTML = '';
    new QRCode(document.getElementById('qrcode'), {text: link, width: 200, height: 200, colorDark : "#000000", colorLight : "#ffffff"});
    new bootstrap.Modal(document.getElementById('qrModal')).show();
}
</script>
{% endblock %}
HTMLEOF

echo -e "${YELLOW}Настройка службы панели...${RESET}"
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

# ==========================================
# ЧАСТЬ 6: АВТООБНОВЛЕНИЕ
# ==========================================
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

# ==========================================
# ФИНАЛЬНЫЙ ОТЧЕТ
# ==========================================
echo -e "${CYAN}${BOLD}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "           🎉 УСТАНОВКА ЗАВЕРШЕНА УСПЕШНО! 🎉"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo -e "${RESET}"
echo -e "${BOLD}🖥️ ПАНЕЛЬ УПРАВЛЕНИЯ:${RESET}"
echo -e "   URL: ${GREEN}https://${PANEL_DOMAIN}:${PANEL_PORT}${RESET}"
echo -e "   Логин: ${YELLOW}admin${RESET}"
echo -e "   Пароль: ${YELLOW}admin${RESET}"
echo -e "   ${RED}⚠️ Смените пароль при первом входе!${RESET}"
echo ""
