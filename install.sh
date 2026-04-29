#!/bin/bash
set -e

# ==========================================
# Оформление консоли
# ==========================================
GREEN='\033[1;32m'
BLUE='\033[1;34m'
YELLOW='\033[1;33m'
RED='\033[1;31m'
NC='\033[0m'

echo -e "${BLUE}======================================================${NC}"
echo -e "${GREEN}  Инсталлятор MTProto Proxy + Сайт-Заглушка + Панель  ${NC}"
echo -e "${BLUE}======================================================${NC}"

# Проверка на root
if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}[Ошибка] Пожалуйста, запустите скрипт от имени root (sudo ./install.sh)${NC}"
  exit 1
fi

# ==========================================
# 1. Сбор данных от пользователя
# ==========================================
echo -e "\n${YELLOW}>>> Введите домены для настройки (они должны быть уже привязаны к IP сервера):${NC}"
read -p "1. Домен для MTProto Proxy (например, tg.example.com): " MT_DOMAIN
read -p "2. Домен для Сайта-заглушки (например, example.com): " DECOY_DOMAIN
read -p "3. Домен для Веб-панели (например, admin.example.com): " ADMIN_DOMAIN
read -p "4. Email для SSL-сертификатов Let's Encrypt: " EMAIL

# ==========================================
# 2. Установка зависимостей
# ==========================================
echo -e "\n${BLUE}[1/7] Установка необходимых пакетов...${NC}"
apt-get update > /dev/null
apt-get install -y nginx certbot python3 python3-pip python3-venv wget curl jq iptables > /dev/null

# Установка MTG (современное ядро MTProto v2)
if [ ! -f /usr/local/bin/mtg ]; then
    echo -e "${BLUE}[2/7] Скачивание ядра MTProto (mtg v2)...${NC}"
    wget -qO mtg.tar.gz https://github.com/9seconds/mtg/releases/download/v2.1.7/mtg-2.1.7-linux-amd64.tar.gz
    tar -xzf mtg.tar.gz
    mv mtg-2.1.7-linux-amd64/mtg /usr/local/bin/mtg
    chmod +x /usr/local/bin/mtg
    rm -rf mtg.tar.gz mtg-2.1.7-linux-amd64
fi

# ==========================================
# 3. Настройка SSL сертификатов (Certbot)
# ==========================================
echo -e "\n${BLUE}[3/7] Проверка и выпуск SSL сертификатов...${NC}"
systemctl stop nginx || true

mkdir -p /var/www/certbot

for DOMAIN in "$MT_DOMAIN" "$DECOY_DOMAIN" "$ADMIN_DOMAIN"; do
    if [ ! -d "/etc/letsencrypt/live/$DOMAIN" ]; then
        echo -e "${YELLOW}Выпускаем сертификат для $DOMAIN...${NC}"
        certbot certonly --standalone --non-interactive --agree-tos -m "$EMAIL" -d "$DOMAIN" || {
            echo -e "${RED}[Ошибка] Не удалось выпустить сертификат для $DOMAIN. Проверьте A-запись DNS.${NC}"
            exit 1
        }
    else
        echo -e "${GREEN}Сертификат для $DOMAIN уже существует. Пропускаем.${NC}"
    fi
done

# ==========================================
# 4. Развертывание Сайта-Заглушки
# ==========================================
echo -e "\n${BLUE}[4/7] Установка сайта-заглушки...${NC}"
mkdir -p /var/www/decoy

cat > /var/www/decoy/index.html << 'EOF'
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
<div class="wrapper"><div class="container">
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
<div class="timer-block">Автоматическое обновление через: <span id="timer">05:00</span></div>
<button class="btn" onclick="location.reload()">Обновить</button>
<a href="mailto:rsoc_in@rkn.gov.ru" class="support-link">Служба поддержки</a>
</div></div>
<div class="footer">Роскомнадзор 2026 | E-mail: rsoc_in@rkn.gov.ru</div>
<script>
function generateIncident() {
    const d = new Date();
    const pad = n => String(n).padStart(2,'0');
    const ts = `${d.getFullYear()}${pad(d.getMonth()+1)}${pad(d.getDate())}${pad(d.getHours())}${pad(d.getMinutes())}${pad(d.getSeconds())}`;
    const chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789';
    let rand = '';
    for (let i = 0; i < 25; i++) rand += chars[Math.floor(Math.random()*chars.length)];
    return `fab_nmk_${ts}_${rand}`;
}
document.getElementById('incident-code').innerText = 'Инцидент: ' + generateIncident();
let t = 300;
const el = document.getElementById('timer');
const i = setInterval(() => {
    t--;
    let m = String(Math.floor(t/60)).padStart(2,'0');
    let s = String(t%60).padStart(2,'0');
    el.innerText = `${m}:${s}`;
    if (t <= 0) { clearInterval(i); location.reload(); }
}, 1000);
</script>
</body>
</html>
EOF

