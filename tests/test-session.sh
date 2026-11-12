#!/usr/bin/env bash
# Offline test for the gamescope session profile: which shell retroforge-session hosts, and with what.
#
#   tests/test-session.sh
#
# WHY THIS EXISTS. The shell is three files that never change together: session.conf names it and
# its gamescope flags, retroforge-session turns those into a gamescope command line, and the
# OpenGamepadUI prebuilt pin decides where the shell lands in the image. Each failure is a black or
# frozen panel on a device with no console:
#
#   - OGUI drives gamescope through the Steam-mode X atoms (GAMESCOPECTRL_BASELAYER_APPID,
#     STEAM_OVERLAY, ...). Without --steam gamescope ignores them: the shell paints, but it can never
#     put itself over a game or take focus back for the quick menu.
#   - the pin unpacks a tarball whose root carries a Makefile beside usr/. The wrong strip count
#     either drops the shell at /share/... (nothing finds it) or litters the image root.
#   - Godot's X11 backend dlopen()s libXinerama and refuses to start without it; nothing else in the
#     base pulls it in, so the pin has to.
#
# Runs on the host with no root, no device and no build.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONF="$ROOT/rootfs/overlay/etc/retroforge/session.conf"
SESSION="$ROOT/rootfs/overlay/usr/bin/retroforge-session"
PKG="$ROOT/packages/opengamepadui"
PIN="$PKG/source.pin"
PKGBUILD="$PKG/PKGBUILD"
BASE="$ROOT/rootfs/customize-base.sh"
TRIM="$ROOT/rootfs/conf/trim.list"

PASS=0; FAIL=0; CASE=""
ok()  { PASS=$((PASS+1)); printf '  ok   %s -- %s\n' "$CASE" "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s -- %s\n' "$CASE" "$1"; }

for f in "$CONF" "$SESSION" "$PIN" "$PKGBUILD" "$BASE" "$TRIM"; do
  [ -f "$f" ] || { echo "missing input: $f" >&2; exit 1; }
done

# session.conf is sh, sourced by retroforge-session. Source it the same way, in a subshell, and read
# back what the session would see — not a grep for a line that might be commented out.
conf() { (set +u; . "$CONF"; eval "printf '%s' \"\${$1-}\""); }
pin_field() { sed -n "s/^$1:[[:space:]]*//p" "$PIN" | head -1; }

# =================================================================================================
CASE="the shell"
cmd="$(conf RETROFORGE_SESSION_CMD)"
[ "${cmd%% *}" = "opengamepadui" ] \
  && ok "RETROFORGE_SESSION_CMD is upstream's launcher, opengamepadui" \
  || bad "RETROFORGE_SESSION_CMD is '$cmd', not opengamepadui"
# OGUI's update pack is the x86_64 build: applying one at start leaves a black panel on this device,
# and any update pack would override the OS image's shell version.
case " $cmd " in
  *" --skip-update-pack "*) ok "the shell never applies a downloaded update pack (--skip-update-pack)" ;;
  *) bad "RETROFORGE_SESSION_CMD '$cmd' lacks --skip-update-pack — a downloaded x86_64 update.zip would replace the shell" ;;
esac
sh -n "$CONF" 2>/dev/null && ok "session.conf parses as sh" || bad "session.conf is not valid sh"
# pam_systemd gives every login session an ambient CAP_WAKE_ALARM; inherited by the shell and its
# games, it made the game's /proc/<pid>/fdinfo unreadable to mangoapp, which aborted every few seconds
# (blinking, frozen Performance Overlay, HW 2026-10-04).
grep -Eq '^setpriv --inh-caps=-all --ambient-caps=-all \$RETROFORGE_SESSION_CMD ' "$SESSION" \
  && ok "the shell starts with no inherited/ambient capabilities (setpriv)" \
  || bad "the shell is not started under setpriv --ambient-caps=-all: games inherit CAP_WAKE_ALARM again"

# =================================================================================================
CASE="gamescope flags for OGUI"
args=" $(conf RETROFORGE_GAMESCOPE_SHELL_ARGS) "
case "$args" in *" --steam "*) ok "--steam is passed (OGUI's control atoms need it)";;
                *) bad "no --steam: gamescope would ignore OGUI's focus and overlay atoms";; esac
case "$args" in *" --xwayland-count 2 "*) ok "two nested Xwaylands (shell + game)";;
                *) bad "not --xwayland-count 2: '$args'";; esac
grep -q '\$RETROFORGE_GAMESCOPE_SHELL_ARGS -R ' "$SESSION" \
  && ok "retroforge-session puts the shell args on the gamescope command line, before the handshake" \
  || bad "retroforge-session does not apply RETROFORGE_GAMESCOPE_SHELL_ARGS"
if sed 's,#.*,,' "$SESSION" | grep -q -- '--steam'; then
  bad "retroforge-session hard-codes --steam — it belongs to the shell profile in session.conf"
else
  ok "retroforge-session itself stays shell-agnostic (no hard-coded --steam)"
fi

# =================================================================================================
CASE="dual-screen boards"
# The second panel (device-env RETROFORGE_SECONDARY_CONNECTOR) becomes gamescope's second output
# (patches/0040). Without the guard a single-panel board would pass a bare --secondary-output and
# gamescope would take the next argument as the connector name.
if grep -Fq 'if [ -n "${RETROFORGE_SECONDARY_CONNECTOR:-}" ]; then' "$SESSION" &&
   grep -Fq 'GS_ARGS="$GS_ARGS --secondary-output $RETROFORGE_SECONDARY_CONNECTOR"' "$SESSION"; then
  ok "--secondary-output is passed only when the board declares a second panel"
else
  bad "retroforge-session does not pass --secondary-output under a RETROFORGE_SECONDARY_CONNECTOR guard"
fi
if grep -Fq 'if [ -n "${RETROFORGE_SECONDARY_TOUCHSCREEN:-}" ]; then' "$SESSION" &&
   grep -Fq 'GS_ARGS="$GS_ARGS --secondary-touch-device $RETROFORGE_SECONDARY_TOUCHSCREEN"' "$SESSION"; then
  ok "--secondary-touch-device is passed only when the board names its second digitizer"
else
  bad "retroforge-session does not pass --secondary-touch-device under a RETROFORGE_SECONDARY_TOUCHSCREEN guard"
fi
grep -q '0043-wlserver-route-the-secondary-touchscreen-to-the-secondary-output.patch' "$ROOT/packages/gamescope/source.pin" \
  && ok "the gamescope build carries --secondary-touch-device (patch 0043 in source.pin)" \
  || bad "--secondary-touch-device is passed but patch 0043 is not in packages/gamescope/source.pin"
grep -Fq 'secondary-output' "$ROOT/packages/gamescope/patches/0040-drm-drive-a-secondary-output.patch" &&
  grep -q '0040-drm-drive-a-secondary-output.patch' "$ROOT/packages/gamescope/source.pin" \
  && ok "the gamescope build carries the flag (patch 0040 in source.pin)" \
  || bad "--secondary-output is passed but patch 0040 is not in packages/gamescope/source.pin"
