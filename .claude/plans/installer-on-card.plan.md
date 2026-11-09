# Plan: the installer lives on the SD card; the standalone medium is dropped

AGREED 2026-11-04, branch feat/installer-on-card.

## Decisions
- D1 The OS still comes from the latest OTA: bundle resolved from the channel, verified before
  consent, streamed by RAUC. No slot copy. EXCEPT a dev image (2026-11-09): it copies its own
  running root, since the dev channel usually has nothing published and the build in hand is the
  one being tested (release-info `running:<dev>`, retroforge-install verify_running_root).
- D2 The installer keeps its own UI (pygame) in its own session. Not rebuilt in the plugin.
- D3 Entry: Settings > General, directly below Updates, shown only when booted from a card.
- installer/ stays the source directory; files ship via installer/shipped-files, as genpart.sh does.
- Launched from OGUI only, so Wi-Fi is already set up: no netcfg, no wifi.conf, no network screens.
- Flow: row -> release-info check -> confirmation dialog -> `systemctl --no-block start
  retroforge-installer.service`; Conflicts= stops the session; preflight, consent, progress, done;
  Cancel reboots, Done powers off so the card can come out. The dialog only agrees to leave the session; the four-button sequence
  stays the real consent.

## Privilege model
- System unit, runs as root, fixed ExecStart, no arguments. OGUI stays `player`.
- One polkit rule: active local session may `start` that one unit.
- `player` must not survive into the installer: it lingers, is in `input` (/dev/uinput), InputPlumber's
  bus is open, and confirm-ui takes the sequence on its command line. So Conflicts=user@1000.service
  and /run/nologin while it runs, with
  Conflicts=systemd-user-sessions.service so nothing removes it. The spine refuses consent if a process
  of that real uid is alive. The session unit also restarts InputPlumber, which OGUI leaves modified.
- The log is root-owned under /var/log/retroforge, never written by root into /home/player.
- The channel from player's ota.conf is validated.

## Phases
1. Ship the components in the root: packages, relock, move into the overlay, pygame wheel, guard check.
2. Installer session: unit, polkit rule, log, saved_entry carried over.
3. release-info follows the Updates channel; netcfg and the network screens deleted.
4. Plugin row + dialog.
5. Delete the standalone medium: scripts, lock, Makefile, CI, tests, docs.
6. Hardware gates: fresh, abort at consent, full replacement via force external (the keep-/home reinstall is not reachable from the UI), boot internal
   with the card in, first OTA, power key mid-install, Wi-Fi drop during the stream, no player
   process during consent, uinput press cannot reach the installer, Wi-Fi survives the session stop,
   gamescope second start. UFS board and Air X.
