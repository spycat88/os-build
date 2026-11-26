#!/usr/bin/env bash
# Offline check for the session's stop hook that undoes OpenGamepadUI's idle dim.
#
#   tests/test-undim-backlight.sh
#
# A shell that stopped while dimmed left the backlight at 10%, systemd-backlight@ saved that and
# restored it at every boot. The hook runs the REAL rootfs/overlay/usr/lib/retroforge/undim-backlight
# against a fabricated /sys/class/backlight and asserts on the brightness it leaves, including that
# the player-owned file it reads cannot steer a write outside the backlight tree.
#
# Runs on the host with no root and no device.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOOK="$ROOT/rootfs/overlay/usr/lib/retroforge/undim-backlight"

PASS=0; FAIL=0
ok()   { printf '  ok   %s\n' "$1"; PASS=$((PASS + 1)); }
bad()  { printf '  FAIL %s\n' "$1"; FAIL=$((FAIL + 1)); }
check() { [[ $2 == "$3" ]] && ok "$1" || bad "$1 (want '$3', got '$2')"; }

[[ -x $HOOK ]] || { echo "undim-backlight is missing or not executable: $HOOK" >&2; exit 1; }

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
export RETROFORGE_BACKLIGHT_DIR="$TMP/sys/class/backlight" RETROFORGE_UNDIM_FILE="$TMP/undim-brightness"

make_bl() {  # make_bl name max cur
    mkdir -p "$RETROFORGE_BACKLIGHT_DIR/$1"
    echo "$2" >"$RETROFORGE_BACKLIGHT_DIR/$1/max_brightness"
    echo "$3" >"$RETROFORGE_BACKLIGHT_DIR/$1/brightness"
}
cur() { cat "$RETROFORGE_BACKLIGHT_DIR/$1/brightness"; }
run() { "$HOOK" >/dev/null 2>&1; echo $?; }

echo "== no file: nothing changes"
rm -rf "$TMP/sys" "$RETROFORGE_UNDIM_FILE"; make_bl panel 4095 409
check "exit 0" "$(run)" 0
check "brightness kept" "$(cur panel)" 409

echo "== dimmed: the level from before the dim is written back"
printf 'panel\t0.650000\n' >"$RETROFORGE_UNDIM_FILE"
check "exit 0" "$(run)" 0
check "65% of 4095" "$(cur panel)" 2662
[[ -f $RETROFORGE_UNDIM_FILE ]] && ok "file left for the next start" || bad "file removed"

echo "== two backlights, each its own"
rm -rf "$TMP/sys"; make_bl panel 255 25; make_bl bottom 1023 102
printf 'panel\t1.000000\nbottom\t0.500000\n' >"$RETROFORGE_UNDIM_FILE"
run >/dev/null
check "panel 100%" "$(cur panel)" 255
check "bottom 50%" "$(cur bottom)" 512

echo "== bad lines are skipped"
rm -rf "$TMP/sys"; make_bl panel 255 25
mkdir -p "$TMP/sys/class/evil"; echo 1 >"$TMP/sys/class/evil/max_brightness"; echo 0 >"$TMP/sys/class/evil/brightness"
printf '../evil\t1.0\npanel\t1.5\npanel\t-0.2\npanel\tabc\nmissing\t0.5\npanel\n' >"$RETROFORGE_UNDIM_FILE"
check "exit 0" "$(run)" 0
check "panel untouched" "$(cur panel)" 25
check "no write outside the backlight dir" "$(cat "$TMP/sys/class/evil/brightness")" 0

echo "== a symlinked file is not followed"
printf 'panel\t1.0\n' >"$TMP/real"; ln -sf "$TMP/real" "$RETROFORGE_UNDIM_FILE"
run >/dev/null
check "panel untouched" "$(cur panel)" 25

echo
echo "$PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
