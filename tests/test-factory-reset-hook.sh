#!/usr/bin/env bash
# Offline test for image/initramfs/factory-reset-hook.sh — the initramfs side of a factory reset
# (issue #40, .claude/plans/factory-reset.plan.md): look for the request on this disk's ESP, and on
# one, run the OS's /usr/lib/retroforge/factory-reset chrooted into the read-only root, then put the
# initramfs back exactly as it was for switch_root.
#
#   tests/test-factory-reset-hook.sh
#
# WHY: the hook runs in the initramfs, where nothing can be debugged (no serial console) and where a
# mistake costs a boot. Its promises are all about what it leaves mounted and what it never stops:
# the ESP read-only and only for a look, the four binds undone in reverse, and a boot that goes on
# whatever the reset did. The wipe itself is tests/test-factory-reset.sh's.
#
# HOW: the real hook is sourced (as init does) with init's log/warn writing to a file; mount, umount
# and chroot are stubs on PATH that log their argv. The ESP "mount" links the mountpoint at a
# directory; chroot prints two lines and exits with $SB/chroot-rc. sysfs is a fake tree with the boot
# disk (mmcblk0) and a decoy second card (mmcblk1) carrying the same partition names. Plus static
# checks that init sources the hook between the root and /var, and that mkinitramfs ships it with the
# binaries it uses.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="$ROOT/image/initramfs/factory-reset-hook.sh"
INIT="$ROOT/image/initramfs/init"
MKI="$ROOT/image/mkinitramfs.sh"
[ -f "$HOOK" ] || { echo "no hook: $HOOK" >&2; exit 1; }

