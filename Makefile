# retroforge master build orchestrator.
#
# Drives the whole Phase-1 pipeline — toolchain image, kernel, firmware, base
# rootfs, read-only root, boot artifact, SD card / RAUC bundle — as one incremental
# dependency graph so each stage rebuilds only when its inputs change. The individual
# stage scripts under kernel/ firmware/ rootfs/ image/ ota/ boot/ stay the source of truth; this
# file only wires them together and pins WHERE each one runs (host vs container).
#
# Quick start:
#   make sdcard        # full bring-up image -> out/images/sdcard.img
#   make help          # list every target
#
# Conventions:
#   * The build is UNIFIED — one image serves every supported SoC/board. There is no SOC
#     argument: the kernel is built with the union of all config fragments, patches and
#     device trees (kernel/), and the boot artifact bundles every board DTB (the ABL DTB
#     picker selects at boot).
#   * Container stages run in the retroforge-build image with the repo bind-mounted at
#     /src; host stages either need the network or drive docker themselves (base
#     customization registers qemu binfmt, so it cannot run nested in the container).
#   * Stamp files live under the already-gitignored out/ work/ firmware/ trees.
#
# Memory: builds cross-compile INSIDE docker, never on the host. Don't reorder the
# kernel patches. work/base is root-owned (clean-base uses docker to remove it).

BUILD_IMG ?= retroforge-build
# The RAUC signing self-test's image: build/Dockerfile's first stage, holding rauc + openssl +
# mksquashfs and nothing else. Separate because that suite runs on every push and pull request and
# has no use for the cross-toolchain the full image spends its build time on. Same Dockerfile, so
# the two cannot disagree about the rauc pin — see the header there.
SIGN_IMG  ?= retroforge-sign

# Optional knobs forwarded to the underlying scripts:
#   BASE_CONFIG  repo-relative path to a full verbatim kernel .config (e.g. a ROCKNIX
#                config) — skips the defconfig+fragment merge in kernel/build.sh.
#   RETROFORGE_VERSION  the release this build calls itself, stamped into /etc/retroforge-release AND
#                carried by the RAUC bundle manifest. Empty (a local build) renders as `dev`, and
#                the bundle then identifies itself by its build timestamp instead. CI sets it from
#                the release tag. There is no separate bundle-version knob; see below.
#   RETROFORGE_DEV=1  build a dev image. `set -a; . ./dev.env; set +a` sets this and the rest;
#                dev.env is TRACKED and secret-free, and sources dev.env.local (gitignored) for
#                Wi-Fi creds. A RELEASE image (no RETROFORGE_DEV) builds locally too — it just
#                cannot be published, since the release reviewer and signing credentials only exist in CI.
#   RETROFORGE_WIFI_SSID/PSK  OPTIONAL dev-only Wi-Fi profile, injected from the environment so it
#                never touches the repo. Absent => a card with NO network and no SSH, i.e. the
#                shipping first-boot condition (the only honest way to test OOBE locally).
#   RETROFORGE_WIFI  intent knob for the above: 1 = require creds (fail loudly rather than hand you
#                an unreachable card), 0 = no profile even when creds are set. See dev.env.
#   RETROFORGE_SSH_PUBKEY  root's authorized_keys on a dev card. dev.env generates a throwaway key
#                under work/dev-ssh/ rather than using your personal one.
BASE_CONFIG ?=

OUT := out

# Source-tree layout, as variables rather than the ~120 hardcoded strings they replace. The repo
# was flat until 2026-08-26 and every directory name appeared verbatim in dozens of recipes, so a
# rename was a repo-wide sed with no way to tell a path from prose. These make the next move a
# one-line change. They name SOURCE directories only — build outputs stay under $(OUT), and
# $(OUT)/images/ is deliberately NOT tied to any of them (release workflows and muscle memory
# both depend on those artifact paths).
ROOTFS_DIR := rootfs
IMAGE_DIR  := image
OTA_DIR    := ota
TESTS_DIR  := tests

# work/ must be created by the HOST, and before anything else runs. Several stages that write
# into it are root inside docker (the kernel build's modules_install, the base export), so on a
# tree where work/ does not exist — a fresh clone, or a `rm -rf work` full-rebuild test —
# whichever container stage lands first creates work/ ITSELF root-owned. Every host-side stage
# after that then dies on mkdir/touch inside it: packages/build-overlay.sh, work/.base.stamp,
# work/.rootfs-mode-*. (Cost a rebuild on 2026-07-26.)
#
# out/ never had this problem because out/.build-image.stamp is host-made through the
# `| $(BUILD_STAMP)` order-only prereq that every container stage carries. work/ has no single
# equivalent gate, and adding one per stage would silently regress the day a new stage forgets
# it — so create the directory at parse time, which no target can route around. Only the
# top-level directory is host-owned; the root-owned trees INSIDE it (work/base, work/kernel) are
# by design, and clean-base/distclean already remove those from inside a container.
# work/ccache is the same trap one level down: kernel/build.sh (root) creates work/ccache/kernel,
# and a root-made parent then fails packages/build-overlay.sh's host mkdir of overlay-<arch>.
$(shell mkdir -p work/ccache)

# --- where each stage runs ----------------------------------------------------
# Container runtime: docker where it is installed, otherwise podman (the Fedora build box runs
# rootless podman). Exported so the host scripts (build/lib-container.sh) make the same choice.
# Under podman every run disables SELinux labelling: on an enforcing host a container cannot read
# an unlabelled bind mount, and relabelling (:z) would rewrite the labels of the checkout.
RETROFORGE_CONTAINER ?= $(if $(shell command -v docker 2>/dev/null),docker,podman)
export RETROFORGE_CONTAINER
CTR_RUN  := $(RETROFORGE_CONTAINER) run$(if $(filter podman,$(RETROFORGE_CONTAINER)), --security-opt label=disable)
BUSYBOX  := docker.io/library/busybox
# Container: repo bind-mounted at /src. INBUILD is the plain run; DOCKER lets a
# recipe insert `-e VAR` flags (which must precede the image name) before the image.
DOCKER   := $(CTR_RUN) --rm -v $(CURDIR):/src -w /src
INBUILD := $(DOCKER) $(BUILD_IMG)

# --- signing material, which lives OUTSIDE the repo ---------------------------
# The OTA signing PKI is deliberately not under $(CURDIR): out/ is one `rm -rf` away from taking
# the 20-year root of trust with it, and a device flashed with a keyring whose key is gone rejects
# every future bundle. So the container cannot see it by default -- only /src is mounted.
#
# Set PKIDIR to mount it read-only at /pki for the two targets that need it:
#
#   PKIDIR=~/retroforge-pki make bundle          # a real signature
#   PKIDIR=~/retroforge-pki make test-signing    # incl. the keyring-vs-signing-key check
#
# Unset, both keep their previous behaviour exactly: `bundle` mints an ephemeral dev cert and
# `test-signing` announces the keyring check as skipped. Resolved with $(realpath ...) so a typo --
# or a tilde the shell did not expand -- fails here, loudly, instead of silently mounting nothing.
# NEVER answer this by copying private keys back under the repo.
ifdef PKIDIR
PKI_REAL := $(realpath $(PKIDIR))
ifeq ($(PKI_REAL),)
$(error PKIDIR=$(PKIDIR) does not exist (if it starts with ~, quote it differently: PKIDIR=$$HOME/...))
endif
PKI_MOUNT := -v $(PKI_REAL):/pki:ro -e PKIDIR=/pki
# The filenames ota/gen-signing-ca.sh always mints, so `PKIDIR=... make bundle` is enough on its own.
# ?= keeps an explicit RAUC_CERT/RAUC_KEY (env or command line) winning over these.
RAUC_CERT ?= /pki/release.cert.pem
RAUC_KEY  ?= /pki/release.key.pem
endif

# The bundling invocation, shared by `bundle` and `sign-bundle` so the two cannot drift in how the
# key reaches the container. Recursively expanded (`=`, not `:=`) because PKI_MOUNT and RAUC_CERT/
# RAUC_KEY only exist inside the ifdef above -- expanding this eagerly would bake in their values
# from before that block ran.
GENBUNDLE = $(DOCKER) $(PKI_MOUNT) -e RAUC_CERT="$(RAUC_CERT)" -e RAUC_KEY="$(RAUC_KEY)" $(BUILD_IMG) \
	  $(OTA_DIR)/genbundle.sh

# Dev-only credential env, forwarded into the rootfs assembler (no-op unless RETROFORGE_DEV=1).
DEV_ENV := -e RETROFORGE_DEV -e RETROFORGE_WIFI -e RETROFORGE_WIFI_SSID -e RETROFORGE_WIFI_PSK -e RETROFORGE_SSH_PUBKEY

# RetroForge's ScreenScraper developer login, for EVERY build (rootfs/lib-assemble-scraper.sh): from
# dev.env.local on a host, repository secrets in CI. Without it the image cannot scrape ROM art.
# SCRAPER_STAMP re-assembles the root when it appears or goes (presence only, like DEV_WIFI: a
# secret's value never names a file).
SCRAPER_ENV   := -e RETROFORGE_SS_DEVID -e RETROFORGE_SS_DEVPASSWORD
SCRAPER_STAMP := work/.rootfs-scraper-$(if $(RETROFORGE_SS_DEVID),$(if $(RETROFORGE_SS_DEVPASSWORD),on,off),off)

