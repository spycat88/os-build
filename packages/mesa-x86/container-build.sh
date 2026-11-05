#!/usr/bin/env bash
# mesa-x86, container half: runs INSIDE the pinned x86_64 Arch image (./builder.pin), started by
# ./build.sh. Builds packages/mesa's pinned tarball with packages/mesa's patches, twice: x86_64
# into usr/lib and i686 into usr/lib32, and leaves the runtime files under /out/payload.
#
# Expects: the repo read-only at /repo, a writable /out, and in the environment
#   SNAPSHOT        Arch Linux Archive date (2026/08/11)
#   PATCHES         packages/mesa/source.pin's patch list, in order (may be empty)
#   MESA_VERSION    the string for mesa's VERSION file (lib.sh mx86_mesa_version_string)
#   HOST_UID/GID    owner to hand /out back to
#   STAGE           build (default) | configure   (configure: stop after `meson setup`)
#   ARCHES          default "x86_64 i686"
set -euo pipefail

: "${SNAPSHOT:?}" "${MESA_VERSION:?}" "${HOST_UID:?}" "${HOST_GID:?}"
STAGE="${STAGE:-build}"
ARCHES="${ARCHES:-x86_64 i686}"
OUT=/out
PAYLOAD="$OUT/payload"
SRC=/build/src

# Root-owned leftovers would make the host's next `rm -rf` fail, so hand /out back on ANY exit,
# including a gate below firing after the install.
trap 'chown -R "$HOST_UID:$HOST_GID" "$OUT" 2>/dev/null || true' EXIT

log() { printf '[mesa-x86] %s\n' "$*" >&2; }

# --- toolchain: the guest's own package generation -------------------------------------------
# Every library the driver links comes from the same Arch snapshot the guest was built from, so
# the driver cannot need a symbol the guest lacks (see builder.pin). multilib supplies lib32-*.
/repo/packages/mesa-x86/pacman-snapshot.sh "$SNAPSHOT"

# Deliberately NOT installed, because meson links whatever it finds: libdisplay-info and
# xcb-util-keysyms (the x11 WSI's optional capture hotkey), which the 2026-08-11 guest does not
# ship at all; and spirv-tools, lm_sensors, valgrind, libunwind, which it does ship but which
# Turnip and zink do not need (the meson options below also turn them off). An ICD with an
# unresolvable NEEDED is dropped silently by the Vulkan loader and pressure-vessel; compose.sh
# re-checks the whole closure against the real guest.
deps=(
  meson ninja python-mako python-yaml python-packaging python-ply glslang
  libdrm libx11 libxcb libxext libxfixes libxshmfence libxrandr libxxf86vm
  wayland wayland-protocols xorgproto expat zstd zlib libglvnd
  lib32-glibc lib32-gcc-libs lib32-libdrm lib32-libx11 lib32-libxcb lib32-libxext lib32-libxfixes
  lib32-libxshmfence lib32-libxrandr lib32-libxxf86vm lib32-wayland lib32-expat lib32-zstd
  lib32-zlib lib32-libglvnd
)
pacman -S --noconfirm --needed "${deps[@]}"

