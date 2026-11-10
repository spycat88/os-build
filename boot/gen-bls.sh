#!/usr/bin/env bash
# retroforge boot data generator: the board table and the common kernel command line that every
# Boot Loader Specification entry is written from.
#
#   boot/gen-bls.sh <outdir>
#
# Emits two files, both installed into the root under /usr/lib/retroforge/boot/ (rootfs/
# lib-assemble-boot.sh) so a root and the entries that boot it always come from one build:
#
#   boards.tsv   one row per bootable board: id <TAB> name <TAB> dtb <TAB> model <TAB> bootargs
#   cmdline      the arguments every entry carries, on one line
#
# Pure text: no toolchain, no cross-build, no network, so tests/test-bls.sh runs it on a bare host.
#
# THE ENTRIES THEMSELVES ARE NOT GENERATED HERE, because what goes in them is per-disk and
# per-device: the PARTUUIDs of the slot's partitions (read off the disk being written), and the
# board (read off the devicetree the device booted with). The writers -- image/make-sdcard.sh for a
# card, the post-install hook for an update, the installer for an internal install, and
# retroforge-bootctl when a fresh card confirms its first boot -- all build them with one function,
# bls_entry_text in rootfs/overlay/usr/lib/retroforge/install/lib-bls.sh, from these two files.
#
# Two input files, both of which are the single source of truth for what they carry:
#   boot/boards.map              build-time board catalog (id / menu name / dtb / board bootargs)
#   kernel/dts/qcom/*.dts        each board's root `model`, which is how a running system (and
#                                OpenABL's Device model setting) names the board
set -euo pipefail
shopt -s nullglob

OUTDIR="${1:-}"
[ -n "$OUTDIR" ] || { echo "usage: boot/gen-bls.sh <outdir>" >&2; exit 2; }

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BOARDS="$ROOT/boot/boards.map"
DTS="$ROOT/kernel/dts/qcom"
[ -f "$BOARDS" ] || { echo "missing input: $BOARDS" >&2; exit 1; }

# --- the common kernel command line -------------------------------------------------------------
# Board-specific args come from boards.map; root=/retroforge.var=/retroforge.slot=
# are per slot and per disk, and lib-bls.sh adds them when it writes an entry. The EFI stub
# OVERWRITES /chosen/bootargs with the loader's command line, so every argument has to be in the
# entry's `options` or it is not applied.
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

# A board's root `model`: the name the running system reads back from
# /sys/firmware/devicetree/base/model, and the one OpenABL's Device model setting holds. A .dts
# without a model of its own takes the one from the file it #includes.
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

# Filename-derived rows: any board .dts with no catalog row. The RP6's top-dpad variant is a
# hardware revision with its own DTB but the same board otherwise, so it inherits its parent's
# bootargs by stripping the suffix, and its row follows its parent's. Anything else is a catalog gap
# and fails the build rather than shipping a board nobody can boot.
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

mkdir -p "$OUTDIR"
tsv="$OUTDIR/boards.tsv"
tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT

emit_row() {  # <id> <name> <dtb> <bootargs>
  local eid=$1 ename=$2 edtb=$3 eargs=$4 model
  [ -f "$DTS/$edtb.dts" ] || { echo "board $eid names DTB $edtb, which has no kernel/dts/qcom/$edtb.dts" >&2; exit 1; }
  model="$(dts_model "$DTS/$edtb.dts")"
  [ -n "$model" ] || { echo "kernel/dts/qcom/$edtb.dts has no root model, so a running system could not name board $eid" >&2; exit 1; }
  case "$eid$ename$edtb$model$eargs" in
    *$'\t'*) echo "board $eid: a field contains a tab" >&2; exit 1 ;;
  esac
  printf '%s\t%s\t%s\t%s\t%s\n' "$eid" "${ename:-$eid}" "$edtb" "$model" "$eargs"
}

{
  for i in "${!pids[@]}"; do
    emit_row "${pids[$i]}" "${pnames[$i]}" "${pdtbs[$i]}" "${pbootargs[$i]}"
    for j in "${!dbases[@]}"; do
      [ "${dparents[$j]}" = "${pdtbs[$i]}" ] || continue
      base="${dbases[$j]}"
      derived_name="$(dts_model "$DTS/$base.dts")"
      [ -n "$derived_name" ] || derived_name="${pnames[$i]} (${base#*-})"
      emit_row "$base" "$derived_name" "$base" "${pbootargs[$i]}"
    done
  done
} > "$tmp"

# The model is the key a running system looks its board up by, so two rows sharing one would make
# the lookup pick whichever comes first. Refuse it here, where it is a build failure, rather than on
# a device, where it is the wrong command line.
dup="$(cut -f4 "$tmp" | sort | uniq -d | head -1)"
[ -z "$dup" ] || { echo "two boards share the devicetree model '$dup' — a running system could not tell them apart" >&2; exit 1; }
dup="$(cut -f1 "$tmp" | sort | uniq -d | head -1)"
[ -z "$dup" ] || { echo "two boards share the id '$dup'" >&2; exit 1; }

{
  echo "# retroforge board table. GENERATED by boot/gen-bls.sh from boot/boards.map and kernel/dts/qcom; do not edit."
  echo "# id	name	dtb	model	bootargs"
  cat "$tmp"
} > "$tsv"
printf '%s %s\n' "$BOOT_CMDLINE" "$SESSION_CMDLINE" > "$OUTDIR/cmdline"

echo "  ok   boards.tsv ($(grep -vc '^#' "$tsv") boards) + cmdline -> ${OUTDIR#"$ROOT"/}"
