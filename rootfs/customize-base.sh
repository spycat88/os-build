#!/usr/bin/env bash
# retroforge root bootstrap — lay the RELEASE root down from packages, into an empty tree.
#
# PHASE 4c. This script used to `docker export` a vendor-built base image and pacman-install
# on top of it. It now bootstraps: `pacman -r work/base` against an EMPTY directory, so every
# file on the image arrives from a package that rootfs/manifest.lock names and
# rootfs/fetchlock.sh sha256-verifies. 116 of the lock's rows used to be class `base` —
# content that shipped inside the image with no file to install and nothing to check. There is
# no such class any more.
#
# Docker is still here, and still needs qemu binfmt: an aarch64 root has to be laid down by an
# aarch64 pacman running aarch64 install scriptlets, and a container is how we get an aarch64
# userspace on an x86 host. It is the EXECUTION ENVIRONMENT (build/builder.pin, the same pin
# packages/build-overlay.sh builds in) and no longer the CONTENT SOURCE. Consequences:
#   - /.dockerenv is never created in the target root, so it cannot reach a device and make
#     systemd-detect-virt report a container (which silently skips ~13 units).
#   - nothing is inherited, so rootfs/assemble-rootfs.sh has nothing to scrub.
#   - the three identity files no package owns are ours: /etc/os-release (rootfs/conf/os-release),
#     /etc/locale.conf and /etc/hostname, all written below.
#
# The upstream holo-core package set is minimal: no Wi-Fi supplicant, no SSH server, no
# Vulkan/Mesa userspace. On top of the `base` metapackage this lays the runtime that ships in
# every build —
#   networkmanager   Wi-Fi manager (release + test); does its own DHCP
#   wpa_supplicant   NM's Wi-Fi WPA backend (optdepend of networkmanager, so installed explicitly)
#   bluez/bluez-utils Bluetooth stack + bluetoothctl (the shell pairs controllers/audio)
#   openssh          SSH server (dropbear isn't in the pinned holo repo)
#   wireless-regdb   regulatory database — REQUIRED for 5 GHz (else channels are no-TX)
#   mesa + vulkan-freedreno (Turnip) + vulkan-tools   GPU / Vulkan
#   vulkan-mesa-layers  for the vram-report-limit implicit layer retroforge-launch turns on (4 GB heap)
# Runtime deps of precompiled packages are NOT hardcoded here — each
# packages/<name>/prebuilt.pin declares its own `deps:`, aggregated into the install list.
# The result lands in work/base/ — the directory rootfs/assemble-rootfs.sh consumes.
#
# Components NOT in the holo repo and not built from source here ship as
# precompiled-package PINS: each packages/<name>/prebuilt.pin declares a tarball by
# url + sha256 (+ tar strip-components). They are fetched + verified on the host and
# extracted into the base here; add one by dropping a new pin file — no code change.
# Per-component config / service enablement (if any) is injected later by assemble-rootfs.sh.
#
# This installs PACKAGES only — it writes NO network/SSH config and enables NO services.
# First-boot networking is the shell's responsibility on release. All Wi-Fi/SSH
# scaffolding (.link/.network, regdom, wpa creds, sshd + host keys, enable-symlinks) is a
# DEV-ONLY injection done later by assemble-rootfs.sh under RETROFORGE_DEV=1 (see it).
#
# This EXECUTES arm64 userspace (pacman, its install scriptlets, locale-gen, useradd), so it
# needs qemu binfmt — registered on demand via tonistiigi/binfmt. Network required.
#
#   rootfs/customize-base.sh
#
# Prints the bootstrapped rootfs path on stdout. FORCE=1 re-runs.
#
# TWO INSTALL MODES (Phase 4a step 2). Default is LOCKED: rootfs/fetchlock.sh materializes
# exactly the package files rootfs/manifest.lock declares, sha256-verified on the host, and the
# container installs that explicit list with `pacman -U`. No repo database is synced, so no
# dependency resolution happens implicitly at build time.
#   RETROFORGE_RESOLVE=1  re-resolve from PKGS with `pacman -Sy` (the pre-lock behaviour). This is
#                       how the lock is REGENERATED, so it must exist: `make relock` runs this
#                       mode and then rootfs/genmanifest.sh over the result. Never ships.
# The two modes produce different trees by design (that is the point of relocking), so the mode
# is folded into the reuse-cache key below — a resolve-built base can never satisfy a locked
# build, and vice versa.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# The EXECUTION environment, not the content source (see the header). Shared with
# packages/build-overlay.sh: one pinned arm64 builder image, used by both stages.
. "$ROOT/build/lib-pins.sh"
LOCKFILE="$ROOT/rootfs/manifest.lock"
PACMANCONF="$ROOT/rootfs/conf/pacman.conf"
OSRELEASE="$ROOT/rootfs/conf/os-release"
# The pinned system UID/GID range. It SHIPS from rootfs/overlay (the device's own boot-time sysusers
# run must agree with it), but it has to be in the target root BEFORE the transaction whose
# sysusers hook allocates the ids — so this script reads it from there and stages it in early.
# There is exactly one copy; assemble-rootfs.sh later re-lays the identical file with the overlay.
IDPIN="$ROOT/rootfs/overlay/usr/lib/sysusers.d/01-retroforge-enforce-ids.conf"
DEST="$ROOT/work/base"
RESOLVE="${RETROFORGE_RESOLVE:-}"

# The root's foundation. `base` is the metapackage the vendor's own image is built from, so
# declaring it reproduces the shipped set exactly (measured: `pacman -r <empty> -Sy base PKGS`
# resolves the same 394 packages, name and version, that the old export-plus-install path
# produced) instead of hand-reconstructing a minimal list that would drift from upstream on
# every bump. It pulls `pacman` and `archlinux-keyring` in as dependencies; those are removed
# from the RELEASE tree afterwards by rootfs/seal-rootfs.sh, exactly as before — 4c changes
# where content comes from, not what it contains. See docs/archive/phase4.md.
BOOTSTRAP_PKGS=(base)

