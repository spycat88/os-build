#!/usr/bin/env bash
# Offline test for /usr/bin/retroforge-bootctl.
#
#   tests/test-bootctl.sh
#
# WHY THIS FILE EXISTS. bootctl is what tells RAUC that a boot was healthy (mark-good, from
# retroforge-boot-good.service) and that it was not (set-state self bad, from
# retroforge-boot-bad.service). Both run unattended on every boot of every device, so a wrong exit
# status is either a healthy slot that never stops being a trial -- and fails over after three boots
# -- or a unit that re-fires every 30s for the rest of the uptime. Neither needs hardware to catch.
#
# THE CONTRACT IS THE EXIT STATUS, and every legal call exits 0, including no-ops.
#
# HOW IT WORKS: the real, shipped retroforge-bootctl is executed -- not a copy. It exposes the seams
# BOOTINFO, SESSION_MARKER, RAUC, ESP, BOOTPARTS, BOOTDIR and DEVDIR, and lib-bls.sh adds BLKID and
# DT_MODEL, documented at the top of each. The ESP and the two slots' boot partitions are plain
# directories laid out as OpenABL reads them (ESP: loader/loader.conf; bootfs/<slot>: loader/entries,
# vmlinuz-<kver>, ...). `rauc` and `blkid` are stubbed on
# disk: the rauc stub does what RAUC's custom backend does (src/bootchooser.c: mark-good is
# set-state <slot> good, mark-bad set-state bad, mark-active set-primary then set-state good) by
# calling bootctl back, and logs every call; the blkid stub prints the UUID stored in the "device".
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BOOTCTL="$ROOT/rootfs/overlay/usr/bin/retroforge-bootctl"
[ -f "$BOOTCTL" ] || { echo "no retroforge-bootctl: $BOOTCTL" >&2; exit 1; }

PASS=0; FAIL=0; CASE=""; SB=""
OUT=""; RC=0

ok()  { PASS=$((PASS+1)); printf '  ok   %s -- %s\n' "$CASE" "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s -- %s\n' "$CASE" "$1"; }

# --- stubs --------------------------------------------------------------------------------------
RAUC_STUB='#!/usr/bin/env bash
set -u
printf "%s\n" "$*" >> "$SB/rauc.log"
[ -e "$SB/rauc.fail" ] && { echo "rauc stub: failing on purpose" >&2; exit 1; }
[ "${1:-}" = status ] || { echo "rauc stub: only status is stubbed" >&2; exit 2; }
verb="${2:-}"; slot="${3:-}"
case "$slot" in
  booted)   name=$(sed -n "s/^slot=//p" "$SB/run/boot") ;;
  rootfs.0) name=A ;;
  rootfs.1) name=B ;;
  *) echo "rauc stub: unknown slot $slot" >&2; exit 1 ;;
esac
[ -n "$name" ] || { echo "rauc stub: no booted slot" >&2; exit 1; }
case "$verb" in
  mark-good)   bash "$BOOTCTL" set-state "$name" good ;;
  mark-bad)    bash "$BOOTCTL" set-state "$name" bad ;;
  mark-active) bash "$BOOTCTL" set-primary "$name" && bash "$BOOTCTL" set-state "$name" good ;;
  *) echo "rauc stub: unknown verb $verb" >&2; exit 2 ;;
esac
'
BLKID_STUB='#!/usr/bin/env bash
dev="${!#}"
[ -f "$dev" ] && cat "$dev"
'

MODEL="ACME Handheld One"

