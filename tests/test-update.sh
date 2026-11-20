#!/usr/bin/env bash
# Offline test for /usr/bin/retroforge-update — the OTA client the shell drives.
#
#   tests/test-update.sh
#
# WHY THIS FILE EXISTS. The caller (the RetroForge shell plugin) PARSES STDOUT, under a contract
# inherited from the steamos-update interface. `check` printing the wrong thing is not
# a cosmetic bug — anything on stdout that is not a version string becomes "an update is available,
# called <that>", and a stray traceback would offer the fleet an update named `Traceback`. Every
# case below is really one assertion: does the shipped file honour a contract we do not control.
#
# The second reason is duplicate detection. The caller refuses to re-offer a version it already applied,
# so an identity that changes between two calls makes one update look like two, and an identity
# that never changes makes a real update invisible. That rule is written TWICE — in shell in
# ota/genbundle.sh and in Python here — and `identity-rules-agree` below is the only thing that
# makes them stay the same rule. Phase 2 exists because those two strings had drifted apart.
#
# HOW IT WORKS: the real, shipped rootfs/overlay/usr/bin/retroforge-update is executed — not a copy, not a
# sed-mangled variant. It exposes the environment seams documented in its own header
# (RETROFORGE_RELEASE_FILE, RETROFORGE_OTA_CONFIG, RETROFORGE_OTA_USER_CONFIG, RETROFORGE_OTA_STAGE, RETROFORGE_SHELL_SETTINGS,
# RETROFORGE_CURL, RETROFORGE_OTA_URL) and they exist for this file. curl is stubbed on disk so no test
# touches the network. Nothing here needs rauc, a bus, a server or a device.
#
# WHAT THIS CANNOT COVER: the install half. `apply`'s D-Bus conversation with rauc needs a bus, and
# the only evidence that matters about a real install is a hardware one (see docs/worklog/DONE.md). What is
# covered is everything up to InstallBundle, which is where every decision gets made.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CLIENT="$ROOT/rootfs/overlay/usr/bin/retroforge-update"
GENBUNDLE="$ROOT/ota/genbundle.sh"
[ -f "$CLIENT" ] || { echo "no retroforge-update: $CLIENT" >&2; exit 1; }

PASS=0; FAIL=0; CASE=""
ok()  { PASS=$((PASS+1)); printf '  ok   %s -- %s\n' "$CASE" "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s -- %s\n' "$CASE" "$1"; }

W="$(mktemp -d)"
trap 'rm -rf "$W"' EXIT

# Loading retroforge-update as a module writes a __pycache__ into rootfs/overlay/usr/bin, which the
# assembler copies into the rootfs verbatim. Keep the bytecode in the sandbox.
export PYTHONPYCACHEPREFIX="$W/pycache"

# --- the sandbox ---------------------------------------------------------------------------------
#
# A curl stub rather than a real server: it answers from files under $W/www, keyed by the URL path,
# which is enough to exercise every branch the client has. It also RECORDS each request, so a case
# can assert that a fetch did NOT happen — that is the only way to prove the disk-space guard runs
# before the download rather than after it, which is the whole point of that guard.
mkdir -p "$W/bin" "$W/www" "$W/stage"
cat >"$W/bin/curl" <<'STUB'
#!/usr/bin/env bash
# Faithful enough for the two shapes the client uses: a plain GET to stdout, and -o <dest> for the
# bundle. Exits 22 like the real curl's -f on a missing document.
url=""; dest=""
# The FULL argv, not just the path: the stall-abort case asserts which flags the download carries
# and the manifest fetch does not, and those are invisible in requests.log.
printf '%s\n' "$*" >> "$WWW/../argv.log"
while [ $# -gt 0 ]; do
  case "$1" in
    -o) dest="$2"; shift 2 ;;
    http*|https*) url="$1"; shift ;;
    *) shift ;;
  esac
done
path="${url#*://}"; path="${path#*/}"
printf '%s\n' "$path" >> "$WWW/../requests.log"
src="$WWW/$path"
[ -f "$src" ] || exit 22
if [ -n "$dest" ]; then cp "$src" "$dest"; else cat "$src"; fi
STUB
chmod +x "$W/bin/curl"

# Every check and install needs the hosted channel list (EXIT_NO_CHANNELS), so the sandbox serves
# the repository's own ota/channels.json at the URL run() points the client at, unless a case removes it.
cp "$ROOT/ota/channels.json" "$W/www/channels.json"

# First-boot setup is done unless a case says otherwise: the setup gate is tested explicitly, and
# every other case would otherwise pass for the wrong reason. The shape is what OpenGamepadUI's
# ConfigFile writes, including a [general.updates] section that must not be mistaken for [general].
printf '[general]\n\nfirst_boot=false\n\n[general.updates]\n\nauto_update=false\n' >"$W/settings.cfg"

release_file() { # <version> [build] [mode] -> path
  local f="$W/release-$1"
  { echo "RETROFORGE_VARIANT=unified"
    echo "RETROFORGE_BUILD=${2:-20260101T000000Z}"
    echo "RETROFORGE_VERSION=$1"
    echo "RETROFORGE_GIT=abc1234"
    echo "RETROFORGE_MODE=${3:-release}"
  } >"$f"
  printf '%s' "$f"
}

manifest() { # <channel> <json>
  mkdir -p "$W/www/$1"
  printf '%s\n' "$2" >"$W/www/$1/latest.json"
}

bundle_file() { # <channel> <name> <bytes>
  mkdir -p "$W/www/$1"
  head -c "$3" /dev/zero >"$W/www/$1/$2"
}

# Runs the SHIPPED client. Sets OUT/ERR/RC. Extra env comes in as VAR=VAL arguments.
run() { # <arg...> -- with env assignments allowed before the first non-assignment
  local -a envs=()
  while [ $# -gt 0 ] && [[ $1 == *=* ]]; do envs+=("$1"); shift; done
  : >"$W/requests.log"
  : >"$W/argv.log"
  OUT="$(env PATH="$W/bin:$PATH" WWW="$W/www" \
      RETROFORGE_CURL="$W/bin/curl" \
      RETROFORGE_OTA_URL="https://updates.example" \
      RETROFORGE_OTA_CONFIG="$W/nonexistent.conf" \
      RETROFORGE_OTA_STAGE="$W/stage" \
      RETROFORGE_SHELL_SETTINGS="$W/settings.cfg" \
      RETROFORGE_OTA_CHANNELS_URL="https://lists.example/channels.json" \
      "${envs[@]}" python3 "$CLIENT" "$@" 2>"$W/err")"
  RC=$?
  ERR="$(cat "$W/err")"
}

