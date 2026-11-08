#!/usr/bin/env bash
# Offline test for /usr/lib/rauc/post-install.sh — the RAUC handler that turns a freshly written
# slot into a bootable one.
#
#   tests/test-post-install.sh
#
# WHY THIS FILE EXISTS. The hook is the most destructive program we ship: it runs `mkfs.ext4` and
# `btrfstune -f -U` against a partition it picks itself, from the initramfs handoff's slot= -- and
# RAUC's exported slot names are only ever allowed to disagree with that answer, never to supply it.
# It is also the one writer of the slot state (ORDER, <slot>_OK, <slot>_TRY in the ESP's grubenv)
# that acts behind RAUC's back, mid-install. tests/test-bootctl.sh covers the other writer of that
# block; this covers the hook, which nothing else executes before hardware does.
#
# ORDER IS THE POINT. The hook's own header calls its steps load-bearing, and every one of them is
# an ORDERING claim rather than a value: the target is disarmed (<T>_OK=0) before anything is
# touched, the fsid is re-randomised before anything mounts the target (or a mount of the target can
# silently hand you the RUNNING root — same fsid, same devid=1), the slot witness is written after
# the wholesale copy that would otherwise clobber it, the ESP GRUB is the last file written to the
# ESP, and the re-arm (ORDER target-first, <T>_OK=1, <T>_TRY=0) is the last write of all. Values are
# cheap to check by eye; order is not. So every stub appends to one call log and the assertions are
# largely `expect_order`.
#
# HOW IT WORKS: the real, shipped post-install.sh is executed — not a copy — through the test seams
# documented at its head (ESP, EFI, MNT, EFIMNT, VAR, DEVDIR, DEVTEST, EDITENV, BOOTINFO, SHA256).
# GRUBENV is deliberately left at its default, so the suite also pins where the hook looks for the
# block ($ESP/EFI/steamos/grubenv, the `grubenv=` of etc/rauc/system.conf). grub-editenv is stubbed
# through EDITENV: `list` prints the block's key=value lines, `set` edits keys in place and fails on
# a missing file, and every write is logged. Stubbed on PATH: exactly the commands that would touch
# real storage (mount, umount, mkfs.ext4, btrfstune, btrfs, rsync) plus `mountpoint`. Each storage
# stub models the effect the hook depends on — mkfs empties the backing directory, mount exposes it
# at the mountpoint, rsync copies — so what the run actually leaves on the target slot and the ESP
# is asserted, not assumed.
#
# WHAT IT CANNOT COVER, so that nobody reads a green run as more than it is: whether btrfstune's new
# fsid actually stops the kernel aliasing the two roots, whether rsync's real --one-file-system
# skips our offload bind mounts, whether 256M is enough for the copy, whether real grub-editenv
# accepts the writes, and whether the ESP GRUB reads the keys the way they are asserted here. Those
# need the device. On macOS, also not the fsid value itself: there is no /proc/sys/kernel/random/uuid,
# so btrfstune is handed an empty -U and the stub cannot tell. This asserts that the hook asks for
# the right things, in the right order, and refuses to act on a target it cannot prove.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="$ROOT/rootfs/overlay/usr/lib/rauc/post-install.sh"
[ -f "$HOOK" ] || { echo "no post-install hook: $HOOK" >&2; exit 1; }

PASS=0; FAIL=0; CASE=""; SB=""
OUT=""; RC=0; RAUC_SLOTS=""

