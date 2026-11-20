#!/usr/bin/env bash
# Offline test for /usr/bin/steam and /usr/lib/retroforge/steam-bootstrap: how the image provides the
# `steam` the OpenGamepadUI Steam plugin launches games with.
#
#   tests/test-steam.sh
#
# WHY THIS EXISTS. Neither is exercised before a player picks a Steam game, and each rule below fails
# as a game that never starts, a black screen, a half-set-up client that looks ready, or a ~631 MB
# surprise download:
#   the pin (steam.pin): names CHANNELS, not versions; the client channel is a steamdeck_ line,
#     because the plugin starts the client with -steamdeck.
#   bootstrap, client:
#   - reads steam_client_<client_channel>_linuxarm64 and installs Valve's arm64 client binaries,
#     refusing them unless the manifest's sha256 matches;
#   - writes package/beta = the channel when it installs the client and when the file is missing,
#     and otherwise leaves it to the client;
#   - unpacks Valve's zips correctly: '\' separators, no execute bits in the zip, Unix symlinks;
#   - a failed download leaves no half-set-up client and no temp files, and never touches the
#     player's other files in the Steam folder;
#   - refuses a zip path or symlink that leaves its folder;
#   - downloads no Steam Runtime, and removes the one earlier builds installed.
#   wrapper:
#   - runs steamrtarm64/steam raw on the host (no runtime container: games' pressure-vessel cannot
#     start nested in it) with the plugin's arguments, from steamrtarm64 with its own libraries first
#     on LD_LIBRARY_PATH, and starts it again on exit 42 (after an update);
#   - points ~/.steam/steam and ~/.steam/root at the client, and the links Valve's steam.sh makes;
#   - drops a D-Bus address that is not ours, and the STEAM_RUNTIME variables;
#   - a failed bootstrap is exit 1 without running anything.
#   kept running in the background (retroforge-steam-keep, the wrapper's "Kept running" block): on
#   by default; the first launch starts the client as a user unit with the launch's environment
#   (OGUI_ID=Steam, not the game's), later ones hand their arguments to it, and a game's launch lasts
#   exactly as long as Steam's own reaper for that app id (never OGUI's reaper, which takes the same
#   arguments), so OGUI neither returns to its menu early nor waits forever. Exit from OGUI's menu ends
#   the game's processes, not Steam; a kept client turned off mid-game stops when the game ends;
#   without a user manager Steam runs with the launch, as when off.
#   minimal: the kept client's web helper is killed and the one the client starts again frozen, and
#   nothing it had started yet lives; frozen already, nothing is killed; a launch that needs Steam's
#   UI holds it running (Steam's UI until OGUI closes it, a game until it has run a while), a hold of a
#   launch that is gone does not.
# Valve's servers are replaced by file:// URLs: $CDN for the client.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BOOT="$ROOT/rootfs/overlay/usr/lib/retroforge/steam-bootstrap"
WRAP="$ROOT/rootfs/overlay/usr/bin/steam"
PIN_REAL="$ROOT/rootfs/overlay/usr/share/retroforge/steam/steam.pin"
for f in "$BOOT" "$WRAP" "$PIN_REAL"; do [ -f "$f" ] || { echo "missing: $f" >&2; exit 1; }; done

