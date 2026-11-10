#!/usr/bin/env bash
# retroforge read-only root assembler — stage `first-boot-storage`.
#
# SOURCED by rootfs/assemble-rootfs.sh, never executed. Split out of it for issue #43; the code
# and its rationale are unchanged.
#
# Carries the grow-home.sh heredoc verbatim -- do not re-indent it.
#
# Reads the assembler's globals rather than taking arguments -- $stage (the staged tree), $ROOT
# (repo root), $OUT (build outputs). Turning ~20 implicit globals into positional parameters is
# where a verbatim move stops being verbatim, so it is deliberately not done.

# STAGE first-boot-storage — the player user's growable home. We dd a fixed image to a card, so we grow on first boot instead. Three pieces:
#  - /etc/fstab mounts the dedicated home partition (/dev/retroforge/retroforge-home, ext4) at /home.
#    nofail so a card without that partition (the old 2-partition test image) still boots.
#  - retroforge-grow-home: a oneshot that extends the home partition (systemd-repart) + its ext4
#    (resize2fs from e2fsprogs, in the base) to fill the device on first boot, before /home mounts.
#  - the player user (uid 1000) is baked into the base /etc (customize-base.sh); /home/player is
#    laid down at image-build time (image/lib-homestage.sh). ROMs, saves and states live on /home.
#  The shared ESP is also fstab-mounted here, at /esp (Phase 5). It is the partition's only mount
#  definition: it is typed basic data (partition-table.txt), which gpt-auto never auto-mounts.
echo "  injecting first-boot storage: /home mount + grow (player user baked in base)"
mkdir -p "$stage/etc"
#
# BOTH ROWS NAME /dev/retroforge/<GPT name>, NOT PARTLABEL=/LABEL=. Every retroforge medium carries the
# same eight GPT names, so with a card inserted in a device installed to internal storage a label
# names whichever disk udev enumerated first — and udev publishes ONE symlink per duplicate name, so
# the loser gets none at all. /dev/retroforge/* is the same set of links scoped to the disk we booted
# from (usr/lib/udev/rules.d/69-retroforge-bootdisk.rules + usr/lib/retroforge/on-boot-disk), which is
# the only disk either of these mounts can correctly mean. It matters most for the ESP: OpenABL counts
# tries in the booted disk's Boot Loader Specification entry names, and RAUC's mark-good resets them
# through this mount. On the wrong ESP the count runs down every boot until OpenABL fails over a
# healthy slot, and the other install's entries are rewritten. Both ESPs look alike, so nothing
# downstream can notice.
if ! grep -q '/dev/retroforge/RETROFORGE' "$stage/etc/fstab" 2>/dev/null; then
  printf '%s\n' \
    '# retroforge shared ESP — loader.conf (the primary slot). Mounted at /esp; it is typed basic' \
    '# data, which gpt-auto never auto-mounts.' \
    '/dev/retroforge/RETROFORGE  /esp  vfat  defaults,nofail,noatime  0 2' \
    >>"$stage/etc/fstab"
fi
# Both slots' boot partitions, where each slot's boot entries, kernel and DTBs live (lib-bls.sh).
# retroforge-bootctl reads and writes the slot state there, for the slot it did NOT boot as much as
# for the one it did, so both are reachable at fixed paths. Automounted: nothing touches them on a
# normal boot until RAUC or mark-good asks. systemd creates the mountpoints under /run itself.
if ! grep -q '/dev/retroforge/retroforge-boot-A' "$stage/etc/fstab" 2>/dev/null; then
  printf '%s\n' \
    '# retroforge per-slot boot partitions: each slot BLS entries, kernel, initramfs and DTBs.' \
    '/dev/retroforge/retroforge-boot-A  /run/retroforge/bootfs/a  vfat  noauto,x-systemd.automount,nofail,noatime  0 0' \
    '/dev/retroforge/retroforge-boot-B  /run/retroforge/bootfs/b  vfat  noauto,x-systemd.automount,nofail,noatime  0 0' \
    >>"$stage/etc/fstab"
fi
if ! grep -q '/dev/retroforge/retroforge-home' "$stage/etc/fstab" 2>/dev/null; then
  printf '%s\n' \
    '# retroforge shared data partition — the player home, ROMs and saves live here.' \
    '# retroforge-grow-home.service grows BOTH the partition (systemd-repart) and the ext4 (resize2fs)' \
    '# before this mounts. x-systemd.growfs stays only as a belt-and-suspenders fallback (a no-op' \
    '# once grow-home has already sized the fs to the partition).' \
    '/dev/retroforge/retroforge-home  /home  ext4  defaults,nofail,x-systemd.growfs  0 2' \
    >>"$stage/etc/fstab"
