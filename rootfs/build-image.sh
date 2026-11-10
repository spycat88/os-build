#!/usr/bin/env bash
# retroforge Phase 1 image flow — base rootfs + device firmware + kernel -> rootfs.img.
#
# Chains the pieces into one bootable read-only Btrfs root:
#   1. bootstrap the root from packages               (rootfs/customize-base.sh)
#   2. fetch device-proprietary firmware (pinned)     (firmware/fetch-qcom-fw.sh)
#   3. assemble the read-only Btrfs root              (rootfs/assemble-rootfs.sh)
#
# Prereq: unified kernel already built (kernel/build.sh) so out/ has vmlinuz + modroot,
# plus the initramfs (image/mkinitramfs.sh) and the boot data (boot/gen-bls.sh) — the assembler
# bakes all three into the root.
# Device firmware is fetched from the pinned retroforge-linux/qcom-firmwares repo — no proprietary
# blobs ship in-repo. Steps 3-4 run in the retroforge-build image.
#
#   rootfs/build-image.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT/build/lib-container.sh"
OUT="$ROOT/out"
FW="$ROOT/firmware/qcom-fw"
DK=(ctr run --rm -v "$ROOT":/src -w /src retroforge-build)

[ -f "$OUT/vmlinuz" ] \
  || { echo "no kernel: out/vmlinuz — run kernel/build.sh first" >&2; exit 1; }
[ -f "$OUT/initramfs.cpio.zst" ] \
  || { echo "no initramfs: out/initramfs.cpio.zst — run image/mkinitramfs.sh first" >&2; exit 1; }

# 1. the root, laid down from packages into an empty tree (pinned, idempotent): the `base`
# metapackage plus the release runtime (NetworkManager, openssh, mesa+Turnip+vulkan-tools).
# customize-base.sh prints a host absolute path; step 4 runs in a container with the repo
# bind-mounted at /src, so translate the $ROOT prefix to /src for the in-container call.
BASE="$("$ROOT/rootfs/customize-base.sh")"
BASE_CTR="/src/${BASE#"$ROOT"/}"

# 2. device firmware — fetch the pinned device-proprietary blobs (idempotent).
"$ROOT/firmware/fetch-qcom-fw.sh"
if [ ! -d "$FW" ]; then
  echo "no device firmware ($FW missing) — firmware/fetch-qcom-fw.sh did not stage it." >&2
  exit 1
fi

# 3. assemble the read-only Btrfs root. Forward the TEST-ONLY credential env (a no-op
# unless RETROFORGE_DEV=1) so a dev card can carry Wi-Fi + SSH creds; see assemble-rootfs.sh.
# Env flags must precede the image name, so spell this docker run out rather than reuse DK.
ctr run --rm -v "$ROOT":/src -w /src \
  -e RETROFORGE_DEV -e RETROFORGE_WIFI -e RETROFORGE_WIFI_SSID -e RETROFORGE_WIFI_PSK -e RETROFORGE_SSH_PUBKEY \
  -e RETROFORGE_SS_DEVID -e RETROFORGE_SS_DEVPASSWORD -e RETROFORGE_DEBUG \
  retroforge-build rootfs/assemble-rootfs.sh "$BASE_CTR"

cat <<EOF

Image flow done. Read-only root at out/images/rootfs.img.
The root carries its own boot half (Phase 5): /boot/{vmlinuz, initramfs-retroforge.img, dtbs} and the
/usr/lib/retroforge/boot mirror (run boot/gen-bls.sh for out/boot/* first).
Next — the flashable card:
  image/make-sdcard.sh             # -> out/images/sdcard.img (or `make sdcard`)
EOF