CASE="gamescope focus for Steam on its own XWayland"
# 0049: Steam runs on :1 under OGUI and reads gamescope's focus atoms from its own root; with them
# on :0 only, a native game got Steam's Desktop controller config (HW, MANGMI Air X, 2026-10-23).
P49="$ROOT/packages/gamescope/patches/0049-steamcompmgr-steam-on-another-xwayland-sees-the-focus.patch"
if [ -f "$P49" ] && grep -q '0049-steamcompmgr-steam-on-another-xwayland-sees-the-focus.patch' "$ROOT/packages/gamescope/source.pin"; then
  grep -qE '^\+\s+for \( size_t i = 1; \( server = wlserver_get_xwayland_server\( i \) \); i\+\+ \)' "$P49" \
    && grep -qE '^\+\s+publish_focus_on_other_xwaylands\( pFocus, vecPossibleFocusWindows \);' "$P49" \
    && ok "0049: the focus atoms are published on every XWayland after the first" \
    || bad "0049: the focus atoms reach the first XWayland only"
  grep -qE '^\+\s+if \( window_is_steam\( w \) \|\| w->bIsSteamPid \|\| w->bIsSteamWebHelperPid \)' "$P49" \
    && ok "0049: Steam's own windows are reported to it as 769 (OGUI tags them with its own id)" \
    || bad "0049: Steam's windows keep OGUI's id, and Steam takes its own UI for a game"
  # OGUI's core takes the XWayland with GAMESCOPE_KEYBOARD_FOCUS_DISPLAY for the primary one.
  ! grep -qE '^\+.*gamescope(Keyboard|Mouse)?FocusDisplay' "$P49" \
    && ok "0049: the focus-display atoms stay on the first XWayland (OGUI finds its primary by them)" \
    || bad "0049: a focus-display atom is published elsewhere: OGUI would see two primaries"
else
  bad "gamescope patch 0049 is missing or not in packages/gamescope/source.pin"
fi

CASE="no-r-by-default"
# gamescope keeps -r as g_nNestedRefresh, which overrides the scanning mode's rate in its limiter
# and vblank pacing. The session used to pass the panel's first declared rate: on a 60,120 panel
# scanning at 120, "60 fps (120Hz)" then ran 120 fps (HW, Odin 3, 2026-10-23). The GS_ARGS block
# is extracted from the shipped script and run.
GSARGS="$(mktemp)"
sed -n '/^GS_ARGS="--backend drm/,/^fi$/p' "$SESSION" > "$GSARGS"
gsargs() { env -i "$@" /bin/sh -c '. "$1"; printf "%s" "$GS_ARGS"' sh "$GSARGS"; }
out="$(gsargs RETROFORGE_GAMESCOPE_W=1920 RETROFORGE_GAMESCOPE_H=1080 RETROFORGE_PANEL_REFRESH_RATES=60,120)"
case " $out " in
  *" -r "*) bad "the default command line passes -r: '$out'" ;;
  *"--backend drm -W 1920 -H 1080"*) ok "the default command line carries no -r" ;;
  *) bad "could not read GS_ARGS from the shipped script: '${out:-<nothing>}'" ;;
esac
out="$(gsargs RETROFORGE_GAMESCOPE_W=1920 RETROFORGE_GAMESCOPE_H=1080 RETROFORGE_GAMESCOPE_REFRESH=120)"
case " $out " in
  *" -r 120 "*) ok "RETROFORGE_GAMESCOPE_REFRESH still reaches gamescope as an operator override" ;;
  *) bad "the override was dropped: '${out:-<nothing>}'" ;;
esac
grep -qE '^[[:space:]]*(: "\$\{)?RETROFORGE_GAMESCOPE_REFRESH[:=]' "$SESSION" \
  && bad "the script assigns RETROFORGE_GAMESCOPE_REFRESH itself, so the override is a default again" \
  || ok "nothing in the script defaults RETROFORGE_GAMESCOPE_REFRESH"
rm -f "$GSARGS"

# =================================================================================================
CASE="environment for what gamescope hosts"
for kv in QT_QPA_PLATFORM=xcb SDL_VIDEO_MINIMIZE_ON_FOCUS_LOSS=0 vk_xwayland_wait_ready=false \
          SDL_AUDIO_DRIVER=pipewire,pulseaudio SDL_AUDIODRIVER=pipewire,pulseaudio; do
  k=${kv%%=*}; v=${kv#*=}
  got="$( (set +u; . "$CONF"; env) | sed -n "s/^$k=//p")"
  [ "$got" = "$v" ] && ok "$k=$v is exported" || bad "$k is '${got:-<not exported>}', want $v"
done

# =================================================================================================
CASE="the OpenGamepadUI package"
# A local PKGBUILD since 2026-10-02: upstream's aarch64 release with the pck rebuilt from the tagged
# source plus patches, because the released pck crash-loops on devicetree boards (#542) and cannot
# launch games under Godot 4.7 (#540). These checks pin the shape; the build itself is what proves
# the patches still apply (patch failure fails makepkg).
pb() { (set +u; . "$PKGBUILD"; eval "printf '%s\n' \"\${$1[@]}\""); }
[ "$(pin_field name)" = "opengamepadui" ] && [ "$(pin_field pkgbuild_local)" = "PKGBUILD" ] \
  && ok "source.pin: local PKGBUILD named opengamepadui" || bad "source.pin name/pkgbuild_local wrong"
[ "$(pb pkgname)" = "opengamepadui" ] && ok "PKGBUILD pkgname matches the pin" || bad "pkgname is '$(pb pkgname)'"
ver="$(pb pkgver)"
pb source | grep -q "/releases/download/v\${pkgver}/opengamepadui-aarch64.tar.gz\|/releases/download/v$ver/opengamepadui-aarch64.tar.gz" \
  && ok "sources the aarch64 release tarball of pkgver ($ver)" || bad "no aarch64 release tarball for $ver in source=()"
pb source | grep -q "/archive/refs/tags/v$ver.tar.gz" \
  && ok "sources the tagged project source of the same version" || bad "no v$ver source archive in source=()"
nsrc="$(pb source | grep -c .)"; nsum="$(pb sha256sums | grep -cE '^[0-9a-f]{64}$')"
[ "$nsrc" = "$nsum" ] && [ "$nsrc" -gt 0 ] && ok "one full sha256 per source ($nsrc)" \
  || bad "$nsrc sources but $nsum valid sha256sums"
grep -q 'sha256sum -c' "$PKGBUILD" && ok "prepare() verifies the sums itself (build-overlay runs --skipinteg)" \
  || bad "nothing verifies the downloads — makepkg runs with --skipinteg"
grep -q -- '--export-pack "Linux/X11 aarch64"' "$PKGBUILD" && ok "exports the aarch64 preset as a pack" \
  || bad "PKGBUILD does not export the aarch64 preset"
case " $(pb depends | tr '\n' ' ') " in *" libxinerama "*) ok "depends on libxinerama (Godot's X11 backend needs it)";;
                                          *) bad "libxinerama is not a dependency — Godot's X11 backend will not start";; esac
grep -qE '^PKGS=\(.* opengamepadui[ )]' "$BASE" && ok "opengamepadui is in PKGS (overlay packages install only when listed)" \
  || bad "opengamepadui missing from PKGS in customize-base.sh"
for p in $(pin_field patches); do
  [ -s "$PKG/patches/$p" ] && ok "patch present: $p" || bad "listed patch missing: $p"
done

# What each patch must keep doing. Content checks, because a patch rewritten in a later bump can
# still apply cleanly while no longer fixing the bug it was added for.
# 0001 (#542, no DMI on a devicetree board) and 0002 (#540, custom_maximum_size under Godot 4.7) are
# upstream since v0.47.0 and were dropped with that bump; an older pin needs them back.
if [ "$(printf '%s\n' 0.47.0 "$ver" | sort -V | head -1)" = 0.47.0 ]; then
  ok "pinned v$ver carries upstream's #542 and #540 fixes (were patches 0001/0002)"
else
  bad "pinned v$ver predates 0.47.0 — DT boards crash-loop (#542) and game launch breaks (#540) without 0001/0002"
fi

