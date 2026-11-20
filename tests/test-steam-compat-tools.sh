#!/usr/bin/env bash
# Offline test for Proton-CachyOS arm64 and its ARMv8.0 rebuild as Steam compatibility tools:
# /usr/lib/retroforge/steam-compat-tools (the tool, DXVK-Sarek where the GPU needs it) and
# /usr/bin/retroforge-proton (the plugin's Apps > Proton).
#
#   tests/test-steam-compat-tools.sh
#
# WHY THIS EXISTS. Nothing here runs before a player picks a Windows game, and each rule below fails
# as a game without a working DXVK, a half tool Steam lists, a tool a game loses, or a player's own
# tool gone:
#   which GPUs need Sarek: SoC class SM6115 and SM4450 (device-env), nothing else, an unknown board
#   neither; RETROFORGE_STEAM_SAREK=on|off overrides it;
#   helper (steam-compat-tools install):
#   - the image's pin follows the channel (no tag), and names one folder for the tool;
#   - one API request picks the newest release with the arm64 tarball and its .sha512sum (highest
#     Proton version, then latest published), skipping releases without them, drafts, prereleases
#     and uploads in progress; refuses a tarball unless its sha512 (and GitHub's sha256) match;
#     installs it whole as compatibilitytools.d/<dir> (symlinks kept), its compatibilitytool.vdf
#     naming the tool <dir>, with its .retroforge-pin, and the Sarek user_settings.py where the GPU
#     needs it;
#   - the release already installed: no download, nothing said;
#   - GitHub unreachable, rate limited, answering nonsense or with no arm64 build: the installed
#     release stays (exit 0); on a fresh image, exit 1 and no tool;
#   - a new release replaces the old one under the same name, by rename, keeping the player's
#     user_settings.py; while a process runs from the tool (a mapped file) it waits, checked, and goes
#     in at a later run without a second download; one withdrawn meanwhile is dropped;
#   - folders of the earlier per-release scheme go once the one-name folder is in, each when nothing
#     runs from it (working folder), and a player's user_settings.py in one comes along;
#   - a tag in the pin holds that release (asked by tag, then not at all), and a sha512 with it is
#     checked instead of the .sha512sum;
#   - on a GPU that does not need Sarek, deletes only its own user_settings.py (also the old toggle's
#     text) from every tool of ours, keeps the tools; where it is needed, writes it into each, over
#     the old text;
#   - never touches a folder it did not install, or a user_settings.py the player edited;
#   - sweeps what a killed run left, replaces a broken folder of its own, refuses a tarball without
#     its folder, proton or a compatibilitytool.vdf it can rename, and leaves a running install alone
#     (lock);
#   - its progress file goes 0, percentages, 100, unpacking, and is gone at the end, but not when
#     another run holds the lock;
#   status: the tool this CPU takes (Proton-CachyOS, or its ARMv8.0 rebuild), credited to its GitHub
#   owner, and its installed release (only from a folder RetroForge installed), as JSON;
#   retroforge-proton: status is the helper's; install runs the helper as the user unit with --wait
#   after any run of it already going, else in the foreground, and fails with the log's last line.
# GitHub's API is a local fake (a pin's releases: points at it) and the downloads are file:// URLs;
# device-env, systemd-run and systemctl are stubs.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HELPER="$ROOT/rootfs/overlay/usr/lib/retroforge/steam-compat-tools"
PIN_REAL="$ROOT/rootfs/overlay/usr/share/retroforge/steam/proton-cachyos-arm64.pin"
for f in "$HELPER" "$PIN_REAL"; do [ -f "$f" ] || { echo "missing: $f" >&2; exit 1; }; done

PASS=0; FAIL=0; CASE=""
ok()  { PASS=$((PASS+1)); printf '  ok   %s -- %s\n' "$CASE" "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s -- %s\n' "$CASE" "$1"; }

T="$(mktemp -d)" && [ -d "$T" ] || { echo "mktemp -d failed" >&2; exit 1; }
HOLDER=""; SERVER=""
trap 'for p in $HOLDER $SERVER; do kill "$p" 2>/dev/null; done; rm -rf "$T"' EXIT

digest() { python3 -c 'import hashlib,sys; print(hashlib.new(sys.argv[1], open(sys.argv[2],"rb").read()).hexdigest())' "$1" "$2"; }

SROOT="$T/home/.local/share/Steam"
TOOLS="$SROOT/compatibilitytools.d"
STABLE=proton-cachyos-arm64-retroforge
TOOL="$TOOLS/$STABLE"
NEXT="$SROOT/.retroforge-compat-tools.next"
SHOWN="Proton-CachyOS arm64 (RetroForge)"
PIN="$T/proton-cachyos-arm64.pin"
DL="$T/dl"; API="$T/api"; mkdir -p "$DL" "$API"
# Releases: R<n> is the tag, D<n> its tarball's top folder (the asset's name without .tar.xz).
R0=cachyos-11.0-20260703-slr;  D0=proton-cachyos-11.0-20260703-slr-arm64
R1=cachyos-11.0-20261005-slr;  D1=proton-cachyos-11.0-20261005-slr-arm64
R2=cachyos-11.0-20261105-slr;  D2=proton-cachyos-11.0-20261105-slr-arm64
R3=cachyos-11.0-20261215-slr;  D3=proton-cachyos-11.0-20261215-slr-arm64
RS=cachyos-10.0-sunset-slr;    DS=proton-cachyos-10.0-sunset-slr-arm64
RN=cachyos-12.0-20261201-slr;  DN=proton-cachyos-12.0-20261201-slr-arm64
RX=cachyos-11.0-20261231-slr;  DX=proton-cachyos-11.0-20261231-slr-arm64

mktool() {  # mktool <top> <marker> [no-proton|no-dir|bad-vdf]: $DL/<top>.tar.xz, laid out like Proton-CachyOS's
  python3 - "$DL" "$@" <<'PY'
import io, os, sys, tarfile
dl, top, marker = sys.argv[1:4]
what = sys.argv[4] if len(sys.argv) > 4 else ""
def add(t, name, data=b"", mode=0o644, kind=tarfile.REGTYPE, link=""):
    i = tarfile.TarInfo(name); i.type = kind; i.mode = mode; i.linkname = link; i.size = len(data)
    t.addfile(i, io.BytesIO(data) if data else None)
vdf = ('"compatibilitytools"\n{\n  "compat_tools"\n  {\n    "%s" // Internal name of this tool\n    {\n'
       '      // Can register this tool with Steam in two ways:\n      "install_path" "."\n\n'
       '      // For this template, we\'re going to substitute the display_name key in here, e.g.:\n'
       '      "display_name" "%s"\n\n      "from_oslist"  "windows"\n      "to_oslist"    "linux"\n    }\n  }\n}\n'
       % (top, top))
if what == "bad-vdf":
    vdf = '"compatibilitytools"\n{\n  "compat_tools"\n  {\n    "a" { "install_path" "." }\n    "b" { "install_path" "." }\n  }\n}\n'
files = {
    "compatibilitytool.vdf": vdf.encode(),
    "toolmanifest.vdf": b'"manifest"\n{\n  "version" "2"\n  "commandline" "/proton %verb%"\n'
                        b'  "require_tool_appid" "4185400"\n}\n',
    "proton": f"#!/usr/bin/env python3\n# {marker}\n".encode(),
    "version": f"1 {marker}\n".encode(),
    "user_settings.sample.py": b"user_settings = {}\n",
}
d = top + "-renamed" if what == "no-dir" else top
with tarfile.open(os.path.join(dl, top + ".tar.xz"), "w:xz") as t:
    add(t, d, kind=tarfile.DIRTYPE, mode=0o755)
    for name, data in files.items():
        if not (name == "proton" and what == "no-proton"):
            add(t, f"{d}/{name}", data, 0o755 if name == "proton" else 0o644)
    add(t, f"{d}/files/lib/wine/dxvk-sarek/aarch64-windows/d3d11.dll", b"MZ sarek\n")
    add(t, f"{d}/files/lib/libfoo.so.1", b"\x7fELF foo\n", 0o555)
    add(t, f"{d}/files/lib/libfoo.so", kind=tarfile.SYMTYPE, link="libfoo.so.1")
PY
}
# releases <<EOF, one per line: <tag> <published> <top|-> [flags]: the fake API's list of releases.
# flags: nosidecar badsidecar baddigest nodigest uploading draft prerelease. - = no arm64 build.
releases() { python3 "$T/releases.py" "$DL" "$API/releases.json"; }
cat >"$T/releases.py" <<'PY'
import hashlib, json, os, sys
dl, out = sys.argv[1:3]
rels = []
for line in sys.stdin:
    if not line.strip():
        continue
    tag, published, top, *flags = line.split()
    x86 = f"proton-{tag}-x86_64"
    assets = [{"name": x86 + ".tar.xz", "state": "uploaded", "browser_download_url": f"file://{dl}/{x86}.tar.xz"},
              {"name": x86 + ".sha512sum", "state": "uploaded", "browser_download_url": f"file://{dl}/{x86}.sha512sum"}]
    if top != "-":
        path = os.path.join(dl, top + ".tar.xz")
        data = open(path, "rb").read()
        tarball = {"name": top + ".tar.xz", "state": "starter" if "uploading" in flags else "uploaded",
                   "browser_download_url": "file://" + path}
        if "nodigest" not in flags:
            tarball["digest"] = "sha256:" + ("0" * 64 if "baddigest" in flags else hashlib.sha256(data).hexdigest())
        assets.append(tarball)
        if "nosidecar" not in flags:
            side = os.path.join(dl, f"{tag}.{top}.sha512sum")
            with open(side, "w") as f:
                f.write(("0" * 128 if "badsidecar" in flags else hashlib.sha512(data).hexdigest()) + f"  {top}.tar.xz\n")
            assets.append({"name": top + ".sha512sum", "state": "uploaded", "browser_download_url": "file://" + side})
    rels.append({"tag_name": tag, "published_at": published, "draft": "draft" in flags,
                 "prerelease": "prerelease" in flags, "assets": assets})
with open(out, "w") as f:
    json.dump(rels, f, indent=1)
PY

# The fake API: GET <base>?per_page=N (the list) and <base>/tags/<tag>, from $API/releases.json. Every
# request goes to $API/requests.log. $API/status, when there, is the answer instead: an HTTP code (403
# comes with GitHub's rate-limit headers) or "garbage" (200, not JSON).
cat >"$T/api.py" <<'PY'
import http.server, json, os, sys, urllib.parse
d = sys.argv[1]
BASE = "/repos/CachyOS/proton-cachyos/releases"
class H(http.server.BaseHTTPRequestHandler):
    def reply(self, code, body=b"{}", headers=()):
        self.send_response(code)
        for k, v in headers:
            self.send_header(k, v)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)
    def do_GET(self):
        with open(os.path.join(d, "requests.log"), "a") as f:
            f.write(self.path + "\n")
        try:
            status = open(os.path.join(d, "status")).read().strip()
        except OSError:
            status = ""
        if status == "garbage":
            return self.reply(200, b"<html>not json</html>")
        if status:
            limit = [("X-RateLimit-Remaining", "0"), ("X-RateLimit-Reset", "1792209892")] if status == "403" else []
            return self.reply(int(status), b'{"message": "no"}', limit)
        url = urllib.parse.urlsplit(self.path)
        rels = json.load(open(os.path.join(d, "releases.json")))
        if url.path == BASE:
            n = int(urllib.parse.parse_qs(url.query).get("per_page", ["30"])[0])
            return self.reply(200, json.dumps(rels[:n]).encode())
        if url.path.startswith(BASE + "/tags/"):
            tag = urllib.parse.unquote(url.path[len(BASE + "/tags/"):])
            for r in rels:
                if r["tag_name"] == tag:
                    return self.reply(200, json.dumps(r).encode())
        self.reply(404, b'{"message": "Not Found"}')
    def log_message(self, *args):
        pass