fi

# Grow the home PARTITION to fill the device with systemd-repart (declarative, online — it issues
# a BLKPG resize so it works while the disk is in use, and relocates the GPT backup header for us).
# The stock systemd-repart.service is initrd-only (no [Install], Before=initrd-root-fs.target) and
# our initramfs carries no systemd to run it, so ship our own unit running the same tool early in
# real-root boot, before /home mounts. repart matches our partition by its discoverable "Linux
# /home" GUID (typecode 8302 in image/partition-table.txt), so it can never touch the root
# partition. That same GUID would make systemd's gpt-auto generator synthesize a competing
# home.mount, so the partition also carries GPT bit 63 ("no-auto") — /etc/fstab below is the one
# and only definition of home.mount.
#
# The ext4 grow used to ride SOLELY on x-systemd.growfs (mount-time). That RACED home.mount: on HW
# the mount+growfs ran before repart's enlargement was visible, so the fs was sized to the flashed
# ~1G while the partition became 8.7G — /home then filled instantly and the session died with
# ENOSPC. Fix: retroforge-grow-home now runs a wrapper that does repart THEN
# resize2fs, ordered Before=home.mount so the fs grow is a race-free OFFLINE resize (partition
# already enlarged, /home not yet mounted). Idempotent — resize2fs is a no-op once the fs fills the
# partition, so it is safe to run every boot; x-systemd.growfs remains only as a fallback.
install -d -m0755 "$stage/usr/lib/repart.d"
cat >"$stage/usr/lib/repart.d/50-retroforge-home.conf" <<'REPART'
[Partition]
# Match the existing /home partition (Linux /home GUID) and grow it to claim free space at the end
# of the disk. No SizeMinBytes/SizeMaxBytes -> repart expands it to take everything available.
Type=home
REPART

install -d -m0755 "$stage/usr/lib/retroforge"
cat >"$stage/usr/lib/retroforge/grow-home.sh" <<'GROW'
#!/bin/sh
# retroforge first-boot grow: enlarge the /home partition to fill the device, THEN grow its ext4.
# Runs from retroforge-grow-home.service, ordered Before=home.mount, so the fs grow is a race-free
# offline resize2fs (partition already enlarged, /home not yet mounted) rather than the mount-time
# x-systemd.growfs that lost a race to home.mount and left the ext4 at the flashed ~1G. Idempotent.
set -eu

# /dev/retroforge/, NOT /dev/disk/by-label/: this script resolves the partition and then hands its
# PARENT DISK to systemd-repart, which writes the GPT. With two retroforge media attached, by-label
# names an arbitrary one, so the by-label version of this line could grow the internal install's
# home partition — and rewrite the internal disk's GPT — while booted off a card. The scoped link
# only ever names a partition on the disk we booted from (69-retroforge-bootdisk.rules).
HOME_DEV=/dev/retroforge/retroforge-home

# Wait for udev to publish the home partition's symlink. Even ordered After systemd-udev-trigger,
# the probe that creates the symlink is async, so poll briefly, and settle the queue only if it has
# still not appeared. Settling FIRST waited out the whole boot-time coldplug -- 2.6s on the Air X,
# on the path to local-fs, on every boot (measured 2026-10-31) -- for one symlink that is usually
# already there. A card without a home partition (nofail / old 2-partition test image) never shows
# it, so give up and no-op (x-systemd.growfs covers any fs at mount) rather than hang boot.
i=0
while [ ! -b "$HOME_DEV" ] && [ "$i" -lt 50 ]; do
  sleep 0.2
  i=$((i + 1))
done
[ -b "$HOME_DEV" ] || udevadm settle --timeout=30 2>/dev/null || true
if [ ! -b "$HOME_DEV" ]; then
  echo "[retroforge-grow-home] no ${HOME_DEV} after settle — nothing to grow (x-systemd.growfs covers any fs)"
  exit 0
fi
HOME_PART=$(readlink -f "$HOME_DEV")

