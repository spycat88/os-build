#!/usr/bin/env bash
# Offline test for /usr/bin/retroforge-scrape -- the ROM artwork scraper the RetroForge plugin drives
# (plan .claude/plans/scraper.plan.md, Phase 1).
#
#   tests/test-scrape.sh
#
# WHY THIS EXISTS. retroforge-scrape sends RetroForge's ScreenScraper developer password (and the
# player's own, when set) with every request, writes into the player's home, and spends a daily
# quota the player cannot reset. Each rule below is what keeps that safe, and none of it shows when
# a scrape simply works:
#
#   - the passwords never reach stdout, stderr or curl's argv (curl reads the URL from stdin);
#   - every transfer is https only, redirects included, and only to *.screenscraper.fr;
#   - a ROM is identified the way ScreenScraper matches best (CRC + MD5 up to 128 MiB, the single
#     file inside a zip, the first disc of an .m3u, name + size otherwise);
#   - art is picked by ES-next's fallback chains, then by region, at a server-side size (box: 450 high);
#   - quota and refusals stop the run with their own exit code, before more requests are wasted;
#   - a second run asks again only for what is missing; nothing half-written is left behind;
#   - stdout is a contract: `N%` lines then one JSON summary line, or the plugin misreads it.
#
# HOW: the shipped rootfs/overlay/usr/bin/retroforge-scrape runs with its environment seams
# (RETROFORGE_CURL, RETROFORGE_ROMS_DIR, RETROFORGE_MEDIA_DIR, RETROFORGE_SCRAPER_SYSTEMS, HOME,
# RETROFORGE_SS_DEVID/DEVPASSWORD) pointing into a sandbox; curl is a stub that plays ScreenScraper
# (answer shapes captured live on 2026-10-17) and logs every call. No network.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRAPE="$ROOT/rootfs/overlay/usr/bin/retroforge-scrape"
SYSTEMS="$ROOT/rootfs/overlay/usr/share/retroforge/scraper/systems.json"
LIBRARY="$ROOT/apps/ogui-retroforge-plugin/plugin/library_roms.gd"
[ -f "$SCRAPE" ] || { echo "no retroforge-scrape: $SCRAPE" >&2; exit 1; }

