# Installing to internal storage

RetroForge normally runs from the SD card you flashed it to. **Settings > General > Internal
storage** puts it on the device's own internal storage instead, alongside Android, so the device boots
with no card in it.

> **Using the free slot as a ROM library is not wired up yet.** A hot-inserted card is mounted through
> udisks by the storage scripts under `/usr/lib/retroforge/storage/`, but no shell uses it as a
> library yet.

The installer is part of the card's own OS. It downloads the latest release from the channel picked in
**Updates**, from the same host `retroforge-update` uses, so there has to be a bundle published in that
channel ([ota.md](ota.md)). The card's OS itself is not copied. Connect to Wi-Fi in Settings first.

- [What it does to the device](#what-it-does-to-the-device)
- [The install, step by step](#the-install-step-by-step)
- [When it refuses](#when-it-refuses)
- [When it fails](#when-it-fails)
- [How it runs](#how-it-runs)
- [Testing it on a dev card](#testing-it-on-a-dev-card)
- [What it deliberately does not do](#what-it-deliberately-does-not-do)

---

## What it does to the device

**Android stays bootable and arrives factory-reset.** The bootloader on these handhelds is a chooser,
so the device keeps both systems.

**Android's user data is destroyed.** Apps, saves, photos: everything in its `userdata` partition.
There is no way around it: `userdata` cannot be shrunk in place, so the installer deletes it, recreates
it at the size you choose, and appends RetroForge's eight partitions into the space that frees. You
choose how much Android keeps, on screen, before anything is written.

**Nothing outside that span is touched.** The safety property is geometric, not a list of names: every
sector the installer writes falls inside the old `userdata`'s extent or in space that was already
unallocated. The firmware partitions (`xbl`, `abl`, `devinfo`, `super`, every OEM one) sit outside it
and are safe by construction, on any layout, including boards nobody has captured.

**RetroForge on your SD card is not touched.** Its partitions are refused as a target outright, and
the new `/home` starts empty: games and saves on the card do not come across.

**Your Wi-Fi networks do come across.** Every Wi-Fi profile NetworkManager has on the card (the
networks joined in Settings, and a dev card's baked-in one) is copied into the new slot's `/etc`
overlay, so the first internal boot joins the same network. Other connection types are left behind.
This is best-effort: a profile that cannot be copied is logged, and the install carries on.

**On a device that already runs RetroForge internally**, the installer replaces it completely,
**including `/home`**. A repair that keeps `/home` is not offered yet; the pre-flight screen says so.

---

## The install, step by step

1. **Settings > General > Internal storage > Install.** The row appears only when the device booted
   from a card. It asks the update server what it would install, and stops here if it cannot find out.
2. **Confirmation dialog.** It names the version and says RetroForge closes. Nothing is erased yet.
3. **Pre-flight.** The session ends and the installer takes the panel: the target disk, its model and
   size, what Android keeps (**left/right to change**), what RetroForge gets, **every partition that
   will be destroyed, by index and name**, and what will be downloaded. Every figure is measured by the
   same programs that will act on it.
4. **Consent.** A random four-button sequence, drawn as positions on a diamond and echoed back. The
   buttons are named by **position**, never by letter: `A` is a different physical button on an AYANEO
   Pocket ACE than on a Pocket S2. A wrong press re-randomises rather than locking you out. **SELECT
   aborts**, and it is never part of a sequence.
5. **Progress.** The spine's own steps, with the download percentage read off its output.
6. **Done.** Power off, remove the card, power on. It boots from internal storage from then on, with
   or without the card.

Nothing is written to the disk until after step 4. The bundle is verified *before* consent is asked,
so a download that will not verify costs you nothing. Cancel and Restart both reboot, back into the
card if the install did not finish.

Once an internal install exists, **Linux mode boots it and not the card: internal wins.** The
bootloader's **force external** option is the way back to the card, and to this installer. The very
last byte the installer writes is the internal bootloader entry, so an interrupted install still boots
the card.

---

## When it refuses

The installer picks its own target and will not be argued with. What it says, and what it means:

| On screen | Why |
|---|---|
| `partition N (ROCKNIX) is a bootable ESP that is not ours` | Another distribution is installed on that disk. Remove it first: the installer will not take a disk it does not understand. |
| `no partition named 'userdata' -- this board is not supported yet` | Nothing on the disk is safe to shrink. |
| `userdata and the free space after it total N GiB` | Not enough room for both Android and RetroForge. |
| `sgdisk reports GPT problems` / `the GPT is damaged or absent` | The partition table is not readable. A damaged table is refused rather than repaired: "damaged" and "a layout we do not understand" cannot be told apart from here. |
| `a process of the session user is still running` | Something of `player`'s survived the session ending, and it could answer the consent screen. Restart and try again. |

A refusal always names the disk and the reason. There is no override flag, deliberately.

---

## When it fails

The screen says which of two states the device is in: nothing was written, or the disk was modified
and Android's data is gone. **Try again** re-runs from the top; it takes no backups, so a second run is
designed to be the recovery. **Restart** goes back to the card's own session, where you can reconnect
to Wi-Fi and start again from Settings.

The log is `/var/log/retroforge/install.log` on the card, written when the installer's unit stops: the
build identity, the installer's journal, NetworkManager's, the kernel ring and the install record. A
paired computer can read it over SSH (`player` can read it; [remote-access.md](remote-access.md)).

---

## How it runs

`retroforge-installer.service` runs as root; OGUI stays `player`. The one privileged step is
`50-retroforge-installer.rules`, which lets the active local session `start` that one unit. The unit has
no arguments and no `[Install]`. It runs gamescope with `installer/ui` as its only client, and it
reboots on every stop, except a finished install, which powers off.

**`player` must not outlive the session.** It lingers, it is in `input` so it can open `/dev/uinput`,
InputPlumber's bus takes calls from anyone, and the sequence is on `confirm-ui`'s command line, so a
leftover process could read the sequence and press it. The unit therefore conflicts with
`user@1000.service`, closes logins with `/run/nologin`, and ends every session of the user; the spine
then refuses to ask for consent if a process of that uid is alive.

The components live in `installer/` and ship into `/usr/lib/retroforge/install/`, listed in
`installer/shipped-files`. `rootfs/guard-rootfs.sh` checks a release root against that list and against
every tool the install path calls. `tests/test-installer-shipped.sh` checks the lists themselves.

---

## Testing it on a dev card

A dev image (`RETROFORGE_MODE=dev` in `/etc/retroforge-release`) installs **itself**: it does not ask
the update server. `release-info` answers with the root the card booted from
(`BUNDLE=running:<device>`), and `retroforge-install` copies that slot into root-a byte for byte, up to
the filesystem's size, then runs the same handler a bundle install does (`post-install-fresh.sh`
re-randomises the fsid and seeds var-a). Before the carve it checks that the device is the mounted
root, holds btrfs, and fits root-a. Only the OS slot is copied: `/home` is staged empty and `/var`
comes from the image's seed, exactly as with a bundle. The dev keyring and the `dev` channel pin
come along, so the installed device takes later dev bundles as updates.

To test a bundle instead, serve it (rauc streams it over NBD and needs `Range`, so
nginx, not `python3 -m http.server`) and name it to the unit:

```bash
make bundle
docker run --rm -p 8088:80 -v "$PWD/out/images:/usr/share/nginx/html:ro" nginx:alpine
```

```bash
# on the device, as root
systemctl edit retroforge-installer.service --stdin <<'CONF'
[Service]
Environment=RETROFORGE_INSTALL_BUNDLE=http://<host>:8088/<bundle>.raucb
CONF
```

Then use the Settings row. A dev card keeps root SSH while the installer runs, and the spine can be
driven from a root shell with `RETROFORGE_CONFIRM=/usr/lib/retroforge/install/confirm-tty` once the
session is stopped.

`installer/probe-internal.sh` is the read-only recon for a new board.

---

## What it deliberately does not do

- **No repair that keeps `/home`.** A disk that already carries RetroForge gets a full replacement.
- **No backups.** A plain-text record of the pre-state goes into the log, best-effort, and it never
  blocks an install.
- **No target override.** The disk is chosen by the rules above or the install does not happen.
- **No network setup.** It starts from Settings, where Wi-Fi already is.

---

## See also

- [ota.md](ota.md) — the update server and the channels
- [internal-storage.md](internal-storage.md) — the captured partition layouts these rules were
  derived from
- [RUNBOOK.md](RUNBOOK.md#recovery-when-it-does-not-boot) — recovery for a device that will not boot