requests() { wc -l <"$W/requests.log" | tr -d ' '; }

# =================================================================================================
CASE="probe"
# --supports-duplicate-detection is how the caller asks whether it may dedupe by the printed version.
# Exit 0 opts in. Getting this wrong silently disables the mechanism the rest of the file protects.
run --supports-duplicate-detection
[ "$RC" = 0 ] && ok "exits 0 (opts in to duplicate detection)" \
              || bad "exit $RC, expected 0 — the caller would not dedupe"

# =================================================================================================
CASE="no-update"
manifest stable '{"version":"1.0.0","bundle":"retroforge-1.0.0.raucb","size":100}'
run RETROFORGE_RELEASE_FILE="$(release_file 1.0.0)" RETROFORGE_OTA_CHANNEL=stable check
[ "$RC" = 7 ] && ok "exit 7 when the server offers what we run" \
              || bad "exit $RC, expected 7"
# "Prints nothing" is a separate assertion from the exit code, and the more important one: the caller
# reads stdout regardless of the status.
[ -z "$OUT" ] && ok "stdout is empty" \
              || bad "printed '$OUT' — the caller parses stdout as an available version"

# =================================================================================================
CASE="update-available"
manifest stable '{"version":"1.1.0","bundle":"retroforge-1.1.0.raucb","size":100}'
run RETROFORGE_RELEASE_FILE="$(release_file 1.0.0)" RETROFORGE_OTA_CHANNEL=stable check
[ "$RC" = 0 ] && ok "exit 0" || bad "exit $RC, expected 0"
[ "$OUT" = "1.1.0" ] && ok "prints exactly the version" \
                     || bad "printed '$OUT', expected '1.1.0'"

# =================================================================================================
CASE="duplicate-detection"
# The same check twice must print the SAME string. A version derived from anything time-varying
# would make one update look like two, and the caller would re-offer it forever.
#
# IT READS $OUT FROM THE CASE ABOVE, so it has to stay adjacent to it — inserting a case between
# the two silently changes what "the same check twice" compares (caught doing exactly that).
first="$OUT"
run RETROFORGE_RELEASE_FILE="$(release_file 1.0.0)" RETROFORGE_OTA_CHANNEL=stable check
[ "$OUT" = "$first" ] && ok "two checks print the same identity ('$OUT')" \
                      || bad "identity changed between calls: '$first' then '$OUT'"

# =================================================================================================
CASE="channel-precedence"
# The channel has FOUR sources and the order between them is a product decision, not a detail.
# USER_CONFIG_FILE is the only one a user can write on a release device — no sudo on the image,
# pairingd hands out a `player` login and never root's — so without it the channel is whatever the
# image says, forever, and the shell (which carries no environment of ours) can never be aimed
# anywhere else. With it, /etc still wins: the one image that ships /etc/retroforge/ota.conf is a dev
# card, where the pin stops the card being offered a stable release that would downgrade it, and a
# file in $HOME must not undo that quietly.
manifest etcchan  '{"version":"2.0.0","bundle":"retroforge-2.0.0.raucb","size":100}'
manifest userchan '{"version":"3.0.0","bundle":"retroforge-3.0.0.raucb","size":100}'
manifest envchan  '{"version":"4.0.0","bundle":"retroforge-4.0.0.raucb","size":100}'
printf 'OTA_CHANNEL=etcchan\n'  >"$W/etc-ota.conf"
printf 'OTA_CHANNEL=userchan\n' >"$W/user-ota.conf"

run RETROFORGE_RELEASE_FILE="$(release_file 1.0.0)" \
    RETROFORGE_OTA_USER_CONFIG="$W/user-ota.conf" check
[ "$OUT" = "3.0.0" ] && ok "a user file with no /etc file and no env steers the check" \
                     || bad "printed '$OUT', expected '3.0.0' — the user file was ignored"

run RETROFORGE_RELEASE_FILE="$(release_file 1.0.0)" \
    RETROFORGE_OTA_CONFIG="$W/etc-ota.conf" RETROFORGE_OTA_USER_CONFIG="$W/user-ota.conf" check
[ "$OUT" = "2.0.0" ] && ok "/etc outranks the user file (the dev pin cannot be undone from \$HOME)" \
                     || bad "printed '$OUT', expected '2.0.0' — the user file overrode the pin"

run RETROFORGE_RELEASE_FILE="$(release_file 1.0.0)" RETROFORGE_OTA_CHANNEL=envchan \
    RETROFORGE_OTA_CONFIG="$W/etc-ota.conf" RETROFORGE_OTA_USER_CONFIG="$W/user-ota.conf" check
[ "$OUT" = "4.0.0" ] && ok "the environment still outranks both files" \
                     || bad "printed '$OUT', expected '4.0.0'"

# `status` must name the source, not just the winner. Three of the four are invisible on a device
# — an env var in someone else's environment, a file a release does not ship, a file in $HOME
# nobody remembers writing — so "it is checking the wrong channel" is otherwise unanswerable.
run RETROFORGE_RELEASE_FILE="$(release_file 1.0.0)" \
    RETROFORGE_OTA_USER_CONFIG="$W/user-ota.conf" status
printf '%s\n' "$OUT" | grep -q "channel from $W/user-ota.conf" \
  && ok "status names the file the channel came from" \
  || bad "status does not say where the channel came from: $OUT"

# The user file may choose a channel on the pinned host; it may NOT choose the host. Same signature
# gate either way, but where a device fetches from is an operator decision, and one writable file in
# $HOME must not silently aim every future update somewhere else.
printf 'OTA_CHANNEL=userchan\nOTA_URL=https://evil.example\n' >"$W/user-ota.conf"
run RETROFORGE_RELEASE_FILE="$(release_file 1.0.0)" RETROFORGE_OTA_URL= \
    RETROFORGE_OTA_USER_CONFIG="$W/user-ota.conf" check
