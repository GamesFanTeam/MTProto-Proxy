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
    echo -e "${GREEN}${BOLD}"
    echo "  ████████╗███████╗██╗     ███████╗███╗   ███╗████████╗"
    echo "  ╚══██╔══╝██╔════╝██║     ██╔════╝████╗ ████║╚══██╔══╝"
    echo "     ██║   █████╗  ██║     █████╗  ██╔████╔██║   ██║   "
    echo "     ██║   ██╔══╝  ██║     ██╔══╝  ██║╚██╔╝██║   ██║   "
    echo "     ██║   ███████╗███████╗███████╗██║ ╚═╝ ██║   ██║   "
    echo "     ╚═╝   ╚══════╝╚══════╝╚══════╝╚═╝     ╚═╝   ╚═╝   "
    echo -e "${RESET}${CYAN}        MTProto Proxy Darknet Edition Installer${RESET}"
    echo -e "${RESET}"
}

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
apt-get install -y -qq curl wget jq openssl certbot xxd socat ufw python3 python3-pip python3-venv iproute2 net-tools procps qrencode >/dev/null 2>&1

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
echo -e "  ${GREEN}Прокси домен:${RESET} ${PROXY_DOMAIN} (порт 443)"
echo -e "  ${GREEN}Панель домен:${RESET} ${PANEL_DOMAIN} (порт ${PANEL_PORT})"
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

echo -e "${BOLD}Выберите домен для Fake TLS маскировки (Глобальный):${RESET}"
echo "1) ads.x5.ru"
echo "2) 1c.ru"
echo "3) ozon.ru"
echo "4) vk.com"
echo "5) max.ru"
echo "6) Свой вариант"
while true; do
    read -rp "Ваш выбор [1-6]: " FAKE_CHOICE
    case "${FAKE_CHOICE}" in
        1) FAKE_DOMAIN="ads.x5.ru"; break ;;
        2) FAKE_DOMAIN="1c.ru"; break ;;
        3) FAKE_DOMAIN="ozon.ru"; break ;;
        4) FAKE_DOMAIN="vk.com"; break ;;
        5) FAKE_DOMAIN="max.ru"; break ;;
        6)
            read -rp "Введите свой домен для маскировки (напр. google.com): " FAKE_DOMAIN
            if [[ -n "$FAKE_DOMAIN" ]]; then break; else echo -e "${RED}Домен не может быть пустым.${RESET}"; fi
            ;;
        *) echo -e "${RED}Неверный выбор. Введите число от 1 до 6.${RESET}" ;;
    esac
done

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

echo ""
echo -e "${GREEN}${BOLD}Ссылка для подключения к прокси:${RESET}"
echo -e "\e]8;;${TG_LINK}\a${CYAN}${TG_LINK}${RESET}\e]8;;\a"
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
    echo -e "${GREEN}Правила firewall успешно применены.${RESET}"
else
    echo -e "${YELLOW}UFW отключен, порты готовы к использованию.${RESET}"
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

if [[ ! -d "$PANEL_DIR/venv" ]]; then
    python3 -m venv "$PANEL_DIR/venv"
fi

"$PANEL_DIR/venv/bin/pip" install -q --upgrade pip >/dev/null 2>&1
"$PANEL_DIR/venv/bin/pip" install -q Flask gunicorn toml werkzeug >/dev/null 2>&1

cat > "$PANEL_DIR/app.py" << 'PYEOF'
import os, json, secrets, toml, subprocess
from datetime import datetime, timedelta
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

def execute_proxy_cmd(action):
    try: subprocess.run(['systemctl', action, 'telemt'], check=False, timeout=10)
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

def get_active_secrets():
    # Эвристический поиск активных юзеров в логах за последние 10 минут
    try:
        result = subprocess.run(['journalctl', '-u', 'telemt', '--since', '10 minutes ago', '--no-pager'], capture_output=True, text=True)
        logs = result.stdout
        meta = load_json(USERS_META_PATH)
        active_users = []
        for name, data in meta.items():
            if data['secret'] in logs:
                active_users.append(name)
        return active_users
    except:
        return []

