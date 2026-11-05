# packages/

Pacman packages layered on top of the upstream aarch64 base — overlays rebuilt from
source with retroforge patches (`source.pin`) and pinned precompiled tarballs
(`prebuilt.pin`). (Static files baked straight into the rootfs live under `rootfs/overlay/`,
not here.)

## Precompiled external packages (`prebuilt.pin`)

Components that aren't in the holo pacman repo and aren't built from source here are
pulled in as **pinned precompiled artifacts**. Drop a `packages/<name>/prebuilt.pin`:

```
name: inputplumber                 # staged as work/prebuilt/<name>.{tar,blob}; manifest key
version: 0.77.6
url: https://.../inputplumber-aarch64.tar.gz
sha256: 0e0f7600…                  # from the asset's .sha256.txt sidecar
kind: tar                          # optional: tar (default) | file
strip: 1                           # tar only: --strip-components to land files at /usr
dest: /                            # optional: where to put it (default /)
deps: libiio                       # optional: holo-repo runtime deps (space-separated)
```

`kind: tar` extracts the archive into `dest` (any tar compression; autodetected). `kind: file`
copies the artifact verbatim **to** `dest`, which is then the full destination *file* path — for
artifacts that aren't archives at all.

`rootfs/customize-base.sh` auto-discovers every `prebuilt.pin`, fetches + sha256-verifies
it on the host, and extracts it into the release base — **adding a package is just a new
pin file, no code change**. Any `deps:` a pin declares are pacman-installed into the base
alongside the prebuilt (e.g. shared libraries the binary links), so a prebuilt's runtime
deps live with the pin instead of being hardcoded in the install list. The set of installed
prebuilts **and their deps** is recorded in the base at `/usr/lib/retroforge/prebuilt.manifest`,
which keys the base reuse-cache (bump a pin, or change its deps, → the base rebuilds).
Currently there are NO pins: `inputplumber/`, the last one, moved to a from-source overlay
package with its 0.82.0 bump (it now carries a patch — upstream PR #757, input layers — and a
patched package must be built, not pinned). The mechanism stays for the next component that
needs it.

## Built here, never in the image: `mesa-x86/`

`mesa-x86/` builds `mesa/`'s pinned tarball and patches for x86_64 + i686 (Turnip, zink GL) and
composes it over FEX's ArchLinux RootFS into a squashfs **guest image that devices download** for
x86 games under Valve's FEX tool. It has no `source.pin`, `prebuilt.pin` or `PKGBUILD`, so neither
`build-overlay.sh` nor `customize-base.sh` picks it up, and it is published by its own
manual-only workflow (`release-fex-guest.yml`), not by `overlay.yml` or `image.yml`. Its CPU
baseline is `-march=x86-64`, the guest's own; the aarch64 rules below do not apply to it. See
[`mesa-x86/README.md`](mesa-x86/README.md).

## What CI does with these packages

Nothing is published anywhere. `.github/workflows/overlay.yml` builds the packages a pull request
touches, purely to prove they still compile. On a push to `main` its `warm` job builds the whole set
into an `actions/cache` entry, and a release build (`.github/workflows/image.yml`) restores that and
rebuilds only the packages whose stamps no longer match — see `docs/ci.md`.

There used to be more: a GHCR **artifact store** that each package was published to, keyed by
`packages/inputhash.sh`, plus a per-package `artifact.pin` recording the sha256 of the published
bytes and a bot that opened a **pin-bump PR** to carry those shas into the tree. A release build
verified them, which meant a release image could only ever be built by CI.

All of it was sized against the cost of an overlay build **on a dev box**, where arm64 emulation
makes the set take hours. CI does not pay that. On the native `ubuntu-24.04-arm` runners it uses,
the packages measured `sddm 5m, mesa 5m, gamescope 4m, scx-scheds 4m, mangohud 3m, rauc 1m` —
**well under 30 minutes for everything**, against a release build
that already runs 33–41 minutes. It was retired on 2026-08-04. The `warm` cache that replaced it on
CI is just this directory and its stamps in `actions/cache` — no registry, pin or bot.

