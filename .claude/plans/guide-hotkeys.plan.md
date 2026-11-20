# Guide-modifier emulator hotkeys (InputPlumber input layers) — plan

Status: scaffolding implemented on branch feat/guide-hotkey-layer (2026-10-20), NOT HW-tested.
InputPlumber converted from a prebuilt pin (0.81.0 tarball) to a from-source overlay package at
v0.82.0 + upstream PR #757 (input layers). Snes9x is the one-emulator HW testbed. Offline tests
pass (tests/test-launch.sh, 486). guide-hotkeys.yaml validates against the BUILT package's
schema/device_profile_v1.json (strict, additionalProperties false; checked 2026-10-21 with
`uv run --with pyyaml --with jsonschema`), which carries PR #757's `layers`. Serde can still
differ from the schema — watch `journalctl -u inputplumber` for a parse error on first HW load.
The overlay build needs `options=(!lto)` (GCC slim-LTO hidapi object vs ld.lld; PKGBUILD).

## Goal (user decision 2026-10-18)

One Guide-modifier layer on every device: Guide+L1 quick load, Guide+R1 quick save,
Guide+R2 fast-forward, Guide+Start emulator menu or exit. Motivation: L3/R3 and Select+Start
hotkeys clash with games; mGBA/Snes9x/melonDS cannot bind pad combos themselves.

## Why it was blocked, and what unblocked it

InputPlumber profiles were single-source mappings: no modifier/chord concept (asked ShadowApex
2026-10-18, upstream issue #533). He answered with PR #757 (2026-10-19, branch
shadowapex/input-layers-v2, exactly one commit on top of v0.82.0): a mapping may target
`layer: {name: x}`; while the activating input is held, the layer's mappings override the base
ones; releasing pops the layer and releases whatever it produced (no stuck keys); layers stack
(max 8). Open, unmerged as of 2026-10-20 — we carry it as a package patch; drop it when a release
has it. An older InputPlumber silently ignores `layers:` (unknown fields skipped), so OTA
rollback keeps working — but silently, so any plugin-side surfacing must version-gate.

## Design

### The mechanism (one source of truth per emulator)

- `packages/inputplumber/` — PKGBUILD from the v0.82.0 tag + `patches/0001-...input-layers...`
  (the PR, verbatim via git format-patch). File set = upstream's `make install`, same as the old
  prebuilt tarball. No libiio since 0.82.0 (upstream 966be34). With the pin gone, the repo has
  ZERO prebuilt pins (mechanism kept).
- `/usr/share/retroforge/emulators/<emu>/guide-hotkeys.yaml` — a per-emulator IP device profile:
  base mapping sends Guide to BOTH `layer: guide` AND `gamepad: Guide`; the layer maps
  L1/R1/R2/Start to keyboard F1-F4. Per-emulator because the F-key meanings are seeded into each
  emulator's own config.
- `emulator.json "gamepad_profile": "guide-hotkeys.yaml"` — retroforge-launch loads it on every
  composite device right before the start and puts back each device's previous profile on exit
  (leftover of our own profile -> the shipped default instead). Best-effort: no InputPlumber, no
  busctl, refused profile — the game still starts, one log line.

### Why Guide maps to itself too (load-bearing, verify on HW)

Translation runs BEFORE the intercept check (composite_device/mod.rs handle_event:
translate_event, then is_intercept_event per translated event). A Guide mapping that only
targets the layer consumes Guide before the Pass-mode intercept sees it — and that intercept is
how OGUI gets its DBus Guide event (the in-game menu, which opens on RELEASE). Re-emitting Guide
keeps the menu; during a chord the held Guide is flushed to the virtual pad instead (nothing
binds pad-Guide in any emulator).

### target_devices is explicit in the profile

`[xbox-elite, keyboard, mouse]` — identical to every board's devices.d EXCEPT the MANGMI Pocket
Max, which ships no keyboard target (its composite produces no keyboard capability); without the
explicit list the layer's F-keys would be dropped there. Loading replaces targets; the restore
loads a profile without target_devices (targets stay) — residue on the Max only, gone at reboot.

### Snes9x testbed bindings

Layer: L1 -> KeyF1, R1 -> KeyF2, R2 -> KeyF3 (both the trigger AND button capability: boards'
capability maps disagree on what R2 is post-translation; an unmatched layer row never fires),
Start -> KeyF4. Seeded snes9x.conf [Shortcuts]: QuickLoad000=F1, QuickSave000=F2, EmuTurbo=F3
(hold = fast-forward), GTK_quit=F4 (the clean exit path, SRAM written — the pad exit Snes9x
could not have, emulator.json notes). Names from gtk_control.cpp b_links; key format
"Keyboard <GDK name>" (gtk_binding.cpp).

