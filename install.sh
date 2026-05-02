#!/usr/bin/env bash
set -Eeuo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

TOTAL_STAGES=8
CURRENT_STAGE=""

trap 'echo -e "${RED}${BOLD}Этап ${CURRENT_STAGE}: Не успешно${RESET}" >&2; exit 1' ERR

banner() {
  printf "%b\n" "${CYAN}${BOLD}"
  printf "  ███╗   ███╗████████╗██████╗ ██████╗  ██████╗ ████████╗ ██████╗ \n"
  printf "  ████╗ ████║╚══██╔══╝██╔══██╗██╔══██╗██╔═══██╗╚══██╔══╝██╔═══██╗\n"
  printf "  ██╔████╔██║   ██║   ██████╔╝██████╔╝██║   ██║   ██║   ██║   ██║\n"
  printf "  ██║╚██╔╝██║   ██║   ██╔═══╝ ██╔══██╗██║   ██║   ██║   ██║   ██║\n"
  printf "  ██║ ╚═╝ ██║   ██║   ██║     ██║  ██║╚██████╔╝   ██║   ╚██████╔╝\n"
  printf "  ╚═╝     ╚═╝   ╚═╝   ╚═╝     ╚═╝  ╚═╝ ╚═════╝    ╚═╝   ╚═════╝  \n"
  printf "%b\n" "${RESET}${YELLOW}MTProto Proxy Panel Installer by Mr_EFES${RESET}"
  printf "\n"
}

stage_ok() {
  echo -e "${GREEN}${BOLD}Этап ${CURRENT_STAGE}: Успешно${RESET}"
}

need_root() {
  [[ $EUID -eq 0 ]] || { echo -e "${RED}Запусти скрипт от root.${RESET}"; exit 1; }
}

issue_ssl() {
  local domain="$1"
  local email="$2"
  local cert_path="/etc/letsencrypt/live/${domain}/fullchain.pem"

  if [[ -f "$cert_path" ]] && openssl x509 -in "$cert_path" -noout -checkend 86400 >/dev/null 2>&1; then
    echo "exist"
    return 0
  fi

  if [[ -n "$email" ]]; then
    certbot certonly --standalone -d "$domain" --email "$email" --agree-tos --non-interactive --quiet >/dev/null 2>&1
  else
    certbot certonly --standalone -d "$domain" --register-unsafely-without-email --agree-tos --non-interactive --quiet >/dev/null 2>&1
  fi

  [[ -f "$cert_path" ]] && echo "new" || echo "error"
}

banner
need_root

CURRENT_STAGE="1/8 — Подготовка системы"
DEBIAN_FRONTEND=noninteractive apt-get update -y -qq >/dev/null 2>&1
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq curl wget jq openssl certbot xxd socat ufw python3 python3-pip python3-venv iproute2 net-tools qrencode sqlite3 >/dev/null 2>&1
stage_ok

read -rp "Домен прокси (например tg.example.com): " PROXY_DOMAIN
[[ -n "${PROXY_DOMAIN:-}" ]] || exit 1
read -rp "Домен панели (например admin.example.com): " PANEL_DOMAIN
[[ -n "${PANEL_DOMAIN:-}" ]] || exit 1
read -rp "Порт панели [4444]: " PANEL_PORT_INPUT
PANEL_PORT="${PANEL_PORT_INPUT:-4444}"
read -rp "Email для Let's Encrypt (необязательно): " CERT_EMAIL

CURRENT_STAGE="2/8 — Выбор FakeTLS"
echo "1) ads.x5.ru"
echo "2) 1c.ru"
echo "3) ozon.ru"
echo "4) vk.com"
echo "5) max.ru"
echo "6) Свой вариант"
read -rp "Ваш выбор [1-6, Enter = 5]: " FAKE_CHOICE
case "${FAKE_CHOICE:-5}" in
  1) FAKE_DOMAIN="ads.x5.ru" ;;
  2) FAKE_DOMAIN="1c.ru" ;;
  3) FAKE_DOMAIN="ozon.ru" ;;
  4) FAKE_DOMAIN="vk.com" ;;
  5) FAKE_DOMAIN="max.ru" ;;
  6)
    read -rp "Введите свой домен для FakeTLS: " FAKE_DOMAIN
    [[ -n "${FAKE_DOMAIN:-}" ]] || exit 1
    ;;
  *) FAKE_DOMAIN="max.ru" ;;
esac
stage_ok

CURRENT_STAGE="3/8 — SSL"
systemctl stop nginx apache2 >/dev/null 2>&1 || true
case "$(issue_ssl "$PROXY_DOMAIN" "$CERT_EMAIL")" in
  exist|new) : ;;
  *) exit 1 ;;
esac
case "$(issue_ssl "$PANEL_DOMAIN" "$CERT_EMAIL")" in
  exist|new) : ;;
  *) exit 1 ;;
esac
stage_ok

CURRENT_STAGE="4/8 — Telemt"
ARCH="$(uname -m)"
case "$ARCH" in
  x86_64) BIN_ARCH="x86_64" ;;
  aarch64|arm64) BIN_ARCH="aarch64" ;;
  *) exit 1 ;;
esac

TMP_DIR="$(mktemp -d)"
wget -q "https://github.com/telemt/telemt/releases/latest/download/telemt-${BIN_ARCH}-linux-gnu.tar.gz" -O "${TMP_DIR}/telemt.tar.gz"
tar -xzf "${TMP_DIR}/telemt.tar.gz" -C "${TMP_DIR}"
install -m 755 "${TMP_DIR}/telemt" /usr/local/bin/telemt
rm -rf "${TMP_DIR}"
stage_ok

