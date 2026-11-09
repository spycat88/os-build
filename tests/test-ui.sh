#!/usr/bin/env bash
# Offline test for installer/ui and installer/confirm-ui — the gamepad half of §4d's consent contract.
#
#   tests/test-ui.sh
#
# WHY THIS FILE EXISTS. §4d has one trap that every stubbed gate case passes without: THE
# RENDERER'S STDOUT IS THE ANSWER AND NOTHING ELSE. A renderer that also writes its screen there
# makes every attempt read as a wrong answer — an installer that can never take consent, with a
# symptom ("that was not the sequence shown") pointing nowhere near the cause. The tty renderer paid
# for that finding once; the plan requires the gamepad renderer to have its own case against the
# real thing rather than inherit the confidence.
#
# HOW IT RUNS WITH NO SDL, NO PANEL AND NO PAD. installer/ui imports pygame lazily, inside its view
# only, and takes its input from a file of tokens when RETROFORGE_UI_EVENTS is set. So the real
# shipped file — not a copy, not a mangled variant — runs here as its own state machine, answers a
# real unix socket, and is driven by the real installer/confirm-ui. What is NOT covered is anything
# with a pixel in it: the drawing is asserted through describe(), which is what the view is handed.
#
# The end-to-end against the SPINE lives in tests/test-install.sh, next to its sandbox, for the
# same reason the tty renderer's does: the sandbox that stubs sgdisk/mkfs/rauc is that file's, and
# a second copy of it here would be a regression rather than a convenience.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
UI="$ROOT/installer/ui"
SHIM="$ROOT/installer/confirm-ui"
VIEW="$ROOT/installer/uiview.py"
for f in "$UI" "$SHIM"; do
  [ -x "$f" ] || { echo "not executable: $f" >&2; exit 1; }
done
[ -f "$VIEW" ] || { echo "no view module: $VIEW" >&2; exit 1; }

