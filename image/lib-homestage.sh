# shellcheck shell=bash
# retroforge /home staging — the player user's home, built once and used by two writers.
#
# SOURCED, never executed (hence mode 0644, like lib-slotwrite.sh).
#
# WHY THIS FILE EXISTS, and it is the same argument lib-slotwrite.sh opens with: /home is written
# twice -- once by image/make-sdcard.sh into an image at build time, and once by
# installer/retroforge-install onto an internal disk on the device -- and the two must produce the
# same tree. So the layout lives here and both callers ask for it.

if ! declare -F die >/dev/null 2>&1; then
  die() { printf '[lib-homestage] ERROR: %s\n' "$1" >&2; exit 1; }
fi

# uid/gid 1000, baked into the base by rootfs/customize-base.sh. Numeric rather than resolved
# through a passwd file, because neither caller is resolving names through the target's root:
# make-sdcard.sh runs on the build host and the installer writes a disk it did not boot from.
PLAYER_UID=${PLAYER_UID:-1000}
PLAYER_GID=${PLAYER_GID:-1000}

# <home-root> is the directory that becomes the /home FILESYSTEM's root -- a staging dir for
# make-sdcard.sh (which then hands it to `mkfs.ext4 -d`), the mountpoint of the freshly created
# home partition for the installer. So this creates `player/` inside it, not the home itself.
stage_player_home() {  # <home-root>
  local root="$1"
  local playerhome="$root/player"

  [ -d "$root" ] || die "no home root at $root"
  # The home is the player's alone (0700): Steam keeps its saved sign-in in it. The SMB guests reach
  # the shared folders as the player (ksmbd.conf's guest account), and no service of another user
  # reads it. /usr/lib/tmpfiles.d/retroforge-home-private.conf applies the same to existing homes.
  install -d -m 0700 "$playerhome" && install -d -m 0755 "$playerhome/.config" "$playerhome/.local/share" \
    || die "cannot create the player home under $root"

  chown -R "$PLAYER_UID:$PLAYER_GID" "$playerhome" \
    || die "cannot give $playerhome to the player user"
}