PASS=0; FAIL=0; CASE=""
ok()  { PASS=$((PASS+1)); printf '  ok   %s -- %s\n' "$CASE" "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s -- %s\n' "$CASE" "$1"; }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }  # check <what> <shell condition>

W="$(mktemp -d)" && [ -d "$W" ] || { echo "mktemp -d failed" >&2; exit 1; }
trap 'rm -rf "$W"' EXIT
mkdir -p "$W/bin" "$W/srv/games"
SRV="$W/srv"

# --- the fake ScreenScraper ------------------------------------------------------------------------
# Developer login dev / dev-secret, player login good / pw-secret. Routing:
#   jeuInfos.php      -> $SRV/games/crc-<CRC>.json when a crc is sent, else $SRV/games/name-<romnom>.json,
#                        else 404 with ScreenScraper's French text; $SRV/status (or status-once) forces
#                        a code, with $SRV/status-body as its text
#   ssuserInfos.php   -> 200 with an ssuser block for the good player, else 403 (user login text)
#   mediaJeu.php      -> PNG / JPEG magic, then "IMG <media> <size asked>" (fanart is the JPEG); the
#                        size is maxwidth, or h<maxheight>;
#                        $SRV/badmedia-<media> serves text/html "NOMEDIA" instead, $SRV/redirect-<media>
#                        reports a redirect that ended on https://evil.example/ (curl's url_effective)
#   $SRV/slow           -> every jeuInfos answer takes 5 s (to cancel a run mid-request)
#   $SRV/timeout-once   -> the next request fails as curl's timeout (exit 28), $SRV/timeout always;
#                        $SRV/timeout-media-once / timeout-media: the same for image downloads only
#   $SRV/games/<key>.json may hold any JSON, e.g. a list (an answer of the wrong shape)
# A wrong developer login gets 403 with the developer text. Every URL goes to $W/url.log, every
# argv to $W/argv.log, every jeuInfos query (as JSON) to $W/queries.log.
cat > "$W/bin/curl" <<EOF
#!/usr/bin/env python3
import json, os, sys, urllib.parse
W, SRV = "$W", "$SRV"
argv = sys.argv[1:]
with open(f"{W}/argv.log", "a") as f:
    f.write(" ".join(argv).replace("\n", "\\\\n") + "\n")
out, wfmt, url = None, "", None
i = 0
while i < len(argv):
    a = argv[i]
    if a in ("-o", "--output"): out = argv[i + 1]; i += 2; continue
    if a in ("-w", "--write-out"): wfmt = argv[i + 1]; i += 2; continue
    if a in ("-K", "--config") and argv[i + 1] == "-":
        for line in sys.stdin.read().splitlines():
            k, _, v = line.partition("=")
            if k.strip() == "url":
                url = v.strip().strip('"')
        i += 2; continue
    if a.startswith("http"): url = a
    i += 1
with open(f"{W}/url.log", "a") as f:
    f.write(f"{url}\n")
def has(flag, val):
    return any(argv[j] == flag and argv[j + 1] == val for j in range(len(argv) - 1))
if not (has("--proto", "=https") and has("--proto-redir", "=https")):
    sys.exit(99)
u = urllib.parse.urlsplit(url or "")
if u.scheme != "https":
    sys.exit(1)
if u.hostname not in ("api.screenscraper.fr", "neoclone.screenscraper.fr"):
    sys.exit(6)
if os.path.exists(f"{SRV}/timeout-once"):
    os.remove(f"{SRV}/timeout-once")
    sys.exit(28)
if os.path.exists(f"{SRV}/timeout"):
    sys.exit(28)
if u.path == "/api2/mediaJeu.php":
    if os.path.exists(f"{SRV}/timeout-media-once"):
        os.remove(f"{SRV}/timeout-media-once")
        sys.exit(28)
    if os.path.exists(f"{SRV}/timeout-media"):
        sys.exit(28)
q = dict(urllib.parse.parse_qsl(u.query))
code, ctype, body, retry, final = 200, "application/json; charset=utf-8", b"", "", url
def text(c, t):
    global code, body
    code, body = c, t.encode()
if q.get("devid") != "dev" or q.get("devpassword") != "dev-secret":
    text(403, "Erreur de login : Vérifier vos identifiants développeur !")
elif u.path == "/api2/jeuInfos.php":
    with open(f"{W}/queries.log", "a") as f:
        f.write(json.dumps(q, sort_keys=True) + "\n")
    if os.path.exists(f"{SRV}/slow"):
        import time; time.sleep(5)
    forced = next((p for p in ("status-once", "status") if os.path.exists(f"{SRV}/{p}")), None)
    if forced:
        c = int(open(f"{SRV}/{forced}").read().split()[0])
        text(c, open(f"{SRV}/status-body").read() if os.path.exists(f"{SRV}/status-body") else "Erreur")
        retry = "2" if c == 429 else ""
        if forced == "status-once":
            os.remove(f"{SRV}/status-once")
    else:
        key = f"crc-{q['crc']}" if q.get("crc") else f"name-{q.get('romnom', '')}"
        path = f"{SRV}/games/{key}.json"
        if os.path.exists(path):
            body = open(path, "rb").read()
        else:
            text(404, "Erreur : Rom/Iso/Dossier non trouvée !  ")
elif u.path == "/api2/ssuserInfos.php":
    if q.get("ssid") == "good" and q.get("sspassword") == "pw-secret":
        body = json.dumps({"header": {"success": "true"}, "response": {"ssuser": {
            "id": "good", "maxthreads": "2", "requeststoday": "5", "maxrequestsperday": "20000",
            "requestskotoday": "0", "maxrequestskoperday": "2000"}}}).encode()
    else:
        text(403, "Erreur de login : Vérifier les identifiants utilisateurs !")
elif u.path == "/api2/mediaJeu.php":
    media = q.get("media", "")
    if os.path.exists(f"{SRV}/redirect-{media}"):
        final = "https://evil.example/x.png"
    if os.path.exists(f"{SRV}/badmedia-{media}"):
        ctype, body = "text/html; charset=UTF-8", b"NOMEDIA"
    else:
        # Bytes start with the real format's magic; the label can lie (ScreenScraper sends resized
        # PNGs as image/jpeg, seen live 2026-10-17): $SRV/mislabel-<media> serves PNG bytes as jpeg.
        jpeg = media.startswith("fanart")
        ctype = "image/jpeg" if jpeg or os.path.exists(f"{SRV}/mislabel-{media}") else "image/png"
        magic = b"\xff\xd8\xff\xe0\n" if jpeg else b"\x89PNG\r\n\x1a\n"
        size = q["maxwidth"] if "maxwidth" in q else "h" + q.get("maxheight", "")
        body = magic + f"IMG {media} {size}".encode()
else:
    text(404, "?")
if out:
    try:
        with open(out, "wb") as f:
            f.write(body)
    except OSError:
        sys.exit(23)  # curl's "write error", as real curl on a name too long or a full disk
else:
    sys.stdout.buffer.write(body)
sys.stdout.write(wfmt.replace("%{http_code}", str(code)).replace("%{content_type}", ctype)
                 .replace("%header{retry-after}", retry).replace("%{url_effective}", final))
EOF
chmod +x "$W/bin/curl"

# mkgame <key> <jeuid> <media>...: a jeuInfos answer, media given as type:region ("-" = none) or
# evil:<url> (a box-2D entry pointing somewhere it must not be fetched from). Quota fields from
# REQ_TODAY / REQ_MAX (defaults 1 / 10000).
mkgame() {
  local key=$1 id=$2; shift 2
  python3 - "$SRV/games/$key.json" "$id" "${REQ_TODAY:-1}" "${REQ_MAX:-10000}" "$@" <<'PY'
import json, sys
path, gid, today, mx, specs = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5:]
base = ("https://neoclone.screenscraper.fr/api2/mediaJeu.php?devid=dev&devpassword=dev-secret"
        f"&softname=RetroForge&ssid=&sspassword=&systemeid=1&jeuid={gid}&media=")
medias = []
for s in specs:
    t, _, r = s.partition(":")
    if t == "evil":
        medias.append({"type": "box-2D", "parent": "jeu", "url": r, "region": "wor", "format": "png"})
        continue
    m = {"type": t, "parent": "jeu", "format": "jpg" if t == "fanart" else "png",
         "url": base + (f"{t}({r})" if r != "-" else t)}
    if r != "-":
        m["region"] = r
    medias.append(m)
json.dump({"header": {"success": "true", "error": ""}, "response": {
    "serveurs": {}, "ssuser": {"id": "", "maxthreads": "1", "requeststoday": today,
                               "maxrequestsperday": mx, "requestskotoday": "0",
                               "maxrequestskoperday": "1000"},
    "jeu": {"id": gid, "noms": [{"region": "wor", "text": "Game"}], "systeme": {"id": "1"},
            "medias": medias}}}, open(path, "w"))
PY
}

