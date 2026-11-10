#!/usr/bin/env bash
# Verification of an INTERNAL install, run on the device — Phase 4c of
# .claude/plans/internal-install.plan.md.
#
#   installer/verify-install.sh            # discover the installed disk
#   installer/verify-install.sh /dev/sda   # check exactly this disk
#
# THE SAME CHECK LIST AS image/verify-card.sh, against real mounts. That one is unprivileged and
# reads image files at byte offsets with mtools; this one has root and real block devices, so it
# mounts read-only instead. The lists are kept deliberately parallel: a card and an install that
# pass different checks are two artifacts nobody can reason about together.
#
# WHY IT EXISTS SEPARATELY FROM THE INSTALLER. The spine writes; this reads. An installer that
# graded its own work would share the bug with its grader -- the same reason select-target.sh is a
# separate script from carve.sh. Run it after the install and BEFORE the card comes out, while
# there is still a shell that can fix things.
#
# READ-ONLY, and structurally so: every mount here is `-o ro`, nothing is created outside a
# tmpdir, and the only block-device reads are through blkid and the mounted filesystems.
#
# WHAT IT CANNOT TELL YOU: that the device boots. Nothing here replaces pulling the card and
# watching ABL hand off. It answers the narrower question of whether the eight partitions carry
# what the boot chain will look for, which is the part that is silent until it is not.
set -uo pipefail

SELFDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

FAIL=0
ok()  { printf '    ok  %s\n' "$1"; }
bad() { printf '    !!  %s\n' "$1"; FAIL=1; }
die() { printf 'verify-install: %s\n' "$1" >&2; exit 1; }

[ "$(id -u)" = 0 ] || die "must run as root -- it mounts the installed filesystems"

# Fail closed on a missing tool, the same rule as select-target.sh's mdir and sfdisk. A verifier
# that skips a check because a binary is absent reports "no failures" for a disk it never looked
# at, which is worse than not running at all.
for t in sgdisk sfdisk blkid mount umount findmnt; do
  command -v "$t" >/dev/null 2>&1 || die "$t not found -- refusing to report on checks it cannot run"
done

# lib-gpt.sh (name -> index, past any entry the GPT no longer uses) and lib-slotwrite.sh
# (index -> /dev/disk/by-partuuid/...). Resolved by search exactly as carve.sh resolves them.
LIBGPT="${RETROFORGE_LIB_GPT:-}"
if [ -z "$LIBGPT" ]; then
  for c in "$SELFDIR/lib-gpt.sh" /usr/lib/retroforge/install/lib-gpt.sh "$SELFDIR/../image/lib-gpt.sh"; do
    [ -r "$c" ] && { LIBGPT="$c"; break; }
  done
fi
SLOTWRITE="${RETROFORGE_SLOTWRITE:-}"
if [ -z "$SLOTWRITE" ]; then
  for c in "$SELFDIR/lib-slotwrite.sh" /usr/lib/retroforge/install/lib-slotwrite.sh \
           "$SELFDIR/../rootfs/overlay/usr/lib/retroforge/install/lib-slotwrite.sh"; do
    [ -r "$c" ] && { SLOTWRITE="$c"; break; }
  done
fi
[ -n "$LIBGPT" ]    && [ -r "$LIBGPT" ]    || die "cannot find lib-gpt.sh (set RETROFORGE_LIB_GPT)"
[ -n "$SLOTWRITE" ] && [ -r "$SLOTWRITE" ] || die "cannot find lib-slotwrite.sh (set RETROFORGE_SLOTWRITE)"
# shellcheck source=../image/lib-gpt.sh
. "$LIBGPT"
# shellcheck source=../rootfs/overlay/usr/lib/retroforge/install/lib-slotwrite.sh
. "$SLOTWRITE"

T="$(mktemp -d)"
cleanup() {
  # Unmount deepest-first: the mounts are independent here, but a future check that nests would
  # otherwise leave a busy mount behind on a device the operator still has to reboot.
  awk -v t="$T" '$2 ~ "^"t {print $2}' /proc/mounts | sort -r | while read -r m; do
    umount "$m" >/dev/null 2>&1 || true
  done
  rm -rf "$T"
}
trap cleanup EXIT

OUR_NAMES=(RETROFORGE retroforge-boot-A retroforge-boot-B retroforge-root-A retroforge-root-B \
           retroforge-var-A retroforge-var-B retroforge-home)

