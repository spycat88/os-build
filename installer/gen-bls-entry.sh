#!/usr/bin/env bash
# retroforge INSTALLER boot entry generator.
#
#   installer/gen-bls-entry.sh <root-partuuid> <version> <outdir>
#
# Emits the installer medium's two Boot Loader Specification (BLS) entries into <outdir>, which
# mkimage.sh copies to /loader/entries/ on the boot partition:
#
#   retroforge.conf        "RetroForge Installer"          the normal boot, into the installer GUI
#   retroforge-debug.conf  "RetroForge Installer (Debug)"  the same, plus retroforge.install.debug
#
# The debug entry is the only way to pass that argument on this hardware: there is no keyboard to
# edit a command line and no serial console. retroforge-installer.service carries
# ConditionKernelCommandLine=!retroforge.install.debug, so it hands the panel to a plain getty
# instead of gamescope — the escape hatch when the GUI is what is broken. The medium no longer carries GRUB or an /EFI tree:
# the bootloader reads this entry directly and boots /vmlinuz.efi off the same FAT partition.
#
# Both values are outputs of installer/mkimage.sh, not inputs to the build:
#
#   <root-partuuid>  the unique GUID sgdisk assigned to p2 (the squashfs root) when mkimage.sh laid
#                    the GPT. It is random per build, so the entry is generated AFTER the table
#                    exists and verify-image.sh checks the two still agree.
#   <version>        RETROFORGE_VERSION, the build's only version knob (set by CI from the release
#                    tag, `dev` for a local build) — the same string mkimage.sh stamps into the
#                    medium's /etc/os-release as VERSION_ID.
#
# THE KERNEL COMMAND LINE. BOOT_CMDLINE is the shipped image's BOOT_CMDLINE **verbatim**
# (boot/gen-grub-cfg.sh), and tests/test-mkimage.sh asserts the two are byte-identical: the EFI stub
# overwrites /chosen/bootargs with the loader's command line, so anything not on the options line
# is not applied at all. video=efifb:off in particular is load-bearing on these panels, and
# loglevel=3 keeps drm/msm's KERN_ERR lines off the installer's own console UI.
#
# `gpt` sits between the two halves so the kernel scans the medium's GPT for the PARTUUID.
#
# Then the installer's own:
#
#   rootfstype=squashfs   the root is a squashfs image dd'd into p2. CONFIG_SQUASHFS=y and
#                         CONFIG_SQUASHFS_ZSTD=y are both built in, so the kernel mounts it with no
#                         initramfs at all — which is why this medium has none.
#   systemd.volatile=state  /var as a tmpfs over the read-only root. Without it journald, NM's state
#                         directory and everything else under /var is unwritable. /etc is handled
#                         differently (three writers pointed at /run — see installer/mkroot.sh);
#                         `state` is the volatile mode that does NOT need an initrd.
#   systemd.firstboot=off  belt to the braces of the masked systemd-firstboot.service: this kills
#                         PID1's own builtin locale/root-password query, which the mask does not.
set -euo pipefail

PARTUUID="${1:-}"
VERSION="${2:-}"
OUTDIR="${3:-}"
[ -n "$PARTUUID" ] && [ -n "$VERSION" ] && [ -n "$OUTDIR" ] \
  || { echo "usage: installer/gen-bls-entry.sh <root-partuuid> <version> <outdir>" >&2; exit 2; }
mkdir -p "$OUTDIR"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

BOOT_CMDLINE="quiet loglevel=3 video=efifb:off console=tty0 cgroup.memory=nokmem,nosocket nosoftlockup panic=5 cpuidle.governor=teo cgroup_favordynmods=1"
INSTALLER_CMDLINE="root=PARTUUID=$PARTUUID rootfstype=squashfs rootwait ro systemd.volatile=state systemd.firstboot=off"

DEBUG_CMDLINE="retroforge.install.debug"

emit_entry() {  # <file> <title> <extra args>
  local opts="$BOOT_CMDLINE gpt $INSTALLER_CMDLINE${3:+ $3}"
  cat >"$OUTDIR/$1" <<EOT
title      $2
version    $VERSION
linux      /vmlinuz.efi
options    $opts
EOT
}
emit_entry retroforge.conf       "RetroForge Installer"         ""
emit_entry retroforge-debug.conf "RetroForge Installer (Debug)" "$DEBUG_CMDLINE"

echo "  ok   installer BLS entries -> ${OUTDIR#"$ROOT"/}  (version $VERSION, root=PARTUUID=$PARTUUID)" >&2
