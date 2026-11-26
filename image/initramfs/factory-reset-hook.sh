# shellcheck shell=bash
# retroforge initramfs — the factory reset hook (issue #40, .claude/plans/factory-reset.plan.md).
#
# SOURCED by image/initramfs/init (installed next to the splash at /usr/lib/retroforge/), after the
# read-only root is mounted and BEFORE /var is: the reset reformats /var, and the /etc overlay that
# lives on it must not be up yet. init's log/warn are used; nothing else of init's is.
#
# The hook only DECIDES and HANDS OVER. It looks for the request (RetroForge:/retroforge/
# factory-reset) on the ESP of the disk that holds the booted /var, and when there is one it runs the
# OS's own /usr/lib/retroforge/factory-reset chrooted into the read-only root: that script has the
# tools the initramfs does not (mkfs.ext4, tar, zstd) and the libraries every other writer of slots
# and homes shares. So this file needs no more of the initramfs than bash builtins, mount, umount and
# chroot (image/mkinitramfs.sh BINS).
#
# NEVER STOPS A BOOT. No ESP, an ESP that will not mount, a bind that fails, a reset that fails or
# gives up: each is a line in /dev/kmsg and the boot goes on. A failed reset keeps its request and
# runs again at the next boot; the script itself caps the attempts (MAX_TRIES), so this cannot loop.
#
# Same disk only: the ESP is found by PARTNAME through sysfs on the disk holding <var device>, not by
# label (no udev here, and a second card carries the same names).
#
# Test seams (tests/test-factory-reset-hook.sh): RF_SYS (/sys), RF_RUN (/run), RF_DEV (/dev); mount,
# umount and chroot on PATH.

# The RetroForge partition on the disk holding <partition device>, printed; fails if none.
reset_esp_of() {  # <partition device>
  local sys=${RF_SYS:-/sys} p k v pname devname diskdir
  # Physical: `cd link/..` would resolve the .. by name, back into class/block.
  diskdir=$(cd -P "$sys/class/block/${1##*/}" 2>/dev/null && cd .. && pwd -P) || return 1
  for p in "$diskdir"/*/; do
    [ -f "$p/partition" ] || continue
    pname=''; devname=''
    while IFS='=' read -r k v; do
      case $k in PARTNAME) pname=$v ;; DEVNAME) devname=$v ;; esac
    done <"$p/uevent"
    if [ "$pname" = RetroForge ] && [ -n "$devname" ]; then
      printf '%s/%s' "${RF_DEV:-/dev}" "$devname"
      return 0
    fi
  done
  return 1
}

reset_splash() {  # <status line>: what the boot splash shows, when it runs
  local d=${RF_RUN:-/run}/retroforge/splash
  [ -d "$d" ] && printf '%s\n' "$1" >"$d/status"
}

factory_reset_hook() {  # <var device> <sysroot>
  local vardev=$1 sysroot=$2 run=${RF_RUN:-/run} esp chk req=0 rc d
  local -a bound=()
  if ! esp=$(reset_esp_of "$vardev"); then
    warn "factory reset: no RetroForge on the disk holding $vardev -- not checked"
    return 0
  fi
  chk=$run/retroforge/reset-esp
  mkdir -p "$chk" || { warn "factory reset: cannot create $chk -- not checked"; return 0; }
  if ! mount -t vfat -o ro "$esp" "$chk"; then
    warn "factory reset: cannot mount $esp to look for a request -- not checked"
    return 0
  fi
  [ -f "$chk/retroforge/factory-reset" ] && req=1
  umount "$chk" || warn "factory reset: cannot unmount $chk"
  [ "$req" = 1 ] || return 0

  log "factory reset requested on $esp: running /usr/lib/retroforge/factory-reset (var $vardev)"
  reset_splash "Resetting the device"
  # What the reset needs of the running system inside the root: device nodes, /proc (mkfs checks
  # what is mounted), /sys (the partitions by name), and a writable /run for its mountpoints.
  for d in dev proc sys run; do
    if ! mount --bind "/$d" "$sysroot/$d"; then
      warn "factory reset: cannot bind /$d into the root -- not run, the request stays"
      break
    fi
    bound+=("$d")
  done
  if [ "${#bound[@]}" = 4 ]; then
    chroot "$sysroot" /usr/bin/env PATH=/usr/bin:/usr/sbin \
        /usr/lib/retroforge/factory-reset --var-dev "$vardev" 2>&1 \
      | while IFS= read -r line; do log "$line"; done
    rc=${PIPESTATUS[0]}
    case $rc in
      0) log "factory reset done" ;;
      3) warn "factory reset: given up after its last try -- booting the device as it is" ;;
      *) warn "factory reset failed (exit $rc) -- it runs again at the next boot" ;;
    esac
  fi
  # Unbound in reverse, so nothing of the initramfs stays mounted in the root at switch_root.
  for ((d = ${#bound[@]} - 1; d >= 0; d--)); do
    umount "$sysroot/${bound[d]}" || warn "factory reset: cannot unmount $sysroot/${bound[d]}"
  done
  reset_splash "Starting RetroForge"
  return 0
}
