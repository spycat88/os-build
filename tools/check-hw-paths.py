#!/usr/bin/env python3
"""check-hw-paths: every board profile's hardware-map pins against its compiled devicetree.

The profiles (rootfs/overlay/usr/lib/retroforge/devices/*.conf, RETROFORGE_HW_*) name sysfs nodes the
kernel creates on the device: a power_supply, a backlight, thermal zone types, a hwmon, the GPU's
devfreq, LED class devices. No board needs to be in hand to check most of them, because every one
of those names is the devicetree plus a fixed rule in the driver that registers it. This reads each
board's DTB, works out what the kernel will create the way the kernel does, and checks every pin
against that:

  thermal zones   the zone's node name, if the zone is available, its sensor provider is enabled,
                  and the name fits THERMAL_NAME_LENGTH (the core refuses longer ones)
  LEDs            led_compose_name(): the label, else color:function[-enumerator], else the node
                  name -- for each LED whose controller (and, for a multicolor group, every member;
                  for a PWM LED, every PWM provider) is enabled; plus the names a driver registers
                  with no node per LED (DRIVER_LEDS)
  backlights      pwm-backlight: the device name; qcom WLED: label or node name; SY7758 and the
                  Odin 2 Mini's controller: their fixed names; a DSI panel that dims over DCS:
                  its DSI device, <host>.<channel> (the PANELS table says which panels do)
  power supplies  the names the enabled supply drivers register (SUPPLIES)
  fan             pwm-fan -> pwmfan, gpio-fan -> gpio_fan, when the node and its PWM are enabled
  GPU devfreq     the Adreno's device name, <translated reg>.<node name>

What it cannot see is anything only hardware knows: whether a diode is fitted, which ring is the
left one, which zone runs hottest, whether a GPIO is really the enable. hw-map's own fallback
covers a wrong guess on the device (it logs the pin and detects).

DTBs come from the kernel build (--dtbs out/dtbs, what `make check-hw-paths` passes) or are
compiled here from kernel/dts/qcom against a Linux tree with RetroForge's devicetree patches applied
(--linux-src). Each DTB's root `model` goes through the real device-env, so the pins checked are
the ones a booted board gets. A known gap goes in tools/check-hw-paths.xfail; a listed check that
starts passing fails the run, so the list cannot go stale.
"""
import argparse
import fnmatch
import os
import shutil
import struct
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DEVICE_DIR = ROOT / "rootfs/overlay/usr/lib/retroforge/devices"
DEVICE_ENV = ROOT / "rootfs/overlay/usr/lib/retroforge/device-env"
XFAIL = ROOT / "tools/check-hw-paths.xfail"

# ------------------------------------------------------------------------------- the driver tables

# DSI panels by compatible: "dcs" registers its own backlight under its DSI device name, always;
# "borrows" links the devicetree `backlight` (drm_panel_of_backlight) and registers none; "none"
# registers none and links none. An enabled panel missing here fails the run: a new panel driver
# has to be read and added, not guessed.
PANELS = {
    "chipone,icna3512": "dcs",              # kernel/patches/0530
    "chipone,icna3520": "dcs",              # 0530
    "mangmi,pocket-max-panel": "dcs",       # 0530
    "ayaneo,pocket-dmg-panel": "dcs",       # 0510
    "ch13726a,rp5": "dcs",                  # 0535
    "ch13726a,rpmini": "dcs",               # 0535
    "ch13726a,rpminiv2": "dcs",             # 0535
    "ch13726a,thor": "dcs",                 # 0535
    "vtdr6130,rp6": "dcs",                  # 0555
    "il97680a,rpnova": "dcs",               # 0560
    "vtdr6130,rpduo": "dcs",                # 0557
    "retroidpocket,rpduo-panel-bottom": "dcs",  # 0561 (panel-ilitek-il97680a-cmd)
    "retroid,pocket-classic-panel": "dcs",  # upstream chipwealth-ch13726a + 0536
    "retroid,pocket-classic-g1392-panel": "dcs",  # upstream chipwealth-ch13726a + 0536
    "ayaneo,pocket-ace-panel": "borrows",   # 0505
    "ayaneo,pocket-ds-secondary-panel": "borrows",  # 0515
    "syna,td4328": "borrows",               # 0520
    "ayaneo,wt0600-2k": "borrows",          # 0540
    "ayaneo,wt0630-2k": "borrows",          # 0540
    "ayaneo,ar14-144hz": "borrows",         # 0545
    "ayaneo,wt0600-1080p-60hz": "borrows",  # 0550
    "mangmi,hx83112a": "borrows",           # 0565
    "mangmi,bm5460bb1": "borrows",          # 0570
    "mangmi,td4310": "borrows",             # 0575
    "mangmi,air-y-pro-panel": "borrows",    # 0580
    "mangmi,gh7005": "borrows",             # 0585
    "focaltech,ft7131m": "borrows",         # 0590
    "boe,xm91080g": "none",                 # 0525 (the Mini's backlight is ayn,odin2miniled)
}