# --- sandbox ------------------------------------------------------------------------------------
sandbox() {
  SB="$(mktemp -d)"
  mkdir -p "$SB/bin" "$SB/esp/loader" "$SB/bootfs/a/loader/entries" "$SB/bootfs/b/loader/entries" \
           "$SB/run" "$SB/boot/dtbs" "$SB/dev"
  printf '%s\n' "$RAUC_STUB" >"$SB/bin/rauc"
  printf '%s\n' "$BLKID_STUB" >"$SB/bin/blkid"
  chmod +x "$SB/bin/rauc" "$SB/bin/blkid"
  printf '# id\tname\tdtb\tmodel\tbootargs\n' >"$SB/boot/boards.tsv"
  printf 'acme-one\tACME One\tqcs8550-acme-one\t%s\tirqaffinity=0-2\n' "$MODEL" >>"$SB/boot/boards.tsv"
  printf 'acme-two\tACME Two\tqcs8550-acme-two\tACME Handheld Two\t\n' >>"$SB/boot/boards.tsv"
  printf 'quiet console=tty0\n' >"$SB/boot/cmdline"
  printf 'version=1.2.3\nkernel=6.18.4\n' >"$SB/boot/release"
  printf 'dtb-one' >"$SB/boot/dtbs/qcs8550-acme-one.dtb"
  printf 'dtb-two' >"$SB/boot/dtbs/qcs8550-acme-two.dtb"
  printf '%s\0' "$MODEL" >"$SB/model"
  local s p
  for s in A B; do
    for p in root var boot; do
      printf '%s-%s-uuid\n' "$p" "${s,,}" >"$SB/dev/retroforge-$p-$s"
    done
    mkdir -p "$SB/bootfs/${s,,}/dtbs"
    printf 'kernel-%s' "$s" >"$SB/bootfs/${s,,}/vmlinuz-6.18.4"
  done
  printf 'title A\n' >"$SB/bootfs/a/loader/entries/retroforge-a+2-1.conf"
  printf 'title B\n' >"$SB/bootfs/b/loader/entries/retroforge-b+3.conf"
  printf 'default retroforge-a.conf\n' >"$SB/esp/loader/loader.conf"
  seed_boot A
}
done_() { chmod -R u+w "$SB" 2>/dev/null; rm -rf "$SB"; }
t() { CASE="$1"; sandbox; }
seed_boot() {  # <slot or ""> -- the initramfs handoff
  if [ -n "$1" ]; then printf 'slot=%s\nsource=bls\n' "$1" >"$SB/run/boot"
  else printf 'source=cmdline-fallback\n' >"$SB/run/boot"; fi
}

ENVS=()
run() {  # <args...> -- the real bootctl against the sandbox; sets OUT and RC
  OUT="$(env SB="$SB" BOOTCTL="$BOOTCTL" PATH="$SB/bin:$PATH" \
            BOOTINFO="$SB/run/boot" SESSION_MARKER="$SB/marker" \
            RAUC=rauc ESP="$SB/esp" BOOTPARTS="$SB/bootfs" BOOTDIR="$SB/boot" DEVDIR="$SB/dev" \
            BLKID=blkid DT_MODEL="$SB/model" \
            bash "$BOOTCTL" "$@" 2>&1)"
  RC=$?
}
# Every entry on both slots' partitions, by name.
entries() { (cd "$SB/bootfs" && ls a/loader/entries b/loader/entries 2>/dev/null | grep '\.conf$' | sort | tr '\n' ' ' | sed 's/ $//'); }
default_() { sed -n 's/^default //p' "$SB/esp/loader/loader.conf"; }
rauc_calls() { cat "$SB/rauc.log" 2>/dev/null; }

# --- get-current --------------------------------------------------------------------------------
t "get-current"
run get-current
[ "$RC" = 0 ] && [ "$OUT" = A ] && ok "names the booted slot (A)" || bad "rc=$RC out='$OUT'"
seed_boot B; run get-current
[ "$OUT" = B ] && ok "follows the handoff (B)" || bad "out='$OUT'"
seed_boot ""; run get-current
[ "$RC" != 0 ] && ok "a cmdline-fallback boot names no slot (rc=$RC)" || bad "answered '$OUT' for a boot with no slot"
done_

