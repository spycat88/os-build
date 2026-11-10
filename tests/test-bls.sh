#!/usr/bin/env bash
# Offline test for the Boot Loader Specification boot data and the library that writes the entries.
#
#   tests/test-bls.sh
#
# Four files have to agree about what a board IS, and each of them is edited for a different
# reason, so they drift silently:
#
#   boot/boards.map                                    build-time catalog: id / name / dtb / bootargs
#   kernel/dts/qcom/*.dts                              the DTBs that ship, and each board's root model
#   rootfs/overlay/usr/lib/retroforge/devices/*.conf   the identity the RUNNING system reports
#   rootfs/overlay/usr/lib/retroforge/device-env       the model -> profile map
#
# boot/gen-bls.sh turns the first two into the board table every entry is written from, and
# lib-bls.sh writes the entries. A mismatch anywhere is a board that cannot be committed, an entry
# that boots the wrong DTB, or a slot that mounts the other slot's /var.
#
# Everything runs on the host with no root, no device and no cross-build: the board table is
# GENERATED here into a temp dir, so this never asserts against a stale out/boot. Run via `make test`.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEVICES="$ROOT/rootfs/overlay/usr/lib/retroforge/devices"
BOARDS="$ROOT/boot/boards.map"
DTS="$ROOT/kernel/dts/qcom"
GEN="$ROOT/boot/gen-bls.sh"
BLSLIB="$ROOT/rootfs/overlay/usr/lib/retroforge/install/lib-bls.sh"