PASS=0; FAIL=0; CASE=""
ok()  { PASS=$((PASS+1)); printf '  ok   %s -- %s\n' "$CASE" "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s -- %s\n' "$CASE" "$1"; }

T="$(mktemp -d)"
trap 'rm -rf "$T"; pkill -f "$UI" 2>/dev/null' EXIT
# Loading installer/ui as a module writes a __pycache__ next to it, which the installer image build
# would then copy verbatim. Keep the bytecode in the sandbox. Same reason as tests/test-update.sh.
export PYTHONPYCACHEPREFIX="$T/pycache"
export RETROFORGE_UI_DEADLINE=30

cat >"$T/facts-wipe" <<'EOF'
SCREEN=android-wipe
DISK=/dev/sda
WWID=UFS:test
SECTOR=512
UD_INDEX=11
UD_GIB_NOW=96
UD_GIB_AFTER=16
RETROFORGE_GIB=80
REPLACES_OURS=0
HOME_ACTION=create
EOF
cat >"$T/facts-reinst" <<'EOF'
SCREEN=reinstall
DISK=/dev/sda
WWID=UFS:test
SECTOR=512
HOME_ACTION=keep
HOME_GIB=214
EOF
cat >"$T/facts-replaces" <<'EOF'
SCREEN=android-wipe
DISK=/dev/sda
WWID=UFS:test
SECTOR=512
UD_INDEX=11
UD_GIB_NOW=96
UD_GIB_AFTER=16
RETROFORGE_GIB=90
REPLACES_OURS=1
HOME_GIB=180
HOME_ACTION=create
EOF

# --- the harness -----------------------------------------------------------------------------
# Start the real UI with a scripted input source, wait for its socket, then ask it for consent
# through the real shim. $OUT is the shim's stdout ALONE and $ERR everything else, because keeping
# those two apart is the property most of this file is about.
ui_ask() {  # <events-file> <facts> <sequence>
  local events="$1" facts="$2" seq="$3" i=0
  SOCK="$T/sock.$RANDOM"
  RETROFORGE_UI_SOCK="$SOCK" RETROFORGE_UI_EVENTS="$events" RETROFORGE_UI_INPUT_DEVICES="${DEVFILE-}" \
    "$UI" >"$T/ui.log" 2>&1 &
  UI_PID=$!
  while [ ! -S "$SOCK" ]; do
    i=$((i+1)); [ "$i" -gt 300 ] && { echo "the UI never created its socket" >&2; return 9; }
    sleep 0.02
  done
  RETROFORGE_UI_SOCK="$SOCK" "$SHIM" --facts "$facts" --sequence "$seq" >"$T/out" 2>"$T/err"
  local rc=$?
  wait "$UI_PID" 2>/dev/null
  OUT="$(cat "$T/out")"; ERR="$(cat "$T/err")"
  return $rc
}

# describe() for a given facts file, as JSON, straight out of the shipped file.
describe() {  # <facts> <sequence> [pressed]
  FACTS="$1" SEQ="$2" PRESSED="${3:-}" python3 - <<'PY'
import importlib.util, json, os
from importlib.machinery import SourceFileLoader
loader = SourceFileLoader("nvui", os.path.join(os.environ["ROOT"], "installer/ui"))
spec = importlib.util.spec_from_loader("nvui", loader)
ui = importlib.util.module_from_spec(spec); loader.exec_module(ui)
s = ui.ConsentScreen(ui.read_facts(os.environ["FACTS"]), os.environ["SEQ"])
for t in os.environ.get("PRESSED", ""):
    s.handle(t)
print(json.dumps({"desc": s.describe(), "result": s.result}))
PY
}
export ROOT

# =================================================================================================
CASE="confirm-ui: stdout is the answer and nothing else"
# THE CASE THE PLAN DEMANDS. The spine reads this in a command substitution and compares it to the
# sequence it asked for; one stray line and consent can never be given.
printf 'SHOWN\n' >"$T/ev-ok"
if ui_ask "$T/ev-ok" "$T/facts-wipe" SWNE; then
  ok "the shim exits 0 when the sequence is pressed"
else
  bad "the shim failed: $ERR"
fi
[ "$OUT" = SWNE ] \
  && ok "and its stdout is exactly the pressed sequence" \
  || bad "stdout was not the answer: $(printf '%q' "$OUT")"
[ "$(printf '%s' "$OUT" | wc -l)" -le 1 ] \
  && ok "one line, nothing else -- no screen text, no log line, no progress" \
  || bad "stdout carried more than the answer"
# And the structural half of the same property: the UI writes a line about this very request, and
# that line does not and cannot land on the shim's stdout. The tty renderer had to keep its whole
# screen off one file descriptor; here the renderer is a different process entirely.
grep -q "consent requested for /dev/sda (android-wipe), sequence SWNE" "$T/ui.log" \
  && ok "while the UI logs the request it was given, on its own descriptor, harmlessly" \
  || bad "the UI did not log the request: $(cat "$T/ui.log")"

CASE="confirm-ui: a wrong press is returned as a wrong answer, immediately"
printf 'S\nS\n' >"$T/ev-wrong"
ui_ask "$T/ev-wrong" "$T/facts-wipe" SWNE
[ "$OUT" = SS ] \
  && ok "the second press ends the attempt rather than collecting two more that cannot matter" \
  || bad "a wrong press did not end the attempt: $(printf '%q' "$OUT")"
[ "$OUT" != SWNE ] \
  && ok "and what it returns is not the sequence, so the spine re-randomises and asks again" \
  || bad "a wrong press produced the right answer"

CASE="confirm-ui: SELECT cancels, and a cancel is not an answer"
printf 'BACK\n' >"$T/ev-abort"
if ui_ask "$T/ev-abort" "$T/facts-wipe" SWNE; then
  bad "an abort exited 0, which the spine would read as consent"
else
  ok "an abort exits non-zero, which the spine reads as 'the install was cancelled'"
fi
[ -z "$OUT" ] \
  && ok "and it prints nothing at all on stdout" \
  || bad "an abort put something on stdout: $(printf '%q' "$OUT")"

CASE="confirm-ui: it fails closed when there is no UI to ask"
RETROFORGE_UI_SOCK="$T/nothing-here.sock" RETROFORGE_UI_CONNECT_TIMEOUT=1 \
  "$SHIM" --facts "$T/facts-wipe" --sequence SWNE >"$T/out" 2>"$T/err" \
  && bad "the shim exited 0 with no UI running" \
  || ok "no UI means a non-zero exit -- 'we could not ask' must never look like 'they said yes'"
[ ! -s "$T/out" ] && ok "and nothing on stdout" || bad "it printed something without an answer"
grep -qi 'cannot reach the installer UI' "$T/err" \
  && ok "and it says so on stderr, where the operator can read it" \
  || bad "the failure is silent: $(cat "$T/err")"

CASE="confirm-ui: a UI that dies mid-wait is not consent either"
python3 - "$T/dead.sock" <<'PY' &
import socket, sys, os
p = sys.argv[1]
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.bind(p); s.listen(1)
c, _ = s.accept()
c.recv(4096)
c.close(); s.close(); os.unlink(p)
PY
DEAD=$!
for _ in $(seq 1 100); do [ -S "$T/dead.sock" ] && break; sleep 0.02; done
RETROFORGE_UI_SOCK="$T/dead.sock" "$SHIM" --facts "$T/facts-wipe" --sequence SWNE \
  >"$T/out" 2>"$T/err" \
  && bad "a connection that closed without answering exited 0" \
  || ok "a UI that goes away mid-wait exits non-zero"
[ ! -s "$T/out" ] && ok "and nothing on stdout" || bad "it printed something"
wait "$DEAD" 2>/dev/null

CASE="confirm-ui: it refuses facts it cannot render, rather than inventing a screen"
printf 'SCREEN=something-else\nDISK=/dev/sda\n' >"$T/facts-bogus"
printf 'SHOWN\n' >"$T/ev-ok2"
ui_ask "$T/ev-ok2" "$T/facts-bogus" SWNE \
  && bad "an unknown screen was rendered and answered" \
  || ok "an unknown screen is refused"
[ ! -s "$T/out" ] && ok "and nothing on stdout" || bad "it answered anyway"

# =================================================================================================
CASE="ui: the buttons are POSITIONS, and the mapping is the only place a letter exists"
python3 - <<'PY' && ok "SDL's positional constants map to N/E/S/W at the event boundary" \
                 || bad "the button mapping is not positional"
import os, sys
sys.path.insert(0, os.path.join(os.environ["ROOT"], "installer"))
import uipad
# SDL_CONTROLLER_BUTTON_A/B/X/Y are 0/1/2/3 and are defined by POSITION: bottom, right, left, top.
want = {0: "S", 1: "E", 2: "W", 3: "N"}
sys.exit(0 if uipad.BUTTON_TO_CARDINAL == want and set(uipad.CARDINALS) == {"N","E","S","W"} else 1)
PY
# The silkscreen differs between boards (`A` is EAST on the Pocket ACE, SOUTH on the Pocket S2), so
# a button letter must not survive into anything drawn. This reads what describe() actually returns
# rather than trusting the source.
for facts in "$T/facts-wipe" "$T/facts-reinst" "$T/facts-replaces"; do
  text="$(describe "$facts" SWNE | python3 -c 'import json,sys; d=json.load(sys.stdin)["desc"]; print(d["title"], d["prompt"], d["note"], d["abort"], " ".join(h+" "+b for h,b in d["blocks"]), " ".join(x["name"] for x in d["diamonds"]))')"
  if printf '%s' "$text" | grep -qE '\b(button|press(es|ed)?) *[ABXY]\b|\b[ABXY] button\b'; then
    bad "a face-button letter reached the screen for $(basename "$facts")"
  else
    ok "no face-button letter on the screen for $(basename "$facts")"
  fi
done
d="$(describe "$T/facts-wipe" NESW | python3 -c 'import json,sys; print(" ".join(x["pos"]+":"+x["name"] for x in json.load(sys.stdin)["desc"]["diamonds"]))')"
[ "$d" = "N:NORTH E:EAST S:SOUTH W:WEST" ] \
  && ok "the diamonds follow the sequence, in order, named by position" \
  || bad "the diamonds do not follow the sequence: $d"

CASE="ui: the screen is DERIVED from the facts, never a fixed string"
a="$(describe "$T/facts-wipe" SWNE)"
b="$(describe "$T/facts-reinst" SWNE)"
printf '%s' "$a" | grep -q '96 GiB' && printf '%s' "$a" | grep -q '16 GiB' \
  && ok "the wipe screen quotes both the size lost and the size kept" \
  || bad "the wipe screen does not quote the measured sizes"
printf '%s' "$a" | grep -qi 'NOT recoverable' \
  && ok "and says the loss is permanent, in the user's terms" \
  || bad "the wipe screen does not say the loss is permanent"
printf '%s' "$a" | grep -qi 'Volume Up' \
  && ok "and names how to get back to Android" \
  || bad "the wipe screen does not say how to reach Android afterwards"

CASE="ui: the two consent screens cannot render each other"
printf '%s' "$b" | grep -qi 'deletes Android' \
  && bad "the reinstall screen renders the Android-wipe warning, which is flatly false there" \
  || ok "no Android-wipe text on the reinstall path"
printf '%s' "$b" | grep -q '214 GiB' \
  && ok "it quotes the /home figure instead" \
  || bad "the reinstall screen does not quote the /home size"
printf '%s' "$a" | grep -qi 'asked to erase /home' \
  && bad "the wipe screen rendered the reinstall's erase text" \
  || ok "and the wipe screen cannot produce the reinstall wording"

CASE="ui: it never reassures about the thing it is deleting"
# The finding of 2026-08-21, which cost the tty screen a hardware run: `fresh` on a disk that is
# already ours destroys the retroforge /home, and "your game library is safe" is true only when the
# games are on the SD card.
r="$(describe "$T/facts-replaces" SWNE)"
printf '%s' "$r" | grep -q 'your game library is safe' \
  && bad "it still reassures 'your game library is safe' while erasing the disk holding it" \
  || ok "the SD-card reassurance drops its second clause when /home is being replaced"
printf '%s' "$r" | grep -qi 'deletes the RetroForge install already here' \
  && ok "and it says outright that the existing install is going" \
  || bad "it does not disclose that an existing retroforge install is destroyed"
printf '%s' "$r" | grep -q '180 GiB' \
  && ok "quoting what that /home is using today" \
  || bad "it does not quote the /home size at risk"
printf '%s' "$a" | grep -q 'your game library is safe' \
  && ok "while a stock Android disk still gets it -- there the games really are on the card" \
  || bad "the reassurance was lost on the disk where it is true"

# =================================================================================================
# the stubs the sections below share
# =================================================================================================
mkdir -p "$T/bin"
cat >"$T/bin/curl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${NET_CURL_CALLS:-/dev/null}"
[ -n "${NET_CURL_BODY:-}" ] && printf '%s' "$NET_CURL_BODY"
exit "${NET_HOST_RC:-0}"
EOF
chmod +x "$T/bin"/*
state() { printf '%s\n' "$1" | sed -n 's/^STATE=//p'; }

CASE="release-info and retroforge-update agree on the host"
# The literal is written twice, in two files that do not share code.
ota_default="$(sed -n 's/^DEFAULT_URL = "\(.*\)"$/\1/p' "$ROOT/rootfs/overlay/usr/bin/retroforge-update" | head -1)"
rel_default="$(sed -n 's/^DEFAULT_URL = "\(.*\)"$/\1/p' "$ROOT/installer/release-info" | head -1)"
[ -n "$ota_default" ] && [ "$rel_default" = "$ota_default" ] \
  && ok "both default to $ota_default" \
  || bad "release-info says '$rel_default', retroforge-update says '$ota_default'"

CASE="§5: a finished install powers off, anything else leaves and the unit reboots"
# Power off is what makes the card safe to pull: booted beside a card, the card gets touched, and
# pulled while the system runs it goes out dirty (Pocket ACE, 2026-11-06). The other exits reboot.
restartcheck() {  # <rc> <token> -- prints the result tuple the end screen produces
  RC="$1" TOKEN="$2" python3 -c '
import json, os, sys
sys.path.insert(0, os.path.join(os.environ["ROOT"], "installer"))
import uiflow
class R: tail = ["boom"]
s = uiflow.ProgressScreen(R()); s.finish(int(os.environ["RC"]))
s.handle(uiflow.TOKEN_BACK if os.environ["TOKEN"] == "BACK" else os.environ["TOKEN"])
print(json.dumps(s.result))'
}
[ "$(restartcheck 0 S)" = '["poweroff"]' ] \
  && ok "a finished install powers off on its one button" \
  || bad "the success screen does not power off: $(restartcheck 0 S)"
[ "$(restartcheck 1 S)" = '["retry"]' ] \
  && ok "a FAILED one retries on the bottom button -- the documented recovery" \
  || bad "the failure screen's bottom button does not retry: $(restartcheck 1 S)"
[ "$(restartcheck 1 BACK)" = '["quit"]' ] \
  && ok "and SELECT leaves" \
  || bad "SELECT on a failed install does not leave: $(restartcheck 1 BACK)"
labels=$(SNIPPET= python3 - <<'PY2'
import json, os, sys
sys.path.insert(0, os.path.join(os.environ["ROOT"], "installer"))
import uiflow
class R: tail = ["boom"]
s = uiflow.ProgressScreen(R()); s.finish(1)
print(json.dumps([b["label"] for b in s.describe()["buttons"]]))
PY2
)
[ "$labels" = '["Try again", "Restart"]' ] \
  && ok "the failure screen offers Try again and Restart" \
  || bad "the failure screen offers: $labels"
# The UI only asks. It must not run `systemctl poweroff` itself: the unit's stop would then reboot
# into the shutdown that is already running.
grep -q 'systemctl' "$ROOT/installer/ui" \
  && bad "the UI runs systemctl itself; the unit owns how the device goes down" \
  || ok "the UI leaves the shutdown to the unit"
mark="$(mktemp -u)"
RETROFORGE_INSTALL_POWEROFF="$mark" python3 - <<'PY2' 2>/dev/null
import importlib.machinery, importlib.util, os, sys
path = os.path.join(os.environ["ROOT"], "installer", "ui")
sys.path.insert(0, os.path.dirname(path))
loader = importlib.machinery.SourceFileLoader("installer_ui", path)
spec = importlib.util.spec_from_loader("installer_ui", loader)
ui = importlib.util.module_from_spec(spec)
loader.exec_module(ui)
ui.ask_for_poweroff()
PY2
[ -e "$mark" ] && ok "asking leaves the mark the unit reads" || bad "ask_for_poweroff left no mark at $mark"
rm -f "$mark"
out="$(RETROFORGE_INSTALL_POWEROFF=/nonexistent/dir/mark python3 - <<'PY2' 2>&1
import importlib.machinery, importlib.util, os, sys
path = os.path.join(os.environ["ROOT"], "installer", "ui")
sys.path.insert(0, os.path.dirname(path))
loader = importlib.machinery.SourceFileLoader("installer_ui", path)
spec = importlib.util.spec_from_loader("installer_ui", loader)
ui = importlib.util.module_from_spec(spec)
loader.exec_module(ui)
ui.ask_for_poweroff()
print("survived")
PY2
)"
printf '%s' "$out" | grep -q survived \
  && ok "a mark it cannot write costs a reboot, not a crash" \
  || bad "an unwritable mark kills the UI: $out"

# =================================================================================================
# §4d: no controller and no keyboard -> stop
# =================================================================================================
# Both fixtures are shaped like the real file, and both traps in them were measured on a device:
# InputPlumber ALWAYS publishes a virtual keyboard that DECLARES the whole alphabet while carrying
# only a couple of quick-access buttons (KeyHome/KeyF1 -- no letters), and pmic_pwrkey/gpio-keys
# carry `Handlers=kbd` while being unable to type a letter.
cat >"$T/devices-none" <<'EOF'
I: Bus=0000 Vendor=0000 Product=0000 Version=0000
N: Name="pmic_pwrkey"
S: Sysfs=/devices/platform/soc@0/c400000.spmi/spmi-0/0-00/input/input0
H: Handlers=kbd event0
B: EV=3
B: KEY=10000000000000 0

I: Bus=0019 Vendor=0001 Product=0001 Version=0100
N: Name="gpio-keys"
S: Sysfs=/devices/platform/gpio-keys/input/input4
H: Handlers=kbd event3
B: EV=3
B: KEY=8000000000000 0

I: Bus=0003 Vendor=1234 Product=5678 Version=0111
N: Name="InputPlumber Keyboard"
S: Sysfs=/devices/virtual/input/input10
H: Handlers=sysrq kbd event8
B: EV=3
B: KEY=300000c07 ff9f207ac07057ff fabeffdfffefffff fffffffffffffffe
EOF
{ cat "$T/devices-none"; cat <<'EOF'

I: Bus=0003 Vendor=413c Product=2113 Version=0111
N: Name="Dell KB216 Wired Keyboard"
S: Sysfs=/devices/platform/soc@0/1c08000.pcie/usb1/1-3/1-3:1.0/input/input14
H: Handlers=sysrq kbd event12
B: EV=120013
B: KEY=1000000000007 ff9f207ac14057ff febeffdfffefffff fffffffffffffffe
EOF
} >"$T/devices-kbd"

keycheck() {  # <devices-file> -> prints True/False
  RETROFORGE_UI_INPUT_DEVICES="$1" python3 -c '
import os, sys
sys.path.insert(0, os.path.join(os.environ["ROOT"], "installer"))
import uipad
print(uipad.typing_keyboard_present())'
}

CASE="§4d: what counts as something to answer with"
[ "$(keycheck "$T/devices-kbd")" = True ] \
  && ok "a USB keyboard counts" \
  || bad "a real keyboard was not detected"
[ "$(keycheck "$T/devices-none")" = False ] \
  && ok "and a machine with only power/volume keys and InputPlumber's virtual keyboard does not" \
  || bad "something that cannot type a letter was counted as a keyboard"
# The two exclusions, named individually so a regression says which one broke.
grep -q 'devices/virtual' installer/uipad.py \
  && ok "the virtual keyboard is excluded by sysfs path -- it declares letters it never carries" \
  || bad "nothing excludes InputPlumber's own keyboard"
[ "$(keycheck "$T/nonexistent-devices-file")" = True ] \
  && ok "an unreadable device list reports PRESENT -- the gate is the safety property, not this" \
  || bad "a missing /proc file made the installer refuse to run"

CASE="#69: the UI attaches InputPlumber's pad, never the sources it is built from"
# Real /proc/bus/input/devices content, AYANEO Pocket ACE 2026-08-26, the boot that lost the race.
{
  cat <<'EOF'
I: Bus=0003 Vendor=4001 Product=0428 Version=0111
N: Name="AYANEO Controller"
S: Sysfs=/devices/platform/soc@0/1c08000.pcie/pci0001:00/0001:00:00.0/usb1/1-2/1-2:1.0/0003:4001:0428.0003/input/input5
H: Handlers=js0 event5
B: EV=20000b

I: Bus=0003 Vendor=045e Product=0b12 Version=0001
N: Name="Microsoft Xbox Series S|X Controller"
S: Sysfs=/devices/virtual/input/input9
H: Handlers=kbd js1 event9
B: EV=20000b

I: Bus=0003 Vendor=28de Product=11ff Version=0001
N: Name="Microsoft X-Box 360 pad 0"
S: Sysfs=/devices/virtual/input/input10
H: Handlers=js2 event10
B: EV=20000b
EOF
} >"$T/devices-pads"

padids() {  # <devices-file> -> prints the sorted vendor:product set
  python3 -c '
import os, sys
sys.path.insert(0, os.path.join(os.environ["ROOT"], "installer"))
import uipad
print(" ".join(sorted(uipad.virtual_pad_ids(sys.argv[1]))))' "$1"
}

[ "$(padids "$T/devices-pads")" = "045e:0b12 28de:11ff" ] \
  && ok "the two uinput pads are found and the physical AYANEO source is not" \
  || bad "virtual_pad_ids did not separate InputPlumber's target from its source: got '$(padids "$T/devices-pads")'"
case "$(padids "$T/devices-pads")" in
  *4001:0428*) bad "the raw source pad was classed as virtual -- the UI would hold it and break the gate" ;;
  *) ok "4001:0428 stays out: holding it is what took the composite device down" ;;
esac
[ -z "$(padids "$T/nonexistent-devices-file")" ] \
  && ok "an unreadable device list yields no ids, so every pad is attached rather than none" \
  || bad "a missing /proc file was treated as an allow-list"
# The identity must NOT be matched by name: SDL renames a pad to gamecontrollerdb's string, so the
# device above reaches the UI as "Xbox Series X Controller" and would match nothing.
python3 -c '
import sys
guid = "030000005e040000120b000001000000"   # bus 0003, vendor 045e, product 0b12
sys.exit(0 if "%04x:%04x" % (int(guid[10:12]+guid[8:10],16), int(guid[18:20]+guid[16:18],16)) == "045e:0b12" else 1)' \
  && ok "vendor:product survives SDL's rename via the joystick GUID byte layout" \
  || bad "the GUID vendor/product offsets are wrong -- every pad would read as unidentified"
grep -q '_drop_sources' "$ROOT/installer/uipad.py" \
  && ok "a source opened before InputPlumber's target appears is released when it does" \
  || bad "nothing releases a source pad grabbed while winning the race, which ordering cannot fix"

CASE="§4d: with nothing to answer with, consent is refused rather than drawn"
# The screen alone would leave the spine blocked on an answer that can never come.
printf 'SHOWN\n' >"$T/ev-noinput"
DEVFILE="$T/devices-none" ui_ask "$T/ev-noinput" "$T/facts-wipe" SWNE \
  && bad "consent was granted on a machine with no input device" \
  || ok "the shim exits non-zero, which the spine reads as an abort"
[ -z "$OUT" ] \
  && ok "and nothing reaches stdout, so nothing can be mistaken for an answer" \
  || bad "it put something on stdout: $(printf '%q' "$OUT")"
grep -q 'no input device to take consent on' "$T/ui.log" \
  && ok "the journal says which of the two failures this is" \
  || bad "the refusal is not explained: $(cat "$T/ui.log")"
# And it must be the refusal, not a crash: a machine that gets a keyboard back must recover.
DEVFILE="$T/devices-kbd" ui_ask "$T/ev-noinput" "$T/facts-wipe" SWNE \
  && ok "the same run with a keyboard attached takes consent normally" \
  || bad "a machine WITH a keyboard was also refused: $ERR"
[ "$OUT" = SWNE ] \
  && ok "so the stop is about the input device and nothing else" \
  || bad "the answer was wrong with a keyboard present: $OUT"

CASE="§4d: the screen says what is wrong and what to do"
noinput="$(python3 -c '
import importlib.util, json, os, sys
from importlib.machinery import SourceFileLoader
loader = SourceFileLoader("nvui", os.path.join(os.environ["ROOT"], "installer/ui"))
spec = importlib.util.spec_from_loader("nvui", loader)
ui = importlib.util.module_from_spec(spec); loader.exec_module(ui)
print(json.dumps(ui.NoInputScreen().describe()))')"
printf '%s' "$noinput" | grep -qi 'controller or .*keyboard' \
  && ok "it names both things it looked for" \
  || bad "the screen does not say what is missing"
printf '%s' "$noinput" | grep -qi 'USB keyboard' \
  && ok "and tells the user the one thing that fixes it" \
  || bad "the screen offers no way out"
printf '%s' "$noinput" | grep -qi 'Nothing has been written' \
  && ok "while saying the device is untouched, which is the question a stuck installer raises" \
  || bad "it does not say whether anything was written"

CASE="§6: the pygame wheel is pinned to the Python the image actually ships"
# A WHEEL IS ABI-LOCKED. packages/pygame-ce/prebuilt.pin carries a cp313 build because rootfs/manifest.lock
# ships python 3.13; a python bump in the lock makes that wheel unimportable, and the symptom would
# be an installer that comes up to a black panel with an ImportError in a child's stderr -- which
# is exactly how the pygame.controller bug presented. Two files, one fact, so assert they agree.
PIN="$ROOT/packages/pygame-ce/prebuilt.pin"
[ -f "$PIN" ] || bad "no pygame pin at $PIN"
pin_py="$(sed -n 's/^python:[[:space:]]*//p' "$PIN" | head -1)"
lock_py="$(awk '$1 == "python" {print $2}' "$ROOT/rootfs/manifest.lock" | head -1)"
want="cp$(printf '%s' "$lock_py" | cut -d. -f1)$(printf '%s' "$lock_py" | cut -d. -f2)"
[ -n "$pin_py" ] && [ "$pin_py" = "$want" ] \
  && ok "the wheel is $pin_py and the lock ships python $lock_py" \
  || bad "the wheel is '$pin_py' but the lock ships python '$lock_py' (wants $want)"
# The extraction target has to name that same python, or the wheel lands where nothing imports it.
grep -q "^dest:.*python3\.$(printf '%s' "$lock_py" | cut -d. -f2)/" "$PIN" \
  && ok "and it is extracted into that interpreter's site-packages" \
  || bad "the pin's dest does not name python3.$(printf '%s' "$lock_py" | cut -d. -f2): $(grep '^dest:' "$PIN")"


CASE="ui: the game-controller API is the one pygame actually has"
# `pygame.controller` does not exist as a top-level module in either pygame or pygame-ce -- it is
# pygame._sdl2.controller. Written from the docs rather than the library, that line took the whole
# UI down with an AttributeError the first time it ran against a real pygame (Pocket S2,
# 2026-08-22), AFTER gamescope had come up, so the symptom was a black panel. Nothing offline could
# catch it: the suite never imports pygame, by design.
grep -q 'from pygame._sdl2 import controller' "$ROOT/installer/uipad.py" \
  && ok "the controller module is imported from pygame._sdl2, where it lives" \
  || bad "uipad.py does not import the controller API from pygame._sdl2"
# Comments stripped first -- the file EXPLAINS the trap at length, and an assertion that could not
# tell the warning from the thing warned about would fail on its own documentation.
if sed 's/#.*$//' "$ROOT/installer/uipad.py" | grep -qE '(^|[^_.])pygame\.controller'; then
  bad "something still reaches for the top-level pygame.controller, which does not exist"
else
  ok "and nothing reaches for the top-level name that does not exist"
fi

CASE="ui: the model is separable from the view"
# Everything above ran with no SDL, no display and no pad, and that is only true while the state
# machine cannot reach pygame at all. The separation is physical: installer/ui names pygame nowhere,
# installer/uiview.py is the only file that imports it, and installer/ui loads that module inside
# build_io() -- i.e. only once something has decided to open a display.
if grep -nE '^[[:space:]]*(import pygame|from pygame)' "$UI"; then
  bad "installer/ui imports pygame"
else
  ok "installer/ui never imports pygame -- it only ever holds a handle the view gave it"
fi
[ "$(grep -c 'import pygame' "$VIEW")" -eq 1 ] \
  && ok "installer/uiview.py imports it exactly once" \
  || bad "uiview.py imports pygame more than once"
grep -qE '^\s+import pygame' "$VIEW" \
  && ok "and that import is inside the view class, not at module scope" \
  || bad "uiview.py imports pygame at module scope"
grep -q 'import uiview' "$UI" \
  && ok "installer/ui loads the view lazily, in build_io()" \
  || bad "installer/ui does not load the view module"

CASE="the prompt row sits on ONE baseline"
# There is no pygame on the build host -- this suite exists precisely so the UI can be tested with
# no SDL, no panel and no pad -- so these are structural. A diamond's label is centred on the
# diamond; SELECT used to be blitted at the row's top, a whole span higher, so the two captions in
# the same row did not line up (reported from the panel, 2026-08-25).
grep -q 'cy - surf.get_height() // 2' "$VIEW" \
  && ok "SELECT's caption is centred on the row's centre line, like the diamond captions" \
  || bad "the wordy control is not centred on the row"
grep -qE '_inline\(x, cy,' "$VIEW" \
  && ok "and the centre line is passed in, so one row cannot have two of them" \
  || bad "_inline still takes the row's top instead of its centre"

CASE="the type scale is one number"
# The panel is held at arm's length; h/34 read small on the device. Everything is derived from
# `base` so a size complaint moves one number and the title/heading/body relationship survives it.
grep -qE 'base = max\(16, int\(self\.h / 28\)\)' "$VIEW" \
  && ok "the body size is h/28" || bad "the base type size is not what this suite expects"
[ "$(grep -cE 'pygame\.font\.Font\(None, (int\()?base' "$VIEW")" -eq 3 ] \
  && ok "and the title and headings are multiples of it, not sizes of their own" \
  || bad "a font size is set independently of base -- a scale change will skew the hierarchy"

CASE="ui: the consent socket is root-only"
printf 'SHOWN\n' >"$T/ev-perm"
SOCK="$T/perm.sock"
RETROFORGE_UI_SOCK="$SOCK" RETROFORGE_UI_EVENTS="$T/ev-perm" "$UI" >/dev/null 2>&1 &
p=$!
for _ in $(seq 1 200); do [ -S "$SOCK" ] && break; sleep 0.02; done
mode="$(stat -c %a "$SOCK" 2>/dev/null)"
[ "$mode" = 600 ] \
  && ok "mode 0600 -- nothing else on the medium has business answering for the user" \
  || bad "the socket is mode $mode"
kill "$p" 2>/dev/null; wait "$p" 2>/dev/null

# =================================================================================================
# release-info — what the medium would install, and why it sometimes cannot
# =================================================================================================
# The card carries no bundle at all, so this is the program that says what will be downloaded. Every
# failure below reaches a person as a line on the pre-flight screen or the Settings row, and a 404 on
# <channel>/latest.json is exactly the answer this file has to name.
RELINFO="$ROOT/installer/release-info"
[ -x "$RELINFO" ] || { echo "no release-info: $RELINFO" >&2; exit 1; }
mkdir -p "$T/rel"
export REL_CALLS="$T/rel/curl-calls"
relinfo() {  # prints release-info's key=value output
  : >"$REL_CALLS"
  PATH="$T/bin:$PATH" NET_CURL_CALLS="$REL_CALLS" \
    RETROFORGE_OTA_URL="${REL_URL-https://ota.example}" \
    RETROFORGE_OTA_CONFIG="${REL_CONF-/dev/null}" \
    RETROFORGE_RELEASE_FILE="${REL_RELEASE-/dev/null}" \
    RETROFORGE_MOUNTINFO="${REL_MOUNTINFO-/dev/null}" \
    "$RELINFO" 2>/dev/null
}
MANIFEST='{"version":"0.2.0","build":"20260825","bundle":"retroforge-0.2.0.raucb","size":4294967296,"sha256":"deadbeef"}'

CASE="release-info: a published release becomes a bundle URL"
out="$(NET_CURL_BODY="$MANIFEST" relinfo)"
[ "$(state "$out")" = ok ] && ok "a manifest that parses is STATE=ok" || bad "not ok: $out"
printf '%s' "$out" | grep -qx 'BUNDLE=https://ota.example/stable/retroforge-0.2.0.raucb' \
  && ok "the bundle URL is the channel's, with the manifest's bare filename on the end" \
  || bad "the bundle URL is wrong: $out"
# THE BUNDLE IS THE ONLY THING IT RESOLVES. /home is staged empty on the device, so there is no
# second artifact to download -- asserted, because re-adding one would reintroduce a publisher and
# a download during the install.
printf '%s' "$out" | grep -q '^SEED=' \
  && bad "release-info emits a SEED url -- /home needs nothing downloaded" \
  || ok "and nothing but the bundle: /home is built on the device, not fetched"
printf '%s' "$out" | grep -q '^DETAIL=RetroForge 0.2.0, 4.0 GiB from ota.example' \
  && ok "one line for the panel: the version, the download size and the host it comes from" \
  || bad "the detail line is not what the screen puts under 'To install': $out"

CASE="release-info: a dev image installs the root it is running from"
printf 'RETROFORGE_BUILD=20261109T120000Z\nRETROFORGE_VERSION=dev\nRETROFORGE_MODE=dev\n' >"$T/rel/dev-release"
printf '%s\n' \
  '22 1 0:20 / / ro,relatime shared:1 - tmpfs tmpfs rw' \
  '30 1 0:31 / / ro,relatime shared:2 - btrfs /dev/mmcblk0p4 ro,compress=zstd' \
  '31 30 0:32 / /var rw shared:3 - ext4 /dev/mmcblk0p6 rw' >"$T/rel/mountinfo"
out="$(REL_RELEASE="$T/rel/dev-release" REL_MOUNTINFO="$T/rel/mountinfo" NET_HOST_RC=22 relinfo)"
[ "$(state "$out")" = ok ] \
  && ok "an empty dev channel does not stop a dev image: STATE=ok" \
  || bad "a dev image was refused: $out"
printf '%s' "$out" | grep -qx 'BUNDLE=running:/dev/mmcblk0p4' \
  && ok "the source is the device / is mounted from, the last mount of / winning" \
  || bad "the running root is not the source: $out"
printf '%s' "$out" | grep -qx 'SOURCE=running' && printf '%s' "$out" | grep -qx 'BUILD=20261109T120000Z' \
  && ok "and it says so, by build" || bad "SOURCE/BUILD missing: $out"
[ ! -s "$REL_CALLS" ] \
  && ok "the update server is not asked at all" || bad "a dev image still fetched: $(cat "$REL_CALLS")"
out="$(REL_RELEASE="$T/rel/dev-release" REL_MOUNTINFO=/dev/null relinfo)"
[ "$(state "$out")" = malformed ] \
  && ok "a dev image whose root cannot be found says so, and offers nothing" \
  || bad "an unknown running root was offered: $out"
printf 'RETROFORGE_MODE=release\n' >"$T/rel/rel-release"
out="$(REL_RELEASE="$T/rel/rel-release" REL_MOUNTINFO="$T/rel/mountinfo" NET_CURL_BODY="$MANIFEST" relinfo)"
printf '%s' "$out" | grep -qx 'BUNDLE=https://ota.example/stable/retroforge-0.2.0.raucb' \
  && ok "a release image still installs the channel's release" \
  || bad "a release image did not resolve the channel: $out"

CASE="release-info: a channel with nothing published is not an unreachable server"
out="$(NET_HOST_RC=22 relinfo)"
[ "$(state "$out")" = no-release ] \
  && ok "curl's 22 -- an HTTP error -- is STATE=no-release" \
  || bad "a 404 was not read as an empty channel: $out"
printf '%s' "$out" | grep -q "stable" \
  && ok "and the channel is named, because that is what the operator would have to change" \
  || bad "the channel is not in the message: $out"
out="$(NET_HOST_RC=6 relinfo)"
[ "$(state "$out")" = unreachable ] \
  && ok "every other curl failure is STATE=unreachable, kept apart from an empty channel" \
  || bad "a transport failure was not reported as unreachable: $out"

CASE="release-info: a manifest that does not parse is not a release"
[ "$(state "$(NET_CURL_BODY='<html>hi</html>' relinfo)")" = malformed ] \
  && ok "a captive portal's HTML is STATE=malformed, not a bundle" \
  || bad "non-JSON was accepted"
[ "$(state "$(NET_CURL_BODY='{"version":"1","bundle":"b.raucb"}' relinfo)")" = malformed ] \
  && ok "a manifest with no size is refused, as retroforge-update refuses it" \
  || bad "a sizeless manifest was accepted"
[ "$(state "$(NET_CURL_BODY='{"bundle":"b.raucb","size":10}' relinfo)")" = malformed ] \
  && ok "and one that names no version, which is what the screen would have to call it" \
  || bad "a versionless manifest was accepted"

CASE="release-info: the manifest cannot aim this medium at another host"
# THE MANIFEST IS NOT A TRUST BOUNDARY. Left unchecked, `bundle` is a redirect primitive: the
# signature would still reject whatever came back, but a manifest must not be able to point the
# installer somewhere else at all. These are retroforge-update's shapes, checked against the port.
for b in 'http://evil.example/x.raucb' '../../etc/passwd' '/etc/passwd' '..\\x.raucb' '.hidden'; do
  out="$(NET_CURL_BODY="{\"version\":\"1\",\"bundle\":\"$b\",\"size\":10}" relinfo)"
  if [ "$(state "$out")" = malformed ] && ! printf '%s' "$out" | grep -q '^BUNDLE='; then
    ok "$b is refused, and no BUNDLE is emitted for it"
  else
    bad "$b produced a bundle: $out"
  fi
done

CASE="release-info: the channel comes from the same file the OTA client reads"
printf 'OTA_CHANNEL=dev\n' >"$T/rel/ota.conf"
out="$(REL_CONF="$T/rel/ota.conf" NET_CURL_BODY="$MANIFEST" relinfo)"
printf '%s' "$out" | grep -qx 'URL=https://ota.example/dev/latest.json' \
  && ok "/etc/retroforge/ota.conf's OTA_CHANNEL steers it, as it steers retroforge-update" \
  || bad "the channel from the config file was ignored: $out"
printf '%s' "$out" | grep -q 'BUNDLE=https://ota.example/dev/' \
  && ok "and the bundle comes from that channel, not from stable" \
  || bad "the bundle URL kept the default channel: $out"

CASE="release-info: the channel is the one Updates shows"
# Same order as retroforge-update's channel_setting(): env, /etc, $HOME, built-in. A dev card pins
# OTA_CHANNEL in /etc on purpose, and the user's file must not undo that.
mkdir -p "$T/userconf"
relchan() {
  NET_CURL_BODY="$MANIFEST" RETROFORGE_OTA_USER_CONFIG="$T/userconf/ota.conf" relinfo | sed -n 's/^CHANNEL=//p'
}
printf 'OTA_CHANNEL=beta\n' >"$T/userconf/ota.conf"
[ "$(relchan)" = beta ] && ok "the channel picked in Updates is the one installed from" \
  || bad "the user's channel is ignored: $(relchan)"
[ "$(REL_CONF="$T/rel/ota.conf" relchan)" = dev ] && ok "and a dev card's pin in /etc still outranks it" \
  || bad "the user's file undid the pin: $(REL_CONF="$T/rel/ota.conf" relchan)"
printf 'OTA_CHANNEL=../../elsewhere\n' >"$T/userconf/ota.conf"
[ "$(relchan)" = stable ] && ok "one that is not a path segment is refused: player writes this file, root reads it" \
  || bad "a malformed channel was used: $(relchan)"
printf 'OTA_URL=https://evil.example\nOTA_CHANNEL=beta\n' >"$T/userconf/ota.conf"
REL_URL= NET_CURL_BODY="$MANIFEST" RETROFORGE_OTA_USER_CONFIG="$T/userconf/ota.conf" relinfo \
  | grep -q 'evil.example' && bad "the host was taken from a file player writes" \
  || ok "the host is never read from that file"
rm -f "$T/userconf/ota.conf"
# player owns this file and root reads it, and a home survives reboots.
mkfifo "$T/userconf/ota.conf"
[ "$(timeout 10 bash -c "$(declare -f relinfo relchan); $(declare -p T RELINFO REL_CALLS MANIFEST); relchan")" = stable ] \
  && ok "a FIFO in its place cannot hang the pre-flight" || bad "a FIFO hung or steered release-info"
rm -f "$T/userconf/ota.conf"
ln -s /dev/zero "$T/userconf/ota.conf"
[ "$(relchan)" = stable ] && ok "a symlink in its place is not followed" || bad "a symlink was followed: $(relchan)"
rm -f "$T/userconf/ota.conf"
printf 'OTA_CHANNEL=beta\n' >"$T/userconf/real"
ln -s "$T/userconf/real" "$T/userconf/ota.conf"
[ "$(relchan)" = stable ] && ok "not even to a real file" || bad "a symlink to a file was followed"
rm -f "$T/userconf/ota.conf" "$T/userconf/real"

CASE="release-info: a failure is an answer, not an error"
# The caller reads STATE and never a shell status.
NET_HOST_RC=6 relinfo >/dev/null 2>&1 \
  && ok "it exits 0 even when it could not resolve a release" \
  || bad "release-info exits non-zero, and its caller only reads STATE"
unset NET_CURL_BODY NET_HOST_RC

# =================================================================================================
# pre-flight — §5's screen before the gate
# =================================================================================================
# Stubs for the three read-only tools the screen derives from. The carve stub RECORDS its calls, so
# a case can assert the screen re-asks rather than interpolating between answers.
mkdir -p "$T/bin"
cat >"$T/bin/select-target.sh" <<'EOF'
#!/usr/bin/env bash
printf 'TARGET=/dev/sda\nMODE=fresh\nSECTOR=512\nUD_INDEX=11\nUD_START=100\nUD_END=200\nCEIL=999\n'
EOF
cat >"$T/bin/carve.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$CARVE_CALLS"
printf 'CEIL=999\nNEW_END=500\nRETROFORGE_MIB=81920\nRETROFORGE_GIB=%s\nREPLACES_OURS=1\n' "$(( 96 - $3 ))"
printf 'DESTROY=11 userdata data-erased\n'
printf 'DESTROY=17 retroforge-home replaced\n'
EOF
# EMITTED THE WAY THE REAL ONE EMITS IT: device-env uses `printf '%s=%q\n'`, and bash's %q escapes
# rather than quotes when it can, so a board name arrives as `AYANEO\ Pocket\ ACE`. The stub used to
# emit the single-quoted form -- the other thing %q produces -- and a parser that only stripped
# quotes passed here while putting a backslash on the panel of a real Pocket S2.
cat >"$T/bin/device-env" <<'EOF'
#!/usr/bin/env bash
printf '%s=%q\n' RETROFORGE_DEVICE_NAME 'AYANEO Pocket ACE'
printf '%s=%q\n' RETROFORGE_SOC_CLASS SM8550
EOF
chmod +x "$T/bin"/*
export CARVE_CALLS="$T/carve-calls"; : >"$CARVE_CALLS"
mkdir -p "$T/rel"

# THE REAL release-info, NOT A STUB, with the curl above under it: the screen's "To install" line is
# the last hop of a chain (curl -> manifest validation -> the panel) and stubbing the middle of it
# would leave the two halves free to disagree about what a resolved release looks like. The cases
# that leave BUNDLE_OVERRIDE set never reach it -- that is the hardware stager's shape, and it
# short-circuits.
flow() {  # <python snippet reading `pf` (a PreflightScreen)>
  PATH="$T/bin:$PATH" \
  RETROFORGE_SELECT_TARGET="$T/bin/select-target.sh" RETROFORGE_CARVE="$T/bin/carve.sh" \
  RETROFORGE_DEVICE_ENV="$T/bin/device-env" RETROFORGE_INSTALL_BUNDLE="${BUNDLE_OVERRIDE-https://x/b.raucb}" \
  RETROFORGE_RELEASE_INFO="${RELINFO_OVERRIDE-$ROOT/installer/release-info}" \
  RETROFORGE_OTA_URL=https://ota.example RETROFORGE_OTA_CONFIG=/dev/null \
  SNIPPET="$1" python3 - <<'PY'
import json, os, sys
sys.path.insert(0, os.path.join(os.environ["ROOT"], "installer"))
import uiflow
facts, _why = uiflow.gather_preflight()
pf = uiflow.PreflightScreen(facts) if facts else None
exec(os.environ["SNIPPET"])
PY
}

CASE="pre-flight: every figure comes from the tool that will act on it"
out="$(flow 'print(json.dumps(pf.describe()))')"
printf '%s' "$out" | grep -q 'AYANEO Pocket ACE' \
  && ok "the board names itself, from device-env rather than from a guess" \
  || bad "the device name is missing: $out"
printf '%s' "$out" | grep -q 'AYANEO\\\\ Pocket' \
  && bad "the shell escaping reached the screen -- this is the Pocket S2 backslash" \
  || ok "and the shell escaping device-env applies is undone, not printed"
# THE OTHER PRODUCER. release-info emits plain prose with spaces, and the parser that unescapes
# device-env's %q must not truncate it -- taking the first shlex token rendered a real device's
# "the installer can reach https://..." as the single word "the".
kvcheck="$(python3 -c '
import os, sys
sys.path.insert(0, os.path.join(os.environ["ROOT"], "installer"))
import uiflow
d = uiflow.kv("DETAIL=the installer can reach https://x\nNAME=AYANEO\\ Pocket\\ S2\n")
print("%s|%s" % (d["DETAIL"], d["NAME"]))')"
[ "$kvcheck" = "the installer can reach https://x|AYANEO Pocket S2" ] \
  && ok "and a value with spaces survives whole, from either producer" \
  || bad "kv() mangled a value: $kvcheck"
# THE eMMC NAME. A UFS LUN carries device/model; an eMMC has none and names itself in device/name
# (the CID product name) -- the MANGMI Air X's target rendered as "unknown" (2026-10-17).
mkdir -p "$T/sysblock/sda/device" "$T/sysblock/mmcblk1/device"
printf 'KM8V8001JM-B813  \n' >"$T/sysblock/sda/device/model"
printf 'MMC64G\n'            >"$T/sysblock/mmcblk1/device/name"
echo 250069680 >"$T/sysblock/sda/size"; echo 122142720 >"$T/sysblock/mmcblk1/size"
factscheck="$(RETROFORGE_SYS_BLOCK="$T/sysblock" python3 -c '
import os, sys
sys.path.insert(0, os.path.join(os.environ["ROOT"], "installer"))
import uiflow
print("|".join(uiflow.disk_facts(d)["model"] for d in ("/dev/sda", "/dev/mmcblk1", "/dev/sdz")))')"
[ "$factscheck" = "KM8V8001JM-B813|MMC64G|unknown" ] \
  && ok "the target's model is read for UFS and eMMC alike, and unknown only when sysfs has neither" \
  || bad "disk_facts() model: $factscheck"
printf '%s' "$out" | grep -q '/dev/sda' \
  && ok "and the target is the one select-target.sh chose" \
  || bad "the target is not what select-target returned"
printf '%s' "$out" | grep -q 'p11' && printf '%s' "$out" | grep -q 'p17' \
  && ok "the full list of partitions about to be destroyed is on the screen, by index" \
  || bad "the destroy list is not rendered: $out"
printf '%s' "$out" | grep -qi 'retroforge-home' \
  && ok "including /home, which is the one that costs a user their games" \
  || bad "/home is not named in the destroy list"
printf '%s' "$out" | grep -q 'data erased:  p11 userdata' \
  && ok "grouped under its fate, which is stated once for the group" \
  || bad "the destroy list is not grouped by fate: $out"

CASE="pre-flight: a reinstall's partition list fits on the panel"
# NINE LINES DID NOT FIT. HW 2026-08-25, Pocket ACE mid-reinstall: one line per partition ran off
# the bottom and collided with the SELECT row -- worse after the type scale went up, which it did
# because these screens were too small to read.
#
# THIS FIXTURE MIRRORS carve.sh, and the first attempt at the fix failed because an earlier one did
# not. carve.sh ALWAYS emits `userdata data-erased` and THEN one `replaced` per partition of ours,
# so a reinstall has two fates, always. A fix that compacted only when every fate matched could
# therefore never fire on hardware -- and a fixture of eight identical fates, which no disk
# produces, let it pass here anyway. Emit what the real tool emits.
cat >"$T/bin/carve.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$CARVE_CALLS"
printf 'CEIL=999\nNEW_END=500\nRETROFORGE_MIB=81920\nRETROFORGE_GIB=%s\nREPLACES_OURS=1\n' "$(( 96 - $3 ))"
printf 'DESTROY=11 userdata data-erased\n'
for i in 1 2 3 4 5 6 7 8; do printf 'DESTROY=%s retroforge-p%s replaced\n' "$i" "$i"; done
EOF
chmod +x "$T/bin/carve.sh"
nine="$(flow 'print(json.dumps(pf.describe()))')"
printf '%s' "$nine" | grep -q 'These 9 partitions will be destroyed' \
  && ok "the heading carries the count, so the number is never inferred from line-counting" \
  || bad "the destroy heading does not carry the count: $nine"
printf '%s' "$nine" | grep -q 'data erased:  p11 userdata' \
  && ok "userdata is grouped under its own fate" \
  || bad "the data-erased group is missing: $nine"
printf '%s' "$nine" | grep -q 'replaced:  p1 retroforge-p1,  p2 retroforge-p2' \
  && ok "and our eight share one 'replaced' line instead of eight of their own" \
  || bad "the replaced group is not one line: $nine"
missing=""
for i in 1 2 3 4 5 6 7 8; do
  printf '%s' "$nine" | grep -q "p$i retroforge-p$i" || missing="$missing p$i"
done
printf '%s' "$nine" | grep -q 'p11 userdata' || missing="$missing p11"
[ -z "$missing" ] \
  && ok "with every index and name still on the panel -- compacted, never shortened" \
  || bad "the destroy list dropped partitions:$missing"
# The whole point is the line count, so count them: two groups is two lines, not nine.
[ "$(printf '%s' "$nine" | python3 -c 'import json,sys
d = json.load(sys.stdin)
b = [x for x in d["blocks"] if "will be destroyed" in x[0]][0][1]
print(len(b.split("\n")))')" = 2 ] \
  && ok "two fates, two lines -- the six the panel did not have are back" \
  || bad "the destroy body is not one line per fate"
printf '%s' "$out" | grep -qi 'Nothing has been written yet' \
  && ok "and it says nothing has happened yet, because nothing has" \
  || bad "the screen does not say the disk is still untouched"

CASE="pre-flight: the size knob re-asks carve.sh, it does not interpolate"
: >"$CARVE_CALLS"
out="$(flow '
pf.handle("RIGHT"); a = pf.describe()
pf.handle("LEFT"); pf.handle("LEFT"); b = pf.describe()
print(json.dumps({"gib": pf.gib, "a": a, "b": b}))')"
[ "$(grep -c . "$CARVE_CALLS")" -ge 4 ] \
  && ok "every adjustment asks carve.sh again ($(grep -c . "$CARVE_CALLS") calls)" \
  || bad "the screen adjusted without re-asking carve: $(cat "$CARVE_CALLS")"
grep -q 'plan /dev/sda 20' "$CARVE_CALLS" && grep -q 'plan /dev/sda 12' "$CARVE_CALLS" \
  && ok "and it asks about the size it is showing, not the one it started with" \
  || bad "carve was not asked about the adjusted sizes: $(cat "$CARVE_CALLS")"
printf '%s' "$out" | python3 -c 'import json,sys; d=json.load(sys.stdin); sys.exit(0 if d["gib"]==12 else 1)' \
  && ok "left and right move it by a step each, with a floor under them" \
  || bad "the adjustment did not land where it should"

CASE="pre-flight: the medium works out for itself what it would install"
# THE POINT OF PHASE 6. Nothing is configured into this medium: the bundle comes from the channel
# manifest, and until it did the screen ended at "NO BUNDLE CONFIGURED" with a Cancel button --
# which is where the first end-to-end hardware run stopped.
out="$(BUNDLE_OVERRIDE= NET_CURL_BODY="$MANIFEST" \
  flow 'pf.handle("S"); print(json.dumps({"r": pf.result, "d": pf.describe(), "f": pf.facts}))')"
printf '%s' "$out" | grep -q '"r": \["start", 16\]' \
  && ok "a resolved release makes the screen startable with nothing else configured" \
  || bad "it will not start against a published release: $out"
printf '%s' "$out" | grep -q 'RetroForge 0.2.0, 4.0 GiB from ota.example' \
  && ok "and 'To install' names the version, the size and the host" \
  || bad "the screen does not say what it would download: $out"
printf '%s' "$out" | grep -q '"seed"' \
  && bad "the facts still carry a /home source: $out" \
  || ok "and the bundle is all it needs -- there is no /home source to resolve"

CASE="pre-flight: the spine is started with the URL the screen showed"
# THE ONE THAT WOULD HAVE SHIPPED SILENTLY. SpineRun used to read the module's own BUNDLE
# -- the environment, i.e. empty on a medium -- so a screen that had resolved a release perfectly
# would still have handed `--bundle ''` to the spine. Resolving a SECOND time here would be no
# better: the server can publish between the two calls, and then what installs is not what the
# operator read and consented to. It is the screen's own facts or nothing.
cat >"$T/bin/spine-recorder" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >"$T/rel/spine-argv"
EOF
chmod +x "$T/bin/spine-recorder"
rm -f "$T/rel/spine-argv"
BUNDLE_OVERRIDE= NET_CURL_BODY="$MANIFEST" RETROFORGE_SPINE="$T/bin/spine-recorder" \
  flow '
import time
r = uiflow.SpineRun(16, "/nonexistent.sock", pf.facts["bundle"], "fresh")
for _ in range(500):
    if r.returncode() is not None: break
    time.sleep(0.01)' >/dev/null 2>&1
argv="$(cat "$T/rel/spine-argv" 2>/dev/null)"
printf '%s' "$argv" | grep -q -- '--bundle https://ota.example/stable/retroforge-0.2.0.raucb' \
  && ok "the resolved bundle URL reaches the spine's command line" \
  || bad "the spine was started with something else: $argv"
printf '%s' "$argv" | grep -qi 'seed' \
  && bad "the spine was handed a /home source it no longer accepts: $argv" \
  || ok "and no /home source -- the spine builds the player home itself"
grep -q 'top.facts\["bundle"\], "fresh")' "$ROOT/installer/ui" \
  && ok "and the loop passes the SCREEN's facts, so nothing re-resolves behind the consent" \
  || bad "installer/ui does not hand SpineRun the screen's own bundle"
# --intent, WHICH HARDWARE FOUND MISSING. On a disk that already carries RetroForge the spine refuses
# to choose for us, so an install there died at select-target every time -- with the UI having done
# everything else right (Pocket ACE, 2026-08-25). The argument existed; nothing passed it.
printf '%s' "$argv" | grep -q -- '--intent fresh' \
  && ok "and --intent fresh, which is what the pre-flight screen promised" \
  || bad "the spine is started with no intent, so a disk of ours refuses: $argv"
grep -q '"fresh")' "$ROOT/installer/ui" \
  && ok "the loop names the intent explicitly rather than leaving it to a default" \
  || bad "installer/ui does not pass an intent to SpineRun"

CASE="pre-flight: it cannot start an install it has no bundle for"
out="$(BUNDLE_OVERRIDE= NET_HOST_RC=22 \
  flow 'pf.handle("S"); print(json.dumps({"r": pf.result, "d": pf.describe()}))')"
printf '%s' "$out" | grep -q '"start"' \
  && bad "it started an install with no bundle: $out" \
  || ok "pressing continue with no release resolved starts nothing"
# The quotes release-info puts round the channel are gone by the time this reaches a screen: kv()
# parses values the way the shell would, which is what undoes device-env's %q escaping. Prose is
# prose either way, and the terminal caller still sees the quoted form.
printf '%s' "$out" | grep -q "nothing published in the stable channel" \
  && ok "and the screen says WHICH failure it is, not that a bundle is 'not configured'" \
  || bad "the screen does not explain why it will not start: $out"
printf '%s' "$out" | grep -q '"label": "Check again"' \
  && ok "the button asks the server again, which is the one thing that could change the answer" \
  || bad "there is no way to re-ask: $out"
printf '%s' "$out" | grep -q '"r": \["recheck"\]' \
  && ok "and pressing it says so to the loop, which keeps the size the operator dialled in" \
  || bad "the press produced no recheck: $out"

CASE="pre-flight: a dev run's override wins, and costs no round trip"
# docs/install-internal.md serves a bundle off a laptop and names it in RETROFORGE_INSTALL_BUNDLE. With
# that set there is nothing to ask.
cat >"$T/bin/release-info-marker" <<EOF
#!/usr/bin/env bash
: >"$T/rel/was-run"
EOF
chmod +x "$T/bin/release-info-marker"
rm -f "$T/rel/was-run"
out="$(RELINFO_OVERRIDE="$T/bin/release-info-marker" flow 'print(json.dumps(pf.facts))')"
[ ! -e "$T/rel/was-run" ] \
  && ok "release-info is never run when the bundle is given" \
  || bad "it went to the server for facts it had been handed"
printf '%s' "$out" | grep -q 'https://x/b.raucb' \
  && ok "and the stager's bundle URL reaches the screen unchanged" \
  || bad "the override did not reach the facts: $out"

CASE="pre-flight: a failed resolution is never cached, or Check again could not work"
# The button's whole promise. A cached "no" would make it redraw the same screen forever, and the
# operator would be pressing a button that cannot answer -- the shape §4b already paid for once.
twice="$(PATH="$T/bin:$PATH" RETROFORGE_RELEASE_INFO="$ROOT/installer/release-info" \
  RETROFORGE_OTA_URL=https://ota.example RETROFORGE_OTA_CONFIG=/dev/null \
  RETROFORGE_INSTALL_BUNDLE= \
  MANIFEST="$MANIFEST" python3 - <<'PY'
import json, os, sys
sys.path.insert(0, os.path.join(os.environ["ROOT"], "installer"))
import uiflow
os.environ["NET_HOST_RC"] = "22"
first = uiflow.resolve_release()["state"]
del os.environ["NET_HOST_RC"]
os.environ["NET_CURL_BODY"] = os.environ["MANIFEST"]
second = uiflow.resolve_release()["state"]
third = uiflow.resolve_release()
print(json.dumps([first, second, third["state"], third["bundle"]]))
PY
)"
printf '%s' "$twice" | grep -q '\["no-release", "ok", "ok"' \
  && ok "a resolution that failed is asked again the next time" \
  || bad "the failure stuck: $twice"

# =================================================================================================
# the VIEW's layout -- the half nothing could see until 2026-08-25
# =================================================================================================
# THE CONSENT SCREEN OVERLAPPED ITS OWN BUTTON ROW on an AYANEO Pocket ACE. Everything except the
# buttons flows down the screen and the buttons are pinned to the bottom, so content that grew ran
# straight through them -- text over the one row that says which button does what, on the screen
# where that matters most. The pre-flight screen hit the same wall in August and was fixed by
# compacting ITS content, which fixed one screen and left the mechanism in place.
#
# installer/fakepygame.py is what lets this be asserted at all: uiview imports pygame lazily, so a
# stand-in with deterministic metrics can be injected and every blit recorded. It proves the
# ARITHMETIC, not the pixels -- that the flow is measured against the button row and shrunk until it
# clears it. The real metrics still come from a real SDL on the device.
CONSENT='desc = {"screen": "consent", "title": "Erase Android data on AYANEO Pocket ACE?",
  "blocks": [("This device is running Android",
              "RetroForge will be installed alongside it. Android keeps the space you chose and "
              "everything else on that partition is erased, including apps, saves and photos. "
              "This cannot be undone and there is no backup."),
             ("What happens next",
              "The disk is repartitioned, RetroForge is downloaded and written, and the device "
              "reboots into it. Android still boots afterwards, factory-reset.")],
  "diamonds": [{"pos": p, "name": n, "done": False} for p, n in
               (("S","BOTTOM"),("W","LEFT"),("N","TOP"),("E","RIGHT"))],
  "prompt": "Press these four buttons in this order",
  "note": "It is the POSITION on the pad, not the letter printed on the button.",
  "buttons": [{"pos": "SELECT", "label": "Cancel"}], "abort": ""}'

layout() {  # <w> <h> <python building `desc`>  -> "<lowest flow pixel> <button row y>"
  SCR_W="$1" SCR_H="$2" DESC="$3" python3 "$ROOT/installer/layout-probe.py"
}

CASE="the view reserves the button row"
read -r bottom row < <(layout 1920 1080 "$CONSENT")
[ "${bottom:-0}" -le "${row:-0}" ] && [ -n "$bottom" ] \
  && ok "1920x1080: the content ends at $bottom, above the button row at $row" \
  || bad "the consent screen overlaps its buttons ($bottom vs $row)"
read -r bottom row < <(layout 1080 1920 "$CONSENT")
[ "${bottom:-0}" -le "${row:-0}" ] && [ -n "$bottom" ] \
  && ok "1080x1920 (portrait): clears it too" \
  || bad "portrait overlaps ($bottom vs $row)"
read -r bottom row < <(layout 1280 720 "$CONSENT")
[ "${bottom:-0}" -le "${row:-0}" ] && [ -n "$bottom" ] \
  && ok "1280x720: clears it on a short panel, which is where it breaks first" \
  || bad "720p overlaps ($bottom vs $row)"

CASE="the shrink is what prevents the overlap, not luck"
# MEASURED BOTH WAYS while writing this: with the shrink, this content ends at 534 on a 720p panel
# whose button row is at 601; with the loop disabled it ends at 607, six pixels into the row. A test
# whose fixture fits anyway would prove nothing, so this one is deliberately larger than any real
# screen -- two long blocks plus the diamonds -- and it is the case that fails if the loop goes.
BIG='desc = {"title":"Erase Android data?",
  "blocks":[("Heading one","word "*160),("Heading two","word "*160)],
  "diamonds":[{"pos":p,"name":n,"done":False} for p,n in
              (("S","BOTTOM"),("W","LEFT"),("N","TOP"),("E","RIGHT"))],
  "prompt":"Press these four buttons in this order",
  "note":"It is the POSITION on the pad.",
  "buttons":[{"pos":"SELECT","label":"Cancel"}]}'
read -r bottom row < <(layout 1280 720 "$BIG")
[ "${bottom:-0}" -le "${row:-0}" ] && [ -n "$bottom" ] \
  && ok "content larger than any real screen still clears the row ($bottom <= $row)" \
  || bad "the shrink did not engage: $bottom vs $row"

CASE="the shrink stops at the LARGEST size that fits, not the first one under the limit"
# It stepped down 8% a time and kept the first size that cleared the row, so it undershot by up to a
# whole step: the type came out smaller than it needed to be and left a gap above the buttons.
# Reported on an AYANEO Pocket ACE (1620x1080) 2026-08-25. "yes" means base+1 really does overflow,
# so the size on the panel is maximal rather than merely safe. The ACE's own geometry is one of the
# cases -- a 3:2 panel, which is where the margin arithmetic is least forgiving.
for geom in 1620x1080 1280x720 1920x1080; do
  gw="${geom%x*}"; gh="${geom#*x}"
  [ "$(MAXIMAL=1 layout "$gw" "$gh" "$BIG")" = yes ] \
    && ok "$geom: the chosen type size is the largest that clears the row" \
    || bad "$geom: a larger type size would still have fitted -- the shrink overshot"
done

CASE="the view shrinks rather than eliding"
# NOTHING MAY BE DROPPED from a consent screen -- "and 4 more" is not a thing it may say. So the fix
# is a smaller type scale, and the proof is that every block still reaches the surface.
n_big=$(COUNT=1 layout 1920 1080 "$CONSENT")
n_small=$(COUNT=1 layout 1280 720 "$CONSENT")
[ "${n_small:-0}" -ge "${n_big:-0}" ] && [ "${n_small:-0}" -gt 20 ] \
  && ok "a short panel still draws everything ($n_small pieces vs $n_big on a tall one)" \
  || bad "content went missing rather than shrinking ($n_small vs $n_big)"

# =================================================================================================
# progress
# =================================================================================================
progress() {  # <python snippet with `p` (a ProgressScreen) and `feed(lines)`>
  SNIPPET="$1" python3 - <<'PY'
import json, os, sys
sys.path.insert(0, os.path.join(os.environ["ROOT"], "installer"))
import uiflow
class FakeRun:
    tail = ["mkfs.ext4: No such file or directory", "retroforge-install: ERROR: the carve failed"]
p = uiflow.ProgressScreen(FakeRun())
def feed(*lines):
    for l in lines: p.feed(l)
exec(os.environ["SNIPPET"])
PY
}

CASE="progress: the phases are the spine's own step markers"
out="$(progress '
feed("[retroforge-install] == recon ==", "[retroforge-install] == carve ==")
print(json.dumps(p.describe()))')"
printf '%s' "$out" | python3 -c '
import json,sys
rows = json.load(sys.stdin)["rows"]
active = [r for r in rows if r["state"] == "active"]
sys.exit(0 if len(active) == 1 and active[0]["label"] == "Repartitioning" else 1)' \
  && ok "the step the spine last printed is the one shown as running" \
  || bad "the active phase does not follow the spine: $out"
out="$(progress '
feed("[retroforge-install] == root slot ==", "  42% Copying image to rootfs.0")
print(json.dumps(p.describe()))')"
printf '%s' "$out" | grep -q '42' \
  && ok "and rauc's own percentage is read off the same pipe -- no second bus client in the installer" \
  || bad "the rauc percentage was not picked up: $out"
out="$(progress '
feed("[retroforge-install] == recon ==", "  42% something")
print(json.dumps(p.describe()))')"
printf '%s' "$out" | python3 -c '
import json,sys
rows = json.load(sys.stdin)["rows"]
sys.exit(0 if all(r["percent"] is None for r in rows if r["state"] != "active") else 1)' \
  && ok "a percentage belongs to the phase that is running, and to no other" \
  || bad "a stale percentage leaked onto another phase"
# uiview draws `blocks` and THEN `rows`, so a phase named in both is painted twice on the panel.
# It was: describe() built one plain-text block per reached phase as well as the row, and every
# phase the spine reached appeared twice. Observed on an AYANEO Pocket ACE, 2026-08-25.
out="$(progress '
feed("[retroforge-install] == recon ==", "[retroforge-install] == select-target ==",
     "[retroforge-install] == install record ==")
print(json.dumps(p.describe()))')"
printf '%s' "$out" | python3 -c '
import json,sys
d = json.load(sys.stdin)
labels = {r["label"] for r in d["rows"]}
text = " ".join(h + " " + b for h, b in d["blocks"])
sys.exit(0 if not [l for l in labels if l in text] else 1)' \
  && ok "a phase is named once -- the rows are the renderer, blocks does not shadow them" \
  || bad "a phase label appears in blocks AND rows, so the panel draws it twice: $out"

CASE="progress: a failure says WHICH of two states the device is in"
# The one thing a failure owes the user. "It failed" is not actionable; "nothing was written" and
# "Android's data is already gone" are different situations and only one needs anything done.
out="$(progress '
feed("[retroforge-install] == verify sources ==")
p.finish(1); print(json.dumps(p.describe()))')"
printf '%s' "$out" | grep -qi 'Nothing was written' \
  && ok "a failure before the carve says the device is exactly as it was" \
  || bad "it does not tell the user the disk is untouched: $out"
printf '%s' "$out" | grep -qi 'was modified' \
  && bad "it claims the disk was modified when the carve never ran" \
  || ok "and it does not claim otherwise"
out="$(progress '
feed("[retroforge-install] == carve ==", "[retroforge-install] == filesystems ==")
p.finish(1); print(json.dumps(p.describe()))')"
printf '%s' "$out" | grep -qi 'disk WAS modified' \
  && ok "a failure after the carve says so, and that Android's data is already gone" \
  || bad "a failure past the carve still claims nothing was written: $out"
printf '%s' "$out" | grep -q 'the carve failed' \
  && ok "and it shows the tail of what the spine actually said" \
  || bad "the error text is not on the screen"
CASE="progress: a successful install is not a VERIFIED install (#66)"
# verify-install.sh shipped on every medium and NOTHING could invoke it -- a release medium has no
# shell, and the first end-to-end install (Pocket ACE, 2026-08-25) mentioned it zero times in the
# whole ESP log. The UI runs it now, and the done screen must not tell anyone to pull the card
# before it has spoken: that window is the only one the check gets.
out="$(progress 'p.finish(0); p.begin_verify(); print(json.dumps(p.describe()))')"
printf '%s' "$out" | grep -qi 'Remove the SD card' \
  && bad "it says to remove the card while the check is still running: $out" \
  || ok "while the check runs it does NOT tell the operator to pull the card"
printf '%s' "$out" | grep -qi 'leave the SD card in' \
  && ok "and says to leave it in, which is what the check needs" \
  || bad "it does not say to leave the card in: $out"
printf '%s' "$out" | grep -q 'Power off' \
  && ok "Power off stays offered throughout -- a check that hangs must not trap anyone" \
  || bad "a running check leaves the operator with no button at all: $out"

out="$(progress '
p.finish(0); p.begin_verify()
p.feed_verify("    !!  retroforge-root-A is empty")
p.finish_verify(1); print(json.dumps(p.describe()))')"
printf '%s' "$out" | grep -q 'retroforge-root-A is empty' \
  && ok "a failed check puts the !! line on screen, not just a verdict" \
  || bad "the failing check is not named: $out"
# NOT a bare grep for "Remove the SD card": the correct screen says "Do NOT remove the SD card",
# which contains it. The first version of this case asserted the negation and passed on the bug.
printf '%s' "$out" | grep -qi 'do not remove the SD card' \
  && ok "and it tells them to LEAVE the card in, not to remove it" \
  || bad "a failed check does not warn against removing the card: $out"
printf '%s' "$out" | python3 -c '
import json,sys
d = json.load(sys.stdin)
sys.exit(0 if [b for b in d["buttons"] if b["label"] == "Try again"] else 1)' \
  && ok "a rejected install offers Try again -- the documented recovery" \
  || bad "a rejected install offers no way to re-run it: $out"
# A press on that screen must RETRY, not power off. rc==0 used to mean "any press = poweroff".
out="$(progress '
p.finish(0); p.begin_verify()
p.feed_verify("    !!  something")
p.finish_verify(1); p.handle("S"); print(p.result[0])')"
[ "$out" = retry ] \
  && ok "and pressing it retries rather than powering off" \
  || bad "the press did not route to retry: $out"

# rc 1 is BOTH "a check failed" and "it could not run" -- die() also exits 1 -- so the !! lines are
# what tells them apart. A verifier that refused must not be reported as a failed install.
out="$(progress 'p.finish(0); p.begin_verify(); p.finish_verify(1); print(json.dumps(p.describe()))')"
printf '%s' "$out" | grep -qi 'could not run' \
  && ok "a check that REFUSED to run says so, instead of claiming the install failed" \
  || bad "an unrunnable check is reported as a failed one: $out"
printf '%s' "$out" | grep -qi 'did not pass' \
  && bad "it claims the check failed when the check never ran: $out" \
  || ok "and it does not claim the install was rejected"

out="$(progress 'p.finish(0); p.begin_verify(); p.finish_verify(0); print(json.dumps(p.describe()))')"
printf '%s' "$out" | grep -qi 'Power off, remove the SD card' \
  && ok "success tells the user to power off and take the card out" \
  || bad "the success screen does not say to remove the card: $out"
printf '%s' "$out" | grep -qi 'can stay in' \
  && bad "it still says the card can stay in: $out" \
  || ok "and no longer says the card can stay in"
printf '%s' "$out" | grep -qi 'does not prove the device boots' \
  && ok "and the check does not overclaim -- it never says the device will boot" \
  || bad "the verified screen overstates what was checked: $out"
printf '%s' "$out" | grep -qiE '\bpress [ABXY]\b' \
  && bad "the result screen names a face-button letter" \
  || ok "and it still names no face-button letter"

# =================================================================================================
# the session — gamescope on the panel, with the UI as its only client
# =================================================================================================
SESSION="$ROOT/installer/installer-session"
SAVELOG="$ROOT/installer/save-log.sh"
[ -x "$SESSION" ] && [ -x "$SAVELOG" ] || { echo "session scripts missing" >&2; exit 1; }

cat >"$T/bin/device-env-panel" <<'EOF'
#!/usr/bin/env bash
printf "RETROFORGE_DEVICE_NAME='AYANEO Pocket ACE'\n"
printf 'RETROFORGE_PRIMARY_CONNECTOR=DSI-1\n'
printf 'RETROFORGE_PANEL_NATIVE_WIDTH=1080\n'
printf 'RETROFORGE_PANEL_NATIVE_HEIGHT=1620\n'
printf 'RETROFORGE_PANEL_REFRESH_RATES=60,120\n'
EOF
printf '#!/bin/sh\nexit 1\n' >"$T/bin/no-seatd"        # "no seatd is running"
chmod +x "$T/bin"/*

session() {  # env overrides passed through
  RETROFORGE_INSTALLER_DRYRUN=1 RETROFORGE_XDG_RUNTIME_DIR="$T/xdg" RETROFORGE_UI="$UI" RETROFORGE_SEATD_PGREP="$T/bin/no-seatd" \
    RETROFORGE_DEVICE_ENV="${DEVENV-$T/bin/device-env-panel}" \
    RETROFORGE_SEATD_SOCK="${SOCKARG-$T/seatd.sock}" "$SESSION" 2>"$T/session.err"
}

CASE="session: the command line is the one bring-up validated on hardware"
cmd="$(session)"
printf '%s' "$cmd" | grep -q 'seatd-launch -- ' \
  && ok "gamescope runs under seatd-launch -- root, no logind session, which is the installer's case" \
  || bad "the seat launcher is missing: $cmd"
printf '%s' "$cmd" | grep -q -- '--backend drm' \
  && ok "the DRM backend, not a nested one" \
  || bad "no --backend drm: $cmd"
printf '%s' "$cmd" | grep -q -- '-W 1620 -H 1080' \
  && ok "the portrait panel is swapped to a landscape logical canvas (1080x1620 -> 1620x1080)" \
  || bad "the logical output was not swapped: $cmd"
# gamescope keeps -r as a refresh that overrides the scanning mode's in its limiter and vblank
# pacing, so -r <first declared rate> paced a 120 Hz preferred mode at 60 (HW, Odin 3, 2026-10-23).
printf '%s' "$cmd" | grep -qE -- '(^| )-r ' \
  && bad "it passes -r, which pins gamescope's pacing to that rate whatever the panel scans: $cmd" \
  || ok "and no -r: gamescope boots the preferred mode and paces against the real one"
printf '%s' "$cmd" | grep -q -- '--prefer-output DSI-1' \
  && ok "pinned to the board's own connector" \
  || bad "the connector is not pinned: $cmd"
printf '%s' "$cmd" | grep -q -- "-- $UI" \
  && ok "and the UI is gamescope's own child, so either half dying is one failure the unit sees" \
  || bad "the UI is not gamescope's child: $cmd"
# The ROCKNIX-era flag. Our gamescope carries upstream PR #2228 composite rotation and auto-engages
# it off the connector's panel orientation, so passing it would be passing a flag that no longer
# exists -- and the plan still mentions it, which is exactly how that would happen.
printf '%s' "$cmd" | grep -q -- '--use-rotation-shader' \
  && bad "it passes --use-rotation-shader, which our patched gamescope no longer has" \
  || ok "no --use-rotation-shader -- rotation is auto-engaged from the connector"

CASE="session: an unknown board still gets a screen"
printf '#!/bin/sh\nexit 0\n' >"$T/bin/device-env-empty"; chmod +x "$T/bin/device-env-empty"
cmd="$(DEVENV="$T/bin/device-env-empty" session)"
printf '%s' "$cmd" | grep -q -- '-W 1920 -H 1080' \
  && ok "a board device-env does not know falls back to generic landscape" \
  || bad "an unknown board produced: $cmd"
printf '%s' "$cmd" | grep -q -- '--prefer-output' \
  && bad "it pinned a connector it was never told about" \
  || ok "and pins no connector, rather than inventing one"

CASE="session: it clears the socket seatd-launch leaks"
# docs/archive/bringup-phase2.md: seatd-launch leaks /run/seatd.sock on an unclean exit and the next start
# dies "Socket file found ... refusing to start". An installer is a tool people re-run after a
# crash, so this would bite on exactly the second attempt.
: >"$T/seatd.sock"
session >/dev/null
[ ! -e "$T/seatd.sock" ] \
  && ok "a stale socket left by an earlier run is removed" \
  || bad "the stale socket survived; the next start would refuse"
grep -qi 'stale' "$T/session.err" \
  && ok "and it says so, rather than deleting a socket silently" \
  || bad "the removal is not logged"
# But only when nothing is listening: removing a LIVE seatd's socket breaks a running session.
: >"$T/seatd.sock"
printf '#!/bin/sh\nexit 0\n' >"$T/bin/yes-seatd"; chmod +x "$T/bin/yes-seatd"
RETROFORGE_INSTALLER_DRYRUN=1 RETROFORGE_XDG_RUNTIME_DIR="$T/xdg" RETROFORGE_UI="$UI" RETROFORGE_SEATD_PGREP="$T/bin/yes-seatd" \
  RETROFORGE_DEVICE_ENV="$T/bin/device-env-panel" RETROFORGE_SEATD_SOCK="$T/seatd.sock" \
  "$SESSION" >/dev/null 2>&1
[ -e "$T/seatd.sock" ] \
  && ok "a socket with a live seatd behind it is left alone" \
  || bad "it removed a live seatd's socket"

CASE="every token a screen handles must be one the pad can produce"
# HW-FOUND 2026-08-24 (user): "left/right to change the android userdata size doesn't work".
# PreflightScreen has handled LEFT and RIGHT since it was written -- they are how the operator
# decides how much of the disk Android keeps -- and NOTHING COULD EVER PRODUCE THEM. uipad
# translated the four face buttons and BACK and stopped there, so those branches were unreachable
# code and the only symptom was a number that would not move.
#
# The specific fix is the d-pad mapping. The general check is this case: a screen that handles a
# token no input emits is a control that does not exist, and nothing else would notice.
produced="$(cd "$ROOT/installer" && python3 -c '
import uipad
toks = set(uipad.BUTTON_TO_CARDINAL.values()) | set(uipad.KEY_TO_CARDINAL.values())
toks |= set(uipad.BUTTON_TO_NAV.values()) | set(uipad.KEY_TO_NAV.values())
toks |= {uipad.TOKEN_BACK, uipad.TOKEN_QUIT}
print(" ".join(sorted(toks)))' 2>&1)"
printf '%s' "$produced" | grep -q LEFT && printf '%s' "$produced" | grep -q RIGHT \
  && ok "the pad can produce LEFT and RIGHT ($produced)" \
  || bad "LEFT/RIGHT are still unreachable: $produced"
# Both input paths, because §4d names a USB keyboard as the fallback when no pad enumerates.
grep -q 'BUTTON_TO_NAV = {13: TOKEN_LEFT, 14: TOKEN_RIGHT}' "$ROOT/installer/uipad.py" \
  && ok "from the d-pad (SDL CONTROLLER_BUTTON_DPAD_LEFT/RIGHT)" \
  || bad "the d-pad is not mapped"
grep -q 'KEY_TO_NAV' "$ROOT/installer/uipad.py" \
  && ok "and from the arrow keys" || bad "no keyboard equivalent"
grep -q 'elif ev.button in BUTTON_TO_NAV' "$ROOT/installer/uipad.py" \
  && ok "poll() actually consults the map" \
  || bad "the map exists but no event path reads it"
# The invariant itself: every literal token the screens compare against must be producible.
handled="$(grep -ohE 'token == "[A-Z]+"' "$ROOT/installer/ui" "$ROOT/installer/uiflow.py" \
          | grep -oE '"[A-Z]+"' | tr -d '"' | sort -u)"
unreachable=""
for t in $handled; do
  printf '%s' "$produced" | grep -qw "$t" || unreachable="$unreachable $t"
done
[ -z "$unreachable" ] \
  && ok "every token the screens handle is producible ($(printf '%s' "$handled" | wc -w) checked)" \
  || bad "screens handle tokens no input can emit:$unreachable"

CASE="no target: the screen says WHY, it does not just wait"
# HW-FOUND 2026-08-24 (user): the medium shipped without lib-gpt.sh, select-target.sh died with
# "cannot find lib-gpt.sh", gather_preflight() read that non-zero exit as the NORMAL no-target
# outcome, and the panel sat on "Waiting for the installer." with no other word. A person holding
# the device could not tell a broken build from a disk the installer refuses to touch. The reason
# was already being logged and then thrown away by returning a bare None.
noreason="$(cd "$ROOT/installer" && python3 -c '
import importlib.util, os, sys
from importlib.machinery import SourceFileLoader
sys.path.insert(0, os.path.abspath("."))
loader = SourceFileLoader("nvui", "ui"); spec = importlib.util.spec_from_loader("nvui", loader)
ui = importlib.util.module_from_spec(spec); loader.exec_module(ui)
d = ui.IdleScreen("select-target: cannot find lib-gpt.sh").describe()
print(d["title"])
for h, b in d["blocks"]:
    print("%s|%s" % (h, b))
print("NOTE|%s" % d["note"])
' 2>&1)"
printf '%s' "$noreason" | grep -qi 'cannot find lib-gpt.sh' \
  && ok "the reason from the tool is on the screen, verbatim" \
  || bad "the reason is not shown: $noreason"
printf '%s' "$noreason" | grep -qiE 'no disk to install onto|nothing .* install' \
  && ok "it states plainly that there is no target" \
  || bad "the screen does not say what the situation is"
printf '%s' "$noreason" | grep -qi 'nothing has been written' \
  && ok "it says nothing has been written (the operator's first question)" \
  || bad "it does not reassure that the disk is untouched"
# THE ADVICE MUST NOT INVENT A CAUSE. It used to end with "a device already running from its
# internal disk is refused on purpose" whatever the real reason was, so on a Pocket FIT refused for
# carrying ROCKNIX it explained a cause that had nothing to do with that disk, in the confident
# voice of the real one (HW 2026-08-24).
foreign="$(cd "$ROOT/installer" && python3 -c '
import importlib.util, os, sys
from importlib.machinery import SourceFileLoader
sys.path.insert(0, os.path.abspath("."))
l = SourceFileLoader("nvui", "ui"); s = importlib.util.spec_from_loader("nvui", l)
ui = importlib.util.module_from_spec(s); l.exec_module(ui)
d = ui.IdleScreen("/dev/sda: partition 12 (ROCKNIX) is a bootable ESP that is not ours -- remove the other OS first").describe()
print(d["blocks"][-1][1])' 2>&1)"
printf '%s' "$foreign" | grep -qi 'another operating system' \
  && ok "a foreign install is named as such" \
  || bad "rule 3b does not tell the operator there is another OS: $foreign"
printf '%s' "$foreign" | grep -qi 'remove that installation first' \
  && ok "and says it must be removed before RetroForge can install" \
  || bad "it does not say what to do about it"
printf '%s' "$foreign" | grep -qi 'running from its internal disk is refused' \
  && bad "it still asserts the running-disk cause on a foreign-OS refusal" \
  || ok "it does not assert a cause that is not this one"
# An unrecognised reason must fall back honestly rather than guess.
other="$(cd "$ROOT/installer" && python3 -c '
import importlib.util, os, sys
from importlib.machinery import SourceFileLoader
sys.path.insert(0, os.path.abspath("."))
l = SourceFileLoader("nvui", "ui"); s = importlib.util.spec_from_loader("nvui", l)
ui = importlib.util.module_from_spec(s); l.exec_module(ui)
print(ui.IdleScreen("something nobody anticipated").describe()["blocks"][-1][1])' 2>&1)"
printf '%s' "$other" | grep -qi 'worth reporting' \
  && ok "an unrecognised reason falls back to 'report it', not to a guess" \
  || bad "an unknown refusal still gets a confident explanation: $other"
# And the reason itself must survive select-target's summary line.
sel="$(cd "$ROOT/installer" && python3 -c '
import uiflow, unittest.mock as m
out = "scanning\n  /dev/sda: partition 12 (ROCKNIX) is a bootable ESP that is not ours -- remove the other OS first\nno disk qualifies -- see the reasons above"
with m.patch.object(uiflow, "run_tool", lambda *a, **k: (1, out)):
    print(uiflow.gather_preflight()[1])' 2>&1 | tail -1)"
printf '%s' "$sel" | grep -qi 'ROCKNIX' \
  && ok "the per-disk reason survives, not just the summary" \
  || bad "gather_preflight kept the summary and dropped the reason: $sel"
printf '%s' "$sel" | grep -qi 'see the reasons above' \
  && bad "the screen would tell the operator to look above it, on a panel with no above" \
  || ok "the useless summary line is not what reaches the screen"
# No SSH note: a release medium enables no sshd, so it was false there as well as unhelpful.
printf '%s' "$noreason" | grep -qi 'ssh' \
  && bad "the panel still mentions SSH, which a release medium does not have" \
  || ok "no developer context on the panel"
# With no reason available the screen must still be useful rather than blank.
blank="$(cd "$ROOT/installer" && python3 -c '
import importlib.util, os, sys
from importlib.machinery import SourceFileLoader
sys.path.insert(0, os.path.abspath("."))
loader = SourceFileLoader("nvui", "ui"); spec = importlib.util.spec_from_loader("nvui", loader)
ui = importlib.util.module_from_spec(spec); loader.exec_module(ui)
print(len(ui.IdleScreen().describe()["blocks"]))' 2>&1)"
[ "$blank" -ge 2 ] 2>/dev/null \
  && ok "it still renders $blank blocks when no reason was captured" \
  || bad "with no reason the screen degrades to nothing useful: $blank"
# It asks for nothing, so a scripted source must not spend a press on it.
noninter="$(cd "$ROOT/installer" && python3 -c '
import importlib.util, os, sys
from importlib.machinery import SourceFileLoader
sys.path.insert(0, os.path.abspath("."))
loader = SourceFileLoader("nvui", "ui"); spec = importlib.util.spec_from_loader("nvui", loader)
ui = importlib.util.module_from_spec(spec); loader.exec_module(ui)
print(ui.IdleScreen().interactive)' 2>&1)"
[ "$noninter" = "False" ] && ok "still non-interactive (a screen that asks nothing takes no press)" \
  || bad "IdleScreen became interactive: $noninter"

CASE="session: XDG_RUNTIME_DIR is provided, because nothing else does"
# THE FIRST HARDWARE BOOT OF THE INSTALLER MEDIUM DIED HERE (Pocket S2, 2026-08-24). gamescope came
# all the way up -- seatd, DRM master, Turnip on an Adreno 750, DSI-1 at 1440x2560 -- then logged
# "XDG_RUNTIME_DIR is invalid or not set" 128 times, failed to open its wayland socket, and ABORTED
# with a core dump. libwayland will not create a socket without that variable, and it is LOGIND that
# normally makes /run/user/<uid> and exports it -- this session has no logind session by design.
#
# It passed by hand on the panel in August because that run came from an interactive root SSH login,
# where logind had already done both. Nothing in the command line differed. So this case checks the
# ENVIRONMENT, not the command: a dry run must still leave the directory there, 0700, because that
# is the side effect gamescope depends on.
rm -rf "$T/xdg2"
RETROFORGE_INSTALLER_DRYRUN=1 RETROFORGE_XDG_RUNTIME_DIR="$T/xdg2" RETROFORGE_UI="$UI" \
  RETROFORGE_SEATD_PGREP="$T/bin/yes-seatd" RETROFORGE_DEVICE_ENV="$T/bin/device-env-panel" \
  RETROFORGE_SEATD_SOCK="$T/seatd.sock" "$SESSION" >/dev/null 2>&1
[ -d "$T/xdg2" ] \
  && ok "the runtime directory is created" \
  || bad "no XDG_RUNTIME_DIR is created -- gamescope aborts on its wayland socket"
[ "$(stat -c%a "$T/xdg2" 2>/dev/null)" = 700 ] \
  && ok "it is 0700 (the wayland socket lives in it)" \
  || bad "the runtime directory is $(stat -c%a "$T/xdg2" 2>/dev/null), not 0700"
grep -q 'export XDG_RUNTIME_DIR=' "$SESSION" \
  && ok "and it is EXPORTED, so gamescope and the UI both inherit it" \
  || bad "the variable is set but never exported"
# /run/user/0 is logind's namespace; fabricating it would collide the day anything here starts a
# real session.
# Non-comment lines only: the script EXPLAINS at length why it avoids /run/user/0, and a plain grep
# matched that prose and failed on correct code the first time this case ran.
grep -vE '^[[:space:]]*#' "$SESSION" | grep -q '/run/user/0' \
  && bad "it fabricates /run/user/0, which belongs to logind" \
  || ok "it does not squat on logind's /run/user/0"

CASE="session: a seatd that is already running is used, not duplicated"
# seatd-launch starts its OWN seatd and refuses when the socket exists, and the shipped image
# enables seatd.service (Pocket S2, 2026-08-22: pid 710, /run/seatd.sock root:seat 0770). An
# installer-session that always reached for seatd-launch would die before gamescope started.
: >"$T/seatd.sock"
cmd="$(RETROFORGE_INSTALLER_DRYRUN=1 RETROFORGE_XDG_RUNTIME_DIR="$T/xdg" RETROFORGE_UI="$UI" RETROFORGE_SEATD_PGREP="$T/bin/yes-seatd" \
  RETROFORGE_DEVICE_ENV="$T/bin/device-env-panel" RETROFORGE_SEATD_SOCK="$T/seatd.sock" \
  "$SESSION" 2>"$T/session.err")"
grep -qi 'using the seatd already running' "$T/session.err" \
  && ok "it takes the seat from the running daemon instead of launching a second" \
  || bad "it did not notice a live seatd: $(cat "$T/session.err")"
rm -f "$T/seatd.sock"
cmd="$(session)"
printf '%s' "$cmd" | grep -q 'seatd-launch -- ' \
  && ok "and with no seat daemon there, it launches one -- the bring-up path" \
  || bad "it stopped using seatd-launch when nothing was running: $cmd"

CASE="session: it refuses rather than drawing nothing"
RETROFORGE_INSTALLER_DRYRUN=1 RETROFORGE_UI="$T/not-here" RETROFORGE_DEVICE_ENV="$T/bin/device-env-panel" \
  "$SESSION" >/dev/null 2>&1 \
  && bad "it started a session with no UI to run" \
  || ok "a missing UI is a loud failure at second zero, not a black panel"

# =============================================================================================
# the log — what is left to read after a run
# =============================================================================================
cat >"$T/bin/journalctl" <<'EOF'
#!/usr/bin/env bash
# Echoes back which query it was asked, so the suite can assert the log collects more than the
# installer's own unit.
printf 'Aug 22 12:00:00 player installer-session[1]: gamescope: could not open /dev/dri/card0\n'
printf 'journalctl-args: %s\n' "$*"
EOF
chmod +x "$T/bin"/*
mkdir -p "$T/run/install" "$T/varlog"
printf 'consent: given at 2026-08-22T10:00:00Z, sequence SWNE, attempt 1\n' >"$T/run/install/record"
printf 'RETROFORGE_BUILD=20260825T090000Z\nRETROFORGE_VERSION=1.2.3\nRETROFORGE_GIT=abc1234\nRETROFORGE_MODE=release\n' >"$T/run/retroforge-release"

LOGOUT="$T/varlog/retroforge/install.log"
savelog() {
  PATH="$T/bin:$PATH" RETROFORGE_INSTALL_LOG="$LOGOUT" RETROFORGE_INSTALL_RECORD="$T/run/install/record" \
    JOURNALCTL="${JC-$T/bin/journalctl}" RETROFORGE_INSTALL_RELEASE="${RELARG-$T/run/retroforge-release}" \
    "$SAVELOG" "$@" 2>"$T/savelog.err"
}

CASE="log: it lands under /var/log, never in a directory player owns"
grep -q '^LOGFILE=.*:-/var/log/retroforge/install.log' "$SAVELOG" \
  && ok "the default is /var/log/retroforge/install.log" || bad "the log's default path moved"
grep -v '^#' "$SAVELOG" | grep -q '/home/player' \
  && bad "root writes into /home/player, and follows any symlink left there" \
  || ok "nothing in it touches /home/player"
savelog && ok "it exits 0" || bad "save-log.sh failed"
[ -f "$LOGOUT" ] && ok "and creates its directory" || bad "no log at $LOGOUT"
grep -q 'could not open /dev/dri/card0' "$LOGOUT" \
  && ok "the session's journal is in it" || bad "the journal is not in the log"
grep -q 'consent: given' "$LOGOUT" \
  && ok "and the spine's own install record, which the journal does not carry" \
  || bad "the install record is missing from the log"
grep -q '^card: .*RETROFORGE_VERSION=1.2.3' "$LOGOUT" \
  && ok "the header names the build that ran" || bad "the log does not identify the card: $(head -3 "$LOGOUT")"
RELARG="$T/run/absent" savelog
grep -q '^card: no .*absent' "$LOGOUT" \
  && ok "an image carrying no identity says so, rather than printing nothing" \
  || bad "a missing release file is silent: $(head -3 "$LOGOUT")"
savelog

CASE="log: it carries the network's side of the story too"
# The OS is streamed, so a drop mid-stream is what this log is most likely to be read for.
grep -q 'journalctl-args:.*-u retroforge-installer.service' "$LOGOUT" \
  && ok "the installer's own unit is collected" || bad "the installer's journal is missing"
grep -q 'journalctl-args:.*-u NetworkManager.service' "$LOGOUT" \
  && ok "and NetworkManager's, which owns the association and the lease" \
  || bad "no network journal is collected"
grep -q 'journalctl-args:.*-k' "$LOGOUT" \
  && ok "and the kernel ring" || bad "the kernel ring is missing"

CASE="log: a log that cannot be saved never fails the unit"
JC="$T/bin/nonexistent-journalctl" savelog \
  && ok "no journalctl on the image is a line in the log, not an error" \
  || bad "a missing journalctl failed the unit"
grep -q 'no journalctl' "$LOGOUT" && ok "and it says which part is missing" || bad "the log does not record why it is empty"
LOGOUT="/proc/nonexistent/install.log" savelog && ok "an unwritable path exits 0 too" || bad "an unwritable log failed the unit"

printf '\ntest-ui.sh: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
