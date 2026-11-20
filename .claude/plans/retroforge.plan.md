# Plan: RetroForge

**Complexity**: Large
**Status** (2026-10-05): Phases 0-3 done -- HW-validated on all three SoCs: SM8550 (AYANEO Pocket
ACE), SM8250 (MANGMI Pocket Max), SM8650 (KONKR Pocket FIT, dev image 2026-10-04). Phase 4 (RetroForge
OGUI plugin) mostly built: catalog + retroforge-emu, Settings > Emulators store, per-system ROM tabs,
fast cores per emulator / per game, automatic ROM rescan; open items at the end
of its section.
Phase 4b (more emulators) and 4c (library scaling) after it. Phase 5 not started. Phase 6 (final
polish: Resume, memory-card check) last, not blocking.

## Summary

RetroForge is a standalone retro-emulation Linux distribution for Qualcomm Snapdragon handhelds
(SM8250 / SM8550 / SM8650). It is derived from the upstream project credited in README.md (GPL-2.0-or-later): it reuses
that project's Holo aarch64 base, unified kernel/DTS, steamcl + GRUB boot chain, RAUC A/B updates
and installer, without shipping the Steam client (installed into /home on demand from Main menu > Emulators >
Steam Client), x86 emulation or the Android container. The shell is
[OpenGamepadUI](https://github.com/ShadowBlip/OpenGamepadUI) inside gamescope. Emulators are upstream
AppImages that the RetroForge OGUI plugin downloads from their own releases (not in the image), started
per ROM by `retroforge-launch`.

## Decisions

| Decision | Choice |
|---|---|
| Relationship to upstream | Own project, not a fork. No upstream remote. Attribution kept (README, DTS copyrights, patch authors) |
| Base | Holo aarch64 packages, pinned snapshot, sealed read-only Btrfs root |
| Targets | SM8250, SM8550, SM8650 — same kernel/DTS/boot chain as upstream; ROCKNIX ABL prerequisite |
| Shell | OpenGamepadUI under gamescope |
| Removed | Steam client + seed (from the image; see Steam below), Decky, FEX, Proton, lsfg-vk, Android container (Lepton, Play, podman, adb), gtk2, vpower, steamos-* entry points |
| Steam (2026-10-15) | Downloaded on demand, never shipped. Steam Client is installed from Main menu > Emulators (2026-10-18), with its progress: "Steam Client" (`steam-install`: Valve's arm64 client binaries via `steam-bootstrap --install`, the x86 guest, then the client's own update; ~2 GB download, ~3 GB on disk; Open starts Steam's UI; no library card). Before that, `steam` downloads nothing and says where to install it. The RetroForge plugin replaces the OGUI Steam plugin (2026-10-21): it lists every game the account owns, from the signed-in client's own caches (`steam-library`: licenses in `appcache/packageinfo.vdf` minus package 0, game types and names in `appcache/appinfo.vdf`, installed ones from the app manifests), with Install and Uninstall handed to Steam's own dialog (`steam://install/<id>`, progress from the manifest) and art from the client's cache or Valve's CDN, in a Steam tab refreshed when Steam closes. No second sign-in and no steamcmd: the Steam CLI entry (Valve's arm64 steamcmd, for the OGUI Steam plugin) is gone. `/usr/bin/steam` runs the client from /home, raw on the host (2026-10-19: gtk2, libibus and lsof in the base, as Nova-Deck; games' Steam Linux Runtime 4.0 container cannot start nested in the client's steamrt3c one). Everything it downloads follows a channel, not a version (2026-10-16): `steam.pin` names client `steamdeck_stable` (to match the plugin's `-steamdeck`; a mismatch costs a ~631 MB client re-download). Also downloaded into /home: the x86 guest Valve's FEX tool needs for native x86 games and x86 Protons (FEX's ArchLinux RootFS channel with x86 Turnip, `steam/x86-guest.pin`, ~1.4 GB, XXH3-checked, installed with Steam Client, kept on its channel in the background and mounted with squashfuse while Steam runs; `STEAM_COMPAT_GRAPHICS_PROVIDER` points at it; `packages/mesa-x86` builds one with our own Mesa, for the pin's fixed url+sha256 mode). And the newest Proton-CachyOS arm64 release, on the player's Download in Apps > Proton (`retroforge-proton`, with its percentage; the entry Steam, GOG and Epic share, with the ARMv8.0 channel on those CPUs) or a store game's first launch; one stable tool name across updates. DXVK-Sarek has no setting (2026-10-31): it is on in every Proton of ours on the Adreno 610/613 (SM6115, SM4450), which lose upstream DXVK with Mesa 26.3 (no multiViewport), and off elsewhere. Windows games use Valve's Proton ARM64, whose DXVK drives the native Turnip. The image carries only the wrapper, its helpers and the channel pins. FEX for x86 games is left to Steam, which adds it per game (not yet seen on hardware), so no FEX, box64 or x86 Mesa in the image (the guard refuses them and any x86 binfmt entry). SM6115 needs kernel 0025 (Valve's LSE atomics). A Settings > General toggle (off by default, 2026-10-21; `retroforge-steam-keep`) keeps the client running between games as a user unit, so games after the first skip Steam's ~18 s cold start. Another (on by default on the SM6115 and 4 GB boards, 2026-10-22; `retroforge-steam-direct`) starts a game Steam has started before without the client, replaying Steam's own logged launch: ~1.5 GB more headroom, and Hades no longer killed by earlyoom on the Air X; no cloud, achievements, overlay or Steam Input. `docs/steam-arm64.md` |
| Kept | retroforge-pairingd (always on until the shell has a switch), userspace fake-suspend (retroforge-suspend / retroforge-rest) |
| Names | Display RetroForge, os-release ID `retroforge`, D-Bus `org.retroforge`, session user `player` (uid 1000) |
| Root slots | 2G each (was 4G until 2026-10-03 trim, 7G with the x86 payloads) |
| Firmware | Fetched from retroforge-linux/qcom-firmwares (pinned; Nova-Deck import + SM6115 blobs) |
| OTA signing | New RetroForge CA; private keys in `~/retroforge-pki`, never in the repo |
| Emulators | Upstream AppImages, downloaded on demand by an OGUI plugin (not in the image); must use our patched Mesa/Turnip, not a bundled one |

## Phases

### Phase 0 — Base system ✅ done

- Imported the reference tree, removed Steam / x86 / Android stacks, their tests, CI jobs and kernel
  options (binder, Android netfilter set, NTSYNC, EROFS).
- Session launcher shell-agnostic: `RETROFORGE_SESSION_CMD` (placeholder `vkcube --wsi xcb`) +
  `RETROFORGE_GAMESCOPE_SHELL_ARGS`.
- Power button: configurable short/long actions (suspend / power off).
- Upstream names renamed to retroforge; `deck` → `player`; root slots 4G.
- SD format helpers kept as `retroforge-format-{sdcard,device}`.
- `guard-rootfs.sh` fails a release build if a removed stack comes back;
  `tests/test-upstream-name.sh` fails on leftover upstream names.
- New OTA signing CA + release cert.
- `make relock` run: `rootfs/manifest.lock` re-resolved without the removed stacks' dependencies.
  `installer/manifest.lock` needs no relock (same package set and snapshot); relock it after the
  first `make kernel` if its package list changes.
- Since built and booted many times (2026-10-02/03): root image ~1.0G apparent in its 2G slot.

### Phase 0 follow-ups (before the first real build)

| Task | Why |
|---|---|
| ✅ Build `make sdcard`, check `du --apparent-size out/images/rootfs.img` (~1.0G in the 2G slot) | Confirm the 2G slot has ≥1G headroom; `make-sdcard.sh`'s `fits` check is the backstop |
| ✅ Boot on one SM8250, one SM8550, one SM8650 (Pocket FIT, 2026-10-04) | Gate: gamescope + vkcube on the panel, A/B confirm via retroforge-boot-good |
| ✅ Back up `~/retroforge-pki/ca.key.pem` off this machine (done 2026-10-03) | Losing it means no device can ever accept another update |

### Phase 1 — OpenGamepadUI as the shell — done

Done:
- `packages/opengamepadui`: first a prebuilt pin of upstream's aarch64 release tarball (v0.46.1);
  since 2026-10-02 a local PKGBUILD (engine/core/reaper from that tarball, pck re-exported with our
  patches, see Phase 2). `deps: libxinerama` (Godot's X11 backend).
- Session profile in `session.conf`: `RETROFORGE_SESSION_CMD=opengamepadui`,
  `RETROFORGE_GAMESCOPE_SHELL_ARGS="--steam --xwayland-count 2"` (OGUI drives gamescope through the
  Steam-mode X atoms, so X11/Xwayland is required), plus `QT_QPA_PLATFORM=xcb`,
  `SDL_VIDEO_MINIMIZE_ON_FOCUS_LOSS=0`, `vk_xwayland_wait_ready=false`. Driven by `retroforge-session`;
  `gamescope-session-plus` is NOT used.
- OGUI's self-updater trimmed from the release root (incl. the `make_nice` setcap helper that any
  user could pkexec). The OS slot carries the OGUI version.
- gamescope `0023` (Android/xdg titles) retired; `0005` kept (it covers OGUI's window too).
- Guard 9b (shell present, updater absent); `tests/test-session.sh`.
- Relocked: + opengamepadui, + libxinerama, gamescope rehashed. Root 1.8G apparent / 945M allocated.

Remaining:
- ✅ **Hardware** (SM8550 Pocket ACE, SM8250 Pocket Max, 2026-10-02/03): boots to OGUI; pad
  navigation (InputPlumber), quick-menu overlay over a running game, mangoapp, focus switching
  OGUI <-> game (DuckStation), panel rotation. SM8650 (Pocket FIT) ✅ 2026-10-04.
- Check OGUI's in-app update setting cannot still download a user-local build (likely moot once the
  RetroForge OSPlatform removes OGUI's updater, Phase 5).
- ✅ PowerStation: done in Phase 2 (patched upstream PowerStation, retroforge-powerd stripped down).

### Phase 2 — Handheld features in OGUI (High) — done

Decisions (2026-10-02, from reading OGUI v0.46.1 source in `_ref/OpenGamepadUI`):
- **No OGUI plugin for now** (superseded 2026-10-03: the Phase 4 RetroForge plugin). Only OGUI's built-in screens; RetroForge-only controls (fan curve,
  scheduler, update channel) stay CLI/SSH (`retroforge-scheduler`, `retroforge-update`, powerd D-Bus).
  Update channel / OS updates: superseded 2026-10-04 by a RetroForge OSPlatform in OGUI (Phase 5).
- **No per-game (per-ROM) layer.** The upstream tweaks layer (game-tweaks.json, retroforge_perf, the
  per-game `scheduler` override) existed for x86 titles under FEX/Proton; emulators carry their own
  per-game settings (Phase 3). Profile, GPU clock, CPU scheduler, fan curve stay system-wide.
- **Update gate = OGUI's own OOBE marker**: `settings.cfg [general] first_boot=false`.
- **Perf UI = upstream PowerStation, patched (2026-10-03).** OGUI's performance menu speaks only
  `org.shadowblip.PowerStation`. We build upstream PowerStation (`packages/powerstation`, main @
  b161e80) with two patches meant for upstream: non-SMT CPUs keep all cores (it halved them and
  grouped big.LITTLE cores by per-cluster core_id), and a devfreq backend for non-PCI GPUs
  (Adreno under msm: clock limits, min/max range, manual switch). OGUI patch 0003 hides the TDP /
  thermal / power-profile controls an SoC GPU does not have. retroforge-powerd's power profiles, PPD
  interface and GPU clock control were removed; it keeps the fan (one curve, `power.conf`), the
  boot CPU governor (ondemand; the kernel default is performance), sched_ext and the suspend clamp.
  scx_lavd no longer runs with --autopower.

Done:
- retroforge-update gates on the OGUI first-boot marker (was Steam's loginusers.vdf); Steam wording
  gone; `channels` / `set-channel <name>` added. `retroforge-select-branch` + its test removed.
- Per-game layer removed: `retroforge_perf.py`, `tests/test-perf.sh`, powerd's perf tick and
  scheduler override (powerd keeps a 3s scheduler-reconcile tick).
- Phase 1 image kept as `out/images/sdcard.p1.img`.
- `brightnessctl` 0.5.1 (overlay PKGBUILD — not in the holo snapshot; logind backend, not setuid)
  so OGUI's brightness slider exists. Relocked (+1 row). HW ✅ (slider moves the panel).
- Session runs `opengamepadui --skip-update-pack`: OGUI's self-updater fetches the x86_64
  `update.zip`; applying it at start would black the panel and override the image's shell version.

- **OGUI v0.46.1 crash-loops on DT boards** (HW, Pocket FIT 2026-10-02: black panel after the
  splash). HardwareManager reads DMI `product_name`; no SMBIOS on ABL UEFI → null FileAccess →
  SIGSEGV ~10s into every start (upstream #542). Also #540: Godot 4.7 native
  `custom_maximum_size` breaks the game launch menu. v0.45.1 crashes the same way.
  Fix: `packages/opengamepadui` is now a local PKGBUILD — upstream's aarch64 engine/core/reaper
  from the release tarball, `opengamepad-ui.pck` re-exported from the v0.46.1 tag + 2 patches
  (null guard + devicetree-model fallback; rename to `scroll_maximum_size`) with the arm64
  Godot 4.7.1 editor and the real core loaded (an x86 export without the core drops data from 14
  scenes). Pck verified file-by-file against upstream. HW: boot to OGUI, open a game's launch menu.
  Drop the patches when upstream releases fixes; consider sending them upstream.
- `which` added to PKGS: OGUI probes helpers with `which <cmd>` (brightnessctl, wpctl, mangoapp,
  bwrap); without it the brightness slider was absent.
- HW 2026-10-02, AYANEO Pocket ACE (SM8550), build 20261002T165505Z: boots to OGUI, no crashes,
  0 script errors, brightness slider works, volume works. Remaining log noise is harmless:
  "Could not identify active GPU" (platform DRM device has no PCI ids; glxinfo would not help —
  decided to skip it), a one-time burst of 68 "Unexpected NUL" (upstream /proc scan), plugin store
  request failing on first boot. Power menu, launch menu, SM8250 and SM8650 all checked since.

Remaining OS-side (found in OGUI source):
- ✅ OGUI power menu suspend / reboot / poweroff work from the session (HW, Pocket Max 2026-10-03).
- ✅ PowerStation (above) HW-tested 2026-10-03 on the Pocket Max (SM8250, dev build
  20261003T114234Z): Adreno 650 found via devfreq, menu populated without TDP controls, GPU max
  405 -> 400 MHz OPP lands in devfreq, core count 4 offlines cpu4-7, all 8 cores kept after OGUI's
  default apply, ondemand on every policy; GPU cap and core count survive suspend/resume.
- Send upstream: PowerStation 0001/0002 (ShadowBlip/PowerStation), branch `_ref/PowerStation`
  retroforge-arm. OGUI sent 2026-10-03: #559 (0001, fixes #542), #560 (0002, fixes #540), #561 (0003),
  from loki666/OpenGamepadUI branches fix/no-dmi-devicetree, fix/custom-maximum-size,
  fix/perf-menu-soc-gpu. Drop each patch once it lands in a release.
- HW 2026-10-03, MANGMI Pocket Max (SM8250), dev build 20261003T094820Z (`29a24b7`): first
  SM8250 boot. retroforge-session.service (no sddm) gives an Active wayland session on seat0/VT1,
  boot-good confirmed slot A, polkit grants NM / timezone / power / udisks to the session with no
  prompt, OGUI up without crashes (only the known glxinfo / GPU-id errors), backlight controllable.
  Also verified: session restarts after gamescope is killed (Restart=always, new seat0 session);
  OGUI power menu suspend / reboot / poweroff, and power-key short press -> retroforge-suspend (both
  suspend cycles resume with radios, CPUs, backlight and the session intact). gamescope does
  direct multi-plane scanout here (OGUI + mangoapp on 2 KMS planes, UBWC, DPU 90-degree rotation),
  compositing only occasionally. A game's launch menu / game scanout moves to Phase 3.
- ✅ Steam wording cleaned (2026-10-03) across the overlay; what remains names a measurement
  taken under the Steam client or the boot chain (steamcl, steamos-bootconf), on purpose.
- ✅ `kernel/kernel.config` CONFIG_PROC_CHILDREN comment fixed (2026-10-03; next image build
  rebuilds the kernel).
- retroforge-pairingd stays always-on (no shell switch).

### Phase 3 — Emulator platform (High) — done (closed 2026-10-03)

Closed with DuckStation running end to end on the SM8250 Pocket Max: upstream AppImage on our
Mesa/Turnip (fuse3), `retroforge-launch` with clean exits on every path, first-run settings from the
image, per-game CPU pinning (`--cpus big`), the player folder layout, guest SMB shares (with the
ksmbd backport), and the retroforge-session stop fixes (fast restart, games stopped first). What was
left moved: the other five emulators and the DuckStation hotkeys to Phase 4b (they reach players
through the plugin catalog); DuckStation's pinned-tag re-test to Phase 4 (first catalog); the
upstream reports to the Backlog; the SM8650 boot stayed a Phase 0/1 item (done 2026-10-04).


- Emulators to ship (decided 2026-10-03): Dolphin, ARMSX2, DuckStation, Azahar, rpcs3, Cemu.
  DuckStation done here; the other five moved to Phase 4b.
  Packaging: probably AppImages (they bundle their own Qt / ffmpeg, which is why the root dropped
  both). Check per AppImage whether it uses the system's patched Mesa/Turnip or a bundled one --
  that decides GPU support on these SoCs. (Earlier plan: native PKGBUILDs, RetroArch + cores.)
- **Distribution (decided 2026-10-03, design in Phase 4): not in the image.** An OGUI plugin downloads an
  emulator's AppImage the first time a ROM needs it, and offers updates when RetroForge publishes a
  new one. This reverses the Phase 2 "no OGUI plugin" decision for this purpose. Until it exists,
  AppImages are pushed to `/home/player/emulators` by hand for testing.
- **DuckStation first** (2026-10-03). Upstream `latest` DuckStation-arm64.AppImage (86 MB,
  218 MB unpacked): bundles Qt6 / SDL3 / GTK3 but NO Mesa, libvulkan, libGL/EGL, gbm or drm, so
  it uses our Mesa/Turnip. Needs glibc >= 2.35 (root has 2.43) and host libX11/xcb/wayland/
  fontconfig, all present; only unused Qt plugins (eglfs, wl-shell) miss libs. Static type-2
  runtime: root has no `fusermount`, so either ship fuse3 or extract on download
  (`--appimage-extract`, what the test does). Launched from OGUI via a `Categories=Game` .desktop
  in `~/.local/share/applications` with `-bigpicture -fullscreen`.
  HW ✅ 2026-10-03, MANGMI Pocket Max (SM8250): Crash Team Racing (CHD, SCPH-550x BIOS set) runs
  full speed on Vulkan/Turnip through the gamescope WSI layer (60 Hz swapchain, Adreno idling at
  305 MHz); sound, picture and orientation OK; OGUI overlay works over it; OGUI's Exit (reaper
  SIGTERM to the process group) quits it cleanly. With cpu4-7 offline it ran on the little
  cluster alone, CPU thread ~44% of one 1.8 GHz core: PS1 needs no pinning. Lessons for the
  plugin / launcher:
  - Exec the real binary (`usr/bin/duckstation-qt`), never the extracted `AppRun` symlink: Qt
    takes applicationDirPath from the symlink, misses `qt.conf`, finds no platform plugin, aborts.
  - Seeding settings.ini to skip the setup wizard also skips its controller auto-map: write
    `[InputSources] SDL = true` + a `[Pad1]` SDL-0 mapping. InputPlumber exposes a single
    virtual Xbox Elite 2 pad (real joypad is root-only), so `SDL-0` is stable. Leave Guide
    unbound (OGUI owns it).
  - No xdg-desktop-portal: harmless Qt warning, it falls back to its own theme.
  - Exit is OGUI Guide -> running-game card -> Exit; an emulator hotkey can come later.
- **Per-game CPU pinning at launch** (decided 2026-10-03). The performance menu's core-count
  slider stays a POWER control: PowerStation offlines the fastest cores first, so "4 cores" on
  SM8250/SM8550/SM8650 is the little cluster only. Keeping a game's threads on the fast cores
  (no migration across clusters) is done per game instead: the launcher sets the emulator's CPU
  affinity to the big cores, so background work (audio, input, Wi-Fi) keeps the little ones.
  - Pick the big cores from `/sys/devices/system/cpu/cpuN/cpu_capacity`, not by CPU number.
  - Per game, the player's choice through the plugin (decided 2026-10-03; done, see above).
  - sched_ext: scx_lavd honours the affinity mask (HW-checked).
- PowerStation follow-up for upstream: moved to the Backlog.
- InputPlumber hotkeys: exit to shell works through OGUI's Guide menu; emulator save/load-state
  hotkeys moved to Phase 4b.
- Per-device defaults: DROPPED as a standalone item (2026-10-03). Nothing needs one today (DuckStation's
  seed is the same on every device; per-device pinning went with the per-game player choice). Add a
  device-specific value from `/usr/lib/retroforge/devices/<device>.conf` only when an emulator needs it --
  likely first: Azahar's screen layout on the dual-screen Pocket DS, or resolution scaling once a heavy
  emulator shows a real gap between SoCs.
- ✅ **Player folder layout** (2026-10-03): `~/{roms/<system>,bios/<system>,saves/<system>,
  states/<system>,emulators}` (bios per system since 2026-10-05, before more emulators land) from `/usr/share/user-tmpfiles.d/retroforge-home.conf`, created by player's own user
  manager at every login (system tmpfiles is not ordered after /home, which is `nofail`), so OTA'd
  devices, which keep /home, gain new folders too. The user `systemd-tmpfiles-setup.service` must be
  linked into `/etc/systemd/user/basic.target.wants` -- user presets are only applied at package
  install, which an image build never runs (HW: the folders were missing until that link). Every
  launch.conf system needs its rows (test). DuckStation's seed puts memory cards in `~/saves/psx`
  and states in `~/states/psx`. ROMs from a second SD card stay with Phase 5's automount decision.
- ✅ **Network shares** (decided + built 2026-10-03): ksmbd (in-kernel SMB3, `CONFIG_SMB_SERVER=m`)
  + ksmbd-tools 3.5.7 (overlay PKGBUILD, not in the snapshot; Samba was ~110 MiB+ with deps),
  `/etc/ksmbd/ksmbd.conf`: shares roms, bios, saves, states only; GUEST read-write mapped to
  `player`; ON by default (preset + .wants), avahi-daemon enabled for `retroforge.local` and an
  `_smb._tcp` record. `[ipc$] guest ok = yes` is needed: ksmbd-tools adds [ipc$] without it, so a
  guest could not list shares. HW (Pocket Max, 20261003T175813Z): direct share URLs work as guest
  (anonymous or any name) from Linux; Windows 10/11 refuse SMB guest logins by default.
  - ✅ Listing the shares at the server root (`smb://retroforge.local/`) failed for every user, guest
    or authenticated, with stock or our [ipc$]: kernel 7.2's `smb2_ioctl()` looks the RPC pipe id up
    as an open file and returns -ENOENT before `fsctl_pipe_transceive()` runs. Upstream regression
    from "ksmbd: add SMB3 request replay support"; backported Gael Blivet's fix (applied to
    ksmbd-for-next-next) as kernel/patches/1000. HW (20261003T183508Z): guest `smbclient -L` and
    the desktop file manager list roms/bios/saves/states.
  - HW end to end (same card): folders created at login with no manual step; BIOS + CTR copied in
    over the guest shares (~58 MB/s, owned by player, with a POSIX ACL from ksmbd); DuckStation
    seeded from the image; the CTR memory card landed in ~/saves/psx and is visible on the `saves`
    share; with SaveStateOnExit (now in the seed) OGUI's Exit wrote ~/states/psx/
    SCUS-94426_resume.sav. Not yet checked: what DuckStation does with that resume state on the next
    launch; two short runs right after enabling it wrote no state (likely exited during boot).
- ✅ Licence check: never ship BIOS. DuckStation checked 2026-10-03 (see Phase 4, Licences);
  emulators come from upstream, so RetroForge redistributes none.

### Phase 4 — RetroForge OGUI plugin: ROM library + emulator manager (High)

First steps, host-testable before any GDScript: `retroforge-launch --gui <emulator>` (no-ROM mode
for the store's Open; done 2026-10-04, `GUI_ARGS` in the emulator conf, DuckStation
`-bigpicture -fullscreen`; HW ✅ 2026-10-04 on the Pocket ACE: Big Picture opens with no ROM, its
own Exit returns to OGUI, mount released), and a first
`catalog.json` with DuckStation pinned to a
numbered release (v0.1-11894 or newer), re-tested on HW (launch, pad, every exit path, memory card,
resume state). Catalog done 2026-10-04: `/usr/share/retroforge/catalog.json` in the image (schema 1: name,
systems, github owner/repo, tag, anchored asset regex, sha256, size, homepage, licence; launch
details stay in the image's emulator conf), DuckStation pinned to v0.1-11894 (sha256 = GitHub's
digest), checked by `tests/test-catalog.sh` (`RETROFORGE_NET_TEST=1` also re-checks every pin against
GitHub). The image's copy is the only one (OTA updates it); the hosted catalog that was to win from
`~/.cache/retroforge/catalog.json` is dropped (emulator-latest.plan.md D7, 2026-10-16).
Part 2 started 2026-10-04: `/usr/bin/retroforge-emu list | install <emu> | remove <emu>` (Python,
`tests/test-emu.sh`), the download half the plugin drives (stdout = `N%` lines / JSON; exit 2 usage,
3 network, 4 verification, 5 local). Install: GitHub API for the pinned tag, refuse unless the
asset's digest + size equal the catalog's and the URL is https; curl `--proto =https
--proto-redir =https` into a .part; sha256 + size again; rename to `<tag>.AppImage`, flip
`current` atomically, keep the previous AppImage, delete older ones. Real install from GitHub
verified on the host (DuckStation, 86 MB, 9 s).
Plugin side done 2026-10-04 (HW ✅ Pocket ACE):
- No pre-launch check (decided): a ROM card always launches; when retroforge-launch exits 3 it leaves
  `not-installed|mount-failed <emu>` in `$XDG_RUNTIME_DIR/retroforge-launch.status`, and the plugin's
  EXIT hook shows OGUI's shared dialog ("DuckStation is not installed. Download it from the RetroForge
  store first."). Needed OGUI patch 0004 (#562): an app that exits before any window was never
  seen as stopped (loading screen hung); now stopped on the first failed check, ~0.6 s.
- Store = Settings > Emulators (decided: not OGUI's dormant Store button, which is meant for game
  stores): the plugin injects a button after Library + a page into OGUI's settings menu at runtime
  (`emulators_page.gd`, built like library_settings_menu.tscn: own State, StateUpdater REPLACE,
  TabSetter, TextSetter). Per emulator: Download / Update / Open (`retroforge-launch --gui` via
  LaunchManager) and Delete (confirm dialog); progress from the .part size; rows rebuilt after
  each action with the focus handed back.
- retroforge-emu retries every transient curl error (`--retry-all-errors`): a curl 55 (Wi-Fi drop)
  failed the first in-UI download on the ACE.
Still open in part 2/3: an OGUI notification when an emulator update is available (now from
retroforge-emu `check`, emulator-latest.plan.md; the hosted catalog is dropped, D7).
HW 2026-10-04, Pocket ACE, v0.1-11894 from a card: first-run seed, launch, OGUI Exit
(double SIGTERM, clean, mount released); DuckStation keeps every seeded value when it rewrites
settings.ini (drops our comments, adds [UI] geometry). Memory card and resume state not checked
(game left during the intro).
Tab prototype done 2026-10-04 (`apps/ogui-retroforge-plugin/`, `build.sh` -> `out/plugins/retroforge.zip`,
`tests/test-plugin.sh`): YES, a plugin can add a per-system tab. HW ✅ Pocket ACE: a "PlayStation"
tab next to Installed / All Games with OGUI's own cards, CTR also in All Games, its card opens OGUI's
launch menu and runs `retroforge-launch psx <rom>` (path with spaces as one argument). What it took:
- OGUI's library menu only fills Installed and All Games; a tab added via `library_tabs_state`
  is placed in the TabContainer but the plugin fills its grid (cards from `card.tscn`, button_up ->
  `game_launcher` state, as `library_menu.gd` does). Node layout must match AllGamesTab
  (ScrollerJoystick, then MarginContainer > HFlowContainer): the menu focuses `get_child(1).get_child(0)`.
- Plugins initialise BEFORE the library menu is ready (PluginManager first in card_ui.tscn), so
  tabs are added from `library_manager.library_loaded`, never in the plugin's `_ready`.
- Never override `_init()` in a plugin script: it replaces the base constructor, and
  `Library._init` is what registers the library on ready (first try loaded, never registered).
Done 2026-10-04 (plugin 0.1.2; HW ✅ Pocket ACE: 4 colliding ROMs = 4 cards, Refresh Library after deleting two dropped the stale cards and renamed the rest): library items are keyed by NAME across
all providers, so two same-named ROMs merged into one item (the second was lost). `rom_names.gd`
now names a colliding ROM "Tetris (PlayStation)" (other system) or "Tetris (CUE)" (same system),
compared without case; and each scan first removes our launch items whose ROM is gone or whose
name now means another file (`load_library` only adds). Tested in a stock headless Godot
(`RETROFORGE_GODOT=<godot 4.7 x86_64>`, skipped without). Per-game fast cores done 2026-10-04 (plugin 0.1.3): Game settings > RetroForge (the gear on a ROM's
launch menu; button + page injected at runtime like Settings > Emulators, shown for RetroForge ROMs
only) holds "Run on fast cores". Saved in OGUI's settings.cfg `[retroforge.fast_cores]`, key
`<system>/<file>` (not the card name, which can change), absent = off; flipping it rewrites the
launch item's args (`--cpus big` first), which OGUI reads at each launch. HW ✅ Pocket FIT
(SM8650): on -> `retroforge-launch --cpus big`, DuckStation affinity 2-7; off -> 0-7, key erased;
on survives a session restart (toggle shown on, pinned 2-7).
Emulator-level default done 2026-10-04 (plugin 0.1.4 + retroforge-launch): the per-game toggle became an
override. Settings > Emulators has "Run on fast cores" per emulator, written to the player's
`~/.config/retroforge/emulators/<emu>.conf` as `CPUS=big|all`, which retroforge-launch reads itself (read,
never sourced; also applies to Open / --gui). Game settings > RetroForge is a dropdown: "Emulator
default (On|Off)" (no --cpus) / On (`--cpus big`) / Off (`--cpus all`), saved in OGUI's settings.cfg
`[retroforge.cpus]` (replaces `[retroforge.fast_cores]`). The image still pins nothing (test). HW ✅ Pocket FIT:
default on -> plain launch pinned 2-7; game Off -> `--cpus all`, 0-7; Open -> 2-7.
OGUI per-game performance profiles checked 2026-10-04 (Pocket FIT): the quick-bar core count is saved
per game (`~/.local/share/opengamepadui/data/performance/profiles/<device>_<docked|undocked>_<sha256
of card name>.tres`), applied when the game starts, the default restored when it stops. Bug found:
OGUI ships no default profile for any device; a missing default is created from the settings
applied at that moment, so on a fresh image a game's core count stayed applied after it exited.
OGUI patch 0005 (branch fix/perf-default-profile on upstream main, cherry-picked to
retroforge-perf-menu) saves the startup settings as the docked + undocked defaults when missing; HW ✅
(defaults saved at start with 8 cores; CTR set to 4 -> back to 8 on exit). Upstream PR waits for the
authors' confirmation (user asks on their Discord). Notes: turning Advanced mode on resets the
profile to all cores (upstream design); per-game profiles are keyed by card name (a renamed card
loses its profile); with fast cores On and a 4-core profile the emulator ends up on the online fast
cores (2,3 on SM8650), whatever the order of pinning and profile apply.
Performance Overlay (quick bar slider) fixed 2026-10-04: OGUI writes $MANGOHUD_CONFIGFILE and
mangoapp reloads it; mangoapp only shows once gamescope sends it a game frame time, so it never
shows over the library (by design). In games it blinked and froze: pam_systemd (systemd >= 254) puts
CAP_WAKE_ALARM in every login session's ambient set, OGUI passed it on to the games, and mangoapp
(gamescope's child, which drops ambient caps) then got EACCES on the game's /proc/<pid>/fdinfo, an
uncaught ghc::filesystem error that aborted it every ~4 s. retroforge-session now starts the shell under
`setpriv --inh-caps=-all --ambient-caps=-all` (test). HW ✅ Pocket FIT: overlay steady and updating,
no mangoapp abort. Also MangoHud patch 0007 (ours): find_fd() catches the filesystem error, so a
game holding capabilities can no longer crash mangoapp (upstream master already does this in
mangohud-next, no PR). HW ✅: with the old session (game has CAP_WAKE_ALARM) the overlay stays up,
0 aborts.
Still to handle: OGUI's search only covers Installed / All Games;
the tab refreshes twice at start (two library loads); upstream `remove_tab` resets `current_tab`
on the wrong condition (`size > current_tab`).
OGUI only reloads its library at start and from Settings > Library > Refresh Library: no D-Bus
service, signal or file watch. Automatic rescan (2026-10-05, plugin 0.1.6, HW ✅ Pocket ACE):
`rom_watch.gd` + a 5 s Timer in plugin.gd. Each poll lists `~/roms/<system>/*` as name, size and
mtime; `load_library("retroforge-roms")` runs once that list differs from the last library load AND two
polls in a row agree (a copy still running waits; a ROM shows 5-10 s after its copy ends). Skipped
while a game runs (`launch_manager.get_running()`) and while our own load is in flight; any
`library_loaded` for our library (start, Refresh Library, ours) resets the baseline. Not a dir-mtime
check as first proposed: Godot gives whole seconds, so a file created in the same second as a poll
went unseen, and an SMB copy can set the final size before writing (only mtime moves). Rejected:
inotifywait in a Pty (no inotify-tools, process lifecycle), systemd .path (OGUI has no IPC).
HW check: copy a ROM over SMB while on the library (card appears after the copy, not during),
delete one (card goes), copy during a game (nothing until exit).

**Phase 4 open items** (plan check 2026-10-04)
- Automatic rescan: done 2026-10-05 (plugin 0.1.6, see above), HW ✅ Pocket ACE.
- Resume and the memory-card / resume-state HW check: moved to Phase 6 (2026-10-04, not blocking).
- Plugin store: masked 2026-10-05, UNMASKED 2026-10-06 (user decision): OGUI patches 0006
  (store URL as the `OpenGamepadUI/plugin/store_url` project setting) and 0007 (RetroForge sets it
  to "") dropped, because OGUI's first-start screen then showed an empty catalog. RetroForge may never
  have a store of its own (its one plugin ships in the image and OTAs), so upstream's store stays,
  with its first-boot request noise. Branches feat/plugin-store-url + retroforge-store-off are kept
  in _ref/OpenGamepadUI (local; PR not sent).
- Attribution per emulator: done 2026-10-05 (plugin 0.1.7). Catalog `author` (required by
  tests/test-catalog.sh) + homepage + licence name/url, shown as one dimmed line under each
  emulator on Settings > Emulators (`credits.gd`); HW ✅ Pocket ACE.
- Update notification + plugin updates from the store. (Hosted catalog dropped 2026-10-16:
  emulator-latest.plan.md D7.)

Decided 2026-10-03: one OGUI card per ROM, grouped in one library tab per system (PSX, PS2, ...),
and emulators fetched on demand. Both live in ONE plugin (`retroforge`), since the ROM card is what
needs the emulator. Design from OGUI v0.46.1 source (`_ref/OpenGamepadUI`); to review before code.

**What OGUI gives us (verified in source)**
- Plugins: `user://plugins/<id>.zip` = `~player/.local/share/opengamepadui/plugins/`, loaded with
  `ProjectSettings.load_resource_pack`; the zip holds `plugins/<id>/plugin.json` + `plugin.gd`
  (GDScript source, no export needed). Enabled by default (`settings.cfg [plugins.enabled]`).
  Only the user dir is scanned, so the image can not ship it read-only: seed the zip into /home
  (see Delivery).
- `Library` subclass = a library provider: `get_library_launch_items()` returns
  `LibraryLaunchItem`s (`name, command, args[], env{}, cwd, tags[], categories[], installed,
  metadata{}`); args are an array, so ROM paths with spaces need no quoting (unlike `.desktop`
  Exec, which OGUI splits on spaces).
- `get_app_lifecycle_hooks()` -> `AppLifecycleHook` PRE_LAUNCH / LAUNCH / EXIT;
  `LaunchManager` AWAITS pre-launch hooks before starting the app, and a hook can emit
  `progressed(percent)` / `notified(text)`. That is the "download on first launch" point.
- `Library.install/update/has_update/uninstall` + `install_progressed`: OGUI's install flow.
  The launch menu only shows Install / Launch / Uninstall; nothing in the UI calls `has_update`
  or `InstallManager.update`, so there is no built-in update badge.
- Library tabs: `res://core/ui/card_ui/library/library_tabs_state.tres` (`TabContainerState`)
  has `add_tab(text, ScrollContainer)` / `remove_tab`; the menu itself only builds Installed and
  All Games. A plugin adds the per-system tabs and fills their grids.
- `BoxArtProvider` (GRID_PORTRAIT / GRID_LANDSCAPE / BANNER / LOGO): artwork per item, later.

**Plugin parts** (overall shape, 2026-10-03: like armada's Decky store -- a store for the emulators
plus the ROM library that launches them)
1. Systems table (in the plugin): `psx -> {name "PlayStation", exts [chd, cue, pbp, m3u, iso],
   emulator duckstation}`, `ps2 -> armsx2`, `gc/wii -> dolphin`, `3ds -> azahar`, `ps3 -> rpcs3`,
   `wiiu -> cemu`. ROM dirs `/home/player/roms/<system>/` (one level deep; m3u wins over its
   member cue/chd so a multi-disc game is one card).
2. Library provider `retroforge-roms`: one item per ROM, `name` from the file name (strip region /
   tags later), `tags [<system>]`, `metadata {system, rom, emulator}`, `installed true`.
   `command` = `retroforge-launch` (below), `args [<system>, <rom path>]`, prefixed with `--cpus big|all`
   only when the game overrides its emulator's fast-cores default (done 2026-10-04, see above).
   Rescan on OGUI start, via Settings > Library > Refresh Library, and automatically (rom_watch.gd).
   **Resume (decided 2026-10-03): the plugin asks.** When a game has a resume state, its card offers
   Resume / Start fresh before launching. Emulators cannot ask themselves: DuckStation's "Resume
   Game -- load this state, or start from a fresh boot?" dialog only exists in its own game list
   (`FullscreenUI::HandleGameListActivate`), which a ROM card on the command line bypasses. Needs a
   `retroforge-launch --resume` mapped per emulator (DuckStation: `-resume`, from the emulator conf) and
   a per-emulator way to tell whether a resume state exists (DuckStation names it
   `~/states/psx/<serial>_resume.sav`, so the plugin needs the game's serial). Moved to Phase 6
   (2026-10-04). Until then games boot
   fresh; the state is still loadable from the emulator's pause menu.
3. Tabs: one tab per system that has at least one ROM, populated from the provider's items (done:
   OGUI's own cards in a plugin-built grid, see the tab prototype above).
4. Emulator manager, modelled on armada's Decky store (armada-os/armada, `decky/armada-store`;
   decided 2026-10-03): NO mirror -- AppImages come straight from each emulator's own releases.
   A catalog (`catalog.json`) lists per emulator: the releases API URL (GitHub / GitLab), the
   PINNED release tag, an asset regex (e.g. `^DuckStation-arm64\.AppImage$`), the binary inside the
   AppImage and default args. Decided 2026-10-03: RetroForge HOSTS the catalog (fetched over HTTPS from
   the RetroForge server; the copy bundled in the plugin is only the offline fallback) and pins one
   tested tag per emulator, so RetroForge alone decides when an update is offered: bumping a tag in the
   hosted catalog after testing is what makes the plugin offer it. No "newest" mode (armada follows
   upstream's newest; an upstream change could break a seed or the launch args unnoticed).
   REVERSED 2026-10-16 (emulator-latest.plan.md): latest by default, the pin kept as the "tested"
   marker, one-press revert, and NO hosted catalog — the image's catalog (OTA-updated) is the only one. Rolling
   tags are never pinned: DuckStation's `latest` (the 0.1-12070 build tested so far) replaces its
   asset in place, so its pin must be a numbered release (v0.1-11894 or newer), re-tested on HW.
   Install: fetch that tag's release, download over HTTPS only (refuse a
   redirect to http), verify the asset's sha256 against the API's `digest` field (GitHub publishes
   one per asset; matched our tested DuckStation AppImage) -- armada does not verify, we do --
   then stage and rename atomically to `/home/player/emulators/<emu>/<tag>.AppImage`, chmod +x,
   flip `current` (previous AppImage kept until the new one has launched once). Update check =
   installed tag vs the hosted catalog's tag (armada's 1 h cache, and a failed fetch never counts
   as "no update").
   **Store screen** (decided 2026-10-03, armada-store style): the plugin's own page lists the
   catalog's emulators with installed vs catalog tag, and per emulator: Download, Update (when the
   hosted catalog's pinned tag is newer), Delete, and **Open** -- start the emulator's own GUI for
   the settings OGUI does not expose (graphics, per-game options, controller tweaks). Open needs a
   no-ROM mode in the launcher (`retroforge-launch --gui <emulator>`: same AppImage mount / setsid /
   exit handling, GUI args from the emulator conf instead of the ROM args, e.g. DuckStation without
   `-batch`). An OGUI notification points at the store when the catalog offers an update. Updates
   are never applied at launch. Not via OGUI's `has_update`: in v0.46.1 no UI calls it, and it is
   per library item, so one DuckStation update would flag every PSX card.
   **ROM whose emulator is not installed**: SUPERSEDED 2026-10-04 -- no pre-launch check and no
   download from a card: the launch fails fast and the EXIT hook's popup points at Settings >
   Emulators (see "Plugin side done" above).
5. Per-emulator first-run config -- MOVED to the image (decided 2026-10-03, done): defaults in
   `/usr/share/retroforge/emulators/<emu>/`, named by `SEED=(<file>:<path under $HOME>)` in
   `/etc/retroforge/emulators/<emu>.conf`; retroforge-launch copies them before the first start, never
   over an existing file. One set per emulator for every device: InputPlumber presents each
   handheld's joypad as one virtual Xbox Elite pad (SDL-0). Per-device overrides via
   `/usr/lib/retroforge/devices/<device>.conf` only if a device ever needs one. The plugin only
   downloads; a "reset to RetroForge defaults" action on its Emulators page if needed later.
   HW ✅ (Pocket Max, settings.ini removed first): seeded, no wizard, pad + Select+Start + Exit OK.
   Contents (DuckStation: settings.ini with wizard off, BIOS/ROM dirs, Vulkan, `[Pad1]` SDL-0 mapping,
   ConfirmPowerOff off (SIGTERM path), auto-updater off, `[Hotkeys] OpenPauseMenu = SDL-0/Back & SDL-0/Start` -- by default only
   keyboard Escape opens its menu, so a controller can never reach Exit; HW-verified). Never overwrite a user-changed config after that.

**Launcher `retroforge-launch <system> <rom>`** (in the image, `/usr/bin`, shell, unit-tested)
- Resolves the emulator from the system, mounts `/home/player/emulators/<emu>/current` and runs
  `<mount>/<binary> <per-emu args> <rom>` under the AppImage rules above (DuckStation:
  `-batch -fullscreen -- <rom>`; `-batch` returns to OGUI when the game closes).
- The one place for per-game CPU pinning (Phase 3), and for any device-specific value later.
- Keeps the plugin free of emulator details beyond the manifest; testable over SSH without OGUI.

**Plugin store: RetroForge's own, upstream's masked** (decided 2026-10-03)
- OGUI hard-codes `PLUGIN_STORE_URL` = ShadowBlip/OpenGamepadUI-plugins `plugins.json`
  (`core/global/plugin_loader.gd:20`). Its 7 entries (steam, flathub, steamgriddb, recapture,
  lutris, sunshine, ayaneo-modules) are Steam/x86/desktop oriented, and the request is the
  "plugin store request failing" noise seen on first boot. Mask it.
- OGUI patches 0006/0007 (written 2026-10-05: store URL as a project setting, set empty in our
  build) were DROPPED 2026-10-06: an empty catalog on OGUI's first-start screen. Revisit only if a
  RetroForge store is ever hosted.
- RetroForge store = a `plugins.json` in the same format (`plugin.id/name/version/min-api-version`,
  `archive.url`, `archive.sha256`, `versions[]`) on the RetroForge update server, listing `retroforge`
  (and anything else we publish). OGUI then gives us, unchanged: periodic store check
  (`on_update_timeout`), "update available" when `plugin.version` is greater and the API is
  compatible, install with sha256 verification into `user://plugins/<id>.zip`.
- The RetroForge server hosts the plugin store (`plugins.json` + plugin zips) and the emulator
  catalog (`catalog.json`, pinned tags); the emulators themselves come from upstream (part 4). Trust (decided 2026-10-03): HTTPS to the RetroForge host is enough; the plugin
  index carries a sha256 per archive (emulators: GitHub's per-asset digest), no separate signature. Downloads must refuse plain
  http and invalid certificates.

**Delivery of the plugin itself**
- Built in-repo (`apps/ogui-retroforge-plugin/` -> zip), shipped in the image at a read-only path and
  copied into `~player/.local/share/opengamepadui/plugins/` by the session when missing or older
  than the image's copy (compare `plugin.version`), so a freshly flashed image works offline. Later
  versions come from the RetroForge store; the session never downgrades a store-updated copy.
  SUPERSEDED 2026-10-18 (ota-ui plan): no plugin store exists, the image is the only source, so the
  session installs the image's copy whenever the version DIFFERS (beta -> stable channel switch).

**Decided 2026-10-03**
- Download source: ~~RetroForge mirror~~ REVERSED 2026-10-03 -- straight from upstream releases,
  armada-store style (see part 4). We redistribute nothing, so no LGPL source hosting for the
  libraries the AppImages bundle.
- FUSE: `fuse3` in the image (fusermount3 setuid, already on the guard permit list), AppImages
  stay packed. Install = download + verify + chmod + `current` symlink.
  HW ✅ 2026-10-03 (Pocket Max, dev build 20261003T135813Z): AppImage mounts as player; CTR runs,
  controller OK; OGUI Exit graceful in ~70 ms, no core dump, no leftover process or mount -- but
  only through a launcher wrapper (prototype `/home/player/emulators/appimage-run`, to become
  the AppImage path of `retroforge-launch`). Rules it encodes, each found on HW:
  - Never exec the AppImage (or AppRun): the runtime starts `AppRun`, a symlink; Qt takes
    applicationDirPath from it, misses `usr/bin/qt.conf`, finds no platform plugin and aborts.
    Same in DuckStation v0.1-11580 / 11894; desktops hide it with a system Qt. Mount with
    `--appimage-mount` and exec `<mount>/<binary>` (manifest field `binary`, e.g.
    `usr/bin/duckstation-qt`). Report upstream.
  - OGUI `Reaper.reap()` (`core/systems/launcher/reaper.gd:65`) signals every PID in the tree,
    leaves inward, as `kill -TERM -- -PID` then `kill -TERM PID`, separate commands. Run the
    emulator under `setsid` so it leads its own group: its two signals arrive back to back and
    coalesce, as when OGUI launches it directly. Inside the wrapper's group it got a second,
    later SIGTERM, which DuckStation takes as "force quit" -> abort(), core dump, 14 s exit.
    No OGUI patch needed.
  - The mount runtime is in the tree too: start it with SIGTERM ignored, or OGUI tears the files
    away under a shutting-down emulator. The runtime also ignores INT (bash background) -- release
    it after the emulator exits with SIGHUP to the runtime, then `fusermount3 -u` (the parent
    holds the mount busy until it exits).
  - Exit pressed twice = SIGKILL leaves a dead mount: sweep `fuse.<appimage>` mounts on start
    (`fusermount3 -uz`).
  - The wrapper traps TERM and waits; it never forwards the signal (that would be the second
    Ctrl+C).
- **`retroforge-launch <system> <rom>` done** (2026-10-03): `/usr/bin/retroforge-launch` with
  `/etc/retroforge/launch.conf` (system -> emulator) and `/etc/retroforge/emulators/<emu>.conf` (BINARY
  inside the AppImage, ARGS); runs `/home/player/emulators/<emu>/current`. Offline suite
  `tests/test-launch.sh` (fake AppImage / emulator / fusermount3, OGUI reap replayed; in
  `make test`). HW ✅ on the Pocket Max, dev build 20261003T153817Z: an OGUI card running
  `retroforge-launch psx .../ctr.chd` boots CTR directly; OGUI Exit graceful (~190 ms), and quitting
  from DuckStation's own pause menu returns to OGUI (`-batch`); no core dump, process or mount left.
  The FUSE type is named after the file `current` points to (`fuse.0.1-12070.AppImage`), as the
  stale sweep assumes; only the mount dir takes the link's name.
- ✅ **Per-game CPU pinning** (2026-10-03): `retroforge-launch --cpus big <system> <rom>` starts the
  emulator under `taskset -c <fast cores>`: every ONLINE CPU whose cpu_capacity is above the
  smallest online one (SM8250 cpu4-7, SM8550 cpu3-7, SM8650 cpu2-7), never by number, never the
  prime core alone; nothing pinned when no fast core is online (PowerStation core-count limit) or
  the SoC is homogeneous. Decided: it is the PLAYER's choice, per game -- the plugin offers it and
  puts `--cpus big` on that game's command line; no emulator conf in the image pins anything (a
  test enforces it). HW (Pocket Max, DuckStation): affinity 4-7, every working thread stays there;
  Mesa's 4 idle shader-disk-cache threads reset themselves to all CPUs (Mesa util_queue,
  harmless); scx_lavd honours the mask (320 samples, 0 on cpu0-3). CoreThread ~10% of a big core
  at 825 MHz -- PS1 gains nothing; it matters for rpcs3 / Cemu / ARMSX2.
