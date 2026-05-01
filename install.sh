#!/bin/bash
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

clear
echo -e "${CYAN}${BOLD}MTProto Enhanced Installer${RESET}"

if [[ $EUID -ne 0 ]]; then
  echo -e "${RED}Запусти от root${RESET}"
  exit 1
fi

echo -e "${YELLOW}Установка зависимостей...${RESET}"
apt-get update -qq
apt-get install -y curl wget jq openssl certbot xxd socat ufw python3 python3-pip python3-venv sqlite3 qrencode >/dev/null

# === ШАГ 1. ЗАПУСК ТВОЕГО ОРИГИНАЛЬНОГО INSTALLER ===
echo -e "${CYAN}Запускаю оригинальный install.sh...${RESET}"

curl -fsSL https://raw.githubusercontent.com/GamesFanTeam/MTProto-Proxy/main/install.sh -o /tmp/original.sh
chmod +x /tmp/original.sh
bash /tmp/original.sh

# === ШАГ 2. ДОБАВЛЕНИЕ ФУНКЦИОНАЛА ===

echo -e "${CYAN}Добавляю расширенный функционал...${RESET}"

PANEL_DIR="/var/www/telemt-panel"
DATA_DIR="/var/lib/telemt-panel"
mkdir -p "$DATA_DIR"

# доп пакеты
if [[ -d "$PANEL_DIR/venv" ]]; then
  "$PANEL_DIR/venv/bin/pip" install qrcode[pil] pillow >/dev/null
fi

# === БАЗА ДАННЫХ ===
DB="$DATA_DIR/db.sqlite"

sqlite3 $DB <<EOF
CREATE TABLE IF NOT EXISTS users (
id INTEGER PRIMARY KEY,
name TEXT,
secret TEXT,
enabled INTEGER,
created INTEGER,
expires INTEGER,
traffic_up INTEGER DEFAULT 0,
traffic_down INTEGER DEFAULT 0
);
EOF

# === WATCHDOG ===
cat > /usr/local/bin/mtproto-watchdog.sh <<'EOF'
#!/bin/bash
if ! systemctl is-active --quiet telemt; then
  systemctl restart telemt
fi
EOF

chmod +x /usr/local/bin/mtproto-watchdog.sh

(crontab -l 2>/dev/null; echo "* * * * * /usr/local/bin/mtproto-watchdog.sh") | crontab -

# === ПАТЧ ПАНЕЛИ ===
cat > $PANEL_DIR/app.py <<'PY'
import sqlite3, time, secrets, subprocess, io
from flask import Flask, render_template, request, redirect, url_for, send_file
import qrcode

app = Flask(__name__)
app.secret_key = "secret"

DB = "/var/lib/telemt-panel/db.sqlite"

def db():
    conn = sqlite3.connect(DB)
    conn.row_factory = sqlite3.Row
    return conn

def restart():
    subprocess.run(["systemctl","restart","telemt"])

@app.route("/", methods=["GET","POST"])
def index():
    conn = db()
    if request.method == "POST":
        name = request.form["name"]
        secret = secrets.token_hex(16)
        now = int(time.time())
        conn.execute("INSERT INTO users(name,secret,enabled,created,expires) VALUES(?,?,?,?,?)",
                     (name, secret, 1, now, now + 2592000))
        conn.commit()
        restart()

    users = conn.execute("SELECT * FROM users").fetchall()
    return render_template("dashboard.html", users=users)

@app.route("/toggle/<int:id>")
def toggle(id):
    conn = db()
    u = conn.execute("SELECT enabled FROM users WHERE id=?", (id,)).fetchone()
    conn.execute("UPDATE users SET enabled=? WHERE id=?", (0 if u["enabled"] else 1, id))
    conn.commit()
    restart()
    return redirect("/")

@app.route("/delete/<int:id>")
def delete(id):
    conn = db()
    conn.execute("DELETE FROM users WHERE id=?", (id,))
    conn.commit()
    restart()
    return redirect("/")

@app.route("/qr/<int:id>")
def qr(id):
    conn = db()
    u = conn.execute("SELECT * FROM users WHERE id=?", (id,)).fetchone()
    link = f"tg://proxy?server=YOUR_IP&port=443&secret=ee{u['secret']}"
    img = qrcode.make(link)
    buf = io.BytesIO()
    img.save(buf)
    buf.seek(0)
    return send_file(buf, mimetype="image/png")

@app.route("/restart")
def restart_btn():
    restart()
    return redirect("/")

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=4444)
PY

# === HTML ===
cat > $PANEL_DIR/templates/dashboard.html <<'HTML'
<html>
<body>
<h2>MTProto Panel</h2>

<form method="post">
<input name="name" placeholder="Имя">
<button>Создать</button>
</form>

<br>

{% for u in users %}
<div>
<b>{{u.name}}</b>
{% if u.enabled %}
[ВКЛ]
{% else %}
[ВЫКЛ]
{% endif %}

<a href="/toggle/{{u.id}}">ON/OFF</a>
<a href="/qr/{{u.id}}">QR</a>
<a href="/delete/{{u.id}}">DEL</a>
</div>
{% endfor %}

<br>
<a href="/restart">RESTART PROXY</a>

</body>
</html>
HTML

systemctl restart telemt-panel

echo -e "${GREEN}ГОТОВО${RESET}"