# Per-build identity, stamped into /etc/retroforge-release by rootfs/assemble-rootfs.sh so a flashed
# device can name the release it came from. RETROFORGE_VERSION is set by CI from the release tag and
# is empty for a local build, which assemble-rootfs.sh renders as `dev`. The git sha is resolved on
# the HOST: /src is bind-mounted into the container, but git itself is not in the build image.
#
# THIS IS THE ONLY VERSION KNOB, and as of 2026-08-03 it is also the bundle's. It used to be one of
# two: `VERSION` named the RAUC bundle and defaulted to today's date inside genbundle.sh, entirely
# independently of what the image called itself. The OTA client compares the manifest's identity
# against the device's /etc/retroforge-release to decide whether an update is available, so two
# unrelated strings meant that comparison was meaningless — a device could be offered its own build
# forever, or never be offered a real one. ota/genbundle.sh now reads the identity back OUT of
# the assembled image (out/images/rootfs.release) instead of being told, so the bundle cannot name
# a version the bytes inside it do not carry, and `VERSION` is GONE rather than kept as a
# cross-check: with $(VERSION_STAMP) below, a stale image cannot survive a version change, so a
# second knob could only ever be redundant or wrong.
RETROFORGE_VERSION ?=
RETROFORGE_GIT     := $(shell git rev-parse --short HEAD 2>/dev/null || echo unknown)
ID_ENV := -e RETROFORGE_VERSION -e RETROFORGE_GIT=$(RETROFORGE_GIT)

# RETROFORGE_VERSION changes the rootfs CONTENT (the /etc/retroforge-release it stamps), and make cannot
# see environment variables — the same trap RETROFORGE_DEV needed $(MODE_STAMP) for, with the same
# silent symptom: an existing rootfs.img looks up-to-date to a `RETROFORGE_VERSION=1.4.0 make bundle`,
# the assembler is skipped, and you ship a bundle whose image still identifies itself as the
# previous build. genbundle.sh would then name the bundle after those older bytes, which is honest
# but not what was asked for. Encode the version in a stamp the rootfs depends on, so changing it
# re-assembles. A re-assembly, not a base or kernel rebuild — the correct price for changing what
# the image calls itself.
VERSION_STAMP := work/.rootfs-version-$(if $(RETROFORGE_VERSION),$(RETROFORGE_VERSION),dev)

# RETROFORGE_DEV changes the rootfs CONTENT (Wi-Fi profile, SSH host keys + authorized_keys) but is
# an environment variable, which make cannot see. Without this, an existing release rootfs.img looks
# up-to-date to a `RETROFORGE_DEV=1 make sdcard`, the assembler is skipped, and you flash a RELEASE
# root wrapped in a dev-built card — no Wi-Fi, no SSH, and no error anywhere. (Cost me a boot cycle
# on 2026-07-09.) Encode the mode in a stamp file that rootfs depends on, so flipping it rebuilds.
# Lives under work/ (host-owned); out/images is written by the container as root.
#
# THE NAME: this was RETROFORGE_TEST until 2026-07-30. It was chosen while debugging the very first
# Steam OOBE, where "test" meant a throwaway card, and it long outlived that — this is the normal
# development cycle now, and the release path is the one that is special. Renamed with the artifact
# pins, since both turn on the same distinction: who built these bytes.
# The Wi-Fi profile is a THIRD state, not a sub-detail of dev, and it has to reach the stamp or it
# fails exactly the way RETROFORGE_DEV did before this stamp existed. "dev with creds" and "dev
# without creds" produce different rootfs CONTENT (an /etc/NetworkManager profile that auto-joins,
# or nothing), so sharing work/.rootfs-mode-dev between them means dropping the creds leaves the
# image looking up-to-date: the assembler is skipped and you flash the PREVIOUS card, still
# auto-joining, while believing you are testing the offline first boot. No error anywhere.
#
# DEV_WIFI mirrors the assembler's own decision (rootfs/assemble-rootfs.sh, `dev_wifi`) and must
# keep mirroring it: it is the EFFECTIVE outcome, not the knob. That distinction is the point —
# forgetting to source dev.env.local is indistinguishable from asking for no Wi-Fi as far as the
# image is concerned, so both must land on the same stamp. (RETROFORGE_WIFI=1 with no creds is a hard
# error in the assembler, so make needs no case for it.)
DEV_WIFI     := $(if $(filter 0,$(RETROFORGE_WIFI)),,$(if $(RETROFORGE_WIFI_SSID),$(if $(RETROFORGE_WIFI_PSK),1,),))
ROOTFS_MODE  := $(if $(filter 1,$(RETROFORGE_DEV)),dev$(if $(DEV_WIFI),,-nowifi),release)
MODE_STAMP   := work/.rootfs-mode-$(ROOTFS_MODE)

# The BASE tree is mode-dependent for the same reason and needs the same treatment: RETROFORGE_DEV=1
# adds DEV_PKGS (evtest, usbutils) to the bootstrap (rootfs/customize-base.sh:176), so a dev base
# and a release base are DIFFERENT trees. Every $(BASE_STAMP) prerequisite is a file and none of them
# encodes the mode, so without this a base built in one mode looks up-to-date to the other and make
# never invokes customize-base.sh at all — its mode-aware reuse key (`dev:1`, line 306) is
# unreachable in exactly the case it was written for. Caught on 2026-07-28 building a release bundle
# straight after a dev card: the release guard tripped on `only in tree: evtest usbutils`. The
# reverse direction — a release base under a DEV card — has no guard at all (guard-rootfs.sh is
# release-only) and is the direction that cost the 2026-07-09 boot cycle.
#
# This is a PREREQUISITE stamp, not a per-mode rename of $(BASE_STAMP). Naming the stamp
# work/.base-$(ROOTFS_MODE).stamp would be wrong: stamps accumulate, the tree does not. There is one
# work/base, so a `.base-dev.stamp` left behind by an earlier dev build still looks satisfied after
# a release build has since overwritten that tree — the stale-tree bug back again, silently. Instead
# there is one stamp for the tree and one marker for the mode it was built in, and the marker rule
# deletes its siblings so only ever one exists (same shape as $(MODE_STAMP) above). Flipping the mode
# re-creates the marker newer than $(BASE_STAMP), which re-runs customize-base.sh, which then really
# rebuilds because the mode is in its reuse key too. A flip costs a full base rebuild — the correct
# price, and the one `make relock` already pays deliberately.
# Deliberately NOT $(ROOTFS_MODE): that one carries the -nowifi dimension, and the base does not
# have one. DEV_PKGS keys off RETROFORGE_DEV alone, and the Wi-Fi profile is written by the ASSEMBLER,
# not by the bootstrap — so a dev base is byte-identical whether or not creds were present. Reusing
# ROOTFS_MODE here would rename this marker on a Wi-Fi flip and charge a full base rebuild (the
# expensive half of the build) for a change that cannot affect work/base. Toggling Wi-Fi costs a
# rootfs re-assembly and nothing more.
BASE_MODE       := $(if $(filter 1,$(RETROFORGE_DEV)),dev,release)
BASE_MODE_STAMP := work/.base-mode-$(BASE_MODE)

