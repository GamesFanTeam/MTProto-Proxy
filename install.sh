#!/bin/bash
set -euo pipefail

# ── Цветовая схема и UI Терминала ────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
BOLD='\033[1m'
RESET='\033[0m'

show_banner() {
    clear
    echo -e "${CYAN}${BOLD}"
    echo "  ███╗   ███╗████████╗██████╗ ██████╗  ██████╗ ████████╗ ██████╗ "
    echo "  ████╗ ████║╚══██╔══╝██╔══██╗██╔══██╗██╔═══██╗╚══██╔══╝██╔═══██╗"
    echo "  ██╔████╔██║   ██║   ██████╔╝██████╔╝██║   ██║   ██║   ██║   ██║"
    echo "  ██║╚██╔╝██║   ██║   ██╔═══╝ ██╔══██╗██║   ██║   ██║   ██║   ██║"
    echo "  ██║ ╚═╝ ██║   ██║   ██║     ██║  ██║╚██████╔╝   ██║   ╚██████╔╝"
    echo "  ╚═╝     ╚═╝   ╚═╝   ╚═╝     ╚═╝  ╚═╝ ╚═════╝    ╚═╝   ╚═════╝  "
    echo -e "${RESET}${BLUE}     Production MTProto Proxy Panel 2026 by Mr_EFES${RESET}"
    echo ""
}

print_step() { echo -e "\n${BOLD}${BLUE}[*] $1${RESET}"; }
print_success() { echo -e "${GREEN}[+] $1${RESET}"; }
print_error() { echo -e "${RED}[x] $1${RESET}"; exit 1; }

# ==========================================
# ЧАСТЬ 1: СБОР ДАННЫХ И ИСПРАВЛЕННЫЙ FAKE TLS
# ==========================================
show_banner

if [[ $EUID -ne 0 ]]; then print_error "Запустите скрипт от имени root (sudo bash)."; fi

print_step "СБОР УСТАНОВОЧНЫХ ДАННЫХ"
read -rp "Введите домен для ПРОКСИ (напр. tg.example.com): " PROXY_DOMAIN
[[ -z "${PROXY_DOMAIN}" ]] && print_error "Домен обязателен!"

read -rp "Введите домен для ПАНЕЛИ УПРАВЛЕНИЯ (напр. admin.example.com): " PANEL_DOMAIN
[[ -z "${PANEL_DOMAIN}" ]] && print_error "Домен панели обязателен!"

read -rp "Введите порт для панели [Enter = 4444]: " PANEL_PORT
PANEL_PORT=${PANEL_PORT:-4444}

read -rp "Введите Email для SSL Let's Encrypt (для уведомлений): " CERT_EMAIL

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
        read -rp "Введите свой домен (например, yandex.ru): " FAKE_DOMAIN
        [[ -z "$FAKE_DOMAIN" ]] && FAKE_DOMAIN="ads.x5.ru"
        ;;
    *) FAKE_DOMAIN="ads.x5.ru" ;;
esac

print_success "Принят SNI для Fake TLS: $FAKE_DOMAIN"

# ==========================================
# ЧАСТЬ 2: ПОДГОТОВКА СИСТЕМЫ И SSL
# ==========================================
print_step "УСТАНОВКА ЗАВИСИМОСТЕЙ (0/100%)"
apt-get update -qq >/dev/null 2>&1
apt-get install -y -qq curl wget jq openssl certbot xxd socat ufw python3 python3-pip python3-venv iproute2 net-tools qrencode >/dev/null 2>&1
systemctl stop nginx apache2 2>/dev/null || true
print_success "Системные зависимости установлены"

issue_ssl() {
    local domain=$1
    local email=$2
    if [[ -n "$email" ]]; then
        certbot certonly --standalone -d "${domain}" --email "${email}" --agree-tos --non-interactive --quiet >/dev/null 2>&1
    else
        certbot certonly --standalone -d "${domain}" --register-unsafely-without-email --agree-tos --non-interactive --quiet >/dev/null 2>&1
    fi
}

