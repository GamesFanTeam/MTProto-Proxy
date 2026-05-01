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
    echo -e "${RESET}${MAGENTA}        MTProto Proxy Telegram Installer by Mr_EFES (Production)"
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
echo "1) max.ru"
echo "2) vk.com"
echo "3) ozon.ru"
echo "4) Свой вариант"
while true; do
    read -rp "Ваш выбор [1-4]: " FAKE_CHOICE
    case "${FAKE_CHOICE}" in
        1) FAKE_DOMAIN="max.ru"; break ;;
        2) FAKE_DOMAIN="vk.com"; break ;;
        3) FAKE_DOMAIN="ozon.ru"; break ;;
        4)
            read -rp "Введите свой домен для маскировки (напр. google.com): " FAKE_DOMAIN
            if [[ -n "$FAKE_DOMAIN" ]]; then break; else echo -e "${RED}Домен не может быть пустым.${RESET}"; fi
            ;;
        *) echo -e "${RED}Неверный выбор. Введите число от 1 до 4.${RESET}" ;;
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
echo -e "${CYAN}${BOLD}Ссылка для подключения к прокси:${RESET}"
echo -e "\e]8;;${TG_LINK}\a${GREEN}${TG_LINK}${RESET}\e]8;;\a"
echo ""
echo -e "${YELLOW}QR-код для подключения:${RESET}"
qrencode -t ANSIUTF8 "${TG_LINK}"
echo ""

# ==========================================
# ЧАСТЬ 4: НАСТРОЙКА FIREWALL
# ==========================================
echo -e "${BOLD}--- НАСТРОЙКА FIREWALL (UFW) ---${RESET}"
echo -e "  - Открытие порта 22 (SSH)..."
ufw allow 22/tcp >/dev/null 2>&1 || true
echo -e "  - Открытие порта 443 (MTProto)..."
ufw allow 443/tcp >/dev/null 2>&1
echo -e "  - Открытие порта ${PANEL_PORT} (Панель)..."
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
echo -e "  - Создание директорий панели..."

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

echo -e "  - Настройка Python окружения (venv)..."
if [[ ! -d "$PANEL_DIR/venv" ]]; then
    python3 -m venv "$PANEL_DIR/venv"
fi

"$PANEL_DIR/venv/bin/pip" install -q --upgrade pip >/dev/null 2>&1
echo -e "  - Установка Flask, Gunicorn, Werkzeug..."
"$PANEL_DIR/venv/bin/pip" install -q Flask gunicorn toml werkzeug >/dev/null 2>&1

echo -e "  - Сборка Backend архитектуры..."
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

def get_service_status():
    try:
        status = subprocess.run(['systemctl', 'is-active', 'telemt'], capture_output=True, text=True).stdout.strip()
        if status == 'active':
            pid = subprocess.run(['systemctl', 'show', '-p', 'MainPID', 'telemt'], capture_output=True, text=True).stdout.strip().split('=')[1]
            uptime = subprocess.run(['ps', '-o', 'etime=', '-p', pid], capture_output=True, text=True).stdout.strip()
            # ps output might be e.g. "  05:48" or "1-02:30:15"
            return "Работает", uptime.strip(), "success", True
        return "Отключен", "-", "danger", False
    except:
        return "Ошибка", "-", "danger", False

def process_timers(meta, toml_config):
    now = datetime.now()
    meta_changed = False
    toml_changed = False
    toml_users = toml_config.get('access', {}).get('users', {})

    for name, data in list(meta.items()):
        try:
            created_at = datetime.fromisoformat(data['created_at'])
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
            
            def plural(n, forms):
                if n % 10 == 1 and n % 100 != 11: return forms[0]
                if 2 <= n % 10 <= 4 and (n % 100 < 10 or n % 100 >= 20): return forms[1]
                return forms[2]
                
            d_str = f"{d} {plural(d, ['день', 'дня', 'дней'])}"
            h_str = f"{h} {plural(h, ['час', 'часа', 'часов'])}"
            m_str = f"{m} {plural(m, ['минута', 'минуты', 'минут'])}"
            data['time_str'] = f"Осталось: {d_str} {h_str} {m_str}"
        else:
            data['time_str'] = "Осталось: 0 дней 0 часов 0 минут"
            
            # Auto Pause Logic
            if data.get('status') == 'active':
                data['status'] = 'disabled'
                data['auto_paused'] = True
                if name in toml_users:
                    del toml_users[name]
                    toml_changed = True
                meta_changed = True
                
            # Auto Delete Logic
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
        flash('Учетные данные обновлены!', 'success')
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
    flash('Данные администратора успешно изменены!', 'success')
    return redirect(url_for('dashboard'))

