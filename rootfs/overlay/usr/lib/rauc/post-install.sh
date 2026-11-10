#!/usr/bin/env bash
# retroforge RAUC post-install handler.
#
# Runs after RAUC has written and unmounted the target slot. A freshly written slot is NOT usable
# until this has run: the bytes are an exact copy of the running slot, so it shares an fsid, it has
# no per-slot identity in /var, and its boot partition still carries the OLD build's kernel.
#
# Order is load-bearing:
#
#   0. disarm     -- RAUC armed the target BEFORE calling us; take that back until it is real: every
#                    entry on the target's boot partition goes.
#   1. fsid       -- MUST come before anything mounts the target. Until btrfstune has run, the
#                    target and the running root share an fsid AND devid=1, which is the pair
#                    btrfs keys its in-kernel device list on: the second one scanned is treated as
#                    the first having MOVED, so mounting the target can silently hand you the
#                    RUNNING root. Every later step here mounts the target, so this is step 1.
#   2. /var       -- per-slot identity. Without it the updated slot boots as a different device.
#   3. boot files -- the target root's kernel, initramfs and DTBs go onto the target's boot partition.
#   4. re-arm     -- the target's debug entry, then its boot entry, written for this device's board
#                    with all three tries, and the ESP loader.conf's default moved to it.
#
# WHY THE BOOT FILES COME OUT OF THE NEW ROOT AND NOT THE BUNDLE: the kernel, the initramfs, the
# DTBs, the board table, the command line and the versions the entry is written from all ship inside the rootfs
# (/boot and /usr/lib/retroforge/boot). Taking them from the root makes the pairing true by
# construction -- there is no bundle layout to keep in sync, and no way to install a root whose
# entry does not boot it.
#
# THE SLOT STATE IS THE BOOT ENTRIES (lib-bls.sh): each slot's entry, on its own boot partition,
# carries a +N boot counter that OpenABL counts down, and the ESP loader.conf's default is the primary. RAUC drives it through its custom
# backend, retroforge-bootctl; this hook writes it with the same library directly, because RAUC is
# mid-install and cannot be asked. It only ever touches the TARGET's boot partition and the default.
#
# WHO AM I: the booted slot is the initramfs handoff's slot= (retroforge.slot= on the command line
# the booted entry carries), and the target is the other one. RAUC's exported slot names are used
# only to cross-check, and a disagreement is fatal rather than resolved by preference.
#
# THE BOARD is this device's: the running devicetree's model, looked up in the TARGET root's board
# table, so the new entry carries the new build's DTB name and board arguments.
#
# A ROOT FROM BEFORE THE BLS BOOT CHAIN IS REFUSED: it has no boot data to write an entry from,
# and its own update hook and bootctl drive a GRUB state that nothing reads any more. Going back
# past the switch is a reflash.
set -euo pipefail

