# RetroAchievements for the standalone emulators — plan

Status: written 2026-11-13 (branch feat/standalone-cheevos), design as agreed in chat 2026-11-13.
Phase 1 DONE offline 2026-11-13 (not pushed); D1 REVISED the same day (user: the token in its own
file, not RetroArch's settings), done offline; Phase 2 (HW) mostly HW-OK on Pocket FIT 2026-11-14 (notes below), merged to main.

## Why

The RetroArch plan gave gb, gbc, gba, snes, md, segacd and n64 RetroAchievements with one sign-in
(Settings > Library > RetroAchievements, `retroforge-cheevos`). Five standalone emulators we ship
have the same rcheevos client built in, and RetroAchievements' login token belongs to the account,
not to the program that asked for it: the token `login2` already gave us signs them in too.

| System(s) | Emulator (catalog pin) | Where it keeps the sign-in (under $HOME) | Hardcore | Booleans |
|---|---|---|---|---|
| psx | DuckStation v0.1-11894 | `.local/share/duckstation/settings.ini` `[Cheevos]` Enabled, Username, **Token encrypted** | ChallengeMode (default false) | true/false |
| ps2 | ARMSX2 2.9 (PCSX2) | `.config/ARMSX2/inis/PCSX2.ini` `[Achievements]` Enabled, Username; `inis/secrets.ini` `[Achievements]` Token | ChallengeMode (default false) | true/false |
| psp | PPSSPP v1.20.4 | `.config/ppsspp/PSP/SYSTEM/ppsspp.ini` `[Achievements]` AchievementsEnable, AchievementsUserName; token = the whole of `PSP/SYSTEM/ppsspp_retroachievements.dat` | AchievementsChallengeMode (**default true**) | True/False |
| gc, wii | Dolphin 2609 (pkgforge) | `.config/dolphin-emu/RetroAchievements.ini` `[Achievements]` Enabled, Username, ApiToken | HardcoreEnabled (**default true**) | True/False |
| dc | Flycast 2.7 (pkgforge) | `.config/flycast/emu.cfg` `[achievements]` Enabled, UserName, Token | HardcoreMode (default false) | yes/no |

Sources read 2026-11-13 at the pinned tags: duckstation `src/core/achievements.cpp` +
`settings.cpp`, ARMSX2 `pcsx2/Achievements.cpp` + `pcsx2-qt/QtHost.cpp` (secrets layer) +
`Pcsx2Config.cpp`, ppsspp `Core/RetroAchievements.cpp` + `UI/NativeApp.cpp` (NativeSaveSecret) +
`Core/Config.cpp`, dolphin `Core/Config/AchievementSettings.cpp` + `CommonPaths.h` (CMake
`USE_RETRO_ACHIEVEMENTS` ON by default), flycast `core/achievements/achievements.cpp` +
`core/cfg/option.cpp`.

Out of reach: melonDS 1.1 has no RetroAchievements; RetroAchievements does not cover 3DS, Wii U,
Xbox or PS3 (Azahar, Cemu, hakux, RPCS3). DS achievements would mean RetroArch's melonDS DS core: a
separate decision, not this plan.

### DuckStation's token

DuckStation keeps `Token` = base64(AES-128-CBC(token zero-padded to 16 bytes)), key = SHA-256 of
(the bytes of `/etc/machine-id`, newline included, then the user name), re-hashed 100 more times;
AES key = its first 16 bytes, IV = its last 16. Not portable mode (our settings are under
`.local/share/duckstation`). A token it cannot decrypt makes it ask for a login. Our machine-id is
made on the device at first boot and kept across OTA updates, so the launcher computes it on the
device at each launch (`openssl enc -aes-128-cbc -nopad`, token on stdin; the key is derived from
world-readable data anyway: obfuscation, not secrecy).

## Decisions (agreed 2026-11-13)

- **D1 One sign-in, in RetroForge's own file** (revised 2026-11-13; first draft kept it in
  RetroArch's `retroarch.cfg`). `~/.config/retroforge/retroachievements.json`
  (`{"version": 1, "user", "token", "hardcore"}`, 0600), written by `retroforge-cheevos` only.
  Why not `retroarch.cfg`: RetroArch rewrites it at exit (the tool had to refuse changes while it
  ran), may write it back 0644, and resetting RetroArch's settings would sign the player out of
  everything. RetroArch becomes the sixth `achievements` entry, written at launch like the others
  (quoted values, `cheevos_password` always empty). A sign-in made in RetroArch's own menu no
  longer counts for the others: replaced at RetroArch's next launch (D3).
- **D1b Homes that signed in before the file** (plugin 0.1.110-0.1.114): while the file is missing,
  the sign-in is read from `retroarch.cfg`, read only (status and launches create nothing); the
  player's first Sign in / Sign out / Hardcore change creates the file, which wins from then on.
  A sign-in file that is not one (not JSON, another version) writes nothing at launch and makes
  `status`/`hardcore` exit 5; Sign in and Sign out replace it (the player is never stuck).
- **D2 Written at launch, by the launcher.** Before each start of one of the five (game or Open),
  `retroforge-launch` writes the name, token, enabled flag and hardcore into that emulator's files,
  after the first-run seed (a file made first would keep the seed out for good). The emulator is
  not running then, so its own write-back on exit cannot undo it. Stays written, like an emulator-level option: no restore journal.
- **D3 RetroForge owns the sign-in.** Signed out in RetroForge: an empty name and token, achievements
  off, PPSSPP's token file removed. A sign-in or sign-out made in an emulator's own menu is replaced
  at its next launch. (Existing devices: a player who signed in only inside DuckStation/PPSSPP/...
  is signed out there at the first launch after the update, until they sign in in Settings.)
- **D4 One hardcore toggle, always written.** RetroForge's Hardcore row (default off, RetroArch plan
  D3) is written every launch, signed in or not: Dolphin and PPSSPP default to hardcore ON, which
  would block the Guide+L1 load-state hotkey.