if grep -q 'evil\.example' "$W/argv.log"; then
  bad "the user file repointed the server: $(cat "$W/argv.log")"
else
  ok "OTA_URL in the user file is ignored — the fetch stayed on the built-in host"
fi
printf 'OTA_CHANNEL=userchan\n' >"$W/user-ota.conf"

# =================================================================================================
CASE="setup-not-done"
# The OOBE gate. A multi-gigabyte download before the user reaches the library is the wrong first
# impression. OpenGamepadUI's first-boot flow is what writes `[general] first_boot=false`; until it
# has, every check is a silent 7 and makes no request at all.
gate_case() { # <label> <settings file>
  run RETROFORGE_RELEASE_FILE="$(release_file 1.0.0)" RETROFORGE_OTA_CHANNEL=stable \
      RETROFORGE_SHELL_SETTINGS="$2" check
  [ "$RC" = 7 ] && [ -z "$OUT" ] && [ "$(requests)" = 0 ] \
    && ok "$1: exit 7, silent, no request" \
    || bad "$1: exit $RC out='$OUT' requests=$(requests), expected a silent 7 with no fetch"
}
gate_case "no settings file" "$W/absent.cfg"
printf '[general]\n\nfirst_boot=true\n' >"$W/fb-true.cfg"
gate_case "first_boot=true" "$W/fb-true.cfg"
printf '[general]\n\nlanguage="en"\n' >"$W/fb-missing.cfg"
gate_case "first_boot key missing (OGUI shows the OOBE)" "$W/fb-missing.cfg"
printf '[general]\n\nlanguage="en"\n\n[general.updates]\n\nfirst_boot=false\n' >"$W/fb-other.cfg"
gate_case "first_boot=false in another section" "$W/fb-other.cfg"
# And the other direction: the default fixture (setup done) does reach the server.
manifest stable '{"version":"1.1.0","bundle":"retroforge-1.1.0.raucb","size":100}'
run RETROFORGE_RELEASE_FILE="$(release_file 1.0.0)" RETROFORGE_OTA_CHANNEL=stable check
[ "$RC" = 0 ] && [ "$OUT" = "1.1.0" ] && ok "setup done: the check goes through" \
                                      || bad "setup done but exit $RC out='$OUT'"
run RETROFORGE_RELEASE_FILE="$(release_file 1.0.0)" RETROFORGE_OTA_CHANNEL=stable \
    RETROFORGE_SHELL_SETTINGS="$W/fb-true.cfg" status
printf '%s\n' "$OUT" | grep -q 'first boot not finished' \
  && ok "status says why updates are deferred" || bad "status hides the gate: $OUT"

# =================================================================================================
CASE="unreachable-server"
# Fail CLOSED. A check that cannot reach the server must not answer "yes", and must not crash: an
# unhandled traceback on stdout would be read as a version string.
run RETROFORGE_RELEASE_FILE="$(release_file 1.0.0)" RETROFORGE_OTA_CHANNEL=missing check
[ "$RC" = 7 ] && ok "exit 7 when the manifest 404s" || bad "exit $RC, expected 7"
[ -z "$OUT" ] && ok "stdout stays empty" || bad "printed '$OUT'"
case "$ERR" in *Traceback*) bad "leaked a traceback" ;; *) ok "reported the reason on stderr" ;; esac

# =================================================================================================
CASE="malformed-manifest"
manifest broken '{"version": "1.1.0", oops'
run RETROFORGE_RELEASE_FILE="$(release_file 1.0.0)" RETROFORGE_OTA_CHANNEL=broken check
[ "$RC" = 7 ] && [ -z "$OUT" ] && ok "unparseable JSON -> silent 7" \
                              || bad "exit $RC out='$OUT'"

# =================================================================================================
CASE="bundle-name-is-a-redirect-primitive"
# `bundle` is concatenated into a URL the client then fetches. Left unchecked it aims the device at
# another host or another path. The signature would still reject whatever came back, but a manifest
# must not be able to point this device anywhere at all.
i=0
for evil in '../../etc/passwd' 'http://elsewhere/x.raucb' '/etc/passwd' 'a/b.raucb' '.hidden'; do
  i=$((i+1))
  manifest "evil$i" "{\"version\":\"9.9.9\",\"bundle\":\"$evil\",\"size\":100}"
  run RETROFORGE_RELEASE_FILE="$(release_file 1.0.0)" RETROFORGE_OTA_CHANNEL="evil$i" check
  [ "$RC" = 7 ] && [ -z "$OUT" ] && ok "rejected bundle=$evil" \
                                || bad "ACCEPTED bundle=$evil (exit $RC, out='$OUT')"
done

# =================================================================================================
CASE="missing-size"
# Nothing sizes a download any more (rauc streams), so this no longer guards an allocation -- it
# guards the MANIFEST. A latest.json without a usable size is malformed, and a malformed manifest
# must be refused rather than partially honoured.
manifest nosize '{"version":"9.9.9","bundle":"retroforge-9.9.9.raucb"}'
run RETROFORGE_RELEASE_FILE="$(release_file 1.0.0)" RETROFORGE_OTA_CHANNEL=nosize check
[ "$RC" = 7 ] && ok "manifest with no usable size -> 7" || bad "exit $RC, expected 7"

