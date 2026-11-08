# RetroForge

**A retro-emulation OS for Qualcomm Snapdragon handhelds.**

Turn an AYANEO Pocket, AYN Odin, Retroid Pocket, KONKR or MANGMI handheld into a console-like
emulation machine: boot straight into a gamepad UI, pick a system, pick a game, play.

---

## Status

RetroForge is at **Phase 0**: the base system boots to a gamescope session on the supported SoCs, with
a liveness placeholder (`vkcube`) where the shell will be. Not yet a usable product.

| Phase | What lands |
|---|---|
| 0 | Base system: the Holo aarch64 root, unified kernel, A/B updates, boots to a gamescope session |
| 1 | [OpenGamepadUI](https://github.com/ShadowBlip/OpenGamepadUI) as the shell |
| 2 | Handheld features in the shell: power profiles, suspend, brightness, updates, first-boot Wi-Fi |
| 3 | Emulators: RetroArch + cores and standalone emulators, built natively against our Mesa/Turnip |
| 4 | A ROM library in the shell |
| 5 | Release infrastructure: signing CA, update server, release channel |

You need an **unlockable bootloader**, a spare **SD card**, and the device already running
**[OpenABL](https://github.com/OpenHandheldCollective/OpenABL)** — the custom bootloader that can
start a Linux system on these handhelds at all (the community continuation of the ROCKNIX ABL; if
you already run ROCKNIX you have a compatible one). RetroForge does not ship one; on a stock Android
bootloader a card simply does nothing. RetroForge runs from the card and does not touch your Android
install.

## Supported devices

<!-- AUTO-GENERATED from rootfs/overlay/usr/lib/retroforge/devices/*.conf — regenerate with /ecc:update-docs -->

| Board | SoC | Profile |
|---|---|---|
| AYN Odin 3 | SM8750 | `ayn-odin-3` |
| KONKR Pocket FIT Elite | SM8750 | `konkr-pocket-fit-elite` |
| AYANEO Pocket S2 | SM8650 | `ayaneo-pocket-s2` |
| KONKR Pocket FIT | SM8650 | `konkr-pocket-fit` |
| AYANEO Pocket ACE | SM8550 | `ayaneo-pocket-ace` |
| AYN Odin 2 | SM8550 | `ayn-odin-2` |
| AYN Thor | SM8550 | `ayn-thor` |
| Retroid Pocket Nova | SM8550 | `retroid-pocket-nova` |
| AYN Thor Lite | SM8250 | `ayn-thor-lite` |
| MANGMI Pocket Max | SM8250 | `mangmi-pocket-max` |
| Retroid Pocket 5 | SM8250 | `retroid-pocket-5` |
| Retroid Pocket 5 Visionox | SM8250 | `retroid-pocket-5-visionox` |
| Retroid Pocket Flip2 | SM8250 | `retroid-pocket-flip2` |
| Retroid Pocket Flip2 Visionox | SM8250 | `retroid-pocket-flip2-visionox` |
| AYANEO Pocket DMG | SM8550 | `ayaneo-pocket-dmg` |
| AYANEO Pocket DS | SM8550 | `ayaneo-pocket-ds` |
| AYANEO Pocket EVO | SM8550 | `ayaneo-pocket-evo` |
| AYANEO Pocket S 1K | SM8550 | `ayaneo-pocket-s1k` |
| AYANEO Pocket S 2K | SM8550 | `ayaneo-pocket-s2k` |
| AYN Odin 2 Mini | SM8550 | `ayn-odin-2-mini` |
| AYN Odin 2 Portal | SM8550 | `ayn-odin-2-portal` |
| Retroid Pocket 6 | SM8550 | `retroid-pocket-6` |
| Retroid Pocket Mini | SM8250 | `retroid-pocket-mini` |
| Retroid Pocket Mini V2 | SM8250 | `retroid-pocket-mini-v2` |
| MANGMI Air Y Pro | SM8250 | `mangmi-air-y-pro` |
| MANGMI Air X MQ65 | SM6115 | `mangmi-air-x-mq65` |
| MANGMI Air X MQ66 | SM6115 | `mangmi-air-x-mq66` |
| MANGMI Air X MQ66B | SM6115 | `mangmi-air-x-mq66b` |
| MANGMI Air Y | SM6115 | `mangmi-air-y` |
| Anbernic RG 55G1 | SM4450 | `anbernic-rg55g1` |
| Retroid Pocket Classic | SM4450 | `retroid-pocket-classic` |
| Retroid Pocket Classic 6 | SM4450 | `retroid-pocket-classic-6` |
| Retroid Pocket Classic 6 Rev Q | SM4450 | `retroid-pocket-classic-6-revq` |
| Retroid Pocket Classic Rev Q | SM4450 | `retroid-pocket-classic-revq` |

<!-- END AUTO-GENERATED -->

No board has been validated on RetroForge itself yet. The kernel, device trees and per-board data are
the ones the upstream project validated (see *Acknowledgements*), so the table is what the hardware
layer supports, not a claim about RetroForge builds.

> **SM8250 boards have no sensor DSP.** The `slpi.mbn` firmware for that SoC is published in no
> open source, so every Snapdragon 865 board is without its accelerometer — no auto-rotation.

> **SM6115 (MANGMI Air X, Air Y) and the MANGMI Air Y Pro are ports in progress** — brought over from
> ROCKNIX's trees on 2026-10-09 and not yet booted on RetroForge. Its Steam story is also different: Valve's arm64 client
> builds after 2026-04-15 need ARMv8.1 LSE atomics, which the Air X's Cortex-A73/A53 cores lack.

> **SM4450 (Anbernic RG 55G1, Retroid Pocket Classic) is a port in progress** — brought over from
> ROCKNIX's SM4450 device on 2026-10-26 and not yet booted on RetroForge.

One image serves every device: the running system identifies the board and configures itself.

## For developers

### What it is

An immutable, A/B-updatable aarch64 Linux distribution built on SteamOS 3 "Holo" packages, on
Qualcomm mobile silicon (**SM4450 / SM6115 / SM8250 / SM8550 / SM8650 / SM8750**). The root is read-only, bootstrapped from
packages into a sealed Btrfs image; updates are RAUC bundles installed to the inactive slot behind a
custom `retroforge-bootctl` bootloader backend. No Steam client, no x86 emulation, no Android container.

The build is **unified** — one image for every supported SoC, one kernel carrying the union of
drivers and DTBs. There is no `SOC` argument.

### Build

Everything goes through the top-level `Makefile`, which wires the per-stage scripts into one
incremental graph and pins where each stage runs. Kernel, rootfs assembly, boot packaging and
bundling all cross-compile inside the `retroforge-build` Docker image. **Never invoke the stage
scripts by hand.**

```sh
make help                       # every target and knob
make sdcard                     # full image -> out/images/sdcard.img
make kernel                     # Image + dtbs + modules
make test                       # offline suites: no build, no container, no root, no device
```

Dev vs release is selected by **environment**, not by a make knob, and it must be sourced before
*every* invocation — a bare `make` afterwards flips the mode and rebuilds the other one:

```sh
set -a; . ./dev.env; set +a
```

`RETROFORGE_DEV=1` is the developer path: Wi-Fi creds, an SSH key and the dev package set baked in. See
`make help` and the header of the `Makefile` for every knob.

### Repository layout

The tree follows the order a build happens in: assemble a root, lay it onto a disk, ship it to a
device.

| Path | Purpose |
|---|---|
| `rootfs/` | **What is inside a root.** The package closure (`manifest.lock` + its generator and materializer), the bootstrap that lays it down, and the seal/trim/guard trio that says what a release root must not be able to do |
| `rootfs/overlay/` | The payload injected into every root with a single `cp -a` — one tree mirroring the device's own filesystem |
| `rootfs/conf/` | The declarative inputs: `pacman.conf`, `os-release`, `trim.list`, `seal.list` |
| `image/` | **Turning a root into partitions.** The A/B layout and its `sgdisk` emitter, the initramfs, the card assembler, and the verifier that reads the result back |
| `ota/` | **Getting an image onto a device already in the field.** Signed RAUC bundles and the signing CA that mints their cert, the publishers, and the nginx/CI-user setup for the OTA host |
| `installer/` | The internal installer, shipped in the root and started from Settings: the partition carve, the on-device UI, and the read-only board probe |
| `packages/` | From-source overlay: PKGBUILDs + source pins for what we patch or version-bump, plus the builder that turns them into a local pacman repo |
| `kernel/` | Unified kernel: config fragments, patches, all device trees, firmware embed list |
| `firmware/` | Vendor firmware fetch/verify recipes + their pins |
| `boot/` | UEFI boot: the ESP GRUB picks the slot from RAUC's state, the per-slot stage-2 config picks the board; GRUB from a pinned release |
| `apps/retroforge-splash/` | The boot splash drawer |
| `tests/` | Every offline suite. `make test` runs the host ones; the signing and disk suites need a container |
| `build/` | Where the build itself is pinned: the cross-compile `Dockerfile`, the builder digest and the repo snapshot |

Most of those directories carry their own `README.md` documenting them file-by-file.

### Adding a board

Three pieces of data, all discovered automatically: a DTS under `kernel/dts/qcom/`, a device
profile under `rootfs/overlay/usr/lib/retroforge/devices/` plus its `model` case in `device-env`, and —
if the gamepad is not already covered — an InputPlumber config. An unmatched board falls through
to `defaults.conf` and still boots.

## Acknowledgements

RetroForge is a derived work. Its build system, A/B update path, installer, hardware layer and most of
its tooling started as a copy of **[Nova-Deck/os-build](https://github.com/Nova-Deck/os-build)**
(GPL-2.0-or-later), adapted for a retro-emulation focus. The notices of that work travel with it.

**[ROCKNIX](https://rocknix.org/)** — their **ABL work is the foundation everything here stands on**:
these handhelds ship an Android bootloader that will not load an ordinary Linux boot flow, and
solving that gates every other problem. Beyond that: the kernel enablement, the device trees, and
the device-by-device bring-up this class of hardware depends on.

**Armada** showed that a console-style handheld experience on this hardware was a real target, and
the boot splash's design derives from its `armada-splash`.

Thanks also to Valve and Collabora, whose aarch64 Arch port RetroForge builds on, and to the Mesa,
gamescope, InputPlumber, OpenGamepadUI and RAUC projects.

## License

RetroForge's own code is **GPL-2.0-or-later**. The full text of GPL-2.0 is in [LICENSE](LICENSE); "or
later" is stated here and applies to everything in this repository that is ours — you may use this
work under GPL-2.0 or, at your option, any later version published by the Free Software Foundation.

Third-party material in the tree keeps its own license, and a few cases are worth naming because
the LICENSE file alone would misrepresent them:

| What | License |
|---|---|
| `kernel/patches/*` | derivatives of Linux — **GPL-2.0-only**, not "or later" |
| `boot/patches/grub/*` | derivatives of GRUB — **GPL-3.0-or-later** |
| `packages/*/patches/*` | each carries the license of the project it patches |
| `apps/retroforge-splash/src/stb_truetype.h` | stb_truetype v1.26, **public domain** (Sean Barrett), vendored verbatim |

`apps/retroforge-splash` is a from-scratch implementation whose design is derived from Armada's
`armada-splash` (GPL-2.0-or-later).

## Firmware

Proprietary Qualcomm firmware is **never** committed to this repo. `firmware/` holds only
fetch-and-verify recipes against two pinned sources, both landing in gitignored trees: open
firmware from upstream `linux-firmware`, and device-proprietary vendor blobs — extracted from each
device's Android vendor image and published at
[retroforge-linux/qcom-firmwares](https://github.com/retroforge-linux/qcom-firmwares) — at a pinned commit,
verified against that repo's `sha256sums.txt`.

Respect per-device bootloader-unlock terms and upstream package licenses.