print_step "ВЫПУСК SSL СЕРТИФИКАТОВ"
echo "Выпуск SSL для $PROXY_DOMAIN..."
issue_ssl "$PROXY_DOMAIN" "$CERT_EMAIL"
[[ -f "/etc/letsencrypt/live/${PROXY_DOMAIN}/fullchain.pem" ]] && print_success "SSL $PROXY_DOMAIN готов" || print_error "Ошибка SSL $PROXY_DOMAIN"

echo "Выпуск SSL для $PANEL_DOMAIN..."
issue_ssl "$PANEL_DOMAIN" "$CERT_EMAIL"
[[ -f "/etc/letsencrypt/live/${PANEL_DOMAIN}/fullchain.pem" ]] && print_success "SSL $PANEL_DOMAIN готов" || print_error "Ошибка SSL $PANEL_DOMAIN"

# ==========================================
# ЧАСТЬ 3: ЯДРО TELEMT PROXY
# ==========================================
print_step "УСТАНОВКА MTPROTO ЯДРА"
ARCH=$(uname -m)
[[ "$ARCH" == "x86_64" ]] && BIN_ARCH="x86_64" || BIN_ARCH="aarch64"
wget -q "https://github.com/telemt/telemt/releases/latest/download/telemt-${BIN_ARCH}-linux-gnu.tar.gz" -O /tmp/telemt.tar.gz
tar -xzf /tmp/telemt.tar.gz -C /tmp
mv /tmp/telemt /usr/local/bin/telemt
chmod +x /usr/local/bin/telemt
rm -f /tmp/telemt.tar.gz
mkdir -p /etc/telemt