ok()  { PASS=$((PASS+1)); printf '  ok   %s -- %s\n' "$CASE" "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s -- %s\n' "$CASE" "$1"; }

# GNU stat on the device and in CI, BSD stat on a Mac.
mtime() { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1"; }

# --- sandbox ------------------------------------------------------------------------------------
#
# Slot devices are regular files under $SB/dev (hence DEVTEST=-e), and each one's "filesystem" is a
# directory under $SB/fs named after it. `mount` symlinks the mountpoint at that directory, `umount`
# removes the symlink, `mkfs.ext4` empties it. That is enough to model everything the hook does with
# a mounted slot, and it means a hook that mounted the WRONG device would read and write visibly
# wrong contents rather than passing.
#
# Layout in play, mirroring the device:
#   $SB/efi      = the RUNNING slot's efi partition, mounted at $EFI (EFI/steamos/parts.env)
#   $SB/esp      = the shared ESP, mounted at $ESP (EFI/steamos/grubenv, EFI/BOOT/bootaa64.efi, ...)
#   $SB/var      = the RUNNING /var
#   $SB/run/boot = the initramfs handoff ($BOOTINFO)
#   $SB/fs/retroforge-root-<s>, retroforge-var-<s>, retroforge-efi-<s> = the six slot filesystems

GRUBENV_F=""   # set by sandbox(); the block the hook finds by default under $ESP

sandbox() {
  SB="$(mktemp -d)"
  GRUBENV_F="$SB/esp/EFI/steamos/grubenv"
  mkdir -p "$SB"/{bin,dev,fs,log,run,var,mnt,efimnt} \
           "$SB/esp/EFI/steamos" "$SB/esp/EFI/BOOT" \
           "$SB/efi/EFI/steamos"
  : >"$SB/log/calls"

  touch "$SB"/dev/retroforge-{root,var,efi}-{A,B}
  local s b f
  for s in A B; do
    b="$SB/fs/retroforge-root-$s/usr/lib/retroforge/boot"
    mkdir -p "$b/fonts" "$b/dtbs" \
             "$SB/fs/retroforge-efi-$s/EFI/steamos" \
             "$SB/fs/retroforge-var-$s/lib/retroforge"
    # The boot files inside each installed root, each naming the root and file it came from, so an
    # assertion says exactly which root -- and which slot's grub-<slot>.cfg -- a copy was taken from.
    for f in grub-esp.efi grubaa64.efi grub-a.cfg grub-b.cfg fonts/dejavu-mono.pf2 \
             dtbs/one.dtb dtbs/two.dtb; do
      printf 'ROOT-%s %s\n' "$s" "${f##*/}" >"$b/$f"
    done
    # What the root still ships for an older hook updating into it (rootfs/lib-assemble-boot.sh).
    # This hook must not put any of it on the ESP.
    ln -s grub-esp.efi "$b/steamcl.efi"
    printf '1.%s\n'         "$s" >"$b/steamcl-version"
    printf 'OLD-FONT-%s\n'  "$s" >"$b/fonts/default.pf2"
    # Stale stage 2 on the target efi, so a missed refresh is visible rather than invisible; and the
    # partition's own parts.env, which an update must never take away.
    printf 'OLD-EFI-GRUB-%s\n' "$s" >"$SB/fs/retroforge-efi-$s/EFI/steamos/grubaa64.efi"
    printf 'PARTS-ON-EFI-%s\n' "$s" >"$SB/fs/retroforge-efi-$s/EFI/steamos/parts.env"
    # Stale state on the target /var, so a missing reformat is visible rather than invisible.
    printf 'stale\n' >"$SB/fs/retroforge-var-$s/lib/retroforge/leftover-from-the-last-install"
  done

  # The running efi: the parts.env the ESP is refreshed from, plus the partsets a device upgraded
  # from the steamcl boot chain still carries. Nothing may read or copy those any more.
  printf 'PARTS-ON-RUNNING-EFI\n' >"$SB/efi/EFI/steamos/parts.env"
  mkdir -p "$SB/efi/SteamOS/partsets"
  for f in all shared A B dev; do printf 'partset-%s\n' "$f" >"$SB/efi/SteamOS/partsets/$f"; done
  printf 'A\n' >"$SB/efi/SteamOS/partsets/self"

  # The old ESP GRUB is stale on purpose.
  printf 'OLD-ESP-GRUB\n' >"$SB/esp/EFI/BOOT/bootaa64.efi"

  boot_from A
  seed_var
  write_stubs
}
done_() { rm -rf "$SB"; }
t() { CASE="$1"; RAUC_SLOTS=""; sandbox; }

write_grubenv() {  # <key=value>...
  { printf '# GRUB Environment Block\n'; printf '%s\n' "$@"; } >"$GRUBENV_F"
}

# The initramfs handoff, and the grubenv as RAUC leaves it when it starts the hook: its set-primary
# has already run, so the target is first in ORDER and OK.
boot_from() {  # <A|B>
  local booted="$1" target=A
  [ "$booted" = A ] && target=B
  printf 'slot=%s\nsource=partuuid\n' "$booted" >"$SB/run/boot"
  write_grubenv "ORDER=$target $booted" A_OK=1 A_TRY=0 B_OK=1 B_TRY=0
}

# A running /var with the pieces that have to survive an update, plus the two that must not.
seed_var() {
  mkdir -p "$SB/var/lib/retroforge" \
           "$SB/var/lib/overlays/etc/upper/NetworkManager/system-connections" \
           "$SB/var/lib/overlays/etc/work" "$SB/var/lib/systemd"
  printf 'a\n'          >"$SB/var/lib/retroforge/slot"
  printf 'de:ad:be:ef:00:01\n' >"$SB/var/lib/retroforge/mac-wifi"
  printf '7070e56b\n'   >"$SB/var/lib/overlays/etc/upper/machine-id"
  printf '[wifi]\n'     >"$SB/var/lib/overlays/etc/upper/NetworkManager/system-connections/home.nmconnection"
  printf 'ssh-ed25519\n' >"$SB/var/lib/overlays/etc/upper/ssh_host_ed25519_key"
  printf 'seed\n'       >"$SB/var/lib/systemd/random-seed"
}

write_stubs() {
  cat >"$SB/bin/mount" <<'EOF'
#!/bin/sh
echo "mount $*" >>"$SB/log/calls"
[ -e "$SB/fail-mount" ] && exit 32
prev=; last=
for a in "$@"; do prev=$last; last=$a; done
back="$SB/fs/${prev##*/}"
[ -d "$back" ] || { echo "mount: no filesystem on ${prev}" >&2; exit 32; }
rm -rf "$last"
ln -s "$back" "$last"
EOF
  cat >"$SB/bin/umount" <<'EOF'
#!/bin/sh
echo "umount $*" >>"$SB/log/calls"
[ -L "$1" ] || { echo "umount: $1: not mounted" >&2; exit 32; }
rm -f "$1"
EOF
  cat >"$SB/bin/mkfs.ext4" <<'EOF'
#!/bin/sh
echo "mkfs.ext4 $*" >>"$SB/log/calls"
[ -e "$SB/fail-mkfs" ] && exit 1
last=
for a in "$@"; do last=$a; done
rm -rf "$SB/fs/${last##*/}"
mkdir -p "$SB/fs/${last##*/}"
EOF
  cat >"$SB/bin/btrfstune" <<'EOF'
#!/bin/sh
echo "btrfstune $*" >>"$SB/log/calls"
[ -e "$SB/fail-btrfstune" ] && exit 1
exit 0
EOF
  # `btrfs filesystem label` -- the second half of un-sharing the target's identity. The bundle
  # image is slot A's byte for byte, so a raw write leaves BOTH partitions labelled
  # retroforge-root-A until this runs.
  cat >"$SB/bin/btrfs" <<'EOF'
#!/bin/sh
echo "btrfs $*" >>"$SB/log/calls"
[ -e "$SB/fail-btrfs-label" ] && exit 1
exit 0
EOF
  cat >"$SB/bin/rsync" <<'EOF'
#!/bin/sh
echo "rsync $*" >>"$SB/log/calls"
[ -e "$SB/fail-rsync" ] && exit 1
prev=; last=
for a in "$@"; do prev=$last; last=$a; done
cp -a "$prev." "$last" || exit 1
EOF
  cat >"$SB/bin/mountpoint" <<'EOF'
#!/bin/sh
[ -e "$SB/fail-esp" ] && exit 1
exit 0
EOF
  # grub-editenv, reached through the hook's EDITENV seam. The block is kept as its signature line
  # plus key=value lines, which is all `list` shows of a real one. `set` replaces a key in place or
  # appends it, and refuses a file that is not there -- the hook has to find RAUC's block, not make
  # one. Every write is logged for the order assertions; `list` is the suite reading the result, so
  # it is not.
  cat >"$SB/bin/grub-editenv" <<'EOF'
#!/usr/bin/env bash
set -u
f="${1:-}"; cmd="${2:-}"
shift 2 2>/dev/null || shift $#
case "$cmd" in
  list)
    [ -f "$f" ] || { echo "grub-editenv: $f: No such file or directory" >&2; exit 1; }
    sed '/^#/d' "$f" ;;
  set)
    echo "grub-editenv $f set $*" >>"$SB/log/calls"
    [ -f "$f" ] || { echo "grub-editenv: $f: No such file or directory" >&2; exit 1; }
    [ -e "$SB/fail-editenv" ] && { echo "grub-editenv stub: failing on purpose" >&2; exit 1; }
    if [ -e "$SB/fail-rearm" ]; then
      for kv in "$@"; do
        case "$kv" in ORDER=*) echo "grub-editenv stub: failing the re-arm on purpose" >&2; exit 1 ;; esac
      done
    fi
    for kv in "$@"; do
      case "$kv" in *=*) ;; *) echo "grub-editenv stub: '$kv' is not key=value" >&2; exit 2 ;; esac
      k="${kv%%=*}"
      if grep -q "^$k=" "$f"; then
        awk -v k="$k=" -v kv="$kv" 'index($0, k) == 1 { print kv; next } { print }' "$f" >"$f.tmp"
      else
        { cat "$f"; printf '%s\n' "$kv"; } >"$f.tmp"
      fi
      mv "$f.tmp" "$f"
    done ;;
  *)
    echo "grub-editenv $f $cmd $*" >>"$SB/log/calls"
    echo "grub-editenv stub: unknown command $cmd" >&2; exit 2 ;;