# Power-supply drivers by compatible: the supplies each registers, as (name, kind). "battery" is a
# Battery that reports a capacity; "companion" is a Battery-typed node that does not (bq256xx's).
BATTMGR = [("qcom-battmgr-bat", "battery"), ("qcom-battmgr-usb", "charger"),
           ("qcom-battmgr-wls", "charger")]
BATTMGR_X86 = BATTMGR + [("qcom-battmgr-ac", "charger")]   # sc8280xp / x1e80100 variants
BQ256XX = [("bq256xx-charger", "charger"), ("bq256xx-battery", "companion")]
SUPPLIES = {
    "qcom,pm8150b-fg": [("battery", "battery")],          # 0910 qcom-fg
    "qcom,pmi8998-fg": [("battery", "battery")],
    "qcom,pmi8994-fg": [("battery", "battery")],
    "qcom,pm8150b-charger": [("pm8150b-charger", "charger")],  # 0910: "%s-charger" of the match data
    "cellwise,cw221x": [("battery", "battery")],          # 0925
    "halomicro,hl7139": [("hl7139-charger", "charger")],  # 0920 (a charge pump: online = pump on)
    "sgmicro,sgm41515": BQ256XX,                          # 0945
    **{f"ti,{c}": BQ256XX for c in ("bq25600", "bq25600d", "bq25601", "bq25601d", "bq25611d",
                                    "bq25618", "bq25619")},
}

WLED = {"qcom,pm8150l-wled", "qcom,pmi8998-wled", "qcom,pm8941-wled", "qcom,pmi8994-wled",
        "qcom,pm660l-wled", "qcom,pm6150l-wled", "qcom,pmi8950-wled", "qcom,pm8950-wled"}
LED_CHIPS = {"heroic,htr3212", "awinic,aw20036", "awinic,aw20054", "awinic,aw20072",
             "awinic,aw20108", "pwm-leds", "gpio-leds"}
# LEDs a driver registers under names of its own, with no child node per LED.
DRIVER_LEDS = {
    "singleadc-joypad": [f"rgb:{s}{i}" for s in "lr" for i in range(1, 9)],   # 0763 stick rings
    "konkr,pf-elite-mcu": ["konkr:rgb:joysticks"],                            # 0765 stick rings
}
LED_COLORS = ["white", "red", "green", "blue", "amber", "violet", "yellow", "ir", "multicolor",
              "rgb", "purple", "orange", "pink", "cyan", "lime"]   # drivers/leds/led-core.c
THERMAL_NAME_LENGTH = 20                                            # including the NUL

# ---------------------------------------------------------------------------------- the FDT reader