# Release runtime packages — credentials are NEVER installed here (test-only at assemble).
#   gamescope + seatd   the session compositor and its seat manager.
#   xorg-xwayland       gamescope's nested X server; the shell and most emulators are X11 clients.
#   bluez/bluez-utils   Bluetooth stack (controllers, audio); the WCN7850 BT firmware ships from
#                       assemble-rootfs.sh, bluetoothd is enabled by 60-retroforge-bluetooth.preset.
#   networkmanager      Wi-Fi manager. Ships no auto-enable preset; the network preset below enables it.
#   pipewire stack + alsa-ucm-conf   audio. alsa-ucm-conf supplies the codec/lib snippets the device
#                       UCM2 profiles under rootfs/overlay Include. pipewire-jack is not needed.
#   rtkit               REQUIRED for PipeWire realtime priority: module-rt only uses the RTKit path
#                       (an RLIMIT_RTPRIO grant was tried on HW and does not work). D-Bus activated.
#   libinput-tools      the `libinput` CLI that retroforge-powerbuttond and retroforge-suspend read the
#                       power key through. Our GUI-less build (packages/libinput/), from the overlay.
#   e2fsprogs           /home is an ext4 partition grown to fill the card on first boot (resize2fs).
#   noto-fonts(+emoji)  the base only carries Latin adwaita-fonts; non-Latin UI text is tofu
#                       without these. noto-fonts-cjk is deliberately NOT here: 299 MiB, a fifth
#                       of the root, so CJK text renders as tofu (2026-10-03 disk-space trim).
# No display manager. retroforge-session.service (rootfs/overlay) logs player in through PAM itself,
# which gives the ACTIVE seat0 logind session stock polkit (allow_active) authorizes Wi-Fi +
# timezone against. SDDM did the same job and dragged in qt6-declarative (122 MiB) for a greeter
# that was never shown. No ffmpeg either (190 MiB with its codec libs, nothing in PKGS needs it):
# an emulator that wants it pulls it in as its own dependency.
#   mangohud            the performance overlay gamescope spawns with --mangoapp. Overlay build with
#                       the Qualcomm/Adreno GPU + battery patches (packages/mangohud).
#   retroforge-gpu-priority  implicit Vulkan layer: an emulator's queues at LOW GPU priority, so the
#                       shell's overlay preempts it. Enabled by retroforge-launch. Overlay, ours.
#   python + python-gobject  the interpreter and D-Bus bindings behind retroforge-powerd and the other
#                       shipped python tools; a missing one fails at the shebang or the import.
#   scx-scheds          sched_ext schedulers (scx_lavd). Installed but OFF by default: retroforge-powerd
#                       selects one only when the user picks it. Needs CONFIG_SCHED_CLASS_EXT. Overlay.
#   rauc                A/B update client, the snapshot's 1.15.2 (must be >= 1.15.1: 1.14 cannot
#                       install a dm-verity bundle on a kernel >= 6.19).
#                       Reads /etc/rauc/system.conf: bootloader=grub over the ESP's grubenv.
#   btrfs-progs         `btrfstune -U` in the post-install hook, so the two slots never share an fsid.
#   rsync               the post-install hook copies the running /var into the new slot's /var.
#   gptfdisk            sgdisk: the internal installer reads and writes the GPT with it.
#   dosfstools          mkfs.vfat: the installer's ESP and both efi partitions.
#   mtools              mdir: reads a foreign ESP's content, which is how select-target.sh recognises
#                       another distribution's install. It refuses to run without it.
#   parted              partprobe: re-reads the table after the carve; recon() requires it outright.
#   earlyoom            userspace OOM killer, acting before allocation fails (policy in
#                       earlyoom.service.d/retroforge.conf, enabled by 60-retroforge-earlyoom.preset).
#   zram-generator      the image's only swap device; needs CONFIG_ZRAM (kernel/kernel.config).
#   udisks2             removable-media service behind the storage automount and format paths.
#   f3                  f3probe, the counterfeit-card check before formatting an SD card. Overlay.
#   upower              battery service; needs kernel patches 0526/0527 for charge_full/charge_now.
#                       D-Bus activated, so it needs no preset.
#   brightnessctl       OpenGamepadUI's ONLY usable backlight provider (display_manager.gd picks it
#                       when `which brightnessctl` succeeds; the other is a SteamOS helper we do not
#                       ship) — without it the brightness slider is absent. As the session user it
#                       sets the panel through logind's SetBrightness, so no udev/group grant is needed.
#                       Overlay (packages/brightnessctl): not in the holo snapshot.
#   which               OpenGamepadUI probes every helper with `which <cmd>` before using it:
#                       brightnessctl (no brightness slider without it), wpctl (volume), mangoapp,
#                       bwrap. base does not pull `which` in, so without it each probe fails and the
#                       feature silently disappears (HW 2026-10-02: no brightness slider).
#   powerstation        org.shadowblip.PowerStation, the only backend OpenGamepadUI's performance menu
#                       speaks (core count, GPU clock range). Overlay (packages/powerstation), patched
#                       for non-SMT CPUs and devfreq SoC GPUs.
#   inputplumber        the input daemon: each board's pad/MCU in, one virtual X-Box Elite pad out.
#                       Overlay (packages/inputplumber) since 0.82.0 — a prebuilt.pin before that —
#                       patched with upstream PR #757 (input layers: the Guide-modifier emulator
#                       hotkeys). Board configs we carry beyond upstream's stay in
#                       rootfs/overlay/etc/inputplumber/.
#   opengamepadui       the shell. Overlay (packages/opengamepadui): upstream's aarch64 release with
#                       the pck rebuilt from source + patches (it crash-loops on DT boards otherwise).
#   fuse3               fusermount3 (setuid, already on guard-rootfs.sh's permit list) so emulator
#                       AppImages run as shipped: the type-2 runtime mounts its squashfs through it
#                       and, without it, aborts ("Cannot mount AppImage, please check your FUSE
#                       setup", HW 2026-10-03, DuckStation). Emulators are not in the image; the
#                       RetroForge OGUI plugin downloads them into /home (plan Phase 3/4).
#   ksmbd-tools         userspace for ksmbd, the in-kernel SMB3 server (CONFIG_SMB_SERVER=m) behind the
#                       player's network shares (/etc/ksmbd/ksmbd.conf: roms, bios, saves, states;
#                       guest read-write, on by default). Overlay (packages/ksmbd-tools): not in the
#                       holo snapshot. Chosen over Samba, ~110 MiB+ with its dependencies.
#   avahi               mDNS: announces retroforge.local and the SMB shares (/etc/avahi/services/
#                       smb.service). Already pulled in as a dependency; listed because the image
#                       now ENABLES avahi-daemon (60-retroforge-shares.preset), which must not depend on
#                       some other package keeping it around.
#   PortMaster's needs (Main menu > Emulators downloads it into ~/roms/ports/PortMaster; plan Phase
#   4b). Its GUI is python + pysdl2 on the system SDL2 libraries:
#   sdl2_ttf/sdl2_image  its text and images. sdl2_image's JPEG XL support brings libjxl + highway
#                       + gperftools (~17 MiB), measured 2026-10-11.
#   sdl2_mixer          its sounds and music; pysdl2 refuses to load the GUI without it. Overlay
#                       (packages/sdl2_mixer): not in the holo snapshot.
#   squashfuse          ports mount their runtimes (Godot, mono, ...) from squashfs images with
#                       `mount`; as player, without root, a FUSE mount is the only way. Pulls fuse2
#                       (its fusermount is already on guard-rootfs.sh's setuid permit list).
#   mesa-utils          glxinfo: PortMaster's per-system GL setup files (libgl_<system>.txt, ours
#                       too) ask it whether desktop GL exists before falling back to gl4es.
#   unzip               PortMaster.sh installs runtime bundles dropped in its autoinstall folder
#                       with it, and some ports unpack their game data with it on first run.
#   openal/libtheora    the LÖVE runtime PortMaster fetches (runtimes/love_11.5) links both and
#                       does not ship them; PortMaster's splash, its first-run port patcher and
#                       every LÖVE port run on it. Measured 2026-10-11 on the ACE: +5.0 MiB.
#   xxhash              xxhsum, which /usr/lib/retroforge/steam-x86-guest checks FEX's x86 RootFS with
#                       (FEX's links file gives only an XXH3-64). Already pulled in by rsync; listed so
#                       that check does not depend on rsync keeping it around.
#   fuse-overlayfs      lays our x86 Mesa (/usr/lib/retroforge/x86-mesa) over that RootFS, read-only,
#                       as the player (/usr/lib/retroforge/steam-x86-guest).
#   Valve's arm64 Steam client, which Main menu > Emulators > Steam Client downloads into the home,
#   run raw on the host by /usr/bin/steam, as Nova-Deck does, rather than inside Valve's Steam
#   Runtime container (games' own pressure-vessel cannot start nested inside it):
#   gtk2                steamui.so links libgtk-x11-2.0 and libgdk_pixbuf-2.0. Back in the root for
#                       it (dropped 2026-10-03): ~96 MiB installed with its new deps before the trim
#                       (gtk2 38, glycin 17, librsvg 10, adwaita-fonts 7), measured 2026-10-17.
#   libibus             steamwebhelper (CEF) links libibus-1.0.so.5: without it the helper does not
#                       load at all (tested 2026-10-17 under qemu; Nova-Deck saw the same). The library
#                       alone, 3.7 MiB and no new deps; `ibus` itself would bring gtk3, gtk4 and
#                       llvm-libs (142 MB download).
#   lsof                the client maps each localhost connection to a process with `lsof` and
#                       rejects its own UI's websocket when it cannot ("WebUITransport: Connection
#                       rejected", then an "Unexpected Transport Error" dialog and no UI). HW
#                       2026-10-17 on the ACE: with lsof on PATH it reaches the sign-in. 392 KiB,
#                       glibc + libtirpc only (Nova-Deck ships it too).
#                       Every library the client's arm64 ELFs link resolves against PKGS + gtk2 and
#                       libibus (checked in the builder 2026-10-17); no ffmpeg, the client ships its
#                       own libav*.
#   tailscale           the Tailscale node agent + CLI, one static binary (Settings > Network > VPN,
#                       the plugin's tailscale_settings.gd). Overlay (packages/tailscale): not in the
#                       snapshot. tailscaled is NOT enabled: off until the player turns it on, then
#                       started by the shell (polkit 50-retroforge-tailscale.rules); its state is
#                       /var/lib/tailscale.
#   zlib-ng-compat      zlib-ng as the system libz.so.1, in place of core/zlib (it provides zlib and
#                       libz.so=1-64; nothing in the snapshot needs a versioned zlib). On the Air X,
#                       32 MB of libraries, against zlib 1.3.2 (2026-10-23): inflate 1.4-1.5x, deflate
#                       2x, crc32 6-10x, adler32 2-6x, on A73 and A53 alike; no LSE atomics; level-1
#                       output ~25% bigger. It speeds what uses the system libz (our Python tools, OGUI,
#                       PortMaster ports); emulators and Steam's runtime carry their own zlib.
PKGS=(wpa_supplicant wireless-regdb openssh vulkan-icd-loader vulkan-freedreno vulkan-mesa-layers vulkan-tools retroforge-gpu-priority mesa gamescope seatd mangohud bluez bluez-utils networkmanager alsa-ucm-conf pipewire wireplumber pipewire-pulse pipewire-alsa rtkit e2fsprogs xorg-xwayland noto-fonts noto-fonts-emoji python python-gobject scx-scheds rauc btrfs-progs rsync gptfdisk dosfstools mtools parted earlyoom zram-generator udisks2 f3 upower libinput-tools brightnessctl opengamepadui powerstation inputplumber which fuse3 ksmbd-tools avahi sdl2_ttf sdl2_image sdl2_mixer squashfuse mesa-utils unzip openal libtheora rmtfs msm-firmware-loader hexagonrpcd xxhash fuse-overlayfs gtk2 libibus lsof tailscale zlib-ng-compat)

