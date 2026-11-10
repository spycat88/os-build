# retroforge slot-write primitives — Phase 2 of .claude/plans/internal-install.plan.md.
#
# SOURCED, never executed (hence mode 0644, like gamescope-display.sh and power-ops.sh).
#
# WHY THIS FILE EXISTS: everything a RAUC bundle does NOT carry has to be written twice -- once by
# the OTA path (rootfs/overlay/usr/lib/rauc/post-install.sh) and once by the internal installer, which
# writes the same artifacts onto a disk that has no retroforge on it yet. Two copies of that logic
# would drift, and the direction they drift in is "the installed system boots, the updated one does
# not" or the reverse -- discoverable only on hardware, on a device with no serial console. So the
# shared half lives here and post-install.sh sources it.
#
# The functions take explicit arguments and touch nothing implicitly: the OTA path addresses a
# running system's /esp and boot partitions, the installer addresses mountpoints under /run on a foreign disk,
# and a primitive that reached for a global would be right for exactly one of them.
#
# die() and log() are the caller's if it has them -- post-install.sh's prefix [post-install.sh] and
# its offline suite asserts that shape, so a primitive that printed its own name would make the
# hook's output read as if two programs were talking. Only define fallbacks when sourced by
# something that has not got them.
if ! declare -F die >/dev/null 2>&1; then
  die() { printf '[lib-slotwrite] ERROR: %s\n' "$1" >&2; exit 1; }
fi
if ! declare -F log >/dev/null 2>&1; then
  log() { printf '[lib-slotwrite] %s\n' "$1"; }
fi

# --- addressing a partition by index, without spelling a device name ----------------------------
# THE ONE RULE THE INSTALLER'S EVERY WRITE DEPENDS ON. genpart.sh --append hands back indices, and
# the tempting way to turn an index into something mkfs can open is `${disk}${n}` or `${disk}p${n}`.
# Do not. The `p` infix depends on the disk's KIND -- `mmcblk0p11` against `sda11` -- so a spine
# written against one is broken on the other, and we cannot test the difference: every device in the
# fleet is UFS (five captures plus a Thor Lite, all UFS 3.1; the only mmcblk anywhere is the boot
# SD). A naming bug of this shape would first appear on a customer's eMMC board, mid-install, on a
# disk whose userdata is already gone. Nothing on the device concatenates a disk and an index today
# and nothing new may start.
#
# LOWER-CASED, and that is not cosmetic either: sgdisk prints partition GUIDs upper case, and the
# by-partuuid links udev makes are lower case. One lowercasing site, so a uuid used as a device path
# cannot disagree with one compared against it.
#
# TWO SEAMS, and they are the same pair every script in this install documents: an unprivileged
# offline suite has no block device to offer and no /dev/disk/by-partuuid to populate, so the
# assertions that matter -- that the answer is lower-cased and that it never contains the disk name
# -- would otherwise be unreachable. Neither has a use on a device. Named here so the rule above
# reads as having declared carve-outs rather than as being quietly untrue.
PARTUUID_DIR=${PARTUUID_DIR:-/dev/disk/by-partuuid}
DISKTEST=${DISKTEST:--b}

part_uuid() {  # <disk> <index> -> lowercase partition GUID
  sgdisk -i "$2" "$1" 2>/dev/null \
    | sed -n 's/^Partition unique GUID: \([0-9A-Fa-f-]*\).*/\1/p' | tr 'A-Z' 'a-z'
}

# Returns NON-ZERO for an image file, which has no partition nodes at all. Callers must treat that
# as "there is nothing to open here" rather than falling back to a name they built themselves --
# guessing a device node to write to is precisely the guess this rule exists to refuse.
part_dev() {  # <disk> <index> -> /dev/disk/by-partuuid/<uuid>
  local uuid
  # shellcheck disable=SC2086  # DISKTEST is a predicate, not a path
  [ $DISKTEST "$1" ] || return 1
  uuid="$(part_uuid "$1" "$2")"
  [ -n "$uuid" ] || return 1
  printf '%s/%s\n' "$PARTUUID_DIR" "$uuid"
}