**Locally, the cache is the stamps.** `build-overlay.sh` records each package's input hash under
`work/repo/<arch>/.stamps/<name>.hash` and rebuilds only what moved, so a one-line gamescope patch
costs a gamescope build and nothing else. Change a `source.pin`, a patch or a `PKGBUILD` and the next
`make overlay` rebuilds that package; change nothing and it does nothing.

`retroforge.db` is deliberately **not** pinned: `repo-add` is not byte-reproducible either, so a pin on
it could never hold. Nothing installs *from* the db in a locked build — `fetchlock.sh` hands pacman an
explicit file list — so it is an index, not an input.

## CPU baseline (`-march`) for from-source packages

The base `makepkg.conf` ships `CFLAGS="-O2 -pipe -fno-plt -fexceptions …"` with **no `-march`**, so
everything built from source targets the stock `armv8-a` baseline. `mesa` states the floor
explicitly in its own `PKGBUILD` rather than inheriting it, so the contract is visible where the
bytes are made:

```
-march=armv8-a+crc -moutline-atomics       # packages/mesa — the Cortex-A73/A53 level, see below
```

**The floor is set by the OLDEST SoC the image must serve, not the newest.** The overlay is built
once per architecture and the image is unified across every board, so one built byte has to run on
all of them. Raising the floor above what the oldest board supports does not fail at build time — it
produces packages that SIGILL on that device, after the pipeline has published them. That stopped
being hypothetical on the first MANGMI Air X boot.

**The oldest board is now SM6115 (Cortex-A73 + A53, ARMv8.0-A).** Until that port SM8250
(Cortex-A77/A55, ARMv8.2-A) was the floor, and mesa raised itself to
`-march=armv8.2-a+fp16+dotprod` — the exact level of those cores, verified per core in the GCC and
LLVM tables, for inline LSE atomics plus fp16/dotprod in the format-conversion paths (`armv8.2-a`
implies `armv8.1-a`, i.e. `CAS`/`LDADD` emitted inline instead of `ldxr/stxr` loops; `i8mm`, `bf16`
and SVE were checked absent on the A55 and left out). The A73 and A53 have none of it:

| core | GCC `aarch64-cores.def` | LSE | F16 | DOTPROD |
| --- | --- | --- | --- | --- |
| Cortex-A73 / A53 (SM6115) | `V8A, (CRC)` | no | no | no |
| Cortex-A77 / A55 (SM8250) | `V8_2A, (F16, RCPC, DOTPROD[, SSBS])` | yes | yes | yes |
| Cortex-X3/A715 (SM8550), X4/A720 (SM8650) | ARMv9-A | yes | yes | yes |

The Air X's first boot (2026-10-10) died in turnip on a `casal` during Vulkan device enumeration —
gamescope SIGILL every 20 s, the panel showing fbcon's cursor — with 3279 unguarded LSE instructions
in gallium + EGL and 345 in turnip, while every other package in the image was clean.
`packages/mesa/PKGBUILD` now pins `-march=armv8-a+crc`: ARMv8.0-A plus the CRC32 instructions,
which is exactly what both of those cores implement and nothing more.