s = http.server.HTTPServer(("127.0.0.1", 0), H)
with open(os.path.join(d, "port.part"), "w") as f:
    f.write(str(s.server_address[1]))
os.rename(os.path.join(d, "port.part"), os.path.join(d, "port"))
s.serve_forever()
PY
python3 "$T/api.py" "$API" & SERVER=$!
for _ in $(seq 100); do [ -e "$API/port" ] && break; sleep 0.1; done
[ -e "$API/port" ] || { echo "the fake API did not start" >&2; exit 1; }
RELEASES="http://127.0.0.1:$(cat "$API/port")/repos/CachyOS/proton-cachyos/releases"

mkpin() {  # mkpin [tag] [sha512] [releases url]
  { printf 'name: proton-cachyos-arm64\nreleases: %s\nasset: proton-cachyos-*-slr-arm64.tar.xz\n' "${3:-$RELEASES}"
    printf 'dir: %s\ndisplay_name: %s\n' "$STABLE" "$SHOWN"
    [ -n "${1-}" ] && printf 'tag: %s\n' "$1"
    [ -n "${2-}" ] && printf 'sha512: %s\n' "$2"; } >"$PIN"
}
NOPROXY=(env -u http_proxy -u HTTP_PROXY -u https_proxy -u HTTPS_PROXY -u all_proxy -u ALL_PROXY)
tools() {  # tools <args>: the helper against the test's Steam root and pin, on a GPU that needs Sarek
           # unless SAREK=off. REQS: its API requests.
  : >"$API/requests.log"
  OUT="$("${NOPROXY[@]}" HOME="$T/home" RETROFORGE_STEAM_ROOT="$SROOT" RETROFORGE_STEAM_COMPAT_PIN="$PIN" \
         RETROFORGE_DEVICE_ENV="$T/no-device-env" RETROFORGE_STEAM_SAREK="${SAREK:-on}" \
         python3 "$HELPER" "$@" 2>"$T/err")"; RC=$?
  ERR="$(cat "$T/err")"; REQS="$(cat "$API/requests.log")"
}
asked() { grep -c . "$API/requests.log"; }
leftovers() { find "$SROOT" -maxdepth 1 -name '.retroforge-compat-tools-*' | head -3; }
tag_of() { sed -n 's/^tag: //p' "$1/.retroforge-pin" 2>/dev/null; }
settings() {  # settings <tool dir>: the user_settings dict Proton would load, as JSON
  python3 -I -c 'import json, sys; sys.dont_write_bytecode = True; sys.path.insert(0, sys.argv[1]); import user_settings; print(json.dumps(user_settings.user_settings, sort_keys=True))' "$1"
}
vdf_strings() {  # vdf_strings <tool dir>: compatibilitytool.vdf's quoted strings, comments dropped, |-joined
  python3 -c 'import re, sys; t = re.sub(r"//[^\n]*", "", open(sys.argv[1]).read()); print("|".join(re.findall(r"\"([^\"]*)\"", t)))' "$1/compatibilitytool.vdf"
}
VDF_OURS="compatibilitytools|compat_tools|$STABLE|install_path|.|display_name|$SHOWN|from_oslist|windows|to_oslist|linux"
ours_only() { [ "$(cd "$TOOLS" && LC_ALL=C ls -d proton-cachyos-1* 2>/dev/null | grep -v '^proton-cachyos-10.0-arm64$')" = "" ]; }
hold() {  # hold <how> <path>: a process of ours that maps a file there (map) or works in a folder there (cwd)
  rm -f "$T/held"
  if [ "$1" = map ]; then
    python3 -c 'import mmap, sys, time
f = open(sys.argv[1], "rb"); m = mmap.mmap(f.fileno(), 0, access=mmap.ACCESS_READ); f.close()
open(sys.argv[2], "w").close(); time.sleep(120)' "$2" "$T/held" &
  else
    (cd "$2" && touch "$T/held" && exec sleep 120) &
  fi
  HOLDER=$!
  for _ in $(seq 50); do [ -e "$T/held" ] && break; sleep 0.1; done
}
release() { kill "$HOLDER"; wait "$HOLDER" 2>/dev/null; HOLDER=""; }

# ================================================================================================
CASE="the real pin"
python3 - "$PIN_REAL" <<'PY' && ok "a channel (no tag): the GitHub API, the arm64 tarball, one folder and name" || bad "the image's proton-cachyos-arm64.pin is not that"
import fnmatch, re, sys
t = open(sys.argv[1]).read()
f = {}
for k in ("name", "releases", "asset", "dir", "display_name", "tag", "sha512"):
    m = re.search(rf"^{k}:[ \t]*(.*?)[ \t]*$", t, re.M)
    f[k] = m.group(1) if m and m.group(1) else None