PROG=${0##*/}
log()  { printf '[%s] %s\n' "$PROG" "$1"; }
die()  { printf '[%s] ERROR: %s\n' "$PROG" "$1" >&2; exit 1; }

# Test seams, documented exactly as retroforge-bootctl documents its own. The offline suite
# (tests/test-post-install.sh) executes THIS file -- not a copy -- so what it asserts is the
# artifact that ships; overriding them points it at a sandbox ESP/var and fake slot devices.
# Nothing here is otherwise conditional on being under test, and the defaults are what every real
# invocation uses. DEVTEST is the one assertion the sandbox cannot keep: an unprivileged test has
# no block devices to offer, so it relaxes -b to -e. Everything a wrong answer here would destroy
# lives behind DEVDIR, so treat both as the pair they are. lib-bls.sh adds BLKID and DT_MODEL.
ESP=${ESP:-/esp}              # the shared ESP (loader.conf, OpenABL's DTBs); mounted by fstab
BOOTPARTS=${BOOTPARTS:-/run/retroforge/bootfs}   # <BOOTPARTS>/a and /b: the slots' boot partitions (fstab automounts)
MNT=${MNT:-/run/retroforge/rauc-target}
VAR=${VAR:-/var}
# /dev/retroforge/, NOT /dev/disk/by-partlabel/: the same GPT names exist on every retroforge medium, so
# by-partlabel would let this hook reformat the /var and read the partition UUIDs of the OTHER disk
# when two are attached. The links here are scoped to the disk we booted from
# (/usr/lib/udev/rules.d/69-retroforge-bootdisk.rules), which is the disk rauc just wrote a slot on --
# etc/rauc/system.conf names its slot devices through the same links, so the two cannot disagree.
DEVDIR=${DEVDIR:-/dev/retroforge}
DEVTEST=${DEVTEST:--b}
# The initramfs handoff that names the booted slot.
BOOTINFO=${BOOTINFO:-/run/retroforge/boot}

# The shared half of this hook. Everything a RAUC bundle does not carry has to be written twice --
# once here and once by the internal installer, onto a disk with no retroforge on it -- and two copies
# of that logic drift in the direction "the installed system boots, the updated one does not", which
# is discoverable only on hardware. So they live in two libraries and this sources both.
#
# Resolved RELATIVE TO THIS SCRIPT, with no seam, because rootfs/overlay/ mirrors the device layout
# exactly: /usr/lib/rauc/../retroforge/install/ and rootfs/overlay/usr/lib/rauc/../retroforge/install/ are
# both right, so the offline suite exercises the shipped path rather than a test-only one.
SELFDIR="$(cd "$(dirname "$0")" && pwd)"
SLOTWRITE="$SELFDIR/../retroforge/install/lib-slotwrite.sh"
BLSLIB="$SELFDIR/../retroforge/install/lib-bls.sh"
[ -r "$SLOTWRITE" ] || die "cannot read $SLOTWRITE -- this root is missing the slot-write primitives"
[ -r "$BLSLIB" ] || die "cannot read $BLSLIB -- this root is missing the boot entry primitives"
# shellcheck source=../retroforge/install/lib-slotwrite.sh
. "$SLOTWRITE"
# shellcheck source=../retroforge/install/lib-bls.sh
. "$BLSLIB"

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

dev_root=$DEVDIR/retroforge-root-$target
dev_var=$DEVDIR/retroforge-var-$target
dev_boot=$DEVDIR/retroforge-boot-$target
# shellcheck disable=SC2086  # DEVTEST is a predicate, not a path
[ $DEVTEST "$dev_root" ] || die "no block device at $dev_root"
# shellcheck disable=SC2086
[ $DEVTEST "$dev_var" ]  || die "no block device at $dev_var"
# shellcheck disable=SC2086
[ $DEVTEST "$dev_boot" ] || die "no block device at $dev_boot"
log "target slot $target ($dev_root)"

# What the entry is written from, asserted HERE -- before step 0, ahead of everything destructive --
# rather than at its use site in step 4. By then the target's fsid is randomised and its /var
# reformatted, so a failure would leave the slot unbootable with a run that cannot be retried cleanly.
# Fail while nothing has been touched.

ls "$ESP" >/dev/null 2>&1 || true         # trigger the fstab automounts if they are not up
mountpoint -q "$ESP" || die "the ESP is not mounted at $ESP"
TFS="$BOOTPARTS/${target,,}"
ls "$TFS" >/dev/null 2>&1 || true
mountpoint -q "$TFS" || die "slot $target's boot partition is not mounted at $TFS"
# The partition UUIDs the entry names. The partitions are this disk's and an update never changes
# the GPT, so these are read now and are what they will be at step 4.
uuid_root=$(bls_dev_partuuid "$dev_root")
uuid_var=$(bls_dev_partuuid "$dev_var")
[ -n "$uuid_root" ] && [ -n "$uuid_var" ] \
  || die "cannot read the PARTUUIDs of slot $target (root '$uuid_root', var '$uuid_var')"
[ -n "$(bls_running_model)" ] || die "cannot read this device's devicetree model -- the entry could not name the board"

# --- 0. DISARM ----------------------------------------------------------------------------------
# RAUC has ALREADY armed this slot by the time we run. Its order is fixed and not ours to change:
# it calls the backend's set-primary (the target's counter to three tries, loader.conf's default
# to it) and only THEN starts the post-install handler. So on entry the ESP says "boot the target
# next" while the target is not yet bootable -- its /var is the previous install's or freshly
# mkfs'd, and the kernel on its boot partition is the other build's.
#
# So: take the target's entry away for the duration of the work, and write a fresh one at the very
# end once the slot is genuinely bootable. An interrupted post-install then leaves nothing pointing
# at a half-prepared slot: with no entry for the target, loader.conf's default matches nothing and
# OpenABL boots the running slot, and the failure mode becomes "the install failed, run it again"
# instead of "three bad boots, then the fall-back".
bls_remove "$TFS" "$target"
log "disarmed slot $target for the duration of the install (re-armed at the end)"

# --- 1. fsid ------------------------------------------------------------------------------------
# -f because the filesystem is a byte copy of a mounted one, which btrfstune otherwise refuses.
btrfstune -f -U "$(cat /proc/sys/kernel/random/uuid)" "$dev_root" >/dev/null \
  || die "btrfstune could not re-randomise the fsid of $dev_root"

# The LABEL is the other identity the byte copy got wrong. rootfs/assemble-rootfs.sh bakes
# retroforge-root-A into the image, RAUC writes that image verbatim to whichever slot it targets,
# and nothing else corrects it -- so without this, both partitions answer to retroforge-root-A.
# The entry addresses the root by PARTUUID, so this is not what makes the slot boot; it is what
# makes `blkid` honest. Cheap, and the window where it is wrong is this hook's own.
btrfs filesystem label "$dev_root" "retroforge-root-${target^^}" >/dev/null \
  || die "cannot label $dev_root as retroforge-root-${target^^}"
log "fsid randomised, label set to retroforge-root-${target^^}"

# --- 2. per-slot /var ---------------------------------------------------------------------------
# Reformat, then copy the RUNNING /var over wholesale, then stamp the slot's own identity onto it.
# seed_var mounts and unmounts $MNT itself and carries the reasoning for all three; the source is a
# DIRECTORY here, which is what makes this the OTA case (the installer passes a seed tarball,
# because on a fresh disk there is no running system whose /var describes the device).
seed_var "$dev_var" "$target" "$MNT" "$VAR"

# --- 3. boot files: the target's kernel onto its boot partition ----------------------------------
# Safe to mount the root now: the fsid was re-randomised in step 1, so this cannot alias the
# running root.
mount -o ro "$dev_root" "$MNT" || die "cannot mount the target root to read its boot files"
trap 'umount "$MNT" 2>/dev/null || true' EXIT

BOOTDIR="$MNT/usr/lib/retroforge/boot"
[ -f "$BOOTDIR/boards.tsv" ] && [ -f "$BOOTDIR/cmdline" ] && [ -f "$BOOTDIR/release" ] \
  || die "the installed root has no BLS boot data (/usr/lib/retroforge/boot/{boards.tsv,cmdline,release}): it predates the BLS boot chain, and going back past it is a reflash"

# The entry texts first, while nothing has moved: an unknown board dies here, with every file
# untouched.
entry=$(bls_device_entry "$BOOTDIR" "$target" "$uuid_root" "$uuid_var")
debug=$(bls_device_entry "$BOOTDIR" "$target" "$uuid_root" "$uuid_var" debug)

mountpoint -q "$TFS" || die "slot $target's boot partition is not mounted at $TFS"
bls_install_slot_files "$TFS" "$MNT"
log "kernel, initramfs and DTBs of slot $target installed in $TFS"

umount "$MNT"; trap - EXIT

# --- 4. re-arm ----------------------------------------------------------------------------------
# The direct inverse of step 0, plus the default: RAUC's set-primary already moved it, but a handler
# run outside RAUC has no such step, and the default is the one thing the next boot reads first. A
# fresh entry has all three tries: whatever the target counted before belongs to the root that was
# there.
bls_write_debug "$TFS" "$target" "$debug"$'\n'
bls_write_entry "$TFS" "$target" "$entry"$'\n'
bls_set_default "$ESP" "$target"

log "slot $target re-armed for a trial boot ($BLS_ENTRIES/$(bls_entry_name "$target" "$BLS_TRIES")); reboot to try it"
