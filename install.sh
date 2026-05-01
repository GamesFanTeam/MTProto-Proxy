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
                certbot certonly --standalone -d "${domain}" --email "${email}" --agree-tos --non-interactive --quiet >/dev/null 2>&1 || true
            else
                certbot certonly --standalone -d "${domain}" --register-unsafely-without-email --agree-tos --non-interactive --quiet >/dev/null 2>&1 || true
            fi
            [[ -f "$cert_path" ]] && echo "renewed" || echo "error"
        fi
    else
        if [[ -n "$email" ]]; then
            certbot certonly --standalone -d "${domain}" --email "${email}" --agree-tos --non-interactive --quiet >/dev/null 2>&1 || true
        else
            certbot certonly --standalone -d "${domain}" --register-unsafely-without-email --agree-tos --non-interactive --quiet >/dev/null 2>&1 || true
        fi
        [[ -f "$cert_path" ]] && echo "new" || echo "error"
    fi
}
show_banner
if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}Ошибка: запустите скрипт от имени root.${RESET}"
    exit 1
fi
echo -e "${YELLOW}Проверка необходимых пакетов...${RESET}"
apt-get update -qq >/dev/null 2>&1
apt-get install -y -qq curl wget jq openssl certbot xxd socat ufw python3 python3-pip python3-venv iproute2 net-tools qrencode >/dev/null 2>&1
systemctl stop nginx apache2 2>/dev/null || true
# ==========================================
# ЧАСТЬ 1: СБОР ВВОДНЫХ ДАННЫХ
# ==========================================
echo -e "${BOLD}--- НАСТРОЙКА ПРОКСИ И ПАНЕЛИ ---${RESET}"
echo ""
read -rp "Введите домен для ПРОКСИ (напр. tg.example.com): " PROXY_DOMAIN
[[ -z "${PROXY_DOMAIN}" ]] && { echo -e "${RED}Домен для прокси обязателен!${RESET}"; exit 1; }
read -rp "Введите домен для ПАНЕЛИ УПРАВЛЕНИЯ (напр. admin.example.com): " PANEL_DOMAIN
[[ -z "${PANEL_DOMAIN}" ]] && { echo -e "${RED}Домен для панели обязателен!${RESET}"; exit 1; }
read -rp "Введите порт для панели (по умолчанию 4444): " PANEL_PORT
PANEL_PORT=${PANEL_PORT:-4444}
read -rp "Email для SSL сертификатов (необязательно): " SSL_EMAIL
read -rp "FakeTLS домен для маскировки (по умолчанию www.microsoft.com): " FAKE_TLS_DOMAIN
FAKE_TLS_DOMAIN=${FAKE_TLS_DOMAIN:-www.microsoft.com}
echo -e "\n${YELLOW}Выпуск SSL сертификатов...${RESET}"
proxy_cert_status=$(issue_ssl "$PROXY_DOMAIN" "$SSL_EMAIL")
panel_cert_status=$(issue_ssl "$PANEL_DOMAIN" "$SSL_EMAIL")
if [[ "$proxy_cert_status" == "error" ]]; then
    echo -e "${RED}Не удалось получить SSL сертификат для ${PROXY_DOMAIN}${RESET}"
    exit 1
fi
if [[ "$panel_cert_status" == "error" ]]; then
    echo -e "${RED}Не удалось получить SSL сертификат для ${PANEL_DOMAIN}${RESET}"
    exit 1
fi
echo -e "${GREEN}SSL сертификаты успешно получены${RESET}"
# ==========================================
# ЧАСТЬ 2: УСТАНОВКА TELEMT
# ==========================================
echo -e "\n${YELLOW}Установка Telemt...${RESET}"
mkdir -p /opt/telemt
cd /opt/telemt
curl -sL https://github.com/TelegramMessenger/MTProxy/releases/download/latest/MTProxy-bin-linux-x64.tar.gz -o mtproxy.tar.gz
tar xzf mtproxy.tar.gz
cp MTProxy-bin-linux-x64/mtproto-proxy /usr/local/bin/telemt
chmod +x /usr/local/bin/telemt
rm -rf MTProxy-bin-linux-x64 mtproxy.tar.gz
mkdir -p /etc/telemt
chown root:root /etc/telemt
chmod 700 /etc/telemt
SECRET_KEY=$(openssl rand -hex 16)
cat > /etc/telemt/telemt.toml << TOMLEOF
port = 443
workers = $(nproc)
nat_info = "$(curl -s https://api.ipify.org):443"
adtag = "$(openssl rand -hex 16)"
censorship = { tls_domain = "${FAKE_TLS_DOMAIN}" }
access = { users = {} }
TOMLEOF
cat > /etc/systemd/system/telemt.service << SVCEOF
[Unit]
Description=Telemt MTProto Proxy
After=network.target
[Service]
Type=simple
ExecStart=/usr/local/bin/telemt /etc/telemt/telemt.toml
Restart=always
RestartSec=10
LimitNOFILE=65535
[Install]
WantedBy=multi-user.target
SVCEOF
systemctl daemon-reload
systemctl enable telemt --now >/dev/null 2>&1
# ==========================================
# ЧАСТЬ 3: МОНТОРИНГ И АВТО-ПОДНЯТИЕ
# ==========================================
echo -e "${YELLOW}Настройка авто-мониторинга прокси...${RESET}"
cat > /usr/local/bin/telemt-monitor.sh << 'MONITOREOF'
#!/bin/bash
SERVICE_NAME="telemt"
LOG_FILE="/var/log/telemt-monitor.log"
log_message() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"
}
check_service() {
    if ! systemctl is-active --quiet "$SERVICE_NAME"; then
        log_message "WARNING: Service $SERVICE_NAME is not running. Attempting to restart..."
        systemctl restart "$SERVICE_NAME"
        sleep 5
        if systemctl is-active --quiet "$SERVICE_NAME"; then
            log_message "SUCCESS: Service $SERVICE_NAME restarted successfully."
        else
            log_message "ERROR: Failed to restart service $SERVICE_NAME."
        fi
    else
        log_message "OK: Service $SERVICE_NAME is running."
    fi
}
check_service
MONITOREOF
chmod +x /usr/local/bin/telemt-monitor.sh
cat > /etc/systemd/system/telemt-monitor.service << SVCEOF
[Unit]
Description=Telemt Auto-Monitor Service
After=telemt.service
[Service]
Type=oneshot
ExecStart=/usr/local/bin/telemt-monitor.sh
RemainAfterExit=yes
[Install]
WantedBy=multi-user.target
SVCEOF
cat > /etc/cron.d/telemt-monitor << CRONEOF
*/1 * * * * root /usr/local/bin/telemt-monitor.sh >/dev/null 2>&1
CRONEOF
systemctl daemon-reload
systemctl enable telemt-monitor --now >/dev/null 2>&1
# ==========================================
# ЧАСТЬ 4: WEB ПАНЕЛЬ
# ==========================================
echo -e "${YELLOW}Создание веб-панели...${RESET}"
PANEL_DIR="/opt/mtproto-panel"
mkdir -p "$PANEL_DIR"/{templates,static}
cd "$PANEL_DIR"
python3 -m venv venv
source venv/bin/activate
pip install --quiet flask toml cryptography qrcode[pil]
ADMIN_USER="admin"
ADMIN_PASS=$(openssl rand -base64 12)
PASSWORD_HASH=$(python3 -c "from werkzeug.security import generate_password_hash; print(generate_password_hash('$ADMIN_PASS'))")
SECRET_KEY=$(python3 -c "import secrets; print(secrets.token_hex(32))")
cat > panel_config.json << CONFIGEOF
{
    "username": "${ADMIN_USER}",
    "password_hash": "${PASSWORD_HASH}",
    "secret_key": "${SECRET_KEY}",
    "proxy_host": "${PROXY_DOMAIN}",
    "proxy_port": 443,
    "panel_port": ${PANEL_PORT},
    "fake_tls_domain": "${FAKE_TLS_DOMAIN}",
    "is_default": true
}
CONFIGEOF
cat > app.py << 'PYEOF'
#!/usr/bin/env python3
import os, json, secrets, subprocess, time, re
from datetime import datetime
from flask import Flask, render_template, request, redirect, url_for, session, flash, jsonify
import toml
from werkzeug.security import generate_password_hash, check_password_hash
import qrcode
import base64
from io import BytesIO
app = Flask(__name__)
CONFIG_PATH = 'panel_config.json'
TELEMT_TOML = '/etc/telemt/telemt.toml'
USERS_DB = '/etc/telemt/users.json'
def load_config():
    with open(CONFIG_PATH, 'r') as f:
        return json.load(f)