assert f["name"] == "proton-cachyos-arm64", f
assert f["releases"] == "https://api.github.com/repos/CachyOS/proton-cachyos/releases", f
assert fnmatch.fnmatchcase("proton-cachyos-11.0-20261005-slr-arm64.tar.xz", f["asset"]), f
for other in ("proton-cachyos-11.0-20261005-slr-x86_64.tar.xz", "proton-cachyos-11.0-20261005-slr-arm64.sha512sum"):
    assert not fnmatch.fnmatchcase(other, f["asset"]), other
assert f["dir"] == "proton-cachyos-arm64-retroforge", f
assert f["display_name"] == "Proton-CachyOS arm64 (RetroForge)", f
assert f["tag"] is None and f["sha512"] is None, f
PY

CASE="helper: fresh install"
mktool "$D0" v0; mktool "$D1" v1
releases <<EOF
$R1 2026-10-04T21:30:56Z $D1
$R0 2026-07-22T00:57:55Z $D0
EOF
mkpin
tools install
[ "$RC" = 0 ] && [ "$OUT" = "$TOOL" ] && ok "exit 0, prints the tool's folder" || bad "rc=$RC out=$OUT err=$ERR"
[ "$REQS" = "/repos/CachyOS/proton-cachyos/releases?per_page=20" ] && ok "one API request, for the newest 20 releases" || bad "requests: $REQS"
[ -f "$TOOL/compatibilitytool.vdf" ] && [ -f "$TOOL/toolmanifest.vdf" ] && [ -x "$TOOL/proton" ] \
  && [ -f "$TOOL/files/lib/wine/dxvk-sarek/aarch64-windows/d3d11.dll" ] && grep -q v1 "$TOOL/proton" \
  && ok "the newest release, whole, in compatibilitytools.d/$STABLE, proton executable" || bad "$(find "$TOOLS" | head -20)"
[ "$(readlink "$TOOL/files/lib/libfoo.so")" = libfoo.so.1 ] && ok "symlinks are kept" || bad "libfoo.so: $(ls -la "$TOOL/files/lib" 2>&1)"
grep -q 'require_tool_appid" "4185400"' "$TOOL/toolmanifest.vdf" && ok "toolmanifest.vdf is the tarball's" || bad "$(cat "$TOOL/toolmanifest.vdf")"
[ "$(vdf_strings "$TOOL")" = "$VDF_OURS" ] && grep -q '"'"$STABLE"'" // Internal name of this tool' "$TOOL/compatibilitytool.vdf" \
  && ok "compatibilitytool.vdf names the tool $STABLE, shown as $SHOWN, the rest and its comments kept" \
  || bad "vdf: $(cat "$TOOL/compatibilitytool.vdf")"
[ "$(cat "$TOOL/.retroforge-pin")" = "$(printf 'name: proton-cachyos-arm64\ntag: %s\nasset: %s.tar.xz\nsha512: %s\nsha256: %s' \
    "$R1" "$D1" "$(digest sha512 "$DL/$D1.tar.xz")" "$(digest sha256 "$DL/$D1.tar.xz")")" ] \
  && ok "its .retroforge-pin: the name, the tag, the asset, its sha512 and sha256" || bad "marker: $(cat "$TOOL/.retroforge-pin" 2>&1)"
[ "$(settings "$TOOL")" = '{"PROTON_DXVK_SAREK": "1"}' ] \
  && ok "user_settings.py loads as Proton loads it, with PROTON_DXVK_SAREK=1 and nothing else" || bad "settings: $(settings "$TOOL" 2>&1)"
[ "$(ls -A "$TOOLS")" = "$STABLE" ] && ok "nothing else in compatibilitytools.d" || bad "$(ls -A "$TOOLS")"
[ -z "$(leftovers)" ] && [ ! -e "$NEXT" ] && ok "no temporary folders left" || bad "left: $(leftovers) $(ls -d "$NEXT" 2>&1)"
grep -q "downloading $D1.tar.xz ($R1)" <<<"$ERR" && grep -q "Steam lists it as \"$SHOWN\" from its next start" <<<"$ERR" \
  && ok "says what it downloads, and that Steam needs a restart" || bad "stderr: $ERR"
cp "$TOOL/user_settings.py" "$T/sarek.py"

CASE="helper: already installed"
mv "$DL/$D1.tar.xz" "$DL/$D1.away"   # a download would fail
tools install
[ "$RC" = 0 ] && [ "$OUT" = "$TOOL" ] && [ -z "$ERR" ] && [ "$(asked)" = 1 ] && ok "one API request, no download, says nothing" || bad "rc=$RC out=$OUT err=$ERR requests=$REQS"
mv "$DL/$D1.away" "$DL/$D1.tar.xz"

CASE="helper: a GPU that does not need Sarek"
SAREK=off tools install
[ "$RC" = 0 ] && [ ! -e "$TOOL/user_settings.py" ] && [ -x "$TOOL/proton" ] && grep -q "turned off in $STABLE" <<<"$ERR" \
  && ok "deletes its user_settings.py, keeps the tool" || bad "rc=$RC err=$ERR requests=$REQS"
tools install
[ "$RC" = 0 ] && [ -f "$TOOL/user_settings.py" ] && ok "one that needs it gets it again" || bad "rc=$RC err=$ERR"

CASE="helper: the player's user_settings.py"
printf 'user_settings = {"PROTON_LOG": "1", "PROTON_DXVK_SAREK": "1"}\n' >"$TOOL/user_settings.py"
SAREK=off tools install
[ "$RC" = 0 ] && grep -q PROTON_LOG "$TOOL/user_settings.py" && grep -q "player's own" <<<"$ERR" \
  && ok "a GPU without the need leaves an edited one alone, and says so" || bad "rc=$RC err=$ERR"
tools install
[ "$RC" = 0 ] && grep -q PROTON_LOG "$TOOL/user_settings.py" && ok "one with the need does not write over it" || bad "rc=$RC err=$ERR"
rm -f "$TOOL/user_settings.py"; tools install

CASE="helper: other tools"
mkdir -p "$TOOLS/GE-Proton10-1" "$TOOLS/proton-cachyos-10.0-arm64" "$TOOLS/other-family"
echo player >"$TOOLS/GE-Proton10-1/compatibilitytool.vdf"
echo player >"$TOOLS/proton-cachyos-10.0-arm64/compatibilitytool.vdf"
cp "$T/sarek.py" "$TOOLS/proton-cachyos-10.0-arm64/user_settings.py"
printf 'name: something-else\ntag: 1\nsha256: %s\n' "$(printf 'b%.0s' {1..64})" >"$TOOLS/other-family/.retroforge-pin"
SAREK=off tools install
[ -f "$TOOLS/proton-cachyos-10.0-arm64/user_settings.py" ] && ok "never touches a folder it did not install" || bad "the player's tool lost its user_settings.py"
tools install

CASE="helper: GitHub cannot be asked"
echo 500 >"$API/status"
tools install
[ "$RC" = 0 ] && [ "$OUT" = "$TOOL" ] && grep -q "answered 500" <<<"$ERR" && grep -q "keeping $R1" <<<"$ERR" && [ "$(tag_of "$TOOL")" = "$R1" ] \
  && ok "an API error: the installed release stays, exit 0, says so" || bad "rc=$RC out=$OUT err=$ERR"
echo 403 >"$API/status"
tools install
[ "$RC" = 0 ] && grep -q "allows no more requests from this network until" <<<"$ERR" && [ "$(tag_of "$TOOL")" = "$R1" ] \
  && ok "the rate limit used up: the same, and says until when" || bad "rc=$RC err=$ERR"
echo garbage >"$API/status"
tools install
[ "$RC" = 0 ] && grep -q "could not ask GitHub's API" <<<"$ERR" && [ "$(tag_of "$TOOL")" = "$R1" ] \
  && ok "an answer that is not JSON: the same" || bad "rc=$RC err=$ERR"
rm -f "$API/status"
mkpin "" "" "http://127.0.0.1:1/repos/CachyOS/proton-cachyos/releases"
tools install
[ "$RC" = 0 ] && [ "$OUT" = "$TOOL" ] && grep -q "could not ask GitHub's API" <<<"$ERR" && [ "$(tag_of "$TOOL")" = "$R1" ] \
  && ok "no network: the same" || bad "rc=$RC out=$OUT err=$ERR"
