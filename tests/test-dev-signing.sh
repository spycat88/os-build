#!/usr/bin/env bash
# Offline test for ota/gen-dev-signing.sh: the build box's dev OTA key, which lets a dev image take a
# new build as an update (rauc install) instead of a reflash that erases its /home.
#
#   tests/test-dev-signing.sh
#
# WHY THIS EXISTS. Every rule below fails as a dev image that refuses its next bundle, which is found
# only after a full build and a copy to the device: a CA regenerated over the one images were flashed
# with; a signing cert rauc's check-purpose=codesign does not accept; private keys written into a
# tracked tree; a keyring of the project CA plus the dev CA that does not verify the dev signature.
# The guard's side (a release keyring is the project CA alone) is in rootfs/guard-rootfs.sh.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GEN="$ROOT/ota/gen-dev-signing.sh"
CA="$ROOT/ota/rauc/retroforge-ca.pem"
for f in "$GEN" "$CA"; do [ -f "$f" ] || { echo "missing: $f" >&2; exit 1; }; done
command -v openssl >/dev/null || { echo "needs openssl" >&2; exit 1; }

PASS=0; FAIL=0; CASE=""
ok()  { PASS=$((PASS+1)); printf '  ok   %s -- %s\n' "$CASE" "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s -- %s\n' "$CASE" "$1"; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mode() { stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1"; }
fpr() { openssl x509 -in "$1" -noout -fingerprint -sha256 | cut -d= -f2; }

CASE="mint"
DEV_PKIDIR="$T/pki" bash "$GEN" 2>"$T/err"; rc=$?
[ "$rc" = 0 ] && for f in ca.cert.pem ca.key.pem release.cert.pem release.key.pem; do [ -s "$T/pki/$f" ] || rc=9; done
[ "$rc" = 0 ] && ok "a dev CA and a signing cert and key, under the names the real PKI uses" || bad "rc=$rc $(ls "$T/pki" 2>&1) $(cat "$T/err")"
[ "$(mode "$T/pki/ca.key.pem")" = 600 ] && [ "$(mode "$T/pki/release.key.pem")" = 600 ] \
  && ok "private keys 0600" || bad "modes: $(mode "$T/pki/ca.key.pem") $(mode "$T/pki/release.key.pem")"
openssl verify -CAfile "$T/pki/ca.cert.pem" "$T/pki/release.cert.pem" >/dev/null 2>&1 \
  && ok "the signing cert chains to the dev CA" || bad "does not verify"
text="$(openssl x509 -in "$T/pki/release.cert.pem" -noout -text)"
grep -q "CA:FALSE" <<<"$text" && grep -q "Code Signing" <<<"$text" \
  && ok "the signing cert has the release profile: CA:FALSE, code signing (rauc's check-purpose=codesign)" || bad "$text"
grep -q "CA:TRUE" <<<"$(openssl x509 -in "$T/pki/ca.cert.pem" -noout -text)" && ok "the CA is a CA" || bad "no CA:TRUE"
grep -q "retroforge-dev" <<<"$(openssl x509 -in "$T/pki/ca.cert.pem" -noout -subject)" \
  && ! cmp -s "$T/pki/ca.cert.pem" "$CA" && ok "it is not the project CA, and says it is a dev one" || bad "subject or equal to the project CA"

CASE="never over itself"
before="$(fpr "$T/pki/ca.cert.pem")"
DEV_PKIDIR="$T/pki" bash "$GEN" 2>"$T/err"; rc=$?
[ "$rc" = 0 ] && [ "$(fpr "$T/pki/ca.cert.pem")" = "$before" ] && [ ! -s "$T/err" ] \
  && ok "run again: the same CA, nothing said (images flashed with it keep taking its bundles)" || bad "rc=$rc $(cat "$T/err")"
mkdir -p "$T/partial"; echo key >"$T/partial/ca.key.pem"
DEV_PKIDIR="$T/partial" bash "$GEN" 2>"$T/err"; rc=$?
[ "$rc" = 1 ] && grep -q "partial dev PKI" "$T/err" && [ "$(cat "$T/partial/ca.key.pem")" = key ] \
  && ok "a partial PKI (a CA key without its certs): refused, untouched" || bad "rc=$rc $(cat "$T/err")"
DEV_PKIDIR="$ROOT/ota/rauc/devtest" bash "$GEN" 2>"$T/err"; rc=$?
[ "$rc" = 1 ] && [ ! -e "$ROOT/ota/rauc/devtest" ] && grep -q "inside the repo" "$T/err" \
  && ok "private keys never inside the tracked tree" || { bad "rc=$rc $(cat "$T/err")"; rm -rf "$ROOT/ota/rauc/devtest"; }

CASE="a dev image's keyring"
{ cat "$CA"; echo; cat "$T/pki/ca.cert.pem"; } >"$T/keyring.pem"
openssl verify -CAfile "$T/keyring.pem" "$T/pki/release.cert.pem" >/dev/null 2>&1 \
  && ok "the project CA then the dev CA, in one keyring: the dev signature verifies" || bad "does not verify against the two-CA keyring"
if openssl verify -purpose codesign -CAfile "$T/keyring.pem" "$T/pki/release.cert.pem" >/dev/null 2>&1; then
  ok "with the codesign purpose rauc checks, too"
elif openssl verify -help 2>&1 | grep -q codesign; then
  bad "the codesign purpose rejects the dev signing cert"
else
  printf '  skip %s -- this openssl has no codesign purpose\n' "$CASE"
fi
! openssl verify -CAfile "$CA" "$T/pki/release.cert.pem" >/dev/null 2>&1 \
  && ok "the project CA alone (a release device) does not accept it" || bad "the project CA accepts a dev signature"

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