- ✅ **`systemctl restart retroforge-session` took 90 s** (fixed 2026-10-03). PAMName= moves the
  session into the logind session scope, so the service cgroup is empty and systemd's stop only
  signals the main PID, retroforge-session (sh). It ran OGUI in the FOREGROUND, and sh holds a trapped
  SIGTERM until the foreground command returns: nothing ever told OGUI to quit, so every stop sat
  out TimeoutStopSec and ended in SIGKILL. Not new (every restart was 90 s), just unmeasured. Now
  the client runs in the background and the script `wait`s, forwards SIGTERM to it, then stops
  gamescope; `<&0` keeps tty1 as its stdin; `SuccessExitStatus=143` so a requested stop is not
  logged as a failure. HW (bind-mounted script + runtime drop-in): restart 0.9-2.3 s (stop
  ~0.1 s + RestartSec), OGUI stdin still /dev/tty1. tests/test-session.sh runs the real script
  with a fake gamescope and client; it fails on the old script.
- ✅ **Games running when the session stops** (fixed 2026-10-03). OGUI quits without stopping
  them: its reaper goes to PID 1, the game runs on until gamescope dies, then loses its display
  and aborts (core dump, ~15 s orphan holding the GPU into the next session). retroforge-session now
  stops games FIRST, gamescope still up, exactly as OGUI's Exit does (Reaper.reap pattern),
  finding OGUI's reapers by executable (so a game outliving a crashed OGUI is covered too), waits
  up to 10 s (RETROFORGE_GAME_STOP_TIMEOUT), then SIGKILLs leftovers. HW: CTR shut down gracefully,
  game gone ~330 ms after the stop, mount released, restart 3.5 s, no core dump; the stale mount
  a killed run left was swept by the next launch.
  Found on the way: DuckStation's `ConfirmPowerOff` IS needed. Its menu Exit never asks, but a
  SIGTERM does, and the dialog waited out the 10 s timeout (game killed, stale mount). Restored
  in the seed, with a test.
