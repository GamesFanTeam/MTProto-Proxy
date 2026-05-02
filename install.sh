#!/bin/bash
set -euo pipefail

# ── Цветовая схема (Darknet/Telegram Vibe) ──────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
BOLD='\033[1m'
NEON_GREEN='\033[38;5;46m'
RESET='\033[0m'

# ── Функция Прогресс Бара ───────────────────────────────────────────────
draw_progress() {
    local -i _progress=$1
    local _text=$2
    local -i _max=100
    local -i _fill=$(( _progress * 40 / _max ))
    local -i _empty=$(( 40 - _fill ))
    local _bar=$(printf "%${_fill}s" "" | tr ' ' '█')
    local _space=$(printf "%${_empty}s" "")
    printf "\r${CYAN}[%s%s] %3d%% ${RESET}- %s\033[K" "$_bar" "$_space" "$_progress" "$_text"
    if [[ $_progress -eq 100 ]]; then echo ""; fi
}

# ── Баннер ──────────────────────────────────────────────────────────────
show_banner() {
    clear
    echo -e "${NEON_GREEN}${BOLD}"
    echo "  ███╗   ███╗████████╗██████╗ ██████╗  ██████╗ ████████╗ ██████╗ "
    echo "  ████╗ ████║╚══██╔══╝██╔══██╗██╔══██╗██╔═══██╗╚══██╔══╝██╔═══██╗"
    echo "  ██╔████╔██║   ██║   ██████╔╝██████╔╝██║   ██║   ██║   ██║   ██║"
    echo "  ██║╚██╔╝██║   ██║   ██╔═══╝ ██╔══██╗██║   ██║   ██║   ██║   ██║"
    echo "  ██║ ╚═╝ ██║   ██║   ██║     ██║  ██║╚██████╔╝   ██║   ╚██████╔╝"
    echo "  ╚═╝     ╚═╝   ╚═╝   ╚═╝     ╚═╝  ╚═╝ ╚═════╝    ╚═╝   ╚═════╝  "
    echo -e "${RESET}${CYAN}      MTProto Proxy & Panel 2026 PRODUCTION EDITION by Mr_EFES"
    echo -e "${RESET}"
}

if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}[!] Ошибка: скрипт должен быть запущен от имени root.${RESET}"
    exit 1
fi

show_banner

# ==========================================
# ЧАСТЬ 1: СБОР ВВОДНЫХ ДАННЫХ
# ==========================================
echo -e "${BOLD}=== СБОР ДАННЫХ ДЛЯ УСТАНОВКИ ===${RESET}\n"

read -rp "1. Введите домен для ПРОКСИ (напр. tg.example.com): " PROXY_DOMAIN
if [[ -z "${PROXY_DOMAIN}" ]]; then echo -e "${RED}Домен обязателен!${RESET}"; exit 1; fi

read -rp "2. Введите домен для ПАНЕЛИ УПРАВЛЕНИЯ (напр. admin.example.com): " PANEL_DOMAIN
if [[ -z "${PANEL_DOMAIN}" ]]; then echo -e "${RED}Домен обязателен!${RESET}"; exit 1; fi

read -rp "3. Введите порт для панели управления [по умолчанию 4444]: " PANEL_PORT_INPUT
PANEL_PORT=${PANEL_PORT_INPUT:-4444}

read -rp "4. Введите Email для SSL (Let's Encrypt) [Enter - пропустить]: " CERT_EMAIL

echo -e "\n${BOLD}Выберите домен для Fake TLS маскировки:${RESET}"
echo "1) ads.x5.ru"
echo "2) 1c.ru"
echo "3) ozon.ru"
echo "4) vk.com"
echo "5) max.ru"
echo "6) Свой вариант"
read -rp "Ваш выбор [1-6, Enter = 1]: " FAKE_CHOICE
case "${FAKE_CHOICE:-1}" in
    1) FAKE_DOMAIN="ads.x5.ru" ;;
    2) FAKE_DOMAIN="1c.ru" ;;
    3) FAKE_DOMAIN="ozon.ru" ;;
    4) FAKE_DOMAIN="vk.com" ;;
    5) FAKE_DOMAIN="max.ru" ;;
    6)
        read -rp "Введите свой домен: " FAKE_DOMAIN
        if [[ -z "$FAKE_DOMAIN" ]]; then FAKE_DOMAIN="ads.x5.ru"; fi
        ;;
    *) FAKE_DOMAIN="ads.x5.ru" ;;
