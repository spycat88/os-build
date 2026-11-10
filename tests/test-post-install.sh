#!/usr/bin/env bash
# Offline test for /usr/lib/rauc/post-install.sh — the RAUC handler that turns a freshly written
# slot into a bootable one.
#
#   tests/test-post-install.sh
#
# WHY THIS FILE EXISTS. The hook is the most destructive program we ship: it runs `mkfs.ext4` and
# `btrfstune -f -U` against a partition it picks itself, from the initramfs handoff's slot= -- and
# RAUC's exported slot names are only ever allowed to disagree with that answer, never to supply it.
# It is also the one writer of the slot state (the Boot Loader Specification entries on the shared
# ESP, lib-bls.sh) that acts behind RAUC's back, mid-install. tests/test-bootctl.sh covers the other
# writer; this covers the hook, which nothing else executes before hardware does.
#
# ORDER IS THE POINT. Every step in the hook's header is an ORDERING claim rather than a value: the
# target's entry is gone before anything is touched, the fsid is re-randomised before anything
# mounts the target (or a mount of the target can silently hand you the RUNNING root — same fsid,
# same devid=1), the slot witness is written after the wholesale copy that would otherwise clobber
# it, and the target's entry is written back only once its files are on the ESP. So the stubs log
# every call, the storage stubs log which entries were on the ESP at the time, and many assertions
# are `expect_order`.
#
# HOW IT WORKS: the real, shipped post-install.sh is executed — not a copy — through the test seams
# documented at its head (ESP, MNT, VAR, DEVDIR, DEVTEST, BOOTINFO) and lib-bls.sh's (BLKID,
# DT_MODEL). Stubbed on PATH: exactly the commands that would touch real storage (mount, umount,
# mkfs.ext4, btrfstune, btrfs, rsync) plus `mountpoint` and `blkid`. Each storage stub models the
# effect the hook depends on — mkfs empties the backing directory, mount exposes it at the
# mountpoint, rsync copies — so what the run actually leaves on the target slot and the ESP is
# asserted, not assumed.
#
# WHAT IT CANNOT COVER: whether btrfstune's new fsid actually stops the kernel aliasing the two
# roots, whether rsync's real --one-file-system skips our offload bind mounts, and whether OpenABL
# boots the entry written here. Those need the device. This asserts that the hook asks for the right
# things, in the right order, and refuses to act on a target it cannot prove.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="$ROOT/rootfs/overlay/usr/lib/rauc/post-install.sh"
[ -f "$HOOK" ] || { echo "no post-install hook: $HOOK" >&2; exit 1; }

PASS=0; FAIL=0; CASE=""; SB=""
OUT=""; RC=0; RAUC_SLOTS=""

