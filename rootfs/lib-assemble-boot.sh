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

# STAGE rauc-boot-mirror — the device keyring and the slot's own boot software (Phase 4b pass 2).
# ----------------------------------------------------------------------------------------------
# Two things the overlay tree cannot carry, because both are BUILD OUTPUTS rather than static files.
#
# 1. The keyring. /etc/rauc/system.conf points at /etc/rauc/keyring.pem; it is installed here from
#    the committed CA so there is ONE copy in the repo (ota/rauc/retroforge-ca.pem, which
#    ota/gen-signing-ca.sh also signs bundles against) rather than a duplicate under rootfs/overlay that could drift.
#
# 2. The boot software, mirrored under /usr/lib/retroforge/boot. The ESP GRUB that picks the slot
#    and both per-slot stage-2 configs are owned by the same build that ships /boot/vmlinuz.efi and
#    /lib/modules/<ver> inside this root, so carrying them here makes the pairing true by
#    construction: the RAUC post-install hook refreshes the ESP and the slot's efi partition FROM
#    this directory, so an update can never install a root whose boot chain does not boot it.
#
#    steamcl.efi IS THE ESP GRUB, as a symlink. A root from before the ESP GRUB installs the first
#    update into this one with ITS hook, which copies /usr/lib/retroforge/boot/steamcl.efi onto the
#    ESP as \EFI\BOOT\bootaa64.efi (with steamcl-version and fonts/default.pf2 beside it, and
#    grubaa64.efi + grub-<slot>.cfg + the boot font onto the slot's efi partition). Under those names
#    it installs this build's chain without knowing it, and the ESP GRUB then follows the boot conf
#    that hook re-armed (boot/gen-esp-cfg.sh). The hook reads through the link with cp and sha256sum.
#
#    /usr/bin/grub-editenv is RAUC's: bootloader=grub runs it for every slot-state call. It is built
#    with the GRUB above (boot/grub.sh); nothing in the package set ships one.
CA_SRC="$ROOT/ota/rauc/retroforge-ca.pem"
BOOTDIR_SRC="$OUT/boot"
[ -f "$CA_SRC" ] || { echo "no RAUC CA at ${CA_SRC#"$ROOT"/} (run ota/gen-signing-ca.sh)" >&2; exit 1; }
for f in grub-esp.efi grubaa64.efi grub-a.cfg grub-b.cfg fonts/dejavu-mono.pf2 grubenv \
         grub-editenv steamcl-version fonts/default.pf2; do
  [ -f "$BOOTDIR_SRC/$f" ] || { echo "no boot artifact: ${BOOTDIR_SRC#"$ROOT"/}/$f (run boot/grub.sh)" >&2; exit 1; }
done
install -D -m0444 "$CA_SRC"      "$stage/etc/rauc/keyring.pem"
install -D -m0755 "$BOOTDIR_SRC/grub-editenv" "$stage/usr/bin/grub-editenv"
install -d -m0755 "$stage/usr/lib/retroforge/boot/fonts"
install -D -m0444 "$BOOTDIR_SRC/grub-esp.efi"     "$stage/usr/lib/retroforge/boot/grub-esp.efi"
ln -sfn grub-esp.efi                              "$stage/usr/lib/retroforge/boot/steamcl.efi"
install -D -m0444 "$BOOTDIR_SRC/steamcl-version"  "$stage/usr/lib/retroforge/boot/steamcl-version"
install -D -m0444 "$BOOTDIR_SRC/fonts/default.pf2" "$stage/usr/lib/retroforge/boot/fonts/default.pf2"
install -D -m0444 "$BOOTDIR_SRC/grubaa64.efi"     "$stage/usr/lib/retroforge/boot/grubaa64.efi"
install -D -m0444 "$BOOTDIR_SRC/grub-a.cfg"       "$stage/usr/lib/retroforge/boot/grub-a.cfg"
install -D -m0444 "$BOOTDIR_SRC/grub-b.cfg"       "$stage/usr/lib/retroforge/boot/grub-b.cfg"
install -D -m0444 "$BOOTDIR_SRC/fonts/dejavu-mono.pf2" "$stage/usr/lib/retroforge/boot/fonts/dejavu-mono.pf2"
# The pristine env block. No A/B update reads this: the ESP is shared, so its grubenv survives
# updates by not being touched, and overwriting it would throw away RAUC's slot state and the board
# choice. It is here for the INTERNAL INSTALLER, which writes an ESP that does not exist yet.
install -D -m0444 "$BOOTDIR_SRC/grubenv"          "$stage/usr/lib/retroforge/boot/grubenv"
# OpenABL's Device model list, for the ESP's \dtbs\qcom (boot/esp-dtbs.sh says why these are not
# simply /boot/dtbs).
"$ROOT/boot/esp-dtbs.sh" "$stage/usr/lib/retroforge/boot/dtbs" "$OUT"/dtbs/*.dtb
chmod 0444 "$stage/usr/lib/retroforge/boot/dtbs"/*.dtb

# The GPT, shipped VERBATIM beside the slot-write primitives (Phase 2 of
# .claude/plans/internal-install.plan.md). image/genpart.sh --append lays our eight partitions into
# an OEM disk's free space and reports where they landed; partition-table.txt is the single source
# of the sizes, types and GPT names it works from, and the same file image/make-sdcard.sh uses for
# an image.
#
# VERBATIM IS THE POINT, and guard-rootfs.sh diffs the two copies rather than trusting this line.
# An installer working from a stale table would produce a disk whose partition SIZES differ from the
# image the release was tested on, and the first symptom is a rootfs image that does not fit a slot --
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
echo "  RAUC: keyring.pem + ESP GRUB + stage-2 configs + /usr/bin/grub-editenv installed"