PASS=0; FAIL=0; CASE=""; SB=""
ok()  { PASS=$((PASS+1)); printf '  ok   %s -- %s\n' "$CASE" "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s -- %s\n' "$CASE" "$1"; }

sandbox() {
  SB="$(mktemp -d)"
  mkdir -p "$SB"/{bin,log,run/retroforge/splash,sysroot,espfs/retroforge,sys/class/block}
  : >"$SB/log/calls"; : >"$SB/log/kmsg"
  printf 'Starting RetroForge\n' >"$SB/run/retroforge/splash/status"
  local disk i n
  for disk in mmcblk0 mmcblk1; do
    i=0
    for n in RetroForge retroforge-efi-A retroforge-efi-B retroforge-root-A retroforge-root-B \
             retroforge-var-A retroforge-var-B retroforge-home; do
      i=$((i + 1))
      local p="$SB/sys/devices/mmc/block/$disk/${disk}p$i"
      mkdir -p "$p"; printf '%s\n' "$i" >"$p/partition"
      printf 'MAJOR=179\nDEVNAME=%sp%s\nDEVTYPE=partition\nPARTNAME=%s\n' "$disk" "$i" "$n" >"$p/uevent"
      ln -s "../../devices/mmc/block/$disk/${disk}p$i" "$SB/sys/class/block/${disk}p$i"
    done
  done
  cat >"$SB/bin/mount" <<EOF
#!/bin/bash
echo "mount \$*" >>"$SB/log/calls"
last=\${*: -1:1}
[ -e "$SB/fail-bind-\${last##*/}" ] && exit 32
case " \$* " in
  *" -t vfat "*) [ -e "$SB/fail-esp" ] && exit 32; rm -rf "\${*: -1:1}"; ln -s "$SB/espfs" "\${*: -1:1}" ;;
esac
exit 0
EOF
  cat >"$SB/bin/umount" <<EOF
#!/bin/bash
echo "umount \$*" >>"$SB/log/calls"
[ -L "\$1" ] && rm -f "\$1"
exit 0
EOF
  cat >"$SB/bin/chroot" <<EOF
#!/bin/bash
echo "chroot \$*" >>"$SB/log/calls"
cp "$SB/run/retroforge/splash/status" "$SB/log/status-during"
echo "[factory-reset] soft reset, attempt 1 of 3"
echo "[factory-reset] ERROR: something" >&2
exit \$(cat "$SB/chroot-rc" 2>/dev/null || echo 0)
EOF
  chmod +x "$SB"/bin/*
}
done_() { rm -rf "$SB"; }
t() { CASE="$1"; sandbox; }

run_hook() {  # <var device>
  PATH="$SB/bin:$PATH" RF_SYS="$SB/sys" RF_RUN="$SB/run" RF_DEV=/dev SB="$SB" HOOK="$HOOK" bash -c '
    log()  { printf "<6>retroforge-init: %s\n" "$*" >>"$SB/log/kmsg"; }
    warn() { printf "<3>retroforge-init: %s\n" "$*" >>"$SB/log/kmsg"; }
    . "$HOOK"
    factory_reset_hook "$1" "$SB/sysroot"' _ "$1"
  RC=$?
}
calls() { tr '\n' '|' <"$SB/log/calls"; }

# =================================================================================================
t "no request"
run_hook /dev/mmcblk0p6
[ "$RC" = 0 ] && [ "$(calls)" = "mount -t vfat -o ro /dev/mmcblk0p1 $SB/run/retroforge/reset-esp|umount $SB/run/retroforge/reset-esp|" ] \
  && ok "the boot disk's ESP mounted read-only for a look, unmounted, nothing else" || bad "rc=$RC calls: $(calls)"
[ ! -s "$SB/log/kmsg" ] && ok "silent: no line in kmsg on an ordinary boot" || bad "kmsg: $(cat "$SB/log/kmsg")"
done_

# =================================================================================================
t "a request"
printf 'level=soft\nnonce=n\n' >"$SB/espfs/retroforge/factory-reset"
run_hook /dev/mmcblk0p6
S="$SB/sysroot"
want="mount -t vfat -o ro /dev/mmcblk0p1 $SB/run/retroforge/reset-esp|umount $SB/run/retroforge/reset-esp|"
want+="mount --bind /dev $S/dev|mount --bind /proc $S/proc|mount --bind /sys $S/sys|mount --bind /run $S/run|"
want+="chroot $S /usr/bin/env PATH=/usr/bin:/usr/sbin /usr/lib/retroforge/factory-reset --var-dev /dev/mmcblk0p6|"
want+="umount $S/run|umount $S/sys|umount $S/proc|umount $S/dev|"
[ "$RC" = 0 ] && [ "$(calls)" = "$want" ] \
  && ok "look, unmount, bind dev/proc/sys/run, chroot the reset with the var device, unbind in reverse" \
  || bad "rc=$RC calls: $(calls)"
grep -qx '<6>retroforge-init: \[factory-reset\] soft reset, attempt 1 of 3' "$SB/log/kmsg" \
  && grep -qx '<6>retroforge-init: \[factory-reset\] ERROR: something' "$SB/log/kmsg" \
  && grep -qx '<6>retroforge-init: factory reset done' "$SB/log/kmsg" \
  && ok "the reset's stdout and stderr land in kmsg, then 'done'" || bad "kmsg: $(cat "$SB/log/kmsg")"
[ "$(cat "$SB/log/status-during")" = "Resetting the device" ] && [ "$(cat "$SB/run/retroforge/splash/status")" = "Starting RetroForge" ] \
  && ok "the splash says 'Resetting the device' during the reset, 'Starting RetroForge' after" || bad "splash: $(cat "$SB/log/status-during" 2>&1)"
done_

# =================================================================================================
t "the reset fails or gives up"
printf 'level=hard\n' >"$SB/espfs/retroforge/factory-reset"
echo 1 >"$SB/chroot-rc"
run_hook /dev/mmcblk0p6
[ "$RC" = 0 ] && grep -q '<3>.*factory reset failed (exit 1) -- it runs again at the next boot' "$SB/log/kmsg" \
  && [ "$(grep -c '^umount' "$SB/log/calls")" = 5 ] \
  && ok "exit 1: a warning, every bind undone, the boot goes on" || bad "rc=$RC kmsg: $(cat "$SB/log/kmsg") calls: $(calls)"
: >"$SB/log/kmsg"; : >"$SB/log/calls"; echo 3 >"$SB/chroot-rc"
run_hook /dev/mmcblk0p6
[ "$RC" = 0 ] && grep -q '<3>.*given up after its last try -- booting the device as it is' "$SB/log/kmsg" \
  && ok "exit 3: 'given up', the boot goes on" || bad "rc=$RC kmsg: $(cat "$SB/log/kmsg")"
done_

# =================================================================================================
t "never stops a boot"
printf 'level=soft\n' >"$SB/espfs/retroforge/factory-reset"
: >"$SB/fail-esp"
run_hook /dev/mmcblk0p6
[ "$RC" = 0 ] && ! grep -q chroot "$SB/log/calls" && grep -q '<3>.*cannot mount /dev/mmcblk0p1 to look for a request' "$SB/log/kmsg" \
  && ok "an ESP that will not mount: a warning, no reset, boot on" || bad "rc=$RC calls: $(calls)"
rm -f "$SB/fail-esp"; : >"$SB/log/calls"; : >"$SB/log/kmsg"
: >"$SB/fail-bind-sys"
run_hook /dev/mmcblk0p6
[ "$RC" = 0 ] && ! grep -q '^chroot' "$SB/log/calls" \
  && [ "$(grep '^umount' "$SB/log/calls" | tr '\n' '|')" = "umount $SB/run/retroforge/reset-esp|umount $SB/sysroot/proc|umount $SB/sysroot/dev|" ] \
  && grep -q '<3>.*cannot bind /sys into the root -- not run, the request stays' "$SB/log/kmsg" \
  && ok "a bind that fails: no reset, the binds made so far undone in reverse" || bad "rc=$RC calls: $(calls)"
rm -f "$SB/fail-bind-sys"; : >"$SB/log/calls"; : >"$SB/log/kmsg"
rm "$SB/sys/devices/mmc/block/mmcblk0/mmcblk0p1/partition"
run_hook /dev/mmcblk0p6
[ "$RC" = 0 ] && [ ! -s "$SB/log/calls" ] && grep -q '<3>.*no RetroForge on the disk holding /dev/mmcblk0p6' "$SB/log/kmsg" \
  && ok "no ESP on the boot disk: nothing mounted (never the second card's), boot on" || bad "rc=$RC calls: $(calls)"
: >"$SB/log/calls"; : >"$SB/log/kmsg"
run_hook /dev/nosuchdev
[ "$RC" = 0 ] && [ ! -s "$SB/log/calls" ] && ok "a var device sysfs does not know: nothing mounted, boot on" || bad "rc=$RC calls: $(calls)"
done_

# =================================================================================================
t "the second card"
printf 'level=hard\n' >"$SB/espfs/retroforge/factory-reset"
run_hook /dev/mmcblk1p6
grep -q 'vfat -o ro /dev/mmcblk1p1 ' "$SB/log/calls" && ! grep -q 'mmcblk0' "$SB/log/calls" \
  && ok "the ESP looked at is the one on the var device's own disk" || bad "calls: $(calls)"
done_

# =================================================================================================
CASE="init and mkinitramfs"
root_line=$(grep -n 'mount -t "\$ROOTFSTYPE" -o ro "\$ROOTDEV" "\$SYSROOT"' "$INIT" | head -1 | cut -d: -f1)
hook_line=$(grep -n 'factory_reset_hook "\$_rdev" "\$SYSROOT"' "$INIT" | head -1 | cut -d: -f1)
var_line=$(grep -n 'mount -t ext4 "\$VARDEV" "\$SYSROOT/var"' "$INIT" | head -1 | cut -d: -f1)
[ -n "$root_line" ] && [ -n "$hook_line" ] && [ -n "$var_line" ] && [ "$root_line" -lt "$hook_line" ] && [ "$hook_line" -lt "$var_line" ] \
  && ok "init runs the hook after the root is mounted and before /var is ($root_line < $hook_line < $var_line)" \
  || bad "order: root=$root_line hook=$hook_line var=$var_line"
grep -q '^\s*\. /usr/lib/retroforge/factory-reset-hook.sh' "$INIT" && grep -q 'factory-reset-hook.sh" "$stage/usr/lib/retroforge/factory-reset-hook.sh"' "$MKI" \
  && ok "init sources the hook from where mkinitramfs installs it" || bad "hook path mismatch between init and mkinitramfs"
bins=$(sed -n 's/^BINS=(\(.*\))$/\1/p' "$MKI")
miss=""; for b in mount umount chroot mkdir; do [[ " $bins " == *" $b "* ]] || miss="$miss $b"; done
[ -z "$miss" ] && ok "the initramfs carries mount, umount, chroot and mkdir" || bad "BINS lacks:$miss"
# Outside comments, none of the tools a full system has and the initramfs does not.
foreign=$(sed 's/#.*//' "$HOOK" | grep -oE '(^|[[:space:];|&!(])(cp|rm|mv|sed|awk|grep|find|cat|tr|head|tail|sort|cut|ls|ln|readlink|basename|dirname)[[:space:]]' | tr -d ' ;|&!(' | sort -u | tr '\n' ' ')
[ -z "$foreign" ] && ok "the hook calls no binary the initramfs lacks (bash builtins + mount/umount/chroot/mkdir)" || bad "the hook calls: $foreign"

echo
echo "test-factory-reset-hook: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