ok()  { PASS=$((PASS+1)); printf '  ok   %s -- %s\n' "$CASE" "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s -- %s\n' "$CASE" "$1"; }

MODEL="ACME Handheld One"

# --- sandbox ------------------------------------------------------------------------------------
#
# Slot devices are regular files under $SB/dev (hence DEVTEST=-e), and each one's "filesystem" is a
# directory under $SB/fs named after it. `mount` symlinks the mountpoint at that directory, `umount`
# removes the symlink, `mkfs.ext4` empties it. A hook that mounted the WRONG device would read and
# write visibly wrong contents rather than passing.
#
# Layout in play, mirroring the device:
#   $SB/esp      = the shared ESP, mounted at $ESP: loader/loader.conf
#   $SB/bootfs/<s>  = slot <s>'s boot partition ($BOOTPARTS/<s>): loader/entries/, vmlinuz-<kver>, ...
#   $SB/var      = the RUNNING /var
#   $SB/run/boot = the initramfs handoff ($BOOTINFO)
#   $SB/model    = the running devicetree's model ($DT_MODEL)
#   $SB/fs/retroforge-root-<s>, retroforge-var-<s>, retroforge-boot-<s> = the six slot filesystems

sandbox() {
  SB="$(mktemp -d)"
  mkdir -p "$SB"/{bin,dev,fs,log,run,var,mnt} "$SB/esp/loader" \
           "$SB/bootfs/a/loader/entries" "$SB/bootfs/b/loader/entries"
  : >"$SB/log/calls"
  touch "$SB"/dev/retroforge-{root,var,boot}-{A,B}
  printf '%s\0' "$MODEL" >"$SB/model"
  local s r b
  for s in A B; do
    r="$SB/fs/retroforge-root-$s"
    b="$r/usr/lib/retroforge/boot"
    mkdir -p "$r/boot" "$b/dtbs" "$SB/fs/retroforge-boot-$s" "$SB/fs/retroforge-var-$s/lib/retroforge"
    # Each file names the root it came from, so an assertion says which root a copy was taken from.
    printf 'ROOT-%s vmlinuz\n' "$s" >"$r/boot/vmlinuz"
    printf 'ROOT-%s initramfs\n'   "$s" >"$r/boot/initramfs-retroforge.img"
    printf 'ROOT-%s one.dtb\n' "$s" >"$b/dtbs/qcs8550-acme-one.dtb"
    printf 'ROOT-%s two.dtb\n' "$s" >"$b/dtbs/qcs8550-acme-two.dtb"
    printf '# id\tname\tdtb\tmodel\tbootargs\n' >"$b/boards.tsv"
    printf 'acme-one\tACME One %s\tqcs8550-acme-one\t%s\tirqaffinity=0-2\n' "$s" "$MODEL" >>"$b/boards.tsv"
    printf 'acme-two\tACME Two\tqcs8550-acme-two\tACME Handheld Two\t\n' >>"$b/boards.tsv"
    printf 'quiet root-%s-cmdline\n' "$s" >"$b/cmdline"
    printf 'version=2.0-%s\nkernel=6.18.4\n' "${s,,}" >"$b/release"
    # Stale state on the target /var, so a missing reformat is visible rather than invisible.
    printf 'stale\n' >"$SB/fs/retroforge-var-$s/lib/retroforge/leftover-from-the-last-install"
    # What the ESP carries for each slot from the build before.
    # What each slot's boot partition carries from the build before: an older kernel version.
    mkdir -p "$SB/bootfs/${s,,}/dtbs"
    printf 'OLD-%s vmlinuz\n' "$s" >"$SB/bootfs/${s,,}/vmlinuz-6.1.0"
    printf 'OLD-%s initramfs\n'   "$s" >"$SB/bootfs/${s,,}/initramfs-6.1.0.img"
    printf 'OLD-%s gone.dtb\n'    "$s" >"$SB/bootfs/${s,,}/dtbs/qcs8550-gone.dtb"
    printf 'OLD-%s-DEBUG\n'       "$s" >"$SB/bootfs/${s,,}/loader/entries/retroforge-debug-${s,,}.conf"
  done
  boot_from A
  seed_var
  write_stubs
}
done_() { rm -rf "$SB"; }
t() { CASE="$1"; RAUC_SLOTS=""; sandbox; }

# The initramfs handoff, and the ESP as RAUC leaves it when it starts the hook: its set-primary has
# already run, so the target's counter is back to +3 and loader.conf's default names it.
boot_from() {  # <A|B>
  local booted="$1" target=A
  [ "$booted" = A ] && target=B
  printf 'slot=%s\nsource=bls\n' "$booted" >"$SB/run/boot"
  rm -f "$SB"/bootfs/[ab]/loader/entries/retroforge-[ab]*.conf
  printf 'RUNNING-%s-ENTRY\n' "$booted" >"$SB/bootfs/${booted,,}/loader/entries/retroforge-${booted,,}+3.conf"
  printf 'OLD-%s-ENTRY\n' "$target"     >"$SB/bootfs/${target,,}/loader/entries/retroforge-${target,,}+3.conf"
  printf 'default retroforge-%s.conf\n' "${target,,}" >"$SB/esp/loader/loader.conf"
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
echo "mount $* entries=[$(ls "$SB/bootfs/a/loader/entries" "$SB/bootfs/b/loader/entries" | grep '^retroforge-[ab]+.*conf$' | sort | tr '\n' ' ')]" >>"$SB/log/calls"
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
echo "btrfstune $* entries=[$(ls "$SB/bootfs/a/loader/entries" "$SB/bootfs/b/loader/entries" | grep '^retroforge-[ab]+.*conf$' | sort | tr '\n' ' ')]" >>"$SB/log/calls"
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
for a in "$@"; do p=$a; done
case "$p" in
  */esp)   [ -e "$SB/fail-esp" ] && exit 1 ;;
  */bootfs/*) [ -e "$SB/fail-boot-${p##*/}" ] && exit 1 ;;
