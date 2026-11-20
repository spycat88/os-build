# PSN games (.pkg) via RPCS3 — plan

Status: Phase 1 DONE 2026-10-20 on branch feat/psn-pkg (not committed): retroforge-launch `stub`
key (validation, stub_boot_target, bad-stub status, not-installed checked first) + rpcs3
emulator.json stub/notes + test-launch.sh "stub ROMs" case (suite 417/0; emu 142, emuopts 596,
catalog 204 all green). python-reviewer: both HIGHs fixed — stubs read as strict UTF-8 (binary
file = bad-stub, never mojibake) and the id allowlisted STUB_ID `[A-Za-z0-9_]{1,64}` (no path /
option / control chars / BOM can reach the command line); its MEDIUM "plugin doesn't know
bad-stub" lands with phase 3 (noted there). Memory: rpcs3-psn-pkg.md.
Phase 2 DONE 2026-10-20 (not committed): `--psn-install` verb + fake-emu --installpkg branch +
"PSN inbox" test case (suite 442/0; emu/emuopts/catalog/shares/session green). Deviations from the
phase text below: result lines are TAB-separated (file names carry spaces; names the lines cannot
carry are skipped), and installed-verify is game/<id>/PARAM.SFO present AND the dir touched by
THIS run (tree_changed vs a probe-file fs timestamp — a stale earlier install never verifies a
re-dropped broken pkg; one id's pkgs verify collectively, documented in the header), EBOOT.BIN
only gating stub creation. python-reviewer pass 2: no CRITICAL, path safety confirmed airtight;
fixed H1 (stale-install verify, above), M1 (RPCS3 stdout redirected off the result lines), M2
(TITLE truncated by UTF-8 bytes, NAME_MAX), M3 (psn_write_stub never reports a stranger's file),
M4 (vfs.yml parse handles quotes + $(EmulatorDir), logs the resolved dev_hdd0), M5 (filename
filter = printable + encodable), M6 (flock, RETROFORGE_PSN_LOCK), M7 (licence verified by content
compare, not existence). H2 accepted as HW question (see phase 5): if RPCS3 leaves CATEGORY "GD"
after base+update in ONE batch, the base gets no card; recovery = re-drop the base pkg (reinstall
wins), revisit if HW confirms.
Phase 4 DONE 2026-10-20 (not committed): retroforge-home.conf `d %h/roms/ps3/psn` + README `C+`
row, psn-readme.txt beside the rpcs3 seeds, test-launch rows (suite 445/0; shares 29, units 18).
Phase 3 DONE 2026-10-20 (not committed): psn_runner.gd (worker-thread verb runner, result-line
parse, no cancel — SIGTERM would kill RPCS3 mid-extract) + psn_settings.gd (Settings > Library
"Install PSN packages (N)" row, hidden when the inbox is empty, refreshed on menu visibility,
refused while a game runs, library reload when a run made stubs) + plugin.gd wiring (psn before
scraper so ROM Art stays on top) + library_roms.gd ps3 exts += psn and the bad-stub popup +
scraper systems.json psn + plugin 0.1.61 + psn-runner case in test-plugin.sh (Godot-gated, skips
without a local Godot like the scrape-runner case; static checks green). Suites: plugin 81,
scrape 113, ui 301, plugin-install 14 — all 0 failed. code-reviewer: APPROVE, 0 CRIT/HIGH/MED;
its LOWs fixed (visibility_changed disconnected in detach + nodes nulled, pending() guards a
deleted inbox, the no-cancel-on-unload choice commented); its remaining LOW is a phase 5 HW item:
gamepad focus when the row hides after a successful run (FocusGroup vs a hidden focused child).
Remaining: phase 5 HW on the ACE. 2026-10-20 first HW pass (dev image 20261020T155335Z, over SSH):
image plumbing OK (inbox + README on first boot), plugin 0.1.61 loads with zero GDScript errors
and both settings rows attach, empty inbox -> nothing-to-do exit 0, garbage pkg -> real headless
RPCS3 ran, `failed` line, exit 3, file kept; vfs seeded, dev_hdd0 on ~/saves/ps3 (RPCS3 makes an
empty game/TEST12345/USRDIR probe — harmless, no PARAM.SFO). Real install (Retro City Rampage DX,
2 pkgs same id in ONE batch): both ok, **H2 ANSWERED: final CATEGORY stays HG**, one stub
"Retro City Rampage™ DX.psn" (TITLE verbatim incl. ™), inbox consumed to just README, EBOOT.BIN
present, rom_watch picked the stub up in the running shell (Found 1 ROM). Second HW round: user missed the
UI step on the first drop (no bug). Launch from the card: **stub boot verified** — launcher ran
`%RPCS3_GAMEID%:NPUB31616` and RPCS3 accepted it; **firmware install-block verified** (PUP run
exited -6 but version.txt check passed = installed, next boot FW 4.93). Boot then failed in
RPCS3 itself: no .rap in exdata ("Failed to locate the game license file ...RETROCITYRAMPAGE.rap"
-> "Failed to decrypt content"), shown as RPCS3's own error dialog whose process lingers (killed
over SSH; a failed NPDRM boot = RPCS3 error window, not a launcher status). Round 3: cause of the
NPDRM stop confirmed — same-batch pkg order is RPCS3's enumeration (Crack sorted before Full, so
the original EBOOT landed last). Re-drop of the crack pkg alone via **the UI button: verified**
(pkg consumed, stub reused = no second card, library reloaded, user confirmed the flow) and the
card then **booted past NPDRM** (PPU precompile on first boot). Still open on HW: rap -> exdata
path (no .rap at hand; covered by the suite's content-compare tests), art scrape on the card,
gamepad focus when the row hides after a run.

## Why

RPCS3 in the image only runs disc games (an .iso, or a decrypted disc folder with
PS3_GAME/USRDIR/EBOOT.BIN). PSN titles are .pkg files and are never booted directly: RPCS3 must
install them into the emulated HDD (dev_hdd0/game/<TITLEID>/), and most need a .rap licence
beside the install. Nothing in RetroForge scans, installs or launches them today.

## The player's story

1. Drop .pkg files (base game, updates, DLC) and their .rap licences into `~/roms/ps3/psn/` — the
   PSN inbox. The inbox is CONSUMED: a successfully installed file is deleted; a failed one stays
   (visible and retryable). A README.txt in the folder states this contract, so the player who
   finds the folder over the network share learns the rules before dropping anything.
2. Trigger the install from the shell (Settings > Library, "Install PSN packages (N)"), watch
   progress.
3. Each installed game appears as a normal PS3 card, named after the game: the install writes a
   stub `~/roms/ps3/<Game Name>.psn` whose single line is the title id. Deleting the stub removes
   the card (not the installed game); renaming the stub renames the card, like any ROM.

## Facts checked against RPCS3 master (2026-10-20, rpcs3.cpp / main_window.cpp / System.h)

- `--installpkg <path>` + `--headless` installs with no dialogs (`InstallPackages(nullptr, …)`,
  rpcs3.cpp:1182). `--no-gui` instead is a fatal error ("Cannot perform installation in no-gui
  mode!") — install runs are ALWAYS `--headless`. `--installfw` and `--installpkg` may share one
  headless invocation.
- `<path>` may be a DIRECTORY: every file in it is processed — `.rap`/`.edat` are copied to
  `dev_hdd0/home/<user>/exdata/<name>.<lowercased ext>` (a plain copy, nothing consumed), every
  `.pkg` is extracted; other files are ignored (extension-filtered). Raps are processed BEFORE
  pkgs in the same call, and order is irrelevant anyway: the licence is only read at boot, when
  RPCS3 decrypts the NPDRM EBOOT/edat. The rap must be named `<CONTENTID>.rap` (PSN dumps are).
- Exit code is 0 even on failure (same flaw as `--installfw`, rpcs3.cpp returns 0 after the
  install branch): success = the expected files exist afterwards.
- Title id without RPCS3: the pkg header holds the 36-char content id at offset 0x30
  (`UP0001-NPUB30024_00-…`); title id = chars 7..15 (`NPUB30024`). Retail pkg magic: 7F 50 4B 47
  ("\x7FPKG") at offset 0.
- Install target: `dev_hdd0/game/<TITLEID>/` with `USRDIR/EBOOT.BIN` as boot file. Our vfs.yml
  maps /dev_hdd0/ to `~/saves/ps3/dev_hdd0/`, so installed PSN games live (and must live — one
  dev_hdd0, licences and updates are tied to it) on the saves share. NAS note: a game is GBs.
- `PARAM.SFO` in the installed dir always carries TITLE (it is what RPCS3's game list shows) and
  CATEGORY: "HG" = HDD (PSN) game, "GD" = game data/disc update, "AC" = DLC, "DG" = disc game. A
  tiny binary key/value table — parse in the launcher, no RPCS3 involved.
- Boot by id: positional arg `%RPCS3_GAMEID%:<TITLEID>` (System.h game_id_boot_prefix) — RPCS3
  resolves the location through its own VFS, so the launcher never needs the dev_hdd0 path.
- RPCS3's headless install fetches the compat DB first (RequestCompatibility); offline it logs and
  carries on — pkg validity comes from the file.
- dev_hdd0/game/ must not be scanned for cards: disc updates (GD) have their own EBOOT.BIN there
  and would become ghost cards. The .psn stub sidesteps dev_hdd0 scanning entirely.

## Decisions

- **D1 — stub = the ROM.** `~/roms/ps3/<Game Name>.psn`, content = the title id on one line. The
  stub flows through everything keyed on ROM files unchanged: RomNames (card name = filename),
  per-game .conf (Game settings, CPUS), stale-card removal, ScreenScraper art by name.
- **D2 — generic launcher stub mechanism, declared per emulator.** emulator.json gains
  `"stub": {"psn": "%RPCS3_GAMEID%:{text}"}`: for a ROM whose extension matches, retroforge-launch
  reads the file's first line (trimmed; must be non-empty, no whitespace) and substitutes it for
  `{text}`; the result replaces `{rom}` in args. Garbage/empty stub = a failed launch with its own
  status for the plugin toast. No RPCS3 knowledge in the launcher core.
- **D3 — install logic lives in retroforge-launch, UI in the plugin.** New verb
  `retroforge-launch --psn-install`: the launcher already owns AppImage mounting, env and the
  definition; the plugin must not duplicate that. The verb has no timeout cap (a multi-GB extract
  on SD takes minutes) and prints one machine-readable result line per pkg for the plugin.
  NOT at library load (the auto-scrape lesson: load-time heavy work was ripped out for
  art_fetch.gd) and NOT via `install`/`setup_args` (fixed paths; SETUP_TIMEOUT 20 s).
- **D4 — stub only for CATEGORY "HG".** Update/DLC pkgs install into existing dirs and must not
  create cards. A stub whose title id already has one is not rewritten.
- **D5 — name from installed PARAM.SFO TITLE**, sanitized for a filename (strip `/` and control
  chars, collapse whitespace, no leading dot); title collision with a different id → append
  ` (<TITLEID>)`. TITLE missing/unparseable → `<TITLEID>.psn`; the player can rename.
- **D6 — the inbox is consumed.** Per pkg: verified installed (title id from the header →
  `dev_hdd0/game/<id>/USRDIR/EBOOT.BIN` exists) → stub written (HG only) → pkg deleted. A rap is
  deleted once its copy exists in exdata. Failures stay in the inbox. Documented contract of the
  folder; nothing else in ~/roms is ever deleted.
- **D7 — no uninstall.** Deleting the stub removes the card only; the dev_hdd0 install stays
  (file-manager affair, like disc dumps).
- **D8 — guard:** the plugin refuses to start an install while a PS3 game is running (one
  dev_hdd0; a headless RPCS3 and a playing one must not fight). The verb itself stays dumb.
- **D9 — README.txt in the inbox**, shipped in the image (source beside the rpcs3 seeds,
  `/usr/share/retroforge/emulators/rpcs3/psn-readme.txt`) and placed by a user-tmpfiles `C+` row,
  so it exists from the first session and image updates refresh it (a plain `C` would pin the
  first version forever; the launcher `sync` mechanism would only place it after an rpcs3 launch).
  Player-facing, short: what to drop (.pkg + .rap, updates and DLC too), where the install is
  triggered (Settings > Library), that installed files are DELETED from this folder and failed
  ones stay, that the game then appears as a card named after itself, and that this folder is the
  only place RetroForge ever deletes player files. The install verb ignores it (not a result
  line); it is not a card (scanner ignores non-ROM extensions).
- **D10 — one RPCS3 at a time** (added after the 2026-10-20 HW pass, where launching the game
  while a second RPCS3 ran ended in earlyoom killing it: two RPCS3s do not fit in the ACE's
  8 GiB, besides sharing one dev_hdd0). The installer's flock (PSN_LOCK) is now taken by a ps3
  GAME launch too (`try_psn_lock`, held for the launcher process's life, so it releases when the
  game exits): a launch mid-install fails exit 3 with new status `psn-installing <emulator>`
  (plugin popup "PSN packages are installing…"); an install mid-game is refused on the lock even
  when started outside OGUI (the plugin's D8 guard still gives the friendlier message first). The
  `--gui` session is deliberately unguarded. Plugin 0.1.62. python-reviewer: approve with fixes,
  all applied — H1 the tests' timed `flock -c sleep` holder replaced by an fd holder that signals
  when it truly holds (and releases on demand); M1 a broken lock PATH is told apart from
  contention (installer refuses with the real error, a game launch logs "launching unguarded" and
  still starts — the guard must not brick ps3 launches); M2 the started RPCS3 inherits the lock
  fd via pass_fds (flock follows the open file description), so a SIGKILLed launcher no longer
  frees the lock while RPCS3 lives. Declined LOWs: /tmp fallback hygiene and keying the guard on
  the emulator rather than system "ps3" (single-user device; launch.conf has one ps3 mapping).
  NOT yet HW-tested (the guard landed after the 2026-10-20 pass; rides the next dev image).
- **D11 — card box art seeded from ICON0.PNG** (after the HW pass: RCR DX's card was blank —
  digital-only titles often have no box scan on ScreenScraper; its fanart/wheel DID download, so
  only the portrait card suffered). `--psn-install` copies the installed game's own ICON0.PNG
  (Sony-mandated; the XMB's icon) to `<media>/ps3/<stub>-box.png` when writing/reusing a stub and
  no box exists yet. A fresh stub still scrapes in full (no cache entry), and a real box download
  overwrites the seed — real art wins; no plugin or scraper change. Failures are cosmetic (logged,
  never result lines). MEDIA_DIR honors RETROFORGE_MEDIA_DIR like the scraper. HW: the RCR DX box
  was hand-seeded on the ACE the same way (the code path itself rides the next card).
  python-reviewer: BLOCK on one HIGH, all fixed — the icon comes from a player-supplied pkg, so
  the seed is size-capped (1 MiB), checked (PNG signature + sane IHDR dimensions ≤ 2048: the
  scraper treats ANY existing box as art, so a junk seed would silence a real one forever), landed
  with os.link (never replaces a name: art racing in from the scraper wins, and a dangling-symlink
  destination fails instead of writing through), and the whole function catches Exception — any
  failure is one stderr log line, never a broken result protocol or an unconsumed pkg. Tests:
  junk + oversized ICON0 in one batch (no seed, a log each, installs still ok), unwritable media
  folder (logged, result line intact). Declined LOW: a symlinked ICON0 source is followed (needs a
  hostile game dir; the content checks above bound the damage). Considered and REJECTED by the
  user (2026-10-20, shown side by side): seeding PIC1 (the 1080p XMB background) as the box
  instead of ICON0 — "that's worse". ICON0 stays the seed; a logo-on-transparency ICON0 (Super
  Stardust) crops ugly, accepted as how it is.

## Phases

1. **Launcher: stub boot.** `stub` key in load_definition (dict ext -> template containing
   `{text}` exactly once; ext without whitespace/dots), resolution before arg substitution, new
   failure status (`bad-stub <emulator> <path under $HOME>`). rpcs3 emulator.json gains the key +
   a notes line. tests/test-launch.sh: good stub (args carry `%RPCS3_GAMEID%:NPUB30024`), empty
   stub, whitespace id, stub ext not in definition (falls through as a plain ROM path → RPCS3
   errors, acceptable), definition validation negatives.
2. **Launcher: `--psn-install`.** Flow: resolve ps3 -> rpcs3 via launch.conf; mount the AppImage
   (existing machinery); inventory `~/roms/ps3/psn/` (*.pkg/*.rap/*.edat, either case, flat — no
   recursion contract); parse each pkg header (magic + content id; unparseable = reported, left);
   one `rpcs3 --headless --installpkg <inbox>` run, no timeout; per pkg verify EBOOT.BIN, read
   PARAM.SFO (TITLE, CATEGORY), write stub per D4/D5, delete per D6; verify rap copies in exdata
   (name match) then delete; stdout one line per file:
   `ok|failed|skipped <file> <titleid|-> <stub name|->`, exit 0 when everything succeeded, 3
   otherwise (matching the existing install-failed convention). Empty inbox: `nothing-to-do`,
   exit 0. tests/test-launch.sh: crafted pkg header fixtures + a fake rpcs3 that "installs"
   (writes EBOOT.BIN + PARAM.SFO fixtures) — ok / failed-verify / GD-no-stub / title collision /
   TITLE-missing fallback / rap copied+deleted / rap not copied kept / garbage file ignored /
   README.txt ignored silently (no result line, never deleted).
3. **Plugin.** library_roms.gd LaunchFailure gains the "bad-stub" match arm ("reinstall the
   package", per the launcher header's promise); Settings > Library row "Install PSN packages (N)" (scraper_settings.gd /
   scrape_runner.gd pattern: threaded subprocess, progress = indeterminate busy + per-line
   results as they print), hidden when the inbox is empty; D8 guard; refresh/let rom_watch pick
   up new stubs; `psn` added to ps3 exts in library_roms.gd; scraper/systems.json ps3 exts +=
   "psn"; plugin.json version bump. tests: test-plugin.sh, test-scrape.sh, test-ui.sh.
4. **Image plumbing.** retroforge-home.conf: `d %h/roms/ps3/psn` row and the D9 README `C+` row
   (+ their test-launch/shares rows if the suites check the skeleton); psn-readme.txt written
   beside the rpcs3 seeds; emulator.json notes already updated in phase 1; check whether any doc
   lists per-system formats (gopher64 phase 4 found none — expect NO-OP).
5. **HW on the ACE.** Real pkg + rap in the inbox: install from the shell with progress, card
   — and the H2 question first: drop a base game + its update in ONE batch and check
   dev_hdd0/game/<id>/PARAM.SFO's CATEGORY afterwards (stays "HG" = fine; "GD" = the base gets no
   card and the stub rule needs rework). Then:
   appears named from PARAM.SFO, art scrape by name, boot via `%RPCS3_GAMEID%:`, licence honoured
   (game starts past the NPDRM check), update pkg installs without a second card, failed/garbage
   pkg stays in the inbox with a readable result. Also: README.txt present in the inbox on a
   fresh image and survives an install run; firmware-missing path still works (stub launch goes
   through the normal flow, so the PS3UPDAT.PUP install step fires as today); gamepad focus is
   sane when the settings row hides itself after a successful run (code-reviewer LOW: FocusGroup
   vs a hidden focused child).

## Out of scope / later

- Uninstall UI (D7), split/multi-part pkg
  archives, an automatic install trigger on inbox changes (rom_watch could, deliberately not:
  install is minutes of IO the player should start), moving dev_hdd0 off the saves share.
