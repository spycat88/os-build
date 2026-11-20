# RetroArch + RetroAchievements for the pre-PS1 systems (and N64) — plan

Status: decisions D1-D7 AGREED 2026-11-09 (branch plan/retroarch). Phases 0-6 DONE 2026-11-09
(Phase 5 HW-OK on the Pocket ACE, SM8550; Phase 6 HW-OK on the Air X, SM6115); merged to main.

## Why

Players want RetroAchievements. None of today's emulators for the older systems has it:

| Systems | Today (`launch.conf`) | Achievements today |
|---|---|---|
| gb, gbc, gba | armGBA 1.0 standalone (catalog `Jacob-Matthew-Cook/armGBA`, now redirects to `MagnominusGit/armGBA`) | no (1.5 has them, needs libcurl) |
| snes | Snes9x 1.63 GTK + `retroforge-sigdefer` shim | no |
| md, segacd | ClownMDEmu 1.6.12 | no |
| n64 | RMG + GLideN64 | no (upstream feature request still open) |

RetroArch has rcheevos built in. This plan moves all four rows to one RetroArch with one core per
system, and one RetroAchievements sign-in.

## Decisions (agreed 2026-11-09)

| System(s) | Core | Source | Achievements |
|---|---|---|---|
| gb, gbc, gba | **armGBA** (`armgba_libretro.so` + `.info`) | `MagnominusGit/armGBA` release zip `armGBA-<v>-aarch64.zip`, GitHub sha256 digest | yes (memory described as mGBA's / gambatte-libretro's) |
| snes | Snes9x (`snes9x_libretro`) | libretro buildbot nightly linux/aarch64 | yes |
| md, segacd | Genesis Plus GX (`genesis_plus_gx_libretro`) | buildbot | yes |
| n64 (Phase 6) | armN64 (`armn64_libretro`, MagnominusGit v1.3; was Mupen64Plus-Next, D7b/D7c) | GitHub release | yes |

RetroArch itself: `pkgforge-dev/RetroArch-AppImage-Enhanced`, `RetroArch-<v>-anylinux-aarch64.AppImage`
(1.22.2, 35 MB, sharun, GitHub digests), format `appimage-sharun`.

- **D1 Buildbot cores, managed by `retroforge-emu`, Cemu-nightly style.** libretro's core repos tag no
  releases (Genesis Plus GX: none; mupen64plus-libretro-nx: one stale tag; libretro/snes9x: 1.52/1.53),
  and `buildbot.libretro.com/nightly/linux/aarch64/latest/` keeps no history, so a pin would point to a
  file gone the next night. So: no tested pin (`--tested` refused for them, the page shows "Nightly
  <date>"); the build id is the date + CRC32 from `latest/.index-extended`; downloads are https only and
  CRC-checked; the previous `.so` stays on the device for `rollback`. No CI repo of our own: it would
  only add a re-installable tested build and a sha256 known in advance, for three cores that change
  rarely. Revisit if Phase 0 finds a core that will not load, or if a bad nightly ever bites.
  armGBA and RetroArch keep the normal catalog model (latest by default, pin = tested, Revert).
- **D1b RetroArch's Online Updater stays OFF** (user 2026-11-09: players must not install cores for
  other systems). The seed hides it, the core updater and Load Core; the cores folder is ours. A `.so`
  copied in by hand over SMB/SSH can still be loaded from RetroArch's content browser: not offered by
  the UI, not blocked.
- **D2 Mega CD on RetroArch, BIOS required.** Genesis Plus GX needs `bios_CD_U.bin` / `bios_CD_E.bin` /
  `bios_CD_J.bin` in the flat `~/bios` (ClownMDEmu needed none: a regression, accepted). A segacd game
  without the BIOS gets a clear "BIOS missing" message, not a black screen.
- **D3 Hardcore off by default**, a toggle in the plugin. Hardcore blocks state loading, rewind, slow
  motion and cheats, so Guide+L1 would stop working.
- **D4 No 32X now.** PicoDrive would bring it back, with achievements: a follow-up.
- **D5 No new systems now** (NES, SMS, GG, PCE, ...): each is a core + ROM folder + `launch.conf` line
  once this plan is done.
