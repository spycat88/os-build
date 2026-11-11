#!/usr/bin/env bash
# retroforge SD-card image builder.
#
# Lays the FULL SteamOS-style 8-partition GPT from image/partition-table.txt and populates
# BOTH slots: ESP + rootfs-a/-b + var-a/-b + home, and each slot's efi-a/efi-b partition with
# that slot's STAGE-2 grub.cfg.
#
# The boot chain this card boots:
#
#   ABL -> /EFI/BOOT/bootaa64.efi (the ESP GRUB, shared ESP: picks the slot from the grubenv)
#       -> \EFI\steamos\grub.cfg on the SLOT's efi partition (stage 2: picks the board)
#       -> kernel in the slot's root /boot
#
# The ESP carries the ESP GRUB, the grubenv (RAUC's slot state + the saved board), parts.env and
# OpenABL's Device model DTBs; each efi partition carries its slot's stage-2 grub.cfg.
#
# WHY B IS POPULATED ON A DEV CARD AND EMPTY ON A RELEASE CARD. The default follows RETROFORGE_DEV;
# RETROFORGE_SLOT_B=0|1 overrides it in either direction.
#
# Dev (Phase 4b): the deliverable of the boot-path pass is that a slot switch and a rollback are
# provable by hand, and you cannot prove a switch to a slot that does not boot — an empty B can only
# ever exercise the failure path. It is also the state a device is never in again after its first
# real update, so testing against it tests a fiction.
#
# Release: B WOULD BE a byte-identical copy of a root that is ALREADY zstd-compressed inside btrfs,
# so it would survive the release compression whole. Nothing dedupes it: the flash instruction is
# `gzip -dc` (32 KiB window), and even zstd --long tops out at a 2 GiB window against a ~4 GiB gap
# between the two copies. That was ~4 of the ~9 GiB a release card compressed to until 2026-08-04
# (measured for the old R2 publisher) — ~44% of every download — bought to cover a failover window that closes
# the first time RAUC writes the slot, which it writes in FULL and reads nothing prior out of. A
# user never hand-tests a slot switch, and a fresh-card A failure is media failure, which will not
# politely spare B. With B left empty a card compresses to ~5 GiB instead.
#
# Flash time is unchanged either way: the dd writes the whole full-size image including its zeros.
#
# Unprivileged: builds each filesystem in a plain file (mtools / mkfs.ext4 -d / mksquashfs),
# lays the GPT with sgdisk via image/genpart.sh, and dd's each filesystem into its partition
# byte offset — no loop mounts, no root.
#
# Run inside the build image (needs sgdisk + mkfs.vfat + mtools + mkfs.ext4 + grub-editenv + fdtput):
#   docker run --rm -v "$PWD":/src -w /src retroforge-build image/make-sdcard.sh
#
# Prereqs: boot/grub.sh (-> out/boot/{grub-esp.efi, grubaa64.efi, grub-a.cfg, grub-b.cfg,
# fonts/dejavu-mono.pf2, grubenv}), kernel/build.sh (-> out/dtbs) and rootfs/build-image.sh
# (-> out/images/{rootfs,var}.img) have run.
set -euo pipefail
export MTOOLS_SKIP_CHECK=1   # mtools on a file image has no geometry; silence the warning

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# The /home layout, shared with installer/retroforge-install. Resolved relative to this script with no
# seam: both files live in image/, so there is exactly one path and no test-only variant of it.
# shellcheck source=lib-homestage.sh
. "$ROOT/image/lib-homestage.sh"
OUT="$ROOT/out"
BOOT="$OUT/boot"
IMGDIR="$OUT/images"
ROOTFS="$IMGDIR/rootfs.img"
VARIMG="$IMGDIR/var.img"
VARIMG_B="$IMGDIR/var-b.img"
ROOTFS_B="$IMGDIR/rootfs-b.img"   # built here from $ROOTFS with a fresh fsid; see section 1b
IMG="$IMGDIR/sdcard.img"
TABLE="$ROOT/image/partition-table.txt"

# Boot artifacts, all staged to out/boot by boot/grub.sh:
GRUB_ESP="$BOOT/grub-esp.efi"           # the ESP GRUB (\EFI\BOOT\bootaa64.efi)
GRUB_EFI="$BOOT/grubaa64.efi"
GRUB_CFG_A="$BOOT/grub-a.cfg"           # per-slot grub.cfg (stage 2, A)
GRUB_CFG_B="$BOOT/grub-b.cfg"
GRUB_FONT="$BOOT/fonts/dejavu-mono.pf2" # stage-2 boot font ($prefix/fonts/ in grub.cfg)
GRUBENV="$BOOT/grubenv"                 # pristine env block (RAUC's slot state + saved_entry)

