# ota/

Getting a built image **onto a device that is already in someone's hands**: the signed RAUC
bundle, and the publishing path that puts it in the Cloudflare R2 bucket devices update from
(`docs/ota.md`).
What is inside the root is `rootfs/`; laying it onto a disk is `image/`.

Updates are A/B and atomic (RAUC + Btrfs read-only root). A slot switch carries `/etc` with it,
because `/etc` is an overlay whose upper dir lives on the per-slot `/var` — which is why the
post-install hook rsyncs `/var` across on update
(`rootfs/overlay/usr/lib/rauc/post-install.sh`; rationale and HW evidence in `docs/worklog/DONE.md`).

## The bundle

| File | Purpose |
|---|---|
| `genbundle.sh [version]` | Wrap the root image into a signed RAUC bundle (`.raucb`) for OTA. Without a key it mints an ephemeral cert whose bundle no device will install; to install on hardware pass `PKIDIR=` (or `RAUC_CERT`/`RAUC_KEY`). Checks the result against the device keyring. |
| `rauc/manifest.raucm.in` | RAUC update-manifest template (`@VERSION@`; `compatible=retroforge`). |
| `rauc/verify-signing.sh` | The signing self-test. Every case is a negative — it feeds a deliberately broken config or cert profile through the shipped `system.conf` and asserts the verification refuses it. `make test-signing` (container-only: it signs real bundles, so it needs rauc). Covered in turn by `tests/test-verify-signing.sh`, which proves those negatives still bite. |
| `rauc/release.cert.pem`, `release.ext` | The release signing profile. Note the `.gitignore` carve-out: every PEM under `rauc/` is asserted to carry no PRIVATE KEY by `tests/test-verify-signing.sh`, so the exception is policed by a test rather than by care. |

## Publishing

| File | Purpose |
|---|---|
| `publish-bundle.sh` | Publish a signed bundle plus its update index to R2, so a device's `retroforge-update` can see it. |
| `lib-rclone.sh` + `rclone.pin` | Sourced, never executed. The R2 credential environment and the pinned, sha256-verified rclone. |

Note that a green release workflow run does **not** by itself mean anything was published —
check the bucket (bundles) or the GitHub Release (card, installer).

_Phase 5._
