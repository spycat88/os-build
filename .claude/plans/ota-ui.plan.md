# Plan: OS updates in the shell (stable / beta)

**Complexity**: Medium. **Branch**: `feat/ota-ui`. **Status**: Phases 1, 2, 2b, 3, 5 done offline 2026-10-18 (plugin 0.1.56), not pushed; Phase 4 HW-OK on the ACE 2026-10-18 (first beta published).

## Summary

The device and server halves of OTA exist and are in use: `retroforge-update` (check / apply `N%` /
`channel` / `channels` / `set-channel` / `status`, first-boot gate, `tests/test-update.sh`),
RAUC A/B streamed adaptive installs, R2 at `https://ota.retroforge.org/<channel>/`, and
`release-bundle.yml` routing `ota/vX.Y.Z` to `stable` and `ota/vX.Y.Z-beta.N` to `beta`. Nothing
in the shell drives it: OGUI's own (x86 `update.zip`) updater still sits in Settings > General.
This plan adds the shell half as a RetroForge `OSPlatform` shipped in the plugin, and publishes the
first beta.

## Decisions

| | Decision |
|---|---|
| D1 | The UI is a RetroForge **`OSPlatform` subclass in the plugin** (`nixos.gd` is the model), NOT an OGUI patch. OGUI's `platform.gd` only knows a fixed list of os-release IDs, so `platform.os` is `null` on RetroForge and `card_ui.gd:107` has already run `platform.load(root)` before plugins load: the plugin installs `platform.os` and calls its `ready(root)` itself. |
| D2 | **Never automatic.** A background check only notifies. Install and reboot happen only on a button press. |
| D2b | **One button, Steam-style**: `Check for updates` -> `Install <version>` (progress while installing) -> `Restart now` when the install is done. Restart = `systemctl reboot`, the same call OGUI's power menu makes (`power_menu.gd:22`). A staged update found at start (client's "restart pending") shows `Restart now` straight away. |
| D3 | **No restriction on channel changes**: stable -> beta and beta -> stable switch freely, no confirmation. Whatever the new channel's `latest.json` names is offered, older or not (the client's inequality check already does this). |
| D5 | **Remote access switch** in the same `PlatformRetroForge` (added 2026-10-18): a toggle that starts / stops `retroforge-pairingd`, so a key can only be sent while the player turned it on (the daemon's documented consent model). Pairing stops being always-on: the unit loses `[Install]`, its preset and the wants symlink. Off at every boot (not persisted), confirmed by the user 2026-10-18. |
| D4 | Beta versions are `X.Y.Z-beta.N`, ahead of the next stable (what the workflow already keys on). |

## Patterns to Mirror

| Category | Source | Pattern |
|---|---|---|
| OS platform | `_ref/OpenGamepadUI/core/platform/os/nixos.gd` | `ready(root)`: await a frame, `_remove_updater`, `_add_updater` into `settings_general_menu` |
| Settings section injected at runtime | `apps/ogui-retroforge-plugin/plugin/scraper_settings.gd` | section_label / card_button_setting / dropdown scenes, `_nodes` kept for teardown |
| Long-running tool on a thread | `apps/ogui-retroforge-plugin/plugin/scrape_runner.gd` | worker thread, progress signal, runner outlives its thread |
| Client contract + tests | `rootfs/overlay/usr/bin/retroforge-update`, `tests/test-update.sh` | exit 7 = none / fail closed; stdout parsed, stderr free text; tests exec the shipped file through env seams |
| Plugin tests | `tests/test-plugin.sh` | |

## Files to Change

| File | Action | Why |
|---|---|---|
| `rootfs/overlay/usr/bin/retroforge-update` | UPDATE | `version` subcommand |
| `tests/test-update.sh` | UPDATE | `version`; channel switch offers an older release |
| `rootfs/overlay/usr/lib/retroforge/install-ogui-plugin`, `tests/test-plugin-install.sh`, `rootfs/lib-assemble-plugin.sh` | UPDATE | image's plugin wins on any version difference |
| `apps/ogui-retroforge-plugin/plugin/retroforge_os.gd` | CREATE | `PlatformRetroForge extends OSPlatform`: updater UI + background check |
| `apps/ogui-retroforge-plugin/plugin/update_runner.gd` | CREATE (if scrape_runner is not reusable as is) | threaded check / apply with `N%` |
| `apps/ogui-retroforge-plugin/plugin/plugin.gd` | UPDATE | install `platform.os` when null and `os_info.id == "retroforge"` |
| `apps/ogui-retroforge-plugin/plugin/plugin.json` | UPDATE | bump `plugin.version` |
| `tests/test-plugin.sh` | UPDATE | static checks for the new files |
| `docs/ota.md`, `docs/RUNBOOK.md`, `.github/workflows/release-bundle.yml` (comment), `.claude/plans/retroforge.plan.md` (Phase 5) | UPDATE | the picker exists; how to cut a beta |

## Tasks

### Phase 1: client gaps (test first)
- `retroforge-update version`: the running identity (identity_of; a dev build its stamp) for the header. DONE.
- Test that a channel switch offers the other channel's release even when it is older
  (beta `0.0.4-beta.1` -> stable `0.0.3`), so D3 is pinned by a test, not by accident.
- `install-ogui-plugin` installs the image's plugin whenever its version DIFFERS, not only when
  newer: the image is the only source (no plugin store), and after beta -> stable the beta plugin
  left in `/home` would call tools the stable image lacks. `tests/test-plugin-install.sh`.
- **Validate**: `tests/test-update.sh`.

### Phase 2: `PlatformRetroForge`
- `ready(root)`: await a frame, find `main`, remove OGUI's updater nodes (as `nixos.gd`
  `_remove_updater`), add an "Updates" section when `/usr/bin/retroforge-update` exists.
