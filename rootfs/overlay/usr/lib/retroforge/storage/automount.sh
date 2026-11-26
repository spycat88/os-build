#!/bin/bash
# Mount an inserted SD card for the session user (ROMs, saves) — the other half of the storage path.
#
# CALLED BY TWO THINGS AND FILTERS FOR NEITHER: block-event.sh (the udev entry point, which has
# already decided this event deserves a mount) and format-device.sh (which has just made the
# filesystem on purpose). Every "should this event be acted on" question — the lock, udevadm settle,
# was-the-media-just-inserted — lives in block-event.sh, so nothing here can misapply one to a
# caller it was not meant for. That separation is not stylistic: holding those checks in this file
# refused the formatter's own post-format mount and left the card unmounted, twice in one afternoon.
#
#   /usr/lib/retroforge/storage/automount.sh add|remove <partition kernel name>
#
# WHY THE OS HAS TO DO THIS AT ALL. The client enumerates drives over UDisks2 — it carries generated
# bindings for the whole API and a CUDisksDrive::ThreadedAdopt — and on this hardware it does notice
# a card: the status bar shows one. What it does NOT do is mount it. Measured 2026-09-02 on an
# internally-installed device: card in, udisksd answering, nothing under /run/media and nothing in
# Settings > Storage.
#
# IT MOUNTS THROUGH UDISKS2 RATHER THAN CALLING mount(8), and that is not ceremony. udisks owns the
# mountpoint namespace the client reads (/run/media/<user>/<label>), applies the filesystem-specific
# option whitelist, and — via as-user — makes the mount belong to the session user rather than to
# root. A hand-rolled mount lands somewhere the client is not looking, with the wrong owner.
#
# THE SESSION USER IS RESOLVED FROM uid 1000, not from `id -u player`. The name is ours to choose and
# the id is pinned in sysusers.d; a udev-triggered unit that dies because a name changed is a card
# that silently stops mounting.
set -euo pipefail

. /usr/lib/retroforge/storage/lib-storage.sh

PROG="${0##*/}"
ACTION="${1:-}"
DEVBASE="${2:-}"
DEVICE="/dev/$DEVBASE"

PLAYER_UID=1000
PLAYER_USER="$(id -nu "$PLAYER_UID" 2>/dev/null || echo player)"

log() { printf '%s: %s\n' "$PROG" "$*" >&2; }

[ -n "$ACTION" ] && [ -n "$DEVBASE" ] || { log "usage: $PROG add|remove <partition>"; exit 22; }

# The [sdcard] network share (etc/ksmbd/ksmbd.conf) serves this path, and it is the card's own root:
# a bind mount of the udisks mount (below). ksmbd resolves a share's path when a client connects, so
# with no card there is no folder and the share cannot be opened at all.
SHARE=/run/retroforge/sdcard
SHARE_UNIT=run-retroforge-sdcard.mount

# --- remove: let udisks tidy up, then drop our compatibility symlink ------------------------------
if [ "$ACTION" = remove ]; then
    # The share's bind mount goes with the card. Its unit is BindsTo= the card and stops on its own;
    # this is a fallback, and ONLY FOR A CARD THAT IS GONE. retroforge-automount@.service is a
    # oneshot without RemainAfterExit, so its ExecStop (this path) runs the moment the add path
    # finishes, with the card still in: the first two versions of the share tore their own bind
    # down here every time (HW 2026-11-26, "Mounted" then "Unmounting" in the same second).
    # Lazy: an SMB client still connected holds the path, and the card is gone either way.
    if [ ! -b "$DEVICE" ] && [ "$(findmnt -rn -o SOURCE --mountpoint "$SHARE" 2>/dev/null | head -n1)" = "$DEVICE" ]; then
        systemctl stop "$SHARE_UNIT" 2>/dev/null || umount -l "$SHARE" 2>/dev/null || true
    fi
    [ -b "$DEVICE" ] || mountpoint -q "$SHARE" 2>/dev/null || rmdir "$SHARE" 2>/dev/null || true
    for link in /run/media/"$DEVBASE" /run/media/retroforge-*; do
        [ -L "$link" ] && [ ! -e "$link" ] && rm -f "$link"
    done
    exit 0