class Node:
    def __init__(self, name, parent):
        self.name, self.parent, self.props, self.children = name, parent, {}, []

    @property
    def path(self):
        if self.parent is None:
            return "/"
        up = self.parent.path
        return (up if up != "/" else "") + "/" + self.name

    @property
    def base(self):  # %pOFn: the name without its unit address
        return self.name.split("@", 1)[0]

    def u32s(self, prop):
        v = self.props.get(prop)
        return list(struct.unpack(f">{len(v) // 4}I", v)) if v else []

    def u32(self, prop, default=None):
        v = self.u32s(prop)
        return v[0] if v else default

    def string(self, prop):
        v = self.props.get(prop)
        return v.split(b"\0", 1)[0].decode() if v is not None else None

    def strings(self, prop):
        v = self.props.get(prop)
        return [s.decode() for s in v.split(b"\0") if s] if v else []

    def compatible(self, *names):
        return any(c in names for c in self.strings("compatible"))

    def available(self):  # of_device_is_available, up the tree: a disabled bus disables its children
        n = self
        while n is not None:
            if n.string("status") not in (None, "okay", "ok"):
                return False
            n = n.parent
        return True

    def walk(self):
        yield self
        for c in self.children:
            yield from c.walk()


class Tree:
    def __init__(self, blob):
        magic, _, off_struct, off_strings = struct.unpack(">IIII", blob[:16])
        if magic != 0xD00DFEED:
            raise ValueError("not a flattened devicetree")
        strings = blob[off_strings:]
        pos, node, self.root = off_struct, None, None
        while True:
            (tok,) = struct.unpack(">I", blob[pos:pos + 4])
            pos += 4
            if tok == 1:  # BEGIN_NODE
                end = blob.index(b"\0", pos)
                child = Node(blob[pos:end].decode(), node)
                if node is None:
                    self.root = child
                else:
                    node.children.append(child)
                node, pos = child, (end + 4) & ~3
            elif tok == 2:  # END_NODE
                node = node.parent
            elif tok == 3:  # PROP
                length, nameoff = struct.unpack(">II", blob[pos:pos + 8])
                pos += 8
                name = strings[nameoff:strings.index(b"\0", nameoff)].decode()
                node.props[name] = blob[pos:pos + length]
                pos = (pos + length + 3) & ~3
            elif tok == 4:  # NOP
                continue
            elif tok == 9:  # END
                break
            else:
                raise ValueError(f"bad FDT token {tok}")
        self.phandles = {}
        for n in self.root.walk():
            ph = n.u32("phandle") or n.u32("linux,phandle")
            if ph:
                self.phandles[ph] = n

    @property
    def model(self):
        return self.root.string("model")

    def node(self, path):
        n = self.root
        for part in [p for p in path.split("/") if p]:
            n = next((c for c in n.children if c.name == part), None)
            if n is None:
                return None
        return n

    def refs(self, node, prop, cells_prop):
        """The providers a phandle list points at: `prop = <&a x y &b z>`, each entry sized by
        the provider's `cells_prop` (#pwm-cells, #thermal-sensor-cells...)."""
        out, v, i = [], node.u32s(prop), 0
        while i < len(v):
            target = self.phandles.get(v[i])
            if target is None:
                out.append(None)
                break
            out.append(target)
            i += 1 + target.u32(cells_prop, 0)
        return out


# ---------------------------------------------------------------------------- the kernel's naming


def addr_cells(node):
    """of_n_addr_cells for a node's children: its own #address-cells, else up the tree, else 1."""
    n = node
    while n is not None:
        v = n.u32("#address-cells")
        if v is not None:
            return v
        n = n.parent
    return 1


def size_cells(node):
    n = node
    while n is not None:
        v = n.u32("#size-cells")
        if v is not None:
            return v
        n = n.parent
    return 1


def join(cells):
    v = 0
    for c in cells:
        v = (v << 32) | c
    return v