PASS=0; FAIL=0; CASE=""
ok()  { PASS=$((PASS+1)); printf '  ok   %s -- %s\n' "$CASE" "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s -- %s\n' "$CASE" "$1"; }

T="$(mktemp -d)" && [ -d "$T" ] || { echo "mktemp -d failed" >&2; exit 1; }
trap 'rm -rf "$T"' EXIT

mode() { python3 -c 'import os,sys; print(oct(os.stat(sys.argv[1]).st_mode & 0o777)[2:])' "$1"; }
sha()  { python3 -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$1"; }
zeros() { printf '0%.0s' {1..64}; }

CDN="$T/cdn"; mkdir -p "$CDN"            # media.steampowered.com/client
DATA="$T/home/.local/share"
STEAM_ROOT="$DATA/Steam"
CLIENT="$STEAM_ROOT/steamrtarm64/steam"
BETA="$STEAM_ROOT/package/beta"
OLD_RT="$DATA/retroforge/steam-runtime"   # where earlier builds kept the Steam Runtime
PIN="$T/steam.pin"
CHAN=steamdeck_rftest

mkpin() {  # mkpin [extra lines...]
  { printf '# a test pin\nclient_channel: %s\n' "$CHAN"
    [ $# -gt 0 ] && printf '%s\n' "$@"
  } >"$PIN"
}
mkclient() {  # mkclient <zip> [extra member] : the client binaries as Valve zips them
  python3 - "$1" "${2:-}" <<'PY'
import stat, sys, zipfile
path, extra = sys.argv[1:3]
def add(z, name, data=b"", mode=stat.S_IFREG | 0o666, system=0):
    i = zipfile.ZipInfo(name); i.create_system = system; i.external_attr = mode << 16
    z.writestr(i, data)
with zipfile.ZipFile(path, "w") as z:
    add(z, "steamrtarm64\\libs/", mode=stat.S_IFDIR)
    add(z, "steamrtarm64/builddate.txt", b"Oct 13 2026\n")
    add(z, "steamrtarm64/steam", b"\x7fELF arm64 steam\n")
    add(z, "steamrtarm64/steamwebhelper.sh", b"#!/bin/bash\nexec ./steamwebhelper\n")
    add(z, "steamrtarm64\\libs\\libcurl.so", b"libcurl.so.4.8.0", stat.S_IFLNK | 0o755, 3)
    add(z, "steamrtarm64/libs/libcurl.so.4.8.0", b"\x7fELF arm64 libcurl\n")
    if extra:
        add(z, extra, b"evil\n")
PY
}
mkmanifest() {  # mkmanifest <client zip> [sha2] [channel]: a channel's manifest, with a decoy package first
  local file="bins_linuxarm64_linuxarm64.zip.$(basename "$1")"
  cp "$1" "$CDN/$file"
  cat >"$CDN/steam_client_${3:-$CHAN}_linuxarm64" <<EOF
"linuxarm64"
{
	"version"		"1791918634"
	"bins_sdk_linuxarm64_linuxarm64"
	{
		"file"		"bins_sdk_linuxarm64_linuxarm64.zip.decoy"
		"size"		"1"
		"sha2"		"0000000000000000000000000000000000000000000000000000000000000000"
	}
	"bins_linuxarm64_linuxarm64"
	{
		"file"		"$file"
		"size"		"$(wc -c <"$1" | tr -d ' ')"
		"sha2"		"${2:-$(sha "$1")}"
	}
}
EOF
}
boot() {  # boot [VAR=value...]: `steam-bootstrap --install`, as steam-install runs it
  OUT="$(env -u RETROFORGE_STEAM_PROGRESS HOME="$T/home" XDG_DATA_HOME="$DATA" \
         RETROFORGE_STEAM_PIN="$PIN" RETROFORGE_STEAM_CDN="file://$CDN" "$@" python3 "$BOOT" --install 2>"$T/err")"; RC=$?
  ERR="$(cat "$T/err")"
}
bootn() {  # bootn [VAR=value...]: plain `steam-bootstrap`, as /usr/bin/steam runs it on every start
  OUT="$(env -u RETROFORGE_STEAM_PROGRESS HOME="$T/home" XDG_DATA_HOME="$DATA" \
         RETROFORGE_STEAM_PIN="$PIN" RETROFORGE_STEAM_CDN="file://$CDN" "$@" python3 "$BOOT" 2>"$T/err")"; RC=$?
  ERR="$(cat "$T/err")"
}
leftovers() { find "$DATA" -name '.retroforge-bootstrap-*' | head -3; }

# ================================================================================================
CASE="the real pin"
python3 - "$PIN_REAL" <<'PY' && ok "a channel only: a steamdeck_ client line, no version, no runtime" \
  || bad "the image's steam.pin is malformed"
import re, sys
t = open(sys.argv[1]).read()
field = lambda k: (re.search(rf"^{k}:[ \t]*(\S+)", t, re.M) or [None, None])[1]
# -steamdeck (the plugin's flag) keeps a steamdeck_ line; any other gets repointed at ~631 MB.
assert re.fullmatch(r"steamdeck_[a-z0-9_]+", field("client_channel") or ""), field("client_channel")
for k in ("version", "url", "sha256"):
    assert field(k) is None, f"{k} pins a version"
for k in ("runtime_base", "runtime_channel", "runtime_snapshot"):
    assert field(k) is None, f"{k}: the client runs without a Steam Runtime"
PY

CASE="fresh image, not installed"
mkpin
mkclient "$T/client.zip"; mkmanifest "$T/client.zip"
bootn
[ "$RC" = 10 ] && [ -z "$OUT" ] && grep -q "Steam Client is not installed: install it from Main menu > Emulators > Steam Client" <<<"$ERR" \
  && ok "without --install: exit 10, says where Steam Client is installed" || bad "rc=$RC out=$OUT err=$ERR"
[ ! -e "$STEAM_ROOT/steamrtarm64" ] && ok "and downloads nothing" || bad "$(ls -la "$STEAM_ROOT" 2>&1 | head)"
OUT="$(python3 "$BOOT" --bogus 2>"$T/err")"; RC=$?
[ "$RC" = 2 ] && grep -q "usage: steam-bootstrap \[--install\]" "$T/err" && ok "an unknown argument: exit 2" || bad "rc=$RC $(cat "$T/err")"

CASE="fresh image"
boot RETROFORGE_STEAM_PROGRESS=1
[ "$RC" = 0 ] && [ "$OUT" = "$CLIENT" ] && ok "exit 0, prints the client's path" || bad "rc=$RC out=$OUT err=$ERR"
[ -f "$CLIENT" ] && [ "$(mode "$CLIENT")" = 755 ] \
  && ok "the client binary is in place, 0755 although the zip says 0666" || bad "steam: $(ls -la "$STEAM_ROOT/steamrtarm64" 2>&1)"
[ "$(mode "$STEAM_ROOT/steamrtarm64/steamwebhelper.sh")" = 755 ] && [ "$(mode "$STEAM_ROOT/steamrtarm64/builddate.txt")" = 644 ] \
  && ok "#! scripts 0755, data 0644" || bad "modes: sh=$(mode "$STEAM_ROOT/steamrtarm64/steamwebhelper.sh") txt=$(mode "$STEAM_ROOT/steamrtarm64/builddate.txt")"
[ -d "$STEAM_ROOT/steamrtarm64/libs" ] && [ "$(readlink "$STEAM_ROOT/steamrtarm64/libs/libcurl.so")" = libcurl.so.4.8.0 ] \
  && ok "'\\' separators become folders, and link entries become symlinks" || bad "libs: $(ls -la "$STEAM_ROOT/steamrtarm64/libs" 2>&1)"
[ -z "$(find "$STEAM_ROOT" -name '*\\*')" ] && ok "no file has a '\\' in its name" || bad "$(find "$STEAM_ROOT" -name '*\\*')"
[ "$(cat "$BETA" 2>/dev/null)" = "$CHAN" ] && ok "package/beta names the pinned channel" || bad "beta: $(cat "$BETA" 2>&1)"
[ -z "$(leftovers)" ] && ok "no temporary folders left" || bad "left: $(leftovers)"
[ ! -e "$OLD_RT" ] && ok "no Steam Runtime is downloaded" || bad "$(ls -la "$OLD_RT")"
grep -q "Steam client from $CHAN" <<<"$ERR" && ok "says on stderr what it downloads, and from which channel" || bad "stderr: $ERR"
CZ="$(wc -c <"$T/client.zip" | tr -d ' ')"
grep -qx "steam-bootstrap: progress $CZ $CZ" <<<"$ERR" && [ "$(grep -c "^steam-bootstrap: progress " <<<"$ERR")" -ge 1 ] \
  && ok "RETROFORGE_STEAM_PROGRESS=1: progress lines, ending at the download's total" || bad "stderr: $ERR"
bootn
[ "$RC" = 0 ] && [ "$OUT" = "$CLIENT" ] && ok "installed: a plain start (steam's) prints the client's path" || bad "rc=$RC out=$OUT err=$ERR"
! grep -q "progress" <<<"$ERR" && ok "and no progress lines without the variable" || bad "stderr: $ERR"

CASE="installed, offline"
mv "$CDN" "$CDN.off"
bootn
[ "$RC" = 0 ] && [ "$OUT" = "$CLIENT" ] && [ -z "$ERR" ] && ok "a start reads nothing from the network, and says nothing" || bad "rc=$RC out=$OUT err=$ERR"
boot
[ "$RC" = 0 ] && [ "$OUT" = "$CLIENT" ] && [ -z "$ERR" ] && ok "nor does --install once the client is there" || bad "rc=$RC out=$OUT err=$ERR"
mv "$CDN.off" "$CDN"

CASE="a Steam Runtime from an earlier build"
mkdir -p "$OLD_RT/3c.0.20260824.1/steam-runtime-steamrt-arm64"
printf '#!/bin/sh\n' >"$OLD_RT/3c.0.20260824.1/steam-runtime-steamrt-arm64/run"
bootn
[ "$RC" = 0 ] && [ "$OUT" = "$CLIENT" ] && [ ! -e "$OLD_RT" ] && grep -q "removed $OLD_RT: the client runs without it now" <<<"$ERR" \
  && ok "removed on the next start, and said so" || bad "rc=$RC out=$OUT err=$ERR $(ls -la "$OLD_RT" 2>&1)"
bootn
[ "$RC" = 0 ] && [ -z "$ERR" ] && ok "and nothing said after that" || bad "rc=$RC err=$ERR"

CASE="package/beta"
echo steamdeck_publicbeta >"$BETA"   # the client repointed itself
boot
[ "$RC" = 0 ] && [ "$(cat "$BETA")" = steamdeck_publicbeta ] && ok "left alone when present: the client owns it" || bad "rc=$RC beta=$(cat "$BETA") err=$ERR"
rm -f "$BETA"
bootn
[ "$RC" = 0 ] && [ "$(cat "$BETA" 2>/dev/null)" = "$CHAN" ] && ok "written again when missing, without a client download" \
  || bad "rc=$RC beta=$(cat "$BETA" 2>&1) err=$ERR"

CASE="the pin"
printf '# a test pin\n' >"$PIN"
boot
[ "$RC" = 1 ] && [ -z "$OUT" ] && grep -q "needs client_channel" <<<"$ERR" && ok "a pin without client_channel: exit 1" || bad "rc=$RC out=$OUT err=$ERR"
printf 'client_channel: ../evil\n' >"$PIN"
boot
[ "$RC" = 1 ] && grep -q "not a client channel" <<<"$ERR" && ok "a channel that is not a line name is refused" || bad "rc=$RC err=$ERR"
mkpin

CASE="client channel"
rm -rf "$STEAM_ROOT"; rm -f "$CDN"/steam_client_*
mkmanifest "$T/client.zip" "" steamdeck_otherline
boot
[ "$RC" = 1 ] && grep -q "steam_client_${CHAN}_linuxarm64" <<<"$ERR" && [ ! -e "$STEAM_ROOT/steamrtarm64" ] \
  && ok "only the pinned channel's manifest is read; a missing one is an error naming it" || bad "rc=$RC err=$ERR"
CHAN=steamdeck_otherline; mkpin
boot
[ "$RC" = 0 ] && [ -x "$STEAM_ROOT/steamrtarm64/steam" ] && [ "$(cat "$BETA" 2>/dev/null)" = steamdeck_otherline ] \
  && ok "steam_client_<channel>_linuxarm64 is built from the pin, and package/beta follows it" || bad "rc=$RC beta=$(cat "$BETA" 2>&1) err=$ERR"
CHAN=steamdeck_rftest; mkpin; mkmanifest "$T/client.zip"

CASE="client download, bad checksum"
rm -rf "$STEAM_ROOT/steamrtarm64"
mkdir -p "$STEAM_ROOT/steamapps/common/Game"; echo data >"$STEAM_ROOT/steamapps/common/Game/data"
mkclient "$T/client.zip"; mkmanifest "$T/client.zip" "$(printf 'f%.0s' {1..64})"
boot
[ "$RC" = 1 ] && grep -q "sha256 mismatch" <<<"$ERR" && ok "refused (exit 1)" || bad "rc=$RC err=$ERR"
[ ! -e "$STEAM_ROOT/steamrtarm64" ] && ok "no half-set-up client left" || bad "steamrtarm64 exists"
[ -f "$STEAM_ROOT/steamapps/common/Game/data" ] && ok "the player's games are untouched" || bad "games gone"
[ -z "$(leftovers)" ] && ok "no temporary folders left" || bad "left: $(leftovers)"

CASE="leftover from a failed attempt"
mkdir -p "$STEAM_ROOT/steamrtarm64"; echo stale >"$STEAM_ROOT/steamrtarm64/builddate.txt"
echo steamdeck_publicbeta >"$BETA"
mkmanifest "$T/client.zip"
boot
[ "$RC" = 0 ] && [ -x "$STEAM_ROOT/steamrtarm64/steam" ] && ! grep -q stale "$STEAM_ROOT/steamrtarm64/builddate.txt" \
  && ok "a steamrtarm64/ without the client is replaced" || bad "rc=$RC err=$ERR"
[ "$(cat "$BETA")" = "$CHAN" ] && ok "installing the client sets package/beta to the channel" || bad "beta: $(cat "$BETA")"
[ -f "$STEAM_ROOT/steamapps/common/Game/data" ] && ok "the player's games are untouched" || bad "games gone"

CASE="manifest without the package"
rm -rf "$STEAM_ROOT/steamrtarm64"
printf '"linuxarm64"\n{\n\t"version"\t\t"1"\n}\n' >"$CDN/steam_client_${CHAN}_linuxarm64"
boot
[ "$RC" = 1 ] && grep -q "lists no bins_linuxarm64_linuxarm64" <<<"$ERR" && ok "an error that names the package" || bad "rc=$RC err=$ERR"

CASE="unsafe zip"
mkclient "$T/evil.zip" "../../escaped"; mkmanifest "$T/evil.zip"
boot
[ "$RC" = 1 ] && grep -q "unsafe path" <<<"$ERR" && ok "a path leaving the folder is refused" || bad "rc=$RC err=$ERR"
[ -z "$(find "$T" -name escaped)" ] && [ ! -e "$STEAM_ROOT/steamrtarm64" ] && ok "and nothing was written" || bad "$(find "$T" -name escaped)"

CASE="offline on a fresh image"
rm -rf "$CDN" "$DATA"
boot
[ "$RC" = 1 ] && [ -z "$OUT" ] && grep -q "could not download" <<<"$ERR" && ok "exit 1, says what it could not fetch" || bad "rc=$RC out=$OUT err=$ERR"

# ================================================================================================
# The wrapper, with the bootstrap stubbed: it puts a fake client where the real one is, and that
# records how it was called.
W="$T/w"; mkdir -p "$W"
cat >"$W/client" <<EOF
#!/usr/bin/env bash
n=\$(( \$(cat "$W/count" 2>/dev/null || echo 0) + 1 )); echo "\$n" >"$W/count"
{ echo "args: \$*"; echo "cwd: \$PWD"; echo "dbus: \${DBUS_SESSION_BUS_ADDRESS-unset}"; echo "rt: \${STEAM_RUNTIME-unset}"
  echo "ld: \${LD_LIBRARY_PATH-unset}"; } >"$W/call\$n"
codes=(\$(cat "$W/codes")); c="\${codes[\$((n-1))]:-0}"
if [ "\$c" = S ]; then   # S: run until TERMed, like the real client
  trap 'echo term >"$W/term"; exit 143' TERM; echo \$\$ >"$W/runpid"
  while :; do sleep 0.1; done
fi
exit "\$c"
EOF
cat >"$W/bootstrap" <<EOF
#!/usr/bin/env bash
[ -e "$W/boot-fails" ] && { echo "steam-bootstrap: no network" >&2; exit 1; }
mkdir -p "\$RETROFORGE_STEAM_ROOT/steamrtarm64"
cp "$W/client" "\$RETROFORGE_STEAM_ROOT/steamrtarm64/steam"; echo "\$RETROFORGE_STEAM_ROOT/steamrtarm64/steam"
EOF
chmod +x "$W/client" "$W/bootstrap"
# The x86 guest and the DXVK-Sarek block have their own suites (test-steam-x86-guest.sh,
# test-steam-compat-tools.sh). Here they would reach the real helpers, and on a device start real
# downloads into the test's home (1.4 GB): RETROFORGE_STEAM_X86_GUEST=0 turns the guest off. Starting a
# game without the client
# has its own suite too (test-steam-direct.sh): RETROFORGE_STEAM_DIRECT_CLI names no such file, so every
# launch here goes to the client.
# Keeping Steam running: the real retroforge-steam-keep, over a fake /proc ($P: a process is its
# folder there) and stub systemctl, systemd-run and kill in $W/bin. Off for the wrapper unless a case
# turns it on (it is on by default).
KEEP="$ROOT/rootfs/overlay/usr/bin/retroforge-steam-keep"
P="$W/proc"; mkdir -p "$P" "$W/bin"
unset RETROFORGE_STEAM_KEEP RETROFORGE_STEAM_KEPT XDG_CONFIG_HOME OGUI_ID
cat >"$W/bin/systemctl" <<EOF
#!/usr/bin/env bash
echo "systemctl \$*" >>"$W/sysd.log"
case "\$*" in
  *is-active*) [ -e "$W/unit-active" ] ;;
  *" stop "*) rm -f "$W/unit-active" ;;
esac
EOF
cat >"$W/bin/systemd-run" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$@" >"$W/sdrun.args"
[ -e "$W/sdrun-fails" ] && { echo "Failed to connect to bus: No medium found" >&2; exit 1; }
touch "$W/unit-active"
EOF
cat >"$W/bin/fakekill" <<EOF
#!/usr/bin/env bash
sig=\$1; shift; echo "\$sig \$*" >>"$W/kills"
if [ "\$sig" = -TERM ]; then for p in "\$@"; do rm -rf "$P/\${p:?}"; done; fi
EOF
chmod +x "$W/bin/systemctl" "$W/bin/systemd-run" "$W/bin/fakekill"
fakeproc() {  # fakeproc <pid> <ppid> <comm> <argv...>
  local pid=$1 ppid=$2 comm=$3; shift 3
  mkdir -p "$P/$pid"; echo "$comm" >"$P/$pid/comm"; printf '%s\0' "$@" >"$P/$pid/cmdline"
  echo "$pid ($comm) S $ppid $pid $pid 0 -1" >"$P/$pid/stat"
}
gone() { rm -rf "${P:?}/${1:?}"; }
until_true() { local _; for _ in $(seq 60); do eval "$1" && return 0; sleep 0.1; done; return 1; }
WENV=(env -u RETROFORGE_STEAM_ROOT -u XDG_DATA_HOME -u LD_LIBRARY_PATH HOME="$W/home" RETROFORGE_STEAM_BOOTSTRAP="$W/bootstrap"
      RETROFORGE_CPUINFO="$W/cpuinfo" RETROFORGE_STEAM_X86_GUEST=0 RETROFORGE_STEAM_DIRECT_CLI="$W/no-direct-cli"
      PATH="$W/bin:$PATH" RETROFORGE_STEAM_KEEP_CLI="$KEEP" RETROFORGE_PROC="$P" RETROFORGE_STEAM_KEEP_KILL="$W/bin/fakekill"
      RETROFORGE_STEAM_KEEP=off XDG_RUNTIME_DIR="$W/run")
KENV=(env HOME="$W/home" PATH="$W/bin:$PATH" RETROFORGE_PROC="$P" RETROFORGE_STEAM_KEEP_KILL="$W/bin/fakekill" XDG_RUNTIME_DIR="$W/run")
wrap() {  # wrap <exit codes of successive runs> [args...]
  echo "$1" >"$W/codes"; shift; rm -f "$W/count" "$W"/call*
  WOUT="$("${WENV[@]}" RETROFORGE_STEAM_KEEP="${RETROFORGE_STEAM_KEEP:-off}" bash "$WRAP" "$@" 2>"$W/err")"; WRC=$?
  WERR="$(cat "$W/err")"
}
WROOT="$W/home/.local/share/Steam"

CASE="wrapper: launch"
touch "$W/mybus"
DBUS_SESSION_BUS_ADDRESS="unix:path=$W/mybus" STEAM_RUNTIME=1 wrap 0 -gamepadui -silent steam://rungameid/42
[ "$WRC" = 0 ] && grep -qx "args: -gamepadui -silent steam://rungameid/42" "$W/call1" \
  && ok "runs steamrtarm64/steam itself, no runtime container, with the plugin's arguments" || bad "rc=$WRC $(cat "$W/call1" 2>&1) $WERR"
grep -qx "cwd: $WROOT/steamrtarm64" "$W/call1" && ok "from steamrtarm64 in the Steam folder (XDG default)" || bad "$(grep cwd "$W/call1")"
grep -qx "ld: $WROOT/steamrtarm64:$WROOT/steamrtarm64/video" "$W/call1" \
  && ok "LD_LIBRARY_PATH is the client's own libraries (libav*, libvpx)" || bad "$(grep ld: "$W/call1")"
[ "$(readlink "$W/home/.steam/steam")" = "$WROOT" ] && [ "$(readlink "$W/home/.steam/root")" = "$WROOT" ] \
  && ok "~/.steam/steam and ~/.steam/root point at it" || bad "links: $(ls -la "$W/home/.steam")"
grep -qx "dbus: unix:path=$W/mybus" "$W/call1" && ok "our own D-Bus address is kept" || bad "$(grep dbus "$W/call1")"
grep -qx "rt: unset" "$W/call1" && ok "STEAM_RUNTIME is unset" || bad "$(grep rt: "$W/call1")"
[ -z "$WERR" ] && ok "nothing on stderr" || bad "stderr: $WERR"
[ "$(readlink "$W/home/.steam/bin64")" = "$WROOT/ubuntu12_64" ] && [ "$(readlink "$W/home/.steam/bin32")" = "$WROOT/ubuntu12_32" ] \
  && ok "~/.steam/bin64 and bin32 point at ubuntu12_64 and ubuntu12_32 (the overlay's preload paths)" || bad "links: $(ls -la "$W/home/.steam")"
[ "$(readlink "$W/home/.steam/sdkarm64")" = "$WROOT/linuxarm64" ] \
  && ok "~/.steam/sdkarm64 points at linuxarm64 (every game launches through its steam-launch-wrapper)" || bad "links: $(ls -la "$W/home/.steam")"

CASE="wrapper: Steam Client not installed"
cp "$W/bootstrap" "$W/bootstrap.real"
printf '#!/usr/bin/env bash\necho "steam-bootstrap: Steam Client is not installed: install it from Main menu > Emulators > Steam Client" >&2\nexit 10\n' >"$W/bootstrap"
wrap 0 steam://rungameid/42
[ "$WRC" = 1 ] && [ ! -e "$W/count" ] && ok "exit 1, the client is not started" || bad "rc=$WRC runs=$(cat "$W/count" 2>/dev/null)"
[ "$(grep -c . <<<"$WERR")" = 1 ] && grep -q "Main menu > Emulators > Steam Client" <<<"$WERR" \
  && ok "the bootstrap's one line says where to install it, and nothing more" || bad "stderr: $WERR"
mv "$W/bootstrap.real" "$W/bootstrap"

CASE="wrapper: LD_LIBRARY_PATH set"
echo 0 >"$W/codes"; rm -f "$W/count" "$W"/call*
"${WENV[@]}" LD_LIBRARY_PATH=/opt/x bash "$WRAP" 2>"$W/err"   # WENV unsets it, so it goes after
grep -qx "ld: $WROOT/steamrtarm64:$WROOT/steamrtarm64/video:/opt/x" "$W/call1" \
  && ok "the client's libraries come first, the caller's stay after them" || bad "$(grep ld: "$W/call1")"

CASE="wrapper: foreign D-Bus"
DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/0/bus" wrap 0
grep -qx "dbus: unset" "$W/call1" && ok "a bus socket that is not ours is dropped" || bad "$(grep dbus "$W/call1")"

CASE="wrapper: update restart"
wrap "42 42 7" steam://rungameid/1
[ "$(cat "$W/count")" = 3 ] && [ "$WRC" = 7 ] && ok "exit 42 starts the client again; the final status is returned" || bad "runs=$(cat "$W/count") rc=$WRC"
grep -qx "args: steam://rungameid/1" "$W/call3" && ok "with the same arguments" || bad "$(cat "$W/call3")"

CASE="wrapper: stopped by a signal"
echo S >"$W/codes"; rm -f "$W/count" "$W"/call* "$W/term" "$W/runpid"
"${WENV[@]}" bash "$WRAP" steam://rungameid/1 2>"$W/err" &
wpid=$!
for _ in $(seq 50); do [ -s "$W/runpid" ] && break; sleep 0.1; done
kill -TERM "$wpid"; wait "$wpid"; WRC=$?
[ -e "$W/term" ] && ok "a TERM to the wrapper reaches the client" || bad "the client never got TERM"
[ "$WRC" = 143 ] && [ "$(cat "$W/count")" = 1 ] && ok "and the wrapper exits with its status, without restarting" \
  || bad "rc=$WRC runs=$(cat "$W/count")"
pid="$(cat "$W/runpid" 2>/dev/null)"
[ -n "$pid" ] && ! kill -0 "$pid" 2>/dev/null && ok "nothing is left running" || { bad "client still running"; kill "$pid" 2>/dev/null; }

CASE="wrapper: bootstrap fails"
touch "$W/boot-fails"
wrap 0
[ "$WRC" = 1 ] && [ ! -e "$W/count" ] && grep -q "could not be set up" <<<"$WERR" && ok "exit 1, nothing run" || bad "rc=$WRC err=$WERR"
rm -f "$W/boot-fails"

CASE="wrapper: ~/.steam/steam is a real folder"
rm -f "$W/home/.steam/steam"; mkdir -p "$W/home/.steam/steam"
wrap 0
[ -d "$W/home/.steam/steam" ] && [ ! -L "$W/home/.steam/steam" ] && grep -q "leaving it alone" <<<"$WERR" \
  && ok "left alone, and said so" || bad "$(ls -la "$W/home/.steam")"
rmdir "$W/home/.steam/steam"

CASE="wrapper: SIGILL"
echo "Features	: fp asimd evtstrm crc32 cpuid" >"$W/cpuinfo"
wrap 132
[ "$WRC" = 132 ] && grep -q "kernel/patches/0025" <<<"$WERR" && ok "on a CPU without LSE it names the kernel patch" || bad "rc=$WRC err=$WERR"
echo "Features	: fp asimd evtstrm aes crc32 atomics fphp" >"$W/cpuinfo"
wrap 132
! grep -q "0025" <<<"$WERR" && ok "with LSE it does not" || bad "err=$WERR"

CASE="wrapper: the client fails"
wrap 1
[ "$WRC" = 1 ] && grep -q "the client exited with status 1" <<<"$WERR" && ok "a failed start is said" || bad "rc=$WRC err=$WERR"
wrap 0
! grep -q "exited with status" <<<"$WERR" && ok "a clean exit says nothing" || bad "err=$WERR"

# ================================================================================================
# Keeping Steam running between games.
CONF="$W/home/.config/retroforge/steam.conf"
STEAM_REAPER="$WROOT/linuxarm64/reaper"
SLOG="$WROOT/logs/console_log.txt"   # Steam's own log: one line per step of a launch
reset_keep() {
  rm -f "$W/unit-active" "$W/sdrun.args" "$W/sdrun-fails" "$W/kills" "$W/sysd.log" "$W/count" "$W"/call* "$CONF" "$SLOG"
  local d; for d in "$P"/*; do [ -d "$d" ] && gone "${d##*/}"; done
  echo 0 >"$W/codes"
}
step() {  # step <appid> <step> [stamp]: a line of Steam's log, now unless stamped
  mkdir -p "${SLOG%/*}"
  printf '[%s] GameAction [AppID %s, ActionID 1] : LaunchApp changed task to %s with ""\n' "${3:-$(date '+%F %T')}" "$1" "$2" >>"$SLOG"
}
bg_wrap() {  # bg_wrap [VAR=value...] -- args...: the wrapper in the background, as OGUI's launch
  local -a vars=()
  while [ "$1" != -- ]; do vars+=("$1"); shift; done; shift
  "${WENV[@]}" "${vars[@]}" bash "$WRAP" "$@" 2>"$W/err" &
  wpid=$!
}
finish() { until_true '! kill -0 "$wpid" 2>/dev/null'; wait "$wpid"; WRC=$?; }

