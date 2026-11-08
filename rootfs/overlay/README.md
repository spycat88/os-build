# rootfs/overlay — the unified rootfs overlay payload

Every SoC-agnostic file that retroforge lays over the base rootfs lives here, in **one tree that
mirrors the target filesystem exactly**. `rootfs/assemble-rootfs.sh` injects it with a single
`cp -a rootfs/overlay/. "$stage/"` (the `overlay-payload` stage). The tree carries final paths, executable
bits (tracked in git), and the systemd presets + `*.target.wants` symlinks that enable each
service — so the assembler generates and `chmod`s nothing. Ownership is normalized to `root:root`
afterwards (the `overlay-ownership` stage).

Every file lands at a unique target path; the layers below are a way of reading the tree, not
separate trees.

## Layers (what each backing does, and why)

**Input — `etc/inputplumber/`** (part of every build)
InputPlumber's device/profile config: the union of every supported board's config. InputPlumber
matches by hardware, so non-matching configs are inert. It overrides the package's
`/usr/share/inputplumber` defaults ONLY via the `.d` dirs it scans under `/etc` — composite
configs in `devices.d/` and capability maps in `capability_maps.d/`. Do **not** rename them to the
un-suffixed `devices`/`capability_maps` (those apply only under `/usr/share`) or the configs load
from nowhere and no composite device is built. Enabled by a shipped
`usr/lib/systemd/system-preset/60-retroforge.preset` (60 < the stock 99 "disable *") plus a
`multi-user.target.wants/inputplumber.service` symlink.

**Session — gamescope-session plumbing**
The boot-to-compositor path: launcher `/usr/bin/retroforge-session` + its `/etc/retroforge/session.conf`,
`retroforge-session.service` (systemd logs `player` in through its own PAM stack — no display
manager), and `default.target -> graphical.target`. The device boots straight into it, giving a REAL active `seat0` logind session (so stock polkit authorizes
Wi-Fi/timezone). `seatd.service` stays enabled as an unused fallback; gamescope takes the seat
through logind. The shell gamescope hosts is `RETROFORGE_SESSION_CMD` in `session.conf` (a `vkcube`
liveness placeholder until OpenGamepadUI lands), plus `RETROFORGE_GAMESCOPE_SHELL_ARGS` for the
gamescope flags that shell needs.

**HW-support — Qualcomm backings for handheld affordances**
`retroforge-rest` (userspace "rest mode"/fake-suspend), the suspend engine (a `systemd-suspend.service`
drop-in redirects logind `Suspend()` into `retroforge-suspend`; `retroforge-powerbuttond` runs a
configurable short/long-press action, suspend and power-off by default), the power-policy daemon
`retroforge-powerd`, the key-pairing agent `retroforge-pairingd`, Bluetooth, and `systemd-timesyncd`.
All enabled via shipped presets + `*.target.wants` symlinks. No Wi-Fi resume hook ships (NM
re-associates unaided). `etc/systemd/system/systemd-rfkill.{service,socket} -> /dev/null`: the
suspend engine soft-blocks the radios, and systemd-rfkill would save that block and restore it at the
next boot (see `_pow_rf_enter` in `usr/lib/retroforge/power-ops.sh`); `99-zz-retroforge-rfkill.rules`
drops udev's want for the masked socket.

**Update and storage entry points**
`usr/bin/retroforge-update` is the OS update client (RAUC), including its channel picker
(`channels` / `set-channel`); `usr/bin/retroforge-format-sdcard` / `retroforge-format-device` pkexec into
`usr/lib/retroforge/storage/format-device.sh`. `50-retroforge-timezone.rules` is the one polkit grant
stock polkit still prompts for in the seat session; `50-retroforge-power.rules` lets wheel (player)
reboot, power off and suspend from an ssh login too, where stock logind policy wants a password.

**Audio — ALSA UCM2 machine profiles**
`usr/share/alsa/ucm2/Qualcomm/sm8{250,550,650}/<CARD>/` profiles, card-name-matched via relative
symlinks under `conf.d/sm8{250,550,650}/` (preserved by `cp -a`). They `Include` codec snippets that
the base `alsa-ucm-conf` package must provide (SM8550 uses wcd938x, SM8650 wcd939x, SM8250 wcd938x
plus wsa881x or AW88166 for speakers). One snippet is NOT in that package and ships here instead:
`ucm2/codecs/wsa881x/init.conf`, without which the two wsa881x amps expose no stereo `Speakers
Volume` control for the SM8250 profiles to bind to. The SM8250 boards also route through the legacy
q6asm/ADM path rather than AudioReach, and the AYN Thor Lite additionally needs
`usr/share/wireplumber/wireplumber.conf.d/51-ayn-thor-lite.conf` to pin its PCMs to S16LE — the ADM
COPP is a bit-exact passthrough and UCM has no key for the sample format.