# 0018: joining Wi-Fi saved a mistyped password that the UI could neither show nor undo (HW, Air X,
# 2026-10-18). Each line below is one of the faults it fixes; the profile helper is run further down.
P18="$PKG/patches/0018-network-one-working-profile-connected-means-activated-forget.patch"
# 0019: Steam's Big Picture window lost the focus to a helper window (black screen over Steam, HW,
# Pocket FIT, 2026-10-19). Checked on the patch's new side: launch_manager.gd only.
P19="$PKG/patches/0019-launch-focus-a-focusable-window-of-the-app.patch"
if [ -f "$P19" ]; then
  files19="$(grep -E '^\+\+\+ b/' "$P19" | sed 's#^+++ b/##' | sort -u)"
  [ "$files19" = "core/global/launch_manager.gd" ] && ok "0019: changes launch_manager.gd only" || bad "0019 touches: $files19"
  grep -qE '^\+\s+if window in focusable:' "$P19" && grep -qE '^\+\s+var focusable := _xwayland_primary.get_focusable_windows\(\)' "$P19" \
    && ok "0019: a new window gamescope can focus is preferred over the first new one" || bad "0019: no focusable preference"
  grep -qE '^\+\s+for app in running:' "$P19" && grep -qE '^\+\s+app.switch_window.call_deferred\(window\)' "$P19" \
    && ok "0019: with nothing focused, a running app's newly focusable window gets the focus" || bad "0019: no late focus"
  # Not synchronously: the signal comes while GamescopeInstance is bound, and switch_window calls back
  # into it; godot-rust refuses that and the switch is lost (Steam behind the loading screen, HW).
  ! grep -qE '^\+\s+app.switch_window\(window\)' "$P19" \
    && ok "0019: that switch is deferred, out of gamescope's signal" || bad "0019: switch_window called inside focusable_windows_updated"
  grep -q "0019-launch-focus-a-focusable-window-of-the-app.patch" "$PKG/source.pin" \
    && ok "0019: listed in source.pin" || bad "0019: not in source.pin's patches"
else
  bad "0019: $P19 is missing"
fi
# 0017: Steam's reaper is found by its arguments; get_string_from_utf8() stops at the first NUL of
# /proc/<pid>/cmdline (Godot 4.7.1), so it never matched and Steam was stopped mid-launch (HW, Pocket
# FIT, 2026-10-19; was a separate 0020, folded into 0017).
P17="$PKG/patches/0017-running-app-steam-launch-alive-while-steam-reaper-runs.patch"
if [ -f "$P17" ]; then
  files17="$(grep -E '^\+\+\+ b/' "$P17" | sed 's#^+++ b/##' | sort -u)"
  [ "$files17" = "core/systems/launcher/running_app.gd" ] && ok "0017: changes running_app.gd only" || bad "0017 touches: $files17"
  grep -qE '^\+\s+data\[i\] = 10' "$P17" && grep -qE '^\+\s+var argv := data.get_string_from_utf8\(\).split\("\\n"\)' "$P17" \
    && ! grep -qE '^\+.*get_string_from_utf8\(\).split\(char\(0\)\)' "$P17" \
    && ok "0017: the reaper's arguments are split on NULs turned into newlines, not decoded up to the first NUL" \
    || bad "0017: the cmdline is still decoded up to its first NUL"
  grep -q "0016-thread-pool-start-on-first-use.patch 0017-running-app-steam-launch-alive-while-steam-reaper-runs.patch" "$PKG/source.pin" \
    && ok "0017: listed in source.pin, after 0016" || bad "0017: not in source.pin's patches"
else
  bad "0017: $P17 is missing"
fi
# 0021: a Steam desktop shortcut started Steam's desktop mode over the game (HW, Pocket FIT, 2026-10-21).
P21="$PKG/patches/0021-library-desktop-steam-shortcuts-start-steams-gamepad-ui.patch"
if [ -f "$P21" ]; then
  [ "$(grep -E '^\+\+\+ b/' "$P21" | sed 's#^+++ b/##' | sort -u)" = "core/systems/library/library_desktop.gd" ] \
    && ok "0021: changes library_desktop.gd only" || bad "0021 touches more than library_desktop.gd"
  grep -qE '^-\s+var args := PackedStringArray\(\["-silent"\]\)' "$P21" \
    && grep -qE '^\+\s+var args := PackedStringArray\(\["-gamepadui", "-steamos3", "-steampal", "-steamdeck", "-silent"\]\)' "$P21" \
    && ok "0021: a Steam shortcut gets the Steam plugin's flags, not -silent alone" || bad "0021: the quirk still adds -silent alone"
  grep -q "0019-launch-focus-a-focusable-window-of-the-app.patch 0021-library-desktop-steam-shortcuts-start-steams-gamepad-ui.patch" "$PKG/source.pin" \
    && ok "0021: listed in source.pin, after 0019" || bad "0021: not in source.pin's patches"
else
  bad "0021: $P21 is missing"
fi
# 0022: every orphan window warned about once a second (Steam kept running: HW, Pocket FIT, 2026-10-22).
P22="$PKG/patches/0022-launch-manager-orphan-windows-warned-once.patch"
if [ -f "$P22" ]; then
  [ "$(grep -E '^\+\+\+ b/' "$P22" | sed 's#^+++ b/##' | sort -u)" = "core/global/launch_manager.gd" ] \
    && ok "0022: changes launch_manager.gd only" || bad "0022 touches more than launch_manager.gd"
  grep -qE '^-\s+if not orphan_windows.is_empty\(\):' "$P22" && grep -qE '^\+\s+if orphan_windows != _orphan_windows:' "$P22" \
    && grep -qE '^\+var _orphan_windows := PackedInt64Array\(\)' "$P22" \
    && ok "0022: orphan windows are warned about when their set changes, not on every check" || bad "0022: still warns on every check"
  grep -q "0021-library-desktop-steam-shortcuts-start-steams-gamepad-ui.patch 0022-launch-manager-orphan-windows-warned-once.patch" "$PKG/source.pin" \
    && ok "0022: listed in source.pin, after 0021" || bad "0022: not in source.pin's patches"
else
  bad "0022: $P22 is missing"
fi
# 0023: a recent app's home card stayed on a replaced library item: no art, Play did nothing
# (HW, Pocket FIT, 2026-10-22).
P23="$PKG/patches/0023-home-card-rebuilt-when-its-library-item-is-replaced.patch"
if [ -f "$P23" ]; then
  [ "$(grep -E '^\+\+\+ b/' "$P23" | sed 's#^+++ b/##' | sort -u)" = "core/ui/card_ui/home/cardui_home.gd" ] \
    && ok "0023: changes cardui_home.gd only" || bad "0023 touches more than cardui_home.gd"
  grep -qE '^-\s+if item.name in card_nodes and is_instance_valid\(card_nodes\[item.name\]\):' "$P23" \
    && grep -qE '^\+\s+if is_instance_valid\(old\) and \(old as GameCard\).library_item == item:' "$P23" \
    && grep -qE '^\+\s+var old = card_nodes.get\(item.name\)' "$P23" \
    && ok "0023: a card is reused only while it shows the very library item (untyped: a freed card may be listed)" \
    || bad "0023: home cards are still reused by name"
  grep -q "0022-launch-manager-orphan-windows-warned-once.patch 0023-home-card-rebuilt-when-its-library-item-is-replaced.patch" "$PKG/source.pin" \
    && ok "0023: listed in source.pin, after 0022" || bad "0023: not in source.pin's patches"
else
  bad "0023: $P23 is missing"