- Section: **Version** (read-only), **Channel** dropdown (Stable / Beta from `channels`; disabled
  with the reason when `pinned`; change = `set-channel` then re-check), and the **one update
  button** of D2b, with a progress bar under it while installing.
- Every command runs off the main thread. Components configured only after `add_child` (release
  export SEGFAULT, see build gotchas). Errors -> a line under the button, never a silent no-op.
- `plugin.gd`: install it only when `platform.os == null` and `os_info.id == "retroforge"`.
- **Validate**: `tests/test-plugin.sh`; deploy with auto-rollback; HW on ACE.

### Phase 2b: remote access (pairing) switch
- Unit: drop `[Install]`, `60-retroforge-pairingd.preset` and the committed
  `multi-user.target.wants/retroforge-pairingd.service`; `Restart=on-failure` stays.
- Already-installed devices: first-boot preset-all wrote the wants link into the `/etc` overlay's
  upper dir, which survives an OTA. Remove it in the RAUC post-install hook on the new slot (it already
  rsyncs `/var`), with a test, or pairing stays always-on on every device updated over the air.
- polkit rule `50-retroforge-pairing.rules`: `org.freedesktop.systemd1.manage-units` for
  `unit == "retroforge-pairingd.service"`, verbs `start`/`stop` only, active session + wheel (as the
  timezone rule). Nothing else becomes manageable.
- UI: "Remote access" section, toggle "Allow pairing a computer" (state read from
  `systemctl is-active`, so the switch never lies after a crash or a stop elsewhere), and while on, the
  address and port to pair with (`docs/remote-access.md`).
- Guard / tests: guard-rootfs no longer expects pairingd enabled; `tests/test-pairingd.sh`
  (unit has no `[Install]`); polkit rule grants exactly start/stop of that one unit.
- Docs: `docs/remote-access.md` "Pairing is always on — for now" becomes how the switch works;
  daemon header CONSENT MODEL.

### Phase 3: background check
- One check a few minutes after session start, then every 6 h, skipped while a game runs. An
  available update posts an OGUI notification pointing at Settings > General. Nothing installs.

### Phase 4: first beta + HW
- Build/sign `0.0.4-beta.1`, install it on the ACE from a local file first (`docs/ota.md` step 2),
  then tag `ota/v0.0.4-beta.1` (creates `beta/` in the bucket).