CASE="keep: the setting"
reset_keep
out="$("${KENV[@]}" bash "$KEEP" status 2>"$W/kerr")"
[ "$out" = on ] && grep -q "the default" "$W/kerr" && ok "on by default" || bad "out=$out $(cat "$W/kerr")"
mkdir -p "${CONF%/*}"; printf '# mine\nDXVK_SAREK=on\n' >"$CONF"
out="$("${KENV[@]}" bash "$KEEP" on 2>"$W/kerr")"
[ "$out" = on ] && grep -qx "KEEP_RUNNING=on" "$CONF" && grep -qx "DXVK_SAREK=on" "$CONF" && grep -qx "# mine" "$CONF" \
  && ok "on is saved beside the DXVK-Sarek setting, which stays" || bad "out=$out conf=$(cat "$CONF")"
[ "$("${KENV[@]}" bash "$KEEP" status 2>/dev/null)" = on ] && ok "and read back" || bad "status after on"
[ "$("${KENV[@]}" RETROFORGE_STEAM_KEEP=off bash "$KEEP" status 2>/dev/null)" = off ] \
  && ok "RETROFORGE_STEAM_KEEP overrides the file" || bad "override ignored"
"${KENV[@]}" bash "$KEEP" sideways >/dev/null 2>&1; [ $? = 2 ] && ok "a bad invocation is exit 2" || bad "bad invocation"