# ==========================================
# 5. Установка Веб-панели управления (Python Flask)
# ==========================================
echo -e "\n${BLUE}[5/7] Развертывание адаптивной веб-панели...${NC}"
mkdir -p /opt/proxy_panel
cd /opt/proxy_panel
python3 -m venv venv
./venv/bin/pip install flask > /dev/null

cat > /opt/proxy_panel/app.py << 'EOF'
from flask import Flask, render_template_string, request
import subprocess

app = Flask(__name__)

HTML = """
<!DOCTYPE html>
<html lang="ru">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Управление Proxy</title>
    <style>
        body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; background: #f3f4f6; color: #111827; margin: 0; padding: 16px; }
        .container { max-width: 600px; margin: 0 auto; background: #fff; border-radius: 10px; padding: 20px; box-shadow: 0 4px 6px rgba(0,0,0,0.05); }
        h1 { font-size: 22px; margin-top: 0; border-bottom: 2px solid #e5e7eb; padding-bottom: 10px; }
        h3 { margin-bottom: 8px; font-size: 16px; }
        .card { background: #f9fafb; border: 1px solid #e5e7eb; border-radius: 8px; padding: 16px; margin-bottom: 16px; }
        pre { white-space: pre-wrap; word-wrap: break-word; font-size: 13px; background: #111827; color: #10b981; padding: 12px; border-radius: 6px; overflow-x: auto; }
        .btn { display: block; width: 100%; padding: 14px; background: #059669; color: #fff; text-align: center; border: none; border-radius: 6px; font-size: 16px; cursor: pointer; text-decoration: none; margin-top: 8px; font-weight: 600; }
        .btn:hover { background: #047857; }
    </style>
</head>
<body>
    <div class="container">
        <h1>🔧 Панель управления</h1>
        
        <div class="card">
            <h3>🔗 Ссылка для подключения</h3>
            <pre>{{ link }}</pre>
        </div>

        <div class="card">
            <h3>Статус сервисов</h3>
            <pre>{{ status }}</pre>
        </div>

        <div class="card">
            <h3>🌐 Диагностика сети (IP Check)</h3>
            <p style="font-size: 13px; color: #4b5563;">Быстрая проверка доступности внешних узлов для мониторинга ограничений IP.</p>
            <form method="POST">
                <button class="btn" type="submit">Запустить проверку сети</button>
            </form>
            {% if diag %}
                <h4 style="margin-top: 16px;">Результаты:</h4>
                <pre>{{ diag }}</pre>
            {% endif %}
        </div>
    </div>
</body>
</html>
"""

@app.route('/', methods=['GET', 'POST'])
def index():
    diag_res = ""
    if request.method == 'POST':
        try:
            ping1 = subprocess.getoutput("ping -c 3 ya.ru")
            diag_res = f"--- Проверка доступности (ya.ru) ---\n{ping1}"
        except Exception as e:
            diag_res = str(e)

    status_mtg = subprocess.getoutput("systemctl is-active mtg")
    status_nginx = subprocess.getoutput("systemctl is-active nginx")
    status_text = f"MTProto (mtg): {status_mtg}\nNginx (multiplex): {status_nginx}"
    
    try:
        with open("/etc/mtg/link.txt", "r") as f:
            link = f.read().strip()
    except:
        link = "Ссылка генерируется..."

    return render_template_string(HTML, status=status_text, diag=diag_res, link=link)

if __name__ == '__main__':
    app.run(host='127.0.0.1', port=5000)
EOF

# Сервис для веб-панели
cat > /etc/systemd/system/proxypanel.service << EOF
[Unit]
Description=Proxy Admin Panel
After=network.target

