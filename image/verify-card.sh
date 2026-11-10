#!/usr/bin/env bash
# Offline verification of a built A/B card image — out/images/sdcard.img.
#
# Same doctrine as rootfs/guard-rootfs.sh: assert the BUILT ARTIFACT, not the source diff. That
# guard stops at the staged tree (it runs before mkfs), so nothing checked the partition table,
# the ESP contents, or the filesystem identities the A/B switch depends on. This closes that gap
# for the parts a slot switch can be silently wrong about.
#
# The card boots OpenABL → a Boot Loader Specification entry on a slot's boot partition → the kernel
# beside it. So beyond the filesystem identities this asserts the boot partitions: one OS entry and
# one debug entry per populated slot (counted, naming that slot's PARTUUIDs), a loader.conf that
# defaults to slot A, each populated slot's kernel/initramfs/DTBs, and nothing else on the ESP.
#
# It matters most for one thing that is invisible until hardware contradicts you: the two roots
# are content-identical by design, so if they also share a btrfs fsid then mounting slot B can
# hand you slot A, and every slot test after that is meaningless. That check is why this exists.
#
# Everything here is unprivileged — dd out a superblock and ask blkid, read ext4 with debugfs,
# read the ESP/boot partitions with mtools. No loop mounts, no root.
#
# Run inside the build image (needs sgdisk, blkid, debugfs, mtools, cpio, zstd):
#   docker run --rm -v "$PWD":/src -w /src retroforge-build image/verify-card.sh
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
IMG="${1:-$ROOT/out/images/sdcard.img}"
TABLE="$ROOT/image/partition-table.txt"
INITRAMFS="$ROOT/out/initramfs.cpio.zst"

[ -f "$IMG" ] || { echo "no card image: $IMG (run make sdcard)" >&2; exit 1; }
for t in sgdisk blkid debugfs mdir mtype mlabel cpio cmp zstd; do
  command -v "$t" >/dev/null 2>&1 || { echo "$t not found — run inside retroforge-build" >&2; exit 1; }
done

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
export MTOOLS_SKIP_CHECK=1
FAIL=0
ok()  { printf '    ok  %s\n' "$1"; }
bad() { printf '    !!  %s\n' "$1"; FAIL=1; }

part_num() { awk -v n="$1" '/^[[:space:]]*#/||/^[[:space:]]*$/{next} {i++; if ($1==n) {print i; exit}}' "$TABLE"; }
start()    { sgdisk -i "$1" "$IMG" | sed -n 's/^First sector: \([0-9]*\).*/\1/p'; }
part_uuid() { sgdisk -i "$1" "$IMG" | sed -n 's/^Partition unique GUID: \(.*\)/\1/p' | tr '[:upper:]' '[:lower:]'; }

P_ESP=$(part_num esp)
P_BOOTA=$(part_num boot-a); P_BOOTB=$(part_num boot-b)
P_ROOTA=$(part_num rootfs-a); P_ROOTB=$(part_num rootfs-b)
P_VARA=$(part_num var-a);     P_VARB=$(part_num var-b)

echo "[retroforge] verifying ${IMG#"$ROOT"/}"

# ----------------------------------------------------------------------------------------------
# 1. Filesystem identity. Two btrfs filesystems on one disk sharing an fsid AND devid=1 are the
# pair btrfs keys its in-kernel device list on: the second scanned is treated as the first having
# MOVED, and silently replaces its path.
# ----------------------------------------------------------------------------------------------
echo "  1. filesystem identity"
declare -A U TY
for p in "$P_ROOTA" "$P_ROOTB" "$P_VARA" "$P_VARB"; do
  s=$(start "$p")
  [ -n "$s" ] || { bad "cannot read start sector of partition $p"; continue; }
  dd if="$IMG" of="$T/p$p.sb" bs=512 skip="$s" count=8192 status=none
  U[$p]=$(blkid -p -o value -s UUID "$T/p$p.sb" 2>/dev/null)
  TY[$p]=$(blkid -p -o value -s TYPE "$T/p$p.sb" 2>/dev/null)
done

if [ -z "${U[$P_ROOTB]:-}" ]; then
  ok "slot B is empty (release card, or RETROFORGE_SLOT_B=0) — skipping the A/B identity checks"
  SLOT_B=0