# --- which disk ---------------------------------------------------------------------------------
# By GPT name, not by asking which disk we booted from: the point of this script is to check an
# install that may not be the running system (run it from the card, before the first internal boot).
DISK="${1:-}"
if [ -z "$DISK" ]; then
  for d in /dev/sd? /dev/nvme?n? /dev/mmcblk?; do
    [ -b "$d" ] || continue
    if gpt_rows "$d" 2>/dev/null | awk '{print $5}' | grep -qx retroforge-root-A; then
      [ -z "$DISK" ] || die "more than one disk carries a retroforge install ($DISK and $d) -- name one"
      DISK="$d"
    fi
  done
fi
[ -n "$DISK" ] || die "no disk carries a retroforge install (looked for retroforge-root-A)"
[ -b "$DISK" ] || die "$DISK is not a block device"

echo "[retroforge] verifying the install on $DISK"

# --- 1. the eight are there, and addressable by PARTUUID -----------------------------------------
# The index is discovered by NAME and never by arithmetic: on an internal install the eight are
# neither row order nor contiguous.
declare -A IDX DEV
rows="$(gpt_rows "$DISK")" || die "cannot read the partition table of $DISK"
for name in "${OUR_NAMES[@]}"; do
  i="$(printf '%s\n' "$rows" | awk -v w="$name" '$5 == w {print $1; exit}')"
  if [ -z "$i" ]; then bad "$name is missing from the table"; continue; fi
  IDX["$name"]="$i"
  d="$(part_dev "$DISK" "$i")" || { bad "$name (p$i) has no partuuid path"; continue; }
  if [ -b "$d" ]; then DEV["$name"]="$d"; ok "$name = p$i, addressable by partuuid"
  else bad "$name (p$i) resolves to $d, which is not a block device"; fi
done
[ "${#DEV[@]}" = 8 ] || { printf '\nverify-install: %d of 8 partitions unusable -- stopping\n' \
  "$(( 8 - ${#DEV[@]} ))" >&2; exit 1; }

# READ THROUGH AN EXISTING MOUNT WHEN THERE IS ONE. This script is meant to run from the installer,
# where nothing on the target is mounted -- but it is at least as useful run on the installed system
# afterwards, and there /esp and /run/retroforge/bootfs/a are already mounted by the running OS. `mount -o ro`
# on a device that is already mounted fails with "would change RO state", which would report the ESP
# as unreadable on a perfectly good install. We only ever read, so an existing mount serves.
USE_PATH=""; USE_OURS=0
use_fs() {  # <dev> <tmp-mountpoint> -> 0 with USE_PATH set
  local existing
  USE_PATH=""; USE_OURS=0
  existing="$(findmnt -no TARGET --source "$1" 2>/dev/null | head -1)"
  if [ -n "$existing" ]; then USE_PATH="$existing"; return 0; fi
  mkdir -p "$2"
  mount -o ro "$1" "$2" 2>/dev/null || return 1
  USE_PATH="$2"; USE_OURS=1
}
release_fs() { [ "$USE_OURS" = 1 ] && umount "$USE_PATH" >/dev/null 2>&1; USE_OURS=0; return 0; }

fstype() { blkid -o value -s TYPE  "$1" 2>/dev/null; }
fsuuid() { blkid -o value -s UUID  "$1" 2>/dev/null; }
fslabel() { blkid -o value -s LABEL "$1" 2>/dev/null; }

# --- 2. filesystem identities --------------------------------------------------------------------
echo "  1. filesystems"
expect_fs() {  # <gpt-name> <expected type>
  local got; got="$(fstype "${DEV[$1]}")"
  [ "$got" = "$2" ] && ok "$1 is $2" || bad "$1 is '${got:-none}', expected $2"
}
expect_fs RETROFORGE   vfat
expect_fs retroforge-boot-A vfat
expect_fs retroforge-boot-B vfat
expect_fs retroforge-root-A btrfs
expect_fs retroforge-var-A  ext4
expect_fs retroforge-home   ext4