API_TOKEN="$(openssl rand -hex 24)"
PANEL_ADMIN_USER="admin"
PANEL_ADMIN_PASS="$(openssl rand -base64 18 | tr -dc 'A-Za-z0-9' | head -c 16)"
PANEL_SECRET_KEY="$(openssl rand -hex 32)"
INITIAL_USERNAME="default_phone"
INITIAL_SECRET="$(openssl rand -hex 16)"
INITIAL_EXPIRES="$(date -u -d '+30 days' +%Y-%m-%dT%H:%M:%SZ)"

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
systemctl enable telemt --now >/dev/null 2>&1
sleep 2
systemctl is-active --quiet telemt
stage_ok

CURRENT_STAGE="5/8 — Веб-панель"
cat > /var/www/telemt-panel/app.py <<'PYEOF'
import io
import json
import os
import re
import secrets
import sqlite3
import subprocess
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

app = Flask(__name__)
app.secret_key = os.environ.get("PANEL_SECRET_KEY", "change-me")

def db():
    conn = sqlite3.connect(DB_PATH)
    conn.row_factory = sqlite3.Row
    return conn

def ensure_schema():
    os.makedirs(APP_DIR, exist_ok=True)
    conn = db()
    conn.executescript(
        """
        CREATE TABLE IF NOT EXISTS admin(
            id INTEGER PRIMARY KEY CHECK(id=1),
            username TEXT NOT NULL,
            password_hash TEXT NOT NULL
        );
        CREATE TABLE IF NOT EXISTS settings(
            key TEXT PRIMARY KEY,
            value TEXT NOT NULL
        );
        CREATE TABLE IF NOT EXISTS accesses(
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
            expires_at TEXT NOT NULL,
            lock_reason TEXT,
            last_ip TEXT
        );
        """
    )
    for col in ("lock_reason", "last_ip"):
        try:
            conn.execute(f"ALTER TABLE accesses ADD COLUMN {col} TEXT")
        except Exception:
            pass
    conn.commit()
    conn.close()

def get_setting(key, default=""):
    conn = db()
    row = conn.execute("SELECT value FROM settings WHERE key=?", (key,)).fetchone()
    conn.close()
    return row["value"] if row else default

def set_setting(key, value):
    conn = db()
    conn.execute(
        "INSERT INTO settings(key,value) VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value",
        (key, value),
    )
    conn.commit()
    conn.close()

def get_admin():
    conn = db()
    row = conn.execute("SELECT username, password_hash FROM admin WHERE id=1").fetchone()
    conn.close()
    return row

def set_admin(username, password_hash):
    conn = db()
    conn.execute(
        "INSERT INTO admin(id, username, password_hash) VALUES(1, ?, ?) ON CONFLICT(id) DO UPDATE SET username=excluded.username, password_hash=excluded.password_hash",
        (username, password_hash),
    )
    conn.commit()
    conn.close()

def utcnow():
    return datetime.now(timezone.utc)

def parse_dt(value):
    if not value:
        return None
    try:
        return datetime.fromisoformat(value.replace("Z", "+00:00"))
    except Exception:
        return None