- Not pursued (decided 2026-10-03): a one-off gamescope SIGABRT core dump when a game was
  SIGKILLed during the session stop (timeout/kill path only; never seen on a clean stop).
- ROM cards show in All Games as well as in their system tab.

**Open questions for review**
- Licences: the plugin downloads from upstream, so RetroForge redistributes no emulator; still check
  each emulator's licence AND its author's stated terms (configuration, packaging) before adding it
  to the catalog.
  DuckStation (checked 2026-10-03): CC BY-NC-ND 4.0. The README allows redistributing
  "unmodified releases", prefers a link to duckstation.org, and states "pre-configured settings and
  packages are considered modifications" -- so the author would count our seed settings.ini and the
  plugin's packaging as modifications. Decided 2026-10-03: proceed anyway (seed; the mirror is
  gone, see Download source), the risk is accepted. Attribution (author, link, licence) shown in the plugin since 0.1.7; still owed: RetroForge staying
  non-commercial.
- BIOS: the plugin can tell the user which BIOS a system needs and where to drop it; never ships it.
- Artwork scraping later (ScreenScraper needs credentials).

### Phase 4b — Grow the emulator catalog (after Phase 4)

- ✅ ARMSX2 (PS2), 2026-10-05, plugin 0.1.8. GPL-3.0, "The ARMSX2 team (based on PCSX2)". Numbered
  releases are Android-only; Linux arm64 AppImages exist only in dated nightlies, so the pin is
  `nightly-20261005` (= 2.8.1 + one microVU clamp fix; `nightly-20261004` is exactly 2.8), the
  `Linux-arm64-4K-pages` build (our kernel is 4K pages). Old nightlies may be pruned upstream: then
  re-pin. Settings: `~/.config/ARMSX2/inis/PCSX2.ini` (PCSX2 keys); the seed MUST carry
  `[UI] SettingsVersion = 1` or ARMSX2 offers to reset everything to defaults. Renderer left on
  Automatic (forcing Vulkan shows a warning each start; Auto picks Vulkan on Turnip). BIOS left on
  Auto (user decision): ARMSX2 picks the first image in ~/bios/ps2. Args `-batch -nogui -fullscreen --`,
  GUI `-bigpicture -fullscreen`. HW ✅ Pocket ACE: Maximo (USA) 58.7 fps avg, Turnip 26.2.4, SDL-0 pad +
  rumble, Select+Start pause menu, OGUI Exit (SIGTERM) writes the resume state with no dialog; exiting
  from ARMSX2's own pause menu does not (its "close" path skips SaveStateOnShutdown).
