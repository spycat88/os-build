# Plan: one gamescope on two panels (dual-screen boards)

**Complexity**: Large
**Branch**: `feat/gamescope-dual-output` (off `main` at 479d84d)
**Status** (2026-10-12): steps 0-6 done and HW-verified on the Thor Lite dev image: two outputs,
window routing, both panels on direct scanout (kernel 0397 + gamescope 0044), bottom touchscreen
routed, melonDS seeded for two screens on dual-screen boards with its second-window menu hidden,
one OGUI Exit ends it (exit_resend: SIGTERM, then SIGKILL of the emulator alone). Open: touch
landing not yet confirmed, Azahar re-check with the dual seed, step 7 (bottom panel off when unused),
Thor / Pocket DS device values.
**Targets**: AYN Thor Lite (top DSI-1, bottom DSI-2 1080x1240, `bottom_touchscreen`), AYN Thor
(SM8550, panels the other way round: top DSI-2, bottom DSI-1 per ROCKNIX/Armada), AYANEO Pocket DS.
Every single-panel board must behave exactly as today.

## Why

NDS/3DS emulators (melonDS, Azahar) put the second screen in a **second top-level window of the
same process**. One X11 client can only talk to one Xwayland, so a second gamescope on a leased
panel cannot show it (that is what the lease branch hit; Armada and Bazzite don't do it either:
melonDS `Window1` off, Azahar hybrid layout). The lease setup also broke OGUI (it picked the
second gamescope's Xwayland as primary). One gamescope that drives both CRTCs removes both problems.

## Prior art (researched 2026-10-12)

- Upstream: #211 / #227 "one vblankmanager/composition step per output", never built, never
  refused. PR #2344 (open) spans several CRTCs with one cropped framebuffer in one commit (tiled
  monitors). Nobody drives two independent panels from DRM gamescope.
- 3.16.31 (our base) already has **virtual connectors**: `g_VirtualConnectorFocuses`, per-focus
  `paint_all(pFocus)` and `Present`, per-connector held commits, upscaler, fade, mangoapp, touch
  following the mouse-focus connector. Wired only for the OpenVR and nested Wayland backends
  (`UsesVirtualConnectors()` is false for DRM).
- ROCKNIX does dual screen under **sway**: title rules
  (`.*(Secondary|\[w2\]|Sub|Bottom|Screen 2|GamePad).*` -> second output), `map_to_output` per
  touchscreen, touch on a separate seat; melonDS `Screen1Enabled=1 Screen1Layout=2 ScreenSizing=4
  Screen1Sizing=5` plus a patch so `-f` fullscreens every window; Azahar `layout_option=4`.
- Window titles to match: melonDS prefixes `[w1] ` / `[w2] ` when it has several windows; Azahar
  ends the titles with `| Primary Window` / `| Secondary Window`. Neither picks a QScreen itself.

## Decisions

