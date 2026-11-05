# Installing to internal storage

RetroForge normally runs from the SD card you flashed it to. The **installer medium** puts it on the
device's own internal storage instead, alongside Android — so the device boots with no card in it,
and the slot is free.

> **Using that free slot as a ROM library is not wired up yet.** A hot-inserted card is mounted
> through udisks by the storage scripts under `/usr/lib/retroforge/storage/`, but no shell uses it as a
> library yet; that arrives with the shell.

> **A medium can only install once a `stable` bundle has been published.** The installer downloads
> the OS from the same host `retroforge-update` uses, `https://ota.retroforge.org` — written into
> `installer/netcfg`, `installer/release-info` and `retroforge-update`, which `tests/test-ui.sh`
> asserts agree. Until a bundle is in the bucket the pre-flight screen reports nothing published in
> the channel. Media built before 2026-10-13 carry the never-resolving placeholder
> `updates.retroforge.invalid` and stop at "could not be resolved (DNS)". The bucket is described in
> [ota.md](ota.md).

It is a separate image from the card: a self-contained recovery tool that boots on the handheld,
draws its own screens on the panel, and is driven with the gamepad. It downloads the current RetroForge
release while you watch — the OS is the only thing it needs from the network — and gives the new
`/home` an empty `player` home, laid out by the same `image/lib-homestage.sh` a card uses.