fi
# 0025: a game started from the Steam client's own UI got the client's app id, so Steam Input never
# reached it (SuperTux, HW, MANGMI Air X, 2026-10-23).
P25="$PKG/patches/0025-running-app-a-game-steam-starts-keeps-its-own-app-id.patch"
if [ -f "$P25" ]; then
  files25="$(grep -E '^\+\+\+ b/' "$P25" | sed 's#^+++ b/##' | sort -u | tr '\n' ' ')"
  [ "$files25" = "core/global/launch_manager.gd core/systems/launcher/running_app.gd " ] \
    && ok "0025: changes launch_manager.gd and running_app.gd only" || bad "0025 touches: $files25"
  grep -qE '^-\s+xwayland.set_app_id\(window, self.app_id\)' "$P25" && grep -qE '^\+\s+xwayland.set_app_id\(window, wanted\)' "$P25" \
    && grep -qE '^\+\s+var wanted := get_window_app_id\(window\)' "$P25" \
    && ok "0025: each window is stamped with the id it should carry, not the app's alone" || bad "0025: every window still gets the app's id"
  grep -qE '^\+\s+var steam_game_id := steam_game_id_from_env\(Reaper.get_pid_environment\(window_pid\)\)' "$P25" \
    && grep -qE '^\+\s+var id := env.get\("SteamGameId", ""\) as String' "$P25" \
    && ok "0025: a window whose process has SteamGameId keeps the game's id" || bad "0025: SteamGameId is not read"
  # Godot's to_int() logs an error for a 64-bit unsigned id (a non-Steam shortcut's), on every check.
  grep -qE '^\+\s+if id.length\(\) > 10 or not id.is_valid_int\(\):' "$P25" \
    && ok "0025: a shortcut's 64-bit SteamGameId never reaches to_int()" || bad "0025: a 64-bit SteamGameId reaches to_int()"
  grep -qE '^\+\s+app_ids.insert\(0, window_app_id\)' "$P25" && grep -qE '^\+\s+new_focused_apps.append_array\(app_ids\)' "$P25" \
    && ok "0025: a focused game's id goes ahead of the app's in the baselayer app ids" || bad "0025: the game's id is not in the baselayer app ids"
  # From ids cached in update(), without asking gamescope: LaunchManager asks on every focus change.
  grep -qE '^\+\s+if app.owns_app_id\(to\):' "$P25" && grep -qE '^\+\s+return id == self.app_id or id in window_app_ids.values\(\)' "$P25" \
    && ok "0025: LaunchManager maps a focused game id to its app, without asking gamescope" || bad "0025: a focused game id maps to no running app"
  grep -q "0024-input-focus-profile-instead-of-intercept-mode.patch 0025-running-app-a-game-steam-starts-keeps-its-own-app-id.patch" "$PKG/source.pin" \
    && ok "0025: listed in source.pin, after 0024" || bad "0025: not in source.pin's patches"
else
  bad "0025: $P25 is missing"
fi
# 0033: one null in launcher.json's recents emptied the home screen's row (HW, Pocket FIT, 2026-10-22).
P33="$PKG/patches/0033-launch-manager-recent-apps-names-only.patch"
if [ -f "$P33" ]; then
  [ "$(grep -E '^\+\+\+ b/' "$P33" | sed 's#^+++ b/##' | sort -u)" = "core/global/launch_manager.gd" ] \
    && ok "0033: changes launch_manager.gd only" || bad "0033 touches more than launch_manager.gd"
  grep -qE '^\+\s+if not app is String:' "$P33" && grep -qE '^\+\s+var recent: Array = .*filter\(func\(n\): return n is String\)' "$P33" \
    && ok "0033: recent apps are read and saved as names only" || bad "0033: a non-name recent entry still reaches the home screen"
  grep -q "0032-card-art-only-near-the-screen.patch 0033-launch-manager-recent-apps-names-only.patch" "$PKG/source.pin" \
    && ok "0033: listed in source.pin, after 0032" || bad "0033: not in source.pin's patches"
else
  bad "0033: $P33 is missing"
fi
# 0034: install scripts' Proton windows set a client launch running; Steam was stopped at its shader
# prompt before the game started (HW, MANGMI Air X, 2026-10-24).
P34="$PKG/patches/0034-running-app-a-steam-launch-counts-once-steam-starts-the-game.patch"
if [ -f "$P34" ]; then
  [ "$(grep -E '^\+\+\+ b/' "$P34" | sed 's#^+++ b/##' | sort -u)" = "core/systems/launcher/running_app.gd" ] \
    && ok "0034: changes running_app.gd only" || bad "0034 touches more than running_app.gd"
  grep -qE '^\+\s+steam_game_launched = _steam_launch_running\(true\)' "$P34" && grep -qE '^\+\s+if not steam_game_launched:' "$P34" \
    && ok "0034: a Steam launch stays started until Steam's reaper for the game has run" || bad "0034: windows before the game still set it running"
  grep -qE '^\+\s+if game_only and "Install=1" in argv' "$P34" \
    && ok "0034: Steam's install-script reaper (Install=1) is not the game's" || bad "0034: an install-script reaper counts as the game"
  grep -q "0033-launch-manager-recent-apps-names-only.patch 0034-running-app-a-steam-launch-counts-once-steam-starts-the-game.patch" "$PKG/source.pin" \
    && ok "0034: listed in source.pin, after 0033" || bad "0034: not in source.pin's patches"
else
  bad "0034: $P34 is missing"
fi
# 0035: the library tabs kept a card on a replaced LibraryItem (no art, no Play): Hades, HW 2026-10-24.
P35="$PKG/patches/0035-library-menu-a-card-is-rebuilt-when-its-library-item-is-replaced.patch"
if [ -f "$P35" ]; then
  [ "$(grep -E '^\+\+\+ b/' "$P35" | sed 's#^+++ b/##' | sort -u)" = "core/ui/card_ui/library/library_menu.gd" ] \
    && ok "0035: changes library_menu.gd only" || bad "0035 touches more than library_menu.gd"
  grep -qE '^\+\s+if is_instance_valid\(old\) and \(old as GameCard\).library_item == item:' "$P35" \
    && ok "0035: a library card is reused only while it shows the very item" || bad "0035: cards are still reused by name"
  grep -q "0034-running-app-a-steam-launch-counts-once-steam-starts-the-game.patch 0035-library-menu-a-card-is-rebuilt-when-its-library-item-is-replaced.patch" "$PKG/source.pin" \
    && ok "0035: listed in source.pin, after 0034" || bad "0035: not in source.pin's patches"
else
  bad "0035: $P35 is missing"
fi
# 0038: a touch release InputManager never saw left current_touches above zero, and the library no longer
# followed the D-pad (HW, MANGMI Air X, 2026-10-25).
P38="$PKG/patches/0038-input-menus-follow-the-d-pad-again-after-a-touch.patch"
if [ -f "$P38" ]; then
  [ "$(grep -E '^\+\+\+ b/' "$P38" | sed 's#^+++ b/##' | sort -u | tr '\n' ' ')" = "core/systems/input/input_manager.gd core/ui/card_ui/home/cardui_home.gd core/ui/card_ui/library/library_menu.gd " ] \
    && ok "0038: changes the input manager, home and the library only" || bad "0038 touches other files"
  grep -qE '^\+func pointer_recent\(window_msec := 500\) -> bool:' "$P38" \
    && ok "0038: InputManager.pointer_recent, from the last pointer event's time" || bad "0038: no pointer_recent"
  [ "$(grep -cE '^-\s+if \(input_manager as InputManager\)\.current_touches > 0:' "$P38")" = 2 ] \
    && [ "$(grep -cE '^\+\s+if \(input_manager as InputManager\)\.pointer_recent\(\):' "$P38")" = 2 ] \
    && ok "0038: home and the library no longer trust the touch count" || bad "0038: a menu still skips scrolling on current_touches"
  grep -q "0037-scripts-with-no-per-frame-work-stop-running-every-frame.patch 0038-input-menus-follow-the-d-pad-again-after-a-touch.patch" "$PKG/source.pin" \
    && ok "0038: listed in source.pin, after 0037" || bad "0038: not in source.pin's patches"
