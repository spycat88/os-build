#!/usr/bin/env bash
# Offline test of what device-env REPORTS: run the shipped script against the shipped profiles
# with a faked devicetree model, and check the values userspace will eval.
#
#   tests/test-device-env.sh
#
# Focus: the second-panel block (RETROFORGE_SECONDARY_*) of dual-screen boards. gamescope drives that
# connector as its second output (--secondary-output) and routes its digitizer there
# (--secondary-touch-device, matched on the input device name). A wrong value here is a dark
# bottom panel or touches landing on the wrong screen, and nothing on the device would say why.
# Run via `make test`.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEVENV="$ROOT/rootfs/overlay/usr/lib/retroforge/device-env"
DEVICES="$ROOT/rootfs/overlay/usr/lib/retroforge/devices"
DTS="$ROOT/kernel/dts/qcom"

PASS=0; FAIL=0; CASE=""
ok()  { PASS=$((PASS+1)); printf '  ok   %s -- %s\n' "$CASE" "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s -- %s\n' "$CASE" "$1"; }

SECONDARY=(RETROFORGE_SECONDARY_CONNECTOR RETROFORGE_SECONDARY_TOUCHSCREEN)

# What device-env reports for one model string, evaluated the way consumers do.
report() { (RETROFORGE_MODEL="$1" RETROFORGE_DEVICE_DIR="$DEVICES" bash "$DEVENV"); }
value()  { (eval "$(report "$1")"; eval "printf '%s' \"\${$2-<unset>}\""); }

# =================================================================================================
CASE="AYN Thor Lite"
m="AYN Thor Lite"
[ "$(value "$m" RETROFORGE_PRIMARY_CONNECTOR)" = DSI-1 ] && ok "primary stays DSI-1 (the 1080x1920 panel)" \
  || bad "primary is '$(value "$m" RETROFORGE_PRIMARY_CONNECTOR)', not DSI-1"
[ "$(value "$m" RETROFORGE_SECONDARY_CONNECTOR)" = DSI-2 ] && ok "second panel is DSI-2" \
  || bad "RETROFORGE_SECONDARY_CONNECTOR is '$(value "$m" RETROFORGE_SECONDARY_CONNECTOR)', not DSI-2"
[ "$(value "$m" RETROFORGE_SECONDARY_TOUCHSCREEN)" = bottom_touchscreen ] \
  && ok "bottom digitizer is the input device bottom_touchscreen" \
  || bad "RETROFORGE_SECONDARY_TOUCHSCREEN is '$(value "$m" RETROFORGE_SECONDARY_TOUCHSCREEN)'"

# =================================================================================================
CASE="single-panel boards"
for m in "AYANEO Pocket ACE" "KONKR Pocket FIT" "some board nobody knows"; do
  out="$(report "$m")"
  for v in "${SECONDARY[@]}"; do
    grep -qx "$v=''" <<<"$out" && ok "$m: $v is emitted, empty" \
      || bad "$m: $v is not emitted empty ($(grep "^$v=" <<<"$out" || echo missing))"
  done
done

# =================================================================================================
# Every profile that declares a second panel declares the whole block, on a different connector,
# and its touchscreen name is a `label` in that board's DTS: kernel patch 0705 makes edt-ft5x06
# name the input device after that label, and gamescope matches the name.
CASE="second-panel profiles"
n=0
for conf in "$DEVICES"/*.conf; do
  [ "$(basename "$conf")" = defaults.conf ] && continue
  name="$(sed -n "s/^RETROFORGE_DEVICE_NAME=//p" "$conf" | tr -d "'\"")"
  out="$(report "$name")"
  get() { sed -n "s/^$1=//p" <<<"$out" | tr -d "'"; }
  [ -n "$(get RETROFORGE_SECONDARY_CONNECTOR)" ] || continue
  n=$((n+1)); id="$(basename "$conf" .conf)"
  missing=""
  for v in "${SECONDARY[@]}"; do [ -n "$(get "$v")" ] || missing="$missing $v"; done
  [ -z "$missing" ] && ok "$id declares the whole second-panel block" || bad "$id is missing:$missing"
  [ "$(get RETROFORGE_SECONDARY_CONNECTOR)" != "$(get RETROFORGE_PRIMARY_CONNECTOR)" ] \
    && ok "$id: second panel is not the primary connector" \
    || bad "$id: RETROFORGE_SECONDARY_CONNECTOR equals the primary ($(get RETROFORGE_PRIMARY_CONNECTOR))"
  ts="$(get RETROFORGE_SECONDARY_TOUCHSCREEN)"
  dts="$(grep -l "model = \"$name\";" "$DTS"/*.dts 2>/dev/null | head -1)"
  if [ -z "$dts" ]; then
    bad "$id: no DTS declares model \"$name\""
  elif grep -q "label = \"$ts\";" "$dts"; then
    ok "$id: $ts is a touchscreen label in $(basename "$dts")"
  else
    bad "$id: '$ts' is not a label in $(basename "$dts") -- gamescope would never match it"
  fi
done
[ "$n" -ge 1 ] && ok "$n board(s) declare a second panel" || bad "no board declares a second panel"

# =================================================================================================
CASE="GPU chip id (RETROFORGE_GPU_CHIP_ID)"
# The id mesa's vram-report-limit layer matches, as Turnip reports it: the GPU node's compatible, hex
# on A7xx, core/major/minor.patch on the older Adreno. Read live from the devicetree.
DT=$(mktemp -d); trap 'rm -rf "$DT"' EXIT
chip() {  # chip <parent dir|-> <compatible...>  -> what device-env reports
  rm -rf "$DT"/*; local parent=$1; shift
  if [ "$parent" != - ]; then mkdir -p "$DT/$parent/gpu@3d00000"; printf '%s\0' "$@" > "$DT/$parent/gpu@3d00000/compatible"; fi
  (eval "$(RETROFORGE_MODEL="AYN Thor" RETROFORGE_DEVICE_DIR="$DEVICES" RETROFORGE_DEVICE_TREE="$DT" bash "$DEVENV")"
   printf '%s' "$RETROFORGE_GPU_CHIP_ID")
}
for row in "soc@0 qcom,adreno-43051401 0x5143:0x43051401" "soc@0 qcom,adreno-43050a01 0x5143:0x43050a01" \
           "soc@0 qcom,adreno-650.2 0x5143:0x06050002" "soc@0 qcom,adreno-610.0 0x5143:0x06010000" \
           "soc qcom,adreno-650.2 0x5143:0x06050002" "soc@0 qcom,adreno-gmu-wrapper -" "- - -"; do
  read -r parent compat want <<<"$row"; [ "$want" = - ] && want=""
  got=$(chip "$parent" "$compat" qcom,adreno)
  [ "$got" = "$want" ] && ok "$parent/$compat -> '${want:-none}'" || bad "$parent/$compat -> '$got', want '${want:-none}'"
done
# The four SoCs we ship, from the DTS the kernel builds: each board's GPU node must yield an id.
for soc in sm6115 sm8250 sm8550 sm8650; do
  f=$(find "$ROOT/work" -path "*/arch/arm64/boot/dts/qcom/$soc.dtsi" 2>/dev/null | head -1)
  [ -n "$f" ] || { ok "skipped: no unpacked kernel tree with $soc.dtsi"; continue; }
  c=$(grep -o 'qcom,adreno-[0-9a-f.]*"' "$f" | head -1 | tr -d '"')
  got=$(chip soc@0 "$c" qcom,adreno)
  [ -n "$got" ] && ok "$soc ($c) -> $got" || bad "$soc's compatible '$c' yields no chip id"
done

# =================================================================================================
# Wi-Fi power save (issue #27). The SM4450 boards' WLAN firmware (inside wpss.mbn) keeps dozing between
# beacons whatever power save is set to (the same under Anbernic's Android); with power save on, too,
# pings to the RG55G1 took 129 ms on average, 582 ms at worst, against 70 / 205 ms with it off.
# Those boards ask for it off; the rest keep NetworkManager's default. wifi-powersave turns the
# answer into a NetworkManager drop-in under /run, before NetworkManager reads its config.
CASE="wifi power save"
WPS="$ROOT/rootfs/overlay/usr/lib/retroforge/wifi-powersave"
for m in "Anbernic RG 55G1" "Retroid Pocket Classic" "Retroid Pocket Classic Rev Q" "Retroid Pocket Classic 6" \
         "Retroid Pocket Classic 6 Rev Q"; do
  [ "$(value "$m" RETROFORGE_WIFI_POWERSAVE)" = off ] && ok "$m: off" \
    || bad "$m: RETROFORGE_WIFI_POWERSAVE is '$(value "$m" RETROFORGE_WIFI_POWERSAVE)', not off"
done
[ "$(value "MANGMI Air X MQ66" RETROFORGE_WIFI_POWERSAVE)" = "" ] && ok "another board: unset (NetworkManager's default)" \
  || bad "MANGMI Air X MQ66: RETROFORGE_WIFI_POWERSAVE is '$(value "MANGMI Air X MQ66" RETROFORGE_WIFI_POWERSAVE)'"
NMD=$(mktemp -d); trap 'rm -rf "$NMD"' EXIT
run_wps() { RETROFORGE_MODEL="$1" RETROFORGE_DEVICE_DIR="$DEVICES" RETROFORGE_DEVICE_ENV="$DEVENV" \
            RETROFORGE_NM_CONF_DIR="$NMD" bash "$WPS"; }
if [ ! -f "$WPS" ]; then
  bad "no $WPS"
else
  run_wps "Anbernic RG 55G1"
  grep -qx 'wifi.powersave=2' "$NMD/50-retroforge-wifi-powersave.conf" 2>/dev/null \
    && grep -qx '\[connection\]' "$NMD/50-retroforge-wifi-powersave.conf" \
    && ok "RG55G1: the drop-in sets wifi.powersave=2 (disable) under [connection]" \
    || bad "RG55G1: no drop-in with wifi.powersave=2: $(cat "$NMD"/* 2>&1)"
  run_wps "MANGMI Air X MQ66"
  [ ! -e "$NMD/50-retroforge-wifi-powersave.conf" ] && ok "another board: no drop-in (a stale one is removed)" \
    || bad "the drop-in is still there for a board that does not ask for it"
fi

echo
echo "test-device-env.sh: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
