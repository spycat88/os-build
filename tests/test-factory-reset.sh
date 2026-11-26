#!/usr/bin/env bash
# Offline test for /usr/lib/retroforge/factory-reset — the wipe the initramfs runs at the boot after a
# Settings > Factory reset (issue #40, .claude/plans/factory-reset.plan.md).
#
#   tests/test-factory-reset.sh
#
# WHY THIS FILE EXISTS. The reset is the second most destructive program we ship after the RAUC hook:
# it reformats both /var slots and either empties /home around four folders or reformats it, on
# partitions it finds itself. The two things that must never go wrong are WHICH disk (a second card
# carries the same partition names) and WHAT a soft reset keeps (a player's ROMs, BIOS, saves and
# states). Both are asserted on what the run leaves behind, not on what it says.
#
# HOW: the real, shipped script runs through its seams (SYSFS, DEVDIR, RUNDIR, LIBDIR, VAR_SEED), with
# the shipped lib-slotwrite.sh and lib-homestage.sh. Stubbed on PATH, as in tests/test-post-install.sh:
# mount, umount and mkfs.ext4 -- each "filesystem" is a directory under $SB/fs named after its device;
# mount symlinks the mountpoint at it, mkfs.ext4 empties it. tar is the real one, unpacking a small
# seed made here. sysfs is a fake tree holding the boot disk (mmcblk0) and a decoy second card
# (mmcblk1) with the same eight GPT names.
#
# WHAT IT CANNOT COVER: the real mkfs.ext4, vfat rename atomicity, the initramfs's chroot, and a
# power cut on a real card (modelled here as a step that fails). Those are the HW checks of the plan.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RESET="$ROOT/rootfs/overlay/usr/lib/retroforge/factory-reset"
LIBDIR="$ROOT/rootfs/overlay/usr/lib/retroforge/install"
[ -f "$RESET" ] || { echo "no factory-reset: $RESET" >&2; exit 1; }