# Populate the B slot too: on for a dev card, off for a release card. See the header for why.
# Read the mode rather than defaulting to 1, so that forgetting to forward RETROFORGE_DEV produces a
# release-shaped card (small, one bootable slot) rather than silently shipping the 4 GiB copy.
SLOT_B="${RETROFORGE_SLOT_B:-$([ "${RETROFORGE_DEV:-}" = 1 ] && echo 1 || echo 0)}"

MIB=$((1024 * 1024))
END_SLACK_MIB=2   # tail room for the backup GPT (well over its ~17 KiB)

# /home (ext4) carries a ready /home/player from image-build time (see below). The partition is
# flashed small; on first boot retroforge-grow-home extends the partition + its ext4 to fill the card.

for t in sgdisk mkfs.vfat mcopy mmd mkfs.ext4 grub-editenv fdtget fdtput; do
  command -v "$t" >/dev/null 2>&1 || { echo "$t not found — run inside retroforge-build" >&2; exit 1; }
done
[ "$SLOT_B" = 1 ] && { command -v btrfstune >/dev/null 2>&1 || {
  echo "btrfstune not found — run inside retroforge-build (or set RETROFORGE_SLOT_B=0)" >&2; exit 1; }; }
for f in "$GRUB_ESP" "$GRUB_EFI" "$GRUB_CFG_A" "$GRUB_CFG_B" "$GRUB_FONT" "$GRUBENV"; do
  [ -f "$f" ] || { echo "no boot artifact: ${f#"$ROOT"/} (run boot/grub.sh)" >&2; exit 1; }
done
compgen -G "$OUT/dtbs/*.dtb" >/dev/null || { echo "no DTBs in ${OUT#"$ROOT"/}/dtbs (run kernel/build.sh)" >&2; exit 1; }
[ -f "$ROOTFS" ] || { echo "no rootfs: ${ROOTFS#"$ROOT"/} (run rootfs/build-image.sh)" >&2; exit 1; }
[ -f "$VARIMG" ] || { echo "no var image: ${VARIMG#"$ROOT"/} (run rootfs/build-image.sh)" >&2; exit 1; }

