# OTA updates

Where a device in the field gets its OS updates from. The device half — the `retroforge-update` client,
the RAUC A/B install, the trial boot and rollback — is in `docs/RUNBOOK.md`; this file is the bucket
updates are served from and the act of publishing.

**Updates are served from a Cloudflare R2 bucket** since 2026-10-13, replacing a self-hosted nginx
host (its provisioning scripts are in git history before that date), at the custom domain
**`https://ota.retroforge.org`**. That URL is the device-side default in two places —
`retroforge-update`'s `DEFAULT_URL` and the installer's `release-info`
(`tests/test-ui.sh` asserts they agree). Images built before 2026-10-13 carry the placeholder
`updates.retroforge.invalid` instead, which never resolves: they fail closed and report "no update"
until reflashed (or given `OTA_URL` in `/etc/retroforge/ota.conf`).

> **The first-boot gate.** `retroforge-update`'s `check` and apply paths both begin with `setup_done()`:
> until OpenGamepadUI's first-boot flow has written `[general] first_boot=false` into
> `/home/player/.local/share/opengamepadui/settings.cfg`, the client exits 7 ("no update") without
> contacting any server, and `retroforge-update status` shows `setup: first boot not finished (updates
> deferred)`. A device that has finished setup checks normally.

| | |
|---|---|
| Storage | Cloudflare R2, bucket `R2_BUCKET`, public read |
| Public URL | `R2_PUBLIC_BASE` = `https://ota.retroforge.org`, the bucket's custom domain; also the devices' `DEFAULT_URL` |
| Publisher | `ota/publish-bundle.sh` (rclone, pinned in `ota/rclone.pin`), run by `release-bundle.yml` on `ota/v*` (stable, beta) and by `nightly-bundle.yml` every night (nightly), both through `sign-publish-bundle.yml` |
| Retention | 3 bundles per channel (`RETROFORGE_OTA_KEEP`); a bundle is ~530 MiB (measured 2026-10-13), so three channels hold ~4.7 GiB of R2's 10 GB free tier |

## Layout

**The bucket root is the URL root.** The client's `DEFAULT_URL` carries no path prefix, so a
*channel* is the first path segment:

```
<bucket>/
  stable/
    latest.json                   -> <R2_PUBLIC_BASE>/stable/latest.json
    retroforge-0.2.0.raucb        -> <R2_PUBLIC_BASE>/stable/retroforge-0.2.0.raucb
  beta/
  nightly/
```

The host itself comes from `OTA_URL` in `/etc/retroforge/ota.conf` or `RETROFORGE_OTA_URL` in the
environment, falling back to `DEFAULT_URL`. A channel is a directory, not a migration. The client's
`OTA_CHANNEL` selects one, from the first of these that has it:

| source | who can write it | note |
|---|---|---|
| `RETROFORGE_OTA_CHANNEL` | whoever runs the command | one invocation only |
| `/etc/retroforge/ota.conf` | root | only a **dev** image ships this file, pinned to `dev` so the image is never offered a stable release |
| `~/.config/retroforge/ota.conf` | the user, no root needed | `/home/player/.config/retroforge/ota.conf` (spelled out, not `$HOME`); the only one reachable on a release device |
| built-in `stable` | — | |

`/etc` outranks `$HOME` on purpose: a file in `$HOME` must not silently undo the dev image's pin. On
a release image `/etc/retroforge/ota.conf` does not exist, so the user's file is the only entry in the
chain. It may set `OTA_CHANNEL` **only** — `OTA_URL` is read from `/etc` and the environment, never
from `$HOME`, because which host a device fetches from is an operator decision and one writable file
under `$HOME` must not repoint every future update.

`retroforge-update status` prints which of them supplied the channel in effect, which is the fastest
answer to "why is it checking that channel". `retroforge-update channel` prints the same pair
tab-separated for a program to read, so the shell's channel picker does not re-derive the precedence
and then disagree with the fetch.

### The client contract

`retroforge-update` keeps the exit-code contract it was written to: `check` exits 0 and prints the
available version on stdout, or exits 7 for "none" — and 7 is also how every recoverable failure
exits (unreachable server, malformed manifest), so a check fails closed. Apply (no argument) emits
forward-only `N%` lines on stdout and everything else on stderr. An update already installed and
waiting for a reboot is reported by reprinting its version; `staged` answers that question alone
(exit 0 and the version, else 7), and `version` prints the running one. The caller is the RetroForge
shell plugin's Updates section; it can also be run by hand over SSH as `player`.

