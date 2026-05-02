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

# Шаг 3
((STEP++)); draw_progress $STEP $TOTAL_STEPS "Скачивание ядра Telemt..."
ARCH=$(uname -m)
[[ "$ARCH" == "aarch64" || "$ARCH" == "arm64" ]] && BIN_ARCH="aarch64" || BIN_ARCH="x86_64"
wget -q "https://github.com/telemt/telemt/releases/latest/download/telemt-${BIN_ARCH}-linux-gnu.tar.gz" -O /tmp/telemt.tar.gz
tar -xzf /tmp/telemt.tar.gz -C /tmp
mv /tmp/telemt /usr/local/bin/telemt
chmod +x /usr/local/bin/telemt
rm -f /tmp/telemt.tar.gz

# Шаг 4
((STEP++)); draw_progress $STEP $TOTAL_STEPS "Настройка Telemt..."
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

# Ожидание порта
for i in {1..5}; do
    if ss -tulpen 2>/dev/null | grep -q ":443"; then break; fi
    sleep 2
done

# Шаг 5
((STEP++)); draw_progress $STEP $TOTAL_STEPS "Настройка Firewall..."
ufw allow 22/tcp >/dev/null 2>&1 || true
ufw allow 443/tcp >/dev/null 2>&1
ufw allow ${PANEL_PORT}/tcp >/dev/null 2>&1
ufw --force reload >/dev/null 2>&1 || true

# Шаг 6
((STEP++)); draw_progress $STEP $TOTAL_STEPS "Подготовка окружения Web Panel..."
PANEL_DIR="/var/www/telemt-panel"
mkdir -p "$PANEL_DIR/templates"
if [[ ! -d "$PANEL_DIR/venv" ]]; then
    python3 -m venv "$PANEL_DIR/venv"
fi
"$PANEL_DIR/venv/bin/pip" install -q --upgrade pip >/dev/null 2>&1
"$PANEL_DIR/venv/bin/pip" install -q Flask gunicorn toml werkzeug qrcode >/dev/null 2>&1

# Шаг 7
((STEP++)); draw_progress $STEP $TOTAL_STEPS "Создание Backend и БД..."

cat > "$PANEL_DIR/db.json" << EOF
{
    "panel_start_time": $(date +%s),
    "users": {
        "admin_default": {
            "secret": "${USER_SECRET}",
            "status": "active",
            "device": "System",
            "time_left": 2592000,
            "last_update": $(date +%s),
            "paused_at": 0
        }
    }
}
EOF

cat > "$PANEL_DIR/panel_config.json" << EOF
{
    "admin_login": "admin",
    "password_hash": "...",
    "is_default": true,
    "proxy_host": "${PROXY_DOMAIN}",
    "proxy_port": 443,
    "secret_key": "$(openssl rand -hex 24)"
}
EOF

cat > "$PANEL_DIR/app.py" << 'PYEOF'
import os, json, secrets, toml, subprocess, time
import qrcode, base64
from io import BytesIO
from flask import Flask, render_template, request, redirect, url_for, session, flash, jsonify
from werkzeug.security import generate_password_hash, check_password_hash

app = Flask(__name__)
CONFIG_PATH = 'panel_config.json'
DB_PATH = 'db.json'
TELEMT_TOML = '/etc/telemt/telemt.toml'
MONTH_SECONDS = 30 * 86400

def load_json(path):
    with open(path, 'r') as f: return json.load(f)

def save_json(data, path):
    with open(path, 'w') as f: json.dump(data, f, indent=4)

config = load_json(CONFIG_PATH)
app.secret_key = config.get('secret_key', secrets.token_hex(16))

if "..." in config.get('password_hash', ''):
    config['password_hash'] = generate_password_hash('admin')
    save_json(config, CONFIG_PATH)

def generate_qr(data):
    qr = qrcode.QRCode(version=1, box_size=4, border=2)
    qr.add_data(data)
    qr.make(fit=True)
    img = qr.make_image(fill_color="#3390ec", back_color="white")
    buffered = BytesIO()
    img.save(buffered, format="PNG")
    return base64.b64encode(buffered.getvalue()).decode()