@app.route('/', methods=['GET', 'POST'])
def dashboard():
    cfg = load_json(CONFIG_PATH)
    meta = load_json(USERS_META_PATH)
    try:
        with open(TELEMT_TOML, 'r') as f: t_config = toml.load(f)
    except: t_config = {'access': {'users': {}}, 'censorship': {'tls_domain': 'max.ru'}}

    # Sync missing users from TOML to Meta (e.g. admin_default)
    now_iso = datetime.now().isoformat()
    for name, secret in t_config.get('access', {}).get('users', {}).items():
        if name not in meta:
            meta[name] = {'secret': secret, 'created_at': now_iso, 'status': 'active', 'faketls': t_config.get('censorship', {}).get('tls_domain', 'max.ru')}
            save_json(USERS_META_PATH, meta)

    meta_changed, toml_changed = process_timers(meta, t_config)
    if toml_changed:
        with open(TELEMT_TOML, 'w') as f: toml.dump(t_config, f)
        execute_proxy_cmd('restart')
    if meta_changed:
        save_json(USERS_META_PATH, meta)

    if request.method == 'POST':
        nickname = request.form.get('nickname', '').strip().replace(' ', '_')
        device = request.form.get('device', 'Phone')
        faketls = request.form.get('faketls', '').strip() or 'max.ru'
        
        if not nickname:
            flash('Укажите никнейм!', 'danger')
            return redirect(url_for('dashboard'))

        user_key = f"{nickname}_{device}"
        new_secret = secrets.token_hex(16)

        # Update global FakeTLS based on new user generation
        t_config.setdefault('censorship', {})['tls_domain'] = faketls
        t_config.setdefault('access', {}).setdefault('users', {})[user_key] = new_secret
        with open(TELEMT_TOML, 'w') as f: toml.dump(t_config, f)

        meta[user_key] = {'secret': new_secret, 'created_at': datetime.now().isoformat(), 'status': 'active', 'faketls': faketls}
        save_json(USERS_META_PATH, meta)

        execute_proxy_cmd('restart')
        flash(f'Доступ для {user_key} создан! Сервер перенастроен на SNI: {faketls}', 'success')
        return redirect(url_for('dashboard'))

    # Build Links
    proxy_links = {}
    for name, m_data in meta.items():
        domain = m_data.get('faketls', t_config.get('censorship', {}).get('tls_domain', 'max.ru'))
        hex_domain = domain.encode('utf-8').hex()
        final_secret = f"ee{m_data['secret']}{hex_domain}"
        link = f"tg://proxy?server={cfg['proxy_host']}&port={cfg.get('proxy_port', 443)}&secret={final_secret}"
        proxy_links[name] = {
            'link': link, 
            'status': m_data.get('status', 'active'),
            'time_str': m_data.get('time_str', '')
        }

    stats = get_proxy_stats()
    srv_status, srv_uptime, srv_color, is_running = get_service_status()
    total_users = len(meta)
    online_users = len(stats)
    
    return render_template('dashboard.html', 
                           links=proxy_links, host=cfg['proxy_host'], 
                           stats=stats, current_user=cfg['username'],
                           srv_status=srv_status, srv_uptime=srv_uptime, srv_color=srv_color, is_running=is_running,
                           total_users=total_users, online_users=online_users)

@app.route('/system_action/<action>')
def system_action(action):
    if action in ['restart', 'stop', 'start']:
        execute_proxy_cmd(action)
        verb = "перезапущен" if action == 'restart' else ("остановлен" if action == 'stop' else "запущен")
        flash(f'Прокси-сервер успешно {verb}', 'success')
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
            if meta[username].get('auto_paused'):
                meta[username]['created_at'] = datetime.now().isoformat()
                meta[username]['auto_paused'] = False
            flash(f'Доступ для {username} включен', 'success')
        else:
            if username in users_node: del users_node[username]
            meta[username]['status'] = 'disabled'
            flash(f'Доступ для {username} приостановлен', 'warning')
            
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