# --- per-slot /var ------------------------------------------------------------------------------
# Reformat the slot's var partition and populate it, then stamp the two pieces of identity that
# distinguish this slot from the one the content came from.
#
# THE POPULATION IS WHOLESALE, and that shape is load-bearing. It used to be a hand-picked whitelist
# (machine-id, then NetworkManager connections, then SSH host keys...) and that was wrong: every new
# piece of per-device state has to be REMEMBERED, and forgetting one fails SILENTLY -- the update
# succeeds, the slot boots, and something is subtly a different device. On hardware with no serial
# console that is the worst failure shape available. A full copy inverts it: state survives by
# default, and anything we do NOT want has to be excluded on purpose, in writing, below. (SteamOS
# reaches the same conclusion; cf. _reference/steamos-teardown/docs/system-updates.md §4, which
# rsyncs the whole partition after reformatting it.)
#
# The reformat stays: the target's /var is whatever the PREVIOUS install left there, and stale state
# is what makes a slot behave differently from the one that was tested.
#
# <source> IS EITHER A DIRECTORY OR A TARBALL, and which one is what separates the two callers. The
# OTA path passes the RUNNING /var -- there is a live system to copy from and copying it is the
# whole point. The installer passes /usr/lib/retroforge/var-seed.tar.zst out of the root it just
# wrote, because on a disk with no retroforge on it there is nothing to copy: the running system is
# the card, whose /var describes the card, not the device being built. Everything
# after the population is identical, which is why it is one function and not two.
seed_var() {  # <dev> <slot> <mnt> <source>
  local dev="$1" slot="$2" mnt="$3" src="$4"
  local SLOT="${slot^^}"
  case "$SLOT" in A|B) ;; *) die "seed_var: '$slot' is not an image name (A or B)" ;; esac

  # Resolve WHICH KIND of source this is before the reformat, not at the point of use. Both checks
  # are free, and the reformat is destructive: an installer handed a seed tarball path that does not
  # exist would otherwise discover it with the target's /var already emptied, turning a bad argument
  # into a slot that has to be redone.
  local mode
  if   [ -d "$src" ]; then mode=dir
  elif [ -f "$src" ]; then mode=tar
  else die "no /var source at $src -- neither a directory to copy nor a seed tarball"
  fi

  mkfs.ext4 -q -F -L "retroforge-var-$SLOT" "$dev" || die "cannot reformat $dev"

  mkdir -p "$mnt"
  mount "$dev" "$mnt" || die "cannot mount the target /var ($dev)"
  # OURS IS ADDITIVE, and that matters more than it looks. The caller may already own an EXIT trap:
  # post-install.sh does not at this point, but Phase 4's installer holds mountpoints under /run on
  # a foreign disk and will carry one across its whole run. A bare `trap ... EXIT` here would
  # overwrite it and the success path's `trap - EXIT` would then disarm the caller entirely --
  # silently, with the symptom being leaked mounts on exactly the failure paths where cleanup
  # matters. So: chain the previous handler behind ours, and restore it verbatim on the way out.
  #
  # Expanded at trap-SET time, not at trap-fire time: $mnt is a local, and by the time an EXIT trap
  # runs on the die() path this function has gone.
  local prev_cmd
  prev_cmd="$(trap -p EXIT | sed -n "s/^trap -- '\(.*\)' EXIT\$/\1/p")"
  trap "umount $(printf %q "$mnt") 2>/dev/null || true${prev_cmd:+; $prev_cmd}" EXIT

  if [ "$mode" = dir ]; then
    # rsync, in the image for exactly this (rootfs/customize-base.sh PKGS). -aHAX preserves modes,
    # owners, hard links, ACLs and xattrs. Modes matter more than they look: sshd refuses to start
    # if a private host key is group/world-readable, so a mode-losing copy would take SSH down on
    # the updated slot and nowhere else. --numeric-ids because we are copying between two roots
    # rather than resolving names through THIS one's passwd.
    #
    # --one-file-system is LOAD-BEARING. /var/log, /var/tmp, /var/cache/pacman, /var/lib/flatpak and
    # /var/lib/systemd/coredump are bind mounts from the SHARED /home offload tree, i.e. not in this
    # partition at all. Without it we would copy shared data into a 256M partition -- /var/log alone
    # can exceed it -- and duplicate what both slots already share. The mount points themselves need
    # no special handling: systemd creates a .mount unit's target directory if it is missing.
    #
    # Trailing slash on the source: copy its CONTENTS into $mnt, not a /var/var.
    rsync -aHAX --numeric-ids --one-file-system "${src%/}/" "$mnt/" \
      || die "cannot copy $src to the target slot"
    log "copied $src wholesale ($(du -sh -x "$src" 2>/dev/null | cut -f1), offload bind mounts skipped)"
  else
    # The flags MIRROR the rsync above, and have to: -p --numeric-owner --xattrs --acls is what
    # `rsync -aHAX --numeric-ids` promises, and tar preserves hard links natively. An installed slot
    # and an updated one must reach the same /var, and the modes are the sharp end -- sshd refuses
    # to start if a private host key is group/world-readable, so a mode-losing unpack takes SSH down
    # on installed devices and nowhere else. rootfs/assemble-rootfs.sh packs with the same set.
    #
    # -p IS NOT REDUNDANT, even though this runs as root and tar defaults to it there. Measured:
    # without -p the sticky bit on /var/tmp comes back 0777 instead of 1777 -- the bit IS in the
    # archive, tar simply masks it off when it does not think it is preserving permissions. rsync -a
    # has no such mode, so leaving it implicit would make the two paths agree only by accident of
    # who is running them, which is the exact drift this file exists to prevent.
    tar -p --numeric-owner --xattrs --acls -xf "$src" -C "$mnt" \
      || die "cannot unpack the /var seed $src onto $dev"
    log "seeded /var from $src"
  fi

  # The overlay dirs must exist before the target boots -- the initramfs mounts /etc from them, so a
  # slot missing them does not come up at all. A directory source brings them; this is a guard
  # against the one case that would be unrecoverable, and the seed tarball's own guarantee.
  mkdir -p "$mnt/lib/overlays/etc/upper" "$mnt/lib/overlays/etc/work" "$mnt/lib/retroforge"

  # THE ONE FILE THAT MUST NOT SURVIVE THE POPULATION VERBATIM. Everything else in /var describes
  # the DEVICE and is correct on either slot; this describes WHICH SLOT it is. Written last,
  # deliberately after the copy that would otherwise clobber it.
  printf '%s\n' "$SLOT" >"$mnt/lib/retroforge/slot"

  # THE SECOND THING THE COPY MUST NOT KEEP: /var/lib/retroforge/mac-wifi, the write-once record of
  # this device's derived Wi-Fi MAC. Deleted so the target re-derives it from the machine-id that
  # the copy above just carried over (gen-mac.sh: sha256(machine-id)).
  #
  # On a healthy device this is a no-op in effect -- same machine-id in, same MAC out, so the
  # address is stable across the update, which is the requirement. It matters for the devices where
  # it is NOT a no-op: a unit flashed before the MAC-collision fix has a COLLIDING address persisted
  # here, and because the file is write-once and outranks the derivation, that unit keeps the bad
  # MAC forever.
  rm -f "$mnt/lib/retroforge/mac-wifi"

  # THE THIRD: an enable link for the pairing daemon in the /etc overlay upper. Pairing was always on
  # until the shell got its Remote access switch, which starts and stops it (plan ota-ui D5); an
  # older image's link copied here would start it at every boot of the target, accepting SSH keys
  # with nobody having turned pairing on. The unit has no [Install] any more, so nothing recreates it.
  rm -f "$mnt/lib/overlays/etc/upper/systemd/system/multi-user.target.wants/retroforge-pairingd.service"

  # Put the caller's handler back exactly as it was -- `trap - EXIT` only when there was nothing.
  umount "$mnt"
  if [ -n "$prev_cmd" ]; then trap "$prev_cmd" EXIT; else trap - EXIT; fi
}