# =================================================================================================
CASE="streams-rather-than-downloading"
#
# REPLACES THREE CASES that were retired when the client stopped downloading bundles:
#   insufficient-disk      -- asserted a free-space check that ran before the transfer
#   download-stall-abort   -- asserted curl's --speed-limit/--speed-time on the bundle fetch
#   bundle-not-left-behind -- asserted the staged .raucb was unlinked on failure as well as success
# All three were deleted rather than left passing. With nothing staged they would each have gone
# GREEN WHILE ASSERTING NOTHING -- no download to run out of room for, no argv to carry a stall
# flag, no file to leave behind -- which is the failure shape this suite exists to prevent.
#
# What replaces them is the property that made them unnecessary: the bundle never touches this
# device's storage. rauc streams it over NBD and, because the manifest marks the image
# `adaptive=block-hash-index`, fetches only the blocks it cannot find in the two slots.
#
# The stall guard has NO replacement, deliberately -- rauc's D-Bus API has no Cancel, so it could
# not be reimplemented here. See the long comment above EXIT_OK in the client.
bundle_file stream retroforge-9.9.9.raucb 4096
manifest stream '{"version":"9.9.9","bundle":"retroforge-9.9.9.raucb","size":4096}'
run RETROFORGE_RELEASE_FILE="$(release_file 1.0.0)" RETROFORGE_OTA_CHANNEL=stream
# Exactly one request to the update server, and it is the manifest (the other is the channel list,
# which every apply fetches). A second would mean something still fetches bundles.
[ "$(grep -vc '^channels.json$' "$W/requests.log")" = 1 ] && grep -qx 'stream/latest.json' "$W/requests.log" \
                      && ok "fetched only the manifest, never the bundle" \
                      || bad "made $(requests) requests — something is still downloading the bundle"
case "$(cat "$W/argv.log" 2>/dev/null)" in
  *" -o "*) bad "curl was asked to write a file — the bundle is being staged again" ;;
  *) ok "curl never writes to disk" ;;
esac
left="$(find "$W/stage" -name '*.raucb' 2>/dev/null | wc -l | tr -d ' ')"
[ "$left" = 0 ] && ok "nothing bundle-shaped lands in the staging directory" \
               || bad "$left bundle(s) in $W/stage — the client staged a download"

# ...and the assertion the shell cannot make: WHAT gets handed to InstallBundle. It must be the
# https URL built from the manifest, never a local path. Driven through the client's own module
# seam (same technique as staged-stamp-is-spent-by-the-reboot below) because there is no bus here.
cat >"$W/stream_test.py" <<'PY'
import importlib.util, os, sys
from importlib.machinery import SourceFileLoader
loader = SourceFileLoader("nvu", os.environ["CLIENT"])
spec = importlib.util.spec_from_loader("nvu", loader)
nvu = importlib.util.module_from_spec(spec); loader.exec_module(nvu)
nvu.offered_channels = lambda: [("stable", "", "")]  # the hosted list is the curl stub's business

seen = {}
nvu.setup_done = lambda: True
nvu.config = lambda: ("https://updates.example.test", "stable")
nvu.manifest = lambda base, ch: {
    "version": "9.9.9", "build": "20260101T000000Z", "git": "", "bundle": "retroforge-9.9.9.raucb",
    "size": 4096, "url": f"{base}/{ch}/retroforge-9.9.9.raucb",
}
def fake_install(source, on_percent):
    seen["source"] = source
    return True
nvu.install = fake_install

fails = []
if nvu.cmd_apply() != nvu.EXIT_OK:
    fails.append("apply did not succeed with a working install")
src = seen.get("source")
if src != "https://updates.example.test/stable/retroforge-9.9.9.raucb":
    fails.append(f"InstallBundle got {src!r}, not the manifest URL")
if os.path.exists(os.path.join(nvu.STAGE_DIR, "retroforge-9.9.9.raucb")):
    fails.append("apply created a bundle file in the staging directory")
# To a FILE, not stdout: cmd_apply legitimately prints `100%` there and logs to stderr, and mixing
# the verdict into the artefact under test is how a case ends up asserting its own noise.
with open(os.environ["VERDICT"], "w") as handle:
    handle.write("\n".join(fails))
PY
rm -f "$W/stage/staged.json"
CLIENT="$CLIENT" RETROFORGE_OTA_STAGE="$W/stage" VERDICT="$W/stream.verdict" \
  python3 "$W/stream_test.py" >/dev/null 2>&1
out="$(cat "$W/stream.verdict" 2>/dev/null)"
[ -z "$out" ] && ok "InstallBundle is handed the manifest's https URL, not a path" \
              || bad "$out"
rm -f "$W/stage/staged.json"

# =================================================================================================
CASE="apply-refuses-a-reinstall"
#
# HW-OBSERVED 2026-08-18, and invisible to every other apply case here because they all offer a
# version the device is not running. A card took 0.2.3 -> 0.2.4 correctly, then installed 0.2.4 A
# SECOND TIME when only the shell had an update, ending with BOTH slots on 0.2.4.
#
# WHY IT HAPPENS: `check` compares the running version to the channel's, but `apply` did not — and
# THE CALLER DECIDES WHEN TO APPLY. The shell this was first written for applied client and OS
# updates as one aggregate, so a shell update alone drove the OS apply with the OS already up to
# date. A caller is not obliged to have asked first.
#
# WHY IT MATTERS more than a wasted transfer: usr/lib/rauc/post-install.sh gives the target slot a
# fresh per-slot /var and re-arms its boot conf. A redundant apply therefore overwrites the
# PREVIOUS RELEASE — the rollback target — and puts the device on a trial boot of what it was
# already running. The whole point of A/B is that the other side survives.
#
# Note that the request count cannot detect this: rauc streams the bundle, so a redundant install
# makes exactly the same one curl request (the manifest) as a refused one. The exit code and stdout
# are the discriminators, because they are also what the caller reads.
bundle_file uptodate retroforge-9.9.9.raucb 4096
manifest uptodate '{"version":"9.9.9","bundle":"retroforge-9.9.9.raucb","size":4096}'
rm -f "$W/stage/staged.json"
run RETROFORGE_RELEASE_FILE="$(release_file 9.9.9)" RETROFORGE_OTA_CHANNEL=uptodate
# EXIT_OK, not 7: the state the caller asked for already holds, and 7 is how this client reports a
# FAILED update. Before the guard this returned 7 — the install was attempted and died on the
# absent bus — so the exit code alone separates the two behaviours.
[ "$RC" = 0 ] && ok "apply on an up-to-date device succeeds instead of failing" \
              || bad "exit $RC — 7 here means the install was attempted, or is reported as a failure"
[ "$OUT" = "100%" ] && ok "the bar completes and stdout stays a bare 100%" \
                    || bad "stdout was '$OUT', not '100%'"
