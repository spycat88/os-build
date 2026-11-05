# OTA updates

Where a device in the field gets its OS updates from. The device half — the `retroforge-update` client,
the RAUC A/B install, the trial boot and rollback — is in `docs/RUNBOOK.md`; this file is the bucket
updates are served from and the act of publishing.

**Updates are served from a Cloudflare R2 bucket** since 2026-10-13, replacing a self-hosted nginx
host (its provisioning scripts are in git history before that date), at the custom domain
**`https://ota.retroforge.org`**. That URL is the device-side default in three places —
`retroforge-update`'s `DEFAULT_URL` and the installer medium's `netcfg` and `release-info`
(`tests/test-ui.sh` asserts the three agree). Images built before 2026-10-13 carry the placeholder
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
| Publisher | `ota/publish-bundle.sh` (rclone, pinned in `ota/rclone.pin`), run by `release-bundle.yml` on `ota/v*` |
| Retention | 3 bundles per channel (`RETROFORGE_OTA_KEEP`); a bundle is ~530 MiB (measured 2026-10-13) |

## Layout

**The bucket root is the URL root.** The client's `DEFAULT_URL` carries no path prefix, so a
*channel* is the first path segment:

```
<bucket>/
  stable/
    latest.json                   -> <R2_PUBLIC_BASE>/stable/latest.json
    retroforge-0.2.0.raucb        -> <R2_PUBLIC_BASE>/stable/retroforge-0.2.0.raucb
  beta/
```

The host itself comes from `OTA_URL` in `/etc/retroforge/ota.conf` or `RETROFORGE_OTA_URL` in the
environment, falling back to `DEFAULT_URL`. A channel is a directory, not a migration. The client's
`OTA_CHANNEL` selects one, from the first of these that has it:

| source | who can write it | note |
|---|---|---|
| `RETROFORGE_OTA_CHANNEL` | whoever runs the command | one invocation only |
| `/etc/retroforge/ota.conf` | root | only a **dev** card ships this file, pinned to `dev` so the card is never offered a stable release |
| `~/.config/retroforge/ota.conf` | the user, no root needed | `/home/player/.config/retroforge/ota.conf` (spelled out, not `$HOME`); the only one reachable on a release device |
| built-in `stable` | — | |

`/etc` outranks `$HOME` on purpose: a file in `$HOME` must not silently undo the dev card's pin. On
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
- **Update channel**, Stable or Beta. Switching either way needs no confirmation and checks the new
  channel at once; going back to Stable offers stable's release even when it is older than the beta
  running (the check compares for inequality). The dropdown is disabled when `/etc` or the
  environment pins the channel, as on a dev card.
- **A background check** 3 minutes after the shell starts, then every 6 hours, never while a game runs.
  It posts one notification per version found and never installs.

Channel selection lives in the same program: `retroforge-update channels` lists what a picker offers
(`stable`, `beta`, plus the channel in effect if it is neither, and a `pinned<TAB><source>` line
when `/etc` or the environment outranks the user's choice), and `retroforge-update set-channel <name>`
writes `~/.config/retroforge/ota.conf`. The old Steam-shaped `retroforge-select-branch` is gone.

**Which channels exist:** `stable` and `beta`, each a prefix in the bucket that appears on its first
publish. `release-bundle.yml` decides between them from the tag's semver pre-release suffix — `ota/v0.3.0`
publishes to `stable`, `ota/v0.3.0-beta.1` to `beta`. Not a separate tag namespace, because the
version string then records the channel and duplicate detection turns on that string: two channels
publishing the same `0.3.0` would leave a device switching stable → beta believing it is already up
to date. A beta bundle is signed with the same release key and gated exactly as hard; the channel
decides who is offered it, not whether it is trustworthy. The bare `v*` image-release tags refuse a
pre-release suffix outright — there is no beta card, and a medium installs the latest `stable`
whatever its own version says.

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
recover — on a device with no serial console. Every published bundle gets a hardware install first.

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

**Proving the update path needs no published card and no published bundle.** It needs a device on
the boot flow you are shipping and a bundle that device will accept, and both are buildable locally.

One thing decides whether a boot-flow change can be shipped as an OTA at all: **RAUC runs the BOOTED
slot's post-install handler, not the bundle's.** A device runs the handler of the release it is on,
so a change the old handler does not understand (a new boot layout, a file it requires that the new
image no longer ships) cannot be fixed in the bundle — the next card is then a mandatory reflash for
every device in the field. Read the running release's `usr/lib/rauc/post-install.sh` against the new
image before promising an OTA. A handler that dies partway is safe for the running system but is
**not a dry run**: it can leave the target slot overwritten and unbootable while the booted slot
keeps running.

```sh
# 1. the device: build the new boot flow locally and flash it. Give the CARD a version too, or
#    both ends render `dev` and there is no version change to detect.
set -a; . ./dev.env; set +a
RETROFORGE_VERSION=<base> PKIDIR=$HOME/retroforge-pki make sdcard    # dev card, new boot flow

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

(on a DEV card `/etc/retroforge/ota.conf` pins `dev` and outranks this file, so edit that one — you have
root on a dev card), and drive check → install → restart from the shell. Then check again — it must
report up-to-date and **not** re-offer. **Reset the channel when you are done**: `~/.config` is on
`/home`, shared by both slots, so `OTA_CHANNEL=test` survives the update and the device silently
keeps reading it forever. `retroforge-update status` names the file it came from.

**`ota/publish-bundle.sh` refuses dev bundles, and that does not obstruct this.** The mode gate
protects `stable` from a test image reaching the fleet; hand-placing a bundle in a channel of your
own is you doing something explicit. The gate is on publishing, not installing.

Only once that passes: tag `vX.Y.Z` (card + installer), then `ota/vX.Y.Z`.

**`ota/vX.Y.Z` publishes by itself.** `release-bundle.yml` builds the rootfs, signs the bundle with
the release cert (`sign`), and `publish` runs `ota/publish-bundle.sh` against the bucket with the
`R2_*` secrets and variables — `make publish-bundle` by hand is the fallback, not the route. The
signing key reaches the `sign` step on a tag only, so a manual run still produces a throwaway-cert
bundle and never publishes.

**No approval gates on this plan.** The jobs name the `release-signing` environment, but the repo is
private on GitHub Free, which has no environments: the secrets are repo-wide and nothing waits for a
reviewer. Anyone who can push an `ota/v*` tag can sign and publish. Creating the environment (a paid
plan or a public repo) and moving the secrets into it restores the two approvals — reaching the
signing key, then reaching the bucket — with no workflow change.

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
   the account ID is `R2_ACCOUNT_ID`.
4. **In GitHub**: `R2_ACCOUNT_ID`, `R2_ACCESS_KEY_ID`, `R2_SECRET_ACCESS_KEY`, `RAUC_CERT_PEM` and
   `RAUC_KEY_PEM` as repository **secrets**; `R2_BUCKET` and `R2_PUBLIC_BASE` as repository
   **variables**. Repo-wide because this plan has no environments (above).

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