mkpin
releases <<EOF
$R2 2026-11-05T00:00:00Z -
$R1 2026-10-04T21:30:56Z -
EOF
tools install
[ "$RC" = 0 ] && grep -q "none of the newest 2 releases has proton-cachyos-\*-slr-arm64.tar.xz" <<<"$ERR" && [ "$(tag_of "$TOOL")" = "$R1" ] \
  && [ -x "$TOOL/proton" ] && ok "no release with an arm64 build: the same" || bad "rc=$RC err=$ERR"

CASE="helper: a new release, bad sha512"
mktool "$D2" v2
releases <<EOF
$R2 2026-11-05T00:00:00Z $D2 badsidecar
$R1 2026-10-04T21:30:56Z $D1
EOF
tools install
[ "$RC" = 1 ] && grep -q "sha512 mismatch" <<<"$ERR" && [ -z "$OUT" ] && ok "refused (exit 1, nothing on stdout)" || bad "rc=$RC out=$OUT err=$ERR"
[ "$(tag_of "$TOOL")" = "$R1" ] && grep -q v1 "$TOOL/proton" && ours_only && ok "the installed release stays, nothing half-installed" || bad "$(ls -A "$TOOLS")"
[ -z "$(leftovers)" ] && [ ! -e "$NEXT" ] && ok "no temporary folders left" || bad "left: $(leftovers)"

CASE="helper: a new release, GitHub's sha256 disagrees"
releases <<EOF
$R2 2026-11-05T00:00:00Z $D2 baddigest
$R1 2026-10-04T21:30:56Z $D1
EOF
tools install
[ "$RC" = 1 ] && grep -q "sha256 mismatch.*GitHub lists" <<<"$ERR" && [ "$(tag_of "$TOOL")" = "$R1" ] && [ -z "$(leftovers)" ] \
  && ok "refused, the installed release stays" || bad "rc=$RC err=$ERR"

CASE="helper: the newest release with an arm64 build"
mktool "$DS" sunset; mktool "$DN" v12; mktool "$DX" vx
releases <<EOF
$RX 2026-12-31T00:00:00Z -
$RX 2026-12-30T00:00:00Z $DX nosidecar
$RX 2026-12-29T00:00:00Z $DX uploading
$RN 2026-12-28T00:00:00Z $DN draft
$RN 2026-12-27T00:00:00Z $DN prerelease
$RS 2026-11-20T00:00:00Z $DS
$R1 2026-10-04T21:30:56Z $D1
$R2 2026-11-05T00:00:00Z $D2
EOF
tools install
[ "$RC" = 0 ] && [ "$OUT" = "$TOOL" ] && [ "$(tag_of "$TOOL")" = "$R2" ] && grep -q v2 "$TOOL/proton" \
  && ok "$R2: not one without an arm64 build or a .sha512sum, still uploading, a draft, a prerelease, or 10.0-sunset published after it" \
  || bad "rc=$RC out=$OUT tag=$(tag_of "$TOOL") err=$ERR"
[ "$(vdf_strings "$TOOL")" = "$VDF_OURS" ] && ok "under the same name, compatibilitytool.vdf rewritten again" || bad "vdf: $(cat "$TOOL/compatibilitytool.vdf")"
[ "$(settings "$TOOL")" = '{"PROTON_DXVK_SAREK": "1"}' ] && ok "with the Sarek user_settings.py" || bad "settings: $(settings "$TOOL" 2>&1)"
grep -q "updated $TOOL from $R1 to $R2" <<<"$ERR" && ok "says it updated, from what to what" || bad "stderr: $ERR"
ours_only && [ -z "$(leftovers)" ] && [ ! -e "$NEXT" ] && ok "the old release is gone, no second folder, nothing left" || bad "$(ls -A "$TOOLS") left: $(leftovers)"
[ -f "$TOOLS/GE-Proton10-1/compatibilitytool.vdf" ] && [ -f "$TOOLS/proton-cachyos-10.0-arm64/compatibilitytool.vdf" ] \
  && [ -f "$TOOLS/other-family/.retroforge-pin" ] \
  && ok "other tools, another pin's folder and a player's Proton-CachyOS are untouched" || bad "$(ls -A "$TOOLS")"

CASE="helper: a new release while a game runs from the tool"
mktool "$D3" v3
releases <<EOF
$R3 2026-12-15T00:00:00Z $D3
$R2 2026-11-05T00:00:00Z $D2
EOF
printf 'user_settings = {"PROTON_LOG": "1"}\n' >"$TOOL/user_settings.py"
hold map "$TOOL/files/lib/libfoo.so.1"
tools install
[ "$RC" = 0 ] && [ "$OUT" = "$TOOL" ] && [ "$(tag_of "$TOOL")" = "$R2" ] && grep -q v2 "$TOOL/proton" \
  && ok "the release in use stays in place" || bad "rc=$RC out=$OUT tag=$(tag_of "$TOOL") err=$ERR"
[ "$(tag_of "$NEXT")" = "$R3" ] && [ -x "$NEXT/proton" ] && grep -q "a game runs from $TOOL: $R3 is ready" <<<"$ERR" \
  && ok "the new one waits, checked, in .retroforge-compat-tools.next, and it says so" || bad "next: $(tag_of "$NEXT") err=$ERR"
releases <<EOF
$R2 2026-11-05T00:00:00Z $D2
EOF
tools install
[ "$RC" = 0 ] && [ ! -e "$NEXT" ] && [ "$(tag_of "$TOOL")" = "$R2" ] && ok "withdrawn upstream meanwhile: dropped" || bad "rc=$RC err=$ERR $(ls -A "$SROOT")"
releases <<EOF
$R3 2026-12-15T00:00:00Z $D3
$R2 2026-11-05T00:00:00Z $D2
EOF
tools install
[ "$(tag_of "$NEXT")" = "$R3" ] && [ "$(tag_of "$TOOL")" = "$R2" ] && ok "published again: it waits again" || bad "not waiting again: $(tag_of "$NEXT") $(tag_of "$TOOL") err=$ERR"
release
mv "$DL/$D3.tar.xz" "$DL/$D3.away"   # a second download would fail
tools install
[ "$RC" = 0 ] && [ "$(tag_of "$TOOL")" = "$R3" ] && grep -q v3 "$TOOL/proton" && [ ! -e "$NEXT" ] \
  && grep -q "$R3 was downloaded and checked before" <<<"$ERR" && ok "with nothing running from it, the next run puts it in without downloading" \
  || bad "rc=$RC tag=$(tag_of "$TOOL") err=$ERR"
[ "$(vdf_strings "$TOOL")" = "$VDF_OURS" ] && ours_only && [ -z "$(leftovers)" ] && ok "under the same name, and nothing left" || bad "$(ls -A "$TOOLS") $(leftovers)"
grep -q PROTON_LOG "$TOOL/user_settings.py" && grep -q "keeping the player's own user_settings.py" <<<"$ERR" \
  && ok "the player's user_settings.py came along" || bad "settings: $(cat "$TOOL/user_settings.py" 2>&1) err=$ERR"
mv "$DL/$D3.away" "$DL/$D3.tar.xz"
rm -f "$TOOL/user_settings.py"; tools install

CASE="helper: folders of the earlier per-release scheme"
rm -rf "$SROOT"; mkdir -p "$TOOLS"
for d in "$D0" "$D1"; do   # as the earlier helper left them: the tarball's folder and a marker naming the version
  tar -xJf "$DL/$d.tar.xz" -C "$TOOLS"
  printf 'name: proton-cachyos-arm64\nversion: cachyos-%s\nsha256: %s\n' "$d" "$(digest sha256 "$DL/$d.tar.xz")" >"$TOOLS/$d/.retroforge-pin"
done
cp "$T/sarek.py" "$TOOLS/$D1/user_settings.py"
printf 'user_settings = {"PROTON_LOG": "1"}\n' >"$TOOLS/$D0/user_settings.py"
releases <<EOF
$R2 2026-11-05T00:00:00Z $D2
$R1 2026-10-04T21:30:56Z $D1
EOF
hold cwd "$TOOLS/$D1/files"
tools install
[ "$RC" = 0 ] && [ "$OUT" = "$TOOL" ] && [ "$(tag_of "$TOOL")" = "$R2" ] && [ "$(vdf_strings "$TOOL")" = "$VDF_OURS" ] \
  && ok "the one-name folder is installed" || bad "rc=$RC out=$OUT err=$ERR"