echo -e "  - Рендер HTML шаблонов..."
cat > "$PANEL_DIR/templates/layout.html" << 'HTMLEOF'
<!DOCTYPE html>
<html lang="ru">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Панель управления MTProto Proxy</title>
    <link href="https://cdn.jsdelivr.net/npm/bootstrap@5.3.0/dist/css/bootstrap.min.css" rel="stylesheet">
    <link href="https://cdnjs.cloudflare.com/ajax/libs/font-awesome/6.4.0/css/all.min.css" rel="stylesheet">
    <style>
        body { background: #f4f6f9; min-height: 100vh; font-family: 'Segoe UI', system-ui, -apple-system, sans-serif; display: flex; flex-direction: column; }
        .navbar-brand { font-weight: 600; letter-spacing: 0.5px; }
        .main-content { flex: 1; }
        .card { border: none; border-radius: 10px; box-shadow: 0 4px 12px rgba(0,0,0,0.05); margin-bottom: 1.5rem; }
        .card-header { border-radius: 10px 10px 0 0 !important; font-weight: 600; padding: 1rem 1.25rem; border-bottom: none; }
        .table { margin-bottom: 0; }
        .table th { background-color: #f8f9fa; font-weight: 600; border-bottom: 2px solid #e9ecef; }
        .badge-custom { font-size: 0.75rem; font-weight: 500; padding: 0.4em 0.6em; border-radius: 6px; }
        .btn-action { width: 38px; height: 38px; padding: 0; line-height: 38px; text-align: center; border-radius: 8px; margin: 0 2px; transition: all 0.2s; }
        .btn-action:hover { transform: translateY(-2px); box-shadow: 0 4px 8px rgba(0,0,0,0.1); }
        .link-input { background-color: #f8f9fa; border: 1px solid #e9ecef; border-radius: 6px 0 0 6px; font-size: 0.85rem; color: #495057; }
        .btn-copy { border-radius: 0 6px 6px 0; border: 1px solid #e9ecef; border-left: none; background: #fff; color: #6c757d; }
        .btn-copy:hover { background: #e9ecef; }
        footer { background: #fff; padding: 1rem 0; box-shadow: 0 -2px 10px rgba(0,0,0,0.02); margin-top: auto; color: #6c757d; font-size: 0.9rem; font-weight: 500; }
    </style>
</head>
<body>
    <nav class="navbar navbar-expand-lg navbar-dark bg-dark shadow-sm mb-4">
        <div class="container-fluid px-4">
            <span class="navbar-brand"><i class="fas fa-server me-2 text-primary"></i>Панель управления MTProto Proxy</span>
            {% if session.get('user') %}
            <div class="d-flex align-items-center">
                <span class="text-light me-3"><i class="fas fa-user-circle me-1"></i> {{ session.get('user') }}</span>
                <a href="{{ url_for('logout') }}" class="btn btn-sm btn-outline-light"><i class="fas fa-sign-out-alt"></i> Выход</a>
            </div>
            {% endif %}
        </div>
    </nav>

    <div class="container-fluid px-4 main-content">
        {% with messages = get_flashed_messages(with_categories=true) %}
            {% if messages %}
                {% for category, message in messages %}
                    <div class="alert alert-{{ category }} alert-dismissible fade show shadow-sm rounded-3">
                        <i class="fas fa-info-circle me-2"></i>{{ message }}
                        <button type="button" class="btn-close" data-bs-dismiss="alert"></button>
                    </div>
                {% endfor %}
            {% endif %}
        {% endwith %}
        {% block content %}{% endblock %}
    </div>

    <footer class="text-center mt-5">
        MTProto Proxy Panel 2026 by Mr_EFES
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
    <div class="col-md-5 col-lg-4">
        <div class="card p-4 shadow">
            <div class="text-center mb-4">
                <i class="fas fa-shield-alt fa-3x text-primary mb-2"></i>
                <h4 class="fw-bold text-dark">Авторизация</h4>
            </div>
            <form method="POST">
                <div class="mb-3">
                    <label class="form-label small text-muted">Логин</label>
                    <input type="text" name="username" class="form-control form-control-lg" required autofocus>
                </div>
                <div class="mb-4">
                    <label class="form-label small text-muted">Пароль</label>
                    <input type="password" name="password" class="form-control form-control-lg" required>
                </div>
                <button type="submit" class="btn btn-primary btn-lg w-100 fw-bold">Войти</button>
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
        <div class="card p-4 border-warning shadow">
            <h4 class="text-center text-warning mb-4"><i class="fas fa-key"></i> Смена пароля по умолчанию</h4>
            <form method="POST">
                <div class="mb-4">
                    <label class="form-label small text-muted">Новый пароль</label>
                    <input type="password" name="new_password" class="form-control form-control-lg" required minlength="6">
                </div>
                <button type="submit" class="btn btn-warning btn-lg w-100 fw-bold text-dark">Сохранить пароль</button>
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
            <div class="card-header bg-success text-white"><i class="fas fa-user-plus me-2"></i>Создать доступ</div>
            <div class="card-body">
                <form method="POST">
                    <div class="mb-3">
                        <label class="form-label small text-muted">Никнейм</label>
                        <input type="text" name="nickname" class="form-control" placeholder="Например: Ivan" required>
                    </div>
                    <div class="mb-3">
                        <label class="form-label small text-muted">Устройство</label>
                        <select name="device" class="form-select">
                            <option value="Phone">📱 Телефон</option><option value="PC">💻 ПК</option><option value="Tablet">📟 Планшет</option>
                        </select>
                    </div>
                    <div class="mb-4">
                        <label class="form-label small text-muted">Сайт для FakeTLS маскировки</label>
                        <input type="text" name="faketls" class="form-control" placeholder="Например: ozon.ru">
                    </div>
                    <button type="submit" class="btn btn-success w-100 fw-bold"><i class="fas fa-magic me-2"></i>Сгенерировать</button>
                </form>
            </div>
        </div>

        <!-- Блок: Настройки прокси -->
        <div class="card">
            <div class="card-header bg-primary text-white"><i class="fas fa-cogs me-2"></i>Настройки прокси</div>
            <div class="card-body">
                <div class="d-flex justify-content-between mb-3 pb-2 border-bottom">
                    <span class="text-muted fw-bold">Статус сервера:</span>
                    <span class="badge bg-{{ srv_color }} px-3 py-2" style="font-size:0.85rem;">{{ srv_status }}</span>
                </div>
                <div class="d-flex justify-content-between mb-3 pb-2 border-bottom">
                    <span class="text-muted fw-bold">Uptime сервера:</span>
                    <span class="fw-bold text-dark">{{ srv_uptime }}</span>
                </div>
                <div class="d-flex justify-content-between mb-3 pb-2 border-bottom">
                    <span class="text-muted fw-bold">Всего Пользователей:</span>
                    <span class="fw-bold text-primary fs-5">{{ total_users }}</span>
                </div>
                <div class="d-flex justify-content-between mb-4 pb-2 border-bottom">
                    <span class="text-muted fw-bold">Онлайн Пользователей:</span>
                    <span class="fw-bold text-success fs-5">{{ online_users }}</span>
                </div>
                
                <div class="d-grid gap-2">
                    <a href="{{ url_for('system_action', action='restart') }}" class="btn btn-primary shadow-sm" onclick="return confirm('Перезагрузить все прокси?')">
                        <i class="fas fa-sync-alt me-2"></i>Перезагрузить все прокси
                    </a>
                    
                    {% if is_running %}
                    <a href="{{ url_for('system_action', action='stop') }}" class="btn btn-danger shadow-sm" onclick="return confirm('Вы уверены, что хотите полностью остановить прокси?')">
                        <i class="fas fa-stop-circle me-2"></i>Остановить все прокси
                    </a>
                    {% else %}
                    <a href="{{ url_for('system_action', action='start') }}" class="btn btn-success shadow-sm">
                        <i class="fas fa-play-circle me-2"></i>Запустить прокси
                    </a>
                    {% endif %}
                    
                    <button class="btn btn-warning text-dark shadow-sm mt-2" data-bs-toggle="modal" data-bs-target="#adminModal">
                        <i class="fas fa-user-shield me-2"></i>Изменить Пароль Администратора
                    </button>
                </div>
            </div>
        </div>
    </div>

    <!-- Правая колонка: Список -->
    <div class="col-lg-8">
        <div class="card h-100">
            <div class="card-header bg-info text-white"><i class="fas fa-list-ul me-2"></i>Список доступов</div>
            <div class="card-body p-0">
                <div class="table-responsive">
                    <table class="table table-hover align-middle">
                        <thead>
                            <tr>
                                <th class="ps-4" style="width: 30%;">Пользователь</th>
                                <th style="width: 45%;">Ссылка</th>
                                <th class="text-end pe-4" style="width: 25%;">Действия</th>
                            </tr>
                        </thead>
                        <tbody>
                            {% for name, data in links.items() %}
                            <tr class="{% if data.status == 'disabled' %}table-secondary opacity-75{% endif %}">
                                <td class="ps-4">
                                    <div class="fw-bold text-dark mb-1">
                                        {{ name }}
                                        {% if data.status == 'disabled' %}<span class="badge bg-danger ms-1" style="font-size:0.6rem;">Пауза</span>{% endif %}
                                    </div>
                                    <span class="badge-custom {% if '0 дней' in data.time_str %}bg-danger text-white{% elif 'disabled' in data.status %}bg-secondary text-white{% else %}bg-success text-white{% endif %} shadow-sm">
                                        <i class="far fa-clock me-1"></i> {{ data.time_str }}
                                    </span>
                                </td>
                                <td>
                                    <div class="input-group input-group-sm">
                                        <input type="text" class="form-control link-input" value="{{ data.link }}" readonly id="link-{{ loop.index }}">
                                        <button class="btn btn-copy" type="button" 
                                                onclick="navigator.clipboard.writeText(document.getElementById('link-{{ loop.index }}').value);
                                                         let i=this.querySelector('i'); i.className='fas fa-check text-success';
                                                         setTimeout(()=>i.className='fas fa-copy',1500)" title="Скопировать">
                                            <i class="fas fa-copy"></i>
                                        </button>
                                    </div>
                                </td>
                                <td class="text-end pe-4 text-nowrap">
                                    <button class="btn btn-light btn-action text-primary border shadow-sm" onclick="showQR('{{ data.link }}')" title="Показать QR"><i class="fas fa-qrcode"></i></button>
                                    <a href="{{ url_for('toggle_user', username=name) }}" class="btn btn-light btn-action border shadow-sm {% if data.status == 'active' %}text-warning{% else %}text-success{% endif %}" title="{% if data.status == 'active' %}Пауза{% else %}Включить{% endif %}">
                                        <i class="fas {% if data.status == 'active' %}fa-pause{% else %}fa-play{% endif %}"></i>
                                    </a>
                                    <a href="{{ url_for('delete_user', username=name) }}" class="btn btn-light btn-action text-danger border shadow-sm" onclick="return confirm('Вы уверены, что хотите удалить доступ для {{ name }}?')" title="Удалить"><i class="fas fa-trash-alt"></i></a>
                                </td>
                            </tr>
                            {% else %}
                            <tr><td colspan="3" class="text-center py-5 text-muted"><i class="fas fa-inbox fa-3x mb-3 text-light"></i><br>Нет созданных доступов</td></tr>
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
    <div class="modal-content border-0 shadow-lg rounded-4">
      <div class="modal-header border-0 pb-0">
        <button type="button" class="btn-close" data-bs-dismiss="modal"></button>
      </div>
      <div class="modal-body text-center pb-4 pt-1">
        <h5 class="fw-bold mb-3 text-dark">Сканируйте для подключения</h5>
        <div id="qrcode" class="d-flex justify-content-center p-3 bg-white rounded-3 shadow-sm border"></div>
      </div>
    </div>
  </div>
</div>

<!-- Модальное окно Смены Администратора -->
<div class="modal fade" id="adminModal" tabindex="-1">
  <div class="modal-dialog modal-dialog-centered">
    <div class="modal-content border-0 shadow-lg">
      <div class="modal-header bg-warning text-dark border-0">
        <h5 class="modal-title fw-bold"><i class="fas fa-user-shield me-2"></i>Настройки администратора</h5>
        <button type="button" class="btn-close" data-bs-dismiss="modal"></button>
      </div>
      <form action="{{ url_for('update_admin') }}" method="POST">
          <div class="modal-body p-4">
              <div class="mb-3">
                  <label class="form-label small fw-bold">Текущий пароль (обязательно)</label>
                  <input type="password" name="old_password" class="form-control" required>
              </div>
              <hr class="text-muted">
              <div class="mb-3">
                  <label class="form-label small fw-bold">Новый Логин</label>
                  <input type="text" name="new_username" class="form-control" value="{{ current_user }}" required>
              </div>
              <div class="mb-3">
                  <label class="form-label small fw-bold">Новый Пароль (Оставьте пустым, если не меняете)</label>
                  <input type="password" name="new_password" class="form-control" minlength="6">
              </div>
          </div>
          <div class="modal-footer border-0 pt-0">
              <button type="button" class="btn btn-light" data-bs-dismiss="modal">Отмена</button>
              <button type="submit" class="btn btn-warning fw-bold">Сохранить изменения</button>
          </div>
      </form>
    </div>
  </div>
</div>

<script>
function showQR(link) {
    document.getElementById('qrcode').innerHTML = '';
    new QRCode(document.getElementById('qrcode'), {text: link, width: 220, height: 220, colorDark : "#1a1a1a", colorLight : "#ffffff", correctLevel : QRCode.CorrectLevel.M});
    new bootstrap.Modal(document.getElementById('qrModal')).show();
}
</script>
{% endblock %}
HTMLEOF

echo -e "  - Обновление Backend панели завершено."
echo -e "  - Настройка службы панели..."

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
