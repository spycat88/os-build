#!/usr/bin/env python3
"""retroforge telemetry server — receives the once-per-boot device report and upserts it into SQLite.

    POST /v1/report     JSON from retroforge-telemetry. 201 {"status":"created"} for a new device,
                        200 {"status":"updated"} for a returning one, 4xx for anything malformed.
    GET  /v1/stats      aggregate counts (needs `Authorization: Bearer $TELEMETRY_STATS_TOKEN`).
    GET  /healthz       200 "ok".

Python 3.9+ standard library only, plus the optional `maxminddb` module for GeoIP. Meant to run
behind a TLS-terminating reverse proxy (Caddy / nginx) on localhost; see README.md.

Configuration (environment):
    TELEMETRY_DB            SQLite path                      (default ./telemetry.db)
    TELEMETRY_LISTEN        host:port                        (default 127.0.0.1:8080)
    TELEMETRY_GEOIP_DB      country .mmdb (GeoLite2-Country or DB-IP country lite); unset = no lookup
    TELEMETRY_TRUST_PROXY   1 = take the client IP from X-Forwarded-For / X-Real-IP (set ONLY when a
                            proxy you control is in front; otherwise any client can claim any IP)
    TELEMETRY_STATS_TOKEN   bearer token for /v1/stats; unset = /v1/stats disabled
    TELEMETRY_RATE          reports per IP per minute before 429 (default 30)

PRIVACY. The request IP is used for two things only — the GeoIP lookup and the in-memory rate limit —
and is never written to the database or the log.
"""
import ipaddress
import json
import os
import re
import sqlite3
import sys
import threading
import time
from collections import defaultdict, deque
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HERE = os.path.dirname(os.path.abspath(__file__))
DB_PATH = os.environ.get("TELEMETRY_DB", os.path.join(os.getcwd(), "telemetry.db"))
LISTEN = os.environ.get("TELEMETRY_LISTEN", "127.0.0.1:8080")
GEOIP_DB = os.environ.get("TELEMETRY_GEOIP_DB", "")
TRUST_PROXY = os.environ.get("TELEMETRY_TRUST_PROXY", "") == "1"
STATS_TOKEN = os.environ.get("TELEMETRY_STATS_TOKEN", "")
RATE = int(os.environ.get("TELEMETRY_RATE", "30"))
MAX_BODY = 8192

SCHEMAS = {1}
DEVICE_ID = re.compile(r"^[0-9a-f]{20}$")
STR_FIELDS = (
    "os_name", "os_version_id", "os_version", "os_build_id", "os_variant", "os_git", "build_mode",
    "soc", "device_model", "device_profile", "kernel", "arch", "install_target", "ota_channel",
    "boot_slot",
)
INT_FIELDS = ("cpu_count", "ram_mb", "storage_gb", "uptime_s")
FIELDS = STR_FIELDS + INT_FIELDS


def log(msg):
    print(msg, file=sys.stderr, flush=True)


# --- storage ---------------------------------------------------------------------------------------

_local = threading.local()


def db():
    conn = getattr(_local, "conn", None)
    if conn is None:
        conn = sqlite3.connect(DB_PATH, timeout=10)
        conn.execute("PRAGMA foreign_keys = ON")
        conn.execute("PRAGMA busy_timeout = 10000")
        _local.conn = conn
    return conn


def init_db():
    with open(os.path.join(HERE, "schema.sql")) as f:
        sql = f.read()
    conn = sqlite3.connect(DB_PATH)
    conn.executescript(sql)
    conn.close()


def now():
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


UPSERT = f"""
INSERT INTO devices (device_id, first_seen, last_seen, report_count, first_version_id, country, schema,
                     {", ".join(FIELDS)})
VALUES (:device_id, :now, :now, 1, :os_version_id, :country, :schema, {", ".join(":" + f for f in FIELDS)})
ON CONFLICT(device_id) DO UPDATE SET
    last_seen    = excluded.last_seen,
    report_count = devices.report_count + 1,
    country      = COALESCE(excluded.country, devices.country),
    schema       = excluded.schema,
    {", ".join(f"{f} = excluded.{f}" for f in FIELDS)}
"""


def store(rec):
    """Upsert one validated report. Returns True when the device is new."""
    conn = db()
    with conn:  # one transaction: the existence check and the write cannot interleave with another report
        conn.execute("BEGIN IMMEDIATE")
        new = conn.execute("SELECT 1 FROM devices WHERE device_id = ?", (rec["device_id"],)).fetchone() is None
        conn.execute(UPSERT, rec)
        if rec.get("os_build_id"):
            conn.execute(
                "INSERT OR IGNORE INTO device_builds (device_id, os_build_id, os_version_id, first_seen)"
                " VALUES (?, ?, ?, ?)",
                (rec["device_id"], rec["os_build_id"], rec.get("os_version_id"), rec["now"]),
            )
    return new


