#!/usr/bin/env bash
# Offline tests for the INSTALLER MEDIUM — Phase 6 of .claude/plans/internal-install.plan.md.
#
#   tests/test-mkimage.sh
#
# Host-only: no docker, no root, no built tree, no network. Run via `make test`. Peer of
# tests/test-mkroot.sh, which covers the ROOT; this covers what gets written around it — the
# two-partition table, the boot chain and the generated BLS entry (loader/entries/retroforge.conf).
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TABLE="$ROOT/installer/medium-table.txt"
GENENTRY="$ROOT/installer/gen-bls-entry.sh"
MKIMAGE="$ROOT/installer/mkimage.sh"
SHIPPED_GENCFG="$ROOT/boot/gen-grub-cfg.sh"

PASS=0; FAIL=0; SKIP=0; CASE=""
ok()   { PASS=$((PASS+1)); printf '  ok   %s -- %s\n' "$CASE" "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL %s -- %s\n' "$CASE" "$1"; }
skip() { SKIP=$((SKIP+1)); printf '  skip %s -- %s\n' "$CASE" "$1"; }

for f in "$TABLE" "$GENENTRY" "$MKIMAGE" "$SHIPPED_GENCFG"; do
  [ -e "$f" ] || { echo "missing input: $f" >&2; exit 1; }
done
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT

rows() { grep -vE '^[[:space:]]*(#|$)' "$TABLE"; }

# ---------------------------------------------------------------------------------------------
CASE="medium-table"
n=$(rows | wc -l)
[ "$n" -eq 2 ] && ok "declares exactly 2 partitions" \
  || bad "declares $n partitions — the medium has no slots and needs no more"

read -r _ esp_size esp_type esp_fs esp_label _ < <(rows | sed -n 1p)
read -r rt_name rt_size rt_type _ rt_label _ < <(rows | sed -n 2p)

# 0700, NOT ef00, and the reasoning is measured rather than assumed. An EFI System Partition is
# hidden from users by Windows and macOS, which makes this installer's own advice — "copy
# wifi.conf.example next to it on another computer" — impossible, and loses the install log on the
# way back out. ABL does not select by type: a working ROCKNIX card is MBR (`dos`) with a plain
# 0xc FAT32 partition carrying /EFI/BOOT/bootaa64.efi and no EFI System Partition anywhere
# (measured 2026-08-24). The loader is found by CONTENT.
[ "$esp_type" = 0700 ] && ok "p1 is 0700, so every OS shows it (ABL boots by content, not type)" \
  || bad "p1 type is $esp_type — an ef00 here is invisible on Windows/macOS, where wifi.conf is written"
[ "$esp_fs" = vfat ] && ok "p1 is vfat" || bad "p1 fs is $esp_fs"
[ "$rt_name" = root ] && ok "p2 is the root" || bad "p2 is named $rt_name"
[ "$rt_size" = rest ] && ok "p2 takes the rest of the medium" \
  || bad "p2 is fixed at $rt_size — the root is sized by what got built"

# 11 characters is all a FAT label has room for; a longer one is silently truncated by mkfs.vfat,
# and then nothing that searches for it finds it.
[ "${#esp_label}" -le 11 ] && ok "the ESP label fits FAT ($esp_label, ${#esp_label} chars)" \
  || bad "the ESP label $esp_label is ${#esp_label} chars — FAT holds 11"
# It must NOT be one of the install's own labels: a dev card and an internal install already share
# those, and an installer whose /esp matched the TARGET's would write its failure log onto the disk
# it just failed to install.
case "$esp_label" in
  [Nn][Oo][Vv][Aa][Dd][Ee][Cc][Kk]*) bad "the ESP label is a retroforge-* one — it would collide with the target" ;;
  *) ok "the ESP label does not collide with an install's labels" ;;
esac
grep -q 'RFINSTALLER' "$ROOT/installer/mkroot.sh" \
  && ok "mkroot.sh's fstab entry names the same label" \
  || bad "mkroot.sh does not mention RFINSTALLER — /esp would never mount"

# ---------------------------------------------------------------------------------------------
CASE="BLS entries"
UUID=deadbeef-0000-1111-2222-333344445555
VER=v9.9.9
shipped_cmdline=$(sed -n 's/^BOOT_CMDLINE="\(.*\)"$/\1/p' "$SHIPPED_GENCFG" | head -1)
base_opts="$shipped_cmdline gpt root=PARTUUID=$UUID rootfstype=squashfs rootwait ro systemd.volatile=state systemd.firstboot=off"
if ! "$GENENTRY" "$UUID" "$VER" "$T/entries" >/dev/null 2>"$T/err"; then
  bad "the generator failed: $(head -1 "$T/err")"