# Partition number and size (MiB) for a row of the table, so the two files can never drift.
part_num()  { awk -v n="$1" '/^[[:space:]]*#/||/^[[:space:]]*$/{next} {i++; if ($1==n) {print i; exit}}' "$TABLE"; }
part_mib()  { awk -v n="$1" '/^[[:space:]]*#/||/^[[:space:]]*$/{next}
  $1==n { s=$2; u=substr(s,length(s),1); v=substr(s,1,length(s)-1)
          if (u=="G") print v*1024; else if (u=="M") print v; else print 0; exit }' "$TABLE"; }

P_ESP=$(part_num esp);    P_EFIA=$(part_num efi-a); P_EFIB=$(part_num efi-b)
P_ROOTA=$(part_num rootfs-a); P_VARA=$(part_num var-a)
P_ROOTB=$(part_num rootfs-b); P_VARB=$(part_num var-b)
P_HOME=$(part_num home)

ESP_SIZE_MIB=$(part_mib esp)
EFI_SIZE_MIB=$(part_mib efi-a)

# Every populated filesystem must fit the slot the table declares for it. A silently truncated
# dd would produce a card that boots into a corrupt filesystem, so fail loudly here instead.
fits() {  # <file> <slot-mib> <what>
  local bytes slot_bytes; bytes=$(stat -c %s "$1"); slot_bytes=$(( $2 * MIB ))
  [ "$bytes" -le "$slot_bytes" ] || {
    echo "$3 is $(( bytes / MIB ))MiB but its partition is only ${2}MiB — raise it in ${TABLE#"$ROOT"/}" >&2
    exit 1; }
}
fits "$ROOTFS" "$(part_mib rootfs-a)" "rootfs.img"
fits "$VARIMG" "$(part_mib var-a)"    "var.img"
if [ "$SLOT_B" = 1 ]; then
  [ -f "$VARIMG_B" ] || { echo "no var-b image: ${VARIMG_B#"$ROOT"/} (run rootfs/build-image.sh)" >&2; exit 1; }
  fits "$ROOTFS"   "$(part_mib rootfs-b)" "rootfs.img (slot B)"
  fits "$VARIMG_B" "$(part_mib var-b)"    "var-b.img"
fi

# Stage the /home tree: the player user's home, owned by player (uid/gid 1000, baked into the base)
# so the session can write it immediately — mkfs.ext4 -d preserves this.
#
# THE LAYOUT ITSELF LIVES IN image/lib-homestage.sh, because the internal installer builds the same
# tree on a device and the two must not drift.
homestage="$(mktemp -d)"
# Every name here is ${x:-} because the trap is armed BEFORE most of them exist: under `set -u` an
# early exit (a `fits` check failing, say) would otherwise die inside the trap on an unset variable
# and mask the real error. The previous fix for that was a block of empty pre-assignments carrying
# a comment pointing at a line number, which is a trap of its own.
trap 'rm -f "${esp:-}" "${efi_a:-}" "${efi_b:-}" "${home:-}" "${ROOTFS_B:-}" "${conf_a:-}" "${conf_b:-}" "${partsenv:-}" "${flag:-}"; rm -rf "${homestage:-}"' EXIT
stage_player_home "$homestage"

# Size /home to its content + headroom (ext4 metadata + a little slack so mkfs.ext4 -d has room),
# unless forced. retroforge-grow-home grows it to fill the card on first boot, so this is only the flash-time
# floor. du -sm rounds each file up to a whole MiB, so this already over-counts slightly.
home_mib=$(du -sm "$homestage" | cut -f1)
HOME_SIZE_MIB="${HOME_SIZE_MIB:-$(( home_mib + home_mib / 5 + 128 ))}"

fixed_mib=$("$ROOT/image/genpart.sh" --min)
total_mib=$(( fixed_mib + HOME_SIZE_MIB + END_SLACK_MIB ))

echo "[retroforge] SD image: ${fixed_mib}MiB fixed layout ($([ "$SLOT_B" = 1 ] && echo 'A+B populated' || echo 'A populated, B empty')) + home ${HOME_SIZE_MIB}MiB -> ${total_mib}MiB"

# 1b. Slot B's root: the SAME content, but it MUST NOT be the same bytes.
#
# mkfs.btrfs bakes an fsid into the superblock, and every btrfs image we build also has devid=1.
# Writing rootfs.img verbatim to both p4 and p5 would put two filesystems on one disk sharing
# exactly the pair btrfs keys its in-kernel device list on: the second one scanned is treated as
# the first one having MOVED, and its path silently replaces it. The failure mode is that mounting
# p5 hands you p4's filesystem — on the one test whose entire purpose is proving which slot booted.
# btrfstune -U rewrites the fsid in the superblocks and in every metadata block header, which is
# why it needs its own copy of the file rather than an in-place round trip.
#
# (RAUC hits this too: every `rauc install` writes identical bytes to the inactive slot. Its
# post-install hook does the same, `rootfs/overlay/usr/lib/rauc/post-install.sh`.)
if [ "$SLOT_B" = 1 ]; then
  rm -f "$ROOTFS_B"
  cp --reflink=auto "$ROOTFS" "$ROOTFS_B"
  btrfstune -f -U "$(cat /proc/sys/kernel/random/uuid)" "$ROOTFS_B" >/dev/null
  btrfs filesystem label "$ROOTFS_B" retroforge-root-B >/dev/null
  echo "  slotB rootfs-b.img: fresh btrfs fsid + label retroforge-root-B (content identical to A)"
fi
# Slot A needs no copy at all: rootfs/assemble-rootfs.sh already labels rootfs.img retroforge-root-A,
# and section 5 writes it straight into p4. This used to `cp --reflink=auto` the whole multi-GiB
# image to a rootfs-a.img purely to run `btrfs filesystem label` on it -- an extra full-size write
# per build, and one that happened even with RETROFORGE_SLOT_B=0.

# 3. /home filesystem (ext4, label retroforge-home) populated with the player home via mkfs.ext4 -d,
# which fills the fs from $homestage at creation — unprivileged, no loop mount. -m0: no reserved
# blocks (it's a data partition). -d preserves the staged player:player ownership. The offload directories under /home/.retroforge are created on first boot by
# retroforge-offload-prepare.service, not here — it seeds them from the read-only root's content.
home="$(mktemp)"
truncate -s "${HOME_SIZE_MIB}M" "$home"
mkfs.ext4 -q -F -L retroforge-home -m0 -d "$homestage" "$home"
echo "  home ${HOME_SIZE_MIB}MiB ext4 — player home (${home_mib}MiB), grows to fill the card on first boot"

# 4. blank disk image + the full GPT from the table (single source of truth for offsets/types).
mkdir -p "$IMGDIR"; rm -f "$IMG"
truncate -s "${total_mib}M" "$IMG"
"$ROOT/image/genpart.sh" "$IMG" >/dev/null
sgdisk -p "$IMG"

# 4b. ESP filesystem (FAT32) — the ESP GRUB's home:
#
# mtools has no mkdir -p: create each directory level (an existing dir is fine to re-touch).
fatdir() {  # <img> <msdos path, no leading '::'>
  local img="$1" path="$2" p="" part
  for part in ${path//\// }; do
    p="$p/$part"
    mmd -i "$img" "::$p" >/dev/null 2>&1 || true
  done
}
#
#   /EFI/BOOT/bootaa64.efi           ABL starts this (the ESP GRUB); it is the only way onto the card
#   /EFI/steamos/grubenv             RAUC's slot state (ORDER, A_OK/A_TRY, B_OK/B_TRY) and the
#                                    saved board choice, seeded so the FIRST boot picks A
#   /EFI/steamos/parts.env           where our eight partitions are (see 4c)
#   /dtbs/qcom/*.dtb                 OpenABL's Device model list (boot/esp-dtbs.sh)
#
# NOTHING RESOLVES THE ESP BY THIS LABEL. ABL finds /EFI/BOOT/bootaa64.efi by content, the OS
# mounts it by GPT name from /etc/fstab, and the stage-2 grub.cfg addresses it by partition index
# (falling back to a search for /EFI/steamos/grubenv, i.e. by content). The label is a human
# convenience on a mounted card -- it is the drive name Windows shows -- and nothing should depend on
# it agreeing with the GPT name (RetroForge). An earlier version of this script had grub.cfg searching for a FAT label
# this line had stopped writing, and nothing failed -- the saved board choice just never persisted.
esp="$(mktemp)"
truncate -s "${ESP_SIZE_MIB}M" "$esp"
mkfs.vfat -F 32 -n RETROFORGE "$esp" >/dev/null
fatdir "$esp" /EFI/BOOT
fatdir "$esp" /EFI/steamos
fatdir "$esp" /dtbs/qcom
# The pristine env block comes from out/boot, not from a `grub-editenv create` here: the internal
# installer starts from the same file, so a card and an install carry the same object. The slot
# state is seeded on a copy: A is the only slot a fresh card is sure to have, and B is OK only when
# this card populates it. RAUC makes B OK itself the first time it writes it.
envtmp="$(mktemp)"
cp "$GRUBENV" "$envtmp"
grub-editenv "$envtmp" set "ORDER=A B" "A_OK=1" "A_TRY=0" "B_OK=$SLOT_B" "B_TRY=0"
mcopy -i "$esp" "$envtmp" ::/EFI/steamos/grubenv
espdtbs="$(mktemp -d)"
"$ROOT/boot/esp-dtbs.sh" "$espdtbs" "$OUT"/dtbs/*.dtb >/dev/null
mcopy -i "$esp" "$espdtbs"/*.dtb ::/dtbs/qcom/
mcopy -i "$esp" "$GRUB_ESP" ::/EFI/BOOT/bootaa64.efi

# 4c. efi-a / efi-b (p2/p3): each slot's STAGE-2 home. In the post-install hook's refresh shape,
# both carry /EFI/steamos/{grubaa64.efi, grub.cfg, fonts, parts.env}; grub.cfg is the A or B
# variant, which the ESP GRUB hands over to.
#
# parts.env is where our eight partitions ARE on this medium. The stage-2 grub.cfg carries the same
# numbers as build-time defaults, so on a card the file changes nothing — it is seeded anyway, and
# that is deliberate: it makes the card exercise the same lookup an internal install depends on, on
# every boot, instead of shipping that path untested until the installer exists. On an internal
# install our eight are APPENDED to the OEM's GPT and land at per-vendor indices, and the installer
# writes this file with the real ones. It is the one map of the layout, so it goes on both slots
# and the ESP identically; each reader picks the keys it needs.
partsenv="$(mktemp)"
grub-editenv "$partsenv" create
grub-editenv "$partsenv" set \
  "nd_esp=$P_ESP" "nd_efi_a=$P_EFIA" "nd_efi_b=$P_EFIB" \
  "nd_root_a=$P_ROOTA" "nd_root_b=$P_ROOTB" \
  "nd_var_a=$P_VARA" "nd_var_b=$P_VARB" "nd_home=$P_HOME"
mcopy -i "$esp" "$partsenv" ::/EFI/steamos/parts.env
mkefi() {  # <img> <grub.cfg> <label-suffix>
  local img="$1" cfg="$2" label_suffix="$3"
  truncate -s "${EFI_SIZE_MIB}M" "$img"
  mkfs.vfat -F 32 -n "GRUB-${label_suffix}" "$img" >/dev/null
  fatdir "$img" /EFI/steamos/fonts
  mcopy -i "$img" "$GRUB_EFI" ::/EFI/steamos/grubaa64.efi
  mcopy -i "$img" "$cfg" ::/EFI/steamos/grub.cfg
  mcopy -i "$img" "$GRUB_FONT" ::/EFI/steamos/fonts/dejavu-mono.pf2
  mcopy -i "$img" "$partsenv" ::/EFI/steamos/parts.env
}
efi_a="$(mktemp)"; efi_b="$(mktemp)"
mkefi "$efi_a" "$GRUB_CFG_A" "A"
echo "  efi-a  grubaa64.efi + grub.cfg(A) + parts.env"
mkefi "$efi_b" "$GRUB_CFG_B" "B"
echo "  efi-b  grubaa64.efi + grub.cfg(B) + parts.env"

# 5. write each filesystem into its partition's byte offset (notrunc; no loop device).
write_part() {  # <partnum> <file> <label>
  local start; start=$(sgdisk -i "$1" "$IMG" | sed -n 's/^First sector: \([0-9]*\).*/\1/p')
  [ -n "$start" ] || { echo "cannot read start sector of partition $1" >&2; exit 1; }
  dd if="$2" of="$IMG" bs=512 seek="$start" conv=notrunc status=none
  echo "  p$1  $3"
}
write_part "$P_ESP"   "$esp"    "RetroForge (ESP GRUB + grubenv + parts.env + dtbs)"
write_part "$P_EFIA"  "$efi_a"  "retroforge-efi-A (stage-2 grub.cfg A)"
write_part "$P_EFIB"  "$efi_b"  "retroforge-efi-B (stage-2 grub.cfg B)"
write_part "$P_ROOTA" "$ROOTFS"   "retroforge-root-A (btrfs, ro)"
write_part "$P_VARA"  "$VARIMG" "retroforge-var-A (ext4)"
if [ "$SLOT_B" = 1 ]; then
  write_part "$P_ROOTB" "$ROOTFS_B" "retroforge-root-B (btrfs, ro, distinct fsid)"
  write_part "$P_VARB"  "$VARIMG_B" "retroforge-var-B (ext4)"
fi
write_part "$P_HOME"  "$home"   "retroforge-home (ext4, grows on first boot)"

echo "  ok   $(du -h "$IMG" | cut -f1) -> ${IMG#"$ROOT"/}"

# 6. No compression here. The image compresses hard (most of the card is empty — B slots plus the
# unallocated tail), but single-threaded gzip over ~19GiB dominates the wall time of an otherwise
# incremental rebuild, and every local consumer of this image dd's the raw .img anyway. Compression
# is a release/CI concern: do it there, where it runs once per artifact instead of once per edit.

cat <<EOF
Done. Write it to the card (replace sdX with your device, ALL DATA LOST):
  sudo dd if=${IMG#"$ROOT"/} of=/dev/sdX bs=4M conv=fsync status=progress
ABL starts /EFI/BOOT/bootaa64.efi (the ESP GRUB) off the ESP; it picks the slot from RAUC's state in
/EFI/steamos/grubenv and hands over to \EFI\steamos\grub.cfg on that slot's efi-A/B partition,
which boots the kernel in the slot root's /boot.
/home (last partition) holds the player home and grows to fill the card.
$([ "$SLOT_B" = 1 ] \
  && echo "Both slots carry a full system, so a switch is testable: retroforge-bootctl set-primary B" \
  || echo "The B slots are empty and B_OK=0, so the ESP GRUB only ever tries A. The first update
writes B in full and RAUC marks it OK.")

The board: OpenABL's Device model names it when it is set (the ESP's /dtbs/qcom lists our boards);
otherwise the FIRST boot stops at the stage-2 board menu and waits, and the choice is saved in
/EFI/steamos/grubenv. Once the board is known the menu is hidden.

ESP layout: /EFI/BOOT/bootaa64.efi (the ESP GRUB)
            /EFI/steamos/{grubenv, parts.env}
            /dtbs/qcom/*.dtb (OpenABL's Device model list)
Filesystem labels: ESP RETROFORGE | efi-A GRUB-A | efi-B GRUB-B (cosmetic; nothing resolves by them)
EOF
