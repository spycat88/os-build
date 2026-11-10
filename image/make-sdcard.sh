#!/usr/bin/env bash
# retroforge SD-card image builder.
#
# Lays the FULL SteamOS-style 8-partition GPT from image/partition-table.txt and populates
# ESP + boot-a + rootfs-a + var-a + home. The B partitions stay empty (see below).
#
# The boot chain this card boots:
#
#   OpenABL -> a Boot Loader Specification entry in \loader\entries on the slot's boot partition
#           -> the kernel, initramfs and DTB beside it on that partition
#
# rootfs/overlay/usr/lib/retroforge/install/lib-bls.sh has the layout and the A/B state. A FRESH
# CARD carries one OS entry per populated slot (plus its debug entry), the same on every board: the
# command line common to all of them, and the DTB OpenABL's Device model setting picks off the
# slot's partition. The first healthy boot rewrites the booted slot's entries with the board's own
# arguments added (retroforge-bootctl mark-good), and every update writes them that way.
#
# WHY B IS EMPTY, ON A DEV CARD AND A RELEASE CARD ALIKE. boot-b, rootfs-b and var-b are left
# empty (boot-b has only an empty /loader/entries), and the first update writes them.
# RETROFORGE_SLOT_B=1 populates B anyway, for proving a slot switch by hand without an update first.
# Dev cards populated B by default until 2026-11-10, so a dev card looked like no device in the field.
#
# B WOULD BE a byte-identical copy of a root that is ALREADY zstd-compressed inside btrfs,
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
# Run inside the build image (needs sgdisk + mkfs.vfat + mtools + mkfs.ext4 + fdtput):
#   docker run --rm -v "$PWD":/src -w /src retroforge-build image/make-sdcard.sh
#
# Prereqs: boot/gen-bls.sh (-> out/boot/{boards.tsv, cmdline}), kernel/build.sh (-> out/vmlinuz,
# out/dtbs), image/mkinitramfs.sh (-> out/initramfs.cpio.zst) and rootfs/build-image.sh
# (-> out/images/{rootfs,var}.img, and out/boot/release from rootfs/lib-assemble-boot.sh) have run.
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

# Boot artifacts. The kernel and initramfs are the same files rootfs/assemble-rootfs.sh puts in the
# root's /boot, and the board table and command line the ones it puts in /usr/lib/retroforge/boot,
# so the card's entries are what an update hook would write for this build.
KERNEL="$OUT/vmlinuz"
INITRAMFS="$OUT/initramfs.cpio.zst"
BOARDS_TSV="$BOOT/boards.tsv"           # boot/gen-bls.sh: model -> DTB + board args
CMDLINE="$BOOT/cmdline"                 # boot/gen-bls.sh: the args every entry carries
RELEASE="$BOOT/release"                 # rootfs/lib-assemble-boot.sh: build + kernel version
# The entry builders, shared with every on-device writer.
# shellcheck source=../rootfs/overlay/usr/lib/retroforge/install/lib-bls.sh
. "$ROOT/rootfs/overlay/usr/lib/retroforge/install/lib-bls.sh"

# Populate the B slot too: off unless asked for, whatever the build mode. See the header for why.
SLOT_B="${RETROFORGE_SLOT_B:-0}"

MIB=$((1024 * 1024))
END_SLACK_MIB=2   # tail room for the backup GPT (well over its ~17 KiB)

# /home (ext4) carries a ready /home/player from image-build time (see below). The partition is
# flashed small; on first boot retroforge-grow-home extends the partition + its ext4 to fill the card.

for t in sgdisk mkfs.vfat mcopy mmd mkfs.ext4 fdtget fdtput; do
  command -v "$t" >/dev/null 2>&1 || { echo "$t not found — run inside retroforge-build" >&2; exit 1; }
done
[ "$SLOT_B" = 1 ] && { command -v btrfstune >/dev/null 2>&1 || {
  echo "btrfstune not found — run inside retroforge-build (or set RETROFORGE_SLOT_B=0)" >&2; exit 1; }; }
for f in "$BOARDS_TSV" "$CMDLINE"; do
  [ -f "$f" ] || { echo "no boot artifact: ${f#"$ROOT"/} (run boot/gen-bls.sh)" >&2; exit 1; }
