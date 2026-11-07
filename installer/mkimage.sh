#!/usr/bin/env bash
# retroforge INSTALLER medium image builder. Phase 6 of .claude/plans/internal-install.plan.md.
#
#   installer/mkimage.sh [installer-rootfs-dir]     (default: work/installer-base)
#
# Writes out/images/installer.img — a flashable two-partition medium that boots on the handheld,
# draws the consent screen on the panel, and installs RetroForge to the device's internal disk.
#
# RUN INSIDE THE BUILD IMAGE. It needs mksquashfs, sgdisk, mkfs.vfat and mtools, and
# it must run as root to preserve the ownership pacman gave work/installer-base — a squashfs built
# by the host user would put every file on the medium under uid 1000, and the installer runs as
# root against a stranger's disk. installer/mkroot.sh is the host-side half (its only container is
# the emulated pacman); this is the container-side half. Same division as
# rootfs/customize-base.sh -> rootfs/assemble-rootfs.sh, and the reason the plan's sketch of
# mksquashfs-inside-mkroot.sh was not followed.
#
# UNPRIVILEGED IN THE SENSE THAT MATTERS: no loop devices and no mounts. Each filesystem is built
# in a plain FILE (mksquashfs from a directory, mtools into a FAT image) and then dd'd into the
# partition at the offset sgdisk assigned it. That is image/make-sdcard.sh's technique, and it is
# what lets the whole medium be assembled in a container with no privileged flags.
#
# THE MEDIUM BOOTS FROM A BLS ENTRY, NOT GRUB. There is no /EFI tree on it at all: the bootloader
# reads /loader/entries/retroforge.conf (+ retroforge-debug.conf) (BLS) off the boot partition and
# boots /vmlinuz.efi from the same FAT filesystem. The shipped card's A/B chain (ESP GRUB -> stage-2
# grub.cfg -> slot root) exists to choose a slot; this medium has one root, so there is nothing to
# choose. installer/gen-bls-entry.sh writes the entry against the root PARTUUID sgdisk assigns below
# and the RETROFORGE_VERSION stamped in section 0.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BASE="${1:-${INSTALLER_ROOTFS:-$ROOT/work/installer-base}}"
OUT="$ROOT/out/images"
IMG="$OUT/installer.img"
TABLE="$ROOT/installer/medium-table.txt"
GENPART="$ROOT/image/genpart.sh"
GENENTRY="$ROOT/installer/gen-bls-entry.sh"
KERNEL="$ROOT/out/vmlinuz.efi"
DTBDIR="$ROOT/out/dtbs"
WIFI_EXAMPLE="$ROOT/installer/wifi.conf.example"
WORK="$ROOT/work/installer-image"

log() { echo "[retroforge] $*" >&2; }
die() { echo "$*" >&2; exit 1; }

for t in mksquashfs sgdisk mkfs.vfat mcopy mmd; do
  command -v "$t" >/dev/null 2>&1 || die "$t not found — run this inside the build image"
done
for f in "$TABLE" "$GENPART" "$GENENTRY" "$KERNEL"; do
  [ -e "$f" ] || die "missing input: ${f#"$ROOT"/}"
done
[ -d "$DTBDIR" ] || die "missing input: ${DTBDIR#"$ROOT"/}"
[ -f "$BASE/usr/lib/retroforge/pkgs" ] \
  || die "${BASE#"$ROOT"/} is not a finished installer root — run installer/mkroot.sh first"
# The marker installer/mkroot.sh writes LAST. Its absence means a bootstrap died partway, and a
# squashfs of a half-populated tree is an image that boots to a panel and then cannot install.

# Refuse to build a medium out of the SHIPPED root. Both are directories full of a Linux system and
# the argument is positional, so the mistake is one word wide — and the result would be an
# "installer" with no install code on it, discovered on hardware.
grep -q '^ID=retroforge-installer$' "$BASE/etc/os-release" 2>/dev/null \
  || die "${BASE#"$ROOT"/} does not identify as retroforge-installer — wrong tree?"

rm -rf "$WORK"; mkdir -p "$WORK" "$OUT"

