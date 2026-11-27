# retroforge telemetry server (PHP)

Receives the once-per-boot report from `retroforge-telemetry` (see `docs/telemetry.md`), keeps one row
per device in SQLite, and shows the numbers on a password-protected stats page.

- **Needs:** PHP 8.1+ with `pdo_sqlite` (on by default almost everywhere) and HTTPS. No Composer, no
  database server, no PHP extensions beyond that. Works on ordinary shared hosting.
- **New and returning devices:** a first report inserts the device; later ones update `last_seen`,
  `report_count` and the current facts (version, channel, ...). `first_seen` and `first_version_id`
  never change.
- **Country:** looked up from the request IP in a free GeoIP file (`lib/mmdb.php` reads it, no
  extension needed), or taken from Cloudflare's `CF-IPCountry`. The IP itself is never stored.

## Files

| File | |
|---|---|
| `report.php` | the endpoint devices POST to |
| `stats.php` | the stats page (also the folder's index) |
| `config.sample.php` | copy to `config.php`: database path, GeoIP file, stats password |
| `schema.sql` | tables, applied automatically (idempotent) |
| `lib/common.php`, `lib/mmdb.php` | database helpers and the GeoIP reader |
| `data/` | the SQLite database and `country.mmdb` live here |
| `geoip-update.sh` | fetches the free DB-IP country database |
| `.htaccess`, `lib/.htaccess`, `data/.htaccess` | Apache: serve only the two pages |

## Install

1. Upload this folder to the web host, for example as `https://telemetry.retroforge.org/`.
   The client posts to `https://telemetry.retroforge.org/report.php`. Hosting it somewhere else? Set
   `TELEMETRY_URL=` in `rootfs/overlay/etc/retroforge/telemetry.conf` (or change `DEFAULT_URL` in
   `rootfs/overlay/usr/bin/retroforge-telemetry`).
2. Copy `config.sample.php` to `config.php` and set `stats_password` to something long.
3. Make `data/` writable by PHP (`chmod 775 data`, or whatever your host's panel calls it). SQLite
   needs to write the folder, not just the file.
4. Get the GeoIP file: run `./geoip-update.sh` on the host, or download
   `dbip-country-lite-YYYY-MM.mmdb.gz` from <https://db-ip.com/db/download/ip-to-country-lite>,
   unzip it and upload it as `data/country.mmdb`. MaxMind GeoLite2-Country works too.
   Refresh it monthly (cron: `0 4 3 * * /path/to/geoip-update.sh`).
5. Open `stats.php` and sign in.

**nginx** does not read `.htaccess`. Add:

```nginx
location ~ ^/(data|lib)/ { deny all; }
location ~ ^/(config|config\.sample)\.php$ { deny all; }
location ~ \.(sql|md|sh)$ { deny all; }
```

If you can, put `data/` outside the web root and point `db` and `geoip_db` in `config.php` at it.

**Behind Cloudflare:** set `trust_proxy => true`. The IP then comes from `CF-Connecting-IP` and the
country from `CF-IPCountry` (no GeoIP file needed). Leave it `false` otherwise, or a client could
claim any IP in `X-Forwarded-For`.

## Stats page

`stats.php` signs in with `stats_password` and shows, for 7 days / 30 days / 90 days / a year / all time:

- devices ever seen, active in the period, active in the last 24 hours, new in the period, total reports
- active devices per day and new devices per day (bar charts)
- breakdowns of active devices by model, SoC, RetroForge version, country, update channel, SD vs
  internal install, memory, boot disk size and build type
- the 50 most recently seen devices (signed-in only)

Set `stats_public => true` to show the aggregate numbers without a password; the device list stays
behind the sign-in.

## API

`POST /report.php`, JSON body (max 8 KiB):

| Response | When |
|---|---|
| `201 {"status":"created"}` | first report from this `device_id` |
| `200 {"status":"updated"}` | returning device |
| `400` | not JSON, unknown `schema`, `device_id` not 20 lowercase hex digits |
| `405` / `413` | not a POST / body too large |
| `503` | database error (the client retries) |

Unknown fields are ignored; strings are cut to 128 characters; integers outside 0..2^40 become NULL.

## Database

Three tables (full definitions in `schema.sql`):

- `devices`: one row per device. `device_id`, `first_seen`, `last_seen`, `report_count`,
  `first_version_id`, `country`, and every field of the report.
- `device_builds`: one row per (device, build), the first time a device reports that build. Gives
  update roll-out over time.
- `device_days`: one row per (UTC day, device) that reported. Feeds "active devices per day".

Useful queries (`sqlite3 data/telemetry.db`):

```sql
-- how many devices moved to 1.3.0, per day
SELECT date(first_seen), COUNT(*) FROM device_builds WHERE os_version_id = '1.3.0' GROUP BY 1;

-- monthly active devices
SELECT substr(day, 1, 7), COUNT(DISTINCT device_id) FROM device_days GROUP BY 1;
```

Backup: copy `data/telemetry.db` (or `sqlite3 data/telemetry.db ".backup backup.db"` while live).

Retention, if you want it:

```sql
DELETE FROM device_days WHERE day < date('now', '-400 days');
DELETE FROM devices WHERE last_seen < strftime('%Y-%m-%dT%H:%M:%SZ', 'now', '-365 days');
```

## Try it locally

```sh
cp config.sample.php config.php    # set stats_password
php -S 127.0.0.1:8080
RETROFORGE_TELEMETRY_URL=http://127.0.0.1:8080/report.php retroforge-telemetry run
```

`tests/test-telemetry.sh` does this against a fake device.