# --- artifacts (real file targets drive incremental rebuilds) -----------------
BUILD_STAMP := out/.build-image.stamp
SIGN_STAMP  := out/.sign-image.stamp
# Open linux-firmware blobs are SoC-agnostic — the unified kernel embeds the union — so this
# is a single flat tree, not per-SoC.
FW_LINUX     := firmware/linux-fw/.fetched.stamp
# Device-proprietary blobs are SoC-agnostic (the qcom-firmwares repo mirrors /lib/firmware,
# blobs self-namespaced by their on-device path), so this is shared across all SoCs.
FW_QCOM      := firmware/qcom-fw/sha256sums.txt
# The base tree is exported root-owned with the source image's FROZEN mtimes (e.g. sshd dates
# to the image build, not to this run), so it can't be the make target — a content change
# wouldn't bump any in-tree mtime and downstream stages would skip. A stamp outside that tree,
# touched after a successful customize, carries the real recency instead. It also lets a prebuilt-pin
# bump propagate: the pins are listed as prerequisites so editing one re-runs customize-base.
PREBUILT_PINS := $(wildcard packages/*/prebuilt.pin)
# From-source overlay packages (packages/*/source.pin + patches) — rebuilt holo packages with
# retroforge patches, landed in the local pacman repo work/repo/<arch>/ that customize-base.sh
# prepends ahead of the holo repos. The repo db is the make target; the union of pins+patches+
# PKGBUILDs is its prerequisite so ANY overlay input change re-invokes build-overlay.sh. The
# script is INCREMENTAL: it hashes each package's own inputs and rebuilds only the changed
# package(s) (so a one-line gamescope patch no longer recompiles mesa), then re-indexes the db.
OVERLAY_PINS    := $(wildcard packages/*/source.pin)
OVERLAY_PATCHES := $(wildcard packages/*/patches/*.patch)
# Checked-in local PKGBUILDs (pkgbuild_local in a source.pin, e.g. packages/mesa/PKGBUILD) are
# build inputs too — track them so editing a recipe (deps, meson options) rebuilds that package.
OVERLAY_PKGBUILDS := $(wildcard packages/*/PKGBUILD)
# Overlay packages are ARCH-scoped (a rebuilt aarch64 gamescope serves every aarch64 device),
# so the repo is shared at work/repo/<arch>/.
OVERLAY_ARCH    ?= aarch64
OVERLAY_DB      := work/repo/$(OVERLAY_ARCH)/retroforge.db.tar.zst
# Content stamp advanced by build-overlay.sh ONLY when it actually re-indexes (a package really
# rebuilt). base keys off THIS, not retroforge.db's mtime — the script bumps the db even on a no-op
# run (to stop make re-invoking it), and that spurious bump used to cascade the whole expensive
# customize-base off a byte-identical repo.
OVERLAY_STAMP   := work/repo/$(OVERLAY_ARCH)/.overlay.stamp
BASE_STAMP   := work/.base.stamp
KERNEL       := $(OUT)/vmlinuz.efi
ROOTFS       := $(OUT)/images/rootfs.img
# Sibling image the assembler emits alongside the root (see image/partition-table.txt):
# the writable state partition, which also carries the /etc overlay upper.
VARIMG       := $(OUT)/images/var.img
# Slot B's var, emitted by the same run. Identical but for /var/lib/retroforge/slot, which is the
# independent witness of which slot actually mounted (the roots are content-identical by design).
VARIMG_B     := $(OUT)/images/var-b.img
INITRAMFS    := $(OUT)/initramfs.cpio.zst
# The boot splash drawer (apps/retroforge-splash): one static aarch64 binary with no shared
# libraries, and the logo flattened to raw pixels beside it. Both go into the initramfs AND the
# sealed root, because the same program paints the pre-switch_root phase, the session phase and
# the shutdown screens.
SPLASH_BIN   := apps/retroforge-splash/build/retroforge-splash
SPLASH_ASSET := work/splash/logo.nds1
SPLASH_SRC   := apps/retroforge-splash/Makefile apps/retroforge-splash/src/retroforge-splash.c \
                apps/retroforge-splash/src/stb_truetype.h