- ACE: stable -> beta, check, install (progress), Restart now, trial boot confirmed; beta -> stable
  (older build offered, install, restart); dev image shows the channel pinned; nothing before first boot.
- Look for rauc's `using HTTP/1` warning on the first real R2 stream (never observed yet).
- Remote access on the ACE: the switch starts/stops pairingd with no password prompt (polkit needs
  the OGUI session to be `subject.local`), a key registers, it is off after a reboot; an OTA from an
  always-on image leaves pairing off (seed_var dropped the link).
- Settings > General in the real shell: OGUI's updater rows gone, focus starts on System update,
  no crash at start (release export).

**HW so far (ACE, 2026-10-18)**: local release image `v0.0.4-beta.0` (0d231886): Stable check offers
v0.0.3, Beta empty -> no update; pairing switch on -> key registered from the PC -> off, no polkit
prompt; no plugin errors in the shell log. `v0.0.4-beta.1` bundle (same commit, release key)
verified and installed from a local file, rebooted into B, trial boot good, pairing off after the
reboot, channel kept (beta). A manual `rauc install` writes no staged stamp, so the button cannot
offer Restart now for it (by design). Tagged `ota/v0.0.4-beta.1` (8972d8f0): CI published `beta/`. Reflashed beta.0 (with the scraper
login), then in the shell: Beta -> Install (streamed, 11.9% of the bundle fetched, no `using
HTTP/1` warning) -> Restart now -> CI's beta.1 on B, boot confirmed good, pairing (left on) off
after the reboot. Beta -> Stable: v0.0.3 offered, installed (5.7% fetched), Restart now, A good.
On v0.0.3 as predicted: its image plugin is 0.1.43 and its old never-downgrade rule keeps the
installed 0.1.57 (`retroforge-update version` unknown -> blank version line, logged as a WARN),
and pairingd is enabled + active again (v0.0.3's always-on design, no polkit rule). A clean
beta -> stable needs a stable release that carries the plugin fix (0.0.4).

**Offline harness used (2026-10-18)**: Godot 4.7.1 x86_64 (official, sha512-checked) as
`RETROFORGE_GODOT`; a copy of the pinned OGUI 0.46.1 tree with upstream's x86_64 core library
(`opengamepadui-x86_64.tar.gz` of v0.46.1, sha256 05fe8b0e..., copied as template_debug and
template_release into `addons/core/bin`) as `RETROFORGE_OGUI_PROJECT`. Reviews: code + security,
no CRITICAL/HIGH; MEDIUMs fixed in ec1566f6, ef9c9f18. Not done (low): auto-stop for a forgotten
pairing switch (RuntimeMaxSec), hash-compare in install-ogui-plugin.

### Phase 5: docs
- `docs/ota.md`, `docs/RUNBOOK.md`, `release-bundle.yml` comment ("There is no Settings picker"),
  `retroforge.plan.md` Phase 5 entry.

## Validation

```sh
tests/test-update.sh
tests/test-plugin.sh
make test
```

## Risks

| Risk | Likelihood | Mitigation |
|---|---|---|
| Beta -> stable leaves the beta plugin in `/home` | — | fixed in Phase 1: the image's plugin always wins; HW step in Phase 4 |
| Restart into a bundle that never reaches a session (no serial) | Medium | every bundle HW-installed before tagging; trial boot + rollback |
| Runtime edits of Settings > General crash the release export | Medium | configure after `add_child`; deploy with auto-rollback |
| OTA'd devices keep the pairing wants link in `/etc` upper | High if missed | post-install removes it; HW check after an OTA |
| A future OGUI adds `retroforge` to its list | Low | only install when `platform.os` is null |
| HTTP/1 streaming from R2 is slow | Low | observe in Phase 4 |

## Acceptance
- [ ] All phases done, tests green
- [ ] ACE: both channel switches and a restart-into-update proven on HW
- [ ] Nothing installs or reboots without a button press