esac
EOF
  chmod +x "$SB/bin"/*
}

# Run the SHIPPED hook against the sandbox.
run() { # [KEY=VAL ...]  -- leading assignments are passed to the hook, as in test-publish-bundle.sh
  local env_extra=()
  while [ $# -gt 0 ] && [[ $1 == *=* ]]; do env_extra+=("$1"); shift; done
  [ -n "$RAUC_SLOTS" ] && env_extra+=(RAUC_TARGET_SLOTS="$RAUC_SLOTS")
  OUT=$(env PATH="$SB/bin:$PATH" SB="$SB" \
            ESP="$SB/esp" EFI="$SB/efi" MNT="$SB/mnt" EFIMNT="$SB/efimnt" VAR="$SB/var" \
            DEVDIR="$SB/dev" DEVTEST=-e EDITENV="$SB/bin/grub-editenv" BOOTINFO="$SB/run/boot" \
            MOUNTINFO="$SB/mountinfo" SYSDEVBLOCK="$SB/sys" BUNDLEHOME="$SB/home" \
            "${env_extra[@]}" bash "$HOOK" 2>&1)
  RC=$?
  return 0
}

# --- assertions ---------------------------------------------------------------------------------

expect_rc()  { [ "$RC" = "$1" ] && ok "exit=$1" || bad "exit: expected $1, got $RC (output: $OUT)"; }
expect_has() { case "$OUT" in *"$1"*) ok "says '$1'" ;; *) bad "expected '$1' in output, got: $OUT" ;; esac; }
expect_hasnt() { case "$OUT" in *"$1"*) bad "must not say '$1', got: $OUT" ;; *) ok "does not say '$1'" ;; esac; }

expect_call() {
  grep -q -- "$1" "$SB/log/calls" && ok "called: $1" \
    || bad "expected a call matching '$1'; log was: $(tr '\n' ';' <"$SB/log/calls")"
}
expect_no_call() {
  grep -q -- "$1" "$SB/log/calls" \
    && bad "must not call '$1'; log was: $(tr '\n' ';' <"$SB/log/calls")" || ok "never called: $1"
}
# The assertion this file is mostly made of.
expect_order() {  # <earlier> <later>
  local i j
  i=$(grep -n -m1 -- "$1" "$SB/log/calls" | cut -d: -f1)
  j=$(grep -n -m1 -- "$2" "$SB/log/calls" | cut -d: -f1)
  [ -n "$i" ] || { bad "order: '$1' never happened"; return; }
  [ -n "$j" ] || { bad "order: '$2' never happened"; return; }
  [ "$i" -lt "$j" ] && ok "'$1' before '$2'" || bad "'$1' came AFTER '$2' (lines $i, $j)"
}
# The same, over the hook's own log lines -- the ESP copies are plain cp, so this is where they show.
expect_said_order() {  # <earlier> <later>
  local i j
  i=$(printf '%s\n' "$OUT" | grep -n -m1 -- "$1" | cut -d: -f1)
  j=$(printf '%s\n' "$OUT" | grep -n -m1 -- "$2" | cut -d: -f1)
  [ -n "$i" ] || { bad "said order: '$1' never said (output: $OUT)"; return; }
  [ -n "$j" ] || { bad "said order: '$2' never said (output: $OUT)"; return; }
  [ "$i" -lt "$j" ] && ok "said '$1' before '$2'" || bad "said '$1' AFTER '$2' (lines $i, $j)"
}

# The slot state, read back through the stub's `list` the way RAUC would read it.
envval() { SB="$SB" "$SB/bin/grub-editenv" "$GRUBENV_F" list 2>/dev/null | sed -n "s/^$1=//p" | tail -1; }
expect_env() {  # <key> <value>
  local got; got=$(envval "$1")
  [ "$got" = "$2" ] && ok "grubenv $1=$2" || bad "grubenv $1: expected '$2', got '$got'"
}
last_env_write() { grep 'grub-editenv' "$SB/log/calls" | tail -1; }

# Contents of the target slot's filesystems, i.e. what the updated slot will actually boot with.
tvar() { printf '%s' "$SB/fs/retroforge-var-$1"; }
tefi() { printf '%s' "$SB/fs/retroforge-efi-$1"; }
expect_file() {  # <path> <content>
  [ -f "$1" ] || { bad "missing on the target: ${1#"$SB/fs/"}"; return; }
  local got; got=$(cat "$1")
  [ "$got" = "$2" ] && ok "${1#"$SB/fs/"} = '$2'" || bad "${1#"$SB/fs/"}: expected '$2', got '$got'"
}
expect_absent() {
  [ -e "$1" ] && bad "must not exist on the target: ${1#"$SB/fs/"}" || ok "absent: ${1#"$SB/fs/"}"
}
expect_esp() {  # <name> <content>
  [ -f "$SB/esp/$1" ] || { bad "no /$1 on the ESP"; return; }
  local got; got=$(cat "$SB/esp/$1")
  [ "$got" = "$2" ] && ok "/$1 = '$2'" || bad "/$1: expected '$2', got '$got'"
}
expect_no_esp() {  # <name>
  [ -e "$SB/esp/$1" ] && bad "must not exist on the ESP: /$1" || ok "not on the ESP: /$1"
}
# Nothing destructive happened and RAUC's own state is exactly as it left it.
expect_untouched() {
  expect_no_call 'grub-editenv'
  expect_no_call 'btrfstune'
  expect_no_call 'mkfs.ext4'
  expect_no_call 'mount'
  expect_env B_OK 1
  expect_esp EFI/BOOT/bootaa64.efi 'OLD-ESP-GRUB'
}
# Disarmed, and never re-armed: the ESP GRUB skips a slot that is not OK.
expect_nothing_armed() {
  expect_env B_OK 0
  expect_env B_TRY 0
  expect_no_call 'set ORDER='
  expect_hasnt 're-armed for a trial boot'
}

echo "== which slot: the initramfs handoff decides, RAUC only gets to disagree =="

t "the-target-is-the-slot-we-did-not-boot"
run
expect_rc 0
expect_has "target slot B"
expect_call 'grub-editenv .*set B_OK=0 B_TRY=0'
expect_call 'btrfstune .*retroforge-root-B'
expect_call 'btrfs filesystem label .*retroforge-root-B retroforge-root-B'
expect_call 'mkfs.ext4 .*retroforge-var-B'
expect_call "mount $SB/dev/retroforge-efi-B"
expect_env ORDER 'B A'
done_

t "a-handoff-naming-b-targets-a"
boot_from B
run
expect_rc 0
expect_has "target slot A"
expect_call 'grub-editenv .*set A_OK=0 A_TRY=0'
expect_call 'btrfstune .*retroforge-root-A'
expect_call 'btrfs filesystem label .*retroforge-root-A retroforge-root-A'
expect_call 'mkfs.ext4 .*retroforge-var-A'
expect_file "$(tefi A)/EFI/steamos/grub.cfg" 'ROOT-A grub-a.cfg'
expect_esp EFI/BOOT/bootaa64.efi 'ROOT-A grub-esp.efi'
expect_env ORDER 'A B'
expect_env A_OK 1
expect_env B_OK 1                # the running slot's values are not the hook's to move
expect_no_call 'retroforge-root-B'
expect_no_call 'retroforge-var-B'
expect_no_call 'B_OK'
done_

t "the-handoff-outranks-every-older-witness"
# Two things on the device still name a slot and must not get a say: the partsets a device upgraded
# from the steamcl chain carries on its efi (the old answer, through steamos-bootconf this-image),
# and the running /var's slot witness. Both say B here; the handoff says A, so the target is B.
printf 'B\n' >"$SB/efi/SteamOS/partsets/self"
printf 'B\n' >"$SB/var/lib/retroforge/slot"
run
expect_rc 0
expect_has "target slot B"
expect_call 'mkfs.ext4 .*retroforge-var-B'
expect_no_call 'retroforge-var-A'
done_

t "the-running-slot-is-never-touched"
# The failure this rules out is unrecoverable and silent: mkfs on the RUNNING /var. Nothing else in
# the suite would notice, because every other assertion is about the target.
run
expect_rc 0
expect_no_call 'retroforge-var-A'
expect_no_call 'retroforge-root-A'
expect_no_call 'retroforge-efi-A'
expect_no_call 'A_OK'
expect_no_call 'A_TRY'
expect_env A_OK 1
expect_env A_TRY 0
done_

t "rauc-disagreeing-is-fatal"
RAUC_SLOTS="rootfs.0"          # RAUC says it wrote A; we booted A, so the target must be B
run
expect_rc 1
expect_has "refusing"
expect_untouched               # it dies before the disarm, so RAUC's own arming is left as it was
expect_env ORDER 'B A'
done_

t "rauc-agreeing-proceeds"
RAUC_SLOTS="rootfs.1"
run
expect_rc 0
expect_call 'mkfs.ext4 .*retroforge-var-B'
done_

t "an-unrecognised-rauc-slot-name-is-not-a-veto"
# The cross-check is RAUC's value against ours, and ours is authoritative. A name we cannot map is
# no evidence of disagreement, so it must not block an install.
RAUC_SLOTS="rootfs.9"
run
expect_rc 0
expect_call 'mkfs.ext4 .*retroforge-var-B'
done_

t "a-boot-that-resolved-no-slot-is-refused"
# The cmdline-fallback boot records a handoff with no slot=. There is no safe guess here: picking
# wrong reformats the running system's /var.
printf 'source=cmdline-fallback\n' >"$SB/run/boot"
run
expect_rc 1
expect_has "no slot= in"
expect_untouched
done_

t "a-slot-that-is-not-an-image-name-is-refused"
printf 'slot=dev\nsource=partuuid\n' >"$SB/run/boot"
run
expect_rc 1
expect_has "no slot= in"
expect_untouched
done_

t "a-boot-with-no-handoff-at-all-is-refused"
rm -f "$SB/run/boot"
run
expect_rc 1
expect_has "no slot= in"
expect_untouched
done_

t "a-missing-slot-device-is-refused-before-anything-is-touched"
rm -f "$SB/dev/retroforge-var-B"
run
expect_rc 1
expect_has "no block device"
expect_untouched               # the device checks run before the disarm too
done_

echo "== preflight: every tool the run needs is asserted before step 0 =="

t "a-missing-hasher-dies-before-anything-destructive"
# The preflight exists because the two ways of losing the comparator fail in OPPOSITE directions and
# only one of them is survivable. A missing `cmp` (what shipped until 2026-08-05) exits non-zero, so
# the guard degrades to always-copy: wasteful, but the bytes end up right. A missing hasher inside
# $(...) yields two EMPTY strings that compare equal, so the ESP is never refreshed at all and a new
# root boots against the old ESP GRUB. That one is silent and wrong, hence a hard assertion.
#
# It has to fire before step 0. By the use site in step 3 the target's fsid is randomised and its
# /var reformatted, so dying there leaves an unbootable slot and a run that cannot simply be redone.
run SHA256=retroforge-no-such-hasher
expect_rc 1
expect_has "retroforge-no-such-hasher is missing"
expect_untouched
done_

t "a-missing-editenv-dies-before-anything-destructive"
# Without grub-editenv the hook can neither disarm nor re-arm. Found out at step 4, that is a slot
# fully prepared and never armed; found out at step 0, it is still a run that cannot be made safe.
run EDITENV=retroforge-no-such-editenv
expect_rc 1
expect_has "retroforge-no-such-editenv is missing"
expect_untouched
done_

t "a-missing-grubenv-dies-before-anything-destructive"
# No block at $ESP/EFI/steamos/grubenv means the ESP is not where it should be, or not RAUC's. The
# stub's `set` would refuse too, but the hook must not get as far as asking.
rm -f "$GRUBENV_F"
run
expect_rc 1
expect_has "no grubenv at $SB/esp/EFI/steamos/grubenv"
expect_no_call 'grub-editenv'
expect_no_call 'btrfstune'
expect_no_call 'mkfs.ext4'
[ -e "$GRUBENV_F" ] && bad "a grubenv was created" || ok "no grubenv was created"
expect_esp EFI/BOOT/bootaa64.efi 'OLD-ESP-GRUB'
done_

echo "== order: every step of the header, as an assertion =="

t "the-target-is-disarmed-before-the-fsid-is-touched"
# RAUC's set-primary armed the target before calling us. Step 0 takes that back before anything
# makes the slot half-prepared.
run
expect_rc 0
expect_order 'grub-editenv .*set B_OK=0 B_TRY=0' 'btrfstune'
expect_order 'grub-editenv .*set B_OK=0 B_TRY=0' 'mkfs.ext4'
done_

t "the-fsid-is-randomised-before-anything-mounts-the-target"
# Step 1 exists because until btrfstune has run the target and the running root share an fsid AND
# devid=1, and mounting the target can hand you the running root. Every later step mounts it.
run
expect_rc 0
expect_order 'btrfstune' 'mount -o ro'
expect_call 'btrfstune -f -U'
done_

t "var-is-reformatted-before-it-is-copied-into"
run
expect_rc 0
expect_order 'mkfs.ext4' 'rsync'
expect_order 'mkfs.ext4' "mount $SB/dev/retroforge-var-B"
done_

t "the-target-var-is-unmounted-before-the-root-is-mounted"
run
expect_rc 0
expect_order "umount $SB/mnt" 'mount -o ro'
done_

t "the-esp-grub-is-the-last-file-written-to-the-esp"
# ABL starts /EFI/BOOT/bootaa64.efi if it is there, and the shared ESP has no A/B copy behind it, so
# the one file with nothing to roll back to goes after everything the ESP GRUB reads.
run
expect_rc 0
expect_said_order 'refreshed .*/EFI/steamos/parts.env' 'refreshed .*/EFI/BOOT/bootaa64.efi'
expect_said_order 'refreshed .*/dtbs/qcom/two.dtb'     'refreshed .*/EFI/BOOT/bootaa64.efi'
done_