# SLOT B IS EMPTY ON A FRESH INSTALL, and that is a claim worth asserting rather than a gap in the
# list. The spine formats four filesystems, not six: the RAUC handler owns var-A, and root-B/var-B
# are left untouched so the disk matches the release card's shape. A populated B here means either
# an update has already been applied (fine -- set RETROFORGE_SLOT_B=1) or the installer wrote a slot
# it had no business writing.
if [ "${RETROFORGE_SLOT_B:-0}" = 1 ]; then
  expect_fs retroforge-root-B btrfs
  expect_fs retroforge-var-B  ext4
  # Content-identical roots that SHARE an fsid make mounting B hand you A, and every slot test
  # after that is meaningless. Same check, same reason, as image/verify-card.sh.
  a="$(fsuuid "${DEV[retroforge-root-A]}")"; b="$(fsuuid "${DEV[retroforge-root-B]}")"
  { [ -n "$a" ] && [ "$a" != "$b" ]; } \
    && ok "root-A / root-B fsids differ (${a:0:8} vs ${b:0:8})" \
    || bad "root-A and root-B share an fsid -- a slot switch cannot be trusted"
  a="$(fsuuid "${DEV[retroforge-var-A]}")"; b="$(fsuuid "${DEV[retroforge-var-B]}")"
  { [ -n "$a" ] && [ "$a" != "$b" ]; } \
    && ok "var-A / var-B UUIDs differ" || bad "var-A and var-B share a UUID"
else
  for n in retroforge-root-B retroforge-var-B; do
    got="$(fstype "${DEV[$n]}")"
    [ -z "$got" ] && ok "$n is unformatted (empty slot B, as a fresh install leaves it)" \
                  || bad "$n carries a $got filesystem on a fresh install -- set RETROFORGE_SLOT_B=1 if an update has landed"
  done
fi

[ "$(fslabel "${DEV[retroforge-root-A]}")" = retroforge-root-A ] \
  && ok "root-A btrfs label = retroforge-root-A" \
  || bad "root-A btrfs label is '$(fslabel "${DEV[retroforge-root-A]}")'"

# --- 3. the slot witness -------------------------------------------------------------------------
echo "  2. slot witness"
# UPPERCASE, and that is not a detail to normalise away. tests/test-post-install.sh states the
# convention -- the witness records the slot "in the bootconf naming (A/B)" -- and asserts 'B' for
# slot B. seed_var writes $SLOT, which is that same naming.
#
# THE CARD DISAGREES: image/verify-card.sh expects lowercase 'a', and passes, so a card's var-a
# really does carry 'a' while an install's var-A carries 'A'. Nothing reads this file at runtime --
# it is a witness for diagnosis, and the two verifiers are its only readers -- so it costs nothing
# today. It is still two artifacts answering the same question differently, which is the thing
# these parallel check lists exist to surface. Asserted here as the installer actually writes it.
if use_fs "${DEV[retroforge-var-A]}" "$T/var"; then
  got="$(tr -d '[:space:]' <"$USE_PATH/lib/retroforge/slot" 2>/dev/null)"
  [ "$got" = A ] && ok "var-A /var/lib/retroforge/slot = A" \
                 || bad "var-A slot witness: expected 'A', got '${got:-<missing>}'"
  release_fs
else
  bad "cannot read var-A"
fi

# --- 4. the ESP and boot-a (boot entries) ---------------------------------------------------------
# The ESP carries loader.conf (the primary slot) and nothing else. Slot A's Boot Loader
# Specification entries live on boot-a, with the kernel, initramfs and DTBs beside them.
echo "  3. ESP"
if use_fs "${DEV[RETROFORGE]}" "$T/esp"; then
  esp="$USE_PATH"
  grep -qx 'default retroforge-a.conf' "$esp/loader/loader.conf" 2>/dev/null \
    && ok "loader.conf defaults to slot A" || bad "loader.conf does not default to slot A"
  [ -e "$esp/dtbs" ] && bad "the ESP carries /dtbs -- they belong on the slots' boot partitions" \
                     || ok "no /dtbs on the ESP"
  [ -e "$esp/loader/entries" ] && [ -n "$(ls -A "$esp/loader/entries" 2>/dev/null)" ] \
    && bad "the ESP carries entries -- they belong on the slots' boot partitions" || ok "no entries on the ESP"
  for junk in /KERNEL /RETROFORGE /SteamOS /retroforge /EFI/BOOT/bootaa64.efi /EFI/steamos; do
    [ -e "$esp$junk" ] && bad "$junk present on the ESP" || ok "no $junk"
  done
  release_fs