- **D5 Data, not code, per emulator.** emulator.json gets an `achievements` list shaped like
  `system_settings` (file, format, separator, set), with placeholders `{user}`, `{token}`,
  `{duckstation_token}`, `{enabled}`, `{hardcore}`, the boolean words per entry (`"bool": ["True",
  "False"]`), and one extra format `secret` (the whole file = the value, removed when empty) for
  PPSSPP. A file that cannot be written is a warning, never a blocked game.
- **D6 Token files 0600.** Every file the launcher writes a non-empty token into is chmod 0600 before
  the token goes in (the emulators may rewrite them 0644 at exit: re-tightened at the next launch,
  HW check below).

## Phase 1 — launcher + definitions (offline)

- `lib/retroforge/python/achievements.py`: read the sign-in from `retroarch.cfg`; validate a
  definition's `achievements` entries; apply them (placeholders, booleans, `secret` format, 0600,
  DuckStation encryption via openssl); warnings only.
- `launch_def.py`: `achievements` key, validated; `retroforge-launch`: apply after
  `seed_first_run`, for games and `--gui`.
- emulator.json rows for duckstation, armsx2, ppsspp, dolphin, flycast; notes line each.
- Tests: new `tests/test-achievements.sh` (in `make test`): each real definition against a sandbox
  $HOME — signed in / signed out / hardcore on/off, seed kept, 0600, PPSSPP file removed on sign-out,
  DuckStation token decrypts back (openssl) with a fake machine-id, a bad definition refused, an
  unwritable file only warns; `test-launch.sh` still green.
- `retroforge-cheevos` header + plugin wording (cheevos_settings.gd / cheevos_text.gd: the systems
  list), plugin version bump, test-plugin.sh strings.
- Security review (token handling, file modes, argv) before commit.

### Phase 1 notes (2026-11-13)

- `achievements.py` + `achievements` in launch_def / the five emulator.json; applied after
  `seed_first_run` + `sync_files`, game and `--gui`. Plugin 0.1.114: the systems list in
  `cheevos_text.gd` (`SYSTEMS`), used by the user-name row and the signed-in line.