t "the-re-arm-is-the-last-grubenv-write"
# Two writes and only two: the disarm and the re-arm. The re-arm comes after the target efi is
# written and unmounted and after the ESP GRUB is in place -- the slot is genuinely bootable by then.
run
expect_rc 0
case "$(last_env_write)" in
  *"set ORDER=B A B_OK=1 B_TRY=0") ok "the last grubenv write is the re-arm" ;;
  *) bad "the last grubenv write is not the re-arm: $(last_env_write)" ;;
esac
n=$(grep -c 'grub-editenv' "$SB/log/calls")
[ "$n" = 2 ] && ok "two grubenv writes" || bad "expected 2 grubenv writes, got $n"
expect_order "umount $SB/efimnt" 'set ORDER='
expect_said_order 'refreshed .*/EFI/BOOT/bootaa64.efi' 're-armed for a trial boot'
done_

echo "== /var: wholesale, minus two files named in writing =="

t "the-copy-is-wholesale"
# A whitelist has to be extended for every new piece of per-device state, and forgetting one fails
# silently on a device with no serial console. SSH host keys were the next instance after
# machine-id; there would have been another.
run
expect_rc 0
expect_file "$(tvar B)/lib/overlays/etc/upper/machine-id" '7070e56b'
expect_file "$(tvar B)/lib/overlays/etc/upper/ssh_host_ed25519_key" 'ssh-ed25519'
expect_file "$(tvar B)/lib/systemd/random-seed" 'seed'
done_

