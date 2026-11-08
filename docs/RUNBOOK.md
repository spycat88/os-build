# Runbook — flash, reach, update, recover

The operational path, end to end. Design rationale lives elsewhere: [`remote-access.md`](remote-access.md)
for why SSH is shaped the way it is, [`ota.md`](ota.md) for the update server, and the header comments
of the scripts named below for why each step is shaped the way it is.

Every `make` invocation below runs from the repo root. A dev build needs its environment sourced
**before every one of them** (`set -a; . ./dev.env; set +a`) — see the README's Building section.

## Prerequisite: the device already runs OpenABL

**retroforge ships no bootloader.** A card boots because the device is already running
[OpenABL](https://github.com/OpenHandheldCollective/OpenABL) — an Android bootloader replacement
(the community continuation of the ROCKNIX ABL) that can chainload a UEFI payload off an ESP. On a
stock Android ABL a retroforge card does nothing, and nothing on the card can change that: writing
the image is not the first step, flashing that ABL is. We consume it and cannot build it — it
ships as a signed, per-SoC ELF (`abl_signed-<SoC>.elf` on the OpenABL releases page).

Install it by the upstream procedure — write the signed ELF to both the `abl_a` and `abl_b`
partitions (ROCKNIX's `updateabl` script does exactly this), which needs an unlocked bootloader.
That process is theirs to own and keep current; it is not reproduced here.

Two properties of it govern everything below:

- **It has two modes, Android or Linux, and the choice persists in the `devinfo` partition** — so
  set it in ABL's own menu. retroforge never writes `devinfo`: it is in the installer's deny list,
  the format is ABL-private, and on Qualcomm parts that partition also carries unlock and verity
  state. With Linux mode selected, **Volume-Up is a one-time override back to Android** — it
  chooses a mode, not a medium.
- **Linux mode tries internal storage first**, falling through to the card only when no internal
  ESP carries `/EFI/BOOT/bootaa64.efi` or `/KERNEL`. On a device with nothing installed to
  internal that is invisible — the card simply boots. On one that has something, the card needs
  "force external"; see [Recovery](#recovery-when-it-does-not-boot).

A pre-existing ROCKNIX *installation* is the second case, not just a pre-existing ABL: ROCKNIX
installed to internal storage keeps winning the boot until you force external, which reads like a
dead card. That is a setting, not a fault.

## The disk it all operates on

<!-- AUTO-GENERATED from image/partition-table.txt — regenerate with /ecc:update-docs -->

| # | Partition | Size | FS | Label |
|---|---|---|---|---|
| 1 | `esp` | 256M | vfat | `RETROFORGE-ESP` |
| 2 | `efi-a` | 128M | vfat | `retroforge-efi-A` |
| 3 | `efi-b` | 128M | vfat | `retroforge-efi-B` |
| 4 | `rootfs-a` | 2G | btrfs | `retroforge-root-A` |
| 5 | `rootfs-b` | 2G | btrfs | `retroforge-root-B` |
| 6 | `var-a` | 256M | ext4 | `retroforge-var-A` |
| 7 | `var-b` | 256M | ext4 | `retroforge-var-B` |
| 8 | `home` | rest | ext4 | `retroforge-home` |

<!-- END AUTO-GENERATED -->

`image/partition-table.txt` is the single source of truth for sizes, typecodes and labels;
`image/genpart.sh` emits the `sgdisk` script from it. Three facts drive most of what follows:

- **The shared ESP carries the slot state, not a kernel.** RAUC's `ORDER`, `A_OK`/`A_TRY` and
  `B_OK`/`B_TRY` in `/EFI/steamos/grubenv` decide which slot boots; the ESP GRUB (as
  `/EFI/BOOT/bootaa64.efi`) is what ABL starts, and it gives a slot three tries. Each slot's *own*
  efi partition (efi-a/efi-b) carries that slot's stage-2 `grub.cfg`, which picks the board. ABL
  reads partition 1 only.
- **`/var` is per-slot, and `/etc` rides on it** (an overlayfs whose upper dir is
  `/var/lib/overlays/etc/upper`). A slot switch therefore carries `/etc` with it.
- **`/home` is shared and survives everything** — including the paired SSH keys in
  `/home/player/.ssh`, and the offloaded `/var/log`. This is why an OTA does not lock you out.

## Get a release card

**A release card is published only by CI**, through a reviewed `release-cards` approval — but `make
sdcard` on a dev box (no `RETROFORGE_DEV`) builds the same kind of image, which is how a release image's first boot gets
tested on hardware without waiting for a run.

The card is an asset of the `card/v*` GitHub Release, next to its checksums and the package lock it
was built from. A release card compresses to 524 MiB (gz -6, measured 2026-10-13), well inside
GitHub's 2 GiB per-asset cap; `release-sdcard.yml` refuses to publish one that has grown past it.
The asset is named for the release, `retroforge-<version>.img.gz`. The repo is private, so
downloading it from the release page needs a GitHub login with access to it. Write it with
balenaEtcher or Raspberry Pi Imager, or:

```sh
sha256sum -c sha256sums.txt                   # check the download before writing it
gzip -dc retroforge-v1.3.0.img.gz | sudo dd of=/dev/sdX bs=4M conv=fsync status=progress
```

`.gz` rather than `.zst` on purpose: the payload is already compressed (both btrfs roots carry
`compress=zstd`), so every wrapper lands at about the same size and the choice is a compatibility
one, not a size one, and `.gz` is what balenaEtcher and Raspberry Pi Imager open.

Both kinds of tag get a GitHub Release whose notes open with what changed, written by Cloudflare
Workers AI (`@cf/mistralai/mistral-small-3.1-24b-instruct`, or the `RELEASE_NOTES_MODEL` repo
variable) from the commits since the previous tag in the same series. It needs the
`CLOUDFLARE_AI_TOKEN` secret (an API token with Workers AI Read + Edit) and the `CLOUDFLARE_ACCOUNT_ID` secret R2 publishing uses too;
it is free within the Workers plan's 10,000 neurons a day (~120 per release). Without the token, or
on any failure, `.github/scripts/release-notes.sh` writes the plain commit list instead, so a release
never waits on it. An `ota/` Release carries notes only (the bundle is on R2), is never marked
Latest, and is a pre-release for a beta tag.

To cut a card: tag `card/vX.Y.Z`. To cut an update instead, tag `ota/vX.Y.Z` — the two ship on
independent cadences and a bundle is expected far more often than a card. There is nothing to line
up first: the release run compiles the overlay from the sources in the commit it is building
(~34 min on top of the image), so a tag is never waiting on a separate pipeline to have published
anything.

An update goes to the **stable** channel unless its version has a pre-release suffix:
`ota/v0.3.0-beta.1` publishes to **beta**, which devices reach by choosing Beta in Settings > General
> Updates. Number a beta ahead of the stable release it leads to (`0.3.0-beta.N` before `0.3.0`). Install
every bundle on hardware before tagging it (`docs/ota.md`, "Cutting an update").

The version and commit a card was built from are stamped into `/etc/retroforge-release` on the device
(`RETROFORGE_VERSION`, `RETROFORGE_GIT`), so a running system can name where it came from.

## Build and flash a dev card

```sh
set -a; . ./dev.env; set +a                   # RETROFORGE_DEV=1 + optional Wi-Fi creds
make sdcard                                   # -> out/images/sdcard.img
make verify-card                              # GPT, ESP, per-slot filesystem identities
sudo dd if=out/images/sdcard.img of=/dev/sdX bs=4M conv=fsync status=progress
```

**Editing an overlay package needs no CI round trip, in either mode.** `make overlay` compiles it
locally and both the dev and release paths install what is in `work/repo/<arch>/` — patch, build,
flash, repeat is entirely local. Only the package you touched is rebuilt: `build-overlay.sh` keys
each one on `packages/inputhash.sh` over its committed inputs and skips the rest.

```sh
make overlay                                  # rebuild whatever moved (a warm tree: no-op)
packages/build-overlay.sh --only gamescope    # force one package
cat work/repo/aarch64/.stamps/gamescope.hash  # what was built, vs. inputhash.sh on the dir
```

`make-sdcard.sh` lays the **full** GPT — ESP + root-A/-B + var-A/-B + home, with `/home` carrying an
empty `player` home (`image/lib-homestage.sh`, shared with the internal installer) that grows to fill
the card on first boot. Each `efi-*` partition carries that slot's stage-2 `grub.cfg` and
`parts.env`; the ESP carries the ESP GRUB, the grubenv, `parts.env` and OpenABL's Device model list
(`/dtbs/qcom`).

**Whether slot B is populated follows the build mode**, and `RETROFORGE_SLOT_B=0|1` overrides it:

* **Dev card** (`RETROFORGE_DEV=1`): B is populated, carrying a distinct btrfs fsid, because a slot
  switch cannot be proven against a slot that does not boot. Set `RETROFORGE_SLOT_B=0` for a faster
  local loop, at the cost of a card whose first slot switch can only exercise the failover path.
* **Release card**: B is left empty **and the grubenv says `B_OK=0`**. B would be a byte-identical
  copy of an already-compressed root, surviving release compression whole — a second root's worth of
  download for a failover window that closes the first time RAUC writes the slot. `B_OK=0` (and the
  ESP GRUB's check for a kernel) is what keeps it from being tried. The first update writes B in
  full and RAUC marks it OK.

Run `verify-card` before you commit a card to a device — it asserts the built image rather than
the source tree, which is the only place the GPT, the ESP contents and the per-slot filesystem
identities are checked at all.

**The board comes from OpenABL's Device model when it is set.** One image serves every supported
board (the README's table is the roster), so the DTB is the one thing the card cannot know.
OpenABL installs the DTB of its Device model (it lists the ones in the ESP's `/dtbs/qcom`) before it
starts the ESP GRUB, and the stage-2 config boots the entry for that model with the slot's own DTB.
With no Device model, **the first boot stops at the stage-2 board menu and waits**; the choice is
written to `/EFI/steamos/grubenv` and every boot after that takes it with the menu hidden. The menu
comes back for 3 seconds when a board that has never had a boot confirmed is tried again — which is
how a wrong board shows itself and how to get back from it — and when no slot has tries left. With a
Device model set, change the board in OpenABL's menu instead.

### Update a dev card instead of reflashing it

A reflash erases `/home`: Steam and its games, the x86 guest, emulators, Wi-Fi. A dev card takes a
new build as an update instead, into its other slot, keeping `/home`. `dev.env` mints the build
box's own dev OTA key once (`ota/gen-dev-signing.sh`, into `work/dev-pki/`, kept like the dev SSH
key), every dev card built after that trusts it beside the project CA (STAGE `dev-ota-key`), and a
dev build's `make bundle` signs with it. Flash a card once; after that:

```sh
set -a; . ./dev.env; set +a
make bundle                                               # out/images/retroforge-<build>.raucb
scp -i work/dev-ssh/id_ed25519 out/images/retroforge-<build>.raucb root@<device>:/home/
ssh -i work/dev-ssh/id_ed25519 root@<device> 'rauc install /home/retroforge-<build>.raucb && systemctl reboot'
```

`/home` has the room (the bundle is ~1 GB); `/tmp` is RAM. A successful install deletes a
`*.raucb` it was installed from under `/home` (step 5 of `/usr/lib/rauc/post-install.sh`), so there
is nothing to clean up; a failed install keeps it for another try. A release device rejects these bundles
(the guard keeps the dev CA out of release keyrings), and `ota/publish-bundle.sh` refuses them. A
card flashed before its build box had a dev key, or from another build box, trusts no dev bundle:
reflash it once. Deleting `work/dev-pki` does the same to every card flashed with it.

## Reach the device

**These devices have no UART.** If you cannot reach a device over the network, your only
instrument is the offline card mount — see [Recovery](#recovery-when-it-does-not-boot).

### Release image

sshd ships **always-on and key-only**, with no host keys baked in and no account with a password.
Access is granted at runtime by whoever is holding the device:

1. On the device, turn on **Settings > General > Remote access > Allow pairing a computer**. That
   starts the pairing daemon (`retroforge-pairingd`, port 32000); it is off at every boot, and the
   switch's description shows the address to use.
2. From the machine you want to connect from:
   ```sh
   curl -X POST --data-binary @~/.ssh/id_ed25519.pub http://<device>:32000/register
   ```
3. Turn the switch off again. `ssh player@<device>` — immediately, no password. Installed keys live on `/home` and survive
   updates, so an already-paired machine never re-pairs.

Pairing is separate from sshd, which is always on and key-only. Full protocol notes, the Windows
invocations and what persists across an update: [`remote-access.md`](remote-access.md).

### Dev card

`dev.env` bakes `RETROFORGE_SSH_PUBKEY` into `root`'s `authorized_keys` and generates a throwaway
identity for it:

```sh
ssh -i work/dev-ssh/id_ed25519 root@<device>
```

That key survives `make distclean`, so your `known_hosts` entry keeps working across rebuilds. A
dev card built with no Wi-Fi credentials (or `RETROFORGE_WIFI=0`) has no network and no SSH by
design — that is the shipping first-boot condition, and the only honest way to exercise it.

## Ship an update

### Build and sign a bundle

```sh
RETROFORGE_VERSION=<version> PKIDIR=$HOME/retroforge-pki make bundle
```

**The version has to be set before the rootfs is built, not at bundling time.** `RETROFORGE_VERSION`
is stamped into the image's `/etc/retroforge-release`, and `genbundle.sh` reads it back out of the
image to name the bundle — so the bundle can never claim a version its payload does not carry. That
equality is what the device's update check compares, so it is not cosmetic. Changing the version
re-assembles the rootfs (a few minutes; not a base or kernel rebuild).

Omit it and the image calls itself `dev`; the bundle is then named after its build timestamp, which
is still unique per build but is not a release. There is no separate bundle-version knob — the old
`VERSION=` was removed on 2026-08-03 precisely because it could disagree with the image.

`PKIDIR` is not optional for anything a device will accept. Without it `genbundle.sh` mints an
**ephemeral 7-day dev cert**, deleted with its tempdir, which the device keyring rejects on
signature — that reads as a rauc failure and is not one. The PKI lives outside the repo and is
invisible to the build container unless `PKIDIR` mounts it.

There is a second target, `make sign-bundle`, which wraps an **existing** `out/images/rootfs.img`
instead of building one — same signing, no `$(ROOTFS)` prerequisite. CI uses it to split the release
into build → sign → publish so the image build does not queue behind someone approving the signing
environment; locally it is what you want when the image came from somewhere else (a CI artifact, or
another machine) and rebuilding it would defeat the point. It fails rather than building a
replacement if the image is not there. Use plain `make bundle` on a dev box: the prerequisite is the
feature, keeping the bundle honest about the tree it came from.

**`make bundle` does not verify its own output.** rauc logs `No keyring given, skipping signature
verification` at creation, so a green `make` is not evidence the bundle is validly signed. Check
it yourself, **through the shipped config**:

```sh
rauc --conf=rootfs/overlay/etc/rauc/system.conf info out/images/retroforge-<version>.raucb
```

Do not use `rauc info --keyring <ca>` — that applies rauc's default `smimesign` purpose, which
accepts only `emailProtection` or no EKU, and therefore rejects our `codeSigning` release cert
with `unsuitable certificate purpose`. It is a false red. The shipped `system.conf` sets
`check-purpose=codesign`.

### Publish it

```sh
R2_ACCOUNT_ID=… R2_ACCESS_KEY_ID=… R2_SECRET_ACCESS_KEY=… R2_BUCKET=… R2_PUBLIC_BASE=… \
  ota/publish-bundle.sh out/images/retroforge-<version>.raucb
```

Puts the bundle in the R2 bucket and flips the channel pointer at it (normally CI does this on an
`ota/v*` tag; `docs/ota.md`). Devices fetch from `https://ota.retroforge.org` (images before
2026-10-13 carry a placeholder host that never resolves), and
`retroforge-update` on the device currently reports "no update" regardless (it still gates on a Steam
login file that RetroForge never creates; see `docs/ota.md`). Until both are resolved, install by hand. **Install it on a device first** (below) — nothing on the device ends an unconfirmed
trial boot, so a bundle that comes up to a black screen costs ~6 manual power-cycles to recover on
hardware with no serial console. Every published bundle gets a hardware install before it ships.

The publisher verifies the signature against the CA baked into every device's keyring before it moves
a byte, and there is no override: a bundle built without `PKIDIR` carries an ephemeral 7-day cert and
would be a ~4 GB download the fleet discards at the last step. Server contract, retention, rollback
and cert renewal are in **`docs/ota.md`**.

### Install it

Drive the install **as `player` over SSH** — rauc's D-Bus service authorizes it with no `sudo` on the
box and no password anywhere. (The mechanism is rauc's *open bus policy*, not polkit: 1.15.2 ships
no polkit policy, and its `de.pengutronix.rauc.conf` allows any local user to call the installer. The
signature is the gate. See `docs/ota.md` — it was accepted as a design choice.)

```sh
ssh player@<device> rauc install /path/to/retroforge-<version>.raucb
```

Not as `root`: `/root` is on the read-only root and does not survive the slot write. Watch for
`Verifying signature done` (~20%) — that is the device's own keyring accepting the bundle.

Every install writes the whole slot today (`[image.rootfs]` names `rootfs.img` and nothing else),
so budget minutes of SD-card writes for a one-package bump.

The post-install hook makes the freshly written slot bootable: it re-randomises the target's btrfs
fsid (both slots otherwise share an fsid *and* `devid=1`, and mounting one can hand you the other),
copies `/var` across, installs this build's stage-2 grub.cfg + font onto the target's efi
partition, refreshes the shared ESP's `parts.env`, `/dtbs/qcom` and ESP GRUB if they changed, and
finally arms the target for its trial boot in the grubenv (first in `ORDER`, OK, `TRY=0`). Reboot to
land on the new slot.

## Read and steer the boot state

```sh
retroforge-bootctl status               # what booted, RAUC's slot state, what boots next
retroforge-bootctl get-state B          # is slot B fit to boot? (good|bad, RAUC's rule)
retroforge-bootctl set-primary B        # boot slot B next (rauc status mark-active; starts its trial)
retroforge-bootctl set-state B bad      # demote B (rauc status mark-bad); the next boot goes to the other slot
retroforge-bootctl mark-good            # confirm THIS boot (rauc status mark-good booted) — ends its trial
```

**All of these need root, and a release image ships no `sudo`.** As `player` the tool cannot answer
any of it. On a dev card, `ssh -i work/dev-ssh/id_ed25519 root@<device>`; on a release device,
read the state off the card offline (below). `rauc install` is the deliberate exception — it goes
through rauc's D-Bus service and its open bus policy, which is why it works as `player`.

The slot state is RAUC's own (`bootloader=grub`), so `retroforge-bootctl` and `rauc status` agree
by construction. It lives in the ESP's grubenv:

- **`<slot>_OK`** — a hard demote when 0. `set-state <slot> bad` clears it (and the boot-health unit's
  failure path does exactly that, via `retroforge-boot-bad.service`); RAUC's set-primary and a
  completed install set it again.
- **`<slot>_TRY`** — the trial count. The ESP GRUB bumps it before every boot of that slot,
  `mark-good` clears it after a healthy session, and after three tries without one the ESP GRUB
  boots the other slot. A healthy boot *clears* it, so mask `retroforge-boot-good.{path,service}`
  before a test reboot if you want to watch it count.

> **What that means in practice.** A slot that boots but comes up broken IS demoted — the health
> unit fails and the next boot goes to the other slot. A slot that never gets far enough to run
> systemd at all is skipped after its third try. Each retry and each fall-back shows the stage-2
> board menu for 3 seconds.

## Recovery: when it does not boot

There is no serial console. Power off, pull the card, and read it on your workstation.

**If the device has an internal Linux install, an inserted card will NOT boot — pick "force
external" in the bootloader.** ABL's Linux mode tries internal storage first and only falls
through to the card when no internal ESP carries `/EFI/BOOT/bootaa64.efi` or `/KERNEL`. So on a
device installed to internal storage — ours, or **ROCKNIX**, or another distribution's —
inserting a card and rebooting changes nothing, which reads exactly like a dead card or a bricked
machine. Select force external in ABL and the card boots normally. This is the recovery path for
an interrupted or broken internal install, and it is the only one short of EDL.

Since ROCKNIX runs the same ABL, a device that already had ROCKNIX installed to internal
is the most likely version of this, and it is not a retroforge fault to debug — it is the
[boot-order rule](#prerequisite-the-device-already-runs-openabl) working as designed.

Nothing on the SD-card-only path is affected: with no internal ESP present, ABL falls through to
the card unaided and no option needs setting.

**A card is the recovery medium.** Force external boots it, and re-running an install from its Settings
is the designed recovery for one that died partway: it takes no backups precisely because "run it
again" has to work. The run's log is `/var/log/retroforge/install.log` on the card, written when the
installer's unit stops. Full procedure, including what an install destroys and what it refuses:
[install-internal.md](install-internal.md).

**The journal is not on the slot's `/var`.** `/var/log` is bind-mounted onto
`/home/.retroforge/offload/var/log`, so it lives on the shared **home** partition and survives both
slots:

```sh
sudo mount /dev/sdX8 /mnt                     # retroforge-home
sudo journalctl -D /mnt/.retroforge/offload/var/log/journal -e
```

**Do not trust `-b -1` on these devices.** The RTC comes up stale, so the boot index is unreliable
and relative boot offsets silently select the wrong boot. List the boot IDs and query one
explicitly instead:

```sh
sudo journalctl -D /mnt/.retroforge/offload/var/log/journal --list-boots
sudo journalctl -D /mnt/.retroforge/offload/var/log/journal _BOOT_ID=<id>
```

The ESP carries the slot state that decided the boot:

```sh
sudo mount /dev/sdX1 /mnt-esp                 # RETROFORGE-ESP
grub-editenv /mnt-esp/EFI/steamos/grubenv list   # ORDER, A_OK/A_TRY, B_OK/B_TRY, saved_entry
```

`<slot>_OK=0` on the slot that just failed means it was demoted — by the health unit's failure path,
by hand, or by an interrupted install. `<slot>_TRY=3` means it used its three tries without a
healthy session. `tests/test-bootctl.sh` and `tests/test-stage2-grub.sh` document the semantics.

The initramfs is written to **degrade loudly rather than brick**: if it cannot assemble the
`/etc` overlay it falls back to a writable un-overlaid root and says so via `/dev/kmsg`. A device
that boots to a shell with a strange `/etc` is that path, not a corrupt image.

A torn write to the ESP or to a slot's efi partition — a lost grubenv, a missing stage-2 config —
is a **reflash**; the post-install hook refuses to update a card whose ESP has no grubenv. That is
the acknowledged failure mode of the design, not a bug to work around.

## Before a push

```sh
make verify-lock                # lock's retroforge rows vs packages/ (seconds)
make test                       # every offline suite under tests/
make test-signing               # RAUC signing self-test (container)
```

CI runs `make test`, the installer disk suites (`test-select-target`, `test-carve`) and
`make test-signing` on every push and pull request. A pull request that
touches a package also gets a compile pass over the packages it changed
(`.github/workflows/overlay.yml`). `make test` needs no
build, no container, no root and no device — it executes the shipped artifacts against a sandbox.