def sync_telemt(db):
    try:
        with open(TELEMT_TOML, 'r') as f:
            t_config = toml.load(f)
    except:
        t_config = {'access': {'users': {}}, 'censorship': {'tls_domain': 'max.ru'}}
    
    t_config['access']['users'] = {}
    for u, data in db.get('users', {}).items():
        if data['status'] == 'active':
            t_config['access']['users'][u] = data['secret']
            
    with open(TELEMT_TOML, 'w') as f:
        toml.dump(t_config, f)
    subprocess.run(['systemctl', 'restart', 'telemt'], check=False)

def update_timers():
    db = load_json(DB_PATH)
    now = time.time()
    changed = False
    
    for u, data in list(db['users'].items()):
        if data['status'] == 'active':
            elapsed = now - data.get('last_update', now)
            data['time_left'] -= elapsed
            data['last_update'] = now
            if data['time_left'] <= 0:
                data['status'] = 'paused'
                data['time_left'] = 0
                data['paused_at'] = now
                changed = True
        elif data['status'] == 'paused':
            data['last_update'] = now
            # Delete after 32 days
            if now - data.get('paused_at', now) > 32 * 86400:
                del db['users'][u]
                changed = True
                
    if changed:
        save_json(db, DB_PATH)
        sync_telemt(db)
    return db