t "the-saved-wifi-rides-across"
# docs/worklog/DONE.md rates this brick-class on a RELEASE image: the NetworkManager connections live in the
# /etc overlay's upper dir, which lives in the PER-SLOT /var. A target slot without them boots a
# Wi-Fi-only, headless, serial-console-less device with no network and no way back in.
run
expect_rc 0
expect_file "$(tvar B)/lib/overlays/etc/upper/NetworkManager/system-connections/home.nmconnection" '[wifi]'
done_

t "the-copy-asks-for-the-flags-that-make-it-safe"
# A stub cannot prove real rsync honours these; it can prove we never quietly stop asking.
run
expect_rc 0
expect_call 'rsync -aHAX --numeric-ids --one-file-system'
done_

t "the-reformat-drops-the-previous-installs-state"
run
expect_rc 0
expect_absent "$(tvar B)/lib/retroforge/leftover-from-the-last-install"
expect_call 'mkfs.ext4 .*-L retroforge-var-B'
done_

t "the-slot-witness-is-rewritten-to-the-target"
# /var/lib/retroforge/slot records which image this slot is (A/B). Copied verbatim it would make the
# target agree with a lie, and it must therefore be written AFTER the wholesale copy, not before.
# The copy brought slot=a; the witness must be B.
run
expect_rc 0
expect_file "$(tvar B)/lib/retroforge/slot" 'B'
done_

