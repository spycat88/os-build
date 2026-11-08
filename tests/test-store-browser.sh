#!/usr/bin/env bash
# Offline test for the store sign-in's Chromium (.claude/plans/store-signin-window.plan.md, D1):
# rootfs/chromium-pin.py, which writes chromium.pin from the snapshot, and `store browser status|setup`
# (/usr/lib/retroforge/store, python/chromium_setup.py), which installs from it without pacman.
#
#   tests/test-store-browser.sh
#
# Fake repo databases and .pkg.tar.zst packages, served for every https:// request (RETROFORGE_STORE_API).
# Rules: the pin is Chromium's dependency closure minus the lock's snapshot and retroforge rows (and
# what they provide), stripped rows not counted as present, an unresolvable dependency fails; the
# committed pin's snapshot is the lock's. Set-up tries a reset connection again, refuses a package whose sha256 is not the pin's, one
# that would write outside its folder, and too little free space, each leaving nothing set up; it
# unpacks only Chromium's folder, top-level libraries and compiled schemas, into the player's home
# (0700); a second set-up downloads nothing; a new pin gets its own folder, the old one goes at the set-up
# after (a Chromium may run from it); a killed set-up's leftovers go before the free-space check; a bad pin
# fails with the helper's `store:` line; a first `sign-in` sets Chromium up, reporting it, then runs it on its
# own libraries.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
STORE="$ROOT/rootfs/overlay/usr/lib/retroforge/store"
GEN="$ROOT/rootfs/chromium-pin.py"
for f in "$STORE" "$GEN"; do [ -f "$f" ] || { echo "missing: $f" >&2; exit 1; }; done
command -v glib-compile-schemas >/dev/null || { echo "test-store-browser: needs glib-compile-schemas" >&2; exit 1; }
# The packages are .pkg.tar.zst, which tarfile reads only with compression.zstd (Python 3.14+, the image's).
# CI runs 3.14 (.github/workflows/ci.yml); an older python3 on a dev machine skips rather than fails.
python3 -c 'import compression.zstd' 2>/dev/null || {
  echo "test-store-browser: skipped -- $(python3 -V 2>&1) has no compression.zstd (needs 3.14+)"; exit 0; }
T="$(mktemp -d)" && [ -d "$T" ] || { echo "mktemp -d failed" >&2; exit 1; }
trap 'rm -rf "$T"' EXIT

python3 - "$STORE" "$GEN" "$T" "$ROOT" <<'PY'
import hashlib, http.server, io, json, os, socket, stat, struct, subprocess, sys, tarfile, threading

STORE, GEN, T, ROOT = sys.argv[1:5]
PASS = FAIL = 0
CASE = ""


def ok(cond, what, detail=""):
    global PASS, FAIL
    if cond:
        PASS += 1
        print(f"  ok   {CASE} -- {what}")
    else:
        FAIL += 1
        print(f"  FAIL {CASE} -- {what}" + (f": {detail}" if detail else ""))


def tar_bytes(mode, entries):
    """entries: (name, bytes | ("link", target) | ("hard", target), mode)."""
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode=mode) as t:
        for name, body, perm in entries:
            info = tarfile.TarInfo(name)
            info.mode = perm
            if isinstance(body, tuple):
                info.type = tarfile.SYMTYPE if body[0] == "link" else tarfile.LNKTYPE
                info.linkname = body[1]
                t.addfile(info)
            else:
                info.size = len(body)
                t.addfile(info, io.BytesIO(body))
    return buf.getvalue()


# ---- the pin generator ---------------------------------------------------------------------------
CASE = "pin"


def desc(name, depends=(), provides=()):
    lines = [f"%NAME%\n{name}\n", f"%FILENAME%\n{name}-1-1-aarch64.pkg.tar.zst\n",
             f"%SHA256SUM%\n{hashlib.sha256(name.encode()).hexdigest()}\n", "%CSIZE%\n1000\n"]
    if depends:
        lines.append("%DEPENDS%\n" + "".join(d + "\n" for d in depends))
    if provides:
        lines.append("%PROVIDES%\n" + "".join(p + "\n" for p in provides))
    return "\n".join(lines).encode()


dbs = os.path.join(T, "db")
os.makedirs(dbs)
CORE = [("glibc", (), ()), ("zlib", (), ("libz.so=1-64",))]
EXTRA = [("chromium", ("glibc", "gtk3>=3.24", "libz.so=1-64", "keyhelper"), ()),
         ("gtk3", ("glibc", "libfoo.so=2-64"), ()), ("foo", (), ("libfoo.so=2-64",)),
         ("keyhelper", ("gnupg",), ()), ("gnupg", (), ()), ("unrelated", (), ())]
