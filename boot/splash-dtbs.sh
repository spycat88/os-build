#!/usr/bin/env bash
# retroforge: the DTBs each slot's boot partition carries in \dtbs.
#
#   boot/splash-dtbs.sh <outdir> <dtb>...
#
# OpenABL builds its Device model list from the root `model` of the .dtb files on the boot drive,
# and installs the chosen model's DTB from the partition of the entry it boots (the entries name no
# devicetree). So these are both what OpenABL draws its own menu with (the name, the panel rotation
# its menu follows) and what Linux boots with. They are the real DTBs, plus one addition where a
# tree lacks it:
#
# A SPLASH REGION. OpenABL 1.2 keeps the display on at ExitBootServices only when the tree it
# installed has /reserved-memory/splash_region (or cont_splash_region), and powers the display
# down otherwise (Efi/DisplayHandover.c), so without the node the panel would go dark at the
# hand-over on every board whose own tree has none. reg is all zeros,
# the <0 addr 0 size> placeholder OpenABL points at its framebuffer.
#
# Runs in the build image (device-tree-compiler provides fdtget/fdtput).
set -euo pipefail

OUTDIR="${1:-}"
[ -n "$OUTDIR" ] && [ $# -gt 1 ] || { echo "usage: boot/splash-dtbs.sh <outdir> <dtb>..." >&2; exit 2; }
shift
for t in fdtget fdtput; do
  command -v "$t" >/dev/null || { echo "splash-dtbs: $t is missing (device-tree-compiler)" >&2; exit 1; }
done

mkdir -p "$OUTDIR"
for src in "$@"; do
  name="$(basename "$src")"
  dst="$OUTDIR/$name"
  cp -f "$src" "$dst"
  fdtget -t s "$dst" / model >/dev/null 2>&1 \
    || { echo "splash-dtbs: $name has no root model, so OpenABL could not list it" >&2; exit 1; }
  if ! fdtget -l "$dst" /reserved-memory >/dev/null 2>&1; then
    fdtput -c "$dst" /reserved-memory
    fdtput -t i "$dst" /reserved-memory '#address-cells' 2
    fdtput -t i "$dst" /reserved-memory '#size-cells' 2
  fi
  if ! fdtget -l "$dst" /reserved-memory | grep -Eq '^(cont_)?splash_region(@|$)'; then
    ac="$(fdtget -t i "$dst" /reserved-memory '#address-cells' 2>/dev/null || echo 2)"
    sc="$(fdtget -t i "$dst" /reserved-memory '#size-cells' 2>/dev/null || echo 2)"
    fdtput -c "$dst" /reserved-memory/splash_region
    # shellcheck disable=SC2046  # one zero per cell is the point
    fdtput -t i "$dst" /reserved-memory/splash_region reg $(printf '0 %.0s' $(seq 1 $((ac + sc))))
  fi
done
echo "  ok   $# ESP DTBs -> $OUTDIR"
