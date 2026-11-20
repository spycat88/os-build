# Plan: store sign-in on the device (Chromium window)

**Complexity**: Medium-High. **Branch**: `steam-armv8-proton`. **Status**: prototype committed at
f8f62179 (2026-10-29), HW-OK on Pocket FIT for GOG and Epic + Google; D1, D4, D5 agreed 2026-10-29; Phase 1 done offline 2026-10-29 (`store browser status|setup`), HW pending; Phase 2 done offline 2026-10-29 (`sign-in` opens Chromium, python/chromium_signin.py; LAN page and qr.py removed), HW pending; Phase 3 done 2026-10-29 (plugin 0.1.93). Phases 1-3 HW-OK on the Pocket FIT 2026-10-29 (dev image): Chromium set-up, GOG (loki666b) and Epic (loki_666b) signed in from Settings > Stores, Guide > Exit cancels; found and fixed there: CDN resets (16b8f478), Epic digital extras listed as games (10a290c4). Air X pending (its Wi-Fi).

## Summary

Settings > Stores signs in with the phone today (stores.plan.md D6: a QR code for a one-time LAN page).
This replaces it with the store's own sign-in page in a window on the device: Sign in opens it, the
player signs in there (touch or on-screen keyboard), the window closes by itself and the row says whom
it signed in. The prototype (`apps/retroforge-store-signin/`, removed after Phase 4; at f8f62179) proved the pieces on the Pocket FIT
(2026-10-29): Chromium in app mode, the code read over the DevTools pipe, the existing `sign_in(code)`.

## What the prototype established

| | Finding |
|---|---|
| F1 | **Chromium, not Electron.** Google refuses sign-in in embedded web views (Electron, WebKit, Servo) by policy; the real Chromium passes. GOG works in both, so one browser covers both stores. |
| F2 | **`--disable-blink-features=AutomationControlled`.** `--remote-debugging-pipe` alone makes `navigator.webdriver` true in every page (probed on the device) and Cloudflare's check on Epic loops forever. |
| F3 | **Scale = screen height / 720** (`--force-device-scale-factor`, 1.5 on 1080p, a 1280x720 page). 1.0 is unreadable on a 6" panel, 2.0 (960x540) makes the forms scroll. Chromium sees the rotated DSI panel as landscape. |
| F4 | **Size.** Chromium 147 is 162 MB to download (396 MB unpacked) plus 19 MB of packages the image lacks (GTK3 and its closure). The rootfs is 1.85 GB of its 2 GB slot: it does not fit in the image. |
| F5 | **Focus.** OGUI ties windows to apps by `OGUI_ID` in `/proc/<pid>/environ`; Chromium overwrites its environ (process titles), so its window is an orphan and stays behind OGUI (black screen). The test used a `/run` helper setting `GAMESCOPECTRL_BASELAYER_APPID`. |
| F6 | **Sandbox** works with unprivileged user namespaces (no setuid helper needed in /home). |
| F7 | **The Air X failure is its network**: Google fails after the password there and works on the Pocket FIT with the same card ([[ace-wifi-stalls]]-like stalls). Not a blocker for the design. |

## Decisions (proposed, to agree)