fi

[ "$ACTION" = add ] || { log "unknown action: $ACTION"; exit 22; }
[ -b "$DEVICE" ] || { log "not a block device: $DEVICE"; exit 0; }

DISK="$(storage_disk_of "$DEVICE")" || exit 0

# THE SAME PREDICATES THE FORMATTER USES, for the same reason and in the same order. Mounting is not
# destructive, but adopting a partition off the disk we booted from — or off the vendor's internal
# storage — puts a filesystem the system depends on under the client's management, where the next
# thing offered is a format.
storage_is_sd "$DISK"          || { log "skipping $DEVICE: not a removable SD card"; exit 0; }
storage_is_system_disk "$DISK" && { log "skipping $DEVICE: this system runs from it"; exit 0; }
storage_is_retroforge_partition "$DEVICE" && { log "skipping $DEVICE: a RetroForge system's own partition"; exit 0; }

if findmnt -rn -o SOURCE 2>/dev/null | grep -Fxq "$DEVICE"; then
    log "skipping $DEVICE: already mounted"
    exit 0
fi

# EXT4, EXFAT AND VFAT. Upstream mounted ext4 only, for the Steam library: "We need symlinks for
# Steam for now, so only automount ext4 as that's what Steam will format". That reason does not
# apply to a ROM card: the library reads <card>/roms/<system>/ (the plugin's rom_roots.gd), the
# emulators open a ROM by its path, and exFAT is what nearly every ROM card out there is (and what
# a PC writes without help). udisks gives an exfat/vfat mount uid=/gid= of the as-user on its own,
# so the player owns every file on it; nothing here needs to set that.
#
# Anything else (ntfs, btrfs, f2fs, no filesystem) is still left unmounted.
#
# EXIT 0, where upstream exits 2. Inserting a card from another system is a normal thing for a
# person to do, not a fault, and this runs as a templated systemd unit — a non-zero exit leaves a
# failed unit sitting in `systemctl --failed` for the rest of the boot. That distinction cost this
# branch three rounds of chasing failed units that meant nothing.
FSTYPE="$(lsblk -no FSTYPE "$DEVICE" 2>/dev/null | head -n1 | tr -d '[:space:]')"
case "$FSTYPE" in
    ext4|exfat|vfat) : ;;
    *)  log "skipping $DEVICE: ${FSTYPE:-no filesystem}, not ext4, exfat or vfat (only those cards are automounted)"
        exit 0 ;;
esac

# udisks answers on the system bus and is D-Bus activated, so this call is what starts it — ONCE
# THERE IS A BUS. The unit is ordered After=dbus.socket for that reason; see its header.
# as-user is what puts the mount under /run/media/$PLAYER_USER/ and gives the session ownership of it;
# auth.no_user_interaction because there is no one to ask — this runs from udev, with no session.
#
# STDERR IS KEPT, and that is not a detail. This used to fold stderr into the stdout pipe and then
# sed away everything that was not a mountpoint, so EVERY failure — no bus, no such object, a polkit
# refusal — arrived in the journal as the single line "udisks refused to mount", which named the
# wrong culprit for the one failure that actually happened: at cold boot with a card already in the
# slot, this ran ~8s before dbus-broker was ready and busctl never reached udisks at all
# (HW-caught 2026-09-03). A reason collected and discarded is worse than no reason.
# REPAIR BEFORE MOUNTING, and mount read-only if the repair could not finish. `fsck.ext4 -y` returns
# 0 when the filesystem was clean and 1 when it corrected errors; anything else means it could not
# be made consistent, and mounting such a card read-write is how a card with a damaged journal
# becomes a card with damaged games. Upstream also reported the failure to the Steam client
# (steam://system/devicemountresult); there is no client to tell here, so the read-only mount and
# the journal line are the whole answer.
#
# PER FILESYSTEM. fsck.ext4 -y and fsck.fat -a (dosfstools, in the base) both answer 0 for clean and
# 1 for corrected. exFAT has no checker on the image (exfatprogs does not ship): it mounts unchecked,
# and udisks' own exfat default, errors=remount-ro, is what turns damage found later into a
# read-only card rather than a worse one.
OPTS="noatime"
fsck_rc=0
case "$FSTYPE" in
    ext4)  FSCK=(fsck.ext4 -y) ;;
    vfat)  FSCK=(fsck.fat -a -w) ;;
    *)     FSCK=() ;;