esac

echo -e "\n${CYAN}Подготовка к установке начата...${RESET}\n"

# ==========================================
# ЧАСТЬ 2: УСТАНОВКА И НАСТРОЙКА
# ==========================================
draw_progress 5 "Обновление списка пакетов..."
apt-get update -qq >/dev/null 2>&1

draw_progress 15 "Установка необходимых утилит (curl, python3, qrencode и др.)..."
apt-get install -y -qq curl wget jq openssl certbot xxd socat ufw python3 python3-pip python3-venv iproute2 net-tools qrencode sqlite3 >/dev/null 2>&1
systemctl stop nginx apache2 2>/dev/null || true

# SSL Сертификаты
draw_progress 25 "Выпуск SSL для ${PROXY_DOMAIN}..."
if [[ -n "$CERT_EMAIL" ]]; then
    certbot certonly --standalone -d "${PROXY_DOMAIN}" --email "${CERT_EMAIL}" --agree-tos --non-interactive --quiet >/dev/null 2>&1 || true
else
    certbot certonly --standalone -d "${PROXY_DOMAIN}" --register-unsafely-without-email --agree-tos --non-interactive --quiet >/dev/null 2>&1 || true
fi

draw_progress 35 "Выпуск SSL для ${PANEL_DOMAIN}..."
if [[ -n "$CERT_EMAIL" ]]; then
    certbot certonly --standalone -d "${PANEL_DOMAIN}" --email "${CERT_EMAIL}" --agree-tos --non-interactive --quiet >/dev/null 2>&1 || true
else
    certbot certonly --standalone -d "${PANEL_DOMAIN}" --register-unsafely-without-email --agree-tos --non-interactive --quiet >/dev/null 2>&1 || true
fi

# Ядро Telemt
draw_progress 50 "Скачивание и установка ядра Telemt MTProto..."
ARCH=$(uname -m)
case "$ARCH" in
    "x86_64") BIN_ARCH="x86_64" ;;
    "aarch64"|"arm64") BIN_ARCH="aarch64" ;;
    *) echo -e "\n${RED}Неподдерживаемая архитектура: $ARCH${RESET}"; exit 1 ;;
esac
wget -q "https://github.com/telemt/telemt/releases/latest/download/telemt-${BIN_ARCH}-linux-gnu.tar.gz" -O /tmp/telemt.tar.gz
tar -xzf /tmp/telemt.tar.gz -C /tmp
mv /tmp/telemt /usr/local/bin/telemt
chmod +x /usr/local/bin/telemt
rm -f /tmp/telemt.tar.gz

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

# Firewall
draw_progress 65 "Настройка Firewall (UFW)..."
ufw allow 22/tcp >/dev/null 2>&1 || true
ufw allow 443/tcp >/dev/null 2>&1 || true
ufw allow ${PANEL_PORT}/tcp >/dev/null 2>&1 || true
if ufw status >/dev/null 2>&1; then ufw --force reload >/dev/null 2>&1; fi

# Web Панель
draw_progress 75 "Развертывание Web UI Панели и базы данных..."
PANEL_DIR="/var/www/telemt-panel"
mkdir -p "$PANEL_DIR/templates"
if [[ ! -d "$PANEL_DIR/venv" ]]; then python3 -m venv "$PANEL_DIR/venv"; fi
"$PANEL_DIR/venv/bin/pip" install -q --upgrade pip >/dev/null 2>&1
"$PANEL_DIR/venv/bin/pip" install -q Flask gunicorn toml werkzeug >/dev/null 2>&1

# ==========================================
# BACKEND (PYTHON APP)
# ==========================================
cat > "$PANEL_DIR/app.py" << 'PYEOF'
import os
import sqlite3
import secrets
import toml
import subprocess
import threading
import time
from flask import Flask, render_template, request, redirect, url_for, session, flash, jsonify
from werkzeug.security import generate_password_hash, check_password_hash

app = Flask(__name__)
app.secret_key = secrets.token_hex(24)
DB_PATH = 'panel.db'
TELEMT_TOML = '/etc/telemt/telemt.toml'
PROXY_HOST = os.environ.get('PROXY_HOST', 'localhost')

def get_db():
    conn = sqlite3.connect(DB_PATH)
    conn.row_factory = sqlite3.Row
    return conn

