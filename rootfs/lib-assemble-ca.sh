#!/usr/bin/env bash
# retroforge read-only root assembler — stages `ca-anchors`.
#
# SOURCED by rootfs/assemble-rootfs.sh, never executed.
#
# Runs on EVERY build, release included, AFTER overlay-payload (which lays the anchors down).
#
# Reads the assembler's globals rather than taking arguments -- $stage (the staged tree).

# STAGE ca-anchors — extra trust anchors RetroForge ships on top of the Mozilla store.
#
# The anchors live in rootfs/overlay/etc/ca-certificates/trust-source/anchors/, the local-anchor
# directory p11-kit reads. That alone covers NSS (Chromium, Steam's CEF), which loads p11-kit-trust
# and reads trust-source at runtime, and it survives an on-device `update-ca-trust`. It does NOT
# cover OpenSSL / GnuTLS / curl / Python: they read the files update-ca-trust EXTRACTED, and those
# were extracted in customize-base.sh, before the overlay existed, and the root is read-only at
# runtime. So each anchor is added here to the two extracted forms those libraries read:
#   extracted/tls-ca-bundle.pem   (/etc/ssl/certs/ca-certificates.crt links to it: curl, GnuTLS, Python)
#   extracted/cadir/ + its hash link, and /etc/ssl/certs/<hash>.0 (OpenSSL's CApath lookup)
# It is done by hand rather than by re-running update-ca-trust because the assembler runs on the
# build host, not in the target. rootfs/guard-rootfs.sh checks the result.
#
# Current anchors:
#   isrg-root-yr.crt   Let's Encrypt's Gen Y RSA root (ISRG Root YR, 2025-2045). LE's Gen Y leaves
#                      chain leaf -> YR1/YR2/YR3 -> Root YR, and servers that do not also send the
#                      YR-by-X1 cross-sign (dpaste.com, 2026-11) fail "unable to get local issuer
#                      certificate" against a Mozilla store that does not have Root YR yet. Taken
#                      from letsencrypt.org/certificates; SHA-256 E5:7B:7E:6F:15:0C:41:91:02:E8:D5:C0:
#                      55:72:9F:F9:67:B9:D1:A8:29:BF:00:CE:C8:9C:A6:04:EB:F4:A8:6F. Drop it once the
#                      pinned ca-certificates-mozilla carries it (this stage then says so).
ca_anchors="$stage/etc/ca-certificates/trust-source/anchors"
ca_extracted="$stage/etc/ca-certificates/extracted"
if compgen -G "$ca_anchors/*.crt" >/dev/null; then
  [ -s "$ca_extracted/tls-ca-bundle.pem" ] || {
    echo "ca-anchors: $ca_extracted/tls-ca-bundle.pem is missing -- the base never extracted its CA store" >&2; exit 1; }
  for ca_crt in "$ca_anchors"/*.crt; do
    ca_name="${ca_crt##*/}"; ca_name="${ca_name%.crt}"
    ca_body="$(sed '/-----/d' "$ca_crt" | tr -d '\n')"
    if tr -d '\n' <"$ca_extracted/tls-ca-bundle.pem" | grep -qF "$ca_body"; then
      echo "  ca-anchors: $ca_name is already in the extracted store (Mozilla now carries it? then drop it from rootfs/overlay)"
      continue
    fi
    echo "  ca-anchors: + $ca_name ($(openssl x509 -in "$ca_crt" -noout -subject | sed 's/^subject=//'))"
    ca_mode="$(stat -c %a "$ca_extracted/tls-ca-bundle.pem")"
    chmod u+w "$ca_extracted/tls-ca-bundle.pem"
    { printf '# %s\n' "$ca_name"; openssl x509 -in "$ca_crt"; } >>"$ca_extracted/tls-ca-bundle.pem"
    chmod "$ca_mode" "$ca_extracted/tls-ca-bundle.pem"
    if [ -d "$ca_extracted/cadir" ]; then
      ca_hash="$(openssl x509 -in "$ca_crt" -noout -subject_hash)"
      ca_n=0
      while [ -e "$ca_extracted/cadir/$ca_hash.$ca_n" ] || [ -L "$ca_extracted/cadir/$ca_hash.$ca_n" ]; do ca_n=$((ca_n + 1)); done
      ca_dir_mode="$(stat -c %a "$ca_extracted/cadir")"
      chmod u+w "$ca_extracted/cadir"
      openssl x509 -in "$ca_crt" -out "$ca_extracted/cadir/$ca_name.pem"
      chmod 0444 "$ca_extracted/cadir/$ca_name.pem"
      ln -s "$ca_name.pem" "$ca_extracted/cadir/$ca_hash.$ca_n"
      chmod "$ca_dir_mode" "$ca_extracted/cadir"
      # Arch's /etc/ssl/certs mirrors cadir with relative links; follow suit when it does.
      if [ -d "$stage/etc/ssl/certs" ] && [ ! -e "$stage/etc/ssl/certs/$ca_hash.$ca_n" ] \
         && find "$stage/etc/ssl/certs" -maxdepth 1 -lname '*ca-certificates/extracted/cadir/*' -print -quit | grep -q .; then
        ln -s "../../ca-certificates/extracted/cadir/$ca_hash.$ca_n" "$stage/etc/ssl/certs/$ca_hash.$ca_n"
      fi
    fi
  done
fi
unset ca_anchors ca_extracted ca_crt ca_name ca_body ca_mode ca_hash ca_n ca_dir_mode
