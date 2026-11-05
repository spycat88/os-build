# CI

## Today: `.github/workflows/ci.yml`

Three jobs, no secrets, on every push and pull request:

| job | what it runs | needs |
|---|---|---|
| `test` | `make test` — `verify-lock`, then every offline suite under `tests/` (boot state, post-install, update client, pairing, power, installer UI, rootfs guard, upstream-name check, …) | the runner's shell, plus `grub-common` so `test-install.sh`'s grub-editenv case runs |
| `disk` | `tests/test-select-target.sh` and `tests/test-carve.sh` — the installer's disk choice and carve, against the real GPTs captured in `docs/internal-storage.md` | `gdisk`, `mtools`, `dosfstools` from apt |
| `signing` | `make test-signing` — every case a negative against `ota/rauc/verify-signing.sh` | `build/Dockerfile`'s `signing` stage (rauc + openssl + mksquashfs, ~66 MB) |

## Today: `.github/workflows/overlay.yml` — the package compile pass

Builds the from-source overlay packages a **pull request** touches, to prove they still compile.
It publishes nothing and needs no secrets. Triggered by a change to any overlay input
(`packages/*/source.pin`, its patches, a local `PKGBUILD`, `build-overlay.sh`, `inputhash.sh`,
`build/builder.pin`, `build/snapshot.pin`, `build/lib-pins.sh`), plus `workflow_dispatch`.

| job | runner | what it runs |
|---|---|---|
| `plan` | x86 | `verify-lock-rows.sh`, then a `git diff` against the base ref → the build matrix |
| `build` | `ubuntu-24.04-arm` | one job per *changed* package: `build-overlay.sh --only <pkg> --no-index` (PRs and dispatches only) |
| `warm` | `ubuntu-24.04-arm` | on `main` only: restore the overlay cache, `build-overlay.sh --prune-retired`, save it back |

Three properties this leans on:

- **Native aarch64, so no emulation.** `build-overlay.sh`'s own binfmt probe passes and it never
  registers qemu or needs `--privileged`. `vars.OVERLAY_RUNNER` overrides the label; do **not**
  point it at a self-hosted runner while this repo is public.
- **Fork PRs run it fine**, now that nothing is published: `contents: read`, no secrets, no registry.
- **Unknown scope widens the check.** A dispatch with no diff base, or a change to the builder
  itself, selects every package rather than none.

**A push to `main` runs `warm`, not the matrix.** `warm` keeps the overlay cache the release builds
restore (`actions/cache`, key `overlay-aarch64-<hash of every overlay input>`, falling back to the
previous `main` entry). `build-overlay.sh`'s per-package stamps then rebuild only what moved, as they
do on a dev box. It has to be `main`: caches are scoped by ref, and a release runs on a **tag**, which
can read `main`'s caches but saves into a scope no later tag can see. PR caches, fork PRs included,
are never visible to a release. `workflow_dispatch` on `main` with no package list re-warms by hand;
on any other branch it forces a proof pass over a branch that never saw a PR.

### What used to be here

Until 2026-08-04 this workflow was a build-once-and-cache pipeline: it published every package to
GHCR keyed by `packages/inputhash.sh`, ran a `verify` job asserting a cold machine could reconstitute
the repo with zero compiles, and opened a **pin-bump PR** carrying each artifact's sha256 into
`packages/*/artifact.pin` — which a release build then enforced. It needed two PATs (`PIN_BUMP_PAT`,
`GHCR_PRUNE_TOKEN`), a pinned `oras`, and a prune job.

It was retired because its premise was a **dev-box** number. An overlay build costs hours under arm64
emulation on a workstation, and the store existed so nothing paid that twice. CI never paid it: on
`ubuntu-24.04-arm` the packages measured `sddm 5m, mesa 5m, gamescope 4m, scx-scheds 4m,
mangohud 3m, rauc 1m` — well under half an hour for the set (the larger set the tree started from
took ~34 minutes), against a release card build that already ran 33–41 minutes. Both PAT secrets can
be deleted; nothing reads them.

That half hour is still paid by every release build job, rebuilding identical sources almost every
time, which is what brought back the `warm` cache. It keeps none of the store's machinery: no registry, no secret,
no pin, no bot. The stamps decide freshness, and `fetchlock.sh` checks the lock rows against the
commit's sources the same as ever.

The signing job checks the committed keyring (`ota/rauc/retroforge-ca.pem`) against the committed
release certificate (`ota/rauc/release.cert.pem`). Both are public, so it runs on a fork's PR
with access to nothing. The private half — does the signing *key* match that cert — announces
itself as skipped there and runs wherever a PKI is mounted:

    PKIDIR=~/retroforge-pki make test-signing

## Today: the release image builds

`.github/workflows/image.yml` is a `workflow_call`-only builder: restore the overlay cache `warm`
saved on `main` → `build-overlay.sh --prune-retired` (a re-index when nothing moved, ~30 min cold) →
`make toolchain` → `make sdcard`, `make bundle` or `make installer`, with `df -h` into the step
summary.
work/ peaks near 30 GB and out/ near 21 GB against ~109 G free on the runner, measured by
`preflight.yml` — there is room, and an earlier design that deleted each stage's inputs as it went
was reverted as cleverness bought against a limit that is not there. Two thin callers invoke it on
their own triggers, because the flashable images (card and installer) and a field update are wanted
at different cadences:

| workflow | trigger | secrets | ships to |
|---|---|---|---|
| `release.yml` | `v*` tag, or manual | none — `GITHUB_TOKEN` only; `release-cards` for its reviewer | one GitHub Release, `RetroForge vX.Y.Z` under tag `vX.Y.Z`, carrying `sdcard.img.gz`, `installer.img.gz` and a `.sha256` for each |
| `release-bundle.yml` | `ota/v*` tag, or manual | `RAUC_CERT_PEM`/`RAUC_KEY_PEM` and `R2_*` (repo-wide: no environments on this plan) | the Cloudflare R2 bucket in `vars.R2_BUCKET`, `<channel>/` prefix, served at `https://ota.retroforge.org` (see `docs/ota.md`) |

**The tag namespaces are separate on purpose.** A bundle ships far more often than an image, so it
has its own `ota/v*` namespace; the bare `v*` cuts the card and installer together (the two used to
be separate `card/v*` and `installer/v*` releases). `v1.3.0` and `ota/v1.3.0` on one commit are the
same OS delivered two ways.

**The card is a release asset** since 2026-10-13: a release card compresses to 524 MiB (gz -6), a
quarter of GitHub's 2 GiB per-asset cap, and the release job checks the cap before uploading. It went
to R2 while it measured 5.08 GiB (2026-08-04, root still carrying an x86 stack). The repo is private,
so downloading a card needs a GitHub login with access to it. The installer medium (404 MiB) is a
release asset the same way; nothing is published to R2 any more.

**CI is the only thing that PUBLISHES a release image**, because the reviewer gates and the signing
credentials live here. Building one is not restricted: `make sdcard` with no `RETROFORGE_DEV` produces a real release
image on a dev box, which is how a release image's first boot gets tested on hardware.

The blocker that once made a release build impossible on a clean runner is worth recording. A clean
runner has no `work/`, so it rebuilt the overlay, and because our builds are not bit-reproducible
`rootfs/fetchlock.sh` failed every run — the lock pinned those rows to artifact bytes only the last
`make relock` machine could reproduce. The lock now pins them to their **sources**, which is the
claim that survives crossing a machine. A release image's overlay is built from those same sources —
in the run itself, or by `main`'s `warm` job under stamps that hash them — so the source pins are also
its byte provenance. See `packages/README.md`.

## Today: the FEX guest image, `.github/workflows/release-fex-guest.yml`

Not part of any OS image. It builds `packages/mesa-x86` (our Mesa pin and patches for x86_64 +
i686) on an `ubuntu-24.04` x86_64 runner, composes it over FEX's ArchLinux RootFS, and uploads the
squashfs as a workflow artifact. With `publish` ticked it cuts a Release `fex-guest/v<version>` on
the built commit (reviewer: the `release-cards` environment), after the same 2 GiB per-asset check
as the card. **`workflow_dispatch` is its only trigger**: no push, tag or schedule, so nothing
starts it but a person. The version comes from the tree (`<mesa pkgver>-<guest.pin revision>`),
not from an input. Devices only use a published guest once
`rootfs/overlay/usr/share/retroforge/steam/x86-guest.pin` names it, and only if its url is public,
which a private repo's Release asset is not. See `packages/mesa-x86/README.md`.

## Not here yet, and why

**Bundle signing, beyond a CI secret.** `release-bundle.yml` signs only on an `ota/v*` tag, in its
`sign` job, inside the protected `release-signing` environment that holds `RAUC_CERT_PEM` /
`RAUC_KEY_PEM`; a dispatch builds with an ephemeral dev cert — it proves the bundle assembles and the
verity hashes compute, while producing something every device will reject. The open question is
whether the release private key belongs in GitHub at all. The shape is settled by the PKI:

- **one secret**, the release signing key, scoped to a protected *environment* (not the repo, where
  any workflow on any branch can read it). Write it to `$RUNNER_TEMP`, never the workspace — the
  repo tree gets uploaded as artifacts and cached.
- `PKIDIR=$RUNNER_TEMP/pki make bundle` mounts it read-only at `/pki` and points `RAUC_CERT` /
  `RAUC_KEY` at it. Copy the committed `ota/rauc/release.cert.pem` in alongside the key.
- `verify-signing.sh` then asserts the key matches the committed cert *as public-key digests*, so a
  stale or truncated secret fails there instead of producing bundles no device accepts.
- **the CA key never reaches a runner.** That is what the two-level PKI is for: if the release key
  leaks, mint a new cert offline under the same CA, commit it, update the one secret — no device is
  affected. See `ota/gen-signing-ca.sh`.
- worth considering before real releases: signing off-CI, or via an HSM/KMS the runner reaches by
  OIDC, so the key never exists as a file. A key that can push arbitrary code to devices with no
  serial console is a large thing to keep in a CI secret store.

**cosign-signed artifacts and published update manifests** — the original Phase 7 scope, CI
patterns borrowed from ublue-os/image-template, for the single unified image (every supported SoC
in one kernel + boot artifact). All of it sits on top of a working image build. The runtime update
mechanism stays RAUC A/B over read-only Btrfs roots.

## The standing caveat

CI green is not evidence about the device. The self-test runs the **build container's** rauc
against the shipped config; the device runs its own (the pinned snapshot's). A 1.14-on-device /
1.15-in-container skew is exactly how the dm-verity install bug reached hardware. Only an on-device
`rauc install` is evidence about the device.