def init_db():
    with get_db() as conn:
        conn.execute('''CREATE TABLE IF NOT EXISTS users (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            nickname TEXT, device TEXT, secret TEXT,
            status TEXT DEFAULT 'active',
            seconds_left INTEGER DEFAULT 2592000,
            paused_at DATETIME,
            created_at DATETIME DEFAULT CURRENT_TIMESTAMP
        )''')
        conn.execute('''CREATE TABLE IF NOT EXISTS settings (
            admin_login TEXT, admin_password_hash TEXT, tls_domain TEXT
        )''')
        cur = conn.execute('SELECT COUNT(*) FROM settings')
        if cur.fetchone()[0] == 0:
            default_hash = generate_password_hash('admin')
            conn.execute('INSERT INTO settings (admin_login, admin_password_hash, tls_domain) VALUES (?, ?, ?)',
                         ('admin', default_hash, os.environ.get('FAKE_DOMAIN', 'ads.x5.ru')))

def sync_telemt():
    with get_db() as conn:
        users = conn.execute("SELECT nickname, device, secret FROM users WHERE status = 'active'").fetchall()
        settings = conn.execute("SELECT tls_domain FROM settings LIMIT 1").fetchone()
    
    tls_domain = settings['tls_domain'] if settings else 'ads.x5.ru'
    
    config = {
        'general': {'use_middle_proxy': True, 'modes': {'classic': False, 'secure': False, 'tls': True}},
        'server': {'port': 443},
        'censorship': {'tls_domain': tls_domain},
        'access': {'users': {}}
    }
    
    for u in users:
        key = f"{u['nickname']}_{u['device']}"
        config['access']['users'][key] = u['secret']
        
    with open(TELEMT_TOML, 'w') as f:
        toml.dump(config, f)
    
    subprocess.run(['systemctl', 'restart', 'telemt'], check=False, timeout=10)

def background_timer_task():
    while True:
        sync_needed = False
        try:
            with get_db() as conn:
                # Отнимаем минуту у активных
                conn.execute("UPDATE users SET seconds_left = seconds_left - 60 WHERE status = 'active' AND seconds_left > 0")
                # Авто-пауза
                cur = conn.execute("UPDATE users SET status = 'paused', paused_at = CURRENT_TIMESTAMP WHERE status = 'active' AND seconds_left <= 0")
                if cur.rowcount > 0: sync_needed = True
                # Авто-удаление если пауза > 32 дней
                cur = conn.execute("DELETE FROM users WHERE status = 'paused' AND (julianday(CURRENT_TIMESTAMP) - julianday(paused_at)) > 32")
                if cur.rowcount > 0: sync_needed = True
                conn.commit()
            
            if sync_needed:
                sync_telemt()
        except Exception as e:
            pass
        time.sleep(60)

threading.Thread(target=background_timer_task, daemon=True).start()

