-- retroforge telemetry database (SQLite 3.24+ for UPSERT). lib/common.php applies it on every request;
-- every statement is idempotent, so it is safe to run against a live database.
--
-- Timestamps are UTC, ISO 8601 text ('2026-11-26T23:45:16Z'): sortable, readable in the sqlite3
-- shell, and what strftime() and date() take directly.
PRAGMA journal_mode = WAL;

-- One row per device, keyed by the client's device ID (first 20 hex digits of md5(SoC serial)).
-- A report from a new ID inserts; a report from a known ID overwrites the facts that can change and
-- leaves first_seen / first_version_id alone.
CREATE TABLE IF NOT EXISTS devices (
    device_id        TEXT PRIMARY KEY
                     CHECK (length(device_id) = 20 AND device_id NOT GLOB '*[^0-9a-f]*'),
    first_seen       TEXT NOT NULL,
    last_seen        TEXT NOT NULL,
    report_count     INTEGER NOT NULL DEFAULT 1,   -- ~ boots that reached the server
    first_version_id TEXT,                         -- the release the device first reported with
    country          TEXT,                         -- ISO 3166-1 alpha-2 from GeoIP; NULL if unknown. The IP is not kept.
    schema           INTEGER,
    os_name          TEXT,
    os_version_id    TEXT,
    os_version       TEXT,
    os_build_id      TEXT,
    os_variant       TEXT,
    os_git           TEXT,
    build_mode       TEXT,                         -- release / dev
    soc              TEXT,                         -- e.g. SM8550
    device_model     TEXT,                         -- devicetree model, e.g. 'AYN Odin 2'
    device_profile   TEXT,                         -- retroforge profile, e.g. ayn-odin-2
    kernel           TEXT,
    arch             TEXT,
    cpu_count        INTEGER,
    ram_mb           INTEGER,
    storage_gb       INTEGER,                      -- size of the disk the OS booted from
    install_target   TEXT,                         -- ufs / sd / emmc / usb / nvme / unknown
    ota_channel      TEXT,
    boot_slot        TEXT,                         -- A / B
    uptime_s         INTEGER                       -- at the moment of the last report
);

CREATE INDEX IF NOT EXISTS devices_last_seen ON devices(last_seen);
CREATE INDEX IF NOT EXISTS devices_model     ON devices(device_model);
CREATE INDEX IF NOT EXISTS devices_version   ON devices(os_version_id);

-- Each distinct build a device has run, with when it was first seen on it. One row per
-- (device, build), so this grows with OTAs, not with boots: it answers "how fast does a release
-- roll out" and "which version did people come from", which the overwrite-in-place devices row cannot.
CREATE TABLE IF NOT EXISTS device_builds (
    device_id     TEXT NOT NULL REFERENCES devices(device_id) ON DELETE CASCADE,
    os_build_id   TEXT NOT NULL,
    os_version_id TEXT,
    first_seen    TEXT NOT NULL,
    PRIMARY KEY (device_id, os_build_id)
);

-- Which devices reported on which UTC day: one row per (day, device), however many boots. It is what
-- the stats page's "active devices per day" chart counts, which last_seen alone cannot answer for any
-- day but today. Grows by (active devices x days); prune with the DELETE in README.md if it matters.
CREATE TABLE IF NOT EXISTS device_days (
    day       TEXT NOT NULL,                      -- 'YYYY-MM-DD', UTC
    device_id TEXT NOT NULL REFERENCES devices(device_id) ON DELETE CASCADE,
    PRIMARY KEY (day, device_id)
) WITHOUT ROWID;