for repo, pkgs in (("core", CORE), ("extra", EXTRA)):
    entries = [(f"{n}-1-1/desc", desc(n, d, p), 0o644) for n, d, p in pkgs]
    open(os.path.join(dbs, repo + ".db"), "wb").write(tar_bytes("w:gz", entries))
lock = os.path.join(T, "manifest.lock")
open(lock, "w").write("# repo snapshot: https://snap.example/mash\n# name version arch source sha256\n"
                      "glibc 1-1 aarch64 snapshot aa\nzlib 1-1 aarch64 snapshot bb\ngnupg 1-1 aarch64 stripped cc\n"
                      "mesa 1-1 aarch64 retroforge dd\n")
out = os.path.join(T, "chromium.pin")
r = subprocess.run([sys.executable, GEN, "--lock", lock, "--db-dir", dbs, "--out", out], capture_output=True, text=True)
pin = open(out).read() if os.path.exists(out) else ""
listed = sorted(line.split()[2].split("-1-1-")[0] for line in pin.splitlines() if line.startswith("package:"))
ok(r.returncode == 0 and "snapshot: https://snap.example/mash" in pin, "written, with the lock's snapshot", r.stderr)
ok(listed == ["chromium", "foo", "gnupg", "gtk3", "keyhelper"], "the closure minus the image's packages", str(listed))
ok("package: core" not in pin, "a dependency the image has (also by soname) is not listed", pin)
line = next((l for l in pin.splitlines() if " chromium-1-1-" in l), "")
ok(line.split()[1:] == ["extra", "chromium-1-1-aarch64.pkg.tar.zst", hashlib.sha256(b"chromium").hexdigest(), "1000"],
   "each row: repo, file, the snapshot's sha256, size", line)
open(lock, "a").write("chromium 1-1 aarch64 snapshot ee\n")
r = subprocess.run([sys.executable, GEN, "--lock", lock, "--db-dir", dbs, "--out", out], capture_output=True, text=True)
ok(r.returncode == 0 and "package:" not in open(out).read(), "nothing to fetch once the image has Chromium", r.stderr)
open(lock, "w").write("# repo snapshot: https://snap.example/mash\n")
EXTRA[0] = ("chromium", ("missing-lib",), ())
open(os.path.join(dbs, "extra.db"), "wb").write(
    tar_bytes("w:gz", [(f"{n}-1-1/desc", desc(n, d, p), 0o644) for n, d, p in EXTRA]))
r = subprocess.run([sys.executable, GEN, "--lock", lock, "--db-dir", dbs, "--out", out], capture_output=True, text=True)
ok(r.returncode != 0 and "provides missing-lib" in r.stderr, "an unresolvable dependency fails the relock", r.stderr)

committed = os.path.join(ROOT, "rootfs/overlay/usr/share/retroforge/stores/chromium.pin")
lock_snap = next(l.split(":", 1)[1].strip() for l in open(os.path.join(ROOT, "rootfs/manifest.lock"))
                 if l.startswith("# repo snapshot:"))
pin_snap = next((l.split(":", 1)[1].strip() for l in open(committed) if l.startswith("snapshot:")), None)
ok(pin_snap == lock_snap, "the committed pin follows the lock's snapshot (make relock rewrites both)",
   f"{pin_snap} != {lock_snap}")

# ---- the fake snapshot ---------------------------------------------------------------------------
SCHEMA = (b'<schemalist><schema id="org.retroforge.test" path="/org/retroforge/test/">'
          b'<key name="k" type="b"><default>true</default></key></schema></schemalist>')
PKGS = {
    "chromium": tar_bytes("w:zst", [
        (".PKGINFO", b"pkgname = chromium\n", 0o644),
        ("usr/bin/chromium", b"#!/bin/sh\n", 0o755),
        ("usr/lib/chromium/chromium", b"#!/bin/sh\necho \"fake chromium on $LD_LIBRARY_PATH\"\n", 0o755),
        ("usr/lib/chromium/chrome-sandbox", b"x", 0o4755),
        ("usr/lib/chromium/resources.pak", b"pak", 0o644),
        ("usr/lib/chromium/locales/en-US.pak", b"pak", 0o644),
        ("usr/lib/chromium/chromium-alias", ("hard", "usr/lib/chromium/chromium"), 0o755),
        ("usr/share/doc/chromium/README", b"doc", 0o644)]),
    "gtk3": tar_bytes("w:zst", [
        ("usr/lib/libgtk-3.so.0.2400.1", b"elf", 0o755),
        ("usr/lib/libgtk-3.so.0", ("link", "libgtk-3.so.0.2400.1"), 0o777),
        ("usr/lib/gtk-3.0/3.0.0/immodules/im-x.so", b"elf", 0o755),
        ("usr/lib/pkgconfig/gtk+-3.0.pc", b"pc", 0o644),
        ("usr/share/glib-2.0/schemas/org.retroforge.test.gschema.xml", SCHEMA, 0o644)]),
    "evil": tar_bytes("w:zst", [("usr/lib/libevil.so", ("link", "/etc/passwd"), 0o777)]),
    "escape": tar_bytes("w:zst", [("usr/lib/chromium/../../../../../escaped", b"x", 0o644)]),
}
ROUTES = {f"/snap.example/mash/extra/os/aarch64/{n}-1-1-aarch64.pkg.tar.zst": b for n, b in PKGS.items()}
SEEN = []
RESETS = {}  # path -> connections still to reset (a CDN that drops a handshake, Pocket FIT 2026-10-29)


