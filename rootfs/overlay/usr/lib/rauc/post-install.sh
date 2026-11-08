#!/usr/bin/env bash
# retroforge RAUC post-install handler.
#
# Runs after RAUC has written and unmounted the target slot. A freshly written slot is NOT usable
# until this has run: the bytes are an exact copy of the running slot, so it shares an fsid, it has
# no per-slot identity in /var, and its efi partition still carries the OLD build's stage 2.
#
# Order is load-bearing:
#
#   0. disarm     -- RAUC armed the target BEFORE calling us; take that back until it is real.
#   1. fsid       -- MUST come before anything mounts the target. Until btrfstune has run, the
#                    target and the running root share an fsid AND devid=1, which is the pair
#                    btrfs keys its in-kernel device list on: the second one scanned is treated as
#                    the first having MOVED, so mounting the target can silently hand you the
#                    RUNNING root. Every later step here mounts the target, so this is step 1.
#   2. /var       -- per-slot identity. Without it the updated slot boots as a different device.
#   3. boot files -- the target's efi partition gets this build's stage-2 grub.cfg + boot font, and
#                    the shared ESP gets parts.env, OpenABL's \dtbs\qcom and this build's ESP GRUB
#                    (content-identical when unchanged), the ESP GRUB last.
#   4. re-arm     -- the grubenv names the target first, OK and with all three tries.
#   5. tidy up    -- a local bundle under /home that this install came from is deleted. Last, and
#                    best-effort: by now the slot is armed, so nothing here may fail the install.
#
# WHY THE BOOT FILES COME OUT OF THE NEW ROOT AND NOT THE BUNDLE: grub-esp.efi and grub-<slot>.cfg
# are boot software owned by the same build that ships /boot/vmlinuz.efi and /lib/modules/<ver> inside the
# rootfs. Taking them from the root makes the pairing true by construction -- there is no bundle
# layout to keep in sync, and no way to install a root whose stage 2 does not boot it.
#
# THE SLOT STATE IS RAUC'S (bootloader=grub): ORDER, A_OK/A_TRY and B_OK/B_TRY in the ESP's grubenv.
# This hook writes it directly, with the same grub-editenv RAUC uses, because RAUC is mid-install
# and cannot be asked; it only ever moves the TARGET's two values and ORDER.
#
# WHO AM I: the booted slot is the initramfs handoff's slot= (retroforge.slot= on the command line
# the stage-2 entry booted), and the target is the other one. RAUC's exported slot names are used
# only to cross-check, and a disagreement is fatal rather than resolved by preference.
#
# A ROOT FROM BEFORE THE ESP GRUB IS REFUSED: it has no grub-esp.efi to install, and its own userspace
# drives a boot conf the ESP GRUB only follows. Going back past the switch is a reflash.
set -euo pipefail