done
[ -f "$RELEASE" ] || { echo "no boot artifact: ${RELEASE#"$ROOT"/} (run rootfs/build-image.sh)" >&2; exit 1; }
BLS_VERSION="$(bls_release "$RELEASE" version)"
BLS_KVER="$(bls_release "$RELEASE" kernel)"
[ -f "$KERNEL" ] || { echo "no kernel: ${KERNEL#"$ROOT"/} (run kernel/build.sh)" >&2; exit 1; }
[ -f "$INITRAMFS" ] || { echo "no initramfs: ${INITRAMFS#"$ROOT"/} (run image/mkinitramfs.sh)" >&2; exit 1; }
compgen -G "$OUT/dtbs/*.dtb" >/dev/null || { echo "no DTBs in ${OUT#"$ROOT"/}/dtbs (run kernel/build.sh)" >&2; exit 1; }
[ -f "$ROOTFS" ] || { echo "no rootfs: ${ROOTFS#"$ROOT"/} (run rootfs/build-image.sh)" >&2; exit 1; }
[ -f "$VARIMG" ] || { echo "no var image: ${VARIMG#"$ROOT"/} (run rootfs/build-image.sh)" >&2; exit 1; }

# Partition number and size (MiB) for a row of the table, so the two files can never drift.
part_num()  { awk -v n="$1" '/^[[:space:]]*#/||/^[[:space:]]*$/{next} {i++; if ($1==n) {print i; exit}}' "$TABLE"; }
part_mib()  { awk -v n="$1" '/^[[:space:]]*#/||/^[[:space:]]*$/{next}
  $1==n { s=$2; u=substr(s,length(s),1); v=substr(s,1,length(s)-1)
          if (u=="G") print v*1024; else if (u=="M") print v; else print 0; exit }' "$TABLE"; }

P_ESP=$(part_num esp);    P_BOOTA=$(part_num boot-a); P_BOOTB=$(part_num boot-b)
P_ROOTA=$(part_num rootfs-a); P_VARA=$(part_num var-a)
P_ROOTB=$(part_num rootfs-b); P_VARB=$(part_num var-b)
P_HOME=$(part_num home)

ESP_SIZE_MIB=$(part_mib esp)
BOOT_SIZE_MIB=$(part_mib boot-a)

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
trap 'rm -f "${esp:-}" "${boot_a:-}" "${boot_b:-}" "${home:-}" "${ROOTFS_B:-}" "${flag:-}"; rm -rf "${homestage:-}" "${slotdtbs:-}" "${entries:-}"' EXIT
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

# 4b. The ESP and the slots' boot partitions (FAT32).
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
#   ESP    /loader/loader.conf       `default retroforge-a.conf`
#   boot-a  /loader/entries/retroforge-a+3.conf, retroforge-debug-a.conf
#                                    slot A's OS entry (3 tries) and its debug entry
#          /vmlinuz-<kver>, /initramfs-<kver>.img, /dtbs/
#                                    slot A's kernel, initramfs and DTBs; the DTBs are also
#                                    OpenABL's Device model list (boot/splash-dtbs.sh)
#   boot-b  /loader/entries/, plus the same entries and files for slot B when this card populates
#          B; an empty entries directory otherwise, which the first update fills
#
# NOTHING RESOLVES THESE BY LABEL. OpenABL reads every FAT filesystem on the boot drive and the OS
# mounts them by PARTLABEL from /etc/fstab. The labels are a human convenience on a mounted card.
# The ESP's is its GPT name, RETROFORGE; the boot partitions' are short (BOOT-A/BOOT-B), because a
# FAT label caps at 11 characters.
#
# The entries name root and var by PARTUUID, read here off the GPT genpart.sh just laid: they
# are this card's, and an update never rewrites the partition table, so they stay right.
uuid_of() {  # <partnum>
  sgdisk -i "$1" "$IMG" | sed -n 's/^Partition unique GUID: \([0-9A-Fa-f-]*\).*/\1/p' | tr 'A-Z' 'a-z'
}
uuid_root_a=$(uuid_of "$P_ROOTA"); uuid_var_a=$(uuid_of "$P_VARA")
uuid_root_b=$(uuid_of "$P_ROOTB"); uuid_var_b=$(uuid_of "$P_VARB")
[ -n "$uuid_root_a" ] && [ -n "$uuid_var_a" ] && [ -n "$uuid_root_b" ] && [ -n "$uuid_var_b" ] \
  || { echo "cannot read the slots' partition UUIDs back from ${IMG#"$ROOT"/}" >&2; exit 1; }

mkfat() {  # <img> <size-mib> <label>
  truncate -s "${2}M" "$1"
  mkfs.vfat -F 32 -n "$3" "$1" >/dev/null
}
slotdtbs="$(mktemp -d)"
"$ROOT/boot/splash-dtbs.sh" "$slotdtbs" "$OUT"/dtbs/*.dtb >/dev/null

esp="$(mktemp)"
mkfat "$esp" "$ESP_SIZE_MIB" RETROFORGE
fatdir "$esp" /loader
entries="$(mktemp -d)"
bls_loader_conf_text A >"$entries/loader.conf"
mcopy -i "$esp" "$entries/loader.conf" ::/loader/loader.conf

# A slot's own files, named by kernel version as bls_install_slot_files names them on a device,
# and its two entries: the OS entry with all its tries, and the debug entry. The command line is
# the one every board shares; the first healthy boot adds the board's own arguments.
common="$(head -1 "$CMDLINE")"
slot_files() {  # <img> <A|B> <root-uuid> <var-uuid>
  local img="$1" slot="$2" cmd
  fatdir "$img" /dtbs
  mcopy -i "$img" "$KERNEL" "::/vmlinuz-$BLS_KVER"
  mcopy -i "$img" "$INITRAMFS" "::/initramfs-$BLS_KVER.img"
  mcopy -i "$img" "$slotdtbs"/*.dtb ::/dtbs/
  cmd="$(bls_cmdline "$common" "" "$slot" "$3" "$4")"
  bls_entry_text "$(bls_title "$slot")" "$BLS_VERSION" "$BLS_KVER" "$cmd" "$BLS_SORT_KEY" \
    >"$entries/$(bls_entry_name "$slot" "$BLS_TRIES")"
  bls_entry_text "$(bls_title "$slot" debug)" "$BLS_VERSION" "$BLS_KVER" "$(bls_debug_cmdline "$cmd")" \
    >"$entries/$(bls_debug_name "$slot")"
  mcopy -i "$img" "$entries/$(bls_entry_name "$slot" "$BLS_TRIES")" "$entries/$(bls_debug_name "$slot")" \
    ::/loader/entries/
}
boot_a="$(mktemp)"; boot_b="$(mktemp)"
mkfat "$boot_a" "$BOOT_SIZE_MIB" BOOT-A
mkfat "$boot_b" "$BOOT_SIZE_MIB" BOOT-B
# Both get the directory, so the layout is the same whether or not a slot is populated.
fatdir "$boot_a" /loader/entries
fatdir "$boot_b" /loader/entries
slot_files "$boot_a" A "$uuid_root_a" "$uuid_var_a"
# B gets files and entries only when B is populated: an entry for an empty slot would be a try spent
# on a root that is not there, and the first update writes B's files with its entries.
[ "$SLOT_B" = 1 ] && slot_files "$boot_b" B "$uuid_root_b" "$uuid_var_b"
echo "  esp    loader.conf (default slot A)"
echo "  boot-a  slot A's entry + debug entry, kernel $BLS_KVER"
if [ "$SLOT_B" = 1 ]; then echo "  boot-b  slot B's entry + debug entry, kernel $BLS_KVER"
else echo "  boot-b  empty entries directory"; fi

# 5. write each filesystem into its partition's byte offset (notrunc; no loop device).
write_part() {  # <partnum> <file> <label>
  local start; start=$(sgdisk -i "$1" "$IMG" | sed -n 's/^First sector: \([0-9]*\).*/\1/p')
  [ -n "$start" ] || { echo "cannot read start sector of partition $1" >&2; exit 1; }
  dd if="$2" of="$IMG" bs=512 seek="$start" conv=notrunc status=none
  echo "  p$1  $3"
}
write_part "$P_ESP"   "$esp"    "RETROFORGE (loader.conf)"
write_part "$P_BOOTA"  "$boot_a"  "retroforge-boot-A (slot A's entries + kernel)"
write_part "$P_BOOTB"  "$boot_b"  "retroforge-boot-B ($([ "$SLOT_B" = 1 ] && echo "slot B's entries + kernel" || echo "no entries yet"))"
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
OpenABL boots the Boot Loader Specification entries in /loader/entries on each slot's boot
partition; the kernel, initramfs and DTBs of the slot sit beside them.
/home (last partition) holds the player home and grows to fill the card.
$([ "$SLOT_B" = 1 ] \
  && echo "Both slots carry a full system, so a switch is testable: retroforge-bootctl set-primary B" \
  || echo "The B slots are empty and have no entry, so OpenABL only ever boots A. The first update
writes B and its entry.")

One OS entry per slot, the same on every board: set OpenABL's Device model to this device so it
loads the right DTB off the slot's partition. Once the first boot is confirmed healthy, the booted
slot's entries are rewritten with this board's own kernel arguments.

ESP:   /loader/loader.conf
boot-a: /loader/entries/*.conf, /vmlinuz-$BLS_KVER, /initramfs-$BLS_KVER.img, /dtbs/$([ "$SLOT_B" = 1 ] && echo '
boot-b: the same files, with the entries for slot B' || echo '
boot-b: /loader/entries/ (empty until the first update)')
Filesystem labels: ESP RETROFORGE | boot-A BOOT-A | boot-B BOOT-B (cosmetic; nothing resolves by them)
EOF
