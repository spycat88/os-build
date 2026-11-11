#!/usr/bin/env bash
# retroforge stage-2 grub.cfg generator.
#
#   boot/gen-grub-cfg.sh <A|B> <outfile>
#
# Emits the grub.cfg installed as /EFI/steamos/grub.cfg on that slot's efi partition. Pure text:
# no toolchain, no cross-build, no network — so tests/test-stage2-grub.sh can generate and assert
# the real artifact on a bare host. boot/grub.sh calls it twice after building grubaa64.efi.
#
# Two input files, both of which are the single source of truth for what they carry:
#   boot/boards.map              build-time board catalog (id / menu name / dtb / board bootargs)
#   image/partition-table.txt   partition ORDER and GPT labels
#
# THE ONE THING THIS FILE EXISTS TO GET RIGHT is telling GRUB where things are. The ESP GRUB
# (boot/gen-esp-cfg.sh) hands over with $root set to THIS slot's efi partition, so at the top of
# the script $root is that partition — and every other partition we need is on the same disk, at an index that comes from
# parts.env when the medium carries one and from the build-time table when it does not (see the
# "where our eight partitions actually are" block). Deriving from $root beats searching by
# filesystem label, which is what this used to do:
#
#   * A RAUC install writes the bundle's rootfs image to the inactive slot VERBATIM. Until the
#     post-install hook runs, both roots carry the SAME btrfs label and the same fsid, so
#     `search --label retroforge-root-B` is ambiguous exactly when a slot switch is in flight.
#   * A label search silently falls through to whatever else matches. The FAT label of the ESP
#     drifted from RETROFORGE to ESP once already and nothing failed loudly; the grubenv simply
#     stopped being found, so the saved board choice never persisted.
#
# The label search is kept as a FALLBACK only, and it is loud when it is used.
#
# For the same reason the cmdline names partitions by PARTUUID rather than PARTLABEL: the eight GPT
# names are identical on every retroforge medium, so with two attached — a card left in after an
# install to internal storage — findfs resolves whichever it enumerates first. The UUIDs are read
# out of the GPT at boot with `probe --part-uuid`, off the disk we were chainloaded from, so they
# are per-disk by construction and survive an update untouched. PARTLABEL remains as the announced
# fallback.
#
# EVERY FALLBACK ARM BELOW PAUSES 10 SECONDS, not 3. These messages are the entire diagnostic on a
# device with no serial console, and gfxterm draws them in the boot font — which is already at the
# only scale lever we have (`grub-mkfont -s 32`, boot/grub.sh) and is still small on a 1080p handheld
# panel held at arm's length. HW-confirmed 2026-08-06 on a Pocket S2: the text was legible but 3s was
# not long enough to read it before the menu painted over.
#
# Waiting for a keypress instead was considered and rejected. `sleep --interruptible` aborts on ESC
# only (grub-core/commands/sleep.c), the power button is wired to the PMIC and never reaches GRUB's
# EFI console input, and — decisively — these arms fire on a USER's device in the field. Blocking on
# input on a machine with no keyboard turns a degraded-but-bootable device into one that looks
# bricked. Loud, then carry on; never wedged.
#
# Tries are not counted here. The ESP GRUB counts them in the grubenv (RAUC's ORDER/<slot>_TRY)
# before handing over, and tells this config through rf_retry/rf_fallback whether to show the menu.
set -euo pipefail
shopt -s nullglob

SLOT="${1:-}"
OUTFILE="${2:-}"
case "$SLOT" in
  A|B) ;;
  *) echo "usage: boot/gen-grub-cfg.sh <A|B> <outfile>" >&2; exit 2 ;;
esac
[ -n "$OUTFILE" ] || { echo "usage: boot/gen-grub-cfg.sh <A|B> <outfile>" >&2; exit 2; }

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BOARDS="$ROOT/boot/boards.map"
TABLE="$ROOT/image/partition-table.txt"
DTS="$ROOT/kernel/dts/qcom"
slot_lc="${SLOT,,}"

for f in "$BOARDS" "$TABLE"; do
  [ -f "$f" ] || { echo "missing input: $f" >&2; exit 1; }
done