- **D6 armGBA as a core inside RetroArch**, not the standalone app: one frontend, one sign-in, same
  hotkeys and options; armGBA's speed (the reason it replaced mGBA) is kept. armGBA is not on the
  buildbot, so it is a catalog asset.
- **D7 N64 moves too, in its own phase (Phase 6)**, after the pre-PS1 systems are HW-OK. Same mupen64plus
  core and GLideN64 as RMG, so the A610 should cope. If Phase 0/6 measures it slower than RMG on the
  A610, N64 stays on RMG without achievements.
- **D7b (2026-11-09, change of plans) N64 core = armN64** (MagnominusGit/armN64 v1.1, GPL-2.0), not
  Mupen64Plus-Next: a GitHub catalog core like armGBA, its own core-option defaults (Fast/HLE, GL
  renderer, no seeded options file). Achievements: SET_SUPPORT_ACHIEVEMENTS + RDRAM as
  RETRO_MEMORY_SYSTEM_RAM in mupen64plus-next's word order. Reverted the same day (0c0ab264): bad on the
  SM6115.
- **D7c (2026-11-17, retest) armN64 1.3 + RetroArch's GL driver for N64 only.** armN64 has no Vulkan
  renderer (GL, GPU = GL compute, CPU). It shares the frontend's context only when
  GET_PREFERRED_HW_RENDER says GL; beside Vulkan it makes its own GL context and hands RetroArch a
  software frame read back at native size every frame: CPU and GPU wait on each other (neither busy,
  still slow) and Resolution never reaches the screen. That was the 2026-11-09 SM6115 result, not the
  core. Fix: seed a per-core override `config/armN64/armN64.cfg` = `video_driver = "glcore"`
  (auto_overrides_enable is on by default); every other system stays on Vulkan. HW 2026-11-17, Air X
  (A610): Super Mario 64 at 2x, 60 fps, no crackle, main thread ~27% of one core.

## What we know (2026-11-09)

- Stable buildbot has no linux/aarch64 (`/stable/1.22.2/linux/` = x86, x86_64); nightly has
  `RetroArch.7z` and every core we need in `latest/`.
- The sharun AppImage path is already handled: `launch_formats.py:146` `SharunAppImage` links the
  hardcoded paths, forces the image's Turnip (`SHARUN_ALLOW_SYS_VKICD=1`, `VK_DRIVER_FILES`) and keeps
  the self-updater off (`DISABLE_AUTO_UPDATES=1`).
- armGBA core needs glibc >= 2.34; whatever glibc sharun bundles is what the `dlopen` sees.
- RetroArch 1.22.2 sorts saves by core or content dir, not by our system folder: we rewrite
  `savefile_directory` / `savestate_directory` per game, as armGBA's `system_settings` does today.

## Patterns to mirror

| Category | Source | Pattern |
|---|---|---|
| Launch definition | `rootfs/overlay/usr/share/retroforge/emulators/armgba/emulator.json` | notes[], format, binary, args, gui_args, seed, `system_settings` rewriting folders per game |
| Per-system args | `rootfs/overlay/usr/lib/retroforge/python/launch_def.py:19` | `system_args` = per-system `-L <core>` |
| Sharun AppImage | `rootfs/overlay/usr/lib/retroforge/python/launch_formats.py:146` | no AppRun, hook links, system Vulkan ICD |
| Rolling builds | `rootfs/overlay/usr/bin/retroforge-emu` header (ROLLING TAGS / NO TESTED BUILD) | `<tag>-<id>` naming, `--tested` refused, previous kept for rollback |
| Errors | `retroforge-emu` | exit 0/2/3/4/5/6, progress + JSON on stdout only, the rest on stderr |
| Catalog | `rootfs/overlay/usr/share/retroforge/catalog.json` | github, tag, tag_pattern, asset, sha256, size, licence |
| Account sign-in | `apps/ogui-retroforge-plugin/plugin/scraper_settings.gd:81` | user + secret password rows, password handed to a tool, never kept by the plugin |
| Hotkeys | `emulators/*/guide-hotkeys.yaml` | Guide + L1/R1/R2/Start -> F1-F4, bound in the seeded config |
| Options | `emulators/*/options.json`, `emuopts.py` | common set, per-game .conf |
| Source compliance | `.github/emu-sources.json` | upstream repo + tag -> ref |
| Tests | `tests/test-emu.sh`, `tests/test-launch.sh`, `tests/test-catalog.sh`, `tests/test-emuopts.sh`, `tests/test-key-drift.sh` | shell tests, offline by default, `RETROFORGE_NET_TEST=1` for live |