class Api(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def do_GET(self):
        SEEN.append(self.path)
        if RESETS.get(self.path, 0) > 0:
            RESETS[self.path] -= 1
            self.connection.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER, struct.pack("ii", 1, 0))
            self.connection.close()  # an RST, no answer
            self.close_connection = True
            return
        body = ROUTES.get(self.path)
        self.send_response(200 if body is not None else 404)
        if body is not None:
            self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        if body is not None:
            self.wfile.write(body)


api = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Api)
threading.Thread(target=api.serve_forever, daemon=True).start()
HOME = os.path.join(T, "home")
DATA = os.path.join(HOME, ".local/share/retroforge/stores")
CHROMIUM = os.path.join(DATA, "chromium")
BASE_ENV = {"HOME": HOME, "PATH": os.environ["PATH"], "RETROFORGE_STORE_API": f"http://127.0.0.1:{api.server_address[1]}"}


def pins(name, packages, comment="", size=None):
    """A pins folder whose chromium.pin lists packages (names in PKGS; a sha256 may be overridden)."""
    folder = os.path.join(T, "pins-" + name)
    os.makedirs(folder, exist_ok=True)
    lines = [f"# {comment}", "snapshot: https://snap.example/mash"]
    for p in packages:
        p, sha = p if isinstance(p, tuple) else (p, hashlib.sha256(PKGS[p]).hexdigest())
        lines.append(f"package: extra {p}-1-1-aarch64.pkg.tar.zst {sha} {size or len(PKGS[p])}")
    open(os.path.join(folder, "chromium.pin"), "w").write("\n".join(lines) + "\n")
    return folder


def store(*args, pin_dir):
    return subprocess.run([sys.executable, STORE] + list(args), env=dict(BASE_ENV, RETROFORGE_STORE_PINS=pin_dir),
                          text=True, capture_output=True, timeout=60)


def nothing_set_up():
    return not os.path.lexists(os.path.join(CHROMIUM, "current")) and not [
        e for e in os.listdir(CHROMIUM) if e != ".lock"] if os.path.isdir(CHROMIUM) else True


# ---- set-up --------------------------------------------------------------------------------------
CASE = "browser"
good = pins("good", ["chromium", "gtk3"])
r = store("browser", "status", pin_dir=good)
ok(r.returncode == 0 and json.loads(r.stdout) == {"ready": False, "binary": None}, "not ready before setup", r.stdout + r.stderr)
r = store("browser", "setup", pin_dir=pins("badsha", ["chromium", ("gtk3", "0" * 64)]))
ok(r.returncode == 1 and "sha256 mismatch" in r.stderr and nothing_set_up(), "a package that is not the pin's: nothing set up", r.stderr)
r = store("browser", "setup", pin_dir=pins("evil", ["chromium", "evil"]))
ok(r.returncode == 1 and "could not unpack" in r.stderr and nothing_set_up(), "a link out of the folder: nothing set up", r.stderr)
r = store("browser", "setup", pin_dir=pins("escape", ["escape", "chromium"]))
ok(r.returncode == 1 and "could not unpack" in r.stderr and nothing_set_up() and not os.path.exists(os.path.join(T, "escaped")),
   "a path out of the folder: nothing written, nothing set up", r.stderr)
os.makedirs(os.path.join(CHROMIUM, ".setup-killed", "x"))
r = store("browser", "setup", pin_dir=pins("huge", ["chromium"], size=10 ** 15))
ok(r.returncode == 1 and "not enough free space" in r.stderr and nothing_set_up(),
   "too little free space: refused first, a killed set-up's leftovers gone before the check", r.stderr)

SEEN.clear()
RESETS["/snap.example/mash/extra/os/aarch64/gtk3-1-1-aarch64.pkg.tar.zst"] = 1
r = store("browser", "setup", pin_dir=good)
cur = os.path.join(CHROMIUM, "current")
ok(r.returncode == 0 and "trying again (2/3)" in r.stderr and SEEN.count(next(iter(RESETS))) == 2,
   "a connection the server resets is tried again, and the set-up goes on", r.stderr)