# --- partition table lookups ------------------------------------------------------------------
# Row order IS the partition number (image/genpart.sh emits the sgdisk script from the same
# file, so these cannot disagree without genpart.sh disagreeing too).
part_num()   { awk -v n="$1" '/^[[:space:]]*#/||/^[[:space:]]*$/{next} {i++; if ($1==n) {print i; exit}}' "$TABLE"; }
part_label() { awk -v n="$1" '/^[[:space:]]*#/||/^[[:space:]]*$/{next} {if ($1==n) {print $5; exit}}' "$TABLE"; }

P_ESP=$(part_num esp)
P_ROOT=$(part_num "rootfs-$slot_lc")
P_VAR=$(part_num "var-$slot_lc")
L_ROOT=$(part_label "rootfs-$slot_lc")
L_VAR=$(part_label "var-$slot_lc")
L_EFI=$(part_label "efi-$slot_lc")
for v in P_ESP P_ROOT P_VAR L_ROOT L_VAR L_EFI; do
  [ -n "${!v}" ] || { echo "cannot resolve $v from ${TABLE#"$ROOT"/}" >&2; exit 1; }
done

# The ESP fallback searches by CONTENT, not by label. The labels in partition-table.txt are GPT
# partition names, and `search --label` matches the FILESYSTEM label — two different things that
# need not hold the same value (the ESP's GPT name is RetroForge, its FAT label RETROFORGE, and
# the GPT name was RETROFORGE-ESP on older cards). Searching for a file the ESP is the only partition to carry needs no
# agreement between this generator and the card assembler at all, which is the point: the last
# version of this config searched for a FAT label that image/make-sdcard.sh had stopped writing,
# and nothing failed — the grubenv simply went missing. The grubenv is that file now: the ESP GRUB
# (boot/gen-esp-cfg.sh) keeps the slot state in it, so every retroforge ESP carries one.
ESP_MARKER="/EFI/steamos/grubenv"

# --- the common kernel command line -------------------------------------------------------------
# Board-specific args come from boards.map; root=/retroforge.var=/retroforge.efi=/retroforge.slot= are
# per-slot and added per menuentry. This replaces the old boot/cmdline file, which the android-bootimg backend
# baked into the image header: with a UEFI chain the EFI stub OVERWRITES /chosen/bootargs with
# GRUB's command line, so every argument has to be on the `linux` line or it is not applied.
# loglevel=3 is NOT redundant with `quiet`, and the difference is visible on the panel: `quiet`
# raises the console level to 4, which still prints KERN_ERR. drm/msm emits a steady run of
# `*ERROR*` lines during DPU bring-up, and every one of them lands on top of the boot splash.
# 3 keeps the genuinely fatal ones and drops the rest. Nothing is lost — the journal still has
# them all, which is the only place anyone reads them on a board with no serial console.
# cpuidle.governor=teo picks the TEO idle governor over menu, which would otherwise win on rating;
# see the cpuidle block in kernel/kernel.config for why.
# NOT audit=0. Kernel auditing is kept off by journald instead (usr/lib/systemd/journald.conf.d/
# 10-retroforge-audit.conf): audit=0 never registers the audit netlink socket, so every record PAM,
# sshd or dbus-broker sent made the kernel exec modprobe and wait for it.
# cgroup_favordynmods=1: moving a process between cgroups otherwise waits out an RCU grace period,
# 10-20 ms on the Air X with lazy RCU, and every login, scope and game launch moves one; with it the
# move is ~free, for a slightly costlier fork and exit (2026-10-31).
BOOT_CMDLINE="quiet loglevel=3 video=efifb:off console=tty0 cgroup.memory=nokmem,nosocket nosoftlockup panic=5 cpuidle.governor=teo cgroup_favordynmods=1"

# The installed system only, not the installer (which prints its failure log to tty1 and so needs
# the console there): no fbdev emulation, so the kernel puts nothing on the panel itself and the boot
# splash's modeset is the first. fbdev's own lit the panel black at ~1.2 s, and the splash's then had
# to be a second, full one: msm reserves its colour blocks (DSPPs) only in a modeset, and the splash
# sets the colour matrix gamescope later keeps, so that gamescope's first frame is not a modeset too.
# Each was ~0.7 s of the panel off (Air X, 2026-11-01). With no fbdev there is no kernel console either,
# which was already kept off tty1, the session's VT: bound there, it took the panel back the moment the
# splash let go of DRM master.
SESSION_CMDLINE="drm_kms_helper.fbdev_emulation=0"