def fmt_dt(dt):
    return dt.astimezone(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")

def remaining_seconds(row):
    now = utcnow()
    created = parse_dt(row["created_at"]) or now
    dur = int(row["duration_seconds"])
    paused_total = int(row["paused_total_seconds"] or 0)
    status = row["status"]
    if status == "active":
        elapsed = (now - created).total_seconds() - paused_total
    elif status in ("paused", "auto_paused"):
        p = parse_dt(row["paused_since"]) or now
        elapsed = (p - created).total_seconds() - paused_total
    else:
        elapsed = (now - created).total_seconds() - paused_total
    return max(0, int(dur - elapsed))

def fmt_remaining(sec):
    sec = max(0, int(sec))
    d = sec // 86400
    h = (sec % 86400) // 3600
    m = (sec % 3600) // 60
    return f"{d} дней {h} часов {m} минут"

def system_uptime():
    try:
        with open("/proc/uptime", "r", encoding="utf-8") as f:
            total = int(float(f.read().split()[0]))
        d = total // 86400
        h = (total % 86400) // 3600
        m = (total % 3600) // 60
        return f"{d} дней {h} часов {m} минут"
    except Exception:
        return "н/д"

def service_uptime(service="telemt"):
    try:
        out = subprocess.check_output(["systemctl", "show", service, "-p", "ActiveEnterTimestampMonotonic", "--value"], text=True).strip()
        if not out or out == "0":
            return "н/д"
        started_us = int(out)
        with open("/proc/uptime", "r", encoding="utf-8") as f:
            boot_sec = float(f.read().split()[0])
        now_us = int(boot_sec * 1_000_000)
        total = max(0, int((now_us - started_us) / 1_000_000))
        d = total // 86400
        h = (total % 86400) // 3600
        m = (total % 3600) // 60
        return f"{d} дней {h} часов {m} минут"
    except Exception:
        return "н/д"

def telemt_running():
    return subprocess.run(["systemctl", "is-active", "--quiet", "telemt"]).returncode == 0

def api_req(method, path, data=None):
    token = get_setting("telemt_api_token")
    url = f"http://127.0.0.1:9091{path}"
    headers = {"Authorization": token, "Content-Type": "application/json"}
    body = json.dumps(data).encode("utf-8") if data is not None else None
    req = urllib.request.Request(url, data=body, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=10) as resp:
            raw = resp.read().decode("utf-8") or "{}"
            payload = json.loads(raw)
    except urllib.error.HTTPError as exc:
        try:
            payload = json.loads(exc.read().decode("utf-8"))
            msg = payload.get("error", {}).get("message") or payload.get("message") or str(exc)
        except Exception:
            msg = str(exc)
        raise RuntimeError(msg)
    if isinstance(payload, dict) and payload.get("ok") is True and "data" in payload:
        return payload["data"]
    return payload

def api_get_users():
    data = api_req("GET", "/v1/users")
    return data if isinstance(data, list) else []

def api_create_user(username, secret, exp_rfc3339):
    return api_req("POST", "/v1/users", {
        "username": username,
        "secret": secret,
        "expiration_rfc3339": exp_rfc3339,
    })

def api_delete_user(username):
    return api_req("DELETE", "/v1/users/" + urllib.parse.quote(username))

def api_patch_user(username, payload):
    return api_req("PATCH", "/v1/users/" + urllib.parse.quote(username), payload)

def link_for(secret):
    host = get_setting("proxy_host", "127.0.0.1")
    port = get_setting("proxy_port", "443")
    fake = get_setting("fake_tls_domain", "max.ru")
    return f"tg://proxy?server={host}&port={port}&secret=ee{secret}{fake.encode('utf-8').hex()}"

def qr_bytes(text):
    img = qrcode.make(text)
    buf = io.BytesIO()
    img.save(buf, format="PNG")
    buf.seek(0)
    return buf

def admin_required():
    return "admin" in session

def ensure_login():
    if request.endpoint in {"login", "static"} or request.path.startswith("/static"):
        return None
    if not admin_required():
        return redirect(url_for("login"))

@app.before_request
def before():
    return ensure_login()

def sync_accesses():
    conn = db()
    rows = conn.execute("SELECT * FROM accesses").fetchall()
    api_map = {}
    try:
        users = api_get_users()
        for u in users:
            if isinstance(u, dict) and u.get("username"):
                api_map[u["username"]] = u
    except Exception:
        api_map = {}

    changed = False
    now = utcnow()

    for row in rows:
        username = row["username"]
        api = api_map.get(username, {})
        current_connections = int(api.get("current_connections", 0) or 0)
        active_ips = api.get("active_unique_ips_list") or []
        active_ips_count = int(api.get("active_unique_ips", len(active_ips)) or len(active_ips))
        first_ip = active_ips[0] if active_ips else None

        if row["status"] == "active":
            if current_connections > 1 or active_ips_count > 1:
                try:
                    api_delete_user(username)
                except Exception:
                    pass
                conn.execute(
                    "UPDATE accesses SET status='paused', paused_since=?, paused_remaining_seconds=?, auto_paused_at=NULL, lock_reason='multi_device', last_ip=? WHERE username=?",
                    (fmt_dt(now), remaining_seconds(row), first_ip, username),
                )
                changed = True
                continue

            rem = remaining_seconds(row)
            if rem <= 0:
                try:
                    api_delete_user(username)
                except Exception:
                    pass
                conn.execute(
                    "UPDATE accesses SET status='auto_paused', paused_since=?, paused_remaining_seconds=0, auto_paused_at=?, lock_reason=NULL WHERE username=?",
                    (fmt_dt(now), fmt_dt(now), username),
                )
                changed = True
                continue

            if first_ip:
                conn.execute("UPDATE accesses SET last_ip=? WHERE username=? AND (last_ip IS NULL OR last_ip='')", (first_ip, username))
                changed = True

        elif row["status"] == "auto_paused":
            paused_at = parse_dt(row["auto_paused_at"]) or parse_dt(row["paused_since"]) or now
            if (now - paused_at).total_seconds() >= 24 * 3600:
                try:
                    api_delete_user(username)
                except Exception:
                    pass
                conn.execute("DELETE FROM accesses WHERE username=?", (username,))
                changed = True

    if changed:
        conn.commit()
    conn.close()

def bootstrap_access():
    conn = db()
    if conn.execute("SELECT 1 FROM accesses LIMIT 1").fetchone() is None:
        now = utcnow()
        exp = now + timedelta(days=30)
        secret = get_setting("bootstrap_secret")
        if not secret:
            secret = secrets.token_hex(16)
            set_setting("bootstrap_secret", secret)
        username = get_setting("bootstrap_username", "default_phone")
        conn.execute(
            """
            INSERT OR REPLACE INTO accesses(username, device, secret, created_at, duration_seconds, paused_total_seconds, paused_since, paused_remaining_seconds, auto_paused_at, status, expires_at, lock_reason, last_ip)
            VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?)
            """,
            (username, "Телефон", secret, fmt_dt(now), 30*24*3600, 0, None, None, None, "active", fmt_dt(exp), None, None),
        )
        conn.commit()
        try:
            api_create_user(username, secret, fmt_dt(exp))
        except Exception:
            pass
    conn.close()

@app.route("/login", methods=["GET", "POST"])
def login():
    admin = get_admin()
    if request.method == "POST":
        if admin and request.form.get("username") == admin["username"] and check_password_hash(admin["password_hash"], request.form.get("password", "")):
            session["admin"] = admin["username"]
            return redirect(url_for("dashboard"))
        flash("Неверный логин или пароль", "danger")
    return render_template("login.html")

@app.route("/logout")
def logout():
    session.clear()
    return redirect(url_for("login"))

@app.route("/")
def dashboard():
    sync_accesses()
    conn = db()
    items = conn.execute("SELECT * FROM accesses ORDER BY datetime(created_at) DESC").fetchall()
    conn.close()

    users = {}
    try:
        for u in api_get_users():
            users[u.get("username")] = u
    except Exception:
        users = {}

    rows = []
    ips = set()
    active_connections = 0
    for row in items:
        api = users.get(row["username"], {})
        online = int(api.get("current_connections", 0) or 0) > 0
        active_connections += int(api.get("current_connections", 0) or 0)
        for ip in api.get("active_unique_ips_list") or []:
            ips.add(ip)
        rows.append({
            **dict(row),
            "online": online,
            "link": link_for(row["secret"]),
            "remaining_text": fmt_remaining(remaining_seconds(row)),
            "connections": int(api.get("current_connections", 0) or 0),
            "ips_count": int(api.get("active_unique_ips", 0) or 0),
            "status_text": "Активен" if row["status"] == "active" else ("Пауза" if row["status"] == "paused" else ("Автопауза" if row["status"] == "auto_paused" else row["status"])),
        })

    admin = get_admin()
    return render_template(
        "dashboard.html",
        accesses=rows,
        total_created=len(items),
        connected_ips=len(ips),
        active_connections=active_connections,
        fake_tls_domain=get_setting("fake_tls_domain", "max.ru"),
        proxy_host=get_setting("proxy_host", "127.0.0.1"),
        proxy_port=get_setting("proxy_port", "443"),
        server_status="Работает" if telemt_running() else "Отключен",
        telemt_uptime=service_uptime("telemt"),
        system_uptime=system_uptime(),
        admin_name=admin["username"] if admin else "admin",
    )

@app.route("/create", methods=["POST"])
def create_access():
    nickname = (request.form.get("nickname") or "").strip()
    device = (request.form.get("device") or "Телефон").strip()
    if not nickname:
        flash("Укажи имя доступа", "danger")
        return redirect(url_for("dashboard"))

    base = re.sub(r"[^A-Za-z0-9_.-]+", "_", f"{nickname}_{device}")[:64]
    username = base or f"user_{secrets.token_hex(3)}"
    conn = db()
    suffix = 2
    while conn.execute("SELECT 1 FROM accesses WHERE username=?", (username,)).fetchone():
        username = f"{base[:58]}_{suffix}"
        suffix += 1

    secret = secrets.token_hex(16)
    now = utcnow()
    exp = now + timedelta(days=30)
    try:
        api_create_user(username, secret, fmt_dt(exp))
    except Exception as exc:
        conn.close()
        flash(f"Не удалось создать доступ: {exc}", "danger")
        return redirect(url_for("dashboard"))

    conn.execute(
        """
        INSERT INTO accesses(username, device, secret, created_at, duration_seconds, paused_total_seconds, paused_since, paused_remaining_seconds, auto_paused_at, status, expires_at, lock_reason, last_ip)
        VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?)
        """,
        (username, device, secret, fmt_dt(now), 30*24*3600, 0, None, None, None, "active", fmt_dt(exp), None, None),
    )
    conn.commit()
    conn.close()
    flash("Доступ создан", "success")
    return redirect(url_for("dashboard"))

@app.route("/toggle/<username>", methods=["POST"])
def toggle_access(username):
    conn = db()
    row = conn.execute("SELECT * FROM accesses WHERE username=?", (username,)).fetchone()
    if not row:
        conn.close()
        flash("Доступ не найден", "danger")
        return redirect(url_for("dashboard"))

    now = utcnow()
    try:
        if row["status"] == "active":
            rem = remaining_seconds(row)
            conn.execute(
                "UPDATE accesses SET status='paused', paused_since=?, paused_remaining_seconds=?, auto_paused_at=NULL WHERE username=?",
                (fmt_dt(now), rem, username),
            )
            try:
                api_delete_user(username)
            except Exception:
                pass
            flash("Доступ поставлен на паузу и соединение разорвано", "success")
        else:
            if row["status"] == "auto_paused" or row["lock_reason"] == "multi_device":
                exp = now + timedelta(days=30)
                conn.execute(
                    """
                    UPDATE accesses
                    SET status='active', created_at=?, paused_total_seconds=0, paused_since=NULL, paused_remaining_seconds=NULL,
                        auto_paused_at=NULL, expires_at=?, lock_reason=NULL, last_ip=NULL
                    WHERE username=?
                    """,
                    (fmt_dt(now), fmt_dt(exp), username),
                )
                api_create_user(username, row["secret"], fmt_dt(exp))
                flash("Доступ включен. Таймер запущен заново", "success")
            else:
                paused_since = parse_dt(row["paused_since"]) or now
                rem = int(row["paused_remaining_seconds"] or remaining_seconds(row))
                paused_total = int(row["paused_total_seconds"] or 0) + int((now - paused_since).total_seconds())
                exp = now + timedelta(seconds=max(0, rem))
                conn.execute(
                    """
                    UPDATE accesses
                    SET status='active', paused_total_seconds=?, paused_since=NULL, paused_remaining_seconds=NULL,
                        auto_paused_at=NULL, expires_at=?, lock_reason=NULL
                    WHERE username=?
                    """,
                    (paused_total, fmt_dt(exp), username),
                )
                api_create_user(username, row["secret"], fmt_dt(exp))
                flash("Доступ возобновлен", "success")
        conn.commit()
    except Exception as exc:
        flash(f"Ошибка: {exc}", "danger")
    finally:
        conn.close()
    return redirect(url_for("dashboard"))

@app.route("/delete/<username>", methods=["POST"])
def delete_access(username):
    conn = db()
    try:
        try:
            api_delete_user(username)
        except Exception:
            pass
        conn.execute("DELETE FROM accesses WHERE username=?", (username,))
        conn.commit()
        flash("Доступ удалён", "success")
    finally:
        conn.close()
    return redirect(url_for("dashboard"))

@app.route("/qr/<username>")
def qr(username):
    conn = db()
    row = conn.execute("SELECT * FROM accesses WHERE username=?", (username,)).fetchone()
    conn.close()
    if not row:
        return "Not found", 404
    return send_file(qr_bytes(link_for(row["secret"])), mimetype="image/png")

@app.route("/settings", methods=["GET", "POST"])
def settings():
    if request.method == "POST":
        fake = (request.form.get("fake_tls_domain") or "").strip()
        host = (request.form.get("proxy_host") or "").strip()
        port = (request.form.get("proxy_port") or "443").strip()
        try:
            port_i = int(port)
            if not fake or not host or port_i < 1 or port_i > 65535:
                raise ValueError
            cfg = toml.load(TELEMT_TOML)
            cfg.setdefault("censorship", {})
            cfg["censorship"]["tls_domain"] = fake
            cfg.setdefault("general", {})
            cfg["general"].setdefault("links", {})
            cfg["general"]["links"]["public_host"] = host
            cfg["general"]["links"]["public_port"] = port_i
            with open(TELEMT_TOML, "w", encoding="utf-8") as f:
                toml.dump(cfg, f)
            set_setting("fake_tls_domain", fake)
            set_setting("proxy_host", host)
            set_setting("proxy_port", str(port_i))
            subprocess.run(["systemctl", "restart", "telemt"], check=False)
            flash("Настройки обновлены", "success")
        except Exception:
            flash("Не удалось сохранить настройки", "danger")
    return render_template(
        "settings.html",
        fake_tls_domain=get_setting("fake_tls_domain", "max.ru"),
        proxy_host=get_setting("proxy_host", "127.0.0.1"),
        proxy_port=get_setting("proxy_port", "443"),
        server_status="Работает" if telemt_running() else "Отключен",
        telemt_uptime=service_uptime("telemt"),
        system_uptime=system_uptime(),
    )

@app.route("/admin/credentials", methods=["GET", "POST"])
def admin_credentials():
    admin = get_admin()
    if request.method == "POST":
        cur_user = request.form.get("current_username", "")
        cur_pass = request.form.get("current_password", "")
        new_user = (request.form.get("new_username") or "").strip() or admin["username"]
        new_pass = request.form.get("new_password", "")
        if not admin or cur_user != admin["username"] or not check_password_hash(admin["password_hash"], cur_pass):
            flash("Текущие данные неверны", "danger")
            return redirect(url_for("admin_credentials"))
        if not new_pass:
            flash("Новый пароль обязателен", "danger")
            return redirect(url_for("admin_credentials"))
        set_admin(new_user, generate_password_hash(new_pass))
        session.clear()
        flash("Данные администратора обновлены. Войдите заново.", "success")
        return redirect(url_for("login"))
    return render_template("admin_credentials.html", current_username=admin["username"] if admin else "admin")

if __name__ == "__main__":
    ensure_schema()
    set_setting("proxy_host", os.environ.get("PROXY_HOST", "127.0.0.1"))
    set_setting("proxy_port", os.environ.get("PROXY_PORT", "443"))
    set_setting("fake_tls_domain", os.environ.get("FAKE_TLS_DOMAIN", "max.ru"))
    set_setting("telemt_api_token", os.environ.get("TELEMT_API_TOKEN", ""))
    set_setting("default_admin_username", os.environ.get("DEFAULT_ADMIN_USERNAME", "admin"))
    set_setting("default_admin_password", os.environ.get("DEFAULT_ADMIN_PASSWORD", "admin"))
    ensure_schema()
    bootstrap_access()
    app.run(host="0.0.0.0", port=int(os.environ.get("PANEL_PORT", "4444")))
PYEOF

cat > /var/www/telemt-panel/templates/layout.html <<'HTMLEOF'
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
      --bg:#f4f8fd; --card:#ffffff; --line:#dbe5f1; --text:#0f172a; --muted:#64748b;
      --blue:#2aabee; --blue2:#52c7ff; --green:#22c55e; --red:#ef4444;
    }
    body{
      min-height:100vh; color:var(--text);
      background:
        radial-gradient(circle at top left, rgba(42,171,238,.16), transparent 25%),
        radial-gradient(circle at top right, rgba(34,197,94,.10), transparent 22%),
        linear-gradient(180deg, #eef5fb 0%, #f7fbff 100%);
      font-family: Inter, "Segoe UI", system-ui, -apple-system, sans-serif;
    }
    .navbar,.card,.modal-content{
      background: rgba(255,255,255,.95) !important;
      border:1px solid var(--line);
      box-shadow:0 14px 45px rgba(15,23,42,.08);
      backdrop-filter: blur(12px);
    }
    .navbar{
      background: linear-gradient(90deg, var(--blue), var(--blue2)) !important;
      color:#fff !important;
      border:none;
      border-radius: 0 0 22px 22px;
    }
    .navbar .navbar-brand,.navbar .btn,.navbar .chip{ color:#fff !important; }
    .navbar .btn{ border-color: rgba(255,255,255,.45); }
    .navbar .btn:hover{ background: rgba(255,255,255,.12); }
    .page-shell{ max-width: 1400px; }
    .card{ border-radius: 22px; }
    .text-muted{ color:var(--muted) !important; }
    .btn{ border-radius:14px; font-weight:700; }
    .btn-primary{ background:var(--blue); border-color:var(--blue); }
    .btn-outline-secondary{ border-color:#cbd5e1; }
    .form-control,.form-select{
      border-radius:14px; border:1px solid var(--line); background:#fff; color:var(--text);
    }
    .form-control:focus,.form-select:focus{
      border-color:var(--blue); box-shadow:0 0 0 .2rem rgba(42,171,238,.16);
    }
    .table{ color:var(--text); margin-bottom:0; }
    .table > :not(caption) > * > *{ background:transparent; border-color:var(--line); }
    .table thead th{ color:var(--muted); font-size:.82rem; letter-spacing:.04em; text-transform:uppercase; white-space:nowrap; }
    .table tbody tr:hover{ background: rgba(42,171,238,.04); }
    .summary-card{ height:100%; padding:1rem 1.05rem; border-radius:22px; }
    .summary-label{ color:var(--muted); font-size:.85rem; }
    .summary-value{ font-size:1.3rem; font-weight:800; line-height:1.1; word-break:break-word; }
    .section-title{ display:flex; align-items:center; gap:.65rem; font-size:1.05rem; font-weight:800; margin-bottom:1rem; }
    .chip{
      display:inline-flex; align-items:center; gap:.35rem; padding:.28rem .55rem;
      border-radius:999px; font-size:.82rem; border:1px solid var(--line);
      background: rgba(255,255,255,.55);
      white-space:nowrap;
    }
    .dot{ width:10px; height:10px; border-radius:999px; display:inline-block; }
    .green{ background:var(--green); box-shadow:0 0 0 4px rgba(34,197,94,.16); }
    .red{ background:var(--red); box-shadow:0 0 0 4px rgba(239,68,68,.16); }
    .footer{ color:var(--muted); text-align:center; padding:1rem 0 1.5rem; font-size:.9rem; }
    .access-meta{ color:var(--muted); font-size:.86rem; }
    .access-name{ font-weight:800; font-size:1.02rem; }
    .small-btns .btn{ padding:.38rem .56rem; }
    .copy-field input{ border-right:0; }
    .copy-field .btn{ border-left:0; }
    .sni-pill{ cursor:pointer; user-select:none; }
    .sni-pill:hover{ transform: translateY(-1px); }
    .status-box{ min-height: 100%; }
    @media (max-width: 992px){
      .card{ border-radius:18px; }
      .navbar{ border-radius:0 0 18px 18px; }
      .summary-value{ font-size:1.15rem; }
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
    <div class="ms-auto d-flex flex-wrap align-items-center gap-2 justify-content-end">
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
        <div class="alert alert-{{ category }} border-0 shadow-sm rounded-4 mb-2" role="alert">{{ message }}</div>
      {% endfor %}
      </div>
    {% endif %}
  {% endwith %}
  {% block content %}{% endblock %}
</main>
<footer class="footer">MTProto Proxy Panel 2026 by Mr_EFES</footer>
<script src="https://cdn.jsdelivr.net/npm/bootstrap@5.3.3/dist/js/bootstrap.bundle.min.js"></script>
{% block scripts %}{% endblock %}
</body>
</html>
HTMLEOF

cat > /var/www/telemt-panel/templates/login.html <<'HTMLEOF'
{% extends "layout.html" %}
{% block content %}
<div class="row justify-content-center align-items-center" style="min-height:72vh;">
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
            <input class="form-control form-control-lg" name="username" required autofocus>
          </div>
          <div>
            <label class="form-label text-muted mb-1">Пароль</label>
            <input class="form-control form-control-lg" type="password" name="password" required>
          </div>
          <button class="btn btn-primary btn-lg w-100" type="submit">Войти</button>
        </form>
      </div>
    </div>
  </div>
</div>
{% endblock %}
HTMLEOF

cat > /var/www/telemt-panel/templates/dashboard.html <<'HTMLEOF'
{% extends "layout.html" %}
{% block content %}
<div class="row g-4 mb-4">
  <div class="col-12 col-lg-4">
    <div class="card mb-4">
      <div class="card-body p-4 p-md-5">
        <div class="section-title"><i class="fa-solid fa-plus text-primary"></i>Создать новый доступ</div>
        <form method="post" action="{{ url_for('create_access') }}" class="row g-3 align-items-end">
          <div class="col-12">
            <label class="form-label text-muted mb-1">Имя</label>
            <input class="form-control" name="nickname" placeholder="Например: Иван" required>
          </div>
          <div class="col-12">
            <label class="form-label text-muted mb-1">Устройство</label>
            <select class="form-select" name="device">
              <option>Телефон</option>
              <option>Компьютер</option>
              <option>Планшет</option>
            </select>
          </div>
          <div class="col-12">
            <button class="btn btn-primary w-100" type="submit">Создать доступ</button>
          </div>
        </form>
      </div>
    </div>

    <div class="card">
      <div class="card-body p-4 p-md-5">
        <div class="section-title"><i class="fa-solid fa-chart-column text-primary"></i>Статистика</div>
        <div class="row g-3">
          <div class="col-6">
            <div class="summary-card card">
              <div class="summary-label">Общее количество доступов</div>
              <div class="summary-value">{{ total_created }}</div>
            </div>
          </div>
          <div class="col-6">
            <div class="summary-card card">
              <div class="summary-label">IP-адресов онлайн</div>
              <div class="summary-value">{{ connected_ips }}</div>
            </div>
          </div>
          <div class="col-6">
            <div class="summary-card card">
              <div class="summary-label">Активных подключений</div>
              <div class="summary-value">{{ active_connections }}</div>
            </div>
          </div>
          <div class="col-6">
            <div class="summary-card card">
              <div class="summary-label">Fake TLS</div>
              <div class="summary-value">{{ fake_tls_domain }}</div>
            </div>
          </div>
        </div>
        <div class="mt-3 text-muted small">
          Статус сервера: <strong>{{ server_status }}</strong><br>
          Uptime сервера: <strong>{{ telemt_uptime }}</strong><br>
          Uptime системы: <strong>{{ system_uptime }}</strong>
        </div>
      </div>
    </div>
  </div>

  <div class="col-12 col-lg-8">
    <div class="card status-box">
      <div class="card-body p-4 p-md-5">
        <div class="section-title"><i class="fa-solid fa-list text-primary"></i>Список доступов</div>
        <div class="table-responsive">
          <table class="table align-middle">
            <thead>
              <tr>
                <th>Имя устройства</th>
                <th>Таймер</th>
                <th>Ссылка / QR</th>
                <th>Сеть</th>
                <th class="text-end">Действия</th>
              </tr>
            </thead>
            <tbody>
            {% for item in accesses %}
              <tr>
                <td>
                  <div class="access-name">{{ item.username }}</div>
                  <div class="access-meta">Устройство: {{ item.device }}</div>
                  {% if item.last_ip %}
                  <div class="access-meta">IP: {{ item.last_ip }}</div>
                  {% endif %}
                </td>
                <td>
                  <div class="fw-bold">{{ item.remaining_text }}</div>
                  <div class="access-meta">{{ item.status_text }}</div>
                </td>
                <td style="min-width:320px;">
                  <div class="input-group copy-field">
                    <input class="form-control" id="link-{{ loop.index }}" value="{{ item.link }}" readonly>
                    <button class="btn btn-outline-secondary" type="button" onclick="copyLink('link-{{ loop.index }}', this)">Копия</button>
                    <button class="btn btn-outline-secondary" type="button" data-bs-toggle="modal" data-bs-target="#qrModal" data-qr-url="{{ url_for('qr', username=item.username) }}" data-qr-name="{{ item.username }}">QR</button>
                  </div>
                </td>
                <td>
                  <span class="chip"><span class="dot {{ 'green' if item.online else 'red' }}"></span>{{ 'В сети' if item.online else 'Не в сети' }}</span>
                  <div class="access-meta mt-2">{{ item.connections }} conn / {{ item.ips_count }} IP</div>
                </td>
                <td class="text-end">
                  <div class="d-inline-flex flex-wrap gap-2 small-btns justify-content-end">
                    <form method="post" action="{{ url_for('toggle_access', username=item.username) }}">
                      <button class="btn btn-warning btn-sm" type="submit">{% if item.status == 'active' %}Пауза{% else %}Вкл{% endif %}</button>
                    </form>
                    <form method="post" action="{{ url_for('delete_access', username=item.username) }}" onsubmit="return confirm('Удалить доступ?');">
                      <button class="btn btn-danger btn-sm" type="submit">Удалить</button>
                    </form>
                  </div>
                </td>
              </tr>
            {% else %}
              <tr><td colspan="5" class="text-center text-muted py-5">Пока нет доступов</td></tr>
            {% endfor %}
            </tbody>
          </table>
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
        <button type="button" class="btn-close" data-bs-dismiss="modal" aria-label="Закрыть"></button>
      </div>
      <div class="modal-body text-center">
        <img id="qrImage" src="" class="img-fluid rounded-4 border">
        <div id="qrName" class="mt-3 text-muted small"></div>
      </div>
    </div>
  </div>
</div>
{% endblock %}

{% block scripts %}
<script>
function copyLink(id, btn){
  const el = document.getElementById(id);
  navigator.clipboard.writeText(el.value).then(() => {
    const old = btn.innerHTML;
    btn.innerHTML = 'Скопировано';
    setTimeout(() => btn.innerHTML = old, 1200);
  });
}
document.getElementById('qrModal')?.addEventListener('show.bs.modal', function(ev){
  const btn = ev.relatedTarget;
  document.getElementById('qrImage').src = btn.getAttribute('data-qr-url');
  document.getElementById('qrName').textContent = btn.getAttribute('data-qr-name');
});
</script>
{% endblock %}
HTMLEOF

cat > /var/www/telemt-panel/templates/settings.html <<'HTMLEOF'
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

<div class="card">
  <div class="card-body p-4 p-md-5">
    <div class="section-title"><i class="fa-solid fa-sliders text-primary"></i>Настройки прокси</div>
    <form method="post" class="vstack gap-4">
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
      <button class="btn btn-primary" type="submit">Сохранить и перезапустить</button>
    </form>
  </div>
</div>
{% endblock %}

{% block scripts %}
<script>
document.querySelectorAll('.sni-pill').forEach((el) => {
  el.addEventListener('click', () => {
    document.getElementById('fake_tls_domain').value = el.dataset.sni;
  });
});
</script>
{% endblock %}
HTMLEOF

cat > /var/www/telemt-panel/templates/admin_credentials.html <<'HTMLEOF'
{% extends "layout.html" %}
{% block content %}
<div class="row justify-content-center">
  <div class="col-12 col-lg-7">
    <div class="card">
      <div class="card-body p-4 p-md-5">
        <div class="section-title"><i class="fa-solid fa-user-gear text-primary"></i>Изменить логин и пароль администратора</div>
        <form method="post" class="row g-3">
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
            <input class="form-control" name="new_username" placeholder="Оставь пустым, если не менять">
          </div>
          <div class="col-12 col-md-6">
            <label class="form-label text-muted mb-1">Новый пароль</label>
            <input class="form-control" type="password" name="new_password" required>
          </div>
          <div class="col-12">
            <button class="btn btn-primary" type="submit">Сохранить</button>
          </div>
        </form>
      </div>
    </div>
  </div>
</div>
{% endblock %}
HTMLEOF

python3 -m venv /var/www/telemt-panel/venv >/dev/null 2>&1
/var/www/telemt-panel/venv/bin/pip install --upgrade pip >/dev/null 2>&1
/var/www/telemt-panel/venv/bin/pip install Flask gunicorn toml werkzeug qrcode pillow >/dev/null 2>&1

/var/www/telemt-panel/venv/bin/python - <<PY
import os, sqlite3
from werkzeug.security import generate_password_hash
db = sqlite3.connect("/var/lib/telemt-panel/panel.db")
db.executescript("""
CREATE TABLE IF NOT EXISTS admin(
    id INTEGER PRIMARY KEY CHECK(id=1),
    username TEXT NOT NULL,
    password_hash TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS settings(
    key TEXT PRIMARY KEY,
    value TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS accesses(
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
    expires_at TEXT NOT NULL,
    lock_reason TEXT,
    last_ip TEXT
);
""")
pairs = {
    "proxy_host": "${PROXY_DOMAIN}",
    "proxy_port": "443",
    "fake_tls_domain": "${FAKE_DOMAIN}",
    "telemt_api_token": "${API_TOKEN}",
    "bootstrap_username": "${INITIAL_USERNAME}",
    "bootstrap_secret": "${INITIAL_SECRET}",
    "default_admin_username": "${PANEL_ADMIN_USER}",
    "default_admin_password": "${PANEL_ADMIN_PASS}",
}
for k,v in pairs.items():
    db.execute("INSERT INTO settings(key,value) VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value", (k,v))
db.execute("INSERT INTO admin(id,username,password_hash) VALUES(1,?,?) ON CONFLICT(id) DO UPDATE SET username=excluded.username, password_hash=excluded.password_hash", ("${PANEL_ADMIN_USER}", generate_password_hash("${PANEL_ADMIN_PASS}")))
db.commit()
db.close()
PY

cat > /usr/local/bin/telemt-panel-maintain.py <<'PYEOF'
import json
import sqlite3
import urllib.parse
import urllib.request
import urllib.error
from datetime import datetime, timezone, timedelta

DB_PATH = "/var/lib/telemt-panel/panel.db"

def db():
    c = sqlite3.connect(DB_PATH)
    c.row_factory = sqlite3.Row
    return c

def setting(conn, key, default=""):
    row = conn.execute("SELECT value FROM settings WHERE key=?", (key,)).fetchone()
    return row["value"] if row else default

def utcnow():
    return datetime.now(timezone.utc)

def fmt(dt):
    return dt.astimezone(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00","Z")

def parse(v):
    if not v:
        return None
    try:
        return datetime.fromisoformat(v.replace("Z","+00:00"))
    except Exception:
        return None

def remaining(row):
    now = utcnow()
    created = parse(row["created_at"]) or now
    dur = int(row["duration_seconds"])
    paused_total = int(row["paused_total_seconds"] or 0)
    if row["status"] == "active":
        elapsed = (now - created).total_seconds() - paused_total
    elif row["status"] in ("paused","auto_paused"):
        p = parse(row["paused_since"]) or now
        elapsed = (p - created).total_seconds() - paused_total
    else:
        elapsed = (now - created).total_seconds() - paused_total
    return max(0, int(dur - elapsed))

def api(token, method, path, data=None):
    req = urllib.request.Request(
        f"http://127.0.0.1:9091{path}",
        data=json.dumps(data).encode("utf-8") if data is not None else None,
        headers={"Authorization": token, "Content-Type":"application/json"},
        method=method
    )
    with urllib.request.urlopen(req, timeout=10) as resp:
        out = json.loads(resp.read().decode("utf-8") or "{}")
    return out.get("data", out)

def main():
    conn = db()
    token = setting(conn, "telemt_api_token")
    rows = conn.execute("SELECT * FROM accesses").fetchall()
    try:
        users = api(token, "GET", "/v1/users")
        m = {u.get("username"): u for u in users if isinstance(u, dict)}
    except Exception:
        m = {}
    changed = False
    now = utcnow()

    for row in rows:
        u = m.get(row["username"], {})
        conn_count = int(u.get("current_connections", 0) or 0)
        ips = u.get("active_unique_ips_list") or []
        ip_count = int(u.get("active_unique_ips", len(ips)) or len(ips))

        if row["status"] == "active":
            if conn_count > 1 or ip_count > 1:
                try:
                    api(token, "DELETE", "/v1/users/" + urllib.parse.quote(row["username"]))
                except Exception:
                    pass
                conn.execute(
                    "UPDATE accesses SET status='paused', paused_since=?, paused_remaining_seconds=?, lock_reason='multi_device', last_ip=? WHERE username=?",
                    (fmt(now), remaining(row), ips[0] if ips else None, row["username"])
                )
                changed = True
            elif remaining(row) <= 0:
                try:
                    api(token, "DELETE", "/v1/users/" + urllib.parse.quote(row["username"]))
                except Exception:
                    pass
                conn.execute(
                    "UPDATE accesses SET status='auto_paused', paused_since=?, paused_remaining_seconds=0, auto_paused_at=? WHERE username=?",
                    (fmt(now), fmt(now), row["username"])
                )
                changed = True
            elif ips:
                conn.execute("UPDATE accesses SET last_ip=? WHERE username=? AND (last_ip IS NULL OR last_ip='')", (ips[0], row["username"]))
                changed = True
        elif row["status"] == "auto_paused":
            paused_at = parse(row["auto_paused_at"]) or parse(row["paused_since"]) or now
            if (now - paused_at).total_seconds() >= 86400:
                try:
                    api(token, "DELETE", "/v1/users/" + urllib.parse.quote(row["username"]))
                except Exception:
                    pass
                conn.execute("DELETE FROM accesses WHERE username=?", (row["username"],))
                changed = True

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
WorkingDirectory=/var/www/telemt-panel
Environment="PANEL_PORT=${PANEL_PORT}"
Environment="PANEL_SECRET_KEY=${PANEL_SECRET_KEY}"
Environment="PROXY_HOST=${PROXY_DOMAIN}"
Environment="PROXY_PORT=443"
Environment="FAKE_TLS_DOMAIN=${FAKE_DOMAIN}"
Environment="TELEMT_API_TOKEN=${API_TOKEN}"
Environment="DEFAULT_ADMIN_USERNAME=${PANEL_ADMIN_USER}"
Environment="DEFAULT_ADMIN_PASSWORD=${PANEL_ADMIN_PASS}"
ExecStart=/var/www/telemt-panel/venv/bin/gunicorn --workers 2 --threads 4 --bind 0.0.0.0:${PANEL_PORT} --certfile /etc/letsencrypt/live/${PANEL_DOMAIN}/fullchain.pem --keyfile /etc/letsencrypt/live/${PANEL_DOMAIN}/privkey.pem --access-logfile - --error-logfile - --capture-output app:app
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable telemt-panel --now >/dev/null 2>&1
sleep 2
systemctl is-active --quiet telemt-panel
stage_ok

CURRENT_STAGE="6/8 — Firewall"
ufw allow 22/tcp >/dev/null 2>&1 || true
ufw allow 443/tcp >/dev/null 2>&1 || true
ufw allow "${PANEL_PORT}"/tcp >/dev/null 2>&1 || true
ufw reload >/dev/null 2>&1 || true
stage_ok

CURRENT_STAGE="7/8 — Обслуживание"
cat > /etc/cron.d/telemt-panel <<EOF
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
stage_ok

CURRENT_STAGE="8/8 — Итог"
TG_LINK="tg://proxy?server=${PROXY_DOMAIN}&port=443&secret=ee${INITIAL_SECRET}$(printf '%s' "${FAKE_DOMAIN}" | xxd -p -c 256)"

echo
echo "${TG_LINK}"
if command -v qrencode >/dev/null 2>&1; then
  printf '%s\n' "${TG_LINK}" | qrencode -t ANSIUTF8
fi
echo
echo "Панель: https://${PANEL_DOMAIN}:${PANEL_PORT}"
echo "Логин: ${PANEL_ADMIN_USER}"
echo "Пароль: ${PANEL_ADMIN_PASS}"
echo "Установку завершено успешно."
stage_ok
