#!/usr/bin/env python3
# retroforge internal install — PRE-FLIGHT, the spine as a child process, and the progress screen.
# Phase 5 of .claude/plans/internal-install.plan.md.
#
# THE UI DOES NOT INSTALL ANYTHING, and this is the file where that is easiest to break. It runs
# installer/retroforge-install and reads its output; every figure it puts on a screen was measured by
# the program that will act on it — select-target.sh for the target, carve.sh `plan` for what the
# carve does to it, device-env for the board. The one time a figure on a consent-adjacent screen
# was derived independently it said "RetroForge will use the remaining 0 GiB" while the carve handed
# it 90853 MiB (Pocket ACE, 2026-08-21). A second copy of a rule is how the halves drift apart.
import os
import time

from uipad import TOKEN_BACK, TOKEN_QUIT, log

# =================================================================================================
# pre-flight — what is about to happen, while nothing has happened yet
# =================================================================================================
# Every number on this screen is MEASURED, by the same programs the spine will use. The UI does not
# read a partition table and reason about it: select-target.sh says what the target is, carve.sh
# `plan` says what the carve would do to it, device-env says what board this is. That is not
# ceremony -- the one time a figure on a consent-adjacent screen was derived independently, it said
# "RetroForge will use the remaining 0 GiB" while the carve went on to hand it 90853 MiB (Pocket ACE,
# 2026-08-21). A second copy of a rule is how the two halves drift apart.
DEVICE_ENV = os.environ.get("RETROFORGE_DEVICE_ENV", "/usr/lib/retroforge/device-env")
SELECT_TARGET = os.environ.get(
    "RETROFORGE_SELECT_TARGET", "/usr/lib/retroforge/install/select-target.sh")
CARVE = os.environ.get("RETROFORGE_CARVE", "/usr/lib/retroforge/install/carve.sh")
SPINE = os.environ.get("RETROFORGE_SPINE", "/usr/lib/retroforge/install/retroforge-install")
VERIFY_INSTALL = os.environ.get(
    "RETROFORGE_VERIFY_INSTALL", "/usr/lib/retroforge/install/verify-install.sh")
# WHERE THE BYTES COME FROM. The OS bundle is resolved from the update channel at install time by
# installer/release-info, so any card installs the current release. /home needs nothing from
# anywhere: the spine stages an empty player home exactly as the card does.
#
# On a dev image release-info answers `running:<root device>` instead of a URL: the spine copies the
# running root rather than streaming a bundle. Nothing here needs to know; it is passed through.
#
# The bundle remains overridable, for a dev run (docs/install-internal.md) and for the suite.
RELEASE_INFO = os.environ.get("RETROFORGE_RELEASE_INFO", "/usr/lib/retroforge/install/release-info")
BUNDLE = os.environ.get("RETROFORGE_INSTALL_BUNDLE", "")

# Where disk_facts() reads model and size. Overridable for the suite only: the build container's
# /sys/block is the build host's disks.
SYS_BLOCK = os.environ.get("RETROFORGE_SYS_BLOCK", "/sys/block")

UD_GIB_DEFAULT = int(os.environ.get("RETROFORGE_UD_GIB", "16"))
UD_GIB_MIN = 4          # carve.sh has its own ANDROID_FLOOR_GIB; this is the UI's coarse guard
UD_GIB_STEP = 4


def run_tool(argv, timeout=120):
    """A read-only helper: (rc, output). It never raises — a tool that is missing is a fact."""
    import subprocess

    try:
        p = subprocess.run(argv, capture_output=True, text=True, timeout=timeout)
        return p.returncode, (p.stdout or "") + (p.stderr or "")
    except (OSError, ValueError) as e:
        return 127, str(e)
    except Exception as e:                                   # noqa: BLE001 - timeout, mostly
        return 124, str(e)