else
  SLOT_B=1
  [ "${TY[$P_ROOTA]}" = btrfs ] && [ "${TY[$P_ROOTB]}" = btrfs ] \
    && ok "both roots are btrfs" || bad "root types: ${TY[$P_ROOTA]} / ${TY[$P_ROOTB]}"
  [ -n "${U[$P_ROOTA]}" ] && [ "${U[$P_ROOTA]}" != "${U[$P_ROOTB]}" ] \
    && ok "rootfs-a / rootfs-b fsids differ (${U[$P_ROOTA]:0:8} vs ${U[$P_ROOTB]:0:8})" \
    || bad "rootfs-a and rootfs-b SHARE an fsid — a slot switch cannot be trusted"
  [ -n "${U[$P_VARA]}" ] && [ "${U[$P_VARA]}" != "${U[$P_VARB]}" ] \
    && ok "var-a / var-b UUIDs differ" \
    || bad "var-a and var-b share a UUID"
fi

# Per-slot filesystem LABELS. Not how the boot finds the root -- the entries go by PARTUUID -- but
# they are what `blkid` on a mounted card reports,
# and they are the thing a RAUC raw write silently gets wrong (the bundle image is slot A's, so an
# install leaves the target labelled retroforge-root-A until the post-install hook re-labels it).
for pair in "$P_ROOTA:retroforge-root-A" "$P_ROOTB:retroforge-root-B"; do
  pn=${pair%%:*}; want=${pair#*:}
  [ "$SLOT_B" = 0 ] && [ "$pn" = "$P_ROOTB" ] && continue
  got=$(blkid -p -o value -s LABEL "$T/p$pn.sb" 2>/dev/null)
  [ "$got" = "$want" ] && ok "p$pn btrfs label = $want" || bad "p$pn btrfs label: expected '$want', got '$got'"
done

# ----------------------------------------------------------------------------------------------
# 2. The independent slot witness. /var/lib/retroforge/slot records which var actually mounted;
# it is written per-slot at image build and re-written by post-install.sh. It is the only
# cross-check that does not share a failure mode with the selection code.
# ----------------------------------------------------------------------------------------------
echo "  2. slot witness"
check_slot() {  # <partnum> <expected letter>
  local s got
  s=$(start "$1")
  dd if="$IMG" of="$T/var$1.img" bs=512 skip="$s" count=524288 status=none
  got=$(debugfs -R "cat /lib/retroforge/slot" "$T/var$1.img" 2>/dev/null | tr -d '\n\r')
  [ "$got" = "$2" ] && ok "p$1 /var/lib/retroforge/slot = $2" \
                    || bad "p$1 slot witness: expected '$2', got '$got'"
}
check_slot "$P_VARA" A
[ "$SLOT_B" = 1 ] && check_slot "$P_VARB" B

# ----------------------------------------------------------------------------------------------
# 3. The ESP and the slots' boot partitions: the boot entries OpenABL reads, and the files they name.
# ----------------------------------------------------------------------------------------------
echo "  3. ESP (loader.conf)"
espoff=$(( $(start "$P_ESP") * 512 ))
need_file() {  # <msdos path> <what>
  mtype -i "$IMG@@$espoff" "$1" >"$T/f" 2>/dev/null && ok "$2 present" || bad "$2 missing"
}
# The FAT label. Nothing in the boot chain RESOLVES by it, which is exactly why it is worth
# asserting: when it did matter, it drifted and nothing failed.
# mlabel, not blkid: a FAT32 volume label lives in a root-directory entry out in the data area,
# so probing a short dd of the superblock reports nothing at all.
# mlabel prints " Volume label is RETROFORGE   " -- leading space, and the label space-padded to the
# full 11 bytes FAT stores. Both have to be stripped or this compares against padding.
esp_fslabel=$(mlabel -i "$IMG@@$espoff" -s :: 2>/dev/null \
  | sed -n 's/^[[:space:]]*Volume label is //p' | sed 's/[[:space:]]*$//')
[ -n "$esp_fslabel" ] && [ "${#esp_fslabel}" -le 11 ] \
  && ok "ESP FAT label '$esp_fslabel' (<= 11 chars)" \
  || bad "ESP FAT label is empty or over the 11-char FAT limit: '$esp_fslabel'"

# Nothing of the GRUB chain or the ones before it: OpenABL would boot \EFI\BOOT\BOOTAA64.EFI only when
# no entry ran, and an old loader there would be a boot path nothing maintains.
for f in ::/EFI/BOOT/bootaa64.efi ::/EFI/steamos ::/KERNEL ::/SteamOS; do
  mdir -i "$IMG@@$espoff" "$f" >/dev/null 2>&1 && bad "${f#::} present on the card" || ok "no ${f#::}"
done

# The fresh-card loader.conf: slot A first, and no menu held up.
mtype -i "$IMG@@$espoff" ::/loader/loader.conf >"$T/loader.conf" 2>/dev/null || true
grep -qx 'default retroforge-a.conf' "$T/loader.conf" && ok "loader.conf defaults to slot A" \
                                                     || bad "loader.conf does not say 'default retroforge-a.conf'"
grep -q '^timeout' "$T/loader.conf" && bad "loader.conf sets a timeout -- a fresh card would stop at the menu" \
                                     || ok "loader.conf sets no timeout"
mdir -i "$IMG@@$espoff" ::/loader/entries >/dev/null 2>&1 && bad "the ESP carries entries -- they belong on the slots' boot partitions" \
                                                          || ok "no entries on the ESP"

echo "  3b. boot-a / boot-b (each slot's entries and the files they name)"
efiaoff=$(( $(start "$P_BOOTA") * 512 )); efiboff=$(( $(start "$P_BOOTB") * 512 ))
BOOTDIR="$ROOT/out/boot"
KVER=$(sed -n 's/^kernel=//p' "$BOOTDIR/release" 2>/dev/null)
VERSION=$(sed -n 's/^version=//p' "$BOOTDIR/release" 2>/dev/null)
[ -n "$KVER" ] && [ -n "$VERSION" ] && ok "out/boot/release: version $VERSION, kernel $KVER" \
  || bad "out/boot/release does not name a version and a kernel"

# One OS entry and one debug entry per populated slot, each on that slot's own boot partition, each
# naming that slot's partitions and no DTB (OpenABL installs its Device model's from the same
# partition's /dtbs). Nothing else: one image serves every board, so no entry names one.
check_slot_entries() {  # <A|B> <offset> <root-uuid> <var-uuid>
  local S="$1" s off="$2" e d
  s=$(printf '%s' "$S" | tr 'AB' 'ab')
  e="retroforge-$s+3.conf"; d="retroforge-debug-$s.conf"
  mdir -b -i "$IMG@@$off" ::/loader/entries 2>/dev/null | sed 's|.*/||' | grep '\.conf$' | sort >"$T/entries-$s"
  printf '%s\n' "$d" "$e" | sort | cmp -s - "$T/entries-$s" \
    && ok "boot-$s: exactly $e and $d" \
    || bad "boot-$s entries are not exactly $e and $d: $(tr '\n' ' ' <"$T/entries-$s")"
  mtype -i "$IMG@@$off" "::/loader/entries/$e" >"$T/e-$s" 2>/dev/null || true
  mtype -i "$IMG@@$off" "::/loader/entries/$d" >"$T/d-$s" 2>/dev/null || true
  grep -qx "title RetroForge (Slot $S)" "$T/e-$s" && ok "$e: titled RetroForge (Slot $S)" \
                                                  || bad "$e: $(grep '^title' "$T/e-$s")"
  grep -qx "title RetroForge (Slot $S, debug)" "$T/d-$s" && ok "$d: titled RetroForge (Slot $S, debug)" \
                                                         || bad "$d: $(grep '^title' "$T/d-$s")"
  for f in "$T/e-$s" "$T/d-$s"; do
    for want in "root=PARTUUID=$3" "retroforge.var=PARTUUID=$4" "retroforge.slot=$S" "rauc.slot=$S"; do
      grep -q "^options .*$want" "$f" || bad "boot-$s ${f##*/}: no $want"
    done
    for want in "version $VERSION" "linux /vmlinuz-$KVER" "initrd /initramfs-$KVER.img"; do
      grep -qx "$want" "$f" || bad "boot-$s ${f##*/}: does not say '$want'"
    done
    grep -q '^devicetree' "$f" && bad "boot-$s ${f##*/} names a devicetree -- OpenABL's Device model should pick it"
  done
  ok "boot-$s entries name slot $S's partitions, this build's kernel and no devicetree"
}
mdir -i "$IMG@@$efiboff" ::/loader/entries >/dev/null 2>&1 && ok "boot-b has /loader/entries" \
                                                           || bad "boot-b has no /loader/entries"
check_slot_entries A "$efiaoff" "$(part_uuid "$P_ROOTA")" "$(part_uuid "$P_VARA")"
if [ "$SLOT_B" = 1 ]; then
  check_slot_entries B "$efiboff" "$(part_uuid "$P_ROOTB")" "$(part_uuid "$P_VARB")"
else
  mdir -b -i "$IMG@@$efiboff" ::/loader/entries 2>/dev/null | grep -q '\.conf$' \
    && bad "boot-b carries entries over an empty slot B" || ok "no entries on boot-b (slot B empty)"
fi

# Each populated slot's files, byte-identical to this build's.
check_slot_files() {  # <a|b> <offset>
  mtype -i "$IMG@@$2" "::/vmlinuz-$KVER" >"$T/k-$1" 2>/dev/null || true
  cmp -s "$T/k-$1" "$ROOT/out/vmlinuz" && ok "boot-$1 /vmlinuz-$KVER is out/vmlinuz" \
                                         || bad "boot-$1 /vmlinuz-$KVER is missing or not this build's kernel"
  mtype -i "$IMG@@$2" "::/initramfs-$KVER.img" >"$T/i-$1" 2>/dev/null || true
  cmp -s "$T/i-$1" "$INITRAMFS" && ok "boot-$1 /initramfs-$KVER.img is this build's initramfs" \
                                || bad "boot-$1 /initramfs-$KVER.img is missing or not this build's initramfs"
}
check_slot_files a "$efiaoff"
if [ "$SLOT_B" = 1 ]; then
  check_slot_files b "$efiboff"
else
  mdir -b -i "$IMG@@$efiboff" :: 2>/dev/null | grep -v '/loader' | grep -q . \
    && bad "boot-b carries files over an empty slot B" || ok "boot-b holds no files (slot B empty)"
fi

# The DTBs on boot-a are what OpenABL installs and lists as Device models: one per shipped board,
# each with the splash region that keeps OpenABL 1.2 from powering the panel down (boot/splash-dtbs.sh).
n_boot_dtbs=$(mdir -b -i "$IMG@@$efiaoff" ::/dtbs 2>/dev/null | grep -c '\.dtb$' || true)
n_dtbs=$(find "$ROOT/out/dtbs" -maxdepth 1 -name '*.dtb' 2>/dev/null | wc -l | tr -d ' ')
[ "$n_boot_dtbs" -gt 0 ] && [ "$n_boot_dtbs" = "$n_dtbs" ] \
  && ok "boot-a /dtbs carries all $n_dtbs DTBs" \
  || bad "boot-a /dtbs carries $n_boot_dtbs DTBs, out/dtbs has $n_dtbs"
mdir -i "$IMG@@$espoff" ::/dtbs >/dev/null 2>&1 && bad "the ESP carries /dtbs -- they belong on the slots' boot partitions" \
                                                || ok "no /dtbs on the ESP"

# ----------------------------------------------------------------------------------------------
# 4. The initramfs actually carries what the boot path needs. The phase-5 init mounts root (ro) +
# var (inside the btrfs root, so the mount survives switch_root), stacks the /etc overlay and
# hands off to systemd. No FAT partition is mounted here: the booted system mounts the ESP at /esp
# and the slots' boot partitions at /run/retroforge/bootfs/{a,b} from /etc/fstab.
# ----------------------------------------------------------------------------------------------
echo "  4. initramfs"
if [ -f "$INITRAMFS" ]; then
  ( cd "$T" && zstd -dcq "$INITRAMFS" | cpio -idm --quiet 2>/dev/null )
  for b in mount partx findfs switch_root; do
    [ -x "$T/usr/bin/$b" ] && ok "$b staged" || bad "$b is NOT in the initramfs"
  done
  grep -q 'retroforge.var=' "$T/init" && ok "init mounts /var from retroforge.var=PARTUUID=" \
                                      || bad "init has no /var handoff (retroforge.var=)"
  grep -q 'switch_root "\$SYSROOT"' "$T/init" && ok "init hands off via switch_root" \
                                                || bad "init has no switch_root"
else
  bad "no ${INITRAMFS#"$ROOT"/}"
fi

echo
[ "$FAIL" = 0 ] && echo "  card OK" || echo "  card FAILED verification"
exit "$FAIL"
