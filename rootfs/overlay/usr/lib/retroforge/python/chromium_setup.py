# chromium_setup — Chromium for the store sign-in, into the player's home without a package manager
# (/usr/lib/retroforge/store; .claude/plans/store-signin-window.plan.md, D1). Release roots have no
# pacman (seal-rootfs.sh), and Chromium does not fit the root, so the image ships only chromium.pin
# (rootfs/chromium-pin.py): the snapshot's packages Chromium needs that the image lacks, with their
# sha256. set_up() downloads them, checks each, and unpacks what the sign-in window uses:
#
#   <data>/chromium/<pin digest>/chromium/   usr/lib/chromium (the browser, its .pak files, locales)
#                                lib/        the packages' top-level usr/lib/*.so* (GTK3 and its own)
#                                schemas/    their GSettings schemas, compiled (GTK aborts on a missing one)
#   <data>/chromium/current -> <pin digest>
#
# Run it with LD_LIBRARY_PATH=lib and GSETTINGS_SCHEMA_DIR=schemas (environment()). Nothing outside
# <data> changes. A new pin (the next relock) gets its own folder at the next set_up(); the old one goes
# at the set-up after that (a Chromium may still run from it), with any killed set-up's leftovers. Each package is unpacked with tarfile's "data" filter: no
# absolute path, no path or link out of the folder, no setuid bit (the sandbox uses user namespaces).
import fcntl
import hashlib
import os
import shutil
import subprocess
import tarfile
import tempfile

try:
    from compression import zstd  # Python 3.14+: the image's Python, and what tarfile's "r:zst" needs
    _ZSTD_ERRORS = (zstd.ZstdError,)
except ImportError:  # an older Python (CI's): importable, but unpack() fails as a SetupError
    _ZSTD_ERRORS = ()

FREE_FACTOR = 3  # free space wanted, times the download: the packages unpack to ~2.2x (396/181 MB)
DOWNLOAD_SHARE = 95  # % of the progress the downloads take; unpacking each is in its download's share


class SetupError(Exception):
    pass


def read_pin(path):
    """(snapshot, [(repo, file, sha256, size)], digest of the pin's text)."""
    try:
        with open(path, "rb") as f:
            raw = f.read()
    except OSError as err:
        raise SetupError(f"no Chromium pin: {err}")
    snapshot, packages = None, []
    for line in raw.decode("utf-8").splitlines():
        key, _, value = line.partition(":")
        if line.startswith("#") or not value:
            continue
        if key == "snapshot":
            snapshot = value.strip()
        elif key == "package":
            try:
                repo, name, sha256, size = value.split()
                packages.append((repo, name, sha256, int(size)))
            except ValueError:
                raise SetupError(f"the Chromium pin {path} has a bad line: {line}")
    if not (snapshot and packages):
        raise SetupError(f"the Chromium pin {path} lists no snapshot or no package")
    return snapshot, packages, hashlib.sha256(raw).hexdigest()[:16]


def paths(folder):
    return {"binary": os.path.join(folder, "chromium", "chromium"), "lib": os.path.join(folder, "lib"),
            "schemas": os.path.join(folder, "schemas")}


def installed(data, pin_path):
    """The paths of the Chromium set up from this pin, else None (no network)."""
    try:
        digest = read_pin(pin_path)[2]
    except SetupError:
        return None
    current = os.path.join(data, "chromium", "current")
    if os.path.realpath(current) != os.path.realpath(os.path.join(data, "chromium", digest)):
        return None
    found = paths(os.path.join(data, "chromium", digest))
    return found if os.access(found["binary"], os.X_OK) else None


def environment(found, base=None):
    """base (default os.environ) with what Chromium needs to find its libraries and schemas."""
    env = dict(os.environ if base is None else base)
    env["LD_LIBRARY_PATH"] = found["lib"]
    env["GSETTINGS_SCHEMA_DIR"] = found["schemas"]
    return env