def kv(text):
    """
    KEY=VALUE lines, parsed the way the SHELL would parse them.

    Not `.strip("'\\"")`. device-env emits with `printf '%s=%q\\n'`, and bash's %q escapes rather
    than quotes when it can: a board called `AYANEO Pocket S2` arrives as `AYANEO\\ Pocket\\ S2`.
    Stripping quotes leaves the backslash in, and it goes on the panel -- measured on a real Pocket
    S2, 2026-08-22, where the pre-flight title read "Install RetroForge on AYANEO\\ Pocket\\ S2".
    Every offline stub had emitted the single-quoted form, which is the other thing %q produces.
    """
    import shlex

    out = {}
    for line in text.splitlines():
        if "=" not in line or line.startswith("#"):
            continue
        k, v = line.split("=", 1)
        try:
            # JOINED, not parts[0]. Both producers feed this: device-env emits one %q-escaped token
            # (`AYANEO\ Pocket\ S2`), which shlex returns as a single element -- but release-info emits
            # plain prose with spaces (`DETAIL=the installer can reach https://...`), which splits
            # into many. Taking the first element rendered that as "the" on a real Pocket S2.
            # Joining handles both; the only loss is a run of consecutive spaces, which no producer
            # here emits and no screen would show.
            parts = shlex.split(v.strip())
        except ValueError:                       # an unbalanced quote (an SSID with an apostrophe)
            parts = [v.strip().strip("'\"")]
        out[k.strip()] = " ".join(parts)
    return out


