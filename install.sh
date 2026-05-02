#!/usr/bin/env bash
set -Eeuo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
BOLD='\033[1m'
RESET='\033[0m'

TOTAL_STEPS=11
STEP_NOW=0

log() { printf "%b\n" "$*"; }

progress() {
  local pct=$(( STEP_NOW * 100 / TOTAL_STEPS ))
  local filled=$(( pct / 5 ))
  local empty=$(( 20 - filled ))
  local bar
  bar=$(printf "%${filled}s" "" | tr ' ' '█')
  bar+=$(printf "%${empty}s" "" | tr ' ' '░')
  printf "\r${CYAN}%s${RESET} [%s] %3d%%" "$1" "$bar" "$pct"
}

step_done() {
  STEP_NOW=$((STEP_NOW+1))
  progress "$1"
  printf "\n"
}

trap 'printf "\n%b\n" "${RED}${BOLD}Установка завершилась НЕУСПЕШНО на строке ${LINENO}.${RESET}" >&2' ERR

print_banner() {
  printf "%b\n" "${CYAN}${BOLD}"
  printf "  ███╗   ███╗████████╗██████╗ ██████╗  ██████╗ ████████╗ ██████╗ \n"
  printf "  ████╗ ████║╚══██╔══╝██╔══██╗██╔══██╗██╔═══██╗╚══██╔══╝██╔═══██╗\n"
  printf "  ██╔████╔██║   ██║   ██████╔╝██████╔╝██║   ██║   ██║   ██║   ██║\n"
  printf "  ██║╚██╔╝██║   ██║   ██╔═══╝ ██╔══██╗██║   ██║   ██║   ██║   ██║\n"
  printf "  ██║ ╚═╝ ██║   ██║   ██║     ██║  ██║╚██████╔╝   ██║   ╚██████╔╝\n"
  printf "  ╚═╝     ╚═╝   ╚═╝   ╚═╝     ╚═╝  ╚═╝ ╚═════╝    ╚═╝   ╚═════╝  \n"
  printf "%b\n" "${RESET}${MAGENTA}          MTProto Proxy Panel Installer by Mr_EFES${RESET}"
  printf "\n"
}

issue_ssl() {
  local domain="$1"
  local email="$2"
  local cert_path="/etc/letsencrypt/live/${domain}/fullchain.pem"
  if [[ -f "$cert_path" ]]; then
    if openssl x509 -in "$cert_path" -noout -checkend 86400 >/dev/null 2>&1; then
      echo "exist"
      return 0
    fi
  fi

  if [[ -n "$email" ]]; then
    certbot certonly --standalone -d "$domain" --email "$email" --agree-tos --non-interactive >/dev/null 2>&1
  else
    certbot certonly --standalone -d "$domain" --register-unsafely-without-email --agree-tos --non-interactive >/dev/null 2>&1
  fi

  if [[ -f "$cert_path" ]]; then
    [[ -f "$cert_path" ]] && echo "new" || echo "error"
  else
    echo "error"
  fi
}

validate_domain() {
  local value="$1"
  [[ "$value" =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$ ]]
}

validate_port() {
  local value="$1"
  [[ "$value" =~ ^[0-9]+$ ]] && (( value >= 1 && value <= 65535 ))
}

print_banner

if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
  log "${RED}Ошибка: запустите скрипт от имени root.${RESET}"
  exit 1
fi

log "${YELLOW}Проверяю окружение и ставлю зависимости...${RESET}"
apt-get update -y
apt-get install -y curl wget jq openssl certbot xxd socat ufw python3 python3-pip python3-venv iproute2 net-tools qrencode sqlite3
step_done "Пакеты установлены"

read -rp "1. Укажите Домен ПРОКСИ (напр. tg.example.com): " PROXY_DOMAIN
validate_domain "${PROXY_DOMAIN:-}" || { log "${RED}Домен прокси обязателен и должен быть корректным FQDN.${RESET}"; exit 1; }

read -rp "2. Укажите Домен ПАНЕЛИ (напр. admin.example.com): " PANEL_DOMAIN
validate_domain "${PANEL_DOMAIN:-}" || { log "${RED}Домен панели обязателен и должен быть корректным FQDN.${RESET}"; exit 1; }

read -rp "3. Укажите порт ПАНЕЛИ [по умолчанию будет 4444]: " PANEL_PORT_INPUT
PANEL_PORT="${PANEL_PORT_INPUT:-4444}"
validate_port "${PANEL_PORT}" || { log "${RED}Порт панели должен быть числом от 1 до 65535.${RESET}"; exit 1; }

read -rp "Введите Email для Let's Encrypt (необязательно): " CERT_EMAIL

log ""
log "${BOLD}Выберите домен для Fake TLS маскировки:${RESET}"
log "1) ads.x5.ru"
log "2) 1c.ru"
log "3) ozon.ru"
log "4) vk.com"
log "5) max.ru"
log "6) Свой Вариант"
read -rp "Ваш выбор [1-6, Enter = 1, или сразу домен]: " FAKE_CHOICE
case "${FAKE_CHOICE:-1}" in
  1) FAKE_DOMAIN="ads.x5.ru" ;;
  2) FAKE_DOMAIN="1c.ru" ;;
  3) FAKE_DOMAIN="ozon.ru" ;;
  4) FAKE_DOMAIN="vk.com" ;;
  5) FAKE_DOMAIN="max.ru" ;;
  6)
    read -rp "Введите свой домен для Fake TLS маскировки: " FAKE_DOMAIN
    [[ -n "${FAKE_DOMAIN:-}" ]] || { log "${RED}Свой домен не может быть пустым.${RESET}"; exit 1; }
    ;;
  *)
    FAKE_DOMAIN="${FAKE_CHOICE}"
    ;;
esac
validate_domain "${FAKE_DOMAIN:-}" || { log "${RED}Домен FakeTLS/SNI должен быть корректным FQDN.${RESET}"; exit 1; }

INITIAL_USERNAME="default_phone"
INITIAL_SECRET="$(openssl rand -hex 16)"

log "${CYAN}Параметры:${RESET}"
log "  Прокси: ${PROXY_DOMAIN}:443"
log "  Панель: https://${PANEL_DOMAIN}:${PANEL_PORT}"
log "  FakeTLS SNI: ${FAKE_DOMAIN}"
if [[ -n "${CERT_EMAIL}" ]]; then
  log "  Email SSL: ${CERT_EMAIL}"
else
  log "  Email SSL: не указан"
fi
log ""

log "${YELLOW}Выпускаю/обновляю SSL для прокси...${RESET}"
case "$(issue_ssl "$PROXY_DOMAIN" "$CERT_EMAIL")" in
  exist) log "${GREEN}SSL для прокси уже действителен.${RESET}" ;;
  new) log "${GREEN}SSL для прокси выпущен.${RESET}" ;;
  error) log "${RED}Не удалось получить SSL для прокси.${RESET}"; exit 1 ;;
esac

log "${YELLOW}Выпускаю/обновляю SSL для панели...${RESET}"
case "$(issue_ssl "$PANEL_DOMAIN" "$CERT_EMAIL")" in
  exist) log "${GREEN}SSL для панели уже действителен.${RESET}" ;;
  new) log "${GREEN}SSL для панели выпущен.${RESET}" ;;
  error) log "${RED}Не удалось получить SSL для панели.${RESET}"; exit 1 ;;
esac
step_done "SSL готов"

systemctl stop nginx apache2 2>/dev/null || true

ARCH="$(uname -m)"
case "$ARCH" in
  x86_64) BIN_ARCH="x86_64" ;;
  aarch64|arm64) BIN_ARCH="aarch64" ;;
  *) log "${RED}Неподдерживаемая архитектура: $ARCH${RESET}"; exit 1 ;;
esac

log "${YELLOW}Скачиваю telemt...${RESET}"
TMP_DIR="$(mktemp -d)"
wget -q "https://github.com/telemt/telemt/releases/latest/download/telemt-${BIN_ARCH}-linux-gnu.tar.gz" -O "${TMP_DIR}/telemt.tar.gz"
tar -xzf "${TMP_DIR}/telemt.tar.gz" -C "${TMP_DIR}"
install -m 755 "${TMP_DIR}/telemt" /usr/local/bin/telemt
rm -rf "${TMP_DIR}"
step_done "telemt установлен"