[ ! -f "$W/stage/staged.json" ] \
  && ok "no staged stamp is written for an install that never happened" \
  || bad "a staged.json was written — the next check would report restart-pending forever"

# ...and the assertion the exit code cannot make on its own: that install() was never REACHED.
# Same module seam as streams-rather-than-downloading above, because a bus-less environment makes
# "did not install" and "tried and failed" look alike from outside.
cat >"$W/reinstall_test.py" <<'PY'
import importlib.util, os
from importlib.machinery import SourceFileLoader
loader = SourceFileLoader("nvu", os.environ["CLIENT"])
spec = importlib.util.spec_from_loader("nvu", loader)
nvu = importlib.util.module_from_spec(spec); loader.exec_module(nvu)
nvu.offered_channels = lambda: [("stable", "", "")]  # the hosted list is the curl stub's business

called = []
nvu.setup_done = lambda: True
nvu.config = lambda: ("https://updates.example.test", "stable")
nvu.device_identity = lambda: {
    "version": "9.9.9", "build": "20260101T000000Z", "git": "abc1234", "mode": "release",
}
nvu.manifest = lambda base, ch: {
    "version": "9.9.9", "build": "20260202T000000Z", "git": "def5678",
    "bundle": "retroforge-9.9.9.raucb", "size": 4096,
    "url": f"{base}/{ch}/retroforge-9.9.9.raucb",
}
# Nothing is staged: this is the state a device is in AFTER the reboot that completed the real
# update, which is exactly when the spurious apply arrived.
nvu.staged_identity = lambda installer=None: None
nvu.install = lambda source, on_percent: called.append(source) or True

fails = []
if nvu.cmd_apply() != nvu.EXIT_OK:
    fails.append("apply did not report success on an up-to-date device")
if called:
    fails.append(f"InstallBundle was called with {called[0]!r} — the running version was reinstalled")
# The BUILD and GIT differ above while the version matches, deliberately: identity_of() keys on the
# version for a real release, so a rebuild of the same release must not read as a new update.
with open(os.environ["VERDICT"], "w") as handle:
    handle.write("\n".join(fails))
PY
CLIENT="$CLIENT" RETROFORGE_OTA_STAGE="$W/stage" VERDICT="$W/reinstall.verdict" \
  python3 "$W/reinstall_test.py" >/dev/null 2>&1
out="$(cat "$W/reinstall.verdict" 2>/dev/null)"
[ -z "$out" ] && ok "InstallBundle is never reached when the device already runs that version" \
              || bad "$out"
rm -f "$W/stage/staged.json"

# =================================================================================================
CASE="argv-fails-closed-on-a-word-and-open-on-a-flag"
#
# THE DEFAULT ACTION OF THIS PROGRAM IS AN INSTALL, so what main() does with an argument it does not
# recognise decides whether a typo writes the inactive slot. It used to fall through to apply for
# anything unrecognised -- `--enable-duplicate-detection` landed in the right place by accident.
#
# The two shapes have OPPOSITE right answers, and this case asserts both, because either one alone
# is satisfiable by a parser that is wrong in the other direction:
#
#   a FLAG must still reach apply. Callers grow flags on this command line over time --
#   --enable-duplicate-detection is itself one that arrived after the interface existed -- and a
#   client that refused an unfamiliar one would stop applying updates FLEET-WIDE and silently, the
#   day Valve shipped the next one.
#
#   a WORD must not. `chekc` is not a request to install over the other slot.
#
# The channel is the up-to-date one from the case above, deliberately: apply then answers 0 with a
# bare `100%` while a refusal answers 7 with nothing, so the two paths are told apart by what the caller
# would actually read, and neither needs a bus.
for flag in --enable-duplicate-detection --a-flag-valve-has-not-shipped-yet; do
  rm -f "$W/stage/staged.json"
  run RETROFORGE_RELEASE_FILE="$(release_file 9.9.9)" RETROFORGE_OTA_CHANNEL=uptodate "$flag"
  [ "$RC" = 0 ] && [ "$OUT" = "100%" ] \
    && ok "'$flag' still reaches apply (forward-compatible)" \
    || bad "'$flag' did not reach apply: exit $RC, stdout '$OUT' — a new Valve flag would stop the fleet updating"
done

for word in chekc refresh ""; do
  rm -f "$W/stage/staged.json"
  run RETROFORGE_RELEASE_FILE="$(release_file 9.9.9)" RETROFORGE_OTA_CHANNEL=uptodate "$word"
  [ "$RC" = 7 ] && ok "'$word' is refused rather than treated as apply" \
                || bad "'$word' exited $RC — an unknown word fell through to an install"
  # The assertion that outranks the exit code: this path is reachable from a caller that PARSES
  # STDOUT as a version, so a usage message there would offer the fleet an update called 'usage:'.
  [ -z "$OUT" ] && ok "'$word' says nothing on stdout" \
                || bad "'$word' printed '$OUT' on stdout — the caller would read that as a version"
  [ "$(requests)" = 0 ] && ok "'$word' is refused before any request is made" \
                        || bad "'$word' reached the network before being refused"
done
case "$ERR" in
  *usage:*) ok "the usage message goes to stderr, where it cannot be parsed as a version" ;;
  *) bad "no usage on stderr — a refused invocation says nothing anywhere" ;;
esac
# ...and the one that must NOT have moved: an explicit -h still prints usage to STDOUT for a human.
run -h
[ "$RC" = 0 ] && case "$OUT" in *usage:*) ok "-h still prints usage on stdout and exits 0" ;;
  *) bad "-h printed '$OUT'" ;; esac || bad "-h exited $RC"
rm -f "$W/stage/staged.json"

# =================================================================================================
CASE="apply-progress"
# The progress bar reads stdout. Every line must be N%, forward-only. The install then fails here (no
# bus), which is expected and must still leave stdout clean.
bundle_file ok retroforge-9.9.9.raucb 4096
manifest ok '{"version":"9.9.9","bundle":"retroforge-9.9.9.raucb","size":4096}'
run RETROFORGE_RELEASE_FILE="$(release_file 1.0.0)" RETROFORGE_OTA_CHANNEL=ok
badline=""; last=-1; mono=1
while read -r line; do
  [ -z "$line" ] && continue
  case "$line" in
    *%) n="${line%\%}"; case "$n" in ''|*[!0-9]*) badline="$line" ;;
          *) [ "$n" -le "$last" ] && mono=0; last="$n" ;; esac ;;
    *) badline="$line" ;;
  esac