esac
if [ "${#FSCK[@]}" = 0 ]; then
    log "no checker for $FSTYPE on this image; mounting $DEVICE unchecked"
    OPTS="$OPTS,rw"
else
    "${FSCK[@]}" "$DEVICE" || fsck_rc=$?
    if [ "$fsck_rc" != 0 ] && [ "$fsck_rc" != 1 ]; then
        log "${FSCK[0]} could not repair $DEVICE (status $fsck_rc); mounting READ-ONLY"
        OPTS="$OPTS,ro"
    else
        [ "$fsck_rc" = 0 ] || log "${FSCK[0]} corrected errors on $DEVICE"
        OPTS="$OPTS,rw"
    fi
fi

OBJ="/org/freedesktop/UDisks2/block_devices/$DEVBASE"
err="$(mktemp)"

# ONE CALL, NO RETRY. There was a retry loop here for two days, for failures whose cause I had not
# looked for: after a format the unit came back "Object does not exist at path …", and once that was
# retried, "No such interface org.freedesktop.UDisks2.Filesystem on object …". Both were f3probe's
# doing — it writes across the whole device, and what it leaves behind reads to blkid as a
# filesystem, so udev starts this unit for a partition that has none. The fix belongs in the
# formatter, which now zeroes those sectors the moment the probe finishes, exactly as upstream does
# and for the reason upstream gives. A retry here would only have made that quieter.
#
# If a genuine lag ever turns up, it will arrive as a failed unit naming its own reason, which is
# the point of the message below.
mountpoint="$(busctl call --timeout=120 \
    org.freedesktop.UDisks2 "$OBJ" \
    org.freedesktop.UDisks2.Filesystem Mount 'a{sv}' 3 \
    as-user s "$PLAYER_USER" \
    auth.no_user_interaction b true \
    options s "$OPTS" \
    2>"$err" | sed -n 's/^s "\(.*\)"$/\1/p')" || true
reason="$(tr -d '\r' < "$err" | tr '\n' ' ')"; rm -f "$err"

if [ -z "$mountpoint" ]; then
    log "could not mount $DEVICE: ${reason:-no mountpoint returned and no error text}"
    exit 1
fi
log "mounted $DEVICE at $mountpoint ($OPTS)"

# THE MOUNTPOINT MUST BE WRITABLE BY player, or the card mounts and then nothing can install to it.
# root_owner= at mkfs time covers cards WE formatted; this covers everything else — a card formatted
# by another system whose root directory belongs to some other uid. Tested as player rather than
# assumed from the mode bits, because the answer depends on ownership, mode and the filesystem.
if ! setpriv --clear-groups --reuid "$PLAYER_UID" --regid "$PLAYER_UID" test -w "$mountpoint" 2>/dev/null; then
    log "$mountpoint is not writable by $PLAYER_USER; opening it up"
    chmod 777 "$mountpoint" 2>/dev/null || log "could not chmod $mountpoint — installs to this card will fail"
fi

# A COMPATIBILITY SYMLINK UNDER /run/media, which the reference platform also creates and which
# exists because older tooling and user scripts hardcode the older mount point. Named after the
# MOUNTPOINT when the filesystem has a label and after the device otherwise, which is upstream's
# rule; a link named after the device would otherwise shadow the labelled name people actually see.
if [ -n "$FSTYPE" ] && [ -n "${mountpoint##*/}" ] && [ "$(lsblk -no LABEL "$DEVICE" 2>/dev/null | head -n1)" != "" ]; then
    link="/run/media/${mountpoint##*/}"
else
    link="/run/media/$DEVBASE"
fi
[ -d "$link" ] || ln -sfn "$mountpoint" "$link" 2>/dev/null || true

