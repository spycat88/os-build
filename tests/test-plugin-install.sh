#!/usr/bin/env bash
# Offline test for /usr/lib/retroforge/install-ogui-plugin — how the session puts the image's RetroForge
# plugin into OpenGamepadUI's plugin folder.
#
#   tests/test-plugin-install.sh
#
# WHY THIS EXISTS. OGUI only loads plugins from the player's ~/.local/share/opengamepadui/plugins,
# so a fresh card has no ROM library and no Emulators page until something copies the image's copy
# there. The rules, each of which goes wrong silently:
#   - install when missing, or when the installed copy's version DIFFERS from the image's: an OS
#     update brings a newer plugin, and a beta -> stable channel switch an OLDER one that must win
#     too (the image is the plugin's only source; a newer copy left behind calls tools the stable
#     image does not have);
#   - replace a same-version copy whose bytes differ (plugin changes land without a version bump),
#     but never rewrite a byte-identical one;
#   - an unreadable installed zip counts as missing (it would never load);
#   - the copy is atomic: OGUI must never find a half-written retroforge.zip;
#   - a broken image copy is an error, not an install.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TOOL="$ROOT/rootfs/overlay/usr/lib/retroforge/install-ogui-plugin"
[ -f "$TOOL" ] || { echo "no install-ogui-plugin: $TOOL" >&2; exit 1; }

PASS=0; FAIL=0; CASE=""
ok()  { PASS=$((PASS+1)); printf '  ok   %s -- %s\n' "$CASE" "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s -- %s\n' "$CASE" "$1"; }

T="$(mktemp -d)" && [ -d "$T" ] || { echo "mktemp -d failed" >&2; exit 1; }
trap 'rm -rf "$T"' EXIT

mkzip() {  # mkzip <path> <version>: a plugin zip as build.sh lays it out
  python3 - "$1" "$2" <<'PY'
import json, sys, zipfile
path, version = sys.argv[1:3]
with zipfile.ZipFile(path, "w") as z:
    z.writestr("plugins/retroforge/plugin.json", json.dumps({"plugin.id": "retroforge", "plugin.version": version}))
    z.writestr("plugins/retroforge/plugin.gd", "extends Plugin\n")
PY
}
version_of() { python3 -c 'import json,sys,zipfile; print(json.loads(zipfile.ZipFile(sys.argv[1]).read("plugins/retroforge/plugin.json"))["plugin.version"])' "$1" 2>/dev/null; }

SRC="$T/image/retroforge.zip"
DST_DIR="$T/home/.local/share/opengamepadui/plugins"
DST="$DST_DIR/retroforge.zip"
mkdir -p "$T/image"
run() {
  OUT="$(RETROFORGE_PLUGIN_SRC="$SRC" RETROFORGE_PLUGIN_DIR="$DST_DIR" python3 "$TOOL" 2>"$T/err")"; RC=$?
  ERR="$(cat "$T/err")"
}

# =================================================================================================
CASE="fresh card"
mkzip "$SRC" 0.2.0
run
[ "$RC" = 0 ] && [ "$(version_of "$DST")" = 0.2.0 ] && ok "installs the image's copy when none is there (exit 0)" || bad "rc=$RC installed=$(version_of "$DST") err=$ERR"
cmp -s "$SRC" "$DST" && ok "the installed zip is byte-identical to the image's" || bad "the copy differs"
[ "$(ls -A "$DST_DIR")" = retroforge.zip ] && ok "no temporary file left beside it" || bad "left: $(ls -A "$DST_DIR")"
[ "$(stat -c %a "$DST")" = 644 ] && ok "mode 644" || bad "mode $(stat -c %a "$DST")"

CASE="identical copy"
touch -d '2001-01-01' "$DST"; before="$(stat -c %Y "$DST")"
run
[ "$RC" = 0 ] && [ "$(stat -c %Y "$DST")" = "$before" ] && ok "byte-identical: left alone" || bad "rewritten (rc=$RC)"

CASE="OS update brings a newer plugin"
mkzip "$SRC" 0.10.0
run
[ "$RC" = 0 ] && [ "$(version_of "$DST")" = 0.10.0 ] && ok "0.2.0 installed, image has 0.10.0: upgraded (compared as versions, not text)" || bad "installed=$(version_of "$DST") rc=$RC"

CASE="beta -> stable channel switch"
mkzip "$DST" 0.11.0
mkzip "$SRC" 0.10.0
run
[ "$RC" = 0 ] && [ "$(version_of "$DST")" = 0.10.0 ] && ok "a newer installed copy is replaced by the image's older one" || bad "installed=$(version_of "$DST") rc=$RC"
[ "$(ls -A "$DST_DIR")" = retroforge.zip ] && ok "no temporary file left beside it" || bad "left: $(ls -A "$DST_DIR")"

CASE="unreadable installed copy"
echo "not a zip" > "$DST"
run
[ "$RC" = 0 ] && [ "$(version_of "$DST")" = 0.10.0 ] && ok "a broken installed zip is replaced" || bad "installed=$(version_of "$DST") rc=$RC"

CASE="broken image copy"
cp "$DST" "$T/good.zip"
echo "garbage" > "$SRC"
run
[ "$RC" != 0 ] && ok "an unreadable image zip is an error (exit $RC)" || bad "exit 0 on a broken image zip"
cmp -s "$T/good.zip" "$DST" && ok "... and the installed copy is untouched" || bad "the installed copy changed"
rm -f "$SRC"
run
[ "$RC" != 0 ] && cmp -s "$T/good.zip" "$DST" && ok "no image zip at all: error, installed copy untouched" || bad "rc=$RC"

CASE="stdout"
mkzip "$SRC" 0.12.0; rm -rf "$DST_DIR"
run
[ -z "$OUT" ] && ok "prints nothing on stdout (the session's log gets stderr)" || bad "stdout: $OUT"
[ -f "$DST" ] && ok "creates the plugins folder when OGUI has not yet" || bad "no plugins folder created"

CASE="same version, other contents"
mkzip "$SRC" 0.12.0
python3 -c 'import sys,zipfile; zipfile.ZipFile(sys.argv[1],"a").writestr("plugins/retroforge/extra.gd","# edit\n")' "$SRC"
run
[ "$RC" = 0 ] && cmp -s "$SRC" "$DST" && ok "a same-version copy with other bytes is replaced" || bad "kept (rc=$RC)"
[ "$(ls -A "$DST_DIR")" = retroforge.zip ] && ok "no temporary file left beside it" || bad "left: $(ls -A "$DST_DIR")"
case "$ERR" in *"contents changed"*) ok "the log says why";; *) bad "log: $ERR";; esac
touch -d '2001-01-01' "$DST"; before="$(stat -c %Y "$DST")"
run
[ "$RC" = 0 ] && [ "$(stat -c %Y "$DST")" = "$before" ] && [ -z "$ERR" ] && ok "... and left alone on the next start" || bad "rewritten (rc=$RC err=$ERR)"

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