def translate(node):
    """of_translate_address of the node's first reg, or None when a bus on the way has no ranges."""
    reg = node.u32s("reg")
    bus = node.parent
    ac = addr_cells(bus)
    if not reg or len(reg) < ac:
        return None
    addr = join(reg[:ac])
    while bus.parent is not None:
        if "ranges" not in bus.props:
            return None
        rng = bus.u32s("ranges")
        if rng:
            c_ac, p_ac, c_sc = addr_cells(bus), addr_cells(bus.parent), size_cells(bus)
            step = c_ac + p_ac + c_sc
            for i in range(0, len(rng) - step + 1, step):
                child = join(rng[i:i + c_ac])
                parent = join(rng[i + c_ac:i + c_ac + p_ac])
                size = join(rng[i + c_ac + p_ac:i + step])
                if child <= addr < child + size:
                    addr = addr - child + parent
                    break
            else:
                return None
        bus = bus.parent
    return addr


def dev_name(node):
    """of_device_make_bus_id: <translated reg>.<name> where the address translates, else the
    node's full name prefixed onto the names below it, walking up."""
    name, n = None, node
    while n.parent is not None:
        addr = translate(n) if "reg" in n.props else None
        if addr is not None:
            mask = n.u32("mask")
            head = f"{addr:x}.{(mask & -mask).bit_length() - 1:x}.{n.base}" if mask else f"{addr:x}.{n.base}"
            return f"{head}:{name}" if name else head
        name = f"{n.name}:{name}" if name else n.name
        n = n.parent
    return name


def led_name(node):
    """led_compose_name for a driver that passes only the fwnode (all of ours)."""
    label = node.string("label")
    if label is not None:
        return label
    color, function, enum = node.u32("color"), node.string("function"), node.u32("function-enumerator")
    if color is not None or function is not None:
        c = LED_COLORS[color] if color is not None and color < len(LED_COLORS) else ""
        return f"{c}:{function or ''}-{enum}" if enum is not None else f"{c}:{function or ''}"
    return node.name


# ------------------------------------------------------------------ what the kernel will register