# --- get-primary / get-state: OpenABL's rule over the entries -----------------------------------
t "get-primary"
run get-primary
[ "$RC" = 0 ] && [ "$OUT" = A ] && ok "the default with tries left (A, +2-1)" || bad "rc=$RC out='$OUT'"
mv "$SB/bootfs/a/loader/entries/retroforge-a+2-1.conf" "$SB/bootfs/a/loader/entries/retroforge-a+0-3.conf"
run get-primary
[ "$OUT" = B ] && ok "the default ran out of tries: the other slot" || bad "out='$OUT'"
mv "$SB/bootfs/b/loader/entries/retroforge-b+3.conf" "$SB/bootfs/b/loader/entries/retroforge-b+0-3.conf"
run get-primary
[ "$RC" != 0 ] && ok "no slot with tries left is an error (rc=$RC)" || bad "answered '$OUT' with no good slot"
done_

t "get-state"
run get-state A
[ "$RC" = 0 ] && [ "$OUT" = good ] && ok "a slot with tries left is good" || bad "rc=$RC out='$OUT'"
mv "$SB/bootfs/b/loader/entries/retroforge-b+3.conf" "$SB/bootfs/b/loader/entries/retroforge-b+0-3.conf"
run get-state B
[ "$OUT" = bad ] && ok "+0 is bad" || bad "out='$OUT'"
rm "$SB/bootfs/b/loader/entries/retroforge-b+0-3.conf"; run get-state B
[ "$RC" = 0 ] && [ "$OUT" = bad ] && ok "no entry is bad" || bad "rc=$RC out='$OUT'"
printf 'x' >"$SB/bootfs/b/loader/entries/retroforge-b.conf"; run get-state B
[ "$OUT" = good ] && ok "an uncounted entry is good" || bad "out='$OUT'"
run get-state self
[ "$OUT" = good ] && ok "self resolves to the booted slot" || bad "out='$OUT'"
run get-state C
[ "$RC" != 0 ] && ok "an unknown slot is refused" || bad "accepted slot C"
done_

# --- set-state / set-primary --------------------------------------------------------------------
t "set-state"
run set-state self bad
[ "$RC" = 0 ] && ok "self bad exits 0" || bad "rc=$RC: $OUT"
[ "$(entries)" = "retroforge-a+0.conf retroforge-b+3.conf" ] && ok "A's counter is +0, so OpenABL boots B" \
  || bad "entries: $(entries)"
run set-state A good
[ "$(entries)" = "retroforge-a+3.conf retroforge-b+3.conf" ] && ok "good puts the counter back to +3" \
  || bad "entries: $(entries)"
grep -qx 'title A' "$SB/bootfs/a/loader/entries/retroforge-a+3.conf" && ok "a rename: the entry's content is untouched" \
  || bad "the entry's content changed"
run set-state A sideways
[ "$RC" != 0 ] && ok "a bad state value is refused" || bad "accepted 'sideways'"
rm "$SB/bootfs/b/loader/entries/retroforge-b+3.conf"
run set-state B bad
[ "$RC" = 0 ] && ok "bad on a slot with no entry is a no-op, exit 0" || bad "rc=$RC: $OUT"
run set-state B good
[ "$RC" != 0 ] && ok "good on a slot with no entry is refused (rc=$RC)" || bad "called a slot with nothing to boot good"
done_

t "set-primary"
run set-primary B
[ "$RC" = 0 ] && [ "$(default_)" = retroforge-b.conf ] && ok "loader.conf default retroforge-b.conf" \
  || bad "rc=$RC default='$(default_)': $OUT"
mv "$SB/bootfs/a/loader/entries/retroforge-a+2-1.conf" "$SB/bootfs/a/loader/entries/retroforge-a+0-3.conf"
run set-primary A
[ "$(entries)" = "retroforge-a+3.conf retroforge-b+3.conf" ] && [ "$(default_)" = retroforge-a.conf ] \
  && ok "a slot made primary gets its three tries back" || bad "entries: $(entries) default=$(default_)"
