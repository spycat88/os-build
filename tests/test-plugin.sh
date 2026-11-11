#!/usr/bin/env bash
# Offline test for the RetroForge OpenGamepadUI plugin's packaging (plan Phase 4).
#
#   tests/test-plugin.sh
#
# WHY THIS EXISTS. OGUI loads a plugin with no feedback when it is subtly wrong, and none of it
# shows until a card fails to appear on a device:
#
#   - a zip without plugins/<id>/plugin.json, or a plugin.json missing one of the fields
#     PluginLoader requires, is skipped with a warning nobody sees;
#   - a min-api-version OGUI's API (2.0.0 in v0.46.1) is not feature-compatible with: skipped;
#   - an entrypoint that is not in the zip: "Unable to load plugin";
#   - a script that overrides _init() replaces its base class's constructor: Library._init is what
#     registers a library on ready, so the ROM library silently never loaded (HW, 2026-10-04).
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/apps/ogui-retroforge-plugin/plugin"
BUILD="$ROOT/apps/ogui-retroforge-plugin/build.sh"
OGUI_API="2.0.0"   # PluginLoader.PLUGIN_API_VERSION in the pinned OGUI (packages/opengamepadui)

PASS=0; FAIL=0; CASE=""
ok()  { PASS=$((PASS+1)); printf '  ok   %s -- %s\n' "$CASE" "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s -- %s\n' "$CASE" "$1"; }

[ -f "$SRC/plugin.json" ] && [ -x "$BUILD" ] || { echo "missing plugin sources or build.sh" >&2; exit 1; }
command -v python3 >/dev/null || { echo "python3 is required" >&2; exit 1; }
T="$(mktemp -d)" && [ -d "$T" ] || { echo "mktemp -d failed" >&2; exit 1; }
trap 'rm -rf "$T"' EXIT

# =================================================================================================
CASE="plugin.json"
meta() { python3 -c 'import json,sys; m=json.load(open(sys.argv[1])); print(m.get(sys.argv[2], ""))' "$SRC/plugin.json" "$1"; }
python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$SRC/plugin.json" 2>/dev/null \
  && ok "is valid JSON" || bad "does not parse"
for field in plugin.id plugin.name plugin.version plugin.min-api-version entrypoint; do
  [ -n "$(meta "$field")" ] && ok "has $field (PluginLoader requires it)" || bad "lacks $field: OGUI skips the plugin"
done
[ "$(meta plugin.id)" = retroforge ] && ok "id is retroforge (the zip must be retroforge.zip)" || bad "id is '$(meta plugin.id)'"
[[ $(meta plugin.version) =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] && ok "version is semver (upgrades compare it)" || bad "version '$(meta plugin.version)' is not x.y.z"
# SemanticVersion.is_feature_compatible: same major, and min-api minor/patch not above OGUI's.
api="$(meta plugin.min-api-version)"
python3 - "$api" "$OGUI_API" <<'PY' && ok "min-api-version $api works with OGUI's API $OGUI_API" || bad "min-api-version $api is not compatible with OGUI's API $OGUI_API"
import sys
want, have = ([int(x) for x in v.split(".")] for v in sys.argv[1:3])
sys.exit(0 if want[0] == have[0] and want[1:] <= have[1:] else 1)
PY
[ -f "$SRC/$(meta entrypoint)" ] && ok "entrypoint $(meta entrypoint) exists" || bad "entrypoint $(meta entrypoint) is not in plugin/"

# =================================================================================================
CASE="scripts"
for gd in "$SRC"/*.gd; do
  name="$(basename "$gd")"
  head -1 "$gd" | grep -Eq '^extends ' && ok "$name starts with extends" || bad "$name has no extends line"
  grep -Eq '^func _init\(' "$gd" \
    && bad "$name overrides _init(): it replaces the base constructor (Library._init registers the library)" \
    || ok "$name does not override _init()"
done
grep -q '^extends Plugin$' "$SRC/$(meta entrypoint)" && ok "the entrypoint extends Plugin" || bad "the entrypoint does not extend Plugin"
# OGUI is a release export: a component's method called before it is in the tree (its @onready
# children still null) segfaults OGUI instead of erroring. scraper_settings.gd filled its dropdown
# before add_child and OGUI crashed at every start (ACE, 2026-10-17).
python3 - "$SRC/scraper_settings.gd" <<'PY2' && ok "scraper_settings.gd fills its dropdown only once it is in the tree" || bad "scraper_settings.gd calls the dropdown before add_child: OGUI segfaults"
import sys
s = open(sys.argv[1]).read()
add, fill = s.find("box.add_child(node)"), s.find("_region.clear()")
sys.exit(0 if 0 <= add < fill and s.find("_region.add_item") > add else 1)
PY2
# The same crash rule for the Updates section: the channel dropdown is filled after add_child.
python3 - "$SRC/retroforge_os.gd" <<'PY2' && ok "retroforge_os.gd fills its dropdown only once it is in the tree" || bad "retroforge_os.gd calls the dropdown before add_child: OGUI segfaults"
import sys
s = open(sys.argv[1]).read()
add, fill = s.find("box.add_child(node)"), s.find("_channel.item_selected.connect(_on_channel_selected)\n\t_load_state()")
sys.exit(0 if 0 <= add < fill and s.find("await _fill_channels()") > s.find("func _load_state()") > 0
         and s.find("_channel.clear()") > 0 and s.find("_channel.add_item") > 0 else 1)
PY2
# retroforge-launch's missing-file status names every choice of a system_requires "any" (the Mega CD
# BIOS of any region): the message must take them all, not only exactly one path.
grep -q 'if words.size() < 3:' "$SRC/library_roms.gd" && grep -q 'for file_path in words.slice(2):' "$SRC/library_roms.gd" \
  && grep -q '"one of " + ", ".join(files)' "$SRC/library_roms.gd" \
  && ok "library_roms.gd names every file a missing-file status lists" \
  || bad "library_roms.gd reads only one missing-file path (system_requires lists choices)"

# A Revert row runs its own args: a RetroArch core's carries --core=<core>, which a hardcoded
# ["rollback", id] would drop (and revert RetroArch itself instead).
grep -q '_rollback.bind(id, name_text, args, row)' "$SRC/apps_page.gd" \
  && grep -q 'var cmd := Command.create(EMU_TOOL, args)' "$SRC/apps_page.gd" \
  && ! grep -q 'Command.create(EMU_TOOL, \["rollback", id\])' "$SRC/apps_page.gd" \
  && ok "apps_page.gd reverts with the row's own args (a core's --core=)" \
  || bad "apps_page.gd reverts with a fixed [rollback, id]: a core's Revert would revert RetroArch"

# The RetroAchievements password goes to retroforge-cheevos on stdin (the runner's second argument),
# never in its argv, and the field is emptied after every attempt.
grep -q '_login.start(\["login", user\], password)' "$SRC/cheevos_settings.gd" \
  && ! grep -qE 'OS.execute\(TOOL, \[[^]]*password' "$SRC/cheevos_settings.gd" \
  && grep -q '_password.text = ""' "$SRC/cheevos_settings.gd" \
  && ok "cheevos_settings.gd hands the password over on stdin only, then clears it" \
  || bad "cheevos_settings.gd: the password must go on stdin (start(args, password)) and be cleared"
grep -q 'load(plugin_base.path_join("cheevos_settings.gd"))' "$SRC/plugin.gd" && grep -q '_cheevos.detach()' "$SRC/plugin.gd" \
  && ok "plugin.gd attaches and detaches the RetroAchievements section" || bad "plugin.gd does not load cheevos_settings.gd"

# Settings > Network > VPN (tailscale_settings.gd). `tailscale up` refuses a run that does not repeat
# every non-default setting, so each run must pass the netfilter mode the first one set; the sign-in
# QR code comes from `up --json` (a PNG data URL), and our dialog copy must stay out of the group
# OGUI looks its own dialog up by.
grep -q 'load(plugin_base.path_join("tailscale_settings.gd"))' "$SRC/plugin.gd" && grep -q '_tailscale.detach()' "$SRC/plugin.gd" \
  && ok "plugin.gd attaches and detaches the Tailscale section" || bad "plugin.gd does not load tailscale_settings.gd"
grep -q 'const UP_FLAGS := \["--netfilter-mode=off"\]' "$SRC/tailscale_settings.gd" \
  && grep -q 'args.append_array(PackedStringArray(UP_FLAGS))' "$SRC/tailscale_settings.gd" \
  && grep -q '"up", "--json"' "$SRC/tailscale_settings.gd" \
  && ok "tailscale_settings.gd runs up --json with the same netfilter mode every time" \
  || bad "tailscale_settings.gd: every tailscale up must pass --json and UP_FLAGS"
grep -q 'if line == "{":' "$SRC/tailscale_settings.gd" && grep -A1 'if line == "{":' "$SRC/tailscale_settings.gd" | grep -q 'buffer = ""' \
  && ok "tailscale up's warning lines before a JSON object are dropped, not parsed with it" \
  || bad "tailscale_settings.gd must restart its buffer at each '{' line: the netfilter warning hid the sign-in URL"
grep -q '_dialog.remove_from_group(group)' "$SRC/tailscale_settings.gd" \
  && ok "the Tailscale sign-in dialog leaves OGUI's dialog group" || bad "the Tailscale sign-in dialog stays in group dialog"
grep -q '^ExecStartPost=-/usr/bin/tailscale set --operator=player$' "$ROOT/rootfs/overlay/usr/lib/systemd/system/tailscaled.service.d/retroforge.conf" \
  && ok "tailscaled makes player its operator (the switch runs the CLI as the session user)" \
  || bad "tailscaled.service.d does not set --operator=player: the switch would be refused"
# Off by default: nothing may start tailscaled at boot (no preset, no enable link); the switch
# starts and stops it through polkit, and that rule grants exactly start/stop of this one unit.
ts_enabled=0
grep -rqsE '^enable[[:space:]]+tailscaled' "$ROOT/rootfs/overlay/usr/lib/systemd/system-preset" && ts_enabled=1
[ -n "$(find "$ROOT/rootfs/overlay" -path '*.wants/tailscaled.service' 2>/dev/null)" ] && ts_enabled=1
[ "$ts_enabled" = 0 ] && ok "tailscaled is not enabled at boot (no preset, no .wants link)" \
  || bad "something enables tailscaled at boot: Tailscale must stay off until the player turns it on"
grep -q 'settings.get_value(SECTION, KEY, false)' "$SRC/tailscale_settings.gd" \
  && ok "the Tailscale switch defaults to off" || bad "tailscale_settings.gd: the stored choice must default to off"
TS_RULE="$ROOT/rootfs/overlay/usr/share/polkit-1/rules.d/50-retroforge-tailscale.rules"
if [ ! -f "$TS_RULE" ]; then
  bad "missing: ${TS_RULE#"$ROOT"/}"
elif ! command -v node >/dev/null; then
  printf '  skip %s -- no node to evaluate %s\n' "$CASE" "${TS_RULE#"$ROOT"/}"
else
  verdicts="$(node - "$TS_RULE" <<'JS'
const fs = require("fs");
let rule;
global.polkit = { Result: { YES: "yes", NO: "no" }, addRule: f => { rule = f; } };
eval(fs.readFileSync(process.argv[2], "utf8"));
const ask = (id, unit, verb, active = true, wheel = true, local = true) =>
  rule({ id, lookup: k => ({ unit, verb })[k] }, { active, local, isInGroup: g => g === "wheel" && wheel }) || "pass";
const M = "org.freedesktop.systemd1.manage-units", U = "tailscaled.service";
console.log([
  ask(M, U, "start"), ask(M, U, "stop"), ask(M, U, "restart"), ask(M, "sshd.service", "start"),
  ask(M, U, "start", false), ask(M, U, "start", true, false), ask(M, U, "start", true, true, false),
  ask("org.freedesktop.systemd1.manage-unit-files", U, "enable"),
].join(" "));
JS
)"
  [ "$verdicts" = "yes yes pass pass pass pass pass pass" ] \
    && ok "polkit grants start/stop of tailscaled to the active local wheel session, nothing else" \
    || bad "50-retroforge-tailscale.rules verdicts: $verdicts"
fi

# OGUI never calls ready() on our OS platform (it knows no `retroforge` OS): plugin.gd must, and
# only where OGUI detected none.
grep -q 'if platform.os or not platform.os_info or platform.os_info.id != "retroforge":' "$SRC/plugin.gd" \
  && grep -q '_os.ready(get_tree().root)' "$SRC/plugin.gd" \
  && ok "plugin.gd installs the RetroForge OS platform only over none, and calls its ready()" \
  || bad "plugin.gd does not install retroforge_os.gd as platform.os (or would replace OGUI's)"
grep -q '^extends OSPlatform$' "$SRC/retroforge_os.gd" && ok "retroforge_os.gd extends OSPlatform" || bad "retroforge_os.gd does not extend OSPlatform"

# BoxArtManager refuses a provider whose provider_id is empty when it becomes ready.
grep -q 'load(plugin_base.path_join("boxart_retroforge.gd"))' "$SRC/plugin.gd" && grep -q 'add_boxart(art)' "$SRC/plugin.gd" \
  && grep -q '^	provider_id = "retroforge"$' "$SRC/boxart_retroforge.gd" \
  && ok "the art provider is added, with an id (BoxArtManager refuses an empty one)" || bad "boxart_retroforge.gd is not added by plugin.gd, or has no provider_id"
# A download's progress poll outlives the page's rows (the player leaves Emulators and comes back):
# it finds the row by emulator id on every tick. Bound to a row, every tick errored on the freed
# row and the shown progress froze, and an install looked stuck (HW, Pocket FIT, 2026-10-19).
grep -q '_show_progress_file.bind(str(emu.get("progress")), id)' "$SRC/apps_page.gd" \
  && grep -q '_show_progress.bind(part, int(emu.get("size", 0)), id)' "$SRC/apps_page.gd" \
  && ! grep -qE '_show_progress(_file)?\.bind\(.*, row\)' "$SRC/apps_page.gd" \
  && ok "the download progress poll finds its row by emulator id, not a row the page may have freed" \
  || bad "apps_page.gd binds a row to its progress poll: it freezes once the page rebuilds its rows"
# The store sign-in's window (.claude/plans/store-signin-window.plan.md, D3): Chromium opens on OGUI's
# game display and is adopted as one of OGUI's running apps, so OGUI focuses it as a game. Its windows
# were orphans behind OGUI otherwise (black screen, Pocket FIT 2026-10-29). OGUI's own is_running()
# (OS.is_process_running) only knows Godot's children and its kill() (Reaper) spares the pid it is
# given: signin_app.gd overrides both.
grep -q 'args.append_array(\["--display", display\])' "$SRC/store_settings.gd" \
  && grep -q '_window.adopt(int(data.get("pid", 0)), _on_cancel.bind(store))' "$SRC/store_settings.gd" \
  && [ "$(grep -c '_window.release()' "$SRC/store_settings.gd")" -ge 3 ] \
  && ok "store_settings.gd opens the sign-in on the game display, adopts its window and releases it" \
  || bad "store_settings.gd does not pass --display, adopt the window on open, or release it on closed/finish/detach"
grep -q 'launch_manager._add_running(app)' "$SRC/signin_window.gd" && grep -q 'state_machine.push_state(in_game_state)' "$SRC/signin_window.gd" \
  && grep -q 'xwayland.set_app_id(window, app.app_id)' "$SRC/signin_window.gd" \
  && ok "signin_window.gd makes Chromium a running app, in the in-game state, its windows carrying the app id" \
  || bad "signin_window.gd does not register Chromium with OGUI as a running app"
grep -q '^extends RunningApp$' "$SRC/signin_app.gd" && grep -q '^func is_running() -> bool:$' "$SRC/signin_app.gd" \
  && grep -q '^func kill(_sig: Reaper.SIG = Reaper.SIG.TERM) -> void:$' "$SRC/signin_app.gd" \
  && ok "signin_app.gd overrides RunningApp's is_running() and kill() with their signatures" \
  || bad "signin_app.gd does not override is_running()/kill() as RunningApp declares them"
# OGUI's Main menu frees a running-game card only on app_killed, which its own stop emits after the
# state: release() must too, or every sign-in left a "RetroForge store sign-in" card behind.
python3 - "$SRC/signin_window.gd" <<'PY2' && ok "release() stops the app as OGUI does: STOPPED, then app_killed" || bad "signin_window.gd release() does not emit app_killed after STOPPED: a stale running-game card stays"
import sys
s = open(sys.argv[1]).read()
body = s[s.index("func release()"):]
st, kill = body.find("app.state = RunningApp.STATE.STOPPED"), body.find("app.app_killed.emit()")
sys.exit(0 if 0 <= st < kill else 1)
PY2
grep -q 'if not launch_manager.get_running().is_empty():' "$SRC/store_settings.gd" \
  && ok "Sign in waits for no game to run (the window takes its place; nothing gives it focus back)" \
  || bad "store_settings.gd signs in over a running game"
# Nothing tells OGUI that a web page's text field has the focus: the helper's `typing` events do, and
# the keyboard comes up as Guide+X brings it up over a game (on the popup stack), only when no other
# popup is up, and goes with the field unless the player opened it; never left behind. It types into a
# hidden field of ours (GODOT context), not the window (X11: no InputPlumber keyboard found after a
# fresh boot, Air X 2026-11-01); each edit, and Enter, goes to the helper on its stdin (say).
grep -q '_window.typing(bool(data.get("on", false)), s\["runner"\].say)' "$SRC/store_settings.gd" \
  && python3 - "$SRC/signin_window.gd" <<'PY2' \
  && ok "a page's text field taking the focus opens OGUI's keyboard, typing through the helper; losing it closes ours" \
  || bad "the sign-in's typing events do not open/close OGUI's keyboard into the helper, or leave it up after"
import sys
s = open(sys.argv[1]).read()
body = s[s.index("func typing(on: bool, say: Callable)"):s.index("func _close_osk()")]
rel = s[s.index("func release()"):]
sys.exit(0 if all(x in body for x in ("if on and popup_state_machine.current_state() == null:",
                                      "popup_state_machine.push_state(osk_state)", "state_machine.push_state(popup_state)",
                                      "KeyboardContext.new(KeyboardContext.TYPE.GODOT, _field)", "osk.open(context)",
                                      "context.submitted.connect(_on_submitted)", "elif not on and _osk_ours:",
                                      '"type": "text", "delete": _sent.length() - same, "insert": now.substr(same)',
                                      '"type": "key", "key": "Enter"', "_field.focus_mode = Control.FOCUS_NONE"))
         and "TYPE.X11" not in body
         and "if popup_state_machine.current_state() == osk_state:" in s and "if _osk_ours:" in rel
         and "_field.queue_free()" in rel else 1)
PY2
# OGUI's keyboard hands gamescope's input focus to OGUI's window only for an X11 context; ours is GODOT,
# so without this touches went to Chromium, the field blurred and the keyboard closed (issue #34).
python3 - "$SRC/signin_window.gd" <<'PY2' \
  && ok "the sign-in's keyboard takes the touches (OGUI's window gets gamescope's input focus, 2)" \
  || bad "signin_window.gd opens its GODOT keyboard without giving OGUI's window the touches: a tap closes it"
import sys
s = open(sys.argv[1]).read()
body = s[s.index("func typing(on: bool, say: Callable)"):s.index("func _open_field()")]
take = s[s.index("func _osk_takes_touch()"):]
sys.exit(0 if body.index("osk.open(context)") < body.index("_osk_takes_touch()")
         and "gamescope.get_xwayland(gamescope.XWAYLAND_TYPE_OGUI)" in take
         and "get_windows_for_pid(OS.get_process_id())" in take
         and "set_input_focus(windows[0], 2)" in take else 1)
PY2
# A store refusing the stored refresh token (revoked, expired) signs it out and is exit 3, like never
# having signed in: the library reads the helper's stderr so the player is told to sign in again.
grep -q 'out.append(OS.execute(tool, args, output, true))' "$SRC/library_store.gd" \
  && grep -q '"sign in again" in line' "$SRC/library_store.gd" \
  && ok "a store that ended the sign-in says so when its library loads" \
  || bad "library_store.gd does not tell the player a store ended the sign-in (an empty library, silently)"
# A listing that FAILED (exit 1: two loads at once at startup raced, Pocket FIT 2026-11-02; the Air X
# during an install) is not an empty library: _drop_stale removed every card of the store, and the
# Installed tab emptied until the next load (issue #32). Only exit 3 (signed out, or the sign-in
# refused) empties it; a failure keeps the cards there are.
python3 - "$SRC/library_store.gd" <<'PY2' \
  && ok "a failed store listing keeps the store's cards; only signed out (exit 3) empties the library" \
  || bad "library_store.gd drops every card of a store when its listing fails (issue #32)"
import sys
s = open(sys.argv[1]).read()
get = s[s.index("func get_library_launch_items()"):s.index("func _games()")]
games = s[s.index("func _games()"):s.index("func _drop_stale(")]
sys.exit(0 if "if games == null:" in get and get.index("if games == null:") < get.index("_drop_stale(items)")
         and "return null" in games and "return []" in games else 1)
PY2
python3 - "$SRC/library_steam.gd" <<'PY2' \
  && ok "a failed Steam listing keeps the Steam cards" \
  || bad "library_steam.gd drops every Steam card when steam-library fails"
import sys
s = open(sys.argv[1]).read()
get = s[s.index("func get_library_launch_items()"):s.index("func _games()")]
games = s[s.index("func _games()"):s.index("func _drop_stale(")]
sys.exit(0 if "if games == null:" in get and get.index("if games == null:") < get.index("_drop_stale(items)")
         and "return null" in games else 1)
PY2
# The runners read a tool's pipes for as long as it runs (an install: minutes). On WorkerThreadPool
# that held both of its low-priority threads (30% of 8), and every card's art load (shared_art.gd)
# waited behind them: all tabs showed empty cards until the install ended (issue #32). They run on
# threads of their own.
for f in store_runner.gd psn_runner.gd scrape_runner.gd; do
  if ! grep -q "WorkerThreadPool" "$SRC/$f" && grep -q "_thread = Thread.new()" "$SRC/$f" \
     && grep -q "_thread.wait_to_finish()" "$SRC/$f" && grep -q "err_thread.wait_to_finish()" "$SRC/$f"; then
    ok "$f reads its tool on threads of its own, not the shared pool"
  else
    bad "$f holds WorkerThreadPool threads for its tool's whole run: art loads starve (issue #32)"
  fi
done
! grep -qiE 'qr|phone' "$SRC/store_settings.gd" && ok "no QR code or phone left on the Stores page (plan D4)" \
  || bad "store_settings.gd still mentions the QR/phone sign-in"
# Steam's download ends with the client updated and closed: nothing said the next step is opening it,
# where Steam's own sign-in (QR) comes up.
grep -q 'elif code == 0 and emu.get("kind") == "steam" and before == null:' "$SRC/apps_page.gd" \
  && grep -q 'Open it from Main menu > Steam to sign in' "$SRC/apps_page.gd" \
  && ok "Steam's first download says to open it from Main menu > Steam to sign in" \
  || bad "Steam's first download ends without saying where to sign in"
# OGUI's desktop library lists the shortcut Steam writes for each game it installs, on the same card
# as our entry: launched through it Steam came up in its desktop mode, and Home showed the game twice,
# once without its cover (HW, Pocket FIT, 2026-10-21). The plugin drops those entries as they arrive,
# deferred (LibraryManager is emitting), and sweeps the ones that came before it.
grep -q 'library_manager.library_launch_item_added.connect(_drop_steam_shortcut)' "$SRC/plugin.gd" \
  && grep -q 'library_manager.remove_library_launch_item.call_deferred(DESKTOP_LIBRARY_ID, item.name)' "$SRC/plugin.gd" \
  && grep -q 'const DESKTOP_LIBRARY_ID := "desktop"' "$SRC/plugin.gd" \
  && ok "Steam's desktop shortcuts leave the library as they arrive (deferred): one entry per Steam game, ours" \
  || bad "plugin.gd does not drop the desktop library's Steam shortcuts"
# The installed Steam games' library id is spelled in three files: a mismatch leaves the Steam tab
# empty (plugin.gd) or its cards without art (boxart_retroforge.gd).
[ "$(grep -ho '"retroforge-steam"' "$SRC/library_steam.gd" "$SRC/plugin.gd" "$SRC/boxart_retroforge.gd" | wc -l)" -eq 3 ] \
  && grep -q 'add_library(steam)' "$SRC/plugin.gd" \
  && ok "the Steam games' library is added, under the id the tab and the art provider look for" \
  || bad "library_steam.gd is not added, or its id differs between library_steam.gd, plugin.gd and boxart_retroforge.gd"
# Starting Steam games without the client (retroforge-steam-direct) is /usr/bin/steam's choice at each
# launch, so a game's launch item stays `steam ... steam://rungameid/<appid>` (OGUI's Steam handling
# keys on that argument) and the setting applies from the next launch without a rescan. Its toggle
# is attached and detached like the other Steam toggles, after keep-running, with no separator of its
# own (bfd3f38: the rows there draw none).
grep -q '^	item.command = "steam"$' "$SRC/library_steam.gd" && grep -q '^	item.args = SteamApps.launch_args(game\["appid"\])$' "$SRC/library_steam.gd" \
  && ok "a Steam game launches through /usr/bin/steam, which decides whether the client starts" \
  || bad "library_steam.gd no longer launches games through steam: the start-without-Steam setting would be bypassed"
grep -q 'load(plugin_base.path_join("steam_direct.gd")).new().setup(get_tree())' "$SRC/plugin.gd" \
  && grep -q '_direct.detach()' "$SRC/plugin.gd" && grep -q '^const TOOL := "/usr/bin/retroforge-steam-direct"$' "$SRC/steam_direct.gd" \
  && ok "the start-without-Steam toggle is attached and detached, and runs retroforge-steam-direct" \
  || bad "plugin.gd does not attach steam_direct.gd, or it runs another command"
python3 - "$SRC/steam_direct.gd" <<'PY2' && ok "steam_direct.gd turns its separator off before add_child, after the keep-running toggle" || bad "steam_direct.gd draws its own separator, or is not placed after the keep-running toggle"
import sys
s = open(sys.argv[1]).read()
sep, add = s.find("_toggle.separator_visible = false"), s.find("box.add_child(_toggle)")
sys.exit(0 if 0 <= sep < add and s.find('["RetroForgeSteamKeep", ') > 0 else 1)
PY2

# =================================================================================================
CASE="zip"
"$BUILD" "$T" >/dev/null && [ -f "$T/retroforge.zip" ] && ok "build.sh writes retroforge.zip" || bad "build.sh failed"
sum1="$(sha256sum "$T/retroforge.zip" | cut -d' ' -f1)"
mapfile -t files < <(python3 -c 'import sys,zipfile; print("\n".join(zipfile.ZipFile(sys.argv[1]).namelist()))' "$T/retroforge.zip")
want=(); for f in "$SRC"/*; do want+=("plugins/retroforge/$(basename "$f")"); done
[ "$(printf '%s\n' "${files[@]}" | sort)" = "$(printf '%s\n' "${want[@]}" | sort)" ] \
  && ok "holds exactly plugin/* under plugins/retroforge/ (where PluginLoader looks)" \
  || bad "zip contents: ${files[*]}"
"$BUILD" "$T" >/dev/null
[ "$(sha256sum "$T/retroforge.zip" | cut -d' ' -f1)" = "$sum1" ] \
  && ok "rebuilding gives the same bytes (store sha256 stays valid)" || bad "the zip changes between builds"

# =================================================================================================
# OGUI keys its library by item name across every provider: two ROMs with the same name became one
# card and the second ROM was lost; a rescan never dropped a deleted ROM. rom_names.gd has no OGUI
# types, so a stock Godot runs it (RETROFORGE_GODOT=<godot 4 binary>, or godot on PATH; skipped without).
CASE="rom helpers"
GODOT="${RETROFORGE_GODOT:-$(command -v godot || true)}"
if [ -z "$GODOT" ]; then
  printf '  skip %s -- no Godot (set RETROFORGE_GODOT to a Godot 4 binary)\n' "$CASE"
else
  cat >"$T/names_test.gd" <<GD
extends SceneTree

const RomNames := preload("$SRC/rom_names.gd")
const LaunchArgs := preload("$SRC/launch_args.gd")
const RomWatch := preload("$SRC/rom_watch.gd")
const Credits := preload("$SRC/credits.gd")
const GameDirs := preload("$SRC/game_dirs.gd")
const EmuOptions := preload("$SRC/emu_options.gd")
const EmuState := preload("$SRC/emu_state.gd")
const ArtPaths := preload("$SRC/art_paths.gd")
const UpdateStates := preload("$SRC/update_states.gd")
const InternalInstall := preload("$SRC/internal_install.gd")
const SteamApps := preload("$SRC/steam_apps.gd")
const SteamWatch := preload("$SRC/steam_watch.gd")
const CheevosText := preload("$SRC/cheevos_text.gd")
const SYSTEMS := {"psx": "PlayStation", "ps2": "PlayStation 2"}
var failed := 0

func check(what: String, got, want) -> void:
	if got == want:
		print("  ok   $CASE -- ", what)
	else:
		failed += 1
		print("  FAIL $CASE -- ", what, ": got ", got, ", want ", want)

func names(roms: Array) -> PackedStringArray:
	var list := []
	for r in roms:
		list.append({"system": r[0], "path": "/home/player/roms/%s/%s" % r})
	return RomNames.names_for(list, SYSTEMS)

func _init() -> void:
	check("a unique ROM keeps its file name",
		names([["psx", "Crash Bandicoot.chd"], ["ps2", "Jak.iso"]]),
		PackedStringArray(["Crash Bandicoot", "Jak"]))
	check("the same name on two systems gets the system",
		names([["psx", "Tetris.chd"], ["ps2", "Tetris.iso"]]),
		PackedStringArray(["Tetris (PlayStation)", "Tetris (PlayStation 2)"]))
	check("the same name in one system gets the extension",
		names([["psx", "Tetris.cue"], ["psx", "Tetris.chd"]]),
		PackedStringArray(["Tetris (CUE)", "Tetris (CHD)"]))
	check("names differing only in case collide (OGUI settings are lower-cased)",
		names([["psx", "tetris.chd"], ["ps2", "TETRIS.iso"]]),
		PackedStringArray(["tetris (PlayStation)", "TETRIS (PlayStation 2)"]))
	check("both rules together stay unique",
		names([["psx", "T.cue"], ["psx", "T.chd"], ["ps2", "T.iso"]]),
		PackedStringArray(["T (PlayStation) (CUE)", "T (PlayStation) (CHD)", "T (PlayStation 2)"]))
	check("names still equal after both rules are numbered",
		names([["psx", "A.chd"], ["psx", "a.chd"], ["psx", "B (CUE).chd"], ["psx", "B.cue"], ["psx", "B.chd"]]),
		PackedStringArray(["A (CHD)", "a (CHD) (2)", "B (CUE)", "B (CUE) (2)", "B (CHD)"]))
	check("a ROM still there is kept",
		RomNames.stale({"A": "/r/A.chd"}, {"A": "/r/A.chd", "B": "/r/B.chd"}), PackedStringArray())
	check("a deleted ROM is dropped",
		RomNames.stale({"A": "/r/A.chd", "B": "/r/B.chd"}, {"A": "/r/A.chd"}), PackedStringArray(["B"]))
	check("a name now meaning another file is dropped (re-added with the new ROM)",
		RomNames.stale({"A": "/r/A.cue"}, {"A": "/r/A.chd"}), PackedStringArray(["A"]))
	# Every choice is in the player confs (retroforge-launch reads them): a card is just system + ROM.
	var rom := "/home/player/roms/psx/Crash Team Racing (USA).chd"
	check("launch args: system and ROM, nothing else (choices live in the confs)",
		LaunchArgs.for_rom("psx", rom), PackedStringArray(["psx", rom]))
	check("options are saved per system + file, not per card name",
		LaunchArgs.rom_id("psx", rom), "psx/Crash Team Racing (USA).chd")
	var launch_conf := "# system=emulator\npsx=duckstation\nps2=armsx2\npsx=other  \npsxx=nope\n"
	check("launch.conf: last system=emulator line wins, like retroforge-launch",
		LaunchArgs.emulator_for("psx", launch_conf), "other")
	check("launch.conf: an unmapped system has no emulator",
		LaunchArgs.emulator_for("gc", launch_conf), "")
	check("player conf: CPUS read like retroforge-launch (last line)",
		LaunchArgs.conf_cpus("CPUS=all\n# x\nCPUS=big\n"), "big")
	check("player conf: an unknown CPUS value reads as unset",
		LaunchArgs.conf_cpus("CPUS=fast\n"), "")
	check("player conf: CPUS rewritten once, other lines kept",
		LaunchArgs.conf_with("# mine\nCPUS=all\nFOO=1\nCPUS=all\n", "CPUS", "big"), "# mine\nFOO=1\nCPUS=big\n")
	check("player conf: an empty value removes the key",
		LaunchArgs.conf_with("CPUS=all\naspect=4:3\n", "CPUS", ""), "aspect=4:3\n")
	check("player conf: removing the last key leaves nothing",
		LaunchArgs.conf_with("CPUS=all\n", "CPUS", ""), "")
	check("player conf: any key read like retroforge-launch (last line, prefix-safe)",
		LaunchArgs.conf_value("aspect_x=1\naspect=4:3\naspect=16:9\n", "aspect"), "16:9")
	check("player conf: written under XDG_CONFIG_HOME, where retroforge-launch looks",
		LaunchArgs.player_conf_path("duckstation"), OS.get_environment("XDG_CONFIG_HOME") + "/retroforge/emulators/duckstation.conf")
	check("emulator default: off before anything is saved", LaunchArgs.emulator_fast_cores("duckstation"), false)
	check("emulator default: saving On succeeds", LaunchArgs.set_emulator_fast_cores("duckstation", true), true)
	check("emulator default: reads back On", LaunchArgs.emulator_fast_cores("duckstation"), true)
	check("emulator default: the file holds CPUS=big",
		FileAccess.get_file_as_string(LaunchArgs.player_conf_path("duckstation")), "CPUS=big\n")
	LaunchArgs.set_emulator_fast_cores("duckstation", false)
	check("emulator default: Off reads back off", LaunchArgs.emulator_fast_cores("duckstation"), false)
	# Game settings > RetroForge: the game's own conf, named after the ROM file like retroforge-launch's.
	check("game conf: under XDG_CONFIG_HOME/retroforge/games/<system>/<rom file>.conf",
		LaunchArgs.game_conf_path("psx", rom), OS.get_environment("XDG_CONFIG_HOME") + "/retroforge/games/psx/Crash Team Racing (USA).chd.conf")
	check("game conf: a folder ROM (PS3 dump) is named after the folder",
		LaunchArgs.game_conf_path("ps3", "/home/player/roms/ps3/GAME/"), OS.get_environment("XDG_CONFIG_HOME") + "/retroforge/games/ps3/GAME.conf")
	check("game fast cores: the emulator default before anything is saved", LaunchArgs.game_cpus("psx", rom), "")
	check("game fast cores: choosing the default writes no file",
		LaunchArgs.set_game_cpus("psx", rom, "") and not FileAccess.file_exists(LaunchArgs.game_conf_path("psx", rom)), true)
	check("game fast cores: saving On succeeds", LaunchArgs.set_game_cpus("psx", rom, "big"), true)
	check("game fast cores: reads back On", LaunchArgs.game_cpus("psx", rom), "big")
	check("game fast cores: the file holds CPUS=big", FileAccess.get_file_as_string(LaunchArgs.game_conf_path("psx", rom)), "CPUS=big\n")
	LaunchArgs.set_game_cpus("psx", rom, "")
	check("game fast cores: back to the emulator default", LaunchArgs.game_cpus("psx", rom), "")
	check("game fast cores: an unknown value saves the default", LaunchArgs.set_game_cpus("psx", rom, "fast") and LaunchArgs.game_cpus("psx", rom) == "", true)
	test_rom_watch()
	test_game_dirs()
	test_credits()
	test_emu_options()
	test_emu_state()
	test_art_paths()
	test_update_states()
	test_internal_install()
	test_steam_apps()
	test_cheevos_text()
	quit(1 if failed else 0)

# Settings > Library > RetroAchievements (cheevos_settings.gd): retroforge-cheevos' exit codes and
# status -> what the player reads.
func test_cheevos_text() -> void:
	check("cheevos: wrong password", CheevosText.failure_text(7, "retroforge-cheevos: Invalid user/password combination."),
		"RetroAchievements refused your user name or password.")
	check("cheevos: offline", CheevosText.failure_text(3, "retroforge-cheevos: retroachievements.org not reached"),
		"RetroAchievements could not be reached. Check the network and try again.")
	check("cheevos: RetroArch running is its own message",
		CheevosText.failure_text(5, "retroforge-cheevos: RetroArch is running: close the game first (RetroArch writes...)"),
		"Close the game first: RetroArch is running and would undo this.")
	check("cheevos: any other local failure", CheevosText.failure_text(5, "retroforge-cheevos: cannot write x"),
		"RetroArch's settings could not be saved.")
	check("cheevos: a strange answer", CheevosText.failure_text(8, ""), "RetroAchievements did not answer as expected. Try again later.")
	check("cheevos: the tool missing (-1)", CheevosText.failure_text(-1, ""), "This build has no RetroAchievements sign-in.")
	check("cheevos: signed in", CheevosText.account_text({"signed_in": true, "user": "Player1"}),
		"Signed in as Player1. Game Boy, SNES and Mega Drive games earn achievements.")
	check("cheevos: signed out", CheevosText.account_text({"signed_in": false, "user": null}),
		"Not signed in. A free account from retroachievements.org.")
	check("cheevos: no status (tool missing)", CheevosText.account_text({}), "Not signed in. A free account from retroachievements.org.")

# Settings > General > Internal storage (retroforge_os.gd): release-info's answer -> what is shown.
func test_internal_install() -> void:
	var ok := InternalInstall.parse_release("URL=https://x/stable/latest.json\nCHANNEL=stable\nSTATE=ok\nVERSION=0.0.6\nDETAIL=a=b\n")
	check("release: key=value lines", [ok["STATE"], ok["VERSION"], ok["DETAIL"]], ["ok", "0.0.6", "a=b"])
	check("release: a published version can be installed", InternalInstall.can_install(ok), true)
	check("release: no output cannot", InternalInstall.can_install(InternalInstall.parse_release("")), false)
	check("release: a failed resolve cannot", InternalInstall.can_install({"STATE": "unreachable"}), false)
	check("confirmation: names the version", InternalInstall.confirmation(ok).contains("0.0.6"), true)
	check("confirmation: says it closes the session and erases nothing yet",
		[InternalInstall.confirmation(ok).contains("closes RetroForge"), InternalInstall.confirmation(ok).contains("Nothing is erased")], [true, true])
	var dev := InternalInstall.parse_release("CHANNEL=dev\nSOURCE=running\nSTATE=ok\nVERSION=dev\nBUILD=20261109T120000Z\nBUNDLE=running:/dev/mmcblk0p4\n")
	check("release: a dev image's running root can be installed", InternalInstall.can_install(dev), true)
	check("confirmation: a dev image says it installs itself, by build",
		[InternalInstall.confirmation(dev).contains("this running"), InternalInstall.confirmation(dev).contains("20261109T120000Z")], [true, true])
	check("refusal: the channel with nothing in it is named", InternalInstall.refusal({"STATE": "no-release", "CHANNEL": "beta"}).contains("beta"), true)
	check("refusal: unreachable points at the network", InternalInstall.refusal({"STATE": "unreachable"}).contains("Wi-Fi"), true)
	check("refusal: nothing from the tool still says something", InternalInstall.refusal({}) != "", true)


# Settings > General > Updates (retroforge_os.gd): retroforge-update's answers -> what is shown.
func test_update_states() -> void:
	check("channels: stable and beta, not pinned",
		UpdateStates.parse_channels("stable\nbeta\n"), {"channels": ["stable", "beta"], "pinned": ""})
	check("channels: a dev card's pin is listed and named",
		UpdateStates.parse_channels("stable\nbeta\ndev\npinned\t/etc/retroforge/ota.conf\n"),
		{"channels": ["stable", "beta", "dev"], "pinned": "/etc/retroforge/ota.conf"})
	check("channel: the name before the tab", UpdateStates.parse_channel("beta\t/home/player/.config/retroforge/ota.conf\n"), "beta")
	check("channel: nothing read is empty", UpdateStates.parse_channel(""), "")
	check("channel names: Stable, Beta, others as they are",
		[UpdateStates.channel_name("stable"), UpdateStates.channel_name("beta"), UpdateStates.channel_name("dev")], ["Stable", "Beta", "dev"])
	var S := UpdateStates.Step
	check("button: one button walks Check -> Install -> Restart now",
		[UpdateStates.button_for(S.IDLE, "0.0.3")["button"], UpdateStates.button_for(S.AVAILABLE, "0.0.3", "0.0.4")["button"],
		 UpdateStates.button_for(S.STAGED, "0.0.3", "0.0.4")["button"]],
		["Check for updates", "Install", "Restart now"])
	check("button: pressable only when it does something",
		[UpdateStates.button_for(S.IDLE, "1")["disabled"], UpdateStates.button_for(S.CHECKING, "1")["disabled"],
		 UpdateStates.button_for(S.AVAILABLE, "1", "2")["disabled"], UpdateStates.button_for(S.INSTALLING, "1", "2")["disabled"],
		 UpdateStates.button_for(S.STAGED, "1", "2")["disabled"]],
		[false, true, false, true, false])
	check("button: the install's progress is in its description",
		"42%" in UpdateStates.button_for(S.INSTALLING, "0.0.3", "0.0.4", 42)["description"], true)
	check("button: both versions when one is available",
		UpdateStates.button_for(S.AVAILABLE, "0.0.4-beta.1", "0.0.3")["description"], "RetroForge 0.0.3 is available (you have 0.0.4-beta.1).")
	check("background check: only when idle and no game runs",
		[UpdateStates.background_check_wanted(S.IDLE, false), UpdateStates.background_check_wanted(S.IDLE, true),
		 UpdateStates.background_check_wanted(S.CHECKING, false), UpdateStates.background_check_wanted(S.AVAILABLE, false),
		 UpdateStates.background_check_wanted(S.INSTALLING, false), UpdateStates.background_check_wanted(S.STAGED, false)],
		[true, false, false, false, false, false])
	check("background check: the notification names the version and where to install it",
		UpdateStates.available_text("0.0.4"), "RetroForge 0.0.4 is available: Settings > General > Updates")
	check("channel description: says what pins it",
		UpdateStates.channel_description("/etc/retroforge/ota.conf"), "Set by /etc/retroforge/ota.conf on this device.")

## OGUI's card is 2:3 and draws its texture whole, top-left: a SNES box (wider than tall) left two
## thirds of the card empty (ACE, 2026-10-17). A card image is the box scaled to cover the card,
## its centre cut out (user decision 2026-10-17, over a fitted box on a blurred backdrop); cached
## as a small JPEG until the box changes.
func test_card_images(media: String) -> void:
	# A wide box in thirds, red | blue | green: the card keeps the middle, cut at both sides.
	var wide := Image.create(640, 468, false, Image.FORMAT_RGBA8)
	wide.fill_rect(Rect2i(0, 0, 214, 468), Color(1, 0, 0))
	wide.fill_rect(Rect2i(214, 0, 213, 468), Color(0, 0, 1))
	wide.fill_rect(Rect2i(427, 0, 213, 468), Color(0, 1, 0))
	var card := ArtPaths.card_image(wide)
	check("card: a wide box becomes a 300x450 card", card.get_size(), Vector2i(300, 450))
	var mid := card.get_pixel(150, 225)
	var left := card.get_pixel(1, 225)
	var right := card.get_pixel(298, 225)
	check("card: the box's centre, full height, cut at both sides",
		[mid.b > 0.9, left.r > 0.9, right.g > 0.9, card.get_pixel(150, 1).b > 0.9, card.get_pixel(150, 448).b > 0.9],
		[true, true, true, true, true])
	# A tall box: top and bottom bands, cut; the middle row fills the card's width.
	var tall := Image.create(200, 600, false, Image.FORMAT_RGB8)
	tall.fill(Color(0, 1, 0))
	tall.fill_rect(Rect2i(0, 200, 200, 200), Color(0, 0, 1))
	var card2 := ArtPaths.card_image(tall)
	check("card: a tall box fills the width, its middle kept",
		[card2.get_size(), card2.get_pixel(1, 225).b > 0.9, card2.get_pixel(298, 225).b > 0.9, card2.get_pixel(150, 1).g > 0.9],
		[Vector2i(300, 450), true, true, true])
	var exact := Image.create(600, 900, false, Image.FORMAT_RGB8)
	exact.fill(Color(1, 1, 0))
	check("card: a 2:3 box is only scaled", ArtPaths.card_image(exact).get_pixel(0, 0).is_equal_approx(Color(1, 1, 0)), true)
	var box_path := media + "/snes/Wide.zip-box.png"
	DirAccess.make_dir_recursive_absolute(box_path.get_base_dir())
	wide.save_png(box_path)
	var cache := ArtPaths.card_cache_path("$T/art/cards", "snes", "/r/snes/Wide.zip")
	check("card cache: under <cards>/<system>/<rom>.jpg", cache, "$T/art/cards/snes/Wide.zip.jpg")
	check("card cache: nothing cached yet", ArtPaths.cached_card(cache, box_path), null)
	var made: Image = ArtPaths.make_card(box_path, cache)
	check("card cache: made and saved", [made.get_size() if made else null, FileAccess.file_exists(cache)], [Vector2i(300, 450), true])
	var again: Image = ArtPaths.cached_card(cache, box_path)
	check("card cache: read back (a JPEG, by its bytes)", again.get_size() if again else null, Vector2i(300, 450))
	var webp := Image.create(5, 4, false, Image.FORMAT_RGBA8)
	webp.save_webp(media + "/psx/Webp-named.png")
	var w: Image = ArtPaths.load_image(media + "/psx/Webp-named.png")
	check("art: a WebP loads too, by its bytes", w.get_size() if w else null, Vector2i(5, 4))
	OS.delay_msec(1100)  # file times are in seconds
	wide.save_png(box_path)
	check("card cache: a newer box makes it stale", ArtPaths.cached_card(cache, box_path), null)
	check("card cache: no box -> no card", ArtPaths.make_card(media + "/snes/None.zip-box.png", cache + ".x"), null)
	# Steam's own card art (600x900, or 1200x1800 as _2x) becomes a CARD_SIZE card image too.
	var steam_cache := ArtPaths.steam_card_cache_path("$T/art/cards", 1145360)
	check("steam card cache: under <cards>/steam/<appid>.jpg", steam_cache, "$T/art/cards/steam/1145360.jpg")
	var capsule := Image.create(1200, 1800, false, Image.FORMAT_RGB8)
	capsule.fill(Color(0, 0, 1))
	capsule.save_jpg("$T/art/library_600x900_2x.jpg")
	var steam_card: Image = ArtPaths.make_card("$T/art/library_600x900_2x.jpg", steam_cache)
	check("steam card: a 1200x1800 capsule is cached as a 300x450 card",
		[steam_card.get_size() if steam_card else null, FileAccess.file_exists(steam_cache)], [Vector2i(300, 450), true])


## PortMaster ports are never scraped: each port PortMaster installs carries a gameinfo.xml (ES
## gameList) whose <path> is the launch script and <image> its screenshot, both relative to
## ~/roms/ports (seen for Apotris and 8-Bit Buccaneer, 2026-10-17). Every layout but the logo uses it.
func test_port_art(media: String) -> void:
	var ports := "$T/art/roms/ports"
	write(ports + "/8bitbuccaneer/gameinfo.xml", '<?xml version="1.0" encoding="utf-8"?>\n<gameList>\n  <game>\n    <path>./8-BIT BUCCANEER.sh</path>\n    <name>8-BIT BUCCANEER</name>\n    <image>./8bitbuccaneer/screenshot.png</image>\n  </game>\n</gameList>\n')
	write(ports + "/8bitbuccaneer/screenshot.png", "png")
	write(ports + "/apotris/gameinfo.xml", "<?xml version='1.0' encoding='utf-8'?>\n<gameList><game><path>./Apotris.sh</path><name>Apotris</name><image>./apotris/screenshot.png</image></game></gameList>")
	write(ports + "/apotris/screenshot.png", "png")
	write(ports + "/evil/gameinfo.xml", "<gameList><game><path>./Evil.sh</path><image>../../../etc/passwd</image></game></gameList>")
	write(ports + "/gone/gameinfo.xml", "<gameList><game><path>./Gone.sh</path><image>./gone/screenshot.png</image></game></gameList>")
	write(ports + "/broken/gameinfo.xml", "<gameList><game><path>./Broken.sh</pa")
	check("ports: a card is the port's screenshot",
		ArtPaths.path_for(media, "ports", ports + "/8-BIT BUCCANEER.sh", 0, ports), ports + "/8bitbuccaneer/screenshot.png")
	check("ports: the wide layouts too, no logo",
		[ArtPaths.path_for(media, "ports", ports + "/Apotris.sh", 1, ports), ArtPaths.path_for(media, "ports", ports + "/Apotris.sh", 2, ports), ArtPaths.path_for(media, "ports", ports + "/Apotris.sh", 3, ports)],
		[ports + "/apotris/screenshot.png", ports + "/apotris/screenshot.png", ""])
	check("ports: an image outside ~/roms/ports, a missing image, a broken file, an unknown port -> none",
		[ArtPaths.path_for(media, "ports", ports + "/Evil.sh", 0, ports), ArtPaths.path_for(media, "ports", ports + "/Gone.sh", 0, ports),
		 ArtPaths.path_for(media, "ports", ports + "/Broken.sh", 0, ports), ArtPaths.path_for(media, "ports", ports + "/Other.sh", 0, ports)],
		["", "", "", ""])
	check("ports: the default ports folder is ~/roms/ports", ArtPaths.ports_dir(), OS.get_environment("HOME").path_join("roms/ports"))


## Art retroforge-scrape fetched, per OGUI layout (0 portrait, 1 landscape, 2 banner, 3 logo).
## Keyed by the ROM's file (or folder) name, so Game.cue and Game.chd never share art.
func test_art_paths() -> void:
	var media := "$T/art/media"
	write(media + "/psx/Game.chd-box.png", "png")
	write(media + "/psx/Game.chd-screen.png", "png")
	write(media + "/psx/Game.chd-wheel.jpg", "jpg")
	write(media + "/psx/Other.cue-fanart.jpg", "jpg")
	write(media + "/psx/Other.cue-screen.png", "png")
	write(media + "/ps3/Flower-box.png", "png")
	var rom := "/home/player/roms/psx/Game.chd"
	check("art: a card is the box", ArtPaths.path_for(media, "psx", rom, 0), media + "/psx/Game.chd-box.png")
	check("art: wide layouts fall back to the screenshot without fan art",
		[ArtPaths.path_for(media, "psx", rom, 1), ArtPaths.path_for(media, "psx", rom, 2)],
		[media + "/psx/Game.chd-screen.png", media + "/psx/Game.chd-screen.png"])
	check("art: wide layouts prefer fan art", ArtPaths.path_for(media, "psx", "/r/psx/Other.cue", 2), media + "/psx/Other.cue-fanart.jpg")
	check("art: the logo is the wheel, as .jpg too", ArtPaths.path_for(media, "psx", rom, 3), media + "/psx/Game.chd-wheel.jpg")
	check("art: none scraped -> no path (OGUI shows its placeholder)", ArtPaths.path_for(media, "psx", "/r/psx/Other.cue", 0), "")
	check("art: same name, other extension: not shared", ArtPaths.path_for(media, "psx", "/r/psx/Game.cue", 0), "")
	check("art: same file, other system: not shared", ArtPaths.path_for(media, "ps2", rom, 0), "")
	check("art: a game folder by its name (trailing slash too)",
		[ArtPaths.path_for(media, "ps3", "/r/ps3/Flower", 0), ArtPaths.path_for(media, "ps3", "/r/ps3/Flower/", 0)],
		[media + "/ps3/Flower-box.png", media + "/ps3/Flower-box.png"])
	# Loaded by the file's bytes, not its name (a PNG saved as .jpg loaded nothing in Godot).
	var img := Image.create(4, 3, false, Image.FORMAT_RGBA8)
	img.save_png(media + "/psx/Png-named.jpg")
	img.save_jpg(media + "/psx/Jpg-named.png")
	var a: Image = ArtPaths.load_image(media + "/psx/Png-named.jpg")
	var b: Image = ArtPaths.load_image(media + "/psx/Jpg-named.png")
	check("art: a PNG named .jpg and a JPEG named .png both load", [a.get_size() if a else null, b.get_size() if b else null], [Vector2i(4, 3), Vector2i(4, 3)])
	check("art: not an image, or no file -> null",
		[ArtPaths.load_image(media + "/psx/Game.chd-box.png"), ArtPaths.load_image(media + "/nothing.png")], [null, null])
	test_card_images(media)
	test_port_art(media)
	check("art: no system or ROM, or an unknown layout -> no path",
		[ArtPaths.path_for(media, "", rom, 0), ArtPaths.path_for(media, "psx", "", 0), ArtPaths.path_for(media, "psx", rom, 9)],
		["", "", ""])

## Games that are folders: a PS3 disc dump is PS3_GAME/USRDIR/EBOOT.BIN in a folder RPCS3 boots.
func test_game_dirs() -> void:
	var ps3 := "$T/dirs/roms/ps3"
	var markers := ["PS3_GAME/USRDIR/EBOOT.BIN", "USRDIR/EBOOT.BIN"]
	write(ps3 + "/Demon's Souls [BLUS30443]/PS3_GAME/USRDIR/EBOOT.BIN", "elf")
	write(ps3 + "/Flower/USRDIR/EBOOT.BIN", "elf")
	write(ps3 + "/Half copied/PS3_GAME/PARAM.SFO", "sfo")
	write(ps3 + "/.hidden/PS3_GAME/USRDIR/EBOOT.BIN", "elf")
	check("game folders: a disc dump and a bare PS3_GAME count; a folder with no EBOOT.BIN and a hidden one do not",
		GameDirs.scan(ps3, markers), PackedStringArray([ps3 + "/Demon's Souls [BLUS30443]", ps3 + "/Flower"]))
	check("game folders: a system without markers lists none", GameDirs.scan(ps3, []), PackedStringArray())
	check("game folders: a folder keeps its whole name (no extension cut at a dot)",
		RomNames.names_for([{"system": "ps3", "path": ps3 + "/Uncharted 2. Among Thieves", "dir": true}], {"ps3": "PlayStation 3"}),
		PackedStringArray(["Uncharted 2. Among Thieves"]))
	check("game folders: a folder and an .iso of one game are told apart",
		RomNames.names_for([{"system": "ps3", "path": ps3 + "/Flower", "dir": true}, {"system": "ps3", "path": ps3 + "/Flower.iso"}],
			{"ps3": "PlayStation 3"}),
		PackedStringArray(["Flower (FOLDER)", "Flower (ISO)"]))
	var watch = RomWatch.new().setup("$T/dirs/roms", ["ps3"], {"ps3": markers})
	watch.mark_loaded()
	write(ps3 + "/Half copied/PS3_GAME/USRDIR/EBOOT.BIN", "e")
	check("rescan: a game folder is due once its EBOOT.BIN arrived and settled",
		[watch.poll(false), watch.poll(false)], [false, true])
	watch.mark_loaded()
	append(ps3 + "/Half copied/PS3_GAME/USRDIR/EBOOT.BIN", "lf")
	check("rescan: an EBOOT.BIN still growing keeps it waiting", [watch.poll(false), watch.poll(false)], [false, true])
	watch.mark_loaded()
	write(ps3 + "/Other/PS3_GAME/PARAM.SFO", "sfo")
	check("rescan: a folder without its marker is no change", [watch.poll(false), watch.poll(false)], [false, false])

## Attribution the emulators' licences ask for (DuckStation: CC BY-NC-ND, link duckstation.org).
func test_credits() -> void:
	var lic := {"name": "CC BY-NC-ND 4.0", "url": "https://x.org/LICENSE"}
	check("credits: author, homepage and licence on one short line",
		Credits.credit_text({"author": "A. Dev", "homepage": "https://www.x.org/", "licence": lic}),
		"By A. Dev · x.org · Licence CC BY-NC-ND 4.0")
	check("credits: no author still shows the homepage",
		Credits.credit_text({"homepage": "https://x.org/", "licence": lic}), "x.org · Licence CC BY-NC-ND 4.0")
	check("credits: JSON nulls (retroforge-emu list of an old catalog) are skipped",
		Credits.credit_text({"author": null, "homepage": null, "licence": null}), "")
	check("version: a pkgforge tag shows its version only",
		Credits.version_text("2609@2026-10-01_1790876487"), "2609")
	check("version: other tags are shown as they are",
		Credits.version_text("v0.1-11894"), "v0.1-11894")
	check("version: a nightly build (retroforge-emu's nightly-<id>) says Nightly",
		[Credits.version_text("nightly-cc6fea125"), Credits.version_text("nightly")], ["Nightly cc6fea125", "Nightly"])
	check("version: an RPCS3 build-<commit> keeps 8 digits",
		Credits.version_text("build-64ba740c27be6946074cd91db85be4d48146d768"), "Build 64ba740c")

## The Emulators page's rows (plan emulator-latest Phase 2): latest by default, tested kept, Revert.
func test_emu_state() -> void:
	var mb := 50 * 1048576
	var follows := {"tested": "v1", "follows_latest": true, "installed": null, "previous": null, "size": mb}
	var r := EmuState.rows("x", follows, {})
	check("state: not installed, no check yet: Download the newest, tested named",
		[r.main.text, r.main.button, r.main.args, r.main.description],
		["Not installed", "Download", ["install", "x"], "The newest version from upstream, about 50 MB. RetroForge tested v1."])
	check("state: not installed: Install tested offered right below Download, nothing else",
		[r.tested, r.extra], [{"text": "Install tested version (v1)", "button": "Install",
			"description": "The version RetroForge tested, 50 MB.", "args": ["install", "x", "--tested"]}, []])
	r = EmuState.rows("x", follows, {"latest": "v3", "error": null})
	check("state: not installed, check answered: names the newest", r.main.description,
		"Version v3, the newest from upstream, about 50 MB. RetroForge tested v1.")
	var inst := follows.merged({"installed": "v1"}, true)
	r = EmuState.rows("x", inst, {"latest": "v1", "error": null})
	check("state: the tested build installed and newest: Open, Tested, Check says up to date",
		[r.main.text, r.main.button, r.main.args, r.extra.map(func(e): return [e.args, e.description])],
		["Version v1 · Tested", "Open", [], [[["check", "x", "--refresh"], "Up to date: v1 is the newest from upstream."]]])
	r = EmuState.rows("x", inst, {})
	check("state: installed, never checked: no Update, a Check row that asks upstream on demand",
		[r.main.button, r.extra.map(func(e): return [e.button, e.description])],
		["Open", [["Check", "Asks upstream whether a newer version is out."]]])
	r = EmuState.rows("x", inst, {"latest": "v3", "error": null})
	check("state: a newer build upstream: Update to it (and no Check row)",
		[r.main.text, r.main.button, r.main.args, r.main.description],
		["Version v1 · Tested", "Update", ["install", "x"], "Update to v3 available, about 50 MB."])
	check("state: ... with no Check row beside the Update", r.extra.map(func(e): return e.button), [])
	r = EmuState.rows("x", inst, {"latest": null, "error": "GitHub answered HTTP 403"})
	check("state: a failed check (offline, rate limit): no Update, Check stays offered",
		[r.main.button, r.main.description, r.extra.map(func(e): return e.button)], ["Open", "Installed.", ["Check"]])
	var newer := follows.merged({"installed": "v3", "previous": "v1"}, true)
	r = EmuState.rows("x", newer, {"latest": "v3", "error": null})
	check("state: an untested build installed: says so, Install tested below it, Check and Revert before Delete",
		[r.main.text, r.main.description, r.tested.args, r.extra.map(func(e): return e.args)],
		["Version v3", "Installed straight from upstream. RetroForge tested v1.", ["install", "x", "--tested"],
			[["check", "x", "--refresh"], ["rollback", "x"]]])
	var cemu := {"tested": null, "follows_latest": true, "installed": "nightly-abc", "previous": "nightly-def", "size": mb}
	r = EmuState.rows("x", cemu, {"latest": "nightly-123", "error": null})
	check("state: a nightly-only entry: Update to the newer nightly (no Check beside it), Revert, never Install tested",
		[r.main.text, r.main.button, r.tested, r.extra.map(func(e): return e.text)],
		["Nightly abc", "Update", null, ["Revert to Nightly def"]])
	var pinned := {"tested": "v2", "follows_latest": false, "installed": "v1", "update": true, "previous": null, "size": mb}
	r = EmuState.rows("x", pinned, {})
	check("state: a pinned-only entry keeps the offline Update to its pin, no Install tested",
		[r.main.button, r.main.description, r.tested, r.extra], ["Update", "Update to v2 available, 50 MB.", null, []])
	var pm := {"tested": "2026.1", "follows_latest": true, "self_update": true, "installed": "2026.9", "previous": null, "size": mb}
	r = EmuState.rows("x", pm, {"latest": "2026.10", "error": null})
	check("state: PortMaster installed updates itself: Open only, no Update, no Install tested",
		[r.main.button, r.main.description, r.tested, r.extra], ["Open", "Installed. Updates itself: open it to check.", null, []])
	# Steam Client (retroforge-emu's "kind": "steam"): Valve's client updates itself, so a check
	# answer is ignored and there is never an Update, Check or Revert.
	var steam := {"kind": "steam", "installed": null, "size": 2110 * 1048576}
	r = EmuState.rows("steam-client", steam, {"latest": "v9", "error": null})
	check("state: Steam Client not installed: Download, no tested or extra rows",
		[r.main.text, r.main.button, r.main.args, r.tested, r.extra],
		["Not installed", "Download", ["install", "steam-client"], null, []])
	check("state: ... its description gives the download's size", r.main.description.contains("about 2110 MB"), true)
	r = EmuState.rows("steam-client", steam.merged({"installed": "1791918634"}, true), {"latest": "v9", "error": null})
	check("state: Steam Client installed: Open (Steam's UI) and a Repair row, nothing else",
		[r.main.text, r.main.button, r.main.args, r.tested, r.extra.map(func(e): return [e.button, e.args])],
		["Installed", "Open", [], null, [["Repair", ["install", "steam-client"]]]])

	# RetroArch (catalog "cores"): its libretro cores are installed and updated with it, and each one
	# can go back to the build kept beside it. A missing core (a failed install, a deleted file)
	# makes every game of its system stop with "download it again": the page offers Repair.
	var ra := {"tested": "1.22", "follows_latest": true, "installed": "1.22", "previous": null, "size": mb,
		"cores": {"snes9x": {"installed": "nightly-2026-11-07-aa", "previous": "nightly-2026-11-01-bb",
				"tested": null, "follows_latest": true, "source": "buildbot"},
			"armgba": {"installed": "v1.5", "previous": null, "tested": "v1.5", "follows_latest": true,
				"source": "github"}}}
	r = EmuState.rows("retroarch", ra, {"latest": "1.22", "error": null,
		"cores": {"snes9x": {"latest": "nightly-2026-11-07-aa", "error": null}, "armgba": {"latest": "v1.5", "error": null}}})
	check("state: cores up to date: Open, Check says up to date, a Revert row for the core that kept one",
		[r.main.button, r.extra.map(func(e): return [e.button, e.args])],
		["Open", [["Check", ["check", "retroarch", "--refresh"]], ["Revert", ["rollback", "retroarch", "--core=snes9x"]]]])
	check("state: ... the core's Revert row names the core and the build",
		r.extra[1].text, "Revert the snes9x core to Nightly 2026-11-01-bb")
	r = EmuState.rows("retroarch", ra, {"latest": "1.22", "error": null,
		"cores": {"snes9x": {"latest": "nightly-2026-11-08-cc", "error": null}, "armgba": {"latest": "v1.5", "error": null}}})
	check("state: a newer core nightly (RetroArch itself current): Update, naming the core",
		[r.main.button, r.main.args, r.main.description],
		["Update", ["install", "retroarch"], "Newer cores available: snes9x."])
	r = EmuState.rows("retroarch", ra, {"latest": "1.23", "error": null,
		"cores": {"snes9x": {"latest": "nightly-2026-11-08-cc", "error": null}, "armgba": {"latest": "v1.5", "error": null}}})
	check("state: RetroArch and a core newer: one Update, RetroArch's version first",
		[r.main.button, r.main.description], ["Update", "Update to 1.23 available, about 50 MB. Newer cores too."])
	r = EmuState.rows("retroarch", ra, {"latest": "1.22", "error": null,
		"cores": {"snes9x": {"latest": null, "error": "not on the libretro buildbot today"}, "armgba": {"latest": "v1.5", "error": null}}})
	check("state: a core whose check failed offers no Update and no 'up to date'",
		[r.main.button, r.extra[0].description], ["Open", "Asks upstream whether a newer version is out."])
	var broken := ra.duplicate(true)
	broken.cores.armgba.installed = null
	r = EmuState.rows("retroarch", broken, {})
	check("state: a missing core: Repair (install fetches only what is missing), naming it",
		[r.main.button, r.main.args, r.main.description],
		["Repair", ["install", "retroarch"], "The armgba core is missing: its games will not start. Repair downloads it."])
	var fresh := ra.merged({"installed": null}, true)
	r = EmuState.rows("retroarch", fresh, {})
	check("state: RetroArch not installed: Download as for any emulator (its cores come with it)",
		[r.main.button, r.main.args], ["Download", ["install", "retroarch"]])

## Per-emulator options: what the pages offer from options.json, and the choice at each level.
func test_emu_options() -> void:
	var json := JSON.stringify({"files": {"main": {"path": "x.ini", "format": "ini"}},
		"options": [{"id": "aspect", "label": "Aspect ratio", "description": "How the picture fills the screen.",
			"choices": [{"value": "4:3", "label": "4:3", "set": [{"args": ["-a"]}]},
				{"value": "16:9", "label": "16:9 (widescreen)", "set": [{"args": ["-w"]}]}]}]})
	var opts := EmuOptions.parse(json)
	check("options: parsed in order, choices without their actions",
		opts, [{"id": "aspect", "label": "Aspect ratio", "description": "How the picture fills the screen.",
			"choices": [{"value": "4:3", "label": "4:3"}, {"value": "16:9", "label": "16:9 (widescreen)"}]}])
	check("options: none without an options.json", EmuOptions.parse(""), [])
	check("options: an option missing its choices hides them all (never offer what cannot apply)",
		EmuOptions.parse('{"options": [{"id": "a", "label": "A"}]}'), [])
	check("options: not JSON", EmuOptions.parse("{"), [])
	# What the launcher refuses is never offered: a saved value would not apply (or would break the conf).
	var bad_cases := {
		"an id that is the CPUS key": {"id": "CPUS"},
		"an uppercase id": {"id": "Aspect"},
		"an id with =": {"id": "a=b"},
		"an empty value (it is the unset item)": {"choices": [{"value": "", "label": "x", "set": [{"args": ["-x"]}]}]},
		"a value with a space": {"choices": [{"value": "a b", "label": "x", "set": [{"args": ["-x"]}]}]},
		"a value with a newline": {"choices": [{"value": "a\nCPUS=big", "label": "x", "set": [{"args": ["-x"]}]}]},
		"a repeated value": {"choices": [{"value": "a", "label": "x", "set": [{"args": ["-x"]}]},
			{"value": "a", "label": "y", "set": [{"args": ["-y"]}]}]},
		"a choice with nothing to do": {"choices": [{"value": "a", "label": "x", "set": []}]},
		"a choice without set": {"choices": [{"value": "a", "label": "x"}]},
		"a two-line label": {"label": "A\nB"},
	}
	for what in bad_cases:
		var option := {"id": "aspect", "label": "A", "choices": [{"value": "a", "label": "x", "set": [{"args": ["-x"]}]}]}
		option.merge(bad_cases[what], true)
		check("options: refused with " + what, EmuOptions.parse(JSON.stringify({"options": [option]})), [])
	var one := {"id": "aspect", "label": "A", "choices": [{"value": "a", "label": "x", "set": [{"args": ["-x"]}]}]}
	check("options: refused with a repeated option id", EmuOptions.parse(JSON.stringify({"options": [one, one]})), [])
	write(OS.get_environment("XDG_CONFIG_HOME") + "/../data/fakeemu/options.json", json)
	check("options: read from <data dir>/<emulator>/options.json",
		EmuOptions.options_for("fakeemu", OS.get_environment("XDG_CONFIG_HOME") + "/../data").size(), 1)
	# Every options.json the image ships: the pages offer it in full (emuopts loads them in test-emuopts.sh).
	var data_dir := "$ROOT/rootfs/overlay/usr/share/retroforge/emulators"
	for emu in DirAccess.get_directories_at(data_dir):
		var path := data_dir.path_join(emu).path_join("options.json")
		if FileAccess.file_exists(path):
			var raw = JSON.parse_string(FileAccess.get_file_as_string(path))
			check("image %s/options.json: every option offered" % emu, EmuOptions.options_for(emu, data_dir).size(), raw["options"].size())
	check("options: an emulator without options.json has none",
		EmuOptions.options_for("nope", OS.get_environment("XDG_CONFIG_HOME") + "/../data"), [])
	var aspect: Dictionary = opts[0]
	check("emulator level: the emulator's own setting first, then the choices",
		EmuOptions.emulator_items(aspect), PackedStringArray(["Emulator's setting", "4:3", "16:9 (widescreen)"]))
	check("game level: the emulator's choice named in the default",
		EmuOptions.game_items(aspect, "16:9"), PackedStringArray(["Emulator default (16:9 (widescreen))", "4:3", "16:9 (widescreen)"]))
	check("game level: no emulator choice",
		EmuOptions.game_items(aspect, "")[0], "Emulator default (emulator's setting)")
	check("items stand for: unset, then each value", EmuOptions.values(aspect), ["", "4:3", "16:9"])
	check("a saved value selects its item", EmuOptions.index_of(aspect, "16:9"), 2)
	check("an unknown saved value selects unset", EmuOptions.index_of(aspect, "21:9"), 0)
	check("conf: the option id is the key, last line wins",
		EmuOptions.conf_choice("aspect=4:3\nCPUS=big\naspect=16:9\n", aspect), "16:9")
	check("conf: a value the option does not have reads as unset", EmuOptions.conf_choice("aspect=21:9\n", aspect), "")
	var rom := "/home/player/roms/psx/Crash Team Racing (USA).chd"
	check("emulator choice: unset at first", EmuOptions.emulator_choice("duckstation", aspect), "")
	EmuOptions.set_emulator_choice("duckstation", aspect, "4:3")
	LaunchArgs.set_emulator_fast_cores("duckstation", true)
	check("emulator choice: saved beside CPUS", FileAccess.get_file_as_string(LaunchArgs.player_conf_path("duckstation")),
		"aspect=4:3\nCPUS=big\n")
	EmuOptions.set_game_choice("psx", rom, aspect, "16:9")
	check("game choice: in the game's conf", EmuOptions.game_choice("psx", rom, aspect), "16:9")
	EmuOptions.set_game_choice("psx", rom, aspect, "")
	check("game choice: back to the emulator default, no file left", FileAccess.file_exists(LaunchArgs.game_conf_path("psx", rom)), false)
	LaunchArgs.set_game_cpus("psx", rom, "big")
	EmuOptions.set_game_choice("psx", rom, aspect, "16:9")
	EmuOptions.set_game_choice("psx", rom, aspect, "")
	check("game choice: clearing an option keeps the game's CPUS line",
		FileAccess.get_file_as_string(LaunchArgs.game_conf_path("psx", rom)), "CPUS=big\n")
	LaunchArgs.set_game_cpus("psx", rom, "")
	write(LaunchArgs.game_conf_path("psx", rom), "# mine\naspect=4:3\nother=1\naspect=21:9\n")
	EmuOptions.set_game_choice("psx", rom, aspect, "16:9")
	check("game choice: other lines kept, repeated lines collapse to one",
		FileAccess.get_file_as_string(LaunchArgs.game_conf_path("psx", rom)), "# mine\nother=1\naspect=16:9\n")
	DirAccess.remove_absolute(LaunchArgs.game_conf_path("psx", rom))
	EmuOptions.set_emulator_choice("duckstation", aspect, "")
	LaunchArgs.set_emulator_fast_cores("duckstation", false)
	check("emulator choice: back to the emulator's setting", EmuOptions.emulator_choice("duckstation", aspect), "")


## The Steam games, from the signed-in client's own files (library_steam.gd, steam_apps.gd): no
## second sign-in, as the OGUI Steam plugin's steamcmd needs. Which games is steam-library's to say
## (tests/test-steam-library.sh); here its JSON, an install's progress, launching, art and rescans.
func acf(appid: String, name: String, flags: int, dir: String, extra := "") -> String:
	var nested := '\t"UserConfig"\n\t{\n\t\t"StateFlags"\t\t"999"\n\t}\n'
	var top := '\t"appid"\t\t"%s"\n\t"name"\t\t"%s"\n\t"StateFlags"\t\t"%d"\n\t"installdir"\t\t"%s"\n' % [appid, name, flags, dir]
	return '"AppState"\n{\n' + nested + top + extra + '}\n'

func test_steam_apps() -> void:
	var root := "$T/steam"
	var sd := "$T/sdcard/SteamLibrary"
	var apps := root + "/steamapps"
	write(apps + "/libraryfolders.vdf", '"libraryfolders"\n{\n\t"0"\n\t{\n\t\t"path"\t\t"%s"\n\t\t"apps"\n\t\t{\n\t\t\t"1145360"\t\t"1"\n\t\t}\n\t}\n\t"1"\n\t{\n\t\t"path"\t\t"%s/"\n\t}\n}\n' % [root, sd])
	write(apps + "/appmanifest_1145360.acf", acf("1145360", "Hades", 4, "Hades"))
	check("steam: library folders are the client's root, then libraryfolders.vdf's other paths, once",
		SteamApps.library_dirs(root), PackedStringArray([root, sd]))
	var games := SteamApps.parse_library('{"games": [{"appid": 1145360, "name": "Hades", "installed": true, "dir": "/x/Hades"}, {"appid": 413150, "name": "Stardew Valley", "installed": false, "dir": ""}, {"appid": "x", "name": "No Id"}, {"appid": 9, "name": ""}], "owned_known": true}')
	check("steam library: steam-library's games, installed or not; an entry without an id or a name dropped",
		games, [{"appid": 1145360, "name": "Hades", "installed": true, "dir": "/x/Hades"}, {"appid": 413150, "name": "Stardew Valley", "installed": false, "dir": ""}])
	check("steam library: anything that is not its JSON is no games",
		[SteamApps.parse_library(""), SteamApps.parse_library("[1]"), SteamApps.parse_library('{"games": 3}')], [[], [], []])
	write(sd + "/steamapps/appmanifest_268910.acf", acf("268910", "Cuphead", 1026, "Cuphead", '\t"BytesToDownload"\t\t"4000"\n\t"BytesDownloaded"\t\t"1000"\n'))
	check("steam install: progress from the manifest, in any library folder (a nested section's flags are not the app's)",
		SteamApps.app_state(root, 268910), {"flags": 1026, "done": 1000, "total": 4000})
	check("steam install: no manifest yet, no state", SteamApps.app_state(root, 413150), {})
	check("steam install: done once fully installed with nothing still going",
		[SteamApps.install_complete(4), SteamApps.install_complete(6), SteamApps.install_complete(1026), SteamApps.install_complete(4 | 0x100000), SteamApps.install_complete(0)],
		[true, false, false, false, false])
	check("steam: launched as the OGUI Steam plugin does, with the rungameid OGUI takes the app id from",
		SteamApps.launch_args(1145360),
		PackedStringArray(["-gamepadui", "-steamos3", "-steampal", "-steamdeck", "-silent", "steam://rungameid/1145360"]))
	check("steam: the app a launch starts, from its rungameid: ours, a Steam shortcut's, the Steam plugin's; none otherwise",
		[SteamApps.appid_of(SteamApps.launch_args(1145360)), SteamApps.appid_of(PackedStringArray(["-silent", "steam://rungameid/413150"])),
		 SteamApps.appid_of(PackedStringArray(["steam://open/bigpicture"])), SteamApps.appid_of(PackedStringArray(["steam://rungameid/x"])), SteamApps.appid_of(PackedStringArray())],
		[1145360, 413150, 0, 0, 0])
	check("steam: an install or uninstall opens Steam's own UI at the steam:// URI, not silent",
		SteamApps.ui_args("steam://install/413150"),
		PackedStringArray(["-gamepadui", "-steamos3", "-steampal", "-steamdeck", "steam://install/413150"]))
	check("steam client: not installed without the client's arm64 binary", SteamApps.client_installed(root), false)
	write(root + "/steamrtarm64/steam", "elf")
	check("steam client: not installed while the x86 guest is missing", SteamApps.client_installed(root), false)
	OS.set_environment("RETROFORGE_STEAM_X86_GUEST", "0")
	check("steam client: installed without the x86 guest when it is off", SteamApps.client_installed(root), true)
	OS.set_environment("RETROFORGE_STEAM_X86_GUEST", "")
	write("$T/retroforge/fex-guest/current", "1")
	check("steam client: installed with the x86 guest beside the client's folder", SteamApps.client_installed(root), true)
	var cache := root + "/appcache/librarycache"
	write(cache + "/1145360/library_600x900.jpg", "p")
	write(cache + "/1145360/0a1b2c/logo.png", "l")
	write(cache + "/268910_header.jpg", "h")
	check("steam art: the client's cached art per OGUI layout: in the app's folder, one folder down, or flat (older clients)",
		[SteamApps.art_path(root, 1145360, 0), SteamApps.art_path(root, 1145360, 3), SteamApps.art_path(root, 268910, 1)],
		[cache + "/1145360/library_600x900.jpg", cache + "/1145360/0a1b2c/logo.png", cache + "/268910_header.jpg"])
	check("steam art: none cached, or a layout OGUI does not have: none",
		[SteamApps.art_path(root, 268910, 2), SteamApps.art_path(root, 1145360, 7)], ["", ""])
	# Valve's CDN, played by a folder: <cdn>/<appid>/<file>.
	var cdn := "$T/cdn"
	var art := "$T/steam-art"
	OS.set_environment("RETROFORGE_STEAM_ART_CDN", "file://" + cdn)
	write(cdn + "/413150/library_600x900.jpg", "card")
	var got := SteamApps.fetch_art(art, 413150, 0)
	check("steam art fetch: an owned game's card art from Valve's CDN, kept in the cache",
		[got, FileAccess.get_file_as_string(got)], [art + "/413150/library_600x900.jpg", "card"])
	DirAccess.remove_absolute(cdn + "/413150/library_600x900.jpg")
	check("steam art fetch: kept art is not fetched again", SteamApps.fetch_art(art, 413150, 0), art + "/413150/library_600x900.jpg")
	check("steam art fetch: art the CDN does not have: none, and a mark", [SteamApps.fetch_art(art, 413150, 3), FileAccess.file_exists(art + "/413150/logo.png.missing")], ["", true])
	write(cdn + "/413150/logo.png", "logo")
	check("steam art fetch: not asked again for a day", SteamApps.fetch_art(art, 413150, 3), "")
	check("steam art fetch: no app id or no such layout: nothing asked", [SteamApps.fetch_art(art, 0, 0), SteamApps.fetch_art(art, 413150, 9)], ["", ""])
	OS.set_environment("RETROFORGE_STEAM_ART_CDN", "http://127.0.0.1:9")
	check("steam art fetch: an unreachable CDN (a network stall): none, no mark, asked again next time",
		[SteamApps.fetch_art(art, 413150, 2), FileAccess.file_exists(art + "/413150/library_hero.jpg.missing")], ["", false])
	write(cache + "/2073850/bde08dae/library_capsule.jpg", "c")
	check("steam art: the newer cache's portrait (library_capsule.jpg, in a hashed folder)",
		SteamApps.art_path(root, 2073850, 0), cache + "/2073850/bde08dae/library_capsule.jpg")
	OS.set_environment("RETROFORGE_STEAM_ART_CDN", "")
	var watch = SteamWatch.new().watch_steam(root)
	check("steam rescan: nothing before OGUI's first library load", [watch.poll(false), watch.poll(false)], [false, false])
	watch.mark_loaded()
	check("steam rescan: nothing while the client's files match the library", [watch.poll(false), watch.poll(false)], [false, false])
	write(sd + "/steamapps/appmanifest_413150.acf", acf("413150", "Stardew Valley", 4, "Stardew Valley"))
	check("steam rescan: a game installed (another library folder too) is due once two polls agree",
		[watch.poll(false), watch.poll(false)], [false, true])
	watch.mark_loaded()
	write(root + "/appcache/packageinfo.vdf", "licenses")
	check("steam rescan: a new license in the client's cache (a game bought elsewhere) is due",
		[watch.poll(false), watch.poll(false)], [false, true])
	watch.mark_loaded()
	DirAccess.remove_absolute(apps + "/appmanifest_1145360.acf")
	check("steam rescan: never while a game (or Steam's UI) runs", [watch.poll(true), watch.poll(true)], [false, false])
	check("steam rescan: an uninstall is due after it", [watch.poll(false), watch.poll(false)], [false, true])

func write(path: String, text: String) -> void:
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(text)
	f.close()

func append(path: String, text: String) -> void:
	var f := FileAccess.open(path, FileAccess.READ_WRITE)
	f.seek_end()
	f.store_string(text)
	f.close()

## Automatic rescan: ROMs copied over SMB only showed after Refresh Library or a restart.
func test_rom_watch() -> void:
	var roms := "$T/roms"
	write(roms + "/psx/A.chd", "aaaa")
	var watch = RomWatch.new().setup(roms, ["psx", "ps2"])
	check("rescan: nothing before OGUI's first library load", [watch.poll(false), watch.poll(false)], [false, false])
	watch.mark_loaded()
	check("rescan: nothing while the folders match the library", [watch.poll(false), watch.poll(false)], [false, false])
	write(roms + "/psx/B.chd", "bb")
	check("rescan: a new ROM waits one poll (copy may still run)", watch.poll(false), false)
	check("rescan: then it is due once two polls agree", watch.poll(false), true)
	watch.mark_loaded()
	check("rescan: not again after the reload", watch.poll(false), false)
	write(roms + "/psx/C.chd", "c")
	watch.poll(false)
	append(roms + "/psx/C.chd", "cc")
	check("rescan: a file still growing keeps it waiting", watch.poll(false), false)
	check("rescan: due once the file stopped growing", watch.poll(false), true)
	watch.mark_loaded()
	OS.execute("touch", ["-d", "@1000000000", roms + "/psx/C.chd"])
	watch.poll(false)
	OS.execute("touch", ["-d", "@1000000100", roms + "/psx/C.chd"])
	check("rescan: same size but a new mtime (SMB copy into a preallocated file) keeps it waiting", watch.poll(false), false)
	check("rescan: due once the mtime settled", watch.poll(false), true)
	watch.mark_loaded()
	DirAccess.remove_absolute(roms + "/psx/A.chd")
	check("rescan: a deleted ROM is due too", [watch.poll(false), watch.poll(false)], [false, true])
	watch.mark_loaded()
	write(roms + "/ps2/J.iso", "j")
	check("rescan: a system folder created later is watched", [watch.poll(false), watch.poll(false)], [false, true])
	watch.mark_loaded()
	write(roms + "/gc/G.iso", "g")
	write(roms + "/psx/sub/D.chd", "d")
	check("rescan: other folders and subfolders are not ROMs", [watch.poll(false), watch.poll(false)], [false, false])
	write(roms + "/psx/E.chd", "e")
	check("rescan: never while a game runs", [watch.poll(false), watch.poll(true), watch.poll(true)], [false, false, false])
	check("rescan: after the game, two settled polls again", [watch.poll(false), watch.poll(false)], [false, true])
	write(roms + "/psx/F.chd", "f")
	watch.mark_loaded()
	check("rescan: a ROM copied between our scan and library_loaded is still picked up",
		[watch.poll(false), watch.poll(false)], [false, true])
GD
  out="$(XDG_CONFIG_HOME="$T/config" "$GODOT" --headless --script "$T/names_test.gd" 2>&1)"; rc=$?
  printf '%s\n' "$out" | grep -E '^  (ok|FAIL) '
  n_ok="$(printf '%s\n' "$out" | grep -c '^  ok ')"; n_bad="$(printf '%s\n' "$out" | grep -c '^  FAIL ')"
  PASS=$((PASS + n_ok)); FAIL=$((FAIL + n_bad))
  if [ "$rc" -ne 0 ] && [ "$n_bad" -eq 0 ]; then
    bad "Godot failed: $(printf '%s\n' "$out" | grep -E 'ERROR|error' | head -3)"
  fi
  # Godot exits 0 when a preloaded script does not compile: the checks using it just never run.
  if printf '%s\n' "$out" | grep -q 'SCRIPT ERROR'; then
    bad "a script did not compile: $(printf '%s\n' "$out" | grep 'SCRIPT ERROR' | head -3)"
  fi

  # scrape_runner.gd runs /usr/bin/retroforge-scrape on a worker thread; here against a fake tool
  # that behaves like it (progress lines, a JSON summary, warnings on stderr, an exit code). Its
  # signals arrive over frames, so this is a script of its own that awaits them.
  CASE="scrape runner"
  cat >"$T/fake-scrape" <<'SH'
#!/bin/bash
# $FAKE_MODE: ok | quota | login (reads the password on stdin) | slow (until SIGTERM)
printf '%s\n' "$*" > "$FAKE_ARGS"
printf '%s\n' "$*" >> "${FAKE_LOG:-/dev/null}"
case $FAKE_MODE in
  rom) echo "100%"; echo '{"scraped": 1, "not_found": 0, "skipped": 0, "failed": 0, "quota_left": 9}'; exit 0 ;;
  lost) echo "100%"; echo '{"scraped": 0, "not_found": 0, "skipped": 0, "failed": 1, "quota_left": 9}'; exit 0 ;;
  login) read -r pw; [ "$pw" = pw-secret ] && exit 0; echo "retroforge-scrape: ScreenScraper refused the player's login" >&2; exit 7 ;;
  slow) trap 'echo "{\"scraped\": 1, \"not_found\": 0, \"skipped\": 0, \"failed\": 0, \"quota_left\": 9}"; echo "retroforge-scrape: cancelled" >&2; exit 5' TERM
        echo "10%"; while :; do sleep 0.1; done ;;
esac
for i in $(seq 1 3000); do echo "retroforge-scrape: warning: $i: no image (200 text/html)" >&2; done
echo "50%"; echo "100%"
echo '{"scraped": 3, "not_found": 1, "skipped": 5, "failed": 1, "quota_left": 9000}'
[ "$FAKE_MODE" = quota ] && { echo "retroforge-scrape: ScreenScraper's daily request quota is used up: try again tomorrow" >&2; exit 6; }
exit 0
SH
  chmod +x "$T/fake-scrape"
  cat >"$T/runner_test.gd" <<GD
extends SceneTree

const ScrapeRunner := preload("$SRC/scrape_runner.gd")
const ArtFetch := preload("$SRC/art_fetch.gd")
const SharedArt := preload("$SRC/shared_art.gd")
var failed := 0

func check(what: String, got, want) -> void:
	if got == want:
		print("  ok   $CASE -- ", what)
	else:
		failed += 1
		print("  FAIL $CASE -- ", what, ": got ", got, ", want ", want)

func _initialize() -> void:
	run()

func job(mode: String, args: Array, stdin_text := "", cancel_at := -1) -> Dictionary:
	OS.set_environment("FAKE_MODE", mode)
	OS.set_environment("FAKE_ARGS", "$T/fake-args")
	var r := ScrapeRunner.new()
	r.tool = "$T/fake-scrape"
	var seen: Array[int] = []
	r.progressed.connect(func(p: int) -> void:
		seen.append(p)
		if p == cancel_at:
			r.cancel())
	check(mode + ": starts", r.start(args, stdin_text), true)
	check(mode + ": a second start while running is refused", r.start(args), false)
	var res: Array = await r.finished
	return {"code": res[0], "summary": res[1], "error": res[2], "seen": seen, "running": r.running}

func run() -> void:
	check("line: progress", ScrapeRunner.parse_line("42%"), {"percent": 42})
	check("line: the summary (JSON numbers are floats)", ScrapeRunner.parse_line('{"scraped": 1}'), {"summary": {"scraped": 1.0}})
	check("line: anything else is ignored", [ScrapeRunner.parse_line("x"), ScrapeRunner.parse_line("101%"), ScrapeRunner.parse_line("[1]")], [{}, {}, {}])
	check("summary text", ScrapeRunner.summary_text({"scraped": 3, "not_found": 1, "skipped": 5, "failed": 1}),
		"Art for 3 games. 1 not found on ScreenScraper. 1 failed: try again later.")
	check("summary text: nothing new", ScrapeRunner.summary_text({"scraped": 0, "not_found": 0, "skipped": 5, "failed": 0}), "No new art: every game is up to date.")
	check("failure: no developer login in this build", "cannot scrape" in ScrapeRunner.failure_text(9, ""), true)
	check("failure: login refused", "user name or password" in ScrapeRunner.failure_text(7, ""), true)
	check("failure: network", "network" in ScrapeRunner.failure_text(3, "retroforge-scrape: ScreenScraper unreachable (curl exit 6)"), true)
	check("failure: quota and closed say the tool's own reason, without its prefix",
		[ScrapeRunner.failure_text(6, "retroforge-scrape: warning: x\nretroforge-scrape: ScreenScraper's daily request quota is used up: try again tomorrow"),
		 ScrapeRunner.failure_text(8, "retroforge-scrape: ScreenScraper is closed for maintenance")],
		["ScreenScraper's daily request quota is used up: try again tomorrow", "ScreenScraper is closed for maintenance"])
	check("failure: cancelled", ScrapeRunner.failure_text(5, "retroforge-scrape: cancelled"), "Cancelled.")

	var a := await job("ok", ["run", "--all"])
	check("ok: exit 0, progress in order, the summary", [a.code, a.seen, a.summary.get("scraped")], [0, [50, 100], 3.0])
	check("ok: arguments reach the tool", FileAccess.get_file_as_string("$T/fake-args").strip_edges(), "run --all")
	check("ok: 3,000 warnings on stderr did not stall it, and are not the error", a.error, "")
	check("ok: not running any more", a.running, false)
	var b := await job("quota", ["run"])
	check("quota: exit 6 with the tool's last stderr line", [b.code, b.error], [6, "retroforge-scrape: ScreenScraper's daily request quota is used up: try again tomorrow"])
	var c := await job("login", ["login", "good"], "pw-secret")
	check("login: the password goes on stdin", c.code, 0)
	check("login: never in the arguments", FileAccess.get_file_as_string("$T/fake-args").strip_edges(), "login good")
	var d := await job("login", ["login", "good"], "wrong")
	check("login: refused is exit 7", d.code, 7)
	var e := await job("slow", ["run"], "", 10)
	check("cancel: SIGTERM, the tool's summary and exit 5", [e.code, e.summary.get("scraped"), e.seen], [5, 1.0, [10]])
	var r := ScrapeRunner.new()
	r.tool = "$T/no-such-tool"
	r.start(["run"])
	var f: Array = await r.finished
	check("a tool that cannot start: exit -1", f[0], -1)
	await test_art_fetch()
	await test_shared_art()
	quit(1 if failed else 0)

# shared_art.gd: one texture per art file for every card showing it, held only while a card holds it.
func test_shared_art() -> void:
	var art := SharedArt.new()
	var src := "$T/shared-art.png"
	Image.create(4, 6, false, Image.FORMAT_RGBA8).save_png(src)
	var decodes := []
	var job := func() -> Image:
		decodes.append(1)
		return Image.load_from_file(src)
	var both := []
	var ask := func() -> void: both.append(await art.texture("card:" + src, src, job))
	ask.call()
	ask.call()
	while both.size() < 2:
		await process_frame
	check("shared art: two cards asking at once get one texture, decoded once",
		[both[0] != null, both[0] == both[1], decodes.size()], [true, true, 1])
	var held: Texture2D = both[0]
	both.clear()
	var later: Texture2D = await art.texture("card:" + src, src, job)
	check("shared art: a later card gets the one a card still holds", [later == held, decodes.size()], [true, 1])
	later = null
	held = null
	var fresh: Texture2D = await art.texture("card:" + src, src, job)
	check("shared art: once no card holds it, the file is decoded again", [fresh != null, decodes.size()], [true, 2])
	OS.execute("touch", ["-m", "-d", "2001-01-01", src])
	var newer: Texture2D = await art.texture("card:" + src, src, job)
	check("shared art: a changed file is decoded again, while a card holds the old one", [newer != fresh, decodes.size()], [true, 3])
	var none: Texture2D = await art.texture("card:none", "$T/none.png", func() -> Image: return null)
	check("shared art: no image, no texture", none, null)

# art_fetch.gd: a card of a ROM with no art fetches it (run --rom) and awaits it, as Steam's do.
func fetcher(mode: String, allowed := true) -> ArtFetch:
	OS.set_environment("FAKE_MODE", mode)
	var a := ArtFetch.new()
	a.runner.tool = "$T/fake-scrape"
	a.cache_path = "$T/scrape.json"
	a.allowed = func() -> bool: return allowed
	return a

func runs() -> PackedStringArray:
	var text := FileAccess.get_file_as_string("$T/fake-log").strip_edges()
	return PackedStringArray() if text == "" else text.split("\n")

func test_art_fetch() -> void:
	OS.set_environment("FAKE_LOG", "$T/fake-log")
	FileAccess.open("$T/scrape.json", FileAccess.WRITE).store_string('{"roms": {"snes/Known.zip": {"status": "not_found"}}}')
	check("fetch: the key is the tool's (system/file, a game folder's name)",
		[ArtFetch.key_of("snes", "/r/snes/A (USA).zip"), ArtFetch.key_of("ps3", "/r/ps3/Game/")], ["snes/A (USA).zip", "ps3/Game"])
	var a := fetcher("rom")
	await a.fetch("snes", "/r/snes/New.zip")
	check("fetch: a ROM never tried is scraped, alone, and awaited", runs(), PackedStringArray(["run --rom /r/snes/New.zip"]))
	await a.fetch("snes", "/r/snes/Known.zip")
	await a.fetch("ports", "/r/ports/Port.sh")
	check("fetch: not a ROM the tool already tried, nor a port (PortMaster's art)", runs().size(), 1)
	a.fetch("snes", "/r/snes/Twice.zip")
	a.fetch("snes", "/r/snes/Twice.zip")
	a.fetch("snes", "/r/snes/Other.zip")
	while not a._pending.is_empty():
		await a.fetched
	check("fetch: a ROM asked for twice runs once; one run at a time, in order", runs().slice(1),
		PackedStringArray(["run --rom /r/snes/Twice.zip", "run --rom /r/snes/Other.zip"]))
	await fetcher("rom", false).fetch("snes", "/r/snes/Off.zip")
	check("fetch: nothing when not allowed (setting off, no developer login)", runs().size(), 3)
	var b := fetcher("rom")
	b.other = ScrapeRunner.new()
	b.other.tool = "$T/fake-scrape"
	OS.set_environment("FAKE_MODE", "slow")
	b.other.start(["run", "--all"])
	b.fetch("snes", "/r/snes/Wait.zip")
	await create_timer(0.3).timeout
	check("fetch: waits for a Settings run going", runs()[-1], "run --all")
	OS.set_environment("FAKE_MODE", "rom")
	b.other.cancel()
	while not b._pending.is_empty():
		await b.fetched
	check("fetch: then runs", runs()[-1], "run --rom /r/snes/Wait.zip")
	for mode in ["quota", "lost"]:
		var c := fetcher(mode)
		await c.fetch("snes", "/r/snes/%s.zip" % mode)
		var n := runs().size()
		await c.fetch("snes", "/r/snes/%s-next.zip" % mode)
		check("fetch: after a %s run, every fetch is held (offline, cards would wait on curl)" % mode, runs().size(), n)
GD
  out="$(XDG_CONFIG_HOME="$T/config" timeout 60 "$GODOT" --headless --script "$T/runner_test.gd" 2>&1)"; rc=$?
  printf '%s\n' "$out" | grep -E '^  (ok|FAIL) '
  n_ok="$(printf '%s\n' "$out" | grep -c '^  ok ')"; n_bad="$(printf '%s\n' "$out" | grep -c '^  FAIL ')"
  PASS=$((PASS + n_ok)); FAIL=$((FAIL + n_bad))
  if [ "$rc" -ne 0 ] && [ "$n_bad" -eq 0 ]; then
    bad "Godot failed (rc $rc): $(printf '%s\n' "$out" | grep -E 'ERROR|error' | head -3)"
  fi
  if printf '%s\n' "$out" | grep -q 'SCRIPT ERROR'; then
    bad "a script did not compile: $(printf '%s\n' "$out" | grep 'SCRIPT ERROR' | head -3)"
  fi

  # psn_runner.gd runs `retroforge-launch --psn-install` on a worker thread (plan psn-pkg Phase 3);
  # here against a fake verb that prints tab-separated result lines, noise on stderr, and exits as
  # the real one does (0 all ok, 3 when something failed).
  CASE="psn runner"
  cat >"$T/fake-psn" <<'SH'
#!/bin/bash
# $FAKE_PSN_MODE: ok | mixed | empty
echo "retroforge-launch: psn-install: dev_hdd0 at /x" >&2
case $FAKE_PSN_MODE in
  ok)    printf 'ok\tA Game.pkg\tNPUB30024\tA Game.psn\n'; printf 'ok\tA.rap\t-\t-\n'; exit 0 ;;
  mixed) printf 'ok\tUpdate.pkg\tNPUB30024\t-\n'; printf 'failed\tBroken.pkg\tNPUB11111\t-\n'
         echo "retroforge-launch: psn-install: Broken.pkg: no PARAM.SFO" >&2; exit 3 ;;
  empty) echo "nothing-to-do"; exit 0 ;;
esac
SH
  chmod +x "$T/fake-psn"
  cat >"$T/psn_runner_test.gd" <<GD
extends SceneTree

const PsnRunner := preload("$SRC/psn_runner.gd")
var failed := 0

func check(what: String, got, want) -> void:
	if got == want:
		print("  ok   $CASE -- ", what)
	else:
		failed += 1
		print("  FAIL $CASE -- ", what, ": got ", got, ", want ", want)

func _initialize() -> void:
	run()

func job(mode: String) -> Dictionary:
	OS.set_environment("FAKE_PSN_MODE", mode)
	var r := PsnRunner.new()
	r.tool = "$T/fake-psn"
	check(mode + ": starts", r.start(), true)
	check(mode + ": a second start while running is refused", r.start(), false)
	var res: Array = await r.finished
	return {"code": res[0], "results": res[1], "error": res[2], "running": r.running}

func run() -> void:
	check("line: ok", PsnRunner.parse_line("ok\tA Game.pkg\tNPUB30024\tA Game.psn"),
		{"status": "ok", "file": "A Game.pkg", "title_id": "NPUB30024", "stub": "A Game.psn"})
	check("line: anything else is ignored",
		[PsnRunner.parse_line("nothing-to-do"), PsnRunner.parse_line("noise"), PsnRunner.parse_line("ok\tx\ty")],
		[{}, {}, {}])
	check("results text", PsnRunner.results_text([
		{"status": "ok", "file": "A.pkg", "stub": "A.psn"}, {"status": "ok", "file": "B.PKG", "stub": "-"},
		{"status": "ok", "file": "A.rap", "stub": "-"}, {"status": "failed", "file": "C.pkg", "stub": "-"}]),
		"Installed 2 packages. 1 licence. 1 failed and stays in roms/ps3/psn.")
	check("results text: empty inbox", PsnRunner.results_text([]), "Nothing to install: the PSN folder is empty.")
	check("a stub means the library reloads", [PsnRunner.any_stub([{"status": "ok", "stub": "A.psn"}]),
		PsnRunner.any_stub([{"status": "ok", "stub": "-"}, {"status": "failed", "stub": "x.psn"}])], [true, false])
	check("failure: concurrent", PsnRunner.failure_text(3, "retroforge-launch: a PSN install or a PlayStation 3 game is already running"),
		"A PSN install or a PlayStation 3 game is already running.")
	check("failure: rpcs3 missing", "Apps" in PsnRunner.failure_text(3, "retroforge-launch: rpcs3 is not installed (x)"), true)

	var a := await job("ok")
	check("ok: exit 0, both result lines, stderr noise is not the error",
		[a.code, a.results.size(), a.error, a.running], [0, 2, "", false])
	var b := await job("mixed")
	check("mixed: exit 3, the last stderr line is the error",
		[b.code, b.results.size(), "Broken.pkg" in b.error], [3, 2, true])
	var c := await job("empty")
	check("empty: exit 0 with no results", [c.code, c.results], [0, []])
	var r := PsnRunner.new()
	r.tool = "$T/no-such-tool"
	r.start()
	var f: Array = await r.finished
	check("a tool that cannot start: exit -1", f[0], -1)
	quit(1 if failed else 0)
GD
  out="$(XDG_CONFIG_HOME="$T/config" timeout 60 "$GODOT" --headless --script "$T/psn_runner_test.gd" 2>&1)"; rc=$?
  printf '%s\n' "$out" | grep -E '^  (ok|FAIL) '
  n_ok="$(printf '%s\n' "$out" | grep -c '^  ok ')"; n_bad="$(printf '%s\n' "$out" | grep -c '^  FAIL ')"
  PASS=$((PASS + n_ok)); FAIL=$((FAIL + n_bad))
  if [ "$rc" -ne 0 ] && [ "$n_bad" -eq 0 ]; then
    bad "Godot failed (rc $rc): $(printf '%s\n' "$out" | grep -E 'ERROR|error' | head -3)"
  fi
  if printf '%s\n' "$out" | grep -q 'SCRIPT ERROR'; then
    bad "a script did not compile: $(printf '%s\n' "$out" | grep 'SCRIPT ERROR' | head -3)"
  fi

  # panel_client.gd: the Hardware card's busctl to retroforge-paneld, on a worker thread. Against
  # the REAL daemon on a dbus-run-session bus over a fabricated sysfs (busctl --user), so what is
  # pinned is busctl's actual --json=short reply and its "Call failed:" text, not a guess at them.
  # No display here: a measured status carries measureError and Calibrate fails, which is the path
  # the card must show rather than swallow.
  CASE="panel client"
  PANELD="$ROOT/rootfs/overlay/usr/bin/retroforge-paneld"
  if ! command -v dbus-run-session >/dev/null || ! command -v busctl >/dev/null || ! python3 -c 'import gi' 2>/dev/null; then
    printf '  skip %s -- no dbus-run-session, busctl or python gi\n' "$CASE"
  else
    mkdir -p "$T/panel/sys/ae94000.dsi.0" "$T/panel/dri"
    echo 76 > "$T/panel/sys/ae94000.dsi.0/frame_len_120"; echo 2006 > "$T/panel/sys/ae94000.dsi.0/frame_len_60"
    printf 'SERIAL-P\0' > "$T/panel/serial"
    echo '{"SERIAL-P": {"120": 48}}' > "$T/panel/state.json"
    cat >"$T/panel_test.gd" <<GD
extends SceneTree

const PanelClient := preload("$SRC/panel_client.gd")
var failed := 0

func check(what: String, got, want) -> void:
	if got == want:
		print("  ok   $CASE -- ", what)
	else:
		failed += 1
		print("  FAIL $CASE -- ", what, ": got ", got, ", want ", want)

func _initialize() -> void:
	run()

func run() -> void:
	var c := PanelClient.new()
	c.bus = "--user"
	check("a call starts", c.request_status(false), true)
	check("one call at a time", c.request_status(false), false)
	var s: Dictionary = await c.status_received
	check("quick status: supported", s.get("supported"), true)
	check("quick status: saved line, highest rate first", PanelClient.format_saved(s), "120 Hz: calibrated · 60 Hz: factory")
	c.request_status(true)
	s = await c.status_received
	check("measured status without a display: the reason, not an error", PanelClient.format_rate(s).begins_with("no CRTC"), true)
	c.request_calibrate()
	var r: Dictionary = await c.calibrated
	check("a failed Calibrate carries paneld's reason", str(r.get("error", "")).begins_with("no CRTC"), true)
	check("free again after a reply", c.busy, false)
	check("rate line", PanelClient.format_rate({"measuredHz": 118.35, "nominalHz": 120}), "118.35 Hz · nominal 120 (-1.65)")
	check("rate line above nominal", PanelClient.format_rate({"measuredHz": 120.1, "nominalHz": 120}), "120.10 Hz · nominal 120 (+0.10)")
	check("rate line, no knob", PanelClient.format_rate({"measuredHz": 59.94, "nominalHz": null}), "59.94 Hz")
	check("no saved line without knobs", PanelClient.format_saved({"supported": false}), "")
	check("result line", PanelClient.format_result({"rate": 120, "startHz": 118.35, "endHz": 120.08}), "120 Hz calibrated: 118.35 → 120.08 Hz")
	check("busctl failure text", PanelClient.parse_reply(1, "Call failed: a measurement or calibration is running\n"), {"error": "a measurement or calibration is running"})
	check("garbage reply", PanelClient.parse_reply(0, "nope").has("error"), true)
	quit(1 if failed else 0)
GD
    out="$(RETROFORGE_PANEL_SYSFS_GLOB="$T/panel/sys/*" RETROFORGE_PANEL_SERIAL="$T/panel/serial" \
      RETROFORGE_PANEL_STATE="$T/panel/state.json" RETROFORGE_PANEL_DRM_GLOB="$T/panel/dri/card*" \
      RETROFORGE_PANEL_LIB="$ROOT/rootfs/overlay/usr/lib/retroforge" RETROFORGE_PANELD_BUS=session PYTHONDONTWRITEBYTECODE=1 XDG_CONFIG_HOME="$T/config" GODOT="$GODOT" \
      timeout 60 dbus-run-session -- bash -c '"$1" & for _ in $(seq 100); do busctl --user list 2>/dev/null | grep -q "^org.retroforge.Panel " && break; sleep 0.1; done; exec "$GODOT" --headless --script "$2"' _ "$PANELD" "$T/panel_test.gd" 2>&1)"; rc=$?
    printf '%s\n' "$out" | grep -E '^  (ok|FAIL) '
    n_ok="$(printf '%s\n' "$out" | grep -c '^  ok ')"; n_bad="$(printf '%s\n' "$out" | grep -c '^  FAIL ')"
    PASS=$((PASS + n_ok)); FAIL=$((FAIL + n_bad))
    if [ "$rc" -ne 0 ] && [ "$n_bad" -eq 0 ]; then
      bad "Godot failed (rc $rc): $(printf '%s\n' "$out" | grep -E 'ERROR|error' | head -3)"
    fi
    if printf '%s\n' "$out" | grep -q 'SCRIPT ERROR'; then
      bad "a script did not compile: $(printf '%s\n' "$out" | grep 'SCRIPT ERROR' | head -3)"
    fi
  fi

  # =================================================================================================
  # store_runner.gd against a fake /usr/lib/retroforge/store: N% lines, JSON events, a line written to
  # its stdin, the exit code and the last stderr line.
  CASE="store runner"
  cat >"$T/fake-store" <<'SH'
#!/bin/bash
echo "store: noise" >&2
echo "10%"; echo '{"event": "page", "url": "http://x/y"}'
read -r answer
printf '{"event": "said", "line": "%s"}\n' "$answer"
echo "55%"
[ "$2" = fail ] && { echo "store: GOG did not take the code" >&2; exit 4; }
exit 0
SH
  chmod +x "$T/fake-store"
  cat >"$T/store_runner_test.gd" <<GD
extends SceneTree

const StoreRunner := preload("$SRC/store_runner.gd")
var failed := 0

func check(what: String, got, want) -> void:
	if got == want:
		print("  ok   $CASE -- ", what)
	else:
		failed += 1
		print("  FAIL $CASE -- ", what, ": got ", got, ", want ", want)

func _initialize() -> void:
	run()

func job(verb: String) -> Dictionary:
	var r := StoreRunner.new()
	r.tool = "$T/fake-store"
	var seen := {"percent": [], "events": []}
	r.progressed.connect(func(p: int) -> void: seen["percent"].append(p))
	r.event.connect(func(e: Dictionary) -> void:
		seen["events"].append(e)
		if e.get("event") == "page":
			r.say("accept"))
	check(verb + ": starts", r.start(["gog", verb]), true)
	check(verb + ": a second start while running is refused", r.start(["gog", verb]), false)
	var res: Array = await r.finished
	return {"code": res[0], "error": res[1], "percent": seen["percent"], "events": seen["events"], "running": r.running}

func run() -> void:
	check("line: percent", StoreRunner.parse_line("42%"), {"percent": 42})
	check("line: event", StoreRunner.parse_line('{"event": "code", "sender": "1.2.3.4"}'), {"event": {"event": "code", "sender": "1.2.3.4"}})
	check("line: anything else is ignored", [StoreRunner.parse_line("101%"), StoreRunner.parse_line("noise"), StoreRunner.parse_line("[1]")], [{}, {}, {}])
	check("failure: not signed in", StoreRunner.failure_text("GOG", 3, "x"), "Sign in to GOG first: Settings > Stores.")
	check("failure: offline", "could not be reached" in StoreRunner.failure_text("Epic Games", 4, "x"), true)
	check("failure: the tool's reason", StoreRunner.failure_text("GOG", 1, "it is not installed"), "it is not installed")

	var a := await job("sign-in")
	check("progress lines", a.percent, [10, 55])
	check("events, and the line said to stdin comes back", a.events, [{"event": "page", "url": "http://x/y"}, {"event": "said", "line": "accept"}])
	check("exit 0: no error, stderr noise is not one", [a.code, a.error, a.running], [0, "", false])
	var b := await job("fail")
	check("a failure: its exit code and its last stderr line, unprefixed", [b.code, b.error], [4, "GOG did not take the code"])
	var r := StoreRunner.new()
	r.tool = "$T/no-such-tool"
	r.start(["gog", "status"])
	var f: Array = await r.finished
	check("a tool that cannot start: exit -1", f[0], -1)
	quit(1 if failed else 0)
GD
  out="$(XDG_CONFIG_HOME="$T/config" timeout 60 "$GODOT" --headless --script "$T/store_runner_test.gd" 2>&1)"; rc=$?
  printf '%s\n' "$out" | grep -E '^  (ok|FAIL) '
  n_ok="$(printf '%s\n' "$out" | grep -c '^  ok ')"; n_bad="$(printf '%s\n' "$out" | grep -c '^  FAIL ')"
  PASS=$((PASS + n_ok)); FAIL=$((FAIL + n_bad))
  if [ "$rc" -ne 0 ] && [ "$n_bad" -eq 0 ]; then
    bad "Godot failed (rc $rc): $(printf '%s\n' "$out" | grep -E 'ERROR|error' | head -3)"
  fi
  if printf '%s\n' "$out" | grep -q 'SCRIPT ERROR'; then
    bad "a script did not compile: $(printf '%s\n' "$out" | grep 'SCRIPT ERROR' | head -3)"
  fi

  # =================================================================================================
  # Settings > General > Updates (retroforge_os.gd) in OGUI's own settings scene, against a fake
  # retroforge-update: OGUI's updater goes, the one button walks Check -> Install -> Restart now, the
  # channel switch checks at once, and a session restarted with an update waiting offers Restart now.
  # Needs OGUI's classes, so a copy of the pinned OGUI source tree whose addons/core/bin also holds
  # upstream's x86_64 core library (from the same release's opengamepadui-x86_64.tar.gz, named
  # template_debug and template_release): RETROFORGE_OGUI_PROJECT=<dir>. Skipped without. The plugin
  # is copied into <dir>/plugins/retroforge on every run.
  # =================================================================================================
  # Every plugin script parses against OGUI's classes. Most use OGUI types, so the stock-Godot suites
  # above never load them: a parse error (a loop variable shadowing a local, 2026-11-09 in
  # library_roms.gd) would ship and take the whole ROM library down. Same OGUI project as below.
  CASE="compile"
  if [ -z "${RETROFORGE_OGUI_PROJECT:-}" ] || [ ! -f "${RETROFORGE_OGUI_PROJECT:-}/project.godot" ]; then
    printf '  skip %s -- no OGUI project (set RETROFORGE_OGUI_PROJECT)\n' "$CASE"
  else
    mkdir -p "$RETROFORGE_OGUI_PROJECT/plugins/retroforge"
    cp "$SRC"/* "$RETROFORGE_OGUI_PROJECT/plugins/retroforge/"
    for gd in "$SRC"/*.gd; do
      name="${gd##*/}"
      err="$("$GODOT" --headless --path "$RETROFORGE_OGUI_PROJECT" --check-only \
        --script "res://plugins/retroforge/$name" 2>&1 | grep -E 'Parse Error|Failed to load script' | head -2)"
      [ -z "$err" ] && ok "$name parses" || bad "$name: $err"
    done
  fi

  CASE="updates-ui"
  OGUI_PROJECT="${RETROFORGE_OGUI_PROJECT:-}"
  if [ -z "$OGUI_PROJECT" ] || [ ! -f "$OGUI_PROJECT/project.godot" ]; then
    printf '  skip %s -- no OGUI project (set RETROFORGE_OGUI_PROJECT)\n' "$CASE"
  else
    mkdir -p "$OGUI_PROJECT/plugins/retroforge" "$T/updates/d"
    cp "$SRC"/* "$OGUI_PROJECT/plugins/retroforge/"
    cat >"$T/updates/fake-update" <<'SH'
#!/bin/bash
# Fake retroforge-update. State in $FAKE_DIR: channel, staged (version), latest.<channel>, and
# pinned: a dev card, whose /etc/retroforge/ota.conf pins `dev` and refuses set-channel.
D=$FAKE_DIR; echo "$*" >> $D/calls
ch=$(cat $D/channel 2>/dev/null || echo stable); src=/home/player/.config/retroforge/ota.conf
[ -e $D/pinned ] && { ch=dev; src=/etc/retroforge/ota.conf; }
case "$1" in
  version) echo 0.0.3 ;;
  channels) printf 'stable\nbeta\n'; if [ -e $D/pinned ]; then printf 'dev\npinned\t%s\n' "$src"; fi ;;
  channel) printf '%s\t%s\n' "$ch" "$src" ;;
  set-channel) [ -e $D/pinned ] && exit 1; [ -e $D/slow-set ] && sleep 0.5; echo "$2" > $D/channel ;;
  staged) [ -s $D/staged ] && { cat $D/staged; exit 0; }; exit 7 ;;
  check) [ -s $D/staged ] && { cat $D/staged; exit 0; }
         v=$(cat $D/latest.$ch 2>/dev/null); [ -n "$v" ] && [ "$v" != 0.0.3 ] && { echo "$v"; exit 0; }; exit 7 ;;
  "") v=$(cat $D/latest.$ch); for p in 10 50 100; do echo "$p%"; sleep 0.2; done; echo "$v" > $D/staged ;;
esac
SH
    printf '#!/bin/sh\ntouch "$FAKE_DIR/rebooted"\n' >"$T/updates/fake-reboot"
    cat >"$T/updates/fake-systemctl" <<'SH'
#!/bin/bash
# Fake systemctl for retroforge-pairingd: the unit runs while $FAKE_DIR/pairing exists.
echo "$*" >> "$FAKE_DIR/systemctl-calls"
case "$1" in
  is-active) [ -e "$FAKE_DIR/pairing" ] ;;
  --no-block) ;;
  start) touch "$FAKE_DIR/pairing" ;;
  stop) rm -f "$FAKE_DIR/pairing" ;;
  *) exit 1 ;;
esac
SH
    printf '#!/bin/sh\ncat "$FAKE_DIR/medium"\n' >"$T/updates/fake-boot-medium"
    cat >"$T/updates/fake-release-info" <<'SH'
#!/bin/bash
if [ -e "$FAKE_DIR/no-release" ]; then printf 'CHANNEL=stable\nSTATE=no-release\n'; else printf 'CHANNEL=stable\nSTATE=ok\nVERSION=0.0.6\n'; fi
SH
    chmod +x "$T/updates/fake-update" "$T/updates/fake-reboot" "$T/updates/fake-systemctl" \
      "$T/updates/fake-boot-medium" "$T/updates/fake-release-info"
    cat >"$OGUI_PROJECT/retroforge_updates_test.gd" <<'GD'
extends SceneTree

var failed := 0
var D := OS.get_environment("FAKE_DIR")

func check(what: String, got, want) -> void:
	if got == want:
		print("  ok   updates-ui -- ", what)
	else:
		failed += 1
		print("  FAIL updates-ui -- ", what, ": got ", got, ", want ", want)

func _initialize() -> void:
	run.call_deferred()

func wait(sec: float) -> void:
	await create_timer(sec).timeout

func put(name: String, text: String) -> void:
	var f := FileAccess.open(D.path_join(name), FileAccess.WRITE)
	f.store_string(text)
	f.close()

# OGUI's shared dialog, reduced to what the row uses; `answer` is the press.
class FakeDialog extends Node:
	signal choice_selected(accepted: bool)
	var message := ""
	var answer := false
	func open(_return_node, text := "", _confirm := "", _cancel := "") -> void:
		message = text
		(func(): choice_selected.emit(answer)).call_deferred()

func test_internal_install(os, box: Node, channel: Node) -> void:
	var row: Node = box.get_node_or_null("RetroForgeInternalInstall")
	check("booted from a card, the row sits under the Updates rows", row != null and row.get_index() > channel.get_index(), true)
	var pairing_at: int = box.get_node("RetroForgePairing").get_index()
	check("and above Remote access", row.get_index() < pairing_at, true)
	var calls := D.path_join("systemctl-calls")
	var dialog := FakeDialog.new()
	dialog.add_to_group("dialog")
	root.add_child(dialog)
	put("no-release", "")
	row.button_up.emit()
	await wait(0.4)
	check("nothing published: no dialog, and the row says why", [dialog.message, row.description.contains("nothing")], ["", true])
	DirAccess.remove_absolute(D.path_join("no-release"))
	row.button_up.emit()
	await wait(0.4)
	check("the dialog names the version", dialog.message.contains("0.0.6"), true)
	check("Cancel starts nothing", FileAccess.get_file_as_string(calls).contains("retroforge-installer"), false)
	dialog.answer = true
	row.button_up.emit()
	await wait(0.4)
	check("Install starts the unit without blocking on it",
		FileAccess.get_file_as_string(calls).contains("--no-block start retroforge-installer.service"), true)
	dialog.queue_free()
	var other = load("res://plugins/retroforge/retroforge_os.gd").new()
	other.boot_medium = D.path_join("../fake-boot-medium")
	var bare := VBoxContainer.new()
	root.add_child(bare)
	put("medium", "internal")
	other._add_internal_install(bare)
	await wait(0.3)
	check("booted from internal storage, there is no row", bare.get_child_count(), 0)
	bare.queue_free()

func run() -> void:
	var processor := ResourceProcessor.new()  # card_ui.tscn has one: it drives every Command
	processor.registry = load("res://core/systems/resource/resource_registry.tres") as ResourceRegistry
	root.add_child(processor)
	var menu: Node = load("res://core/ui/card_ui/settings/general_settings_menu.tscn").instantiate()
	root.add_child(menu)
	await process_frame
	var os = load("res://plugins/retroforge/retroforge_os.gd").new()
	os.tool = D.path_join("../fake-update")
	os.reboot_command.assign([D.path_join("../fake-reboot")])
	os.systemctl = D.path_join("../fake-systemctl")
	os.boot_medium = D.path_join("../fake-boot-medium")
	os.release_info = D.path_join("../fake-release-info")
	put("medium", "card")
	put("latest.stable", "0.0.3")
	put("latest.beta", "0.0.4-beta.1")
	os.ready(root)
	await wait(0.5)
	var box: Node = menu.get_node("MarginContainer/VBoxContainer/VBoxContainer")
	check("OGUI's updater controls are gone", [box.has_node("AutoUpdateToggle"), box.has_node("CheckUpdateButton"), box.has_node("UpdateButton"), menu.has_node("SoftwareUpdater"), menu.has_node("UpdateTimer")], [false, false, false, false, false])
	var button: Node = box.get_node_or_null("RetroForgeUpdateButton")
	var channel: Node = box.get_node_or_null("RetroForgeUpdateChannel")
	check("the button and dropdown sit right under the Updates label",
		[box.get_node("UpdatesLabel").get_index() + 2, box.get_node("UpdatesLabel").get_index() + 3], [button.get_index(), channel.get_index()])
	check("focus starts on the button", box.get_node("FocusGroup").current_focus, button)
	check("idle: Check for updates, version shown", [button.button_text, button.description], ["Check for updates", "RetroForge 0.0.3."])
	check("dropdown: Stable, Beta; Stable selected", [channel.option_button.item_count, channel.option_button.get_item_text(0), channel.option_button.get_item_text(1), channel.selected], [2, "Stable", "Beta", 0])
	await test_pairing(box, channel)
	await test_internal_install(os, box, channel)
	button.button_up.emit()
	await wait(0.5)
	check("stable is up to date: still Check, says so", [button.button_text, button.description], ["Check for updates", "No update found on the Stable channel."])
	put("slow-set", "")
	channel.option_button.select(1)
	channel.item_selected.emit(1)
	await wait(0.2)
	check("while the channel is being written, the button and the dropdown wait", [button.disabled, channel.disabled], [true, true])
	DirAccess.remove_absolute(D.path_join("slow-set"))
	await wait(1.2)
	check("switching to Beta writes it and checks at once", FileAccess.get_file_as_string(D.path_join("channel")).strip_edges(), "beta")
	check("beta offers 0.0.4-beta.1: Install", [button.button_text, button.disabled], ["Install", false])
	button.button_up.emit()
	await wait(0.3)
	check("installing: disabled, channel locked", [button.button_text, button.disabled, channel.disabled], ["Installing...", true, true])
	await wait(1.5)
	check("installed: Restart now", [button.button_text, button.disabled, channel.disabled], ["Restart now", false, false])
	button.button_up.emit()
	await wait(0.3)
	check("Restart now runs the reboot command", FileAccess.file_exists(D.path_join("rebooted")), true)
	# A new session with the update still waiting: Restart now from the start.
	var menu2: Node = load("res://core/ui/card_ui/settings/general_settings_menu.tscn").instantiate()
	menu.queue_free()
	await process_frame
	root.add_child(menu2)
	await process_frame
	var os2 = load("res://plugins/retroforge/retroforge_os.gd").new()
	os2.tool = os.tool
	os2.systemctl = os.systemctl
	os2.ready(root)
	await wait(0.5)
	var b2: Node = menu2.get_node("MarginContainer/VBoxContainer/VBoxContainer/RetroForgeUpdateButton")
	check("restarted session: staged update shows Restart now", [b2.button_text, b2.description], ["Restart now", "RetroForge 0.0.4-beta.1 is installed. Restart to use it."])
	check("restarted session: Beta still selected", menu2.get_node("MarginContainer/VBoxContainer/VBoxContainer/RetroForgeUpdateChannel").selected, 1)
	var menu3: Node = await test_background_check(menu2)
	await test_pinned(menu3)
	quit(1 if failed else 0)

# A background check (here 0.3 s after start instead of 3 min) finds an update: Install, and one
# notification naming it -- never an install.
func test_background_check(previous: Node) -> Node:
	DirAccess.remove_absolute(D.path_join("staged"))
	put("channel", "stable")
	put("latest.stable", "0.0.5")
	var menu3: Node = load("res://core/ui/card_ui/settings/general_settings_menu.tscn").instantiate()
	previous.queue_free()
	await process_frame
	root.add_child(menu3)
	await process_frame
	# A method, disconnected before quit: lambdas left on the NotificationManager resource abort
	# Godot's teardown ("double free").
	var nm = load("res://core/global/notification_manager.tres")
	nm.notification_queued.connect(note)
	nm.notification_sent.connect(note)
	var os3 = load("res://plugins/retroforge/retroforge_os.gd").new()
	os3.tool = D.path_join("../fake-update")
	os3.systemctl = D.path_join("../fake-systemctl")
	os3.first_check_delay = 0.3
	os3.in_game = func() -> bool: return false  # LaunchManager needs InputPlumber, absent here
	os3.ready(root)
	await wait(1.2)
	var b3: Node = menu3.get_node("MarginContainer/VBoxContainer/VBoxContainer/RetroForgeUpdateButton")
	check("background check: found 0.0.5, offers Install", [b3.button_text, b3.description], ["Install", "RetroForge 0.0.5 is available (you have 0.0.3)."])
	nm.notification_queued.disconnect(note)
	nm.notification_sent.disconnect(note)
	check("background check: one notification naming it", notes.has("RetroForge 0.0.5 is available: Settings > General > Updates"), true)
	check("background check: nothing installed", FileAccess.file_exists(D.path_join("staged")), false)
	return menu3

# A dev card: /etc/retroforge/ota.conf pins `dev`. The dropdown shows it, greyed out with the file
# that pins it, and a check asks the dev channel only -- never stable or beta, never a set-channel.
func test_pinned(previous: Node) -> void:
	put("pinned", "")
	put("latest.dev", "")
	var sets_before := FileAccess.get_file_as_string(D.path_join("calls")).count("set-channel")
	var menu4: Node = load("res://core/ui/card_ui/settings/general_settings_menu.tscn").instantiate()
	previous.queue_free()
	await process_frame
	root.add_child(menu4)
	await process_frame
	var os4 = load("res://plugins/retroforge/retroforge_os.gd").new()
	os4.tool = D.path_join("../fake-update")
	os4.systemctl = D.path_join("../fake-systemctl")
	os4.ready(root)
	await wait(0.5)
	var box: Node = menu4.get_node("MarginContainer/VBoxContainer/VBoxContainer")
	var b4: Node = box.get_node("RetroForgeUpdateButton")
	var c4: Node = box.get_node("RetroForgeUpdateChannel")
	check("pinned: dropdown lists dev after Stable and Beta, dev selected",
		[c4.option_button.item_count, c4.option_button.get_item_text(2), c4.selected], [3, "dev", 2])
	check("pinned: dropdown greyed out, names the file that pins it",
		[c4.disabled, c4.description], [true, "Set by /etc/retroforge/ota.conf on this device."])
	b4.button_up.emit()
	await wait(0.5)
	check("pinned: nothing on dev -- no offer, the dropdown stays greyed out",
		[b4.button_text, b4.description, c4.disabled], ["Check for updates", "No update found on the dev channel.", true])
	put("latest.dev", "20261018.1200")
	b4.button_up.emit()
	await wait(0.5)
	check("pinned: a bundle seeded on dev is offered", [b4.button_text, b4.description],
		["Install", "RetroForge 20261018.1200 is available (you have 0.0.3)."])
	check("pinned: no set-channel was ever asked",
		FileAccess.get_file_as_string(D.path_join("calls")).count("set-channel"), sets_before)

var notes: Array[String] = []
func note(n) -> void:
	notes.append(n.text)

# A player's press on an OGUI Toggle, as its _gui_input does on ui_accept.
func press(toggle: Node) -> void:
	toggle.button_pressed = not toggle.button_pressed
	toggle.toggled.emit(toggle.button_pressed)

# Remote access: the switch starts and stops retroforge-pairingd and shows its real state.
func test_pairing(box: Node, channel: Node) -> void:
	var pairing: Node = box.get_node_or_null("RetroForgePairing")
	check("pairing: a Remote access switch under the update channel and, on a card, Internal storage", pairing.get_index(), channel.get_index() + 6)
	check("pairing: off at start, says how to turn it on", [pairing.button_pressed, "Turn on" in pairing.description], [false, true])
	press(pairing)
	await wait(0.5)
	check("pairing: on starts the unit", FileAccess.file_exists(D.path_join("pairing")), true)
	check("pairing: on says where to send the key", [pairing.button_pressed, ":32000/register" in pairing.description], [true, true])
	DirAccess.remove_absolute(D.path_join("pairing"))  # stopped elsewhere (a crash, ssh)
	load("res://assets/state/states/settings_general.tres").state_entered.emit(null)
	await wait(0.2)
	check("pairing: reopening Settings > General shows a stop made elsewhere, without acting on it",
		[pairing.button_pressed, FileAccess.get_file_as_string(D.path_join("systemctl-calls")).count("stop")], [false, 0])
	press(pairing)
	await wait(0.5)
	press(pairing)
	await wait(0.5)
	check("pairing: off stops the unit", [FileAccess.file_exists(D.path_join("pairing")), pairing.button_pressed], [false, false])
	check("pairing: only start, stop and is-active are asked",
		Array(FileAccess.get_file_as_string(D.path_join("systemctl-calls")).split("\n", false)).filter(func(l): return not (l.begins_with("is-active") or l == "start retroforge-pairingd.service" or l == "stop retroforge-pairingd.service")), [])
GD
    out="$(cd "$OGUI_PROJECT" && FAKE_DIR="$T/updates/d" timeout 120 "$GODOT" --headless --path . --script res://retroforge_updates_test.gd 2>&1)"; rc=$?
    rm -f "$OGUI_PROJECT/retroforge_updates_test.gd"
    printf '%s\n' "$out" | grep -E '^  (ok|FAIL) '
    n_ok="$(printf '%s\n' "$out" | grep -c '^  ok ')"; n_bad="$(printf '%s\n' "$out" | grep -c '^  FAIL ')"
    PASS=$((PASS + n_ok)); FAIL=$((FAIL + n_bad))
    if [ "$rc" -ne 0 ] && [ "$n_bad" -eq 0 ]; then
      bad "Godot failed (rc $rc): $(printf '%s\n' "$out" | grep -E 'ERROR' | head -3)"
    fi
    if printf '%s\n' "$out" | grep -q 'SCRIPT ERROR'; then
      bad "a script did not compile: $(printf '%s\n' "$out" | grep 'SCRIPT ERROR' | head -3)"
    fi

    # ===============================================================================================
    # Settings > Display > Reduced UI resolution (display_settings.gd), against a fake xprop: on, the
    # shell's own display (gamescope's Xwayland 0) is set to the design size at the output's aspect
    # and Godot draws it 1:1; the viewport stretch is left for a full-size shell behind a game. The
    # stretch drew the same pixels and then copied them, scaled, into an output-sized window every
    # frame (1.9 ms more GPU per frame on the Air X's Adreno 610). The Vulkan renderer switch below it.
    CASE="display"
    mkdir -p "$T/display/bin" "$T/display/d" "$T/display/home"
    printf '#!/bin/sh\nfor a; do last=$a; done\necho "$last" >> "$FAKE_DIR/xprop-calls"\n' >"$T/display/bin/xprop"
    chmod +x "$T/display/bin/xprop"
    cat >"$OGUI_PROJECT/retroforge_display_test.gd" <<'GD'
extends SceneTree

var failed := 0
var D := OS.get_environment("FAKE_DIR")

func check(what: String, got, want) -> void:
	if got == want:
		print("  ok   display -- ", what)
	else:
		failed += 1
		print("  FAIL display -- ", what, ": got ", got, ", want ", want)

func _initialize() -> void:
	run.call_deferred()

func calls() -> Array:
	return Array(FileAccess.get_file_as_string(D.path_join("xprop-calls")).split("\n", false))

func run() -> void:
	var DisplaySettings = load("res://plugins/retroforge/display_settings.gd")
	DisplaySettings._output = Vector2i(1920, 1080)  # a headless Godot has no screen
	root.content_scale_size = Vector2i(1280, 800)
	var settings := load("res://core/global/settings_manager.tres") as SettingsManager
	settings.set_value("retroforge", "reduced_ui_resolution", true)
	var d = DisplaySettings.new()
	d.apply_all(self)
	check("reduced: the shell's display is the design size at the output's aspect", calls(), ["1,1920,1080,0", "0,1422,800,0"])
	check("reduced: Godot draws it 1:1", root.content_scale_mode, Window.CONTENT_SCALE_MODE_CANVAS_ITEMS)
	d.set_backgrounded(true)
	check("reduced, behind a game: no display change, still 1:1", [calls().size(), root.content_scale_mode], [2, Window.CONTENT_SCALE_MODE_CANVAS_ITEMS])
	d.set_backgrounded(false)
	d._on_reduced_ui_toggled(false)
	check("off: the shell's display goes back to the output size", calls().back(), "0,1920,1080,0")
	check("off: Game resolution's Native is still the output size", d.size_for("native"), Vector2i(1920, 1080))
	d.set_backgrounded(true)
	check("off, behind a game: the design size through Godot's stretch, no display change", [calls().size(), root.content_scale_mode], [3, Window.CONTENT_SCALE_MODE_VIEWPORT])
	d.set_backgrounded(false)
	check("off, brought up over the game: the output size again", root.content_scale_mode, Window.CONTENT_SCALE_MODE_CANVAS_ITEMS)
	DisplaySettings._output = Vector2i(1280, 960)
	check("a panel no bigger than the design size (Air Y, 1280x960) keeps its size", d.reduced_size(), Vector2i(1280, 960))
	await test_renderer(DisplaySettings)
	quit(failed)

# Vulkan renderer: offered only where the board starts the shell on OpenGL; the choice goes to
# ~/.config/retroforge/display.conf as UI_RENDERER=, which retroforge-session reads.
func test_renderer(DisplaySettings) -> void:
	var conf := OS.get_environment("HOME").path_join(".config/retroforge/display.conf")
	var menu: Node = load("res://core/ui/common/settings/display_settings_menu.tscn").instantiate()
	root.add_child(menu)
	await process_frame
	OS.set_environment("RETROFORGE_UI_RENDERER", "")
	var plain = DisplaySettings.new()
	plain.tree = self
	plain.attach()
	check("renderer: no Vulkan switch on a board with no default", menu.find_child("RetroForgeVulkanRenderer", true, false), null)
	plain.detach()
	await process_frame
	OS.set_environment("RETROFORGE_UI_RENDERER", "opengl")
	DirAccess.make_dir_recursive_absolute(conf.get_base_dir())
	FileAccess.open(conf, FileAccess.WRITE).store_string("OTHER=1\n")
	var d = DisplaySettings.new()
	d.tree = self
	d.attach()
	var toggle: Node = menu.find_child("RetroForgeVulkanRenderer", true, false)
	check("renderer: the switch is offered, off (OpenGL, the board's default)", [toggle != null, toggle.button_pressed if toggle else null, d.chosen_renderer()], [true, false, "opengl"])
	check("renderer: right under Reduced UI resolution", toggle.get_index(), menu.find_child("RetroForgeReducedUI", true, false).get_index() + 1)
	toggle.button_pressed = true
	toggle.toggled.emit(true)  # as a press does (OGUI's Toggle)
	check("renderer: on writes UI_RENDERER=vulkan, keeping the file's other lines", FileAccess.get_file_as_string(conf), "OTHER=1\nUI_RENDERER=vulkan\n")
	toggle.button_pressed = false
	toggle.toggled.emit(false)  # as a press does (OGUI's Toggle)
	check("renderer: off writes UI_RENDERER=opengl, once", FileAccess.get_file_as_string(conf), "OTHER=1\nUI_RENDERER=opengl\n")
	FileAccess.open(conf, FileAccess.WRITE).store_string("UI_RENDERER=vulkan\n")
	check("renderer: a stored vulkan shows the switch on", DisplaySettings.new().chosen_renderer(), "vulkan")
GD
    out="$(cd "$OGUI_PROJECT" && FAKE_DIR="$T/display/d" HOME="$T/display/home" PATH="$T/display/bin:$PATH" timeout 120 "$GODOT" --headless --path . --script res://retroforge_display_test.gd 2>&1)"; rc=$?
    rm -f "$OGUI_PROJECT/retroforge_display_test.gd"
    printf '%s\n' "$out" | grep -E '^  (ok|FAIL) '
    n_ok="$(printf '%s\n' "$out" | grep -c '^  ok ')"; n_bad="$(printf '%s\n' "$out" | grep -c '^  FAIL ')"
    PASS=$((PASS + n_ok)); FAIL=$((FAIL + n_bad))
    if [ "$rc" -ne 0 ] && [ "$n_bad" -eq 0 ]; then
      bad "Godot failed (rc $rc): $(printf '%s\n' "$out" | grep -E 'ERROR' | head -3)"
    fi
    if printf '%s\n' "$out" | grep -q 'SCRIPT ERROR'; then
      bad "a script did not compile: $(printf '%s\n' "$out" | grep 'SCRIPT ERROR' | head -3)"
    fi
  fi
fi

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