# --- board catalog ------------------------------------------------------------------------------
declare -a pids=() pnames=() pdtbs=() pbootargs=()
while IFS=$'\t' read -r id name dtb bootargs; do
  [ -n "$id" ] || continue
  [[ $id == \#* ]] && continue
  [ -n "$dtb" ] || continue
  pids+=( "$id" ); pnames+=( "$name" ); pdtbs+=( "$dtb" ); pbootargs+=( "$bootargs" )
done < "$BOARDS"
[ "${#pids[@]}" -gt 0 ] || { echo "no board rows in ${BOARDS#"$ROOT"/}" >&2; exit 1; }

# --- per-board GRUB rotation --------------------------------------------------------------------
# 270 is right for every SM8xxx board in the catalog, and it is NOT derivable from the DTS: the
# panel node's `rotation = <N>` is 90 on some of those boards and 270 on others (Pocket DMG, RP5,
# Pocket Max, ...) while all of them want GRUB's 270, because the two count different things.
# The only boards that want something else are ROCKNIX's SM4450 and SM6115 builds, whose device
# options carry GRUB_ROTATION="90" against the same GRUB rotation patch (every other SoC there
# leaves it at the default). So the override is keyed on the SoC, by DTB name prefix, mirroring
# that table — a new SoC that needs one adds a case here, not a catalog column that would drift.
# Only the odd ones out produce a line, keyed on the SAVED entry (the console block below says why
# a fresh card cannot be helped).
soc_grub_rotation() {  # <dtb basename> -> GRUB rotation for a non-default board, or "" for the 270 default
  case "$1" in
    # The two landscape-native panels in the fleet (1280x960, no DTS rotation): nothing to rotate.
    # The Air Y row must come before the sm6115-* one.
    sm6115-mangmi-air-y)     echo 0 ;;
    sm8250-mangmi-air-y-pro) echo 0 ;;
    sm6115-*)                echo 90 ;;
    sm4450-*)                echo 90 ;;
    *)                       echo "" ;;
  esac
}
ROT_OVERRIDES=""
for i in "${!pids[@]}"; do
  r="$(soc_grub_rotation "${pdtbs[$i]}")"
  [ -n "$r" ] || continue
  ROT_OVERRIDES+="if [ \"\${saved_entry}\" = \"${pids[$i]}\" ]; then set rotation=$r; fi"$'\n'
done