class Board:
    """Everything the kernel registers on one board, with what keeps a node from registering."""

    def __init__(self, tree):
        self.tree = tree
        self.problems = []   # things on this board that will not register, worth a look
        self.zones = self._zones()
        self.leds = self._leds()
        self.backlights = self._backlights()
        self.supplies = self._supplies()
        self.fans = self._fans()
        self.gpus = self._gpus()

    def _providers_ok(self, node, prop, cells):
        provs = self.tree.refs(node, prop, cells)
        return bool(provs) and all(p is not None and p.available() for p in provs)

    def _zones(self):
        zones = {}
        tz = self.tree.node("/thermal-zones")
        for z in (tz.children if tz else []):
            if not z.available():
                continue
            if len(z.name) >= THERMAL_NAME_LENGTH:
                self.problems.append(f"thermal zone {z.name}: {len(z.name)} characters, the core "
                                     f"refuses {THERMAL_NAME_LENGTH - 1}+")
                continue
            if self._providers_ok(z, "thermal-sensors", "#thermal-sensor-cells"):
                zones[z.name] = z
        return zones

    def _leds(self):
        leds = {}
        registered = set()   # LED nodes that become class devices, for the multicolor groups
        for n in self.tree.root.walk():
            if not n.available():
                continue
            lpg = any(c.startswith("qcom,") and c.endswith(("-lpg", "-pwm")) for c in n.strings("compatible"))
            for c in n.strings("compatible"):
                for name in DRIVER_LEDS.get(c, []):
                    leds[name] = n
            if lpg or n.compatible(*LED_CHIPS):
                for child in n.children:
                    if not child.available() or not any(k in child.props for k in ("label", "color", "function")):
                        continue
                    if n.compatible("pwm-leds") and not self._providers_ok(child, "pwms", "#pwm-cells"):
                        self.problems.append(f"LED {led_name(child)}: its PWM provider is disabled")
                        continue
                    leds[led_name(child)] = child
                    registered.add(child)
                    registered.update(child.children)   # an LPG multi-led's channels
            elif n.compatible("pwm-leds-multicolor"):
                for child in n.children:
                    if not child.available():
                        continue
                    chans = [c for c in child.children if c.available()]
                    if chans and all(self._providers_ok(c, "pwms", "#pwm-cells") for c in chans):
                        leds[led_name(child)] = child
                    else:
                        self.problems.append(f"LED {led_name(child)}: a PWM provider of its channels "
                                             "is disabled, so it never registers")
        for n in self.tree.root.walk():
            if n.available() and n.compatible("leds-group-multicolor"):
                members = [self.tree.phandles.get(p) for p in n.u32s("leds")]
                if members and all(m in registered for m in members):
                    leds[led_name(n)] = n
                else:
                    self.problems.append(f"LED {led_name(n)}: a member LED does not register")
        return leds

    def _backlights(self):
        bls = {}
        for n in self.tree.root.walk():
            if not n.available():
                continue
            if n.compatible("pwm-backlight"):
                if self._providers_ok(n, "pwms", "#pwm-cells"):
                    bls[dev_name(n)] = n
                else:
                    self.problems.append(f"backlight {n.path}: its PWM provider is disabled")
            elif n.compatible(*WLED):
                bls[n.string("label") or n.base] = n
            elif n.compatible("silergy,sy7758"):
                if "enable-gpios" in n.props:
                    bls["sy7758-backlight"] = n
                else:   # mainline sy7758: devm_gpiod_get(dev, "enable") is not optional
                    self.problems.append(f"backlight {n.path}: SY7758 without enable-gpios fails "
                                         "probe, so sy7758-backlight never registers")
            elif n.compatible("ayn,odin2miniled"):
                bls["odin2miniled-backlight"] = n
            elif n.compatible("awinic,aw99706"):
                # mainline aw99706.c: devm_backlight_device_register(dev, "aw99706-backlight", ...)
                bls["aw99706-backlight"] = n
            elif n.parent is not None and n.parent.compatible("qcom,mdss-dsi-ctrl") \
                    and n.strings("compatible") and n.base == "panel":
                compat = n.strings("compatible")[0]
                kind = PANELS.get(compat)
                if kind is None:
                    self.problems.append(f"panel {compat} ({n.path}) is not in PANELS: read its "
                                         "driver and add it")
                elif kind == "dcs":
                    bls[f"{dev_name(n.parent)}.{n.u32('reg', 0)}"] = n
        return bls

    def _supplies(self):
        out = {}
        for n in self.tree.root.walk():
            if not n.available():
                continue
            if n.compatible("qcom,pmic-glink"):
                x86 = n.compatible("qcom,sc8280xp-pmic-glink", "qcom,x1e80100-pmic-glink")
                for name, kind in (BATTMGR_X86 if x86 else BATTMGR):
                    out[name] = kind
            for c in n.strings("compatible"):
                for name, kind in SUPPLIES.get(c, []):
                    out[name] = kind
        return out

    def _fans(self):
        fans = {}
        for n in self.tree.root.walk():
            if not n.available():
                continue
            if n.compatible("pwm-fan") and self._providers_ok(n, "pwms", "#pwm-cells"):
                fans["pwmfan"] = n
            elif n.compatible("gpio-fan"):
                fans["gpio_fan"] = n
        return fans

    def dsi_connectors(self):
        """[(connector, host, panel)] the way msm names them: DSI hosts in address order (the DPU
        makes one encoder per interface, dsi0 first), DSI-1, DSI-2... for each host that drives a
        panel. A host whose sink is a bridge (the Odin 2's lt8912b) makes that bridge's connector
        type instead, and the second host of a bonded pair (qcom,dual-dsi-mode, one panel on both
        links) makes none."""
        out, seen = [], set()
        hosts = [n for n in self.tree.root.walk()
                 if n.compatible("qcom,mdss-dsi-ctrl") and n.available()]
        for host in sorted(hosts, key=lambda n: translate(n) or 0):
            sink = None
            ports = [c for c in host.children if c.base in ("ports", "port")]   # not the panel's own
            for ep in (e for p in ports for e in p.walk()):
                if ep.base != "endpoint" or "remote-endpoint" not in ep.props:
                    continue
                dev = self.tree.phandles.get(ep.u32("remote-endpoint"))
                while dev is not None and dev.base in ("endpoint", "port", "ports"):
                    dev = dev.parent
                if dev is not None and not any(c.endswith("-dpu") for c in dev.strings("compatible")):
                    sink = dev
            if sink is None or sink.base != "panel" or id(sink) in seen:
                continue
            seen.add(id(sink))
            out.append((f"DSI-{len(out) + 1}", host, sink))
        return out

    def primary_backlight(self, connector):
        """The backlight that dims the panel behind `connector`: (name, why) or (None, why)."""
        hit = next(((h, p) for c, h, p in self.dsi_connectors() if c == connector), None)
        if hit is None:
            return None, f"no {connector} on this board"
        host, panel = hit
        compat = (panel.strings("compatible") or ["?"])[0]
        where = f"{connector} = {compat} on {host.name}"
        kind = PANELS.get(compat)
        if kind == "dcs":
            return f"{dev_name(host)}.{panel.u32('reg', 0)}", where
        if kind == "borrows":
            target = self.tree.phandles.get(panel.u32("backlight"))
            name = next((k for k, v in self.backlights.items() if v is target), None)
            return name, f"{where}, which links {target.path if target else 'no backlight'}"
        return None, f"{where}, which names no backlight of its own"

    def _gpus(self):
        return {dev_name(n): n for n in self.tree.root.walk()
                if n.available() and n.compatible("qcom,adreno")}