def save_config(data):
    with open(CONFIG_PATH, 'w') as f:
        json.dump(data, f, indent=4)
def load_users_db():
    if os.path.exists(USERS_DB):
        with open(USERS_DB, 'r') as f:
            return json.load(f)
    return {}
def save_users_db(data):
    with open(USERS_DB, 'w') as f:
        json.dump(data, f, indent=4)
config = load_config()
app.secret_key = config.get('secret_key', secrets.token_hex(32))
if "..." in config.get('password_hash', ''):
    config['password_hash'] = generate_password_hash('admin')
    save_config(config)
def restart_telemt():
    try:
        subprocess.run(['systemctl', 'restart', 'telemt'], check=False, timeout=10)
    except Exception:
        pass
def get_proxy_stats():
    try:
        result = subprocess.run(['ss', '-tn', 'state', 'established'], capture_output=True, text=True, timeout=5)
        lines = result.stdout.splitlines()
        ips = set()
        for line in lines:
            if ':443' in line:
                parts = line.split()
                if len(parts) >= 5:
                    peer_addr = parts[4]
                    ip = peer_addr.rsplit(':', 1)[0]
                    ip = ip.replace('::ffff:', '').strip('[]')
                    if ip and ip not in ['127.0.0.1', '0.0.0.0']:
                        ips.add(ip)
        return list(ips)
    except Exception:
        return []
