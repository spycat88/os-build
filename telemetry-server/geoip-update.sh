#!/bin/sh
# Fetch this month's DB-IP "IP to Country Lite" database (CC BY 4.0, no account needed) to
# $1 (default: data/country.mmdb next to this script). Run monthly from cron. report.php opens the
# file per request, so nothing needs restarting.
set -eu
out=${1:-$(dirname "$0")/data/country.mmdb}
month=$(date -u +%Y-%m)
tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT
curl -fsSL "https://download.db-ip.com/free/dbip-country-lite-$month.mmdb.gz" | gunzip >"$tmp"
mv -f "$tmp" "$out"
chmod 0644 "$out"
echo "GeoIP database updated: $out ($month)"