# 1. Grow the partition to fill the disk (systemd-repart, declarative via /usr/lib/repart.d). Pass the
#    parent DISK EXPLICITLY: with no device argument, repart auto-detects the disk from the ROOT fs,
#    which fails on our btrfs root (mounted as the pseudo-device /dev/root — no initramfs) with
#    "Cannot determine correct backing block device". That was the flaky red boot error ("Failed to
#    start ... grow of /home"); deriving the disk from the home partition sidesteps root entirely.
#    Non-fatal: log and press on to resize2fs rather than throwing a boot error if it ever fails.
DISK=$(lsblk -no pkname "$HOME_PART" 2>/dev/null | head -n1)
if [ -n "${DISK:-}" ] && [ -b "/dev/${DISK}" ]; then
  systemd-repart --dry-run=no "/dev/${DISK}" \
    || echo "[retroforge-grow-home] systemd-repart on /dev/${DISK} failed (non-fatal; resize2fs still runs)" >&2
else
  echo "[retroforge-grow-home] could not resolve parent disk of ${HOME_PART} — skipping partition grow" >&2
fi

# Let udev settle so the enlarged partition's size is current before resize2fs.
udevadm settle 2>/dev/null || true

# 2. Grow the ext4 to fill the (now enlarged) partition. No-op once it already fills it; non-fatal so
#    a not-cleanly-unmounted fs can't block boot (x-systemd.growfs is the fallback).
if resize2fs "$HOME_PART"; then
  # The crumb retroforge-grow-home.service is conditioned on: once /home fills the device there is
  # nothing to grow again, so later boots skip the unit outright. It is on /var (mounted by the
  # initramfs, so present when the condition is read), which an OTA copies to the new slot and a
  # reflash starts without.
  mkdir -p /var/lib/retroforge && : >/var/lib/retroforge/home-grown
else
  echo "[retroforge-grow-home] resize2fs skipped/failed (non-fatal)" >&2
fi
GROW
chmod 0755 "$stage/usr/lib/retroforge/grow-home.sh"

install -d -m0755 "$stage/usr/lib/systemd/system"
cat >"$stage/usr/lib/systemd/system/retroforge-grow-home.service" <<'UNIT'
[Unit]
Description=retroforge first-boot grow of /home to fill the storage device (systemd-repart + resize2fs)
Documentation=man:systemd-repart(8)
DefaultDependencies=no
ConditionDirectoryNotEmpty=/usr/lib/repart.d
# Grown once is grown for good: grow-home.sh leaves this crumb when /home fills the device.
ConditionPathExists=!/var/lib/retroforge/home-grown
# After systemd-udev-trigger (block coldplug), else the home partition's by-label symlink isn't
# published yet when we run and the grow no-ops (HW: grow-home ran 1s before "Found device" and
# bailed). Before home.mount (not just local-fs-pre.target): the ext4 resize must complete while
# /home is still unmounted, else it races the mount-time x-systemd.growfs (see grow-home.sh).
After=systemd-udevd.service systemd-udev-trigger.service
Before=home.mount local-fs-pre.target shutdown.target
Conflicts=shutdown.target

[Service]
Type=oneshot
RemainAfterExit=yes
# Wrapper: systemd-repart (grow partition) THEN resize2fs (grow ext4). 76/77 tolerance is inside it.
ExecStart=/usr/lib/retroforge/grow-home.sh

[Install]
WantedBy=sysinit.target
UNIT

# Enable on release: higher-priority preset (60 < 99 stock "disable *") + a build-time symlink
# fallback. The unit runs early (Before=local-fs-pre.target), pulled in via sysinit.target.
install -d -m0755 "$stage/usr/lib/systemd/system-preset"
echo "enable retroforge-grow-home.service" \
  >"$stage/usr/lib/systemd/system-preset/60-retroforge-storage.preset"
install -d -m0755 "$stage/etc/systemd/system/sysinit.target.wants"
ln -sf /usr/lib/systemd/system/retroforge-grow-home.service \
       "$stage/etc/systemd/system/sysinit.target.wants/retroforge-grow-home.service"

# Mask the stock systemd-repart.service. It's static but WantedBy=sysinit.target, so it also auto-runs
# in real-root boot and FAILS the same way our old unit did: with no device argument it can't resolve
# the btrfs /dev/root backing disk ("Cannot determine correct backing block device"), throwing a red
# "Failed to start Repartition Root Disk" every boot. retroforge-grow-home replaces it (explicit disk +
# resize2fs), so silence the duplicate. It STAYS masked now that the initramfs exists: the stock unit
# is initrd-only, and our initramfs is a plain shell script with no systemd in it to run the unit.
ln -sf /dev/null "$stage/etc/systemd/system/systemd-repart.service"