CASE="keep: Steam's launches"
reset_keep
fakeproc 4242 1 reaper "$STEAM_REAPER" SteamLaunch AppId=42 -- "$WROOT/linuxarm64/steam-launch-wrapper" -- game
fakeproc 4343 1 reaper "$STEAM_REAPER" SteamLaunch AppId=43 -- game
fakeproc 5000 1 reaper /usr/share/opengamepadui/reaper SteamLaunch AppId=42 -- env steam steam://rungameid/42
fakeproc 5100 1 reaper "$STEAM_REAPER" SteamLaunch -- game AppId=42
fakeproc 5200 1 bash bash -c "reaper SteamLaunch AppId=42"
[ "$("${KENV[@]}" bash "$KEEP" games 42)" = 4242 ] \
  && ok "app 42's launch is Steam's reaper with AppId=42, not OGUI's reaper with the same arguments" \
  || bad "games 42: $("${KENV[@]}" bash "$KEEP" games 42 | tr '\n' ' ')"
[ "$("${KENV[@]}" bash "$KEEP" games | sort | tr '\n' ' ')" = "4242 4343 " ] \
  && ok "without an app id, every Steam launch; an AppId= after -- (the game's own argument) is none" \
  || bad "games: $("${KENV[@]}" bash "$KEEP" games | tr '\n' ' ')"