def _placed(name):
    """Where a package's file goes in the set-up folder, or None when the sign-in does not use it."""
    if name.startswith("usr/lib/chromium/"):
        return "chromium/" + name[len("usr/lib/chromium/"):]
    rest = name[len("usr/lib/"):] if name.startswith("usr/lib/") else ""
    if rest and "/" not in rest and ".so" in rest:
        return "lib/" + rest
    if name.startswith("usr/share/glib-2.0/schemas/") and name.endswith(".gschema.xml"):
        return "schemas/" + os.path.basename(name)
    return None


def _filter(member, dest):
    new = _placed(member.name)
    if new is None:
        return None
    if member.islnk():
        target = _placed(member.linkname)
        if target is None:
            return None
        member = member.replace(linkname=target, deep=False)
    return tarfile.data_filter(member.replace(name=new, deep=False), dest)


def unpack(package, folder):
    """The used files of one .pkg.tar.zst into folder (refused: anything that would leave it)."""
    try:
        with tarfile.open(package, "r:zst") as t:
            t.extractall(folder, filter=_filter)
    except (tarfile.TarError, OSError, EOFError) + _ZSTD_ERRORS as err:
        raise SetupError(f"could not unpack {os.path.basename(package)}: {err}")


def _clean(root):
    """All but `current` and the folder it points at: a killed set-up's .setup- folder (none runs now:
    the caller holds the lock) and older pins' folders. Done before the free-space check, so a killed
    set-up's leftovers never block the retry, and at the set-up after the one that replaced a folder, so
    a Chromium still running from it keeps its files."""
    keep = os.path.basename(os.path.realpath(os.path.join(root, "current")))
    for other in os.listdir(root):
        if other not in (keep, "current", ".lock"):
            path = os.path.join(root, other)
            if os.path.islink(path) or not os.path.isdir(path):
                os.unlink(path)
            else:
                shutil.rmtree(path, ignore_errors=True)


def set_up(data, pin_path, fetch, progress):
    """Chromium from the pin, downloaded with fetch(url, dest, sha256, progress) (which refuses a
    mismatch), checked, unpacked; progress(done, total). The paths, as installed() gives them."""
    snapshot, packages, digest = read_pin(pin_path)
    root = os.path.join(data, "chromium")
    os.makedirs(root, mode=0o700, exist_ok=True)
    with open(os.path.join(root, ".lock"), "w") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)  # one set-up at a time (two stores signing in)
        _clean(root)
        found = installed(data, pin_path)
        if found:
            progress(1, 1)
            return found
        total = sum(p[3] for p in packages)
        free = shutil.disk_usage(root).free
        if free < total * FREE_FACTOR:
            raise SetupError(f"not enough free space for Chromium: {total * FREE_FACTOR // 2**20} MiB "
                             f"wanted, {free // 2**20} MiB free")
        with tempfile.TemporaryDirectory(dir=root, prefix=".setup-") as tmp:
            folder = os.path.join(tmp, digest)
            done = 0
            for repo, name, sha256, size in packages:
                pkg = os.path.join(tmp, "package")
                fetch(f"{snapshot}/{repo}/os/aarch64/{name}", pkg, sha256,
                      lambda d, _t, base=done: progress((base + min(d, size)) * DOWNLOAD_SHARE // 100, total))
                unpack(pkg, folder)
                os.unlink(pkg)
                done += size
            found = paths(folder)
            if not os.access(found["binary"], os.X_OK):
                raise SetupError("the Chromium packages have no usr/lib/chromium/chromium")
            os.makedirs(found["schemas"], exist_ok=True)
            try:
                res = subprocess.run(["glib-compile-schemas", found["schemas"]], capture_output=True, text=True)
            except OSError as err:
                raise SetupError(f"could not compile the GSettings schemas: {err}")
            if res.returncode != 0:
                raise SetupError(f"glib-compile-schemas failed: {res.stderr.strip()}")
            final = os.path.join(root, digest)
            os.rename(folder, final)  # _clean() removed any old one: it was not `current`'s
        link = os.path.join(root, ".current")
        if os.path.lexists(link):
            os.unlink(link)
        os.symlink(digest, link)
        os.replace(link, os.path.join(root, "current"))
        progress(1, 1)
        return paths(final)