# The asset is sized from the widest panel in the device registry (image/mksplash.sh reads it and
# fails the build when it outgrows the render box), so a new board's conf has to re-run it.
SPLASH_GEOM  := $(wildcard rootfs/overlay/usr/lib/retroforge/devices/*.conf)
# GRUB (boot/grub.sh). Co-products in the same out/boot: grub-esp.efi (the ESP GRUB), grub-a.cfg,
# grub-b.cfg, fonts/, grubenv (the pristine env block the ESP gets), grub-editenv (for RAUC on the
# device) and steamcl-version (what an older root's update hook expects beside the ESP GRUB).
GRUB         := $(OUT)/boot/grubaa64.efi
SDCARD       := $(OUT)/images/sdcard.img
# The LD_PRELOAD shim that moves a program's SIGTERM handler onto its GLib main loop
# (apps/retroforge-sigdefer; Snes9x's Exit crash). aarch64, built in the container like the splash.
SIGDEFER_LIB := apps/retroforge-sigdefer/build/libretroforge-sigdefer.so
SIGDEFER_SRC := apps/retroforge-sigdefer/Makefile apps/retroforge-sigdefer/src/retroforge-sigdefer.c
# The LD_PRELOAD library PortMaster's gptokeyb2 runs with (apps/retroforge-gptk-interpose; its exclusive
# pad grab under sdl2-compat). aarch64, built in the container like sigdefer.
GPTK_LIB     := apps/retroforge-gptk-interpose/build/libretroforge-gptk-interpose.so
GPTK_SRC     := apps/retroforge-gptk-interpose/Makefile apps/retroforge-gptk-interpose/src/retroforge-gptk-interpose.c
# The LD_PRELOAD shim that hides the menu bar of every QMainWindow after the first
# (apps/retroforge-hidemenu; melonDS's second window on dual-screen boards). aarch64, in the container.
HIDEMENU_LIB := apps/retroforge-hidemenu/build/libretroforge-hidemenu.so
HIDEMENU_SRC := apps/retroforge-hidemenu/Makefile apps/retroforge-hidemenu/src/retroforge-hidemenu.c
# Our Mesa built for x86_64 + i686 (packages/mesa-x86), which steam-x86-guest lays over the x86 guest
# Valve's FEX tool runs x86 games in. Built in an x86_64 Arch container: native on an x86_64 host,
# emulated (and slow) on an arm64 one. build.sh caches on its inputs, so an unchanged tree is a no-op.
# RETROFORGE_X86_MESA=0 builds an image without it (x86 games then use the guest's own Mesa).
MESA_X86_STAMP := work/mesa-x86/out/.inputs.sha256
MESA_X86_SRC   := $(wildcard packages/mesa-x86/*.sh packages/mesa-x86/*.pin) packages/mesa/source.pin \
                  packages/mesa/PKGBUILD $(wildcard packages/mesa/patches/*.patch)
MESA_X86_DEP   := $(if $(filter 0,$(RETROFORGE_X86_MESA)),,$(MESA_X86_STAMP))
# The RetroForge OpenGamepadUI plugin (apps/ogui-retroforge-plugin): a reproducible zip of plugin/, shipped
# read-only in the root and copied into the player's plugins folder by retroforge-session.
PLUGIN_ZIP   := $(OUT)/plugins/retroforge.zip
PLUGIN_SRC   := apps/ogui-retroforge-plugin/build.sh $(wildcard apps/ogui-retroforge-plugin/plugin/*)

# Repo sources the rootfs assembler reads directly (itself + the unified rootfs/overlay/ payload tree
# it copies in wholesale). find recurses, so files added under rootfs/overlay/ are tracked
# automatically — no per-file Makefile edits.
#
# rootfs/conf/seal.list + rootfs/seal-rootfs.sh are assembler inputs too: the seal is the last thing
# that touches the staged tree (Phase 4a step 3), so editing what gets stripped changes the image
# exactly as editing rootfs/overlay/ does.
#
# rootfs/guard-rootfs.sh is listed for the opposite reason -- it changes no bytes in the image, but
# it decides whether one is produced at all (Phase 4a step 4). A tightened assertion has to re-run
# against the tree it was tightened for, not wait for the next unrelated rootfs/overlay edit.
# rootfs/manifest.lock is one of its inputs (it asserts the tree still matches the lock) and is
# already a $(BASE_STAMP) prerequisite, which reaches the rootfs transitively.
#
# The lib-assemble-*.sh helpers are the assembler's sub-stages (issue #43) and MUST be listed:
# they are sourced, so make sees no dependency on them by itself, and a helper edited without
# being here would not invalidate this stamp -- the next build would silently reuse the previous
# rootfs.img and the change would appear to have been "verified" against bytes that predate it.
ASSEMBLE_SRC := $(shell find $(ROOTFS_DIR)/assemble-rootfs.sh $(ROOTFS_DIR)/lib-assemble-*.sh \
                              $(ROOTFS_DIR)/seal-rootfs.sh $(ROOTFS_DIR)/conf/seal.list \
                              $(ROOTFS_DIR)/guard-rootfs.sh rootfs/overlay -type f 2>/dev/null)

# Kernel inputs: any change re-triggers the (full, from-scratch) kernel build. The unified
# kernel globs every fragment/patch/dts, and bakes the firmware embed list.
# There is no cmdline file to list: the common boot args live in boot/gen-grub-cfg.sh and land on
# the `linux` line of the generated grub.cfg, so nothing in kernel/build.sh reads one.
# kernel/build.sh IS here (added 2026-07-26): it is the recipe itself — it decides the config
# merge, the firmware embed and the =m/=y assertions, so editing it changes the Image but make
# could not see that. Editing it alone used to be a silent no-op that only showed up as a stale
# kernel on the card. Same class of bug as the bootstrap-script dep fixed in c0d2cb6.
KERNEL_SRC := kernel/SOURCE.pin kernel/embed.list kernel/build.sh \
              $(wildcard kernel/*.config) \
              $(wildcard kernel/patches/*.patch) \
              $(wildcard kernel/dts/qcom/*)

# ...but the kernel keys off the CONTENT of that list, not its mtimes. git rewrites a file
# whenever its content differs between the old and new tree, stamping it with the time of the
# checkout — so `git checkout` + `pull --ff-only` across a branch that touches any kernel input
# rewrites it TWICE (out to the other version, back to this one) and leaves a fresh mtime on
# bytes that never changed. That cost a full ~25min from-scratch rebuild per merge, for nothing:
# measured 2026-07-30, when the PR #12 fast-forward re-stamped kernel/build.sh and
# kernel/kernel.config with content identical to the kernel already in out/.
#
# So $(KERNEL) depends on this digest file instead. Its recipe runs whenever an input's mtime
# moves (which is the only cheap signal that something MIGHT have changed), but it rewrites
# itself only when the digest actually differs — so its own mtime advances on real edits alone.
# Same shape as $(OVERLAY_STAMP) below, which keys off sha256sum $(OVERLAY_DB) rather than
# retroforge.db's mtime for exactly this reason. One file rather than that rule's stamp+.sha pair,
# because here the digest IS the marker; there the stamp doubles as a build marker.
#
# The file list is inside the digest, not just the file contents, so adding or deleting a patch
# counts as a change. Paths are repo-relative, so the digest does not follow the checkout dir.
KERNEL_SRC_HASH := work/.kernel-src.hash

# ccache (kernel/build.sh) is a dev-box speedup only, OFF on CI (GitHub sets CI=true). A CI cache
# only helps if it is carried across runs in actions/cache, where it would creep toward its
# max_size and push the overlay repo + pacman caches out of the 10 GB repo quota — and losing the
# overlay cache costs a full emulated rebuild, far more than ccache saves on the kernel.
# The container does not see the host's CI, so the decision is made here and passed in.
RETROFORGE_CCACHE ?= $(if $(CI),0,1)

.DEFAULT_GOAL := help

# ==============================================================================
# Phony orchestration targets
# ==============================================================================
.PHONY: help all image toolchain kernel fw-linux fw-qcom base overlay verify-lock check-hw-paths \
        rootfs relock installer installer-root relock-installer verify-image \
        initramfs splash plugin sigdefer gptk-interpose hidemenu mesa-x86 grub sdcard verify-card test test-disk bundle sign-bundle publish-bundle \
        clean clean-base clean-overlay clean-ccache distclean

# An always-out-of-date prerequisite, for rules that must re-evaluate their own inputs every run
# rather than trust a prerequisite's mtime. Only $(KERNEL_SRC_HASH) uses it; see the note there.
.PHONY: FORCE
FORCE:

help: ## Show this help
	@echo "retroforge build — unified image (all SoCs/boards)"
	@echo
	@grep -hE '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
	  | awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-12s\033[0m %s\n",$$1,$$2}'
	@echo
	@echo "Knobs: BASE_CONFIG RETROFORGE_VERSION ESP   dev build: set -a; . ./dev.env; set +a"

all: sdcard ## Alias for `sdcard` (the full bring-up image)

image: $(ROOTFS) ## Read-only Btrfs root only (out/images/rootfs.img)

toolchain: $(BUILD_STAMP) ## Build the retroforge-build cross-compile docker image
kernel:    $(KERNEL)       ## Build vmlinuz.efi + all dtbs + modules (in build container)
fw-linux:  $(FW_LINUX)     ## Fetch open linux-firmware blobs (host, network)
fw-qcom:   $(FW_QCOM)      ## Fetch device-proprietary firmware from the qcom-firmwares repo (host, network)
overlay:   $(OVERLAY_DB)   ## Rebuild from-source overlay pkgs (patched gamescope) -> work/repo/<arch>/
base:      $(BASE_STAMP)   ## Bootstrap the aarch64 root from packages (host; docker+qemu)
rootfs:    $(ROOTFS)       ## Assemble the read-only root + var images (in container)
initramfs: $(INITRAMFS)    ## Build the initramfs that mounts ro-root + /etc overlay (in container)
splash:    $(SPLASH_BIN) $(SPLASH_ASSET) ## Build the boot-splash drawer + flattened logo (in container)
plugin:    $(PLUGIN_ZIP) ## Build the RetroForge OpenGamepadUI plugin zip (host, python3)
sigdefer:  $(SIGDEFER_LIB) ## Build the Snes9x SIGTERM shim, libretroforge-sigdefer.so (in container)
hidemenu:  $(HIDEMENU_LIB) ## Build the melonDS second-window menu shim, libretroforge-hidemenu.so (in container)
mesa-x86:  $(MESA_X86_STAMP) ## Build our x86_64 + i686 Mesa for the FEX guest's overlay (x86_64 container)
gptk-interpose: $(GPTK_LIB) ## Build PortMaster gptokeyb2's pad interposer (in container)
grub:      $(GRUB)         ## Build the ESP GRUB + per-slot grub.cfg (in container)
sdcard:    $(SDCARD)       ## Build the flashable SD-card image (in container)

# Asserts the BUILT card the way guard-rootfs.sh asserts the built tree — the guard stops at the
# staged tree (it runs before mkfs), so nothing else checks the GPT, the ESP, or the per-slot
# filesystem identities an A/B switch depends on. Unprivileged: no loop mounts, no root.
verify-card: $(SDCARD) | $(BUILD_STAMP) ## Verify the built A/B card image (in container)
	$(INBUILD) $(IMAGE_DIR)/verify-card.sh

# The two offline suites over the A/B boot logic. Neither needs a build, a container, root or a
# device — they are pure shell over temp-dir state — so there is no reason not to run them, and
# until now there was no target that did. That absence is not academic: the RAUC backend had no
# offline coverage at all, and a broken one reached hardware and aborted a real install.
#
# HOST-SIDE ON PURPOSE, unlike everything else here. All three scripts execute the shipped artifacts
# (image/initramfs/init, rootfs/overlay/usr/bin/retroforge-bootctl and rootfs/overlay/usr/lib/rauc/
# post-install.sh) against a sandbox; putting them in the container would test the same files
# through an extra layer that can only add failure modes.
#
# The three cover the update path end to end, each from the side the others cannot see: the
# initramfs READS the slot state, retroforge-bootctl WRITES it, and the post-install hook DRIVES both
# while reformatting a partition. None of them needs root — the hook suite stubs the commands that
# would touch real storage.
# A second's worth of committed-file arithmetic, and the reason it is a PREREQUISITE of `test`
# rather than a step inside rootfs/fetchlock.sh: fetchlock makes the same comparison but needs a
# populated work/repo plus the ~382 snapshot packages it verifies alongside, so on a clean machine
# nothing runs it until the overlay pipeline's retrieval job — hours of aarch64 compiles after the
# wrong row was pushed. Hanging it off `test` is what puts it on every push and every PR: the ci
# workflow runs `make test`, and it triggers on paths overlay.yml deliberately ignores, so a commit
# touching ONLY rootfs/manifest.lock is still checked. It covers BOTH manifests — the installer
# carries gamescope too, and its lock is the one that gets forgotten.
verify-lock: ## Check both locks' retroforge rows against packages/ (host, seconds, no build)
	bash packages/verify-lock-rows.sh

# Every board profile's hardware-map pins (RETROFORGE_HW_*) against what its devicetree makes the
# kernel register (tools/check-hw-paths.py). Reads the DTBs `make kernel` staged in out/dtbs; with
# LINUX_SRC=<a Linux tree> it compiles kernel/dts/qcom against that tree instead, no build needed.
check-hw-paths: ## Check every board's hardware-map pins against its DTB (out/dtbs, or LINUX_SRC=<tree>)
	python3 tools/check-hw-paths.py $(if $(LINUX_SRC),--linux-src $(LINUX_SRC),--dtbs $(OUT)/dtbs)

test: verify-lock ## Run every offline suite (host, no build needed)
	bash $(TESTS_DIR)/test-bootctl.sh
	bash $(TESTS_DIR)/test-post-install.sh
	bash $(TESTS_DIR)/test-boot-disk.sh
	bash $(TESTS_DIR)/test-pairingd.sh
	bash $(TESTS_DIR)/test-power-led.sh
	bash $(TESTS_DIR)/test-suspend.sh
	bash $(TESTS_DIR)/test-gamescope-display.sh
	bash $(TESTS_DIR)/test-stage2-grub.sh
	bash $(TESTS_DIR)/test-device-env.sh
	bash $(TESTS_DIR)/test-partition-table.sh
	bash $(TESTS_DIR)/test-units.sh
	bash $(TESTS_DIR)/test-session.sh
	bash $(TESTS_DIR)/test-launch.sh
	bash $(TESTS_DIR)/test-sigdefer.sh
	bash $(TESTS_DIR)/test-hidemenu.sh
	bash $(TESTS_DIR)/test-catalog.sh
	bash $(TESTS_DIR)/test-plugin.sh
	bash $(TESTS_DIR)/test-plugin-install.sh
	bash $(TESTS_DIR)/test-ogui-patches.sh
	bash $(TESTS_DIR)/test-steam.sh
	bash $(TESTS_DIR)/test-steam-direct.sh
	bash $(TESTS_DIR)/test-steam-library.sh
	bash $(TESTS_DIR)/test-steam-install.sh
	bash $(TESTS_DIR)/test-steam-x86-guest.sh
	bash $(TESTS_DIR)/test-steam-compat-tools.sh
	bash $(TESTS_DIR)/test-steam-proton.sh
	bash $(TESTS_DIR)/test-steam-remoteplay.sh
	bash $(TESTS_DIR)/test-store.sh
	bash $(TESTS_DIR)/test-store-browser.sh
	bash $(TESTS_DIR)/test-emu.sh
	bash $(TESTS_DIR)/test-scrape.sh
	bash $(TESTS_DIR)/test-sysctl.sh
	bash $(TESTS_DIR)/test-oom.sh
	bash $(TESTS_DIR)/test-key-drift.sh
	bash $(TESTS_DIR)/test-portmaster.sh
	bash $(TESTS_DIR)/test-shares.sh
	bash $(TESTS_DIR)/test-coredump-limit.sh
	bash $(TESTS_DIR)/test-cpu-affinity.sh
	bash $(TESTS_DIR)/test-fan-curve.sh
	bash $(TESTS_DIR)/test-hw-map.sh
	bash $(TESTS_DIR)/test-hw-dtb.sh
	bash $(TESTS_DIR)/test-cpu-scheduler.sh
	bash $(TESTS_DIR)/test-panel-calibration.sh
	bash $(TESTS_DIR)/test-splash.sh
	bash $(TESTS_DIR)/test-splash-status.sh
	bash $(TESTS_DIR)/test-update.sh
	bash $(TESTS_DIR)/test-publish-bundle.sh
	bash $(TESTS_DIR)/test-storage.sh
	bash $(TESTS_DIR)/test-install.sh
	bash $(TESTS_DIR)/test-ui.sh
	bash $(TESTS_DIR)/test-mkroot.sh
	bash $(TESTS_DIR)/test-lib-pins.sh
	bash $(TESTS_DIR)/test-lib-container.sh
	bash $(TESTS_DIR)/test-verify-lock.sh
	bash $(TESTS_DIR)/test-mkimage.sh
	bash $(TESTS_DIR)/test-mesa-source.sh
	bash $(TESTS_DIR)/test-fex-guest.sh
	bash $(TESTS_DIR)/test-guard.sh
	bash $(TESTS_DIR)/test-upstream-name.sh

# The fourth suite, separate because it is the one that CANNOT run on the host: it signs real
# bundles and verifies them through the shipped system.conf, so it needs rauc. Every case in it is
# a negative — it feeds ota/rauc/verify-signing.sh a deliberately broken config or cert profile
# and requires it to go red — because the failure mode of a check is not "it breaks", it is "it
# stays green while asserting nothing".
#
# It depends on $(SIGN_STAMP), NOT $(BUILD_STAMP): the suite needs rauc, openssl and mksquashfs,
# and building the aarch64 cross-toolchain + GRUB's autotools to get them is what made this the
# slowest thing in `ci`. Both images come from the same build/Dockerfile, so the rauc pin they
# share cannot drift. Anyone who already has the full image loses nothing — the signing stage is
# its own first layer, so docker reuses it rather than fetching anything twice.
test-signing: $(SIGN_STAMP) ## Prove the RAUC signing self-test still catches what it claims (container; PKIDIR= adds the keyring check)
	$(DOCKER) $(PKI_MOUNT) $(SIGN_IMG) $(TESTS_DIR)/test-verify-signing.sh

# The fifth suite pair, and the reason they are not in `test`: they need sgdisk, mtools and
# dosfstools, which a plain dev box does not have (and which the shipped image never gets, because
# select-target.sh and carve.sh are installer-only and are never staged into the rootfs). So they
# run in the container, where those tools already live for verify-image.
#
# They had no target and no CI job until 2026-08-25 — 181 assertions over the two scripts that
# CHOOSE a stranger's disk and then DELETE partitions on it, run only when someone remembered to
# type the path. That is the same failure this repo has already paid for twice: a check nothing
# invokes is a check that is not asserting anything. Nothing here needs root and nothing is
# mounted; the fixtures are sparse images rebuilt from the real GPTs in docs/internal-storage.md.
test-disk: | $(BUILD_STAMP) ## Run the select-target + carve suites, which need sgdisk/mtools (container)
	$(INBUILD) $(TESTS_DIR)/test-select-target.sh
	$(INBUILD) $(TESTS_DIR)/test-carve.sh

# ==============================================================================
# Toolchain images
# ==============================================================================
# No --target: `full` is the last stage in build/Dockerfile, so a plain build selects it.
$(BUILD_STAMP): build/Dockerfile
	$(RETROFORGE_CONTAINER) build -t $(BUILD_IMG) -f build/Dockerfile build
	@mkdir -p $(@D) && touch $@

# The signing stage alone. Both stamps key off the same Dockerfile, so editing it rebuilds
# whichever images you actually use rather than coupling them.
$(SIGN_STAMP): build/Dockerfile
	$(RETROFORGE_CONTAINER) build --target signing -t $(SIGN_IMG) -f build/Dockerfile build
	@mkdir -p $(@D) && touch $@

# ==============================================================================
# Firmware (host)
# ==============================================================================
# Open blobs (Adreno GPU, WCN7850 Wi-Fi/BT, Iris VPU) — pinned + verified, host network.
$(FW_LINUX): firmware/LINUX_FW.pin
	firmware/fetch-linux-fw.sh
	@touch $@

# Device-proprietary blobs (zap shaders, DSP/modem, tplg, ath12k, Renesas) — fetched from the
# pinned retroforge-linux/qcom-firmwares repo + verified against its sha256sums.txt. The repo's sha
# sidecar lands as the target; @touch bumps recency past the pin (cp -a preserves old mtimes).
$(FW_QCOM): firmware/QCOM_FW.pin
	firmware/fetch-qcom-fw.sh
	@touch $@

# ==============================================================================
# From-source overlay packages (host — build-overlay.sh drives docker + qemu binfmt)
# ==============================================================================
# Rebuild changed holo packages with retroforge patches into the local pacman repo work/repo/<arch>/.
# Union prereq re-invokes the script on any input change; the script self-selects which package(s)
# to rebuild (per-package input hash). Only when a source.pin exists does `base` depend on it.
#
# THE CACHE IS LOCAL AND IT IS THE STAMPS. build-overlay.sh keys each package on
# packages/inputhash.sh over its committed inputs and records it as
# work/repo/<arch>/.stamps/<name>.hash, so a package whose sources have not moved is not rebuilt —
# a one-line gamescope patch costs a gamescope build and nothing else. That is the whole caching
# story now, on a dev box and in CI alike, and it means this goal touches NO network beyond what
# makepkg fetches for a package it has actually decided to build.
#
# There used to be a `packages/overlay-store.sh pull-all` here that retrieved CI-built artifacts
# from GHCR before compiling. It was retired 2026-08-04: the store existed because an overlay build
# costs ~4h emulated on a dev box, but on the native aarch64 runners CI uses it costs ~34 minutes
# for the whole set, which is not worth a registry, a pin format and a bot with write access to
# main. See .github/workflows/overlay.yml for the per-package measurements.
$(OVERLAY_DB): build/builder.pin build/snapshot.pin $(OVERLAY_PINS) $(OVERLAY_PATCHES) $(OVERLAY_PKGBUILDS)
	packages/build-overlay.sh

# Advance .overlay.stamp only when the overlay repo's CONTENT actually changed, and do it in THIS
# target's own recipe so make observes the new mtime within the same invocation (base depends on
# this stamp). Keying on the db's sha (not its mtime) is what lets build-overlay.sh keep bumping
# retroforge.db's mtime on a no-op run WITHOUT cascading into a base rebuild: the sha is unchanged, so
# the stamp is left alone. A REAL re-index changes the sha, we touch the stamp, and base rebuilds
# right away — the previous ORDER-ONLY `| $(OVERLAY_DB)` form could not, because the stamp was
# advanced as a side effect of the DB rule and make never re-stat'd it mid-run (a stale-mtime miss
# that silently shipped a base built against the OLD overlay). $@.sha persists the last-seen hash.
$(OVERLAY_STAMP): $(OVERLAY_DB)
	@newsha=$$(sha256sum $(OVERLAY_DB) | cut -d' ' -f1); \
	 [ "$$(cat $@.sha 2>/dev/null)" = "$$newsha" ] || { printf '%s\n' "$$newsha" > $@.sha; touch $@; }
	@[ -e $@ ] || touch $@   # first-ever run: ensure the stamp exists even if the sha file seeded it

# ==============================================================================
# Root bootstrap (host — customize-base.sh drives docker + qemu binfmt itself)
# ==============================================================================
# Every prerequisite here is an input to the tree work/base ends up containing. Without one
# listed, the stamp short-circuits `make base` and editing that input is silently a no-op --
# the script's own reuse check never gets to run, because make never invokes the script.
#
# build/builder.pin pins the arm64 image the bootstrap EXECUTES in (Phase 4c; it contributes
# no files to the root, but it is the pacman that lays them down). build/snapshot.pin selects the
# package-repo revision every row is installed from. build/lib-pins.sh validates both.
#
# rootfs/manifest.lock is the strongest input: under the default LOCKED mode customize-base.sh
# installs exactly the package FILES it declares (Phase 4a step 2), so editing the lock changes
# the tree. rootfs/fetchlock.sh is listed for the same reason build scripts generally are -- it
# is what turns the lock into that install. rootfs/conf/pacman.conf and rootfs/conf/os-release are the
# two committed declarations the bootstrap stages into the container: the repo set the root is
# resolved from, and the root's own identity.
# rootfs/customize-base.sh is listed LAST but matters most: it is the script that turns all of
# the above into a tree, so editing it changes the tree. Its absence here meant a fix to the
# bootstrap was silently a no-op -- make saw the stamp as satisfied and never invoked it. (Cost a
# build cycle on 2026-07-26: a `make sdcard` after a script fix rebuilt nothing.) The script also
# folds its own sha256 into its reuse marker, because the make prereq alone only gets the script
# RUN -- the marker check inside it would otherwise still short-circuit.
#
# $(BASE_MODE_STAMP) is the RETROFORGE_DEV prerequisite (see its definition): it is the only one of
# these that changes when nothing on disk does.
#
# The mode assertion in the recipe is the other half of that. A marker file saying which mode the
# tree was built in is a claim, and an unchecked claim is how the stale-base bug shipped in the first
# place. customize-base.sh records `dev:1` in its own reuse key for a dev bootstrap, so the built
# tree states its own mode: assert that against the mode we asked for. This guards BOTH directions,
# which nothing downstream does -- guard-rootfs.sh only ever runs on a release build.
$(BASE_STAMP): build/builder.pin build/snapshot.pin build/lib-pins.sh $(ROOTFS_DIR)/manifest.lock $(ROOTFS_DIR)/fetchlock.sh \
               $(ROOTFS_DIR)/conf/pacman.conf $(ROOTFS_DIR)/conf/os-release $(ROOTFS_DIR)/customize-base.sh $(PREBUILT_PINS) \
               $(BASE_MODE_STAMP)
	$(ROOTFS_DIR)/customize-base.sh
	@test -f work/base/usr/bin/sshd   # sentinel: sshd present => release runtime laid down
	@: "sentinel: the pairing agent's interpreter and key validator. Both arrive as transitive"; \
	 : "dependencies of other packages, so a dependency change elsewhere could remove them and"; \
	 : "the only symptom would be that remote access silently stops working on a shipped image."; \
	 for f in usr/bin/python3 usr/bin/ssh-keygen; do \
	   test -e "work/base/$$f" || { \
	     echo "retroforge-pairingd needs /$$f and the base tree has no such file" >&2; exit 1; }; \
	 done
	@: "sentinel: the tree must be in the mode this build asked for (see above)"; \
	 got=release; grep -qx 'dev:1' work/base/usr/lib/retroforge/pkgs 2>/dev/null && got=dev; \
	 [ "$$got" = "$(BASE_MODE)" ] || { \
	   echo "base tree is a $$got build, this is a $(BASE_MODE) build (stale work/base)" >&2; \
	   exit 1; }
	@mkdir -p $(@D) && touch $@   # recency marker outside the root-owned tree (frozen mtimes)

# Switching RETROFORGE_DEV swaps which marker exists, so the base is rebuilt on the next make. The
# rm is what keeps it a marker rather than a cache: exactly one mode is ever claimed, and it is
# always the mode work/base was last built in.
$(BASE_MODE_STAMP):
	@mkdir -p $(@D) && rm -f work/.base-mode-* && touch $@
	@echo "[retroforge] base mode: $(ROOTFS_MODE)"

# A built overlay repo is an extra base input: customize-base installs the patched packages
# from it and folds its content hash into the reuse-cache key. Wire it as a prerequisite only
# when source.pin packages exist, so a repo with no overlay still builds normally.
ifneq ($(OVERLAY_PINS),)
$(BASE_STAMP): $(OVERLAY_STAMP)
endif

# ==============================================================================
# Kernel (container) — needs both firmware sets baked in (CONFIG_EXTRA_FIRMWARE)
# ==============================================================================
# Advance the kernel-source digest only when the sources' CONTENT changed — see KERNEL_SRC_HASH
# up top for why an mtime dependency is not good enough here. Written in this target's own recipe
# so make observes the new mtime within the same invocation, the same requirement $(OVERLAY_STAMP)
# documents. A missing $(KERNEL) still rebuilds regardless of this file, so a `make clean` (which
# leaves work/ alone) cannot be tricked into skipping the build by a digest that survived it.
# FORCE, not $(KERNEL_SRC): the recipe has to run on EVERY invocation, because the case it must
# catch has no newer prerequisite to trigger it. DELETING a patch changes what the kernel is built
# from, but leaves every surviving input older than the digest, so an mtime-driven rule would skip
# and keep serving the pre-deletion hash. (The old direct dependency had the same blind spot for
# the same reason; it is fixed here rather than carried over.) Recomputing is a sha256sum over
# ~60 files, single-digit ms — cheap enough to pay unconditionally.
$(KERNEL_SRC_HASH): FORCE
	@mkdir -p $(@D)
	@new=$$(sha256sum $(KERNEL_SRC) | sha256sum | cut -d' ' -f1); \
	 [ "$$(cat $@ 2>/dev/null)" = "$$new" ] || printf '%s\n' "$$new" > $@

$(KERNEL): $(KERNEL_SRC_HASH) $(FW_LINUX) $(FW_QCOM) | $(BUILD_STAMP)
	$(DOCKER) $(if $(BASE_CONFIG),-e BASE_CONFIG=/src/$(BASE_CONFIG)) -e RETROFORGE_CCACHE=$(RETROFORGE_CCACHE) \
	  $(BUILD_IMG) kernel/build.sh

# Regenerate rootfs/manifest.lock (Phase 4a). Deliberately NOT a dependency of the image build:
# the lock is a reviewed artifact, so it is regenerated on purpose and its diff is read, never
# refreshed as a silent build side effect.
#
# It must NOT go through $(BASE_STAMP), which builds in LOCKED mode -- relocking a tree that was
# itself installed from the lock can only ever reproduce that lock. Re-resolving is the whole
# point, so this drives customize-base.sh directly in RETROFORGE_RESOLVE=1 mode: pacman -Sy resolves
# PKGS against the pinned snapshot, and genmanifest.sh then records what that produced.
#
# The resulting tree is a RESOLVE tree and must never ship, so the stamp is REMOVED rather than
# touched. The next build re-runs customize-base.sh, which sees mode:resolve in the reuse marker,
# rebuilds in locked mode, and so ships a tree actually verified against the new lock.
# Release-only by construction: genmanifest.sh refuses a dev base.
#
# RETROFORGE_DEV is cleared here rather than passed through: with it set, the base would be built
# with the dev tooling and genmanifest.sh would then refuse it -- correct, but only after a full
# emulated install. The lock is a release artifact, so force release up front.
#
# The overlay repo IS a prerequisite even though the base stamp is not. Dropping $(BASE_STAMP)
# dropped its transitive overlay dependency with it, and without a built work/repo/aarch64 the
# resolve would satisfy mesa/gamescope/rauc from the snapshot instead of from our patched builds
# — locking upstream binaries under a `snapshot` class. That is a silently WRONG lock, which is
# worse than a failed one, so declare the overlay directly.
relock: $(if $(OVERLAY_PINS),$(OVERLAY_STAMP)) ## Re-resolve from PKGS and regenerate rootfs/manifest.lock (host; release only)
	RETROFORGE_DEV= RETROFORGE_RESOLVE=1 FORCE=1 $(ROOTFS_DIR)/customize-base.sh
	$(ROOTFS_DIR)/genmanifest.sh
	$(ROOTFS_DIR)/chromium-pin.py   # the store sign-in's Chromium follows the lock (packages the image lacks)
	rm -f $(BASE_STAMP) work/.base-mode-*   # the tree left behind is a RESOLVE tree: claim no mode for it
	@echo "review the diff, commit it, then rebuild: git diff $(ROOTFS_DIR)/manifest.lock $(ROOTFS_DIR)/overlay/usr/share/retroforge/stores/chromium.pin"

# ==============================================================================
# Installer image (host docker + qemu) — the standalone medium that installs to internal storage
# ==============================================================================
# Phase 6 of .claude/plans/internal-install.plan.md. A SEPARATE root from the shipped one, with its
# own package declaration (installer/pkgs.list) and its own lock (installer/manifest.lock): the
# installer carries partition and filesystem tools that no device ever gets, so folding them into
# rootfs/manifest.lock would make the shipped image's reviewed artifact describe content that image
# never contains. installer/genlock.sh's header carries the full reasoning.
#
# installer/mkroot.sh self-caches on its own input key (packages, pins, snapshot, builder, and a hash
# over every file it places), so an unchanged tree costs the key check and nothing else. That is why
# these are phony rather than file targets — the script owns the reuse decision, exactly as
# rootfs/customize-base.sh does for the shipped base.
# $(KERNEL) IS A REAL PREREQUISITE, not decoration: mkroot.sh ships the kernel's MODULES into the
# installer root (the 802.11 stack is =m, so firmware with no driver is indistinguishable from no
# firmware) and reads them out of out/modroot, which the kernel build produces. Without this line
# `make installer` builds the root FIRST and dies on a tree that has never built a kernel — which is
# every CI runner, and was the first thing the 2026-08-25 smoke run hit.
#
# `verify-lock` IS FIRST ON PURPOSE. mkroot.sh's resolve refuses a retroforge package built from
# sources installer/manifest.lock does not describe — correct, and the only thing standing between a
# stale row and a published medium — but it makes that call from inside the root bootstrap, i.e.
# after $(KERNEL). installer/v0.0.8 spent 56 minutes building 7.2.5 to reach it. verify-lock decides
# the same question in a second from committed files, so ordering it ahead of the kernel turns that
# into a fast failure. Prerequisites are built left to right, which holds for `make installer`; a
# `make -j installer` would race the kernel against it and lose the head start, not the check.
installer-root: verify-lock $(KERNEL) $(if $(OVERLAY_PINS),$(OVERLAY_STAMP)) ## Bootstrap the installer root -> work/installer-base (host; docker+qemu)
	installer/mkroot.sh >/dev/null

# The medium itself. Host-side mkroot.sh produces the tree; this compresses it and lays the two
# partitions, and it runs IN THE CONTAINER because the tree is root-owned — a squashfs built by the
# build user would put every file on the medium under uid 1000, and the installer runs as root
# against a stranger's disk. $(KERNEL) and $(GRUB) are real prerequisites: the kernel, the dtbs and
# the stage-2 GRUB all land on the medium's ESP, since there is no slot root for them to live in.
#
# $(ID_ENV) because installer/mkimage.sh stamps the medium's identity (see its section 0): without it
# every installer image ever built calls itself the same thing, which is the first question asked at
# the fallback console. NOT $(DEV_ENV): the dev/release mode is read back out of the ROOT's own
# reuse marker, so it cannot disagree with what was actually baked in.
installer: installer-root $(KERNEL) $(GRUB) | $(BUILD_STAMP) ## Build the flashable installer medium -> out/images/installer.img
	$(DOCKER) $(ID_ENV) $(BUILD_IMG) installer/mkimage.sh

# Asserts the BUILT medium, the way verify-card.sh asserts the built card. The suites in `make test`
# read the SCRIPTS — a script that says the right thing while producing the wrong image passes every
# one of them — and this is the only thing that opens the image. No dependency on `installer`:
# verifying a downloaded or CI-built medium is a normal thing to do, and rebuilding it here from a
# possibly-newer tree would verify something other than the file in front of you.
#
# RETROFORGE_INSTALLER_ALLOW_DEV=1 to accept a dev medium (sshd + a baked Wi-Fi PSK); without it that
# is a failure, because a dev medium must never be the one that gets published.
verify-image: | $(BUILD_STAMP) ## Verify a built installer medium (in container; IMG= to point elsewhere)
	$(DOCKER) -e RETROFORGE_INSTALLER_ALLOW_DEV $(BUILD_IMG) installer/verify-image.sh $(IMG)

# Mirrors `relock` above, including why it must NOT go through the locked path: relocking a tree
# that was itself installed from the lock can only ever reproduce that lock. FORCE=1 because the
# reuse key folds the mode in, so an existing locked tree would otherwise satisfy this.
#
# The overlay repo IS a prerequisite: installer/pkgs.list names gamescope, which exists in no holo
# repo, and without work/repo/aarch64 the resolve would either fail or — worse — satisfy it from a
# snapshot and lock an unpatched upstream binary under a `snapshot` class.
relock-installer: $(if $(OVERLAY_PINS),$(OVERLAY_STAMP)) ## Re-resolve installer/pkgs.list and regenerate installer/manifest.lock (host)
	RETROFORGE_DEV= RETROFORGE_RESOLVE=1 FORCE=1 installer/mkroot.sh >/dev/null
	installer/genlock.sh
	@echo "review the diff, commit it, then rebuild: git diff installer/manifest.lock"

# ==============================================================================
# Read-only root (container) — base userspace + kernel + firmware -> Btrfs image
# ==============================================================================
# Switching RETROFORGE_DEV swaps which stamp exists, so the rootfs is rebuilt on the next make.
$(MODE_STAMP):
	@mkdir -p $(@D) && rm -f work/.rootfs-mode-* && touch $@
	@echo "[retroforge] rootfs mode: $(ROOTFS_MODE)"

# Same shape for the scraper login (see SCRAPER_STAMP).
$(SCRAPER_STAMP):
	@mkdir -p $(@D) && rm -f work/.rootfs-scraper-* && touch $@
	@echo "[retroforge] ScreenScraper login: $(if $(findstring -on,$@),in the image,NONE (no ROM art scraping))"

# Same shape, same reason, for RETROFORGE_VERSION (see its definition): one marker at a time, and
# changing the version re-creates it newer than the rootfs, which re-assembles.
$(VERSION_STAMP):
	@mkdir -p $(@D) && rm -f work/.rootfs-version-* && touch $@
	@echo "[retroforge] rootfs version: $(if $(RETROFORGE_VERSION),$(RETROFORGE_VERSION),dev)"

# $(INITRAMFS) and $(GRUB) are prerequisites because the root CARRIES its own boot
# half: /boot/{Image,initramfs-retroforge.img,dtbs} that the slot's stage 2 boots, plus the
# /usr/lib/retroforge/boot mirror the RAUC hook refreshes the ESP and the slot's efi partition FROM.
# That is what makes "this root and the software that boots it came from one build" true by
# construction. No cycle: the initramfs is built from work/base, never from the assembled root.
$(ROOTFS): $(KERNEL) $(INITRAMFS) $(GRUB) boot/esp-dtbs.sh $(BASE_STAMP) $(FW_LINUX) $(FW_QCOM) $(PLUGIN_ZIP) $(SIGDEFER_LIB) $(GPTK_LIB) $(HIDEMENU_LIB) $(MESA_X86_DEP) $(ASSEMBLE_SRC) $(MODE_STAMP) $(VERSION_STAMP) $(SCRAPER_STAMP) | $(BUILD_STAMP)
	$(DOCKER) $(DEV_ENV) $(SCRAPER_ENV) $(ID_ENV) -e RETROFORGE_DEBUG -e RETROFORGE_X86_MESA $(BUILD_IMG) \
	  $(ROOTFS_DIR)/assemble-rootfs.sh /src/work/base

# ==============================================================================
# Boot stage + bootable media (container)
# ==============================================================================
# The initramfs mounts the slot's root + var + efi partition, stacks the /etc overlay, and
# switch_roots. It is staged out of the base rootfs (bash + util-linux), so the base is a prereq.
$(INITRAMFS): $(IMAGE_DIR)/mkinitramfs.sh $(IMAGE_DIR)/initramfs/init $(SPLASH_BIN) $(SPLASH_ASSET) $(BASE_STAMP) | $(BUILD_STAMP)
	$(INBUILD) $(IMAGE_DIR)/mkinitramfs.sh /src/work/base

# The boot splash: a static aarch64 drawer plus the flattened logo. Both are initramfs payload,
# which is why they are prerequisites of it rather than of the rootfs alone — a theme or binary
# change that did not rebuild the cpio would leave the OLD splash on the card with no sign of it.
$(PLUGIN_ZIP): $(PLUGIN_SRC)
	apps/ogui-retroforge-plugin/build.sh $(OUT)/plugins

$(SPLASH_BIN): $(SPLASH_SRC) | $(BUILD_STAMP)
	$(INBUILD) -c 'make -C apps/retroforge-splash'

$(SIGDEFER_LIB): $(SIGDEFER_SRC) | $(BUILD_STAMP)
	$(INBUILD) -c 'make -C apps/retroforge-sigdefer'

$(GPTK_LIB): $(GPTK_SRC) | $(BUILD_STAMP)
	$(INBUILD) -c 'make -C apps/retroforge-gptk-interpose'

$(HIDEMENU_LIB): $(HIDEMENU_SRC) | $(BUILD_STAMP)
	$(INBUILD) -c 'make -C apps/retroforge-hidemenu'

# On the host (build.sh runs its own x86_64 container); a no-op when its inputs are unchanged.
$(MESA_X86_STAMP): $(MESA_X86_SRC)
	bash packages/mesa-x86/build.sh

$(SPLASH_ASSET): $(IMAGE_DIR)/mksplash.sh $(IMAGE_DIR)/png2nds1.py $(IMAGE_DIR)/splash/logo.svg $(IMAGE_DIR)/splash/logo.png $(SPLASH_GEOM) | $(BUILD_STAMP)
	$(INBUILD) $(IMAGE_DIR)/mksplash.sh

# The ESP GRUB + the two per-slot grub.cfg files + grubenv. The patch set and the board catalog are
# prerequisites because both change the artifact: a new patch changes grubaa64.efi, and a new
# board row changes the configs generated beside it. image/partition-table.txt is in there for
# the same reason -- the configs address partitions by index out of that file.
#
# THE CO-PRODUCTS ARE NOT SEPARATE TARGETS, and the cost is worth
# knowing: make only stats grubaa64.efi, so deleting a co-product on its own does NOT retrigger this
# rule. It fails at the consumer instead -- rootfs/assemble-rootfs.sh and image/make-sdcard.sh both
# check each file by name and name this script in the error. Loud, and one recipe run rather than
# four. Giving grubenv its own rule would mean either running boot/grub.sh twice or minting the
# block outside it, which is the second writer that shipping it as an artifact exists to remove.
$(GRUB): boot/grub.sh boot/gen-grub-cfg.sh boot/gen-esp-cfg.sh boot/grub.pin boot/boards.map \
         $(IMAGE_DIR)/partition-table.txt $(wildcard boot/patches/grub/*.patch) | $(BUILD_STAMP)
	$(INBUILD) boot/grub.sh

# var.img and var-b.img are co-products of the same assembler run as rootfs.img.
$(VARIMG): $(ROOTFS)
$(VARIMG_B): $(ROOTFS)

# RETROFORGE_DEV and RETROFORGE_SLOT_B have to be FORWARDED, not just set: this rule ran through plain
# $(INBUILD), so neither reached the container and `RETROFORGE_SLOT_B=0 make sdcard` silently did
# nothing at all. It matters more now that the mode picks the default -- make-sdcard.sh populates
# slot B for a dev card and leaves it empty for a release card, and an unforwarded RETROFORGE_DEV
# would build every card release-shaped. No mode stamp is needed on top: $(ROOTFS) already depends
# on $(MODE_STAMP), so flipping the mode rebuilds the rootfs and this rule with it.
$(SDCARD): $(ROOTFS) $(VARIMG) $(VARIMG_B) $(GRUB) boot/esp-dtbs.sh $(IMAGE_DIR)/make-sdcard.sh | $(BUILD_STAMP)
	$(DOCKER) -e RETROFORGE_DEV -e RETROFORGE_SLOT_B $(BUILD_IMG) $(IMAGE_DIR)/make-sdcard.sh

# Signed RAUC OTA bundle (Phase 4). Without PKIDIR it mints an ephemeral cert that NO device accepts
# (devices trust only the CA, dev images too). For an installable bundle use
# PKIDIR=~/retroforge-pki (mounts the PKI at /pki and points RAUC_CERT/RAUC_KEY at it), or set
# RAUC_CERT/RAUC_KEY yourself to paths the CONTAINER can see -- repo-relative ones resolve under
# /src, anything else needs PKIDIR or a mount of your own.
#
# No version argument: genbundle.sh reads the identity out of the image it is wrapping
# (out/images/rootfs.release, written by the same assembler run that produced rootfs.img). Set
# RETROFORGE_VERSION before the rootfs is built, not here.
bundle: $(ROOTFS) | $(BUILD_STAMP) ## Build a signed RAUC update bundle (in container; PKIDIR= to sign for real)
	$(GENBUNDLE)

# The same wrap, minus the $(ROOTFS) PREREQUISITE, for signing an image this tree did not build.
#
# WHY IT EXISTS. CI splits the release into build -> sign -> publish so a 30-minute build does not
# sit behind a human approving the signing environment (see .github/workflows/release-bundle.yml).
# The sign job restores out/images/rootfs.img from a workflow artifact and holds nothing else the
# build produced -- no kernel, no base, no overlay. `make bundle` there would see rootfs.img present
# but every one of ITS prerequisites missing, and cheerfully rebuild the entire image before signing
# it: a second full build, and one whose bytes nobody reviewed.
#
# So this target asserts the payload rather than deriving it. That is the whole difference, and it is
# why the assertion is a hard error and not a `make rootfs`: if the image is not here, the artifact
# did not arrive, and the answer is to find out why -- never to build a replacement locally and sign
# THAT under the release key.
#
# Use `bundle` everywhere else. On a dev box the prerequisite is the feature: it keeps the bundle
# honest about the tree it came from.
sign-bundle: | $(BUILD_STAMP) ## Sign a RAUC bundle around an EXISTING out/images/rootfs.img (in container; PKIDIR=)
	@test -f $(ROOTFS) || { \
	  echo "no rootfs image: $(ROOTFS)" >&2; \
	  echo "(sign-bundle signs an image built elsewhere -- restore it first; use 'make bundle' to build one)" >&2; \
	  exit 2; }
	$(GENBUNDLE)

# ==============================================================================
# Publish an update (host) — put a signed bundle in the OTA bucket (Cloudflare R2)
# ==============================================================================
# Runs on the HOST, not in the container: the transport is the pinned rclone and the credentials are
# the operator's (R2_* in the environment, see ota/lib-rclone.sh). The script reaches back INTO the container by itself for the one thing that needs the
# pinned rauc — verifying the bundle against the keyring every device carries, which it does before
# it moves a byte and without an override. Bucket contract: docs/ota.md.
#
# No dependency on `bundle`: publishing a CI artifact or a bundle built on another machine is a
# normal thing to do, and re-deriving it here from a possibly-newer tree would publish bytes nobody
# tested. Pass the file you actually installed on a device.
publish-bundle: ## Publish BUNDLE=<file.raucb> to the OTA bucket (host; needs the R2_* variables)
	@test -n "$(BUNDLE)" || { echo "pass BUNDLE=out/images/retroforge-<version>.raucb" >&2; exit 2; }
	$(OTA_DIR)/publish-bundle.sh "$(BUNDLE)" $(CHANNEL)


# ==============================================================================
# Cleaning
# ==============================================================================
# out/ is partly root-owned: the container stages (kernel modules_install, rootfs assembly,
# sdcard) run as root in the build image, so a host-side rm fails on e.g. out/modroot. Remove
# the artifacts from inside a throwaway container as root, like clean-base. (out/.build-image.stamp
# is host-owned and deliberately kept so the toolchain image isn't rebuilt.)
clean: ## Remove built artifacts (out/), keep firmware/base caches + toolchain stamp
	$(CTR_RUN) --rm -v $(CURDIR)/out:/wo $(BUSYBOX) rm -rf /wo/vmlinuz.efi /wo/Image /wo/Image.gz /wo/dtbs /wo/modroot /wo/images /wo/boot /wo/initramfs.cpio.zst /wo/initramfs.cpio.gz

# work/base is root-owned (the bootstrap's pacman writes it as root inside a container), so a
# plain rm fails for the build user — remove it from inside a throwaway container as root.
clean-base: ## Remove the (root-owned) bootstrapped root tree
	$(CTR_RUN) --rm -v $(CURDIR)/work:/wb $(BUSYBOX) rm -rf /wb/base
	rm -f $(BASE_STAMP) work/.base-mode-*   # drop the recency + mode markers too, else the next build skips a gone base

clean-overlay: ## Remove the built (arch-scoped) overlay pacman repo + build tree
	rm -rf work/repo work/overlay-build

# work/ccache holds the compiler caches (kernel/build.sh, packages/build-overlay.sh). The kernel
# one is root-owned (its build runs as root in the build image), so like clean-base this removes
# it from inside a throwaway container. Only ever costs speed: the next build is a cold one.
clean-ccache: ## Remove the kernel + overlay compiler caches (work/ccache)
	$(CTR_RUN) --rm -v $(CURDIR)/work:/wb $(BUSYBOX) rm -rf /wb/ccache

# THE CACHES THIS DELIBERATELY DOES *NOT* REMOVE, all of which surprise people:
#
#   work/prebuilt      the pinned-download cache (customize-base.sh documents it as persistent).
#   work/pacman-cache  the package cache.
#   work/repo          the built overlay packages (NOT clean-overlay — this target no longer runs it).
#   work/ccache        the kernel + overlay compiler caches (`make clean-ccache`).
#
# Together they are, i.e. essentially everything left under work/ after this target runs,
# which is why "distclean left stuff behind" is a reasonable first reading. It is a CHOICE: every
# byte in them is content-addressed against a pin or a package version, so a stale entry cannot
# be served — a mismatched sha is re-fetched.
# Nothing in the build reads them as INPUT to a decision; they only ever save a download. To drop
# them anyway (moving machines, reclaiming disk, or proving a pin still resolves upstream):
#
#   rm -rf work/prebuilt work/pacman-cache && make clean-overlay
#
# work/repo is the newest member and the one with real history. It used to go via clean-overlay,
# and because rootfs/manifest.lock then pinned the overlay's ARTIFACT bytes — which our
# non-reproducible builds move on every rebuild from identical inputs — `make distclean && make
# sdcard` could not succeed on its own: it stopped at work/.base.stamp on a hash mismatch and
# needed a full `make relock` to get going again. The lock now pins those rows to their SOURCES
# (packages/inputhash.sh, read by rootfs/fetchlock.sh), so a rebuild is no longer a lock change
# and that hard stop is gone. Keeping the repo is now purely about not re-paying for it: rebuilding
# all the packages under qemu is the single most expensive thing in this build. `make clean-overlay` is still there when you actually want them rebuilt.
distclean: clean clean-base ## clean + drop fetched firmware + kernel tree (KEEPS the download + overlay caches)
	# work/kernel is root-owned (the kernel build's modules_install runs as root in the build
	# image), so remove it from inside a throwaway container like clean/clean-base — a host-side
	# rm fails with permission errors. firmware/* are fetched on the host, so a plain rm is fine.
	$(CTR_RUN) --rm -v $(CURDIR)/work:/wb $(BUSYBOX) rm -rf /wb/kernel
	rm -rf firmware/linux-fw firmware/qcom-fw