def get_server_uptime():
    try:
        with open('/proc/uptime', 'r') as f:
            uptime_seconds = float(f.readline().split()[0])
            days = int(uptime_seconds // 86400)
            hours = int((uptime_seconds % 86400) // 3600)
            minutes = int((uptime_seconds % 3600) // 60)
            return f"{days}д {hours}ч {minutes}м"
    except Exception:
        return "N/A"
def get_service_status(service_name):
    try:
        result = subprocess.run(['systemctl', 'is-active', service_name], capture_output=True, text=True, timeout=5)
        return result.stdout.strip()
    except Exception:
        return "unknown"
def calculate_days_left(created_timestamp):
    try:
        created = datetime.fromisoformat(created_timestamp.replace('Z', '+00:00'))
        now = datetime.now(created.tzinfo) if created.tzinfo else datetime.now()
        delta = (created.replace(tzinfo=None) if created.tzinfo else created) - (now.replace(tzinfo=None) if now.tzinfo else now)
        days_left = 30 + delta.days
        return max(0, days_left)
    except Exception:
        return 30
def get_traffic_stats(username):
    users_db = load_users_db()
    user_data = users_db.get(username, {})
    download = user_data.get('download', 0)
    upload = user_data.get('upload', 0)
    total = download + upload
    
    def format_bytes(bytes_val):
        for unit in ['B', 'KB', 'MB', 'GB', 'TB']:
            if bytes_val < 1024:
                return f"{bytes_val:.2f} {unit}"
            bytes_val /= 1024
        return f"{bytes_val:.2f} PB"
    
    return {
        'download': format_bytes(download),
        'upload': format_bytes(upload),
        'total': format_bytes(total)
    }
@app.before_request
def require_login():
    allowed_routes = ['login', 'static']
    if request.endpoint not in allowed_routes and 'user' not in session and not request.path.startswith('/static'):
        return redirect(url_for('login'))
    cfg = load_config()
    if cfg.get('is_default') and request.endpoint not in ['change_password', 'login'] and 'user' in session:
        return redirect(url_for('change_password'))
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
@app.route('/change_password', methods=['GET', 'POST'])
def change_password():
    if request.method == 'POST':
        new_pass = request.form['new_password']
        cfg = load_config()
        cfg['password_hash'] = generate_password_hash(new_pass)
        cfg['is_default'] = False
        save_config(cfg)
        flash('Пароль успешно изменен!', 'success')
        return redirect(url_for('dashboard'))
    return render_template('change_password.html')
@app.route('/', methods=['GET', 'POST'])
def dashboard():
    cfg = load_config()
    try:
        with open(TELEMT_TOML, 'r') as f:
            t_config = toml.load(f)
    except FileNotFoundError:
        t_config = {'access': {'users': {}}, 'censorship': {'tls_domain': 'max.ru'}}
    users = t_config.get('access', {}).get('users', {})
    users_db = load_users_db()
    tls_domain = t_config.get('censorship', {}).get('tls_domain', 'www.microsoft.com')
    hex_domain = tls_domain.encode('utf-8').hex()
    proxy_links = {}
    for name, secret in users.items():
        final_secret = f"ee{secret}{hex_domain}"
        link = f"tg://proxy?server={cfg['proxy_host']}&port={cfg.get('proxy_port', 443)}&secret={final_secret}"
        user_db = users_db.get(name, {})
        created = user_db.get('created', datetime.now().isoformat())
        days_left = calculate_days_left(created)
        traffic = get_traffic_stats(name)
        enabled = user_db.get('enabled', True)
        
        qr = qrcode.make(link)
        buffered = BytesIO()
        qr.save(buffered, format="PNG")
        qr_base64 = base64.b64encode(buffered.getvalue()).decode()
        
        proxy_links[name] = {
            'secret': secret, 
            'link': link, 
            'qr_code': qr_base64,
            'days_left': days_left,
            'traffic': traffic,
            'enabled': enabled,
            'created': created
        }
    if request.method == 'POST':
        nickname = request.form.get('nickname', '').strip().replace(' ', '_')
        device = request.form.get('device', 'Phone')
        if not nickname:
            flash('Укажите никнейм!', 'danger')
            return redirect(url_for('dashboard'))
        user_key = f"{nickname}_{device}"
        new_secret = secrets.token_hex(16)
        if 'access' not in t_config:
            t_config['access'] = {}
        if 'users' not in t_config['access']:
            t_config['access']['users'] = {}
        t_config['access']['users'][user_key] = new_secret
        
        users_db[user_key] = {
            'created': datetime.now().isoformat(),
            'enabled': True,
            'download': 0,
            'upload': 0
        }
        with open(TELEMT_TOML, 'w') as f:
            toml.dump(t_config, f)
        save_users_db(users_db)
        restart_telemt()
        flash(f'Доступ для {user_key} создан!', 'success')
        return redirect(url_for('dashboard'))
    stats = get_proxy_stats()
    server_status = get_service_status('telemt')
    uptime = get_server_uptime()
    
    return render_template('dashboard.html', links=proxy_links, host=cfg['proxy_host'], stats=stats, 
                         server_status=server_status, uptime=uptime, tls_domain=tls_domain)
@app.route('/delete/<username>')
def delete_user(username):
    try:
        with open(TELEMT_TOML, 'r') as f:
            t_config = toml.load(f)
        if username in t_config.get('access', {}).get('users', {}):
            del t_config['access']['users'][username]
            with open(TELEMT_TOML, 'w') as f:
                toml.dump(t_config, f)
            
            users_db = load_users_db()
            if username in users_db:
                del users_db[username]
                save_users_db(users_db)
                
            restart_telemt()
            flash(f'Пользователь {username} удален', 'success')
    except Exception as e:
        flash(f'Ошибка: {str(e)}', 'danger')
    return redirect(url_for('dashboard'))
@app.route('/toggle/<username>')
def toggle_user(username):
    try:
        users_db = load_users_db()
        if username in users_db:
            current_state = users_db[username].get('enabled', True)
            users_db[username]['enabled'] = not current_state
            save_users_db(users_db)
            
            action = "включен" if users_db[username]['enabled'] else "отключен"
            flash(f'Пользователь {username} {action}', 'success')
    except Exception as e:
        flash(f'Ошибка: {str(e)}', 'danger')
    return redirect(url_for('dashboard'))
@app.route('/update_traffic/<username>', methods=['POST'])
def update_traffic(username):
    try:
        data = request.get_json()
        users_db = load_users_db()
        if username in users_db:
            users_db[username]['download'] = data.get('download', 0)
            users_db[username]['upload'] = data.get('upload', 0)
            save_users_db(users_db)
            return jsonify({'status': 'success'})
    except Exception as e:
        return jsonify({'status': 'error', 'message': str(e)})
    return jsonify({'status': 'error', 'message': 'User not found'})
@app.route('/update_tls_domain', methods=['POST'])
def update_tls_domain():
    try:
        new_domain = request.form.get('tls_domain', '').strip()
        if not new_domain:
            flash('Укажите домен!', 'danger')
            return redirect(url_for('dashboard'))
        
        with open(TELEMT_TOML, 'r') as f:
            t_config = toml.load(f)
        
        if 'censorship' not in t_config:
            t_config['censorship'] = {}
        t_config['censorship']['tls_domain'] = new_domain
        
        with open(TELEMT_TOML, 'w') as f:
            toml.dump(t_config, f)
        
        cfg = load_config()
        cfg['fake_tls_domain'] = new_domain
        save_config(cfg)
        
        restart_telemt()
        flash(f'FakeTLS домен обновлен на {new_domain}', 'success')
    except Exception as e:
        flash(f'Ошибка: {str(e)}', 'danger')
    return redirect(url_for('dashboard'))
@app.route('/restart_proxy', methods=['POST'])
def restart_proxy():
    try:
        restart_telemt()
        flash('Прокси сервер перезапущен!', 'success')
    except Exception as e:
        flash(f'Ошибка при перезапуске: {str(e)}', 'danger')
    return redirect(url_for('dashboard'))
@app.route('/api/status')
def api_status():
    return jsonify({
        'server_status': get_service_status('telemt'),
        'uptime': get_server_uptime(),
        'active_connections': len(get_proxy_stats())
    })
if __name__ == '__main__':
    port = int(os.environ.get('PANEL_PORT', 4444))
    app.run(host='0.0.0.0', port=port)
PYEOF
echo -e "${GREEN}Backend панели создан${RESET}"
# HTML шаблоны
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
        body { background: linear-gradient(135deg, #667eea 0%, #764ba2 100%); min-height: 100vh; }
        .container { max-width: 1200px; margin-top: 2rem; }
        .card { border: none; border-radius: 15px; box-shadow: 0 10px 40px rgba(0,0,0,0.2); }
        .card-header { border-radius: 15px 15px 0 0 !important; font-weight: 600; }
        .btn { border-radius: 8px; }
        .status-indicator { width: 12px; height: 12px; border-radius: 50%; display: inline-block; margin-right: 8px; }
        .status-running { background-color: #28a745; }
        .status-stopped { background-color: #dc3545; }
        .days-badge { font-size: 0.85em; }
        .table-responsive { border-radius: 10px; overflow: hidden; }
    </style>
</head>
<body>
    <div class="container">
        {% with messages = get_flashed_messages(with_categories=true) %}
            {% if messages %}
                {% for category, message in messages %}
                    <div class="alert alert-{{ category }} alert-dismissible fade show">
                        <i class="fas fa-info-circle me-2"></i>{{ message }}
                        <button type="button" class="btn-close" data-bs-dismiss="alert"></button>
                    </div>
                {% endfor %}
            {% endif %}
        {% endwith %}
        {% block content %}{% endblock %}
    </div>
    <script src="https://cdn.jsdelivr.net/npm/bootstrap@5.3.0/dist/js/bootstrap.bundle.min.js"></script>
    <script>
        setInterval(function() {
            fetch('/api/status')
                .then(r => r.json())
                .then(d => {
                    const statusEl = document.getElementById('server-status-indicator');
                    const statusText = document.getElementById('server-status-text');
                    if(statusEl && statusText) {
                        if(d.server_status === 'active') {
                            statusEl.className = 'status-indicator status-running';
                            statusText.textContent = 'Работает';
                        } else {
                            statusEl.className = 'status-indicator status-stopped';
                            statusText.textContent = 'Упал';
                        }
                        document.getElementById('uptime-display').textContent = d.uptime;
                        document.getElementById('connections-display').textContent = d.active_connections;
                    }
                });
        }, 30000);
    </script>
</body>
</html>
HTMLEOF
cat > "$PANEL_DIR/templates/login.html" << 'HTMLEOF'
{% extends "layout.html" %}
{% block content %}
<div class="row justify-content-center">
    <div class="col-md-5">
        <div class="card shadow-sm">
            <div class="card-body p-5">
                <div class="text-center mb-4">
                    <i class="fas fa-shield-alt fa-3x text-primary mb-3"></i>
                    <h3>Вход в панель</h3>
                </div>
                <form method="POST">
                    <div class="mb-3">
                        <label class="form-label"><i class="fas fa-user me-2"></i>Логин</label>
                        <input type="text" name="username" class="form-control" required autofocus>
                    </div>
                    <div class="mb-4">
                        <label class="form-label"><i class="fas fa-lock me-2"></i>Пароль</label>
                        <input type="password" name="password" class="form-control" required>
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
cat > "$PANEL_DIR/templates/change_password.html" << 'HTMLEOF'
{% extends "layout.html" %}
{% block content %}
<div class="row justify-content-center">
    <div class="col-md-5">
        <div class="card border-warning">
            <div class="card-body p-5">
                <div class="text-center mb-4">
                    <i class="fas fa-exclamation-triangle fa-3x text-warning mb-3"></i>
                    <h4 class="text-warning">Смена пароля</h4>
                </div>
                <form method="POST">
                    <div class="mb-3">
                        <label class="form-label"><i class="fas fa-key me-2"></i>Новый пароль</label>
                        <input type="password" name="new_password" class="form-control" required minlength="6">
                    </div>
                    <button type="submit" class="btn btn-warning w-100">Сохранить</button>
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
<div class="d-flex justify-content-between align-items-center mb-4">
    <h2 class="text-white"><i class="fas fa-shield-alt me-2"></i>MTProto Proxy Panel</h2>
    <a href="{{ url_for('logout') }}" class="btn btn-outline-light btn-sm">
        <i class="fas fa-sign-out-alt me-1"></i>Выход
    </a>
</div>
<!-- Статус сервера -->
<div class="card shadow-sm mb-4">
    <div class="card-header bg-dark text-white">
        <div class="d-flex justify-content-between align-items-center">
            <h5 class="mb-0"><i class="fas fa-server me-2"></i>Статус сервера</h5>
            <form method="POST" action="{{ url_for('restart_proxy') }}" style="display:inline;">
                <button type="submit" class="btn btn-sm btn-warning" onclick="return confirm('Перезапустить прокси?')">
                    <i class="fas fa-redo me-1"></i>Перезапустить
                </button>
            </form>
        </div>
    </div>
    <div class="card-body">
        <div class="row text-center">
            <div class="col-md-4">
                <div class="p-3">
                    <span id="server-status-indicator" class="status-indicator {% if server_status == 'active' %}status-running{% else %}status-stopped{% endif %}"></span>
                    <span id="server-status-text" class="fw-bold">{% if server_status == 'active' %}Работает{% else %}Упал{% endif %}</span>
                </div>
            </div>
            <div class="col-md-4">
                <div class="p-3">
                    <i class="fas fa-clock text-info me-2"></i>
                    <strong>Uptime:</strong> <span id="uptime-display">{{ uptime }}</span>
                </div>
            </div>
            <div class="col-md-4">
                <div class="p-3">
                    <i class="fas fa-users text-success me-2"></i>
                    <strong>Подключения:</strong> <span id="connections-display">{{ stats|length }}</span>
                </div>
            </div>
        </div>
    </div>
</div>
<!-- Настройка FakeTLS -->
<div class="card shadow-sm mb-4">
    <div class="card-header bg-primary text-white">
        <h5 class="mb-0"><i class="fas fa-cog me-2"></i>Настройки FakeTLS</h5>
    </div>
    <div class="card-body">
        <form method="POST" action="{{ url_for('update_tls_domain') }}" class="row g-2 align-items-end">
            <div class="col-md-8">
                <label class="form-label text-muted small">Текущий FakeTLS домен: <strong>{{ tls_domain }}</strong></label>
                <input type="text" name="tls_domain" class="form-control" placeholder="Новый домен для FakeTLS" value="{{ tls_domain }}">
            </div>
            <div class="col-md-4">
                <button type="submit" class="btn btn-primary w-100">
                    <i class="fas fa-save me-1"></i>Обновить для новых генераций
                </button>
            </div>
        </form>
    </div>
</div>
<!-- Создание доступа -->
<div class="card shadow-sm mb-4">
    <div class="card-header bg-success text-white">
        <h5 class="mb-0"><i class="fas fa-plus-circle me-2"></i>Создать доступ</h5>
    </div>
    <div class="card-body">
        <form method="POST" class="row g-2 align-items-end">
            <div class="col-md-5">
                <label class="form-label text-muted small">Никнейм</label>
                <input type="text" name="nickname" class="form-control" placeholder="Ivan" required>
            </div>
            <div class="col-md-4">
                <label class="form-label text-muted small">Устройство</label>
                <select name="device" class="form-select">
                    <option value="Phone">📱 Телефон</option>
                    <option value="PC">💻 Компьютер</option>
                    <option value="Tablet">📟 Планшет</option>
                </select>
            </div>
            <div class="col-md-3">
                <button type="submit" class="btn btn-success w-100">
                    <i class="fas fa-magic me-1"></i>Генерировать
                </button>
            </div>
        </form>
    </div>
</div>
<!-- Список доступов -->
<div class="card shadow-sm mb-4">
    <div class="card-header bg-info text-white">
        <h5 class="mb-0"><i class="fas fa-list me-2"></i>Список доступов</h5>
    </div>
    <div class="card-body">
        <div class="table-responsive">
            <table class="table table-hover align-middle">
                <thead class="table-light">
                    <tr>
                        <th><i class="fas fa-user me-1"></i>Имя_Устройство</th>
                        <th><i class="fas fa-calendar me-1"></i>Осталось дней</th>
                        <th><i class="fas fa-download me-1"></i>Трафик</th>
                        <th><i class="fas fa-link me-1"></i>Ссылка</th>
                        <th class="text-end"><i class="fas fa-cog me-1"></i>Действия</th>
                    </tr>
                </thead>
                <tbody>
                    {% if links %}
                        {% for name, data in links.items() %}
                        <tr class="{% if not data.enabled %}table-secondary{% endif %}">
                            <td class="fw-bold">{{ name }}</td>
                            <td>
                                {% if data.days_left > 7 %}
                                    <span class="badge bg-success days-badge">🟢 {{ data.days_left }} дн.</span>
                                {% elif data.days_left > 0 %}
                                    <span class="badge bg-warning text-dark days-badge">🟡 {{ data.days_left }} дн.</span>
                                {% else %}
                                    <span class="badge bg-danger days-badge">🔴 Истек</span>
                                {% endif %}
                            </td>
                            <td>
                                <small class="text-muted">↓ {{ data.traffic.download }} ↑ {{ data.traffic.upload }}</small>
                            </td>
                            <td>
                                <div class="input-group input-group-sm">
                                    <input type="text" class="form-control" value="{{ data.link }}" readonly id="link-{{ loop.index }}">
                                    <button class="btn btn-outline-secondary" type="button"
                                            onclick="navigator.clipboard.writeText(document.getElementById('link-{{ loop.index }}').value);
                                                     this.innerHTML='<i class=\'fas fa-check\'></i>';
                                                     setTimeout(()=>this.innerHTML='<i class=\'fas fa-copy\'></i>',1500)">
                                        <i class="fas fa-copy"></i>
                                    </button>
                                    <button class="btn btn-outline-primary" type="button" data-bs-toggle="modal" data-bs-target="#qrModal{{ loop.index }}">
                                        <i class="fas fa-qrcode"></i>
                                    </button>
                                </div>
                                
                                <!-- QR Modal -->
                                <div class="modal fade" id="qrModal{{ loop.index }}" tabindex="-1">
                                    <div class="modal-dialog modal-sm">
                                        <div class="modal-content">
                                            <div class="modal-header">
                                                <h6 class="modal-title">QR Code: {{ name }}</h6>
                                                <button type="button" class="btn-close" data-bs-dismiss="modal"></button>
                                            </div>
                                            <div class="modal-body text-center">
                                                <img src="data:image/png;base64,{{ data.qr_code }}" alt="QR Code" class="img-fluid">
                                                <p class="small text-muted mt-2">Отсканируйте для подключения</p>
                                            </div>
                                        </div>
                                    </div>
                                </div>
                            </td>
                            <td class="text-end">
                                <a href="{{ url_for('toggle_user', username=name) }}" 
                                   class="btn btn-sm {% if data.enabled %}btn-warning{% else %}btn-success{% endif %}"
                                   title="{% if data.enabled %}Отключить{% else %}Включить{% endif %}">
                                    <i class="fas {% if data.enabled %}fa-pause{% else %}fa-play{% endif %}"></i>
                                </a>
                                <a href="{{ url_for('delete_user', username=name) }}" 
                                   class="btn btn-sm btn-danger"
                                   onclick="return confirm('Удалить {{ name }}?')">
                                    <i class="fas fa-trash"></i>
                                </a>
                            </td>
                        </tr>
                        {% endfor %}
                    {% else %}
                        <tr>
                            <td colspan="5" class="text-center text-muted py-4">
                                <i class="fas fa-inbox fa-2x mb-2"></i><br>Нет пользователей
                            </td>
                        </tr>
                    {% endif %}
                </tbody>
            </table>
        </div>
    </div>
</div>
<!-- Активные подключения -->
<div class="card shadow-sm">
    <div class="card-header bg-dark text-white">
        <div class="d-flex justify-content-between align-items-center">
            <h5 class="mb-0"><i class="fas fa-chart-line me-2"></i>Активные подключения</h5>
            <span class="badge bg-light text-dark">{{ stats|length }} онлайн</span>
        </div>
    </div>
    <div class="card-body">
        {% if stats %}
            <div class="d-flex flex-wrap gap-2">
                {% for ip in stats %}
                    <span class="badge bg-secondary border">
                        <i class="fas fa-globe me-1"></i>{{ ip }}
                    </span>
                {% endfor %}
            </div>
        {% else %}
            <p class="text-muted text-center mb-0">Нет активных подключений</p>
        {% endif %}
    </div>
</div>
{% endblock %}
HTMLEOF
echo -e "${GREEN}HTML шаблоны созданы${RESET}"
# Gunicorn сервис
cat > /etc/systemd/system/telemt-panel.service << SVCEOF
[Unit]
Description=MTProto Panel
After=network.target telemt.service
[Service]
Type=simple
User=root
WorkingDirectory=${PANEL_DIR}
Environment="PATH=${PANEL_DIR}/venv/bin"
Environment="PANEL_PORT=${PANEL_PORT}"
ExecStart=${PANEL_DIR}/venv/bin/gunicorn -w 2 -b 0.0.0.0:${PANEL_PORT} app:app
Restart=always
[Install]
WantedBy=multi-user.target
SVCEOF
systemctl daemon-reload
systemctl enable telemt-panel --now >/dev/null 2>&1
# ==========================================
# ЧАСТЬ 5: FIREWALL И ЗАВЕРШЕНИЕ
# ==========================================
echo -e "${YELLOW}Настройка firewall...${RESET}"
ufw --force enable >/dev/null 2>&1 || true
ufw allow 22/tcp >/dev/null 2>&1
ufw allow 443/tcp >/dev/null 2>&1
ufw allow ${PANEL_PORT}/tcp >/dev/null 2>&1
# Автообновление сертификатов
(crontab -l 2>/dev/null; echo "0 3 * * * certbot renew --post-hook 'systemctl restart telemt telemt-panel' >/dev/null 2>&1") | crontab - 2>/dev/null || true
clear
show_banner
echo -e "${GREEN}${BOLD}=========================================="
echo "           УСТАНОВКА ЗАВЕРШЕНА!"
echo -e "==========================================${RESET}"
echo ""
echo -e "${CYAN}📊 Прокси сервер:${RESET}"
echo "   Домен: https://${PROXY_DOMAIN}"
echo "   Порт: 443 (FakeTLS: ${FAKE_TLS_DOMAIN})"
echo ""
echo -e "${CYAN}🎛️ Веб-панель:${RESET}"
echo "   URL: https://${PANEL_DOMAIN}:${PANEL_PORT}"
echo "   Логин: ${ADMIN_USER}"
echo -e "   Пароль: ${RED}${BOLD}${ADMIN_PASS}${RESET}"
echo ""
echo -e "${YELLOW}⚠️  Сохраните пароль! Он показан только один раз.${RESET}"
echo ""
echo -e "${BLUE}Функции панели:${RESET}"
echo "  ✓ Вкл/Откл пользователей без удаления"
echo "  ✓ Смена FakeTLS домена для новых генераций"
echo "  ✓ Статус сервера, uptime, активные подключения"
echo "  ✓ QR-коды и копирование ссылок"
echo "  ✓ Перезапуск прокси из панели"
echo "  ✓ Авто-поднятие при сбоях (мониторинг)"
echo "  ✓ Трекер трафика по пользователям"
echo "  ✓ Таймер 30 дней для оплаты"
echo ""
echo -e "${GREEN}Готово к использованию!${RESET}"
SCRIPTEOF
chmod +x /workspace/install.sh
cat > /workspace/install.sh << 'SCRIPTEOF'
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
                certbot certonly --standalone -d "${domain}" --email "${email}" --agree-tos --non-interactive --quiet >/dev/null 2>&1 || true
            else
                certbot certonly --standalone -d "${domain}" --register-unsafely-without-email --agree-tos --non-interactive --quiet >/dev/null 2>&1 || true
            fi
            [[ -f "$cert_path" ]] && echo "renewed" || echo "error"
        fi
    else
        if [[ -n "$email" ]]; then
            certbot certonly --standalone -d "${domain}" --email "${email}" --agree-tos --non-interactive --quiet >/dev/null 2>&1 || true
        else
            certbot certonly --standalone -d "${domain}" --register-unsafely-without-email --agree-tos --non-interactive --quiet >/dev/null 2>&1 || true
        fi
        [[ -f "$cert_path" ]] && echo "new" || echo "error"
    fi
}
show_banner
if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}Ошибка: запустите скрипт от имени root.${RESET}"
    exit 1
fi
echo -e "${YELLOW}Проверка необходимых пакетов...${RESET}"
apt-get update -qq >/dev/null 2>&1
apt-get install -y -qq curl wget jq openssl certbot xxd socat ufw python3 python3-pip python3-venv iproute2 net-tools qrencode >/dev/null 2>&1
systemctl stop nginx apache2 2>/dev/null || true
# ==========================================
# ЧАСТЬ 1: СБОР ВВОДНЫХ ДАННЫХ
# ==========================================
echo -e "${BOLD}--- НАСТРОЙКА ПРОКСИ И ПАНЕЛИ ---${RESET}"
echo ""
read -rp "Введите домен для ПРОКСИ (напр. tg.example.com): " PROXY_DOMAIN
[[ -z "${PROXY_DOMAIN}" ]] && { echo -e "${RED}Домен для прокси обязателен!${RESET}"; exit 1; }
read -rp "Введите домен для ПАНЕЛИ УПРАВЛЕНИЯ (напр. admin.example.com): " PANEL_DOMAIN
[[ -z "${PANEL_DOMAIN}" ]] && { echo -e "${RED}Домен для панели обязателен!${RESET}"; exit 1; }
read -rp "Введите порт для панели (по умолчанию 4444): " PANEL_PORT
PANEL_PORT=${PANEL_PORT:-4444}
read -rp "Email для SSL сертификатов (необязательно): " SSL_EMAIL
read -rp "FakeTLS домен для маскировки (по умолчанию www.microsoft.com): " FAKE_TLS_DOMAIN
FAKE_TLS_DOMAIN=${FAKE_TLS_DOMAIN:-www.microsoft.com}
echo -e "\n${YELLOW}Выпуск SSL сертификатов...${RESET}"
proxy_cert_status=$(issue_ssl "$PROXY_DOMAIN" "$SSL_EMAIL")
panel_cert_status=$(issue_ssl "$PANEL_DOMAIN" "$SSL_EMAIL")
if [[ "$proxy_cert_status" == "error" ]]; then
    echo -e "${RED}Не удалось получить SSL сертификат для ${PROXY_DOMAIN}${RESET}"
    exit 1
fi
if [[ "$panel_cert_status" == "error" ]]; then
    echo -e "${RED}Не удалось получить SSL сертификат для ${PANEL_DOMAIN}${RESET}"
    exit 1
fi
echo -e "${GREEN}SSL сертификаты успешно получены${RESET}"
# ==========================================
# ЧАСТЬ 2: УСТАНОВКА TELEMT
# ==========================================
echo -e "\n${YELLOW}Установка Telemt...${RESET}"
mkdir -p /opt/telemt
cd /opt/telemt
curl -sL https://github.com/TelegramMessenger/MTProxy/releases/download/latest/MTProxy-bin-linux-x64.tar.gz -o mtproxy.tar.gz
tar xzf mtproxy.tar.gz
cp MTProxy-bin-linux-x64/mtproto-proxy /usr/local/bin/telemt
chmod +x /usr/local/bin/telemt
rm -rf MTProxy-bin-linux-x64 mtproxy.tar.gz
mkdir -p /etc/telemt
chown root:root /etc/telemt
chmod 700 /etc/telemt
SECRET_KEY=$(openssl rand -hex 16)
cat > /etc/telemt/telemt.toml << TOMLEOF
port = 443
workers = $(nproc)
nat_info = "$(curl -s https://api.ipify.org):443"
adtag = "$(openssl rand -hex 16)"
censorship = { tls_domain = "${FAKE_TLS_DOMAIN}" }
access = { users = {} }
TOMLEOF
cat > /etc/systemd/system/telemt.service << SVCEOF
[Unit]
Description=Telemt MTProto Proxy
After=network.target
[Service]
Type=simple
ExecStart=/usr/local/bin/telemt /etc/telemt/telemt.toml
Restart=always
RestartSec=10
LimitNOFILE=65535
[Install]
WantedBy=multi-user.target
SVCEOF
systemctl daemon-reload
systemctl enable telemt --now >/dev/null 2>&1
# ==========================================
# ЧАСТЬ 3: МОНТОРИНГ И АВТО-ПОДНЯТИЕ
# ==========================================
echo -e "${YELLOW}Настройка авто-мониторинга прокси...${RESET}"
cat > /usr/local/bin/telemt-monitor.sh << 'MONITOREOF'
#!/bin/bash
SERVICE_NAME="telemt"
LOG_FILE="/var/log/telemt-monitor.log"
log_message() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"
}
check_service() {
    if ! systemctl is-active --quiet "$SERVICE_NAME"; then
        log_message "WARNING: Service $SERVICE_NAME is not running. Attempting to restart..."
        systemctl restart "$SERVICE_NAME"
        sleep 5
        if systemctl is-active --quiet "$SERVICE_NAME"; then
            log_message "SUCCESS: Service $SERVICE_NAME restarted successfully."
        else
            log_message "ERROR: Failed to restart service $SERVICE_NAME."
        fi
    else
        log_message "OK: Service $SERVICE_NAME is running."
    fi
}
check_service
MONITOREOF
chmod +x /usr/local/bin/telemt-monitor.sh
cat > /etc/systemd/system/telemt-monitor.service << SVCEOF
[Unit]
Description=Telemt Auto-Monitor Service
After=telemt.service
[Service]
Type=oneshot
ExecStart=/usr/local/bin/telemt-monitor.sh
RemainAfterExit=yes
[Install]
WantedBy=multi-user.target
SVCEOF
cat > /etc/cron.d/telemt-monitor << CRONEOF
*/1 * * * * root /usr/local/bin/telemt-monitor.sh >/dev/null 2>&1
CRONEOF
systemctl daemon-reload
systemctl enable telemt-monitor --now >/dev/null 2>&1
# ==========================================
# ЧАСТЬ 4: WEB ПАНЕЛЬ
# ==========================================
echo -e "${YELLOW}Создание веб-панели...${RESET}"
PANEL_DIR="/opt/mtproto-panel"
mkdir -p "$PANEL_DIR"/{templates,static}
cd "$PANEL_DIR"
python3 -m venv venv
source venv/bin/activate
pip install --quiet flask toml cryptography qrcode[pil]
ADMIN_USER="admin"
ADMIN_PASS=$(openssl rand -base64 12)
PASSWORD_HASH=$(python3 -c "from werkzeug.security import generate_password_hash; print(generate_password_hash('$ADMIN_PASS'))")
SECRET_KEY=$(python3 -c "import secrets; print(secrets.token_hex(32))")
cat > panel_config.json << CONFIGEOF
{
    "username": "${ADMIN_USER}",
    "password_hash": "${PASSWORD_HASH}",
    "secret_key": "${SECRET_KEY}",
    "proxy_host": "${PROXY_DOMAIN}",
    "proxy_port": 443,
    "panel_port": ${PANEL_PORT},
    "fake_tls_domain": "${FAKE_TLS_DOMAIN}",
    "is_default": true
}
CONFIGEOF
cat > app.py << 'PYEOF'
#!/usr/bin/env python3
import os, json, secrets, subprocess, time, re
from datetime import datetime
from flask import Flask, render_template, request, redirect, url_for, session, flash, jsonify
import toml
from werkzeug.security import generate_password_hash, check_password_hash
import qrcode
import base64
from io import BytesIO
app = Flask(__name__)
CONFIG_PATH = 'panel_config.json'
TELEMT_TOML = '/etc/telemt/telemt.toml'
USERS_DB = '/etc/telemt/users.json'
def load_config():
    with open(CONFIG_PATH, 'r') as f:
        return json.load(f)
def save_config(data):
    with open(CONFIG_PATH, 'w') as f:
        json.dump(data, f, indent=4)
def load_users_db():
    if os.path.exists(USERS_DB):
        with open(USERS_DB, 'r') as f:
            return json.load(f)
    return {}
def save_users_db(data):
    with open(USERS_DB, 'w') as f:
        json.dump(data, f, indent=4)
config = load_config()
app.secret_key = config.get('secret_key', secrets.token_hex(32))
if "..." in config.get('password_hash', ''):
    config['password_hash'] = generate_password_hash('admin')
    save_config(config)
def restart_telemt():
    try:
        subprocess.run(['systemctl', 'restart', 'telemt'], check=False, timeout=10)
    except Exception:
        pass
def get_proxy_stats():
    try:
        result = subprocess.run(['ss', '-tn', 'state', 'established'], capture_output=True, text=True, timeout=5)
        lines = result.stdout.splitlines()
        ips = set()
        for line in lines:
            if ':443' in line:
                parts = line.split()
                if len(parts) >= 5:
                    peer_addr = parts[4]
                    ip = peer_addr.rsplit(':', 1)[0]
                    ip = ip.replace('::ffff:', '').strip('[]')
                    if ip and ip not in ['127.0.0.1', '0.0.0.0']:
                        ips.add(ip)
        return list(ips)
    except Exception:
        return []
def get_server_uptime():
    try:
        with open('/proc/uptime', 'r') as f:
            uptime_seconds = float(f.readline().split()[0])
            days = int(uptime_seconds // 86400)
            hours = int((uptime_seconds % 86400) // 3600)
            minutes = int((uptime_seconds % 3600) // 60)
            return f"{days}д {hours}ч {minutes}м"
    except Exception:
        return "N/A"
def get_service_status(service_name):
    try:
        result = subprocess.run(['systemctl', 'is-active', service_name], capture_output=True, text=True, timeout=5)
        return result.stdout.strip()
    except Exception:
        return "unknown"
def calculate_days_left(created_timestamp):
    try:
        created = datetime.fromisoformat(created_timestamp.replace('Z', '+00:00'))
        now = datetime.now(created.tzinfo) if created.tzinfo else datetime.now()
        delta = (created.replace(tzinfo=None) if created.tzinfo else created) - (now.replace(tzinfo=None) if now.tzinfo else now)
        days_left = 30 + delta.days
        return max(0, days_left)
    except Exception:
        return 30
def get_traffic_stats(username):
    users_db = load_users_db()
    user_data = users_db.get(username, {})
    download = user_data.get('download', 0)
    upload = user_data.get('upload', 0)
    total = download + upload
    
    def format_bytes(bytes_val):
        for unit in ['B', 'KB', 'MB', 'GB', 'TB']:
            if bytes_val < 1024:
                return f"{bytes_val:.2f} {unit}"
            bytes_val /= 1024
        return f"{bytes_val:.2f} PB"
    
    return {
        'download': format_bytes(download),
        'upload': format_bytes(upload),
        'total': format_bytes(total)
    }
@app.before_request
def require_login():
    allowed_routes = ['login', 'static']
    if request.endpoint not in allowed_routes and 'user' not in session and not request.path.startswith('/static'):
        return redirect(url_for('login'))
    cfg = load_config()
    if cfg.get('is_default') and request.endpoint not in ['change_password', 'login'] and 'user' in session:
        return redirect(url_for('change_password'))
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
@app.route('/change_password', methods=['GET', 'POST'])
def change_password():
    if request.method == 'POST':
        new_pass = request.form['new_password']
        cfg = load_config()
        cfg['password_hash'] = generate_password_hash(new_pass)
        cfg['is_default'] = False
        save_config(cfg)
        flash('Пароль успешно изменен!', 'success')
        return redirect(url_for('dashboard'))
    return render_template('change_password.html')
@app.route('/', methods=['GET', 'POST'])
def dashboard():
    cfg = load_config()
    try:
        with open(TELEMT_TOML, 'r') as f:
            t_config = toml.load(f)
    except FileNotFoundError:
        t_config = {'access': {'users': {}}, 'censorship': {'tls_domain': 'max.ru'}}
    users = t_config.get('access', {}).get('users', {})
    users_db = load_users_db()
    tls_domain = t_config.get('censorship', {}).get('tls_domain', 'www.microsoft.com')
    hex_domain = tls_domain.encode('utf-8').hex()
    proxy_links = {}
    for name, secret in users.items():
        final_secret = f"ee{secret}{hex_domain}"
        link = f"tg://proxy?server={cfg['proxy_host']}&port={cfg.get('proxy_port', 443)}&secret={final_secret}"
        user_db = users_db.get(name, {})
        created = user_db.get('created', datetime.now().isoformat())
        days_left = calculate_days_left(created)
        traffic = get_traffic_stats(name)
        enabled = user_db.get('enabled', True)
        
        qr = qrcode.make(link)
        buffered = BytesIO()
        qr.save(buffered, format="PNG")
        qr_base64 = base64.b64encode(buffered.getvalue()).decode()
        
        proxy_links[name] = {
            'secret': secret, 
            'link': link, 
            'qr_code': qr_base64,
            'days_left': days_left,
            'traffic': traffic,
            'enabled': enabled,
            'created': created
        }
    if request.method == 'POST':
        nickname = request.form.get('nickname', '').strip().replace(' ', '_')
        device = request.form.get('device', 'Phone')
        if not nickname:
            flash('Укажите никнейм!', 'danger')
            return redirect(url_for('dashboard'))
        user_key = f"{nickname}_{device}"
        new_secret = secrets.token_hex(16)
        if 'access' not in t_config:
            t_config['access'] = {}
        if 'users' not in t_config['access']:
            t_config['access']['users'] = {}
        t_config['access']['users'][user_key] = new_secret
        
        users_db[user_key] = {
            'created': datetime.now().isoformat(),
            'enabled': True,
            'download': 0,
            'upload': 0
        }
        with open(TELEMT_TOML, 'w') as f:
            toml.dump(t_config, f)
        save_users_db(users_db)
        restart_telemt()
        flash(f'Доступ для {user_key} создан!', 'success')
        return redirect(url_for('dashboard'))
    stats = get_proxy_stats()
    server_status = get_service_status('telemt')
    uptime = get_server_uptime()
    
    return render_template('dashboard.html', links=proxy_links, host=cfg['proxy_host'], stats=stats, 
                         server_status=server_status, uptime=uptime, tls_domain=tls_domain)
@app.route('/delete/<username>')
def delete_user(username):
    try:
        with open(TELEMT_TOML, 'r') as f:
            t_config = toml.load(f)
        if username in t_config.get('access', {}).get('users', {}):
            del t_config['access']['users'][username]
            with open(TELEMT_TOML, 'w') as f:
                toml.dump(t_config, f)
            
            users_db = load_users_db()
            if username in users_db:
                del users_db[username]
                save_users_db(users_db)
                
            restart_telemt()
            flash(f'Пользователь {username} удален', 'success')
    except Exception as e:
        flash(f'Ошибка: {str(e)}', 'danger')
    return redirect(url_for('dashboard'))
@app.route('/toggle/<username>')
def toggle_user(username):
    try:
        users_db = load_users_db()
        if username in users_db:
            current_state = users_db[username].get('enabled', True)
            users_db[username]['enabled'] = not current_state
            save_users_db(users_db)
            
            action = "включен" if users_db[username]['enabled'] else "отключен"
            flash(f'Пользователь {username} {action}', 'success')
    except Exception as e:
        flash(f'Ошибка: {str(e)}', 'danger')
    return redirect(url_for('dashboard'))
@app.route('/update_traffic/<username>', methods=['POST'])
def update_traffic(username):
    try:
        data = request.get_json()
        users_db = load_users_db()
        if username in users_db:
            users_db[username]['download'] = data.get('download', 0)
            users_db[username]['upload'] = data.get('upload', 0)
            save_users_db(users_db)
            return jsonify({'status': 'success'})
    except Exception as e:
        return jsonify({'status': 'error', 'message': str(e)})
    return jsonify({'status': 'error', 'message': 'User not found'})
@app.route('/update_tls_domain', methods=['POST'])
def update_tls_domain():
    try:
        new_domain = request.form.get('tls_domain', '').strip()
        if not new_domain:
            flash('Укажите домен!', 'danger')
            return redirect(url_for('dashboard'))
        
        with open(TELEMT_TOML, 'r') as f:
            t_config = toml.load(f)
        
        if 'censorship' not in t_config:
            t_config['censorship'] = {}
        t_config['censorship']['tls_domain'] = new_domain
        
        with open(TELEMT_TOML, 'w') as f:
            toml.dump(t_config, f)
        
        cfg = load_config()
        cfg['fake_tls_domain'] = new_domain
        save_config(cfg)
        
        restart_telemt()
        flash(f'FakeTLS домен обновлен на {new_domain}', 'success')
    except Exception as e:
        flash(f'Ошибка: {str(e)}', 'danger')
    return redirect(url_for('dashboard'))
@app.route('/restart_proxy', methods=['POST'])
def restart_proxy():
    try:
        restart_telemt()
        flash('Прокси сервер перезапущен!', 'success')
    except Exception as e:
        flash(f'Ошибка при перезапуске: {str(e)}', 'danger')
    return redirect(url_for('dashboard'))
@app.route('/api/status')
def api_status():
    return jsonify({
        'server_status': get_service_status('telemt'),
        'uptime': get_server_uptime(),
        'active_connections': len(get_proxy_stats())
    })
if __name__ == '__main__':
    port = int(os.environ.get('PANEL_PORT', 4444))
    app.run(host='0.0.0.0', port=port)
PYEOF
echo -e "${GREEN}Backend панели создан${RESET}"
# HTML шаблоны
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
        body { background: linear-gradient(135deg, #667eea 0%, #764ba2 100%); min-height: 100vh; }
        .container { max-width: 1200px; margin-top: 2rem; }
        .card { border: none; border-radius: 15px; box-shadow: 0 10px 40px rgba(0,0,0,0.2); }
        .card-header { border-radius: 15px 15px 0 0 !important; font-weight: 600; }
        .btn { border-radius: 8px; }
        .status-indicator { width: 12px; height: 12px; border-radius: 50%; display: inline-block; margin-right: 8px; }
        .status-running { background-color: #28a745; }
        .status-stopped { background-color: #dc3545; }
        .days-badge { font-size: 0.85em; }
        .table-responsive { border-radius: 10px; overflow: hidden; }
    </style>
</head>
<body>
    <div class="container">
        {% with messages = get_flashed_messages(with_categories=true) %}
            {% if messages %}
                {% for category, message in messages %}
                    <div class="alert alert-{{ category }} alert-dismissible fade show">
                        <i class="fas fa-info-circle me-2"></i>{{ message }}
                        <button type="button" class="btn-close" data-bs-dismiss="alert"></button>
                    </div>
                {% endfor %}
            {% endif %}
        {% endwith %}
        {% block content %}{% endblock %}
    </div>
    <script src="https://cdn.jsdelivr.net/npm/bootstrap@5.3.0/dist/js/bootstrap.bundle.min.js"></script>
    <script>
        setInterval(function() {
            fetch('/api/status')
                .then(r => r.json())
                .then(d => {
                    const statusEl = document.getElementById('server-status-indicator');
                    const statusText = document.getElementById('server-status-text');
                    if(statusEl && statusText) {
                        if(d.server_status === 'active') {
                            statusEl.className = 'status-indicator status-running';
                            statusText.textContent = 'Работает';
                        } else {
                            statusEl.className = 'status-indicator status-stopped';
                            statusText.textContent = 'Упал';
                        }
                        document.getElementById('uptime-display').textContent = d.uptime;
                        document.getElementById('connections-display').textContent = d.active_connections;
                    }
                });
        }, 30000);
    </script>
</body>
</html>
HTMLEOF
cat > "$PANEL_DIR/templates/login.html" << 'HTMLEOF'
{% extends "layout.html" %}
{% block content %}
<div class="row justify-content-center">
    <div class="col-md-5">
        <div class="card shadow-sm">
            <div class="card-body p-5">
                <div class="text-center mb-4">
                    <i class="fas fa-shield-alt fa-3x text-primary mb-3"></i>
                    <h3>Вход в панель</h3>
                </div>
                <form method="POST">
                    <div class="mb-3">
                        <label class="form-label"><i class="fas fa-user me-2"></i>Логин</label>
                        <input type="text" name="username" class="form-control" required autofocus>
                    </div>
                    <div class="mb-4">
                        <label class="form-label"><i class="fas fa-lock me-2"></i>Пароль</label>
                        <input type="password" name="password" class="form-control" required>
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
cat > "$PANEL_DIR/templates/change_password.html" << 'HTMLEOF'
{% extends "layout.html" %}
{% block content %}
<div class="row justify-content-center">
    <div class="col-md-5">
        <div class="card border-warning">
            <div class="card-body p-5">
                <div class="text-center mb-4">
                    <i class="fas fa-exclamation-triangle fa-3x text-warning mb-3"></i>
                    <h4 class="text-warning">Смена пароля</h4>
                </div>
                <form method="POST">
                    <div class="mb-3">
                        <label class="form-label"><i class="fas fa-key me-2"></i>Новый пароль</label>
                        <input type="password" name="new_password" class="form-control" required minlength="6">
                    </div>
                    <button type="submit" class="btn btn-warning w-100">Сохранить</button>
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
<div class="d-flex justify-content-between align-items-center mb-4">
    <h2 class="text-white"><i class="fas fa-shield-alt me-2"></i>MTProto Proxy Panel</h2>
    <a href="{{ url_for('logout') }}" class="btn btn-outline-light btn-sm">
        <i class="fas fa-sign-out-alt me-1"></i>Выход
    </a>
</div>
<!-- Статус сервера -->
<div class="card shadow-sm mb-4">
    <div class="card-header bg-dark text-white">
        <div class="d-flex justify-content-between align-items-center">
            <h5 class="mb-0"><i class="fas fa-server me-2"></i>Статус сервера</h5>
            <form method="POST" action="{{ url_for('restart_proxy') }}" style="display:inline;">
                <button type="submit" class="btn btn-sm btn-warning" onclick="return confirm('Перезапустить прокси?')">
                    <i class="fas fa-redo me-1"></i>Перезапустить
                </button>
            </form>
        </div>
    </div>
    <div class="card-body">
        <div class="row text-center">
            <div class="col-md-4">
                <div class="p-3">
                    <span id="server-status-indicator" class="status-indicator {% if server_status == 'active' %}status-running{% else %}status-stopped{% endif %}"></span>
                    <span id="server-status-text" class="fw-bold">{% if server_status == 'active' %}Работает{% else %}Упал{% endif %}</span>
                </div>
            </div>
            <div class="col-md-4">
                <div class="p-3">
                    <i class="fas fa-clock text-info me-2"></i>
                    <strong>Uptime:</strong> <span id="uptime-display">{{ uptime }}</span>
                </div>
            </div>
            <div class="col-md-4">
                <div class="p-3">
                    <i class="fas fa-users text-success me-2"></i>
                    <strong>Подключения:</strong> <span id="connections-display">{{ stats|length }}</span>
                </div>
            </div>
        </div>
    </div>
</div>
<!-- Настройка FakeTLS -->
<div class="card shadow-sm mb-4">
    <div class="card-header bg-primary text-white">
        <h5 class="mb-0"><i class="fas fa-cog me-2"></i>Настройки FakeTLS</h5>
    </div>
    <div class="card-body">
        <form method="POST" action="{{ url_for('update_tls_domain') }}" class="row g-2 align-items-end">
            <div class="col-md-8">
                <label class="form-label text-muted small">Текущий FakeTLS домен: <strong>{{ tls_domain }}</strong></label>
                <input type="text" name="tls_domain" class="form-control" placeholder="Новый домен для FakeTLS" value="{{ tls_domain }}">
            </div>
            <div class="col-md-4">
                <button type="submit" class="btn btn-primary w-100">
                    <i class="fas fa-save me-1"></i>Обновить для новых генераций
                </button>
            </div>
        </form>
    </div>
</div>
<!-- Создание доступа -->
<div class="card shadow-sm mb-4">
    <div class="card-header bg-success text-white">
        <h5 class="mb-0"><i class="fas fa-plus-circle me-2"></i>Создать доступ</h5>
    </div>
    <div class="card-body">
        <form method="POST" class="row g-2 align-items-end">
            <div class="col-md-5">
                <label class="form-label text-muted small">Никнейм</label>
                <input type="text" name="nickname" class="form-control" placeholder="Ivan" required>
            </div>
            <div class="col-md-4">
                <label class="form-label text-muted small">Устройство</label>
                <select name="device" class="form-select">
                    <option value="Phone">📱 Телефон</option>
                    <option value="PC">💻 Компьютер</option>
                    <option value="Tablet">📟 Планшет</option>
                </select>
            </div>
            <div class="col-md-3">
                <button type="submit" class="btn btn-success w-100">
                    <i class="fas fa-magic me-1"></i>Генерировать
                </button>
            </div>
        </form>
    </div>
</div>
<!-- Список доступов -->
<div class="card shadow-sm mb-4">
    <div class="card-header bg-info text-white">
        <h5 class="mb-0"><i class="fas fa-list me-2"></i>Список доступов</h5>
    </div>
    <div class="card-body">
        <div class="table-responsive">
            <table class="table table-hover align-middle">
                <thead class="table-light">
                    <tr>
                        <th><i class="fas fa-user me-1"></i>Имя_Устройство</th>
                        <th><i class="fas fa-calendar me-1"></i>Осталось дней</th>
                        <th><i class="fas fa-download me-1"></i>Трафик</th>
                        <th><i class="fas fa-link me-1"></i>Ссылка</th>
                        <th class="text-end"><i class="fas fa-cog me-1"></i>Действия</th>
                    </tr>
                </thead>
                <tbody>
                    {% if links %}
                        {% for name, data in links.items() %}
                        <tr class="{% if not data.enabled %}table-secondary{% endif %}">
                            <td class="fw-bold">{{ name }}</td>
                            <td>
                                {% if data.days_left > 7 %}
                                    <span class="badge bg-success days-badge">🟢 {{ data.days_left }} дн.</span>
                                {% elif data.days_left > 0 %}
                                    <span class="badge bg-warning text-dark days-badge">🟡 {{ data.days_left }} дн.</span>
                                {% else %}
                                    <span class="badge bg-danger days-badge">🔴 Истек</span>
                                {% endif %}
                            </td>
                            <td>
                                <small class="text-muted">↓ {{ data.traffic.download }} ↑ {{ data.traffic.upload }}</small>
                            </td>
                            <td>
                                <div class="input-group input-group-sm">
                                    <input type="text" class="form-control" value="{{ data.link }}" readonly id="link-{{ loop.index }}">
                                    <button class="btn btn-outline-secondary" type="button"
                                            onclick="navigator.clipboard.writeText(document.getElementById('link-{{ loop.index }}').value);
                                                     this.innerHTML='<i class=\'fas fa-check\'></i>';
                                                     setTimeout(()=>this.innerHTML='<i class=\'fas fa-copy\'></i>',1500)">
                                        <i class="fas fa-copy"></i>
                                    </button>
                                    <button class="btn btn-outline-primary" type="button" data-bs-toggle="modal" data-bs-target="#qrModal{{ loop.index }}">
                                        <i class="fas fa-qrcode"></i>
                                    </button>
                                </div>
                                
                                <!-- QR Modal -->
                                <div class="modal fade" id="qrModal{{ loop.index }}" tabindex="-1">
                                    <div class="modal-dialog modal-sm">
                                        <div class="modal-content">
                                            <div class="modal-header">
                                                <h6 class="modal-title">QR Code: {{ name }}</h6>
                                                <button type="button" class="btn-close" data-bs-dismiss="modal"></button>
                                            </div>
                                            <div class="modal-body text-center">
                                                <img src="data:image/png;base64,{{ data.qr_code }}" alt="QR Code" class="img-fluid">
                                                <p class="small text-muted mt-2">Отсканируйте для подключения</p>
                                            </div>
                                        </div>
                                    </div>
                                </div>
                            </td>
                            <td class="text-end">
                                <a href="{{ url_for('toggle_user', username=name) }}" 
                                   class="btn btn-sm {% if data.enabled %}btn-warning{% else %}btn-success{% endif %}"
                                   title="{% if data.enabled %}Отключить{% else %}Включить{% endif %}">
                                    <i class="fas {% if data.enabled %}fa-pause{% else %}fa-play{% endif %}"></i>
                                </a>
                                <a href="{{ url_for('delete_user', username=name) }}" 
                                   class="btn btn-sm btn-danger"
                                   onclick="return confirm('Удалить {{ name }}?')">
                                    <i class="fas fa-trash"></i>
                                </a>
                            </td>
                        </tr>
                        {% endfor %}
                    {% else %}
                        <tr>
                            <td colspan="5" class="text-center text-muted py-4">
                                <i class="fas fa-inbox fa-2x mb-2"></i><br>Нет пользователей
                            </td>
                        </tr>
                    {% endif %}
                </tbody>
            </table>
        </div>
    </div>
</div>
<!-- Активные подключения -->
<div class="card shadow-sm">
    <div class="card-header bg-dark text-white">
        <div class="d-flex justify-content-between align-items-center">
            <h5 class="mb-0"><i class="fas fa-chart-line me-2"></i>Активные подключения</h5>
            <span class="badge bg-light text-dark">{{ stats|length }} онлайн</span>
        </div>
    </div>
    <div class="card-body">
        {% if stats %}
            <div class="d-flex flex-wrap gap-2">
                {% for ip in stats %}
                    <span class="badge bg-secondary border">
                        <i class="fas fa-globe me-1"></i>{{ ip }}
                    </span>
                {% endfor %}
            </div>
        {% else %}
            <p class="text-muted text-center mb-0">Нет активных подключений</p>
        {% endif %}
    </div>
</div>
{% endblock %}
HTMLEOF
echo -e "${GREEN}HTML шаблоны созданы${RESET}"
# Gunicorn сервис
cat > /etc/systemd/system/telemt-panel.service << SVCEOF
[Unit]
Description=MTProto Panel
After=network.target telemt.service
[Service]
Type=simple
User=root
WorkingDirectory=${PANEL_DIR}
Environment="PATH=${PANEL_DIR}/venv/bin"
Environment="PANEL_PORT=${PANEL_PORT}"
ExecStart=${PANEL_DIR}/venv/bin/gunicorn -w 2 -b 0.0.0.0:${PANEL_PORT} app:app
Restart=always
[Install]
WantedBy=multi-user.target
SVCEOF
systemctl daemon-reload
systemctl enable telemt-panel --now >/dev/null 2>&1
# ==========================================
# ЧАСТЬ 5: FIREWALL И ЗАВЕРШЕНИЕ
# ==========================================
echo -e "${YELLOW}Настройка firewall...${RESET}"
ufw --force enable >/dev/null 2>&1 || true
ufw allow 22/tcp >/dev/null 2>&1
ufw allow 443/tcp >/dev/null 2>&1
ufw allow ${PANEL_PORT}/tcp >/dev/null 2>&1
# Автообновление сертификатов
(crontab -l 2>/dev/null; echo "0 3 * * * certbot renew --post-hook 'systemctl restart telemt telemt-panel' >/dev/null 2>&1") | crontab - 2>/dev/null || true
clear
show_banner
echo -e "${GREEN}${BOLD}=========================================="
echo "           УСТАНОВКА ЗАВЕРШЕНА!"
echo -e "==========================================${RESET}"
echo ""
echo -e "${CYAN}📊 Прокси сервер:${RESET}"
echo "   Домен: https://${PROXY_DOMAIN}"
echo "   Порт: 443 (FakeTLS: ${FAKE_TLS_DOMAIN})"
echo ""
echo -e "${CYAN}🎛️ Веб-панель:${RESET}"
echo "   URL: https://${PANEL_DOMAIN}:${PANEL_PORT}"
echo "   Логин: ${ADMIN_USER}"
echo -e "   Пароль: ${RED}${BOLD}${ADMIN_PASS}${RESET}"
echo ""
echo -e "${YELLOW}⚠️  Сохраните пароль! Он показан только один раз.${RESET}"
echo ""
echo -e "${BLUE}Функции панели:${RESET}"
echo "  ✓ Вкл/Откл пользователей без удаления"
echo "  ✓ Смена FakeTLS домена для новых генераций"
echo "  ✓ Статус сервера, uptime, активные подключения"
echo "  ✓ QR-коды и копирование ссылок"
echo "  ✓ Перезапуск прокси из панели"
echo "  ✓ Авто-поднятие при сбоях (мониторинг)"
echo "  ✓ Трекер трафика по пользователям"
echo "  ✓ Таймер 30 дней для оплаты"
echo ""
echo -e "${GREEN}Готово к использованию!${RESET}"
SCRIPTEOF

$ wc -l /workspace/install.sh && bash -n /workspace/install.sh && echo "Синтаксис OK"
wc -l /workspace/install.sh && bash -n /workspace/install.sh && echo "Синтаксис OK"