PROG=${0##*/}
log()  { printf '[%s] %s\n' "$PROG" "$1"; }
die()  { printf '[%s] ERROR: %s\n' "$PROG" "$1" >&2; exit 1; }

# Test seams, documented exactly as retroforge-bootctl documents its own. The offline suite
# (tests/test-post-install.sh) executes THIS file -- not a copy -- so what it asserts is the
# artifact that ships; overriding them points it at a sandbox ESP/efi/var and fake slot devices.
# Nothing here is otherwise conditional on being under test, and the defaults are what every real
# invocation uses. DEVTEST is the one assertion the sandbox cannot keep: an unprivileged test has
# no block devices to offer, so it relaxes -b to -e. Everything a wrong answer here would destroy
# lives behind DEVDIR, so treat both as the pair they are.
ESP=${ESP:-/esp}              # the shared ESP (ESP GRUB + grubenv); mounted by fstab
EFI=${EFI:-/efi}              # the RUNNING slot's efi partition (parts.env); initramfs mount
MNT=${MNT:-/run/retroforge/rauc-target}
EFIMNT=${EFIMNT:-/run/retroforge/rauc-efi}
VAR=${VAR:-/var}
# /dev/retroforge/, NOT /dev/disk/by-partlabel/: the same GPT names exist on every retroforge medium, so
# by-partlabel would let this hook reformat the /var and rewrite the efi partition of the OTHER disk
# when two are attached. The links here are scoped to the disk we booted from
# (/usr/lib/udev/rules.d/69-retroforge-bootdisk.rules), which is the disk rauc just wrote a slot on --
# etc/rauc/system.conf names its slot devices through the same links, so the two cannot disagree.
DEVDIR=${DEVDIR:-/dev/retroforge}
DEVTEST=${DEVTEST:--b}
# The slot-state editor RAUC itself runs, and the block it edits (system.conf `grubenv=`). BOOTINFO
# is the initramfs handoff that names the booted slot.
EDITENV=${EDITENV:-grub-editenv}
GRUBENV=${GRUBENV:-$ESP/EFI/steamos/grubenv}
BOOTINFO=${BOOTINFO:-/run/retroforge/boot}
# The hasher, a seam for the same reason EDITENV is one: the suite runs this script with the HOST's PATH
# appended, so it cannot make a tool absent, and the assertion below would be untestable as a bare
# command name. Overriding it with a name that does not exist is how the offline suite reaches the
# die() -- there is no other way in, and an assertion nothing can exercise is what put a dead `cmp`
# in this file for three releases.
SHA256=${SHA256:-sha256sum}
# Step 5's view of the kernel: the mount table that maps the bundle mount point to a device, the
# sysfs tree that walks that device down to its loop file, and the only tree a bundle is deleted
# from. Seams so the offline suite can model a loop-backed bundle without a loop device.
MOUNTINFO=${MOUNTINFO:-/proc/self/mountinfo}
SYSDEVBLOCK=${SYSDEVBLOCK:-/sys/dev/block}
BUNDLEHOME=${BUNDLEHOME:-/home}

# The shared half of this hook. Everything a RAUC bundle does not carry has to be written twice --
# once here and once by the internal installer, onto a disk with no retroforge on it -- and two copies
# of that logic drift in the direction "the installed system boots, the updated one does not", which
# is discoverable only on hardware. So they live in one file and this sources it.
#
# Resolved RELATIVE TO THIS SCRIPT, with no seam, because rootfs/overlay/ mirrors the device layout
# exactly: /usr/lib/rauc/../retroforge/install/ and rootfs/overlay/usr/lib/rauc/../retroforge/install/ are
# both right, so the offline suite exercises the shipped path rather than a test-only one. Sourced
# AFTER the seams above so the library picks up an overridden $SHA256 rather than its own default.
SELFDIR="$(cd "$(dirname "$0")" && pwd)"
SLOTWRITE="$SELFDIR/../retroforge/install/lib-slotwrite.sh"
[ -r "$SLOTWRITE" ] || die "cannot read $SLOTWRITE -- this root is missing the slot-write primitives"
# shellcheck source=../retroforge/install/lib-slotwrite.sh
. "$SLOTWRITE"

# --- which slot did we just write? --------------------------------------------------------------
# The booted slot comes from the initramfs handoff, NOT from RAUC: RAUC names slots as they appear
# in system.conf, and this must not depend on a value that could be misnamed. The target is simply
# the other slot. RAUC's value is used only to cross-check.
booted=$(sed -n 's/^slot=//p' "$BOOTINFO" 2>/dev/null || true)
case "$booted" in
  A) target=B ;;
  B) target=A ;;
  *) die "this boot did not come from a slot (no slot= in $BOOTINFO) -- refusing to guess a target" ;;
esac

if [ -n "${RAUC_TARGET_SLOTS:-}" ]; then
  # RAUC names slots as they appear in system.conf ("rootfs.0"/"rootfs.1"); map to our images.
  case "${RAUC_TARGET_SLOTS}" in
    *rootfs.0*) rauc_target=A ;;
    *rootfs.1*) rauc_target=B ;;
    *)          rauc_target='' ;;
  esac
  if [ -n "$rauc_target" ] && [ "$rauc_target" != "$target" ]; then
    die "RAUC says it wrote slot '$rauc_target' but the booted image is '$booted' (target '$target') -- refusing"
  fi
fi

case "$target" in
  A) dev_root=$DEVDIR/retroforge-root-A; dev_var=$DEVDIR/retroforge-var-A; dev_efi=$DEVDIR/retroforge-efi-A ;;
  B) dev_root=$DEVDIR/retroforge-root-B; dev_var=$DEVDIR/retroforge-var-B; dev_efi=$DEVDIR/retroforge-efi-B ;;
esac
# shellcheck disable=SC2086  # DEVTEST is a predicate, not a path
[ $DEVTEST "$dev_root" ] || die "no block device at $dev_root"
# shellcheck disable=SC2086
[ $DEVTEST "$dev_var" ]  || die "no block device at $dev_var"
# shellcheck disable=SC2086
[ $DEVTEST "$dev_efi" ]  || die "no block device at $dev_efi"
log "target slot $target ($dev_root, $dev_efi)"