else
  bad "0038: $P38 is missing"
fi
# One file of the tree as 0018 leaves it, hunk by hunk (context and added lines; a new file whole).
newside() { python3 - "$P18" "$1" <<'PY'
import sys
out, on = [], False
for line in open(sys.argv[1], encoding="utf-8"):
    if line.startswith("diff --git "):
        on = line.rstrip().endswith("b/" + sys.argv[2])
    elif on and line[:1] in " +" and not line.startswith("+++"):
        out.append(line[1:])
sys.stdout.write("".join(out))
PY
}
MENU="$(newside core/ui/common/settings/network_settings_menu.gd)"
TREE="$(newside core/ui/components/wifi_network_tree.gd)"
printf '%s\n' "$MENU" | python3 -c '
import re, sys
s = sys.stdin.read()
body = lambda f: re.search(r"^func %s\(.*?(?=^func |\Z)" % f, s, re.S | re.M).group(0)
close, challenge = body("_close_dialog"), body("_on_wifi_challenge")
ok = "password_input.text = \"\"" in close and "secret = true" in close and challenge.split("\n")[1].strip() == "_close_dialog()"
sys.exit(0 if ok else 1)' \
  && ok "0018: every password dialog opens on an empty, hidden field (the last one's text was resubmitted)" \
  || bad "0018: the password dialog no longer starts from an empty field"
printf '%s\n' "$MENU" | grep -q 'pressed.disconnect(_pending_submit)' \
  && ok "0018: a dialog left unsubmitted drops its submit handler (the next Submit joined that network too)" \
  || bad "0018: stale submit handlers are not disconnected"
printf '%s\n' "$MENU" | grep -q '"Show password"' && printf '%s\n' "$MENU" | grep -q 'secret = not on' \
  && ok "0018: Show password reveals what was typed" || bad "0018: no Show password toggle in the dialog"
printf '%s\n' "$MENU" | grep -q '"Forget network"' && printf '%s\n' "$MENU" | grep -q 'wifi_tree.forget(' \
  && ok "0018: a saved network can be forgotten from its dialog" || bad "0018: no Forget network"
printf '%s\n' "$MENU" | grep -q 'back_watcher.set_process_input(false)' \
  && ok "0018: B closes the dialog instead of leaving the page" || bad "0018: B still leaves the page from the dialog"
printf '%s\n' "$TREE" | grep -q 'state == NetworkActiveConnection.NM_ACTIVE_CONNECTION_STATE_ACTIVATED' \
  && ok "0018: a join succeeds on its own activation's state, not the device's previous one" \
  || bad "0018: a join no longer waits for its activation to be ACTIVATED"
printf '%s\n' "$TREE" | python3 -c '
import re, sys
s = sys.stdin.read()
f = re.search(r"^static func status_text\(.*?(?=^\S)", s, re.S | re.M).group(0)
sys.exit(0 if f.count("\"Connected\"") == 1 and "== NetworkDevice.NM_DEVICE_STATE_ACTIVATED:\n\t\treturn \"Connected\"" in f else 1)' \
  && grep -q '^-			item.set_text(4, "Connected")' "$P18" \
  && ok "0018: a row says Connected only for an activated device (not for an access point still tried)" \
  || bad "0018: Connected is shown for something other than an activated device"
printf '%s\n' "$TREE" | grep -q 'NetworkProfiles.stale_after_join(saved_before, saved_now, failure.is_empty())' \
  && ok "0018: a join keeps one profile per network (the new one once it works, else the old ones)" \
  || bad "0018: joins pile up profiles again"
newside core/ui/card_ui/ootbe/network_select.gd | grep -q '^	wifi_pass_box.text = ""' \
  && ok "0018: the first-boot password popup opens empty too" || bad "0018: the first-boot popup keeps the last text"
newside core/systems/network/network_manager.gd | grep -q 'fresh.take_over_path(instance.resource_path)' \
  && ok "0018: a core instance that lost the Wi-Fi device is replaced (after a NetworkManager restart)" \
  || bad "0018: after a NetworkManager restart the Wi-Fi settings find no device again"

# -------------------------------------------------------------------------------------------------
# network_profiles.gd, as 0018 ships it, against a fake nmcli. It has no OGUI types, so a stock
# Godot runs it (RETROFORGE_GODOT=<godot 4 binary>, or godot on PATH; skipped without).
CASE="Wi-Fi saved profiles (OGUI 0018)"
GODOT="${RETROFORGE_GODOT:-$(command -v godot || true)}"
if [ -z "$GODOT" ]; then
  printf '  skip %s -- no Godot (set RETROFORGE_GODOT to a Godot 4 binary)\n' "$CASE"
else
  T16="$(mktemp -d)" && [ -d "$T16" ] || { echo "mktemp -d failed" >&2; exit 1; }
  newside core/systems/network/network_profiles.gd > "$T16/network_profiles.gd"
  # Profiles are "uuid|type|ssid" lines in $T16/nm; every call is logged to $T16/calls.
  cat > "$T16/nmcli" <<'SH'
#!/bin/bash
D="$(dirname "$0")"
printf '%s\n' "$*" >> "$D/calls"
[ -e "$D/fail" ] && exit 8
case "$*" in
  "-t -f UUID,TYPE connection show") while IFS='|' read -r u t s; do echo "$u:$t"; done < "$D/nm" ;;
  "-e no -g 802-11-wireless.ssid connection show uuid "*)
    u="${!#}"; line="$(grep "^$u|" "$D/nm")" || exit 10; printf '%s\n' "${line#*|*|}" ;;
  "connection delete uuid "*)
    u="${!#}"; grep -q "^$u|" "$D/nm" || exit 10; grep -v "^$u|" "$D/nm" > "$D/nm.new"; mv "$D/nm.new" "$D/nm" ;;
  *) exit 2 ;;
esac
SH
  chmod +x "$T16/nmcli"
  printf '%s\n' 'u1|802-11-wireless|home' 'u2|802-3-ethernet|home' 'u3|802-11-wireless|home2' \
    'u4|802-11-wireless|home' 'u5|802-11-wireless|a:b\c' 'u6|802-11-wireless|cafe ' 'u7|802-11-wireless|cafe' > "$T16/nm"
  cat > "$T16/profiles_test.gd" <<GD
extends SceneTree

const P := preload("$T16/network_profiles.gd")
var failed := 0

func check(what: String, got, want) -> void:
	if got == want:
		print("  ok   $CASE -- ", what)
	else:
		failed += 1
		print("  FAIL $CASE -- ", what, ": got ", got, ", want ", want)

func calls() -> int:
	return FileAccess.get_file_as_string("$T16/calls").count("\n")

