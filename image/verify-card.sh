#!/usr/bin/env bash
# Offline verification of a built A/B card image — out/images/sdcard.img.gz (or a raw .img).
#
# Same doctrine as rootfs/guard-rootfs.sh: assert the BUILT ARTIFACT, not the source diff. That
# guard stops at the staged tree (it runs before mkfs), so nothing checked the partition table,
# the ESP contents, or the filesystem identities the A/B switch depends on. This closes that gap
# for the parts a slot switch can be silently wrong about.
#
# The card boots ABL → the ESP GRUB (on the ESP; it picks the slot) → the slot's stage-2 grub.cfg
# (on its efi-a/b partition; it picks the board) → kernel. So beyond the filesystem identities this
# asserts the two boot homes: the ESP carries the ESP GRUB + the grubenv with RAUC's seeded slot
# state + parts.env + OpenABL's Device model DTBs, and each efi partition carries its stage-2 config.
#
# It matters most for one thing that is invisible until hardware contradicts you: the two roots
# are content-identical by design, so if they also share a btrfs fsid then mounting slot B can
# hand you slot A, and every slot test after that is meaningless. That check is why this exists.
#
# Everything here is unprivileged — dd out a superblock and ask blkid, read ext4 with debugfs,
# read the ESP/efi partitions with mtools. No loop mounts, no root.
#
# Run inside the build image (needs sgdisk, blkid, debugfs, mtools, cpio, zstd):
#   docker run --rm -v "$PWD":/src -w /src retroforge-build image/verify-card.sh
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
IMG="${1:-$ROOT/out/images/sdcard.img.gz}"
TABLE="$ROOT/image/partition-table.txt"
INITRAMFS="$ROOT/out/initramfs.cpio.zst"

[ -f "$IMG" ] || { echo "no card image: $IMG (run make sdcard)" >&2; exit 1; }
for t in sgdisk blkid debugfs mdir mtype mlabel cpio cmp zstd; do
  command -v "$t" >/dev/null 2>&1 || { echo "$t not found — run inside retroforge-build" >&2; exit 1; }
done

T="$(mktemp -d)"; RAW=""; trap 'rm -rf "$T"; [ -z "$RAW" ] || rm -f "$RAW"' EXIT

# The build ships the card gzip'd (image/make-sdcard.sh), and every check below reads partitions
# by byte offset, so unpack it first. Beside the .gz rather than in $T: the container's /tmp is not
# sized for a ~19 GiB card. --sparse=always keeps the zeros (most of the card) off the disk.
if [ "${IMG%.gz}" != "$IMG" ]; then
  RAW="$(dirname "$IMG")/.verify-$(basename "${IMG%.gz}")"
  echo "[retroforge] unpacking ${IMG#"$ROOT"/}"
  if command -v pigz >/dev/null; then pigz -dc "$IMG"; else gzip -dc "$IMG"; fi \
    | cp --sparse=always /dev/stdin "$RAW" || { echo "could not unpack $IMG" >&2; exit 1; }
  SRC="${IMG#"$ROOT"/}"; IMG="$RAW"
fi
export MTOOLS_SKIP_CHECK=1
FAIL=0
ok()  { printf '    ok  %s\n' "$1"; }
bad() { printf '    !!  %s\n' "$1"; FAIL=1; }

part_num() { awk -v n="$1" '/^[[:space:]]*#/||/^[[:space:]]*$/{next} {i++; if ($1==n) {print i; exit}}' "$TABLE"; }
start()    { sgdisk -i "$1" "$IMG" | sed -n 's/^First sector: \([0-9]*\).*/\1/p'; }
part_uuid() { sgdisk -i "$1" "$IMG" | sed -n 's/^Partition unique GUID: \(.*\)/\1/p' | tr '[:upper:]' '[:lower:]'; }

P_ESP=$(part_num esp)
P_EFIA=$(part_num efi-a); P_EFIB=$(part_num efi-b)
P_ROOTA=$(part_num rootfs-a); P_ROOTB=$(part_num rootfs-b)
P_VARA=$(part_num var-a);     P_VARB=$(part_num var-b)
P_HOME=$(part_num home)

ESP_UUID=$(part_uuid "$P_ESP")
EFIA_UUID=$(part_uuid "$P_EFIA")
EFIB_UUID=$(part_uuid "$P_EFIB")

echo "[retroforge] verifying ${SRC:-$IMG}"

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

