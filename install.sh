#!/bin/bash
set -e

# ==========================================
# Цвета и оформление
# ==========================================
GREEN='\033[1;32m'
BLUE='\033[1;34m'
YELLOW='\033[1;33m'
RED='\033[1;31m'
NC='\033[0m'

echo -e "${BLUE}======================================================${NC}"
echo -e "${GREEN}  PRODUCTION INSTALLER: MTProto + Decoy + Admin      ${NC}"
echo -e "${BLUE}======================================================${NC}"

if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}[Ошибка] Запустите от root (sudo)${NC}"
  exit 1
fi

# ==========================================
# 1. Запрос данных
# ==========================================
echo -e "\n${YELLOW}>>> Настройка доменов:${NC}"
read -p "1. Домен прокси (напр. tg.hid-net.ru): " MT_DOMAIN
read -p "2. Домен заглушки (напр. hid-net.ru): " DECOY_DOMAIN
read -p "3. Домен админ-панели (напр. admin.hid-net.ru): " ADMIN_DOMAIN
read -p "4. Email для SSL: " EMAIL

# ==========================================
# 2. Подготовка системы
# ==========================================
echo -e "\n${BLUE}[1/7] Установка системных утилит...${NC}"
apt-get update > /dev/null
apt-get install -y nginx certbot python3 python3-pip python3-venv wget curl jq xxd openssl > /dev/null

if [ ! -f /usr/local/bin/mtg ]; then
    echo -e "${BLUE}[2/7] Загрузка ядра MTProto (mtg 2.1.7)...${NC}"
    wget -qO mtg.tar.gz https://github.com/9seconds/mtg/releases/download/v2.1.7/mtg-2.1.7-linux-amd64.tar.gz
    tar -xzf mtg.tar.gz
    mv mtg-2.1.7-linux-amd64/mtg /usr/local/bin/mtg
    chmod +x /usr/local/bin/mtg
    rm -rf mtg.tar.gz mtg-2.1.7-linux-amd64
fi

# ==========================================
# 3. SSL Сертификаты
# ==========================================
echo -e "\n${BLUE}[3/7] Получение SSL сертификатов...${NC}"
systemctl stop nginx || true
mkdir -p /var/www/certbot

for DOMAIN in "$MT_DOMAIN" "$DECOY_DOMAIN" "$ADMIN_DOMAIN"; do
    if [ ! -d "/etc/letsencrypt/live/$DOMAIN" ]; then
        echo -e "Выпуск для $DOMAIN..."
        certbot certonly --standalone --non-interactive --agree-tos -m "$EMAIL" -d "$DOMAIN"
    else
        echo -e "Сертификат для $DOMAIN найден."
    fi
done