# --- 0. the medium's identity ----------------------------------------------------------------------
# WHICH IMAGE AM I LOOKING AT. installer/os-release is deliberately static so a rebuild does not churn
# the tree, and until this block every installer medium ever built answered identically — the same
# NAME, the same ID, no version, no date. That is the first question a person asks at the fallback
# console, which exists precisely for the moment something has gone wrong, and the medium could not
# answer it. Same shape as rootfs/assemble-rootfs.sh section 4a: one stamp, in one place, read back
# by everything downstream.
#
# STAMPED HERE AND NOT IN installer/mkroot.sh, because this is the half that makes an ARTIFACT.
# mkroot's tree is reused across builds on its own input key — a per-build timestamp written there
# would either bust that cache on every run (a full emulated pacstrap) or, worse, survive a reuse
# and describe a build that happened yesterday. The root is the cacheable part; the image is the
# published part; the identity belongs to the published part.
#
# IDEMPOTENT BY CONSTRUCTION: os-release is REWRITTEN from the committed file plus this block, never
# appended to. The tree it lands in is cached, so appending would stack a fresh block on every
# `make installer` until the file carried a dozen contradictory VERSION= lines, the last one
# winning by accident.
#
# THE MODE IS READ OUT OF THE TREE, NOT OUT OF THE ENVIRONMENT. installer/mkroot.sh folds `dev:0|1`
# into the reuse marker it installs at /usr/lib/retroforge/pkgs, so the tree states what was baked
# into it. Deriving it from $RETROFORGE_DEV here would let `RETROFORGE_DEV=1 make installer-root`
# followed by a plain `make installer` stamp `release` on a medium carrying an authorized_keys and
# a Wi-Fi PSK — the exact drift assemble-rootfs.sh's "both read the one flag" note is about, except
# that here the two halves are separate processes and cannot share a variable.
OSRELEASE_SRC="$ROOT/installer/os-release"
[ -f "$OSRELEASE_SRC" ] || die "missing input: ${OSRELEASE_SRC#"$ROOT"/}"
if grep -qx 'dev:1' "$BASE/usr/lib/retroforge/pkgs" 2>/dev/null; then
  IMG_MODE=dev
else
  IMG_MODE=release
fi
IMG_VERSION="${RETROFORGE_VERSION:-dev}"
IMG_GIT="${RETROFORGE_GIT:-unknown}"
IMG_BUILD="$(date -u +%Y%m%dT%H%M%SZ)"
{
  echo "RETROFORGE_VARIANT=installer"
  echo "RETROFORGE_BUILD=$IMG_BUILD"
  echo "RETROFORGE_VERSION=$IMG_VERSION"
  echo "RETROFORGE_GIT=$IMG_GIT"
  echo "RETROFORGE_MODE=$IMG_MODE"
} >"$BASE/etc/retroforge-release"
chmod 0644 "$BASE/etc/retroforge-release"
{
  cat "$OSRELEASE_SRC"
  echo "VARIANT=\"installer\""
  echo "VARIANT_ID=installer"
  echo "VERSION_ID=$IMG_VERSION"
  echo "VERSION=\"$IMG_VERSION ($IMG_GIT)\""
  echo "BUILD_ID=$IMG_BUILD"
} >"$BASE/etc/os-release"
chmod 0644 "$BASE/etc/os-release"
# The same fields OUTSIDE the image, as a sidecar beside it. A publisher must be able to name the
# artifact without mounting a squashfs out of the middle of a GPT — ota/genbundle.sh reads
# rootfs.release for exactly that reason, and a release workflow for this medium will want the same.
cp "$BASE/etc/retroforge-release" "$OUT/installer.release"
log "identity: $IMG_VERSION ($IMG_GIT) build $IMG_BUILD, mode $IMG_MODE"
[ "$IMG_MODE" = release ] || log "NOTE: this medium was built from a DEV root (sshd + baked Wi-Fi)"

# --- 1. the root filesystem ------------------------------------------------------------------------
# zstd because the kernel has CONFIG_SQUASHFS_ZSTD=y and it is the best ratio of the three the
# kernel can read. -noappend so a rebuild replaces rather than accumulating; -no-xattrs is NOT set
# because the tree carries capabilities (ping, and anything pacman set) that must survive.
squash="$WORK/root.squashfs"
log "compressing the installer root (this is the slow step)"
mksquashfs "$BASE" "$squash" -comp zstd -Xcompression-level 19 -noappend -quiet \
  -e boot   # nothing boots FROM the root here: the kernel and dtbs live on the ESP
squash_mib=$(( ( $(stat -c%s "$squash") + 1048575 ) / 1048576 ))
log "root.squashfs: ${squash_mib}M (from $(du -sh "$BASE" 2>/dev/null | cut -f1))"

# --- 2. the GPT ------------------------------------------------------------------------------------
# The medium is sized to its content plus slack, not to a card: this image is published and
# downloaded, and `rest` in the table expands to whatever the file happens to be. image/genpart.sh
# emits the sgdisk script from the table exactly as it does for the shipped card.
esp_mib=$(awk '/^[[:space:]]*#/||/^[[:space:]]*$/{next} $1=="esp"{sub(/M$/,"",$2); print $2; exit}' "$TABLE")
[ -n "$esp_mib" ] || die "cannot read the esp size from ${TABLE#"$ROOT"/}"
# 1M of GPT at each end, plus 64M of slack so the medium is not exactly full — a filesystem with
# zero free sectors behind it is the kind of thing that works until one package grows.
total_mib=$(( 1 + esp_mib + squash_mib + 64 + 1 ))
truncate -s "${total_mib}M" "$IMG"
# The env var is image/genpart.sh's own override for which table it reads; it defaults to the
# eight-partition shipped one sitting beside it, which is precisely what must NOT be used here.
RETROFORGE_PARTITION_TABLE="$TABLE" "$GENPART" "$IMG" >/dev/null
sgdisk -p "$IMG" >&2