- [What it does to the device](#what-it-does-to-the-device)
- [Before you boot it](#before-you-boot-it)
- [The install, screen by screen](#the-install-screen-by-screen)
- [When it refuses](#when-it-refuses)
- [When it fails](#when-it-fails)
- [Cutting a release](#cutting-a-release-maintainers)
- [Building one by hand](#building-one-by-hand)
- [What it deliberately does not do](#what-it-deliberately-does-not-do)

---

## What it does to the device

**Android stays bootable and arrives factory-reset.** The bootloader on these handhelds is a
chooser, so the device keeps both systems.

**Android's user data is destroyed.** Apps, saves, photos — everything in its `userdata` partition.
There is no way around it: `userdata` cannot be shrunk in place, so the installer deletes it,
recreates it at the size you choose, and appends RetroForge's eight partitions into the space that
frees. You choose how much Android keeps, on screen, before anything is written.

**Nothing outside that span is touched.** The safety property is geometric, not a list of names:
every sector the installer writes falls inside the old `userdata`'s extent or in space that was
already unallocated. The firmware partitions (`xbl`, `abl`, `devinfo`, `super`, every OEM one) sit
outside it and are safe by construction, on any layout — including boards nobody has captured.

**Your SD card is never written to.** Removable media is refused as a target outright.

**On a device that already runs RetroForge**, the installer replaces it completely, **including
`/home`** — your games, saves and settings. A repair that keeps `/home` is not offered yet; the
pre-flight screen says so in as many words rather than implying otherwise.

---

## Before you boot it

### 1. Write the medium

```bash
curl -LO https://<the URL from the release>/installer.img.gz
gzip -dc installer.img.gz | sudo dd of=/dev/sdX bs=4M status=progress conv=fsync
```

Check it against the release's `installer.img.gz.sha256` first (`sha256sum -c installer.img.gz.sha256`). The medium is sized to its content rather
than to a card, so the card only has to be big enough to hold it.

### 2. Put your Wi-Fi on it — this is the mechanism, not a fallback

**The installer downloads RetroForge over the network and cannot ask you for a password.** These
devices have no keyboard and no guaranteed touchscreen, so the credentials come from a file you
write on another computer, before you boot.

Plug the card into a PC or Mac. Its first partition mounts as **RFINSTALLER** — a plain FAT volume,
deliberately *not* an EFI System Partition, because Windows and macOS hide those. Inside it:

```
retroforge/wifi.conf.example     <- copy this
retroforge/wifi.conf             <- to this, and edit it
```

```ini
SSID=my-network
PSK=my-password
```

Notepad is fine — the parser strips the carriage returns it adds. The password is used once, is
never displayed, never logged, and never reaches the installed system.

**A USB-C Ethernet adapter needs no file at all** and is the zero-config path.

Getting this wrong costs a power-off, a card pull and an edit on another computer, which is why the
installer names *which* step failed rather than saying "network failed".

### 3. Boot from the card

Put the card in and select **Linux** in the bootloader menu. Linux mode tries **internal first** and
falls back to the card, and the test is on what is actually there — so on a device that has only
ever run Android there is nothing internal to find and it boots the card unaided.

**On a device that already has RetroForge (or another Linux) on its internal storage, the card is not
picked up: internal wins.** Use the bootloader's **force external** option. That is the recovery
procedure for an internal install, and it is the only way back to the installer once one exists.

One consequence worth knowing if an install is interrupted: the very last byte the installer writes
is the internal bootloader entry. Before that point the device still boots the card and you can
simply run it again; after it, internal wins and you need force external.

---

## The install, screen by screen

1. **Board menu** — pick your handheld. The medium travels between boards and deliberately
   remembers nothing, so it asks every time; a remembered choice is a card that installed one
   device preselecting the wrong devicetree on the next.
2. **Network** — one failure at a time, each with its own fix: no settings file, an unreadable one
   (naming the offending line), the network not found, the password rejected, no address offered,
   the clock not set yet, or the update server unreachable. The screen re-checks itself every few
   seconds, so the states that resolve on their own — joining, waiting for an address, waiting for
   the clock to be set from the network — move on with no press. A wired adapter plugged in at any
   point is noticed the same way.
3. **Pre-flight** — the target disk, its model and size, what Android keeps (**left/right to
   change**), what RetroForge gets, **every partition that will be destroyed, by index and name**, and
   what will be downloaded (the release version, its size, and the host it comes from). Every figure
   here is measured by the same programs that will act on it, never derived a second time.
4. **Consent** — a random four-button sequence, drawn as positions on a diamond and echoed back.
   The buttons are named by **position**, never by letter: `A` is a different physical button on an
   AYANEO Pocket ACE than on a Pocket S2. A wrong press re-randomises rather than locking you out.
   **SELECT aborts**, and it is never part of a sequence.
5. **Progress** — the spine's own steps, with the download percentage read off its output.
6. **Done** — remove the card and power off. It boots from internal storage from then on.

Nothing is written to the disk until after step 4. The bundle is downloaded and verified *before*
consent is asked — so a download that will not verify costs you nothing.

---

## When it refuses

The installer picks its own target and will not be argued with. What it says, and what it means:

| On screen | Why |
|---|---|
| `removable media is never an install target` | That is the card you booted from. |
| `partition N (ROCKNIX) is a bootable ESP that is not ours` | Another distribution is installed on that disk. Remove it first — the installer will not take a disk it does not understand. |
| `no partition named 'userdata' -- this board is not supported yet` | Nothing on the disk is safe to shrink. |
| `userdata and the free space after it total N GiB` | Not enough room for both Android and RetroForge. |
| `sgdisk reports GPT problems` / `the GPT is damaged or absent` | The partition table is not readable. A damaged table is refused rather than repaired: "damaged" and "a layout we do not understand" cannot be told apart from here. |
| *(no target at all, on a device booted from internal storage)* | The disk the running system is on is never a candidate. Boot from the card. |

A refusal always names the disk and the reason. There is no override flag, deliberately.

---

## When it fails

**Power-cycle the device, pull the card, and read `retroforge-install.log`** in the root of the
RFINSTALLER partition on any computer.

The log is written when the installer's unit *stops*, so a running installer has not produced one
yet — that is why the power-cycle comes first. It carries the medium's own build identity in its
first line, the installer's journal, NetworkManager's (the association and the DHCP transaction),
the kernel ring, and the install record.

If the installer itself could not start, the panel drops to a console showing the tail of that same
log and naming where the full copy is.

To boot the medium without its GUI — a shell on tty1 instead — add `retroforge.install.debug` to the
kernel command line from the boot menu.

**A failure after consent leaves a device that is not bootable into either OS.** The installer says
which of the two states it is in, keyed on whether it reached the carve. Re-running it is the
recovery: it takes no backups (a backup that cannot be restored on the same medium is a promise it
cannot keep), so a second run is designed to be the answer.

---

## Cutting a release (maintainers)

**One workflow: `release`.** Tag `v1.2.3`, or dispatch it with `publish: false` for a test build. It
builds the installer and the SD card side by side and cuts them as one `RetroForge v1.2.3` release.

```
prep  ->  installer + sdcard  ->  release
          |                       |
          |                       GitHub Release <version> ("RetroForge <version>"):
          |                       installer.img.gz + .sha256, sdcard.img.gz + .sha256
          make installer + make verify-image (and make sdcard, in parallel)
```

**A new OS release does not need a new medium.** The bundle is resolved from the channel at install
time, so any medium installs the current OS — that is why an old medium is never an old install. A
medium is cut when the installer itself changes.

One protected environment, one approval: *may this medium become a release*. Nothing here is
signed — a medium is flashed over USB by someone holding the device.

---

## Building one by hand

```bash
make installer      # bootstraps the installer root, then lays the medium
make verify-image   # -> out/images/installer.img
```

`make installer` builds its own root from `installer/pkgs.list` and `installer/manifest.lock` — the
installer carries partition and filesystem tools no device ever gets, so it has a lock of its own
(`make relock-installer` regenerates it).

`make verify-image` is the only thing that opens the built image — everything in `make test` reads
the scripts, and a script that says the right thing while producing the wrong image passes all of
it. It checks the partition table, the boot partition, that the boot config addresses *this* image's
PARTUUID, the root, the build identity, and whether the medium can actually install: every file the
install path resolves at runtime, and the session unit being enabled while the `OnFailure=` console
unit is not. It also refuses a release medium pinned to a channel other than `stable`
(`RETROFORGE_OTA_CHANNEL` at `mkroot.sh` time writes that pin into the medium's `/etc/retroforge/ota.conf`).

**A dev medium fails verification** unless you pass `RETROFORGE_INSTALLER_ALLOW_DEV=1`, because it
bakes an `authorized_keys` and a Wi-Fi PSK and must never be the one that gets published. Build one
with `source dev.env` — it is what makes live diagnosis over SSH possible on a hardware trip.

**Read-only rehearsals against a real device**, both of which stage the tools onto a dev card over
SSH and touch nothing:

```bash
installer/hw-select-target.sh root@<device>   # which disk would it choose, and why
installer/hw-preflight.sh     root@<device>   # the actual pre-flight screen, on that board's geometry
installer/hw-install.sh       root@<device>   # stages, pre-flights, and PRINTS the destructive command
```

---

## What it deliberately does not do

- **No repair that keeps `/home`.** A disk that already carries RetroForge gets a full replacement. The
  screen says so; the size control is what would distinguish the two, and asking for a different
  split *is* a fresh install by definition.
- **No backups.** A plain-text record of the pre-state is written to the medium when it is writable,
  best-effort, and it never blocks an install. A backup that cannot be restored from the same medium
  would be a promise the tool cannot keep.
- **No target override.** The disk is chosen by the rules above or the install does not happen.
- **No text entry anywhere.** No SSID picker, no on-screen keyboard, no typed confirmation.
- **No state kept between boots.** The medium writes no boot environment: it travels between boards,
  and a remembered board choice is worse than asking again.

---

## See also

- [ota.md](ota.md) — the update server and the channel the medium fetches its bundle from
- [internal-storage.md](internal-storage.md) — the captured partition layouts these rules were
  derived from
- [RUNBOOK.md](RUNBOOK.md#recovery-when-it-does-not-boot) — recovery for a device that will not boot