def stats():
    conn = db()
    one = lambda sql: conn.execute(sql).fetchone()[0]
    def by(col, where=""):
        rows = conn.execute(
            f"SELECT COALESCE({col}, 'unknown'), COUNT(*) FROM devices {where} GROUP BY 1 ORDER BY 2 DESC"
        ).fetchall()
        return dict(rows)
    active = "WHERE last_seen >= strftime('%Y-%m-%dT%H:%M:%SZ', 'now', '-30 days')"
    return {
        "devices": one("SELECT COUNT(*) FROM devices"),
        "active_30d": one(f"SELECT COUNT(*) FROM devices {active}"),
        "new_7d": one("SELECT COUNT(*) FROM devices WHERE first_seen >= strftime('%Y-%m-%dT%H:%M:%SZ', 'now', '-7 days')"),
        "active_30d_by": {
            "device_model": by("device_model", active),
            "soc": by("soc", active),
            "os_version_id": by("os_version_id", active),
            "country": by("country", active),
            "ota_channel": by("ota_channel", active),
            "install_target": by("install_target", active),
        },
    }


# --- GeoIP -----------------------------------------------------------------------------------------

_geo = None
if GEOIP_DB:
    try:
        import maxminddb
        _geo = maxminddb.open_database(GEOIP_DB)
        log(f"GeoIP: {GEOIP_DB}")
    except Exception as e:  # missing module or file: run without, say so once
        log(f"GeoIP disabled: {e}")


def country_for(ip, headers):
    if TRUST_PROXY:
        cf = headers.get("CF-IPCountry", "")
        if re.fullmatch(r"[A-Z]{2}", cf) and cf not in ("XX", "T1"):
            return cf
    if _geo is None or not ip:
        return None
    try:
        if not ipaddress.ip_address(ip).is_global:
            return None
        rec = _geo.get(ip) or {}
    except ValueError:
        return None
    code = (rec.get("country") or rec.get("registered_country") or {}).get("iso_code")
    return code if code and re.fullmatch(r"[A-Z]{2}", code) else None


# --- validation ------------------------------------------------------------------------------------

def validate(data):
    if not isinstance(data, dict):
        raise ValueError("body is not a JSON object")
    if data.get("schema") not in SCHEMAS:
        raise ValueError("unknown schema")
    dev = data.get("device_id")
    if not isinstance(dev, str) or not DEVICE_ID.match(dev):
        raise ValueError("device_id must be 20 lowercase hex digits")
    rec = {"device_id": dev, "schema": data["schema"]}
    for f in STR_FIELDS:
        v = data.get(f)
        rec[f] = v[:128] if isinstance(v, str) and v else None
    for f in INT_FIELDS:
        v = data.get(f)
        rec[f] = v if isinstance(v, int) and not isinstance(v, bool) and 0 <= v < 2**40 else None
    return rec


# --- rate limit ------------------------------------------------------------------------------------

_hits = defaultdict(deque)
_hits_lock = threading.Lock()


def limited(ip):
    t = time.monotonic()
    with _hits_lock:
        q = _hits[ip]
        while q and t - q[0] > 60:
            q.popleft()
        if len(q) >= RATE:
            return True
        q.append(t)
        if len(_hits) > 100000:  # bound memory: drop idle entries
            for k in [k for k, v in _hits.items() if not v]:
                del _hits[k]
        return False


# --- HTTP ------------------------------------------------------------------------------------------

class Handler(BaseHTTPRequestHandler):
    server_version = "retroforge-telemetry"
    sys_version = ""

    def log_message(self, fmt, *args):
        pass  # the default logs the client IP; we log our own line without it

    def client_ip(self):
        if TRUST_PROXY:
            xff = self.headers.get("X-Forwarded-For", "")
            if xff:
                return xff.split(",")[0].strip()
            if self.headers.get("X-Real-IP"):
                return self.headers["X-Real-IP"].strip()
        return self.client_address[0]

    def reply(self, code, obj=None, text=None):
        body = text.encode() if text is not None else json.dumps(obj or {}).encode()
        self.send_response(code)
        self.send_header("Content-Type", "text/plain" if text is not None else "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path == "/healthz":
            return self.reply(200, text="ok\n")
        if self.path == "/v1/stats":
            if not STATS_TOKEN or self.headers.get("Authorization", "") != f"Bearer {STATS_TOKEN}":
                return self.reply(401, {"error": "unauthorized"})
            return self.reply(200, stats())
        self.reply(404, {"error": "not found"})

    def do_POST(self):
        if self.path != "/v1/report":
            return self.reply(404, {"error": "not found"})
        ip = self.client_ip()
        if limited(ip):
            return self.reply(429, {"error": "slow down"})
        try:
            length = int(self.headers.get("Content-Length", "0"))
        except ValueError:
            length = -1
        if length <= 0 or length > MAX_BODY:
            return self.reply(413 if length > MAX_BODY else 400, {"error": "bad length"})
        try:
            rec = validate(json.loads(self.rfile.read(length)))
        except (ValueError, UnicodeDecodeError) as e:
            return self.reply(400, {"error": str(e)})
        rec["country"] = country_for(ip, self.headers)
        rec["now"] = now()
        try:
            new = store(rec)
        except sqlite3.Error as e:
            log(f"db error: {e}")
            return self.reply(503, {"error": "storage unavailable"})
        log(f"{'new' if new else 'returning'} {rec['device_id']} {rec.get('device_model')} "
            f"{rec.get('os_version_id')} {rec['country'] or '--'}")
        self.reply(201 if new else 200, {"status": "created" if new else "updated"})


def main():
    init_db()
    host, _, port = LISTEN.rpartition(":")
    srv = ThreadingHTTPServer((host or "127.0.0.1", int(port)), Handler)
    srv.daemon_threads = True
    log(f"listening on {LISTEN}, db {DB_PATH}")
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
