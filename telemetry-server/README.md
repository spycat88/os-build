# retroforge telemetry server

Receives the once-per-boot report from `retroforge-telemetry` (see `docs/telemetry.md`) and keeps one
row per device in SQLite: new devices are inserted, returning devices update `last_seen`,
`report_count` and their current facts, `first_seen` never changes.

- **Stack:** Python 3.9+ standard library (`http.server`, `sqlite3`), plus the optional `maxminddb`
  module for GeoIP. One file, no framework, no database server. SQLite in WAL mode handles far more
  than one report per device per boot; move to Postgres only if the stats queries ever get slow.
- **TLS:** terminated by a reverse proxy (Caddy example included). The server listens on localhost.
- **Privacy:** the request IP is used for the GeoIP lookup and an in-memory rate limit, and never
  written to the database or the log. Keep the proxy's access log off too (the Caddy example does).

## Files

| File | |
|---|---|
| `server.py` | the server |
| `schema.sql` | the database schema, applied idempotently on every start |
| `requirements.txt` | `maxminddb` (optional) |
| `retroforge-telemetry-server.service` | systemd unit |
| `Caddyfile.example` | HTTPS front end for `telemetry.retroforge.org` |
| `geoip-update.sh` | fetches the free DB-IP country database |

## API

`POST /v1/report`, JSON body (max 8 KiB):

| Response | When |
|---|---|
| `201 {"status":"created"}` | first report from this `device_id` |
| `200 {"status":"updated"}` | returning device |
| `400` | not JSON, unknown `schema`, `device_id` not 20 lowercase hex digits |
| `413` / `429` | body too large / more than `TELEMETRY_RATE` reports a minute from one IP |
| `503` | database error (the client retries) |

Unknown fields are ignored; strings are cut to 128 characters; integers outside 0..2^40 are stored as NULL.

`GET /v1/stats` with `Authorization: Bearer $TELEMETRY_STATS_TOKEN`: total devices, active in the last
30 days, new in the last 7, and the active ones broken down by model, SoC, version, country, OTA
channel and install target. Disabled when no token is set.

`GET /healthz`: `ok`.

## Database

Two tables (full definitions in `schema.sql`):

- `devices`: one row per device. `device_id`, `first_seen`, `last_seen`, `report_count`,
  `first_version_id`, `country`, and every field of the report (OS name, version id, version, build
  id, variant, git, build mode, SoC, model, profile, kernel, arch, CPU count, RAM, storage, install
  target, OTA channel, boot slot, uptime).
- `device_builds`: one row per (device, build) the first time a device reports that build. Grows with
  OTAs, not boots, and gives update roll-out curves.

Useful queries:

```sql
-- active devices per model, last 30 days
SELECT device_model, COUNT(*) FROM devices
 WHERE last_seen >= strftime('%Y-%m-%dT%H:%M:%SZ','now','-30 days') GROUP BY 1 ORDER BY 2 DESC;

-- how many devices moved to 1.3.0, per day
SELECT date(first_seen), COUNT(*) FROM device_builds WHERE os_version_id = '1.3.0' GROUP BY 1;

-- SD card vs internal installs
SELECT install_target, COUNT(*) FROM devices GROUP BY 1;
```

## Run it locally

```sh
python3 telemetry-server/server.py            # 127.0.0.1:8080, ./telemetry.db
RETROFORGE_TELEMETRY_URL=http://127.0.0.1:8080/v1/report retroforge-telemetry run
```

`tests/test-telemetry.sh` does exactly this against a fake sysfs.

## Deploy (Debian/Ubuntu/Arch VPS)

```sh
# 1. code and venv
sudo useradd --system --home /var/lib/retroforge-telemetry --shell /usr/sbin/nologin telemetry
sudo mkdir -p /opt/retroforge-telemetry
sudo cp server.py schema.sql requirements.txt geoip-update.sh /opt/retroforge-telemetry/
sudo python3 -m venv /opt/retroforge-telemetry/venv
sudo /opt/retroforge-telemetry/venv/bin/pip install -r /opt/retroforge-telemetry/requirements.txt

# 2. settings
sudo tee /etc/retroforge-telemetry.env >/dev/null <<EOT
TELEMETRY_GEOIP_DB=/var/lib/retroforge-telemetry/country.mmdb
TELEMETRY_STATS_TOKEN=$(openssl rand -hex 24)
EOT
sudo chmod 600 /etc/retroforge-telemetry.env

# 3. service (creates /var/lib/retroforge-telemetry), then GeoIP
sudo cp retroforge-telemetry-server.service /etc/systemd/system/
sudo systemctl daemon-reload && sudo systemctl enable --now retroforge-telemetry-server
sudo /opt/retroforge-telemetry/geoip-update.sh && sudo systemctl restart retroforge-telemetry-server

# 4. HTTPS: DNS A/AAAA for telemetry.retroforge.org -> this host, then
sudo cp Caddyfile.example /etc/caddy/Caddyfile && sudo systemctl reload caddy
```

Monthly GeoIP refresh (root crontab):

```
0 4 3 * * /opt/retroforge-telemetry/geoip-update.sh && systemctl restart retroforge-telemetry-server
```

DB-IP's lite database is CC BY 4.0: credit "IP geolocation by DB-IP" wherever stats are published.
MaxMind GeoLite2-Country works too (free account needed); point `TELEMETRY_GEOIP_DB` at it.

Behind Cloudflare instead of Caddy: keep `TELEMETRY_TRUST_PROXY=1` and the server takes the country
from Cloudflare's `CF-IPCountry` header, so no GeoIP file is needed. Only set
`TELEMETRY_TRUST_PROXY=1` when a proxy you control is the only way in; otherwise clients could forge
`X-Forwarded-For`.

Backups: `sqlite3 /var/lib/retroforge-telemetry/telemetry.db ".backup /somewhere/telemetry-$(date +%F).db"`
is safe while the server runs.

Retention: rows are overwritten in place, so a device that stops reporting keeps its last row. To
drop devices not seen for a year:
`DELETE FROM devices WHERE last_seen < strftime('%Y-%m-%dT%H:%M:%SZ','now','-365 days');`