# --- OpenABL's Device model -> menu entry -------------------------------------------------------
# One line per board .dts: its root `model`, which is the name OpenABL's Device model setting holds
# and the one retroforge_dt_model reads back, mapped to the entry that boots it (the catalog id, or
# the DTB name for a filename-derived entry). A .dts without a model of its own takes the one from
# the file it #includes.
dts_model() {  # <dts> -> its root model, or ""
  local f="$1" m inc
  m="$(sed -n 's/^[[:space:]]*model = "\(.*\)";.*/\1/p' "$f" | head -1)"
  if [ -z "$m" ]; then
    for inc in $(sed -n 's/^#include "\(.*\.dtsi*\)".*/\1/p' "$f"); do
      [ -f "$DTS/$inc" ] || continue
      m="$(sed -n 's/^[[:space:]]*model = "\(.*\)";.*/\1/p' "$DTS/$inc" | head -1)"
      [ -n "$m" ] && break
    done
  fi
  printf '%s' "$m"
}
MODEL_MAP=""
for dts in "$DTS"/*.dts; do
  base="$(basename "$dts" .dts)"
  mid="$base"
  for i in "${!pids[@]}"; do
    if [ "${pdtbs[$i]}" = "$base" ]; then mid="${pids[$i]}"; break; fi
  done
  mname="$(dts_model "$dts")"
  [ -n "$mname" ] || continue
  MODEL_MAP+="if [ \"\$abl_model\" = \"$mname\" ]; then set abl_board=$mid; fi"$'\n'
done

emit_entry() {  # <id> <name> <dtb> <board bootargs>
  local eid=$1 ename=$2 edtb=$3 ebootargs=$4
  cat <<EOF
menuentry '${ename:-$eid}' --id $eid {
  savedefault
  linux (\$slotroot)/boot/vmlinuz.efi $BOOT_CMDLINE $SESSION_CMDLINE $ebootargs root=\$rootspec rootfstype=btrfs rootwait ro retroforge.var=\$varspec retroforge.efi=\$efispec retroforge.slot=$SLOT rauc.slot=$SLOT
  initrd (\$slotroot)/boot/initramfs-retroforge.img
  devicetree (\$slotroot)/boot/dtbs/${edtb}.dtb
}

EOF
}

{
cat <<EOF
# retroforge stage-2 grub.cfg — slot $SLOT. GENERATED by boot/gen-grub-cfg.sh; do not edit.
# Installed as /EFI/steamos/grub.cfg on the $L_EFI partition, read after the ESP GRUB picks slot $SLOT.

insmod part_gpt
insmod fat
insmod btrfs
insmod loadenv
insmod regexp

# --- where our eight partitions actually are ----------------------------------------------------
# The indices are the one thing in this config an install to internal storage can invalidate. On a
# card image/genpart.sh owns the whole medium and lays us down at 1..8, so the build-time constants
# below are right by construction. An internal install APPENDS our eight to the OEM's existing GPT
# instead, and where that lands is a per-vendor fact — userdata is sda11 on the AYANEO-family boards
# and sda17 on the Odin 2 — so a baked gpt1 would address an OEM partition.
#
# Stage 2 cannot work them out for itself. Searching by label is the exact ambiguity the PARTUUID
# work below exists to kill; \`probe --part-uuid\` needs the index before it can return anything and
# has no --part-label to go the other way; and GRUB script has no arithmetic. So whoever CREATED the
# partitions writes the numbers down — image/make-sdcard.sh for a card, the installer for an
# internal install — and this reads them back.
#
# THE FILE IS ON THIS SLOT'S EFI PARTITION, NOT THE SHARED ESP, and that is forced rather than
# chosen: locating the ESP is itself one of the numbers, so an ESP-resident map cannot be read
# without already knowing what it says. (\$root) is the partition the ESP GRUB handed over on, which
# makes it the one place reachable with no index at all. It survives an update because the efi
# partition is not a RAUC slot and rootfs/overlay/usr/lib/rauc/post-install.sh only copies files onto
# it — unlike /var, which that hook reformats.
#
# Defaults first and the env second, mirroring the PARTLABEL→PARTUUID upgrade further down. The
# upgrade is ALL-OR-NOTHING: a file missing a key must never produce a map half from the install and
# half from this build, because a root from one layout with a /var from another is worse than either
# on its own. That is also why the loaded names differ from the consumed ones — load_env cannot
# rename, so loading straight into esp_idx would destroy the default before it could be judged. A
# MISSING file is silent: that is every card built before this landed, and it is not an error.
set esp_idx=$P_ESP
set root_idx=$P_ROOT
set var_idx=$P_VAR
if [ -f (\$root)/EFI/steamos/parts.env ]; then
  load_env -f (\$root)/EFI/steamos/parts.env nd_esp nd_efi_a nd_efi_b nd_root_a nd_root_b nd_var_a nd_var_b nd_home
  if [ -n "\$nd_esp" -a -n "\$nd_root_$slot_lc" -a -n "\$nd_var_$slot_lc" ]; then
    set esp_idx="\$nd_esp"
    set root_idx="\$nd_root_$slot_lc"
    set var_idx="\$nd_var_$slot_lc"
  else
    echo "retroforge: parts.env on this efi partition is incomplete."
    echo "retroforge: Using the built-in partition indices, which are right only on"
    echo "retroforge: a medium retroforge laid out by itself."
    sleep 10
  fi
fi

# --- locate the ESP and this slot's root --------------------------------------------------------
# \$root is the efi partition the ESP GRUB handed over on, and it is the BARE device name --
# hd0,gpt$((P_ESP + 1)), with NO parentheses. That is why every path below writes (\$root)/... :
# grub_set_prefix_and_root() wraps the device in parens only when it builds \$prefix
# (kern/main.c: grub_env_set "root" gets the bare device). Matching \(...\) here never fires,
# which cost one hardware boot: the derivation silently failed, the fallback search ran, and the
# only symptom was a message and a 3s pause before the menu. The optional parens are kept so this
# works either way.
regexp -s bootdisk '^\\(?([^,)]+),gpt[0-9]+\\)?\$' "\$root"
if [ -n "\$bootdisk" ]; then
  set esp="\$bootdisk,gpt\$esp_idx"
  set slotroot="\$bootdisk,gpt\$root_idx"
  probe --part-uuid --set=rootuuid (\$slotroot)
  probe --part-uuid --set=varuuid  (\$bootdisk,gpt\$var_idx)
  probe --part-uuid --set=efiuuid  (\$root)
else
  echo "retroforge: cannot derive the boot disk from '\$root' — falling back to a filesystem search"
  search --no-floppy --file $ESP_MARKER --set esp
  search --no-floppy --label $L_ROOT --set slotroot
  sleep 10
fi

# --- how the kernel is told which partitions to mount -------------------------------------------
# PARTLABEL is the FALLBACK, not the answer. Every retroforge disk carries the same eight GPT names,
# so the moment a second one is attached — a card left inserted after an install to internal
# storage, or a card being imaged on a running device — findfs picks one of them and the choice is
# nondeterministic. The PARTUUIDs above are unique per partition and are derived from the disk
# GRUB was chainloaded off, at boot, so they cannot name the wrong disk and no update has to
# rewrite them.
#
# Three ways this can come back empty and they all end here: probe absent from the embedded module
# set (boot/grub.sh MODULES), the boot-disk derivation above having failed, or a device that has
# no partition at all — the last of which sets the literal string "none" rather than failing, which
# is why the test below checks for it by name. The fallback is the exact cmdline that shipped
# before, so it is known-good; it is announced and paused because "ambiguous when two retroforge
# disks are present" is not a state to enter silently on a device with no serial console.
set rootspec="PARTLABEL=$L_ROOT"
set varspec="PARTLABEL=$L_VAR"
set efispec="PARTLABEL=$L_EFI"
if [ -n "\$rootuuid" -a "\$rootuuid" != "none" -a -n "\$varuuid" -a "\$varuuid" != "none" -a -n "\$efiuuid" -a "\$efiuuid" != "none" ]; then
  set rootspec="PARTUUID=\$rootuuid"
  set varspec="PARTUUID=\$varuuid"
  set efispec="PARTUUID=\$efiuuid"
else
  echo "retroforge: PARTUUID derivation failed — falling back to PARTLABEL."
  echo "retroforge: With another retroforge medium attached this can boot the WRONG one:"
  echo "retroforge: remove all but one and reboot."
  sleep 10
fi

# --- the saved board choice ---------------------------------------------------------------------
# One image serves every board, so the DTB — and therefore the menu entry — is the ONE thing the
# user has to tell us. It is saved on the shared ESP rather than on this slot's efi partition so it
# survives a slot switch and an update.
#
# savedefault is NOT a GRUB builtin. grub-mkconfig emits it as a shell function in the config it
# generates, and a config that calls it without defining it just prints "unknown command" per
# menuentry and saves nothing.
load_env -f (\$esp)/EFI/steamos/grubenv saved_entry rf_board_ok
function savedefault {
  saved_entry="\${chosen}"
  save_env -f (\$esp)/EFI/steamos/grubenv saved_entry
}

# --- the board OpenABL names --------------------------------------------------------------------
# OpenABL installs the DTB of its Device model setting, read from our ESP's \dtbs\qcom, before it
# starts the ESP GRUB, and retroforge_dt_model reads that tree's root model. A model we know wins
# over the saved choice and replaces it, so the board is changed in OpenABL's menu once it is set
# there. Only the name is taken: the entry boots this slot's own DTB for that board.
insmod retroforge
retroforge_dt_model abl_model
set abl_board=""
$MODEL_MAP
if [ -n "\$abl_board" ]; then
  if [ "\$abl_board" != "\${saved_entry}" ]; then
    set saved_entry="\$abl_board"
    save_env -f (\$esp)/EFI/steamos/grubenv saved_entry
  fi
fi

# Once the board is known the menu is hidden and there is no wait. It shows again for 3s on another
# try of a slot that did not come up (rf_retry) while the board has never had a boot confirmed
# (rf_board_ok, which retroforge-bootctl mark-good writes), because that is when a wrong board shows
# itself; a confirmed board was not what failed, and a device shut down before its confirmation
# must not get the menu for it. It also shows when no slot had tries left (rf_fallback), and it
# waits on a fresh card that neither OpenABL nor a saved choice can name the board for.
if [ -n "\${saved_entry}" ]; then
  set default="\${saved_entry}"
  set rf_menu=""
  if [ -n "\$rf_fallback" ]; then set rf_menu=1; fi
  if [ -n "\$rf_retry" -a "\${saved_entry}" != "\$rf_board_ok" ]; then set rf_menu=1; fi
  if [ -n "\$rf_menu" ]; then
    set timeout_style=menu
    set timeout=3
  else
    set timeout_style=hidden
    set timeout=0
  fi
else
  # -1 is "no timeout".
  set default=0
  set timeout_style=menu
  set timeout=-1
fi

# --- the console ----------------------------------------------------------------------------------
# rotation MUST be set before terminal_output brings gfxterm up. Patch 0001 reads it exactly once,
# in grub_video_fb_create_render_target_from_pointer, when the video driver builds the framebuffer
# render target — setting it after that point is a silent no-op. 270 is the panel's mounting on
# every board in the catalog: the display is portrait-native and the device is held landscape, so
# an unrotated menu paints sideways.
#
# The colours are read by the normal module each time it paints the menu, so their placement does
# not matter the way rotation's does; they are here to keep the whole console block in one place.
set rotation=270
# SoCs whose panels sit the other way round for GRUB (SM6115 — the MANGMI Air X — and SM4450 — the
# RP Classic and RG 55G1 — want 90, as in ROCKNIX). Only a board that has been chosen once can be
# honoured here: on a fresh card nothing says which board this is, so the first menu paints
# upside-down on them; every boot after the choice is right.
$ROT_OVERRIDES
set menu_color_normal=cyan/blue
set menu_color_highlight=white/blue

loadfont \$prefix/fonts/dejavu-mono.pf2
insmod gfxterm
insmod efi_gop
set gfxpayload=keep
terminal_output gfxterm

# Tries are counted by the ESP GRUB in the grubenv before it hands over to this config.

EOF

# Filename-derived entries: any board .dts with no catalog row. The RP6's top-dpad variant is a
# hardware revision with its own DTB but the same board otherwise, so it inherits its parent's
# bootargs by stripping the suffix, and its entry follows its parent's in the menu (the catalog
# is sorted by device id, which is the menu order). Anything else is a catalog gap and fails the
# build rather than shipping a board nobody can select.
declare -a dbases=() dparents=()
for dts in "$DTS"/*.dts; do
  base="$(basename "$dts" .dts)"
  printf '%s\n' "${pdtbs[@]}" | grep -qx "$base" && continue
  parent="${base%-top-dpad}"
  printf '%s\n' "${pdtbs[@]}" | grep -qx "$parent" || {
    echo "no catalog row for DTB $base and no parent to derive from — add it to boot/boards.map" >&2
    exit 1
  }
  dbases+=( "$base" ); dparents+=( "$parent" )
done

for i in "${!pids[@]}"; do
  emit_entry "${pids[$i]}" "${pnames[$i]}" "${pdtbs[$i]}" "${pbootargs[$i]}"
  for j in "${!dbases[@]}"; do
    [ "${dparents[$j]}" = "${pdtbs[$i]}" ] || continue
    base="${dbases[$j]}"
    derived_name="$(sed -n 's/^[[:space:]]*model = "\(.*\)";/\1/p' "$DTS/$base.dts" | head -1)"
    [ -n "$derived_name" ] || derived_name="${pnames[$i]} (${base#*-})"
    emit_entry "$base" "$derived_name" "$base" "${pbootargs[$i]}"
  done
done
} > "$OUTFILE"

echo "  ok   grub.cfg ($SLOT) -> ${OUTFILE#"$ROOT"/}  ($(grep -c '^menuentry ' "$OUTFILE") entries, root=$L_ROOT)"