else
  ok "generates against a partition uuid and a version"
  n=$(find "$T/entries" -type f | wc -l)
  [ "$n" -eq 2 ] && ok "emits exactly 2 entries" || bad "emits $n entries, want 2 (normal + debug)"
  check() {  # <file> <title> <options>
    local e="$T/entries/$1" keys
    [ -f "$e" ] || { bad "$1 was not written"; return; }
    keys=$(awk '{print $1}' "$e" | tr '\n' ' ')
    [ "$keys" = "title version linux options " ] && ok "$1: keys are title, version, linux, options" \
      || bad "$1: unexpected keys '$keys'"
    grep -qxF "title      $2" "$e" && ok "$1: title $2" || bad "$1: wrong title: $(sed -n 1p "$e")"
    grep -qx "version    $VER" "$e" && ok "$1: version is the one passed in" || bad "$1: wrong version: $(sed -n 2p "$e")"
    grep -qx 'linux      /vmlinuz.efi' "$e" && ok "$1: linux /vmlinuz.efi" || bad "$1: wrong linux line: $(sed -n 3p "$e")"
    grep -qxF -- "options    $3" "$e" && ok "$1: options line is exactly the expected command line" \
      || bad "$1: options line differs: $(sed -n 4p "$e")"
    for unwanted in "retroforge.slot=" "retroforge.var=" "retroforge.efi=" "rootfstype=btrfs"; do
      grep -q -- "$unwanted" "$e" \
        && bad "$1 carries '$unwanted' — that is slot machinery, and this medium has no slots" \
        || ok "$1: no '$unwanted'"
    done
  }
  check retroforge.conf       "RetroForge Installer"         "$base_opts"
  check retroforge-debug.conf "RetroForge Installer (Debug)" "$base_opts retroforge.install.debug"
fi

# ---------------------------------------------------------------------------------------------
CASE="boot cmdline parity with the shipped generator"
# The shared prefix is hand-copied between the two generators, and a divergence is invisible:
# both media still build, both still boot, and the difference only shows as one of them behaving
# subtly differently on a panel someone is looking at. That is exactly what happened -- loglevel=3
# went into the shipped cmdline and not the installer's, and nothing failed.
#
# Compared as the assigned VALUE, not as a source line, so a comment or reflow above either one
# does not make this fail for no reason.
shipped_cmdline=$(sed -n 's/^BOOT_CMDLINE="\(.*\)"$/\1/p' "$SHIPPED_GENCFG" | head -1)
installer_cmdline=$(sed -n 's/^BOOT_CMDLINE="\(.*\)"$/\1/p' "$GENENTRY" | head -1)
if [[ -z $shipped_cmdline || -z $installer_cmdline ]]; then
    bad "could not read BOOT_CMDLINE from both generators (shipped='$shipped_cmdline' installer='$installer_cmdline')"
elif [[ $shipped_cmdline == "$installer_cmdline" ]]; then
    ok "both generators emit the same shared prefix"
else
    bad "the shared prefix has drifted -- shipped: '$shipped_cmdline' / installer: '$installer_cmdline'"
fi

# loglevel=3 is called out by name because `quiet` reads like it already covers this and does not:
# it gates the console to 4, so drm/msm's *ERROR* lines still print over whatever is on screen.
CASE="the console is quiet enough for a UI to be readable"
for gen in "$SHIPPED_GENCFG" "$GENENTRY"; do
    rel="${gen#"$ROOT"/}"
    if grep -q 'BOOT_CMDLINE=.*loglevel=3' "$gen"; then
        ok "$rel sets loglevel=3 (quiet alone only gates to 4)"
    else
        bad "$rel has no loglevel=3 -- KERN_ERR will print over the splash/installer UI"
    fi
done

# ---------------------------------------------------------------------------------------------
CASE="mkimage guards"
# The argument is positional and both trees are directories full of a Linux system, so picking the
# wrong one is a one-word mistake that would produce an "installer" with no install code on it.
grep -q 'ID=retroforge-installer' "$MKIMAGE" \
  && ok "refuses a tree that does not identify as the installer" \
  || bad "mkimage.sh does not check which tree it was handed"
grep -q 'usr/lib/retroforge/pkgs' "$MKIMAGE" \
  && ok "refuses a half-finished bootstrap (checks the completion marker)" \
  || bad "mkimage.sh does not check the bootstrap completed"