t "the-mac-seed-does-not-survive-the-copy"
# Write-once and outranks the derivation, so a unit flashed before the MAC-collision fix keeps a
# colliding address forever unless an update clears it. Deleting it re-derives from the machine-id
# the copy just carried over — same id, same MAC, so a healthy device sees no change.
run
expect_rc 0
expect_absent "$(tvar B)/lib/retroforge/mac-wifi"
expect_file "$(tvar B)/lib/overlays/etc/upper/machine-id" '7070e56b'
done_

t "a-stale-pairing-enable-link-does-not-survive-the-copy"
# Pairing was always on until the shell got its Remote access switch (plan ota-ui D5): a device that
# ran an older image may hold retroforge-pairingd's multi-user.target.wants link in the /etc overlay
# upper, and that upper rides along with /var. Left there it would start the pairing daemon at
# every boot on the updated slot -- keys accepted with nobody having turned pairing on.
mkdir -p "$SB/var/lib/overlays/etc/upper/systemd/system/multi-user.target.wants"
ln -s /usr/lib/systemd/system/retroforge-pairingd.service \
  "$SB/var/lib/overlays/etc/upper/systemd/system/multi-user.target.wants/retroforge-pairingd.service"
ln -s /usr/lib/systemd/system/sshd.service \
  "$SB/var/lib/overlays/etc/upper/systemd/system/multi-user.target.wants/sshd.service"
run
expect_rc 0
link="$(tvar B)/lib/overlays/etc/upper/systemd/system/multi-user.target.wants/retroforge-pairingd.service"
{ [ -e "$link" ] || [ -L "$link" ]; } && bad "the pairing enable link survived the update" || ok "the pairing enable link is gone"
[ -L "$(tvar B)/lib/overlays/etc/upper/systemd/system/multi-user.target.wants/sshd.service" ] \
  && ok "other enable links are kept" || bad "sshd's enable link was removed too"
rm -rf "$SB/var/lib/overlays/etc/upper/systemd"
done_

t "the-overlay-dirs-exist-even-if-the-copy-did-not-bring-them"
# The one case that would be unrecoverable: the initramfs mounts /etc from these, so a slot without
# them does not come up at all.
rm -rf "$SB/var/lib/overlays"
run
expect_rc 0
[ -d "$(tvar B)/lib/overlays/etc/upper" ] && ok "upper/ created" || bad "no overlay upper/ on the target"
[ -d "$(tvar B)/lib/overlays/etc/work" ]  && ok "work/ created"  || bad "no overlay work/ on the target"
done_

echo "== stage 2 on the target efi partition =="

t "the-stage-2-comes-out-of-the-new-root"
# Not out of the bundle: grubaa64.efi and grub-<slot>.cfg are boot software owned by the same build
# that ships /boot/vmlinuz.efi and /lib/modules/<ver> inside the rootfs, so taking them from the root
# makes the pairing true by construction. The target efi started with stale OLD-EFI-GRUB content,
# and the root carries both slots' configs, so the grub.cfg must be the TARGET's.
run
expect_rc 0
expect_call 'mount -o ro .*retroforge-root-B'
expect_file "$(tefi B)/EFI/steamos/grubaa64.efi" 'ROOT-B grubaa64.efi'
expect_file "$(tefi B)/EFI/steamos/grub.cfg" 'ROOT-B grub-b.cfg'
expect_file "$(tefi B)/EFI/steamos/fonts/dejavu-mono.pf2" 'ROOT-B dejavu-mono.pf2'
expect_has "stage-2 grub.cfg + font installed on $SB/dev/retroforge-efi-B"
done_

t "the-efi-partition-is-copied-onto-not-wiped"
# parts.env on an efi partition says where this medium's partitions are, written once by whoever
# laid the disk out. An update cannot rebuild it, so it must still be there afterwards.
run
expect_rc 0
expect_file "$(tefi B)/EFI/steamos/parts.env" 'PARTS-ON-EFI-B'
done_

t "the-efi-partition-gets-no-partsets"
# steamcl read SteamOS/partsets off the efi partition; the stage-2 grub.cfg reads parts.env. The
# running efi still carries the old partsets here, and none of it may follow onto the target.
run
expect_rc 0
expect_absent "$(tefi B)/SteamOS"
done_

t "a-root-with-no-stage-2-is-fatal-and-leaves-the-esp-alone"
rm -f "$SB/fs/retroforge-root-B/usr/lib/retroforge/boot/grubaa64.efi"
run
expect_rc 1
expect_has "carries no stage-2 GRUB"
expect_nothing_armed
expect_esp EFI/BOOT/bootaa64.efi 'OLD-ESP-GRUB'
done_

t "a-root-from-before-the-esp-grub-is-refused"
# A root without grub-esp.efi predates the GRUB boot chain: its userspace drives a boot conf the ESP
# GRUB only follows. Going back past the switch is a reflash, so neither its efi partition nor the
# ESP may be written.
rm -f "$SB/fs/retroforge-root-B/usr/lib/retroforge/boot/grub-esp.efi"
run
expect_rc 1
expect_has "predates the GRUB boot chain"
expect_no_call "mount $SB/dev/retroforge-efi-B"
expect_file "$(tefi B)/EFI/steamos/grubaa64.efi" 'OLD-EFI-GRUB-B'
expect_esp EFI/BOOT/bootaa64.efi 'OLD-ESP-GRUB'
expect_no_esp EFI/steamos/parts.env
expect_no_esp dtbs/qcom/one.dtb
expect_nothing_armed
done_

echo "== the shared ESP =="