[ ! -e "$TOOLS/$D0" ] && grep -q "removing $D0, of the earlier per-release scheme" <<<"$ERR" && ok "an earlier folder goes once it is in" || bad "$(ls -A "$TOOLS") err=$ERR"
[ -x "$TOOLS/$D1/proton" ] && grep -q "keeping $D1, of the earlier per-release scheme, while something runs from it" <<<"$ERR" \
  && ok "one a process works in stays" || bad "$(ls -A "$TOOLS") err=$ERR"
grep -q PROTON_LOG "$TOOL/user_settings.py" && ok "the player's user_settings.py from an earlier folder came along" || bad "settings: $(cat "$TOOL/user_settings.py" 2>&1)"
release
tools install
[ "$RC" = 0 ] && [ "$(ls -A "$TOOLS")" = "$STABLE" ] && grep -q "removing $D1" <<<"$ERR" && ok "and goes at the next run" || bad "rc=$RC $(ls -A "$TOOLS") err=$ERR"
rm -f "$TOOL/user_settings.py"; tools install

CASE="helper: a tag in the pin"
releases <<EOF
$R3 2026-12-15T00:00:00Z $D3
$R2 2026-11-05T00:00:00Z $D2 badsidecar
$R1 2026-10-04T21:30:56Z $D1
EOF
mkpin "$R1"
tools install
[ "$RC" = 0 ] && [ "$(tag_of "$TOOL")" = "$R1" ] && grep -q v1 "$TOOL/proton" && [ "$(vdf_strings "$TOOL")" = "$VDF_OURS" ] \
  && ok "installs that release, under the same name, though the channel has newer" || bad "rc=$RC tag=$(tag_of "$TOOL") err=$ERR"
[ "$REQS" = "/repos/CachyOS/proton-cachyos/releases/tags/$R1" ] && ok "asking GitHub for it alone" || bad "requests: $REQS"
echo 500 >"$API/status"
tools install
[ "$RC" = 0 ] && [ "$(asked)" = 0 ] && [ -z "$ERR" ] && ok "once it is in, asks nothing" || bad "rc=$RC requests=$REQS err=$ERR"
rm -f "$API/status"
mkpin "$R2" "$(printf '0%.0s' {1..128})"
tools install
[ "$RC" = 1 ] && grep -q "sha512 mismatch" <<<"$ERR" && [ "$(tag_of "$TOOL")" = "$R1" ] && ok "with a sha512 the tarball does not have: refused" || bad "rc=$RC err=$ERR"
mkpin "$R2" "$(digest sha512 "$DL/$D2.tar.xz")"
tools install
[ "$RC" = 0 ] && [ "$(tag_of "$TOOL")" = "$R2" ] && ok "with its sha512: installed, its own (bad) .sha512sum not used" || bad "rc=$RC err=$ERR"
mkpin cachyos-11.0-20990101-slr
tools install
[ "$RC" = 0 ] && grep -q "answered 404" <<<"$ERR" && [ "$(tag_of "$TOOL")" = "$R2" ] && ok "a tag GitHub does not have: the installed release stays" || bad "rc=$RC err=$ERR"
mkpin
printf 'name: proton-cachyos-arm64\n' >"$T/bad.pin"
OUT="$(RETROFORGE_STEAM_ROOT="$SROOT" RETROFORGE_STEAM_COMPAT_PIN="$T/bad.pin" python3 "$HELPER" install 2>&1)"; RC=$?
[ "$RC" = 1 ] && grep -q "needs name, releases, asset, dir, display_name" <<<"$OUT" && ok "a pin without the channel's fields: exit 1" || bad "rc=$RC out=$OUT"

CASE="helper: a killed run"
mkdir -p "$SROOT/.retroforge-compat-tools-dead/tree/$D3"; echo x >"$SROOT/.retroforge-compat-tools-dead/tool.tar.xz"
tools install
[ "$RC" = 0 ] && [ -z "$(leftovers)" ] && [ "$(tag_of "$TOOL")" = "$R3" ] && ok "what it left is swept on the next run" || bad "rc=$RC left: $(leftovers) err=$ERR"

CASE="helper: our folder, broken"
rm -f "$TOOL/proton"
tools install
[ "$RC" = 0 ] && [ -x "$TOOL/proton" ] && grep -q v3 "$TOOL/proton" && ok "a folder of ours without proton is installed again" || bad "rc=$RC err=$ERR"

CASE="helper: the tool's name is the player's"
rm -rf "$TOOL"; mkdir -p "$TOOL"; echo player >"$TOOL/proton"
tools install
[ "$RC" = 0 ] && [ "$OUT" = "$TOOL" ] && [ "$(cat "$TOOL/proton")" = player ] \
  && [ ! -e "$TOOL/.retroforge-pin" ] && [ ! -e "$TOOL/user_settings.py" ] && [ "$(asked)" = 0 ] \
  && grep -q "not installed by RetroForge" <<<"$ERR" && ok "left alone, nothing asked or downloaded, and said so" || bad "rc=$RC out=$OUT err=$ERR"
rm -rf "$TOOL"

CASE="helper: tarball without its folder"
mktool "$DX" vx no-dir
releases <<EOF
$RX 2026-12-31T00:00:00Z $DX
EOF
tools install
[ "$RC" = 1 ] && grep -q "has no $DX/" <<<"$ERR" && [ ! -e "$TOOL" ] && [ ! -e "$TOOLS/$DX-renamed" ] && [ -z "$(leftovers)" ] \
  && ok "refused, nothing installed or left" || bad "rc=$RC err=$ERR $(ls -A "$TOOLS")"

CASE="helper: tarball without proton"
mktool "$DX" vx no-proton; releases <<<"$RX 2026-12-31T00:00:00Z $DX"
tools install
[ "$RC" = 1 ] && [ ! -e "$TOOL" ] && ok "refused, nothing installed" || bad "rc=$RC err=$ERR"

CASE="helper: a compatibilitytool.vdf it cannot rename"
mktool "$DX" vx bad-vdf; releases <<<"$RX 2026-12-31T00:00:00Z $DX"
tools install
[ "$RC" = 1 ] && grep -q "could not name $DX's compatibilitytool.vdf $STABLE" <<<"$ERR" && [ ! -e "$TOOL" ] && [ -z "$(leftovers)" ] \
  && ok "two tools in it: refused, nothing installed" || bad "rc=$RC err=$ERR"

CASE="helper: another run holds the lock"
releases <<<"$R3 2026-12-15T00:00:00Z $D3"
python3 -c 'import fcntl, sys, time
f = open(sys.argv[1], "w"); fcntl.flock(f, fcntl.LOCK_EX); open(sys.argv[2], "w").close(); time.sleep(60)' \
  "$SROOT/.retroforge-compat-tools.lock" "$T/locked" &
HOLDER=$!
for _ in $(seq 50); do [ -e "$T/locked" ] && break; sleep 0.1; done
tools install
[ "$RC" = 0 ] && [ -z "$OUT" ] && [ ! -e "$TOOL" ] && [ "$(asked)" = 0 ] && grep -q "already running" <<<"$ERR" \
  && ok "exits at once, asks and installs nothing" || bad "rc=$RC out=$OUT err=$ERR"
release
tools install
[ "$RC" = 0 ] && [ -x "$TOOL/proton" ] && ok "and the next run installs" || bad "rc=$RC err=$ERR"
rm -rf "$TOOL"
python3 -c 'import fcntl, sys, time
f = open(sys.argv[1], "w"); fcntl.flock(f, fcntl.LOCK_EX); open(sys.argv[2], "w").close(); time.sleep(2)' \
  "$SROOT/.retroforge-compat-tools.lock" "$T/locked2" &
HOLDER2=$!
for _ in $(seq 50); do [ -e "$T/locked2" ] && break; sleep 0.1; done
start=$SECONDS; tools install --wait
[ "$RC" = 0 ] && [ "$OUT" = "$TOOL" ] && [ -x "$TOOL/proton" ] && [ $((SECONDS - start)) -ge 1 ] && grep -q "waiting for it" <<<"$ERR" \
  && ok "--wait (the store, retroforge-proton): waits for that run, then installs and names the folder" || bad "rc=$RC out=$OUT err=$ERR"
wait "$HOLDER2" 2>/dev/null