# Dev-only packages — installed ONLY under RETROFORGE_DEV=1, NEVER in a release base.
# On-device bring-up tools: evtest reads raw /dev/input events; usbutils provides lsusb.
# xorg-xprop + xorg-xwininfo: read the ACTUAL attributes of a window inside gamescope's nested
# Xwayland. Added 2026-08-06 because the Steam bootstrap update dialog is created and shown
# (`Create window` / `Show window`) yet gamescope never selects it as focus and commits zero flips,
# and with no X tools on the image the only way to ask "is it override-redirect / IsViewable /
# what size" was to infer it from gamescope's source. Inference is what made that investigation
# expensive; measuring is cheap. DEV-only — a release card has no business carrying X debug tools.
# alsa-utils: amixer/alsamixer to read and set the mixer, alsaucm to ask what UCM actually resolved,
# aplay + speaker-test to generate a tone without going through Steam. Added 2026-08-10 for the
# same reason as the X tools, and it cost the same way: the MANGMI Pocket Max (SM8250) came up
# silent, and with no ALSA tools on the image every "which control is wrong" question had to be
# answered by reading driver source and guessing. Worse than slow — `amixer` being ABSENT made
# every control query print nothing, which reads exactly like "the control does not exist" and
# sent that investigation down a wrong path (see docs/worklog/DONE.md). The card is a handheld whose audio
# routing is per-board UCM; not being able to inspect it is a permanent tax.
# ffmpeg: dropped from the release root for space (2026-10-03), kept here because the iris/venus
# hardware video decode bring-up is validated with `ffmpeg -c:v h264_v4l2m2m` (kernel/SOURCE.pin).
DEV_PKGS=(evtest usbutils xorg-xprop xorg-xwininfo alsa-utils ffmpeg)