# ----------------------------------------------------------------------------------- the checks


def check(board, pins):
    """[(field, ok, detail)] for every pin the profile sets."""
    res = []

    def one(field, value, have, what):
        if not value:
            return
        ok = value in have
        res.append((field, ok, value if ok else f"{value}: no such {what}; the board has "
                    f"{', '.join(sorted(have)) or 'none'}"))

    one("RETROFORGE_HW_BATTERY", pins.get("RETROFORGE_HW_BATTERY"),
        {k for k, v in board.supplies.items() if v == "battery"}, "battery")
    one("RETROFORGE_HW_CHARGER", pins.get("RETROFORGE_HW_CHARGER"),
        {k for k, v in board.supplies.items() if v == "charger"}, "charger")
    one("RETROFORGE_HW_BACKLIGHT", pins.get("RETROFORGE_HW_BACKLIGHT"), board.backlights, "backlight")
    bl, conn = pins.get("RETROFORGE_HW_BACKLIGHT"), pins.get("RETROFORGE_PRIMARY_CONNECTOR") or ""
    if bl and bl in board.backlights and conn.startswith("DSI-"):
        want, why = board.primary_backlight(conn)
        if want is not None:   # a primary panel with no backlight of its own leaves nothing to compare
            res.append(("RETROFORGE_HW_BACKLIGHT:primary", want == bl,
                        f"{bl} dims {why}" if want == bl else
                        f"{bl} is not the primary panel's backlight: {why} -> {want}"))
    for role in ("CPU", "GPU", "BATTERY", "SKIN"):
        one(f"RETROFORGE_HW_THERMAL_{role}", pins.get(f"RETROFORGE_HW_THERMAL_{role}"), board.zones,
            "thermal zone")
    one("RETROFORGE_HW_FAN", pins.get("RETROFORGE_HW_FAN"), board.fans, "fan")
    one("RETROFORGE_HW_GPU_DEVFREQ", pins.get("RETROFORGE_HW_GPU_DEVFREQ"), board.gpus, "GPU devfreq")
    for spec in (pins.get("RETROFORGE_HW_LED_GROUPS") or "").split():
        group, _, globs = spec.partition("=")
        hits = sorted({l for g in globs.split(",") for l in board.leds if fnmatch.fnmatchcase(l, g)})
        res.append((f"RETROFORGE_HW_LED_GROUPS:{group}", bool(hits),
                    f"{group}={len(hits)} LEDs" if hits else
                    f"{group}={globs} matches no LED; the board has "
                    f"{', '.join(sorted(board.leds)) or 'none'}"))
    return res