- **Launcher redesign (decided 2026-10-05, before more emulators):** `retroforge-launch` mixed HOW an
  emulator is packaged with HOW a game is run, so each packaging quirk became another special case
  (Dolphin's pkgforge AppImage needed /tmp links and a Vulkan env in its sourced bash conf). User
  decisions: keep the FUSE mount (no unpacking at install), rewrite in Python, Flatpak only if an
  emulator ever needs it.
  - **Data, not code, per emulator:** `/usr/share/retroforge/emulators/<emu>/emulator.json` next to its
    seed files, replacing the sourced `/etc/retroforge/emulators/<emu>.conf`:
    `{"format": "appimage" | "appimage-sharun", "binary": "<path in the image>",
      "args": [..., "{rom}", ...], "gui_args": [...], "env": {..}, "seed": [{"file", "to"}]}`.
    `{rom}` appears exactly once in `args` (DuckStation `-- {rom}`, Dolphin `-e {rom}`), no
    "append the ROM" convention. Unknown keys and a bad format are refused at launch (exit 2).
    The catalog stays "where to get it" (hostable later); emulator.json is "how to run it" and
    ships in the image, tested with its seeds. `launch.conf` (system -> emulator) and the player's
    `~/.config/retroforge/emulators/<emu>.conf` (CPUS=) are unchanged: the plugin reads/writes them.
  - **Format drivers** in retroforge-launch, each owning everything about its format once:
    `appimage` = today's lifecycle (stale-mount sweep, mount runtime with SIGTERM ignored, run
    <mount>/<binary> never AppRun, SIGHUP + fusermount3 -u); `appimage-sharun` = the same plus
    pkgforge-dev's specifics: /tmp/<name> links read (as data) from
    bin/01-path-mapping-hardcoded.hook, and the image's Turnip (SHARUN_ALLOW_SYS_VKICD=1 +
    VK_DRIVER_FILES = /usr/share/vulkan/icd.d/freedreno_icd.aarch64.json) instead of the bundled
    Mesa. New formats (an archive, a Flatpak) are a new driver, never emulator-specific code.
  - **Shared run logic, unchanged behaviour:** CLI (`[--cpus big|all] <system> <rom>`,
    `--gui <emu>`), status file for the plugin's popup, first-run SEED, fast cores
    (os.sched_setaffinity, same capacity rule), emulator in its own session, signal handling
    exactly as HW-verified (Exit = 2 x SIGTERM from OGUI's reaper; double Exit = SIGKILL), exit code
    passed through. tests/test-launch.sh is black-box (runs the executable with RETROFORGE_* overrides),
    so it stays the regression suite; only its conf fixtures move to emulator.json.
  - ✅ DONE 2026-10-05: Python retroforge-launch, 3 emulator.json, formats appimage + appimage-sharun;
    /etc/retroforge/emulators/*.conf removed; RETROFORGE_EMU_DATA_DIR replaces RETROFORGE_EMU_CONF_DIR and
    RETROFORGE_EMU_SEED_DIR; test-launch 130 pass. Code review fixes: SIGTERM stays ignored/handled for
    the whole mount wait (Python had restored the default), prepare() inside the try/finally that
    releases, raw read with deadline for the mount line, fusermount3 failures never replace the
    emulator's status, NUL/normalised-path checks, /tmp links only replace our own symlinks and are
    removed on release. HW ✅ Pocket ACE: CTR (OGUI Exit), Maximo (pause-menu exit), NSMBW + MKDD
    (Turnip 26.2.4, /tmp link, fonts OK), whole-tree SIGKILL then relaunch, session stop in game,
    --gui, fast cores (affinity 3-7). Found on HW: pkgforge's runtime serves the mount with a separate
    `dwarfs` process (type fuse.dwarfs, source = AppImage path); the stale sweep now matches that too.
    Known edge, not fixed: if ONLY the launcher is SIGKILLed, dwarfs keeps serving and OGUI's reaper
    waits on it (game looks stuck) until it is unmounted; OGUI's UI cannot cause this (one Exit).
  - Steps: (1) emulator.json for duckstation, armsx2, dolphin + schema checks in test-launch;
    (2) Python retroforge-launch passing the existing suite; (3) the sharun driver (replaces the bash
    /tmp-link code and dolphin.conf's exports, both never committed); (4) HW re-test on the ACE:
    CTR, Maximo, MKDD, NSMBW -- launch, OGUI Exit, emulator-menu / Select+Start exit, double
    Exit, fast cores, Open (--gui), not-installed popup, session stop in game; (5) commit Dolphin
    on top. Note for later: 3 curl retries 2 s apart all fell in one Wi-Fi bad patch on the ACE
    (retroforge-emu exit 3); a longer retry window would make downloads sturdier.
- ✅ Dolphin (GameCube + Wii), 2026-10-05, plugin 0.1.9+. No official Linux arm64 build: pkgforge-dev
  repackages each Dolphin release (pin `2609@2026-10-01_1790876487`, = Dolphin 2609; retroforge-emu now
  allows '@' in tags), format appimage-sharun. Seeds: Dolphin.ini (game paths ~/roms/gc + wii, Wii
  NAND ~/saves/wii, GC memory card folder ~/saves/gc, Vulkan, no stop confirm, analytics declined),
  GCPadNew/WiimoteNew (sideways Wii Remote)/Hotkeys (Select+Start = Stop). The pad's SDL name is
  Dolphin's OWN bundled SDL's: "Xbox One Elite 2 Controller" (ARMSX2's SDL says "Microsoft Xbox One
  Elite 2"); a wrong name leaves every binding dead -- recheck when the pin moves (Logger.ini
  [Logs] CI = True). User decisions: save states stay in Dolphin's own folder (no setting for it);
  no resume-on-exit (Dolphin has none). HW ✅ ACE: MKDD + NSMBW, controls, Select+Start stop.
- **Emulator roster (decided 2026-10-06, surveyed the same day).** Added at the user's request: PPSSPP,
  and from pkgforge-dev Flycast, mGBA, Snes9x, xemu, melonDS (on top of Azahar, rpcs3, Cemu). Every
  one has a pinnable aarch64 AppImage; all but rpcs3 are "anylinux" sharun builds -> format
  appimage-sharun (PPSSPP's official one is built with the same tooling: inspect before assuming).

  | Emulator | Systems | Source (GitHub) | Pin candidate (2026-10-06) | Format |
  |---|---|---|---|---|
  | mGBA | gba, gb, gbc | pkgforge-dev/mGBA-AppImage-Enhanced | 0.10.5-5@2026-10-01_1790876690 | sharun |
  | Snes9x | snes | pkgforge-dev/Snes9x-AppImage | 1.63-1@2026-10-01_1790876690 | sharun |
  | PPSSPP | psp | hrydgard/ppsspp (official) | v1.20.4 | anylinux (inspect) |
  | Flycast | dc | pkgforge-dev/Flycast-AppImage-Enhanced | 2.7@2026-10-01_1790875174 | sharun |
  | melonDS | nds | pkgforge-dev/melonDS-AppImage | 1.1-2@2026-10-01_1790875607 | sharun |
  | Azahar | 3ds | pkgforge-dev/Azahar-AppImage (no official arm64 Linux) | 2126.1.2@2026-10-01_1790876552 | sharun |
  | Cemu | wiiu | pkgforge-dev/Cemu-AppImage-Enhanced | 2.6-4@2026-02-01_1769935971 | sharun |
  | xemu | xbox | pkgforge-dev/xemu-AppImage-Enhanced | 0.8.136@2026-10-01_1790871942 | sharun |
  | rpcs3 | ps3 | RPCS3/rpcs3-binaries-linux-arm64 (official) | build-ffc50905... (v0.0.42-19759) | appimage |

  Order (simplest first): mGBA, Snes9x -> PPSSPP, Flycast (BIOS optional) -> melonDS, Azahar (two
  screens on one panel: layout to decide) -> Cemu (game keys) -> xemu (BIOS + MCPX + HDD image),
  rpcs3 (firmware install). Never pin a `nightly` tag (rolling; test-catalog refuses it).
  Per emulator, the recipe: catalog pin (sha256/size from GitHub's digest, RETROFORGE_NET_TEST=1
  test-catalog), licence + author's stated terms, emulator.json, minimal seed (pad as SDL sees it
  -- check the device name in the emulator's own log, no exit confirmation, folders in the shared
  layout ~/{roms,bios,saves,states}/<system>, Select+Start menu/stop, Guide unbound), launch.conf
  rows, plugin SYSTEMS entry (+ version bump), test-launch checks, HW test on a dev image: launch,
  controls, OGUI Exit, the emulator's own exit, Open. Test games go in ~/Downloads/<system> on the
  host (user provides them; never ship BIOS or games).
- **Roster written 2026-10-06, NOT HW-tested (plugin 0.1.12; tested all at once by the user).**
  rpcs3 pinned to the newer `build-1b90d1c1...` (v0.0.43-20233, published that day) instead of the
  surveyed v0.0.42. Every bundle inspected (work/appimages/x, gitignored) and each emulator's input
  code read at its tag. The pad, for raw-index emulators: InputPlumber's xbox-elite target is uinput
  045e:0b00 v1 "Microsoft X-Box One Elite 2 pad", xpad order (our capability maps put physical X on
  BTN_X/0x133), so SDL raw b0 A, b1 B, b2 X, b3 Y, b4 LB, b5 RB, b6 Back, b7 Start, b8 Guide, b9 L3,
  b10 R3, a0/a1 left, a2 LT, a3/a4 right, a5 RT, hat 0; SDL has no DB row for it (bus 3) and builds
  an xpad mapping, so gamepad-API positions are right. Computed SDL GUID `030010f85e040000000b000001000000`
  (CRC16 0xf810 of the name) -- only Cemu depends on it.
  Launcher additions (generic, tested): sharun hook also read as `.src.hook` (PPSSPP); `{system}` in
  args (mGBA's one save/state folder per launch); a ROM may be a folder (PS3 disc dump);
  emulator.json `install` = one-time import of a player file with the emulator's own binary (RPCS3
  firmware), `missing-file <emu> <path>` / `install-failed <emu>` statuses with plugin popups; an
  Exit during the install (1 s settle: reap() signals leaves first) never starts the game.
  Plugin: 11 new tabs (tab order now by maker then age), `dirs` markers for folder games
  (game_dirs.gd; the watcher counts a folder by its marker file). tests/test-launch.sh checks every
  emulator.json loads and each seed's controller lines (positions, way out, Guide unbound).

  | Emulator | Pad found by | Way out from the pad | Notes |
  |---|---|---|---|
  | mGBA (gb/gbc/gba) | first joystick, raw idx | none: OGUI Exit (no combos; R3 quit dropped) | no exit state on SIGTERM; HW ✅ ACE buttons (Droopy's Tennis) |
  | armGBA (gb/gbc/gba, replaces mGBA 2026-10-25) | SDL game-controller API | Hotkey (Select, seeded: Auto = Guide, OGUI's) + Start twice | one save/state folder in frontend.cfg -> launcher `system_settings` rewrites it per system; .srm saves (mGBA's .sav = same bytes, rename); SIGTERM = SDL quit event, save written; HW: pending |
  | Snes9x | joystick 1, raw idx | none: OGUI Exit (no combos; R3 quit dropped) | hat = axes 6/7; Sound Driver index 3 = PulseAudio; Vulkan |
  | PPSSPP | device 10, gamepad API | Select+Start = pause, Exit quits (--pause-menu-exit) | saves/states via tmpfiles links |
  | Flycast | mapping file by SDL NAME | Select+Start = menu, Exit quits | AutoSaveState on, AutoLoadState off |
  | melonDS | SDL index 0, raw idx | none (no quit hotkey/combos): OGUI Exit | side-by-side screens, JIT on, L3 mic, R3 swap, LT lid, RT ff |
  | Azahar | maptype:all, gamepad API | Select+Start = Exit Azahar | large top + small bottom; L3 cycle, R3 swap; sdmc/nand in ~/saves/3ds |
  | Cemu | exact SDL GUID (computed!) | none: OGUI Exit | screen toggle on paddle 1; audio api 3 required; keys.txt link |
  | xemu | auto-bind, guide-less SDL env mapping | Back+Start = xemu menu, Exit | player supplies MCPX/BIOS/HDD qcow2; XISO only |
  | RPCS3 | "<SDL name> 1" | Select+Start = PS/home menu, Exit Game | firmware install step; dev_hdd0 in ~/saves/ps3 |

  HW checklist per emulator: launch from a card, every button/stick/trigger by position, the way out
  above, OGUI Exit, Open (--gui), saves land in ~/saves/<system>. Specific: Snes9x 6 axes + sound; PPSSPP assets found (sharun /proc/self/exe) and
  device 10; Flycast name -> mapping file (else Select alone opens its menu); melonDS speed (software
  renderer) and JIT; Azahar gamepad mapping present, layout cycle keys, sdmc/nand used; **Cemu GUID**
  (read the real one from xemu.toml port1 after an xemu run, or Cemu's GUI) + which button is paddle 1
  + share/Cemu found (log.txt); xemu Guide inert, Vulkan; RPCS3 `--headless --installfw` on aarch64,
  pad name in RPCS3.log, --big-picture under gamescope; tmpfiles links created on login.
  Pad exit for emulators that cannot bind a combination (mGBA, Snes9x, melonDS, Cemu): decided
  2026-10-06 = none for now, OGUI's Exit (Guide) only. R3-quit was dropped (too easy to hit).
  InputPlumber cannot do it per game (0.81: a profile maps ONE source button; capability-map chords
  are per board and always on; intercept activation is one chord per device and OGUI uses it for
  Guide). Revisit later: retroforge-launch watching Select + Start (held ~1 s) for those four only.
  Still open: Cemu's screen-toggle button.
  xemu memory (HW 2026-10-06, Pocket ACE 7.5 GB): the Vulkan renderer allocates fixed worst-case
  scratch buffers at start (pgraph/vk/buffer.c: 2 x 800 MB compute buffers sized for 10240x10240
  upscaling, 2 x 64 MB staging, VRAM mirror...), ~5 GB resident on Turnip's unified memory: 280 MB
  left, swapping, and the game struggled (one TCG thread at 99% on the prime core at 2.96 GHz;
  governor ondemand was NOT the limit). Not a leak (flat). Options: OpenGL renderer on the bundled
  Mesa (not measured yet), or a per-device default (8 GB boards) once launch options exist. Testing
  moved to the Pocket FIT (16 GB) for xemu, Cemu and RPCS3. On the FIT xemu stays CPU-bound (one TCG thread ~95% on the
  3.05 GHz prime core; card I/O ~1.2 MB/s, 0% iowait): user verdict "xemu sucks anyway".
  scx_lavd 1.1.3 PANICS when cores are offline (cpu_order.rs:678 index out of bounds; HW 2026-10-06
  Pocket FIT): the core-count slider (our power control) hot-plugs CPUs, sched_ext exits, systemd
  restarts lavd, it panics until all cores are back, and stops retrying (start limit). Starts fine
  with all 8 online. To fix: check upstream scx for a fix / guard in retroforge-powerd (only run lavd
  with all cores online, restart it after the slider goes back up). Also seen: switching xemu to a
  per-game OGUI performance profile produced cpu_core_count_current = 4 (user unsure whether set by
  hand) -- check whether OGUI seeds a new per-game profile with a wrong core count.
  xemu switched to the OFFICIAL xemu-project aarch64 AppImage (v0.8.136, classic linuxdeploy
  layout -> format appimage, binary usr/bin/xemu, SDL3 3.4.10 static, no bundled Mesa; 15.5 MB vs
  pkgforge's 37.6 MB), as armada does. User: "runs better" on the FIT (same ~5.3 GB GPU memory and
  ~95% emulated-CPU thread; lavd was also on for this run, off for the pkgforge ones).
  Cemu: v2.6 (the last release, Feb 2025; every pkgforge 2.6-4 build) dies with SIGILL on the first
  instruction of recompiled code (ARM64 recompiler) ~0.2 s into the game on the FIT; pkgforge's
  rolling nightly (master cc6fea1, 2026-10-05) runs SM3DW: pad (computed GUID confirmed by xemu's
  port1), buttons, sound (TVVolume 100 added: missing key = 20 %), saves, clean OGUI exit. No other
  aarch64 Cemu exists (official/Flathub are x86-64 only); armada ships pkgforge's nightly, unpinned.
  Binary is bin/cemu (newer builds have no bin/Cemu). DECIDED 2026-10-07: Cemu follows pkgforge's
  rolling nightly (catalog "channel": "nightly"; 2.6 predates the AArch64 recompiler #1556, May 2025,
  so no patch rescues it). retroforge-emu installs the current asset as nightly-<commit> against GitHub's
  sha256 digest; plugin 0.1.13 shows "Nightly <commit>" and a "Newer nightly / Update" row (checked
  on demand, never at launch). test-catalog allows a rolling tag only with the channel.
  **ares replaces Snes9x (2026-10-07, user decision; NOT HW-tested).** Snes9x 1.63's GTK frontend
  (master too, gtk_s9x.cpp) runs S9xExit -- config save, sound/display/GTK teardown, exit(0) -- inside
  its SIGTERM/SIGINT/SIGQUIT handler while its threads run, so every OGUI Exit crashed it. Options
  surveyed: no other arm64 SNES AppImage but ares (bsnes: no arm64 build; Mesen2: a bare .NET binary
  zip; RetroArch: no arm64 AppImage on GitHub); fixing Snes9x = upstream patch (g_unix_signal_add) or
  an LD_PRELOAD shim, both parked. ares v148 (pkgforge-dev/ares-emu-appimage, numbered pin, sharun,
  bin/ares, ISC) now serves snes + the new md (Mega Drive), segacd (Mega CD) and 32x tabs; plugin
  0.1.14. Launcher gained `system_args` (system -> args put before args): `--system "<ares name>"`
  and `--setting Paths/Saves=~/saves/<system>/` per launch (ares appends its system name; states go
  there too, ~/states/<system> stays empty; unset = next to the ROM). Args `--pseudofullscreen --kiosk`
  (GLX `--fullscreen` renders at monitor size into a window gamescope never resizes: off-centre and
  cropped, HW Pocket Max). HW ✅ Pocket Max 2026-10-07: MD (Kunio no Nekketsu School Fighters) pad,
  sound, saves in ~/saves/md/Mega Drive/, centred full height, clean OGUI Exit; ~1 core, clocks low. SNES Yoshi's Island (SuperFX 2, .zip ROM): 60 fps stable,
  main thread ~69% of a 2.42 GHz big core, 38 C; save in ~/saves/snes/Super Famicom/.
  Seed ~/.local/share/ares/settings.bml: SDL input, Defocus Allow, VirtualPad1 bound by the computed
  SDL GUID (`<guid>/0/<group>/<input>[/Lo|Hi]`, groups 0 axis, 1 hat, 3 button; D-pad = hat + left
  stick), Mega CD BIOS paths ~/bios/segacd/bios_CD_{U,E,J}.bin (ares finds firmware only via its GUI
  Scan; kiosk errors out without it; sha256-checked). Exit: ares sets no signal handler, so SIGTERM
  kills it cleanly but with no final save; AutoSaveMemory flushes battery saves every 30 s. Quit
  hotkey is one button only: unbound. HW checklist: pad GUID binding works (else check the identity
  in ~/.local/share/ares/settings.bml after binding one button in the GUI), audio (SDL), GL under
  gamescope, speed on SM8250 (SuperFX/SA-1, 32X), Mega CD BIOS + a cue/chd, saves land in
  ~/saves/<system>/, 6-button pad needed? (MD port default is the 3-button Control Pad).
  **ares dropped, Snes9x back, ClownMDEmu for Mega Drive + Mega CD, no 32X (2026-10-10, user
  decision: ares too heavy).** Snes9x's exit crash is fixed by an LD_PRELOAD shim,
  apps/retroforge-sigdefer (/usr/lib/retroforge/libretroforge-sigdefer.so, stage sigdefer-shim, `make sigdefer`,
  tests/test-sigdefer.sh): it interposes sigaction() and hands plain SIGTERM/SIGINT handlers to
  g_unix_signal_add, so S9xExit runs from the GLib main loop like a window close. sharun drops
  LD_PRELOAD unless SHARUN_ALLOW_LD_PRELOAD=1 (both in the definition's env). HW ✅ ACE: shim mapped,
  Exit writes snes9x.conf + .srm, no crash; core dumps back on. ClownMDEmu 1.6.12
  (pkgforge-dev/ClownMDEmu-AppImage-Enhanced, sharun, AGPL-3.0): `-f -u ~/.config/clownmdemu/<system>`,
  its "Save Data" linked to ~/saves/<system> (tmpfiles L), seed rewinding = off (keyboard left
  unbound), fixed SDL3 gamepad layout, Mega CD needs no BIOS (own boot ROM). HW ✅ ACE: Mega Drive
  (Kunio) fullscreen, pad, sound, smooth, .srm on Exit. Mega CD untested. 32X: no light standalone
  aarch64 emulator (PicoDrive: no Linux build, SIGTERM skips saves; BlastEm 1.0: interpreters on
  ARM, needs 32X BIOS); Genesis Plus GX has no 32X and no usable standalone frontend. Plugin 0.1.15
  (32x tab gone). The launcher's `system_args` stays (generic, tested) with no user.
  RPCS3 (HW 2026-10-07, Pocket FIT, Lollipop Chainsaw BLUS30917 folder dump): launcher fixes --
  its DwarFS runtime prints the mount point BEFORE mounting (launcher now waits for the mount);
  `rpcs3 --headless --installfw` installs FW 4.93 then aborts in a destructor (judge installs by
  marker + our own signals, not the installer's exit; install steps run with no core file: the
  dump held the launch 44 s); ~/saves/ps3/dev_hdd0 must exist (tmpfiles). Pad bound by name
  ("Xbox One Elite 2 Controller 1", SDL 3.4.14, same GUID). Overlay icons missing (looks in
  ~/.config/rpcs3/Icons and /usr/share/rpcs3; cosmetic). RPCS3 fetches its per-game config
  database (api.rpcs3.net/config, 2,241 games; BLUS30917 = Write Color Buffers) only from its Qt
  game list: catalog "data" files, fetched by retroforge-emu after install/update (user choice).
  Game patches (patch.yml) likewise never fetched: later, with launch options. First boot: long
  RSX shader + PPU module compile, cores 2-7 at 100% (fast cores pinned), 94 C: suggest fast cores
  OFF for RPCS3 (many threads).
  RPCS3 follow-ups done the same night: its SDL3 caught SIGTERM (OGUI Exit did nothing) ->
  SDL_NO_SIGNAL_HANDLERS=1 in its env; LimitMEMLOCK=infinity on retroforge-session.service (RPCS3 then
  raises its own to 2 GiB; "Failed to lock sudo memory" gone); with the config database applied
  (Write Color Buffers) the Turnip GPU hang ("hangcheck ... offending task: rsx::thread", device
  lost) did not come back. Select+Start -> Exit Game and Guide -> Exit both clean; save in
  ~/saves/ps3/dev_hdd0/home/00000001/savedata/BLUS30917-AUTOSAVE.
  OPEN (HW 2026-10-07, FIT, found during a long RPCS3 session): OpenGamepadUI DIMS the panel to
  10 % after 5 min and runs `systemctl suspend` after 20 min while a game is being played.
  core/systems/power/power_saver.gd resets its timers only in _input() (+ a gamescope
  keyboard/mouse counter); in game OGUI sets InputPlumber intercept PASS and InputManager marks
  joypad events handled (input_manager.gd:138-140), so PowerSaver never sees the pad. To decide:
  OGUI patch (count joypad activity / pause the timers while a game runs) vs config.
  melonDS screen layout (HW 2026-10-06, Pocket ACE): the user wants hotkeys for layout, single-screen
  view and switching screen. melonDS (1.1 and master) has no layout/sizing hotkey, its bindings
  are one button OR one axis (no combos, joystickButtonDown), no CLI option for the layout, and its
  config is only saved on a clean window close or a ROM load (never under OGUI's SIGTERM), with the
  menu bar hidden in fullscreen. Left as seeded for now (side by side; R3 swap, L3 mic, LT lid, RT
  fast-forward). Later: per-emulator LAUNCH OPTIONS (plugin choice per emulator + per game, like
  fast cores), applied by rewriting the emulator's config just before launch. User expects this to
  need a script per emulator (several keys per choice, device-dependent values, TOML/XML/QSettings),
  which would revisit the launcher redesign's "data, not code" rule: decide the shape then (e.g. an
  optional per-emulator hook next to emulator.json, run by retroforge-launch). Also possible: upstream
  melonDS hotkeys for cycling layout/sizing.
- The other three: Azahar (3DS), rpcs3 (PS3, needs firmware), Cemu (Wii U). Recipe from DuckStation, per emulator: an aarch64 AppImage that uses our
  Mesa/Turnip (armada's catalog has working asset patterns for all five); `.conf` + minimal seed;
  `launch.conf` system + folder-layout rows; every exit path (SIGTERM vs menu: ConfirmPowerOff-style
  dialogs, save state on exit); licence and author's stated terms; tag pattern + tested pin in catalog.json.
- Emulator save/load-state hotkeys (DuckStation first: seed bindings that avoid in-game combos).
- Device-specific values only when needed (Azahar's dual-screen layout on the Pocket DS is the
  likely first).
- GL on zink, NOT adopted (reviewed 2026-10-04, upstream e606f0f / merge c36dc38): drm/msm puts
  freedreno GL and Turnip Vulkan on different drm_sched priority levels of one ring, so a Vulkan game
  can starve GL clients; upstream moved all session GL to zink (`gallium-drivers=freedreno,zink`,
  vulkan-icd-loader depend, session-wide `MESA_LOADER_DRIVER_OVERRIDE=zink`). Their victim was the
  GL-heavy Steam UI; ours, OpenGamepadUI, already renders with Vulkan (Turnip), and games present
  through the gamescope WSI, so only Xwayland's glamor and mangoapp are GL. Revisit when the UI or the
  overlay stutters under a Vulkan game, or when a GL-rendering emulator joins the catalog -- then
  prefer zink per emulator (its conf), not session-wide. The same change dropped Mesa's device_select
  layer, which only matters for x86 games under FEX/pressure-vessel: not applicable, keep it.

#### PortMaster (planned 2026-10-11; A-E done, HW-tested and merged 2026-10-11)

PortMaster is an "emulator" in Settings > Emulators (Download / Update / Open like the others), but
it is not an AppImage and its games do not go through it: each port installs its own launch script.
Researched 2026-10-11 from PortMaster-GUI (release 2026.10.03-1041) and PortMaster-New (1469 port
scripts); paths below are relative to PortMaster-GUI/PortMaster/.

**Decisions (user, 2026-10-11):**
- **Self-update.** The catalog installs a pinned, sha256-checked `PortMaster.zip` the first time;
  after that PortMaster updates itself (hourly check of GitHub's latest `version.json`, asks the
  player, unzips over its own folder, relaunches). It only writes into a folder player owns, so it
  cannot touch the image. No `--no-check`: the port list moves fast and new ports often require a
  newer PortMaster. Settings > Emulators shows no Update for it (the catalog pin is first-install
  only).
- **No root.** No sudo for player; ports run as player with `ESUDO` empty. A port that only works
  as root is unsupported. (Rejected: NOPASSWD sudo, as handheld firmwares effectively do --
  downloaded scripts would run as root.)
- **Plain cards.** Port cards are named like other ROMs; no screenshots / port.json art for now
  (art comes with the library metadata work, Phase 4c).

**Where it lives (how PortMaster picks its folder).** Three layers each resolve it on their own:
every port script searches `/opt/system/Tools/PortMaster`, `/opt/tools/PortMaster`,
`$XDG_DATA_HOME/PortMaster`, `/roms/ports/PortMaster`; `control.txt` (sourced by every port)
searches again without `$XDG_DATA_HOME`, sets `directory=roms` and ports go to
`/$directory/ports/<port>`; harbourmaster (`pylibs/harbourmaster/config.py:37-242`) probes per-CFW
paths, falls back to `/roms/ports`, and honours `HM_TOOLS_DIR` / `HM_PORTS_DIR` / `HM_SCRIPTS_DIR`.
The system is `NAME=` of /etc/os-release (ours is already `RetroForge`); unknown names get the generic
`PlatformBase` (no gamelist writing, no frontend refresh). There is no plugin mechanism for a new
platform (static `HM_PLATFORMS` dict), but two hook files survive updates (an update unzips over the
folder without deleting): `mod_RetroForge.txt` (sourced by ~1465 ports) and `libgl_RetroForge.txt`. A
custom `control.txt` would NOT survive (only a Platform class re-copies it).
So: image symlink `/roms -> /home/player/roms`, PortMaster at `~/roms/ports/PortMaster`, ports in
`~/roms/ports` -- the generic default of all three layers, no fork, no custom control.txt. Never let
`~/.local/share/PortMaster` exist (port scripts look there before /roms/ports).

**What ports assume, and the no-root answer** (counts over 1469 scripts):
| Assumption | Ports | RetroForge |
|---|---|---|
| root via `$ESUDO` (empty when sudo does not work) | 1231 | empty: no sudo |
| `$ESUDO mount x.squashfs` for a runtime (godot, mono, java, love...) | ~295 | `mount`/`umount` stand-ins first on PATH, on squashfuse + fusermount3 (RetroDECK, the only non-root target, does the same with unsquashfs); `PM_CAN_MOUNT=N` |
| gptokeyb writes `/dev/uinput` | 1363 | udev rule: /dev/uinput for player (group or uaccess, 0660) |
| gl4es with `LIBGL_FB=4` (GBM, straight to KMS) | ~109 | `libgl_RetroForge.txt`: native Mesa GL, gl4es only as fallback (ROCKNIX's libgl_ROCKNIX.txt checks glxinfo) |
| westonpack (headless weston + crusty) | 75 | unknown under gamescope: HW test |
| armhf (`PORT_32BIT=Y`) | 210 | unsupported; PortMaster filters them out by arch |
Most ports are SDL2 built for KMSDRM but do not force `SDL_VIDEODRIVER`, so under our Xwayland SDL
picks x11. `pm_finish` runs `pkill -9 gptokeyb` and `systemctl restart oga_events` (harmless).

**Phases:**
- **A. Image** (host-testable): packages `sdl2_ttf`, `sdl2_image`, `sdl2_mixer` (the GUI is
  python3 + bundled pysdl2 on system SDL2, `PYSDL2_DLL_PATH=/usr/lib`), `squashfuse`, `mesa-utils`
  (glxinfo), `unzip`; the `/roms` symlink; the /dev/uinput udev rule; tmpfiles row for `~/roms/ports`.
- **B. Install through the catalog**: retroforge-emu assumes one AppImage in four places
  (`installed_tag`, `<tag>.AppImage` naming, chmod, remove-the-whole-dir). Add an archive format:
  unpack the pinned, sha256-checked zip into `~/roms/ports/PortMaster` (python zipfile), installed
  version read from PortMaster's own version file, no Update offered after install (self-update).
  Delete removes only `PortMaster/` and never the ports. test-catalog's arm64/aarch64 asset-name
  rule needs an exception (one zip for every arch).
- **C. Open**: a `script` format driver in retroforge-launch so Open runs `PortMaster.sh` (fast cores,
  status file, own session / process group as for the AppImages). Its relaunch loop after a
  self-update must stay inside that process group so OGUI's Exit still reaps it.
- **D. `ports` system**: plugin SYSTEMS entry `exts: ["sh"]` scanning `~/roms/ports/*.sh` (skip
  `PortMaster.sh`), launched as `retroforge-launch ports <script>` (same CPU pinning and exit path as
  ROMs); launch.conf row, tmpfiles rows (bios/saves/states not needed: decide whether
  test-launch's per-system row rule gets an exception), plugin version bump.
- **E. Hook files + HW**: `mod_RetroForge.txt` (`PM_CAN_MOUNT=N`, PATH for the mount stand-ins, display
  size, `GODOT_OPTS`, `pm_platform_helper`) and `libgl_RetroForge.txt`, shipped in the image and copied
  into the PortMaster folder when missing (like the OGUI plugin). HW test: one Godot port (runtime
  mount), one gptokeyb-heavy SDL2 port, one westonpack port; OGUI Exit and the port's own exit.
- **F. Later, optional**: upstream a `PlatformRetroForge` to PortMaster-GUI.

**Status 2026-10-11.** A-E shipped (ed3f4e1, 0840597, eabcc26, 9e2544a). HW Pocket ACE, dev image
plus bind-mounted patches: PortMaster GUI (download, open, splash, installs), A Key(s) Path (Godot 3),
Apotris (SDL2), Cave Crawler 2 (Godot 4 + Weston), Shattered Pixel Dungeon (Java + Weston,
gptokeyb2 mouse), Warzone 2100 (Weston, own libs); OGUI Exit and in-game quit both clean. What the
HW run changed against the plan above:
- `PM_CAN_MOUNT` stays Y (with N ports skip only their umount; the stand-ins handle both).
- PKGS + `openal libtheora` (LÖVE runtime: PortMaster's splash, patcher, LÖVE ports); libtheora 1.2
  renames the decoder, so a private `libtheoradec.so.1` link on `LD_LIBRARY_PATH` (a06161b).
- `get_controls` exports the whole gamecontrollerdb (no RetroForge pad GUID): E2BIG on every exec;
  wrapped as mod_EmuELEC.txt does (1f77eca).
- SDL GLES contexts over GLX on Xwayland are black under gamescope: `SDL_VIDEO_FORCE_EGL` (1911e8c).
- westonpack: its Weston cannot start as player under gamescope (seatd, DRM); mod_RetroForge.txt runs
  the command directly, as westonwrap itself does on ROCKNIX with Mesa, with the port's
  WRAPPED_LIBRARY_PATH behind /usr/lib (0ef5b90, 7f0d556, 0d707a5).
- OGUI's Exit SIGTERMs squashfuse with the game: started with TERM/INT ignored (399c9d5).
- gptokeyb2's libinterpose reports the wrong fd under sdl2-compat (exclusive grab missed):
  apps/retroforge-gptk-interpose preloaded first, libinterpose kept (054fca4, 7f0d556).
Still to do: a clean dev image from main (the image-side changes, openal/libtheora and the
interposer stage, were HW-tested only through /tmp copies); F.

Licence: PortMaster-GUI and PortMaster-New are MIT; gptokeyb/gptokeyb2 GPL-2.0 (downloaded with
PortMaster, not redistributed by RetroForge). Ports and runtimes stay player downloads.

### Phase 4c — Library scaling polish (later, decided 2026-10-04)

Measured 2026-10-04 on the Pocket ACE (plugin timing logs, 2,000 empty `.chd` in `~/roms/psx`):
the ROM scan takes 9 ms, so a scan cache would not help. The cost is OGUI's card UI: its library
menu queues a full refresh per added item (2,001 refreshes, ~24 s of rebuilding after start, each
up to 27 ms), every ROM gets three cards (our tab, All Games, Installed: ~6,000), and OGUI's RSS
goes from 0.4 GB to 1.8 GB (+~240 KB per card, ACE has 7.5 GB). Our tab (0.8 s for 2,000 cards)
is only built after that churn (28 s) and three times. Options, to pick when polishing:
- A. Keep ROMs out of OGUI's lists: register the library (hooks, launch menu) but hand OGUI no
  items; the plugin keeps its own ROM list and builds cards only in its tabs. Loses All Games and
  OGUI search for ROMs (own search needed); reverses "ROM cards show in All Games too".
- B. Lazy cards in our tabs (only what is on screen / page by page).
- C. OGUI patch, upstreamable: coalesce library refreshes (one per batch of adds).
A metadata cache (titles, serials, resume) keyed by path + size + mtime comes with the per-ROM
work that needs it, not before.

### Phase 4d — Dual-screen boards: one gamescope on two panels (planned 2026-10-12)

Detailed plan: [gamescope-dual-output.plan.md](gamescope-dual-output.plan.md), branch
`feat/gamescope-dual-output`. Gamescope drives the bottom panel as a second output (own focus,
own composite, own commits); melonDS / Azahar second windows routed there by title or a
`GAMESCOPE_OUTPUT` property; bottom touchscreen routed by device name. Replaces the DRM-lease
attempt (branch `feat/gamescope-ogc-lease`, not merged: one emulator process cannot span two
gamescopes). Thor Lite first, then Thor and Pocket DS.

### Phase 5 — Release infrastructure (Medium)

- **OGUI's storage screen is dead** (deferred 2026-10-03: only matters once RetroForge runs from
  internal UFS and the SD slot is free for storage; booted from the only SD slot it has nothing to
  manage): its removable-media manager calls
  `/usr/bin/steamos-polkit-helpers/steamos-{format-sdcard,retrigger-automounts,trim-devices}`,
  which Phase 0 removed (guard-forbidden). Decide: ship those three paths as thin wrappers over
  retroforge-format-sdcard / block-event, or accept no Format button.
- **SD automount is ext4-only** (deferred 2026-10-03 with the storage screen: a second card only
  exists to mount once RetroForge runs from internal UFS), inherited from the Steam library requirement that no longer
  applies; ROM cards are usually exfat. Decide whether to automount exfat/vfat too.

- **OS update UI = a RetroForge OSPlatform in OGUI** (noted 2026-10-04, to design with the update
  server). OGUI picks an OS platform from `/etc/os-release` `ID` (hard-coded list in
  `core/global/platform.gd`: steamos, chimeraos, manjaro, nixos, bazzite); its `ready(root)` may
  change the scene tree. The NixOS one (`core/platform/os/nixos.gd`) is the model: it removes OGUI's
  own updater (which on RetroForge only knows the x86 `update.zip`, hence `--skip-update-pack`) and,
  when its `os-updater` script exists, adds an update section to Settings > General: check, apply
  (progress), auto-update toggle and a branch dropdown, all via `Command` on that script.
  For RetroForge: OGUI patch adding `core/platform/os/retroforge.{gd,tres}` + `ID=retroforge` detection,
  driving `retroforge-update` (`check` / apply with `N%` / `channels` / `set-channel`; its contract is
  already OGUI-shaped). Upstreamable like the other distro platforms, and the natural home for
  other RetroForge defaults (theme, startup actions). Replaces "update channel stays CLI/SSH" (Phase 2).
  DONE differently 2026-10-18 (`.claude/plans/ota-ui.plan.md`): no OGUI patch -- the plugin ships
  `retroforge_os.gd` (extends OSPlatform) and installs it as `platform.os` itself, with Updates
  (one button Check/Install/Restart now, Stable/Beta) and Remote access (pairing switch).
- Update server via `ota/setup-server.sh`; replace the `updates.retroforge.invalid` placeholder in
  `retroforge-update`, `installer/release-info`, `installer/netcfg`.
- CI release secrets `RAUC_CERT_PEM` / `RAUC_KEY_PEM` from `~/retroforge-pki`.
- Image / bundle / installer release workflows, runbook.
- Optionally move firmware to a RetroForge-owned repo.

### Phase 6 — Final polish (last, not blocking; decided 2026-10-04)

- **Resume / Start fresh** on a ROM that has a resume state (design in Phase 4 part 2, "Resume
  (decided 2026-10-03)"): `retroforge-launch --resume` mapped per emulator in its conf (DuckStation
  `-resume`), and a per-emulator way to find the state (DuckStation: `~/states/psx/<serial>_resume.sav`,
  so the plugin reads the game's serial from the disc image; the Phase 4c metadata cache would hold it).
- **HW check on the pinned DuckStation v0.1-11894**: memory card saves land in `~/saves/psx` and load
  back, and what DuckStation does with a resume state on the next launch (never verified: every test
  quit during the intro). Do it together with Resume.

## Backlog (outward-facing: send only when decided)

- PowerStation: order SetCoresEnabled by `cpu_capacity` instead of CPU number (Qualcomm numbers
  cores slowest-first; other SoCs do not); plus our patches 0001/0002 (`_ref/PowerStation` retroforge-arm).
- OpenGamepadUI: SENT 2026-10-03 as #559 / #560 / #561; #562 (our patch 0004, apps that exit
  before creating a window) sent 2026-10-04.
- OpenGamepadUI patch 0005 (save the default performance profiles at startup): branch
  `fix/perf-default-profile` in `_ref/OpenGamepadUI`, local only; the user asks the authors on their
  Discord whether it is a real bug before it is pushed to the fork and sent.
- OpenGamepadUI: the library menu queues one full refresh per library_item_added (2,000 items =
  2,001 refreshes, ~24 s); coalesce them (Phase 4c option C).
- DuckStation: AppRun is a symlink, so on a system without Qt, Qt's applicationDirPath misses
  `usr/bin/qt.conf` and no platform plugin loads.

## Risks

| Risk | Likelihood | Mitigation |
|---|---|---|
| OGUI / Godot / GDExtension do not build or run on aarch64 | Resolved | Local PKGBUILD + patches; runs on all three SoCs |
| PowerStation has no Qualcomm backend | Resolved | Upstream PowerStation + our patches 0001/0002 (devfreq GPU, non-SMT cores) |
| Steam-shaped contracts silently broken (update gate, per-game perf, OOBE Wi-Fi) | Low | Phase 2 fixed the known ones; OGUI patch 0005 fixed per-game perf defaults |
| OGUI patches never land upstream | Medium | Each patch carries its upstream branch; drop on release |
| Emulator licensing / aarch64 availability | Medium | Licence allowlist; prefer emulators with arm64 JITs |
| No upstream merges for hardware fixes | Medium | Accepted — RetroForge is standalone |
| SM8250 has no sensor DSP firmware (no auto-rotate) | Certain | Documented |
| GL clients starved by Vulkan games (freedreno GL and Turnip on different drm_sched levels) | Low (UI is Vulkan) | Watch UI/overlay under load; zink per GL emulator (Phase 4b note) |

## Validation

```bash
make test                                   # all offline suites
make test-signing PKIDIR=~/retroforge-pki       # signing chain, in container
make test-disk                              # installer disk suites, in container
make sdcard && make verify-image             # first real build
```
