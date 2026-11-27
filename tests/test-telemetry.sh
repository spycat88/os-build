#!/usr/bin/env bash
# Offline check for the device report: the REAL client (rootfs/overlay/usr/bin/retroforge-telemetry)
# against the REAL server (telemetry-server/server.py) on localhost, over a fabricated sysfs.
#
#   tests/test-telemetry.sh
#
# Asserts: the device ID is md5sum(serial) cut to 20; nothing is sent without a recorded yes (no
# answer, or "off" from the consent screen) and every off source beats a yes; a first report inserts
# and a second updates (report_count, first_seen kept, last_seen moved, version history row per build); a dead server costs exactly ATTEMPTS tries and exit 1; the server refuses
# malformed IDs and never stores an IP. Runs on the host with no root and no device.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLIENT="$ROOT/rootfs/overlay/usr/bin/retroforge-telemetry"
SERVER="$ROOT/telemetry-server/server.py"
TMP=$(mktemp -d)
export PYTHONPYCACHEPREFIX="$TMP/pycache"
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); }
fail() { FAIL=$((FAIL+1)); echo "FAIL: $1" >&2; }
check() { if eval "$2"; then ok; else fail "$1"; fi; }

# --- fake device -------------------------------------------------------------------------------
F=$TMP/dev
mkdir -p "$F/soc0" "$F/block/sda" "$F/home" "$F/etc"
printf '1234567890\n' >"$F/soc0/serial_number"
echo SM8550 >"$F/soc0/machine"
printf 'AYN Odin 2\0' >"$F/model"
printf 'NAME="RetroForge"\nVERSION_ID=1.2.0\nVERSION="1.2.0 (abc123)"\nBUILD_ID=20261126T000000Z\nVARIANT_ID=unified\n' >"$F/os-release"
printf 'RETROFORGE_MODE=release\nRETROFORGE_GIT=abc123\n' >"$F/retroforge-release"
echo 'root=PARTUUID=x rauc.slot=B quiet' >"$F/cmdline"
printf 'MemTotal:       16000000 kB\n' >"$F/meminfo"
echo '42.5 40.0' >"$F/uptime"
mkdir -p "$F/block/sda/sda5"; touch "$F/block/sda/sda5/partition"; echo 500000000 >"$F/block/sda/size"
ln -s "$F/block/sda/sda5" "$F/block/sda5"
mkdir -p "$F/dev"; touch "$F/dev/sda5"; echo "root=$F/dev/sda5" >"$F/boot"
printf '#!/bin/sh\necho RETROFORGE_DEVICE_ID=ayn-odin-2\necho RETROFORGE_SOC_CLASS=SM8550\n' >"$F/device-env"; chmod +x "$F/device-env"

PORT=$((20000 + RANDOM % 20000))
export RETROFORGE_TELEMETRY_SERIAL=$F/soc0/serial_number RETROFORGE_TELEMETRY_SOCINFO=$F/soc0 \
  RETROFORGE_TELEMETRY_DT_MODEL=$F/model RETROFORGE_TELEMETRY_OS_RELEASE=$F/os-release \
  RETROFORGE_TELEMETRY_RF_RELEASE=$F/retroforge-release RETROFORGE_TELEMETRY_CMDLINE=$F/cmdline \
  RETROFORGE_TELEMETRY_MEMINFO=$F/meminfo RETROFORGE_TELEMETRY_UPTIME=$F/uptime \
  RETROFORGE_TELEMETRY_BOOTINFO=$F/boot RETROFORGE_TELEMETRY_SYSBLOCK=$F/block \
  RETROFORGE_TELEMETRY_DEVICE_ENV=$F/device-env RETROFORGE_TELEMETRY_CONFIG=$F/etc/telemetry.conf \
  RETROFORGE_TELEMETRY_USER_CONFIG=$F/home/telemetry.conf RETROFORGE_OTA_CONFIG=$F/etc/ota.conf \
  RETROFORGE_OTA_USER_CONFIG=$F/home/ota.conf RETROFORGE_TELEMETRY_STATE=$F/state.json \
  RETROFORGE_TELEMETRY_URL=http://127.0.0.1:$PORT/v1/report RETROFORGE_TELEMETRY_INTERVAL=1

# --- payload -----------------------------------------------------------------------------------
want_id=$(md5sum "$F/soc0/serial_number" | cut -c1-20)
show=$(python3 "$CLIENT" show)
get() { python3 -c 'import json,sys; print(json.load(sys.stdin).get(sys.argv[1]))' "$1" <<<"$show"; }
check "device_id is md5sum|cut -c1-20" '[[ $(get device_id) == "$want_id" ]]'
check "soc from socinfo"               '[[ $(get soc) == SM8550 ]]'
check "model from devicetree"          '[[ $(get device_model) == "AYN Odin 2" ]]'
check "install target ufs"             '[[ $(get install_target) == ufs ]]'
check "storage size"                   '[[ $(get storage_gb) == 256 ]]'
check "boot slot"                      '[[ $(get boot_slot) == B ]]'
check "default channel stable"         '[[ $(get ota_channel) == stable ]]'
check "ram"                            '[[ $(get ram_mb) == 15625 ]]'