def device_env(model, device_dir=DEVICE_DIR):
    """The pins a board with this model gets, from the real device-env."""
    script = 'eval "$("$1")"; for v in $(compgen -v RETROFORGE_); do printf "%s=%s\\0" "$v" "${!v}"; done'
    env = dict(os.environ, RETROFORGE_MODEL=model, RETROFORGE_DEVICE_DIR=str(device_dir))
    out = subprocess.run(["bash", "-c", script, "_", str(DEVICE_ENV)], env=env, check=True,
                         capture_output=True).stdout.decode()
    return dict(kv.split("=", 1) for kv in out.split("\0") if "=" in kv)


def read_xfail(path):
    known = {}
    for line in (path.read_text().splitlines() if path.exists() else []):
        line = line.strip()
        if line and not line.startswith("#"):
            board, field, reason = (line.split(None, 2) + ["", ""])[:3]
            known[(board, field)] = reason
    return known


# --------------------------------------------------------------------------------- DTB sources


DT_PATHS = ("arch/arm64/boot/dts/", "include/dt-bindings/")


def dts_patch_hunks(patch):
    """The parts of a kernel patch that touch the devicetree sources or their binding headers,
    as one diff. Git and plain unified diffs both: a file starts at `diff --git` or at a
    `---`/`+++` pair, whose path is taken without its first component (a/, linux/, ...)."""
    lines = patch.splitlines(keepends=True)
    keep, out = False, []
    for i, line in enumerate(lines):
        if line.startswith("diff --git "):
            keep = any(f" a/{d}" in line or f" b/{d}" in line for d in DT_PATHS)
        elif line.startswith("--- ") and i + 1 < len(lines) and lines[i + 1].startswith("+++ "):
            path = lines[i + 1][4:].split("\t")[0].strip()
            if path == "/dev/null":
                path = line[4:].split("\t")[0].strip()
            keep = path.split("/", 1)[-1].startswith(DT_PATHS)
        if keep:
            out.append(line)
    return "".join(out)


def compile_dtbs(linux, work):
    """kernel/build.sh's devicetree half, on the host: Linux's qcom dts dir, RetroForge's patches'
    devicetree hunks applied in order, RetroForge's own dts/dtsi on top, cpp + dtc per board."""
    tree = work / "linux"
    qcom = tree / "arch/arm64/boot/dts/qcom"
    shutil.copytree(linux / "arch/arm64/boot/dts/qcom", qcom)
    shutil.copytree(linux / "include/dt-bindings", tree / "include/dt-bindings")
    shutil.copytree(linux / "scripts/dtc/include-prefixes", tree / "scripts/dtc/include-prefixes",
                    symlinks=True)
    warnings = []
    for p in sorted((ROOT / "kernel/patches").glob("*.patch")):
        hunks = dts_patch_hunks(p.read_text(errors="replace"))
        if not hunks:
            continue
        r = subprocess.run(["patch", "-p1", "--forward", "--batch", "-s", "-d", str(tree)],
                           input=hunks.encode(), capture_output=True)
        if r.returncode:
            warnings.append(f"{p.name}: its devicetree hunks do not apply to {linux}")
    for f in (ROOT / "kernel/dts/qcom").iterdir():
        shutil.copy(f, qcom / f.name)
    cc = os.environ.get("CC", "cc")
    out = work / "dtbs"
    out.mkdir()
    failed = []
    for dts in sorted((ROOT / "kernel/dts/qcom").glob("*.dts")):
        pre = work / (dts.stem + ".pp")
        steps = ([cc, "-E", "-nostdinc", "-undef", "-D__DTS__", "-x", "assembler-with-cpp",
                  "-I", str(qcom), "-I", str(tree / "include"),
                  "-I", str(tree / "scripts/dtc/include-prefixes"),
                  "-o", str(pre), str(qcom / dts.name)],
                 ["dtc", "-q", "-I", "dts", "-O", "dtb", "-o", str(out / (dts.stem + ".dtb")),
                  str(pre)])
        for step in steps:
            r = subprocess.run(step, capture_output=True, text=True)
            if r.returncode:
                err = next((l for l in r.stderr.splitlines() if "error" in l.lower()),
                           r.stderr.strip().splitlines()[-1] if r.stderr.strip() else "?")
                failed.append(f"{dts.name} does not compile: {err.replace(str(work) + '/', '')}")
                break
    return out, warnings, failed