### Settings > General > Updates

The plugin's RetroForge OS platform (`apps/ogui-retroforge-plugin/plugin/retroforge_os.gd`) replaces
OGUI's own updater with:

- **System update**, one button walking Steam's steps: *Check for updates* -> *Install* (the install's
  progress in its description) -> *Restart now* (`systemctl reboot`). An update already installed
  when the shell starts shows *Restart now* straight away. Nothing installs or restarts without a
  press.
- **Update channel**, Stable, Beta or Nightly. Switching either way needs no confirmation and checks the new
  channel at once; going back to Stable offers stable's release even when it is older than the beta
  running (the check compares for inequality). The dropdown is disabled when `/etc` or the
  environment pins the channel, as on a dev image.
- **A background check** 3 minutes after the shell starts, then every 6 hours, never while a game runs.
  It posts one notification per version found and never installs.

Channel selection lives in the same program: `retroforge-update channels` lists what a picker offers
(the hosted list below, plus the channel in effect if it is not on it, and a `pinned<TAB><source>` line
when `/etc` or the environment outranks the user's choice), and `retroforge-update set-channel <name>`
writes `~/.config/retroforge/ota.conf`. The old Steam-shaped `retroforge-select-branch` is gone.

**The picker's list is hosted, not baked in.** `channels` fetches
[`ota/channels.json`](../ota/channels.json) from `main` on GitHub
(`https://raw.githubusercontent.com/retroforge-linux/os-build/main/ota/channels.json`) every time, so
adding a channel there makes it appear on devices that are already installed, with no OTA. Each entry
is a name (the bucket prefix, same grammar `publish-bundle.sh` enforces) with an optional `label` and
`description` the picker shows; an entry with a bad name is dropped, and `pinned` is reserved.
`OTA_CHANNELS_URL` in `/etc/retroforge/ota.conf` points a device at another list.

**The list is required, online, every time.** There is no cache and no built-in list. When the file
cannot be fetched or has no usable entry:

- `channels` exits 1 with the reason on stderr. The Updates page shows the channel in effect, locked,
  with "Could not load the update channels. Check your internet connection and open this page
  again.", and tries again each time the General page is opened.
- `check` and apply exit 8 (not 7, "no update") before asking the update server. The Updates button
  says the update channels could not be loaded, and the background check posts nothing.
- An update already installed and waiting for a reboot still shows *Restart now*: that needs no network.

The list is not a trust boundary: a name can only become a path under the update server the image
already trusts, and what that channel serves still has to verify against the keyring. Publish to a
new channel before listing it, or devices that pick it will find nothing there (the check fails
closed).

**Which channels exist:** `stable`, `beta` and `nightly`, each a prefix in the bucket that appears on
its first publish. `nightly` is described in [Nightly](#nightly) below; the rest of this paragraph is
about the two that come from tags. `release-bundle.yml` decides between them from the tag's semver pre-release suffix — `ota/v0.3.0`
publishes to `stable`, `ota/v0.3.0-beta.1` to `beta`. Not a separate tag namespace, because the
version string then records the channel and duplicate detection turns on that string: two channels
publishing the same `0.3.0` would leave a device switching stable → beta believing it is already up
to date. A beta bundle is signed with the same release key and gated exactly as hard; the channel
decides who is offered it, not whether it is trustworthy. `image/` tags refuse a pre-release suffix
outright: there is no beta image, and an image's installer installs from the channel picked in Updates
whatever the image's own version says. An `ota/` tag with a `-nightly` suffix is refused: only
`nightly-bundle.yml` publishes to `nightly`.

A choice made in `~/.config` survives an OTA and a slot switch on its own: `/home` is one partition
shared by both slots. The copy in `/etc` needs `post-install.sh` to carry it, because that one lives
in the per-slot `/var` overlay upper.

**A channel with no `latest.json` is the correct resting state, not an outage.** The client gets a
404, fails closed and exits 7 — "no update available". That is exactly right between releases. A
placeholder pointing at a bundle that is not there would be worse: it would *offer* an update whose
download 404s after the user has already said yes.

### `latest.json`

```json
{ "version": "0.2.0", "build": "20260803T120000Z", "git": "abc1234",
  "bundle": "retroforge-0.2.0.raucb", "size": 3758096384, "sha256": "…" }
```

`version` is the identity the client compares and dedupes on (`build` stands in when the version is
the literal `dev`); it is read out of the bundle's own manifest, not chosen at publish time. `bundle`
must be a **bare filename** — the client rejects a scheme, a host, a `/`, a `\` or a leading dot.
`git` is for a human reading the file. `size` must be a positive integer or the manifest is refused;
it is what the installer's pre-flight screen shows, and it is no longer checked against the transfer,
because rauc fetches the bundle itself. `sha256` is not checked by the client: the RAUC signature is
the integrity gate, and a hash in a file fetched from the same server proves nothing an attacker
could not also rewrite.

## Cutting an update

```sh
# 1. build and sign — the version must be set BEFORE the rootfs, see docs/RUNBOOK.md
RETROFORGE_VERSION=0.2.0 PKIDIR=$HOME/retroforge-pki make bundle

# 2. install it on a device and confirm it boots, BEFORE anyone else gets it
ssh player@<device> rauc install /path/to/retroforge-0.2.0.raucb

# 3. publish — normally by tagging ota/v0.2.0 (below); by hand, with the R2 credentials exported:
R2_ACCOUNT_ID=… R2_ACCESS_KEY_ID=… R2_SECRET_ACCESS_KEY=… R2_BUCKET=… R2_PUBLIC_BASE=… \
  make publish-bundle BUNDLE=out/images/retroforge-0.2.0.raucb
```

Step 2 installs from a **local file**. The device streams when `retroforge-update` drives it (below), but
a local `rauc install <file>` is unaffected: rauc's adaptive path is best-effort with an
unconditional fall-through to a plain full-slot copy, so a workstation install writes the same bytes
it always did. It simply gains nothing from adaptive — there is no download to shrink.

Step 2 is not optional and is not ceremony. Nothing on the device confirms a trial boot that never
reaches a session, so a bundle that comes up to a black screen needs about six manual power-cycles to
recover — on a device with no serial console. Every published bundle gets a hardware install first
— except a nightly, which is published untested by design ([Nightly](#nightly)).

### The device streams; it does not download

`retroforge-update` hands rauc the bundle's **https URL**, not a downloaded file. rauc creates an NBD
device backed by an unprivileged helper (user `nobody`) that turns block reads into HTTP `Range`
requests, so a bundle never occupies storage on the device — there is no staging directory to fill
and no free-space precondition on an update.

Because `ota/rauc/manifest.raucm.in` marks the image `adaptive=block-hash-index`, the bundle also
carries a SHA256 index of every 4 KiB block. rauc looks each block up in **both** slots and fetches
only what it cannot find locally. Measured 2026-08-04 across two independent pairs of real
consecutive bundles: **96.1% of non-zero blocks are reused, ~125 MB crosses the wire instead of
3.90 GB.** Matching is content-addressed, and every local hit is re-hashed against the index inside
the signed bundle before use — a corrupt or tampered local index can only cost bandwidth.

**The endpoint must speak HTTP/2 for that to be quick.** rauc's NBD helper turns block reads into
many concurrent Range requests, which is the request pattern HTTP/1 serialises — and rauc warns about
it at the start of every stream (`using HTTP/1 for streaming, expect slow installation`), observed on
a Pocket ACE against a plain-HTTP lab server. The bundle is fetched by rauc; the only
thing curl fetches is `<channel>/latest.json`, a few hundred bytes. Cloudflare's edge negotiates
HTTP/2 over TLS for an R2 public bucket, so the warning should not appear — **check for it on the
first real stream**, since that is the only place this is observable.

Consequences worth knowing before reading a slow first result:

- **rauc runs from the RUNNING slot**, so it is that slot's `system.conf` and that slot's
  `retroforge-update` which decide whether an install is adaptive — not the bundle's. A slot whose
  config has no `data-directory` installs any bundle as a plain full-slot write.
- **The first adaptive install still saves; it is just slower.** With no stored index for either
  slot rauc generates them on demand, which costs one pass of hashing both slots. Indices are then
  kept in the data directory on `/home`, which is shared, so they survive the slot switch.
- **Progress tracks the INSTALL, not the transfer.** With most blocks coming from local slots, it
  advances through stretches where nothing crosses the network.
- **A failed stream is cheap to retry.** The correct blocks already written into the target slot are
  exactly what the next attempt finds locally. There is no resume, and there is no way to cancel an
  install once accepted — rauc's D-Bus API has no `Cancel` method. A broken connection is bounded
  (5 range-request retries, then the install fails); a merely stalled one is bounded only by TCP.

Both halves fail *silently* if lost — a rauc built without streaming, or a kernel without `nbd.ko`,
degrades to a full download that still succeeds. `rootfs/guard-rootfs.sh` asserts both at build time.

`publish-bundle.sh` does, in order: check the R2 credentials, verify the signature against the
device keyring, read the version back out of the bundle (and refuse a dev image), refuse to overwrite
the bundle `latest.json` already names, upload, **read the bundle back through the public URL — a
`Range` probe, then the whole file — and compare its sha256 to the local one**, **write `latest.json`
last** with `Cache-Control: no-cache`, read that back over HTTPS, and prune to `KEEP`. Everything
before the pointer write is invisible to devices; that write is the publish.

The read-back is not redundant with the upload succeeding. `$SHA` is computed from the local file
*before* the transfer, so without it the `sha256` published in `latest.json` describes the local
file, not the one being served — and a custom domain's cache can serve an older object under the same
name. Because the client does **not** check `sha256` (above), a corrupt or stale bundle would
otherwise be caught no earlier than each device's own signature verification, after the download,
per device. Caught here it costs one re-upload. Reading the whole bundle back costs about 530 MiB of
egress, which R2 does not charge for.

**A published version is immutable.** Overwriting the bundle `latest.json` names would swap bytes
under devices that may be mid-stream, so the publisher refuses it; bump the version instead. A bundle
present but *not* named by `latest.json` is a run that died before the pointer write, and is replaced.

### Validating a release on hardware, before anything is published

**Proving the update path needs no published image and no published bundle.** It needs a device on
the boot flow you are shipping and a bundle that device will accept, and both are buildable locally.

One thing decides whether a boot-flow change can be shipped as an OTA at all: **RAUC runs the BOOTED
slot's post-install handler, not the bundle's.** A device runs the handler of the release it is on,
so a change the old handler does not understand (a new boot layout, a file it requires that the new
image no longer ships) cannot be fixed in the bundle — the next image is then a mandatory reflash for
every device in the field. Read the running release's `usr/lib/rauc/post-install.sh` against the new
image before promising an OTA. A handler that dies partway is safe for the running system but is
**not a dry run**: it can leave the target slot overwritten and unbootable while the booted slot
keeps running.

```sh
# 1. the device: build the new boot flow locally and flash it. Give the IMAGE a version too, or
#    both ends render `dev` and there is no version change to detect.
set -a; . ./dev.env; set +a
RETROFORGE_VERSION=<base> PKIDIR=$HOME/retroforge-pki make sdcard    # dev image, new boot flow

# 2. a bundle the device will accept: a DEV image with a REAL signature.
#    rauc gates on the signature, so this installs exactly like a release bundle.
RETROFORGE_VERSION=<bumped> PKIDIR=$HOME/retroforge-pki make bundle

# 3. install it with rauc directly (no server needed). rauc also accepts an https URL and
#    streams it; with a server, `retroforge-update` on the device does the same.
scp out/images/retroforge-<bumped>.raucb player@<device>:
ssh player@<device> rauc install retroforge-<bumped>.raucb
```


Then reboot and confirm the new slot booted and `/etc/retroforge-release` changed. Once the client is
driven by the shell, the same test runs through a TEST channel instead: upload the bundle and a
hand-written `latest.json` (schema above) under `test/` in the bucket — or under any HTTPS host you
control, pointed at with `OTA_URL` in the device's `/etc/retroforge/ota.conf` — and point the device
at the channel with

```sh
ssh player@<device> 'mkdir -p ~/.config/retroforge && echo OTA_CHANNEL=test > ~/.config/retroforge/ota.conf'
```

(on a DEV image `/etc/retroforge/ota.conf` pins `dev` and outranks this file, so edit that one — you have
root on a dev image), and drive check → install → restart from the shell. Then check again — it must
report up-to-date and **not** re-offer. **Reset the channel when you are done**: `~/.config` is on
`/home`, shared by both slots, so `OTA_CHANNEL=test` survives the update and the device silently
keeps reading it forever. `retroforge-update status` names the file it came from.

**`ota/publish-bundle.sh` refuses dev bundles, and that does not obstruct this.** The mode gate
protects `stable` from a test image reaching the fleet; hand-placing a bundle in a channel of your
own is you doing something explicit. The gate is on publishing, not installing.

Only once that passes: tag `image/vX.Y.Z` (the image), then `ota/vX.Y.Z`.

**`ota/vX.Y.Z` publishes by itself.** `release-bundle.yml` builds the rootfs, then its `release`
job signs the bundle with the release cert and runs `ota/publish-bundle.sh` against the bucket with
the `R2_*` secrets and variables — `make publish-bundle` by hand is the fallback, not the route. If
the publish step fails, the signed bundle is still kept as the run's `retroforge-bundle` artifact for
`make publish-bundle`. The signing key reaches the job on a tag push only, so a manual run still
produces a throwaway-cert bundle and never publishes.

**One approval.** The `release` job names the `release-signing` environment, which holds the
secrets, accepts `ota/v*` tags only, and has a required reviewer (since 2026-11-09): the job waits
for that **one** approval — signing and publishing behind a single gate, "this tag ships". The
build before it needs no key and runs without waiting. Until the repo went public (2026-11) GitHub
Free had no environments, the secrets were repo-wide, and nothing waited.

A publish ends in exactly one of two states, **published** or **red**: a missing credential is an
error, not a skipped step, because nobody reads a skipped step at the bottom of an hour-long success.

### Rolling back a bad release

The previous bundles are still in the bucket — that is what `KEEP=3` is for. Point
`stable/latest.json` at an older one, with `version`, `size` and `sha256` matching it — `version` is
what the client compares against the device:

```sh
rclone cat r2:<bucket>/stable/latest.json > latest.json     # edit it to name the older bundle
rclone copyto --header-upload "Cache-Control: no-cache" --header-upload "Content-Type: application/json" \
  latest.json r2:<bucket>/stable/latest.json
```

(The `r2:` remote is what `ota/lib-rclone.sh`'s `r2_env` defines from the `R2_*` variables; source it,
or configure the same remote by hand.) This only helps devices that have not updated yet; one that
already installed the bad bundle recovers through the boot failsafe, not through the bucket.

## Nightly

`.github/workflows/nightly-bundle.yml` builds `main` every night at 02:30 UTC and publishes it to
`nightly/` **with no approval** (plan `.claude/plans/nightly-channel.plan.md`). It is the one channel
exempt from "every published bundle gets a hardware install first": a device on Nightly takes builds
nobody has booted, and Settings says so ("daily untested builds") while Nightly is selected.

- **Version** `vX.Y.(Z+1)-nightly.YYYYMMDDHHMM` (UTC), one patch ahead of the last stable `ota/v*`
  tag, e.g. `v0.0.8-nightly.202611120230`. Unique per run, which a published version must be, and
  the version in Settings names the channel. The commit is `latest.json`'s `git`.
- **When it builds.** Not when `main` has not moved since the published nightly, and not when `ci.yml`
  has not passed on `main`'s HEAD — except that a published nightly over 30 days old is rebuilt
  anyway, so the bundle on offer is always signed by a cert that is still valid (below). A manual
  run with `force` builds regardless.
- **No GitHub Release.** The commits since the previous nightly are in the run's summary.
- **Where it signs.** The `nightly-signing` environment: deployments from `main` only, no reviewer,
  holding `RAUC_NIGHTLY_CERT_PEM`/`RAUC_NIGHTLY_KEY_PEM`, `R2_ACCESS_KEY_ID`/`R2_SECRET_ACCESS_KEY`
  (a token of its own, so it can be revoked without touching releases) and the `R2_BUCKET` /
  `R2_PUBLIC_BASE` variables. `CLOUDFLARE_ACCOUNT_ID` is repo-wide. The release cert never enters it.

### Nightly signing cert

Nightly bundles are signed by their own cert, not the release one, valid for **90 days**. Devices
trust the CA rather than a cert, so a nightly-signed bundle would install on a stable device just as
a release one does — one keyring has no per-channel signer check. What the short life buys is a bound
on a leak: rauc checks the signer's validity **at install time** (`system.conf` sets no
`use-bundle-signing-time`), so a leaked nightly key is useless after its expiry, without touching a
device. The same rule is why the cert has to be renewed on time: a published nightly stops installing
the day its signer expires.

**Renewing** is by hand, by someone with read access to the private `retroforge-linux/secrets` repo,
which holds the root CA. That repo's access list is the control: no workflow renews, so the root CA
key never reaches a CI runner.

```sh
make renew-nightly-cert                           # the CA from retroforge-linux/secrets, via your gh login
PKIDIR=~/retroforge-pki make renew-nightly-cert   # or from a local copy of it
```

`ota/renew-nightly-cert.sh` fetches only `retroforge-pki/ca.cert.pem` and `ca.key.pem` into a private
tempdir, refuses unless that CA is the committed `ota/rauc/retroforge-ca.pem`, mints a new RSA-4096
key and a 90-day cert with the release profile (`ota/rauc/release.ext`), verifies it, uploads both to
`nightly-signing` in `retroforge-linux/os-build` through stdin, and shreds the tempdir. Nothing is
committed and nothing is kept: the next renewal mints a new pair. Your `gh` login needs admin on
os-build to write environment secrets.

**When:** `nightly-bundle.yml` files an issue ("Nightly signing cert expires on YYYY-MM-DD") 14 days
before expiry. Once it has expired, the nightly run fails before building. After renewing, the next
nightly picks the new cert up.

**If the nightly key leaks:** delete the two `RAUC_NIGHTLY_*` secrets so nothing more is signed, and
renew. Devices check no revocation list, so the leaked cert stays usable until its expiry, at most
90 days away.

## The bucket

Set up once, in the Cloudflare dashboard:

1. **Create the bucket** (`R2_BUCKET`).
2. **Make it publicly readable**: Settings → Public access. Either allow the **r2.dev subdomain**
   (immediate, but rate-limited and not meant for production) or connect a **custom domain** (served
   through Cloudflare's cache, no rate limit). Whichever URL that gives is `R2_PUBLIC_BASE`, and it is
   what devices will be pointed at — changing it later means a device-side change in every image, so
   choose once.
3. **Create an API token** scoped to that one bucket with *Object Read & Write*. It needs delete as well
   as write (the prune). Its access key ID and secret are `R2_ACCESS_KEY_ID` / `R2_SECRET_ACCESS_KEY`;
   the account ID is `R2_ACCOUNT_ID` (the scripts' name for it).
4. **In GitHub**: `CLOUDFLARE_ACCOUNT_ID` (the account ID; the workflows hand it to the scripts as
   `R2_ACCOUNT_ID` and to the release notes), `R2_ACCESS_KEY_ID`, `R2_SECRET_ACCESS_KEY`,
   `RAUC_CERT_PEM` and `RAUC_KEY_PEM` as **secrets** of the `release-signing` environment;
   `R2_BUCKET` and `R2_PUBLIC_BASE` as **variables** of it. `CLOUDFLARE_ACCOUNT_ID` stays a repository
   secret, because the release notes job, which names no environment, reads it too.

**Caching.** `latest.json` changes in place, so the publisher uploads it with
`Cache-Control: no-cache` and reads it back over HTTPS after writing. Bundles never change once
published, so they can be cached freely. If a custom domain carries cache rules that override origin
headers, exempt `*/latest.json` from them, or a release (or a rollback) stays invisible until the
cache expires.

**Budget.** R2's free tier is 10 GB of storage with no egress charge. Three bundles per channel at
~530 MiB, across `stable` and `beta`, is about 3.1 GiB. Raise `RETROFORGE_OTA_KEEP` with that in mind.

## Trust model

**`latest.json` is a hint, never a trust boundary.** It says which bundle to fetch and nothing else.
It cannot select a keyring, a verification mode or an install flag, and the client forces `bundle` to
a bare filename so a manifest can never redirect a device to another host. The gate is the RAUC
signature: the device installs a bundle only if it chains to `/etc/rauc/keyring.pem` with
`check-purpose=codesign`.

That is also why `ota/publish-bundle.sh` verifies against that same keyring before it uploads, with
no override. A dev-cert bundle in the bucket is not a near miss — `make bundle` without `PKIDIR`
mints an *ephemeral 7-day* certificate that is deleted with its tempdir, so the result is a download
that every device in the field discards at the last step.

**The R2 token is a write credential to the fleet's update pointer**, not a signing key. Whoever holds
it can point `latest.json` anywhere in the bucket or delete releases — a denial of updates — but cannot
make a device install anything that does not chain to the keyring.

**Own the hostname.** With a custom domain, whoever controls its DNS controls what devices are told to
fetch. The signature still bounds the damage to "serves a bundle every device rejects", but a name
under somebody else's control gives them that lever. Changing the name later needs a device-side
change (the `DEFAULT_URL` literals above), so choose it once.

**rauc's bus policy is open to every local process.** `de.pengutronix.rauc.conf` ships
`<policy context="default"><allow send_destination="de.pengutronix.rauc"/></policy>` and 1.15.2 has
no polkit policy at all, so any local process can call `InstallBundle`. Bounded by signature
verification, so not arbitrary code execution — but it is the actual mechanism behind "unprivileged
install" (`player` installs with no sudo), and it is not polkit. Accepted as a design choice.