# --- source: exactly what the host driver builds ----------------------------------------------
# packages/mesa/fetch-source.sh reads the URL and sha256 out of packages/mesa/PKGBUILD, falls back
# to the verified mirror, and refuses any other bytes. A host mesa bump is a guest mesa bump.
mkdir -p /build
/repo/packages/mesa/fetch-source.sh /build
TARBALL="$(bash -c 'source /repo/packages/mesa/PKGBUILD >/dev/null 2>&1; echo "${source[0]##*/}"')"
rm -rf "$SRC" && mkdir -p "$SRC"
tar -xf "/build/$TARBALL" -C "$SRC" --strip-components=1
cd "$SRC"

# Same patches, same order, as build-overlay.sh applies to the host build (packages/mesa/source.pin).
for p in ${PATCHES:-}; do
  log "patch $p"
  patch -p1 --forward --batch -i "/repo/packages/mesa/patches/$p"
done
# Same VERSION as the host's prepare(): GL_VERSION and libgallium-<version>.so name the build.
echo "$MESA_VERSION" >VERSION

cat >/build/cross-i686.ini <<'EOF'
[binaries]
c = ['gcc', '-m32']
cpp = ['g++', '-m32']
ar = 'gcc-ar'
strip = 'strip'
pkg-config = 'pkg-config'

[properties]
pkg_config_libdir = ['/usr/lib32/pkgconfig', '/usr/share/pkgconfig']

[host_machine]
system = 'linux'
cpu_family = 'x86'
cpu = 'i686'
endian = 'little'
EOF

# --- configuration ------------------------------------------------------------------------------
# The host's options (packages/mesa/PKGBUILD) where they apply, narrowed to what the guest needs:
#
#   vulkan-drivers=freedreno  Turnip, the point of the exercise: x86 Vulkan games and DXVK/VKD3D
#                             run on it, with the host's patches (packages/mesa/patches).
#   gallium-drivers=zink      GL for x86 titles, as zink over that same Turnip -- what Valve's own
#                             FEX guest Mesa ships (deckard-mesa-linux-x86_64: zink is its only
#                             gallium driver). With no msm driver in libgallium, the hardware
#                             driver fails to load and GLX and EGL retry with zink on their own
#                             (src/glx/glxext.c GLX_DRIVER_ZINK_INFER; src/egl/main/eglapi.c
#                             eglInitialize), so every GL title goes through our Turnip too.
#                             Adding `freedreno`
#                             here would make freedreno GL the default again (the msm name maps
#                             to it) and zink an opt-in through MESA_LOADER_DRIVER_OVERRIDE=zink.
#   glvnd, glx=dri, egl, gbm  the guest's GL stack is libglvnd + libGLX_mesa/libEGL_mesa, and
#                             ours replace FEX's copies of those.
#   vulkan-layers             vram-report-limit only: the host builds it, and Valve's guest
#                             carries it. The host's other layers are for the arm64 session.
#   llvm=disabled             zink and Turnip do not use it, and the host does not either. There
#                             is no llvmpipe in our libgallium; the guest's own llvmpipe stays in
#                             FEX's libgallium-26.2.0.so, which ours do not load.
#
# -march=x86-64 is the guest's baseline (FEX's rootfs is plain Arch x86_64). FEX translates wider
# vector extensions too, but the guest's own libraries do not assume them and neither do we.
common=(
  --prefix=/usr --sysconfdir=/etc --localstatedir=/var
  --buildtype=plain --wrap-mode=nofallback
  -Ddefault_library=shared
  -Db_ndebug=true
  -Dplatforms=x11,wayland
  -Dvulkan-drivers=freedreno
  -Dfreedreno-kmds=msm
  -Dgallium-drivers=zink
  -Dvulkan-layers=vram-report-limit
  -Dglvnd=enabled -Dglx=dri -Degl=enabled -Dgbm=enabled -Dgles1=disabled -Dgles2=enabled
  -Dllvm=disabled -Dshared-llvm=disabled
  -Dgallium-rusticl=false -Dgallium-va=disabled -Dgallium-extra-hud=false
  -Dandroid-libbacktrace=disabled -Dmicrosoft-clc=disabled -Dintel-rt=disabled
  -Ddisplay-info=disabled -Dlmsensors=disabled -Dvalgrind=disabled -Dlibunwind=disabled
  -Dspirv-tools=disabled
  -Dzstd=enabled -Dexpat=enabled -Dxmlconfig=enabled -Dshader-cache=enabled
  -Dhtml-docs=disabled -Dbuild-tests=false
)
cflags='-march=x86-64 -mtune=generic -O2 -pipe -fno-plt -fexceptions -fstack-clash-protection -g0'
# -z now: every symbol binds at load, so a driver that needs something the guest lacks fails to
# load (and compose.sh's ldd -r sees it), instead of crashing mid-game on first call.
ldflags='-Wl,-O1 -Wl,--sort-common -Wl,--as-needed -Wl,-z,relro -Wl,-z,now'

libdir_of() { case "$1" in x86_64) echo lib ;; i686) echo lib32 ;; esac; }

for arch in $ARCHES; do
  libdir="$(libdir_of "$arch")"
  [ -n "$libdir" ] || { echo "unknown arch '$arch'" >&2; exit 1; }
  extra=(--libdir="$libdir")
  [ "$arch" = i686 ] && extra+=(--cross-file /build/cross-i686.ini)
  log "meson setup ($arch)"
  rm -rf "/build/$arch"
  CFLAGS="$cflags" CXXFLAGS="$cflags" LDFLAGS="$ldflags" \
    meson setup "/build/$arch" "$SRC" "${extra[@]}" "${common[@]}"
done

if [ "$STAGE" = configure ]; then
  log "STAGE=configure: stopping after meson setup"
  exit 0
fi

# --- build + install ------------------------------------------------------------------------------
rm -rf "$PAYLOAD" /build/stage
for arch in $ARCHES; do
  log "build ($arch)"
  meson compile -C "/build/$arch"
  DESTDIR="/build/stage" meson install -C "/build/$arch" --no-rebuild --strip --quiet
done

# Runtime files only: no headers, no pkg-config files, no static archives. The rest of the install
# is the payload, as installed -- a file a new mesa release adds rides along without a list here.
rm -rf /build/stage/usr/include
find /build/stage -type d -name pkgconfig -prune -exec rm -rf {} +
find /build/stage -name '*.a' -delete
mkdir -p "$OUT"
cp -a /build/stage "$PAYLOAD"
install -Dm0644 "$SRC/docs/license.rst" "$PAYLOAD/usr/share/licenses/retroforge-mesa-x86/license.rst"