# Precompiled external packages: every packages/<name>/prebuilt.pin (url + sha256 + strip)
# is fetched on the host and extracted into the base. PREBUILT_DIR stages the verified
# tarballs + a manifest; the manifest is also stored in the base as the reuse cache key.
PREBUILT_DIR="$ROOT/work/prebuilt"
# Persistent pacman package cache. The emulated `pacman -Sy` downloads all runtime packages from
# the holo mirror on every base rebuild (a new prebuilt busts the reuse cache even when the package
# SET is unchanged), and that mirror intermittently truncates a transfer. Bind-mounting a host
# cache into /var/cache/pacman/pkg lets a retry reuse the packages that DID land and re-fetch only
# the truncated one, instead of re-rolling the whole 267-package download. It PERSISTS across runs
# like PREBUILT_DIR; docker export excludes bind-mounts, so cached packages never bloat the base
# (which is also why the in-container `pacman -Scc` is dropped — it would only wipe this cache).
PACMAN_CACHE="$ROOT/work/pacman-cache"
mkdir -p "$PACMAN_CACHE"
PREBUILT_PINS=("$ROOT"/packages/*/prebuilt.pin)
pin_field() { sed -n "s/^$2:[[:space:]]*//p" "$1" | head -1; }
# One row per pin, sorted: `name sha256 strip kind dest mode deps...`. It identifies exactly which
# prebuilts a base carries AND the holo-repo runtime deps they declare, so a deps change also
# busts the reuse cache. The container re-reads this file as its placement list.
#
# `deps` stays LAST because it is the only space-separated (multi-token) field; everything the
# container splits positionally must precede it. `dest` and `mode` use '-' rather than an empty
# field so a pin without one cannot shift the columns. `mode` is the kind:file install mode
# (default 0644; 0755 for a pinned file that a unit executes directly). The container
# captures trailing deps tokens into a throwaway var (see the placement loop) — they are
# pacman-installed via INSTALL_PKGS instead.
prebuilt_manifest() {
  local pin kind dest strip mode
  for pin in "${PREBUILT_PINS[@]}"; do
    [ -e "$pin" ] || continue
    kind="$(pin_field "$pin" kind)";   kind="${kind:-tar}"
    dest="$(pin_field "$pin" dest)";   dest="${dest:--}"
    strip="$(pin_field "$pin" strip)"; strip="${strip:-0}"
    mode="$(pin_field "$pin" mode)";   mode="${mode:--}"
    printf '%s %s %s %s %s %s %s\n' "$(pin_field "$pin" name)" "$(pin_field "$pin" sha256)" \
                                 "$strip" "$kind" "$dest" "$mode" "$(pin_field "$pin" deps)"
  done | sort
}
EXPECTED_MANIFEST="$(prebuilt_manifest)"

# Aggregate the holo-repo runtime deps each prebuilt declares (deps: in its pin). They ship in
# every base that carries the prebuilt (release), so they extend the release install list —
# e.g. InputPlumber (a pin until 0.82.0) declared `deps: libiio` there, not hardcoded above.
PREBUILT_DEPS=()
for pin in "${PREBUILT_PINS[@]}"; do
  [ -e "$pin" ] || continue
  pin_deps="$(pin_field "$pin" deps)"
  if [ -n "$pin_deps" ]; then PREBUILT_DEPS+=($pin_deps); fi   # word-split: deps is space-separated
done

# The reuse cache must bust whenever the installed package SET changes — a new release
# package, a new prebuilt's declared deps, or the test-only packages toggling in/out. Probing
# for one sentinel file per package doesn't scale (and silently misses any package without a
# sentinel), so instead record the whole sorted install set in ONE marker file
# (/usr/lib/retroforge/pkgs) and compare it. prebuilt.manifest stays a SEPARATE marker because
# the container also reads it verbatim as the tar-extraction list, so it must hold only
# prebuilt rows.
#
# Under LOCKED mode this list is no longer what pacman resolves — rootfs/manifest.lock is. It
# stays the human-editable DECLARATION of intent (edit it, `make relock`, review the diff) and
# is still asserted against the built tree in-container via `pacman -T`, which catches a leaf
# package that fell out of the lock and would otherwise vanish without a dependency error.
INSTALL_PKGS=("${BOOTSTRAP_PKGS[@]}" "${PKGS[@]}" "${PREBUILT_DEPS[@]}")
# Dev-only tooling is installed by NAME even under LOCKED mode (see the pacman -Sy near the end
# of the container script). It is deliberately NOT in the lock: the lock describes the RELEASE
# image, which is the tree the step-4 seal guard runs against. Keeping test rows out of it also
# means `make relock` must run release — genmanifest.sh refuses a dev base for that reason.
if [ "${RETROFORGE_DEV:-}" = "1" ]; then
  INSTALL_PKGS+=("${DEV_PKGS[@]}")
fi
# Canonical (sorted, de-duped) install set — the reuse-cache key recorded in the base below.
EXPECTED_PKGS="$(printf '%s\n' "${INSTALL_PKGS[@]}" | sort -u)"

# From-source overlay packages (packages/*/source.pin -> work/repo/<arch>/, built by
# packages/build-overlay.sh) override holo binaries via a higher pkgrel. They don't change the
# install SET, so fold the repo db's content hash into the reuse key — a rebuilt overlay (new
# pkgrel/patch) then busts the cache even though PKGS is unchanged.
# Arch-scoped (aarch64), shared across SoCs — overlay packages are plain aarch64 binaries every
# device reuses, so they are NOT under work/base/. See packages/build-overlay.sh.
OVERLAY_REPO="$ROOT/work/repo/aarch64"
OVERLAY_DB="$OVERLAY_REPO/retroforge.db.tar.zst"
if [ -f "$OVERLAY_DB" ]; then
  EXPECTED_PKGS="$EXPECTED_PKGS
overlay:$(sha256sum "$OVERLAY_DB" | cut -d' ' -f1)"
fi

# The builder (build/builder.pin, via build/lib-pins.sh): a tag keyed on its tarball's sha256.
REF="$(pins_builder_ref)"
# Fold the builder into the reuse key. It contributes no FILES to the root any more, but it is
# the pacman that resolves and lays them down, so a bump still has to rebuild rather than be
# silently satisfied by a tree the previous builder produced.
EXPECTED_PKGS="$EXPECTED_PKGS
env:$REF"

# Package-repo snapshot pin (build/snapshot.pin) — the repo every row of the root is installed from.
# We write our own mirrorlist from it (rootfs/conf/pacman.conf Includes it) rather than inherit the
# vendor's; lib-pins.sh refuses a moving alias.
SNAPSHOT="$(pins_snapshot)"
# Fold the revision into the reuse key: bumping the pin must rebuild the base even when the
# package SET is unchanged, which is the whole point of pinning it.
EXPECTED_PKGS="$EXPECTED_PKGS
snapshot:$SNAPSHOT"

# Mode + lock into the reuse key. Three distinct rebuild triggers, all of which the package SET
# alone would miss:
#   mode:      a resolve-built base must NEVER satisfy a locked build. Without this token
#              `make relock` would leave an unverified tree behind that the next `make sdcard`
#              happily reuses and ships.
#   lock:      editing the lock (a package bump, a relock) must rebuild the base.
#   dev:       recorded explicitly so genmanifest.sh can REFUSE a dev base; the dev packages
#              are already in the sorted set above, but not in a form anything can detect.
if [ -n "$RESOLVE" ]; then
  EXPECTED_PKGS="$EXPECTED_PKGS
mode:resolve"
else
  [ -f "$LOCKFILE" ] || { echo "no manifest: $LOCKFILE (RETROFORGE_RESOLVE=1 to re-resolve)" >&2; exit 1; }
  EXPECTED_PKGS="$EXPECTED_PKGS
mode:locked
lock:$(sha256sum "$LOCKFILE" | cut -d' ' -f1)"
fi
if [ "${RETROFORGE_DEV:-}" = "1" ]; then
  EXPECTED_PKGS="$EXPECTED_PKGS
dev:1"
fi
# This script itself. Everything above describes the INPUTS; the tree is also a product of the
# steps below (which packages are placed where, what runs offline with --root=, what /dev nodes
# exist), and none of that is visible in any other key. Without this a bootstrap fix is silently
# a no-op on a tree the reuse check still considers current -- which is exactly what happened on
# 2026-07-26, twice over, since the Makefile was not listing this file as a prerequisite either.
EXPECTED_PKGS="$EXPECTED_PKGS
script:$(sha256sum "$0" | cut -d' ' -f1)"
# The UID/GID pin. It decides the numbers baked into this tree's /etc/passwd and /etc/group, and
# nothing else in the key would notice it changing — the package SET is identical either way. Its
# whole point is that those numbers are stable, so an edit must rebuild rather than be satisfied by
# a base carrying the previous allocation.
[ -f "$IDPIN" ] || { echo "no UID/GID pin: $IDPIN" >&2; exit 1; }
EXPECTED_PKGS="$EXPECTED_PKGS
ids:$(sha256sum "$IDPIN" | cut -d' ' -f1)"
ctr_require "the root bootstrap"
[ -f "$PACMANCONF" ] || { echo "no bootstrap pacman config: $PACMANCONF" >&2; exit 1; }
[ -f "$OSRELEASE" ]  || { echo "no os-release declaration: $OSRELEASE" >&2; exit 1; }

# Already bootstrapped? Reuse unless FORCE=1 (the emulated install is slow). Both markers must
# match the current inputs, else a package add/removal or a prebuilt pin bump would be silently
# missed. The pkgs marker is written last in-container, so its presence also proves the
# bootstrap completed (no need for per-package existence sentinels).
if [ -z "${FORCE:-}" ] \
   && [ "$(cat "$DEST/usr/lib/retroforge/pkgs" 2>/dev/null)" = "$EXPECTED_PKGS" ] \
   && [ "$(cat "$DEST/usr/lib/retroforge/prebuilt.manifest" 2>/dev/null)" = "$EXPECTED_MANIFEST" ]; then
  echo "[retroforge] bootstrapped root present: ${DEST#"$ROOT"/} (FORCE=1 to rebuild)" >&2
  echo "$DEST"; exit 0
fi

# Import the builder if it is not already local (it also registers arm64 binfmt when needed).
pins_builder_ensure >/dev/null

# Fetch + verify every pinned prebuilt on the host (network here); staged into PREBUILT_DIR,
# mounted read-only into the bootstrap container below so they land in the target root.
#
# PREBUILT_DIR PERSISTS across runs (it is NOT wiped) so it doubles as the download cache: a
# re-customize — the base cache busts on any package/overlay change — reuses a staged blob whose
# sha still matches instead of re-fetching it, so a rebuild does not pay the download again. The
# staged name is per-pin (<name>.blob / .tar.gz), so a pin bump
# re-verifies against the NEW sha, misses, and overwrites in place — no orphans, no unbounded growth.
mkdir -p "$PREBUILT_DIR"
# PREBUILT_DIR persists, so the install list has to be cleared BEFORE the mode branch: the
# container decides locked-vs-resolve purely by whether this file exists, and a leftover list
# from an earlier locked run would silently re-lock a resolve run (i.e. make `make relock`
# unable to re-resolve, which is the one thing it exists to do).
rm -f "$PREBUILT_DIR/install.list"

# The pinned mirrorlist crosses into the container as a FILE rather than being interpolated
# into the single-quoted bash -c below: the URL carries literal $repo/$arch, which pacman
# expands and neither shell must. A file keeps them literal with no quoting games.
# rootfs/conf/pacman.conf Includes it from this same staging directory.
printf 'Server = %s/$repo/os/$arch\n' "$SNAPSHOT" >"$PREBUILT_DIR/mirrorlist"
# The bootstrap's repo configuration and the root's identity, both committed declarations
# staged alongside it (see the headers of each).
cp "$PACMANCONF" "$PREBUILT_DIR/pacman.conf"
cp "$OSRELEASE"  "$PREBUILT_DIR/os-release"
# The UID/GID pin, staged so the container can place it before the transaction (see its header).
cp "$IDPIN"      "$PREBUILT_DIR/sysusers-ids.conf"

for pin in "${PREBUILT_PINS[@]}"; do
  [ -e "$pin" ] || continue
  name="$(pin_field "$pin" name)"; ver="$(pin_field "$pin" version)"
  url="$(pin_field "$pin" url)";  sha="$(pin_field "$pin" sha256)"
  kind="$(pin_field "$pin" kind)"; kind="${kind:-tar}"
  : "${name:?$pin: missing name}"; : "${url:?$pin: missing url}"; : "${sha:?$pin: missing sha256}"
  # `.blob` for a raw file (copied verbatim), `.tar` for an archive (tar autodetects gz/xz/zst),
  # `.zip` for one GNU tar cannot read — staged pristine and unpacked container-side with bsdtar.
  case "$kind" in
    tar)  staged="$PREBUILT_DIR/$name.tar" ;;
    zip)  staged="$PREBUILT_DIR/$name.zip" ;;
    file) staged="$PREBUILT_DIR/$name.blob" ;;
    *)    echo "$pin: unknown kind '$kind' (want: tar|zip|file)" >&2; exit 1 ;;
  esac
  # Reuse a cached blob only if its sha already matches the pin (guards against a partial download
  # or a bumped url reusing the old file); otherwise (re)fetch and verify.
  if [ -f "$staged" ] && echo "$sha  $staged" | sha256sum -c --status -; then
    echo "[retroforge] prebuilt $name $ver ($kind): cached ($url)" >&2
    continue
  fi
  echo "[retroforge] fetching prebuilt $name $ver ($kind): $url" >&2
  curl -fsSL "$url" -o "$staged.part"
  echo "$sha  $staged.part" | sha256sum -c - \
    || { echo "$name sha256 mismatch — refusing" >&2; rm -f "$staged.part"; exit 1; }
  mv -f "$staged.part" "$staged"