| | Decision |
|---|---|
| D1 | **Chromium downloaded when Sign in is pressed, never shipped, never in the background** (user, 2026-10-29; as legendary/gogdl, stores D1). No pacman (seal-rootfs.sh strips it from release roots, with gnupg and the keyring): the store helper installs it itself. (1) `make relock` writes `/usr/share/retroforge/stores/chromium.pin` (`rootfs/chromium-pin.py`, committed and reviewed like the lock) from the image's own snapshot db (`rootfs/manifest.lock`'s `repo snapshot`): Chromium and the packages of its closure the image lacks, counting the lock's snapshot and retroforge rows as present but not its stripped ones (2026-10-29: 19 files, 190 MB, GTK3 the largest after Chromium), each with filename, the snapshot's sha256 and size; a test fails when its snapshot is not the lock's. (2) On Sign in the helper downloads them over HTTPS from that snapshot, each checked against the pin; any mismatch aborts with nothing installed. (3) It unpacks with Python 3.14's `tarfile` (`r:zst`, `filter="data"`: no path outside the target), only `usr/lib/chromium/`, the top-level `usr/lib/*.so*` and the GSettings schemas (compiled), into `~/.local/share/retroforge/stores/chromium/<pin digest>/`, then swaps a `current` link; Chromium finds the libraries through `LD_LIBRARY_PATH`, nothing in `/usr` changes. A new pin (next relock) replaces it at the next Sign in. Progress shows on the Sign in row. Chromium only ever opens the two stores' sign-in pages, so a snapshot-old Chromium is acceptable; it moves with each relock. |
| D2 | **One helper verb**: `store <gog\|epic> sign-in` keeps its name and events but opens the window instead of the LAN page: `chromium-signin.py` folds into the helper (or `/usr/lib/retroforge/python/`), then `sign_in(code)` as now. New events: `browser` (`setup` progress, `open` with Chromium's pid, `closed`). |
| D3 | **The plugin makes Chromium one of OGUI's running apps** (revised 2026-10-29, Phase 3). The helper opens it on OGUI's game display (`sign-in --display`); on `open` the plugin registers its pid with LaunchManager as a RunningApp (signin_app.gd: running while /proc/<pid> is, Exit = the plugin's Cancel), pushes the in-game state and gives its windows (by _NET_WM_PID) that app's id, so OGUI focuses them as a game's and the Guide menu and the on-screen keyboard work over it as they did over the prototype, which ran as a launched game. Its stop pops the in-game state, back to Settings > Stores. No OGUI patch. (Was: put its app id in the base layer by hand, the `/run` helper's logic; that would leave OGUI's menu and keyboard out.) |
| D4 | **The LAN/QR page is removed, no fallback** (user, 2026-10-29). Its server was awaiting a security review; `qr.py` (only the store helper, store_settings.gd and test-store.sh use it) goes with it. |
| D5 | **Input**: touch and the OGUI on-screen keyboard (works since b4d6e5a9). No gamepad pointer (user, 2026-10-29: all our devices have a touchscreen). Checked in kernel/dts: every board has a touch node, itself or by include, except the Air X MQ65 and MQ66B (sm6115-mangmi-air-x-base.dtsi has none; only the MQ66 adds its Himax): whether they lack touch or it is just not described is unknown. |
| D6 | **Cancel**: B / the Guide menu's Close ends the window; the row goes back to Sign in. The 15-minute limit stays. |

## Open questions

None (Q1-Q3 answered 2026-10-29: D4, D5, D1).

## Phases

1. **Pin + set-up**: the build writes `chromium.pin` from the snapshot db at relock; the helper's
   Chromium set-up (run by `sign-in`) downloads, checks, unpacks, with progress. `tests/test-store-browser.sh` against a fake snapshot.
2. **Helper**: `sign-in` opens Chromium (flags F2, F3, profile in a private temp folder deleted after),
   reads the code, signs in. Fake-Chromium test for the code reading (GOG address, Epic JSON page).
   Done: events `browser` (`setup` + percent when Chromium is not set up yet, `open` + pid, `closed`), then
   `code` and `signed_in` or `error` (exit 1); the player closing the window, stdin closing (Cancel) or
   SIGTERM end it with exit 0 and no sign-in. The scale is read from the X screen (libX11 through ctypes:
   the image has no xwininfo). Chromium gets its own session, killed whole when it does not close in 10 s.
   The plugin still expects the LAN page's `page` event until Phase 3.
   Done (helper side of Phase 3): `sign-in --display :N`.
3. **Plugin**: Sign in row runs it, progress, focus (D3), Cancel, the QR panel removed.
   `tests/test-plugin.sh` cases. Done: store_settings.gd (row texts, Chromium set-up progress, Cancel
   under the row until the window closes), signin_window.gd + signin_app.gd (D3). B does not cancel
   (gamepad input goes to the focused window, as in a game): the Guide menu's Exit does (D6).
   Nothing compiled offline (no Godot here): the device's plugin load is the first check.
4. **HW**: Pocket FIT, and Air X once its Wi-Fi is sorted. Then
   remove `hw-test/`, `main.js`, `package.json`.
   Done on the Pocket FIT 2026-10-29: set-up (after the retry fix), GOG, Epic, Guide > Exit, no Chromium,
   profile or running-game card left behind. The whole prototype folder is removed (its
   chromium-signin.py lives on as python/chromium_signin.py). Air X still to do.