**What the stock baseline costs the newer boards: nothing for atomics, the intrinsics for real.**
GCC's `-moutline-atomics` (its default, and written out in the mesa recipe) compiles every atomic as a call to a `__aarch64_*` helper that
tests `__aarch64_have_lse_atomics` (set once at load from the CPU's HWCAP) and runs the LSE
instruction on a core that has it — so SM8250/8550/8650 keep their LSE atomics, behind a predictable
branch instead of inline. `fp16` and `dotprod` codegen is lost fleet-wide. If a measurement ever
shows mesa paying for that, the answer is a second, per-SoC mesa build selected at runtime — never a
floor the Air X cannot execute.

**How to check a built package, so this is caught before a device is.** Unguarded LSE is visible in
the binary: an `ldadd`/`cas`/`swp`-family instruction not preceded by the helper's `cbz w16` guard.

```sh
aarch64-linux-gnu-objdump -d lib.so | awk \
  '/^[ \t]+[0-9a-f]+:/ { if ($0 ~ /[ \t](ldadd|ldclr|ldeor|ldset|swp|cas|casp|ldumax|ldumin|ldsmax|ldsmin)[a-z]*[ \t]/) { t++; if (prev !~ /cbz[ \t]+w16/) u++ } prev=$0 }
   END { print t+0 " LSE, " u+0 " unguarded" }'
```

A clean overlay reads `N LSE, 0 unguarded` for every package (gamescope 13/0, opengamepadui 89/0,
scx-scheds 84/0; mesa before the fix 3281/3279). Run it on every ELF of a new or bumped package.

**Why these flags live in each `PKGBUILD` and not a shared toolchain file.**
`packages/inputhash.sh` hashes exactly three things per package — `source.pin`, its declared patches,
and the local `PKGBUILD`. A shared flags file would be **invisible** to it: changing the flags would
move the artifact bytes while leaving the inputhash unchanged, so `rootfs/manifest.lock` would keep
asserting the same provenance for different bytes, and — worse — `build-overlay.sh` would consider
every package up to date and never rebuild any of them, so the flag change would silently not happen
at all. Putting the flags in the `PKGBUILD` keeps them inside the hashed input set, so a flag change
rebuilds the package like any source change. **If this ever becomes a shared file, it must be
added to `inputhash.sh`'s input set in the same commit** — and that bumps every package's hash at
once.

`-mtune` is a scheduling hint, not an ISA floor, so it is chosen separately and more loosely; a
conservative pick across the big.LITTLE clusters is `cortex-a78`, which stays valid with A77 in
the fleet.

## Shared libraries, not static

Every from-source package builds and links **shared** libraries. The meson recipes say
`default_library=shared` explicitly rather than inheriting it, the autotools ones pass
`--enable-shared --disable-static`, and the release trim (`rootfs/conf/trim.list`) removes any `.a`
that still reaches the image. These are build flags, so they live in each `PKGBUILD` for the
inputhash reason below. The places that stay static are deliberate:

| Where | What is static | Why |
|---|---|---|
| `gamescope` | vendored wlroots, libliftoff, libdisplay-info, vkroots | `package()` installs with `--skip-subprojects`, so a shared copy would be linked and never shipped; they are patched private copies that must not shadow a system soname |
| `mangohud` | imgui / implot wraps (not installed) | the overlay is a layer loaded into every game; a private `libimgui.so` would have to ship and could clash with a game's own |
| `scx-scheds` | libbpf (via `libbpf-sys`' default `vendored-libbpf`) | `libbpf-rs` enables it by default in every crate of the vendored workspace; going shared means patching vendored crates (and their checksums) to `default-features = false` and building against the image's libbpf 1.7 |
| Rust packages (`inputplumber`, `powerstation`, `scx-scheds`) | crate dependencies | Rust has no stable ABI, so crates always link statically; C libraries they use from the system (libudev, libelf, libz, …) are shared |
| `mesa`, `mesa-x86` | internal convenience archives | mesa's build links its own `static_library()` pieces into the shared drivers; nothing static is installed |
| `apps/retroforge-splash` | the whole binary, glibc included | the cross toolchain's glibc is newer than the image's, and the splash runs from the initramfs; see its Makefile |
| `boot/` (steamcl, GRUB) | EFI binaries | UEFI has no dynamic loader |

## From-source overlay packages (`source.pin`)

Holo packages that need a retroforge **code** patch are rebuilt from source instead of pulled as
binaries. Drop a `packages/<name>/source.pin` plus the patches under `packages/<name>/patches/`:

```
name: gamescope
pkgbuild_repo: holo/holo-core-aarch64-preview   # GitLab project hosting the PKGBUILD
pkgbuild_path: extra-aarch64/g/gamescope/3.16.17-1
pkgbuild_ref: 1a6f6e90...                        # commit SHA to pin (reproducible)
pkgrel_suffix: 1                                 # integer only: N -> N.1 (kept across upgrades)
patches: 0001-foo.patch 0002-bar.patch          # applied -p1 in the source root
```

`make overlay` (→ `packages/build-overlay.sh`) fetches the PKGBUILD from the monorepo raw endpoint
at the pinned commit (anonymous read; the PKGBUILD pulls the upstream source from public GitHub),
applies the patches, bumps `pkgrel`, and `makepkg`s it inside the pinned builder image
(`build/builder.pin`, the snapshot's own `system.rootfs.zst`) under arm64 qemu. Output is a local pacman repo at **`work/repo/<arch>/`** —
**arch-scoped**, since one aarch64 build serves every aarch64 SoC (NOT per-device). `customize-base.sh`
adds it as a `file://` repo **ahead of the holo repos** so the patched package wins (`pacman -S`
resolves by repo order, not version — the higher `pkgrel` only matters for later upgrades), and
folds the repo db's hash into the base reuse-cache key. `base` depends on `overlay` automatically.

### Rebuilds are incremental, and that is the only cache

`build-overlay.sh` hashes each package's committed inputs with `packages/inputhash.sh` and records
the result as `work/repo/<arch>/.stamps/<name>.hash`. A package is rebuilt when that hash moves or
its artifacts are missing, and skipped otherwise — so `make overlay` on a warm tree is a no-op, and
a one-line patch to one package costs one package's build.

```
make overlay                                # rebuild whatever moved, index the repo
packages/build-overlay.sh --only mesa       # force one package, skip re-examining the rest
packages/build-overlay.sh --prune-retired   # also purge packages no source.pin names any more
packages/inputhash.sh packages/mesa         # the digest that decides
```

Cost matters here because it is what shapes the CI design: a cold build of the set takes **hours on
a dev box** under arm64 emulation but **well under 30 minutes on a native aarch64 runner**.
If a build starts unexpectedly, check the stamp before assuming something is broken:

```
cat work/repo/aarch64/.stamps/mesa.hash     # what was built
packages/inputhash.sh packages/mesa         # what the tree says now
```

`.stamps/<name>.files` is the other half, and the more load-bearing one: it maps a package directory
to the several artifacts it emitted (`mesa` emits five), and both `genmanifest.sh` and `fetchlock.sh`
hard-fail without it.

**There is no shared artifact store.** (CI's `warm` cache is a copy of this directory and its stamps,
not a store: nothing is published or pinned.) A GHCR store keyed by the same input hash existed until
2026-08-04 — with `oras`, an `artifact.pin` per package, and a bot PR carrying published shas — and
it was retired because it was built for the emulated cost and CI never paid it. See *What CI does
with these packages* above for the measurements. `work/repo/<arch>/` is a plain pacman repo, so if
one is ever wanted again, serving that directory over HTTP and repointing the `[retroforge]` `Server`
is the cheap version.

### How these packages are pinned — `inputhash.sh`

`packages/inputhash.sh <package-dir>` prints a digest of a package's **committed inputs**: its
`source.pin`, the patches that pin declares, and `pkgbuild_local` if it has one. Three readers share
that one formula, and they have to agree byte for byte:

| reader | what it does with it |
|---|---|
| `build-overlay.sh` | incremental-rebuild cache key (`work/repo/<arch>/.stamps/<name>.hash`) |
| `rootfs/genmanifest.sh` | writes it into `rootfs/manifest.lock` as the `retroforge` rows' hash |
| `rootfs/fetchlock.sh` | re-derives it and refuses the install when the lock disagrees |
| `packages/verify-lock-rows.sh` | the same comparison from committed files only, so it can run **before** a build (`make verify-lock`) |

So the lock pins these rows to their **sources**, not to the built artifact's bytes — these builds
are not bit-reproducible, and an artifact hash moved on every rebuild from unchanged inputs, which
only ever verified on the machine that last ran `make relock`. Consequences worth knowing:

- Rebuilding a package changes nothing in the lock. Editing a patch or bumping a pin **does**, and
  `fetchlock` will say so by name and ask for `make relock`.
- One split PKGBUILD legitimately gives several rows the same hash (`mesa` emits `mesa`,
  `vulkan-freedreno`, `vulkan-mesa-device-select`). **All of them move together.** Hand-editing the
  row whose name matches the package *directory* and stopping there is a real mistake that has
  happened: it looks correct on every package but one, because only
  `mesa` is split. `make verify-lock` catches it in a second and names the owning package;
  `fetchlock` also catches it, but not until a repo exists to check against.
- `work/repo` therefore survives `make distclean`; `make clean-overlay` still forces a rebuild.

The hash is **path-independent** by construction, because it has to agree between a developer's
checkout and a CI runner's workspace. Do not "simplify" it to `sha256sum "${inputs[@]}" |
sha256sum`: that hashes `<hash>  <path>` lines and silently follows the directory.

### Local (checked-in) PKGBUILD — `pkgbuild_local`

When there is **no suitable holo PKGBUILD** to fetch — a version bump holo hasn't taken, or a
build the holo recipe doesn't cover — point the pin at a retroforge-owned PKGBUILD committed next
to it instead of the `pkgbuild_repo`/`pkgbuild_path`/`pkgbuild_ref` triple:

```
name: mesa
pkgbuild_local: PKGBUILD                          # checked-in recipe (relative to this dir)
pkgrel_suffix: 1
patches: 0001-foo.patch                           # optional; same -p1 injection as fetched pins
```

Everything else is identical: `build-overlay.sh` bumps `pkgrel`, injects the `patches:` after the
first `cd` in `prepare()`, and `makepkg`s it under arm64 qemu. The PKGBUILD still downloads its own
upstream source (e.g. a release tarball), so this stays "from-source", just with a recipe we own.

Current overlay:
- `gamescope/` — **local PKGBUILD** building gamescope `3.16.28` (newer-Turnip/ROCKNIX parity)
  with our remaining patches under `packages/gamescope/patches/`. The composite-rotation patch for
  the portrait Pocket S2 panel is UPSTREAM as of 3.16.28 and no longer carried. (Was a fetched holo
  PKGBUILD at 3.16.17; moved local for the bump.)
- `mesa/` — **local PKGBUILD** building mesa `26.2.0` from the upstream tarball. It tracks the
  Arch/holo recipe (same `arch-meson` invocation + meson options) as closely as possible; the only
  deviations are `gallium-drivers`/`vulkan-drivers` narrowed to **freedreno** (GL) + **freedreno**
  Vulkan (Turnip), plus `gallium-rusticl=false` (no OpenCL → no Rust crate chain) and
  `html-docs=disabled`. LLVM/clang stay on, as upstream. Replaces holo's stale, all-driver
  `mesa`/`vulkan-freedreno`. Carries SM8750 / Adreno a830 enablement patches under
  `packages/mesa/patches/`.
- `rauc/` — **local PKGBUILD** building rauc `1.15.2` from the upstream release tarball. This is
  holo's own `extra-aarch64/r/rauc/1.14-1` recipe with the version bumped and nothing else
  redesigned — the *only* reason we build it is that 1.14 cannot install a dm-verity bundle on a
  kernel `>= 6.19` (upstream fixed it first in `v1.15.1`) and we ship 7.1.x. No retroforge patches.
  Unlike the entries above it outranks holo's build by `pkgver`, not just by repo order.