esac
exit 0
EOF
  # blkid, through lib-bls.sh's BLKID seam: a partition's PARTUUID is its device's name, upper case
  # as blkid can print it, so an entry that names the wrong partition says which one.
  cat >"$SB/bin/blkid" <<'EOF'
#!/bin/sh
for a in "$@"; do dev=$a; done
[ -e "$SB/fail-blkid" ] && exit 2
[ -e "$dev" ] || exit 2
basename "$dev" | tr 'a-z' 'A-Z'
EOF
  chmod +x "$SB/bin"/*
}

# Run the SHIPPED hook against the sandbox.
run() { # [KEY=VAL ...]  -- leading assignments are passed to the hook
  local env_extra=()
  while [ $# -gt 0 ] && [[ $1 == *=* ]]; do env_extra+=("$1"); shift; done
  [ -n "$RAUC_SLOTS" ] && env_extra+=(RAUC_TARGET_SLOTS="$RAUC_SLOTS")
  OUT=$(env PATH="$SB/bin:$PATH" SB="$SB" \
            ESP="$SB/esp" BOOTPARTS="$SB/bootfs" MNT="$SB/mnt" VAR="$SB/var" \
            DEVDIR="$SB/dev" DEVTEST=-e BOOTINFO="$SB/run/boot" \
            BLKID=blkid DT_MODEL="$SB/model" \
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
expect_order() {  # <earlier> <later>
  local i j
  i=$(grep -n -m1 -- "$1" "$SB/log/calls" | cut -d: -f1)
  j=$(grep -n -m1 -- "$2" "$SB/log/calls" | cut -d: -f1)
  [ -n "$i" ] || { bad "order: '$1' never happened"; return; }
  [ -n "$j" ] || { bad "order: '$2' never happened"; return; }
  [ "$i" -lt "$j" ] && ok "'$1' before '$2'" || bad "'$1' came AFTER '$2' (lines $i, $j)"
}
expect_said_order() {  # <earlier> <later> -- over the hook's own log lines
  local i j
  i=$(printf '%s\n' "$OUT" | grep -n -m1 -- "$1" | cut -d: -f1)
  j=$(printf '%s\n' "$OUT" | grep -n -m1 -- "$2" | cut -d: -f1)
  [ -n "$i" ] || { bad "said order: '$1' never said (output: $OUT)"; return; }
  [ -n "$j" ] || { bad "said order: '$2' never said (output: $OUT)"; return; }
  [ "$i" -lt "$j" ] && ok "said '$1' before '$2'" || bad "said '$1' AFTER '$2' (lines $i, $j)"
}

# The slot state on the ESP.
entries() { ls "$SB/bootfs/a/loader/entries" "$SB/bootfs/b/loader/entries" | grep '^retroforge-[ab]+.*\.conf$' | sort | tr '\n' ' ' | sed 's/ $//'; }
default_() { sed -n 's/^default //p' "$SB/esp/loader/loader.conf"; }
expect_entries() {  # <space-separated names>
  [ "$(entries)" = "$1" ] && ok "entries: $1" || bad "entries: expected '$1', got '$(entries)'"
}
expect_default() {
  [ "$(default_)" = "$1" ] && ok "loader.conf default $1" || bad "loader.conf default: expected '$1', got '$(default_)'"
}

tvar() { printf '%s' "$SB/fs/retroforge-var-$1"; }
expect_file() {  # <path> <content>
  [ -f "$1" ] || { bad "missing: ${1#"$SB/"}"; return; }
  local got; got=$(cat "$1")
  [ "$got" = "$2" ] && ok "${1#"$SB/"} = '$2'" || bad "${1#"$SB/"}: expected '$2', got '$got'"
}
expect_absent() {
  [ -e "$1" ] && bad "must not exist: ${1#"$SB/"}" || ok "absent: ${1#"$SB/"}"
}
expect_esp() { expect_file "$SB/esp/$1" "$2"; }
expect_boot() { expect_file "$SB/bootfs/$1/$2" "$3"; }  # <a|b> <path> <content>
# Nothing destructive happened and RAUC's own arming is exactly as it left it.
expect_untouched() {
  expect_no_call 'btrfstune'
  expect_no_call 'mkfs.ext4'
  expect_no_call 'mount'
  expect_entries "retroforge-a+3.conf retroforge-b+3.conf"
  expect_boot b vmlinuz-6.1.0 'OLD-B vmlinuz'
}
# The target has no entry, so OpenABL boots the running slot.
expect_nothing_armed() {
  [ -z "$(ls "$SB/bootfs/b/loader/entries" | grep 'conf$')" ] && ok "slot B's partition has no entry" \
    || bad "slot B still has an entry: $(entries)"
  expect_hasnt 're-armed for a trial boot'
}

echo "== which slot: the initramfs handoff decides, RAUC only gets to disagree =="

t "the-target-is-the-slot-we-did-not-boot"
run
expect_rc 0
expect_has "target slot B"
expect_call 'btrfstune .*retroforge-root-B'
expect_call 'btrfs filesystem label .*retroforge-root-B retroforge-root-B'
expect_call 'mkfs.ext4 .*retroforge-var-B'
expect_call "mount -o ro $SB/dev/retroforge-root-B"
expect_entries "retroforge-a+3.conf retroforge-b+3.conf"
expect_default retroforge-b.conf
done_

t "a-handoff-naming-b-targets-a"
boot_from B
run
expect_rc 0
expect_has "target slot A"
expect_call 'btrfstune .*retroforge-root-A'
expect_call 'mkfs.ext4 .*retroforge-var-A'
expect_boot a vmlinuz-6.18.4 'ROOT-A vmlinuz'
expect_boot b vmlinuz-6.1.0 'OLD-B vmlinuz'
expect_default retroforge-a.conf
expect_file "$SB/bootfs/b/loader/entries/retroforge-b+3.conf" 'RUNNING-B-ENTRY'
expect_no_call 'retroforge-root-B'
expect_no_call 'retroforge-var-B'
done_

t "the-handoff-outranks-the-var-witness"
printf 'B\n' >"$SB/var/lib/retroforge/slot"
run
expect_rc 0
expect_has "target slot B"
expect_call 'mkfs.ext4 .*retroforge-var-B'
expect_no_call 'retroforge-var-A'
done_

t "the-running-slot-is-never-touched"
# The failure this rules out is unrecoverable and silent: mkfs on the RUNNING /var, or the running
# slot's entry or kernel replaced.
run
expect_rc 0
expect_no_call 'retroforge-var-A'
expect_no_call 'retroforge-root-A'
expect_no_call 'retroforge-boot-A'
expect_file "$SB/bootfs/a/loader/entries/retroforge-a+3.conf" 'RUNNING-A-ENTRY'
expect_boot a vmlinuz-6.1.0 'OLD-A vmlinuz'
expect_boot a initramfs-6.1.0.img 'OLD-A initramfs'
done_

t "rauc-disagreeing-is-fatal"
RAUC_SLOTS="rootfs.0"          # RAUC says it wrote A; we booted A, so the target must be B
run
expect_rc 1
expect_has "refusing"
expect_untouched               # it dies before the disarm, so RAUC's own arming is left as it was
expect_default retroforge-b.conf
done_

t "rauc-agreeing-proceeds"
RAUC_SLOTS="rootfs.1"
run
expect_rc 0
expect_call 'mkfs.ext4 .*retroforge-var-B'
done_

t "an-unrecognised-rauc-slot-name-is-not-a-veto"
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
printf 'slot=dev\nsource=bls\n' >"$SB/run/boot"
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
expect_untouched
done_

echo "== preflight: everything the entry needs is asserted before step 0 =="

t "a-boot-partition-that-is-not-mounted-dies-before-anything-destructive"
# The automount failed (or the partition is missing): nothing to disarm, nothing to re-arm.
touch "$SB/fail-boot-b"
run
expect_rc 1
expect_has "slot B's boot partition is not mounted"
expect_untouched
done_

t "unreadable-partuuids-die-before-anything-destructive"
touch "$SB/fail-blkid"
run
expect_rc 1
expect_has "cannot read the PARTUUIDs of slot B"
expect_untouched
done_

t "an-unreadable-model-dies-before-anything-destructive"
run DT_MODEL="$SB/no-such-model"
expect_rc 1
expect_has "cannot read this device's devicetree model"
expect_untouched
done_

echo "== order: every step of the header, as an assertion =="

t "the-target-is-disarmed-before-the-fsid-is-touched"
run
expect_rc 0
expect_call 'btrfstune .* entries=\[retroforge-a+3.conf \]'
expect_said_order 'disarmed slot B' 'fsid randomised'
done_

t "the-fsid-is-randomised-before-anything-mounts-the-target"
run
expect_rc 0
expect_order 'btrfstune' 'mount '
expect_order 'btrfs filesystem label' 'mount '
done_

t "var-is-reformatted-before-it-is-copied-into"
run
expect_rc 0
expect_order 'mkfs.ext4' 'rsync'
done_

t "the-target-var-is-unmounted-before-the-root-is-mounted"
run
expect_rc 0
expect_order "umount $SB/mnt" "mount -o ro $SB/dev/retroforge-root-B"
done_

t "the-entry-comes-back-only-after-the-slot-files"
# Until the kernel and initramfs on the ESP are the new root's, an entry for the target would boot
# the old build's kernel against the new root.
run
expect_rc 0
expect_call "mount -o ro $SB/dev/retroforge-root-B .* entries=\[retroforge-a+3.conf \]"
expect_said_order 'installed in' 're-armed for a trial boot'
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

echo "== the shared ESP =="

t "the-slot-files-come-out-of-the-new-root"
# Not out of the bundle: the kernel, initramfs and DTBs ship inside the rootfs, so taking them from
# the root makes the pairing true by construction.
run
expect_rc 0
expect_boot b vmlinuz-6.18.4 'ROOT-B vmlinuz'
expect_boot b initramfs-6.18.4.img 'ROOT-B initramfs'
expect_boot b dtbs/qcs8550-acme-one.dtb 'ROOT-B one.dtb'
expect_boot b dtbs/qcs8550-acme-two.dtb 'ROOT-B two.dtb'
expect_absent "$SB/bootfs/b/dtbs/qcs8550-gone.dtb"
expect_absent "$SB/bootfs/b/vmlinuz-6.1.0"
expect_absent "$SB/bootfs/b/initramfs-6.1.0.img"
[ -z "$(find "$SB/bootfs/b" -name '*.new')" ] && ok "no temporary file left on boot-b" || bad "$(find "$SB/bootfs/b" -name '*.new')"
done_

t "the-esp-gets-nothing-but-the-default"
run
expect_rc 0
[ "$(ls -A "$SB/esp")" = loader ] && [ "$(ls -A "$SB/esp/loader")" = loader.conf ] \
  && ok "the ESP holds loader.conf alone" || bad "the ESP holds $(cd "$SB/esp" && find . -mindepth 1 | tr '\n' ' ')"
done_

t "the-entry-is-written-for-this-board-from-the-new-root"
run
expect_rc 0
e="$SB/bootfs/b/loader/entries/retroforge-b+3.conf"
grep -qx 'title RetroForge (Slot B)' "$e" && ok "titled RetroForge (Slot B)" || bad "$(cat "$e")"
grep -qx 'version 2.0-b' "$e" && ok "the new root's build version" || bad "$(cat "$e")"
grep -qx 'sort-key retroforge' "$e" && ok "sorts with the slot entries" || bad "$(cat "$e")"
grep -qx 'linux /vmlinuz-6.18.4' "$e" && ok "the new root's kernel, by version" || bad "$(cat "$e")"
grep -qx 'initrd /initramfs-6.18.4.img' "$e" && ok "the new root's initramfs, by version" || bad "$(cat "$e")"
grep -q '^devicetree' "$e" && bad "names a devicetree: $(grep devicetree "$e")" || ok "no devicetree: OpenABL's Device model picks it"
grep -qx 'options quiet root-B-cmdline irqaffinity=0-2 root=PARTUUID=retroforge-root-b rootfstype=btrfs rootwait ro retroforge.var=PARTUUID=retroforge-var-b retroforge.slot=B rauc.slot=B' "$e" \
  && ok "the new root's command line, the board's args and slot B's PARTUUIDs" || bad "$(grep options "$e")"
d="$SB/bootfs/b/loader/entries/retroforge-debug-b.conf"
grep -qx 'title RetroForge (Slot B, debug)' "$d" && ok "the debug entry is titled RetroForge (Slot B, debug)" || bad "$(cat "$d")"
grep -q '^sort-key' "$d" && bad "the debug entry has a sort-key: it would rank with the slot entries" \
                         || ok "the debug entry has no sort-key, so it lists after the slot entries"
grep -qx 'linux /vmlinuz-6.18.4' "$d" && ok "the debug entry boots the same kernel" || bad "$(cat "$d")"
grep -qx 'options root-B-cmdline irqaffinity=0-2 root=PARTUUID=retroforge-root-b rootfstype=btrfs rootwait ro retroforge.var=PARTUUID=retroforge-var-b retroforge.slot=B rauc.slot=B loglevel=7 retroforge.splash=0 systemd.show_status=1' "$d" \
  && ok "the debug entry drops quiet and boots verbosely" || bad "$(grep options "$d")"
done_

t "an-unknown-board-leaves-the-esp-alone"
printf 'Somebody Else\0' >"$SB/model"
run
expect_rc 1
expect_has "is not a board that root knows"
expect_boot b vmlinuz-6.1.0 'OLD-B vmlinuz'
expect_file "$SB/bootfs/a/loader/entries/retroforge-a+3.conf" 'RUNNING-A-ENTRY'
expect_nothing_armed
done_

t "a-root-from-before-the-bls-chain-is-refused"
# Going back past the switch is a reflash: such a root has no board table, and its own hook and
# bootctl drive a GRUB state nothing reads any more.
rm -f "$SB/fs/retroforge-root-B/usr/lib/retroforge/boot/boards.tsv"
run
expect_rc 1
expect_has "predates the BLS boot chain"
expect_boot b vmlinuz-6.1.0 'OLD-B vmlinuz'
expect_nothing_armed
done_

t "a-root-with-no-kernel-is-fatal"
rm -f "$SB/fs/retroforge-root-B/boot/vmlinuz"
run
expect_rc 1
expect_has "has no /boot/vmlinuz"
expect_boot b vmlinuz-6.1.0 'OLD-B vmlinuz'
expect_nothing_armed
done_

t "an-esp-that-is-not-mounted-is-fatal"
# Checked before anything is written: the default could not be moved to the new slot.
touch "$SB/fail-esp"
run
expect_rc 1
expect_has "the ESP is not mounted"
expect_untouched
done_

echo "== the end state, and every way of not reaching it =="

t "a-completed-run-ends-armed-with-three-tries"
run
expect_rc 0
expect_entries "retroforge-a+3.conf retroforge-b+3.conf"
expect_default retroforge-b.conf
expect_has "re-armed for a trial boot"
ls "$SB/esp/loader" "$SB/bootfs/b/loader/entries" | grep -q '\.new$' && bad "a temporary file was left on the ESP" \
  || ok "no temporary file left on the ESP"
expect_absent "$SB/mnt/usr"
done_

t "a-target-that-had-run-out-of-tries-gets-them-back"
mv "$SB/bootfs/b/loader/entries/retroforge-b+3.conf" "$SB/bootfs/b/loader/entries/retroforge-b+0-3.conf"
run
expect_rc 0
expect_entries "retroforge-a+3.conf retroforge-b+3.conf"
done_

t "a-handler-run-outside-rauc-still-moves-the-default"
printf 'default retroforge-a.conf\n' >"$SB/esp/loader/loader.conf"
run
expect_rc 0
expect_default retroforge-b.conf
done_

t "a-failure-at-the-fsid-leaves-nothing-armed"
touch "$SB/fail-btrfstune"
run
expect_rc 1
expect_nothing_armed
expect_default retroforge-b.conf   # names an entry that is not there: OpenABL boots A
expect_no_call 'mkfs.ext4'
done_

t "a-failure-during-the-copy-leaves-nothing-armed"
touch "$SB/fail-rsync"
run
expect_rc 1
expect_nothing_armed
expect_boot b vmlinuz-6.1.0 'OLD-B vmlinuz'
done_

t "a-failure-mounting-the-root-leaves-nothing-armed"
touch "$SB/fail-mount"
run
expect_rc 1
expect_nothing_armed
done_

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