CASE="keep: ending a launch"
fakeproc 4244 4242 steam-launch-wr x; fakeproc 4245 4244 "game (main)" x; fakeproc 4300 1 other x
"${KENV[@]}" bash "$KEEP" end 42 2>"$W/kerr"
[ "$(cat "$W/kills" 2>/dev/null)" = "-TERM 4242 4244 4245" ] \
  && ok "TERM to Steam's reaper and everything under it, a command name with spaces and parens too" \
  || bad "kills: $(cat "$W/kills" 2>&1) $(cat "$W/kerr")"
[ -d "$P/4300" ] && [ -d "$P/4343" ] && [ -d "$P/5000" ] && ok "nothing else: another game, OGUI's reaper" || bad "$(ls "$P")"

CASE="keep: a launch's steps"
reset_keep
since="$(date '+%F %T')"
[ "$("${KENV[@]}" RETROFORGE_STEAM_ROOT="$WROOT" bash "$KEEP" launch 42 "$since")" = unknown ] \
  && ok "unknown without Steam's log" || bad "no log: $("${KENV[@]}" RETROFORGE_STEAM_ROOT="$WROOT" bash "$KEEP" launch 42 "$since")"
step 42 Completed "2020-01-01 00:00:00"; step 42 ProcessingInstallScript; step 43 Completed
echo "[$(date '+%F %T')] GameAction [AppID 42, ActionID 1] : LaunchApp waiting for user response to ShowLaunchOption \"\"" >>"$SLOG"
[ "$("${KENV[@]}" RETROFORGE_STEAM_ROOT="$WROOT" bash "$KEEP" launch 42 "$since")" = ProcessingInstallScript ] \
  && ok "the last step of that app since the launch: an earlier launch's Completed and another app's do not count" \
  || bad "launch 42: $("${KENV[@]}" RETROFORGE_STEAM_ROOT="$WROOT" bash "$KEEP" launch 42 "$since") $(cat "$SLOG")"
[ -z "$("${KENV[@]}" RETROFORGE_STEAM_ROOT="$WROOT" bash "$KEEP" launch 44 "$since")" ] \
  && ok "nothing before Steam has picked a launch up" || bad "launch 44"

CASE="keep: off stops an idle kept Steam"
reset_keep; touch "$W/unit-active"
fakeproc 4343 1 reaper "$STEAM_REAPER" SteamLaunch AppId=43 -- game
"${KENV[@]}" bash "$KEEP" off >/dev/null 2>"$W/kerr"
[ -e "$W/unit-active" ] && grep -q "stops when it ends" "$W/kerr" && ok "not while it runs a game" || bad "$(cat "$W/sysd.log") $(cat "$W/kerr")"
gone 4343
"${KENV[@]}" bash "$KEEP" off >/dev/null 2>&1
[ ! -e "$W/unit-active" ] && grep -q "stop retroforge-steam.service" "$W/sysd.log" && ok "stopped once it runs none" || bad "$(cat "$W/sysd.log")"

CASE="keep: off"
reset_keep
wrap 0 -gamepadui -silent steam://rungameid/42
[ "$(cat "$W/count")" = 1 ] && [ ! -e "$W/sdrun.args" ] && [ "$WRC" = 0 ] \
  && ok "the client runs with the launch, as before; no unit" || bad "rc=$WRC runs=$(cat "$W/count" 2>&1) $WERR"