def format_time(seconds):
    if seconds < 0: seconds = 0
    d = int(seconds // 86400)
    h = int((seconds % 86400) // 3600)
    m = int((seconds % 3600) // 60)
    return f"{d} д {h} ч {m} мин"

def get_server_stats():
    try:
        res = subprocess.run(['ss', '-tn', 'state', 'established'], capture_output=True, text=True)
        ips = {line.split()[4].rsplit(':',1)[0] for line in res.stdout.splitlines() if ':443' in line}
        return list(ips)
    except:
        return []

@app.before_request
def require_login():
    allowed = ['login']
    if request.endpoint not in allowed and 'user' not in session and not request.path.startswith('/static'):
        return redirect(url_for('login'))

@app.route('/login', methods=['GET', 'POST'])
def login():
    if request.method == 'POST':
        cfg = load_json(CONFIG_PATH)
        if request.form['username'] == cfg.get('admin_login', 'admin') and check_password_hash(cfg['password_hash'], request.form['password']):
            session['user'] = cfg.get('admin_login', 'admin')
            return redirect(url_for('dashboard'))
        flash('Неверный логин или пароль', 'danger')
    return render_template('login.html')

@app.route('/logout')
def logout():
    session.pop('user', None)
    return redirect(url_for('login'))

@app.route('/settings', methods=['GET', 'POST'])
def settings():
    cfg = load_json(CONFIG_PATH)
    if request.method == 'POST':
        new_login = request.form['new_login']
        new_pass = request.form['new_password']
        cfg['admin_login'] = new_login
        cfg['password_hash'] = generate_password_hash(new_pass)
        cfg['is_default'] = False
        save_json(cfg, CONFIG_PATH)
        session['user'] = new_login
        flash('Данные администратора изменены!', 'success')
        return redirect(url_for('dashboard'))
    return render_template('settings.html', current_login=cfg.get('admin_login', 'admin'))

@app.route('/', methods=['GET', 'POST'])
def dashboard():
    cfg = load_json(CONFIG_PATH)
    db = update_timers()
    
    try:
        t_config = toml.load(TELEMT_TOML)
        tls_domain = t_config.get('censorship', {}).get('tls_domain', 'max.ru')
    except:
        tls_domain = 'max.ru'
        
    hex_domain = tls_domain.encode('utf-8').hex()
    active_ips = get_server_stats()
    
    # Process users for display
    users_display = {}
    for name, data in db['users'].items():
        final_secret = f"ee{data['secret']}{hex_domain}"
        link = f"tg://proxy?server={cfg['proxy_host']}&port={cfg['proxy_port']}&secret={final_secret}"
        users_display[name] = {
            'link': link,
            'qr': generate_qr(link),
            'status': data['status'],
            'time_str': format_time(data['time_left']),
            'device': data.get('device', 'Phone')
        }

    if request.method == 'POST':
        if 'action' in request.form:
            action = request.form['action']
            target = request.form.get('target_user')
            if action == 'pause' and target in db['users']:
                db['users'][target]['status'] = 'paused'
                db['users'][target]['paused_at'] = time.time()
                flash(f'Доступ {target} приостановлен.', 'warning')
            elif action == 'resume' and target in db['users']:
                # Reset timer if resumed within 24h
                if time.time() - db['users'][target].get('paused_at', time.time()) <= 86400:
                    db['users'][target]['time_left'] = MONTH_SECONDS
                db['users'][target]['status'] = 'active'
                db['users'][target]['last_update'] = time.time()
                flash(f'Доступ {target} возобновлен.', 'success')
            elif action == 'delete' and target in db['users']:
                del db['users'][target]
                flash(f'Доступ {target} удален.', 'success')
            elif action == 'update_sni':
                new_sni = request.form.get('sni_domain')
                try:
                    tc = toml.load(TELEMT_TOML)
                    tc['censorship']['tls_domain'] = new_sni
                    with open(TELEMT_TOML, 'w') as f: toml.dump(tc, f)
                    subprocess.run(['systemctl', 'restart', 'telemt'], check=False)
                    flash('SNI обновлен', 'success')
                except:
                    pass
                return redirect(url_for('dashboard'))
            
            save_json(db, DB_PATH)
            sync_telemt(db)
            return redirect(url_for('dashboard'))
            
        else:
            nickname = request.form.get('nickname', '').strip().replace(' ', '_')
            device = request.form.get('device', 'Phone')
            if nickname:
                user_key = f"{nickname}_{device}"
                db['users'][user_key] = {
                    'secret': secrets.token_hex(16),
                    'status': 'active',
                    'device': device,
                    'time_left': MONTH_SECONDS,
                    'last_update': time.time()
                }
                save_json(db, DB_PATH)
                sync_telemt(db)
                flash(f'Создан доступ {user_key}', 'success')
            return redirect(url_for('dashboard'))

    uptime_sec = time.time() - db.get('panel_start_time', time.time())
    
    # Check if systemd service is active
    srv_status = "Отключен"
    if subprocess.run(['systemctl', 'is-active', '--quiet', 'telemt']).returncode == 0:
        srv_status = "Работает"

    return render_template('dashboard.html', 
                           users=users_display, 
                           stats=active_ips, 
                           uptime=format_time(uptime_sec),
                           server_status=srv_status,
                           tls_domain=tls_domain)

if __name__ == '__main__':
    port = int(os.environ.get('PANEL_PORT', 4444))
    app.run(host='0.0.0.0', port=port)
PYEOF

# Шаг 8
((STEP++)); draw_progress $STEP $TOTAL_STEPS "Создание HTML шаблонов (Telegram Light Style)..."

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
        body { background-color: #f1f2f6; font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif; color: #000; }
        .navbar { background-color: #ffffff; box-shadow: 0 1px 3px rgba(0,0,0,0.05); }
        .navbar-brand { color: #3390ec !important; font-weight: 600; }
        .card { border: none; border-radius: 12px; box-shadow: 0 2px 8px rgba(0,0,0,0.04); margin-bottom: 20px; background: #fff; }
        .card-header { background: #fff; border-bottom: 1px solid #f0f0f0; border-radius: 12px 12px 0 0 !important; font-weight: 600; padding: 15px 20px; }
        .btn-primary { background-color: #3390ec; border-color: #3390ec; }
        .btn-primary:hover { background-color: #2b7bc9; border-color: #2b7bc9; }
        .btn-outline-primary { color: #3390ec; border-color: #3390ec; }
        .btn-outline-primary:hover { background-color: #3390ec; color: #fff; }
        .form-control, .form-select { border-radius: 8px; border: 1px solid #dfe1e5; }
        .form-control:focus { border-color: #3390ec; box-shadow: 0 0 0 0.2rem rgba(51, 144, 236, 0.25); }
        .table { vertical-align: middle; }
        .table th { border-top: none; color: #707579; font-weight: 500; font-size: 0.9rem; }
        .status-dot { display: inline-block; width: 10px; height: 10px; border-radius: 50%; margin-right: 6px; }
        .status-online { background-color: #34c759; box-shadow: 0 0 5px rgba(52, 199, 89, 0.5); }
        .status-offline { background-color: #ff3b30; }
        .qr-img { width: 40px; height: 40px; border-radius: 6px; cursor: pointer; transition: transform 0.2s; }
        .qr-img:hover { transform: scale(1.1); }
        .footer-text { color: #8e8e93; font-size: 0.85rem; text-align: center; margin: 30px 0; }
        .sni-btn { margin-right: 5px; margin-bottom: 5px; border-radius: 20px; font-size: 0.8rem; }
    </style>
</head>
<body>
    <nav class="navbar navbar-expand-lg mb-4">
        <div class="container">
            <a class="navbar-brand" href="/"><i class="fas fa-paper-plane me-2"></i>MTProto Manager</a>
            {% if session.user %}
            <div class="d-flex">
                <a href="/settings" class="btn btn-sm btn-light me-2"><i class="fas fa-cog"></i> Настройки</a>
                <a href="/logout" class="btn btn-sm btn-outline-danger"><i class="fas fa-sign-out-alt"></i> Выход</a>
            </div>
            {% endif %}
        </div>
    </nav>
    <div class="container">
        {% with messages = get_flashed_messages(with_categories=true) %}
            {% if messages %}
                {% for category, message in messages %}
                    <div class="alert alert-{{ category }} alert-dismissible fade show rounded-3" role="alert">
                        {{ message }}
                        <button type="button" class="btn-close" data-bs-dismiss="alert"></button>
                    </div>
                {% endfor %}
            {% endif %}
        {% endwith %}
        {% block content %}{% endblock %}
        <div class="footer-text">«MTProto Proxy Panel 2026 by Mr_EFES»</div>
    </div>
    <script src="https://cdn.jsdelivr.net/npm/bootstrap@5.3.0/dist/js/bootstrap.bundle.min.js"></script>
    <script>
        const tooltipTriggerList = document.querySelectorAll('[data-bs-toggle="tooltip"]')
        const tooltipList = [...tooltipTriggerList].map(tooltipTriggerEl => new bootstrap.Tooltip(tooltipTriggerEl))
    </script>
</body>
</html>
HTMLEOF

cat > "$PANEL_DIR/templates/login.html" << 'HTMLEOF'
{% extends "layout.html" %}
{% block content %}
<div class="row justify-content-center mt-5">
    <div class="col-md-5">
        <div class="card p-2">
            <div class="card-body">
                <div class="text-center mb-4">
                    <div class="bg-light rounded-circle d-inline-flex p-3 mb-3">
                        <i class="fas fa-lock fa-2x text-primary"></i>
                    </div>
                    <h4 class="fw-bold">Авторизация</h4>
                </div>
                <form method="POST">
                    <div class="mb-3">
                        <input type="text" name="username" class="form-control form-control-lg" placeholder="Логин" required autofocus>
                    </div>
                    <div class="mb-4">
                        <input type="password" name="password" class="form-control form-control-lg" placeholder="Пароль" required>
                    </div>
                    <button type="submit" class="btn btn-primary btn-lg w-100 rounded-pill">Войти</button>
                </form>
            </div>
        </div>
    </div>
</div>
{% endblock %}
HTMLEOF

cat > "$PANEL_DIR/templates/settings.html" << 'HTMLEOF'
{% extends "layout.html" %}
{% block content %}
<div class="row justify-content-center">
    <div class="col-md-6">
        <div class="card">
            <div class="card-header"><i class="fas fa-user-shield me-2 text-primary"></i>Смена данных администратора</div>
            <div class="card-body">
                <form method="POST">
                    <div class="mb-3">
                        <label class="form-label text-muted small">Новый Логин</label>
                        <input type="text" name="new_login" class="form-control" value="{{ current_login }}" required>
                    </div>
                    <div class="mb-4">
                        <label class="form-label text-muted small">Новый Пароль</label>
                        <input type="password" name="new_password" class="form-control" required minlength="5">
                    </div>
                    <button type="submit" class="btn btn-primary w-100"><i class="fas fa-save me-2"></i>Сохранить изменения</button>
                </form>
            </div>
        </div>
    </div>
</div>
{% endblock %}
HTMLEOF

cat > "$PANEL_DIR/templates/dashboard.html" << 'HTMLEOF'
{% extends "layout.html" %}
{% block content %}
<div class="row">
    <!-- ЛЕВАЯ КОЛОНКА (Настройки и Статистика) -->
    <div class="col-lg-4 mb-4">
        <!-- Статус сервера -->
        <div class="card">
            <div class="card-header"><i class="fas fa-server me-2 text-primary"></i>Настройки прокси</div>
            <div class="card-body">
                <div class="d-flex justify-content-between mb-2">
                    <span class="text-muted">Статус сервера:</span>
                    {% if server_status == "Работает" %}
                        <span class="fw-bold text-success"><i class="fas fa-check-circle me-1"></i>Работает</span>
                    {% else %}
                        <span class="fw-bold text-danger"><i class="fas fa-times-circle me-1"></i>Отключен</span>
                    {% endif %}
                </div>
                <div class="d-flex justify-content-between mb-4">
                    <span class="text-muted">Uptime панели:</span>
                    <span class="fw-bold">{{ uptime }}</span>
                </div>
                
                <hr>
                <form method="POST" class="mt-3">
                    <input type="hidden" name="action" value="update_sni">
                    <label class="form-label text-muted small">Сайт для FakeTLS маскировки</label>
                    <div class="input-group mb-2">
                        <input type="text" id="sni-input" name="sni_domain" class="form-control" value="{{ tls_domain }}">
                        <button class="btn btn-outline-primary" type="submit">Применить</button>
                    </div>
                    <div class="sni-buttons">
                        <button type="button" class="btn btn-sm btn-outline-secondary sni-btn">ads.x5.ru</button>
                        <button type="button" class="btn btn-sm btn-outline-secondary sni-btn">1c.ru</button>
                        <button type="button" class="btn btn-sm btn-outline-secondary sni-btn">ozon.ru</button>
                        <button type="button" class="btn btn-sm btn-outline-secondary sni-btn">vk.com</button>
                        <button type="button" class="btn btn-sm btn-outline-secondary sni-btn">max.ru</button>
                    </div>
                </form>
            </div>
        </div>

        <!-- Статистика -->
        <div class="card">
            <div class="card-header"><i class="fas fa-chart-pie me-2 text-primary"></i>Статистика</div>
            <div class="card-body">
                <div class="d-flex justify-content-between mb-2">
                    <span class="text-muted">Всего доступов:</span>
                    <span class="badge bg-primary rounded-pill">{{ users|length }}</span>
                </div>
                <div class="d-flex justify-content-between">
                    <span class="text-muted">Активных IP (порт 443):</span>
                    <span class="badge bg-success rounded-pill">{{ stats|length }}</span>
                </div>
            </div>
        </div>
    </div>

    <!-- ПРАВАЯ КОЛОНКА (Доступы) -->
    <div class="col-lg-8">
        <div class="card">
            <div class="card-header d-flex justify-content-between align-items-center">
                <span><i class="fas fa-users me-2 text-primary"></i>Список доступов</span>
                <button class="btn btn-sm btn-primary" data-bs-toggle="modal" data-bs-target="#addUserModal">
                    <i class="fas fa-plus me-1"></i>Добавить
                </button>
            </div>
            <div class="card-body p-0">
                <div class="table-responsive">
                    <table class="table table-hover mb-0">
                        <thead class="bg-light">
                            <tr>
                                <th class="ps-4">Имя Устройства</th>
                                <th>Таймер</th>
                                <th>Ссылка / QR</th>
                                <th class="text-end pe-4">Действия</th>
                            </tr>
                        </thead>
                        <tbody>
                            {% for name, data in users.items() %}
                            <tr>
                                <td class="ps-4">
                                    <div class="fw-bold text-dark">
                                        {% if stats|length > 0 and data.status == 'active' %}
                                            <span class="status-dot status-online" title="В сети"></span>
                                        {% else %}
                                            <span class="status-dot status-offline" title="Не в сети"></span>
                                        {% endif %}
                                        {{ name }}
                                    </div>
                                    <div class="small text-muted"><i class="fas fa-mobile-alt me-1"></i>{{ data.device }}</div>
                                </td>
                                <td>
                                    <div class="small fw-bold {% if data.status == 'paused' %}text-danger{% else %}text-success{% endif %}">
                                        Осталось: <br>{{ data.time_str }}
                                    </div>
                                </td>
                                <td>
                                    <div class="d-flex align-items-center gap-2">
                                        <img src="data:image/png;base64,{{ data.qr }}" class="qr-img border" data-bs-toggle="modal" data-bs-target="#qrModal{{ loop.index }}">
                                        <button class="btn btn-sm btn-light border" onclick="navigator.clipboard.writeText('{{ data.link }}'); this.innerHTML='<i class=\'fas fa-check text-success\'></i>'; setTimeout(()=>this.innerHTML='<i class=\'fas fa-copy\'></i>',1500);" data-bs-toggle="tooltip" title="Копировать">
                                            <i class="fas fa-copy"></i>
                                        </button>
                                    </div>

                                    <!-- Modal QR -->
                                    <div class="modal fade" id="qrModal{{ loop.index }}" tabindex="-1">
                                      <div class="modal-dialog modal-dialog-centered modal-sm">
                                        <div class="modal-content border-0 shadow">
                                          <div class="modal-body text-center p-4">
                                            <h5 class="mb-3">{{ name }}</h5>
                                            <img src="data:image/png;base64,{{ data.qr }}" class="img-fluid rounded mb-3">
                                            <button type="button" class="btn btn-secondary w-100" data-bs-dismiss="modal">Закрыть</button>
                                          </div>
                                        </div>
                                      </div>
                                    </div>
                                </td>
                                <td class="text-end pe-4">
                                    <form method="POST" class="d-inline">
                                        <input type="hidden" name="target_user" value="{{ name }}">
                                        {% if data.status == 'active' %}
                                            <button type="submit" name="action" value="pause" class="btn btn-sm btn-outline-warning" data-bs-toggle="tooltip" title="Пауза">
                                                <i class="fas fa-pause"></i>
                                            </button>
                                        {% else %}
                                            <button type="submit" name="action" value="resume" class="btn btn-sm btn-outline-success" data-bs-toggle="tooltip" title="Вкл">
                                                <i class="fas fa-play"></i>
                                            </button>
                                        {% endif %}
                                        <button type="submit" name="action" value="delete" class="btn btn-sm btn-outline-danger ms-1" onclick="return confirm('Удалить {{ name }}?')" data-bs-toggle="tooltip" title="Удалить">
                                            <i class="fas fa-trash"></i>
                                        </button>
                                    </form>
                                </td>
                            </tr>
                            {% else %}
                            <tr><td colspan="4" class="text-center text-muted py-5"><i class="fas fa-inbox fa-3x mb-3 text-light"></i><br>Нет созданных доступов</td></tr>
                            {% endfor %}
                        </tbody>
                    </table>
                </div>
            </div>
        </div>
    </div>
</div>

<!-- Modal Add User -->
<div class="modal fade" id="addUserModal" tabindex="-1">
  <div class="modal-dialog modal-dialog-centered">
    <div class="modal-content border-0 shadow">
      <div class="modal-header bg-light border-0">
        <h5 class="modal-title fw-bold">Новый доступ</h5>
        <button type="button" class="btn-close" data-bs-dismiss="modal"></button>
      </div>
      <form method="POST">
          <div class="modal-body p-4">
              <div class="mb-3">
                  <label class="form-label text-muted small">Никнейм</label>
                  <input type="text" name="nickname" class="form-control" placeholder="Ivan" required>
              </div>
              <div class="mb-3">
                  <label class="form-label text-muted small">Тип Устройства</label>
                  <select name="device" class="form-select">
                      <option value="Phone">📱 Телефон</option>
                      <option value="PC">💻 Компьютер</option>
                      <option value="Tablet">📟 Планшет</option>
                  </select>
              </div>
          </div>
          <div class="modal-footer border-0 bg-light">
            <button type="button" class="btn btn-light" data-bs-dismiss="modal">Отмена</button>
            <button type="submit" class="btn btn-primary">Создать</button>
          </div>
      </form>
    </div>
  </div>
</div>

<script>
    document.querySelectorAll('.sni-btn').forEach(btn => {
        btn.addEventListener('click', () => {
            document.getElementById('sni-input').value = btn.innerText;
        });
    });
</script>
{% endblock %}
HTMLEOF

# Шаг 9
((STEP++)); draw_progress $STEP $TOTAL_STEPS "Запуск службы панели..."
cat > /etc/systemd/system/telemt-panel.service << EOF
[Unit]
Description=MTProto Web Panel
After=network.target
[Service]
User=root
WorkingDirectory=${PANEL_DIR}
Environment="PATH=${PANEL_DIR}/venv/bin:/usr/bin"
Environment="PANEL_PORT=${PANEL_PORT}"
ExecStart=${PANEL_DIR}/venv/bin/gunicorn --certfile /etc/letsencrypt/live/${PANEL_DOMAIN}/fullchain.pem --keyfile /etc/letsencrypt/live/${PANEL_DOMAIN}/privkey.pem -w 2 -b 0.0.0.0:${PANEL_PORT} app:app
Restart=always
[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable telemt-panel --now >/dev/null 2>&1

# Шаг 10
((STEP++)); draw_progress $STEP $TOTAL_STEPS "Настройка автообновления и cron..."
cat > /usr/local/bin/telemt-cron.sh << 'CRONEOF'
#!/bin/bash
curl -s "http://127.0.0.1:${PANEL_PORT}/" >/dev/null 2>&1 || true
CRONEOF
chmod +x /usr/local/bin/telemt-cron.sh
(crontab -l 2>/dev/null | grep -v "telemt-cron.sh"; echo "* * * * * /usr/local/bin/telemt-cron.sh") | crontab - 2>/dev/null

echo -e "\n\n${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
if systemctl is-active --quiet telemt-panel && systemctl is-active --quiet telemt; then
    echo -e "           🎉 ${BOLD}${GREEN}УСТАНОВКА ЗАВЕРШЕНА УСПЕШНО!${RESET} 🎉"
else
    echo -e "           ⚠️ ${BOLD}${RED}УСТАНОВКА ЗАВЕРШЕНА С ОШИБКАМИ!${RESET} ⚠️"
    echo -e "   Проверьте логи: cat $LOG_FILE"
fi
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}\n"

HEX_DOMAIN=$(printf '%s' "${FAKE_DOMAIN}" | xxd -p | tr -d '\n')
FINAL_SECRET="ee${USER_SECRET}${HEX_DOMAIN}"
TG_LINK="tg://proxy?server=${PROXY_DOMAIN}&port=443&secret=${FINAL_SECRET}"

echo -e "${BOLD}🖥️ ПАНЕЛЬ УПРАВЛЕНИЯ:${RESET}"
echo -e "   URL:    ${GREEN}https://${PANEL_DOMAIN}:${PANEL_PORT}${RESET}"
echo -e "   Логин:  ${YELLOW}admin${RESET}"
echo -e "   Пароль: ${YELLOW}admin${RESET}"
echo -e "   ${RED}⚠️ Рекомендуется сменить данные при первом входе!${RESET}\n"

echo -e "${BOLD}🔗 ПЕРВЫЙ ДОСТУП (System):${RESET}"
echo -e "   ${GREEN}${TG_LINK}${RESET}\n"
echo -e "${BOLD}📱 QR-КОД ПОДКЛЮЧЕНИЯ:${RESET}"
qrencode -t ANSIUTF8 "${TG_LINK}"
echo ""