# The one external tool this script asserts, and it is asserted HERE -- before step 0, ahead of
# everything destructive -- rather than at its use site down in step 3. A comparator that is merely
# ABSENT does not announce itself: `cmp -s` was used until 2026-08-05, diffutils has never been in
# PKGS, and "command not found" is a non-zero exit that reads exactly like "the files differ". The
# ESP refresh below degraded to unconditional copy for three releases without a single failed
# install. Dying at the use site would be worse than useless: by then the target's fsid is
# randomised and its /var reformatted, so the slot is already unbootable and the run cannot be
# retried cleanly. Fail while nothing has been touched.
command -v "$SHA256" >/dev/null || die "$SHA256 is missing -- cannot compare the ESP boot files"
command -v "$EDITENV" >/dev/null || die "$EDITENV is missing -- cannot write the slot state"
ls "$ESP" >/dev/null 2>&1 || true         # trigger the fstab automount if it is not up
[ -f "$GRUBENV" ] || die "no grubenv at $GRUBENV -- is the ESP mounted at $ESP?"

# --- 0. DISARM ----------------------------------------------------------------------------------
# RAUC has ALREADY armed this slot by the time we run. Its order is fixed and not ours to change:
# it calls the bootloader's set-primary (ORDER with the target first, <target>_OK=1, <target>_TRY=0)
# and only THEN starts the post-install handler. So on entry the grubenv says "boot the target next"
# while the target is not yet bootable -- its /var is the previous install's or freshly mkfs'd, and
# its efi partition still holds the other build's stage 2.
#
# So: take the arming back for the duration of the work, and re-arm at the very end once the slot
# is genuinely bootable. An interrupted post-install then leaves nothing pointing at a
# half-prepared slot: the ESP GRUB skips a slot that is not OK, and the failure mode becomes "the
# install failed, run it again" instead of "one bad boot, hope the fall-back fires".
"$EDITENV" "$GRUBENV" set "${target}_OK=0" "${target}_TRY=0" \
  || die "cannot disarm the target slot before preparing it"
sync
log "disarmed slot $target for the duration of the install (re-armed at the end)"

# --- 1. fsid ------------------------------------------------------------------------------------
# -f because the filesystem is a byte copy of a mounted one, which btrfstune otherwise refuses.
btrfstune -f -U "$(cat /proc/sys/kernel/random/uuid)" "$dev_root" >/dev/null \
  || die "btrfstune could not re-randomise the fsid of $dev_root"

# The LABEL is the other identity the byte copy got wrong. rootfs/assemble-rootfs.sh bakes
# retroforge-root-A into the image, RAUC writes that image verbatim to whichever slot it targets,
# and nothing else corrects it -- so without this, both partitions answer to retroforge-root-A.
# Stage 2 normally addresses the root by partition index, so this is not what makes the slot boot;
# it is what makes `blkid` honest and what keeps stage 2's documented fallback (search --label)
# from resolving to the wrong slot. Cheap, and the window where it is wrong is this hook's own.
btrfs filesystem label "$dev_root" "retroforge-root-${target^^}" >/dev/null \
  || die "cannot label $dev_root as retroforge-root-${target^^}"
log "fsid randomised, label set to retroforge-root-${target^^}"

# --- 2. per-slot /var ---------------------------------------------------------------------------
# Reformat, then copy the RUNNING /var over wholesale, then stamp the slot's own identity onto it.
# seed_var mounts and unmounts $MNT itself and carries the reasoning for all three; the source is a
# DIRECTORY here, which is what makes this the OTA case (the installer passes a seed tarball,
# because on a fresh disk there is no running system whose /var describes the device).
seed_var "$dev_var" "$target" "$MNT" "$VAR"

# --- 3. boot files: the target's efi partition + the shared ESP ---------------------------------
# Safe to mount the root now: the fsid was re-randomised in step 1, so this cannot alias the
# running root.
mount -o ro "$dev_root" "$MNT" || die "cannot mount the target root to read its boot files"
trap 'umount "$MNT" 2>/dev/null || true; umount "$EFIMNT" 2>/dev/null || true' EXIT

BOOTDIR="$MNT/usr/lib/retroforge/boot"
[ -f "$BOOTDIR/grub-esp.efi" ] \
  || die "the installed root has no ESP GRUB (/usr/lib/retroforge/boot/grub-esp.efi): it predates the GRUB boot chain, and going back past it is a reflash"

mkdir -p "$EFIMNT"
mount "$dev_efi" "$EFIMNT" || die "cannot mount the target efi partition ($dev_efi)"

# The efi partitions are not RAUC slots (etc/rauc/system.conf declares only rootfs.0/rootfs.1, and
# the bundle carries only rootfs.img), so the only thing that ever writes them on an update is this
# block. write_efi_partition carries the rest of the reasoning, including why it copies onto the
# partition rather than wiping it -- parts.env lives there and an update cannot rebuild it.
write_efi_partition "$EFIMNT" "$target" "$BOOTDIR"
log "stage-2 grub.cfg + font installed on $dev_efi"