# --- consent: no answer yet = nothing at all --------------------------------------------------
out=$(python3 "$CLIENT" run 2>&1); rc=$?
check "no answer: exits 0"             '[[ $rc == 0 ]]'
check "no answer: no attempt"          '! grep -q attempt <<<"$out"'
python3 "$CLIENT" consented 2>/dev/null; rc=$?
check "no answer: condition fails"     '[[ $rc == 1 ]]'
echo TELEMETRY=off >"$F/home/telemetry.conf"   # what the consent screen writes for "no"
python3 "$CLIENT" consented 2>/dev/null; rc=$?
check "declined: condition fails"      '[[ $rc == 1 ]]'
echo TELEMETRY=on >"$F/home/telemetry.conf"    # ... and for "yes"
python3 "$CLIENT" consented 2>/dev/null; rc=$?
check "consented: condition passes"    '[[ $rc == 0 ]]'

# --- dead server: 3 tries then exit 1 ----------------------------------------------------------
out=$(python3 "$CLIENT" run 2>&1); rc=$?
check "dead server exits 1"            '[[ $rc == 1 ]]'
check "dead server tried 3 times"      '[[ $(grep -c "failed" <<<"$out") == 3 ]]'

# --- live server -------------------------------------------------------------------------------
DB=$TMP/t.db
TELEMETRY_DB=$DB TELEMETRY_LISTEN=127.0.0.1:$PORT TELEMETRY_STATS_TOKEN=s3cret python3 "$SERVER" 2>"$TMP/server.log" &
SPID=$!; trap 'kill $SPID 2>/dev/null; rm -rf "$TMP"' EXIT
for _ in $(seq 50); do curl -fs "http://127.0.0.1:$PORT/healthz" >/dev/null && break; sleep 0.1; done

python3 "$CLIENT" run 2>"$TMP/c1"; rc=$?
check "first report exits 0"           '[[ $rc == 0 ]]'
check "first report is created"        'grep -q "HTTP 201" "$TMP/c1"'
q() { python3 -c 'import sqlite3,sys; print(sqlite3.connect(sys.argv[1]).execute(sys.argv[2]).fetchone()[0])' "$DB" "$1"; }
first=$(q "select first_seen from devices")
sleep 1.1
sed -i 's/VERSION_ID=1.2.0/VERSION_ID=1.3.0/; s/BUILD_ID=.*/BUILD_ID=20261201T000000Z/' "$F/os-release"
python3 "$CLIENT" run 2>"$TMP/c2"
check "second report is an update"     'grep -q "HTTP 200" "$TMP/c2"'
check "one device row"                 '[[ $(q "select count(*) from devices") == 1 ]]'
check "report_count 2"                 '[[ $(q "select report_count from devices") == 2 ]]'
check "first_seen kept"                '[[ $(q "select first_seen from devices") == "$first" ]]'
check "last_seen moved"                '[[ $(q "select last_seen > first_seen from devices") == 1 ]]'
check "version updated"                '[[ $(q "select os_version_id from devices") == 1.3.0 ]]'
check "first version kept"             '[[ $(q "select first_version_id from devices") == 1.2.0 ]]'
check "two builds in history"          '[[ $(q "select count(*) from device_builds") == 2 ]]'
check "no IP in database"              '! strings "$DB" | grep -q 127.0.0.1'
check "no IP in server log"            '! grep -v "^listening" "$TMP/server.log" | grep -q 127.0.0.1'

# --- consent withdrawn, and offs that beat a yes ----------------------------------------------
n() { q "select report_count from devices"; }
before=$(n)
RETROFORGE_TELEMETRY=off python3 "$CLIENT" run 2>/dev/null
check "env off beats yes"              '[[ $(n) == $before ]]'
echo 'root=x retroforge.telemetry=0' >"$F/cmdline"; python3 "$CLIENT" run 2>/dev/null
check "cmdline off beats yes"          '[[ $(n) == $before ]]'
echo 'root=x' >"$F/cmdline"
echo TELEMETRY=off >"$F/etc/telemetry.conf"; python3 "$CLIENT" run 2>/dev/null
check "image off beats yes"            '[[ $(n) == $before ]]'
rm "$F/etc/telemetry.conf"
RETROFORGE_TELEMETRY=on python3 "$CLIENT" disable >/dev/null; RETROFORGE_TELEMETRY=on python3 "$CLIENT" run 2>/dev/null; rc=$?
check "withdrawn: env cannot force on" '[[ $(n) == $before ]]'
check "withdrawn: exits 0"             '[[ $rc == 0 ]]'
python3 "$CLIENT" enable >/dev/null; python3 "$CLIENT" run 2>/dev/null
check "enable gives consent"           '[[ $(n) == $((before+1)) ]]'

# --- server validation -------------------------------------------------------------------------
post() { curl -s -o /dev/null -w '%{http_code}' -H 'Content-Type: application/json' -d "$1" "http://127.0.0.1:$PORT/v1/report"; }
check "bad id refused"                 '[[ $(post "{\"schema\":1,\"device_id\":\"ZZ\"}") == 400 ]]'
check "unknown schema refused"         '[[ $(post "{\"schema\":9,\"device_id\":\"0123456789abcdef0123\"}") == 400 ]]'
check "stats needs token"              '[[ $(curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:$PORT/v1/stats) == 401 ]]'
check "stats with token"               'curl -fs -H "Authorization: Bearer s3cret" http://127.0.0.1:$PORT/v1/stats | grep -q "\"devices\": 1"'

echo "test-telemetry: $PASS passed, $FAIL failed"
[[ $FAIL == 0 ]]