DisplayPort audio on SM8250 is its own UCM verb, `ucm2/Qualcomm/sm8250/DisplayPort.conf`, never a
device in HiFi: with no display attached the ADSP refuses the DP port, and one PCM that cannot open
makes PipeWire reject the whole verb it sits in. The Retroid profile enables it; the Pocket Max
profile has it commented out, because probing it undocked delays sound by ~16 s at every boot. The
Pocket Max's `52-pocket-max-dp.conf` (S16LE, fixed periods, no mmap on `hw:PocketMax,3`) is dormant
until that verb returns.

**System hygiene — identity, memory, and the `/var` shape**
Files that are not a subsystem but are load-bearing for the immutable A/B model, because on
this image `/etc/passwd` and `/var` are *build products* rather than device state:

- `usr/lib/sysusers.d/01-retroforge-enforce-ids.conf` — pins every system UID/GID that
  `systemd-sysusers` would otherwise allocate by counting down from 999. Adding one package with a
  sysusers entry shifts every id below it, and the RAUC post-install hook copies `/var` wholesale
  across an update, so drifting ids reassign the ownership of persisted state. **This file is also
  read by `rootfs/customize-base.sh`**, which stages it into the target root *before* the pacman
  transaction — the pin only works if it is there when the sysusers hook runs. Its sha is in the
  base reuse key, and `rootfs/guard-rootfs.sh` assertion 8 checks the built tree against it. There
  is no end-of-line comment syntax in sysusers.d; a trailing `#` silently rejects the line.
- `usr/lib/tmpfiles.d/retroforge-var.conf` — declares the `/var` hierarchy in the ROOT. A fresh flash
  gets `/var` from the build; an *updated* slot gets the previous version's `/var`, so a directory a
  new version needs has to be asserted at boot or it will not exist. New `/var` paths go here.
- `usr/lib/systemd/system/earlyoom.service.d/retroforge.conf` — OOM policy: absolute thresholds
  (RAM spans 8–16 GB across supported SKUs, so percentages mean different headroom per unit),
  reports off (the default is one journal line per second, onto an SD card), and the session spine
  protected. Enabled by `60-retroforge-earlyoom.preset` + a `multi-user.target.wants` symlink.
- `usr/lib/systemd/system/user@.service.d/10-retroforge-oom.conf` and the spine's
  `usr/lib/systemd/user/{pipewire,pipewire-pulse,wireplumber,dbus-broker}.service.d/10-retroforge-oom.conf`
  — the same victim order for the kernel's OOM killer, which MGLRU's `min_ttl_ms` guard
  (`usr/lib/tmpfiles.d/retroforge-mm.conf`) calls long before earlyoom acts: the spine at the
  session's 0 instead of systemd's 200, so a game (900 on every launch path) goes first.
- `usr/lib/systemd/zram-generator.conf` — the image's only swap device, `min(ram, 8192)` compressed in RAM
  with zstd level 1 (lz4 first ran Hades out of memory on the 3.5 GB Air X; the file says why).
  **Coupled to the kernel:** it needs `CONFIG_ZRAM` + the zstd backend, which `kernel/build.sh`
  asserts, because without them there is no `zram0`, no swap, and no error.

**PortMaster's `/roms` — `roms -> /home/player/roms`**
The only top-level symlink in the tree. PortMaster (downloaded into the player's home from
Main menu > Emulators) and every port script it installs locate themselves through hardcoded
`/roms/ports/...` paths (PortMaster's generic default when the system is not one of its known
handheld firmwares). The link points them at the player's `~/roms`, so PortMaster lives in
`~/roms/ports/PortMaster` and its ports in `~/roms/ports` with no change to PortMaster's own files,
which its self-updates would overwrite. The overlay-ownership stage resets it to root (`-h`).

**Game-time quiet — keeping background work off a game's CPUs**
- `usr/lib/retroforge/cpu-affinity.conf` + `usr/lib/systemd/system-generators/retroforge-cpu-affinity`
  — `CPUAffinity` by CLASS, resolved per device at every boot from `cpu_capacity`, so a new SoC
  layout needs no edit. `interactive` (the services a game talks to: InputPlumber, PowerStation,
  `retroforge-powerbuttond`) = every CPU outside the prime cluster; `background`
  (`retroforge-powerd`, `-pairingd`, `-power-led`) = the little cluster. Today: SM8250 0-6 / 0-3,
  SM8550 0-6 / 0-2, SM8650 0-6 / 0-1, SM6115 0-3 / 0-3 and SM4450 0-5 / 0-5 (their big cores
  share one level, so there is no prime core to keep free). Both always contain cpu0, the one CPU
  the suspend engine never offlines; uniform cores get no drop-in at all. The generator writes
  `/run/systemd/generator/<unit>.d/50-retroforge-cpus.conf` (`systemctl cat <unit>` shows it).
  Affinity is inherited by a service's whole process tree. `tests/test-cpu-affinity.sh` drives it
  against fabricated topologies.
- `etc/systemd/system/{shadow,archlinux-keyring-wkd-sync,man-db}.timer -> /dev/null` — Arch
  maintenance timers with nothing to do on an image OS (users and groups are pinned at build time,
  release images carry no pacman keyring, man-db is not installed), which can otherwise fire in
  the middle of a game. `man-db.timer` is masked ahead of time, in case a dependency pulls man-db in.