# NOTHING RESOLVES THE ESP BY THIS LABEL: OpenABL reads every FAT filesystem on the boot drive, the
# OS mounts it by its GPT name from /etc/fstab. It is a human convenience on a mounted disk, and
# it is the same word as the GPT name (RETROFORGE), which fits FAT's 11-character label limit. Kept
# identical to image/make-sdcard.sh's so a card and an internal install present the same object.
ESP_FAT_LABEL=RETROFORGE

# THE FAT WIDTH IS CHOSEN FROM THE DISK, NEVER FORCED. A FAT32 must have at least 65525 data
# clusters to be one, and cluster count scales with SECTORS -- so a partition sized in bytes is a
# different filesystem on 512-byte and 4096-byte media. Every SD card is 512e and every internal UFS
# here is 4Kn, which is why a hardcoded `-F 32` was valid on every card ever flashed and invalid on
# every internal install.
#
# MEASURED on an AYANEO Pocket ACE, 2026-08-21. It surfaces twice, and the two look unrelated:
# the ESP fails inside ABL (its FatPkg returns EFI_VOLUME_CORRUPTED, never publishes a
# SimpleFileSystem handle, and LoadEFI reports "Failed to load EFI: Not Found"), and boot-A/B failed
# one layer later inside steamcl (stage 1 then), which mounted them through the SAME EFI FAT driver
# and so found no boot candidate at all. See the block above the rows in image/partition-table.txt.
#
# The rule is deliberately OURS rather than mkfs.fat's. Dropping the flag entirely also produces a
# valid filesystem, but the width would then be picked by a size-threshold table inside the tool,
# which can move on a version bump and would silently reformat a card's ESP from FAT32 to FAT16.
#
# FAT_SECTOR_SIZE is a TEST SEAM and nothing else. blockdev answers only for a block device, and the
# 4Kn path exists on no card and in no image file -- so without it the one geometry that breaks is
# the one no suite can reach. tests/test-partition-table.sh sets it to drive the rule at 4096
# against the real table; the installer never sets it, and on a device blockdev is authoritative.
fat_type_for() {  # <dev> -> 32 or 16
  local dev="$1" ss bytes sectors
  ss="${FAT_SECTOR_SIZE:-$(blockdev --getss "$dev" 2>/dev/null || true)}"
  bytes="$(blockdev --getsize64 "$dev" 2>/dev/null || stat -c %s "$dev" 2>/dev/null || true)"
  # Unknown geometry keeps the historical answer rather than inventing one: on a card this is right,
  # and on a device that cannot answer blockdev the mkfs below fails loudly either way.
  { [ -n "$ss" ] && [ -n "$bytes" ]; } || { printf 32; return 0; }
  sectors=$(( bytes / ss ))
  # 65525 clusters at one sector per cluster, plus reserved sectors and two FATs. Below this a
  # FAT32 cannot exist here whatever mkfs is asked for.
  if [ "$sectors" -ge 66000 ]; then printf 32; else printf 16; fi
}