[Service]
User=root
WorkingDirectory=/opt/proxy_panel
ExecStart=/opt/proxy_panel/venv/bin/python app.py
Restart=always

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable proxypanel
systemctl restart proxypanel

# ==========================================
# 6. Настройка Nginx (Multiplexing 443 -> Proxy / Decoy)
# ==========================================
echo -e "\n${BLUE}[6/7] Конфигурация Nginx SNI Multiplexing...${NC}"

# Включаем stream модуль в главном конфиге Nginx, если его нет
if ! grep -q "stream {" /etc/nginx/nginx.conf; then
    sed -i '/http {/i \
stream {\n\
    map $ssl_preread_server_name $backend {\n\
        '"$MT_DOMAIN"' mtproto;\n\
        default web;\n\
    }\n\
    upstream mtproto { server 127.0.0.1:8443; }\n\
    upstream web { server 127.0.0.1:8444; }\n\
    server {\n\
        listen 443;\n\
        proxy_pass $backend;\n\
        ssl_preread on;\n\
    }\n\
}\n' /etc/nginx/nginx.conf
fi

# Настройка HTTP и внутренних HTTPS блоков
cat > /etc/nginx/conf.d/proxy_infrastructure.conf << EOF
# Обработчик для Let's Encrypt и редирект HTTP -> HTTPS
server {
    listen 80;
    server_name $MT_DOMAIN $DECOY_DOMAIN $ADMIN_DOMAIN;

    location /.well-known/acme-challenge/ {
        root /var/www/certbot;
    }
    location / {
        return 301 https://\$host\$request_uri;
    }
}

# Внутренний HTTPS для сайта-заглушки (порт 8444)
server {
    listen 8444 ssl;
    server_name $DECOY_DOMAIN;

    ssl_certificate /etc/letsencrypt/live/$DECOY_DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$DECOY_DOMAIN/privkey.pem;

    root /var/www/decoy;
    index index.html;
}

# Внешний HTTPS для веб-панели (порт 4444)
server {
    listen 4444 ssl;
    server_name $ADMIN_DOMAIN;

    ssl_certificate /etc/letsencrypt/live/$ADMIN_DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$ADMIN_DOMAIN/privkey.pem;

    location / {
        proxy_pass http://127.0.0.1:5000;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
    }
}
EOF

# ==========================================
# 7. Запуск MTProto (MTG)
# ==========================================
echo -e "\n${BLUE}[7/7] Генерация секретов и запуск MTProto...${NC}"
mkdir -p /etc/mtg
# Генерируем секрет FakeTLS маскирующийся под домен MTProto
SECRET=$(mtg generate-secret tls -c "$MT_DOMAIN")

cat > /etc/systemd/system/mtg.service << EOF
[Unit]
Description=MTProto Proxy (MTG v2)
After=network.target

[Service]
ExecStart=/usr/local/bin/mtg run-conf /etc/mtg/config.toml
Restart=always
RestartSec=3
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

cat > /etc/mtg/config.toml << EOF
secret = "${SECRET}"
bind-to = "127.0.0.1:8443"
EOF

# Генерация красивой ссылки
IP=$(curl -s -4 ifconfig.me)
PROXY_LINK="tg://proxy?server=${IP}&port=443&secret=${SECRET}"
echo "$PROXY_LINK" > /etc/mtg/link.txt

# Перезапуск всех сервисов
systemctl daemon-reload
systemctl enable mtg
systemctl restart mtg
systemctl restart nginx

# ==========================================
# Финал
# ==========================================
echo -e "\n${GREEN}======================================================${NC}"
echo -e "${GREEN}  УСТАНОВКА УСПЕШНО ЗАВЕРШЕНА!${NC}"
echo -e "${GREEN}======================================================${NC}"
echo -e "${YELLOW}Ваши данные для доступа:${NC}"
echo -e "1. Ссылка на MTProto: \n   ${GREEN}${PROXY_LINK}${NC}"
echo -e "2. Сайт-заглушка:     ${BLUE}https://${DECOY_DOMAIN}${NC}"
echo -e "3. Админ Панель:      ${BLUE}https://${ADMIN_DOMAIN}:4444${NC}"
echo -e "\n${YELLOW}Важно:${NC} SSL-сертификаты будут обновляться автоматически. Панель управления адаптирована для экранов мобильных устройств."