def disk_facts(dev):
    """Model and size straight out of sysfs. Both are decoration; neither may stop a run.

    A UFS LUN (or any SCSI disk) carries device/model; an eMMC has no model attribute and names
    itself in device/name instead, the CID product name -- "MMC64G" on the MANGMI Air X."""
    blk = os.path.join(SYS_BLOCK, os.path.basename(dev))
    facts = {"model": "unknown", "size_gib": "unknown"}
    for attr in ("model", "name"):
        try:
            with open(os.path.join(blk, "device", attr)) as f:
                model = f.read().strip()
        except OSError:
            continue
        if model:
            facts["model"] = model
            break
    try:
        with open(os.path.join(blk, "size")) as f:
            facts["size_gib"] = str(int(f.read().strip()) * 512 // (1024 ** 3))
    except (OSError, ValueError):
        pass
    return facts


def plan_carve(disk, gib):
    """carve.sh plan — the resulting free space and the list of partitions it will destroy."""
    rc, out = run_tool([CARVE, "plan", disk, str(gib)])
    if rc != 0:
        return {"RETROFORGE_GIB": "unknown", "REPLACES_OURS": "unknown", "destroy": [], "error": out}
    fields = kv(out)
    destroy = []
    for line in out.splitlines():
        if line.startswith("DESTROY="):
            parts = line[len("DESTROY="):].split(None, 2)
            if len(parts) == 3:
                destroy.append({"index": parts[0], "name": parts[1], "fate": parts[2]})
    return {
        "RETROFORGE_GIB": fields.get("RETROFORGE_GIB", "unknown"),
        "REPLACES_OURS": fields.get("REPLACES_OURS", "unknown"),
        "destroy": destroy,
        "error": "",
    }


_RELEASE = None     # a resolved release, cached. A FAILURE IS NEVER CACHED, so Check again re-asks.


def resolve_release():
    """
    {bundle, state, detail} -- what this would install, or why it cannot.

    THE FACTS BELONG TO release-info AND THE WORDS TO THE SCREEN. All this does is prefer the
    environment over the server: a dev run can name a bundle in RETROFORGE_INSTALL_BUNDLE.

    Only a resolved release is remembered. Every failure here is one a person can act on -- the
    server was not up yet, the channel had nothing published, DNS was still settling -- and a cached
    "no" would make the Check again button on the pre-flight screen a button that redraws itself.
    """
    global _RELEASE
    if BUNDLE:
        return {"bundle": BUNDLE, "state": "ok", "detail": ""}
    if _RELEASE is not None:
        return _RELEASE
    # SYNCHRONOUS, and bounded so it can stay that way: it blocks the frame like every other tool the
    # pre-flight gathers from (select-target.sh, carve.sh), and the fetch is a few hundred bytes.
    rc, out = run_tool([RELEASE_INFO], timeout=45)
    facts = kv(out)
    state = facts.get("STATE", "")
    if not state:
        # release-info always prints a STATE, so no STATE means it did not run: a card that
        # shipped without it, or a python that could not start. HW 2026-08-24 taught this shape
        # once already, with lib-gpt.sh -- a tool that is missing must not read as an answer.
        state, facts = "no-tool", {
            "DETAIL": "the installer's own release helper did not answer: %s"
                      % ((out.strip().splitlines() or ["it produced nothing (rc=%d)" % rc])[-1])}
    release = {
        "bundle": facts.get("BUNDLE", ""),
        "state": state,
        "detail": facts.get("DETAIL", ""),
    }
    log("release: %s (%s)" % (state, release["detail"] or "no detail"))
    # PROBE: the facts release-info resolved, recorded verbatim. The line above is the one the SCREEN
    # is built from, and it deliberately names only the host -- one line that has already overflowed a
    # panel once. This one is for the LOG, and it names the channel and the exact bundle URL.
    #
    # It exists because a run on a non-default channel could not previously be audited from its own
    # journal: release-info has always emitted URL and CHANNEL, and nothing wrote them down, so
    # "which bundle did this run actually stream?" was answerable only by inference from the host.
    # A screen may summarise; a log must not lose what the code already knew
    # ([[screens-must-say-what-the-code-knows]]).
    log("release probe: channel=%s url=%s version=%s build=%s size=%s bundle=%s"
        % (facts.get("CHANNEL", "?"), facts.get("URL", "?"), facts.get("VERSION", "?"),
           facts.get("BUILD", "?"), facts.get("SIZE", "?"), release["bundle"] or "?"))
    if release["bundle"]:
        _RELEASE = release
    return release


def gather_preflight():
    """
    (facts, reason) -- facts for the pre-flight screen, or None with the reason there are none.

    THE REASON IS RETURNED, NOT JUST LOGGED, and that is the whole point of the second element.
    This used to return a bare None for every no-target outcome, so the panel fell back to a screen
    saying "Waiting for the installer." and nothing else. That reads as correct in exactly one
    situation -- the UI running as a consent renderer for a spine driven over SSH -- and it was
    silently swallowing two others that look nothing like it: a device that genuinely has no target
    (booted from internal, rule 1), and select-target.sh failing to RUN at all.

    HW-FOUND 2026-08-24: the medium shipped without lib-gpt.sh, select-target.sh died with
    "cannot find lib-gpt.sh", and the operator got "Waiting for the installer." forever with no clue
    that anything had gone wrong. A person holding the device could not tell a broken build from a
    disk this installer refuses to touch. Whatever the caller does with it, the reason has to reach
    the screen.
    """
    rc, out = run_tool([SELECT_TARGET])
    if rc != 0:
        # KEEP THE REASONS, NOT THE SUMMARY. select-target.sh prints one INDENTED line per disk
        # explaining why that disk was rejected, then ends with "no disk qualifies -- see the
        # reasons above". Taking splitlines()[-1] kept only the summary, so the panel told the
        # operator to look above it -- on a screen with no above. HW 2026-08-24, Pocket FIT: rule 3b
        # correctly refused a disk carrying ROCKNIX and said so in as many words ("partition 12
        # (ROCKNIX) is a bootable ESP that is not ours -- remove the other OS first"), and that
        # sentence was the one thrown away.
        lines = [ln.strip() for ln in out.strip().splitlines() if ln.strip()]
        detail = [ln for ln in lines if ln.startswith(("/dev/", "  /dev/"))] or \
                 [ln for ln in lines if ln.startswith("/dev/")]
        # The indented per-disk lines are the answer; fall back to everything, then to the summary,
        # so a message shape we did not anticipate still reaches the screen instead of vanishing.
        reason = "\n".join(detail) if detail else ("\n".join(lines[-3:]) if lines
                                                   else "select-target.sh failed with no output")
        log("no install target (%s); serving consent only" % reason.replace("\n", " | "))
        return None, reason
    target = kv(out)
    disk = target.get("TARGET", "")
    if not disk:
        return None, "select-target.sh named no disk"
    name = "this device"
    drc, dout = run_tool([DEVICE_ENV])
    if drc == 0:
        name = kv(dout).get("RETROFORGE_DEVICE_NAME", name)
    facts = {
        "device": name,
        "disk": disk,
        "mode": target.get("MODE", "?"),
        "ud_index": target.get("UD_INDEX", "?"),
        "disk_facts": disk_facts(disk),
    }
    facts.update(release_facts())
    return facts, ""


def release_facts():
    """The three keys the pre-flight screen reads about the download, as a fresh dict."""
    r = resolve_release()
    return {"bundle": r["bundle"], "release": r["state"], "release_detail": r["detail"]}


class PreflightScreen:
    """
    The last screen before the consent gate, and the only one with a knob on it.

    LEFT/RIGHT adjust what Android keeps -- §5 says adjusted, never typed, because there is no text
    entry anywhere in this UI. Every adjustment re-asks carve.sh, so the figure next to it is always
    the one that carve would produce for that choice rather than an interpolation.
    """

    name = "preflight"

    def __init__(self, facts, gib=UD_GIB_DEFAULT):
        self.facts = facts
        self.gib = gib
        self.plan = plan_carve(facts["disk"], gib)
        self.result = None      # ("start", gib) | ("quit",)

    def _replan(self, gib):
        if gib < UD_GIB_MIN:
            return
        self.gib = gib
        self.plan = plan_carve(self.facts["disk"], gib)

    def handle(self, token):
        if token == "LEFT":
            self._replan(self.gib - UD_GIB_STEP)
        elif token == "RIGHT":
            self._replan(self.gib + UD_GIB_STEP)
        elif token == "S":
            # Nothing is written by pressing this. It starts the spine, which recons, verifies the
            # bundle and THEN takes consent -- the disk is still untouched on the other side of it.
            if self.ready():
                self.result = ("start", self.gib)
            else:
                # The disk is already known; it is the download that is not. Ask again for that
                # alone -- and keep the size the operator chose, which is why this is a result the
                # loop acts on rather than a fresh screen built here.
                self.result = ("recheck",)
        elif token in (TOKEN_BACK, TOKEN_QUIT):
            self.result = ("quit",)

    def ready(self):
        return bool(self.facts.get("bundle"))

    def to_install(self):
        """
        What is about to be downloaded, or WHY THERE IS NOTHING TO DOWNLOAD.

        This block used to be the bundle URL or the words "NO BUNDLE CONFIGURED", which named the
        symptom and no cause: an unreachable server, a channel with nothing published and a manifest
        that did not parse all produced the same four words on the same dead-end screen. release-info knows which it is and says so in one line
        ([[screens-must-say-what-the-code-knows]]), so this passes that line through rather than
        writing a fifth version of it here.
        """
        f = self.facts
        if self.ready():
            return f.get("release_detail") or f["bundle"]
        detail = f.get("release_detail")
        if detail:
            return detail
        return ("This installer has not been told what to install, and cannot continue."
                if f.get("release") else
                "The download has not been worked out yet -- press Check again.")

    def describe(self):
        f, d = self.facts, self.facts["disk_facts"]
        destroy = self.plan["destroy"]
        # ONE LINE PER PARTITION DOES NOT FIT, and this screen is the one that must. HW 2026-08-25,
        # Pocket ACE with RetroForge already installed: eight partitions at one line each, under a
        # heading, above four more blocks, ran off the bottom of the panel and collided with the
        # SELECT row -- worse after the type scale went up, which it did because these screens were
        # too small to read.
        #
        # NOTHING IS ELIDED TO ACHIEVE IT. This is the list a person consents to losing; "and 4
        # more" is not a thing a consent screen may say. When every partition shares one fate --
        # which is exactly the eight-of-ours case -- the fate is stated ONCE in the heading and the
        # names run together as prose the wrapper can break, so eight lines become two and every
        # index and name is still on the panel. Mixed fates stay one per line, because there the
        # fate is the information and the list is short anyway.
        lost_head = "These partitions will be destroyed"
        if not destroy:
            lost = "carve.sh could not be asked what it would destroy -- do not continue."
        else:
            # ONE LINE PER FATE, NOT PER PARTITION. carve.sh emits `userdata data-erased` and then
            # one `replaced` per partition of ours that exists, so a reinstall is nine lines under
            # a heading with four blocks below it -- which ran off the panel and collided with the
            # SELECT row on a Pocket ACE (HW 2026-08-25).
            #
            # GROUPING, NOT A SINGLE-FATE SPECIAL CASE. The first attempt at this compacted only
            # when every fate matched, and no real disk produces that: userdata is always in the
            # list with a fate of its own, so the branch could not fire on hardware and the screen
            # was unchanged. Grouping has no such condition -- it is the same code path for one
            # fate or five, which is why it cannot quietly not happen.
            order, groups = [], {}
            for x in destroy:
                fate = x["fate"].replace("-", " ")
                if fate not in groups:
                    groups[fate] = []
                    order.append(fate)
                groups[fate].append("p%s %s" % (x["index"], x["name"]))
            lost_head = "These %d partitions will be destroyed" % len(destroy)
            # Every index and name still reaches the panel: this is the list a person consents to
            # losing, so it is compacted, never shortened. The wrapper breaks the long group.
            lost = "\n".join("%s:  %s" % (fate, ",  ".join(groups[fate])) for fate in order)
        # WHAT KIND OF INSTALL THIS IS, said before anything else. HW 2026-08-24, Pocket ACE with
        # RetroForge already on its internal disk: the screen listed our own eight partitions in the
        # destroy list and never said the word reinstall, so nothing on it distinguished "install
        # alongside Android" from "replace the RetroForge that is already here". The mode was in the
        # facts the whole time and simply was not drawn.
        #
        # AND THE PLAN REALLY IS A FRESH CARVE. select-target.sh reports MODE=reinstall when our
        # eight are present, but plan_carve() calls `carve.sh plan`, and carve.sh handles `plan` in
        # the same branch as `fresh` -- so what is being described, and what pressing through would
        # do, destroys /home. The `reinstall` mode that keeps /home is not reachable from this UI at
        # all. Saying so is the honest thing until it is: the operator is not choosing wrong, the
        # choice does not exist yet.
        if f.get("mode") == "reinstall":
            blocks = [
                ("This device already has RetroForge",
                 "Everything currently installed will be erased and replaced, INCLUDING /home -- "
                 "your games, saves and settings. This installer cannot yet repair an existing "
                 "install while keeping them; it only does a full replacement."),
            ]
        else:
            blocks = [
                ("This device is running Android",
                 "RetroForge will be installed alongside it. Android keeps the space you choose "
                 "below, and everything else on that partition is erased."),
            ]
        blocks += [
            ("Target", "%s  %s  %s GiB" % (f["disk"], d["model"], d["size_gib"])),
            ("Android keeps", "%s GiB   (left / right to change)" % self.gib),
            ("RetroForge gets", "%s GiB" % self.plan["RETROFORGE_GIB"]),
            (lost_head, lost),
            ("To install", self.to_install()),
        ]
        return {
            "screen": "preflight",
            # The title carries it too: the first block explains, but a person glancing at the panel
            # reads the heading, and "Install" and "Replace" are different promises.
            "title": ("Replace the RetroForge on %s" if f.get("mode") == "reinstall"
                      else "Install RetroForge on %s") % f["device"],
            "blocks": blocks,
            "diamonds": [],
            "prompt": "",
            "note": "Nothing has been written yet, and nothing will be until you confirm.",
            "buttons": ([{"pos": "S", "label": "Continue"}] if self.ready() else
                        [{"pos": "S", "label": "Check again"}])
            + [{"pos": "SELECT", "label": "Cancel"}],
            "abort": "",
        }


# =================================================================================================
# the install itself — the spine as a subprocess, and the bar over it
# =================================================================================================
# THE UI DOES NOT INSTALL ANYTHING. It runs installer/retroforge-install and reads its output, which is
# what keeps the orchestrator the testable spine and this a view. Two things come back on that pipe:
#
#   [retroforge-install] == <step> ==     the step markers the spine already prints
#          NN% <message>                rauc's own progress, printed by `rauc install`
#
# The plan said to reuse retroforge-update's D-Bus subscription for the second one. That is the right
# call THERE, where the client talks to the system rauc; it is the wrong one here, because the rauc
# the spine drives lives on the PRIVATE system bus rauc-session.sh starts for the occasion, and the
# UI would have to find that bus to subscribe to it. Reading the percentage off the pipe we already
# hold gets the same number from the same source with no second bus client in the installer.
STEP_RE = r"^\[[^]]+\] == (.+) ==\s*$"
PERCENT_RE = r"^\s*(\d{1,3})%\s+(.*)$"

# The spine's steps, in the order it prints them, with what to call them on a panel. `/home (kept)`
# is the reinstall path's name for the same phase and is folded in.
PHASES = [
    ("recon", "Reading the disk"),
    ("select-target", "Choosing the target"),
    ("install record", "Writing the install record"),
    ("verify sources", "Verifying the download"),
    ("CONFIRM", "Waiting for you"),
    ("carve", "Repartitioning"),
    ("filesystems", "Creating filesystems"),
    ("root slot", "Installing RetroForge"),
    ("/home", "Setting up /home"),
    ("efi-a / efi-b", "Writing the boot slots"),
    ("ESP", "Writing the boot partition"),
    ("done", "Done"),
]
PHASE_ALIAS = {"/home (kept)": "/home"}


class ChildLines:
    """
    Whole lines from a child's merged stdout/stderr, without ever blocking the frame.

    Shared by SpineRun and VerifyRun because they read the same way and only differ in what they
    launch. Subclasses set `self.proc` (non-blocking stdout) and call `_init_lines()`.
    """

    def _init_lines(self):
        os.set_blocking(self.proc.stdout.fileno(), False)
        self.buf = b""
        self.tail = []          # the last few lines, for the failure text

    def poll(self):
        """Whatever whole lines are available right now. Never blocks."""
        try:
            chunk = self.proc.stdout.read()
        except (BlockingIOError, ValueError):
            chunk = None
        if chunk:
            self.buf += chunk
        lines = []
        while b"\n" in self.buf:
            line, self.buf = self.buf.split(b"\n", 1)
            text = line.decode("utf-8", "replace").rstrip()
            if text:
                lines.append(text)
                self.tail = (self.tail + [text])[-12:]
        return lines

    def returncode(self):
        return self.proc.poll()

    def stop(self):
        if self.proc.poll() is None:
            self.proc.terminate()


class VerifyRun(ChildLines):
    """
    installer/verify-install.sh as a child, run by the UI once the spine reports success.

    THE UI RUNS IT, NOT THE SPINE, and that is the whole point. verify-install.sh exists as a
    separate program because "the spine writes; this reads -- an installer that graded its own work
    would share the bug with its grader", so folding it into the spine's success path would undo
    the reason it is a separate file. Running it from here keeps the two judgements apart while
    still getting the answer in front of the operator.

    IT HAD NO CALLER AT ALL UNTIL NOW (#66). The script's own header says to run it "after the
    install and BEFORE the card comes out, while there is still a shell that can fix things" -- and
    a release medium has no shell: no sshd, no Wi-Fi, and a session whose only client is this UI.
    So the tool shipped on every medium and nothing could ever invoke it. Confirmed by the first
    end-to-end install (Pocket ACE, 2026-08-25): zero mentions in the whole ESP log.

    The disk is PASSED, never discovered. verify-install.sh can find the installed disk itself, but
    we already know which one the spine just wrote -- and asking it to search is a second copy of a
    rule that has exactly one right answer here.
    """

    def __init__(self, disk):
        import subprocess

        argv = [VERIFY_INSTALL] + ([disk] if disk else [])
        log("checking the install: %s" % " ".join(argv))
        self.proc = subprocess.Popen(
            argv, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, bufsize=0)
        self._init_lines()


class SpineRun(ChildLines):
    """installer/retroforge-install as a child process, read without blocking the frame."""

    def __init__(self, gib, sock_path, bundle, intent):
        import subprocess

        env = dict(os.environ)
        # THE SPINE MUST ASK US FOR CONSENT. $CONFIRM names who renders; pointing it at our shim is
        # what puts the gate on this screen instead of on a terminal nobody is looking at.
        env["RETROFORGE_CONFIRM"] = os.path.join(
            os.path.dirname(os.path.abspath(__file__)), "confirm-ui")
        env["RETROFORGE_UI_SOCK"] = sock_path
        # THE URL COMES FROM THE SCREEN THAT WAS SHOWN, not from a second call to release-info and
        # not from the module's environment defaults. Whatever the pre-flight printed under "To
        # install" is what gets installed: resolving again here would be a second copy of the rule,
        # free to answer differently from the one the operator read (the update server can publish
        # between the two calls) -- the same drift the screen's every-figure-is-measured rule exists
        # to prevent.
        # --intent IS NOT OPTIONAL, and it was until hardware said so. On a disk that already
        # carries RetroForge the spine refuses to pick for us -- "a disk that already carries a
        # retroforge install admits three different answers and this script may not pick one" -- so an
        # install on such a disk died at select-target, every time, with the UI having done
        # everything else right (Pocket ACE, 2026-08-25). This argument existed and nothing ever
        # passed it, which is why a REQUIRED parameter now rather than a default: the same shape as
        # the bundle, which was silently taken from the module's environment until the day it was
        # empty.
        argv = [SPINE, "--bundle", bundle,
                "--userdata-gib", str(gib), "--intent", intent]
        log("starting the spine: %s" % " ".join(argv))
        self.proc = subprocess.Popen(
            argv, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, env=env, bufsize=0)
        self._init_lines()


# Off first, because a card pulled from a running system goes out dirty.
DONE_NOTE = "Power off, remove the SD card, then power on to start RetroForge from internal storage."


class ProgressScreen:
    """A bar per phase, and the one honest sentence a failure owes the user."""

    name = "progress"

    def __init__(self, run, disk=None):
        self.run = run
        self.disk = disk                # which disk to hand verify-install.sh when the spine wins
        self.phase = None
        self.percent = None
        self.message = ""
        self.rc = None
        self.reached_carve = False      # i.e. whether the disk has been modified
        self.result = None              # ("quit",)
        # None = not started, "running", "ok", "bad", "unrunnable". A successful install is not the
        # same claim as a verified one, and the screen must not merge them.
        self.verify = None
        self.verify_bad = []            # the `!!` lines, which are what the operator has to read
        self.verify_tail = []           # its last few lines, for the case where it refused to run

    def begin_verify(self):
        self.verify = "running"

    def feed_verify(self, line):
        """verify-install.sh prints `    ok  ...` and `    !!  ...`; only the failures go on screen."""
        text = line.strip()
        self.verify_tail = (self.verify_tail + [text])[-6:]
        if text.startswith("!!"):
            self.verify_bad.append(text[2:].strip())

    def finish_verify(self, rc):
        # rc 1 is BOTH "a check failed" and "it could not run" (its die() also exits 1), so the
        # `!!` lines are what tells them apart: a run that refused printed none.
        if rc == 0:
            self.verify = "ok"
        else:
            self.verify = "bad" if self.verify_bad else "unrunnable"

    def feed(self, line):
        import re

        m = re.match(STEP_RE, line)
        if m:
            step = PHASE_ALIAS.get(m.group(1), m.group(1))
            if any(step == p for p, _ in PHASES):
                self.phase = step
                self.percent = None
                if step == "carve":
                    self.reached_carve = True
            return
        m = re.match(PERCENT_RE, line)
        if m:
            self.percent = int(m.group(1))
            self.message = m.group(2)

    def handle(self, token):
        if self.rc is None:
            return
        # A failed install, or one the CHECK rejected, offers Try again and Restart: re-running is the
        # documented recovery, the installer takes no backups precisely because it has to work. A
        # verified install offers only Power off, so any press means that, and it is what makes the
        # card safe to pull. Restart is the UI exiting: the unit saves the log and reboots.
        if self.rc == 0 and self.verify != "bad":
            self.result = ("poweroff",)
        else:
            self.result = ("retry",) if token == "S" else ("quit",)

    def finish(self, rc):
        self.rc = rc

    def describe(self):
        rows = []
        seen_current = False
        for step, label in PHASES:
            if step == self.phase:
                state, seen_current = "active", True
            elif seen_current:
                state = "pending"
            else:
                state = "done" if self.phase else "pending"
            rows.append({
                "label": label,
                "state": state,
                "percent": self.percent if state == "active" else None,
            })
        # NOT a second copy of the phase list. uiview's _phases() renders `rows` -- with the
        # done/active colour, the bar and the percentage -- and this used to ALSO build one
        # plain-text line per reached phase, which _flow() draws immediately above it. So every
        # phase the spine reached appeared twice on the panel: once flat, once as a real row.
        # Observed on an AYANEO Pocket ACE, 2026-08-25 ("Reading the disk / Choosing the target /
        # Writing the install record", each twice). `rows` is the renderer; `blocks` carries only
        # what has no row of its own.
        blocks = []
        title = "Installing RetroForge"
        note = "Do not power the device off."
        buttons = []
        if self.rc == 0:
            title = "RetroForge is installed"
            # THE CARD MUST NOT COME OUT UNTIL THE CHECK HAS SPOKEN. verify-install.sh is the only
            # thing that reads back what was written, and its own header asks to be run "BEFORE the
            # card comes out, while there is still a shell that can fix things" -- so telling the
            # operator to remove it while the check is still running would waste the one window it
            # has. Power off stays offered throughout: a check that hangs must never trap anyone.
            buttons = [{"pos": "S", "label": "Power off"}]
            if self.verify in (None, "running"):
                note = "Checking the install -- leave the SD card in."
            elif self.verify == "ok":
                note = DONE_NOTE
                blocks = blocks + [("Checked", "The eight partitions carry what the boot chain "
                                               "looks for. This does not prove the device boots -- "
                                               "that is the next thing to try.")]
            elif self.verify == "unrunnable":
                # NOT a failed install, and it may not be reported as one. Say which question went
                # unanswered instead of inventing an answer to it.
                note = DONE_NOTE
                blocks = blocks + [("The check could not run",
                                    "The install finished, but the verifier did not run, so "
                                    "nothing has read back what was written.\n"
                                    + "\n".join(self.verify_tail[-4:]))]
            else:
                title = "RetroForge is installed, but the check did not pass"
                note = "Do not remove the SD card. Re-running the installer is the recovery."
                blocks = blocks + [("What did not check out", "\n".join(self.verify_bad))]
                buttons = [{"pos": "S", "label": "Try again"},
                           {"pos": "SELECT", "label": "Restart"}]
        elif self.rc is not None:
            title = "The install did not finish"
            # THE ONE THING A FAILURE OWES THE USER: which of two states the device is in. "It
            # failed" is not actionable; "nothing was written" and "the disk was modified" are
            # different situations and only one of them needs anything done about it.
            note = ("The disk WAS modified. Re-run the installer; Android's data is already gone."
                    if self.reached_carve else
                    "Nothing was written. The device is exactly as it was.")
            buttons = [{"pos": "S", "label": "Try again"},
                       {"pos": "SELECT", "label": "Restart"}]
            blocks = blocks + [("What happened", "\n".join(self.run.tail[-6:]))]
        return {
            "screen": "progress",
            "title": title,
            "blocks": blocks,
            "rows": rows,
            "diamonds": [],
            "prompt": "",
            "note": note,
            "buttons": buttons,
            "abort": "",
        }