part_uuid() { sgdisk -i "$1" "$IMG" | sed -n 's/^Partition unique GUID: \(.*\)/\1/p' | tr '[:upper:]' '[:lower:]'; }
part_start() { sgdisk -i "$1" "$IMG" | sed -n 's/^First sector: \([0-9]*\).*/\1/p'; }
ROOT_UUID="$(part_uuid 2)"
[ -n "$ROOT_UUID" ] || die "sgdisk did not report a partition uuid for p2"

# --- 3. the ESP ------------------------------------------------------------------------------------
# -F 32 is forced here for the same reason image/make-sdcard.sh forces it, and installer/medium-table.txt
# carries the full argument: the filesystem is built inside an image FILE, where mkfs.vfat sees
# 512-byte sectors regardless of the eventual target, and every installer medium is removable and
# therefore 512e. The 4Kn hazard the shipped table warns about cannot reach this partition.
esp="$WORK/esp.img"
truncate -s "${esp_mib}M" "$esp"
mkfs.vfat -F 32 -n RFINSTALLER "$esp" >/dev/null

fatdir() {  # <img> <msdos path, no leading '::'>
  local img="$1" path="$2" p=""
  local IFS=/
  for c in $path; do p="${p:+$p/}$c"; mmd -i "$img" "::$p" >/dev/null 2>&1 || true; done
}
fatdir "$esp" loader/entries
fatdir "$esp" dtbs
fatdir "$esp" retroforge

# The Wi-Fi template, at the path installer/netcfg reads its real counterpart from
# (/esp/retroforge/wifi.conf). HW-FOUND 2026-08-24: the no-Wi-Fi screen has always told the operator
# to "copy wifi.conf.example next to it", and THE FILE HAD NEVER EXISTED -- nothing in this tree
# wrote one and nothing put it on a medium. Instructions naming a file that is not there are worse
# than no instructions: they read as a fault in the person following them.
[ -f "$WIFI_EXAMPLE" ] || die "missing ${WIFI_EXAMPLE#"$ROOT"/} — the no-Wi-Fi screen tells the user to copy it"
mcopy -i "$esp" "$WIFI_EXAMPLE" ::/retroforge/wifi.conf.example

# The BLS entries (normal + debug), generated against the partition uuid sgdisk just assigned. Generated AFTER the GPT
# exists, not before: the uuid is an output of laying the table, and an entry written first would
# have to guess it. NO /EFI directory: nothing on this medium is a UEFI application but the kernel.
entries="$WORK/entries"
"$GENENTRY" "$ROOT_UUID" "$IMG_VERSION" "$entries"
mcopy -i "$esp" "$entries/retroforge.conf" ::/loader/entries/retroforge.conf
mcopy -i "$esp" "$entries/retroforge-debug.conf" ::/loader/entries/retroforge-debug.conf

# The kernel and every dtb, at the FAT root. The loader reads them from the partition it booted from.
mcopy -i "$esp" "$KERNEL" ::/vmlinuz.efi
dtb_n=0
for dtb in "$DTBDIR"/*.dtb; do
  [ -e "$dtb" ] || continue
  mcopy -i "$esp" "$dtb" "::/dtbs/$(basename "$dtb")"
  dtb_n=$((dtb_n + 1))
done
[ "$dtb_n" -gt 0 ] || die "no dtbs copied from ${DTBDIR#"$ROOT"/}"
log "ESP: loader/entries/retroforge{,-debug}.conf + wifi.conf.example + vmlinuz.efi + $dtb_n dtbs (no /EFI)"

# --- 4. write the filesystems into their partitions ---------------------------------------------------
# Every populated filesystem must fit the slot the table gave it. A silently truncated dd produces a
# medium that boots into a corrupt filesystem, which is a much worse failure than this one.
write_part() {  # <partnum> <file> <what>
  local start size_mib avail_mib
  start=$(part_start "$1")
  [ -n "$start" ] || die "cannot read the start sector of p$1"
  size_mib=$(( ( $(stat -c%s "$2") + 1048575 ) / 1048576 ))
  avail_mib=$(( ( $(sgdisk -i "$1" "$IMG" | sed -n 's/^Partition size: \([0-9]*\).*/\1/p') * 512 ) / 1048576 ))
  [ "$size_mib" -le "$avail_mib" ] \
    || die "$3 is ${size_mib}M but p$1 is only ${avail_mib}M"
  dd if="$2" of="$IMG" bs=512 seek="$start" conv=notrunc status=none
  log "p$1 <- $3 (${size_mib}M of ${avail_mib}M)"
}
write_part 1 "$esp" "esp"
write_part 2 "$squash" "root.squashfs"

sync
log "installer image ready: ${IMG#"$ROOT"/} ($(du -h "$IMG" | cut -f1))"
echo "  flash with:  sudo dd if=${IMG#"$ROOT"/} of=/dev/sdX bs=4M conv=fsync status=progress" >&2
echo "$IMG"