t "the-esp-grub-is-refreshed-from-the-new-root"
# ABL starts /EFI/BOOT/bootaa64.efi, so that is the copy that matters, and it is the same build as
# the stage 2 just written.
run
expect_rc 0
expect_esp EFI/BOOT/bootaa64.efi 'ROOT-B grub-esp.efi'
expect_has "refreshed $SB/esp/EFI/BOOT/bootaa64.efi"
done_

t "an-identical-esp-grub-is-left-untouched"
# The skip is not an optimisation. The shared ESP is the only write in the whole update with no A/B
# copy behind it, so every needless rewrite of the file ABL starts is a power-cut window with
# nothing to roll back to. Seed the ESP with content already identical to the new root's and assert
# the file is NOT rewritten -- by mtime, because `cp -f` truncates in place and keeps the inode.
#
# WHY THIS CASE EXISTS: the comparison was `cmp -s` from 58e48a8 until 2026-08-05, and cmp is
# diffutils, which is not in PKGS and has never been on the image. On hardware it was "command not
# found" -- a non-zero exit, indistinguishable from "the files differ" -- so the skip never once
# happened in three releases and every OTA rewrote the ESP. run() appends the HOST's PATH after
# $SB/bin and the host has diffutils, which is precisely why a suite asserting only content could
# not see it. Assert the skip itself, not the bytes.
printf 'ROOT-B grub-esp.efi\n' >"$SB/esp/EFI/BOOT/bootaa64.efi"
touch -t 200101010000 "$SB/esp/EFI/BOOT/bootaa64.efi"
before=$(mtime "$SB/esp/EFI/BOOT/bootaa64.efi")
run
expect_rc 0
after=$(mtime "$SB/esp/EFI/BOOT/bootaa64.efi")
[ "$before" = "$after" ] && ok "bootaa64.efi was not rewritten" \
  || bad "bootaa64.efi was rewritten despite identical content"
expect_hasnt "refreshed $SB/esp/EFI/BOOT/bootaa64.efi"
expect_esp EFI/BOOT/bootaa64.efi 'ROOT-B grub-esp.efi'
# The dtbs genuinely changed, so the same run must still refresh them -- a skip that skips
# everything would pass the assertions above and be just as wrong.
expect_esp dtbs/qcom/one.dtb 'ROOT-B one.dtb'
done_

t "the-esp-gets-parts-env-and-the-dtbs"
# parts.env comes from the RUNNING efi (where whoever laid the disk out wrote it), not from the
# target's; OpenABL's \dtbs\qcom comes from the new root.
run
expect_rc 0
expect_esp EFI/steamos/parts.env 'PARTS-ON-RUNNING-EFI'
expect_esp dtbs/qcom/one.dtb 'ROOT-B one.dtb'
expect_esp dtbs/qcom/two.dtb 'ROOT-B two.dtb'
done_

t "no-parts-env-on-the-running-efi-is-not-an-error"
# A medium from before parts.env existed has none to copy, and the ESP GRUB falls back to a card's
# built-in indices. Logged, not fatal.
rm -f "$SB/efi/EFI/steamos/parts.env"
run
expect_rc 0
expect_has "no parts.env on $SB/efi"
expect_no_esp EFI/steamos/parts.env
expect_esp dtbs/qcom/one.dtb 'ROOT-B one.dtb'
expect_esp EFI/BOOT/bootaa64.efi 'ROOT-B grub-esp.efi'
expect_env B_OK 1
done_

t "nothing-of-the-steamcl-chain-goes-onto-the-esp"
# The root still ships steamcl.efi, steamcl-version and fonts/default.pf2 for an older hook updating
# into it. This hook installs the ESP GRUB and nothing else in /EFI/BOOT.
run
expect_rc 0
expect_no_esp EFI/BOOT/steamcl-version
expect_no_esp EFI/BOOT/steamcl-restricted
expect_no_esp EFI/BOOT/fonts
expect_no_esp EFI/retroforge
done_

t "an-esp-that-is-not-mounted-is-fatal"
: >"$SB/fail-esp"
run
expect_rc 1
expect_has "ESP is not mounted"
expect_nothing_armed
expect_esp EFI/BOOT/bootaa64.efi 'OLD-ESP-GRUB'
expect_no_esp EFI/steamos/parts.env
expect_no_esp dtbs/qcom/one.dtb
done_

echo "== the end state, and every way of not reaching it =="

t "a-completed-run-ends-armed-target-first"
# Seeded as a handler run OUTSIDE RAUC would find it -- no set-primary, so the running slot is first
# -- and with tries the target counted while it sat idle. Both belong to the root that was there
# before: the re-arm puts the target first and gives the trial all three of its tries.
write_grubenv 'ORDER=A B' A_OK=1 A_TRY=0 B_OK=1 B_TRY=2
run
expect_rc 0
expect_env ORDER 'B A'
expect_env B_OK 1
expect_env B_TRY 0
expect_env A_OK 1
expect_env A_TRY 0
expect_has "slot B re-armed for a trial boot"
done_

t "the-grubenv-is-edited-not-recreated"
# The block is shared: the stage-2 configs keep the board choice in it (saved_entry) and the ESP
# GRUB its own note (rf_bcsync). The hook moves the target's two values and ORDER, nothing else.
write_grubenv 'ORDER=B A' A_OK=1 A_TRY=0 B_OK=1 B_TRY=0 saved_entry=ayaneo-pocket-ace rf_bcsync=1
run
expect_rc 0
expect_env saved_entry ayaneo-pocket-ace
expect_env rf_bcsync 1
expect_no_call 'grub-editenv .* create'
done_

t "a-failure-at-the-fsid-leaves-nothing-armed"
# The whole point of the disarm. RAUC armed the slot before calling us; between step 0 and the last
# line the target has a freshly mkfs'd /var and no stage 2, so a state pointing at it boots
# nothing. The failure mode has to be "the install failed, run it again", not "one bad boot, hope
# the fall-back fires".
: >"$SB/fail-btrfstune"
run
expect_rc 1
expect_has "fsid"
expect_no_call 'mkfs.ext4'
expect_nothing_armed
done_