CASE="helper: offline on a fresh image"
rm -rf "$SROOT"
mkpin "" "" "http://127.0.0.1:1/repos/CachyOS/proton-cachyos/releases"
tools install
[ "$RC" = 1 ] && [ -z "$OUT" ] && grep -q "could not ask GitHub's API.*no proton-cachyos-arm64 is installed" <<<"$ERR" && [ -z "$(ls -A "$TOOLS")" ] \
  && ok "exit 1, says what it could not ask, no tool" || bad "rc=$RC out=$OUT err=$ERR"
mkpin

CASE="helper: bad arguments"
tools
[ "$RC" = 2 ] && grep -q usage <<<"$ERR" && ok "no mode: exit 2 with the usage" || bad "rc=$RC err=$ERR"
tools --sarek
[ "$RC" = 2 ] && ok "an unknown mode: exit 2" || bad "rc=$RC err=$ERR"
for verb in on off sarek; do
  tools "$verb"
  [ "$RC" = 2 ] && ok "$verb (gone with the DXVK-Sarek setting): exit 2" || bad "$verb: rc=$RC err=$ERR"
done

# ================================================================================================
# Which GPUs need Sarek: device-env's SoC class.
cat >"$T/device-env" <<EOF
#!/usr/bin/env bash
printf 'RETROFORGE_DEVICE_ID=%q\nRETROFORGE_SOC_CLASS=%q\n' test "\$(cat "$T/soc")"
EOF
chmod +x "$T/device-env"
needs() {  # needs <SoC class> [VAR=value...]: what needs_sarek() answers there
  echo "$1" >"$T/soc"
  env -u RETROFORGE_STEAM_SAREK RETROFORGE_DEVICE_ENV="$T/device-env" "${@:2}" python3 -I -c '
import importlib.machinery, importlib.util, sys
loader = importlib.machinery.SourceFileLoader("helper", sys.argv[1])
m = importlib.util.module_from_spec(importlib.util.spec_from_loader("helper", loader))
loader.exec_module(m)
print("on" if m.needs_sarek() else "off")' "$HELPER"
}
CASE="which GPUs need Sarek"
[ "$(needs SM6115)" = on ] && [ "$(needs SM4450)" = on ] && ok "the Adreno 610 (SM6115) and 613 (SM4450)" || bad "SM6115=$(needs SM6115) SM4450=$(needs SM4450)"
[ "$(needs SM8250)" = off ] && [ "$(needs SM8550)" = off ] && [ "$(needs SM8650)" = off ] && ok "not the A650, A740, A750" || bad "SM8250=$(needs SM8250)"
[ "$(needs "")" = off ] && ok "not an unknown board" || bad "unknown=$(needs "")"
[ "$(needs SM6115 RETROFORGE_DEVICE_ENV="$T/missing")" = off ] && ok "not when device-env cannot run" || bad "no device-env: on"
[ "$(needs SM8250 RETROFORGE_STEAM_SAREK=on)" = on ] && [ "$(needs SM6115 RETROFORGE_STEAM_SAREK=off)" = off ] \
  && [ "$(needs SM6115 RETROFORGE_STEAM_SAREK=maybe)" = on ] && ok "RETROFORGE_STEAM_SAREK=on|off overrides it, anything else does not" || bad "override"

# ================================================================================================
# ARMv8.0: proton-cachyos-armv8.pin (retroforge-linux/proton-cachyos-armv8), taken when /proc/cpuinfo
# has no `atomics`: .tar.zst assets with a <asset>.sha512 sidecar. The Valve-based ARMv8.0 builds offered
# before (proton-armv8, proton-armv8-experimental) are removed once it is in place.
PIN8_REAL="$ROOT/rootfs/overlay/usr/share/retroforge/steam/proton-cachyos-armv8.pin"
CASE="armv8: the real pin"
python3 - "$PIN8_REAL" <<'PY' && ok "proton-cachyos-armv8's API, its .tar.zst with .sha512, one folder" || bad "proton-cachyos-armv8.pin is not that"
import re, sys
f = dict(re.findall(r"^(\w+):[ \t]*(.*?)[ \t]*$", open(sys.argv[1]).read(), re.M))
assert f["name"] == "proton-cachyos-armv8", f
assert f["releases"] == "https://api.github.com/repos/retroforge-linux/proton-cachyos-armv8/releases", f
assert f["asset"] == "proton-cachyos-*-slr-armv8.tar.zst" and f["sidecar"] == ".sha512", f
assert f["dir"] == "proton-cachyos-armv8-retroforge" and "tag" not in f and "prereleases" not in f, f
PY
[ ! -e "$ROOT/rootfs/overlay/usr/share/retroforge/steam/proton-armv8.pin" ] \
  && [ ! -e "$ROOT/rootfs/overlay/usr/share/retroforge/steam/proton-armv8-experimental.pin" ] \
  && ok "the Valve-based ARMv8.0 pins are gone" || bad "proton-armv8*.pin still there"

S8="$T/home8/.local/share/Steam"; TOOLS8="$S8/compatibilitytools.d"; DIR8=proton-cachyos-armv8-retroforge
PINS8="$T/pins8"; mkdir -p "$PINS8"
{ printf 'name: proton-cachyos-armv8\nreleases: %s\nasset: proton-cachyos-*-slr-armv8.tar.zst\nsidecar: .sha512\n' "$RELEASES"
  printf 'dir: %s\ndisplay_name: Proton-CachyOS ARMv8.0 (RetroForge)\n' "$DIR8"; } >"$PINS8/proton-cachyos-armv8.pin"
mkpin; cp "$PIN" "$PINS8/proton-cachyos-arm64.pin"
printf 'processor\t: 0\nFeatures\t: fp asimd evtstrm aes pmull sha1 sha2 crc32 cpuid\n' >"$T/cpuinfo-v80"
printf 'processor\t: 0\nFeatures\t: fp asimd evtstrm aes pmull sha1 sha2 crc32 atomics fphp asimdhp cpuid\n' >"$T/cpuinfo-v82"

mktool8() {  # mktool8 <top> <marker>: $DL/<top>.tar.zst
  mktool "$1" "$2" &&
    python3 -c 'import lzma, sys; open(sys.argv[2], "wb").write(lzma.open(sys.argv[1]).read())' "$DL/$1.tar.xz" "$DL/$1.tar" &&
    rm -f "$DL/$1.tar.xz" && zstd -q -f --rm "$DL/$1.tar" -o "$DL/$1.tar.zst"
}
cat >"$T/releases8.py" <<'PY'
import hashlib, json, os, sys
dl, out = sys.argv[1:3]
rels = []
for line in sys.stdin:
    if not line.strip():
        continue
    tag, published, top, *flags = line.split()
    path = os.path.join(dl, top + ".tar.zst")
    data = open(path, "rb").read()
    with open(path + ".sha512", "w") as f:
        f.write(("0" * 128 if "badsidecar" in flags else hashlib.sha512(data).hexdigest()) + f"  {top}.tar.zst\n")
    rels.append({"tag_name": tag, "published_at": published, "draft": False, "prerelease": "prerelease" in flags,
                 "assets": [{"name": top + ".tar.zst", "state": "uploaded", "browser_download_url": "file://" + path,
                             "digest": "sha256:" + hashlib.sha256(data).hexdigest()},
                            {"name": top + ".tar.zst.sha512", "state": "uploaded",
                             "browser_download_url": "file://" + path + ".sha512"}]})
json.dump(rels, open(out, "w"), indent=1)
PY
releases8() { python3 "$T/releases8.py" "$DL" "$API/releases.json"; }
tools8() {  # tools8 <cpuinfo> <pin|-> <args>: the helper against $S8, its pin chosen by the CPU unless given
  local pin=()
  [ "$2" != - ] && pin=(RETROFORGE_STEAM_COMPAT_PIN="$2")
  : >"$API/requests.log"
  OUT="$("${NOPROXY[@]}" HOME="$T/home8" RETROFORGE_STEAM_ROOT="$S8" RETROFORGE_STEAM_PINS="$PINS8" \
         RETROFORGE_DEVICE_ENV="$T/no-device-env" RETROFORGE_STEAM_SAREK="${SAREK:-on}" \
         RETROFORGE_CPUINFO="$1" "${pin[@]}" python3 "$HELPER" "${@:3}" 2>"$T/err")"; RC=$?
  ERR="$(cat "$T/err")"
}
# Releases as retroforge-linux/proton-cachyos-armv8 publishes them: <CachyOS tag>-armv8, asset proton-<that>.tar.zst.
A8=cachyos-11.0-20261015-slr-armv8; B8=cachyos-11.0-20261005-slr-armv8; P8=cachyos-11.0-20261101-slr-armv8
for t in "$A8" "$B8" "$P8"; do mktool8 "proton-$t" "armv8 $t"; done
releases8 <<EOF
$P8 2026-11-01T12:00:00Z proton-$P8 prerelease
$A8 2026-10-20T22:00:00Z proton-$A8
$B8 2026-10-05T12:00:00Z proton-$B8
EOF