func _init() -> void:
	P.nmcli = "$T16/nmcli"
	check("every Wi-Fi profile of the network, and only those", P.uuids_for("home"), PackedStringArray(["u1", "u4"]))
	check("SSIDs are compared as they are (':' and '\\\\' unescaped, spaces kept)",
		[P.uuids_for("a:b\\\\c"), P.uuids_for("cafe "), P.uuids_for("cafe")],
		[PackedStringArray(["u5"]), PackedStringArray(["u6"]), PackedStringArray(["u7"])])
	var before := calls()
	check("no SSID, no profile and no nmcli call", [P.uuids_for(""), calls() - before], [PackedStringArray(), 0])
	check("delete counts what NetworkManager deleted", P.delete(PackedStringArray(["u1", "nope"])), 1)
	check("...and the profile is gone", P.uuids_for("home"), PackedStringArray(["u4"]))
	check("after a join that worked, the profiles saved before it go",
		P.stale_after_join(PackedStringArray(["old"]), PackedStringArray(["old", "new"]), true), PackedStringArray(["old"]))
	check("after a join that failed, the profile it added goes",
		P.stale_after_join(PackedStringArray(["old"]), PackedStringArray(["old", "new"]), false), PackedStringArray(["new"]))
	check("a first join that worked keeps its profile",
		P.stale_after_join(PackedStringArray(), PackedStringArray(["new"]), true), PackedStringArray())
	DirAccess.open("$T16").make_dir("fail")
	check("nmcli failing: nothing found, nothing deleted", [P.uuids_for("home"), P.delete(PackedStringArray(["u4"]))], [PackedStringArray(), 0])
	quit(1 if failed else 0)
GD
  out="$(XDG_CONFIG_HOME="$T16/config" timeout 60 "$GODOT" --headless --script "$T16/profiles_test.gd" 2>&1)"; rc=$?
  printf '%s\n' "$out" | grep -E '^  (ok|FAIL) '
  n_ok="$(printf '%s\n' "$out" | grep -c '^  ok ')"; n_bad="$(printf '%s\n' "$out" | grep -c '^  FAIL ')"
  PASS=$((PASS + n_ok)); FAIL=$((FAIL + n_bad))
  if [ "$rc" -ne 0 ] && [ "$n_bad" -eq 0 ]; then
    bad "Godot failed (rc $rc): $(printf '%s\n' "$out" | grep -E 'ERROR|error' | head -3)"
  fi
  # Godot exits 0 when a preloaded script does not compile: the checks using it just never run.
  if printf '%s\n' "$out" | grep -q 'SCRIPT ERROR'; then
    bad "a script did not compile: $(printf '%s\n' "$out" | grep 'SCRIPT ERROR' | head -3)"
  fi
  [ "$n_ok" -eq 9 ] || bad "ran $n_ok of 9 checks"
  rm -rf "$T16"
fi

# =================================================================================================
CASE="no self-updater on a RAUC root"
for row in usr/lib/systemd/user/systemd-sysext-updater.service \
           usr/share/opengamepadui/scripts/update_systemd_ext.sh \
           usr/share/opengamepadui/scripts/make_nice \
           usr/share/polkit-1/actions/org.shadowblip.setcap.policy \
           usr/share/polkit-1/actions/org.shadowblip.nixos_updater.policy; do
  grep -qx "glob $row" "$TRIM" && ok "trimmed: $row" || bad "not trimmed: $row"
done