t "a-failure-during-the-copy-leaves-nothing-armed"
: >"$SB/fail-rsync"
run
expect_rc 1
expect_nothing_armed
expect_esp EFI/BOOT/bootaa64.efi 'OLD-ESP-GRUB'
done_

t "the-disarm-failing-stops-the-install-before-it-starts"
# If we cannot take RAUC's arming back we cannot make the window safe, and proceeding would spend
# the safety net on a failure we chose to create.
: >"$SB/fail-editenv"
run
expect_rc 1
expect_has "cannot disarm"
expect_no_call 'btrfstune'
expect_no_call 'mkfs.ext4'
expect_no_call 'mount'
done_

t "the-re-arm-failing-is-fatal"
# Everything is in place but the slot is not armed. That has to read as a failed install, not as a
# success that silently never boots the new slot.
: >"$SB/fail-rearm"
run
expect_rc 1
expect_has "cannot re-arm slot B"
expect_call 'set ORDER=B A B_OK=1 B_TRY=0'   # asked for, and refused
expect_env B_OK 0
expect_env B_TRY 0
expect_hasnt 're-armed for a trial boot'
done_

echo "== step 5: the local bundle this install came from is deleted, and nothing else =="

# The kernel's view of a bundle mount, as step 5 reads it: one mountinfo line for RAUC's mount point
# naming a device by major:minor, and that device in a fake /sys/dev/block. `verity` puts dm-verity
# on top of the loop (format=verity, what we ship); `plain` mounts the loop itself; `nbd` is a
# streamed OTA, whose bottom device has no backing file. RAUC_BUNDLE_MOUNT_POINT is what RAUC
# exports to every handler.
BMP=/run/rauc/bundle
bundle_mount() {  # <verity|plain|nbd> [backing file]
  local top=253:3
  [ "$1" = plain ] && top=7:7
  printf '36 25 %s / %s ro,nodev - squashfs /dev/whatever ro\n' "$top" "$BMP" >"$SB/mountinfo"
  case "$1" in
    verity) mkdir -p "$SB/sys/253:3/slaves/loop7/loop"
            printf '%s\n' "$2" >"$SB/sys/253:3/slaves/loop7/loop/backing_file" ;;
    plain)  mkdir -p "$SB/sys/7:7/loop"
            printf '%s\n' "$2" >"$SB/sys/7:7/loop/backing_file" ;;
    nbd)    mkdir -p "$SB/sys/253:3/slaves/nbd0" ;;
  esac
}
new_bundle() {  # <path under $SB/home>
  mkdir -p "$(dirname "$SB/home/$1")"
  printf 'bundle\n' >"$SB/home/$1"
  printf '%s' "$SB/home/$1"
}
expect_gone() { [ -e "$1" ] && bad "still there: ${1#"$SB/"}" || ok "deleted: ${1#"$SB/"}"; }
expect_kept() { [ -f "$1" ] && ok "kept: ${1#"$SB/"}" || bad "deleted, must be kept: ${1#"$SB/"}"; }

t "a-verity-bundle-under-home-is-deleted-after-the-re-arm"
b=$(new_bundle retroforge-1.raucb); bundle_mount verity "$b"
run RAUC_BUNDLE_MOUNT_POINT=$BMP
expect_rc 0
expect_gone "$b"
expect_has "deleted the installed bundle $b"
expect_env B_OK 1
expect_said_order 'deleted the installed bundle' 're-armed for a trial boot'
done_

t "a-plain-bundle-under-home-is-deleted"
b=$(new_bundle player/Downloads/retroforge-2.raucb); bundle_mount plain "$b"
run RAUC_BUNDLE_MOUNT_POINT=$BMP
expect_rc 0
expect_gone "$b"
done_

t "a-streamed-ota-deletes-nothing"
b=$(new_bundle retroforge-3.raucb); bundle_mount nbd
run RAUC_BUNDLE_MOUNT_POINT=$BMP
expect_rc 0
expect_kept "$b"
expect_has "no local bundle file behind this install"
done_

t "no-mount-point-from-rauc-deletes-nothing"
b=$(new_bundle retroforge-4.raucb); bundle_mount verity "$b"
run
expect_rc 0
expect_kept "$b"
done_

t "a-bundle-outside-home-is-kept"
mkdir -p "$SB/media"; printf 'bundle\n' >"$SB/media/retroforge-5.raucb"
bundle_mount verity "$SB/media/retroforge-5.raucb"
run RAUC_BUNDLE_MOUNT_POINT=$BMP
expect_rc 0
expect_kept "$SB/media/retroforge-5.raucb"
expect_has "only a *.raucb under"
done_

t "a-file-not-named-raucb-is-kept"
b=$(new_bundle retroforge-6.img); bundle_mount verity "$b"
run RAUC_BUNDLE_MOUNT_POINT=$BMP
expect_rc 0
expect_kept "$b"
done_

t "nothing-under-home-retroforge-is-touched"
b=$(new_bundle .retroforge/rauc/x.raucb); bundle_mount verity "$b"
run RAUC_BUNDLE_MOUNT_POINT=$BMP
expect_rc 0
expect_kept "$b"
done_

t "a-path-that-now-goes-through-a-symlink-is-kept"
# The loop recorded the path at open time; if a directory in it has since become a symlink, the
# same string names a different file, and that is not the file that was installed.
mkdir -p "$SB/elsewhere"; printf 'bundle\n' >"$SB/elsewhere/retroforge-7.raucb"
mkdir -p "$SB/home"; ln -s "$SB/elsewhere" "$SB/home/link"
bundle_mount verity "$SB/home/link/retroforge-7.raucb"
run RAUC_BUNDLE_MOUNT_POINT=$BMP
expect_rc 0
expect_kept "$SB/elsewhere/retroforge-7.raucb"
done_

t "a-failed-install-keeps-the-bundle"
b=$(new_bundle retroforge-8.raucb); bundle_mount verity "$b"
: >"$SB/fail-rearm"
run RAUC_BUNDLE_MOUNT_POINT=$BMP
expect_rc 1
expect_kept "$b"
done_

# --- summary ------------------------------------------------------------------------------------

echo
printf '%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ] || exit 1