else
  bad "cannot read the ESP"
fi

echo "  3b. boot-a (slot A's entries and files)"
if use_fs "${DEV[retroforge-boot-A]}" "$T/boot-a"; then
  boota="$USE_PATH"
  # Slot A's entry with every try left, naming THIS disk's partitions. On an internal install the
  # partitions were appended to somebody else's GPT, so an entry that names a card's UUIDs (or none)
  # is a boot failure with no diagnostic, on a device with no serial console.
  for entry in "$boota/loader/entries/retroforge-a+3.conf" "$boota/loader/entries/retroforge-debug-a.conf"; do
    e="${entry#"$boota"}"
    if [ ! -s "$entry" ]; then bad "$e missing"; continue; fi
    ok "$e present"
    for name in retroforge-root-A retroforge-var-A; do
      u="$(part_uuid "$DISK" "${IDX[$name]}")"
      case "$name" in
        *root*) key=root ;; *) key=retroforge.var ;;
      esac
      grep -q "^options .* $key=PARTUUID=$u\( \|$\)" "$entry" \
        && ok "$e: $key=PARTUUID=$u ($name)" \
        || bad "$e does not name $name as $key=PARTUUID=$u -- it would boot another disk's partition"
    done
    for key in linux initrd; do
      p="$(sed -n "s|^$key ||p" "$entry")"
      [ -n "$p" ] && [ -s "$boota$p" ] && ok "$e: $key $p is on boot-a" || bad "$e names a $key '$p' boot-a does not carry"
    done
    grep -q '^devicetree' "$entry" && bad "$e names a devicetree -- OpenABL's Device model should pick it" \
                                   || ok "$e: no devicetree key"
  done
  grep -q '^title RetroForge (Slot A)$' "$boota/loader/entries/retroforge-a+3.conf" 2>/dev/null \
    && ok "the entry is titled RetroForge (Slot A)" || bad "the entry's title is not 'RetroForge (Slot A)'"
  ls "$boota/dtbs/"*.dtb >/dev/null 2>&1 \
    && ok "/dtbs on boot-a carries the DTBs OpenABL installs and lists as Device models" \
    || bad "/dtbs on boot-a is empty -- OpenABL has no devicetree to install for slot A"
  release_fs
else
  bad "cannot read boot-a"
fi

# B is empty after an install: an entry for it would spend boots on a slot with no root.
if use_fs "${DEV[retroforge-boot-B]}" "$T/boot-b"; then
  [ -z "$(ls -A "$USE_PATH/loader/entries" 2>/dev/null)" ] \
    && ok "no entry for slot B" || bad "boot-b carries entries over an empty slot"
  release_fs
else
  bad "cannot read boot-b"
fi

# --- 6. the other OS ------------------------------------------------------------------------------
# The install destroyed userdata's contents by design and promised Android would come back. It only
# does if the partition still looks like Android's to Android: the vendor type GUID, not the Linux
# one a third-party uninstaller leaves behind (issue #56).
echo "  4. the other OS"
ud_idx="$(printf '%s\n' "$rows" | awk '$5 == "userdata" {print $1; exit}')"
if [ -z "$ud_idx" ]; then
  bad "userdata is gone from the table -- Android has no data partition"
else
  ud_type="$(sgdisk -i "$ud_idx" "$DISK" 2>/dev/null | sed -n 's/^Partition GUID code: \([0-9A-Fa-f-]*\).*/\1/p')"
  [ "${ud_type^^}" = "$RETROFORGE_ANDROID_USERDATA_GUID" ] \
    && ok "userdata (p$ud_idx) still carries the Android vendor type" \
    || bad "userdata (p$ud_idx) is typed $ud_type, not $RETROFORGE_ANDROID_USERDATA_GUID -- Android may not recognise it"
fi

# A GPT entry the table no longer uses is what made this disk uninstallable before #56, and the
# carve clears them. Any left here means something rewrote the table after we did.
if gpt_has_dead_entries "$DISK"; then
  bad "the table still carries zeroed GPT entries -- something rewrote it after the carve"
else
  ok "no zeroed GPT entries left behind"
fi

echo
if [ "$FAIL" = 0 ]; then
  echo "[retroforge] install OK on $DISK"
else
  echo "[retroforge] install NOT verified on $DISK -- see the !! lines above" >&2
fi
exit "$FAIL"