# The VRAM report-limit layer in Valve's shape, which is how Valve's FEX guest Mesa ships it (and
# packages/mesa since ba2310f): IMPLICIT, and off unless ENABLE_MESA_VRAM_REPORT_LIMIT=1, which
# Steam's launch-wrapper defaults set for games; DISABLE_MESA_VRAM_REPORT_LIMIT=1 overrides. Mesa
# installs it as an explicit layer. One manifest serves both arches: its library_path is a bare
# file name, so each arch's Vulkan loader finds its own copy in usr/lib or usr/lib32.
python3 - "$PAYLOAD/usr/share/vulkan" <<'EOF'
import json, os, sys
d = sys.argv[1]
src = os.path.join(d, "explicit_layer.d", "VkLayer_MESA_vram_report_limit.json")
dst = os.path.join(d, "implicit_layer.d", "VkLayer_MESA_vram_report_limit.json")
with open(src) as f:
    m = json.load(f)
if m["layer"]["library_path"] != "libVkLayer_MESA_vram_report_limit.so":
    sys.exit(f"vram-report-limit: unexpected library_path {m['layer']['library_path']!r}")
m["layer"]["enable_environment"] = {"ENABLE_MESA_VRAM_REPORT_LIMIT": "1"}
m["layer"]["disable_environment"] = {"DISABLE_MESA_VRAM_REPORT_LIMIT": "1"}
os.makedirs(os.path.dirname(dst), exist_ok=True)
with open(dst, "w") as f:
    json.dump(m, f, indent=3)
    f.write("\n")
os.remove(src)
if not os.listdir(os.path.dirname(src)):
    os.rmdir(os.path.dirname(src))
EOF

# --- gates ------------------------------------------------------------------------------------
fail() { echo "ERROR: mesa-x86: $*" >&2; exit 1; }

for arch in $ARCHES; do
  libdir="$(libdir_of "$arch")"
  case "$arch" in x86_64) machine='X86-64'; class=ELF64 ;; i686) machine='80386'; class=ELF32 ;; esac
  for f in "usr/$libdir/libvulkan_freedreno.so" "usr/$libdir/libEGL_mesa.so.0" \
           "usr/$libdir/libGLX_mesa.so.0" "usr/$libdir/libgbm.so.1" "usr/$libdir/gbm/dri_gbm.so" \
           "usr/$libdir/dri/libdril_dri.so" "usr/$libdir/libgallium-$MESA_VERSION.so" \
           "usr/$libdir/libVkLayer_MESA_vram_report_limit.so" \
           "usr/share/vulkan/icd.d/freedreno_icd.$arch.json" \
           "usr/share/vulkan/implicit_layer.d/VkLayer_MESA_vram_report_limit.json"; do
    [ -e "$PAYLOAD/$f" ] || fail "$f missing from the install"
  done

  # Every ELF under this arch's libdir is that arch. A cross-file slip would otherwise hand the
  # i386 loader an x86_64 driver, which it skips without a word.
  while IFS= read -r -d '' so; do
    hdr="$(readelf -h "$so")"
    grep -q "Class:[[:space:]]*$class" <<<"$hdr" && grep -q "Machine:.*$machine" <<<"$hdr" \
      || fail "${so#"$PAYLOAD"/} is not $class $machine"
  done < <(find "$PAYLOAD/usr/$libdir" -type f -name '*.so*' -print0)

  # Mesa writes an absolute library_path into the ICD. It is what Valve's guest and FEX's rootfs
  # ship too; pressure-vessel resolves it inside the graphics provider's root.
  icd="$PAYLOAD/usr/share/vulkan/icd.d/freedreno_icd.$arch.json"
  grep -q "\"library_path\": \"/usr/$libdir/libvulkan_freedreno.so\"" "$icd" \
    || fail "$icd does not name /usr/$libdir/libvulkan_freedreno.so"
done

# The container's glibc IS the guest generation's glibc (same snapshot), so no driver may need a
# newer symbol version than it provides.
glibc_max="$(ldd --version | sed -n '1s/.* //p')"
while IFS= read -r -d '' so; do
  ceiling="$(readelf --dyn-syms -W "$so" | grep -o 'GLIBC_[0-9.]*' | sed 's/GLIBC_//' | sort -uV | tail -1)"
  [ -z "$ceiling" ] && continue
  [ "$(printf '%s\n%s\n' "$ceiling" "$glibc_max" | sort -V | tail -1)" = "$glibc_max" ] \
    || fail "${so#"$PAYLOAD"/} needs GLIBC_$ceiling, newer than the snapshot's glibc $glibc_max"
done < <(find "$PAYLOAD" -type f -name '*.so*' -print0)

log "payload:"
(cd "$PAYLOAD" && find . \( -type f -o -type l \) | LC_ALL=C sort | sed 's|^\./|  |') >&2