PASS=0; FAIL=0; CASE=""; SB=""; RC=0; OUT=""
ok()  { PASS=$((PASS+1)); printf '  ok   %s -- %s\n' "$CASE" "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s -- %s\n' "$CASE" "$1"; }

NAMES=(RetroForge retroforge-efi-A retroforge-efi-B retroforge-root-A retroforge-root-B
       retroforge-var-A retroforge-var-B retroforge-home)

sandbox() {
  SB="$(mktemp -d)"
  mkdir -p "$SB"/{bin,dev,fs,log,run,lib,sys/class/block}
  : >"$SB/log/calls"
  # The libraries as the image ships them: lib-slotwrite.sh from the overlay, lib-homestage.sh from
  # image/ (rootfs/lib-assemble-boot.sh installs it next to the other).
  cp "$LIBDIR/lib-slotwrite.sh" "$ROOT/image/lib-homestage.sh" "$SB/lib/"
  local disk n i
  for disk in mmcblk0 mmcblk1; do
    i=0
    for n in "${NAMES[@]}"; do
      i=$((i + 1))
      local p="$SB/sys/devices/platform/mmc/block/$disk/${disk}p$i"
      mkdir -p "$p"
      printf '%s\n' "$i" >"$p/partition"
      printf 'MAJOR=179\nDEVNAME=%sp%s\nDEVTYPE=partition\nPARTN=%s\nPARTNAME=%s\n' "$disk" "$i" "$i" "$n" >"$p/uevent"
      ln -s "../../devices/platform/mmc/block/$disk/${disk}p$i" "$SB/sys/class/block/${disk}p$i"
      : >"$SB/dev/${disk}p$i"
      mkdir -p "$SB/fs/${disk}p$i"
    done
    printf 'DEVNAME=%s\nDEVTYPE=disk\n' "$disk" >"$SB/sys/devices/platform/mmc/block/$disk/uevent"
  done
  # The boot disk: p1 ESP, p6/p7 var-A/B, p8 home. The decoy card gets look-alike content everywhere.
  ESP="$SB/fs/mmcblk0p1"; VA="$SB/fs/mmcblk0p6"; VB="$SB/fs/mmcblk0p7"; HOME_FS="$SB/fs/mmcblk0p8"
  mkdir -p "$ESP/retroforge" "$ESP/EFI/steamos"
  printf 'ORDER=A B\n' >"$ESP/EFI/steamos/grubenv"
  for v in "$VA" "$VB"; do
    mkdir -p "$v/lib/overlays/etc/upper/NetworkManager/system-connections" "$v/lib/bluetooth/AA:BB" "$v/lib/retroforge"
    printf '[wifi]\n' >"$v/lib/overlays/etc/upper/NetworkManager/system-connections/home.nmconnection"
    printf 'old\n' >"$v/lib/overlays/etc/upper/machine-id"
    printf 'old\n' >"$v/lib/retroforge/slot"
  done
  mkdir -p "$HOME_FS/player"/{roms/nds,bios,saves/nds,states/nds,.config/retroforge,.local/share/Steam,emulators/dsperate,.ssh} \
           "$HOME_FS/.retroforge/offload/var/log" "$HOME_FS/lost+found"
  printf 'rom\n'   >"$HOME_FS/player/roms/nds/game.nds"
  printf 'bios\n'  >"$HOME_FS/player/bios/bios7.bin"
  printf 'sav\n'   >"$HOME_FS/player/saves/nds/game.sav"
  printf 'state\n' >"$HOME_FS/player/states/nds/game.st1"
  printf 'token\n' >"$HOME_FS/player/.config/retroforge/retroachievements.json"
  printf 'k\n'     >"$HOME_FS/player/.ssh/authorized_keys"
  printf 'x\n'     >"$HOME_FS/player/.bash_history"
  printf 'log\n'   >"$HOME_FS/.retroforge/offload/var/log/journal"
  for d in "$SB"/fs/mmcblk1p*; do printf 'DECOY %s\n' "${d##*/}" >"$d/decoy"; done
  mkdir -p "$SB/fs/mmcblk1p1/retroforge" "$SB/fs/mmcblk1p8/player/roms"
  printf 'decoy-rom\n' >"$SB/fs/mmcblk1p8/player/roms/other.nds"

  # The /var seed, as rootfs/assemble-rootfs.sh packs it (no lib/retroforge/slot inside).
  mkdir -p "$SB/seed/lib/overlays/etc/upper" "$SB/seed/lib/overlays/etc/work" "$SB/seed/lib/pacman/local" "$SB/seed/tmp"
  printf 'db\n' >"$SB/seed/lib/pacman/local/ALPM_DB_VERSION"
  tar --zstd -cf "$SB/var-seed.tar.zst" -C "$SB/seed" . || { echo "cannot pack a test seed (tar --zstd)" >&2; exit 1; }

  write_stubs
}
done_() { rm -rf "$SB"; }
t() { CASE="$1"; sandbox; }

write_stubs() {
  cat >"$SB/bin/mount" <<EOF
#!/bin/sh
echo "mount \$*" >>"$SB/log/calls"
[ -e "$SB/fail-mount" ] && exit 32
prev=; last=
for a in "\$@"; do prev=\$last; last=\$a; done
back="$SB/fs/\${prev##*/}"
[ -d "\$back" ] || { echo "mount: no filesystem on \$prev" >&2; exit 32; }
rm -rf "\$last"; ln -s "\$back" "\$last"
EOF
  cat >"$SB/bin/umount" <<EOF
#!/bin/sh
echo "umount \$*" >>"$SB/log/calls"
[ -L "\$1" ] || { echo "umount: \$1: not mounted" >&2; exit 32; }
rm -f "\$1"
EOF
  cat >"$SB/bin/mkfs.ext4" <<EOF
#!/bin/sh
echo "mkfs.ext4 \$*" >>"$SB/log/calls"
last=
for a in "\$@"; do last=\$a; done
[ -e "$SB/fail-mkfs-\${last##*/}" ] && exit 1
rm -rf "$SB/fs/\${last##*/}"; mkdir -p "$SB/fs/\${last##*/}"
EOF
  chmod +x "$SB"/bin/*
}

request() {  # <file content>
  printf '%b' "$1" >"$ESP/retroforge/factory-reset"
}

run() {
  OUT="$(PATH="$SB/bin:$PATH" SYSFS="$SB/sys" DEVDIR="$SB/dev" RUNDIR="$SB/run/reset" LIBDIR="$SB/lib" \
    VAR_SEED="$SB/var-seed.tar.zst" PLAYER_UID="$(id -u)" PLAYER_GID="$(id -g)" \
    bash "$RESET" "$@" 2>&1)"
  RC=$?
}

tree() { (cd "$1" && find . -mindepth 1 | LC_ALL=C sort | tr '\n' ' '); }
decoy_untouched() {
  local d bad_=""
  for d in "$SB"/fs/mmcblk1p*; do grep -qx "DECOY ${d##*/}" "$d/decoy" 2>/dev/null || bad_="$bad_ ${d##*/}"; done
  [ -f "$SB/fs/mmcblk1p8/player/roms/other.nds" ] || bad_="$bad_ decoy-rom"
  grep -q 'mmcblk1' "$SB/log/calls" && bad_="$bad_ (a call named mmcblk1)"
  [ -z "$bad_" ]
}
var_is_seed() {  # <var fs dir> <slot>
  [ "$(cat "$1/lib/retroforge/slot" 2>/dev/null)" = "$2" ] && [ -f "$1/lib/pacman/local/ALPM_DB_VERSION" ] \
    && [ ! -e "$1/lib/overlays/etc/upper/machine-id" ] && [ ! -e "$1/lib/bluetooth" ] \
    && [ -d "$1/lib/overlays/etc/work" ]
}

# =================================================================================================
t "no request"
run --var-dev /dev/mmcblk0p6
[ "$RC" = 0 ] && ! grep -q mkfs "$SB/log/calls" && [ -f "$HOME_FS/player/.ssh/authorized_keys" ] \
  && [ -f "$VA/lib/overlays/etc/upper/machine-id" ] \
  && ok "exit 0, nothing formatted or removed" || bad "rc=$RC $OUT"
[ "$(grep -c '^umount' "$SB/log/calls")" = 1 ] && [ ! -L "$SB/run/reset/esp" ] \
  && ok "the ESP is unmounted again" || bad "calls: $(tr '\n' '|' <"$SB/log/calls")"
done_

# =================================================================================================
t "soft reset"
request 'level=soft\nnonce=n1\n'
run --var-dev /dev/mmcblk0p6
[ "$RC" = 0 ] && ok "exit 0" || bad "rc=$RC $OUT"
[ "$(tree "$HOME_FS")" = "./lost+found ./player ./player/.config ./player/.local ./player/.local/share ./player/bios ./player/bios/bios7.bin ./player/roms ./player/roms/nds ./player/roms/nds/game.nds ./player/saves ./player/saves/nds ./player/saves/nds/game.sav ./player/states ./player/states/nds ./player/states/nds/game.st1 " ] \
  && ok "home: the four shares kept with their files, a fresh .config/.local/share, nothing else" \
  || bad "home left: $(tree "$HOME_FS")"
[ "$(stat -c %a "$HOME_FS/player")" = 700 ] && ok "the player home is 0700 again (stage_player_home)" || bad "mode $(stat -c %a "$HOME_FS/player")"
! grep -q "mkfs.ext4 .*mmcblk0p8" "$SB/log/calls" && ok "home is not reformatted" || bad "home was reformatted"
var_is_seed "$VA" A && var_is_seed "$VB" B && ok "var-A and var-B are the seed, slot files A and B, Wi-Fi and pairings gone" \
  || bad "var-A: $(tree "$VA") var-B: $(tree "$VB")"
[ ! -e "$ESP/retroforge/factory-reset" ] && [ -f "$ESP/EFI/steamos/grubenv" ] \
  && ok "the request is gone, the rest of the ESP untouched" || bad "ESP: $(tree "$ESP")"
decoy_untouched && ok "the second card is untouched (no call names it)" || bad "decoy touched: $(tr '\n' '|' <"$SB/log/calls")"
[ ! -L "$SB/run/reset/esp" ] && [ ! -L "$SB/run/reset/home" ] && [ ! -L "$SB/run/reset/var" ] \
  && ok "nothing left mounted" || bad "mounts left: $(ls -l "$SB/run/reset")"
done_

# =================================================================================================
t "hard reset"
request 'level=hard\nnonce=n2\n'
run --var-dev /dev/mmcblk0p6
[ "$RC" = 0 ] && ok "exit 0" || bad "rc=$RC $OUT"
grep -q "^mkfs.ext4 -q -F -L retroforge-home -m0 $SB/dev/mmcblk0p8\$" "$SB/log/calls" \
  && ok "home reformatted with the installer's mkfs_home" || bad "calls: $(grep mkfs "$SB/log/calls" | tr '\n' '|')"
[ "$(tree "$HOME_FS")" = "./player ./player/.config ./player/.local ./player/.local/share " ] \
  && ok "home: an empty staged player home, ROMs included gone" || bad "home left: $(tree "$HOME_FS")"
var_is_seed "$VA" A && var_is_seed "$VB" B && ok "both var slots reseeded" || bad "var not reseeded"
[ ! -e "$ESP/retroforge/factory-reset" ] && ok "the request is gone" || bad "request still there"
decoy_untouched && ok "the second card is untouched" || bad "decoy touched"
done_

# =================================================================================================
t "interrupted, then resumed"
request 'level=soft\nnonce=n3\n'
: >"$SB/fail-mkfs-mmcblk0p7"     # var-B cannot be formatted: the power-cut stand-in
run --var-dev /dev/mmcblk0p6
[ "$RC" = 1 ] && ok "a failing step: exit 1" || bad "rc=$RC $OUT"
[ -f "$ESP/retroforge/factory-reset" ] && grep -qx 'tries=1' "$ESP/retroforge/factory-reset" \
  && grep -qx 'level=soft' "$ESP/retroforge/factory-reset" && grep -qx 'nonce=n3' "$ESP/retroforge/factory-reset" \
  && ok "the request stays, its try counted, level and nonce kept" || bad "request: $(cat "$ESP/retroforge/factory-reset" 2>&1)"
[ ! -L "$SB/run/reset/esp" ] && ok "the ESP is unmounted on the failure path too" || bad "ESP left mounted"
rm -f "$SB/fail-mkfs-mmcblk0p7"
run --var-dev /dev/mmcblk0p6
[ "$RC" = 0 ] && var_is_seed "$VA" A && var_is_seed "$VB" B && [ ! -e "$ESP/retroforge/factory-reset" ] \
  && [ -f "$HOME_FS/player/roms/nds/game.nds" ] && [ ! -e "$HOME_FS/player/.ssh" ] \
  && ok "the next boot redoes the reset to the end" || bad "rc=$RC $OUT"
done_

# =================================================================================================
t "give up after 3 tries"
request 'level=hard\nnonce=n4\ntries=3\n'
run --var-dev /dev/mmcblk0p6
[ "$RC" = 3 ] && ! grep -q mkfs "$SB/log/calls" && [ -f "$HOME_FS/player/roms/nds/game.nds" ] \
  && grep -qx 'tries=3' "$ESP/retroforge/factory-reset" \
  && ok "exit 3, nothing touched, the request left as it was" || bad "rc=$RC $OUT"
done_

# =================================================================================================
t "refusals"
request 'level=everything\n'
run --var-dev /dev/mmcblk0p6
[ "$RC" = 1 ] && ! grep -q mkfs "$SB/log/calls" && [ -f "$HOME_FS/player/.ssh/authorized_keys" ] \
  && [ ! -e "$ESP/retroforge/factory-reset" ] \
  && ok "an unknown level: nothing reset, the request removed (it would log every boot)" || bad "rc=$RC $OUT"
request 'level=hard\n'
run --var-dev /dev/nosuchdev
[ "$RC" = 1 ] && ! grep -q mkfs "$SB/log/calls" && ok "a var device sysfs does not know: refused, nothing touched" || bad "rc=$RC $OUT"
rm "$SB/sys/devices/platform/mmc/block/mmcblk0/mmcblk0p8/partition"
run --var-dev /dev/mmcblk0p6
[ "$RC" = 1 ] && ! grep -q mkfs "$SB/log/calls" && [[ $OUT == *"no retroforge-home on the disk"* ]] \
  && ok "no home on the boot disk: refused, never the second card's" || bad "rc=$RC $OUT"
run
[ "$RC" = 2 ] && ok "no --var-dev: usage, exit 2" || bad "rc=$RC"
done_

echo
echo "test-factory-reset: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