def get_server_uptime():
    try:
        with open('/proc/uptime', 'r') as f:
            uptime_seconds = float(f.readline().split()[0])
        d = int(uptime_seconds // 86400)
        h = int((uptime_seconds % 86400) // 3600)
        m = int((uptime_seconds % 3600) // 60)
        return f"{d} дн. {h} ч. {m} мин."
    except:
        return "Неизвестно"

def get_service_status():
    try:
        status = subprocess.run(['systemctl', 'is-active', 'telemt'], capture_output=True, text=True).stdout.strip()
        srv_uptime = get_server_uptime()
        if status == 'active':
            return "Работает", srv_uptime, "success", True
        return "Отключен", srv_uptime, "danger", False
    except:
        return "Ошибка", get_server_uptime(), "danger", False

def process_timers(meta, toml_config):
    now = datetime.now()
    meta_changed = False
    toml_changed = False
    toml_users = toml_config.get('access', {}).get('users', {})

    for name, data in list(meta.items()):
        try: created_at = datetime.fromisoformat(data['created_at'])
        except:
            created_at = now
            data['created_at'] = now.isoformat()
            meta_changed = True
            
        expire_time = created_at + timedelta(days=30)
        delete_time = expire_time + timedelta(days=2)
        diff = expire_time - now
        
        if diff.total_seconds() > 0:
            d = diff.days
            h, rem = divmod(diff.seconds, 3600)
            m, _ = divmod(rem, 60)
            data['time_str'] = f"{d}д {h}ч {m}м"
        else:
            data['time_str'] = "0д 0ч 0м"
            if data.get('status') == 'active':
                data['status'] = 'disabled'
                data['auto_paused'] = True
                if name in toml_users:
                    del toml_users[name]
                    toml_changed = True
                meta_changed = True
                
            if data.get('auto_paused') and now >= delete_time:
                del meta[name]
                meta_changed = True
                continue
    return meta_changed, toml_changed

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
        flash('Пароль обновлен! Добро пожаловать.', 'success')
        return redirect(url_for('dashboard'))
    return render_template('change_password.html')

@app.route('/update_admin', methods=['POST'])
def update_admin():
    cfg = load_json(CONFIG_PATH)
    old_pass = request.form['old_password']
    
    if not check_password_hash(cfg['password_hash'], old_pass):
        flash('Текущий пароль указан неверно!', 'danger')
        return redirect(url_for('dashboard'))
        
    cfg['username'] = request.form['new_username'].strip()
    new_pass = request.form['new_password'].strip()
    if new_pass:
        cfg['password_hash'] = generate_password_hash(new_pass)
        
    save_json(CONFIG_PATH, cfg)
    session['user'] = cfg['username']
    flash('Данные администратора изменены!', 'success')
    return redirect(url_for('dashboard'))

@app.route('/', methods=['GET', 'POST'])
def dashboard():
    cfg = load_json(CONFIG_PATH)
    meta = load_json(USERS_META_PATH)
    try:
        with open(TELEMT_TOML, 'r') as f: t_config = toml.load(f)
    except: t_config = {'access': {'users': {}}, 'censorship': {'tls_domain': 'max.ru'}}

    now_iso = datetime.now().isoformat()
    for name, secret in t_config.get('access', {}).get('users', {}).items():
        if name not in meta:
            meta[name] = {'secret': secret, 'created_at': now_iso, 'status': 'active', 'faketls': t_config.get('censorship', {}).get('tls_domain', 'max.ru')}
            save_json(USERS_META_PATH, meta)

    meta_changed, toml_changed = process_timers(meta, t_config)
    if toml_changed:
        with open(TELEMT_TOML, 'w') as f: toml.dump(t_config, f)
        execute_proxy_cmd('restart')
    if meta_changed: save_json(USERS_META_PATH, meta)

    if request.method == 'POST':
        nickname = request.form.get('nickname', '').strip().replace(' ', '_')
        device = request.form.get('device', 'Phone')
        faketls = request.form.get('faketls', '').strip() or 'max.ru'
        
        if not nickname:
            flash('Укажите никнейм!', 'danger')
            return redirect(url_for('dashboard'))

        user_key = f"{nickname}_{device}"
        new_secret = secrets.token_hex(16)

        # Важно: Не меняем глобальный SNI сервера, только записываем в TOML доступ и в Meta
        t_config.setdefault('access', {}).setdefault('users', {})[user_key] = new_secret
        with open(TELEMT_TOML, 'w') as f: toml.dump(t_config, f)

        meta[user_key] = {'secret': new_secret, 'created_at': datetime.now().isoformat(), 'status': 'active', 'faketls': faketls}
        save_json(USERS_META_PATH, meta)

        execute_proxy_cmd('restart')
        flash(f'Доступ {user_key} создан (SNI: {faketls})', 'success')
        return redirect(url_for('dashboard'))

    active_secrets_logs = get_active_secrets()
    proxy_links = {}
    
    for name, m_data in meta.items():
        domain = m_data.get('faketls', t_config.get('censorship', {}).get('tls_domain', 'max.ru'))
        hex_domain = domain.encode('utf-8').hex()
        final_secret = f"ee{m_data['secret']}{hex_domain}"
        link = f"tg://proxy?server={cfg['proxy_host']}&port={cfg.get('proxy_port', 443)}&secret={final_secret}"
        
        # Определяем статус онлайн на основе парсинга логов
        is_online = (name in active_secrets_logs) and m_data.get('status') == 'active'

        proxy_links[name] = {
            'link': link, 
            'status': m_data.get('status', 'active'),
            'time_str': m_data.get('time_str', ''),
            'is_online': is_online
        }

    stats = get_proxy_stats()
    srv_status, srv_uptime, srv_color, is_running = get_service_status()
    
    return render_template('dashboard.html', 
                           links=proxy_links, host=cfg['proxy_host'], 
                           stats=stats, current_user=cfg['username'],
                           srv_status=srv_status, srv_uptime=srv_uptime, srv_color=srv_color, is_running=is_running,
                           total_users=len(meta), online_users=len(stats))

@app.route('/system_action/<action>')
def system_action(action):
    if action in ['restart', 'stop', 'start']:
        execute_proxy_cmd(action)
        flash('Команда выполнена', 'success')
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
            flash(f'Пользователь {username} активирован', 'success')
        else:
            if username in users_node: del users_node[username]
            meta[username]['status'] = 'disabled'
            flash(f'Доступ {username} приостановлен', 'warning')
            
        with open(TELEMT_TOML, 'w') as f: toml.dump(t_config, f)
        save_json(USERS_META_PATH, meta)
        execute_proxy_cmd('restart')
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
            execute_proxy_cmd('restart')
        flash(f'Пользователь {username} удален', 'success')
    except Exception as e:
        flash(f'Ошибка: {str(e)}', 'danger')
    return redirect(url_for('dashboard'))

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=int(os.environ.get('PANEL_PORT', 4444)))
PYEOF

cat > "$PANEL_DIR/templates/layout.html" << 'HTMLEOF'
<!DOCTYPE html>
<html lang="ru">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Darknet Proxy Panel</title>
    <link href="https://cdn.jsdelivr.net/npm/bootstrap@5.3.0/dist/css/bootstrap.min.css" rel="stylesheet">
    <link href="https://cdnjs.cloudflare.com/ajax/libs/font-awesome/6.4.0/css/all.min.css" rel="stylesheet">
    <style>
        body { background-color: #050505; color: #00ff41; font-family: 'Courier New', Courier, monospace; min-height: 100vh; display: flex; flex-direction: column; }
        .navbar { background-color: #0a0a0a !important; border-bottom: 1px solid #00ff41; box-shadow: 0 0 10px rgba(0,255,65,0.2); }
        .navbar-brand { color: #00ff41 !important; font-weight: bold; text-transform: uppercase; letter-spacing: 2px; }
        .card { background-color: #0a0a0a; border: 1px solid #003300; border-radius: 4px; box-shadow: 0 4px 15px rgba(0,0,0,0.5); margin-bottom: 1.5rem; transition: border-color 0.3s; }
        .card:hover { border-color: #00ff41; }
        .card-header { background-color: #051505 !important; border-bottom: 1px solid #003300; font-weight: bold; text-transform: uppercase; color: #00ff41; border-radius: 4px 4px 0 0 !important; }
        .form-control, .form-select { background-color: #000; border: 1px solid #005500; color: #00ff41; border-radius: 2px; }
        .form-control:focus, .form-select:focus { background-color: #050505; border-color: #00ff41; color: #00ff41; box-shadow: 0 0 5px rgba(0,255,65,0.5); }
        .form-label { color: #00aa22; }
        .btn-success { background-color: #003300; border: 1px solid #00ff41; color: #00ff41; }
        .btn-success:hover { background-color: #00ff41; color: #000; box-shadow: 0 0 10px #00ff41; }
        .btn-primary { background-color: transparent; border: 1px solid #0088ff; color: #0088ff; }
        .btn-primary:hover { background-color: #0088ff; color: #000; }
        .btn-danger { background-color: transparent; border: 1px solid #ff003c; color: #ff003c; }
        .btn-danger:hover { background-color: #ff003c; color: #000; }
        .btn-warning { background-color: transparent; border: 1px solid #ffbb00; color: #ffbb00; }
        .btn-warning:hover { background-color: #ffbb00; color: #000; }
        .btn-outline-secondary { border-color: #004400; color: #00aa22; }
        .btn-outline-secondary:hover { background-color: #004400; color: #00ff41; }
        .table { color: #00aa22; margin-bottom: 0; }
        .table th { background-color: #051505; border-bottom: 1px solid #00ff41; font-weight: normal; text-transform: uppercase; }
        .table td { border-bottom: 1px solid #002200; vertical-align: middle; }
        .table-hover tbody tr:hover { background-color: #001a00; color: #00ff41; }
        .badge { border-radius: 2px; font-weight: normal; padding: 0.4em 0.6em; }
        .btn-action { background: #000; border: 1px solid #005500; color: #00ff41; width: 32px; height: 32px; padding: 0; line-height: 30px; text-align: center; border-radius: 2px; margin: 0 2px; }
        .btn-action:hover { background: #00ff41; color: #000; }
        .btn-action.text-danger { color: #ff003c; border-color: #550000; }
        .btn-action.text-danger:hover { background: #ff003c; color: #000; }
        .link-input { border-radius: 2px 0 0 2px; font-size: 0.8rem; }
        .btn-copy { border-radius: 0 2px 2px 0; border: 1px solid #005500; background: #002200; color: #00ff41; }
        .btn-copy:hover { background: #00ff41; color: #000; }
        .status-dot { height: 10px; width: 10px; border-radius: 50%; display: inline-block; box-shadow: 0 0 5px currentColor; }
        .status-online { background-color: #00ff41; color: #00ff41; }
        .status-offline { background-color: #ff003c; color: #ff003c; }
        footer { border-top: 1px solid #003300; padding: 1rem 0; margin-top: auto; color: #005500; text-align: center; font-size: 0.8rem; }
        .modal-content { background-color: #0a0a0a; border: 1px solid #00ff41; color: #00ff41; }
        .modal-header { border-bottom: 1px solid #003300; }
        .modal-footer { border-top: 1px solid #003300; }
        .text-muted { color: #005500 !important; }
        .alert { background-color: #001a00; border: 1px solid #00ff41; color: #00ff41; border-radius: 2px; }
        .btn-close { filter: invert(1) grayscale(100%) brightness(200%); }
    </style>
</head>
<body>
    <nav class="navbar navbar-expand-lg px-4 mb-4">
        <span class="navbar-brand"><i class="fas fa-terminal me-2"></i>[ PROXY_PANEL_v2.0 ]</span>
        {% if session.get('user') %}
        <div class="ms-auto d-flex align-items-center">
            <span class="me-3 text-uppercase">USER: {{ session.get('user') }}</span>
            <a href="{{ url_for('logout') }}" class="btn btn-sm btn-danger"><i class="fas fa-power-off"></i> EXIT</a>
        </div>
        {% endif %}
    </nav>

    <div class="container-fluid px-4 flex-grow-1">
        {% with messages = get_flashed_messages(with_categories=true) %}
            {% if messages %}
                {% for category, message in messages %}
                    <div class="alert alert-dismissible fade show shadow-sm">
                        <i class="fas fa-angle-right me-2"></i>{{ message }}
                        <button type="button" class="btn-close" data-bs-dismiss="alert"></button>
                    </div>
                {% endfor %}
            {% endif %}
        {% endwith %}
        {% block content %}{% endblock %}
    </div>

    <footer>
        [ MTProto Proxy Server :: Darknet Core :: 2026 ]
    </footer>

    <script src="https://cdn.jsdelivr.net/npm/bootstrap@5.3.0/dist/js/bootstrap.bundle.min.js"></script>
    <script src="https://cdnjs.cloudflare.com/ajax/libs/qrcodejs/1.0.0/qrcode.min.js"></script>
</body>
</html>
HTMLEOF

cat > "$PANEL_DIR/templates/login.html" << 'HTMLEOF'
{% extends "layout.html" %}
{% block content %}
<div class="row justify-content-center align-items-center mt-5">
    <div class="col-md-4">
        <div class="card p-4">
            <div class="text-center mb-4">
                <i class="fas fa-user-secret fa-3x mb-3" style="color: #00ff41;"></i>
                <h5 class="fw-bold">SYSTEM AUTHENTICATION</h5>
            </div>
            <form method="POST">
                <div class="mb-3">
                    <label class="form-label small">LOGIN</label>
                    <input type="text" name="username" class="form-control" required autofocus>
                </div>
                <div class="mb-4">
                    <label class="form-label small">PASSWORD</label>
                    <input type="password" name="password" class="form-control" required>
                </div>
                <button type="submit" class="btn btn-success w-100 fw-bold">> INITIATE CONNECTION</button>
            </form>
        </div>
    </div>
</div>
{% endblock %}
HTMLEOF

cat > "$PANEL_DIR/templates/change_password.html" << 'HTMLEOF'
{% extends "layout.html" %}
{% block content %}
<div class="row justify-content-center mt-5">
    <div class="col-md-5">
        <div class="card p-4">
            <h5 class="text-center text-warning mb-4"><i class="fas fa-exclamation-triangle"></i> SECURE DEFAULT PASSWORD</h5>
            <form method="POST">
                <div class="mb-4">
                    <label class="form-label small">NEW PASSWORD</label>
                    <input type="password" name="new_password" class="form-control" required minlength="6">
                </div>
                <button type="submit" class="btn btn-warning w-100 fw-bold">> UPDATE SECURITY_KEY</button>
            </form>
        </div>
    </div>
</div>
{% endblock %}
HTMLEOF

cat > "$PANEL_DIR/templates/dashboard.html" << 'HTMLEOF'
{% extends "layout.html" %}
{% block content %}
<div class="row">
    <!-- Левая колонка -->
    <div class="col-lg-4">
        <!-- Блок: Создать доступ -->
        <div class="card">
            <div class="card-header">>_ GENERATE_ACCESS</div>
            <div class="card-body">
                <form method="POST">
                    <div class="mb-3">
                        <label class="form-label small">USER_ALIAS</label>
                        <input type="text" name="nickname" class="form-control" placeholder="E.g., Neo" required>
                    </div>
                    <div class="mb-3">
                        <label class="form-label small">DEVICE_TYPE</label>
                        <select name="device" class="form-select">
                            <option value="Phone">Phone</option><option value="PC">Terminal</option><option value="Tablet">Pad</option>
                        </select>
                    </div>
                    <div class="mb-4">
                        <label class="form-label small">SNI_SPOOF (FAKETLS)</label>
                        <input type="text" name="faketls" id="faketls" class="form-control" placeholder="E.g., ozon.ru">
                        <div class="mt-2 d-flex flex-wrap gap-1">
                            <button type="button" class="btn btn-sm btn-outline-secondary" onclick="document.getElementById('faketls').value='ads.x5.ru'">ads.x5.ru</button>
                            <button type="button" class="btn btn-sm btn-outline-secondary" onclick="document.getElementById('faketls').value='1c.ru'">1c.ru</button>
                            <button type="button" class="btn btn-sm btn-outline-secondary" onclick="document.getElementById('faketls').value='ozon.ru'">ozon.ru</button>
                            <button type="button" class="btn btn-sm btn-outline-secondary" onclick="document.getElementById('faketls').value='vk.com'">vk.com</button>
                            <button type="button" class="btn btn-sm btn-outline-secondary" onclick="document.getElementById('faketls').value='max.ru'">max.ru</button>
                        </div>
                    </div>
                    <button type="submit" class="btn btn-success w-100 fw-bold">> EXECUTE GENERATION</button>
                </form>
            </div>
        </div>

        <!-- Блок: Настройки прокси -->
        <div class="card">
            <div class="card-header">>_ SERVER_STATUS</div>
            <div class="card-body">
                <div class="d-flex justify-content-between mb-2">
                    <span>DAEMON_STATE:</span>
                    <span class="text-{{ srv_color }} fw-bold">[{{ srv_status }}]</span>
                </div>
                <div class="d-flex justify-content-between mb-2">
                    <span>OS_UPTIME:</span>
                    <span class="fw-bold">{{ srv_uptime }}</span>
                </div>
                <div class="d-flex justify-content-between mb-2">
                    <span>TOTAL_NODES:</span>
                    <span class="fw-bold">{{ total_users }}</span>
                </div>
                <div class="d-flex justify-content-between mb-4">
                    <span>ACTIVE_FLOWS:</span>
                    <span class="text-primary fw-bold">{{ online_users }}</span>
                </div>
                
                <div class="d-grid gap-2">
                    <a href="{{ url_for('system_action', action='restart') }}" class="btn btn-primary" onclick="return confirm('Restart daemon?')">
                        > REBOOT_PROXY
                    </a>
                    
                    {% if is_running %}
                    <a href="{{ url_for('system_action', action='stop') }}" class="btn btn-danger" onclick="return confirm('KILL proxy process?')">
                        > KILL_PROCESS
                    </a>
                    {% else %}
                    <a href="{{ url_for('system_action', action='start') }}" class="btn btn-success">
                        > START_PROCESS
                    </a>
                    {% endif %}
                    
                    <button class="btn btn-warning mt-2" data-bs-toggle="modal" data-bs-target="#adminModal">
                        > CHANGE_ROOT_CREDENTIALS
                    </button>
                </div>
            </div>
        </div>
    </div>

    <!-- Правая колонка: Список -->
    <div class="col-lg-8">
        <div class="card h-100">
            <div class="card-header">>_ CONNECTED_NODES</div>
            <div class="card-body p-0">
                <div class="table-responsive">
                    <table class="table align-middle">
                        <thead>
                            <tr>
                                <th class="ps-3" style="width: 25%;">ALIAS</th>
                                <th style="width: 15%;">STATUS</th>
                                <th style="width: 40%;">PAYLOAD_LINK</th>
                                <th class="text-end pe-3" style="width: 20%;">CMD</th>
                            </tr>
                        </thead>
                        <tbody>
                            {% for name, data in links.items() %}
                            <tr style="{% if data.status == 'disabled' %}opacity: 0.5;{% endif %}">
                                <td class="ps-3">
                                    <div class="fw-bold mb-1">{{ name }}</div>
                                    <span class="small text-muted"><i class="far fa-clock"></i> {{ data.time_str }}</span>
                                </td>
                                <td>
                                    {% if data.status == 'disabled' %}
                                        <span class="badge" style="border: 1px solid #555; color: #555;">PAUSED</span>
                                    {% else %}
                                        {% if data.is_online %}
                                            <div class="d-flex align-items-center">
                                                <span class="status-dot status-online me-2"></span> <span style="color:#00ff41; font-size: 0.85rem;">В Сети</span>
                                            </div>
                                        {% else %}
                                            <div class="d-flex align-items-center">
                                                <span class="status-dot status-offline me-2"></span> <span style="color:#ff003c; font-size: 0.85rem;">Не в сети</span>
                                            </div>
                                        {% endif %}
                                    {% endif %}
                                </td>
                                <td>
                                    <div class="input-group input-group-sm">
                                        <input type="text" class="form-control link-input" value="{{ data.link }}" readonly id="link-{{ loop.index }}">
                                        <button class="btn btn-copy" type="button" 
                                                onclick="navigator.clipboard.writeText(document.getElementById('link-{{ loop.index }}').value);
                                                         let i=this.querySelector('i'); i.className='fas fa-check';
                                                         setTimeout(()=>i.className='fas fa-copy',1500)">
                                            <i class="fas fa-copy"></i>
                                        </button>
                                    </div>
                                </td>
                                <td class="text-end pe-3 text-nowrap">
                                    <button class="btn btn-action" onclick="showQR('{{ data.link }}')"><i class="fas fa-qrcode"></i></button>
                                    <a href="{{ url_for('toggle_user', username=name) }}" class="btn btn-action {% if data.status == 'active' %}text-warning{% else %}text-success{% endif %}">
                                        <i class="fas {% if data.status == 'active' %}fa-pause{% else %}fa-play{% endif %}"></i>
                                    </a>
                                    <a href="{{ url_for('delete_user', username=name) }}" class="btn btn-action text-danger" onclick="return confirm('Purge {{ name }}?')" ><i class="fas fa-trash-alt"></i></a>
                                </td>
                            </tr>
                            {% else %}
                            <tr><td colspan="4" class="text-center py-5 text-muted">> NO_NODES_FOUND</td></tr>
                            {% endfor %}
                        </tbody>
                    </table>
                </div>
            </div>
        </div>
    </div>
</div>

<!-- Модальное окно QR-кода -->
<div class="modal fade" id="qrModal" tabindex="-1">
  <div class="modal-dialog modal-dialog-centered modal-sm">
    <div class="modal-content">
      <div class="modal-header border-0 pb-0">
        <button type="button" class="btn-close" data-bs-dismiss="modal"></button>
      </div>
      <div class="modal-body text-center pb-4 pt-1">
        <h6 class="fw-bold mb-3">> SCAN_TO_CONNECT</h6>
        <div id="qrcode" class="d-flex justify-content-center p-3 rounded-2" style="background: #fff;"></div>
      </div>
    </div>
  </div>
</div>

<!-- Модальное окно Смены Администратора -->
<div class="modal fade" id="adminModal" tabindex="-1">
  <div class="modal-dialog modal-dialog-centered">
    <div class="modal-content">
      <div class="modal-header">
        <h5 class="modal-title fw-bold">> UPDATE_CREDENTIALS</h5>
        <button type="button" class="btn-close" data-bs-dismiss="modal"></button>
      </div>
      <form action="{{ url_for('update_admin') }}" method="POST">
          <div class="modal-body p-4">
              <div class="mb-3">
                  <label class="form-label small">CURRENT_PASSWORD (REQ)</label>
                  <input type="password" name="old_password" class="form-control" required>
              </div>
              <hr style="border-color: #003300;">
              <div class="mb-3">
                  <label class="form-label small">NEW_LOGIN</label>
                  <input type="text" name="new_username" class="form-control" value="{{ current_user }}" required>
              </div>
              <div class="mb-3">
                  <label class="form-label small">NEW_PASSWORD (LEAVE BLANK TO KEEP)</label>
                  <input type="password" name="new_password" class="form-control" minlength="6">
              </div>
          </div>
          <div class="modal-footer">
              <button type="button" class="btn btn-outline-secondary" data-bs-dismiss="modal">ABORT</button>
              <button type="submit" class="btn btn-warning fw-bold">> APPLY</button>
          </div>
      </form>
    </div>
  </div>
</div>

<script>
function showQR(link) {
    document.getElementById('qrcode').innerHTML = '';
    new QRCode(document.getElementById('qrcode'), {text: link, width: 220, height: 220, colorDark : "#000000", colorLight : "#ffffff", correctLevel : QRCode.CorrectLevel.M});
    new bootstrap.Modal(document.getElementById('qrModal')).show();
}
</script>
{% endblock %}
HTMLEOF

echo -e "  - Обновление Backend панели завершено."

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
echo "           SYSTEM DEPLOYMENT SUCCESSFUL!"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo -e "${RESET}"
echo -e "${BOLD}🖥️ ПАНЕЛЬ УПРАВЛЕНИЯ:${RESET}"
echo -e "   URL: ${GREEN}https://${PANEL_DOMAIN}:${PANEL_PORT}${RESET}"
echo -e "   Логин: ${YELLOW}admin${RESET}"
echo -e "   Пароль: ${YELLOW}admin${RESET}"
echo -e "   ${RED}⚠️ Смените пароль при первом входе!${RESET}"
echo ""
