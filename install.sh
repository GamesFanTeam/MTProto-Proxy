#!/bin/bash
set -euo pipefail
# ── Цветовая схема ──────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
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
echo -e "${RESET}"
}
detect_public_ip() {
curl -4 -fsS --max-time 5 https://api.ipify.org 2>/dev/null || hostname -I 2>/dev/null | awk '{print $1}' || true
}
# Функция выпуска/проверки SSL сертификата с email
issue_ssl() {
local domain=$1
local email=$2
local cert_path="/etc/letsencrypt/live/${domain}/fullchain.pem"
if [[ -f "$cert_path" ]]; then
# Проверяем действительность сертификата (действителен ли еще 24 часа)
if openssl x509 -in "$cert_path" -noout -checkend 86400 >/dev/null 2>&1; then
echo "exist"
else
# Сертификат истек или истекает, перевыпускаем
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
# Сертификата нет, выпускаем новый
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
show_banner
if [[ $EUID -ne 0 ]]; then
echo -e "${RED}Ошибка: запустите скрипт от имени root.${RESET}"
exit 1
fi
echo -e "${YELLOW}Проверка необходимых пакетов...${RESET}"
apt-get update -qq >/dev/null 2>&1
apt-get install -y -qq curl wget jq openssl certbot xxd socat ufw python3 python3-pip python3-venv iproute2 net-tools nginx >/dev/null 2>&1
# Останавливаем веб-серверы которые могут занимать порт 80
systemctl stop nginx apache2 2>/dev/null || true
# ==========================================
# ЧАСТЬ 1: СБОР ВВОДНЫХ ДАННЫХ
# ==========================================
echo -e "${BOLD}--- НАСТРОЙКА ПРОКСИ И ПАНЕЛИ ---${RESET}"
echo ""
# Домен для ПРОКСИ (порт 443)
read -rp "Введите домен для ПРОКСИ (напр. tg.example.com): " PROXY_DOMAIN
if [[ -z "${PROXY_DOMAIN}" ]]; then
echo -e "${RED}Домен для прокси обязателен!${RESET}"
exit 1
fi
# Домен для ПАНЕЛИ
read -rp "Введите домен для ПАНЕЛИ УПРАВЛЕНИЯ (напр. example.com): " PANEL_DOMAIN
if [[ -z "${PANEL_DOMAIN}" ]]; then
echo -e "${RED}Домен для панели обязателен!${RESET}"
exit 1
fi
# Домен для САЙТА-ЗАГУШКИ
read -rp "Введите домен для САЙТА-ЗАГУШКИ (напр. site.example.com): " STUB_DOMAIN
if [[ -z "${STUB_DOMAIN}" ]]; then
echo -e "${YELLOW}Домен для заглушки не указан, пропускаем...${RESET}"
STUB_DOMAIN=""
fi
# Порт для панели
read -rp "Введите порт для панели управления [по умолчанию 4444]: " PANEL_PORT_INPUT
PANEL_PORT=${PANEL_PORT_INPUT:-4444}
# Email для сертификатов
read -rp "Введите Email для уведомлений о сертификатах (необязательно): " CERT_EMAIL
echo ""
echo -e "${CYAN}Параметры установки:${RESET}"
echo -e "  ${BLUE}Прокси домен:${RESET} ${PROXY_DOMAIN} (порт 443)"
echo -e "  ${BLUE}Панель домен:${RESET} ${PANEL_DOMAIN} (порт ${PANEL_PORT})"
if [[ -n "${STUB_DOMAIN}" ]]; then
echo -e "  ${BLUE}Сайт-заглушка домен:${RESET} ${STUB_DOMAIN} (порт 80/443)"
fi
if [[ -n "${CERT_EMAIL}" ]]; then
echo -e "  ${BLUE}Email для сертификатов:${RESET} ${CERT_EMAIL}"
else
echo -e "  ${YELLOW}Email для сертификатов:${RESET} не указан"
fi
echo ""
# ==========================================
# ЧАСТЬ 2: ВЫПУСК SSL СЕРТИФИКАТОВ
# ==========================================
echo -e "${BOLD}--- ВЫПУСК SSL СЕРТИФИКАТОВ ---${RESET}"
# Сертификат для ПРОКСИ
echo -ne "${YELLOW}Проверка/выпуск сертификата для ${PROXY_DOMAIN}... ${RESET}"
ssl_proxy_status=$(issue_ssl "$PROXY_DOMAIN" "$CERT_EMAIL")
case "$ssl_proxy_status" in
"exist")
echo -e "${GREEN}Найден существующий (действителен)${RESET}"
;;
"new")
echo -e "${GREEN}Успешно выпущен новый${RESET}"
;;
"renewed")
echo -e "${GREEN}Успешно обновлен${RESET}"
;;
"error")
echo -e "${RED}ОШИБКА выпуска SSL! Проверьте A-запись домена.${RESET}"
exit 1
;;
esac
# Сертификат для ПАНЕЛИ
echo -ne "${YELLOW}Проверка/выпуск сертификата для ${PANEL_DOMAIN}... ${RESET}"
ssl_panel_status=$(issue_ssl "$PANEL_DOMAIN" "$CERT_EMAIL")
case "$ssl_panel_status" in
"exist")
echo -e "${GREEN}Найден существующий (действителен)${RESET}"
;;
"new")
echo -e "${GREEN}Успешно выпущен новый${RESET}"
;;
"renewed")
echo -e "${GREEN}Успешно обновлен${RESET}"
;;
"error")
echo -e "${RED}ОШИБКА выпуска SSL! Проверьте A-запись домена.${RESET}"
exit 1
;;
esac
# Сертификат для САЙТА-ЗАГУШКИ (если указан)
if [[ -n "${STUB_DOMAIN}" ]]; then
echo -ne "${YELLOW}Проверка/выпуск сертификата для ${STUB_DOMAIN}... ${RESET}"
ssl_stub_status=$(issue_ssl "$STUB_DOMAIN" "$CERT_EMAIL")
case "$ssl_stub_status" in
"exist")
echo -e "${GREEN}Найден существующий (действителен)${RESET}"
;;
"new")
echo -e "${GREEN}Успешно выпущен новый${RESET}"
;;
"renewed")
echo -e "${GREEN}Успешно обновлен${RESET}"
;;
"error")
echo -e "${RED}ОШИБКА выпуска SSL! Проверьте A-запись домена.${RESET}"
exit 1
;;
esac
fi
echo ""
# ==========================================
# ЧАСТЬ 3: УСТАНОВКА ПРОКСИ
# ==========================================
echo -e "${BOLD}--- УСТАНОВКА MTProto ПРОКСИ ---${RESET}"
# Выбор домена для Fake TLS маскировки
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
if [[ -z "$FAKE_DOMAIN" ]]; then
FAKE_DOMAIN="max.ru"
fi
;;
*) FAKE_DOMAIN="max.ru" ;;
esac
echo -e "${YELLOW}Установка ядра Telemt...${RESET}"
ARCH=$(uname -m)
case "$ARCH" in
"x86_64") BIN_ARCH="x86_64" ;;
"aarch64"|"arm64") BIN_ARCH="aarch64" ;;
*)
echo -e "${RED}Неподдерживаемая архитектура: $ARCH${RESET}"
exit 1
;;
esac
DL_URL="https://github.com/telemt/telemt/releases/latest/download/telemt-${BIN_ARCH}-linux-gnu.tar.gz"
if ! wget -q "$DL_URL" -O /tmp/telemt.tar.gz; then
echo -e "${RED}Не удалось скачать Telemt!${RESET}"
exit 1
fi
tar -xzf /tmp/telemt.tar.gz -C /tmp
mv /tmp/telemt /usr/local/bin/telemt
chmod +x /usr/local/bin/telemt
rm -f /tmp/telemt.tar.gz
USER_SECRET=$(openssl rand -hex 16)
mkdir -p /etc/telemt
# Создаем конфиг Telemt
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
# Создаем systemd службу
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
# Проверка работы сервиса через systemctl и ss
echo -ne "${YELLOW}Проверка службы Telemt... ${RESET}"
if systemctl is-active --quiet telemt; then
echo -e "${GREEN}РАБОТАЕТ${RESET}"
else
echo -e "${RED}НЕ РАБОТАЕТ${RESET}"
echo -e "${YELLOW}Логи службы:${RESET}"
journalctl -u telemt --no-pager -n 5
fi
echo -ne "${YELLOW}Проверка прослушивания порта 443... ${RESET}"
if ss -tulpen 2>/dev/null | grep -q ":443" || netstat -tulpen 2>/dev/null | grep -q ":443"; then
echo -e "${GREEN}ПОРТ 443 ОТКРЫТ${RESET}"
else
# Дополнительная проверка через lsof
if command -v lsof >/dev/null 2>&1 && lsof -i :443 >/dev/null 2>&1; then
echo -e "${GREEN}ПОРТ 443 ОТКРЫТ${RESET}"
else
echo -e "${YELLOW}Порт 443 не найден в списке слушающих (это может быть нормально для некоторых конфигураций)${RESET}"
fi
fi
echo -ne "${YELLOW}Проверка доступности ${PROXY_DOMAIN}... ${RESET}"
if ping -c 1 "${PROXY_DOMAIN}" >/dev/null 2>&1; then
echo -e "${GREEN}ДОСТУПЕН${RESET}"
else
echo -e "${YELLOW}Ping недоступен (может быть заблокирован фаерволом)${RESET}"
fi
# Генерация ссылки для подключения
HEX_DOMAIN=$(printf '%s' "${FAKE_DOMAIN}" | xxd -p | tr -d '\n')
FINAL_SECRET="ee${USER_SECRET}${HEX_DOMAIN}"
TG_LINK="tg://proxy?server=${PROXY_DOMAIN}&port=443&secret=${FINAL_SECRET}"
echo ""
echo -e "${CYAN}${BOLD}Ссылка для подключения к прокси:${RESET}"
echo -e "${GREEN}${TG_LINK}${RESET}"
echo ""
# ==========================================
# ЧАСТЬ 4: НАСТРОЙКА FIREWALL
# ==========================================
echo -e "${BOLD}--- НАСТРОЙКА FIREWALL (UFW) ---${RESET}"
# Разрешаем необходимые порты
ufw allow 22/tcp >/dev/null 2>&1 || true
ufw allow 443/tcp >/dev/null 2>&1
ufw allow 80/tcp >/dev/null 2>&1
ufw allow ${PANEL_PORT}/tcp >/dev/null 2>&1
# Перезагружаем UFW если он активен
if ufw status >/dev/null 2>&1; then
ufw --force reload >/dev/null 2>&1
echo -e "${GREEN}Правила firewall применены${RESET}"
echo -e "  - Порт 80 (HTTP): ${GREEN}открыт${RESET}"
echo -e "  - Порт 443 (Прокси/HTTPS): ${GREEN}открыт${RESET}"
echo -e "  - Порт ${PANEL_PORT} (Панель): ${GREEN}открыт${RESET}"
else
echo -e "${YELLOW}UFW не активен, порты будут открыты при включении${RESET}"
fi
echo ""
# ==========================================
# ЧАСТЬ 5: УСТАНОВКА WEB UI ПАНЕЛИ
# ==========================================
echo -e "${BOLD}--- УСТАНОВКА WEB UI ПАНЕЛИ ---${RESET}"
PANEL_DIR="/var/www/telemt-panel"
mkdir -p "$PANEL_DIR/templates"
# Конфигурация панели
if [[ ! -f "$PANEL_DIR/panel_config.json" ]]; then
cat > "$PANEL_DIR/panel_config.json" << EOF
{
"username": "admin",
"password_hash": "scrypt:32768:8:1\$O8eYx9aW\$...",
"is_default": true,
"proxy_host": "${PROXY_DOMAIN}",
"proxy_port": 443,
"secret_key": "$(openssl rand -hex 24)"
}
EOF
echo -e "${GREEN}Конфигурация панели создана${RESET}"
else
# Обновляем proxy_host в существующем конфиге
python3 -c "
import json
with open('$PANEL_DIR/panel_config.json', 'r') as f:
config = json.load(f)
config['proxy_host'] = '${PROXY_DOMAIN}'
config['proxy_port'] = 443
with open('$PANEL_DIR/panel_config.json', 'w') as f:
json.dump(config, f, indent=4)
" 2>/dev/null || true
echo -e "${YELLOW}Существующая конфигурация сохранена${RESET}"
fi
# Установка Python зависимостей
echo -e "${YELLOW}Настройка Python окружения...${RESET}"
if [[ ! -d "$PANEL_DIR/venv" ]]; then
python3 -m venv "$PANEL_DIR/venv"
fi
"$PANEL_DIR/venv/bin/pip" install -q --upgrade pip >/dev/null 2>&1
"$PANEL_DIR/venv/bin/pip" install -q Flask gunicorn toml werkzeug >/dev/null 2>&1
echo -e "${GREEN}Python зависимости установлены${RESET}"
# Backend приложение
cat > "$PANEL_DIR/app.py" << 'PYEOF'
import os, json, secrets, toml, subprocess, re
from flask import Flask, render_template, request, redirect, url_for, session, flash
from werkzeug.security import generate_password_hash, check_password_hash
app = Flask(__name__)
CONFIG_PATH = 'panel_config.json'
TELEMT_TOML = '/etc/telemt/telemt.toml'
def load_config():
with open(CONFIG_PATH, 'r') as f:
return json.load(f)
def save_config(data):
with open(CONFIG_PATH, 'w') as f:
json.dump(data, f, indent=4)
config = load_config()
app.secret_key = config.get('secret_key', secrets.token_hex(16))
# Если пароль по умолчанию, генерируем хэш
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
@app.before_request
def require_login():
allowed_routes = ['login']
if request.endpoint not in allowed_routes and 'user' not in session and not request.path.startswith('/static'):
return redirect(url_for('login'))
config = load_config()
if config.get('is_default') and request.endpoint not in ['change_password', 'login'] and 'user' in session:
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
tls_domain = t_config.get('censorship', {}).get('tls_domain', 'max.ru')
hex_domain = tls_domain.encode('utf-8').hex()
proxy_links = {}
for name, secret in users.items():
final_secret = f"ee{secret}{hex_domain}"
link = f"tg://proxy?server={cfg['proxy_host']}&port={cfg.get('proxy_port', 443)}&secret={final_secret}"
proxy_links[name] = {'secret': secret, 'link': link}
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
with open(TELEMT_TOML, 'w') as f:
toml.dump(t_config, f)
restart_telemt()
flash(f'Доступ для {user_key} создан!', 'success')
return redirect(url_for('dashboard'))
stats = get_proxy_stats()
return render_template('dashboard.html', links=proxy_links, host=cfg['proxy_host'], stats=stats)
@app.route('/delete/<username>')
def delete_user(username):
try:
with open(TELEMT_TOML, 'r') as f:
t_config = toml.load(f)
if username in t_config.get('access', {}).get('users', {}):
del t_config['access']['users'][username]
with open(TELEMT_TOML, 'w') as f:
toml.dump(t_config, f)
restart_telemt()
flash(f'Пользователь {username} удален', 'success')
except Exception as e:
flash(f'Ошибка: {str(e)}', 'danger')
return redirect(url_for('dashboard'))
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
<style>
body { background-color: #f8f9fa; }
.container { max-width: 900px; margin-top: 2rem; }
.card { border-radius: 10px; }
</style>
</head>
<body>
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
<script src="https://cdn.jsdelivr.net/npm/bootstrap@5.3.0/dist/js/bootstrap.bundle.min.js"></script>
</body>
</html>
HTMLEOF
cat > "$PANEL_DIR/templates/login.html" << 'HTMLEOF'
{% extends "layout.html" %}
{% block content %}
<div class="row justify-content-center">
<div class="col-md-6 col-lg-5">
<div class="card shadow-sm">
<div class="card-body p-4">
<h3 class="card-title text-center mb-4">Вход в панель</h3>
<form method="POST">
<div class="mb-3">
<label class="form-label">Логин</label>
<input type="text" name="username" class="form-control" required autofocus>
</div>
<div class="mb-4">
<label class="form-label">Пароль</label>
<input type="password" name="password" class="form-control" required>
</div>
<button type="submit" class="btn btn-primary w-100">Войти</button>
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
<div class="col-md-6 col-lg-5">
<div class="card border-warning shadow-sm">
<div class="card-body p-4">
<h4 class="card-title text-warning text-center">Смена пароля</h4>
<p class="text-muted text-center small">В целях безопасности измените пароль по умолчанию.</p>
<form method="POST">
<div class="mb-3">
<label class="form-label">Новый пароль</label>
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
<h2>🔐 MTProto Proxy Panel</h2>
<a href="{{ url_for('logout') }}" class="btn btn-outline-danger btn-sm">Выход</a>
</div>
<div class="card shadow-sm mb-4">
<div class="card-header bg-success text-white">
<h5 class="mb-0">➕ Создать доступ</h5>
</div>
<div class="card-body">
<form method="POST" class="row g-2 align-items-end">
<div class="col-12 col-md-5">
<label class="form-label text-muted small mb-1">Никнейм</label>
<input type="text" name="nickname" class="form-control" placeholder="Например: Ivan" required>
</div>
<div class="col-12 col-md-4">
<label class="form-label text-muted small mb-1">Устройство</label>
<select name="device" class="form-select">
<option value="Phone">📱 Телефон</option>
<option value="PC">💻 Компьютер</option>
<option value="Tablet">📟 Планшет</option>
</select>
</div>
<div class="col-12 col-md-3">
<button type="submit" class="btn btn-success w-100">Генерировать</button>
</div>
</form>
</div>
</div>
<div class="card shadow-sm mb-4">
<div class="card-header bg-primary text-white">
<h5 class="mb-0">📋 Список доступов</h5>
</div>
<div class="card-body">
<div class="table-responsive">
<table class="table table-hover align-middle">
<thead>
<tr>
<th>Имя_Устройство</th>
<th>Ссылка</th>
<th class="text-end">Действие</th>
</tr>
</thead>
<tbody>
{% if links %}
{% for name, data in links.items() %}
<tr>
<td class="fw-bold">{{ name }}</td>
<td>
<div class="input-group input-group-sm">
<input type="text" class="form-control" value="{{ data.link }}" readonly id="link-{{ loop.index }}">
<button class="btn btn-outline-secondary" type="button" onclick="navigator.clipboard.writeText(document.getElementById('link-{{ loop.index }}').value); this.textContent='✓'; setTimeout(()=>this.textContent='Копия',1500)">Копия</button>
</div>
</td>
<td class="text-end">
<a href="{{ url_for('delete_user', username=name) }}" class="btn btn-sm btn-danger" onclick="return confirm('Удалить пользователя {{ name }}?')">✕</a>
</td>
</tr>
{% endfor %}
{% else %}
<tr>
<td colspan="3" class="text-center text-muted py-4">Нет созданных пользователей</td>
</tr>
{% endif %}
</tbody>
</table>
</div>
</div>
</div>
<div class="card shadow-sm">
<div class="card-header bg-info text-white">
<div class="d-flex justify-content-between align-items-center">
<h5 class="mb-0">📊 Активные подключения</h5>
<span class="badge bg-light text-dark">{{ stats|length }} онлайн</span>
</div>
</div>
<div class="card-body">
<p class="text-muted small mb-3">Уникальные IP-адреса, подключенные в данный момент к порту 443.</p>
{% if stats %}
<div class="d-flex flex-wrap gap-2">
{% for ip in stats %}
<span class="badge bg-secondary border">{{ ip }}</span>
{% endfor %}
</div>
{% else %}
<p class="text-muted mb-0">⏳ В данный момент нет активных сессий.</p>
{% endif %}
</div>
</div>
{% endblock %}
HTMLEOF
echo -e "${GREEN}HTML шаблоны созданы${RESET}"
# Systemd служба для панели
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
# Настройка nginx для сайта-заглушки (если указан домен)
if [[ -n "${STUB_DOMAIN}" ]]; then
echo -e "${YELLOW}Настройка nginx для сайта-заглушки...${RESET}"
cat > /etc/nginx/sites-available/${STUB_DOMAIN} << NGINXEOF
server {
    listen 80;
    server_name ${STUB_DOMAIN};

    location /.well-known/acme-challenge/ {
        root /var/www/html;
    }

    location / {
        return 301 https://\$server_name\$request_uri;
    }
}

server {
    listen 443 ssl http2;
    server_name ${STUB_DOMAIN};

    ssl_certificate /etc/letsencrypt/live/${STUB_DOMAIN}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${STUB_DOMAIN}/privkey.pem;

    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;
    ssl_prefer_server_ciphers on;

    root /var/www/stub-site;
    index index.html;

    location / {
        try_files \$uri \$uri/ =404;
    }
}
NGINXEOF
ln -sf /etc/nginx/sites-available/${STUB_DOMAIN} /etc/nginx/sites-enabled/
rm -f /etc/nginx/sites-enabled/default
mkdir -p /var/www/stub-site
cat > /var/www/stub-site/index.html << 'HTMLEOF'
<!DOCTYPE html>
<html lang="ru">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>Доступ ограничен</title>
<style>
* { box-sizing: border-box; }
body { margin: 0; font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Arial, sans-serif; background: #f3f4f6; color: #111827; display: flex; flex-direction: column; height: 100vh; font-size: 15px; }
.header { height: 48px; display: flex; align-items: center; padding: 0 16px; background: #ffffff; border-bottom: 1px solid #e5e7eb; font-size: 14px; color: #374151; }
.wrapper { flex: 1; display: flex; align-items: center; justify-content: center; padding: 12px; }
.container { width: 100%; max-width: 460px; background: #ffffff; border-radius: 10px; padding: 24px 22px; box-shadow: 0 8px 20px rgba(0,0,0,0.06); text-align: center; }
h1 { font-size: 20px; margin: 0 0 8px; font-weight: 600; }
.incident { font-size: 12px; color: #6b7280; margin-bottom: 18px; word-break: break-all; }
p { font-size: 14px; margin-bottom: 12px; }
ul { list-style: none; padding: 0; margin: 14px 0; }
li { font-size: 14px; margin-bottom: 8px; padding-left: 18px; position: relative; text-align: left; }
li::before { content: ""; width: 5px; height: 5px; background: #2563eb; border-radius: 50%; position: absolute; left: 0; top: 8px; }
.timer-block { margin: 16px 0; padding: 12px; background: #f9fafb; border-radius: 6px; font-size: 13px; }
#timer { display: block; margin-top: 4px; font-size: 16px; font-weight: 600; }
.btn { width: 100%; padding: 12px; border: none; border-radius: 6px; background: #2563eb; color: white; font-size: 14px; cursor: pointer; }
.btn:hover { background: #1d4ed8; }
.support-link { display: inline-block; margin-top: 12px; font-size: 13px; color: #2563eb; text-decoration: none; }
.support-link:hover { text-decoration: underline; }
.footer { font-size: 12px; text-align: center; color: #6b7280; padding: 10px; }
@media (max-width: 480px) { body { font-size: 17px; } h1 { font-size: 24px; } p, li { font-size: 16px; } #timer { font-size: 20px; } .btn { font-size: 16px; padding: 14px; } .header { font-size: 15px; } }
@media (min-width: 481px) and (max-width: 768px) { body { font-size: 16px; } h1 { font-size: 22px; } p, li { font-size: 15px; } }
</style>
</head>
<body>
<div class="header"></div>
<div class="wrapper">
<div class="container">
<h1>Доступ ограничен</h1>
<div class="incident" id="incident-code">Инцидент: генерация...</div>
<p>Чтобы решить проблему, попробуйте сделать следующее:</p>
<ul>
<li>Немного подождать и нажать на кнопку «Обновить»</li>
<li><strong>Отключите VPN</strong>, если он используется</li>
<li>Обновить версию браузера или мобильного приложения</li>
<li>Подключиться к другой WI-FI или мобильной сети</li>
<li>Перезагрузить домашний роутер, если используется домашний WI-FI</li>
</ul>
<p style="font-size: 12px; color: #9ca3af; margin-top: 8px; margin-bottom: 14px;">Если ничего не помогает, пожалуйста, обратитесь в службу поддержки</p>
<div class="timer-block">Автоматическое обновление через:<span id="timer">05:00</span></div>
<button class="btn" onclick="location.reload()">Обновить</button>
<a href="mailto:rsoc_in@rkn.gov.ru" class="support-link">Служба поддержки</a>
</div>
</div>
<div class="footer">Роскомнадзор 2026 | E-mail: rsoc_in@rkn.gov.ru</div>
<script>
function generateIncident() { const d = new Date(); const pad = n => String(n).padStart(2,'0'); const ts = `${d.getFullYear()}${pad(d.getMonth()+1)}${pad(d.getDate())}${pad(d.getHours())}${pad(d.getMinutes())}${pad(d.getSeconds())}`; const chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789'; let rand = ''; for (let i = 0; i < 25; i++) { rand += chars[Math.floor(Math.random()*chars.length)]; } return `fab_nmk_${ts}_${rand}`; }
document.getElementById('incident-code').innerText = 'Инцидент: ' + generateIncident();
let t = 300; const el = document.getElementById('timer'); const i = setInterval(() => { t--; let m = String(Math.floor(t/60)).padStart(2,'0'); let s = String(t%60).padStart(2,'0'); el.innerText = `${m}:${s}`; if (t <= 0) { clearInterval(i); location.reload(); } }, 1000);
</script>
</body>
</html>
HTMLEOF
nginx -t >/dev/null 2>&1 && systemctl reload nginx
echo -e "${GREEN}Сайт-заглушка настроен${RESET}"
fi
sleep 2
echo -ne "${YELLOW}Проверка службы панели... ${RESET}"
if systemctl is-active --quiet telemt-panel; then
echo -e "${GREEN}РАБОТАЕТ${RESET}"
else
echo -e "${RED}НЕ РАБОТАЕТ${RESET}"
journalctl -u telemt-panel --no-pager -n 3
fi
echo ""
# ==========================================
# ЧАСТЬ 6: АВТООБНОВЛЕНИЕ
# ==========================================
echo -e "${BOLD}--- НАСТРОЙКА АВТООБНОВЛЕНИЯ ---${RESET}"
cat > /usr/local/bin/telemt-updater.sh << 'UPDATEEOF'
#!/bin/bash
# Скрипт умного автообновления ядра Telemt
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
# Настраиваем cron задачи
(crontab -l 2>/dev/null | grep -v "telemt-updater" | grep -v "certbot renew") | crontab - 2>/dev/null || true
(crontab -l 2>/dev/null 2>/dev/null; echo "0 4 * * * /usr/local/bin/telemt-updater.sh") | crontab - 2>/dev/null || true
(crontab -l 2>/dev/null 2>/dev/null; echo "0 3 * * * certbot renew --post-hook 'systemctl restart telemt telemt-panel' >/dev/null 2>&1") | crontab - 2>/dev/null || true
if [[ -n "${STUB_DOMAIN}" ]]; then
(crontab -l 2>/dev/null 2>/dev/null; echo "0 3 * * * certbot renew --post-hook 'systemctl reload nginx' >/dev/null 2>&1") | crontab - 2>/dev/null || true
fi
echo -e "${GREEN}Автообновление настроено${RESET}"
echo -e "  - Telemt: ежедневно в 04:00"
echo -e "  - Сертификаты: ежедневно в 03:00"
if [[ -n "${STUB_DOMAIN}" ]]; then
echo -e "  - Сайт-заглушка: перевыпуск сертификатов включен"
fi
echo ""
# ==========================================
# ФИНАЛЬНЫЙ ОТЧЕТ
# ==========================================
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
if [[ -n "${STUB_DOMAIN}" ]]; then
echo -e "${BOLD}🌐 САЙТ-ЗАГУШКА:${RESET}"
echo -e "   URL: ${GREEN}https://${STUB_DOMAIN}${RESET}"
echo -e "   Страница блокировки Роскомнадзора"
echo ""
fi
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
echo ""