ROMS="$W/roms"; MEDIA="$W/media"; CARDS="$W/cards"
run() {  # run <args...> [< stdin]: sets OUT, ERR, RC
  OUT="$(HOME="$W/home" RETROFORGE_CURL="$W/bin/curl" RETROFORGE_ROMS_DIR="$ROMS" RETROFORGE_SD_MOUNTS="$CARDS" \
    RETROFORGE_MEDIA_DIR="$MEDIA" RETROFORGE_SCRAPER_SYSTEMS="$SYSTEMS" \
    RETROFORGE_SS_DEVID="${DEVID-dev}" RETROFORGE_SS_DEVPASSWORD="${DEVPW-dev-secret}" \
    RETROFORGE_SCRAPER_DEVID_FILE="$W/no-devid-file" \
    python3 "$SCRAPE" "$@" 2>"$W/err")"
  RC=$?
  ERR="$(cat "$W/err")"
}
reset() {
  rm -rf "$ROMS" "$MEDIA" "$CARDS" "$W/home" "$SRV/games" "$W"/*.log "$SRV"/status* "$SRV"/badmedia-* "$SRV"/mislabel-* "$SRV"/redirect-* "$SRV"/slow "$SRV"/timeout*
  mkdir -p "$ROMS" "$W/home" "$SRV/games"
}
rom() {  # rom <system>/<file> <content>
  mkdir -p "$ROMS/$(dirname "$1")"; printf '%s' "$2" > "$ROMS/$1"
}
crc() { python3 -c 'import sys,zlib; print("%08X" % (zlib.crc32(open(sys.argv[1],"rb").read()) & 0xffffffff))' "$1"; }
md5() { md5sum "$1" | cut -d' ' -f1 | tr a-f A-F; }
query() {  # query <n> <key>: field <key> of the n-th jeuInfos query (1-based)
  sed -n "${1}p" "$W/queries.log" | python3 -c 'import json,sys; print(json.load(sys.stdin).get(sys.argv[1], "<none>"))' "$2"
}
q() {  # q <romnom> <key>: field <key> of the first jeuInfos query for that romnom
  grep -F "\"romnom\": \"$1\"" "$W/queries.log" | head -n1 \
    | python3 -c 'import json,sys; print(json.load(sys.stdin).get(sys.argv[1], "<none>"))' "$2"
}
nqueries() { if [ -f "$W/queries.log" ]; then wc -l < "$W/queries.log"; else echo 0; fi; }
summary() {  # summary <key>: from the last stdout line
  tail -n1 <<<"$OUT" | python3 -c 'import json,sys; print(json.load(sys.stdin).get(sys.argv[1]))' "$1"
}
contract() {  # stdout: N% lines, never going down, ending at 100 when any, then one JSON object line
  python3 - "$OUT" <<'PY'
import json, re, sys
*pct, last = sys.argv[1].split("\n")
vals = [int(l[:-1]) for l in pct if re.fullmatch(r"\d+%", l)]
try:
    summary = json.loads(last)
except ValueError:
    sys.exit(1)
sys.exit(0 if len(vals) == len(pct) and vals == sorted(vals) and isinstance(summary, dict) else 1)
PY
}
secret_free() {  # no password in stdout, stderr, any curl argv, or any file but the player's conf
  ! grep -qE 'dev-secret|pw-secret' <<<"$OUT$ERR" && ! grep -qE 'dev-secret|pw-secret' "$W/argv.log" 2>/dev/null \
    && ! grep -rlE 'dev-secret|pw-secret' "$W/home" "$MEDIA" 2>/dev/null | grep -v '/.config/retroforge/scraper.conf$' | grep -q .
}

# =================================================================================================
CASE="systems table"
if python3 - "$SYSTEMS" "$LIBRARY" <<'PY'
import json, re, sys
table = json.load(open(sys.argv[1]))["systems"]
lib = {}
for line in open(sys.argv[2]):
    m = re.match(r'\t"([a-z0-9]+)": (\{.*\}),$', line)
    if m:
        d = json.loads(m.group(2))
        lib[m.group(1)] = {k: d[k] for k in ("exts", "dirs") if k in d}
lib.pop("ports", None)
mine = {k: {kk: v[kk] for kk in ("exts", "dirs") if kk in v} for k, v in table.items()}
if mine != lib:
    print(sorted(set(mine) ^ set(lib)), [k for k in mine if k in lib and mine[k] != lib[k]], file=sys.stderr)
    sys.exit(1)
sys.exit(0 if all(v["ss"] and all(isinstance(i, int) for i in v["ss"]) for v in table.values()) else 1)
PY
then ok "systems.json exts/dirs equal library_roms.gd SYSTEMS (ports excepted), ids set"
else bad "systems.json and library_roms.gd SYSTEMS differ"; fi

# =================================================================================================
CASE="bad invocations"
reset
run;                          check "no command: exit 2" '[ "$RC" = 2 ]'
run run --system nosuch;      check "unknown system: exit 2" '[ "$RC" = 2 ]'
run run --system ports;       check "ports are never scraped: exit 2" '[ "$RC" = 2 ]'
run run --rom /etc/passwd;    check "a ROM outside ~/roms: exit 2" '[ "$RC" = 2 ]'
run region mars;              check "unknown region: exit 2" '[ "$RC" = 2 ]'
check "nothing was asked of the network" '[ ! -f "$W/url.log" ]'

# =================================================================================================
CASE="developer credentials"
reset; rom md/a.md "aaaa"; mkgame "crc-$(crc "$ROMS/md/a.md")" 10 box-2D:us
DEVID="" DEVPW="" run run;  check "none in the build: exit 9, no request" '[ "$RC" = 9 ] && [ ! -f "$W/url.log" ]'
DEVPW="wrong" run run;      check "refused by ScreenScraper: exit 9" '[ "$RC" = 9 ]'
check "the refused password is not echoed" '! grep -q wrong <<<"$OUT$ERR"'

# =================================================================================================
CASE="identification"
reset
rom md/small.md "small cart";  mkgame "crc-$(crc "$ROMS/md/small.md")" 11 box-2D:us
mkdir -p "$ROMS/psx"; truncate -s 129M "$ROMS/psx/Big Game (USA).chd"
mkgame "name-Big Game (USA).chd" 12 box-2D:us
mkdir -p "$W/z" "$ROMS/snes"; printf 'snes rom bytes' > "$W/z/Game (USA).sfc"; printf 'read me' > "$W/z/readme.txt"
python3 - "$ROMS/snes/Game (USA).zip" "$W/z" <<'PY'
import os, sys, zipfile
with zipfile.ZipFile(sys.argv[1], "w") as z:
    for name in ("Game (USA).sfc", "readme.txt"):
        z.write(os.path.join(sys.argv[2], name), name)
PY
mkgame "crc-$(crc "$W/z/Game (USA).sfc")" 13 box-2D:us
rom gba/Packed.7z "7z bytes";  mkgame "name-Packed.7z" 14 box-2D:us
rom psx/disc1.cue "first disc"; rom psx/disc2.cue "second disc"
printf '# multi\ndisc1.cue\ndisc2.cue\n' > "$ROMS/psx/Multi.m3u"
mkgame "crc-$(crc "$ROMS/psx/disc1.cue")" 15 box-2D:us
mkdir -p "$ROMS/ps3/My PS3 Game/PS3_GAME/USRDIR"; : > "$ROMS/ps3/My PS3 Game/PS3_GAME/USRDIR/EBOOT.BIN"
mkgame "name-My PS3 Game" 16 box-2D:us
run run
check "exit 0 (rc $RC: $ERR)" '[ "$RC" = 0 ]'
check "small file: CRC + MD5 + size sent" '[ "$(q small.md crc)" = "$(crc "$ROMS/md/small.md")" ] && [ "$(q small.md md5)" = "$(md5 "$ROMS/md/small.md")" ] && [ "$(q small.md romtaille)" = 10 ]'
check "md is systemeid 1, romtype rom" '[ "$(q small.md systemeid)" = 1 ] && [ "$(q small.md romtype)" = rom ]'
check "over 128 MiB: name + size, no hash" '[ "$(q "Big Game (USA).chd" crc)" = "<none>" ] && [ "$(q "Big Game (USA).chd" md5)" = "<none>" ] && [ "$(q "Big Game (USA).chd" romtaille)" = $((129<<20)) ]'
check "zip with one game file (+ .txt): the inner file is hashed and named" '[ "$(q "Game (USA).sfc" crc)" = "$(crc "$W/z/Game (USA).sfc")" ] && [ "$(q "Game (USA).sfc" romtaille)" = 14 ]'
check "7z: name + size only" '[ "$(q Packed.7z crc)" = "<none>" ] && [ "$(q Packed.7z romtaille)" = 8 ]'
check "m3u: its first disc is what is asked" '[ "$(q disc1.cue crc)" = "$(crc "$ROMS/psx/disc1.cue")" ] && ! grep -q disc2 "$W/queries.log" && ! grep -q Multi.m3u "$W/queries.log"'
check "PS3 folder: by folder name, systemeid 59" '[ "$(q "My PS3 Game" systemeid)" = 59 ]'
check "every ROM got its box" '[ -f "$MEDIA/md/small.md-box.png" ] && [ -f "$MEDIA/psx/Big Game (USA).chd-box.png" ] && [ -f "$MEDIA/snes/Game (USA).zip-box.png" ] && [ -f "$MEDIA/gba/Packed.7z-box.png" ] && [ -f "$MEDIA/psx/Multi.m3u-box.png" ] && [ -f "$MEDIA/ps3/My PS3 Game-box.png" ]'
check "playlist members get no art of their own" '[ ! -e "$MEDIA/psx/disc1.cue-box.png" ]'
check "stdout contract" 'contract'
check "summary: 6 scraped" '[ "$(summary scraped)" = 6 ]'
check "no password anywhere" 'secret_free'
check "softname RetroForge, output json" '[ "$(query 1 softname)" = RetroForge ] && [ "$(query 1 output)" = json ]'

# =================================================================================================
CASE="art selection"
reset
rom md/"Euro (Europe).md" "euro";  mkgame "crc-$(crc "$ROMS/md/Euro (Europe).md")" 20 box-2D:jp box-2D:us box-2D:eu ss:wor fanart:- wheel:us
rom md/"Jap (Japan).md" "jap";     mkgame "crc-$(crc "$ROMS/md/Jap (Japan).md")" 21 box-2D:us box-2D:jp sstitle:wor wheel-hd:jp
rom md/"Usa (USA).md" "usa";       mkgame "crc-$(crc "$ROMS/md/Usa (USA).md")" 22 box-2D:jp box-3D:us screenmarqueesmall:wor
rom md/"Kr.md" "kr";               mkgame "crc-$(crc "$ROMS/md/Kr.md")" 23 box-2D:kr
run run
img() { tail -n1 "$MEDIA/md/$1" 2>/dev/null; }  # the text after the magic bytes
check "filename region wins: (Europe) -> box-2D(eu)" '[ "$(img "Euro (Europe).md-box.png")" = "IMG box-2D(eu) h450" ]'
check "(Japan) -> box-2D(jp)" '[ "$(img "Jap (Japan).md-box.png")" = "IMG box-2D(jp) h450" ]'
check "kind before region: a box-2D of another region beats a box-3D of ours" '[ "$(img "Usa (USA).md-box.png")" = "IMG box-2D(jp) h450" ]'
check "any region beats nothing: box-2D(kr)" '[ "$(img "Kr.md-box.png")" = "IMG box-2D(kr) h450" ]'
check "screen: ss" '[ "$(img "Euro (Europe).md-screen.png")" = "IMG ss(wor) 640" ]'
check "screen falls back to sstitle" '[ "$(img "Jap (Japan).md-screen.png")" = "IMG sstitle(wor) 640" ]'
check "fanart (no region) at 1280, as .jpg" '[ "$(img "Euro (Europe).md-fanart.jpg")" = "IMG fanart 1280" ]'
check "wheel" '[ "$(img "Euro (Europe).md-wheel.png")" = "IMG wheel(us) 640" ]'
check "wheel falls back to wheel-hd" '[ "$(img "Jap (Japan).md-wheel.png")" = "IMG wheel-hd(jp) 640" ]'
check "wheel falls back to screenmarqueesmall" '[ "$(img "Usa (USA).md-wheel.png")" = "IMG screenmarqueesmall(wor) 640" ]'
check "a kind the game lacks writes nothing" '[ ! -e "$MEDIA/md/Kr.md-screen.png" ] && [ ! -e "$MEDIA/md/Kr.md-fanart.jpg" ]'
check "no .part left" '! find "$MEDIA" -name "*.part" | grep -q .'

reset
rom md/b3d.md "b3d"; mkgame "crc-$(crc "$ROMS/md/b3d.md")" 24 box-3D:us
run run
check "no box-2D at all -> box-3D" '[ "$(tail -n1 "$MEDIA/md/b3d.md-box.png")" = "IMG box-3D(us) h450" ]'

reset
rom md/"P (Europe).md" "pref"; mkgame "crc-$(crc "$ROMS/md/P (Europe).md")" 25 box-2D:eu box-2D:jp
run region jp; check "region jp saved" '[ "$RC" = 0 ]'
run run
check "the player's region beats the filename's" '[ "$(tail -n1 "$MEDIA/md/P (Europe).md-box.png")" = "IMG box-2D(jp) h450" ]'

# =================================================================================================
CASE="media refused"
reset
rom md/e.md "evil"; mkgame "crc-$(crc "$ROMS/md/e.md")" 30 "evil:http://neoclone.screenscraper.fr/x.png" "evil:https://evil.example/x.png" \
  'evil:https://evil.example\.screenscraper.fr/x.png' "evil:https://u@neoclone.screenscraper.fr/x.png" \
  "evil:https://neoclone.screenscraper.fr.evil.example/x.png" "evil:https://[x/x.png" ss:wor wheel:us
touch "$SRV/badmedia-ss(wor)" "$SRV/redirect-wheel(us)"
rom md/m.md "mislabelled"; mkgame "crc-$(crc "$ROMS/md/m.md")" 31 box-2D:us
touch "$SRV/mislabel-box-2D(us)"
run run
check "exit 0" '[ "$RC" = 0 ]'
check "http media URL never fetched" '! grep -q "^http://" "$W/url.log"'
check "foreign host never fetched (also behind a backslash, user info, a suffix, a bad IPv6)" '! grep -qE "evil|@|\[" "$W/url.log"'
check "odd media URLs skip that image, not the run" '[ "$(summary scraped)" = 2 ] && [ "$(summary failed)" = 0 ]'
check "an image whose redirects end off ScreenScraper is dropped" '[ ! -e "$MEDIA/md/e.md-wheel.png" ]'
check "a non-image answer (NOMEDIA) is not written" '[ ! -e "$MEDIA/md/e.md-screen.png" ] && ! find "$MEDIA" -name "*.part" | grep -q .'
check "PNG bytes labelled image/jpeg are saved as .png" '[ -f "$MEDIA/md/m.md-box.png" ] && [ ! -e "$MEDIA/md/m.md-box.jpg" ]'
check "curl always runs https-only" '! grep -v -- "--proto =https" "$W/argv.log" | grep -q . && ! grep -v -- "--proto-redir =https" "$W/argv.log" | grep -q .'

# =================================================================================================
CASE="missing vs all"
reset
rom md/f.md "found"; mkgame "crc-$(crc "$ROMS/md/f.md")" 40 box-2D:us
rom md/n.md "not in db"
run run
check "first run: one found, one not found" '[ "$(summary scraped)" = 1 ] && [ "$(summary not_found)" = 1 ]'
rm -f "$W/queries.log"; run run
check "second run asks for nothing" '[ "$(nqueries)" = 0 ] && [ "$(summary skipped)" = 2 ]'
python3 - "$W/home/.cache/retroforge/scrape.json" <<'PY'
import json, sys
p = sys.argv[1]; c = json.load(open(p))
for v in c["roms"].values():
    if v.get("status") == "not_found":
        v["checked"] -= 8 * 86400
json.dump(c, open(p, "w"))
PY
rm -f "$W/queries.log"; run run
check "a not-found older than 7 days is asked again" '[ "$(nqueries)" = 1 ] && [ "$(query 1 romnom)" = n.md ]'
printf 'changed' > "$ROMS/md/f.md"; mkgame "crc-$(crc "$ROMS/md/f.md")" 41 box-2D:eu
rm -f "$W/queries.log"; run run
check "a changed file (size/mtime) is asked again" '[ "$(nqueries)" = 1 ] && [ "$(tail -n1 "$MEDIA/md/f.md-box.png")" = "IMG box-2D(eu) h450" ]'
rm -f "$MEDIA/md/f.md-box.png" "$W/queries.log"; run run
check "found but its art deleted: asked again" '[ "$(nqueries)" = 1 ]'
rm -f "$W/queries.log"; run run --all
check "--all asks for everything" '[ "$(nqueries)" = 2 ]'
rm -f "$W/queries.log"; run run --rom "$ROMS/md/f.md" --all
check "--rom asks for that ROM only" '[ "$(nqueries)" = 1 ] && [ "$(query 1 romnom)" = f.md ]'
rm -f "$W/queries.log"; run run --system snes
check "--system with no folder: nothing to do, exit 0" '[ "$RC" = 0 ] && [ "$(nqueries)" = 0 ] && contract'

# =================================================================================================
CASE="sd card"
# On an internal install a card's roms/<system>/ holds games too (rom_roots.gd): scraped into the same
# media folder, ports never read from a card, and a card without a roms folder ignored.
reset
rom md/f.md "found"; mkgame "crc-$(crc "$ROMS/md/f.md")" 40 box-2D:us
mkdir -p "$CARDS/GAMES/roms/md" "$CARDS/GAMES/roms/ports" "$CARDS/OTHER/md"
printf 'on card' > "$CARDS/GAMES/roms/md/c.md"; mkgame "crc-$(crc "$CARDS/GAMES/roms/md/c.md")" 42 box-2D:us
printf 'x' > "$CARDS/OTHER/md/o.md"
printf 'x' > "$CARDS/GAMES/roms/ports/p.sh"
run run
check "a card's ROM is scraped beside ~/roms" '[ "$(summary scraped)" = 2 ] && [ -f "$MEDIA/md/c.md-box.png" ]'
check "a card without a roms folder is not read" '! grep -q "o.md" "$W/queries.log"'
check "ports on a card are not read" '! grep -q "p.sh" "$W/queries.log"'
rm -f "$W/queries.log"; run run --rom "$CARDS/GAMES/roms/md/c.md" --all
check "--rom takes a card's ROM" '[ "$RC" = 0 ] && [ "$(nqueries)" = 1 ] && [ "$(query 1 romnom)" = c.md ]'
run run --rom "$CARDS/OTHER/md/o.md"
check "--rom refuses a card file outside its roms folder" '[ "$RC" = 2 ]'
rm -rf "$CARDS"; rm -f "$W/queries.log"; run run
check "the card pulled out: its art stays, nothing to ask" '[ "$RC" = 0 ] && [ "$(nqueries)" = 0 ] && [ -f "$MEDIA/md/c.md-box.png" ]'

# =================================================================================================
CASE="stopping"
stop_case() {  # stop_case <status> <body> <want rc> <what>
  reset; rom md/a.md "a"; rom md/b.md "b"
  printf '%s' "$1" > "$SRV/status"; printf '%s' "$2" > "$SRV/status-body"
  WANT=$3
  run run
  check "$4: exit $3 after one request" '[ "$RC" = "$WANT" ] && [ "$(nqueries)" = 1 ]'
  check "$4: summary still printed" 'contract'
}
stop_case 430 "Votre quota de scrape est dépassé pour aujourd'hui !" 6 "430 quota"
stop_case 431 "Nettoyer vos fichiers roms" 6 "431 too many not-found"
stop_case 423 "API totalement fermé" 8 "423 maintenance"
stop_case 426 "Le logiciel de scrape utilisé a été blacklisté" 8 "426 blacklisted"
stop_case 401 "API fermé pour les non membres" 8 "401 closed to non-members"
stop_case 500 "boom" 3 "500"

reset; rom md/a.md "a"; mkgame "crc-$(crc "$ROMS/md/a.md")" 50 box-2D:us
printf '429' > "$SRV/status-once"
run run
check "429 once: waits and retries, then scrapes" '[ "$RC" = 0 ] && [ "$(nqueries)" = 2 ] && [ -f "$MEDIA/md/a.md-box.png" ]'
check "429: the wait is the Retry-After ScreenScraper sent (2 s)" 'grep -q "waiting 2 s" <<<"$ERR"'

reset; rom md/a.md "a"; mkgame "crc-$(crc "$ROMS/md/a.md")" 55 box-2D:us
touch "$SRV/timeout-once"
run run
check "a lookup that times out once (Wi-Fi) is retried, then scrapes" '[ "$RC" = 0 ] && [ "$(summary scraped)" = 1 ] && [ -f "$MEDIA/md/a.md-box.png" ]'
reset; for r in a b c d e; do rom "md/$r.md" "$r"; done; touch "$SRV/timeout"
run run
check "no network at all: exit 3 after 3 ROMs in a row failed (each retried once), summary printed" '[ "$RC" = 3 ] && [ "$(grep -c jeuInfos "$W/url.log")" = 6 ] && [ "$(summary failed)" = 3 ] && contract'
reset; rom md/a.md "a"; rom md/b.md "b"; mkgame "crc-$(crc "$ROMS/md/b.md")" 58 box-2D:us
python3 - "$W/bin/curl" <<'PYSTUB'
import sys
p = sys.argv[1]; s = open(p).read()
s = s.replace('if os.path.exists(f"{SRV}/timeout"):', 'if os.path.exists(f"{SRV}/timeout") or (os.path.exists(f"{SRV}/timeout-a") and "romnom=a.md" in (url or "")):', 1)
open(p, "w").write(s)
PYSTUB
touch "$SRV/timeout-a"
run run
check "one ROM whose lookup keeps failing: counted failed, the run goes on" '[ "$RC" = 0 ] && [ "$(summary failed)" = 1 ] && [ "$(summary scraped)" = 1 ]'
rm -f "$SRV/timeout-a"; rm -f "$W/queries.log"; run run
check "...and it is asked again next run (not cached)" '[ "$(nqueries)" = 1 ] && [ "$(query 1 romnom)" = a.md ]'

reset; rom md/a.md "a"; mkgame "crc-$(crc "$ROMS/md/a.md")" 56 box-2D:us ss:wor
touch "$SRV/timeout-media-once"
run run
check "an image download that times out once is retried" '[ "$RC" = 0 ] && [ -f "$MEDIA/md/a.md-box.png" ] && [ -f "$MEDIA/md/a.md-screen.png" ]'
reset; rom md/a.md "a"; mkgame "crc-$(crc "$ROMS/md/a.md")" 57 box-2D:us ss:wor wheel:us
touch "$SRV/timeout-media"
run run
check "images that keep failing: the ROM still counts as found, the run goes on" '[ "$RC" = 0 ] && [ "$(summary scraped)" = 1 ]'
rm -f "$SRV/timeout-media" "$W/queries.log"; run run
check "...and the next run asks for it again and gets the images" '[ "$(nqueries)" = 1 ] && [ -f "$MEDIA/md/a.md-box.png" ] && [ -f "$MEDIA/md/a.md-wheel.png" ]'
rm -f "$W/queries.log"; run run
check "...after which it is complete: not asked again" '[ "$(nqueries)" = 0 ]'
check "curl gives up connecting after 8 s, not 20" 'grep -q -- "--connect-timeout 8 " "$W/argv.log" && ! grep -q -- "--connect-timeout 20" "$W/argv.log"'

reset; rom md/a.md "a"; rom md/b.md "b"
REQ_TODAY=10000 REQ_MAX=10000 mkgame "crc-$(crc "$ROMS/md/a.md")" 51 box-2D:us
REQ_TODAY=10000 REQ_MAX=10000 mkgame "crc-$(crc "$ROMS/md/b.md")" 52 box-2D:us
run run
check "daily quota used up: stops before the next ROM, exit 6" '[ "$RC" = 6 ] && [ "$(nqueries)" = 1 ] && [ "$(summary quota_left)" = 0 ]'
check "the ROM already answered still got its art" '[ "$(ls "$MEDIA/md" | wc -l)" = 1 ]'

reset; rom md/a.md "a"; rom md/b.md "b"; mkgame "crc-$(crc "$ROMS/md/b.md")" 53 box-2D:us
mkdir -p "$W/home/.cache/retroforge"
printf '{"schema": 1, "roms": {}, "quota": {"requeststoday": "10000", "maxrequestsperday": "10000", "at": 1}}' > "$W/home/.cache/retroforge/scrape.json"
run run
check "yesterday's used-up quota does not stop today's run" '[ "$RC" = 0 ] && [ "$(nqueries)" = 2 ] && [ "$(summary scraped)" = 1 ]'

reset; rom md/a.md "a"; mkgame "crc-$(crc "$ROMS/md/a.md")" 54 box-2D:us
rom md/b.md "b"; mkdir -p "$W/home/.cache/retroforge"
printf '{"schema": 1, "roms": {"md/a.md": "junk", "md/b.md": {"checked": "soon", "status": "not_found"}}, "quota": []}' > "$W/home/.cache/retroforge/scrape.json"
run run
check "a cache of the wrong shape is mended, not fatal" '[ "$RC" = 0 ] && [ "$(summary scraped)" = 1 ] && [ "$(summary failed)" = 0 ]'

# =================================================================================================
CASE="one bad ROM does not stop the run"
reset
rom md/good.md "good"; mkgame "crc-$(crc "$ROMS/md/good.md")" 70 box-2D:us
mkdir -p "$ROMS/snes"; printf 'PK\003\004 not really a zip' > "$ROMS/snes/broken.zip"
rom md/list.md "list"; printf '[1, 2]' > "$SRV/games/crc-$(crc "$ROMS/md/list.md").json"
rom md/nojson.md "nojson"; printf '<html>oops' > "$SRV/games/crc-$(crc "$ROMS/md/nojson.md").json"
python3 -c 'import os,sys; open(os.path.join(sys.argv[1].encode(), b"md", b"caf\xe9.md"), "wb").write(b"latin1")' "$ROMS"
LONG="$(printf 'L%.0s' $(seq 1 245)).md"; rom "md/$LONG" "long"; mkgame "crc-$(crc "$ROMS/md/$LONG")" 71 box-2D:us
run run
check "exit 0" '[ "$RC" = 0 ]'
check "the good ROM got its art" '[ -f "$MEDIA/md/good.md-box.png" ]'
check "a corrupt zip is asked by name instead" 'grep -q "\"romnom\": \"broken.zip\"" "$W/queries.log"'
check "answers of the wrong shape + a name too long to write: failed, counted" '[ "$(summary failed)" = 3 ]'
check "a non-UTF-8 file name is skipped with a warning" 'grep -q "not UTF-8" <<<"$ERR"'
check "failed ROMs are not cached (asked again next time)" '! grep -q "list.md" "$W/home/.cache/retroforge/scrape.json"'
check "no traceback" '! grep -q Traceback <<<"$ERR"'

reset; rom md/noart.md "noart"; mkgame "crc-$(crc "$ROMS/md/noart.md")" 72
run run; rm -f "$W/queries.log"; run run
check "found but ScreenScraper has no art for it: not asked again this week" '[ "$(nqueries)" = 0 ]'

reset; rom md/t.md "touched"; mkgame "crc-$(crc "$ROMS/md/t.md")" 73 box-2D:us
run run; touch -d '2001-01-01' "$ROMS/md/t.md"; rm -f "$W/queries.log"; run run
check "same size, new mtime: asked again" '[ "$(nqueries)" = 1 ]'

reset; rom md/c1.md "c1"; rom md/c2.md "c2"; touch "$SRV/slow"
mkdir -p "$MEDIA/md"; : > "$MEDIA/md/old.md-box.png.part"
( HOME="$W/home" RETROFORGE_CURL="$W/bin/curl" RETROFORGE_ROMS_DIR="$ROMS" RETROFORGE_MEDIA_DIR="$MEDIA" \
  RETROFORGE_SCRAPER_SYSTEMS="$SYSTEMS" RETROFORGE_SS_DEVID=dev RETROFORGE_SS_DEVPASSWORD=dev-secret \
  RETROFORGE_SCRAPER_DEVID_FILE="$W/no-devid-file" python3 "$SCRAPE" run >"$W/out" 2>"$W/err" ) & PID=$!
sleep 1.5; kill -TERM "$PID"; wait "$PID"; RC=$?; OUT="$(cat "$W/out")"; ERR="$(cat "$W/err")"
check "Cancel (SIGTERM) mid-request: exit 5, summary printed" '[ "$RC" = 5 ] && contract'
check "a .part left by an earlier killed run is swept" '[ ! -e "$MEDIA/md/old.md-box.png.part" ]'
check "the curl stub was not left behind" '! pgrep -f "$W/bin/curl" >/dev/null'

# =================================================================================================
CASE="player account"
reset; rom md/a.md "a"; mkgame "crc-$(crc "$ROMS/md/a.md")" 60 box-2D:us
run account
check "no account: configured false" '[ "$RC" = 0 ] && python3 -c "import json,sys; sys.exit(json.loads(sys.argv[1])[\"configured\"] is not False)" "$OUT"'
run login good <<<"wrong"
check "a refused login: exit 7, nothing saved" '[ "$RC" = 7 ] && [ ! -e "$W/home/.config/retroforge/scraper.conf" ]'
run login $'good\nregion=jp' <<<"pw-secret"
check "a user name with a line break is refused (no conf injection)" '[ "$RC" = 2 ] && [ ! -e "$W/home/.config/retroforge/scraper.conf" ]'
run login good <<<"pw-secret"
check "accepted login: exit 0" '[ "$RC" = 0 ]'
check "conf is 0600" '[ "$(stat -c %a "$W/home/.config/retroforge/scraper.conf")" = 600 ]'
check "password read from stdin, never in argv" 'secret_free'
run run
check "the player's login is sent" '[ "$(query 1 ssid)" = good ] && [ "$(query 1 sspassword)" = pw-secret ]'
check "and never shown" 'secret_free'
run account
check "account: configured, user, last quota" 'python3 -c "import json,sys; a=json.loads(sys.argv[1]); sys.exit(not (a[\"configured\"] and a[\"user\"] == \"good\" and a[\"max_requests_per_day\"] == 10000))" "$OUT"'
check "account never shows the password" 'secret_free'
run logout
check "logout forgets the login" '[ "$RC" = 0 ] && ! grep -q good "$W/home/.config/retroforge/scraper.conf" 2>/dev/null'

# =================================================================================================
CASE="image stage"
# rootfs/lib-assemble-scraper.sh, sourced the way assemble-rootfs.sh does (it reads $stage).
stage_run() {  # stage_run <devid> <devpassword>: sets OUT, RC; the staged tree is $W/stage
  rm -rf "$W/stage"; mkdir -p "$W/stage"
  OUT="$(stage="$W/stage" RETROFORGE_SS_DEVID="$1" RETROFORGE_SS_DEVPASSWORD="$2" \
    bash -c '. "$0"' "$ROOT/rootfs/lib-assemble-scraper.sh" 2>&1)"; RC=$?
}
F="$W/stage/usr/share/retroforge/scraper/devid"
stage_run dev dev-secret
check "with both values: the login file the tool reads" '[ "$RC" = 0 ] && [ "$(cat "$F")" = "$(printf "devid=dev\ndevpassword=dev-secret")" ]'
check "readable by the player (the scraper runs as the player)" '[ "$(stat -c %a "$F")" = 644 ]'
check "the build log never shows the password" '! grep -q dev-secret <<<"$OUT"'
DEVFILE_OK="$(HOME="$W/home" RETROFORGE_SS_DEVID= RETROFORGE_SS_DEVPASSWORD= RETROFORGE_SCRAPER_DEVID_FILE="$F" RETROFORGE_CURL=/bin/false \
  RETROFORGE_ROMS_DIR="$W/none" RETROFORGE_MEDIA_DIR="$W/stage-media" RETROFORGE_SCRAPER_SYSTEMS="$SYSTEMS" python3 "$SCRAPE" run 2>&1)"
check "the tool takes the staged file as its login (no exit 9)" '! grep -q "no ScreenScraper developer login" <<<"$DEVFILE_OK"'
stage_run dev ""
check "one value missing: no file, a warning, the build goes on" '[ "$RC" = 0 ] && [ ! -e "$F" ] && grep -q WARN <<<"$OUT"'
stage_run $'dev\nx' dev-secret
check "a line break in a value fails the build" '[ "$RC" != 0 ] && [ ! -e "$F" ]'

# =================================================================================================
CASE="repo hygiene"
check "no developer credentials file in the tree" '[ ! -e "$ROOT/rootfs/overlay/usr/share/retroforge/scraper/devid" ]'
check "dev.env.local stays ignored" 'git -C "$ROOT" check-ignore -q dev.env.local'

echo
echo "test-scrape: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