done <<<"$OUT"
[ -z "$badline" ] && ok "stdout carries only N% lines" \
                  || bad "non-progress line on stdout: '$badline'"
[ "$mono" = 1 ] && ok "percentages are forward-only" || bad "progress went backwards"
# NO "emitted progress" ASSERTION, and its absence is the point. Every percentage now comes from
# rauc's PropertiesChanged, so a run without a bus emits none at all -- that is correct behaviour
# here, not a regression. (It used to emit up to PROGRESS_DOWNLOAD_END from the client's own
# download loop before ever reaching the bus, which is what made the old assertion meaningful.)
# What still matters offline is that a failing install says NOTHING on stdout, because anything
# there that is not N% is parsed by the caller as a version string.
[ -z "$OUT" ] && ok "a failed install says nothing on stdout" \
              || ok "progress reached ${last}% and stayed clean"

# =================================================================================================
CASE="identity-rules-agree"
#
# THE ONE CASE THAT IS NOT ABOUT THE CLIENT. The rule "version when it is real, build timestamp
# otherwise" is implemented twice — in shell in ota/genbundle.sh and in Python in the client —
# and nothing but this makes them the same rule. Phase 2 exists because they drifted: the bundle was
# named from a date while the image called itself something else, so the comparison the entire
# update path rests on was between two unrelated strings, and a device could be offered its own
# build forever or never be offered a real one.
#
# genbundle.sh is not run (it needs rauc and a 6G image); its rule is extracted and evaluated the
# same way the shell would. If that extraction stops matching the file, this case must be updated
# WITH it — which is the point at which someone re-reads both rules.
shell_identity() { # <version> <build>
  if [ -n "$1" ] && [ "$1" != dev ]; then printf '%s' "$1"; else printf '%s' "$2"; fi
}
grep -q 'IMG_VERSION" != dev' "$GENBUNDLE" \
  && ok "genbundle.sh still keys on version!=dev (the rule mirrored below)" \
  || bad "genbundle.sh's identity rule changed shape — re-read it against identity_of() and update this test"

for pair in "1.4.0|20260101T000000Z" "dev|20260102T030405Z" "|20260103T000000Z" "1.4.0-rc.1|20260104T000000Z"; do
  v="${pair%%|*}"; b="${pair##*|}"
  want="$(shell_identity "$v" "$b")"
  # The client's answer for the same release file, taken through `status` — the only subcommand
  # that prints the device's own identity without needing a server.
  run RETROFORGE_RELEASE_FILE="$(release_file "$v" "$b")" RETROFORGE_OTA_CHANNEL=missing status
  got="$(printf '%s\n' "$OUT" | sed -n 's/^device: *\([^ ]*\).*/\1/p')"
  [ "$got" = "$want" ] && ok "identity('${v:-<empty>}','$b') = '$got' in both" \
                       || bad "DRIFT for version='${v:-<empty>}' build='$b': genbundle says '$want', client says '$got'"
done

# =================================================================================================
CASE="staged-stamp-is-spent-by-the-reboot"
# HW-CAUGHT 2026-08-03, and invisible to every case above because it only appears on the SECOND
# check, after a real reboot. GetPrimary answers with a slot NAME ("rootfs.1"); the BootSlot
# property answers with a BOOTNAME ("B"). Comparing the two is never equal, so "is an update still
# pending?" was permanently true, the stamp was never cleared, and the shell showed restart-pending
# forever -- a device took exactly one OTA and then stopped being offered anything.
#
# Driven through staged_identity()'s own installer seam rather than a live bus: what matters is
# which VALUES it compares, and a fake installer states them outright.
cat >"$W/staged_test.py" <<'PY'
import importlib.util, os, sys
from importlib.machinery import SourceFileLoader
# The client ships without a .py suffix, so the loader has to be named rather than inferred.
loader = SourceFileLoader("nvu", os.environ["CLIENT"])
spec = importlib.util.spec_from_loader("nvu", loader)
nvu = importlib.util.module_from_spec(spec); loader.exec_module(nvu)
nvu.offered_channels = lambda: [("stable", "", "")]  # the hosted list is the curl stub's business

class Ret:
    def __init__(self, v): self.v = v
    def unpack(self): return (self.v,)

class Installer:
    """primary is a slot NAME, exactly as rauc's GetPrimary answers."""
    def __init__(self, primary, booted): self.primary, self.booted = primary, booted
    def call_sync(self, method, *a, **k):
        if method == "GetPrimary": return Ret(self.primary)
        if method == "GetSlotStatus":
            # bootname is carried because it is the WRONG value to compare against GetPrimary --
            # it must be present for this case to be able to catch someone reaching for it again.
            return Ret([(n, {"state": "booted" if n == self.booted else "inactive",
                             "bootname": {"rootfs.0": "A", "rootfs.1": "B"}[n]})
                        for n in ("rootfs.0", "rootfs.1")])
        raise AssertionError(method)

stamp = {"version": "9.9.9", "build": "20260101T000000Z"}
fails = []

# 1. the reboot happened: primary is the slot we are running. The stamp is spent.
nvu.write_staged(stamp)
if nvu.staged_identity(Installer("rootfs.1", "rootfs.1")) is not None:
    fails.append("still reported restart-pending after the reboot into the primary slot")
if os.path.exists(nvu.STAGED_FILE):
    fails.append("the spent stamp was left on disk, so the next check repeats the bug")

# 2. genuinely pending: installed into the other slot, not yet rebooted.
nvu.write_staged(stamp)
if nvu.staged_identity(Installer("rootfs.1", "rootfs.0")) != "9.9.9":
    fails.append("did not report a genuinely pending update before the reboot")