cat > /etc/systemd/system/telemt.service << EOF
[Unit]
Description=Telemt MTProto
After=network.target
[Service]
Type=simple
User=root
ExecStart=/usr/local/bin/telemt /etc/telemt/telemt.toml
Restart=always
LimitNOFILE=65536
[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload

# ==========================================
# ЧАСТЬ 4: WEB UI ПАНЕЛЬ И БАЗА
# ==========================================
print_step "НАСТРОЙКА WEB-ПАНЕЛИ УПРАВЛЕНИЯ"
PANEL_DIR="/var/www/telemt-panel"
mkdir -p "$PANEL_DIR/templates"

# Создаем виртуальное окружение
python3 -m venv "$PANEL_DIR/venv"
"$PANEL_DIR/venv/bin/pip" install -q Flask gunicorn toml werkzeug qrcode[pil] >/dev/null 2>&1

cat > "$PANEL_DIR/panel_config.json" << EOF
{
    "username": "admin",
    "password_hash": "scrypt:32768:8:1\$0A5B2...", 
    "is_default": true,
    "proxy_host": "${PROXY_DOMAIN}",
    "proxy_port": 443,
    "fake_tls": "${FAKE_DOMAIN}",
    "secret_key": "$(openssl rand -hex 24)"
}
EOF

cat > "$PANEL_DIR/users_db.json" << EOF
{}
EOF

cat > "$PANEL_DIR/app.py" << 'PYEOF'
import os, json, secrets, time, toml, subprocess, io
from flask import Flask, render_template, request, redirect, url_for, session, flash, send_file
from werkzeug.security import generate_password_hash, check_password_hash
import qrcode

app = Flask(__name__)
DIR = os.path.dirname(os.path.abspath(__file__))
CONFIG_PATH = os.path.join(DIR, 'panel_config.json')
USERS_PATH = os.path.join(DIR, 'users_db.json')
TELEMT_TOML = '/etc/telemt/telemt.toml'

def load_json(path):
    try:
        with open(path, 'r') as f: return json.load(f)
    except: return {}

def save_json(path, data):
    with open(path, 'w') as f: json.dump(data, f, indent=4)

config = load_json(CONFIG_PATH)
app.secret_key = config.get('secret_key', secrets.token_hex(16))

if "scrypt:32768" in config.get('password_hash', ''):
    config['password_hash'] = generate_password_hash('admin')
    save_json(CONFIG_PATH, config)

def rebuild_telemt():
    users = load_json(USERS_PATH)
    cfg = load_json(CONFIG_PATH)
    toml_data = {
        "general": {"use_middle_proxy": True, "modes": {"classic": False, "secure": False, "tls": True}},
        "server": {"port": 443},
        "censorship": {"tls_domain": cfg.get("fake_tls", "ads.x5.ru")},
        "access": {"users": {}}
    }
    for uid, udata in users.items():
        if udata.get("status") == "active":
            toml_data["access"]["users"][uid] = udata["secret"]
    
    with open(TELEMT_TOML, 'w') as f:
        toml.dump(toml_data, f)
    subprocess.run(['systemctl', 'restart', 'telemt'], check=False)

def check_online_status():
    try:
        res = subprocess.run(['journalctl', '-u', 'telemt', '--since', '2m'], capture_output=True, text=True)
        logs = res.stdout
        users = load_json(USERS_PATH)
        online = []
        for uid, data in users.items():
            if data['secret'][:8] in logs or data['secret'] in logs:
                online.append(uid)
        return online
    except:
        return []

def get_sys_stats():
    with open('/proc/uptime', 'r') as f:
        uptime_seconds = float(f.readline().split()[0])
    d = int(uptime_seconds // 86400)
    h = int((uptime_seconds % 86400) // 3600)
    m = int((uptime_seconds % 3600) // 60)
    
    try:
        res = subprocess.run(['ss', '-tn', 'state', 'established'], capture_output=True, text=True)
        active_ips = len([line for line in res.stdout.splitlines() if ':443' in line])
    except: active_ips = 0
    return {"d": d, "h": h, "m": m, "ips": active_ips}

def format_timer(seconds):
    if seconds <= 0: return "0 дней 0 часов 0 минут"
    d = seconds // 86400
    h = (seconds % 86400) // 3600
    m = (seconds % 3600) // 60
    return f"{d} дней {h} часов {m} минут"

@app.before_request
def require_login():
    if request.path == '/internal_cron': return
    if request.endpoint not in ['login', 'static'] and 'user' not in session:
        return redirect(url_for('login'))

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

@app.route('/', methods=['GET', 'POST'])
def dashboard():
    users = load_json(USERS_PATH)
    cfg = load_json(CONFIG_PATH)
    
    if request.method == 'POST':
        nickname = request.form.get('nickname', '').strip().replace(' ', '_')
        device = request.form.get('device', 'Phone')
        if not nickname: return redirect(url_for('dashboard'))
        
        uid = f"{nickname}_{device}"
        users[uid] = {
            "secret": secrets.token_hex(16),
            "status": "active",
            "timer_seconds": 2592000, # 30 days
            "last_tick": int(time.time()),
            "created_at": int(time.time())
        }
        save_json(USERS_PATH, users)
        rebuild_telemt()
        flash(f'Доступ {uid} создан!', 'success')
        return redirect(url_for('dashboard'))

    # Format data for UI
    hex_domain = cfg.get("fake_tls", "ads.x5.ru").encode('utf-8').hex()
    online_uids = check_online_status()
    
    display_users = {}
    for uid, data in users.items():
        final_secret = f"ee{data['secret']}{hex_domain}"
        link = f"tg://proxy?server={cfg['proxy_host']}&port={cfg['proxy_port']}&secret={final_secret}"
        display_users[uid] = {
            "link": link,
            "status": data['status'],
            "timer_str": format_timer(data['timer_seconds']),
            "is_online": uid in online_uids and data['status'] == 'active'
        }
        
    return render_template('dashboard.html', users=display_users, stats=get_sys_stats(), total=len(users))

@app.route('/action/<action>/<uid>')
def user_action(action, uid):
    users = load_json(USERS_PATH)
    if uid not in users: return redirect(url_for('dashboard'))
    
    if action == 'pause':
        users[uid]['status'] = 'paused'
        users[uid]['paused_at'] = int(time.time())
    elif action == 'resume':
        users[uid]['status'] = 'active'
        users[uid]['timer_seconds'] = 2592000 # Reset to 30 days
        users[uid]['last_tick'] = int(time.time())
    elif action == 'delete':
        del users[uid]
        
    save_json(USERS_PATH, users)
    rebuild_telemt()
    return redirect(url_for('dashboard'))

@app.route('/settings', methods=['GET', 'POST'])
def settings():
    cfg = load_json(CONFIG_PATH)
    if request.method == 'POST':
        action = request.form.get('action')
        if action == 'credentials':
            cfg['username'] = request.form['new_user']
            if request.form['new_pass']:
                cfg['password_hash'] = generate_password_hash(request.form['new_pass'])
            cfg['is_default'] = False
            flash('Данные администратора обновлены', 'success')
        elif action == 'faketls':
            cfg['fake_tls'] = request.form['fake_tls']
            flash('Fake TLS домен обновлен', 'success')
            save_json(CONFIG_PATH, cfg)
            rebuild_telemt()
            return redirect(url_for('settings'))
            
        save_json(CONFIG_PATH, cfg)
        session['user'] = cfg['username']
        return redirect(url_for('settings'))
    return render_template('settings.html', cfg=cfg)

@app.route('/qr/<uid>')
def generate_qr(uid):
    users = load_json(USERS_PATH)
    cfg = load_json(CONFIG_PATH)
    if uid not in users: return "Not found", 404
    hex_domain = cfg.get("fake_tls", "ads.x5.ru").encode('utf-8').hex()
    final_secret = f"ee{users[uid]['secret']}{hex_domain}"
    link = f"tg://proxy?server={cfg['proxy_host']}&port={cfg['proxy_port']}&secret={final_secret}"
    
    img = qrcode.make(link)
    buf = io.BytesIO()
    img.save(buf, format='PNG')
    buf.seek(0)
    return send_file(buf, mimetype='image/png')

@app.route('/internal_cron')
def cron_task():
    if request.remote_addr != '127.0.0.1': return "Forbidden", 403
    users = load_json(USERS_PATH)
    now = int(time.time())
    changed = False
    
    for uid, udata in list(users.items()):
        if udata['status'] == 'active':
            elapsed = now - udata.get('last_tick', now)
            udata['timer_seconds'] -= elapsed
            udata['last_tick'] = now
            if udata['timer_seconds'] <= 0:
                udata['status'] = 'paused'
                udata['timer_seconds'] = 0
                udata['paused_at'] = now
                changed = True
        elif udata['status'] == 'paused':
            if now - udata.get('paused_at', now) > 86400 * 2:
                del users[uid]
                changed = True
                
    save_json(USERS_PATH, users)
    if changed: rebuild_telemt()
    return "OK"

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=int(os.environ.get('PANEL_PORT', 4444)))
PYEOF

# Инициализация первого пользователя CLI -> БД
FIRST_SECRET=$(openssl rand -hex 16)
cat > "$PANEL_DIR/users_db.json" << EOF
{
    "Admin_Default": {
        "secret": "${FIRST_SECRET}",
        "status": "active",
        "timer_seconds": 2592000,
        "last_tick": $(date +%s),
        "created_at": $(date +%s)
    }
}
EOF

# HTML Шаблоны (Telegram Dark Mode Style)
cat > "$PANEL_DIR/templates/layout.html" << 'HTMLEOF'
<!DOCTYPE html>
<html lang="ru" data-bs-theme="dark">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>MTProto Panel</title>
    <link href="https://cdn.jsdelivr.net/npm/bootstrap@5.3.0/dist/css/bootstrap.min.css" rel="stylesheet">
    <link href="https://cdnjs.cloudflare.com/ajax/libs/font-awesome/6.4.0/css/all.min.css" rel="stylesheet">
    <style>
        body { background-color: #0e1621; color: #f5f5f5; font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif; }
        .navbar { background-color: #17212b !important; border-bottom: 1px solid #2b394a; }
        .card { background-color: #17212b; border: 1px solid #2b394a; border-radius: 12px; }
        .card-header { background-color: #1c2733; border-bottom: 1px solid #2b394a; border-radius: 12px 12px 0 0 !important; font-weight: bold; }
        .btn-primary { background-color: #2b5278; border-color: #2b5278; }
        .btn-primary:hover { background-color: #3e6d9e; border-color: #3e6d9e; }
        .form-control, .form-select { background-color: #242f3d; border: 1px solid #2b394a; color: #fff; }
        .form-control:focus, .form-select:focus { background-color: #242f3d; border-color: #5288c1; color: #fff; box-shadow: none; }
        .table { color: #f5f5f5; }
        .table-hover tbody tr:hover { background-color: #202b36; color: #fff; }
        .status-dot { height: 10px; width: 10px; border-radius: 50%; display: inline-block; }
        .status-online { background-color: #4CAF50; box-shadow: 0 0 8px #4CAF50; }
        .status-offline { background-color: #F44336; }
        .status-paused { background-color: #FFC107; }
        .timer-text { font-size: 0.85rem; color: #8a9ba8; }
        .footer-text { color: #5f7a92; font-size: 0.9rem; margin-top: 30px; margin-bottom: 20px; text-align: center; }
    </style>
</head>
<body>
    {% if session.user %}
    <nav class="navbar navbar-expand-lg navbar-dark mb-4">
        <div class="container">
            <a class="navbar-brand" href="/"><i class="fab fa-telegram-plane me-2 text-primary"></i>Proxy Panel</a>
            <button class="navbar-toggler" type="button" data-bs-toggle="collapse" data-bs-target="#nav">
                <span class="navbar-toggler-icon"></span>
            </button>
            <div class="collapse navbar-collapse" id="nav">
                <ul class="navbar-nav ms-auto">
                    <li class="nav-item"><a class="nav-link" href="/"><i class="fas fa-home me-1"></i>Главная</a></li>
                    <li class="nav-item"><a class="nav-link" href="/settings"><i class="fas fa-cog me-1"></i>Настройки</a></li>
                    <li class="nav-item"><a class="nav-link text-danger" href="/logout"><i class="fas fa-sign-out-alt me-1"></i>Выход</a></li>
                </ul>
            </div>
        </div>
    </nav>
    {% endif %}
    <div class="container mt-4">
        {% with messages = get_flashed_messages(with_categories=true) %}
            {% if messages %}
                {% for category, message in messages %}
                    <div class="alert alert-{{ category }} alert-dismissible fade show border-0" style="background-color: #242f3d; color: #fff;">
                        {{ message }}
                        <button type="button" class="btn-close btn-close-white" data-bs-dismiss="alert"></button>
                    </div>
                {% endfor %}
            {% endif %}
        {% endwith %}
        {% block content %}{% endblock %}
        <div class="footer-text">MTProto Proxy Panel 2026 by Mr_EFES</div>
    </div>
    <script src="https://cdn.jsdelivr.net/npm/bootstrap@5.3.0/dist/js/bootstrap.bundle.min.js"></script>
</body>
</html>
HTMLEOF

cat > "$PANEL_DIR/templates/dashboard.html" << 'HTMLEOF'
{% extends "layout.html" %}
{% block content %}
<div class="row mb-4">
    <div class="col-md-4 mb-3 mb-md-0">
        <div class="card h-100 text-center py-3">
            <div class="text-muted mb-1"><i class="fas fa-server me-1"></i>Статус сервера</div>
            <h4 class="text-success mb-0">Работает</h4>
        </div>
    </div>
    <div class="col-md-4 mb-3 mb-md-0">
        <div class="card h-100 text-center py-3">
            <div class="text-muted mb-1"><i class="fas fa-clock me-1"></i>Uptime системы</div>
            <h5 class="mb-0">{{ stats.d }} дн, {{ stats.h }} ч, {{ stats.m }} мин</h5>
        </div>
    </div>
    <div class="col-md-4">
        <div class="card h-100 text-center py-3">
            <div class="text-muted mb-1"><i class="fas fa-users me-1"></i>Статистика</div>
            <h6 class="mb-0">Доступов: {{ total }} | IP: {{ stats.ips }}</h6>
        </div>
    </div>
</div>

<div class="card mb-4">
    <div class="card-header d-flex justify-content-between align-items-center">
        <span><i class="fas fa-plus-circle me-2"></i>Создать доступ</span>
    </div>
    <div class="card-body">
        <form method="POST" class="row g-2 align-items-end">
            <div class="col-md-5">
                <label class="form-label text-muted small mb-1">Никнейм</label>
                <input type="text" name="nickname" class="form-control form-control-sm" required>
            </div>
            <div class="col-md-4">
                <label class="form-label text-muted small mb-1">Устройство</label>
                <select name="device" class="form-select form-select-sm">
                    <option value="Phone">📱 Телефон</option>
                    <option value="PC">💻 ПК</option>
                </select>
            </div>
            <div class="col-md-3">
                <button type="submit" class="btn btn-primary btn-sm w-100">Создать</button>
            </div>
        </form>
    </div>
</div>

<div class="card">
    <div class="card-header"><i class="fas fa-list me-2"></i>Список доступов</div>
    <div class="card-body p-0">
        <div class="table-responsive">
            <table class="table table-hover align-middle mb-0 border-0">
                <thead style="background-color: #1c2733;">
                    <tr>
                        <th class="border-0 ps-3">Устройство / Таймер</th>
                        <th class="border-0 text-center">Статус</th>
                        <th class="border-0 text-end pe-3">Действия</th>
                    </tr>
                </thead>
                <tbody>
                    {% for uid, data in users.items() %}
                    <tr>
                        <td class="ps-3 border-secondary border-opacity-25">
                            <div class="fw-bold">{{ uid }}</div>
                            <div class="timer-text"><i class="fas fa-hourglass-half me-1"></i>Осталось: {{ data.timer_str }}</div>
                        </td>
                        <td class="text-center border-secondary border-opacity-25">
                            {% if data.status == 'active' %}
                                {% if data.is_online %}
                                    <span class="status-dot status-online" title="В сети"></span> <small class="text-success">В сети</small>
                                {% else %}
                                    <span class="status-dot status-offline" title="Не в сети"></span> <small class="text-danger">Оффлайн</small>
                                {% endif %}
                            {% else %}
                                <span class="status-dot status-paused" title="Пауза"></span> <small class="text-warning">Пауза</small>
                            {% endif %}
                        </td>
                        <td class="text-end pe-3 border-secondary border-opacity-25">
                            <button class="btn btn-sm btn-outline-info me-1" onclick="navigator.clipboard.writeText('{{ data.link }}'); alert('Скопировано!');" title="Копировать">
                                <i class="fas fa-copy"></i>
                            </button>
                            <button class="btn btn-sm btn-outline-light me-1" data-bs-toggle="modal" data-bs-target="#qrModal{{ loop.index }}" title="QR Код">
                                <i class="fas fa-qrcode"></i>
                            </button>
                            {% if data.status == 'active' %}
                                <a href="/action/pause/{{ uid }}" class="btn btn-sm btn-outline-warning me-1" title="Пауза"><i class="fas fa-pause"></i></a>
                            {% else %}
                                <a href="/action/resume/{{ uid }}" class="btn btn-sm btn-outline-success me-1" title="Включить"><i class="fas fa-play"></i></a>
                            {% endif %}
                            <a href="/action/delete/{{ uid }}" class="btn btn-sm btn-outline-danger" onclick="return confirm('Удалить?')" title="Удалить"><i class="fas fa-trash"></i></a>
                        </td>
                    </tr>
                    
                    <!-- Modal QR -->
                    <div class="modal fade" id="qrModal{{ loop.index }}" tabindex="-1">
                        <div class="modal-dialog modal-sm modal-dialog-centered">
                            <div class="modal-content" style="background-color: #17212b;">
                                <div class="modal-header border-0 pb-0">
                                    <h6 class="modal-title">{{ uid }}</h6>
                                    <button type="button" class="btn-close btn-close-white" data-bs-dismiss="modal"></button>
                                </div>
                                <div class="modal-body text-center pt-2">
                                    <img src="/qr/{{ uid }}" class="img-fluid rounded bg-white p-2 mb-3">
                                    <button class="btn btn-primary btn-sm w-100" onclick="navigator.clipboard.writeText('{{ data.link }}');">Копировать ссылку</button>
                                </div>
                            </div>
                        </div>
                    </div>
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
<div class="row">
    <div class="col-md-6 mb-4">
        <div class="card h-100">
            <div class="card-header"><i class="fas fa-globe me-2"></i>Сайт для FakeTLS маскировки</div>
            <div class="card-body">
                <form method="POST">
                    <input type="hidden" name="action" value="faketls">
                    <div class="mb-3">
                        <label class="form-label text-muted small">Текущий домен</label>
                        <input type="text" id="fakeTlsInput" name="fake_tls" class="form-control" value="{{ cfg.fake_tls }}" required>
                    </div>
                    <div class="mb-3 d-flex flex-wrap gap-2">
                        <button type="button" class="btn btn-sm btn-outline-info" onclick="document.getElementById('fakeTlsInput').value='ads.x5.ru'">ads.x5.ru</button>
                        <button type="button" class="btn btn-sm btn-outline-info" onclick="document.getElementById('fakeTlsInput').value='1c.ru'">1c.ru</button>
                        <button type="button" class="btn btn-sm btn-outline-info" onclick="document.getElementById('fakeTlsInput').value='ozon.ru'">ozon.ru</button>
                        <button type="button" class="btn btn-sm btn-outline-info" onclick="document.getElementById('fakeTlsInput').value='vk.com'">vk.com</button>
                        <button type="button" class="btn btn-sm btn-outline-info" onclick="document.getElementById('fakeTlsInput').value='max.ru'">max.ru</button>
                    </div>
                    <button type="submit" class="btn btn-primary">Применить и перезапустить ядро</button>
                </form>
            </div>
        </div>
    </div>
    
    <div class="col-md-6 mb-4">
        <div class="card h-100">
            <div class="card-header"><i class="fas fa-user-shield me-2"></i>Данные Администратора</div>
            <div class="card-body">
                <form method="POST">
                    <input type="hidden" name="action" value="credentials">
                    <div class="mb-3">
                        <label class="form-label text-muted small">Логин панели</label>
                        <input type="text" name="new_user" class="form-control" value="{{ cfg.username }}" required>
                    </div>
                    <div class="mb-3">
                        <label class="form-label text-muted small">Новый пароль (оставьте пустым, если не меняете)</label>
                        <input type="password" name="new_pass" class="form-control">
                    </div>
                    <button type="submit" class="btn btn-primary">Сохранить данные</button>
                </form>
            </div>
        </div>
    </div>
</div>
{% endblock %}
HTMLEOF

cat > "$PANEL_DIR/templates/login.html" << 'HTMLEOF'
{% extends "layout.html" %}
{% block content %}
<div class="row justify-content-center mt-5">
    <div class="col-md-5">
        <div class="card border-0 shadow-lg">
            <div class="card-body p-5">
                <div class="text-center mb-4">
                    <i class="fab fa-telegram-plane fa-3x text-primary mb-3"></i>
                    <h4>Вход в панель</h4>
                </div>
                <form method="POST">
                    <div class="mb-3">
                        <input type="text" name="username" class="form-control p-2" placeholder="Логин" required>
                    </div>
                    <div class="mb-4">
                        <input type="password" name="password" class="form-control p-2" placeholder="Пароль" required>
                    </div>
                    <button type="submit" class="btn btn-primary w-100 p-2">Войти</button>
                </form>
            </div>
        </div>
    </div>
</div>
{% endblock %}
HTMLEOF

# Первичная генерация toml
"$PANEL_DIR/venv/bin/python" -c "from app import rebuild_telemt; rebuild_telemt()"
systemctl enable telemt --now >/dev/null 2>&1
print_success "Файлы панели успешно развернуты"

cat > /etc/systemd/system/telemt-panel.service << EOF
[Unit]
Description=MTProto Proxy Panel
After=network.target
[Service]
User=root
WorkingDirectory=${PANEL_DIR}
Environment="PATH=${PANEL_DIR}/venv/bin:/usr/bin"
Environment="PANEL_PORT=${PANEL_PORT}"
ExecStart=${PANEL_DIR}/venv/bin/gunicorn --certfile /etc/letsencrypt/live/${PANEL_DOMAIN}/fullchain.pem --keyfile /etc/letsencrypt/live/${PANEL_DOMAIN}/privkey.pem -w 1 -b 0.0.0.0:${PANEL_PORT} app:app
Restart=always
[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable telemt-panel --now >/dev/null 2>&1
print_success "Службы запущены"

# ==========================================
# ЧАСТЬ 5: UFW & CRON (ТАЙМЕР И АВТООБНОВЛЕНИЕ)
# ==========================================
print_step "НАСТРОЙКА FIREWALL И ФОНОВЫХ ЗАДАЧ"
ufw allow 22/tcp >/dev/null 2>&1 || true
ufw allow 443/tcp >/dev/null 2>&1
ufw allow ${PANEL_PORT}/tcp >/dev/null 2>&1
if ufw status | grep -q "Status: active"; then ufw --force reload >/dev/null 2>&1; fi

(crontab -l 2>/dev/null | grep -v "telemt-panel" | grep -v "certbot renew") | crontab - 2>/dev/null || true
(crontab -l 2>/dev/null; echo "* * * * * curl -s http://127.0.0.1:${PANEL_PORT}/internal_cron >/dev/null 2>&1") | crontab - 2>/dev/null || true
(crontab -l 2>/dev/null; echo "0 3 * * * certbot renew --post-hook 'systemctl restart telemt telemt-panel' >/dev/null 2>&1") | crontab - 2>/dev/null || true
print_success "Настроен минутный таймер отсчета 30 дней и автообновление SSL"

# ==========================================
# ФИНАЛ
# ==========================================
HEX_DOMAIN=$(printf '%s' "${FAKE_DOMAIN}" | xxd -p | tr -d '\n')
TG_LINK="tg://proxy?server=${PROXY_DOMAIN}&port=443&secret=ee${FIRST_SECRET}${HEX_DOMAIN}"

clear
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
echo -e "           ${GREEN}${BOLD}🎉 УСТАНОВКА ЗАВЕРШЕНА УСПЕШНО! 🎉${RESET}"
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
echo ""
echo -e "${BOLD}📡 ПРОКСИ:${RESET}"
echo -e "   Домен: ${GREEN}${PROXY_DOMAIN}${RESET}"
echo -e "   Fake TLS: ${YELLOW}${FAKE_DOMAIN}${RESET}"
echo ""
echo -e "${BOLD}🖥️ ПАНЕЛЬ УПРАВЛЕНИЯ:${RESET}"
echo -e "   URL: ${GREEN}https://${PANEL_DOMAIN}:${PANEL_PORT}${RESET}"
echo -e "   Логин/Пароль: ${YELLOW}admin${RESET} / ${YELLOW}admin${RESET}"
echo ""
echo -e "${BOLD}🔗 ПЕРВЫЙ ДОСТУП (Admin_Default - 30 дней):${RESET}"
echo -e "   ${BLUE}${TG_LINK}${RESET}"
echo ""
echo -e "${BOLD}📱 QR-КОД ДЛЯ ПОДКЛЮЧЕНИЯ:${RESET}"
qrencode -t ANSIUTF8 "${TG_LINK}"
echo ""
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