CASE="armv8: an ARMv8.0 CPU"
tools8 "$T/cpuinfo-v80" - install
[ "$RC" = 0 ] && [ "$OUT" = "$TOOLS8/$DIR8" ] && [ "$(tag_of "$TOOLS8/$DIR8")" = "$A8" ] \
  && ok "proton-cachyos-armv8.pin: the newest release's .tar.zst (no prerelease), checked by its .sha512" || bad "rc=$RC out=$OUT err=$ERR"
grep -q "armv8 $A8" "$TOOLS8/$DIR8/proton" && [ -L "$TOOLS8/$DIR8/files/lib/libfoo.so" ] \
  && ok "unpacked whole, symlinks kept" || bad "$(ls -la "$TOOLS8/$DIR8" 2>&1 | head -5)"
[ "$(vdf_strings "$TOOLS8/$DIR8")" = "compatibilitytools|compat_tools|$DIR8|install_path|.|display_name|Proton-CachyOS ARMv8.0 (RetroForge)|from_oslist|windows|to_oslist|linux" ] \
  && ok "named $DIR8 for Steam" || bad "$(vdf_strings "$TOOLS8/$DIR8")"
[ "$(settings "$TOOLS8/$DIR8")" = '{"PROTON_DXVK_SAREK": "1"}' ] && ok "DXVK-Sarek on in it" || bad "$(settings "$TOOLS8/$DIR8" 2>&1)"

CASE="armv8: a CPU with atomics"
rm -rf "$T/home8"
tools8 "$T/cpuinfo-v82" - install
[ "$RC" = 1 ] && grep -q "proton-cachyos-\*-slr-arm64.tar.xz" <<<"$ERR" && [ ! -e "$TOOLS8/$DIR8" ] \
  && ok "keeps proton-cachyos-arm64.pin" || bad "rc=$RC err=$ERR"

CASE="armv8: the Valve-based builds go"
oldtool() {  # oldtool <dir> <pin name>: a folder steam-compat-tools installed for that pin
  mkdir -p "$TOOLS8/$1" && touch "$TOOLS8/$1/proton" && printf 'name: %s\ntag: armv8-x\n' "$2" >"$TOOLS8/$1/.retroforge-pin"
}
rm -rf "$T/home8"
oldtool proton-armv8-retroforge proton-armv8
oldtool proton-armv8-experimental-retroforge proton-armv8-experimental
mkdir -p "$TOOLS8/proton-armv8-mine"; touch "$TOOLS8/proton-armv8-mine/proton"   # the player's: no marker
tools8 "$T/cpuinfo-v80" - install
[ "$RC" = 0 ] && [ "$(tag_of "$TOOLS8/$DIR8")" = "$A8" ] && [ ! -e "$TOOLS8/proton-armv8-retroforge" ] \
  && [ ! -e "$TOOLS8/proton-armv8-experimental-retroforge" ] && grep -q "removing proton-armv8-retroforge" <<<"$ERR" \
  && ok "both removed once the new tool is in" || bad "rc=$RC err=$ERR $(ls "$TOOLS8")"
[ -e "$TOOLS8/proton-armv8-mine/proton" ] && ok "a folder RetroForge did not install stays" || bad "$(ls "$TOOLS8")"

CASE="armv8: a bad .sha512"
rm -rf "$T/home8"
oldtool proton-armv8-retroforge proton-armv8
releases8 <<EOF
$A8 2026-10-20T22:00:00Z proton-$A8 badsidecar
EOF
tools8 "$T/cpuinfo-v80" - install
[ "$RC" = 1 ] && grep -q "sha512 mismatch" <<<"$ERR" && [ ! -e "$TOOLS8/$DIR8" ] && [ -z "$(find "$S8" -maxdepth 1 -name '.retroforge-compat-tools-*')" ] \
  && ok "refused, nothing installed, nothing left" || bad "rc=$RC err=$ERR"
[ -e "$TOOLS8/proton-armv8-retroforge/proton" ] && ok "the old build stays while the new one is not in" || bad "$(ls "$TOOLS8")"

CASE="armv8: a GPU without the need"
rm -rf "$T/home8"
releases8 <<EOF
$A8 2026-10-20T22:00:00Z proton-$A8
EOF
tools8 "$T/cpuinfo-v80" - install
mkdir -p "$TOOLS8/$STABLE"
printf 'name: proton-cachyos-arm64\ntag: %s\n' "$R1" >"$TOOLS8/$STABLE/.retroforge-pin"
cp "$TOOLS8/$DIR8/user_settings.py" "$TOOLS8/$STABLE/user_settings.py"
SAREK=off tools8 "$T/cpuinfo-v80" - install
[ "$RC" = 0 ] && [ ! -e "$TOOLS8/$DIR8/user_settings.py" ] && [ ! -e "$TOOLS8/$STABLE/user_settings.py" ] && [ -e "$TOOLS8/$DIR8/proton" ] \
  && ok "Sarek off in it and in a Proton-CachyOS left on the device; the tools stay" || bad "rc=$RC err=$ERR"

# ================================================================================================
# install (what Apps > Proton's Download runs), status, and retroforge-proton.
PROGRESS="$T/home/.local/share/retroforge/steam-compat-tools.progress"
CASE="helper: progress"
rm -rf "$SROOT"; mkdir -p "${PROGRESS%/*}"
echo 42 >"$PROGRESS"   # a killed run's
releases <<EOF
$R1 2026-10-04T21:30:56Z $D1
EOF
mkpin
SEEN="$("${NOPROXY[@]}" HOME="$T/home" RETROFORGE_STEAM_ROOT="$SROOT" RETROFORGE_STEAM_COMPAT_PIN="$PIN" RETROFORGE_STEAM_SAREK=off \
        python3 -I -c '
import importlib.machinery, importlib.util, sys
loader = importlib.machinery.SourceFileLoader("helper", sys.argv[1])
m = importlib.util.module_from_spec(importlib.util.spec_from_loader("helper", loader))
loader.exec_module(m)
seen, write = [], m.progress
def progress(value):
    seen.append(str(value)); write(value)
m.progress = progress
rc = m.main(["steam-compat-tools", "install"])
print(rc, " ".join(seen))' "$HELPER" 2>"$T/err")"
ERR="$(cat "$T/err")"; SEEN="${SEEN##*$'\n'}"   # after the tool's folder, on the helper's stdout
[ "${SEEN%% *}" = 0 ] && [ -x "$TOOL/proton" ] && [ "$(tag_of "$TOOL")" = "$R1" ] && [ ! -e "$TOOL/user_settings.py" ] \
  && ok "installs the newest release; no user_settings.py on a GPU without the need" || bad "seen=$SEEN err=$ERR"
grep -qE '^0 0( [0-9]+)* 100 unpacking$' <<<"$SEEN" && ok "0, percentages, 100, then unpacking" || bad "progress: $SEEN"
[ ! -e "$PROGRESS" ] && ok "the progress file is gone once it ends (a stale one too)" || bad "left: $(cat "$PROGRESS")"

CASE="helper: the old toggle's user_settings.py"
legacy() {  # legacy <file>: what the DXVK-Sarek toggle's releases wrote
  python3 -I -c '
import importlib.machinery, importlib.util, sys
loader = importlib.machinery.SourceFileLoader("helper", sys.argv[1])
m = importlib.util.module_from_spec(importlib.util.spec_from_loader("helper", loader))
loader.exec_module(m)
open(sys.argv[2], "w").write(m.LEGACY_SETTINGS[0])' "$HELPER" "$1"
  grep -q "Settings > General" "$1" || bad "the old text is not the toggle's"
}
legacy "$TOOL/user_settings.py"
tools install
[ "$RC" = 0 ] && ! grep -q "Settings > General" "$TOOL/user_settings.py" && [ "$(settings "$TOOL")" = '{"PROTON_DXVK_SAREK": "1"}' ] \
  && ok "a GPU that needs Sarek: ours, rewritten in today's text" || bad "rc=$RC err=$ERR $(cat "$TOOL/user_settings.py")"