CASE="keep: a game, Steam not running"
reset_keep
bg_wrap RETROFORGE_STEAM_KEEP=on OGUI_ID=Hades DISPLAY=:1 -- -gamepadui -silent steam://rungameid/42
until_true '[ -s "$W/sdrun.args" ]'
A="$(cat "$W/sdrun.args" 2>/dev/null)"
grep -qx -- "--user" <<<"$A" && grep -qx -- "--unit=retroforge-steam" <<<"$A" && grep -qx -- "--collect" <<<"$A" \
  && ok "starts the user unit retroforge-steam.service" || bad "systemd-run: $A"
grep -qx -- "--setenv=OGUI_ID=Steam" <<<"$A" && ! grep -q -- "--setenv=OGUI_ID=Hades" <<<"$A" \
  && ok "its OGUI_ID is Steam (Steam's UI launches find its windows), not the game's" || bad "systemd-run: $A"
grep -qx -- "--setenv=DISPLAY=:1" <<<"$A" && grep -qx -- "--setenv=RETROFORGE_STEAM_KEPT=1" <<<"$A" \
  && ok "with the launch's environment, and marked as the kept client" || bad "systemd-run: $A"
[ "$(tail -4 <<<"$A" | tr '\n' ' ')" = "$WRAP -gamepadui -silent steam://rungameid/42 " ] \
  && ok "running this wrapper with the launch's arguments" || bad "command: $(tail -4 <<<"$A" | tr '\n' ' ')"
[ ! -e "$W/count" ] && ok "the client is not run under OGUI's launch" || bad "runs=$(cat "$W/count")"
# As Hades on the Pocket FIT (2026-10-22): the install scripts under one reaper, then the game
# under another.
step 42 Completed "2020-01-01 00:00:00"; step 42 ProcessingInstallScript
fakeproc 4241 1 reaper "$STEAM_REAPER" SteamLaunch AppId=42 -- install-script
sleep 1.5; gone 4241; sleep 2.2
kill -0 "$wpid" 2>/dev/null && ok "the install scripts' reaper ending is not the game ending" || bad "exited after the install scripts: $(cat "$W/err")"
step 42 Completed; fakeproc 4242 1 reaper "$STEAM_REAPER" SteamLaunch AppId=42 -- game
sleep 2.2
kill -0 "$wpid" 2>/dev/null && ok "once Steam has created the game's process, the launch lasts while its reaper runs" || bad "exited early: $(cat "$W/err")"
gone 4242
finish
[ "$WRC" = 0 ] && [ -e "$W/unit-active" ] && ok "and ends with it, exit 0; Steam keeps running" || bad "rc=$WRC $(cat "$W/err")"

CASE="keep: a game, Steam kept"   # and no Steam log: the first reaper seen is the game's
reset_keep; touch "$W/unit-active"
fakeproc 4242 1 reaper "$STEAM_REAPER" SteamLaunch AppId=42 -- game
bg_wrap RETROFORGE_STEAM_KEEP=on -- -gamepadui -silent steam://rungameid/42
until_true '[ -e "$W/call1" ]'
grep -qx "args: -gamepadui -silent steam://rungameid/42" "$W/call1" && grep -qx "cwd: $WROOT/steamrtarm64" "$W/call1" \
  && grep -qx "ld: $WROOT/steamrtarm64:$WROOT/steamrtarm64/video" "$W/call1" && [ ! -e "$W/sdrun.args" ] \
  && ok "the launch's arguments are handed to the kept client (a second client process), no new unit" || bad "$(cat "$W/call1" 2>&1)"
sleep 0.5
kill -TERM "$wpid"; wait "$wpid"; WRC=$?
[ "$WRC" = 143 ] && [ "$(cat "$W/kills" 2>/dev/null)" = "-TERM 4242" ] && [ -e "$W/unit-active" ] \
  && ok "Exit from OGUI's menu (TERM) ends the game's launch, not Steam" || bad "rc=$WRC kills=$(cat "$W/kills" 2>&1) $(cat "$W/sysd.log")"

CASE="keep: Steam does not start the game"
reset_keep; touch "$W/unit-active"
fakeproc 5000 1 reaper /usr/share/opengamepadui/reaper SteamLaunch AppId=42 -- env steam
bg_wrap RETROFORGE_STEAM_KEEP=on RETROFORGE_STEAM_LAUNCH_WAIT=1 -- steam://rungameid/42
finish
[ "$WRC" = 1 ] && grep -q "did not start app 42 within 1 s" "$W/err" \
  && ok "gives up after RETROFORGE_STEAM_LAUNCH_WAIT s, and says where to look (OGUI's own reaper is not the game)" || bad "rc=$WRC $(cat "$W/err")"
reset_keep; touch "$W/unit-active"
bg_wrap RETROFORGE_STEAM_KEEP=on -- steam://rungameid/42
until_true '[ -e "$W/call1" ]'; rm -f "$W/unit-active"
finish
[ "$WRC" = 1 ] && grep -q "stopped before it started app 42" "$W/err" && ok "or as soon as the kept Steam stops" || bad "rc=$WRC $(cat "$W/err")"
reset_keep; touch "$W/unit-active"
bg_wrap RETROFORGE_STEAM_KEEP=on -- steam://rungameid/42
until_true '[ -e "$W/call1" ]'; step 42 Failed
finish
[ "$WRC" = 1 ] && grep -q "could not start app 42" "$W/err" && ok "or when Steam refuses the launch" || bad "rc=$WRC $(cat "$W/err")"

CASE="keep: launched again while it runs"
reset_keep; touch "$W/unit-active"
fakeproc 4242 1 reaper "$STEAM_REAPER" SteamLaunch AppId=42 -- game
bg_wrap RETROFORGE_STEAM_KEEP=on -- steam://rungameid/42
until_true '[ -e "$W/call1" ]'; step 42 Failed   # AppError_16
sleep 2.2
kill -0 "$wpid" 2>/dev/null && ok "Steam refuses it (the game already runs): the launch follows the running game" || bad "exited: $(cat "$W/err")"
gone 4242
finish
[ "$WRC" = 0 ] && ok "and ends with it" || bad "rc=$WRC $(cat "$W/err")"

CASE="keep: turned off during a game"
reset_keep; touch "$W/unit-active"
fakeproc 4242 1 reaper "$STEAM_REAPER" SteamLaunch AppId=42 -- game
bg_wrap RETROFORGE_STEAM_KEEP=off -- steam://rungameid/42
until_true '[ -e "$W/call1" ]'
[ ! -e "$W/sdrun.args" ] && ok "a kept client still gets the launch" || bad "a unit was started"
gone 4242
finish
[ "$WRC" = 0 ] && [ ! -e "$W/unit-active" ] && ok "and is stopped when the game ends" || bad "rc=$WRC $(cat "$W/sysd.log" 2>&1)"

CASE="keep: Steam's UI"
reset_keep; touch "$W/unit-active"
bg_wrap RETROFORGE_STEAM_KEEP=on -- -gamepadui -steamos3 -steampal -steamdeck
until_true '[ -e "$W/call1" ]'
grep -qx "args: -gamepadui -steamos3 -steampal -steamdeck" "$W/call1" && ok "handed to the kept client" || bad "$(cat "$W/call1" 2>&1)"
sleep 1.2
kill -0 "$wpid" 2>/dev/null && ok "and stays while it runs" || bad "exited: $(cat "$W/err")"
rm -f "$W/unit-active"
finish
[ "$WRC" = 0 ] && ok "until it stops" || bad "rc=$WRC"
reset_keep; touch "$W/unit-active"
bg_wrap RETROFORGE_STEAM_KEEP=on -- -gamepadui
until_true '[ -e "$W/call1" ]'; sleep 0.3
kill -TERM "$wpid"; wait "$wpid"; WRC=$?
[ "$WRC" = 143 ] && [ -e "$W/unit-active" ] && [ ! -e "$W/kills" ] && ok "or OGUI stops it: Steam keeps running" || bad "rc=$WRC $(cat "$W/kills" 2>&1)"