ls "$SB/esp/loader" | grep -q '\.new$' && bad "a temporary file was left behind" || ok "no temporary file left behind"
rm "$SB/bootfs/b/loader/entries/retroforge-b+3.conf"
run set-primary B
[ "$RC" = 0 ] && [ "$(default_)" = retroforge-b.conf ] && ok "a slot with no entry yet only moves the default" \
  || bad "rc=$RC default='$(default_)': $OUT"
done_

t "rauc through the backend"
run get-primary >/dev/null
OUT="$(env SB="$SB" BOOTCTL="$BOOTCTL" PATH="$SB/bin:$PATH" BOOTINFO="$SB/run/boot" ESP="$SB/esp" BOOTPARTS="$SB/bootfs" \
          BOOTDIR="$SB/boot" DEVDIR="$SB/dev" rauc status mark-active rootfs.1 2>&1)"; RC=$?
[ "$RC" = 0 ] && [ "$(default_)" = retroforge-b.conf ] && ok "mark-active rootfs.1 makes B the default" \
  || bad "rc=$RC default='$(default_)': $OUT"
OUT="$(env SB="$SB" BOOTCTL="$BOOTCTL" PATH="$SB/bin:$PATH" BOOTINFO="$SB/run/boot" ESP="$SB/esp" BOOTPARTS="$SB/bootfs" \
          BOOTDIR="$SB/boot" DEVDIR="$SB/dev" rauc status mark-bad booted 2>&1)"; RC=$?
[ "$RC" = 0 ] && [ "$(entries)" = "retroforge-a+0.conf retroforge-b+3.conf" ] && ok "mark-bad booted zeroes A" \
  || bad "rc=$RC entries: $(entries)"
done_

# --- mark-good ----------------------------------------------------------------------------------
t "mark-good"
run mark-good
[ "$RC" = 0 ] && ok "exits 0" || bad "rc=$RC: $OUT"
[ "$(rauc_calls)" = "status mark-good booted" ] && ok "confirms through rauc status mark-good booted" \
  || bad "rauc saw: $(rauc_calls | tr '\n' ';')"
[ "$(entries)" = "retroforge-a+3.conf retroforge-b+3.conf" ] && ok "the booted slot's counter is back to +3" \
  || bad "entries: $(entries)"
grep -qx 'title A' "$SB/bootfs/a/loader/entries/retroforge-a+3.conf" && ok "a committed card's entries are not rewritten" \
  || bad "mark-good rewrote A's entry"
[ ! -e "$SB/esp/dtbs" ] && ok "writes nothing to the ESP but loader.conf" || bad "the ESP got $(ls "$SB/esp")"
done_