# ==========================================
# 4. Сайт-Заглушка (Твой HTML)
# ==========================================
echo -e "\n${BLUE}[4/7] Развертывание сайта-заглушки...${NC}"
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
# 5. Веб-панель управления
# ==========================================
echo -e "\n${BLUE}[5/7] Установка веб-панели...${NC}"
mkdir -p /opt/proxy_panel
cd /opt/proxy_panel
python3 -m venv venv || true
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
        body { font-family: sans-serif; background: #f3f4f6; padding: 15px; margin: 0; }
        .container { max-width: 500px; margin: 0 auto; background: #fff; border-radius: 12px; padding: 20px; box-shadow: 0 4px 10px rgba(0,0,0,0.05); }
        h2 { font-size: 20px; color: #1f2937; margin-top: 0; border-bottom: 2px solid #f3f4f6; padding-bottom: 10px; }
        .status { padding: 10px; background: #ecfdf5; color: #065f46; border-radius: 6px; margin-bottom: 15px; font-size: 14px; }
        pre { background: #111827; color: #34d399; padding: 12px; border-radius: 8px; font-size: 12px; overflow-x: auto; white-space: pre-wrap; }
        .btn { display: block; width: 100%; padding: 14px; background: #2563eb; color: #fff; border: none; border-radius: 8px; font-size: 16px; font-weight: 600; cursor: pointer; }
    </style>
</head>
<body>
    <div class="container">
        <h2>🔧 Управление сервером</h2>
        <div class="status">Статус MTG: {{ status }}</div>
        <div class="status" style="background:#fef3c7; color:#92400e;">Nginx: {{ nstatus }}</div>
        <p><b>Ссылка для подключения:</b></p>
        <pre>{{ link }}</pre>
        <form method="POST"><button class="btn">Запустить диагностику IP</button></form>
        {% if diag %}<h3 style="font-size:14px;">Результат диагностики:</h3><pre>{{ diag }}</pre>{% endif %}
    </div>
</body>
</html>
"""
@app.route('/', methods=['GET', 'POST'])
def index():
    diag = ""
    if request.method == 'POST':
        diag = subprocess.getoutput("curl -s -4 https://ifconfig.me && echo ' | Соединение с Google: ' && curl -o /dev/null -s -w '%{http_code}' https://www.google.com")
    status = subprocess.getoutput("systemctl is-active mtg")
    nstatus = subprocess.getoutput("systemctl is-active nginx")
    try:
        with open("/etc/mtg/link.txt", "r") as f: link = f.read().strip()
    except: link = "Ссылка не найдена"
    return render_template_string(HTML, status=status, nstatus=nstatus, diag=diag, link=link)
if __name__ == '__main__': app.run(host='127.0.0.1', port=5000)
EOF

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
# 6. Nginx Multiplexing (SNI)
# ==========================================
echo -e "\n${BLUE}[6/7] Конфигурация Nginx Multiplexing...${NC}"

# Очистка и создание заново конфигурации stream
if grep -q "stream {" /etc/nginx/nginx.conf; then
    # Если блок уже есть, мы не будем его дублировать, просто надеемся что он корректен.
    # Но для чистоты установки на "свежий" сервер лучше добавить его правильно.
    echo "Блок stream уже присутствует в nginx.conf"
else
    sed -i '/http {/i stream {\n    map $ssl_preread_server_name $backend {\n        '"$MT_DOMAIN"' mtproto;\n        default web;\n    }\n    upstream mtproto { server 127.0.0.1:8443; }\n    upstream web { server 127.0.0.1:8444; }\n    server {\n        listen 443;\n        proxy_pass $backend;\n        ssl_preread on;\n    }\n}\n' /etc/nginx/nginx.conf
fi

cat > /etc/nginx/conf.d/proxy_infrastructure.conf << EOF
server {
    listen 80;
    server_name $MT_DOMAIN $DECOY_DOMAIN $ADMIN_DOMAIN;
    location /.well-known/acme-challenge/ { root /var/www/certbot; }
    location / { return 301 https://\$host\$request_uri; }
}
server {
    listen 8444 ssl;
    server_name $DECOY_DOMAIN;
    ssl_certificate /etc/letsencrypt/live/$DECOY_DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$DECOY_DOMAIN/privkey.pem;
    root /var/www/decoy;
    index index.html;
}
server {
    listen 4444 ssl;
    server_name $ADMIN_DOMAIN;
    ssl_certificate /etc/letsencrypt/live/$ADMIN_DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$ADMIN_DOMAIN/privkey.pem;
    location / {
        proxy_pass http://127.0.0.1:5000;
        proxy_set_header Host \$host;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    }
}
EOF

# ==========================================
# 7. MTProto (Генерация БЕЗ вызова mtg)
# ==========================================
echo -e "\n${BLUE}[7/7] Генерация секретов (Safe Mode)...${NC}"
mkdir -p /etc/mtg

# ИСПОЛЬЗУЕМ OPENSSL ДЛЯ ГЕНЕРАЦИИ, ЧТОБЫ ИЗБЕЖАТЬ ОШИБОК БИНАРНИКА MTG
CORE_HEX=$(openssl rand -hex 16)
DOMAIN_HEX=$(echo -n "$MT_DOMAIN" | xxd -p | tr -d '\n')
FINAL_SECRET="ee${CORE_HEX}${DOMAIN_HEX}"

cat > /etc/mtg/config.toml << EOF
secret = "${FINAL_SECRET}"
bind-to = "127.0.0.1:8443"
EOF

cat > /etc/systemd/system/mtg.service << EOF
[Unit]
Description=MTProto Proxy Service
After=network.target
[Service]
ExecStart=/usr/local/bin/mtg run-conf /etc/mtg/config.toml
Restart=always
LimitNOFILE=1048576
[Install]
WantedBy=multi-user.target
EOF

IP=$(curl -s -4 ifconfig.me)
LINK="tg://proxy?server=${IP}&port=443&secret=${FINAL_SECRET}"
echo "$LINK" > /etc/mtg/link.txt

systemctl daemon-reload
systemctl enable mtg
systemctl restart mtg
systemctl restart nginx

echo -e "\n${GREEN}======================================================${NC}"
echo -e "${GREEN}  ВСЕ СЕРВИСЫ ЗАПУЩЕНЫ УСПЕШНО!${NC}"
echo -e "${GREEN}======================================================${NC}"
echo -e "${YELLOW}MTProto Link:${NC} ${GREEN}$LINK${NC}"
echo -e "${YELLOW}Сайт-заглушка:${NC} https://$DECOY_DOMAIN"
echo -e "${YELLOW}Админ-панель:${NC}  https://$ADMIN_DOMAIN:4444"