def get_uptime_and_status():
    try:
        with open('/proc/uptime', 'r') as f:
            uptime_seconds = float(f.readline().split()[0])
        days = int(uptime_seconds // 86400)
        hours = int((uptime_seconds % 86400) // 3600)
        minutes = int((uptime_seconds % 3600) // 60)
        uptime_str = f"{days} Дней, {hours} Часов, {minutes} Минут"
        
        status = subprocess.run(['systemctl', 'is-active', '--quiet', 'telemt'])
        is_running = (status.returncode == 0)
        
        # Получение активных IP
        ss_res = subprocess.run(['ss', '-tn', 'state', 'established'], capture_output=True, text=True)
        ips = set()
        for line in ss_res.stdout.splitlines():
            if ':443' in line:
                parts = line.split()
                if len(parts) >= 5:
                    ip = parts[4].rsplit(':', 1)[0].replace('::ffff:', '').strip('[]')
                    if ip: ips.add(ip)
        return uptime_str, is_running, list(ips)
    except:
        return "Неизвестно", False, []

@app.before_request
def require_login():
    if request.endpoint not in ['login', 'static'] and 'logged_in' not in session:
        return redirect(url_for('login'))

@app.route('/login', methods=['GET', 'POST'])
def login():
    if request.method == 'POST':
        username = request.form['username']
        password = request.form['password']
        with get_db() as conn:
            admin = conn.execute('SELECT admin_login, admin_password_hash FROM settings LIMIT 1').fetchone()
            if admin and admin['admin_login'] == username and check_password_hash(admin['admin_password_hash'], password):
                session['logged_in'] = True
                return redirect(url_for('dashboard'))
            flash('Неверный логин или пароль!', 'danger')
    return render_template('login.html')

@app.route('/logout')
def logout():
    session.pop('logged_in', None)
    return redirect(url_for('login'))

@app.route('/', methods=['GET', 'POST'])
def dashboard():
    if request.method == 'POST':
        nickname = request.form.get('nickname', '').strip().replace(' ', '_')
        device = request.form.get('device', 'Phone')
        if not nickname:
            flash('Введите никнейм!', 'danger')
            return redirect(url_for('dashboard'))
            
        secret = secrets.token_hex(16)
        with get_db() as conn:
            conn.execute("INSERT INTO users (nickname, device, secret) VALUES (?, ?, ?)", (nickname, device, secret))
        sync_telemt()
        flash(f'Доступ {nickname} успешно создан!', 'success')
        return redirect(url_for('dashboard'))

    uptime, is_running, active_ips = get_uptime_and_status()
    
    with get_db() as conn:
        users = conn.execute("SELECT * FROM users ORDER BY id DESC").fetchall()
        settings = conn.execute("SELECT tls_domain FROM settings LIMIT 1").fetchone()
        
    tls_domain = settings['tls_domain'] if settings else 'ads.x5.ru'
    hex_domain = tls_domain.encode('utf-8').hex()
    
    user_data = []
    for u in users:
        final_secret = f"ee{u['secret']}{hex_domain}"
        link = f"tg://proxy?server={PROXY_HOST}&port=443&secret={final_secret}"
        # Вычисление времени
        d = u['seconds_left'] // 86400
        h = (u['seconds_left'] % 86400) // 3600
        m = (u['seconds_left'] % 3600) // 60
        timer_str = f"{d} дней {h} часа {m} минут"
        
        # Симуляция "Онлайн" индикатора (Если статус активен и на сервере есть коннекты)
        is_online = (u['status'] == 'active' and len(active_ips) > 0)
        
        user_data.append({
            'id': u['id'], 'name': f"{u['nickname']}_{u['device']}",
            'status': u['status'], 'link': link, 'timer': timer_str,
            'is_online': is_online
        })

    return render_template('dashboard.html', users=user_data, uptime=uptime, 
                           is_running=is_running, active_ips=active_ips, 
                           tls_domain=tls_domain, total_users=len(users))

@app.route('/action/<int:uid>/<action>')
def user_action(uid, action):
    with get_db() as conn:
        if action == 'pause':
            conn.execute("UPDATE users SET status = 'paused', paused_at = CURRENT_TIMESTAMP WHERE id = ?", (uid,))
            flash('Доступ поставлен на паузу!', 'warning')
        elif action == 'resume':
            # Сброс таймера на 30 дней при возобновлении
            conn.execute("UPDATE users SET status = 'active', seconds_left = 2592000 WHERE id = ?", (uid,))
            flash('Доступ возобновлен. Таймер сброшен на 30 дней.', 'success')
        elif action == 'delete':
            conn.execute("DELETE FROM users WHERE id = ?", (uid,))
            flash('Доступ удален!', 'danger')
    sync_telemt()
    return redirect(url_for('dashboard'))

@app.route('/settings', methods=['GET', 'POST'])
def panel_settings():
    with get_db() as conn:
        settings = conn.execute("SELECT * FROM settings LIMIT 1").fetchone()
        
    if request.method == 'POST':
        new_tls = request.form.get('tls_domain')
        new_login = request.form.get('admin_login')
        new_pass = request.form.get('admin_pass')
        
        with get_db() as conn:
            if new_tls:
                conn.execute("UPDATE settings SET tls_domain = ?", (new_tls,))
                sync_telemt()
            if new_login and new_pass:
                phash = generate_password_hash(new_pass)
                conn.execute("UPDATE settings SET admin_login = ?, admin_password_hash = ?", (new_login, phash))
        flash('Настройки успешно сохранены!', 'success')
        return redirect(url_for('panel_settings'))
        
    return render_template('settings.html', settings=settings)

if __name__ == '__main__':
    init_db()
    port = int(os.environ.get('PANEL_PORT', 4444))
    app.run(host='0.0.0.0', port=port)
PYEOF

# ==========================================
# FRONTEND (HTML TEMPLATES)
# ==========================================
draw_progress 85 "Создание стилизованного интерфейса (Darknet UI)..."

cat > "$PANEL_DIR/templates/layout.html" << 'HTMLEOF'
<!DOCTYPE html>
<html lang="ru" data-bs-theme="dark">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>MTProto Panel by Mr_EFES</title>
    <link href="https://cdn.jsdelivr.net/npm/bootstrap@5.3.0/dist/css/bootstrap.min.css" rel="stylesheet">
    <link href="https://cdnjs.cloudflare.com/ajax/libs/font-awesome/6.4.0/css/all.min.css" rel="stylesheet">
    <script src="https://cdnjs.cloudflare.com/ajax/libs/qrcodejs/1.0.0/qrcode.min.js"></script>
    <style>
        :root { --neon-green: #39ff14; --dark-bg: #0f1115; --card-bg: #161920; }
        body { background-color: var(--dark-bg); font-family: 'Segoe UI', Roboto, Helvetica, Arial, sans-serif; color: #e0e0e0; }
        .navbar { background-color: var(--card-bg) !important; border-bottom: 1px solid #2a2d35; }
        .navbar-brand { color: var(--neon-green) !important; font-weight: 700; letter-spacing: 1px; }
        .card { background-color: var(--card-bg); border: 1px solid #2a2d35; border-radius: 12px; box-shadow: 0 4px 20px rgba(0,0,0,0.5); }
        .card-header { background-color: rgba(0,0,0,0.2); border-bottom: 1px solid #2a2d35; font-weight: 600; }
        .btn-neon { background-color: transparent; border: 1px solid var(--neon-green); color: var(--neon-green); transition: 0.3s; }
        .btn-neon:hover { background-color: var(--neon-green); color: #000; box-shadow: 0 0 10px var(--neon-green); }
        .form-control, .form-select { background-color: #0a0c0f; border: 1px solid #2a2d35; color: #fff; }
        .form-control:focus, .form-select:focus { background-color: #0a0c0f; border-color: var(--neon-green); color: #fff; box-shadow: none; }
        .status-dot { height: 12px; width: 12px; border-radius: 50%; display: inline-block; margin-right: 5px; }
        .dot-green { background-color: var(--neon-green); box-shadow: 0 0 8px var(--neon-green); }
        .dot-red { background-color: #ff3333; box-shadow: 0 0 8px #ff3333; }
        .table { color: #e0e0e0; }
        .table tbody tr:hover { background-color: rgba(255,255,255,0.05); }
        .timer-text { font-family: monospace; font-size: 0.9em; color: #aaa; }
        footer { font-family: monospace; color: #666; text-align: center; padding: 20px 0; margin-top: 40px; }
    </style>
</head>
<body>
    {% if session.logged_in %}
    <nav class="navbar navbar-expand-lg mb-4">
        <div class="container">
            <a class="navbar-brand" href="{{ url_for('dashboard') }}"><i class="fas fa-terminal me-2"></i>MTProto Panel</a>
            <button class="navbar-toggler" type="button" data-bs-toggle="collapse" data-bs-target="#navbarNav">
                <span class="navbar-toggler-icon"></span>
            </button>
            <div class="collapse navbar-collapse" id="navbarNav">
                <ul class="navbar-nav ms-auto">
                    <li class="nav-item"><a class="nav-link" href="{{ url_for('dashboard') }}"><i class="fas fa-home me-1"></i>Главная</a></li>
                    <li class="nav-item"><a class="nav-link" href="{{ url_for('panel_settings') }}"><i class="fas fa-cog me-1"></i>Настройки</a></li>
                    <li class="nav-item"><a class="nav-link text-danger" href="{{ url_for('logout') }}"><i class="fas fa-sign-out-alt me-1"></i>Выход</a></li>
                </ul>
            </div>
        </div>
    </nav>
    {% endif %}
    
    <div class="container">
        {% with messages = get_flashed_messages(with_categories=true) %}
            {% if messages %}
                {% for category, message in messages %}
                    <div class="alert alert-{{ category }} alert-dismissible fade show border-0" role="alert">
                        {{ message }}
                        <button type="button" class="btn-close btn-close-white" data-bs-dismiss="alert"></button>
                    </div>
                {% endfor %}
            {% endif %}
        {% endwith %}
        {% block content %}{% endblock %}
    </div>

    <footer>MTProto Proxy Panel 2026 by Mr_EFES</footer>

    <!-- Modal for QR -->
    <div class="modal fade" id="qrModal" tabindex="-1">
      <div class="modal-dialog modal-dialog-centered modal-sm">
        <div class="modal-content bg-dark">
          <div class="modal-header border-0">
            <h5 class="modal-title text-success"><i class="fas fa-qrcode me-2"></i>QR-Код</h5>
            <button type="button" class="btn-close btn-close-white" data-bs-dismiss="modal"></button>
          </div>
          <div class="modal-body text-center bg-white p-4 mx-auto rounded mb-3" id="qrcode-container"></div>
        </div>
      </div>
    </div>

    <script src="https://cdn.jsdelivr.net/npm/bootstrap@5.3.0/dist/js/bootstrap.bundle.min.js"></script>
    <script>
        function showQR(link) {
            document.getElementById('qrcode-container').innerHTML = '';
            new QRCode(document.getElementById('qrcode-container'), { text: link, width: 200, height: 200, colorDark : "#000000", colorLight : "#ffffff" });
            new bootstrap.Modal(document.getElementById('qrModal')).show();
        }
    </script>
</body>
</html>
HTMLEOF

cat > "$PANEL_DIR/templates/login.html" << 'HTMLEOF'
{% extends "layout.html" %}
{% block content %}
<div class="row justify-content-center align-items-center" style="min-height: 70vh;">
    <div class="col-md-5">
        <div class="card p-4">
            <div class="text-center mb-4">
                <i class="fas fa-user-secret fa-3x mb-3" style="color: var(--neon-green)"></i>
                <h4 class="text-white">Авторизация</h4>
            </div>
            <form method="POST">
                <div class="mb-3">
                    <input type="text" name="username" class="form-control" placeholder="Логин" required>
                </div>
                <div class="mb-4">
                    <input type="password" name="password" class="form-control" placeholder="Пароль" required>
                </div>
                <button type="submit" class="btn btn-neon w-100 py-2">ВОЙТИ В СИСТЕМУ</button>
            </form>
        </div>
    </div>
</div>
{% endblock %}
HTMLEOF

cat > "$PANEL_DIR/templates/dashboard.html" << 'HTMLEOF'
{% extends "layout.html" %}
{% block content %}
<div class="row mb-4">
    <div class="col-md-4">
        <div class="card h-100 border-success">
            <div class="card-body">
                <h6 class="text-muted"><i class="fas fa-server me-2"></i>Статус сервера</h6>
                <h4 class="{% if is_running %}text-success{% else %}text-danger{% endif %}">
                    {% if is_running %}Работает{% else %}Отключен{% endif %}
                </h4>
                <div class="timer-text mt-2"><i class="fas fa-clock me-1"></i>Uptime: {{ uptime }}</div>
            </div>
        </div>
    </div>
    <div class="col-md-8">
        <div class="card h-100 border-info">
            <div class="card-body">
                <h6 class="text-muted"><i class="fas fa-chart-bar me-2"></i>Статистика (Порт 443)</h6>
                <div class="d-flex justify-content-between align-items-center mt-3">
                    <div>
                        <span class="fs-4 fw-bold text-white">{{ total_users }}</span><br>
                        <span class="text-muted small">Всего доступов</span>
                    </div>
                    <div class="text-end">
                        <span class="fs-4 fw-bold text-info">{{ active_ips|length }}</span><br>
                        <span class="text-muted small">Подключенных IP</span>
                    </div>
                </div>
            </div>
        </div>
    </div>
</div>

<div class="card mb-4">
    <div class="card-header"><i class="fas fa-plus-square me-2"></i>Создать доступ</div>
    <div class="card-body">
        <form method="POST" class="row g-3">
            <div class="col-md-5">
                <input type="text" name="nickname" class="form-control" placeholder="Никнейм пользователя" required>
            </div>
            <div class="col-md-4">
                <select name="device" class="form-select">
                    <option value="Phone">📱 Телефон</option>
                    <option value="PC">💻 Компьютер</option>
                    <option value="Tablet">📟 Планшет</option>
                </select>
            </div>
            <div class="col-md-3">
                <button type="submit" class="btn btn-neon w-100"><i class="fas fa-bolt me-1"></i>Создать</button>
            </div>
        </form>
    </div>
</div>

<div class="card">
    <div class="card-header"><i class="fas fa-users me-2"></i>Список доступов</div>
    <div class="card-body p-0">
        <div class="table-responsive">
            <table class="table table-borderless align-middle mb-0">
                <thead class="border-bottom border-secondary">
                    <tr>
                        <th class="ps-4">Пользователь</th>
                        <th>Статус</th>
                        <th>Ссылка / QR</th>
                        <th class="text-end pe-4">Действия</th>
                    </tr>
                </thead>
                <tbody>
                    {% for user in users %}
                    <tr class="border-bottom border-secondary">
                        <td class="ps-4">
                            <span class="fw-bold text-white">{{ user.name }}</span><br>
                            <span class="timer-text">Осталось: {{ user.timer }}</span>
                        </td>
                        <td>
                            {% if user.is_online %}
                                <span class="status-dot dot-green" title="В сети"></span> <span class="small text-success">В сети</span>
                            {% else %}
                                <span class="status-dot dot-red" title="Не в сети"></span> <span class="small text-danger">Не в сети</span>
                            {% endif %}
                            <br>
                            <span class="badge {% if user.status == 'active' %}bg-success{% else %}bg-warning text-dark{% endif %} mt-1">
                                {{ 'Активен' if user.status == 'active' else 'Пауза' }}
                            </span>
                        </td>
                        <td>
                            <div class="input-group input-group-sm mb-1" style="max-width: 250px;">
                                <input type="text" class="form-control" value="{{ user.link }}" id="link-{{ user.id }}" readonly>
                                <button class="btn btn-outline-secondary" onclick="navigator.clipboard.writeText(document.getElementById('link-{{ user.id }}').value)"><i class="fas fa-copy"></i> Копия</button>
                            </div>
                            <button class="btn btn-sm btn-outline-info" onclick="showQR('{{ user.link }}')"><i class="fas fa-qrcode me-1"></i>QR-код</button>
                        </td>
                        <td class="text-end pe-4">
                            {% if user.status == 'active' %}
                                <a href="{{ url_for('user_action', uid=user.id, action='pause') }}" class="btn btn-sm btn-warning mb-1"><i class="fas fa-pause"></i></a>
                            {% else %}
                                <a href="{{ url_for('user_action', uid=user.id, action='resume') }}" class="btn btn-sm btn-success mb-1"><i class="fas fa-play"></i></a>
                            {% endif %}
                            <a href="{{ url_for('user_action', uid=user.id, action='delete') }}" class="btn btn-sm btn-danger mb-1" onclick="return confirm('Удалить навсегда?')"><i class="fas fa-trash"></i></a>
                        </td>
                    </tr>
                    {% else %}
                    <tr><td colspan="4" class="text-center py-4 text-muted">Список пуст</td></tr>
                    {% endfor %}
                </tbody>
            </table>
        </div>
    </div>
</div>
{% endblock %}
HTMLEOF

cat > "$PANEL_DIR/templates/settings.html" << 'HTMLEOF'
{% extends "layout.html" %}
{% block content %}
<div class="row justify-content-center">
    <div class="col-md-8">
        <div class="card mb-4 border-info">
            <div class="card-header"><i class="fas fa-mask me-2"></i>Настройки прокси (FakeTLS)</div>
            <div class="card-body">
                <form method="POST">
                    <div class="mb-3">
                        <label class="form-label text-muted small">Сайт для FakeTLS маскировки</label>
                        <input type="text" name="tls_domain" id="faketls_input" class="form-control mb-2" value="{{ settings.tls_domain }}" required>
                        <div class="d-flex flex-wrap gap-2">
                            <button type="button" class="btn btn-sm btn-outline-secondary" onclick="document.getElementById('faketls_input').value='ads.x5.ru'">ads.x5.ru</button>
                            <button type="button" class="btn btn-sm btn-outline-secondary" onclick="document.getElementById('faketls_input').value='1c.ru'">1c.ru</button>
                            <button type="button" class="btn btn-sm btn-outline-secondary" onclick="document.getElementById('faketls_input').value='ozon.ru'">ozon.ru</button>
                            <button type="button" class="btn btn-sm btn-outline-secondary" onclick="document.getElementById('faketls_input').value='vk.com'">vk.com</button>
                            <button type="button" class="btn btn-sm btn-outline-secondary" onclick="document.getElementById('faketls_input').value='max.ru'">max.ru</button>
                        </div>
                    </div>
                    <button type="submit" class="btn btn-info w-100"><i class="fas fa-save me-1"></i>Сохранить SNI</button>
                </form>
            </div>
        </div>

        <div class="card border-warning">
            <div class="card-header text-warning"><i class="fas fa-user-shield me-2"></i>Изменить данные Администратора</div>
            <div class="card-body">
                <form method="POST">
                    <div class="mb-3">
                        <label class="form-label text-muted small">Новый Логин</label>
                        <input type="text" name="admin_login" class="form-control" value="{{ settings.admin_login }}" required>
                    </div>
                    <div class="mb-3">
                        <label class="form-label text-muted small">Новый Пароль</label>
                        <input type="password" name="admin_pass" class="form-control" required minlength="5">
                    </div>
                    <button type="submit" class="btn btn-warning w-100"><i class="fas fa-key me-1"></i>Обновить доступы</button>
                </form>
            </div>
        </div>
    </div>
</div>
{% endblock %}
HTMLEOF

# Запуск панели
draw_progress 95 "Настройка и запуск службы панели управления..."
cat > /etc/systemd/system/telemt-panel.service << EOF
[Unit]
Description=MTProto Proxy Web Panel
After=network.target
[Service]
User=root
WorkingDirectory=${PANEL_DIR}
Environment="PATH=${PANEL_DIR}/venv/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
Environment="PANEL_PORT=${PANEL_PORT}"
Environment="PROXY_HOST=${PROXY_DOMAIN}"
Environment="FAKE_DOMAIN=${FAKE_DOMAIN}"
ExecStart=${PANEL_DIR}/venv/bin/gunicorn \
    --certfile /etc/letsencrypt/live/${PANEL_DOMAIN}/fullchain.pem \
    --keyfile /etc/letsencrypt/live/${PANEL_DOMAIN}/privkey.pem \
    -w 2 --threads 2 -b 0.0.0.0:${PANEL_PORT} app:app
Restart=always
[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable telemt-panel --now >/dev/null 2>&1

# Инициализируем БД через запуск python
export PROXY_HOST=${PROXY_DOMAIN}
export FAKE_DOMAIN=${FAKE_DOMAIN}
cd ${PANEL_DIR} && ./venv/bin/python3 -c "import app; app.init_db()" >/dev/null 2>&1
# Перезапуск чтобы подхватило конфиги
systemctl restart telemt-panel telemt

draw_progress 100 "Установка успешно завершена!"

# ==========================================
# ФИНАЛЬНЫЙ ОТЧЕТ И QR
# ==========================================
clear
echo -e "${NEON_GREEN}${BOLD}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "        🎉 УСТАНОВКА ЗАВЕРШЕНА УСПЕШНО! 🎉"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"

# Генерация первого дефолтного пользователя
SECRET=$(openssl rand -hex 16)
HEX_DOMAIN=$(printf '%s' "${FAKE_DOMAIN}" | xxd -p | tr -d '\n')
FINAL_SECRET="ee${SECRET}${HEX_DOMAIN}"
TG_LINK="tg://proxy?server=${PROXY_DOMAIN}&port=443&secret=${FINAL_SECRET}"

sqlite3 ${PANEL_DIR}/panel.db "INSERT INTO users (nickname, device, secret) VALUES ('Admin', 'Master', '${SECRET}');" >/dev/null 2>&1
cd ${PANEL_DIR} && ./venv/bin/python3 -c "import app; app.sync_telemt()" >/dev/null 2>&1

echo -e "\n${BOLD}📡 МАСТЕР-ССЫЛКА (Уже добавлена в панель):${RESET}"
echo -e "${CYAN}${TG_LINK}${RESET}\n"

echo -e "${BOLD}📱 QR-КОД ДЛЯ ПОДКЛЮЧЕНИЯ МАСТЕР-ССЫЛКИ:${RESET}"
qrencode -t ANSIUTF8 "$TG_LINK"
echo ""

echo -e "${BOLD}🖥️ ПАНЕЛЬ УПРАВЛЕНИЯ:${RESET}"
echo -e "   URL: ${GREEN}https://${PANEL_DOMAIN}:${PANEL_PORT}${RESET}"
echo -e "   Логин: ${YELLOW}admin${RESET}"
echo -e "   Пароль: ${YELLOW}admin${RESET}"
echo -e "   ${RED}⚠️ Обязательно смените данные в разделе Настройки!${RESET}"
echo -e "${NEON_GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}\n"