# ------------------------------------------------------------------------------------------ main


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    src = ap.add_mutually_exclusive_group(required=True)
    src.add_argument("--dtbs", type=Path, help="a directory of built DTBs (out/dtbs)")
    src.add_argument("--linux-src", type=Path, help="a Linux tree to compile kernel/dts/qcom against")
    ap.add_argument("--xfail", type=Path, default=XFAIL)
    ap.add_argument("--device-dir", type=Path, default=DEVICE_DIR, help=argparse.SUPPRESS)
    ap.add_argument("-v", "--verbose", action="store_true", help="list what each board registers")
    args = ap.parse_args(argv)

    with tempfile.TemporaryDirectory(prefix="check-hw-paths.") as tmp:
        notes, broken = [], []
        if args.linux_src:
            dtbs, notes, broken = compile_dtbs(args.linux_src.resolve(), Path(tmp))
        else:
            dtbs = args.dtbs
        for n in notes:
            print(f"note: {n}")
        for b in broken:
            print(f"FAIL {b}")
        if not sorted(dtbs.glob("*.dtb")):
            print(f"no DTBs in {dtbs}: run `make kernel`, or pass --linux-src <a Linux tree>")
            return 2
        known = read_xfail(args.xfail)
        seen, failed, xfails = set(), len(broken), 0
        for dtb in sorted(dtbs.glob("*.dtb")):
            tree = Tree(dtb.read_bytes())
            board = Board(tree)
            pins = device_env(tree.model or "", args.device_dir)
            pid = pins.get("RETROFORGE_DEVICE_ID", "unknown")
            if pid == "unknown":
                print(f"FAIL {dtb.name}: model {tree.model!r} has no device profile")
                failed += 1
                continue
            lines = []
            for field, ok, detail in check(board, pins):
                key = (pid, field)
                seen.add(key)
                if key in known:
                    if ok:
                        lines.append(f"  XPASS {field}: {detail} -- remove it from {args.xfail.name}")
                        failed += 1
                    else:
                        lines.append(f"  xfail {field}: {detail} ({known[key]})")
                        xfails += 1
                elif not ok:
                    lines.append(f"  FAIL  {field}: {detail}")
                    failed += 1
                elif args.verbose:
                    lines.append(f"  ok    {field}: {detail}")
            for p in board.problems:
                lines.append(f"  note  {p}")
            if args.verbose:
                lines.append(f"  has   backlights: {', '.join(sorted(board.backlights)) or '-'}; "
                             f"supplies: {', '.join(sorted(board.supplies)) or '-'}; "
                             f"fans: {', '.join(sorted(board.fans)) or '-'}; "
                             f"gpu: {', '.join(sorted(board.gpus)) or '-'}; "
                             f"{len(board.leds)} LEDs, {len(board.zones)} zones")
            bad = any(l.startswith(("  FAIL", "  XPASS")) for l in lines)
            print(f"{'FAIL' if bad else 'ok  '} {pid} ({dtb.name})")
            for l in lines:
                print(l)
        for key in sorted(set(known) - seen):
            print(f"FAIL {args.xfail.name}: {key[0]} {key[1]} names no check that ran")
            failed += 1
        print(f"\n{len(seen)} pins checked, {failed} failed, {xfails} known gaps")
        return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