PASS=0; FAIL=0; CASE=""
ok()   { PASS=$((PASS+1)); printf '  ok   %s -- %s\n' "$CASE" "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL %s -- %s\n' "$CASE" "$1"; }

for f in "$BOARDS" "$GEN" "$BLSLIB"; do
  [ -e "$f" ] || { echo "missing input: $f" >&2; exit 1; }
done
[ -d "$DTS" ] || { echo "missing dts dir: $DTS" >&2; exit 1; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT

# --- 1. every catalog row names a real board DTB (bootargs may be empty) ------------------------
CASE="board catalog -> DTB"
unset pids;  declare -A pids
unset pdtbs; declare -A pdtbs
ncat=0
while IFS=$'\t' read -r id name dtb ba; do
  [ -n "$id" ] || continue
  [[ $id == \#* ]] && continue
  ncat=$((ncat+1))
  [ -n "$name" ] || bad "$id has no menu name in the catalog"
  [ -n "$dtb" ] || { bad "$id has no DTB in the catalog"; continue; }
  pids["$id"]=1
  pdtbs["$dtb"]=1
  [ -f "$DTS/$dtb.dts" ] && ok "$id -> $dtb.dts" || bad "$id names missing DTB $dtb.dts"
done < "$BOARDS"
[ "$ncat" -gt 0 ] && ok "$ncat boards in the catalog" || bad "the catalog is empty"

# --- 2. the catalog and the runtime device profiles agree on identity ---------------------------
# The catalog id is what an entry is written for; RETROFORGE_DEVICE_ID is what device-env reports at
# runtime. They are the same identity and must stay spelled the same, or a board is committed
# under a name the OS has never heard of.
CASE="catalog <-> device profiles"
unset confids; declare -A confids
for f in "$DEVICES"/*.conf; do
  [ "$(basename "$f")" = "defaults.conf" ] && continue
  id=$(sed -n 's/^RETROFORGE_DEVICE_ID=//p' "$f" | head -1 | tr -d "'\"")
  [ -n "$id" ] && confids["$id"]=1 || bad "$(basename "$f") has no RETROFORGE_DEVICE_ID"
done
[ "${#confids[@]}" -eq "$ncat" ] \
  && ok "${#confids[@]} device profiles, ${ncat} catalog rows" \
  || bad "${#confids[@]} device profiles vs $ncat catalog rows"
for id in "${!pids[@]}"; do
  [ -n "${confids[$id]:-}" ] && ok "catalog id '$id' has a device profile" \
                             || bad "catalog id '$id' has no device profile"
done
for id in "${!confids[@]}"; do
  [ -n "${pids[$id]:-}" ] && ok "device profile '$id' has a catalog row" \
                          || bad "device profile '$id' is missing from the catalog"
done

# --- 2b. device-env can actually REACH every profile --------------------------------------------
# A fourth file has to agree and nothing checked it until a six-board SoC import made the gap
# obvious. rootfs/overlay/usr/lib/retroforge/device-env maps the devicetree `model` string to a profile
# name with a hand-written case. Miss a board there and it does not fail: it falls through to
# defaults.conf, so the running system reports device-id `unknown`, exports no SOC_CLASS (powerd
# loses its underclock table) and no panel dims (retroforge-session falls back to a generic
# landscape 1920x1080 on the wrong connector). No error, just a subtly wrong session.
CASE="device-env <-> profiles"
DEVENV="$ROOT/rootfs/overlay/usr/lib/retroforge/device-env"
if [ ! -r "$DEVENV" ]; then
  bad "cannot read $DEVENV"
else
  # Case arms look like:  "AYN Thor Lite")   profile=ayn-thor-lite ;;
  unset envprof; declare -A envprof
  unset envmodel; declare -A envmodel
  while IFS= read -r line; do
    m=$(printf '%s' "$line" | sed -n 's/^[[:space:]]*"\([^"]*\)").*profile=\([A-Za-z0-9._-]*\).*/\1/p')
    p=$(printf '%s' "$line" | sed -n 's/^[[:space:]]*"\([^"]*\)").*profile=\([A-Za-z0-9._-]*\).*/\2/p')
    [ -n "$p" ] || continue
    envprof["$p"]=1
    envmodel["$m"]=1
  done < "$DEVENV"

  for id in "${!confids[@]}"; do
    [ -n "${envprof[$id]:-}" ] && ok "device-env can select profile '$id'" \
      || bad "device-env has no model string mapping to '$id' -- that board silently gets defaults.conf"
  done
  for p in "${!envprof[@]}"; do
    [ -r "$DEVICES/$p.conf" ] && ok "device-env's '$p' arm has a profile file" \
      || bad "device-env maps a model to '$p', but $p.conf does not exist"
  done

  # And the case KEYS must be real model strings, or the match never fires on hardware. Compare
  # against the root `model` of every board .dts (following one level of #include for the boards
  # that inherit their root node from a sibling .dts).
  for dts in "$DTS"/*.dts; do
    mdl=$(sed -n 's/^[[:space:]]*model = "\(.*\)";.*/\1/p' "$dts" | head -1)
    [ -n "$mdl" ] || continue
    [ -n "${envmodel[$mdl]:-}" ] && ok "model '$mdl' is matched by device-env" \
      || bad "$(basename "$dts") declares model '$mdl', which device-env's case never matches"
  done
fi

# --- 3. every shipped DTB is reachable from the catalog ------------------------------------------
# A DTB with no catalog row is only legal when it is a hardware variant deriving from one (the
# RP6's top-dpad revision). Anything else ships a board nobody can boot.
CASE="DTB -> catalog"
ndtb=0
for dts in "$DTS"/*.dts; do
  base=$(basename "$dts" .dts)
  ndtb=$((ndtb+1))
  if [ -n "${pdtbs[$base]:-}" ]; then
    ok "$base covered by a catalog row"
  elif [ -n "${pdtbs[${base%-top-dpad}]:-}" ] && [ "$base" != "${base%-top-dpad}" ]; then
    ok "$base covered by the derived ${base%-top-dpad} entry"
  else
    bad "$base has no catalog row and no parent to derive from"
  fi
done
ok "$ndtb board DTBs, $ncat catalog rows, $((ndtb - ncat)) derived"

# --- 4. gen-bls.sh: the board table and the command line ----------------------------------------
CASE="gen-bls.sh"
if bash "$GEN" "$T/boot" >/dev/null 2>"$T/generr"; then
  ok "generates"
else
  bad "gen-bls.sh failed: $(head -3 "$T/generr")"
fi
TSV="$T/boot/boards.tsv"
rows=$(grep -vc '^#' "$TSV" 2>/dev/null || echo 0)
[ "$rows" -eq "$ndtb" ] && ok "boards.tsv has $rows rows, one per DTB" || bad "boards.tsv has $rows rows, expected $ndtb"
while IFS=$'\t' read -r id name dtb model args; do
  [[ $id == \#* ]] && continue
  [ -n "$model" ] || { bad "$id has no model"; continue; }
  [ -f "$DTS/$dtb.dts" ] || bad "$id names $dtb, which has no .dts"
  nf=$(awk -F'\t' -v i="$id" '$1==i {print NF}' "$TSV")
  [ "$nf" = 5 ] || bad "$id has $nf fields, not 5"
done <"$TSV"
ok "every row has five fields, a model and a real DTB"
for id in "${!pids[@]}"; do
  want=$(awk -F'\t' -v i="$id" '$1==i {print $4}' "$BOARDS")
  got=$(awk -F'\t' -v i="$id" '$1==i {print $5}' "$TSV")
  [ "$want" = "$got" ] || bad "$id: bootargs '$got' in boards.tsv, '$want' in boards.map"
done
ok "the board args are boards.map's, verbatim"
[ -z "$(grep -v '^#' "$TSV" | cut -f4 | sort | uniq -d)" ] && ok "no two boards share a model" \
  || bad "models shared: $(grep -v '^#' "$TSV" | cut -f4 | sort | uniq -d | tr '\n' ' ')"
# Every model a running system can report must be in the table, or that board's first boot can never
# commit and its updates are refused.
for dts in "$DTS"/*.dts; do
  mdl=$(sed -n 's/^[[:space:]]*model = "\(.*\)";.*/\1/p' "$dts" | head -1)
  [ -n "$mdl" ] || continue
  cut -f4 "$TSV" | grep -qxF -- "$mdl" || bad "$(basename "$dts")'s model '$mdl' is not in boards.tsv"
done
ok "every DTS model is in boards.tsv"
CMD="$(cat "$T/boot/cmdline" 2>/dev/null)"
[ "$(wc -l <"$T/boot/cmdline")" = 1 ] && ok "cmdline is one line" || bad "cmdline is not one line"
for a in quiet loglevel=3 console=tty0 drm_kms_helper.fbdev_emulation=0; do
  grep -qw -- "$a" <<<"$CMD" && ok "cmdline carries $a" || bad "cmdline lacks $a: $CMD"
done
for a in root= rauc.slot= retroforge.slot=; do
  grep -q -- "$a" <<<"$CMD" && bad "cmdline carries $a, which is per slot" || ok "cmdline carries no $a"
done
mkdir -p "$T/badroot/boot" "$T/badroot/kernel"
cp "$GEN" "$T/badroot/boot/gen-bls.sh"; ln -s "$DTS/.." "$T/badroot/kernel/dts"
{ cat "$BOARDS"; printf 'bogus-board\tBogus\tqcs-nonexistent\t\n'; } >"$T/badroot/boot/boards.map"
if bash "$T/badroot/boot/gen-bls.sh" "$T/badout" >/dev/null 2>"$T/baderr"; then
  bad "a catalog row naming a missing DTB was accepted"
else
  grep -q 'bogus-board names DTB qcs-nonexistent' "$T/baderr" && ok "a catalog row naming a missing DTB fails the build" \
    || bad "failed for another reason: $(head -2 "$T/baderr")"
fi

# --- 5. lib-bls.sh: what goes in an entry -------------------------------------------------------
# shellcheck source=/dev/null
. "$BLSLIB"

CASE="bls_cmdline"
c="$(bls_cmdline 'quiet' 'irqaffinity=0-2' B r-uuid v-uuid)"
[ "$c" = "quiet irqaffinity=0-2 root=PARTUUID=r-uuid rootfstype=btrfs rootwait ro retroforge.var=PARTUUID=v-uuid retroforge.slot=B rauc.slot=B" ] \
  && ok "common, board, then the slot's partitions and name" || bad "$c"
c="$(bls_cmdline 'quiet' '' a r v)"
[ "$c" = "quiet root=PARTUUID=r rootfstype=btrfs rootwait ro retroforge.var=PARTUUID=v retroforge.slot=A rauc.slot=A" ] \
  && ok "no board args leave no double space, and the slot is upper-cased" || bad "'$c'"
( bls_cmdline 'quiet' '' A r '' ) >/dev/null 2>&1 && bad "accepted a missing PARTUUID" || ok "a missing PARTUUID is fatal"
( bls_cmdline 'quiet' '' C r v ) >/dev/null 2>&1 && bad "accepted slot C" || ok "slot C is refused"
grep -q -- 'retroforge.efi=' <<<"$c" && bad "the command line still names an efi partition" || ok "no retroforge.efi="
# The initramfs reads these keys; the names must be the ones it parses.
for k in retroforge.var= retroforge.slot=; do
  grep -q -- "$k" "$ROOT/image/initramfs/init" && ok "the initramfs reads $k" || bad "image/initramfs/init never reads $k"
done

CASE="bls_debug_cmdline"
c="$(bls_debug_cmdline 'quiet loglevel=3 console=tty0 drm_kms_helper.fbdev_emulation=0 retroforge.splash=1 systemd.show_status=0 root=PARTUUID=r ro')"
[ "$c" = "console=tty0 root=PARTUUID=r ro loglevel=7 retroforge.splash=0 systemd.show_status=1" ] \
  && ok "drops quiet, the log level, the splash and the fbdev switch; boots verbosely" || bad "'$c'"

CASE="bls_title"
[ "$(bls_title a)" = "RetroForge (Slot A)" ] && ok "RetroForge (Slot A)" || bad "$(bls_title a)"
[ "$(bls_title B debug)" = "RetroForge (Slot B, debug)" ] && ok "RetroForge (Slot B, debug)" || bad "$(bls_title B debug)"

CASE="bls_release"
printf 'version=1.2.3\nkernel=6.18.4\n' >"$T/release"
[ "$(bls_release "$T/release" version)" = 1.2.3 ] && [ "$(bls_release "$T/release" kernel)" = 6.18.4 ] \
  && ok "reads version= and kernel=" || bad "$(cat "$T/release")"
( bls_release "$T/nowhere" kernel ) >/dev/null 2>&1 && bad "read a missing release" || ok "no release file is fatal"
printf 'version=1 2\n' >"$T/release-bad"
( bls_release "$T/release-bad" version ) >/dev/null 2>&1 && bad "accepted a version with a space" || ok "a version that is not plain is fatal"

CASE="bls_entry_text"
e="$(bls_entry_text 'RetroForge (Slot B)' 1.2.3 6.18.4 'quiet root=PARTUUID=r' retroforge)"
want=$'title RetroForge (Slot B)\nversion 1.2.3\nsort-key retroforge\nlinux /vmlinuz-6.18.4\ninitrd /initramfs-6.18.4.img\noptions quiet root=PARTUUID=r'
[ "$e" = "$want" ] && ok "title, version, sort-key, linux, initrd, options -- in that order, and no devicetree" || bad "$e"
e="$(bls_entry_text 'RetroForge (Slot B, debug)' 1.2.3 6.18.4 'o')"
grep -q '^sort-key' <<<"$e" && bad "an entry without a sort-key got one" || ok "no sort-key unless one is given"

CASE="bls_device_entry"
mkdir -p "$T/dev-boot"
printf '# id\tname\tdtb\tmodel\tbootargs\none\tOne\tdtb-one\tModel One\targ=1\n' >"$T/dev-boot/boards.tsv"
printf 'quiet common\n' >"$T/dev-boot/cmdline"
printf 'version=9.9\nkernel=6.18.4\n' >"$T/dev-boot/release"
printf 'Model One\0' >"$T/model"
e="$(DT_MODEL="$T/model" bls_device_entry "$T/dev-boot" A r v)"
grep -qx 'title RetroForge (Slot A)' <<<"$e" && grep -qx 'version 9.9' <<<"$e" \
  && grep -qx 'sort-key retroforge' <<<"$e" && grep -qx 'linux /vmlinuz-6.18.4' <<<"$e" \
  && ! grep -q '^devicetree' <<<"$e" && grep -q '^options quiet common arg=1 root=PARTUUID=r ' <<<"$e" \
  && ok "the running model's row, from the given root's table and release" || bad "$e"
e="$(DT_MODEL="$T/model" bls_device_entry "$T/dev-boot" A r v debug)"
grep -qx 'title RetroForge (Slot A, debug)' <<<"$e" && ! grep -q '^sort-key' <<<"$e" \
  && grep -q '^options common arg=1 .* loglevel=7 retroforge.splash=0 systemd.show_status=1$' <<<"$e" \
  && ok "the debug entry: its own title, no sort-key, the verbose command line" || bad "$e"
printf 'Model Two\0' >"$T/model"
( DT_MODEL="$T/model" bls_device_entry "$T/dev-boot" A r v ) >/dev/null 2>&1 \
  && bad "wrote an entry for a board the table does not know" || ok "an unknown board is fatal"
( DT_MODEL="$T/model" bls_device_entry "$T/nowhere" A r v ) >/dev/null 2>&1 \
  && bad "wrote an entry with no board table" || ok "a root with no board table is fatal"
printf 'Model One\0' >"$T/model"; rm "$T/dev-boot/release"
( DT_MODEL="$T/model" bls_device_entry "$T/dev-boot" A r v ) >/dev/null 2>&1 \
  && bad "wrote an entry with no release" || ok "a root with no release is fatal"

# --- 6. lib-bls.sh: the state, read and written -------------------------------------------------
CASE="bls_tries_left"
for pair in 'retroforge-a+3.conf:3' 'retroforge-a+2-1.conf:2' 'retroforge-a+0-3.conf:0' \
            'retroforge-a.conf:' 'retroforge-a+x.conf:' 'retroforge-a+010.conf:10'; do
  n="${pair%%:*}"; want="${pair#*:}"
  got="$(bls_tries_left "/x/$n")"
  [ "$got" = "$want" ] && ok "$n -> '${want}'" || bad "$n -> '$got', expected '$want'"
done

# The ESP and each slot's own boot partition, as directories.
E="$T/esp"; FA="$T/boot-a"; FB="$T/boot-b"
fresh() { rm -rf "$E" "$FA" "$FB"; mkdir -p "$E/loader" "$FA/loader/entries" "$FB/loader/entries"; }

CASE="bls_state / bls_primary"
fresh
[ "$(bls_state "$FA" A)" = bad ] && ok "no entry is bad" || bad "no entry: $(bls_state "$FA" A)"
: >"$FA/loader/entries/retroforge-a+1-2.conf"; : >"$FB/loader/entries/retroforge-b+0-3.conf"
[ "$(bls_state "$FA" A)" = good ] && [ "$(bls_state "$FB" B)" = bad ] && ok "+1 good, +0 bad" || bad "A=$(bls_state "$FA" A) B=$(bls_state "$FB" B)"
[ "$(bls_state "$FB" A)" = bad ] && ok "a slot's state is read off its own partition only" || bad "A read off boot-b: $(bls_state "$FB" A)"
printf 'default retroforge-b.conf\n' >"$E/loader/loader.conf"
[ "$(bls_default "$E")" = B ] && ok "the default is read off the ESP" || bad "default=$(bls_default "$E")"
[ "$(bls_primary "$E" "$FA" "$FB")" = A ] && ok "a bad default falls through to the good slot, as OpenABL does" || bad "primary=$(bls_primary "$E" "$FA" "$FB")"
rm "$FA/loader/entries/retroforge-a+1-2.conf"
bls_primary "$E" "$FA" "$FB" >/dev/null && bad "named a primary with no good slot" || ok "no good slot: status 1"
: >"$FA/loader/entries/retroforge-setup-x.conf"
bls_has_setup "$FA" && ok "setup entries are seen" || bad "bls_has_setup missed one"

CASE="bls_set_tries"
fresh
printf 'BODY\n' >"$FA/loader/entries/retroforge-a+0-3.conf"
bls_set_tries "$FA" A 3
[ "$(ls "$FA/loader/entries")" = "retroforge-a+3.conf" ] && [ "$(cat "$FA/loader/entries/retroforge-a+3.conf")" = BODY ] \
  && ok "a rename to +3, content kept" || bad "$(ls "$FA/loader/entries")"
bls_set_tries "$FB" B 3 && bad "renamed an entry that does not exist" || ok "no entry: status 1"

CASE="bls_write_entry / bls_write_debug / bls_set_default / bls_remove"
fresh
: >"$FB/loader/entries/retroforge-b+1-2.conf"; : >"$FB/loader/entries/retroforge-b.conf"
bls_write_entry "$FB" B $'title new\n'
[ "$(ls "$FB/loader/entries")" = "retroforge-b+3.conf" ] && ok "replaces every entry the slot had, armed with three tries" \
  || bad "$(ls "$FB/loader/entries" | tr '\n' ' ')"
bls_write_debug "$FB" B $'title debug\n'
[ "$(cat "$FB/loader/entries/retroforge-debug-b.conf")" = "title debug" ] && ok "the debug entry, uncounted" \
  || bad "$(ls "$FB/loader/entries" | tr '\n' ' ')"
bls_write_entry "$FA" A $'title a\n' 0
[ -f "$FA/loader/entries/retroforge-a+0.conf" ] && ok "an explicit counter is honoured" || bad "$(ls "$FA/loader/entries" | tr '\n' ' ')"
bls_set_default "$E" B
[ "$(grep -v '^#' "$E/loader/loader.conf")" = "default retroforge-b.conf" ] && ok "default retroforge-b.conf, nothing else" \
  || bad "$(cat "$E/loader/loader.conf")"
bls_set_default "$E" A 5
grep -qx 'timeout 5' "$E/loader/loader.conf" && grep -qx 'default retroforge-a.conf' "$E/loader/loader.conf" \
  && ok "a timeout is written when asked" || bad "$(cat "$E/loader/loader.conf")"
[ -z "$(find "$E" "$FA" "$FB" -name '*.new')" ] && ok "no temporary file left behind" || bad "$(find "$E" "$FA" "$FB" -name '*.new')"
: >"$FB/loader/entries/retroforge-setup-x.conf"
bls_remove "$FB" B
[ -z "$(ls "$FB/loader/entries")" ] && ok "bls_remove takes the entry, the debug entry and any setup entries" \
  || bad "$(ls "$FB/loader/entries" | tr '\n' ' ')"
[ -e "$FA/loader/entries/retroforge-a+0.conf" ] && ok "and nothing of the other slot" || bad "$(ls "$FA/loader/entries" | tr '\n' ' ')"

CASE="bls_install_slot_files"
R="$T/root"; rm -rf "$R"; mkdir -p "$R/boot" "$R/usr/lib/retroforge/boot/dtbs"
printf 'version=2.0\nkernel=6.19.1\n' >"$R/usr/lib/retroforge/boot/release"
printf 'K' >"$R/boot/vmlinuz"; printf 'I' >"$R/boot/initramfs-retroforge.img"
printf 'D1' >"$R/usr/lib/retroforge/boot/dtbs/one.dtb"; printf 'D2' >"$R/usr/lib/retroforge/boot/dtbs/two.dtb"
fresh
mkdir -p "$FB/dtbs"; : >"$FB/vmlinuz-6.18.4"; : >"$FB/initramfs-6.18.4.img"; : >"$FB/dtbs/gone.dtb"
bls_slot_files_present "$FA" && bad "an empty partition has slot files" || ok "an empty partition has no slot files"
( bls_install_slot_files "$FB" "$R" ) && ok "installs" || bad "failed"
[ "$(cat "$FB/vmlinuz-6.19.1")" = K ] && [ "$(cat "$FB/initramfs-6.19.1.img")" = I ] \
  && ok "the kernel and initramfs, named by the root's kernel version" || bad "$(ls "$FB" | tr '\n' ' ')"
[ "$(cat "$FB/dtbs/one.dtb")$(cat "$FB/dtbs/two.dtb")" = D1D2 ] && ok "the root's DTBs" || bad "$(ls "$FB/dtbs" | tr '\n' ' ')"
[ ! -e "$FB/vmlinuz-6.18.4" ] && [ ! -e "$FB/initramfs-6.18.4.img" ] && [ ! -e "$FB/dtbs/gone.dtb" ] \
  && ok "the older build's files are gone" || bad "$(find "$FB" -type f | tr '\n' ' ')"
[ -z "$(find "$FB" -name '*.new')" ] && ok "no temporary file left behind" || bad "$(find "$FB" -name '*.new')"
bls_slot_files_present "$FB" && ok "the slot's files are seen" || bad "bls_slot_files_present missed them"
rm "$R/boot/vmlinuz"
( bls_install_slot_files "$FA" "$R" ) >/dev/null 2>&1 && bad "installed from a root with no kernel" || ok "a root with no kernel is fatal"

# --- 7. the shipped config hands the state to this backend ---------------------------------------
CASE="rauc + systemd"
SYSCONF="$ROOT/rootfs/overlay/etc/rauc/system.conf"
grep -qx 'bootloader=custom' "$SYSCONF" && ok "rauc's bootloader is custom" || bad "system.conf does not say bootloader=custom"
grep -qx 'bootloader-custom-backend=/usr/bin/retroforge-bootctl' "$SYSCONF" \
  && ok "and the backend is retroforge-bootctl" || bad "system.conf names no retroforge-bootctl backend"
grep -q 'grub' "$SYSCONF" && bad "system.conf still mentions grub" || ok "and nothing of grub"
bless="$ROOT/rootfs/overlay/etc/systemd/system/systemd-bless-boot.service"
[ "$(readlink "$bless" 2>/dev/null)" = /dev/null ] \
  && ok "systemd-bless-boot is masked, so it never strips a counter" || bad "systemd-bless-boot is not masked"

echo
echo "test-bls.sh: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
