#!/bin/sh
# Fetch this month's DB-IP "IP to Country Lite" database (CC BY 4.0, no account needed) to
# $1 (default /var/lib/retroforge-telemetry/country.mmdb). Run monthly from cron or a timer, then
# `systemctl restart retroforge-telemetry-server` so the server reopens it.
set -eu
out=${1:-/var/lib/retroforge-telemetry/country.mmdb}
month=$(date -u +%Y-%m)
tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT
curl -fsSL "https://download.db-ip.com/free/dbip-country-lite-$month.mmdb.gz" | gunzip >"$tmp"
install -m 0644 "$tmp" "$out"
echo "GeoIP database updated: $out ($month)"