API_TOKEN="$(openssl rand -hex 24)"
PANEL_ADMIN_USER="admin"
PANEL_ADMIN_PASS="$(openssl rand -base64 18 | tr -dc 'A-Za-z0-9' | head -c 16)"
PANEL_SECRET_KEY="$(openssl rand -hex 32)"

mkdir -p /etc/telemt /var/lib/telemt-panel /var/www/telemt-panel/templates

cat > /etc/telemt/telemt.toml <<EOF
[general]
use_middle_proxy = true
log_level = "normal"

[general.modes]
classic = false
secure = false
tls = true

[general.links]
show = "*"
public_host = "${PROXY_DOMAIN}"
public_port = 443

[server]
port = 443

[server.api]
enabled = true
listen = "127.0.0.1:9091"
whitelist = ["127.0.0.1/32", "::1/128"]
auth_header = "${API_TOKEN}"
minimal_runtime_enabled = false
minimal_runtime_cache_ttl_ms = 1000
runtime_edge_enabled = true
runtime_edge_cache_ttl_ms = 1000

[[server.listeners]]
ip = "0.0.0.0"

[censorship]
tls_domain = "${FAKE_DOMAIN}"
mask = true
tls_emulation = true
tls_front_dir = "tlsfront"

[access.users]
${INITIAL_USERNAME} = "${INITIAL_SECRET}"
EOF

cat > /etc/systemd/system/telemt.service <<EOF
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
Environment=RUST_LOG=info

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable telemt --now
sleep 2
if systemctl is-active --quiet telemt; then
  log "${GREEN}telemt запущен.${RESET}"
else
  log "${RED}telemt не стартовал. Смотри journalctl -u telemt.${RESET}"
  journalctl -u telemt --no-pager -n 20 || true
  exit 1
fi
step_done "telemt запущен"

ufw allow 22/tcp >/dev/null 2>&1 || true
ufw allow 443/tcp >/dev/null 2>&1 || true
ufw allow "${PANEL_PORT}"/tcp >/dev/null 2>&1 || true
ufw reload >/dev/null 2>&1 || true
step_done "Firewall настроен"

PANEL_DIR="/var/www/telemt-panel"
APP_DIR="/var/lib/telemt-panel"

cat > "${PANEL_DIR}/app.py" <<'PYEOF'
import io
import json
import os
import sqlite3
import subprocess
import secrets
import re
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timedelta, timezone

import qrcode
import toml
from flask import Flask, flash, redirect, render_template, request, send_file, session, url_for
from werkzeug.security import check_password_hash, generate_password_hash

APP_DIR = "/var/lib/telemt-panel"
DB_PATH = os.path.join(APP_DIR, "panel.db")
TELEMT_TOML = "/etc/telemt/telemt.toml"
ACCESS_PERIOD_SECONDS = 31 * 24 * 3600 - 60

app = Flask(__name__)
app.secret_key = os.environ.get("PANEL_SECRET_KEY", "change-me")

def db():
    conn = sqlite3.connect(DB_PATH)
    conn.row_factory = sqlite3.Row
    return conn

def init_db():
    os.makedirs(APP_DIR, exist_ok=True)
    conn = db()
    cur = conn.cursor()
    cur.execute("""
        CREATE TABLE IF NOT EXISTS admin (
            id INTEGER PRIMARY KEY CHECK(id=1),
            username TEXT NOT NULL,
            password_hash TEXT NOT NULL
        )
    """)
    cur.execute("""
        CREATE TABLE IF NOT EXISTS settings (
            key TEXT PRIMARY KEY,
            value TEXT NOT NULL
        )
    """)
    cur.execute("""
        CREATE TABLE IF NOT EXISTS accesses (
            username TEXT PRIMARY KEY,
            device TEXT NOT NULL,
            secret TEXT NOT NULL,
            created_at TEXT NOT NULL,
            duration_seconds INTEGER NOT NULL,
            paused_total_seconds INTEGER NOT NULL DEFAULT 0,
            paused_since TEXT,
            paused_remaining_seconds INTEGER,
            auto_paused_at TEXT,
            status TEXT NOT NULL,
            expires_at TEXT NOT NULL
        )
    """)
    conn.commit()
    conn.close()

def get_setting(key, default=""):
    conn = db()
    row = conn.execute("SELECT value FROM settings WHERE key = ?", (key,)).fetchone()
    conn.close()
    return row["value"] if row else default

def set_setting(key, value):
    conn = db()
    conn.execute(
        "INSERT INTO settings(key, value) VALUES(?, ?) "
        "ON CONFLICT(key) DO UPDATE SET value=excluded.value",
        (key, value),
    )
    conn.commit()
    conn.close()

def get_admin():
    conn = db()
    row = conn.execute("SELECT username, password_hash FROM admin WHERE id = 1").fetchone()
    conn.close()
    return row

def set_admin(username, password_hash):
    conn = db()
    conn.execute(
        "INSERT INTO admin(id, username, password_hash) VALUES(1, ?, ?) "
        "ON CONFLICT(id) DO UPDATE SET username=excluded.username, password_hash=excluded.password_hash",
        (username, password_hash),
    )
    conn.commit()
    conn.close()

def utcnow():
    return datetime.now(timezone.utc)

def iso_now():
    return utcnow().replace(microsecond=0).isoformat()

def parse_dt(value):
    if not value:
        return None
    try:
        return datetime.fromisoformat(value.replace("Z", "+00:00"))
    except Exception:
        return None