CASE="keep: no user manager"
reset_keep; touch "$W/sdrun-fails"
RETROFORGE_STEAM_KEEP=on wrap 0 -silent steam://rungameid/42
[ "$WRC" = 0 ] && [ "$(cat "$W/count")" = 1 ] && grep -qx "args: -silent steam://rungameid/42" "$W/call1" \
  && grep -q "could not start Steam as the user unit" <<<"$WERR" && ok "the client runs with the launch, and it is said" || bad "rc=$WRC $WERR"

CASE="keep: inside the unit"
reset_keep; touch "$W/unit-active"
RETROFORGE_STEAM_KEEP=on RETROFORGE_STEAM_KEPT=1 wrap 0 -silent steam://rungameid/42
[ "$WRC" = 0 ] && [ "$(cat "$W/count")" = 1 ] && ! grep -q "handing" <<<"$WERR" \
  && ok "the unit's own run is the client itself, not a hand-over to itself" || bad "rc=$WRC $WERR"

# Minimal: a client (7000, named in ~/.steam/steam.pid) with its web helper (7100) and two of the
# helper's children. parkkill stands in for kill: KILL takes a process away, and killing a helper
# makes the client start another (pid + 100) that has already started a child of its own; STOP and
# CONT set its state.
cat >"$W/bin/parkkill" <<EOF
#!/usr/bin/env bash
sig=\$1; shift; echo "\$sig \$*" >>"$W/kills"
for p in "\$@"; do
  case "\$sig" in
    -KILL)
      if grep -qaF steamwebhelper "$P/\$p/cmdline" 2>/dev/null && [ "\$(cut -d' ' -f4 "$P/\$p/stat")" = 7000 ] \\
         && [ ! -e "$W/no-restart" ]; then
        n=\$((p + 100)); mkdir -p "$P/\$n" "$P/\$((n + 1))"
        echo steamwebhelper >"$P/\$n/comm"; printf '%s\0' "$WROOT/steamrtarm64/steamwebhelper" >"$P/\$n/cmdline"
        echo "\$n (steamwebhelper) S 7000 \$n \$n 0 -1" >"$P/\$n/stat"
        echo steamwebhelper >"$P/\$((n + 1))/comm"; printf '%s\0' "$WROOT/steamrtarm64/steamwebhelper" --type=zygote >"$P/\$((n + 1))/cmdline"
        echo "\$((n + 1)) (steamwebhelper) S \$n \$n \$n 0 -1" >"$P/\$((n + 1))/stat"
        [ -d "$P/7000/task/7000" ] && echo "\$n 7050" >"$P/7000/task/7000/children"
      fi
      rm -rf "$P/\${p:?}" ;;
    -STOP) printf 'State:\tT (stopped)\n' >"$P/\$p/status" ;;
    -CONT) printf 'State:\tS (sleeping)\n' >"$P/\$p/status" ;;
  esac
done
EOF
chmod +x "$W/bin/parkkill"
MENV=("${KENV[@]}" RETROFORGE_STEAM_KEEP_KILL="$W/bin/parkkill" RETROFORGE_STEAM_PARK_WAIT=2)
reset_minimal() {
  reset_keep; rm -rf "$W/run" "$W/no-restart"
  mkdir -p "$W/home/.steam"; echo 7000 >"$W/home/.steam/steam.pid"
  fakeproc 7000 1 steam "$WROOT/steamrtarm64/steam" -gamepadui
  fakeproc 7100 7000 steamwebhelper "$WROOT/steamrtarm64/steamwebhelper"
  fakeproc 7101 7100 steamwebhelper "$WROOT/steamrtarm64/steamwebhelper" --type=zygote
  fakeproc 7102 7101 steamwebhelper "$WROOT/steamrtarm64/steamwebhelper" --type=renderer
  fakeproc 7050 7000 steam-launch-wrapper "$WROOT/linuxarm64/steam-launch-wrapper" -- game
}
state_of() { sed -n 's/^State:[[:space:]]*\(.\).*/\1/p' "$P/$1/status" 2>/dev/null; }

CASE="keep: minimal"
reset_minimal
"${MENV[@]}" bash "$KEEP" minimal 2>"$W/kerr"; RC=$?
[ "$RC" = 0 ] && [ "$(state_of 7200)" = T ] && grep -qx -- "-KILL 7100" "$W/kills" && grep -qx -- "-STOP 7200" "$W/kills" \
  && ok "the web helper is killed, and the one the client starts again frozen" || bad "rc=$RC kills=$(cat "$W/kills" 2>&1) $(cat "$W/kerr")"
grep -qx -- "-KILL 7201" "$W/kills" && [ ! -e "$P/7201" ] && ok "with what it had started already" || bad "kills=$(cat "$W/kills")"
[ -e "$P/7050" ] && ! grep -q 7050 "$W/kills" && ok "the client's other children (a game) are left alone" || bad "kills=$(cat "$W/kills")"
grep -q "client stays signed in" "$W/kerr" && ok "and it is said" || bad "$(cat "$W/kerr")"
: >"$W/kills"
"${MENV[@]}" bash "$KEEP" minimal 2>/dev/null; RC=$?
[ "$RC" = 0 ] && [ ! -s "$W/kills" ] && ok "frozen already: nothing is killed" || bad "rc=$RC kills=$(cat "$W/kills")"
out="$("${MENV[@]}" bash "$KEEP" full 2>/dev/null)"
[ "$(state_of 7200)" = S ] && grep -qx -- "-CONT 7200" "$W/kills" && [ "$out" = woke ] \
  && ok "full: the frozen helper goes on (Steam's UI comes back), and says it woke it" || bad "out=$out kills=$(cat "$W/kills")"
out="$("${MENV[@]}" bash "$KEEP" full 2>/dev/null)"
[ -z "$out" ] && ok "full again: nothing to wake, nothing said" || bad "out=$out"
: >"$W/kills"
"${MENV[@]}" bash "$KEEP" minimal 2>/dev/null
[ "$(state_of 7300)" = T ] && grep -qx -- "-KILL 7200" "$W/kills" && ok "minimal again after it ran: killed and frozen anew" || bad "kills=$(cat "$W/kills")"

CASE="keep: minimal, the kernel's list of children"
reset_minimal; mkdir -p "$P/7000/task/7000"; echo "7100 7050" >"$P/7000/task/7000/children"
fakeproc 7400 7000 steamwebhelper "$WROOT/steamrtarm64/steamwebhelper"   # not in the list
"${MENV[@]}" bash "$KEEP" minimal 2>/dev/null; RC=$?
[ "$RC" = 0 ] && [ "$(state_of 7200)" = T ] && grep -qx -- "-KILL 7100" "$W/kills" && ! grep -q 7400 "$W/kills" \
  && ok "read from /proc/<client>/task/*/children when the kernel has it, not by scanning every process" || bad "rc=$RC kills=$(cat "$W/kills" 2>&1)"

CASE="keep: holds"
reset_minimal; fakeproc 4444 1 bash /usr/bin/steam -gamepadui
"${MENV[@]}" bash "$KEEP" full 4444 2>/dev/null
"${MENV[@]}" bash "$KEEP" minimal 2>/dev/null
[ ! -e "$W/kills" ] && [ -e "$P/7100" ] && ok "a live launch's hold keeps Steam's UI running" || bad "kills=$(cat "$W/kills")"
"${MENV[@]}" bash "$KEEP" minimal 4444 2>/dev/null
[ "$(state_of 7200)" = T ] && ok "until that launch lets go of it (minimal PID)" || bad "kills=$(cat "$W/kills" 2>&1)"
reset_minimal; fakeproc 4444 1 bash /usr/bin/steam -gamepadui
"${MENV[@]}" bash "$KEEP" full 4444 2>/dev/null; gone 4444
"${MENV[@]}" bash "$KEEP" minimal 2>/dev/null
[ "$(state_of 7200)" = T ] && [ ! -e "$W/run/retroforge-steam-full/4444" ] && ok "the hold of a launch that is gone counts for nothing, and goes" || bad "$(ls "$W/run/retroforge-steam-full" 2>&1)"
"${MENV[@]}" bash "$KEEP" minimal 4a 2>/dev/null; [ $? = 2 ] && ok "a PID that is not a number is a bad invocation" || bad "minimal 4a"