# =================================================================================================
# Behaviour: run the real retroforge-session with a fake gamescope and a fake shell client.
# PAMName= puts the session in the logind scope, so systemd's stop reaches ONLY this script. With
# the client in the foreground, sh held the TERM trap until the client returned, nothing told the
# client to quit, and every `systemctl restart retroforge-session` waited out the 90 s stop timeout
# (HW 2026-10-03). The client must get SIGTERM from the script and the session must end promptly.
CASE="session stop"
T="$(mktemp -d)" && [ -d "$T" ] || { echo "mktemp -d failed" >&2; exit 1; }
spids=()
# Also the fake reapers and games (pid files): a regression orphans them exactly like the real bug.
cleanup_t() {
  [ ${#spids[@]} -gt 0 ] && kill -KILL "${spids[@]}" 2>/dev/null
  [ -n "${T:-}" ] && [ -d "$T" ] || return
  cat "$T"/*.pids 2>/dev/null | xargs -r kill -KILL 2>/dev/null
  rm -rf "$T"
}
trap cleanup_t EXIT
mkdir -p "$T/bin" "$T/run" "$T/home"
# gamescope: answer the startup handshake on the -R fifo, then run until SIGTERM.
cat > "$T/bin/gamescope" <<EOF
#!/bin/bash
trap 'echo gamescope-term >> "$T/log"; exit 0' TERM
echo \$\$ > "$T/gs.pid"
echo "gs-vram=\${ENABLE_MESA_VRAM_REPORT_LIMIT-}\${VK_VRAM_REPORT_LIMIT_HEAP_SIZE-}" >> "$T/log"
while [ \$# -gt 0 ]; do [ "\$1" = -R ] && { r=\$2; shift; }; shift; done
echo ":1 gamescope-0" > "\$r"
while :; do sleep 0.05; done
EOF
# The shell client: logs its stdin, exits 5 when $T/client-exit appears, or 0 on SIGTERM.
cat > "$T/client" <<EOF
#!/bin/bash
echo "stdin=\$(readlink /proc/\$\$/fd/0)" >> "$T/log"
echo "vram=\${ENABLE_MESA_VRAM_REPORT_LIMIT-}:\${VK_VRAM_REPORT_LIMIT_HEAP_SIZE-}:\${VK_VRAM_REPORT_LIMIT_DEVICE_ID-}" >> "$T/log"
echo "args=\$*" >> "$T/log"
trap 'echo client-term >> "$T/log"; exit 0' TERM
if [ -e "$T/with-game" ]; then "$T/reaper" "$T/reaper.sh" & fi
echo client-up >> "$T/log"
while [ ! -e "$T/client-exit" ]; do sleep 0.05; done
exit 5
EOF
# OGUI's reaper is a binary found by its executable path, so the fake is a copy of bash (its
# /proc/PID/exe is then $T/reaper) running a script: start the game in its own session, as
# retroforge-launch starts an emulator, and exit once no child is left.
cp "$(command -v bash)" "$T/reaper"
cat > "$T/reaper.sh" <<EOF
echo \$\$ > "$T/reaper.pid"; echo \$\$ >> "$T/fakes.pids"
setsid "$T/game" &
wait
echo reaper-exit >> "$T/log"
EOF
# The game: on SIGTERM records whether gamescope is still up, takes 0.2 s to "save", exits. With
# $T/game-stubborn it ignores SIGTERM.
cat > "$T/game" <<EOF
#!/bin/bash
if [ -e "$T/game-stubborn" ]; then trap '' TERM
else trap 'kill -0 \$(cat "$T/gs.pid") 2>/dev/null && echo game-term-display-up >> "$T/log" || echo game-term-display-gone >> "$T/log"; sleep 0.2; echo game-exit >> "$T/log"; exit 0' TERM
fi
echo \$\$ >> "$T/fakes.pids"
echo game-up >> "$T/log"
while :; do sleep 0.05; done
EOF
chmod +x "$T/bin/gamescope" "$T/client" "$T/game"
run_session() {
  : > "$T/log"; rm -f "$T/client-exit"
  PATH="$T/bin:$PATH" XDG_RUNTIME_DIR="$T/run" HOME="$T/home" RETROFORGE_SESSION_CMD="${SESSION_CMD:-$T/client}" \
    RETROFORGE_OGUI_REAPER="$T/reaper" RETROFORGE_GAME_STOP_TIMEOUT=1 \
    sh "$SESSION" < "$T/stdin" > "$T/session.out" 2>&1 &
  spid=$!; spids+=("$spid")
}
waitfor() { for _ in $(seq 100); do eval "$1" && return 0; sleep 0.05; done; return 1; }
: > "$T/stdin"
if [ -e /etc/retroforge/session.conf ] || [ -e /usr/lib/retroforge/device-env ]; then
  ok "skipped: this host has RetroForge's session.conf/device-env, which would override the fakes"
else
  run_session
  if waitfor 'grep -qx client-up "$T/log"'; then
    grep -qx "stdin=$T/stdin" "$T/log" \
      && ok "the client keeps the session's stdin (tty1 on the device), not /dev/null" \
      || bad "the client's stdin is $(sed -n 's/^stdin=//p' "$T/log"), not the session's"
    t0=$(date +%s%N); kill -TERM "$spid"
    if waitfor "! kill -0 $spid 2>/dev/null"; then
      ms=$(( ($(date +%s%N) - t0) / 1000000 ))
      wait "$spid"; rc=$?
      ok "SIGTERM to the session ends it in ${ms} ms (was: hung until systemd's 90 s SIGKILL)"
      [ "$rc" = 143 ] && ok "exit status 143 after SIGTERM" || bad "exit status $rc after SIGTERM, not 143"
    else
      bad "the session ignored SIGTERM for 5 s: systemctl stop would wait out TimeoutStopSec"
    fi
    grep -qx client-term "$T/log" && ok "the shell client was sent SIGTERM" || bad "the shell client never got SIGTERM"
    waitfor 'grep -qx gamescope-term "$T/log"' && ok "gamescope was stopped" || bad "gamescope was left running"
    ls -d "$T"/run/gamescope.* >/dev/null 2>&1 && bad "the gamescope rundir was left behind" || ok "the gamescope rundir was removed"
  else
    bad "the fake client never started: $(tail -3 "$T/session.out")"
  fi

  run_session
  if waitfor 'grep -qx client-up "$T/log"'; then
    touch "$T/client-exit"
    waitfor "! kill -0 $spid 2>/dev/null" || { bad "the session did not end after the client exited"; kill -KILL "$spid"; }
    wait "$spid"; rc=$?
    [ "$rc" = 5 ] && ok "a client that exits on its own: the session exits with its status (5)" || bad "session exited $rc, the client 5"
    waitfor 'grep -qx gamescope-term "$T/log"' && ok "...and gamescope is stopped" || bad "gamescope survived the client's exit"
  else
    bad "the fake client never started (second run)"
  fi
fi

# -------------------------------------------------------------------------------------------------
CASE="the shell's VRAM report"
# OGUI (Godot's VMA) reserves blocks sized from the reported heap, so the shell alone gets mesa's
# vram-report-limit layer: 512 MiB below 4 GiB of RAM, 1 GiB up to 6 GiB, nothing above, and
# nothing without device-env's GPU chip id (the layer matches one id).
if [ -e /etc/retroforge/session.conf ] || [ -e /usr/lib/retroforge/device-env ]; then
  ok "skipped: this host has RetroForge's session.conf/device-env, which would override the fakes"
else
  for row in "3386492 0x5143:0x06010000 1:512:0x5143:0x06010000" \
             "4194303 0x5143:0x06010000 1:512:0x5143:0x06010000" \
             "4194304 0x5143:0x06050002 1:1024:0x5143:0x06050002" \
             "5700000 0x5143:0x06050002 1:1024:0x5143:0x06050002" \
             "6291456 0x5143:0x43051401 1:1024:0x5143:0x43051401" \
             "6291457 0x5143:0x43051401 ::" \
             "15826200 0x5143:0x43051401 ::" \
             "3386492 - ::" \
             "missing 0x5143:0x06010000 ::"; do
    read -r kb chip want <<<"$row"
    if [ "$kb" = missing ]; then rm -f "$T/meminfo"; else printf 'MemTotal:       %s kB\n' "$kb" > "$T/meminfo"; fi
    [ "$chip" = - ] && chip=""
    RETROFORGE_MEMINFO="$T/meminfo" RETROFORGE_GPU_CHIP_ID="$chip" run_session
    if waitfor 'grep -qx client-up "$T/log"'; then
      got=$(sed -n 's/^vram=//p' "$T/log")
      [ "$got" = "$want" ] && ok "MemTotal $kb kB, chip '${chip:-none}': shell gets '$want'" \
        || bad "MemTotal $kb kB, chip '${chip:-none}': shell got '$got', want '$want'"
      [ "$kb" = 3386492 ] && [ -n "$chip" ] && { grep -qx 'gs-vram=' "$T/log" \
        && ok "gamescope itself does not get the shell's report" || bad "gamescope got the report: $(grep gs-vram "$T/log")"; }
    else
      bad "the fake client never started ($kb kB)"
    fi
    touch "$T/client-exit"
    waitfor "! kill -0 $spid 2>/dev/null" || kill -KILL "$spid"
    wait "$spid" 2>/dev/null
  done
  rm -f "$T/meminfo"
fi

# -------------------------------------------------------------------------------------------------
CASE="the shell's renderer"
# A low-memory board's profile starts OGUI on OpenGL (RETROFORGE_UI_RENDERER=opengl); there, the
# player's Settings > Display > Vulkan renderer (UI_RENDERER= in ~/.config/retroforge/display.conf,
# the last line counts) wins. No board default: no choice. A command naming a renderer, or one that
# is not OGUI (a vkcube check), is left as it is.
if [ -e /etc/retroforge/session.conf ] || [ -e /usr/lib/retroforge/device-env ]; then
  ok "skipped: this host has RetroForge's session.conf/device-env, which would override the fakes"
else
  ln -sf "$T/client" "$T/opengamepadui"
  gl="--rendering-method gl_compatibility --rendering-driver opengl3"
  while IFS='|' read -r what board conf cmd want; do
    rm -rf "$T/home/.config/retroforge"
    if [ -n "$conf" ]; then mkdir -p "$T/home/.config/retroforge"; printf "$conf" > "$T/home/.config/retroforge/display.conf"; fi
    SESSION_CMD="$T/$cmd" RETROFORGE_UI_RENDERER="$board" run_session
    if waitfor 'grep -qx client-up "$T/log"'; then
      got=$(sed -n 's/^args=//p' "$T/log")
      [ "$got" = "${want/GL/$gl}" ] && ok "$what" || bad "$what: the shell got '$got'"
    else
      bad "the fake client never started ($what)"
    fi
    touch "$T/client-exit"
    waitfor "! kill -0 $spid 2>/dev/null" || kill -KILL "$spid"
    wait "$spid" 2>/dev/null
  done <<'ROWS'
OpenGL board, no choice stored: OpenGL|opengl||opengamepadui --skip-update-pack|--skip-update-pack GL
OpenGL board, the player chose Vulkan: no renderer flags|opengl|OTHER=1\nUI_RENDERER=vulkan\n|opengamepadui --skip-update-pack|--skip-update-pack
the last UI_RENDERER= line counts|opengl|UI_RENDERER=vulkan\nUI_RENDERER=opengl\n|opengamepadui --skip-update-pack|--skip-update-pack GL
an unknown value falls back to the board's default|opengl|UI_RENDERER=metal\n|opengamepadui --skip-update-pack|--skip-update-pack GL
a board with no default ignores a stored OpenGL choice||UI_RENDERER=opengl\n|opengamepadui --skip-update-pack|--skip-update-pack
a command that names a renderer keeps it|opengl||opengamepadui --skip-update-pack --rendering-driver vulkan|--skip-update-pack --rendering-driver vulkan
a command that is not OGUI gets no Godot flags|opengl||client|
ROWS
fi

# -------------------------------------------------------------------------------------------------
CASE="session stop with a game running"
if [ -e /etc/retroforge/session.conf ] || [ -e /usr/lib/retroforge/device-env ]; then
  ok "skipped (host has RetroForge's session.conf/device-env)"
else
  # Index of a line in the log: the order is the point (game before shell before gamescope).
  at() { grep -nx "$1" "$T/log" | head -1 | cut -d: -f1; }
  touch "$T/with-game"; rm -f "$T/game-stubborn"
  run_session
  if waitfor 'grep -qx game-up "$T/log"'; then
    kill -TERM "$spid"
    waitfor "! kill -0 $spid 2>/dev/null" || { bad "the session did not end"; kill -KILL "$spid"; }
    wait "$spid"
    grep -qx game-term-display-up "$T/log" \
      && ok "the game got SIGTERM while gamescope was still up (a clean shutdown, not a lost display)" \
      || bad "the game was not stopped before gamescope ($(grep game-term "$T/log" || echo 'no SIGTERM'))"
    [ -n "$(at game-exit)" ] && [ -n "$(at reaper-exit)" ] && [ -n "$(at client-term)" ] \
      && [ "$(at reaper-exit)" -lt "$(at client-term)" ] \
      && ok "the game and its reaper were gone before the shell was stopped" \
      || bad "order in the log: $(tr '\n' ' ' < "$T/log")"
    waitfor 'grep -qx gamescope-term "$T/log"' && [ "$(at game-exit)" -lt "$(at gamescope-term)" ] \
      && ok "gamescope was stopped last" || bad "gamescope stopped before the game exited"
  else
    bad "the fake game never started: $(tail -3 "$T/session.out")"
  fi

  # The shell exits on its own (a crash) with a game running: the game still goes first.
  run_session
  if waitfor 'grep -qx game-up "$T/log"'; then
    touch "$T/client-exit"
    waitfor "! kill -0 $spid 2>/dev/null" || { bad "the session did not end"; kill -KILL "$spid"; }
    wait "$spid"
    grep -qx game-term-display-up "$T/log" && [ -n "$(at reaper-exit)" ] \
      && ok "shell crashed with a game running: the orphaned game is still stopped cleanly" \
      || bad "a game left behind by an exiting shell was not stopped cleanly: $(tr '\n' ' ' < "$T/log")"
  else
    bad "the fake game never started (crash case)"
  fi

  # A game that ignores SIGTERM is killed after RETROFORGE_GAME_STOP_TIMEOUT (1 s here).
  touch "$T/game-stubborn"
  run_session
  if waitfor 'grep -qx game-up "$T/log"'; then
    kill -TERM "$spid"
    waitfor "! kill -0 $spid 2>/dev/null" || { bad "the session did not end"; kill -KILL "$spid"; }
    wait "$spid"
    rp="$(cat "$T/reaper.pid")"
    grep -q "still running after 1s" "$T/session.out" && ! kill -0 "$rp" 2>/dev/null \
      && ok "a game ignoring SIGTERM is killed after the timeout, and the session still ends" \
      || bad "a stubborn game was not killed (session.out: $(tail -2 "$T/session.out"))"
  else
    bad "the fake game never started (stubborn case)"
  fi
  rm -f "$T/with-game" "$T/game-stubborn"
fi

# -------------------------------------------------------------------------------------------------
# cleanup() must WAIT for gamescope to exit, not just signal it. SDDM's autologin starts the next
# session the moment the script returns; a gamescope still alive holds /dev/dri/card0, the new one's
# logind TakeDevice fails EBUSY, the handshake times out and SDDM does not relogin: one client crash
# becomes a permanently black screen (upstream HW 2026-10-04, the old gamescope took ~0.7 s to go).
#
# cleanup() and gs_running() are extracted from the SHIPPED script by name and run in /bin/sh
# against a fake gamescope started as a CHILD of the same shell -- an exited child stays a zombie
# until reaped, and a zombie still answers `kill -0`, which is what gs_running() has to see through.
CASE="gamescope teardown"
extract() { sed -n "/^$1() {/,/^}/p" "$SESSION"; }
{ extract gs_running; extract cleanup; } > "$T/cleanup.sh"
if [ -z "$(extract gs_running)" ] || [ -z "$(extract cleanup)" ]; then
  bad "could not extract gs_running() and cleanup() from retroforge-session"
else
  # Prints "<elapsed ms> <fake state>", the state read BEFORE anything reaps the child: "gone" or
  # "Z" means its fds are closed (DRM released); anything else means it is still running.
  run_cleanup() {
    /bin/sh -c '
      . "$1"
      GS_RUNDIR="$2/td-rundir"; mkdir -p "$GS_RUNDIR"
      RETROFORGE_GAMESCOPE_STOP_TIMEOUT="$4"
      /bin/sh -c "$3" &
      GS_PID=$!
      fake=$GS_PID   # cleanup() clears GS_PID once it is done with it
      sleep 0.3      # let the fake install its trap
      t0=$(date +%s%N)
      cleanup 2>/dev/null
      t1=$(date +%s%N)
      st=gone
      [ -e "/proc/$fake" ] && st=$(sed -n "s/^State:[[:space:]]*\([A-Z]\).*/\1/p" "/proc/$fake/status")
      echo "$(( (t1 - t0) / 1000000 )) $st"
      kill -KILL "$fake" 2>/dev/null; wait "$fake" 2>/dev/null
      exit 0
    ' sh "$T/cleanup.sh" "$T" "$1" "$2"
  }

  # A gamescope that takes 1 s to wind down after SIGTERM must be gone when cleanup() returns.
  read -r ms st < <(run_cleanup 'trap "sleep 1; exit 0" TERM; while :; do sleep 0.1; done' 10)
  case "$st" in
    gone|Z) ok "a slow gamescope had exited when cleanup() returned (${ms} ms, state $st)" ;;
    *)      bad "cleanup() returned after ${ms} ms with gamescope still running (state $st): the next session gets EBUSY on card0" ;;
  esac

  # gamescope can ignore SIGTERM outright; the script must still exit so SDDM can relogin, and it
  # must not escalate to SIGKILL. Bound 1 s here.
  read -r ms st < <(run_cleanup 'trap "" TERM; while :; do sleep 0.1; done' 1)
  [ "$ms" -ge 900 ] && [ "$ms" -lt 3000 ] \
    && ok "a gamescope ignoring SIGTERM: gave up after ${ms} ms with the 1 s bound" \
    || bad "returned after ${ms} ms with a 1 s bound, expected ~1000"
  case "$st" in
    gone|Z) bad "the TERM-ignoring fake is gone (state $st): cleanup() escalated, which it must not" ;;
    *)      ok "...and did not escalate past SIGTERM (state $st)" ;;
  esac

  # The EXIT trap can run cleanup() after an explicit call; the second must be a clean no-op.
  out="$(/bin/sh -c '
    . "$1"; GS_RUNDIR="$2/td-rundir2"; mkdir -p "$GS_RUNDIR"; RETROFORGE_GAMESCOPE_STOP_TIMEOUT=10
    /bin/sh -c "exit 0" & GS_PID=$!
    cleanup && cleanup && echo twice-ok
  ' sh "$T/cleanup.sh" "$T" 2>&1)"
  [ "$out" = "twice-ok" ] && ok "a second cleanup() is a clean no-op" || bad "second call misbehaved: '${out:-<nothing>}'"
fi

# =================================================================================================
CASE="session unit limits"
UNIT="$ROOT/rootfs/overlay/usr/lib/systemd/system/retroforge-session.service"
grep -qx 'LimitMEMLOCK=infinity' "$UNIT" \
  && ok "no locked-memory cap for the session and its games (RPCS3 mlocks emulated memory)" \
  || bad "retroforge-session.service lacks LimitMEMLOCK=infinity: RPCS3 fails to lock memory at 8 MiB"

printf '\ntest-session.sh: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