- Tests: `tests/test-achievements.sh` 71 (in `make test`); `test-launch.sh` 587 (seed checks now
  "file starts with the whole seed": the [Cheevos] section follows it; a signed-out and a signed-in
  DuckStation launch end to end); test-cheevos 43, test-plugin 152 (no Godot), emuopts/emu/emu-cores
  green.
- Security review: no CRITICAL/HIGH. Fixed: an unreadable retroarch.cfg writes nothing (was: signed
  out everywhere); a DuckStation token that cannot be encrypted writes that file signed out (was:
  the previous name/token kept); paths resolved before 0600 / unlink (symlinked settings). Left: a
  `.retroforge-<hex>` temp file after a power cut mid-write (0600, clutter only; emuopts-wide).

### D1 revision notes (2026-11-13)

- `achievements.py`: `read_sign_in` (file, else the old retroarch.cfg, else signed out; None =
  unknown) and `save_sign_in`. `retroforge-cheevos`: no RetroArch-running check, no seeding of
  retroarch.cfg, exit 5 = the sign-in file; status JSON drops `retroarch_running` (unused).
- Plugin: exit 5 is one message ("Your RetroAchievements sign-in could not be saved."), the
  "close the game first" text is gone.
- Tests: test-cheevos 49, test-achievements 83 (RetroArch as the sixth emulator, the old-place
  cases), test-launch 587, test-plugin 561 with Godot 4.7.1 arm64 + OGUI 0.47.0 compile.

## Phase 2 — HW (dev image)

0. On a card that already had a RetroArch sign-in (0.1.110+): still signed in after the update,
   in RetroArch and the five; the first Hardcore toggle creates retroachievements.json.
1. Sign in in Settings; start one game per emulator (RetroArch included): each shows its own
   "logged in as" toast. Sign in while a RetroArch game runs: allowed, reaches it next launch.
2. DuckStation: the token decrypts (no login prompt) — proves the machine-id newline / key details.
3. ARMSX2 2.9 and the pkgforge Dolphin are built with achievements (menu shows them).
4. Hardcore off: Guide+L1 loads a state in each; Hardcore on: refused, the emulator says hardcore.
5. Sign out in Settings: each emulator starts signed out, PPSSPP's `.dat` gone.
6. Modes after each emulator exits: the token files' mode (0644 after exit = acceptable only because
   the next launch re-tightens; note which ones).
7. One unlock in one standalone (softcore), seen on retroachievements.org.

### Phase 2 notes (2026-11-14, Pocket FIT, dev image 91487d90, fresh image)

- Step 0 not run: fresh image, no earlier sign-in.
- 1: DONE. Settings sign-in writes retroachievements.json (0600). Each emulator logged in at its
  first launch, on the seeded config: RetroArch (armgba core, gba), DuckStation, Flycast, PPSSPP,
  ARMSX2 and Dolphin. Dolphin's log shows "loki666 logged in successfully". Its red "not supported
  for this title" popup came from RetroAchievements: the NSMB Wii WBFS hash is not in RA's list,
  although NSMB Wii (game 95) is.
- 2: DONE. DuckStation accepted the encrypted token and added its own AvatarURL.
- 3: DONE. ARMSX2 and Dolphin both log in.
- 4: Hardcore on reached DuckStation (ChallengeMode) and Flycast (HardcoreMode), and both said
  hardcore. Guide+L1 refusal not tried.
- 5: DONE on DuckStation and Flycast: Enabled off, user and token emptied, the emulators' own keys
  (DuckStation AvatarURL) kept. PPSSPP `.dat` removal not checked.
- 6: Flycast emu.cfg, DuckStation settings.ini and ARMSX2 PCSX2.ini/secrets.ini stay 0600 after
  exit; ARMSX2 moves the token from PCSX2.ini to its secrets.ini. Dolphin rewrites
  RetroAchievements.ini as 0644 at exit, and the next launch re-tightens it (home is 0700).
- 7: not tried.
- Found along the way, not this branch: Flycast silent on a board without a mic (SDL3 opens the
  retroforge-fallback node), issue #45.