grep -q 'RETROFORGE_PARTITION_TABLE' "$MKIMAGE" \
  && ok "points genpart.sh at the medium table, not the shipped one" \
  || bad "mkimage.sh does not override the partition table — it would lay the 8-partition layout"
# The medium boots from a BLS entry: no GRUB, no steamcl, no /EFI tree at all.
grep -qE '^[^#]*(grubaa64|bootaa64|steamcl|EFI/)' "$MKIMAGE" \
  && bad "mkimage.sh still writes GRUB/EFI files — the medium boots via BLS and carries no /EFI" \
  || ok "no GRUB, steamcl or /EFI on the medium"
for f in retroforge.conf retroforge-debug.conf; do
  grep -q "::/loader/entries/$f" "$MKIMAGE" \
    && ok "the BLS entry is written to loader/entries/$f" \
    || bad "nothing is written to loader/entries/$f"
done
grep -q '"$GENENTRY" "$ROOT_UUID" "$IMG_VERSION"' "$MKIMAGE" \
  && ok "the entries are generated from p2's PARTUUID and the stamped version" \
  || bad "the entry is not generated from ROOT_UUID and IMG_VERSION"

CASE="the Wi-Fi template is on the medium"
# The no-Wi-Fi screen tells the operator to copy wifi.conf.example, and until 2026-08-24 nothing
# ever put one on a card. netcfg reads /esp/retroforge/wifi.conf, so the template has to sit beside
# that path, on the boot partition that is typed 0700 so Windows and macOS will show it.
grep -q 'retroforge/wifi.conf.example' "$MKIMAGE" \
  && ok "mkimage writes it to /retroforge/ on the boot partition" \
  || bad "the file the screen tells the user to copy is not put on the medium"
grep -q 'fatdir "$esp" retroforge' "$MKIMAGE" \
  && ok "and creates the folder netcfg reads wifi.conf from" \
  || bad "the retroforge folder is not created"
grep -q 'die "missing' "$MKIMAGE" && grep -q 'WIFI_EXAMPLE' "$MKIMAGE" \
  && ok "a missing template fails the build rather than shipping bad instructions" \
  || bad "the template can go missing silently"

CASE="the medium says which build it is"
# Until this landed, every installer image ever built answered identically: the same NAME, the same
# ID, no version, no date. That is the first question asked at the fallback console -- the thing
# that exists for the moment something has gone wrong -- and the medium could not answer it.
grep -q '>"$BASE/etc/retroforge-release"' "$MKIMAGE" \
  && ok "mkimage writes /etc/retroforge-release, the path the shipped image uses too" \
  || bad "no per-build identity is written into the tree"
for f in RETROFORGE_VARIANT RETROFORGE_BUILD RETROFORGE_VERSION RETROFORGE_GIT RETROFORGE_MODE; do
  grep -q "echo \"$f=" "$MKIMAGE" && ok "$f is stamped" || bad "$f is missing from the stamp"
done
# REWRITTEN, NEVER APPENDED. The tree is cached between builds, so `>>` would stack a fresh block on
# every `make installer` until os-release carried a dozen contradictory VERSION= lines, the last one
# winning by accident.
grep -q '>>"$BASE/etc/os-release"' "$MKIMAGE" \
  && bad "os-release is APPENDED to, and the tree it lands in is cached across builds" \
  || ok "os-release is rewritten from the committed file plus the stamp, so a rebuild cannot stack blocks"
grep -q 'cat "$OSRELEASE_SRC"' "$MKIMAGE" \
  && ok "and the static half comes from installer/os-release rather than a second copy of it" \
  || bad "the rewritten os-release does not start from the committed file"
# THE MODE COMES FROM THE TREE. `RETROFORGE_DEV=1 make installer-root` followed by a plain
# `make installer` must not stamp `release` on a medium carrying an authorized_keys and a Wi-Fi PSK;
# mkroot folds `dev:0|1` into the reuse marker precisely so this half can read it back.
grep -q "grep -qx 'dev:1' \"\$BASE/usr/lib/retroforge/pkgs\"" "$MKIMAGE" \
  && ok "the dev/release mode is read out of the root's own reuse marker" \
  || bad "the mode is not derived from the tree"
# Non-comment lines only: the block above EXPLAINS why it does not read that variable, and a naive
# grep reads its own rationale as the violation.
grep -qE '^[^#]*RETROFORGE_DEV' "$MKIMAGE" \
  && bad "mkimage reads RETROFORGE_DEV — a stale environment could disagree with what was baked in" \
  || ok "and never from the environment, which cannot disagree with the tree"