# Per-slot filesystem LABELS. Not how stage 2 normally finds the root -- it goes by partition
# index -- but they are its documented fallback, they are what `blkid` on a mounted card reports,
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
# 3. The ESP. The ESP GRUB at /EFI/BOOT/bootaa64.efi is the only thing ABL can find. The slot state
# is RAUC's, in the seeded grubenv.
# ----------------------------------------------------------------------------------------------
echo "  3. ESP (stage 1)"
espoff=$(( $(start "$P_ESP") * 512 ))
need_file() {  # <msdos path> <what>
  mtype -i "$IMG@@$espoff" "$1" >"$T/f" 2>/dev/null && ok "$2 present" || bad "$2 missing"
}
# The FAT label. Nothing in the boot chain RESOLVES by it (stage 2 goes by partition index, with a
# content search for /EFI/steamos/grubenv as the fallback), which is exactly why it is worth
# asserting: when it did matter, it drifted from what grub.cfg searched for and nothing failed.
# mlabel, not blkid: a FAT32 volume label lives in a root-directory entry out in the data area,
# so probing a short dd of the superblock reports nothing at all.
# mlabel prints " Volume label is RETROFORGE   " -- leading space, and the label space-padded to the
# full 11 bytes FAT stores. Both have to be stripped or this compares against padding.
esp_fslabel=$(mlabel -i "$IMG@@$espoff" -s :: 2>/dev/null \
  | sed -n 's/^[[:space:]]*Volume label is //p' | sed 's/[[:space:]]*$//')
[ -n "$esp_fslabel" ] && [ "${#esp_fslabel}" -le 11 ] \
  && ok "ESP FAT label '$esp_fslabel' (<= 11 chars)" \
  || bad "ESP FAT label is empty or over the 11-char FAT limit: '$esp_fslabel'"
need_file ::/EFI/BOOT/bootaa64.efi         "the ESP GRUB at /EFI/BOOT/bootaa64.efi"
need_file ::/EFI/steamos/grubenv          "/EFI/steamos/grubenv"
need_file ::/EFI/steamos/parts.env        "/EFI/steamos/parts.env"
# bootaa64.efi must be THIS build's ESP GRUB, not the stage-2 binary: only the ESP GRUB carries the
# slot picker, and the plain one would read a grub.cfg the ESP does not have.
mtype -i "$IMG@@$espoff" ::/EFI/BOOT/bootaa64.efi >"$T/bootaa64.efi" 2>/dev/null || true
BOOTDIR="$ROOT/out/boot"
if [ -f "$BOOTDIR/grub-esp.efi" ]; then
  cmp -s "$T/bootaa64.efi" "$BOOTDIR/grub-esp.efi" \
    && ok "bootaa64.efi is out/boot/grub-esp.efi" \
    || bad "bootaa64.efi is not this build's ESP GRUB (out/boot/grub-esp.efi)"
fi

mdir -i "$IMG@@$espoff" ::/KERNEL >/dev/null 2>&1 && bad "/KERNEL present on the card" \
                                                   || ok "no /KERNEL"
mdir -i "$IMG@@$espoff" ::/SteamOS >/dev/null 2>&1 && bad "/SteamOS present: the boot confs belong to the steamcl chain" \
                                                   || ok "no /SteamOS (no boot confs)"
mdir -i "$IMG@@$espoff" ::/EFI/BOOT/steamcl-version >/dev/null 2>&1 && bad "steamcl's companion files are on the ESP" \
                                                                    || ok "no steamcl files"

# The grubenv is a real GRUB env block carrying RAUC's slot state, seeded so the first boot picks
# A and an empty B is never tried.
mtype -i "$IMG@@$espoff" ::/EFI/steamos/grubenv >"$T/grubenv" 2>/dev/null || true
grep -aq "GRUB Environment Block" "$T/grubenv" && ok "grubenv is a valid GRUB env block" \
                                              || bad "grubenv has no GRUB magic header"
[ "$(wc -c <"$T/grubenv")" = 1024 ] && ok "grubenv is 1024 bytes" || bad "grubenv is $(wc -c <"$T/grubenv") bytes, not 1024"
want_b_ok=0; [ "${SLOT_B:-1}" = 1 ] && want_b_ok=1
for kv in "ORDER=A B" "A_OK=1" "A_TRY=0" "B_OK=$want_b_ok" "B_TRY=0"; do
  grep -aqx -- "$kv" "$T/grubenv" && ok "grubenv $kv" || bad "grubenv does not carry $kv"
done
grep -aq '^saved_entry=' "$T/grubenv" && bad "grubenv carries a saved_entry -- this card would pin one board" \
                                       || ok "grubenv has no saved board"

# OpenABL's Device model list: one DTB per shipped board, each with the splash region that keeps
# OpenABL 1.2 from powering the panel down (boot/esp-dtbs.sh).
n_esp_dtbs=$(mdir -b -i "$IMG@@$espoff" ::/dtbs/qcom 2>/dev/null | grep -c '\.dtb$' || true)
n_dtbs=$(find "$ROOT/out/dtbs" -maxdepth 1 -name '*.dtb' 2>/dev/null | wc -l | tr -d ' ')
[ "$n_esp_dtbs" -gt 0 ] && [ "$n_esp_dtbs" = "$n_dtbs" ] \
  && ok "/dtbs/qcom carries all $n_dtbs DTBs" \
  || bad "/dtbs/qcom carries $n_esp_dtbs DTBs, out/dtbs has $n_dtbs"