t "mark-good commits a fresh card's board"
rm -f "$SB"/bootfs/[ab]/loader/entries/*.conf
for id in acme-one acme-two; do printf 'title setup %s\n' "$id" >"$SB/bootfs/a/loader/entries/retroforge-setup-$id.conf"; done
printf 'timeout menu-force\n' >"$SB/esp/loader/loader.conf"
rm -rf "$SB/bootfs/b"/vmlinuz-*
run mark-good
[ "$RC" = 0 ] && ok "exits 0" || bad "rc=$RC: $OUT"
[ "$(entries)" = "retroforge-a+3.conf retroforge-debug-a.conf" ] && ok "slot A's entry and debug entry written, the setup entries gone, nothing for a slot with no kernel" \
  || bad "entries: $(entries)"
e="$SB/bootfs/a/loader/entries/retroforge-a+3.conf"
for l in 'title RetroForge (Slot A)' 'version 1.2.3' 'linux /vmlinuz-6.18.4' 'initrd /initramfs-6.18.4.img'; do
  grep -qxF "$l" "$e" && ok "$l" || bad "no '$l' in: $(cat "$e")"
done
grep -q '^devicetree' "$e" && bad "the entry names a devicetree" || ok "no devicetree: OpenABL's Device model picks it"
d="$SB/bootfs/a/loader/entries/retroforge-debug-a.conf"
grep -qx 'title RetroForge (Slot A, debug)' "$d" && ! grep -q '^sort-key' "$d" \
  && ok "the debug entry: its own title, no sort-key so it lists after the slots" || bad "$(cat "$d")"
grep -qx 'options console=tty0 irqaffinity=0-2 root=PARTUUID=root-a-uuid rootfstype=btrfs rootwait ro retroforge.var=PARTUUID=var-a-uuid retroforge.slot=A rauc.slot=A loglevel=7 retroforge.splash=0 systemd.show_status=1' "$d" \
  && ok "the debug entry boots the same slot, without quiet, verbosely" || bad "$(grep options "$d")"
grep -qx 'options quiet console=tty0 irqaffinity=0-2 root=PARTUUID=root-a-uuid rootfstype=btrfs rootwait ro retroforge.var=PARTUUID=var-a-uuid retroforge.slot=A rauc.slot=A' "$e" \
  && ok "the common args, the board's args and this disk's PARTUUIDs" || bad "$(grep options "$e")"
[ "$(default_)" = retroforge-a.conf ] && ok "the booted slot is the default" || bad "default='$(default_)'"
grep -q 'menu-force' "$SB/esp/loader/loader.conf" && bad "the board menu is still forced" || ok "the board menu is no longer forced"
[ "$(rauc_calls)" = "status mark-good booted" ] && ok "and then confirms" || bad "rauc saw: $(rauc_calls | tr '\n' ';')"
done_

t "mark-good commits both slots when the card carries both"
rm -f "$SB"/bootfs/[ab]/loader/entries/*.conf
printf 'title setup\n' >"$SB/bootfs/a/loader/entries/retroforge-setup-acme-one.conf"
run mark-good
[ "$RC" = 0 ] && [ "$(entries)" = "retroforge-a+3.conf retroforge-b+3.conf retroforge-debug-a.conf retroforge-debug-b.conf" ] && ok "both slots' entries" \
  || bad "rc=$RC entries: $(entries): $OUT"
grep -q 'root=PARTUUID=root-b-uuid .*rauc.slot=B$' "$SB/bootfs/b/loader/entries/retroforge-b+3.conf" \
  && ok "B's entry names B's partitions" || bad "$(cat "$SB/bootfs/b/loader/entries/retroforge-b+3.conf")"
done_

t "mark-good on an unknown board"
rm -f "$SB"/bootfs/[ab]/loader/entries/*.conf
printf 'title setup\n' >"$SB/bootfs/a/loader/entries/retroforge-setup-acme-one.conf"
printf 'Somebody Else\0' >"$SB/model"
run mark-good
[ "$RC" != 0 ] && ok "refuses (rc=$RC), so OnFailure= demotes" || bad "confirmed a board it has no entry for"
[ "$(entries)" = "retroforge-setup-acme-one.conf" ] && ok "and the setup menu stays" || bad "entries: $(entries)"
[ -z "$(rauc_calls)" ] && ok "and RAUC was never asked" || bad "rauc saw: $(rauc_calls | tr '\n' ';')"
done_

t "mark-good on a degraded boot"
seed_boot ""
run mark-good --require-marker
[ "$RC" = 0 ] && ok "a boot with no slot exits 0" || bad "rc=$RC: $OUT"
printf '%s' "$OUT" | grep -q 'nothing to confirm' && ok "and says there is nothing to confirm" || bad "out='$OUT'"
[ -z "$(rauc_calls)" ] && ok "and never asks RAUC" || bad "rauc saw: $(rauc_calls | tr '\n' ';')"
done_

t "mark-good --require-marker"
run mark-good --require-marker
[ "$RC" != 0 ] && ok "no session marker: refuses (rc=$RC)" || bad "confirmed without a session"
[ -z "$(rauc_calls)" ] && ok "and RAUC was never asked" || bad "rauc saw: $(rauc_calls | tr '\n' ';')"
touch "$SB/marker"; run mark-good --require-marker
[ "$RC" = 0 ] && [ "$(rauc_calls)" = "status mark-good booted" ] && ok "with the marker: confirms" \
  || bad "rc=$RC rauc saw: $(rauc_calls | tr '\n' ';')"
done_

t "mark-good --wait"
run mark-good --wait soon
[ "$RC" != 0 ] && ok "a non-number is refused" || bad "accepted --wait soon"
( env SB="$SB" BOOTCTL="$BOOTCTL" PATH="$SB/bin:$PATH" BOOTINFO="$SB/run/boot" SESSION_MARKER="$SB/marker" \
      RAUC=rauc ESP="$SB/esp" BOOTPARTS="$SB/bootfs" BOOTDIR="$SB/boot" DEVDIR="$SB/dev" BLKID=blkid DT_MODEL="$SB/model" \
      bash "$BOOTCTL" mark-good --wait 30 >"$SB/wait.out" 2>&1 &
  pid=$!
  sleep 1
  kill -TERM "$pid" 2>/dev/null
  wait "$pid"; echo $? >"$SB/wait.rc" )
[ "$(cat "$SB/wait.rc" 2>/dev/null)" = 0 ] && ok "a signal during the wait exits 0" \
  || bad "rc=$(cat "$SB/wait.rc" 2>/dev/null): $(cat "$SB/wait.out")"
grep -q 'not confirming, not demoting' "$SB/wait.out" && ok "and says it gave no verdict" || bad "out: $(cat "$SB/wait.out")"
[ -z "$(rauc_calls)" ] && ok "and RAUC was never asked" || bad "rauc saw: $(rauc_calls | tr '\n' ';')"
done_

t "mark-good when RAUC fails"
touch "$SB/rauc.fail"
run mark-good
[ "$RC" != 0 ] && ok "a failed confirmation is a failure (rc=$RC), so OnFailure= demotes" || bad "exited 0"
[ "$(entries)" = "retroforge-a+2-1.conf retroforge-b+3.conf" ] && ok "and the counter keeps running" || bad "entries: $(entries)"
done_

# --- status / usage -----------------------------------------------------------------------------
t "status"
run status
[ "$RC" = 0 ] && ok "exits 0" || bad "rc=$RC"
printf '%s\n' "$OUT" | grep -qx '  retroforge-a+2-1.conf' && printf '%s\n' "$OUT" | grep -qx 'default:     A' \
  && ok "shows the entries and the default" || bad "out='$OUT'"
mv "$SB/bootfs/a/loader/entries/retroforge-a+2-1.conf" "$SB/bootfs/a/loader/entries/retroforge-a+0-3.conf"
run status
printf '%s\n' "$OUT" | grep -q '^next boot:   B$' && ok "and what boots next" || bad "out='$OUT'"
done_

t "usage"
run --help
[ "$RC" = 2 ] && printf '%s' "$OUT" | grep -q 'mark-good' && ok "--help prints the header" || bad "rc=$RC"
run frobnicate
[ "$RC" = 1 ] && ok "an unknown command exits 1" || bad "rc=$RC"
done_

# --- the shipped units call what this tool dispatches -------------------------------------------
CASE="units"
UNITS="$ROOT/rootfs/overlay/usr/lib/systemd/system"
grep -qx 'ExecStart=/usr/bin/retroforge-bootctl mark-good --require-marker --wait 30' "$UNITS/retroforge-boot-good.service" \
  && ok "boot-good runs mark-good --require-marker --wait 30" || bad "boot-good's ExecStart changed"
grep -qx 'ExecStart=/usr/bin/retroforge-bootctl set-state self bad' "$UNITS/retroforge-boot-bad.service" \
  && ok "boot-bad runs set-state self bad" || bad "boot-bad's ExecStart changed"

echo
echo "test-bootctl.sh: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
