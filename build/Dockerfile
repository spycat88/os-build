# retroforge-build — cross-compile build environment for the whole pipeline on x86_64
# hosts (kernel, rootfs/sdcard assembly, boot packaging, RAUC
# bundle). Carries the aarch64 toolchain plus every container stage's deps; source and
# artifacts stay on the host via a bind mount (work/ and out/ are gitignored). Re-runnable.
#
# TWO STAGES, AND THE SPLIT IS ABOUT CI TIME. The `signing` stage below holds only what the RAUC
# signing self-test needs (rauc, openssl, mksquashfs); `full` adds everything else. That test signs
# and verifies real bundles and is the one suite that cannot run on the host, so `ci.yml` builds an
# image for it on every push and pull request — and it was paying for the kernel cross-toolchain,
# a foreign arm64 architecture, autotools, AutoGen and fontconfig to do it.
#
# MEASURED, which is why this exists: the signing job normally ran ~80s, essentially all of it this
# docker build. On 2026-08-04 (run 30917187270) the same build took 1739s — a 20x swing on Ubuntu
# archive throughput alone, finishing 61 seconds inside the job's 30-minute timeout. The baseline
# was never the problem; the unbounded variance was, and most of the payload driving it is
# irrelevant to what the job asserts.
#
# ONE FILE, ON PURPOSE. A separate slim Dockerfile would drift, and the drift would be silent in
# the worst possible place: the whole point of the self-test is that bundles are written by the
# rauc version we ship against. `full` derives FROM `signing`, so both halves resolve the same
# ARG RAUC_VERSION by construction — there is no second pin to forget.
#
# Build the full image with a plain `docker build` (it is the last stage, so it is the default
# target); `make test-signing` builds `--target signing`.

FROM docker.io/library/ubuntu:26.04 AS signing

ENV DEBIAN_FRONTEND=noninteractive

# rauc is the ONE apt package here pinned to an exact version, and it is deliberate. Everything
# else in the lists below (compilers, mkfs tools, curl) only has to work — a newer one produces the
# same artifact. rauc does not: it WRITES the update bundle, and the device's rauc has to be able
# to install what it wrote. That pairing is already load-bearing (the DEVICE side, the snapshot's
# rauc, must be >= 1.15.1 because 1.14 cannot install a dm-verity bundle on kernel >= 6.19), so
# letting the bundle WRITER float means the two halves of the update path can drift apart with no
# signal until a device refuses a bundle — and this device has no serial console to ask why.
#
# The cost of an exact pin is that the build BREAKS when Ubuntu supersedes this version and drops
# the old binary from the archive (Ubuntu has no per-package snapshot the way our pacman side
# does). That is the intended trade: a loud build failure that makes someone re-verify the
# writer/installer pair, rather than a silent version change under a working-looking build.
# To bump: check `apt-cache madison rauc` in this base image, update the pin, and re-run the HW
# `rauc install` test before trusting the bundles it produces.
ARG RAUC_VERSION=1.15.1-1

# squashfs-tools is NOT incidental: `rauc bundle` shells out to mksquashfs for the verity format,
# so ota/rauc/verify-signing.sh cannot mint the bundles it then breaks on purpose without it.
# openssl mints the throwaway cert profiles the negative cases feed in.
RUN apt-get update && apt-get install -y --no-install-recommends \
      openssl ca-certificates \
      squashfs-tools \
      "rauc=${RAUC_VERSION}" \
    && rm -rf /var/lib/apt/lists/*

# Set here rather than in `full` so both stages carry them — a derived stage inherits its parent's
# config, and tests/test-verify-signing.sh is invoked as a bare argument (the ENTRYPOINT bash is
# what runs it).
WORKDIR /src
ENTRYPOINT ["/bin/bash"]

# ==============================================================================
# Everything the rest of the pipeline needs, on top of the signing base.
# ==============================================================================
FROM signing AS full

RUN apt-get update && apt-get install -y --no-install-recommends \
      build-essential \
      gcc-aarch64-linux-gnu \
      ccache \
      bc bison flex \
      dwarves \
      libssl-dev libelf-dev \
      kmod cpio rsync \
      openssh-client \
      xz-utils patch device-tree-compiler \
      curl \
      make python3 \
      librsvg2-bin \
      btrfs-progs gdisk fdisk dosfstools mtools e2fsprogs \
      casync \
      erofs-utils \
      libcap2-bin \
      bsdextrautils zstd \
    && rm -rf /var/lib/apt/lists/*
# bsdextrautils carries `hexdump`, which the kernel's EFI zboot rule
# (drivers/firmware/efi/libstub/Makefile.zboot) needs; zboot is off now (kernel/kernel.config),
# and it stays so turning zboot back on still builds. Ubuntu ships hexdump there, not in util-linux. zstd compresses the initramfs (image/mkinitramfs.sh).
# `fdisk` is NOT redundant with `gdisk`, and neither is it implied by util-linux: Debian ships
# sfdisk in the `fdisk` package while blkid and partx come from util-linux in the base image, so
# `command -v sfdisk` was empty here while every device had it. image/lib-gpt.sh reads type GUIDs
# with `sfdisk --dump` -- one call for the whole table -- to tell a live partition from a GPT entry
# whose type a foreign uninstaller zeroed (issue #56). Without it the installer suites cannot run
# the code they are testing at all.
#
# librsvg2-bin is `rsvg-convert`, which image/mksplash.sh uses to flatten the boot logo from SVG
# to a raster on THIS host. It is deliberately a host-native tool: the splash binary is static
# with no libraries at all, so it carries no SVG or PNG decoder, and the first splash attempt
# died precisely because a rasteriser was cross-built for the device and then failed to load
# there. python3 (above) finishes the job — png2nds1.py needs only stdlib zlib.
#
# erofs-utils is here for ONE assertion, and it earns its place: assemble-rootfs.sh reads the
# graphics_provider.json out of the pinned FEX guest .ero to prove the guest still carries one.
# The mount that surfaces it is `nofail`, so without this the answer arrives at x86 game launch,
# on a user's device. dump.erofs reads the image unprivileged — no loop device, no FUSE, which is
# what makes the check runnable inside this container at all.

# Boot stage: there is no bootloader to build. OpenABL boots Boot Loader Specification entries
# straight off the ESP, and the entries are text (boot/gen-bls.sh, lib-bls.sh), so the GRUB build
# deps that used to live here (AutoGen, autopoint, gawk, fontconfig/freetype for grub-mkfont,
# grub-common, gnu-efi) are gone.
#
# zstd is the BINARY, which GNU tar shells out to for --zstd; tar 1.35 accepts the flag either way
# and fails at run time without it. rootfs/assemble-rootfs.sh needs it for var-seed.tar.zst, the
# /var the internal installer unpacks onto a fresh slot. Note this is the one compressor here that
# the IMAGE also carries (work/base/usr/bin/zstd, a pacman dependency), which is what lets the
# installer extract what this container packs.
RUN dpkg --add-architecture arm64 && apt-get update && apt-get install -y --no-install-recommends \
      zstd \
      git \
      libc6-dev-arm64-cross \
      autoconf automake libtool pkg-config gettext \
    && rm -rf /var/lib/apt/lists/*