done
printf '%s\n' "$EXPECTED_MANIFEST" >"$PREBUILT_DIR/prebuilt.manifest"
# Install-set marker (reuse-cache key only; NOT a tar list) — the full sorted package set.
printf '%s\n' "$EXPECTED_PKGS" >"$PREBUILT_DIR/pkgs"

# LOCKED mode: materialize + sha256-verify the lock's package files on the host and hand the
# container an explicit install list. Done HERE, before the container starts, so a stale or
# republished package fails the build with a hash mismatch instead of after 20 minutes of
# emulated install. Resolve mode writes no list, which is how the container tells the modes apart.
if [ -z "$RESOLVE" ]; then
  "$ROOT/rootfs/fetchlock.sh" "$PREBUILT_DIR/install.list"
else
  echo "[retroforge] RETROFORGE_RESOLVE=1 — re-resolving from PKGS, this tree is for relock only" >&2
fi

# Dev-only tooling crosses as a file for the same reason the mirrorlist does: it keeps the
# container script free of another layer of nested quoting. Absent file => release build.
rm -f "$PREBUILT_DIR/dev.pkgs"
if [ "${RETROFORGE_DEV:-}" = "1" ]; then
  printf '%s\n' "${DEV_PKGS[@]}" >"$PREBUILT_DIR/dev.pkgs"
fi