def fmt_rfc3339(dt):
    return dt.astimezone(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")

def duration_left(row):
    now = utcnow()
    created = parse_dt(row["created_at"]) or now
    duration = int(row["duration_seconds"])
    paused_total = int(row["paused_total_seconds"] or 0)
    paused_since = parse_dt(row["paused_since"])

    if row["status"] == "active":
        elapsed = (now - created).total_seconds() - paused_total
    elif row["status"] in ("paused", "auto_paused"):
        if paused_since:
            elapsed = (paused_since - created).total_seconds() - paused_total
        else:
            elapsed = (now - created).total_seconds() - paused_total
    else:
        elapsed = (now - created).total_seconds() - paused_total

    remaining = int(duration - elapsed)
    return max(0, remaining)

def fmt_remaining(seconds):
    seconds = max(0, int(seconds))
    days = seconds // 86400
    hours = (seconds % 86400) // 3600
    minutes = (seconds % 3600) // 60
    return f"{days} дней {hours} часов {minutes} минут"

def fmt_duration(total):
    total = max(0, int(total))
    days = total // 86400
    hours = (total % 86400) // 3600
    minutes = (total % 3600) // 60
    if days > 0:
        return f"{days} дней {hours} часов {minutes} минут"
    if hours > 0:
        return f"{hours} часов {minutes} минут"
    return f"{minutes} минут"

def system_uptime():
    try:
        with open("/proc/uptime", "r", encoding="utf-8") as f:
            total = float(f.read().split()[0])
        return fmt_duration(total)
    except Exception:
        return "н/д"

def service_uptime(service="telemt"):
    try:
        service_us = subprocess.check_output(
            ["systemctl", "show", service, "-p", "ActiveEnterTimestampMonotonic", "--value"],
            text=True,
            stderr=subprocess.DEVNULL,
        ).strip()
        if not service_us or service_us == "0":
            return "н/д"
        service_us = int(service_us)
        with open("/proc/uptime", "r", encoding="utf-8") as f:
            boot_uptime = float(f.read().split()[0])
        current_us = int(boot_uptime * 1_000_000)
        return fmt_duration((current_us - service_us) / 1_000_000)
    except Exception:
        return "н/д"

def telemt_running():
    try:
        r = subprocess.run(["systemctl", "is-active", "--quiet", "telemt"], timeout=5)
        return r.returncode == 0
    except Exception:
        return False

def restart_telemt():
    subprocess.run(["systemctl", "restart", "telemt"], check=False)

def telemt_api_request(method, path, data=None):
    token = get_setting("telemt_api_token")
    url = f"http://127.0.0.1:9091{path}"
    headers = {
        "Authorization": token,
        "Content-Type": "application/json",
    }
    body = None
    if data is not None:
        body = json.dumps(data).encode("utf-8")
    req = urllib.request.Request(url, data=body, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=12) as resp:
            raw = resp.read().decode("utf-8")
            payload = json.loads(raw) if raw else {}
    except urllib.error.HTTPError as exc:
        try:
            payload = json.loads(exc.read().decode("utf-8"))
            message = payload.get("error", {}).get("message") or payload.get("message") or str(exc)
        except Exception:
            message = str(exc)
        raise RuntimeError(message)
    except urllib.error.URLError as exc:
        raise RuntimeError(str(exc)) from exc

    if isinstance(payload, dict) and payload.get("ok") is True and "data" in payload:
        return payload["data"]
    return payload

def telemt_api_get(path):
    return telemt_api_request("GET", path)

def telemt_api_post(path, data):
    return telemt_api_request("POST", path, data)

def telemt_api_delete(path):
    return telemt_api_request("DELETE", path)

def telemt_create_user(username, secret, expiration_rfc3339):
    return telemt_api_post("/v1/users", {
        "username": username,
        "secret": secret,
        "expiration_rfc3339": expiration_rfc3339,
    })

def normalize_ip_list(value):
    if isinstance(value, list):
        return [str(item) for item in value if item]
    return []

def load_online_users():
    online = {}
    for endpoint in ("/v1/stats/users/active-ips", "/v1/stats/users", "/v1/users", "/v1/runtime/connections/summary"):
        try:
            payload = telemt_api_get(endpoint)
        except Exception:
            continue
        if isinstance(payload, dict):
            for key in ("users", "active_users", "connections", "items"):
                if isinstance(payload.get(key), list):
                    payload = payload[key]
                    break
        if not isinstance(payload, list):
            continue
        for user in payload:
            if not isinstance(user, dict):
                continue
            username = user.get("username")
            if not username:
                continue
            item = online.setdefault(str(username), {"connections": 0, "ips": set()})
            for key in ("active_ips", "active_unique_ips_list", "active_ip_list", "recent_ips"):
                for ip in normalize_ip_list(user.get(key)):
                    item["ips"].add(ip)
            for key in ("current_connections", "active_connections", "tcp_connections"):
                value = user.get(key)
                if isinstance(value, int):
                    item["connections"] = max(item["connections"], value)
            if item["ips"] and item["connections"] == 0:
                item["connections"] = len(item["ips"])
        if online:
            break
    return online

def make_link(secret):
    host = get_setting("proxy_host", "127.0.0.1")
    port = get_setting("proxy_port", "443")
    tls_domain = get_setting("fake_tls_domain", "ads.x5.ru")
    return f"tg://proxy?server={host}&port={port}&secret=ee{secret}{tls_domain.encode('utf-8').hex()}"

def qr_png_bytes(link):
    img = qrcode.make(link)
    buf = io.BytesIO()
    img.save(buf, format="PNG")
    buf.seek(0)
    return buf

def ensure_admin():
    if get_admin() is None:
        username = get_setting("default_admin_username", "admin")
        password = get_setting("default_admin_password", "admin")
        set_admin(username, generate_password_hash(password))

@app.before_request
def auth_guard():
    allowed = {"login", "static"}
    if request.endpoint in allowed or request.path.startswith("/static"):
        return None
    if "admin" not in session:
        return redirect(url_for("login"))
    admin = get_admin()
    if not admin:
        session.clear()
        return redirect(url_for("login"))
    if request.endpoint == "dashboard":
        return None

@app.route("/login", methods=["GET", "POST"])
def login():
    admin = get_admin()
    server_status = "Работает" if telemt_running() else "Отключен"
    if request.method == "POST":
        if admin and request.form.get("username") == admin["username"] and check_password_hash(admin["password_hash"], request.form.get("password", "")):
            session["admin"] = admin["username"]
            return redirect(url_for("dashboard"))
        flash("Неверный логин или пароль", "danger")
    return render_template("login.html", admin_username=admin["username"] if admin else "admin", server_status=server_status)

@app.route("/logout")
def logout():
    session.clear()
    return redirect(url_for("login"))

@app.route("/")
def dashboard():
    conn = db()
    accesses = conn.execute("SELECT * FROM accesses ORDER BY datetime(created_at) DESC").fetchall()
    conn.close()

    online_users = load_online_users()
    total_created = len(accesses)
    connected_ips = set()
    active_users = 0

    rows = []
    for row in accesses:
        remaining = duration_left(row)
        status = row["status"]
        online_data = online_users.get(row["username"], {"connections": 0, "ips": set()})
        ips = online_data["ips"]
        for ip in ips:
            connected_ips.add(ip)
        current_connections = int(online_data["connections"])
        active_unique_ips = len(ips)
        online = current_connections > 0 or active_unique_ips > 0
        if online:
            active_users += 1
        rows.append({
            **dict(row),
            "remaining_text": fmt_remaining(remaining),
            "online": online,
            "online_class": "success" if online else "danger",
            "current_connections": current_connections,
            "active_unique_ips": active_unique_ips,
            "status_label": status,
            "link": make_link(row["secret"]),
        })

    server_status = "Работает" if telemt_running() else "Отключен"
    return render_template(
        "dashboard.html",
        accesses=rows,
        total_created=total_created,
        connected_ips=len(connected_ips),
        active_users=active_users,
        server_status=server_status,
        telemt_uptime=service_uptime("telemt"),
        system_uptime=system_uptime(),
        fake_tls_domain=get_setting("fake_tls_domain", "ads.x5.ru"),
        proxy_host=get_setting("proxy_host", "127.0.0.1"),
        proxy_port=get_setting("proxy_port", "443"),
    )

@app.route("/create", methods=["POST"])
def create_access():
    nickname = (request.form.get("nickname", "") or "").strip()
    device = (request.form.get("device", "") or "Phone").strip()
    if not nickname:
        flash("Укажи имя доступа", "danger")
        return redirect(url_for("dashboard"))

    base_name = re.sub(r"[^A-Za-z0-9_.-]+", "_", f"{nickname}_{device}")[:64]
    username = base_name or f"user_{secrets.token_hex(3)}"
    conn = db()
    used = conn.execute("SELECT username FROM accesses WHERE username = ?", (username,)).fetchone()
    suffix = 2
    while used:
        candidate = f"{base_name[:58]}_{suffix}"
        used = conn.execute("SELECT username FROM accesses WHERE username = ?", (candidate,)).fetchone()
        if not used:
            username = candidate[:64]
            break
        suffix += 1

    secret = secrets.token_hex(16)
    now = utcnow()
    expires = now + timedelta(seconds=ACCESS_PERIOD_SECONDS)
    try:
        telemt_create_user(username, secret, fmt_rfc3339(expires))
    except Exception as exc:
        flash(f"Не удалось создать доступ: {exc}", "danger")
        conn.close()
        return redirect(url_for("dashboard"))

    conn.execute(
        """
        INSERT INTO accesses(
            username, device, secret, created_at, duration_seconds,
            paused_total_seconds, paused_since, paused_remaining_seconds,
            auto_paused_at, status, expires_at
        ) VALUES(?,?,?,?,?,?,?,?,?,?,?)
        """,
        (
            username,
            device,
            secret,
            fmt_rfc3339(now),
            ACCESS_PERIOD_SECONDS,
            0,
            None,
            None,
            None,
            "active",
            fmt_rfc3339(expires),
        ),
    )
    conn.commit()
    conn.close()
    flash(f"Доступ {username} создан", "success")
    return redirect(url_for("dashboard"))

@app.route("/toggle/<username>", methods=["POST"])
def toggle_access(username):
    conn = db()
    row = conn.execute("SELECT * FROM accesses WHERE username = ?", (username,)).fetchone()
    if not row:
        conn.close()
        flash("Доступ не найден", "danger")
        return redirect(url_for("dashboard"))

    now = utcnow()

    try:
        if row["status"] == "active":
            remaining = duration_left(row)
            conn.execute(
                "UPDATE accesses SET status=?, paused_since=?, paused_remaining_seconds=?, auto_paused_at=NULL WHERE username=?",
                ("paused", fmt_rfc3339(now), int(remaining), username),
            )
            telemt_api_delete("/v1/users/" + urllib.parse.quote(username))
            flash(f"Доступ {username} поставлен на паузу и соединение разорвано", "success")
        else:
            if row["status"] == "auto_paused":
                new_expires = now + timedelta(seconds=ACCESS_PERIOD_SECONDS)
                conn.execute(
                    """
                    UPDATE accesses
                    SET status='active',
                        created_at=?,
                        duration_seconds=?,
                        paused_total_seconds=0,
                        paused_since=NULL,
                        paused_remaining_seconds=NULL,
                        auto_paused_at=NULL,
                        expires_at=?
                    WHERE username=?
                    """,
                    (fmt_rfc3339(now), ACCESS_PERIOD_SECONDS, fmt_rfc3339(new_expires), username),
                )
                telemt_create_user(username, row["secret"], fmt_rfc3339(new_expires))
                flash(f"Доступ {username} включен и таймер сброшен на новый цикл", "success")
            else:
                paused_since = parse_dt(row["paused_since"]) or now
                remaining = int(row["paused_remaining_seconds"] or duration_left(row))
                paused_total_seconds = int(row["paused_total_seconds"] or 0) + int((now - paused_since).total_seconds())
                new_expires = now + timedelta(seconds=max(0, remaining))
                conn.execute(
                    """
                    UPDATE accesses
                    SET status='active',
                        paused_total_seconds=?,
                        paused_since=NULL,
                        paused_remaining_seconds=NULL,
                        auto_paused_at=NULL,
                        expires_at=?
                    WHERE username=?
                    """,
                    (paused_total_seconds, fmt_rfc3339(new_expires), username),
                )
                telemt_create_user(username, row["secret"], fmt_rfc3339(new_expires))
                flash(f"Доступ {username} возобновлен", "success")
        conn.commit()
    except Exception as exc:
        flash(f"Ошибка: {exc}", "danger")
    finally:
        conn.close()
    return redirect(url_for("dashboard"))

@app.route("/delete/<username>", methods=["POST"])
def delete_access(username):
    conn = db()
    row = conn.execute("SELECT * FROM accesses WHERE username = ?", (username,)).fetchone()
    if not row:
        conn.close()
        flash("Доступ не найден", "danger")
        return redirect(url_for("dashboard"))
    try:
        telemt_api_delete("/v1/users/" + urllib.parse.quote(username))
        conn.execute("DELETE FROM accesses WHERE username = ?", (username,))
        conn.commit()
        flash(f"Доступ {username} удалён", "success")
    except Exception as exc:
        flash(f"Ошибка удаления: {exc}", "danger")
    finally:
        conn.close()
    return redirect(url_for("dashboard"))

@app.route("/qr/<username>")
def qr_public(username):
    conn = db()
    row = conn.execute("SELECT * FROM accesses WHERE username = ?", (username,)).fetchone()
    conn.close()
    if not row:
        return "Not found", 404
    return send_file(qr_png_bytes(make_link(row["secret"])), mimetype="image/png", as_attachment=False, download_name=f"{username}.png")

@app.route("/link/<username>")
def open_link(username):
    conn = db()
    row = conn.execute("SELECT * FROM accesses WHERE username = ?", (username,)).fetchone()
    conn.close()
    if not row:
        return "Not found", 404
    return redirect(make_link(row["secret"]))

@app.route("/settings", methods=["GET", "POST"])
def settings():
    if request.method == "POST":
        fake_domain = (request.form.get("fake_tls_domain") or "").strip()
        proxy_host = (request.form.get("proxy_host") or "").strip()
        proxy_port = (request.form.get("proxy_port") or "443").strip()
        if not fake_domain or not proxy_host:
            flash("FakeTLS-домен и домен прокси обязательны", "danger")
            return redirect(url_for("settings"))
        if not re.match(r"^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$", fake_domain):
            flash("FakeTLS/SNI должен быть корректным доменом", "danger")
            return redirect(url_for("settings"))
        if not re.match(r"^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$", proxy_host):
            flash("Домен прокси должен быть корректным", "danger")
            return redirect(url_for("settings"))
        try:
            proxy_port_int = int(proxy_port)
            if proxy_port_int <= 0 or proxy_port_int > 65535:
                raise ValueError("invalid port")
            cfg = toml.load(TELEMT_TOML)
            cfg.setdefault("censorship", {})
            cfg["censorship"]["tls_domain"] = fake_domain
            cfg.setdefault("general", {})
            cfg["general"].setdefault("links", {})
            cfg["general"]["links"]["public_host"] = proxy_host
            cfg["general"]["links"]["public_port"] = proxy_port_int
            with open(TELEMT_TOML, "w", encoding="utf-8") as f:
                toml.dump(cfg, f)
            set_setting("fake_tls_domain", fake_domain)
            set_setting("proxy_host", proxy_host)
            set_setting("proxy_port", str(proxy_port_int))
            restart_telemt()
            flash("Настройки FakeTLS обновлены", "success")
        except Exception as exc:
            flash(f"Не удалось обновить настройки: {exc}", "danger")

    return render_template(
        "settings.html",
        fake_tls_domain=get_setting("fake_tls_domain", "ads.x5.ru"),
        proxy_host=get_setting("proxy_host", "127.0.0.1"),
        proxy_port=get_setting("proxy_port", "443"),
        server_status="Работает" if telemt_running() else "Отключен",
        telemt_uptime=service_uptime("telemt"),
        system_uptime=system_uptime(),
    )

@app.route("/admin/credentials", methods=["GET", "POST"])
def admin_credentials():
    admin = get_admin()
    server_status = "Работает" if telemt_running() else "Отключен"
    if request.method == "POST":
        current_user = request.form.get("current_username", "")
        current_pass = request.form.get("current_password", "")
        new_user = request.form.get("new_username", "").strip() or admin["username"]
        new_pass = request.form.get("new_password", "")
        if not admin or current_user != admin["username"] or not check_password_hash(admin["password_hash"], current_pass):
            flash("Текущие данные неверны", "danger")
            return redirect(url_for("admin_credentials"))
        if not new_pass:
            flash("Новый пароль обязателен", "danger")
            return redirect(url_for("admin_credentials"))
        set_admin(new_user, generate_password_hash(new_pass))
        session.clear()
        flash("Данные администратора обновлены. Войдите заново.", "success")
        return redirect(url_for("login"))
    return render_template("admin_credentials.html", current_username=admin["username"] if admin else "admin", server_status=server_status)

@app.route("/bootstrap-link")
def bootstrap_link():
    row = db().execute("SELECT * FROM accesses ORDER BY datetime(created_at) ASC LIMIT 1").fetchone()
    if not row:
        return "No bootstrap access", 404
    return redirect(url_for("qr_public", username=row["username"]))

def auto_maintain():
    conn = db()
    rows = conn.execute("SELECT * FROM accesses").fetchall()
    changed = False
    deleted_users = []
    for row in rows:
        try:
            now = utcnow()
            if row["status"] == "active":
                remaining = duration_left(row)
                if remaining <= 0:
                    conn.execute(
                        """
                        UPDATE accesses
                        SET status='auto_paused',
                            paused_since=?,
                            paused_remaining_seconds=0,
                            auto_paused_at=?,
                            expires_at=?
                        WHERE username=?
                        """,
                        (
                            fmt_rfc3339(now),
                            fmt_rfc3339(now),
                            fmt_rfc3339(now - timedelta(minutes=1)),
                            row["username"],
                        ),
                    )
                    try:
                        telemt_api_delete("/v1/users/" + urllib.parse.quote(row["username"]))
                    except Exception:
                        pass
                    changed = True
            elif row["status"] == "auto_paused":
                paused_at = parse_dt(row["auto_paused_at"]) or parse_dt(row["paused_since"]) or utcnow()
                if (utcnow() - paused_at).total_seconds() >= 2 * 24 * 3600:
                    try:
                        telemt_api_delete("/v1/users/" + urllib.parse.quote(row["username"]))
                    except Exception:
                        pass
                    conn.execute("DELETE FROM accesses WHERE username = ?", (row["username"],))
                    deleted_users.append(row["username"])
                    changed = True
        except Exception:
            pass
    if changed:
        conn.commit()
    if deleted_users:
        app.logger.info("Удалены неактивные доступы после 32-го дня: %s", ", ".join(deleted_users))
    conn.close()

if __name__ == "__main__":
    init_db()
    ensure_admin()
    auto_maintain()
    port = int(os.environ.get("PANEL_PORT", "4444"))
    app.run(host="0.0.0.0", port=port)
PYEOF

cat > "${PANEL_DIR}/templates/layout.html" <<'HTMLEOF'
<!DOCTYPE html>
<html lang="ru">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
  <title>MTProto Proxy Panel</title>
  <link href="https://cdn.jsdelivr.net/npm/bootstrap@5.3.3/dist/css/bootstrap.min.css" rel="stylesheet">
  <link href="https://cdnjs.cloudflare.com/ajax/libs/font-awesome/6.5.2/css/all.min.css" rel="stylesheet">
  <style>
    :root{
      --tg-bg:#f4f8fd;
      --tg-card:#ffffff;
      --tg-line:#dbe5f1;
      --tg-text:#0f172a;
      --tg-muted:#64748b;
      --tg-blue:#2aabee;
      --tg-green:#22c55e;
      --tg-red:#ef4444;
    }
    body{
      min-height:100vh;
      background:
        radial-gradient(circle at top left, rgba(42,171,238,.16), transparent 28%),
        radial-gradient(circle at top right, rgba(34,197,94,.12), transparent 24%),
        linear-gradient(180deg, #eef5fb 0%, #f7fbff 100%);
      color:var(--tg-text);
      font-family: Inter, "Segoe UI", system-ui, -apple-system, sans-serif;
    }
    .navbar, .card, .modal-content{
      background: rgba(255,255,255,.94) !important;
      backdrop-filter: blur(14px);
      border: 1px solid var(--tg-line);
      box-shadow: 0 14px 45px rgba(15,23,42,.08);
    }
    .navbar{ background: linear-gradient(90deg, var(--tg-blue), #6bc5f5) !important; color:#fff !important; }
    .navbar .navbar-brand, .navbar .btn, .navbar .chip{ color:#fff; }
    .navbar .btn{ border-color: rgba(255,255,255,.45); }
    .navbar .btn:hover{ background: rgba(255,255,255,.12); }
    .card{ border-radius: 22px; }
    .navbar{ border-radius: 0 0 22px 22px; }
    .page-shell{ max-width: 1360px; }
    .text-muted{ color: var(--tg-muted) !important; }
    .btn{
      border-radius: 14px;
      font-weight: 700;
    }
    .btn-primary{ background: var(--tg-blue); border-color: var(--tg-blue); }
    .btn-outline-light{ color:#fff; border-color: rgba(255,255,255,.45); }
    .btn-outline-secondary{ border-color: #cbd5e1; }
    .form-control, .form-select{
      background: #fff;
      color: var(--tg-text);
      border: 1px solid var(--tg-line);
      border-radius: 14px;
    }
    .form-control:focus, .form-select:focus{
      background: #fff;
      color: var(--tg-text);
      border-color: var(--tg-blue);
      box-shadow: 0 0 0 .2rem rgba(42,171,238,.16);
    }
    .summary-card{
      border-radius: 22px;
      padding: 1rem 1.1rem;
      height: 100%;
    }
    .summary-label{ color: var(--tg-muted); font-size: .84rem; }
    .summary-value{ font-size: 1.45rem; font-weight: 800; line-height: 1.1; word-break: break-word; }
    .access-name{ font-weight: 800; font-size: 1.03rem; }
    .access-meta{ color: var(--tg-muted); font-size: .86rem; }
    .dot{ display:inline-block; width:10px; height:10px; border-radius:999px; margin-right:.4rem; }
    .dot.green{ background: var(--tg-green); box-shadow: 0 0 0 4px rgba(34,197,94,.18); }
    .dot.red{ background: var(--tg-red); box-shadow: 0 0 0 4px rgba(239,68,68,.18); }
    .chip{ display:inline-flex; align-items:center; gap:.35rem; padding:.28rem .55rem; border-radius:999px; font-size:.82rem; border:1px solid var(--tg-line); background: rgba(255,255,255,.6); white-space: nowrap; }
    .footer{ color: var(--tg-muted); font-size: .9rem; text-align:center; padding: 1rem 0 1.6rem; }
    .access-list{ display: grid; gap: .85rem; }
    .access-card{ border: 1px solid var(--tg-line); border-radius: 18px; padding: 1rem; background: rgba(255,255,255,.72); box-shadow: 0 8px 25px rgba(15,23,42,.05); }
    .link-box{ width: 100%; min-height: 5rem; resize: vertical; font-size: .82rem; border-radius: 14px; }
    .small-btns .btn{ padding: .4rem .58rem; }
    .section-title{ display:flex; align-items:center; gap:.65rem; font-size: 1.08rem; font-weight: 800; }
    .sni-pill{ cursor:pointer; user-select:none; }
    .sni-pill:hover{ transform: translateY(-1px); }
    @media (max-width: 992px){
      .summary-value{ font-size: 1.2rem; }
      .navbar{ border-radius: 0 0 18px 18px; }
      .card{ border-radius: 18px; }
    }
  </style>
</head>
<body>
  <nav class="navbar navbar-expand-lg sticky-top mb-4">
    <div class="container-fluid page-shell px-3 px-lg-4 py-2">
      <a class="navbar-brand fw-bold d-flex align-items-center gap-2" href="{{ url_for('dashboard') }}">
        <i class="fa-brands fa-telegram"></i> MTProto Proxy Panel
      </a>
      {% if session.get('admin') %}
      <div class="ms-auto d-flex align-items-center gap-2 flex-wrap justify-content-end">
        <span class="chip"><span class="dot {{ 'green' if server_status == 'Работает' else 'red' }}"></span>{{ server_status }}</span>
        <a class="btn btn-outline-secondary btn-sm" href="{{ url_for('settings') }}"><i class="fa-solid fa-sliders me-1"></i>Настройки</a>
        <a class="btn btn-outline-secondary btn-sm" href="{{ url_for('admin_credentials') }}"><i class="fa-solid fa-user-gear me-1"></i>Админ</a>
        <a class="btn btn-outline-secondary btn-sm" href="{{ url_for('logout') }}"><i class="fa-solid fa-right-from-bracket me-1"></i>Выход</a>
      </div>
      {% endif %}
    </div>
  </nav>

  <main class="container page-shell px-3 px-lg-4">
    {% with messages = get_flashed_messages(with_categories=true) %}
      {% if messages %}
        <div class="mb-4">
        {% for category, message in messages %}
          <div class="alert alert-{{ category }} border-0 shadow-sm rounded-4 mb-2" role="alert">
            <i class="fa-solid fa-circle-info me-2"></i>{{ message }}
          </div>
        {% endfor %}
        </div>
      {% endif %}
    {% endwith %}

    {% block content %}{% endblock %}
  </main>

  <footer class="footer">
    MTProto Proxy Panel 2026 by Mr_EFES
  </footer>

  <script src="https://cdn.jsdelivr.net/npm/bootstrap@5.3.3/dist/js/bootstrap.bundle.min.js"></script>
  {% block scripts %}{% endblock %}
</body>
</html>
HTMLEOF

cat > "${PANEL_DIR}/templates/login.html" <<'HTMLEOF'
{% extends "layout.html" %}
{% block content %}
<div class="row justify-content-center align-items-center" style="min-height: 72vh;">
  <div class="col-12 col-md-8 col-lg-5">
    <div class="card">
      <div class="card-body p-4 p-md-5">
        <div class="text-center mb-4">
          <div class="display-6 mb-2"><i class="fa-brands fa-telegram"></i></div>
          <h1 class="h3 mb-2">Вход в панель</h1>
          <div class="text-muted">Управление MTProto Proxy</div>
        </div>
        <form method="post" class="vstack gap-3">
          <div>
            <label class="form-label text-muted mb-1">Логин</label>
            <input class="form-control form-control-lg" type="text" name="username" required autofocus>
          </div>
          <div>
            <label class="form-label text-muted mb-1">Пароль</label>
            <input class="form-control form-control-lg" type="password" name="password" required>
          </div>
          <button class="btn btn-primary btn-lg w-100" type="submit">
            <i class="fa-solid fa-right-to-bracket me-2"></i>Войти
          </button>
        </form>
      </div>
    </div>
  </div>
</div>
{% endblock %}
HTMLEOF

cat > "${PANEL_DIR}/templates/dashboard.html" <<'HTMLEOF'
{% extends "layout.html" %}
{% block content %}
<div class="row g-3 mb-4">
  <div class="col-12 col-lg-3">
    <div class="summary-card card">
      <div class="summary-label">Общее количество доступов</div>
      <div class="summary-value">{{ total_created }}</div>
    </div>
  </div>
  <div class="col-12 col-lg-3">
    <div class="summary-card card">
      <div class="summary-label">IP-адресов онлайн</div>
      <div class="summary-value">{{ connected_ips }}</div>
    </div>
  </div>
  <div class="col-12 col-lg-3">
    <div class="summary-card card">
      <div class="summary-label">Активных подключений</div>
      <div class="summary-value">{{ active_users }}</div>
    </div>
  </div>
  <div class="col-12 col-lg-3">
    <div class="summary-card card">
      <div class="summary-label">FakeTLS SNI</div>
      <div class="summary-value">{{ fake_tls_domain }}</div>
    </div>
  </div>
</div>

<div class="row g-4 align-items-start">
  <div class="col-12 col-lg-4">
    <div class="card mb-4">
      <div class="card-body p-4 p-md-5">
        <div class="section-title mb-3"><i class="fa-solid fa-plus text-primary"></i>Создать новый доступ</div>
        <form method="post" action="{{ url_for('create_access') }}" class="vstack gap-3">
          <div>
            <label class="form-label text-muted mb-1">Имя</label>
            <input class="form-control" name="nickname" placeholder="Например: Ivan" required>
          </div>
          <div>
            <label class="form-label text-muted mb-1">Устройство</label>
            <select class="form-select" name="device">
              <option value="Phone">Телефон</option>
              <option value="PC">Компьютер</option>
              <option value="Tablet">Планшет</option>
            </select>
          </div>
          <button class="btn btn-primary w-100" type="submit"><i class="fa-solid fa-wand-magic-sparkles me-2"></i>Создать</button>
        </form>
      </div>
    </div>

    <div class="card mb-4">
      <div class="card-body p-4">
        <div class="section-title mb-3"><i class="fa-solid fa-circle-info text-primary"></i>Сервер</div>
        <div class="vstack gap-2">
          <span class="chip"><span class="dot {{ 'green' if server_status == 'Работает' else 'red' }}"></span>{{ server_status }}</span>
          <div class="access-meta">Uptime сервера: {{ telemt_uptime }}</div>
          <div class="access-meta">Uptime системы: {{ system_uptime }}</div>
        </div>
      </div>
    </div>
  </div>

  <div class="col-12 col-lg-8">
    <div class="card mb-4">
      <div class="card-body p-4 p-md-5">
        <div class="section-title mb-3"><i class="fa-solid fa-list text-primary"></i>Список доступов</div>
        <div class="access-list">
          {% for item in accesses %}
          <div class="access-card">
            <div class="d-flex flex-wrap align-items-start justify-content-between gap-3 mb-3">
              <div>
                <div class="access-name">{{ item.username }}</div>
                <div class="access-meta">Устройство: {{ item.device }}</div>
                <div class="fw-semibold mt-2">Осталось: {{ item.remaining_text }}</div>
                <div class="access-meta">
                  {% if item.status_label == 'active' %}
                    Статус доступа: активен
                  {% elif item.status_label == 'paused' %}
                    Статус доступа: пауза
                  {% else %}
                    Статус доступа: автопауза
                  {% endif %}
                </div>
              </div>
              <div class="text-lg-end">
                <span class="chip"><span class="dot {{ 'green' if item.online else 'red' }}"></span>{{ 'В сети' if item.online else 'Не в сети' }}</span>
                <div class="access-meta mt-2">{{ item.current_connections }} соединений / {{ item.active_unique_ips }} IP</div>
              </div>
            </div>

            <textarea class="form-control link-box mb-3" id="link-{{ loop.index }}" readonly>{{ item.link }}</textarea>

            <div class="d-flex flex-wrap gap-2 small-btns">
              <button class="btn btn-outline-secondary btn-sm" type="button" onclick="copyLink('link-{{ loop.index }}', this)">
                <i class="fa-solid fa-copy me-1"></i>Копия
              </button>
              <a class="btn btn-outline-secondary btn-sm" href="{{ url_for('open_link', username=item.username) }}">
                <i class="fa-brands fa-telegram me-1"></i>Открыть
              </a>
              <a class="btn btn-outline-secondary btn-sm" href="{{ url_for('qr_public', username=item.username) }}" download="{{ item.username }}.png">
                <i class="fa-solid fa-download me-1"></i>PNG
              </a>
              <button class="btn btn-outline-secondary btn-sm" type="button" data-bs-toggle="modal" data-bs-target="#qrModal" data-qr-url="{{ url_for('qr_public', username=item.username) }}" data-qr-name="{{ item.username }}">
                <i class="fa-solid fa-qrcode me-1"></i>QR-код
              </button>
              <form method="post" action="{{ url_for('toggle_access', username=item.username) }}">
                <button class="btn btn-warning btn-sm" type="submit">
                  {% if item.status_label == 'active' %}
                    <i class="fa-solid fa-pause me-1"></i>Пауза
                  {% else %}
                    <i class="fa-solid fa-play me-1"></i>Вкл
                  {% endif %}
                </button>
              </form>
              <form method="post" action="{{ url_for('delete_access', username=item.username) }}" onsubmit="return confirm('Удалить доступ {{ item.username }}?');">
                <button class="btn btn-danger btn-sm" type="submit"><i class="fa-solid fa-trash me-1"></i>Удалить</button>
              </form>
            </div>
          </div>
          {% else %}
          <div class="text-center text-muted py-5">
            <i class="fa-solid fa-box-open fa-2x mb-2"></i>
            <div>Пока нет доступов</div>
          </div>
          {% endfor %}
        </div>
      </div>
    </div>
  </div>
</div>

<div class="modal fade" id="qrModal" tabindex="-1" aria-hidden="true">
  <div class="modal-dialog modal-dialog-centered">
    <div class="modal-content">
      <div class="modal-header border-0">
        <h5 class="modal-title">QR-код подключения</h5>
        <button type="button" class="btn-close" data-bs-dismiss="modal" aria-label="Close"></button>
      </div>
      <div class="modal-body text-center">
        <img id="qrImage" src="" alt="QR" class="img-fluid rounded-4 border border-light-subtle">
        <div class="mt-3 text-muted small" id="qrName"></div>
      </div>
    </div>
  </div>
</div>
{% endblock %}

{% block scripts %}
<script>
  function copyLink(id, btn){
    const value = document.getElementById(id).value;
    navigator.clipboard.writeText(value).then(() => {
      const old = btn.innerHTML;
      btn.innerHTML = '<i class="fa-solid fa-check me-1"></i>Скопировано';
      setTimeout(() => { btn.innerHTML = old; }, 1400);
    });
  }
  const qrModal = document.getElementById('qrModal');
  qrModal?.addEventListener('show.bs.modal', event => {
    const button = event.relatedTarget;
    const url = button.getAttribute('data-qr-url');
    const name = button.getAttribute('data-qr-name');
    document.getElementById('qrImage').src = url;
    document.getElementById('qrName').textContent = name;
  });
</script>
{% endblock %}
HTMLEOF

cat > "${PANEL_DIR}/templates/settings.html" <<'HTMLEOF'
{% extends "layout.html" %}
{% block content %}
<div class="row g-4 mb-4">
  <div class="col-12 col-lg-4">
    <div class="summary-card card">
      <div class="summary-label">Статус сервера</div>
      <div class="summary-value">{{ server_status }}</div>
    </div>
  </div>
  <div class="col-12 col-lg-4">
    <div class="summary-card card">
      <div class="summary-label">Uptime сервера</div>
      <div class="summary-value">{{ telemt_uptime }}</div>
    </div>
  </div>
  <div class="col-12 col-lg-4">
    <div class="summary-card card">
      <div class="summary-label">Uptime системы</div>
      <div class="summary-value">{{ system_uptime }}</div>
    </div>
  </div>
</div>

<div class="row g-4">
  <div class="col-12 col-lg-7">
    <div class="card">
      <div class="card-body p-4 p-md-5">
        <div class="section-title mb-3"><i class="fa-solid fa-wand-magic-sparkles"></i>Настройки прокси</div>
        <form method="post" class="vstack gap-3">
          <div>
            <label class="form-label text-muted mb-1">Сайт для FakeTLS маскировки</label>
            <input id="fake_tls_domain" name="fake_tls_domain" class="form-control form-control-lg" value="{{ fake_tls_domain }}" required>
            <div class="mt-3 d-flex flex-wrap gap-2">
              <span class="chip sni-pill" data-sni="ads.x5.ru">ads.x5.ru</span>
              <span class="chip sni-pill" data-sni="1c.ru">1c.ru</span>
              <span class="chip sni-pill" data-sni="ozon.ru">ozon.ru</span>
              <span class="chip sni-pill" data-sni="vk.com">vk.com</span>
              <span class="chip sni-pill" data-sni="max.ru">max.ru</span>
            </div>
          </div>
          <div class="row g-3">
            <div class="col-12 col-md-8">
              <label class="form-label text-muted mb-1">Домен прокси</label>
              <input class="form-control" name="proxy_host" value="{{ proxy_host }}" required>
            </div>
            <div class="col-12 col-md-4">
              <label class="form-label text-muted mb-1">Порт</label>
              <input class="form-control" name="proxy_port" value="{{ proxy_port }}" required>
            </div>
          </div>
          <button class="btn btn-primary" type="submit"><i class="fa-solid fa-arrows-rotate me-2"></i>Сохранить и перезапустить</button>
        </form>
      </div>
    </div>
  </div>
</div>
{% endblock %}

{% block scripts %}
<script>
  document.querySelectorAll('.sni-pill').forEach((btn) => {
    btn.addEventListener('click', () => {
      const input = document.getElementById('fake_tls_domain');
      if (input) input.value = btn.dataset.sni;
    });
  });
</script>
{% endblock %}
HTMLEOF

cat > "${PANEL_DIR}/templates/admin_credentials.html" <<'HTMLEOF'
{% extends "layout.html" %}
{% block content %}
<div class="row g-4">
  <div class="col-12 col-lg-7">
    <div class="card">
      <div class="card-body p-4 p-md-5">
        <div class="section-title mb-3"><i class="fa-solid fa-user-gear"></i>Изменить логин и пароль администратора</div>
        <form method="post" class="vstack gap-3">
          <div class="row g-3">
            <div class="col-12 col-md-6">
              <label class="form-label text-muted mb-1">Текущий логин</label>
              <input class="form-control" name="current_username" value="{{ current_username }}" required>
            </div>
            <div class="col-12 col-md-6">
              <label class="form-label text-muted mb-1">Текущий пароль</label>
              <input class="form-control" type="password" name="current_password" required>
            </div>
            <div class="col-12 col-md-6">
              <label class="form-label text-muted mb-1">Новый логин</label>
              <input class="form-control" name="new_username" placeholder="Оставь пустым, чтобы не менять">
            </div>
            <div class="col-12 col-md-6">
              <label class="form-label text-muted mb-1">Новый пароль</label>
              <input class="form-control" type="password" name="new_password" required>
            </div>
          </div>
          <button class="btn btn-primary" type="submit"><i class="fa-solid fa-floppy-disk me-2"></i>Сохранить</button>
        </form>
      </div>
    </div>
  </div>
</div>
{% endblock %}
HTMLEOF

python3 -m venv "${PANEL_DIR}/venv"
"${PANEL_DIR}/venv/bin/pip" install --upgrade pip
"${PANEL_DIR}/venv/bin/pip" install Flask gunicorn toml werkzeug qrcode pillow
step_done "Python окружение готово"

"${PANEL_DIR}/venv/bin/python" <<PY
from pathlib import Path
from werkzeug.security import generate_password_hash
import sqlite3

db_path = Path("${APP_DIR}") / "panel.db"
conn = sqlite3.connect(db_path)
conn.execute("PRAGMA journal_mode=WAL;")
conn.execute("""
CREATE TABLE IF NOT EXISTS admin (
    id INTEGER PRIMARY KEY CHECK(id=1),
    username TEXT NOT NULL,
    password_hash TEXT NOT NULL
)
""")
conn.execute("""
CREATE TABLE IF NOT EXISTS settings (
    key TEXT PRIMARY KEY,
    value TEXT NOT NULL
)
""")
conn.execute("""
CREATE TABLE IF NOT EXISTS accesses (
    username TEXT PRIMARY KEY,
    device TEXT NOT NULL,
    secret TEXT NOT NULL,
    created_at TEXT NOT NULL,
    duration_seconds INTEGER NOT NULL,
    paused_total_seconds INTEGER NOT NULL DEFAULT 0,
    paused_since TEXT,
    paused_remaining_seconds INTEGER,
    auto_paused_at TEXT,
    status TEXT NOT NULL,
    expires_at TEXT NOT NULL
)
""")
settings = {
    "proxy_host": "${PROXY_DOMAIN}",
    "proxy_port": "443",
    "fake_tls_domain": "${FAKE_DOMAIN}",
    "telemt_api_token": "${API_TOKEN}",
    "default_admin_username": "${PANEL_ADMIN_USER}",
    "default_admin_password": "${PANEL_ADMIN_PASS}",
}
for k, v in settings.items():
    conn.execute(
        "INSERT INTO settings(key, value) VALUES(?, ?) ON CONFLICT(key) DO UPDATE SET value=excluded.value",
        (k, v),
    )
conn.execute(
    "INSERT INTO admin(id, username, password_hash) VALUES(1, ?, ?) ON CONFLICT(id) DO UPDATE SET username=excluded.username, password_hash=excluded.password_hash",
    ("${PANEL_ADMIN_USER}", generate_password_hash("${PANEL_ADMIN_PASS}")),
)
conn.commit()
conn.close()
PY

step_done "База панели создана"

cat > /usr/local/bin/telemt-panel-maintain.py <<'PYEOF'
import json
import sqlite3
import urllib.parse
import urllib.request
from datetime import datetime, timedelta, timezone

DB_PATH = "/var/lib/telemt-panel/panel.db"

def db():
    conn = sqlite3.connect(DB_PATH)
    conn.row_factory = sqlite3.Row
    return conn

def get_setting(conn, key, default=""):
    row = conn.execute("SELECT value FROM settings WHERE key = ?", (key,)).fetchone()
    return row["value"] if row else default

def utcnow():
    return datetime.now(timezone.utc)

def parse_dt(value):
    if not value:
        return None
    try:
        return datetime.fromisoformat(value.replace("Z", "+00:00"))
    except Exception:
        return None

def fmt_rfc3339(dt):
    return dt.astimezone(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")

def duration_left(row):
    now = utcnow()
    created = parse_dt(row["created_at"]) or now
    duration = int(row["duration_seconds"])
    paused_total = int(row["paused_total_seconds"] or 0)
    paused_since = parse_dt(row["paused_since"])
    if row["status"] == "active":
        elapsed = (now - created).total_seconds() - paused_total
    elif row["status"] in ("paused", "auto_paused"):
        if paused_since:
            elapsed = (paused_since - created).total_seconds() - paused_total
        else:
            elapsed = (now - created).total_seconds() - paused_total
    else:
        elapsed = (now - created).total_seconds() - paused_total
    return max(0, int(duration - elapsed))

def request_api(method, path, token, data=None):
    url = f"http://127.0.0.1:9091{path}"
    headers = {"Authorization": token, "Content-Type": "application/json"}
    body = json.dumps(data).encode("utf-8") if data is not None else None
    req = urllib.request.Request(url, data=body, headers=headers, method=method)
    with urllib.request.urlopen(req, timeout=12) as resp:
        payload = json.loads(resp.read().decode("utf-8") or "{}")
    if payload.get("ok") is True and "data" in payload:
        return payload["data"]
    return payload

def patch_user(token, username, expiration):
    request_api("PATCH", "/v1/users/" + urllib.parse.quote(username), token, {"expiration_rfc3339": expiration})

def delete_user(token, username):
    request_api("DELETE", "/v1/users/" + urllib.parse.quote(username), token)

def main():
    conn = db()
    token = get_setting(conn, "telemt_api_token")
    rows = conn.execute("SELECT * FROM accesses").fetchall()
    changed = False
    now = utcnow()

    for row in rows:
        try:
            if row["status"] == "active":
                remaining = duration_left(row)
                if remaining <= 0:
                    paused_at = now
                    conn.execute(
                        """
                        UPDATE accesses
                        SET status='auto_paused',
                            paused_since=?,
                            paused_remaining_seconds=0,
                            auto_paused_at=?,
                            expires_at=?
                        WHERE username=?
                        """,
                        (fmt_rfc3339(paused_at), fmt_rfc3339(paused_at), fmt_rfc3339(paused_at - timedelta(minutes=1)), row["username"]),
                    )
                    patch_user(token, row["username"], fmt_rfc3339(paused_at - timedelta(minutes=1)))
                    changed = True
            elif row["status"] == "auto_paused":
                paused_at = parse_dt(row["auto_paused_at"]) or parse_dt(row["paused_since"]) or now
                if (now - paused_at).total_seconds() >= 2 * 24 * 3600:
                    try:
                        delete_user(token, row["username"])
                    except Exception:
                        pass
                    conn.execute("DELETE FROM accesses WHERE username = ?", (row["username"],))
                    changed = True
        except Exception:
            pass

    if changed:
        conn.commit()
    conn.close()

if __name__ == "__main__":
    main()
PYEOF
chmod +x /usr/local/bin/telemt-panel-maintain.py

cat > /etc/systemd/system/telemt-panel.service <<EOF
[Unit]
Description=MTProto Proxy Web Panel
After=network.target telemt.service
Requires=telemt.service

[Service]
Type=simple
User=root
WorkingDirectory=${PANEL_DIR}
Environment="PANEL_SECRET_KEY=${PANEL_SECRET_KEY}"
Environment="PANEL_PORT=${PANEL_PORT}"
ExecStart=${PANEL_DIR}/venv/bin/gunicorn --workers 2 --threads 4 --bind 0.0.0.0:${PANEL_PORT} --certfile /etc/letsencrypt/live/${PANEL_DOMAIN}/fullchain.pem --keyfile /etc/letsencrypt/live/${PANEL_DOMAIN}/privkey.pem --access-logfile - --error-logfile - --capture-output app:app
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable telemt-panel --now
sleep 2
if systemctl is-active --quiet telemt-panel; then
  log "${GREEN}Панель запущена и отвечает.${RESET}"
else
  log "${RED}Панель не стартовала. Смотри journalctl -u telemt-panel.${RESET}"
  journalctl -u telemt-panel --no-pager -n 20 || true
  exit 1
fi
step_done "Панель готова"

cat > /etc/cron.d/telemt-panel-maintain <<EOF
* * * * * root /usr/local/bin/telemt-panel-maintain.py >/dev/null 2>&1
0 3 * * * root certbot renew --post-hook 'systemctl restart telemt telemt-panel' >/dev/null 2>&1
0 4 * * * root /usr/local/bin/telemt-updater.sh >/dev/null 2>&1
EOF

cat > /usr/local/bin/telemt-updater.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
ARCH="$(uname -m)"
case "$ARCH" in
  x86_64) BIN_ARCH="x86_64" ;;
  aarch64|arm64) BIN_ARCH="aarch64" ;;
  *) exit 0 ;;
esac
TMP_DIR="$(mktemp -d)"
wget -q "https://github.com/telemt/telemt/releases/latest/download/telemt-${BIN_ARCH}-linux-gnu.tar.gz" -O "${TMP_DIR}/telemt.tar.gz" || exit 0
tar -xzf "${TMP_DIR}/telemt.tar.gz" -C "${TMP_DIR}" || exit 0
systemctl stop telemt || true
install -m 755 "${TMP_DIR}/telemt" /usr/local/bin/telemt
systemctl start telemt || true
rm -rf "${TMP_DIR}"
EOF
chmod +x /usr/local/bin/telemt-updater.sh
step_done "Автообновление включено"

generate_bootstrap() {
  "${PANEL_DIR}/venv/bin/python" <<PY
from datetime import datetime, timedelta, timezone
from pathlib import Path
import sqlite3

db_path = Path("${APP_DIR}") / "panel.db"
conn = sqlite3.connect(db_path)
conn.row_factory = sqlite3.Row
settings = {row["key"]: row["value"] for row in conn.execute("SELECT key, value FROM settings")}
proxy_host = settings["proxy_host"]
proxy_port = settings["proxy_port"]
fake_domain = settings["fake_tls_domain"]
username = "${INITIAL_USERNAME}"
secret = "${INITIAL_SECRET}"
duration_seconds = 31 * 24 * 3600 - 60
created_at = datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00","Z")
expires_at = (datetime.now(timezone.utc) + timedelta(seconds=duration_seconds)).replace(microsecond=0).isoformat().replace("+00:00","Z")

conn.execute(
    """
    INSERT INTO accesses(username, device, secret, created_at, duration_seconds, paused_total_seconds, paused_since, paused_remaining_seconds, auto_paused_at, status, expires_at)
    VALUES(?,?,?,?,?,?,?,?,?,?,?)
    ON CONFLICT(username) DO UPDATE SET
      device=excluded.device,
      secret=excluded.secret,
      created_at=excluded.created_at,
      duration_seconds=excluded.duration_seconds,
      paused_total_seconds=excluded.paused_total_seconds,
      paused_since=excluded.paused_since,
      paused_remaining_seconds=excluded.paused_remaining_seconds,
      auto_paused_at=excluded.auto_paused_at,
      status=excluded.status,
      expires_at=excluded.expires_at
    """,
    (username, "Phone", secret, created_at, duration_seconds, 0, None, None, None, "active", expires_at),
)
conn.commit()
conn.close()

link = f"tg://proxy?server={proxy_host}&port={proxy_port}&secret=ee{secret}{fake_domain.encode('utf-8').hex()}"
print(link)
PY
}

BOOTSTRAP_LINK="$(generate_bootstrap)"
step_done "Первый доступ создан"

log ""
log "${BOLD}Ссылка для подключения:${RESET}"
log "${GREEN}${BOOTSTRAP_LINK}${RESET}"
if command -v qrencode >/dev/null 2>&1; then
  printf "%s\n" "${BOOTSTRAP_LINK}" | qrencode -t ANSIUTF8
else
  log "${YELLOW}qrencode не найден, QR-код не показан.${RESET}"
fi
log ""
log "${BOLD}Панель:${RESET} https://${PANEL_DOMAIN}:${PANEL_PORT}"
log "${BOLD}Логин:${RESET} ${PANEL_ADMIN_USER}"
log "${BOLD}Пароль:${RESET} ${PANEL_ADMIN_PASS}"
log "${YELLOW}Смените данные администратора после входа.${RESET}"
log ""
log "${GREEN}${BOLD}УСТАНОВКА ЗАВЕРШЕНА УСПЕШНО.${RESET}"