legacy "$TOOL/user_settings.py"
SAREK=off tools install
[ "$RC" = 0 ] && [ ! -e "$TOOL/user_settings.py" ] && ok "one without the need: ours, deleted" || bad "rc=$RC err=$ERR"

CASE="helper: an update"
tools install
mktool "$D2" v2
releases <<EOF
$R2 2026-11-05T12:00:00Z $D2
$R1 2026-10-04T21:30:56Z $D1
EOF
tools install
[ "$RC" = 0 ] && [ "$(tag_of "$TOOL")" = "$R2" ] && [ "$(settings "$TOOL")" = '{"PROTON_DXVK_SAREK": "1"}' ] \
  && ok "keeps Sarek on in the new tree" || bad "rc=$RC err=$ERR"

CASE="helper: another run going"
exec 9>"$SROOT/.retroforge-compat-tools.lock"; flock 9
echo 7 >"$PROGRESS"
tools install
[ "$RC" = 0 ] && [ -z "$OUT" ] && [ "$(cat "$PROGRESS")" = 7 ] && ok "exits at once and leaves that run's progress alone" || bad "rc=$RC out=$OUT progress=$(cat "$PROGRESS" 2>&1)"
exec 9>&-; rm -f "$PROGRESS"
rm -f "$TOOL/user_settings.py"

CCLI="$ROOT/rootfs/overlay/usr/bin/retroforge-proton"
C="$T/c"; mkdir -p "$C/bin"
cat >"$C/bin/systemctl" <<EOF
#!/usr/bin/env bash
echo "\$*" >>"$C/systemctl.calls"
case "\$*" in
  "--user show-environment") exit "\$(cat "$C/manager")" ;;
  "--user is-active --quiet retroforge-steam-compat-tools.service")
    n=\$(cat "$C/active"); [ "\$n" -gt 0 ] || exit 3; echo \$((n - 1)) >"$C/active"; exit 0 ;;
esac
exit 1
EOF
cat >"$C/bin/systemd-run" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$@" >"$C/systemd-run.args"
exec "\${@: -3}"  # <helper> install --wait
EOF
chmod +x "$C/bin/systemctl" "$C/bin/systemd-run"
proton() {  # proton <user manager: 0 yes, 1 no> <args>: retroforge-proton with the test's pin (a CPU with atomics)
  rm -f "$C/systemctl.calls" "$C/systemd-run.args"; echo "$1" >"$C/manager"; echo "${ACTIVE:-0}" >"$C/active"
  COUT="$("${NOPROXY[@]}" -u XDG_DATA_HOME -u RETROFORGE_STEAM_ROOT HOME="$T/home" PATH="$C/bin:$PATH" \
          RETROFORGE_CPUINFO="$T/cpuinfo-v82" RETROFORGE_STEAM_COMPAT_TOOLS="$HELPER" \
          RETROFORGE_STEAM_COMPAT_PIN="$PIN" RETROFORGE_DEVICE_ENV="$T/no-device-env" bash "$CCLI" "${@:2}" 2>"$T/cerr")"; CRC=$?
  CERR="$(cat "$T/cerr")"
}
field() { python3 -c 'import json, sys; v = json.loads(sys.argv[1]).get(sys.argv[2]); print("null" if v is None else str(v).lower() if isinstance(v, bool) else v)' "$1" "$2" 2>/dev/null; }

CASE="proton: status"
proton 0 status
[ "$CRC" = 0 ] && [ "$(field "$COUT" installed)" = "$R2" ] && [ "$(field "$COUT" name)" = proton-cachyos-arm64 ] \
  && [ "$(field "$COUT" display_name)" = "$SHOWN" ] && [ "$(field "$COUT" armv8)" = false ] \
  && ok "the tool, its name and the installed release, as JSON" || bad "rc=$CRC out=$COUT err=$CERR"
rm -rf "$SROOT"
proton 0 status
[ "$(field "$COUT" installed)" = null ] && ok "installed null on a fresh image" || bad "out=$COUT"
mkdir -p "$TOOL"; touch "$TOOL/proton" "$TOOL/toolmanifest.vdf" "$TOOL/compatibilitytool.vdf"; printf 'tag: x\n' >"$TOOL/.retroforge-pin"
proton 0 status
[ "$(field "$COUT" installed)" = null ] && ok "installed null for a folder RetroForge did not install" || bad "out=$COUT"
rm -rf "$SROOT"
OUT8="$("${NOPROXY[@]}" HOME="$T/home8" RETROFORGE_STEAM_ROOT="$S8" RETROFORGE_STEAM_PINS="$PINS8" RETROFORGE_CPUINFO="$T/cpuinfo-v80" \
        RETROFORGE_STEAM_COMPAT_TOOLS="$HELPER" bash "$CCLI" status 2>&1)"
[ "$(field "$OUT8" name)" = proton-cachyos-armv8 ] && [ "$(field "$OUT8" armv8)" = true ] && [ "$(field "$OUT8" installed)" = "$A8" ] \
  && ok "an ARMv8.0 CPU: Proton-CachyOS ARMv8.0, armv8 true" || bad "out=$OUT8"
python3 - "$PIN_REAL" "$PIN8_REAL" "$HELPER" <<'PY' && ok "the real pins credit CachyOS and retroforge-linux, with their GitHub pages" || bad "author/homepage from the real pins"
import importlib.machinery, importlib.util, os, sys
os.environ["RETROFORGE_STEAM_ROOT"] = "/nonexistent"
loader = importlib.machinery.SourceFileLoader("helper", sys.argv[3])
m = importlib.util.module_from_spec(importlib.util.spec_from_loader("helper", loader))
loader.exec_module(m)
for pin, author, home in ((sys.argv[1], "CachyOS", "https://github.com/CachyOS/proton-cachyos"),
                          (sys.argv[2], "retroforge-linux", "https://github.com/retroforge-linux/proton-cachyos-armv8")):
    m.PIN = pin
    st = m.status(m.read_pin())
    assert (st["author"], st["homepage"], st["installed"]) == (author, home, None), st
PY

CASE="proton: install, with a user manager"
ACTIVE=1 proton 0 install
[ "$CRC" = 0 ] && [ "$(tag_of "$TOOL")" = "$R2" ] && [ ! -e "$TOOL/user_settings.py" ] \
  && ok "installs it (no Sarek: no device-env here)" || bad "rc=$CRC err=$CERR"
grep -qx -- --wait "$C/systemd-run.args" && grep -qx -- --unit=retroforge-steam-compat-tools "$C/systemd-run.args" \
  && grep -qx -- "--setenv=RETROFORGE_STEAM_ROOT=$SROOT" "$C/systemd-run.args" \
  && [ "$(tail -2 "$C/systemd-run.args" | tr '\n' ' ')" = "install --wait " ] && ok "as the user unit, waited for, the helper waiting for any other run" || bad "$(cat "$C/systemd-run.args" 2>&1)"
[ "$(grep -c is-active "$C/systemctl.calls")" = 2 ] && ok "after the unit's run already going" || bad "$(cat "$C/systemctl.calls")"

CASE="proton: install, no user manager"
rm -rf "$SROOT"
proton 1 install
[ "$CRC" = 0 ] && [ -x "$TOOL/proton" ] && [ ! -e "$C/systemd-run.args" ] && ok "in the foreground" || bad "rc=$CRC err=$CERR"

CASE="proton: install fails"
rm -rf "$SROOT"
mkpin "" "" "http://127.0.0.1:1/repos/CachyOS/proton-cachyos/releases"
proton 0 install
[ "$CRC" = 1 ] && grep -q "^steam-compat-tools: could not ask GitHub's API" <<<"$CERR" && ok "exit 1, the helper's last log line on stderr" || bad "rc=$CRC err=$CERR"
mkpin

CASE="proton: bad invocation"
proton 0
[ "$CRC" = 2 ] && grep -q usage <<<"$CERR" && [ ! -e "$C/systemd-run.args" ] && ok "no verb: exit 2 with the usage, nothing run" || bad "rc=$CRC err=$CERR"

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