grep -q 'installer.release' "$MKIMAGE" \
  && ok "the same fields land beside the image, so a publisher need not open a squashfs to name it" \
  || bad "no identity sidecar is written next to installer.img"
# installer/os-release is an INPUT to mkroot's reuse key: a per-build field there re-bootstraps the
# whole emulated root on every build.
grep -qE '^(VERSION_ID|BUILD_ID|VERSION)=' "$ROOT/installer/os-release" \
  && bad "installer/os-release carries a per-build field — it is hashed into mkroot's reuse key" \
  || ok "installer/os-release stays static, as mkroot's cache key requires"
# And the identity has to reach the container at all.
grep -qE '^installer:.*' "$ROOT/Makefile" \
  && grep -A3 '^installer:' "$ROOT/Makefile" | grep -q '$(ID_ENV)' \
  && ok "the Makefile forwards \$(ID_ENV), or RETROFORGE_VERSION would never reach the stamp" \
  || bad "make installer does not pass ID_ENV into the container"

CASE="the medium carries no Steam seed -- /home is staged empty on the device"
# The distro ships no Steam client, so there is no tree for the medium to carry: the spine stages an
# empty player home with image/lib-homestage.sh exactly as make-sdcard.sh does for a card. A seed
# that crept back in would be 1.4 GiB on the medium and a pin for the spine to refuse against.
grep -qE '^[^#]*(steam[-]seed|SEED_SRC|RETROFORGE_SEED_)' "$MKIMAGE" "$ROOT/installer/mkroot.sh" \
  && bad "mkimage/mkroot still stage a Steam seed onto the medium" \
  || ok "nothing stages a Steam seed or its pin onto the medium"
grep -qE '^installer:.*SEED' "$ROOT/Makefile" \
  && bad "make installer still depends on a seed artifact" \
  || ok "the installer target does not require a seed artifact"
VERIFY="$ROOT/installer/verify-image.sh"
grep -qE 'steam[-]seed|steamui\.so' "$VERIFY" \
  && bad "verify-image still demands a Steam seed the medium no longer carries" \
  || ok "verify-image does not look for a seed or its pin"
grep -q 'lib-homestage.sh' "$VERIFY" \
  && ok "but it does require lib-homestage.sh, which is what the spine builds /home with" \
  || bad "verify-image does not check that lib-homestage.sh reached the medium"

CASE="the verifier knows about everything the medium ships"
# installer/verify-image.sh is the ONLY thing that opens the built image; this file and test-mkroot.sh
# read the scripts, and a script that says the right thing while producing the wrong image passes
# both. So the verifier's list of what must be on the medium has to keep up with what mkroot puts
# there — otherwise a file added to the image is a file nothing ever checks arrived. Asserted in
# this direction only: the verifier states its own expectations (deriving them from the builder
# would make it agree with the builder by construction), but it may not fall behind.
[ -f "$VERIFY" ] || bad "installer/verify-image.sh is missing"
if [ -f "$VERIFY" ]; then
  mapfile -t SHIPS < <(sed -n '/^INSTALL_FILES=(/,/^)/p' "$ROOT/installer/mkroot.sh" \
    | sed -e '1d' -e '$d' -e 's/#.*//' | tr ' ' '\n' | grep -v '^$')
  mapfile -t FOREIGN < <(sed -n '/^FOREIGN_FILES=(/,/^)/p' "$ROOT/installer/mkroot.sh" \
    | sed -e '1d' -e '$d' -e '/^[[:space:]]*#/d' | tr -d '"' | tr ' ' '\n' | grep -v '^$')
  unchecked=""
  for f in "${SHIPS[@]}"; do
    grep -q -- "$f" "$VERIFY" || unchecked="$unchecked $f"
  done
  for spec in "${FOREIGN[@]}"; do
    grep -q -- "${spec##*:}" "$VERIFY" || unchecked="$unchecked ${spec##*:}"
  done
  [ -z "$unchecked" ] \
    && ok "verify-image.sh names all ${#SHIPS[@]} shipped files and all ${#FOREIGN[@]} searched ones" \
    || bad "these reach the medium and nothing verifies they arrived:$unchecked"
fi

printf '\ntest-mkimage.sh: %d passed, %d failed, %d skipped\n' "$PASS" "$FAIL" "$SKIP"
[ "$FAIL" -eq 0 ]