# Read the width back off the superblock and refuse a filesystem outside its own valid range. This
# is what turns the failure above from "the device does not boot, with no clue why" into a message
# at the point of creation -- neither the offline suites nor a card build can reach the 4Kn path.
#
# FAT_ASSERT=0 is the sandbox seam, and it is the same trade DEVTEST makes. tests/test-install.sh
# stubs mkfs.vfat to a recorder, so there is no superblock to read back and this could only ever
# fail there. The assertion IS exercised against real filesystems, at both sector sizes, by
# tests/test-partition-table.sh -- which is also the suite that would have caught the defect it
# exists for. Nothing on a device sets it.
assert_fat_valid() {  # <dev> <label-for-messages>
  local dev="$1" what="$2" bps spc rsv nf t16 t32 re fsz tot rootsec cl lo hi
  [ "${FAT_ASSERT:-1}" = 1 ] || return 0
  g() { dd if="$dev" bs=1 skip="$1" count="$2" 2>/dev/null | od -An -tu"$2" | tr -d ' '; }
  bps=$(g 11 2); spc=$(g 13 1); rsv=$(g 14 2); nf=$(g 16 1)
  t16=$(g 19 2); t32=$(g 32 4); re=$(g 17 2); fsz=$(g 22 2)
  [ "${fsz:-0}" != 0 ] || fsz=$(g 36 4)
  tot=$t16; [ "${tot:-0}" != 0 ] || tot=$t32
  { [ -n "$bps" ] && [ "${spc:-0}" -gt 0 ] && [ "${tot:-0}" -gt 0 ]; } \
    || die "$what on $dev: unreadable FAT superblock after mkfs"
  rootsec=$(( (re * 32 + bps - 1) / bps ))
  cl=$(( (tot - (rsv + nf * fsz + rootsec)) / spc ))
  if [ "$re" = 0 ]; then lo=65525; hi=268435445; else lo=4085; hi=65524; fi
  { [ "$cl" -ge "$lo" ] && [ "$cl" -le "$hi" ]; } \
    || die "$what on $dev has $cl clusters, outside ${lo}..${hi} -- the firmware will refuse to mount it"
}

# Installer-only: an update never creates a filesystem on the shared ESP, it refreshes files on the
# one that is already there.
mkfs_esp() {  # <dev>
  local dev="$1"
  mkfs.vfat -F "$(fat_type_for "$dev")" -n "$ESP_FAT_LABEL" "$dev" >/dev/null \
    || die "cannot create the ESP filesystem on $dev"
  assert_fat_valid "$dev" "the ESP"
}

# The remaining two filesystems the installer creates and an update never does. They live here, next
# to mkfs_esp and to the writers that fill them, so that a card and an internal install produce the
# same objects: image/make-sdcard.sh is the other writer, and its labels are what these repeat.
#
# NOTHING RESOLVES A boot PARTITION BY THIS LABEL either -- the OS mounts both by their GPT names
# from /etc/fstab. `BOOT-A`/`BOOT-B` is a human convenience on a mounted disk, and
# it is again not the GPT name: a FAT label caps at 11 characters.
mkfs_boot() {  # <dev> <slot>
  local dev="$1" slot="${2^^}"
  case "$slot" in A|B) ;; *) die "mkfs_boot: '$2' is not an image name (A or B)" ;; esac
  mkfs.vfat -F "$(fat_type_for "$dev")" -n "BOOT-$slot" "$dev" >/dev/null \
    || die "cannot create the boot-${slot,,} filesystem on $dev"
  assert_fat_valid "$dev" "boot-${slot,,}"
}

# -m0: no reserved-for-root blocks. /home is user data on a device with no admin, so the 5% default
# is 5% of the disk nobody can ever use. make-sdcard.sh passes the same.
mkfs_home() {  # <dev>
  local dev="$1"
  mkfs.ext4 -q -F -L retroforge-home -m0 "$dev" \
    || die "cannot create the /home filesystem on $dev"
}
