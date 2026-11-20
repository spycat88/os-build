#!/usr/bin/env bash
# retroforge DEV signing key — what lets a dev image take a new build as an update instead of a
# reflash, so its /home (Steam and its games, the x86 guest, emulators, Wi-Fi) survives.
#
#   ota/gen-dev-signing.sh                 # mints into work/dev-pki/, once (dev.env runs it)
#   DEV_PKIDIR=<dir> ota/gen-dev-signing.sh
#
# A device installs a bundle only if its signature chains to /etc/rauc/keyring.pem, and every image
# carries the project's CA there (ota/rauc/retroforge-ca.pem), whose key is not on a dev box. So a
# dev image ALSO trusts this build box's own dev CA: rootfs/lib-assemble-devimage.sh appends
# work/dev-pki/ca.cert.pem to its keyring, and a dev build's `make bundle` signs with
# work/dev-pki/release.{cert,key}.pem. Then, once an image is flashed with that keyring:
#
#   set -a; . ./dev.env; set +a; make bundle
#   scp out/images/retroforge-<build>.raucb root@<device>:/home/  &&  ssh root@<device> rauc install /home/retroforge-<build>.raucb
#
# The same two levels and the same signing-cert profile as the real PKI (ota/gen-signing-ca.sh,
# ota/rauc/release.ext), so rauc's check-purpose=codesign accepts it exactly as it does a release
# signature: a CA that signs nothing but the signing cert, and a CA:FALSE codeSigning leaf.
#
# Only dev images trust it: the dev-image stage is never sourced for a release image, and
# rootfs/guard-rootfs.sh fails a release image whose keyring is anything but the project CA. A
# release device rejects these bundles, and ota/publish-bundle.sh refuses to publish one (it
# verifies against the project CA alone).
#
# Like the dev SSH key (dev.env, work/dev-ssh/), it is per build box, lives under work/ (gitignored,
# kept by `make distclean`), and is never regenerated over itself: images flashed with this CA reject
# bundles signed by any other. Deleting work/dev-pki means reflashing those images once more.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIR="${DEV_PKIDIR:-$ROOT/work/dev-pki}"
RELEASE_EXT="$ROOT/ota/rauc/release.ext"
DAYS="${DEV_DAYS:-3650}"  # a dev image may live for years between reflashes
HOST="$(hostname -s 2>/dev/null || echo local)"

command -v openssl >/dev/null 2>&1 || { echo "openssl not found" >&2; exit 1; }
[ -s "$RELEASE_EXT" ] || { echo "missing or empty cert profile: $RELEASE_EXT" >&2; exit 1; }
if [ -s "$DIR/ca.cert.pem" ] && [ -s "$DIR/release.cert.pem" ] && [ -s "$DIR/release.key.pem" ]; then
  exit 0
fi
if [ -e "$DIR/ca.key.pem" ]; then
  echo "refusing to mint over a partial dev PKI: $DIR (move it aside to start again)" >&2
  exit 1
fi
# Private keys only where git does not look: work/ is ignored, every other path under the repo is
# a tracked tree.
case "$(cd "$(dirname "$DIR")" 2>/dev/null && pwd || echo "$DIR")/" in
  "$ROOT"/work/*|"$ROOT"/out/*) ;;
  "$ROOT"/*) echo "refusing to write private keys inside the repo outside work/ or out/: $DIR" >&2; exit 1 ;;
esac

mkdir -p "$DIR"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
umask 077
openssl req -x509 -newkey rsa:4096 -nodes -sha256 -days "$DAYS" \
  -keyout "$work/ca.key.pem" -out "$work/ca.cert.pem" \
  -subj "/O=retroforge-dev/CN=retroforge DEV OTA CA ($HOST)" \
  -addext "basicConstraints=critical,CA:TRUE,pathlen:0" \
  -addext "keyUsage=critical,keyCertSign,cRLSign" >/dev/null 2>&1
openssl req -newkey rsa:4096 -nodes -sha256 \
  -keyout "$work/release.key.pem" -out "$work/release.csr.pem" \
  -subj "/O=retroforge-dev/CN=retroforge DEV OTA signing ($HOST)" >/dev/null 2>&1
openssl x509 -req -in "$work/release.csr.pem" -CA "$work/ca.cert.pem" -CAkey "$work/ca.key.pem" \
  -CAcreateserial -days "$DAYS" -sha256 -extfile "$RELEASE_EXT" \
  -out "$work/release.cert.pem" >/dev/null 2>&1
openssl verify -CAfile "$work/ca.cert.pem" "$work/release.cert.pem" >/dev/null || {
  echo "the dev signing cert does not verify against the dev CA" >&2
  exit 1
}
# The certs last: a dev PKI is complete only once release.cert.pem is there.
install -m0600 "$work/ca.key.pem" "$work/release.key.pem" "$DIR/"
install -m0644 "$work/ca.cert.pem" "$DIR/ca.cert.pem"
install -m0644 "$work/release.cert.pem" "$DIR/release.cert.pem"
echo "dev signing: minted a dev OTA CA and signing key in ${DIR#"$ROOT"/} (dev images trust it from their next flash)" >&2