# ----------------------------------------------------------------------------------------------
# 4. efi-a / efi-b (stage 2 homes). The ESP GRUB hands over to \EFI\steamos\grub.cfg on the slot's
# efi partition, which reads parts.env beside it before it can address anything.
# ----------------------------------------------------------------------------------------------
echo "  4. efi-a / efi-b (stage 2)"
check_efi() {  # <partnum> <letter>
  local p=$1 letter=$2 off
  off=$(( $(start "$p") * 512 ))
  for f in ::/EFI/steamos/grubaa64.efi ::/EFI/steamos/grub.cfg \
           ::/EFI/steamos/fonts/dejavu-mono.pf2 ::/EFI/steamos/parts.env; do
    mtype -i "$IMG@@$off" "$f" >"$T/f" 2>/dev/null && ok "p$p$f present" || bad "p$p$f missing"
  done

  # parts.env: where our eight partitions are on THIS medium, read by the stage-2 grub.cfg before it
  # can address anything. On a card the values equal the generator's build-time defaults, so a wrong
  # one is invisible at boot — which is exactly why it is asserted here against the same table both
  # sides derive from. A card whose map disagrees with its own GPT is a card that would boot fine and
  # then teach the installer's reader the wrong lesson.
  mtype -i "$IMG@@$off" ::/EFI/steamos/parts.env >"$T/parts-$letter.env" 2>/dev/null || true
  grep -aq "GRUB Environment Block" "$T/parts-$letter.env" \
    && ok "p$p parts.env is a valid GRUB env block" \
    || bad "p$p parts.env has no GRUB magic header"
  for kv in "nd_esp=$P_ESP" "nd_efi_a=$P_EFIA" "nd_efi_b=$P_EFIB" \
            "nd_root_a=$P_ROOTA" "nd_root_b=$P_ROOTB" \
            "nd_var_a=$P_VARA" "nd_var_b=$P_VARB" "nd_home=$P_HOME"; do
    grep -aqx -- "$kv" "$T/parts-$letter.env" && ok "p$p parts.env $kv" \
      || bad "p$p parts.env does not carry $kv (the card's map disagrees with ${TABLE#"$ROOT"/})"
  done
  # The shipped grub.cfg must be EXACTLY what boot/gen-grub-cfg.sh produces for THIS slot. One
  # comparison covers the whole class: a stale out/boot from an older build, slot A's config
  # written onto slot B's partition, or a generator change that never reached the card. What the
  # config has to CONTAIN is asserted by tests/test-stage2-grub.sh; this asserts it arrived.
  if [ -x "$ROOT/boot/gen-grub-cfg.sh" ]; then
    if "$ROOT/boot/gen-grub-cfg.sh" "$letter" "$T/expect-$letter.cfg" >/dev/null 2>&1; then
      mtype -i "$IMG@@$off" ::/EFI/steamos/grub.cfg >"$T/oncard-$letter.cfg" 2>/dev/null || true
      cmp -s "$T/expect-$letter.cfg" "$T/oncard-$letter.cfg" \
        && ok "p$p grub.cfg is the current slot-$letter config" \
        || bad "p$p grub.cfg differs from boot/gen-grub-cfg.sh $letter (stale build, or the wrong slot's config)"
    else
      bad "boot/gen-grub-cfg.sh $letter failed"
    fi
  else
    ok "p$p grub.cfg content check skipped (no boot/gen-grub-cfg.sh)"
  fi

}
check_efi "$P_EFIA" A
check_efi "$P_EFIB" B

# ----------------------------------------------------------------------------------------------
# 5. The initramfs actually carries what the boot path needs. The phase-5 init mounts root (ro) +
# var + the slot's efi partition at /efi (inside the btrfs root, so the mount survives
# switch_root), stacks the /etc overlay and hands off to systemd. The ESP is NOT mounted here —
# the booted system mounts it at /esp from /etc/fstab.
# ----------------------------------------------------------------------------------------------
echo "  5. initramfs"
if [ -f "$INITRAMFS" ]; then
  ( cd "$T" && zstd -dcq "$INITRAMFS" | cpio -idm --quiet 2>/dev/null )
  for b in mount partx findfs switch_root; do
    [ -x "$T/usr/bin/$b" ] && ok "$b staged" || bad "$b is NOT in the initramfs"
  done
  grep -q 'steamos.efi=' "$T/init" && ok "init mounts /efi from steamos.efi=PARTUUID=" \
                                    || bad "init has no /efi handoff (steamos.efi=)"
  grep -q 'switch_root "\$SYSROOT"' "$T/init" && ok "init hands off via switch_root" \
                                                || bad "init has no switch_root"
else
  bad "no ${INITRAMFS#"$ROOT"/}"
fi

echo
[ "$FAIL" = 0 ] && echo "  card OK" || echo "  card FAILED verification"
exit "$FAIL"