## HW result 2026-10-21 (MANGMI Air X): the Guide self-mapping is WRONG

Profile loads clean, restore works, Guide tap opens the menu — but Guide+R1 does nothing and the
OGUI menu opens on release. Cause: OGUI sets a SINGLE-cap intercept activation ([Guide] ->
Guide, card_ui.gd:156; device InterceptMode=1 Pass). is_intercept_event_single flips to
InterceptMode::Always on Guide PRESS and sends Guide to DBus; from then on write_event routes
EVERY event (the layer's F2 too) to DBus only. The "chord cancels the intercept" assumption
holds only for multi-cap activations (is_intercept_event_multi). Dropping the self-mapping
fixes the layer but kills tap-Guide -> menu.

A/B CONFIRMED on the Air X: InterceptMode set to 0 by busctl mid-game -> Guide+R1 quick-saved
(states/snes/<game>.000 written). Layer, keyboard target and snes9x.conf seed are correct; the
intercept is the only blocker.

Options (user checking with ShadowApex before choosing):
- (recommended) IP patch 0002, tap-vs-chord: in Pass mode with a layer active, hold the
  activation cap instead of intercepting on press; another press while held = chord -> cancel
  the intercept, layer outputs flow to targets; lone release -> set Always + send Guide
  press/release to DBus (OGUI opens on release already). Possibly belongs in PR #757 itself.
- (fallback) profile only: no Guide re-emit; menu via another chord (e.g. Guide+Select -> Guide
  inside the layer). Changes the menu UX.

## Next try (ShadowApex's idea, 2026-10-22): Guide -> dbus: ui_guide

The profile maps Guide to [layer guide, dbus: ui_guide] instead of re-emitting gamepad:Guide,
as OGUI's own mouse_keyboard_wasd profile does. A translated DBus event skips is_intercept_event
and goes straight to the DBus target (write_event), so the single-cap intercept never flips to
Always and the layer's F-keys reach the keyboard target. No IP patch 0002 needed if it holds.
HW 2026-10-22 on the Air X (bind-mounted over the read-only /usr): Guide+R1 quick-saves, and
ProfilePath stays guide-hotkeys.yaml through OGUI's set_gamepad_profile("") on the Guide press
(global_default*.json exist there, yet nothing replaced the profile). Remaining gap, below
(first point): the menu DOES open when Guide is released after a chord. Asked ShadowApex.
Gaps:
- CONFIRMED: OGUI never sees the chord buttons, so on Guide release after a chord it opens the
  menu (_guide_input opens unless ogui_guide_action is pressed). A profile alone cannot fix it:
  every DBus event sends press AND release, and the release clears the flag before Guide goes up.
  Proposed (pending ShadowApex): each layer chord also emits `dbus: ogui_guide_action` (custom
  actions pass through IP and OGUI's _on_dbus_input_event), plus OGUI patch 0016 ignoring the
  DBus RELEASE of ogui_guide_action so it stays set until _guide_input clears it on Guide release.
- NOT A PROBLEM on the Air X: OGUI's set_gamepad_profile("") on every Guide press left our
  profile loaded.

## Agreed with ShadowApex 2026-10-26: no intercept, deferred Guide tap

Both halves of the problem, fixed where they live:
- **InputPlumber patch 0002** (ours, for PR #757; packages/inputplumber/patches/0002-*):
  a mapping that holds a layer down (mode hold) keeps its OTHER outputs back. On release they go
  out as a press/release tap only if no mapping of a layer the activator holds produced anything
  in between; otherwise nothing. Base-profile outputs while held do not count. Toggle mode and
  mappings without other outputs unchanged. LayerState::defer_tap / finish_tap, chorded flag set
  in record_outputs; handle_event emits the tap through write_chord_events. 6 new layers_test
  cases, full cargo test green (x86 rust:1 container, 2026-10-26).
  **2026-11-07 REDESIGNED at ShadowApex's request on PR #771:** instead of holding back a
  mapping's other outputs, the `layer` target event takes `on_deactivation: {only_when_unused,
  emit_events}`, tapped when its activator lets the layer go (hold released, toggle pressed
  again; stack clears emit nothing). Profiles: `layer: {name: guide, on_deactivation:
  {only_when_unused: true, emit_events: [dbus: ui_guide]}}`; OGUI 0024 writes the same
  (GUIDE_TAP). The profile-load release split out as IP 0003 (own upstream PR). 8 new
  layers_test cases, cargo test 45+4 green (rust:1 container).
  **HW-OK 2026-11-08 on the Pocket ACE** (dev image 0380aae6): lone Guide opens the menu, Guide
  hotkeys in armGBA do not, Guide+A opens the quick bar every time, Guide on the store sign-in
  window opens the menu. #771 updated to IP aabedf4; 0003 (4385b3a) is its own upstream PR.
- **OGUI patch 0024** (packages/opengamepadui/patches/0024-*): no intercept mode (card_ui sets
  NONE). LaunchManager is the ONE profile writer: ogui_focus.json (every pad input -> its DBus UI
  action, right stick/paddles -> none) whenever OGUI has focus (setup, game state exited, OGUI
  focused app); in game: OGUI per-game setting > launcher declaration
  ($XDG_RUNTIME_DIR/opengamepadui/game_profile: path, pid; dead pid = void) > global profile.
  In game OGUI's own Guide combos live in the layer Guide holds: Guide+A -> dbus ui_quick (quick
  bar), Guide+X -> dbus ui_osk (InputPlumber North = BTN_NORTH = BTN_X, the left face button).
  A JSON profile gets Guide -> [layer ogui_guide, ui_guide] and
  those rows where free (*_guide.json, edited as JSON after the target modification because
  InputPlumberProfile drops `layers`); our YAML profiles carry them (test-launch
  guide_layer_ok). A Guide release with no press seen is ignored (Guide+A opens the quick bar,
  which loads the focus profile while Guide is still held). _guide_input
  no longer swaps profiles on press; gamepad_settings no longer loads profiles (OGUI has focus
  whenever it is open). Fixes upstream set_gamepad_profile's early `break` that never loaded a
  profile on a device with a gamepad target (why the 2026-10-22 profile "survived").
- **retroforge-launch**: no busctl. "gamepad_profile" is declared (atomic write, our pid) before
  Popen and withdrawn on exit unless another launcher's declaration replaced it.

In the library (focus profile) OGUI's combos work the old way (ogui_guide_action).

## HW checklist (Pocket ACE or FIT; also once on a Pocket Max for the keyboard-target case)

1. Library: d-pad/stick/A/B/L1/R1/triggers navigate as before (focus profile replaces intercept);
   `busctl --system get-property org.shadowblip.InputPlumber \
   /org/shadowblip/InputPlumber/CompositeDevice0 org.shadowblip.Input.CompositeDevice ProfilePath`
   = .../user data/gamepad/profiles/ogui_focus.json; InterceptMode = 0.
   journalctl -u inputplumber: no parse error for ogui_focus.json.
2. SNES game: ProfilePath = .../snes9x/guide-hotkeys.yaml once the window has focus;
   cat $XDG_RUNTIME_DIR/opengamepadui/game_profile shows it + the launcher pid.
3. Guide tap alone opens the OGUI menu (on release); the menu navigates (focus profile); closing
   it puts guide-hotkeys.yaml back and the game gets input.
4. Guide+R1 saves, Guide+L1 loads, Guide+R2 held fast-forwards, Guide+Start quits — and NONE of
   them opens the menu on Guide release. No stuck keys when Guide is released mid-chord.
4b. In game: Guide+A opens the quick bar, Guide+X the keyboard; neither opens the main menu on
   Guide release, the game gets no A/X, and the quick bar stays open after Guide is released.
   Watch for a stray ui_accept release activating the focused quick-bar item.
5. After exit: library input normal (focus profile), declaration file gone.
6. A game WITHOUT a profile (e.g. PPSSPP): ProfilePath = global_default_guide.json (or the
   target-modified variant), Guide tap opens the menu, the game gets every other button.
7. Hotplug a pad (BT) in the library and in game: it gets the profile of whoever has focus.
8. Existing homes: the [Shortcuts] seed only lands on first run — an installed Snes9x needs
   ~/.config/snes9x/snes9x.conf [Shortcuts] added by hand (or delete the file).
9. Gamepad settings screen: open, change a global mapping, save; library still navigates; the
   change applies in the next game without a profile.

## Rollout after a green testbed

- Per-emulator keyboard-hotkey research for the other 12 emulators (done in-session 2026-10-18,
  NOT saved — redo from pinned sources), one guide-hotkeys.yaml + seed each.
- melonDS/Azahar dual-window: check the keyboard target reaches the focused window under
  gamescope dual-output.
- Emulators with no quick-save concept (PortMaster scripts, Steam): no profile — the key is
  simply absent from their emulator.json.
- Guide+Start on emulators that already exit cleanly via OGUI Exit: keep for muscle memory.
- Upstream: drop patches/0001 when a release carries PR #757; re-read devices/ on every bump
  (0.82.0 took our 50-ayn_thor_lite.yaml — deleted, upstream's matches `compatible: ayn,thor-lite`,
  the first compatible string in our DTS).