# 2b. HW-CAUGHT 2026-11-17 (0.0.8 -> 0.0.9, Air Y Pro): rebooted into the new slot, but its trial
# is still running (B_TRY>0 until retroforge-bootctl marks it good, ~25 s after the shell starts).
# rauc's grub GetPrimary skips a slot with tries counted, so it answers the OLD slot, and the
# shell's session-start `staged` read that as restart-pending: Restart now for the whole session,
# every boot. Running the stamped version is what says the reboot happened.
release = os.path.join(os.path.dirname(nvu.STAGED_FILE), "release")
with open(release, "w") as handle:
    handle.write("RETROFORGE_VERSION=9.9.9\nRETROFORGE_BUILD=20260101T000000Z\n")
nvu.RELEASE_FILE = release
nvu.write_staged(stamp)
if nvu.staged_identity(Installer("rootfs.0", "rootfs.1")) is not None:
    fails.append("reported restart-pending while running the stamped version in its boot trial")
if os.path.exists(nvu.STAGED_FILE):
    fails.append("the stamp outlived the boot into the version it names")
os.unlink(release)
nvu.RELEASE_FILE = "/nonexistent"

# 3. `staged` (the shell's Restart now at session start) answers from staged_identity() alone.
import contextlib, io
for value, want_rc, want_out in (("9.9.9", 0, "9.9.9\n"), (None, 7, "")):
    nvu.staged_identity = lambda installer=None, v=value: v
    buf = io.StringIO()
    with contextlib.redirect_stdout(buf):
        rc = nvu.main(["staged"])
    if (rc, buf.getvalue()) != (want_rc, want_out):
        fails.append(f"staged with {value!r}: exit {rc}, stdout {buf.getvalue()!r}")

print("\n".join(fails))
PY
staged_out="$(CLIENT="$CLIENT" RETROFORGE_OTA_STAGE="$W/stage" python3 "$W/staged_test.py" 2>&1)"
if [ -z "$staged_out" ]; then
  ok "the stamp is cleared by the reboot, and survives until it"
else
  while read -r line; do [ -n "$line" ] && bad "$line"; done <<<"$staged_out"
fi

# =================================================================================================
CASE="channel-picker"
# `channels` + `set-channel` replace the old Steam-shaped retroforge-select-branch: the shell's picker
# reads the list, writes the choice, and the next `check` follows it. The choice lands in the USER
# file only, and is refused when /etc or the environment outranks it (a dev card's pin).
PICK="$W/pick/ota.conf"
# The list the picker shows is the hosted ota/channels.json. The sandbox serves the repository's own
# copy, so this also checks that the file that ships on main parses and offers the three CI publishes.
run RETROFORGE_OTA_USER_CONFIG="$PICK" channels
[ "$RC" = 0 ] && [ "$(printf '%s\n' "$OUT" | cut -f1 | tr '\n' ' ')" = "stable beta nightly " ] \
  && ok "lists stable, beta and nightly from ota/channels.json" || bad "channels: exit $RC, '$OUT'"
run RETROFORGE_OTA_USER_CONFIG="$PICK" set-channel beta
[ "$RC" = 0 ] && grep -qx 'OTA_CHANNEL=beta' "$PICK" \
  && ok "set-channel writes the user file" || bad "set-channel: exit $RC, file: $(cat "$PICK" 2>&1)"
run RETROFORGE_OTA_USER_CONFIG="$PICK" channel
[ "$OUT" = "$(printf 'beta\t%s' "$PICK")" ] && ok "channel reports the new choice and its source" \
                                           || bad "channel printed '$OUT'"
[ "$(requests)" = 0 ] && ok "picking a channel fetched nothing" || bad "set-channel made $(requests) request(s)"
run RETROFORGE_OTA_USER_CONFIG="$PICK" set-channel '../evil'
[ "$RC" = 1 ] && grep -qx 'OTA_CHANNEL=beta' "$PICK" \
  && ok "an invalid name is refused and the file is untouched" || bad "invalid name: exit $RC"
printf 'OTA_CHANNEL=dev\n' >"$W/etc-dev.conf"
run RETROFORGE_OTA_USER_CONFIG="$PICK" RETROFORGE_OTA_CONFIG="$W/etc-dev.conf" set-channel stable
[ "$RC" = 1 ] && grep -qx 'OTA_CHANNEL=beta' "$PICK" \
  && ok "a pinned channel refuses the write" || bad "pinned: exit $RC, file: $(cat "$PICK")"
run RETROFORGE_OTA_USER_CONFIG="$PICK" RETROFORGE_OTA_CONFIG="$W/etc-dev.conf" channels
[ "$(printf '%s\n' "$OUT" | cut -f1 | tr '\n' ' ')" = "stable beta nightly dev pinned " ] \
  && [ "$(printf '%s\n' "$OUT" | tail -1)" = "$(printf 'pinned\t%s' "$W/etc-dev.conf")" ] \
  && ok "channels lists the pinned off-picker channel and says it is pinned" \
  || bad "pinned channels printed '$OUT'"
run set-channel
[ "$RC" = 1 ] && [ -z "$OUT" ] && ok "set-channel with no name is a refusal, not an install" \
                              || bad "bare set-channel: exit $RC out='$OUT'"

# =================================================================================================
CASE="channel-list-hosted"
# The picker's list comes from a file on GitHub so a channel added there reaches devices already
# installed. Online only: no cache, no built-in list. When it cannot be fetched `channels` exits 1
# with nothing on stdout, and the shell shows that instead of a list. The stub serves
# https://lists.example/channels.json from $W/www/channels.json.
rm -f "$W/www/channels.json"
run channels
[ "$RC" = 1 ] && [ -z "$OUT" ] && [[ $ERR == *"cannot fetch the channel list"* ]] \
  && ok "unreachable: exit 1, nothing on stdout, the reason on stderr" || bad "unreachable: exit $RC, '$OUT', '$ERR'"
printf '%s\n' '{"channels":[{"name":"stable","label":"Stable"},"beta",{"name":"rc","label":"Release candidate","description":"Almost\tstable."}]}' \
  >"$W/www/channels.json"
run channels
[ "$RC" = 0 ] && [ "$OUT" = "$(printf 'stable\tStable\t\nbeta\nrc\tRelease candidate\tAlmost stable.')" ] \
  && ok "the hosted list is offered, with its labels (tabs in text flattened)" || bad "hosted: exit $RC, '$OUT'"