## Phase 0 — HW spike (no commits but notes here)

On the weakest board (A610/SM6115, Air X) and one SM8250 (Pocket Max), RetroArch AppImage pushed by
hand to `~/emulators/retroarch`, cores by hand:

1. RetroArch runs mounted through `SharunAppImage` on our Turnip under gamescope: pick `vulkan` vs
   `glcore` (and `gl`/GLES for GLideN64), and the audio driver (pipewire vs pulse).
2. All four cores `dlopen` inside the sharun process (buildbot glibc, armGBA's >= 2.34).
3. SIGTERM (OGUI's Exit) = normal exit with SRAM written; no dialog; no `SDL_NO_SIGNAL_HANDLERS`
   needed.
4. The InputPlumber Elite pad is auto-configured (autoconfig, assets, core-info present in the
   AppImage, or what to seed).
5. armGBA core vs armGBA standalone speed on the A610; Mupen64Plus-Next vs RMG on the A610, same games.
6. Sign in, unlock one achievement in softcore and one in hardcore.
7. Walk RetroArch 1.22's menus with D1b settings: list every path that installs a core (Core Manager,
   Restore Backup, ...) and the key that hides it.
8. Genesis Plus GX Mega CD with and without the BIOS: what the player sees.

GATE: 1, 2 or 3 failing stops the plan. 5 failing for N64 drops Phase 6 (D7).

### Phase 0 notes (2026-11-09, Air X MQ66 = A610, dev image 78354ddb, kernel 7.3.3, 192.168.1.100)

Set-up (gone at reboot): bind mounts over `/usr/share/retroforge/emulators` (+ `retroarch/` spike
definition), `/usr/share/retroforge/catalog.json` (+ `retroarch` entry) and `/etc/retroforge/launch.conf`
(gb/gbc/gba/snes/md/segacd/n64 = retroarch); AppImage as `~/emulators/retroarch/<tag>.AppImage`, cores
by hand in `cores/`. `retroforge-emu list` sees it installed = tested.

- Downloads: AppImage and armGBA zip match GitHub's sha256 digests. Buildbot `.index-extended` CRC32 is
  the CRC of the `.so` INSIDE the zip (= the zip member's CRC), not of the zip: Phase 1 checks the
  unpacked core.
- AppImage (DwarFS, uruntime): bundles glibc **2.43**, Mesa 26.2.6 (Arch) for GL/EGL/gbm, SDL2/3,
  PipeWire, Pulse, ALSA. `share/retroarch` holds only `filters`: NO assets (ozone/xmb unusable ->
  `menu_driver = rgui`), NO autoconfig, NO core info, NO database. RetroAchievements compiled in
  (`cheevos_*`, `dorequest.php`). Build's `core_updater_buildbot_cores_url` is empty: its Online
  Updater cannot fetch cores anyway (D1b holds even before hiding it).
- Cores (readelf): armGBA glibc 2.34 (libz, libstdc++); Snes9x 2.33; Genesis Plus GX 2.33;
  Mupen64Plus-Next 2.34 and **libGL.so.1** (desktop GL; no GLES build on the aarch64 buildbot) ->
  N64 needs RetroArch's `gl`/`glcore` driver, on the bundled Mesa GL as RMG does today. Step 2 OK on
  paper (2.43 >= 2.34); real `dlopen` per core still to see with a game.
- Step 1 OK (menu): `video_driver = vulkan` -> "Turnip Adreno (TM) 610" through the launcher's
  `SHARUN_ALLOW_SYS_VKICD`, X11 (Xwayland) fullscreen 1920x1080, 3 swapchain images; `audio_driver =
  pipewire` -> Speaker sink. Harmless noise: GameMode, xdg-screensaver, MIDI /dev/snd/seq.
- Step 4 pad: seeded `autoconfig/sdl2/RetroForge pad.cfg` matched by vid/pid 1118/2816 ("Xbox One
  Elite 2 Controller configured in port 1"). Buttons not yet checked on screen.
- Step 3 OK (menu): ONE SIGTERM to RetroArch (what OGUI's Exit sends; the launcher never forwards) ->
  normal exit in ~800 ms, config + playlists written, launcher returned, mount released.
  `quit_press_twice` does not apply to signals. No `SDL_NO_SIGNAL_HANDLERS` / `exit_resend` needed.
- RetroArch rewrites the cfg on exit (3377 lines) and keeps our keys; it writes paths back as `~/...`.
- Games from OGUI cards (user: "everything seems to work"; history playlist confirms the core per
  system): gba TMNT (armGBA core, .7z), snes Super Mario All-Stars (Snes9x), md Kunio (Genesis Plus
  GX), n64 Super Mario 64 (Mupen64Plus-Next; RetroArch switched to a GL context for it by itself
  with `video_driver = vulkan`). All four cores `dlopen` fine: step 2 OK. SRAM written (gba, snes);
  Guide hotkey save states written (snes, md).
- FOUND: `sort_savefiles_enable` / `sort_savestates_enable` default to true -> saves landed in
  `~/saves/<system>/<core name>/` (`armGBA/`, `Snes9x/`, `Genesis Plus GX/`). Must be "false" in the
  seed AND in `system_settings` (RetroArch writes its in-memory value back on exit). Spike fixed,
  test files moved up.
- Mupen64Plus-Next writes `Mupen64plus/mupen64plus.ini` + `shaders/` into `system_directory`
  (= the flat `~/bios`): ACCEPTED (user 2026-11-09).
- Step 5 OK (user 2026-11-09): N64 speed on the A610 is fine -> D7 holds, Phase 6 stays. More
  emulator-default and per-ROM options later, if needed.
- Save states: no migration, old states may break (user 2026-11-09). SRAM: no migration either (user 2026-11-09).
- Menu: Select+Start opens RGUI in game (`input_menu_toggle_gamepad_combo = 4`), HW-OK.
- Step 6 MOVED to Phase 3/5 (user 2026-11-09: not expected to fail): the `retroforge-cheevos` sign-in
  and one unlock are tested there anyway.
- Step 7 (from the written cfg): Online Updater and Load Core hidden. NO menu path downloads a core:
  this build's `core_updater_buildbot_cores_url` is empty. What is left needs a `.so` already on disk
  or deliberate tinkering: Settings > User Interface > Menu Item Visibility can show Load Core again
  ("Install or Restore a Core" from a file), Settings > Directory can move the cores folder, Settings
  > Core > Manage Cores backs up / restores / deletes existing cores. DECISION: leave those settings
  visible (kiosk mode would also hide Achievements); seed `core_updater_buildbot_cores_url = ""`
  explicitly so a later build that sets it changes nothing.
- Step 8 + segacd, gb/gbc: MOVED to the Phase 5 card (no disc, BIOS or GB game on the Air X).

PHASE 0 DONE 2026-11-09: gate passed (steps 1-3 OK). Next: Phase 1.

## Phase 1 — catalog and `retroforge-emu`

- `catalog.json`: new `retroarch` entry (pkgforge AppImage, tag_pattern `^[0-9][0-9.]*@...$` as
  Azahar's) with:
  - `cores`: `{"armgba": {github MagnominusGit/armGBA, tag, tag_pattern, asset ^armGBA-[0-9.]+-aarch64\.zip$,
    sha256, size, files: [armgba_libretro.so, armgba_libretro.info]}, "snes9x": {"buildbot":
    "snes9x_libretro.so.zip"}, "genesis_plus_gx": {...}}` (mupen64plus_next added in Phase 6).
  - Only the cores `launch.conf` maps to `retroarch` are listed (D1b).
- `retroforge-emu`:
  - `install retroarch` installs the AppImage, then every core into `~/emulators/retroarch/cores/<core>/<id>/`,
    `current` symlink per core, previous kept (same `activate()` logic).
  - buildbot core: fetch `latest/.index-extended`, take the row, download over https, unzip ONE member
    (`<core>_libretro.so`, `safe_relative`), check CRC32, id = `nightly-<date>-<crc>`.
  - GitHub core: the existing tested/latest path, unzip the named files only.
  - `check` / `list` report each core; `rollback retroarch [--core <c>]`; `remove` removes cores too.
  - Entries no longer in the catalog (armgba, snes9x, clownmdemu, later rmg): NOT handled, no cleanup
    of old installs on devices (user 2026-11-09).
- `.github/emu-sources.json`: retroarch (libretro/RetroArch, tag -> v<ver>), armgba core
  (MagnominusGit/armGBA); buildbot cores point at their libretro repos (master).
- Validate: `tests/test-emu.sh` new cases (core install, CRC mismatch -> exit 4 and nothing changed,
  missing index row -> exit 3, per-core rollback, zip with extra/evil members refused),
  `tests/test-catalog.sh` (schema + live with `RETROFORGE_NET_TEST=1`).

### Phase 1 notes (2026-11-09)

- Code: `rootfs/overlay/usr/lib/retroforge/python/emu_cores.py` (new) + `retroforge-emu` (install
  split into `cmd_install` + `install_build`, `emit()`/`SCALE` progress 0-80 AppImage, 80-99 cores,
  one 100%; `list`/`check` "cores"; `rollback <emu> --core=<core>`; check cache shared via `cached()`).
- Layout as built: `core-builds/<core>/<build>.so` + `cores/<core>_libretro.so` -> relative link
  (RetroArch sees normal core file names in `libretro_directory`). Only the `.so` is installed, never
  the `.info` (Phase 0: RetroArch runs fine without core info).
- `--tested`: GitHub core = its pin; buildbot core = installed only when missing, never moved.
- Tests: new `tests/test-emu-cores.sh` (46, offline, in `make test`); `test-emu.sh` 151,
  `test-catalog.sh` 204 (+ cores schema via the shipped `emu_cores.specs`, aarch64 zip asset,
  emulator.json `-L` cores == catalog cores, live core pins + newest), `test-launch.sh`,
  `test-plugin.sh`, `test-steam-install.sh` green. Live `retroforge-emu check` with the real pins:
  armgba v1.5, buildbot nightly-2026-11-07-<crc> x3.
- MOVED to Phase 2: the real `retroarch` catalog entry (test-catalog requires its emulator.json and
  launch.conf mapping, so they ship together) and `.github/emu-sources.json` (key drift needs
  options.json).
- `retroforge-emu` is 836 lines (was 784): over the 800 limit; candidate split = the unpack code.

## Phase 2 — launch definition and seeds

- `rootfs/overlay/usr/share/retroforge/emulators/retroarch/`:
  - `emulator.json`: format `appimage-sharun`, binary from Phase 0, args
    `-f --config /home/player/.config/retroarch/retroarch.cfg {rom}`; `system_args` per system =
    `-L /home/player/emulators/retroarch/cores/<core>/current/<core>_libretro.so`;
    `system_settings` rewriting `savefile_directory` / `savestate_directory` to `~/saves/{system}` /
    `~/states/{system}`; gui_args = RetroArch's menu.
  - `retroarch.cfg` seed (comments in the notes, RetroArch rewrites the file): drivers from Phase 0;
    `system_directory = ~/bios`; `libretro_directory` / `libretro_info_path` = our cores folder;
    `menu_show_online_updater = false`, `menu_show_core_updater = false`, `menu_show_load_core = false`
    + whatever Phase 0 step 7 found; `cheevos_enable = true`, `cheevos_hardcore_mode_enable = false`;
    `config_save_on_exit` kept on (menu changes stick; our keys are rewritten per game anyway).
  - Hotkeys: `input_load_state = f1`, `input_save_state = f2`, `input_hold_fast_forward = f3`,
    `input_exit_emulator = f4`, `quit_press_twice = true`; `guide-hotkeys.yaml` as the other emulators'.
  - Core options seed (`retroarch-core-options.cfg` or per-core): armGBA's BIOS / boot ROM choices
    carried over from `armgba/frontend.cfg`.
  - `options.json`: the common set mapped to cfg / core-option keys (emulator-options plan).
- Missing BIOS (D2) and missing core: the launcher checks before starting and shows a message.
- `launch.conf`: gb, gbc, gba, snes, md, segacd -> `retroarch`.
- Validate: `tests/test-launch.sh` (core per system, folder rewrite, missing-core/BIOS message),
  `tests/test-emuopts.sh`, `tests/test-key-drift.sh`.

### Phase 2 notes (2026-11-09)

- 2a COMMITTED 9c4a1a16: emulator.json `system_requires` ({system: [{"any": [paths under $HOME],
  "status": missing-file|not-installed}]}), checked before a game starts (never --gui); plugin
  0.1.108 names every choice of a missing-file status ("needs one of ...").
- 2b: `emulators/retroarch/` (emulator.json, retroarch.cfg, retroforge-pad.cfg, guide-hotkeys.yaml,
  options.json: aspect 22/24, integer scale, filter, VSync, frame rate); catalog `retroarch` entry
  with cores armgba (v1.5 pin), snes9x, genesis_plus_gx; launch.conf gb/gbc/gba/snes/md/segacd ->
  retroarch (n64 stays rmg until Phase 6); emu-sources `retroarch`.
- PULLED IN from Phase 4 (dead once launch.conf moved): `emulators/{armgba,snes9x,clownmdemu}` and
  their catalog / emu-sources rows deleted, ClownMDEmu's tmpfiles links dropped, their test-launch
  seed checks replaced by RetroArch's. Still Phase 4: sigdefer shim,
  docs (no save migration, user 2026-11-09).
- Seed autoconfig renamed `retroforge-pad.cfg` (no space in the path).
- 2b COMMITTED 0f9746ef. `make test`: everything green but test-hw-dtb (2 backlight pins on the
  Retroid Flip 2 / RP5 Visionox DTBs from work/, unrelated to this branch).
- 2c COMMITTED f5202c43 (plugin 0.1.109): emu_state.gd reads "cores" (newer core = Update, missing
  core = Repair naming it, a Revert row per core with a kept build); apps_page.gd reverts with the
  row's own args (--core=). FIXED there: 9c4a1a16's library_roms.gd did not parse (loop var `path`
  shadowed a local) -- caught by compiling against OGUI; test-plugin.sh now parses every plugin
  script when RETROFORGE_OGUI_PROJECT is set (526 passed with it).
- Phase 2 HW check still to do (Air X off the network): a game per system from a dev image or the
  spike, Repair after deleting a core, a core Revert from the Apps page.

## Phase 3 — RetroAchievements sign-in

- New `/usr/bin/retroforge-cheevos login|logout|status`: password on stdin only; POST
  `https://retroachievements.org/dorequest.php` `r=login2` (https only, `RetroForge/<version>`
  User-Agent, curl like `retroforge-emu`); writes ONLY `cheevos_username` + `cheevos_token` into
  `retroarch.cfg` (0600, atomic replace), never the password; `hardcore on|off`. Exit codes in the
  `retroforge-emu` style; no secret in logs or errors.
- Plugin: Settings > Library > RetroAchievements (user, password, signed-in state, Sign out, Hardcore
  toggle), mirroring `scraper_settings.gd`; plugin version bump.
- Validate: new `tests/test-cheevos.sh` with a local fake server (good login, bad login, token written,
  password never on disk, cfg perms); plugin Godot suite (see the plugin-godot-tests memory).
- Security review of the helper and the plugin rows before commit.

### Phase 3 notes (2026-11-09)

- `retroforge-cheevos login|logout|hardcore on|off|status` (exit 0/2/3/5/7/8). Live check against
  retroachievements.org with a made-up account: HTTP 401 `"Code":"invalid_credentials"` -> exit 7,
  nothing written; the `RetroForge/<VERSION_ID> retroforge-cheevos` User-Agent is accepted.
- Writes only cheevos_username (the name RetroAchievements answers with) + cheevos_token, empties
  cheevos_password, sets cheevos_enable; retroarch.cfg 0600 before the token; seeded from the image
  when missing; refused while RetroArch runs (it rewrites the file on exit).
- Plugin 0.1.110: Settings > Library > RetroAchievements (cheevos_settings.gd: user, password on
  stdin via scrape_runner.gd, Sign in/out, Hardcore toggle), wording in cheevos_text.gd (stock-Godot
  tested). Tests: tests/test-cheevos.sh (38, in make test), test-plugin.sh 543 with OGUI.
- Security review (no CRITICAL/HIGH), all fixed: umask 077 in the tool (write_atomic's temp file
  held the token at the default mode), RetroArch also detected by comm / ld.so argument, the running
  check repeated after the request, curl -q (no ~/.curlrc), control characters stripped from the
  server's Error. Tests 43.
- HW still to do (Phase 5): sign in with a real account, one unlock, hardcore refuses Guide+L1,
  check retroarch.cfg's mode after RetroArch rewrote it on exit (if 0644: the launcher must chmod it
  back after a RetroArch game -- the token would be world-readable).

## Phase 4 — removal

- Delete `emulators/{armgba,snes9x,clownmdemu}`, their catalog and emu-sources rows, the ClownMDEmu
  `Save Data` rows in `user-tmpfiles.d/retroforge-home.conf`, `apps/retroforge-sigdefer`,
  `rootfs/lib-assemble-sigdefer.sh`, `tests/test-sigdefer.sh` (re-check nothing else preloads it) and
  their rows in `Makefile`, `rootfs/assemble-rootfs.sh`, `.gitignore`; named cases in
  `launch_def.py`, `launch_formats.py`, `emuopts.py`, `retroforge-launch`, tests,
  `packages/inputplumber/PKGBUILD` (testbed reference).
- Existing devices: nothing is touched (user 2026-11-09): old `~/emulators/<old>` installs stay
  where they are, never removed by RetroForge. No save migration at all (user 2026-11-09): neither SRAM nor states are converted or renamed;
  armGBA's `<rom>.srm` happen to match RetroArch's names, Snes9x/ClownMDEmu saves may not load.
- Seed + `system_settings`: `sort_savefiles_enable = "false"`, `sort_savestates_enable = "false"`
  (Phase 0: per-core subfolders otherwise).
- Docs: README row 3, `retroforge.plan.md` notes, RUNBOOK.

### Phase 4 notes (2026-11-09)

- DONE: `apps/retroforge-sigdefer`, `rootfs/lib-assemble-sigdefer.sh`, `tests/test-sigdefer.sh` and
  their Makefile / assemble-rootfs.sh / .gitignore rows removed (Snes9x was its only user); the
  launcher's core_dumps comment no longer names it. README row 3 says what ships now.
  The emulator definitions, catalog rows and tmpfiles links went in Phase 2b. Nothing on devices
  is touched (no cleanup, no save migration).

## Phase 5 — HW validation, merge, push

Dev image (`source dev.env`), A610 + SM8250: a game per system boots; saves land in `~/saves/<system>`;
Guide hotkeys; clean Exit; per-core and RetroArch Revert; sign-in + one achievement; Mega CD with and
without BIOS; no menu path installs a core. Then merge (ff) and push.

DONE 2026-11-09 on the Pocket ACE (SM8550, dev image fea75717, plugin 0.1.110):
- Apps > RetroArch > Download installed RetroArch 1.22.2 + armGBA v1.5 + Snes9x and Genesis Plus GX
  nightlies (2026-11-09 / 2026-11-07); `retroforge-emu check retroarch` resolves all four on the device.
- Games: GBC (Tetris DX) + GBA (TMNT, from .7z) on armGBA, SNES (Super Mario All-Stars) on Snes9x,
  MD (Kunio) + Mega CD (Sonic CD) on Genesis Plus GX. Saves flat in `~/saves/<system>` (Mega CD:
  `scd_U.brm` + `4Mbit_cart.brm`). Guide hotkeys, OGUI Exit and hardcore (Guide+L1 refused) OK (user).
- Mega CD without `bios_CD_*.bin`: refused with "segacd needs ~/bios/bios_CD_U.bin or ... (not found)".
  Mega CD lists `.chd`/`.cue` only: a `.7z` disc is not shown (RetroArch unpacks one member, a CD
  needs the .cue + every track), so Sonic CD was unpacked to `.cue` + 35 `.bin` for the test.
- RetroAchievements: sign-in from Settings > Library; RetroArch showed "logged in as" at game start.
  `retroarch.cfg` stays 0600 with name + token after RetroArch's exit rewrite (no launcher chmod
  needed); `cheevos_password` stays empty.
- Core deleted (link + build) -> the game is refused (`not-installed retroarch`) and the Apps page
  offers Repair; Repair downloaded it and the game ran. Core Revert (a planted older build) swapped
  the builds; the row then offers the swap back, as RetroArch's own Revert does.
- Not seen on the ACE: speakers silent while PipeWire plays (both WSA884x UNATTACHED on SoundWire);
  not caused by this branch (user: not new).

## Phase 6 — N64 (D7, D7b)

- Catalog: add `armn64` (GitHub `MagnominusGit/armN64`, asset `armn64_libretro-<ver>-aarch64.zip`, pin
  v1.3). No options file: armN64's defaults; armN64.cfg per-core override for the GL driver (D7c). (First cut 4ca16cb1 used Mupen64Plus-Next from the buildbot
  with a seeded GLideN64/HLE/dynarec .opt and RetroArch's GL driver switch; replaced before any HW run.)
- Pad: RetroArch autoconfig + core layout (C buttons on the right stick, Z on L2; R2 + face buttons = C
  buttons) replace RMG's seeded Profile 0.
  R2 becomes a real hold fast-forward.
- Saves: no migration (user 2026-11-09): RMG's `.eep/.sra/.fla/.mpk` stay where they are, the core
  starts fresh `<rom>.srm` files. States do not carry over.
- Remove `emulators/rmg` + catalog/emu-sources rows + named tests.
- `launch.conf`: n64 -> retroarch.
- HW: the Air X games that run on RMG at the same speed, one SM8250/SM8550 game, one achievement,
  clean Exit.

DONE 2026-11-09 (HW-OK on the Air X, SM6115/A610, user: "it's fine"): Download installed four cores
(mupen64plus_next nightly-2026-11-09-224c9ab0); first run seeded Mupen64Plus-Next.opt (GLideN64, HLE,
dynarec); Super Mario 64 ran on glcore (RetroArch's switch; the main thread ~50% of one core), RetroAchievements
signed in, `<rom>.srm` written to ~/saves/n64 on Exit, `~/bios/Mupen64plus` created (accepted). RetroArch
writes video_driver = glcore into retroarch.cfg while the N64 game runs, but the next game (armGBA) was back
on vulkan (Turnip loaded): the switch does not stick. Vulkan for N64 = paraLLEl-RDP (in the buildbot core),
not the default (A610; no per-SoC defaults): Quick Menu > Core Options per game. armN64 tried in between
(D7b), reverted. Pocket ACE: a dead pad after boot was InputPlumber losing the re-enumerated xpad (not this plan).

## Risks

| Risk | Level | Mitigation |
|---|---|---|
| Buildbot core will not load in the sharun RetroArch (glibc) | HIGH | Phase 0 step 2; fall back to a CI repo of our own (D1 revisit) |
| Bad buildbot nightly reaches players (no tested pin) | MED | Update is on demand only; per-core rollback keeps the previous `.so` |
| AppImage lacks assets / autoconfig / core-info | MED | Phase 0 step 4; seed or catalog `data` |
| Mega CD now needs a BIOS | MED | D2 message; docs |
| Players lose saves and save states (no migration, user decision) | MED | Documented in the release notes |
| A menu path still installs cores (D1b) | LOW | Phase 0 step 7 + Phase 5 check |
| RetroArch writes its cfg on exit, undoing our keys | LOW | Rewritten before every game (armGBA pattern) |
| RetroAchievements token leak / password on disk | MED | Token only, 0600, stdin password, security review |
| Mupen64Plus-Next slower than RMG on A610 | MED | Measured; N64 stays on RMG (D7) |

## Acceptance

- [ ] Phase 0 notes recorded here, gate passed
- [ ] gb/gbc/gba/snes/md/segacd run on RetroArch, HW-OK on A610 + SM8250
- [ ] One achievement unlocked on HW; hardcore toggle works
- [ ] armgba/snes9x/clownmdemu/sigdefer gone from the image (no cleanup on devices, no save migration)
- [ ] Offline tests green (`tests/test-emu.sh`, `test-launch.sh`, `test-catalog.sh`, `test-emuopts.sh`,
      `test-key-drift.sh`, `test-cheevos.sh`, plugin suite)
- [x] Phase 6 done or dropped by the D7 rule