umount "$EFIMNT"; rmdir "$EFIMNT" 2>/dev/null || true; trap 'umount "$MNT" 2>/dev/null || true' EXIT

# The shared ESP is refreshed from the installed root too, so the ESP GRUB is the same build that
# owns the stage 2 written above.
mountpoint -q "$ESP" || die "the ESP is not mounted at $ESP"
refresh_esp_extras "$ESP" "$EFI" "$BOOTDIR"
refresh_esp_stage1 "$ESP" "$BOOTDIR"

umount "$MNT"; trap - EXIT

# --- 4. re-arm ----------------------------------------------------------------------------------
# The direct inverse of step 0, plus ORDER: RAUC's set-primary already put the target first, but a
# handler run outside RAUC has no such step, and the order is the one thing the next boot reads
# before anything else. TRY=0 gives the trial all three of its tries: whatever the target counted
# while it sat idle belongs to the root that was there before.
"$EDITENV" "$GRUBENV" set "ORDER=$target $booted" "${target}_OK=1" "${target}_TRY=0" \
  || die "cannot re-arm slot $target for its trial boot"
sync

# --- 5. delete the installed bundle -------------------------------------------------------------
# A manual install is `scp bundle /home/ && rauc install /home/<bundle>`, and the multi-GB file is
# dead weight once its slot is armed. The OTA path streams over NBD and leaves nothing on disk.
#
# RAUC DOES NOT TELL A HANDLER THE BUNDLE'S PATH, only RAUC_BUNDLE_MOUNT_POINT. So it is recovered
# from the kernel: the mount point's device (major:minor in mountinfo) is dm-verity (format=verity)
# or the loop device itself (format=plain), and dm-verity's single slave is the loop device whose
# loop/backing_file is the bundle, opened by RAUC itself (mount.c r_setup_loop). A streamed bundle
# bottoms out at an nbd device with no backing_file, and is skipped.
#
# WHAT GETS DELETED IS DELIBERATELY NARROW, because this runs as root on a path a session user can
# choose (rauc's bus policy lets anyone install): a regular *.raucb file under /home, outside
# /home/.retroforge, named by a path with no symlinks in it. Anything else -- a bundle on a USB
# stick, RAUC's own /tmp download copy, a renamed file -- is left alone and says why.
#
# The loop device keeps the inode alive, so unlinking it while RAUC still has it mounted is safe;
# the space comes back when RAUC unmounts the bundle after this hook returns. Never fatal: the slot
# is armed, and a leftover file is not a failed install.
installed_bundle() {
  local mp=${RAUC_BUNDLE_MOUNT_POINT:-} majmin dev slaves depth
  [ -n "$mp" ] || return 1
  majmin=$(awk -v mp="$mp" '$5 == mp { m = $3 } END { if (m != "") print m }' "$MOUNTINFO" 2>/dev/null) || return 1
  [ -n "$majmin" ] || return 1
  dev="$SYSDEVBLOCK/$majmin"
  for depth in 1 2 3 4; do
    if [ -r "$dev/loop/backing_file" ]; then
      cat "$dev/loop/backing_file"
      return 0
    fi
    slaves=("$dev"/slaves/*)
    [ "${#slaves[@]}" = 1 ] && [ -e "${slaves[0]}" ] || return 1
    dev=${slaves[0]}
  done
  return 1
}

delete_installed_bundle() {
  local bundle real
  bundle=$(installed_bundle) || { log "no local bundle file behind this install -- nothing to delete"; return 0; }
  case "$bundle" in
    *" (deleted)") log "bundle $bundle is already gone"; return 0 ;;
    "$BUNDLEHOME"/.retroforge/*) log "not deleting $bundle: it is under $BUNDLEHOME/.retroforge"; return 0 ;;
    "$BUNDLEHOME"/*.raucb) ;;
    *) log "not deleting $bundle: only a *.raucb under $BUNDLEHOME is removed after an install"; return 0 ;;
  esac
  [ -e "$bundle" ] || { log "bundle $bundle is already gone"; return 0; }
  real=$(realpath -- "$bundle" 2>/dev/null) || { log "not deleting $bundle: cannot resolve its path"; return 0; }
  [ "$real" = "$bundle" ] || { log "not deleting $bundle: its path now resolves to $real"; return 0; }
  [ -f "$bundle" ] && [ ! -L "$bundle" ] || { log "not deleting $bundle: not a regular file"; return 0; }
  if rm -f -- "$bundle"; then
    log "deleted the installed bundle $bundle"
  else
    log "WARNING: could not delete the installed bundle $bundle"
  fi
}
delete_installed_bundle || true

log "slot $target re-armed for a trial boot; reboot to try it"