CASE="keep: minimal, no client"
reset_minimal; rm -f "$W/home/.steam/steam.pid"
"${MENV[@]}" bash "$KEEP" minimal 2>/dev/null; RC=$?
[ "$RC" = 0 ] && [ ! -e "$W/kills" ] && ok "no client running: nothing to do" || bad "rc=$RC kills=$(cat "$W/kills" 2>&1)"
reset_minimal; touch "$W/no-restart"
"${MENV[@]}" bash "$KEEP" minimal 2>"$W/kerr"; RC=$?
[ "$RC" = 1 ] && grep -q "did not start its web helper again within 2 s" "$W/kerr" \
  && ok "a client that does not start its helper again: exit 1, and it is said" || bad "rc=$RC $(cat "$W/kerr")"

# The wrapper's holds: retroforge-steam-keep through keeplog, which records how it is called and
# whether the client had the launch yet ($W/call1).
cat >"$W/bin/keeplog" <<EOF
#!/usr/bin/env bash
case "\$1" in full|minimal) echo "\$1\${2:+ pid} \$([ -e "$W/call1" ] && echo handed || echo first)" >>"$W/keep.calls" ;; esac
exec bash "$KEEP" "\$@"
EOF
chmod +x "$W/bin/keeplog"

CASE="keep: a game through the kept client"
CTL="$WROOT/logs/controller_ui.txt"
reset_keep; rm -f "$W/keep.calls"; touch "$W/unit-active"; mkdir -p "${CTL%/*}"
echo "[2026-10-25 03:16:43] OnFocusWindowChanged to game window type: AppID 42, 42" >"$CTL"   # an earlier run's
bg_wrap RETROFORGE_STEAM_KEEP=on RETROFORGE_STEAM_KEEP_CLI="$W/bin/keeplog" RETROFORGE_STEAM_MINIMAL_DELAY=1 -- steam://rungameid/42
until_true '[ -e "$W/call1" ]'
[ "$(head -1 "$W/keep.calls" 2>/dev/null)" = "full pid first" ] \
  && ok "Steam's UI comes back before the launch is handed over (its dialogs, install scripts, shader prompt)" || bad "keep: $(cat "$W/keep.calls" 2>&1)"
step 42 Completed; fakeproc 4242 1 reaper "$STEAM_REAPER" SteamLaunch AppId=42 -- game
sleep 2.5
! grep -q "^minimal" "$W/keep.calls" && ok "not minimal while Steam has not switched the controller to the game (an earlier run's line does not count)" \
  || bad "keep: $(cat "$W/keep.calls" 2>&1)"
echo "[2026-10-25 03:30:20] OnFocusWindowChanged to game window type: AppID 42, 42" >>"$CTL"
until_true 'grep -q "^minimal pid" "$W/keep.calls"'
kill -0 "$wpid" 2>/dev/null && grep -q "^minimal pid" "$W/keep.calls" \
  && ok "minimal RETROFORGE_STEAM_MINIMAL_DELAY s after it has, the launch still on" || bad "keep: $(cat "$W/keep.calls" 2>&1)"
gone 4242
finish
[ "$WRC" = 0 ] && [ "$(tail -1 "$W/keep.calls")" = "minimal pid handed" ] && [ -e "$W/unit-active" ] \
  && ok "and stays minimal when the game ends" || bad "rc=$WRC keep: $(cat "$W/keep.calls" 2>&1)"

CASE="keep: Steam's UI, woken first"
# keep CLI stub: the client was minimal, so `full` wakes its UI.
cat >"$W/bin/keepwoke" <<EOF
#!/usr/bin/env bash
case "\$1" in full) echo woke ;; status) echo on ;; esac
EOF
chmod +x "$W/bin/keepwoke"
reset_keep; touch "$W/unit-active"; mkdir -p "${SLOG%/*}"; echo "[2026-10-25 03:40:00] an older line" >"$SLOG"
bg_wrap RETROFORGE_STEAM_KEEP=on RETROFORGE_STEAM_KEEP_CLI="$W/bin/keepwoke" RETROFORGE_STEAM_UI_SETTLE=0 -- -gamepadui steam://open/bigpicture
sleep 1.5
[ ! -e "$W/call1" ] && ok "Steam's UI from a minimal client: not handed over while the UI starts again" || bad "handed over at once: $(cat "$W/call1" 2>&1)"
echo "[2026-10-25 03:44:10] STARTUP SlowJSMethodCall Settings.RegisterForSettingsChanges took 9.4ms" >>"$SLOG"
until_true '[ -e "$W/call1" ]'
grep -qx "args: -gamepadui steam://open/bigpicture" "$W/call1" 2>/dev/null && ok "but once its first calls are in Steam's log" || bad "$(cat "$W/call1" 2>&1)"
kill -TERM "$wpid"; wait "$wpid" 2>/dev/null
reset_keep; touch "$W/unit-active"
bg_wrap RETROFORGE_STEAM_KEEP=on RETROFORGE_STEAM_KEEP_CLI="$W/bin/keepwoke" RETROFORGE_STEAM_UI_WAIT=1 RETROFORGE_STEAM_UI_SETTLE=0 -- -gamepadui steam://open/bigpicture
until_true '[ -e "$W/call1" ]'
[ -e "$W/call1" ] && ok "or after RETROFORGE_STEAM_UI_WAIT s without them" || bad "never handed over"
kill -TERM "$wpid"; wait "$wpid" 2>/dev/null
reset_keep; touch "$W/unit-active"
step 42 Completed; fakeproc 4242 1 reaper "$STEAM_REAPER" SteamLaunch AppId=42 -- game
bg_wrap RETROFORGE_STEAM_KEEP=on RETROFORGE_STEAM_KEEP_CLI="$W/bin/keepwoke" -- steam://rungameid/42
sleep 1
[ -e "$W/call1" ] && ok "a game is handed over at once (Steam queues its launch until the UI is up)" || bad "a game waited"
kill -TERM "$wpid"; wait "$wpid" 2>/dev/null

CASE="keep: Steam's UI holds it"
reset_keep; rm -f "$W/keep.calls"; touch "$W/unit-active"
bg_wrap RETROFORGE_STEAM_KEEP=on RETROFORGE_STEAM_KEEP_CLI="$W/bin/keeplog" RETROFORGE_STEAM_MINIMAL_DELAY=0 -- -gamepadui -steamos3
until_true '[ -e "$W/call1" ]'; sleep 1.2
[ "$(cat "$W/keep.calls")" = "full pid first" ] && ls "$W/run/retroforge-steam-full/$wpid" >/dev/null 2>&1 \
  && ok "Steam's UI, while OGUI shows it: running, held by the launch" || bad "keep: $(cat "$W/keep.calls" 2>&1) $(ls "$W/run/retroforge-steam-full" 2>&1)"
kill -TERM "$wpid"; wait "$wpid"; WRC=$?
[ "$WRC" = 143 ] && [ "$(tail -1 "$W/keep.calls")" = "minimal pid handed" ] && [ ! -e "$W/run/retroforge-steam-full/$wpid" ] \
  && ok "OGUI closes it: minimal again, the hold gone" || bad "rc=$WRC keep: $(cat "$W/keep.calls" 2>&1)"
reset_keep

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