# The from-source overlay repo is REQUIRED, not optional. PKGS names packages that exist in no
# holo repo at all (mangohud, scx-scheds, libinput-tools, rauc), so a bootstrap without it cannot
# resolve, and a locked build cannot install the /novarepo paths the lock names. Refuse here,
# on the host, rather than 20 emulated minutes in — and refuse for BOTH modes, since the
# pre-4c "mount it only if it happens to exist" made a missing overlay look like a lock problem.
if [ ! -f "$OVERLAY_DB" ] || ! ls "$OVERLAY_REPO"/*.pkg.tar.zst >/dev/null 2>&1; then
  echo "no usable overlay repo at ${OVERLAY_REPO#"$ROOT"/} — the root cannot be laid down without it" >&2
  echo "  build it first: make overlay" >&2
  exit 1
fi

# The target root. It must start EMPTY: this is a bootstrap, and reusing a partially populated
# tree would reintroduce exactly the "content of unknown origin" the phase removes.
#
# BOTH the wipe and the re-create run in a container, so the directory itself is ROOT-owned like
# everything pacman then writes into it. Creating it on the host instead (`mkdir -p "$DEST"`)
# leaves it owned by the build user, and systemd-tmpfiles below then refuses to descend into it:
#   Detected unsafe path transition /target (owned by 1000) -> /target/var (owned by root)
# — its symlink-attack guard, which fires on any ownership transition into a root-owned subtree.
# That silently produced a tree with none of the tmpfiles directories in it. work/ ITSELF stays
# host-owned (created above, and by the Makefile at parse time); only work/base is root-owned,
# which is already how the tree is treated everywhere else (`make clean-base` removes it from
# inside a container for exactly this reason).
echo "[retroforge] clearing the target root -> ${DEST#"$ROOT"/}" >&2
mkdir -p "$ROOT/work"
ctr run --rm -v "$ROOT/work":/wb "$REF" sh -c 'rm -rf /wb/base && mkdir -m0755 /wb/base'

if [ -n "$RESOLVE" ]; then
  echo "[retroforge] resolving the root under arm64: ${INSTALL_PKGS[*]}" >&2
else
  echo "[retroforge] laying down $(wc -l <"$PREBUILT_DIR/install.list") locked packages under arm64" >&2
fi
ctr run --rm --platform linux/arm64 -v "$PREBUILT_DIR":/prebuilt:ro \
  -v "$PACMAN_CACHE":/var/cache/pacman/pkg \
  -v "$OVERLAY_REPO":/novarepo:ro \
  -v "$DEST":/target \
  "$REF" \
  bash -euo pipefail -c '
  # PA is the pacman invocation every step below shares. Three flags carry the whole phase:
  #   -r /target        install into the bind-mounted empty tree, NOT into this container. The
  #                     container is the execution environment; nothing it owns ships.
  #   --config          rootfs/conf/pacman.conf, a committed declaration staged into /prebuilt, which
  #                     Includes the mirrorlist the host wrote from build/snapshot.pin. The vendor
  #                     /etc/pacman.conf in this image is never read and never edited.
  #   --cachedir        the persistent host cache (a bind mount). Root-relative paths would put
  #                     it INSIDE the image being built.
  # dbpath is left to default to /target/var/lib/pacman, which is where it belongs: that database
  # is the tree`s own record of itself, and rootfs/genmanifest.sh reads it to write the lock.
  PA=(pacman -r /target --config /prebuilt/pacman.conf --cachedir /var/cache/pacman/pkg)
  mkdir -p /target/var/lib/pacman

  # A minimal /dev, because pacman runs install scriptlets CHROOTED into the target and the
  # target has no API filesystems. pacstrap mounts /proc, /sys and /dev into the root it builds;
  # we cannot -- a bind mount needs CAP_SYS_ADMIN, which docker drops. CAP_MKNOD it does grant,
  # so the /dev half is buyable and worth buying: without /dev/null, `gnupg`s scriptlet dies on
  # a redirect ("line 5: /dev/null: No such file or directory") and pacman reports a failed hook
  # as a WARNING, so the build stays green with the scriptlet half-run. One package out of 394
  # hits it today, and that one is stripped from the release image -- but the next one to redirect
  # to /dev/null would fail just as quietly.
  #
  # The /proc half stays unbought; the two steps that need it are run offline with --root= below.
  # These nodes are harmless in the shipped image: devtmpfs mounts over /dev at boot.
  mkdir -p /target/dev
  mknod -m 0666 /target/dev/null    c 1 3 2>/dev/null || true
  mknod -m 0666 /target/dev/zero    c 1 5 2>/dev/null || true
  mknod -m 0666 /target/dev/random  c 1 8 2>/dev/null || true
  mknod -m 0666 /target/dev/urandom c 1 9 2>/dev/null || true
  mknod -m 0600 /target/dev/console c 5 1 2>/dev/null || true
  # A plain directory is enough for POSIX semaphores (sem_open creates its file there). From Python
  # 3.14.5 the parallel compileall below takes a multiprocessing lock first and, without /dev/shm,
  # dies on FileNotFoundError before compiling anything (mash-20260528, 2026-11-03).
  mkdir -p -m 1777 /target/dev/shm

  # The UID/GID pin, placed BEFORE the transaction. Order is the whole mechanism: pacman runs the
  # systemd-sysusers hook once at the END of the transaction, over every sysusers.d file present at
  # that moment, and the first definition of a name wins. Placed after the install it would be
  # inert — the ids would already have been allocated by counting down from 999. No package owns
  # this path, so it cannot collide with the transaction. See the file for what drift it prevents.
  install -Dm0644 /prebuilt/sysusers-ids.conf /target/usr/lib/sysusers.d/01-retroforge-enforce-ids.conf

  # Lay the root down. LOCKED when the host staged an install list, else RESOLVE.
  if [ -s /prebuilt/install.list ]; then
    # No -Sy anywhere on this path: nothing syncs a repo database, so pacman CANNOT resolve
    # anything of its own accord -- it installs exactly these host-verified files. Its dependency
    # check over the batch is then a free proof that the lock is a closed set: an unsatisfied dep
    # is a hard error rather than a quiet fetch. Read into an array rather than word-splitting
    # `cat`, so a path is a path.
    mapfile -t lockpkgs < /prebuilt/install.list
    echo "laying down ${#lockpkgs[@]} locked packages into an empty root"
    "${PA[@]}" -U --noconfirm "${lockpkgs[@]}"
  else
    "${PA[@]}" -Sy --noconfirm --disable-download-timeout '"${INSTALL_PKGS[*]}"'
  fi
  # --needed is deliberately absent above: the root starts empty, so there is nothing for it to
  # skip, and its old job (do not re-install what the vendor image already had) no longer exists.

  # Dev-only tooling, installed BY NAME even under locked mode: it is deliberately outside the
  # lock, which describes the release image (the tree the step-4 seal guard runs against). -Sy
  # syncs from the same pinned revision the config above names.
  if [ -s /prebuilt/dev.pkgs ]; then
    mapfile -t devpkgs < /prebuilt/dev.pkgs
    "${PA[@]}" -Sy --noconfirm --needed --disable-download-timeout "${devpkgs[@]}"
  fi

  # Assert the tree against the DECLARATION (base + PKGS + prebuilt deps + dev), not only
  # against the lock. The lock is a resolved closure, so a leaf package that dropped OUT of it
  # leaves no unsatisfied dependency behind -- pacman -U would succeed and the package would
  # simply be absent on the device. -T reports unsatisfied names and honours provides (unlike
  # -Q), so it catches exactly that. Same discipline as the step-4 guard: assert the built tree.
  unmet="$("${PA[@]}" -T '"${INSTALL_PKGS[*]}"' || true)"
  if [ -n "$unmet" ]; then
    echo "the bootstrap did not satisfy the declared package set; unsatisfied:" >&2
    printf "  %s\n" $unmet >&2
    echo "the lock is stale for this declaration -- run: make relock" >&2
    exit 1
  fi

  # ---- the three identity files no package owns -------------------------------------------
  # Before Phase 4c these came in with the vendor image, so the root announced itself as someone
  # else`s distro. Nothing in the package set owns any of the three: measured against the pinned
  # snapshot, /etc/os-release, /etc/locale.conf and /etc/hostname appear in no package file list
  # (only /usr/lib/os-release does, owned by `filesystem`). So a bootstrap that wrote none of
  # them would fall back to the vendor`s /usr/lib/os-release, an unset LANG and a compiled-in
  # hostname. os-release is a committed declaration (rootfs/conf/os-release) installed as the /etc
  # copy, which is exactly what os-release(5) defines /etc for — /usr/lib/os-release is left
  # untouched. The rm is defensive: this snapshot ships no /etc symlink, but if a later one does,
  # install(1) would follow it and rewrite the package-owned file underneath.
  rm -f /target/etc/os-release
  install -Dm0644 /prebuilt/os-release /target/etc/os-release
  # LANG is read by the shell, emulators and games. The locale it names is compiled a few
  # lines down; the two have to agree or everything silently falls back to C.
  printf "LANG=en_US.UTF-8\n" >/target/etc/locale.conf
  # The vendor left a 0-byte /etc/hostname, so the device fell back to a compiled-in default.
  printf "retroforge\n" >/target/etc/hostname

  # Compile the en_US.UTF-8 locale. glibc ships /etc/locale.gen with every entry COMMENTED and
  # nothing runs locale-gen at install time, so /usr/lib/locale would hold only C.utf8 and
  # anything honouring LANG would silently fall back to C. The root is read-only at runtime, so
  # this cannot be deferred to first boot.
  grep -q "^en_US.UTF-8 UTF-8" /target/etc/locale.gen || echo "en_US.UTF-8 UTF-8" >>/target/etc/locale.gen
  chroot /target locale-gen

  # Precompiled external packages staged + verified by the host (packages/*/prebuilt.pin):
  # place each into the rootfs, then record the manifest in the base so the host reuse-check
  # detects pin changes.
  #   kind=tar  -> extract with the pin'"'"'s strip-components into `dest` (default /). Archive roots
  #                differ, so strip is per-package (InputPlumber, a pin until 0.82.0, was rooted
  #                at inputplumber/usr -> strip 1 landed at /usr).
  #   kind=zip  -> as kind=tar, but unpacked with bsdtar because GNU tar cannot read a zip.
  #   kind=file -> copy verbatim to `dest`, which is the full destination FILE path.
  # `dest` is a path in the TARGET root, so every one is prefixed here -- an unprefixed dest
  # would silently unpack into the throwaway container instead.
  if [ -s /prebuilt/prebuilt.manifest ]; then
    while read -r p_name p_sha p_strip p_kind p_dest p_mode p_deps; do
      [ -n "$p_name" ] || continue
      : "${p_deps:-}"  # deps are pacman-installed via the host INSTALL_PKGS list, not here
      # NB: `[ ... ] && x=y` would return 1 on a no-op and kill this `set -e` script.
      if [ "$p_dest" = "-" ]; then p_dest=/; fi
      if [ "$p_mode" = "-" ] || [ -z "$p_mode" ]; then p_mode=0644; fi
      case "${p_kind:-tar}" in
        tar)
          mkdir -p "/target$p_dest"
          # --no-same-owner is LOAD-BEARING, not hygiene. These are third-party archives and they
          # carry their own CI builder`s numeric uid: the InputPlumber tarball is 1001/1001
          # throughout, and it unpacks at / with strip 1, so a root `tar -x` chowned the TARGET`s
          # /usr, /usr/bin, /usr/lib and /usr/share to 1001 -- a uid that does not exist on the
          # image. Long-standing (the same extraction ran before Phase 4c) and missed by
          # the overlay-ownership stage, which reclaims only the repo-checkout uid. Nothing in a
          # read-only system root legitimately belongs to a build account, so extract as root.
          tar -C "/target$p_dest" --no-same-owner --strip-components="${p_strip:-0}" \
              -xf "/prebuilt/$p_name.tar"
          ;;
        zip)
          # Same contract as kind=tar, different reader: GNU tar cannot open a zip, and upstreams
          # that publish only a zip (Google`s platform-tools) would otherwise need repacking on the
          # host, which would mean the staged blob no longer being the bytes the pin`s sha covers.
          # bsdtar reads zip natively and is always present here -- it ships in libarchive, which
          # pacman itself depends on, so it cannot go missing while this container can install
          # anything. It also honours the unix mode in the zip`s external attributes, which is what
          # keeps adb/fastboot executable at rest (verified on r37.0.1: 0755 survives extraction).
          command -v bsdtar >/dev/null || { echo "prebuilt $p_name: kind=zip needs bsdtar" >&2; exit 1; }
          mkdir -p "/target$p_dest"
          bsdtar -C "/target$p_dest" --no-same-owner --strip-components="${p_strip:-0}" \
                 -xf "/prebuilt/$p_name.zip"
          ;;
        file)
          # mode comes from the pin (default 0644): a file a unit executes directly needs the
          # exec bit at rest.
          install -D -m "$p_mode" "/prebuilt/$p_name.blob" "/target$p_dest"
          ;;
        *)
          echo "prebuilt $p_name: unknown kind ${p_kind}" >&2; exit 1
          ;;
      esac
    done < /prebuilt/prebuilt.manifest
    install -Dm0644 /prebuilt/prebuilt.manifest /target/usr/lib/retroforge/prebuilt.manifest
  fi
  # Release base ships the runtime PACKAGES only — no network/SSH config or service
  # enablement. First-boot networking is the shell job; all Wi-Fi/SSH
  # scaffolding (.link/.network, regdom, wpa creds, sshd + host keys, enable-symlinks) is
  # injected dev-only by rootfs/assemble-rootfs.sh under RETROFORGE_DEV=1.

  # Headless-boot fix (GENERAL, not network/test): no package owns /etc/machine-id, so the root
  # ships without one (ConditionFirstBoot=yes) — as it did before 4c, where the vendor image had
  # none either. systemd-firstboot.service therefore runs and, with console=tty0 and no
  # usable console input, prompts for locale/root-password and blocks sysinit.target forever
  # — the device never reaches multi-user. (systemd.firstboot=off on the cmdline only disables
  # PID1'\''s builtin query, NOT this unit.) Mask it; machine-id is still generated on first
  # boot and preset-all still runs, so service enablement is unaffected.
  mkdir -p /target/etc/systemd/system
  ln -sf /dev/null /target/etc/systemd/system/systemd-firstboot.service

  # Network stack is NetworkManager, for every build (release + test) — see PKGS note above.
  # The holo base ships systemd-networkd enabled too, so BOTH run: networkd manages nothing
  # (NM owns the links) yet its wait-online never reaches "configured" and pins
  # network-online.target until it times out EVERY boot, stalling anything ordered after it
  # (e.g. the gamescope session queued behind network-online.target). HW-confirmed 2026-06-27.
  # Mask networkd + its socket + its wait-online so only NetworkManager-wait-online satisfies
  # network-online.target. Masking (not disable) is preset-proof: nothing can socket-activate or
  # Wants= them back. NM provides its own resolved/timesync paths; networkd is pure dead weight.
  ln -sf /dev/null /target/etc/systemd/system/systemd-networkd.service
  ln -sf /dev/null /target/etc/systemd/system/systemd-networkd.socket
  ln -sf /dev/null /target/etc/systemd/system/systemd-networkd-wait-online.service

  # ...and ENABLE NetworkManager for every build. The holo base ships NM installed-but-disabled;
  # with networkd now masked, a release image would have NO active network manager at all, so the
  # shell lists zero Wi-Fi (HW-confirmed). The test block in assemble-rootfs.sh used to be
  # the only place NM got enabled — wrong layer (test-only). Enable it here the preset-proof way:
  # /etc/machine-id is empty so first boot runs preset-all where the stock 99-default.preset says
  # "disable *"; a high-prio preset (60 < 99) keeps NM enabled, and the multi-user.target.wants +
  # dbus-activation symlinks (what systemctl enable NetworkManager makes) are the build-time
  # fallback. NM drives wpa_supplicant directly; no wpa_supplicant.service enable needed.
  # NOTE: this whole block runs inside the single-quoted docker bash -c, and at this stage /usr is
  # pacman-owned + read-only, so the preset goes in /etc (systemd reads /etc/systemd/system-preset/
  # too, at higher priority than /usr/lib). Keep comments apostrophe-free — a bare single-quote
  # closes the -c string and leaks the rest to the host shell (permission-denied on /etc + /usr).
  mkdir -p /target/etc/systemd/system-preset
  echo "enable NetworkManager.service" >/target/etc/systemd/system-preset/60-retroforge-network.preset
  mkdir -p /target/etc/systemd/system/multi-user.target.wants
  ln -sf /usr/lib/systemd/system/NetworkManager.service \
         /target/etc/systemd/system/multi-user.target.wants/NetworkManager.service
  ln -sf /usr/lib/systemd/system/NetworkManager.service \
         /target/etc/systemd/system/dbus-org.freedesktop.NetworkManager.service

  # player user (uid/gid 1000) — owns the session home /home/player (a dedicated growable partition)
  # and the gamescope session. Bake the account into the RO root /etc HERE (the root is read-only
  # at runtime, so a boot-time systemd-sysusers could not persist it). -M: do NOT create a home in
  # the RO root — /home/player lives on the /home partition, which make-sdcard.sh creates
  # player-owned at image-build time. Supplementary
  # groups are added only when they already exist in the base (hardware/seat access for the session).
  # Every account tool below runs CHROOTED into the target: they read and write /etc/passwd,
  # /etc/group and /etc/shadow, and outside the chroot they would edit the throwaway container.
  # (qemu binfmt is registered with the F flag, so the interpreter survives the chroot.)
  if ! chroot /target getent passwd player >/dev/null 2>&1; then
    chroot /target useradd -M -u 1000 -U -s /bin/bash -c "Player" player
  fi
  for g in wheel video render input audio seat; do
    if chroot /target getent group "$g" >/dev/null 2>&1; then chroot /target usermod -aG "$g" player; fi
  done

  # Materialize tmpfiles.d. pacman`s post-transaction hook tries this and FAILS in the bootstrap
  # ("/proc/ is not mounted, but required ... consider using the --root= switch"), because it runs
  # chrooted with no /proc -- and pacman treats a failed hook as a warning, so the build stayed
  # green with none of these directories created. Before 4c it did not matter: the vendor had run
  # it when building the image we exported. Now nobody has, and the root is READ-ONLY at runtime,
  # so a directory tmpfiles would create on first boot cannot appear at all.
  #
  # --root= is the documented offline mode and what the error itself suggests; builder and target
  # ship the identical systemd (258.2-2-arch, both from the pinned snapshot). It runs HERE, after
  # the accounts above, because entries name owners (player, service accounts) that must resolve in the target`s
  # own /etc/passwd -- and after the prebuilts, which ship tmpfiles.d snippets of their own.
  #
  # NOT fatal on a non-zero exit: an offline run legitimately cannot satisfy every line (anything
  # under /proc, /sys or /dev, and ACL/xattr ops the host filesystem may not support), and
  # systemd-tmpfiles returns non-zero if ANY line failed. Report the code rather than swallow it,
  # so a run that starts failing wholesale is visible in the build log.
  if ! systemd-tmpfiles --root=/target --create; then
    echo "[retroforge] systemd-tmpfiles --root exited $? (partial offline application; see above)" >&2
  fi

  # Journal message catalog, offline for the same reason as tmpfiles above. pacman`s hook runs
  # `journalctl --update-catalog` chrooted and fails -- "Failed to open file
  # /usr/lib/systemd/catalog/dbus-broker-launch.catalog: No such file or directory" -- which is a
  # misleading message: every .catalog file IS present in the tree, and the same command with
  # --root= succeeds and writes a 293K database. The chroot is what it cannot cope with.
  #
  # Without this /var/lib/systemd/catalog/database does not exist, so `journalctl -x` has no
  # message explanations. On a device with no serial console, where the only debugging path is
  # reading an offloaded journal off the card, that is the wrong thing to be missing.
  if ! journalctl --root=/target --update-catalog; then
    echo "[retroforge] journalctl --root --update-catalog exited $? (no message catalog)" >&2
  fi

  # Python bytecode, compiled by the image`s own interpreter. The packaged .pyc record source mtimes
  # the installed files no longer have, and the root is read-only at runtime, so without this every
  # Python program compiled each module it imported on every run: ~0.4 s of steam-bootstrap`s
  # 0.55 s, ~1.9 s of the helpers before each Steam launch (Air X, 2026-10-24). checked-hash, so
  # mtimes do not matter; level 0 only, as nothing runs -O. Not fatal, like the steps above: a
  # module that does not compile is reported and left without bytecode.
  find /target/usr/lib/python3.* -name "*.opt-[12].pyc" -delete
  if ! chroot /target sh -c "python3 -m compileall -q -f -j0 -o 0 --invalidation-mode checked-hash /usr/lib/python3.*"; then
    echo "[retroforge] compileall reported modules it could not compile (see above)" >&2
  fi

  # Record the install-set marker LAST, so its presence proves the whole bootstrap ran. The host
  # reuse-check keys off it: a run that died anywhere above leaves no marker, so the next build
  # re-bootstraps instead of shipping a half-populated root. (It used to be written before this
  # block, which made "the marker exists" a weaker claim than the comment said it was.)
  install -Dm0644 /prebuilt/pkgs /target/usr/lib/retroforge/pkgs

  # NB: no `pacman -Scc` here — /var/cache/pacman/pkg is a persistent host bind-mount (the retry
  # cache) and lives outside the target root, so cleaning it would only throw the cache away
  # without shrinking anything that ships.
' >&2
# ^ redirect the container'\''s stdout (pacman progress) to stderr: this script'\''s stdout must
#   carry ONLY the rootfs path (echo "$DEST" below), which build-image.sh captures.

# NO EXPORT STEP. The tree was written straight into the bind-mounted work/base by a root
# pacman inside the container, so it already carries real ownership (root + service users) and
# real modes — the thing the old `docker export | tar -x as root` dance existed to preserve
# (a host-side tar -x squashed everything to the build user, and sshd then refused its non-root
# privsep dir). Nothing is copied, nothing is flattened, and no container filesystem — with its
# /.dockerenv and the vendor image's own contents — is ever the source of these bytes.

# du -sh on a root-owned tree warns on 0700 dirs (/root, NM system-connections, gnupg keys) when
# run as the host user; the size is just for the log line, so drop those stderr warnings.
echo "[retroforge] bootstrapped root ready ($(du -sh "$DEST" 2>/dev/null | cut -f1) at ${DEST#"$ROOT"/})" >&2
echo "$DEST"