SEEN.remove(next(iter(RESETS)))  # the reset try: the count below is of downloads
st = json.loads(store("browser", "status", pin_dir=good).stdout)
ok(r.returncode == 0 and r.stdout.strip().splitlines()[-1] == "100%" and len(SEEN) == 2, "set up: two downloads, 100%", r.stdout + r.stderr)
ok(st["ready"] and st["binary"] == os.path.join(os.path.realpath(cur), "chromium", "chromium")
   and os.access(st["binary"], os.X_OK), "status gives the executable", str(st))
files = sorted(os.path.relpath(os.path.join(d, f), os.path.realpath(cur)) for d, _, fs in os.walk(os.path.realpath(cur)) for f in fs)
ok(files == ["chromium/chrome-sandbox", "chromium/chromium", "chromium/chromium-alias", "chromium/locales/en-US.pak",
             "chromium/resources.pak", "lib/libgtk-3.so.0", "lib/libgtk-3.so.0.2400.1", "schemas/gschemas.compiled",
             "schemas/org.retroforge.test.gschema.xml"], "only Chromium's folder, top-level libraries, schemas", str(files))
lib = os.path.join(os.path.realpath(cur), "lib")
ok(os.readlink(os.path.join(lib, "libgtk-3.so.0")) == "libgtk-3.so.0.2400.1", "a library's link stays relative")
ok(not stat.S_IMODE(os.stat(os.path.join(os.path.realpath(cur), "chromium/chrome-sandbox")).st_mode) & 0o6000,
   "no setuid bit kept")
ok(stat.S_IMODE(os.stat(CHROMIUM).st_mode) == 0o700, "the player's only")

SEEN.clear()
r = store("browser", "setup", pin_dir=good)
ok(r.returncode == 0 and SEEN == [], "a second setup downloads nothing", str(SEEN))
old = os.path.realpath(cur)
os.makedirs(os.path.join(CHROMIUM, ".setup-killed"))
newer = pins("newer", ["chromium", "gtk3"], comment="the next relock")
ok(json.loads(store("browser", "status", pin_dir=newer).stdout)["ready"] is False, "a new pin is not ready yet")
r = store("browser", "setup", pin_dir=newer)
ok(r.returncode == 0 and os.path.realpath(cur) != old and os.path.isdir(old) and not os.path.exists(os.path.join(CHROMIUM, ".setup-killed")),
   "a new pin's set-up switches to its folder, keeps the old one (a Chromium may run from it), drops leftovers",
   str(sorted(os.listdir(CHROMIUM))))
r = store("browser", "setup", pin_dir=newer)
ok(r.returncode == 0 and not os.path.exists(old) and len(os.listdir(CHROMIUM)) == 3, "the set-up after that removes the old one",
   str(sorted(os.listdir(CHROMIUM))))
os.makedirs(os.path.join(T, "pins-bad"))
open(os.path.join(T, "pins-bad", "chromium.pin"), "w").write("snapshot: https://snap.example/mash\npackage: extra x\n")
r = store("browser", "setup", pin_dir=os.path.join(T, "pins-bad"))
ok(r.returncode == 1 and r.stderr.strip().splitlines()[-1].startswith("store: ") and "bad line" in r.stderr,
   "a malformed pin ends with the `store:` line, not a traceback", r.stderr)
ok(store("browser", "bogus", pin_dir=good).returncode == 2, "a bad invocation is exit 2")

CASE = "sign-in"
signin = pins("signin", ["chromium", "gtk3"], comment="the sign-in's own set-up")
r = subprocess.run([sys.executable, STORE, "gog", "sign-in"], input="", text=True, capture_output=True, timeout=60,
                   env=dict(BASE_ENV, RETROFORGE_STORE_PINS=signin, RETROFORGE_STORE_TOOL_GOGDL="true",
                            RETROFORGE_STORE_SCALE="1.5"))
events = [json.loads(l) for l in r.stdout.splitlines()]
steps = [e.get("percent") for e in events if e.get("state") == "setup"]
found = json.loads(store("browser", "status", pin_dir=signin).stdout)
ok(steps and steps == sorted(steps) and steps[-1] == 100 and [e["state"] for e in events[len(steps):]] == ["open", "closed"],
   "a first sign-in sets Chromium up (setup events up to 100), then opens it", r.stdout + r.stderr)
ok(found["ready"] and f"fake chromium on {os.path.join(os.path.dirname(os.path.dirname(found['binary'])), 'lib')}" in r.stderr,
   "the set-up Chromium runs on its own libraries, its output kept off the events", r.stderr)

print(f"\n{PASS} passed, {FAIL} failed")
sys.exit(1 if FAIL else 0)
PY
