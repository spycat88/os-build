#!/usr/bin/env bash
# retroforge read-only root assembler — stage `rauc-boot-mirror`: RAUC keyring, boot mirror, installer GPT.
#
# SOURCED by rootfs/assemble-rootfs.sh, never executed. Split out of it for issue #43; the code
# and its rationale are unchanged.
#
# Runs at top level, in place: sourcing it IS the stage.
#
# Reads the assembler's globals rather than taking arguments -- $stage (the staged tree), $ROOT
# (repo root), $OUT (build outputs). Turning ~20 implicit globals into positional parameters is
# where a verbatim move stops being verbatim, so it is deliberately not done.

# STAGE rauc-boot-mirror — the device keyring and the slot's own boot data (Phase 4b pass 2).
# ----------------------------------------------------------------------------------------------
# Two things the overlay tree cannot carry, because both are BUILD OUTPUTS rather than static files.
#
# 1. The keyring. /etc/rauc/system.conf points at /etc/rauc/keyring.pem; it is installed here from
#    the committed CA so there is ONE copy in the repo (ota/rauc/retroforge-ca.pem, which
#    ota/gen-signing-ca.sh also signs bundles against) rather than a duplicate under rootfs/overlay that could drift.
#
# 2. The boot data, mirrored under /usr/lib/retroforge/boot. Every Boot Loader Specification entry
#    that boots this root is written FROM this directory -- by the RAUC post-install hook for an
#    update, the installer for an internal install, retroforge-bootctl on a fresh card's first boot
#    -- so the entry and the root it boots always come from one build:
#
#      boards.tsv   the board table (boot/gen-bls.sh): model -> DTB and board arguments
#      cmdline      the arguments every entry carries
#      release      the build version and kernel version an entry names
#      dtbs/        the DTBs with a splash region (boot/splash-dtbs.sh), which the writers copy onto
#                   the slot's boot partition as \dtbs, where OpenABL installs its Device model's
#
#    The kernel and initramfs the entry names are this root's /boot, copied onto the slot's boot
#    partition the same way.
CA_SRC="$ROOT/ota/rauc/retroforge-ca.pem"
BOOTDIR_SRC="$OUT/boot"
[ -f "$CA_SRC" ] || { echo "no RAUC CA at ${CA_SRC#"$ROOT"/} (run ota/gen-signing-ca.sh)" >&2; exit 1; }
for f in boards.tsv cmdline; do
  [ -f "$BOOTDIR_SRC/$f" ] || { echo "no boot artifact: ${BOOTDIR_SRC#"$ROOT"/}/$f (run boot/gen-bls.sh)" >&2; exit 1; }
done
install -D -m0444 "$CA_SRC"      "$stage/etc/rauc/keyring.pem"
install -d -m0755 "$stage/usr/lib/retroforge/boot"
install -D -m0444 "$BOOTDIR_SRC/boards.tsv"       "$stage/usr/lib/retroforge/boot/boards.tsv"
install -D -m0444 "$BOOTDIR_SRC/cmdline"          "$stage/usr/lib/retroforge/boot/cmdline"
# release: the build version every entry carries as its `version`, and the kernel version its kernel
# and initramfs are named by on the slot's partition (vmlinuz-<kernel>). The kernel version is the
# one modules_install laid down, else the pinned source's; the build version is the stamp written to
# /etc/retroforge-release above. Also left in out/boot for image/make-sdcard.sh, which writes a card's
# entries without mounting this root.
bls_kver="$(ls "$stage/lib/modules" 2>/dev/null | head -1)"
[ -n "$bls_kver" ] || bls_kver="$(sed -n 's/^version:[[:space:]]*//p' "$ROOT/kernel/SOURCE.pin" | head -1)"
bls_version="$(sed -n 's/^RETROFORGE_VERSION=//p' "$stage/etc/retroforge-release" | head -1)"
[ -n "$bls_kver" ] && [ -n "$bls_version" ] || { echo "cannot name the kernel or build version for the boot entries" >&2; exit 1; }
printf 'version=%s\nkernel=%s\n' "$bls_version" "$bls_kver" >"$BOOTDIR_SRC/release"
install -D -m0444 "$BOOTDIR_SRC/release"          "$stage/usr/lib/retroforge/boot/release"
# OpenABL's Device model list and the slots' own DTBs (boot/splash-dtbs.sh says why these are not
# simply /boot/dtbs).
"$ROOT/boot/splash-dtbs.sh" "$stage/usr/lib/retroforge/boot/dtbs" "$OUT"/dtbs/*.dtb
chmod 0444 "$stage/usr/lib/retroforge/boot/dtbs"/*.dtb

# The GPT, shipped VERBATIM beside the slot-write primitives (Phase 2 of
# .claude/plans/internal-install.plan.md). image/genpart.sh --append lays our eight partitions into
# an OEM disk's free space and reports where they landed; partition-table.txt is the single source
# of the sizes, types and GPT names it works from, and the same file image/make-sdcard.sh uses for
# a card.
#
# VERBATIM IS THE POINT, and guard-rootfs.sh diffs the two copies rather than trusting this line.
# An installer working from a stale table would produce a disk whose partition SIZES differ from the
# card the release was tested on, and the first symptom is a rootfs image that does not fit a slot --
# after the OEM's userdata has already been destroyed, which is not a state to discover a drift in.
# genpart.sh resolves the table next to itself for exactly this reason, so it needs no argument here
# and behaves identically from image/ in the repo and from /usr/lib/retroforge/install/ on a device.
install -D -m0555 "$ROOT/image/genpart.sh"          "$stage/usr/lib/retroforge/install/genpart.sh"
install -D -m0444 "$ROOT/image/partition-table.txt" "$stage/usr/lib/retroforge/install/partition-table.txt"
# lib-gpt.sh is sourced by the script genpart.sh emits, so it ships beside it or the append mode
# refuses. 0444: sourced, never executed, like lib-slotwrite.sh.
install -D -m0444 "$ROOT/image/lib-gpt.sh"          "$stage/usr/lib/retroforge/install/lib-gpt.sh"
# The /home layout, shared with make-sdcard.sh, and the rest of the internal installer. Settings on a
# card starts it (retroforge-installer.service); on an internal install select-target.sh refuses the
# disk it runs from, so there it is inert. installer/shipped-files is the list; guard-rootfs.sh reads
# the same one back. *.py are imported, everything else is executed.
install -D -m0444 "$ROOT/image/lib-homestage.sh"    "$stage/usr/lib/retroforge/install/lib-homestage.sh"
while read -r f; do
  case "$f" in
    ''|'#'*) continue ;;
    *.py)    mode=0444 ;;
    *)       mode=0555 ;;
  esac
  install -D -m"$mode" "$ROOT/installer/$f" "$stage/usr/lib/retroforge/install/$f"
done <"$ROOT/installer/shipped-files"
# $CONFIRM is a fixed path the spine reads. The UI already owns the panel and the pad when the spine
# asks, so it is the shim that hands the request to the UI, never a second SDL client.
ln -sf confirm-ui "$stage/usr/lib/retroforge/install/confirm"
echo "  RAUC: keyring.pem + boot data (board table, cmdline, DTBs) installed"