rm -f "$W/www/channels.json"
run channels
[ "$RC" = 1 ] && [ -z "$OUT" ] && ok "a list fetched before is not remembered" || bad "after going offline: exit $RC, '$OUT'"
printf 'not json\n' >"$W/www/channels.json"
run channels
[ "$RC" = 1 ] && [ -z "$OUT" ] && [[ $ERR == *"not usable"* ]] \
  && ok "a broken hosted file is a failure, not an empty list" || bad "broken: exit $RC, '$OUT'"
printf '%s\n' '{"channels":["../evil","pinned","",{"name":"a b"},42,"good","good"]}' >"$W/www/channels.json"
run channels
# `stable` after it: the channel in effect is always listed, so the picker never loses its selection.
[ "$OUT" = "$(printf 'good\nstable')" ] && ok "invalid, reserved and duplicate names are dropped" || bad "filter: '$OUT'"
printf '%s\n' '{"channels":["../evil"]}' >"$W/www/channels.json"
run channels
[ "$RC" = 1 ] && [ -z "$OUT" ] && ok "a list with nothing usable is a failure" || bad "empty: exit $RC, '$OUT'"
printf 'OTA_CHANNELS_URL=https://lists.example/other.json\n' >"$W/etc-list.conf"
printf '%s\n' '{"channels":["other"]}' >"$W/www/other.json"
run RETROFORGE_OTA_CHANNELS_URL= RETROFORGE_OTA_CONFIG="$W/etc-list.conf" channels
[ "$OUT" = "$(printf 'other\nstable')" ] && ok "OTA_CHANNELS_URL in /etc moves the list" || bad "/etc url: '$OUT'"
# Every check and install needs the list, not just the picker: unreachable is exit 8, never
# "no update" (7) and never an install, and it is decided before the update server is asked.
rm -f "$W/www/channels.json" "$W/www/other.json"
manifest stable '{"version":"9.9.9","bundle":"retroforge-9.9.9.raucb","size":100}'
run RETROFORGE_RELEASE_FILE="$(release_file 1.0.0)" check
[ "$RC" = 8 ] && [ -z "$OUT" ] && [ "$(grep -c latest.json "$W/requests.log")" = 0 ] \
  && ok "check: no channel list is exit 8, and the update server is not asked" \
  || bad "check without the list: exit $RC, '$OUT', requests: $(cat "$W/requests.log")"
run RETROFORGE_RELEASE_FILE="$(release_file 1.0.0)"
[ "$RC" = 8 ] && [ "$(grep -c latest.json "$W/requests.log")" = 0 ] \
  && ok "apply: no channel list is exit 8 and installs nothing" || bad "apply without the list: exit $RC, '$OUT'"
cp "$ROOT/ota/channels.json" "$W/www/channels.json"
run RETROFORGE_RELEASE_FILE="$(release_file 1.0.0)" check
[ "$RC" = 0 ] && [ "$OUT" = "9.9.9" ] && ok "check: with the list back, the update is offered" || bad "check with the list: exit $RC, '$OUT'"

# =================================================================================================
CASE="channel-switch-either-way"
# Channel changes are unrestricted (ota-ui plan D3): beta -> stable offers stable's release even
# though it is OLDER than the running beta. The check compares for inequality, never for order;
# this pins that, so nobody "fixes" it into a newer-only check that strands a device on beta.
manifest stable '{"version":"0.0.3","bundle":"retroforge-0.0.3.raucb","size":100}'
manifest beta '{"version":"0.0.4-beta.1","bundle":"retroforge-0.0.4-beta.1.raucb","size":100}'
run RETROFORGE_RELEASE_FILE="$(release_file 0.0.3)" RETROFORGE_OTA_CHANNEL=beta check
[ "$RC" = 0 ] && [ "$OUT" = "0.0.4-beta.1" ] && ok "stable -> beta offers the beta" \
                                             || bad "exit $RC, printed '$OUT'"
run RETROFORGE_RELEASE_FILE="$(release_file 0.0.4-beta.1)" RETROFORGE_OTA_CHANNEL=stable check
[ "$RC" = 0 ] && [ "$OUT" = "0.0.3" ] && ok "beta -> stable offers the older stable release" \
                                      || bad "exit $RC, printed '$OUT'"

# =================================================================================================
CASE="staged"
# No stamp: nothing pending, exit 7, nothing fetched -- without asking rauc at all.
rm -f "$W/stage/staged.json"
run staged
[ "$RC" = 7 ] && [ -z "$OUT" ] && [ "$(requests)" = 0 ] && ok "no staged update: exit 7, empty stdout, no request" \
                                                   || bad "exit $RC, printed '$OUT', $(requests) request(s)"

# =================================================================================================
CASE="version"
# The shell's Updates section shows the running version. It is identity_of() over the release
# file -- the same string `check` compares against -- so the UI never re-derives the dev rule.
run RETROFORGE_RELEASE_FILE="$(release_file 0.0.4-beta.1)" version
[ "$RC" = 0 ] && [ "$OUT" = "0.0.4-beta.1" ] && ok "prints the running version" \
                                             || bad "exit $RC, printed '$OUT'"
run RETROFORGE_RELEASE_FILE="$(release_file dev 20261018T101500Z dev)" version
[ "$OUT" = "20261018T101500Z" ] && ok "a dev build prints its build stamp, as check would" \
                                || bad "dev build printed '$OUT'"
[ "$(requests)" = 0 ] && ok "fetches nothing" || bad "version made $(requests) request(s)"
run RETROFORGE_RELEASE_FILE="$(release_file 1.0.0)" RETROFORGE_SHELL_SETTINGS="$W/nonexistent.cfg" version
[ "$OUT" = "1.0.0" ] && ok "answers before first-boot setup too (nothing is fetched)" \
                     || bad "before setup printed '$OUT' (exit $RC)"
run RETROFORGE_RELEASE_FILE="$W/nonexistent-release" version
[ "$RC" = 1 ] && [ -z "$OUT" ] && ok "no release file: exit 1, nothing on stdout" \
                              || bad "no release file: exit $RC, printed '$OUT'"

# =================================================================================================
printf '\ntest-update.sh: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