# --- THE ROM FOLDERS ON THE CARD -----------------------------------------------------------------
# The library reads <card>/roms/<system>/ (the plugin's rom_roots.gd, retroforge-scrape's rom_roots).
# Every card mounted read-write gets it, and the system folders ~/roms has, wherever missing, so a
# card put in the slot is ready to fill over the [sdcard] share with no setup (asked for 2026-11-26;
# only cards with a roms folder, or our own formatted ones, used to get any). Ports aside: a port
# only runs from ~/roms/ports. Created as the player, so the folders are theirs on ext4 too (exfat
# and vfat belong to the player by mount option); never fatal, the mount is what matters.
if [[ "$OPTS" == *,rw ]]; then
    card_roms="$mountpoint/roms"
    if [ ! -d "$card_roms" ]; then
        setpriv --clear-groups --reuid "$PLAYER_UID" --regid "$PLAYER_UID" mkdir "$card_roms" 2>/dev/null \
            && log "created $card_roms" || log "could not create $card_roms"
    fi
    if [ -d "$card_roms" ]; then
        player_home="$(getent passwd "$PLAYER_UID" | cut -d: -f6)"
        for sysdir in "${player_home:-/home/$PLAYER_USER}"/roms/*/; do
            sys="$(basename "$sysdir")"
            [ "$sys" = ports ] && continue
            [ -d "$card_roms/$sys" ] && continue
            setpriv --clear-groups --reuid "$PLAYER_UID" --regid "$PLAYER_UID" mkdir "$card_roms/$sys" 2>/dev/null || true
        done
        log "$card_roms holds ROMs: the library lists them while the card is in"
    fi
fi

# --- THE [sdcard] NETWORK SHARE ------------------------------------------------------------------
# The share has to BE the card. It used to be the mount base, /run/media/player, with the card one
# folder down: a folder made at the top of the share landed in /run (tmpfs), not on the card, and
# the share opened with no card in (HW-caught 2026-11-26). The udisks path changes with the label,
# so the card is bind-mounted at the one fixed path the share names.
#
# A MOUNT UNIT, not a bare mount --bind: BindsTo= the card's device unit AND the udisks mount's
# unit, so when the card is pulled out, or unmounted in the UI, systemd takes the bind down with it
# and nothing keeps the card's filesystem mounted behind udisks' back. (The remove path below the
# header must not do it for a card still in: see there.) LazyUnmount, because a connected SMB client holds
# the path and would otherwise make the stop fail. The folder is made 0000 before the mount, so if
# it is ever left behind it can be neither listed nor written; the remove path deletes it.
#
# One card: a second partition, or a second card, does not take the share from the first.
# DEVBASE is a kernel name (mmcblk0p1): no character in it needs escaping in a unit name.
if [[ "$OPTS" == *,rw ]] && ! mountpoint -q "$SHARE" 2>/dev/null; then
    # The udisks mount's unit, by asking systemd (it mangles a path into its mount unit name).
    src_unit="dev-$DEVBASE.device $(systemctl show -P Id -- "$mountpoint" 2>/dev/null || true)"
    mkdir -p "${SHARE%/*}"
    [ -d "$SHARE" ] || mkdir -m 0000 "$SHARE"
    cat > "/run/systemd/system/$SHARE_UNIT" <<UNIT
# Written by $0 for $DEVICE: the [sdcard] network share (etc/ksmbd/ksmbd.conf).
[Unit]
Description=SD card for the sdcard network share
BindsTo=$src_unit
After=$src_unit

[Mount]
What=$mountpoint
Where=$SHARE
Type=none
Options=bind
LazyUnmount=yes
UNIT
    if systemctl daemon-reload && systemctl start "$SHARE_UNIT"; then
        log "$mountpoint is the sdcard network share ($SHARE)"
    else
        log "could not bind $mountpoint at $SHARE: the sdcard network share is unavailable"
    fi
fi

# --- NOBODY IS TOLD ABOUT THE MOUNT beyond udisks itself ----------------------------------------
# The Steam-era announcements (steam://addlibraryfolder after a mount, devicemountresult on a
# failed fsck) went with the client; the reasoning behind dropping them is in git history.
# OpenGamepadUI sees the card through UDisks2 on its own, and the RetroForge plugin finds its roms
# folder by looking (rom_watch.gd polls every few seconds), so no signal is needed for hot swap.