| Decision | Choice | Why |
|---|---|---|
| Model | A second **output** with its own focus, its own composite and its own commits | Panels are not genlocked. One commit for both would hold the top game's flip until the bottom vblank |
| Rejected: one tall canvas cropped across both CRTCs (PR #2344 style) | No | Forces composition every frame on the top panel; drops direct scanout and our pre-rotation series; one rotation for both |
| Rejected: global `--virtual-connector-strategy PerAppId/PerWindow` | No | Both emulator windows share one app id; the strategy also changes overlay/input behaviour of the main screen |
| Bottom panel scanout | Direct scanout first, the plane rotating/scaling an app buffer with the output's aspect (0044); composited otherwise | HW-clean on SM8250's shared offline rotator once kernel 0397 stopped the SSPP handover race |
| Bottom panel plane | Its primary plane is **reserved and never registered with libliftoff** | libliftoff writes `FB_ID=0/CRTC_ID=0` on every registered plane it does not own (`plane.c:367`) on each apply; a second liftoff output would drag both CRTCs into every commit (`apply_current`, `alloc.c:569`) |
| Window routing | Title regex (default covers melonDS `[w2]` and Azahar `Secondary Window`) **plus** a `GAMESCOPE_OUTPUT` window property that overrides it | Works with unmodified emulators; the atom is there for anything else |
| Main screen | Unchanged: OGUI focus atoms, overlay/QAM, mangoapp, screenshots, PipeWire, fps limiter, rotation and colour patches stay on the top output | Smallest behaviour change; OGUI needs nothing |
| Bottom panel colour management (0014/0018) | Skipped in v1 | Night mode on the bottom panel needs its own CRTC colour state (later step) |
| Clock | v1: bottom repaints inside the existing loop with one flip in flight, never blocking. v2: a second `CVBlankTimer` | The session runs both panels at 60 Hz (top is 120 Hz capable, spike 0.1); v1 is enough while it does |
| Base tree | Valve 3.16.31 as on `main` (NOT the OGC fork of the lease branch) | Virtual-connector work is in Valve's tree; OGC was only taken for the lease |
| Patch style | New series `0040`+ in `packages/gamescope/patches`, developed as commits in a git checkout and exported with `git format-patch`; each patch builds alone and is a no-op without `--secondary-output` | Bisectable; single-panel boards stay identical |

## Gamescope interface (new flags)

- `--secondary-output <connector>`: drive this connector as output 2 (e.g. `DSI-2`). Without it
  nothing in the series changes behaviour.
- `--secondary-touch-device <input name>`: route this touchscreen to output 2 (e.g.
  `bottom_touchscreen`). Other touchscreens stay on output 1.
- `--secondary-window-title <regex>`: windows whose title matches go to output 2. Default
  `^\[w2\] |\| Secondary Window$`.
- Window property `GAMESCOPE_OUTPUT` (CARDINAL, 0 = main, 1 = secondary): overrides the title rule.

## Steps

Each step ends with a build of the overlay package and, where marked, a HW check. Thor Lite dev
image (root@192.168.1.125) for dual-screen, ACE / FIT / Pocket Max for single-panel regression.
Rootfs is read-only on cards: test a new gamescope by `mount --bind` over `/usr/bin/gamescope`.
Line numbers below are in the patched 3.16.31 tree (`work/overlay-build/aarch64/gamescope/src/gamescope/src`).

### 0. Spikes on hardware (before any gamescope code)

**Results 2026-10-12 on the Thor Lite (dev image 03e3661, root@192.168.1.155):**
- 0.1 PASSED. Python/ctypes libdrm spike (no compiler on the card), session stopped: DSI-1
  (conn 36, CRTC 94, primary plane 46, 1080x1920, preferred mode **120 Hz**) and DSI-2 (conn 39,
  CRTC 95, plane 52, 1080x1240 @ 60 Hz) modeset together, then 10 s with one
  `NONBLOCK|PAGE_FLIP_EVENT` commit per CRTC in flight: 1186 flips (118.6/s) and 600 flips
  (60.0/s), 0 EBUSY, 0 errors, commit ioctl median 0.1 ms / max 0.25 ms, DSI-2 intervals
  16.66-16.68 ms. Phase between the panels drifted 2.7 -> 8.1 ms: not genlocked, and msm does
  not serialise commits on the two CRTCs. Separate commits per CRTC confirmed.
- The panels can run at **different refresh rates** (top 120 Hz capable; the session pins `-r 60`).
  Do not assume equal rates anywhere; the step 8 second vblank timer matters if the top ever
  runs at 120 Hz.
- 0.2 melonDS 1.1 with `[Instance0.Window1] Enabled = true` (created at startup, no ROM needed):
  both windows are plain top-levels, `WM_CLASS melonDS`, `_NET_WM_WINDOW_TYPE_NORMAL`, **no
  `WM_TRANSIENT_FOR`** (despite the Qt parent), static gravity without `PPosition` (not a
  gamescope dropdown). Titles `[w1] melonDS 1.1` / `[w2] melonDS 1.1`, in game
  `[w2] [60/60] melonDS 1.1`: the `^\[w2\] ` rule holds. Both windows carry `STEAM_GAME`. Size
  hints: w1 min 512x192 (214 with menu), w2 min 256x406.
- **Launched from OGUI (Mario Kart DS), OGUI sets `GAMESCOPECTRL_BASELAYER_WINDOW` to the `[w2]`
  window**, so today gamescope shows the bottom-screen window on the top panel. Step 3 must
  (a) leave tagged windows out of `GAMESCOPE_FOCUSABLE_WINDOWS` (what OGUI picks from) and
  (b) ignore a `BASELAYER_WINDOW` that names a tagged window, falling back to the app-id match.
- **Exit needs two presses with two windows, for both emulators**: OGUI's Exit (SIGTERM) did not
  end melonDS (Mario Kart DS) nor Azahar (New Super Mario Bros. 2) the first time; the second
  did. melonDS without a game never ended on SIGTERM (SIGKILL needed). Single-window melonDS
  quits on the first SIGTERM (emulator notes). Afterwards **both AppImage dwarfs mounts were
  left in /proc/mounts with no process serving them** (cleaned by hand with fusermount3 -u);
  not yet known whether the double Exit or the earlier SIGKILL caused it. Handled in step 6.
- Azahar 2126.1.2 with `layout_option=4`, launched from OGUI (New Super Mario Bros. 2): the
  secondary window appears only while a game runs, title
  `Azahar 9e6f523 | New Super Mario Bros. 2 | Secondary Window`; the main window has **no**
  `| Primary Window` suffix (only the game name). Both `WM_CLASS azahar`, type NORMAL, no
  `WM_TRANSIENT_FOR`, `STEAM_GAME` on both, user-specified position (not `PPosition`: no
  dropdown). Gamescope focused the secondary window (newest map; OGUI set no `BASELAYER_WINDOW`
  this time): the top panel showed the 3DS bottom screen. The title rule `\| Secondary Window$`
  holds.
- 0.3 Thor Lite: top `top_touchscreen` / DSI-1, bottom `bottom_touchscreen` / DSI-2. Thor and
  Pocket DS still owed.

1. **Two independent commits.** A small libdrm program (`spikes/twocrtc.py`, not shipped): modeset DSI-1 and
   DSI-2 together, then flip each CRTC with its own `NONBLOCK|PAGE_FLIP_EVENT` commit in a loop,
   measuring both flip timestamps. Pass: neither CRTC's flip waits for the other's vblank (msm
   shares DPU global resource state between them). Fail: fall back to one commit for both, paced
   by the top panel (bottom latency up to one frame, acceptable for NDS/3DS).
2. **Window shape.** Under the current gamescope, launch melonDS with `Window1` enabled and Azahar
   with `layout_option=4`; `xprop` both windows: `WM_NAME`/`_NET_WM_NAME`, `WM_TRANSIENT_FOR`,
   `_NET_WM_WINDOW_TYPE`, `WM_CLASS`, size hints. If the second window is transient-for the first,
   gamescope's focus walk (`steamcompmgr.cpp:4546-4570`) would make it the main focus: step 3 must
   exclude tagged windows before that walk.
3. Read Thor (SM8550) and Pocket DS connector names, bottom panel mode, touch device names and
   backlight nodes off the devices.

### 1. Device and session config

- Cherry-pick 103c24c from the lease branch (device-env `RETROFORGE_SECONDARY_*`, Thor Lite values,
  `tests/test-device-env.sh`). Reword its message: no lease any more. Drop
  `RETROFORGE_SECONDARY_PANEL_NATIVE_{WIDTH,HEIGHT}` if gamescope reads the mode off the connector
  (it will), or keep them for the touch rotation check only.
- Add Thor and Pocket DS rows (from spike 0.3).
- `retroforge-session` passes `--secondary-output` / `--secondary-touch-device` when the block is set;
  `tests/test-session.sh` case "dual screen" (and "single panel passes neither").
- Do not take 4998658 (second gamescope) or the lease series 0030-0037.

### 2. DRM backend: second output shows a test pattern (patch 0040)

`src/Backends/DRMBackend.cpp`:
- `drm_output_t { pConnector, pCRTC, pPrimaryPlane, mode_id, orientation, queued/visible FB ids,
  pending flip count, present ctx ring }`; `g_DRM` keeps today's members for output 0 and gains an
  optional secondary.
- Selection: after `setup_best_connector`, `setup_secondary_output` picks the named connector,
  a CRTC **distinct** from the primary's (`find_crtc_for_connector` needs an exclude mask) and that
  CRTC's primary plane. Make primary selection deterministic: the main connector must never be the
  secondary one (`-O` with the primary name from device-env).
- libliftoff: replace `liftoff_device_register_all_planes` (1609) with per-plane
  `liftoff_plane_create`, skipping the reserved plane.
- Modeset (`drm_prepare` 3425-3519): keep the secondary CRTC/connector enabled instead of zeroing
  every CRTC that is not `pCRTC`; `drm_unlink_foreign_planes` (3260) treats both CRTCs as ours.
  Bring both up in the first modeset.
- Secondary commit path: own `drmModeAtomicReq` (plane `FB_ID`, `CRTC_ID`, `SRC_*`, `CRTC_*`,
  `rotation`, `IN_FENCE_FD`), `NONBLOCK|PAGE_FLIP_EVENT`, **no blocking wait** (the primary's
  `Commit` blocks at 5001); refuse a new commit while one is in flight.
- `page_flip_handler` (787-828): route by `crtc_id` instead of dropping (798); per-output FB
  queue rotation and pending counters; only the primary feeds `GetVBlankTimer().MarkVBlank`; move
  the `m_uCompletedPresents` write (792) after the routing.
- Backend API: `IBackend::GetSecondaryConnector()` returning an `IBackendConnector` whose
  `Present` composites into its own output image (step 4) and commits the secondary path.
  `GetCurrentConnector()` keeps meaning the main panel.
- Debug hook: a convar that fills the secondary with a solid colour.
- **Done 2026-10-12 (patch 0040).** First HW run: both panels black. The boot console leaves
  DSI-2 lit on CRTC 95; taking CRTC 96 left 95 active with no connector (EINVAL on the secondary
  modeset) and the main modeset then turned 95 off under DSI-2 (EINVAL on every main frame). Fix:
  keep the CRTC/plane already driving the connector, else the last free ones, and refuse when the
  main output would be left without one. Review fixes: re-modeset after a pause/forced modeset
  (DirtyState -> drm_poll_state), finish_drm drops the objects before freeing them.
- HW: Thor Lite bottom panel shows the colour while OGUI runs on the top; top frame pacing
  unchanged (mangoapp frametime graph); ACE/FIT/Max unchanged without the flag.

### 3. Window routing and the second focus (patch 0041)

`src/steamcompmgr.cpp`, `steamcompmgr_shared.hpp`, `xwayland_ctx.hpp`:
- `steamcompmgr_win_t::uOutput`; set in `map_win` (next to `STEAM_GAME`, ~5910) and on
  PropertyNotify of `GAMESCOPE_OUTPUT` / `WM_NAME` / `_NET_WM_NAME` (~7127) from the atom or the
  title regex.
- Candidate filters: `xwayland_ctx_t::GetPossibleFocusWindows` (4656),
  `GetGlobalPossibleFocusWindows` (5103) and the per-ctx `DetermineAndApplyFocus` (4706) skip
  tagged windows for the main focus, so a tagged window can never steal or resize the main one.
  Exclude them before the transient walk (4546).
- A second `global_focus_t` for the secondary, created next to the key-0 entry (10143, 10304),
  `pVirtualConnector` = the backend's secondary connector; picked from tagged windows only, with
  an empty `vecFocuscontrolAppIDs` (never the Steam-controlled branch); no overlay, notification,
  external overlay, cursor.
- X side for the secondary focus: raise, `XResizeWindow` to the secondary panel size (instead of
  `ctx->root_width/height`, 5019-5033), never `XSetInputFocus` and never keyboard/mouse focus.
- Root atoms (`GAMESCOPE_FOCUSED_*`, 5575) stay main-only, and tagged windows are left out of
  `GAMESCOPE_FOCUSABLE_WINDOWS/APPS` (5279-5283), so OGUI never picks one as the base layer.
- `GAMESCOPECTRL_BASELAYER_WINDOW` naming a tagged window is ignored by the main pick (4428), which
  falls back to the app-id match (spike 0.2: OGUI set it to melonDS's `[w2]`).
- Without the flag no secondary focus exists and the filters see no tagged windows: behaviour
  identical.
- **Done 2026-10-12 (patch 0041).** Secondary focus is a standalone `global_focus_t`
  (`g_SecondaryFocus`), not a `g_VirtualConnectorFocuses` entry (keeps it out of the re-key/diff
  loop and of focus control). The filter sits in `xwayland_ctx_t::GetPossibleFocusWindows`, which
  feeds the per-ctx focus, the global list, `GAMESCOPE_FOCUSABLE_*` and the PipeWire focus at
  once. `handle_desktop_window` and `configure_request` keep tagged windows at the panel size
  (bottom panel: orientation property RIGHT_UP -> 270, logical 1240x1080).

### 4. Per-output rendering and paint state (patch 0042)

`src/rendervulkan.cpp/.hpp`, `src/steamcompmgr.cpp`:
- `g_output` becomes per output (ring of output images, partial-overlay images, `nOutImage`,
  `tmpOutput`, `computeFallback`); `vulkan_composite` / `vulkan_get_last_output_image` take the
  output. Pipelines are shared (same format).
- Compute dispatch sizes (`rendervulkan.cpp` 5109, 5170, 5229, 5256, 4669) come from the target
  image, not `currentOutputWidth/Height`.
- `paint_all` sets an RAII "current output" (size, rotation, refresh) from the focus, like the
  PipeWire/screenshot swap at 3037-3041; the secondary paints with rotation from its connector's
  orientation, pre-rotation off, colour LUT/CTM off.
- `hasRepaint` / `hasRepaintNonBasePlane` per focus; the clear at 10907 only clears what was
  painted. Secondary paints when its content changed and it has no flip in flight.
- Screenshots and PipeWire stay on the main output.
- HW: melonDS bottom screen and Azahar secondary window shown on the bottom panel; top panel
  still direct-scanned-out (debug: composite counter), OGUI overlay and Exit work.
- **Done 2026-10-12 (patch 0042), with direct scanout limited to unrotated panels.** A first
  version scanned the bottom buffers out with the plane rotating them (ROTATE_270): on SM8250 that
  goes through the single offline SDE rotator of kernel patch 0385 (one rotator object, one
  `race_job` flag, timed against one CRTC), which the top panel already uses. The top
  (command-mode) panel stalled: `dpu_encoder_frame_done_timeout` / `kickoff timeout` on enc35, garbage
  until a session restart. The plane is now never asked to rotate; the bottom frame is composited
  into a panel-sized image (rotated-copy blit when the layer is unscaled). melonDS [w2]'s buffer is
  not panel-sized (layer scale 0.58), so it takes the shader composite. True direct scanout on a
  rotated bottom panel would need client buffers already in panel orientation (Mesa prerotate,
  packages/mesa 0006, keyed to the main output today) -- not pursued.

### 5. Touch routing (patch 0043)

`src/wlserver.cpp/.hpp`:
- `wlserver_touch` gains the output it belongs to, chosen by `libinput_device_get_name` ==
  `--secondary-touch-device`; the bus heuristic (418-460) keeps binding the others to the main
  panel.
- Per touch point: target surface, offset/scale and orientation of **its** output, kept from down
  to up (today the global `focusedWindowOffset/Scale` and `g_nOutputWidth/Height`, 3269-3274 and
  3329-3334). Remap touch ids per device so ids from the two digitizers never collide.
- Secondary touch is always passthrough (no pointer emulation), never moves keyboard/mouse focus
  (`wlr_seat` keeps them separate).
- HW: DS touch works on the bottom panel while the pad drives the game; touching the top panel in
  OGUI still works; OGUI's input focus never jumps to the bottom window.
- **Done 2026-10-12 (0043 + 0045).** 0043 alone delivered no touch: the routed window sat at 0,0
  of the X screen under the fullscreen main window, and Xwayland routes touch by X geometry and
  stacking. Patch 0045 gives the game's Xwayland a second wl_output to the right of the main one
  (X screen [main][secondary], as ROCKNIX does with sway) and places routed windows there. HW: DS
  and 3DS touch on the bottom panel, both panels still on direct scanout, no gamescope GPU work.
  A touch-click-mode variant for the bottom panel was tried and dropped: raw touch points work.

### 6. Emulator seeds for dual-screen boards (repo, not gamescope)

- Per-device seed values (retroforge.plan.md Phase 4b "Device-specific values only when needed"):
  melonDS `Window1` enabled, top-only / bottom-only layouts (ROCKNIX values above); Azahar
  `layout_option=4`. Single-panel boards keep today's seeds.
- Launcher: nothing new if the default title regex matches. Only if some emulator needs its own
  rule: gamescope reads a root property `GAMESCOPE_SECONDARY_WINDOW_TITLE` that retroforge-launch sets
  from the emulator def and clears on exit.
- melonDS and Azahar with two windows both need two SIGTERMs (spike 0.2). Find why in each
  SIGTERM path (each signal closing one window?) and fix it once in the launcher (forward a second
  TERM after a short grace while the emulator lives) rather than per emulator, or per emulator
  with a small patch / LD_PRELOAD shim like `apps/retroforge-sigdefer`.
- Check that every exit path releases the AppImage mount (spike 0.2 left both dwarfs mounts
  behind); fix in retroforge-launch's release step if the double Exit causes it.
- HW: one NDS and one 3DS game on Thor Lite, every exit path (OGUI Exit, emulator menu), state
  saves.
- **Done 2026-10-12.** Seeds: emulator.json seed entries take an optional `dual_screen_file`, used
  when device-env declares RETROFORGE_SECONDARY_CONNECTOR (melonDS: Window0 top only, Window1 enabled
  bottom only; Azahar: layout_option=4). Exit: melonDS with two windows never exits on SIGTERM (its
  handler calls qApp->quit() inside the signal; deferring it to the GLib loop with retroforge-sigdefer
  did not help, the queued handler was never dispatched). New emulator.json `exit_resend: N`: one
  more SIGTERM N s after the stop, then SIGKILL to the emulator alone N s later; the launcher
  survives and releases the mount (OGUI's second Exit would SIGKILL the launcher too and leave a
  dead dwarfs mount). HW: one Exit press ends melonDS in ~4 s, 0 mounts left.
  **Corrected later 2026-10-12:** the second window was never the cause. melonDS and Azahar both
  init SDL, which catches SIGTERM for an SDL quit event their Qt loop never reads (melonDS has no
  signal handler of its own); one window, or the second panel off, behaves the same. Fixed as for
  RPCS3: SDL_NO_SIGNAL_HANDLERS=1 in both definitions, SIGTERM ends each within 0.5 s, and their
  exit_resend is dropped (the launcher keeps the option).

### 7. Bottom panel off when unused (patch 0046)

- No tagged window: secondary CRTC `ACTIVE=0` through its own modeset commit (the lease series'
  0034 blanked the connector the same way) and backlight off; back on when a tagged window maps.
  Check the msm DSI power-down/up time and that it does not glitch the top panel.
- HW: idle current with the bottom panel off vs on (OGUI menu).
- **Done 2026-10-12 (0046).** ACTIVE=0 + plane detached, mode and connector kept; off 2 s after the
  last routed window, on with the first frame of the next. The panel driver drops the backlight
  with the CRTC (ae96000.dsi.0 bl_power 4). HW Thor Lite: MKDS turns it on straight onto rotated
  direct scanout, top panel undisturbed (0 frame done timeouts); OGUI menu 360 mA off vs 412 mA
  on. ConVar secondary_output_off_when_unused 0 keeps it lit.

### 8. Later (not needed to ship)

- Second `CVBlankTimer` for the bottom CRTC (only if the panels ever differ in refresh).
- Frame callbacks / presentation feedback for windows on the bottom panel from its own clock.
- Night mode / colour management on the bottom CRTC (per-output CTM/LUT state, 0014/0018).
- Direct scanout on the bottom panel.
- Upstream: offer the series to Valve (refers to #227 / #1842) once it has run for a while.

## Size and risk

About 1,500-2,500 changed lines in four gamescope files, most of it in steps 2-4.

| Risk | Likelihood | Mitigation |
|---|---|---|
| msm serialises commits on the two CRTCs | Ruled out (spike 0.1) | — |
| Flip bookkeeping races (FB released while still scanned out, stuck pending counters) | High while building | Per-output queues and counters from the start; stress with the debug colour flip on both outputs |
| A tagged window disturbs the main focus (raise/resize ping-pong, transient walk) | Medium | Filters run before every main-focus step; spike 0.2 decides the transient case |
| Rebase cost on the next gamescope bump | Medium | Keep the series small and flag-gated; offer upstream |
| Bottom panel colour differs (no CTM/LUT) | Certain in v1 | Step 8 |
| Single-panel regression | Low | Everything gated on `--secondary-output`; ACE/FIT/Max regression on each step |

## Validation

```bash
make test       # device-env, session wiring
make overlay    # gamescope with the series (build each patch on its own while developing)
```
HW per step as listed above; final run: Thor Lite NDS + 3DS games, OGUI overlay/QAM, Exit paths,
suspend/resume with both panels; ACE, Pocket FIT, Pocket Max unchanged.
