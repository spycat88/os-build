# retroforge R2 plumbing — the pinned rclone and the credential environment, used by
# ota/publish-bundle.sh to put OTA bundles in the bucket devices update from.
#
# Sourced, never executed. Its own file so the credential setup and the fetch-and-verify live in one
# place; it served the image publisher too until images became GitHub Release assets (2026-10-13).
# shellcheck shell=bash

RCLONE_PIN="${RCLONE_PIN:-$ROOT/ota/rclone.pin}"

pin_field() { sed -n "s/^$2:[[:space:]]*//p" "$1" | head -1; }

# --- rclone, pinned -------------------------------------------------------------------------
# Fetched to work/tools/ and verified against ota/rclone.pin rather than installed from a distro
# repo: the tool that moves our artifacts should not float between a runner and a developer's box.
rclone_bin() {
  local ver url sha host dest zip dir
  # THE ONE TEST SEAM, and the only way either publisher can be exercised offline. The path this
  # returns is absolute and lives under work/tools/, so a suite cannot stub it by shadowing PATH,
  # and pre-creating that path would overwrite the real binary an operator has already fetched.
  # tests/test-publish-bundle.sh sets this; nothing in CI or in a publish ever should.
  if [ -n "${RETROFORGE_RCLONE:-}" ]; then
    printf '%s\n' "$RETROFORGE_RCLONE"
    return 0
  fi
  [ -f "$RCLONE_PIN" ] || die "no rclone pin: $RCLONE_PIN"
  ver="$(pin_field "$RCLONE_PIN" version)"
  case "$(uname -m)" in
    x86_64)        host=amd64 ;;
    aarch64|arm64) host=arm64 ;;
    *) die "no pinned rclone for $(uname -m) — add it to $RCLONE_PIN" ;;
  esac
  url="$(pin_field "$RCLONE_PIN" "url_$host")"
  sha="$(pin_field "$RCLONE_PIN" "sha256_$host")"
  [ -n "$ver" ] && [ -n "$url" ] && [ -n "$sha" ] || die "$RCLONE_PIN: missing version/url/sha for $host"

  dest="$ROOT/work/tools/rclone-$ver-$host/rclone"
  if [ ! -x "$dest" ]; then
    log "fetching rclone $ver ($host)"
    mkdir -p "$(dirname "$dest")"
    zip="$(mktemp)"
    curl -fsSL "$url" -o "$zip" || die "rclone $ver: download failed ($url)"
    # Verify BEFORE extracting, exactly as oras_bin does: an archive is executed-adjacent code, and
    # checking it after unpacking means the bad bytes already reached the filesystem.
    echo "$sha  $zip" | sha256sum -c --status - \
      || { rm -f "$zip"; die "rclone $ver: sha256 mismatch against $RCLONE_PIN"; }
    dir="$(mktemp -d)"
    unzip -q -j "$zip" "*/rclone" -d "$dir" || die "rclone $ver: archive has no rclone binary"
    mv "$dir/rclone" "$dest"
    rm -rf "$zip" "$dir"
    chmod +x "$dest"
  fi
  printf '%s\n' "$dest"
}

# --- the R2 remote --------------------------------------------------------------------------
# Configured entirely through the environment so no credential is ever written to disk — the same
# instinct as .github/workflows/image.yml keeping the RAUC key in $RUNNER_TEMP: anything left in the
# workspace gets swept into artifacts and caches. The remote is named "r2"; paths are r2:<bucket>/...
# The three credentials use :? so EMPTY fails as loudly as unset, which is the case that actually
# happens: in CI they are always *set*, to whatever `${{ secrets.R2_* }}` evaluated to, and an
# environment-scoped secret evaluates to the EMPTY STRING in any job that does not declare that
# environment. No error, no warning, at the point of evaluation. The message names that case rather
# than making you rediscover it after a build.
R2_ENV_HINT='not set. In CI: check the secret exists (repo settings), and if it is scoped to an
  environment, that the job names that environment -- an environment-scoped secret reads as EMPTY,
  silently, in a job that does not.'
r2_env() {
  : "${R2_ACCOUNT_ID:?R2_ACCOUNT_ID $R2_ENV_HINT}"
  : "${R2_ACCESS_KEY_ID:?R2_ACCESS_KEY_ID $R2_ENV_HINT}"
  : "${R2_SECRET_ACCESS_KEY:?R2_SECRET_ACCESS_KEY $R2_ENV_HINT}"
  : "${R2_BUCKET:?R2_BUCKET not set}"
  : "${R2_PUBLIC_BASE:?R2_PUBLIC_BASE not set (the r2.dev URL, or a custom domain if one is attached)}"

  export RCLONE_CONFIG_R2_TYPE=s3
  export RCLONE_CONFIG_R2_PROVIDER=Cloudflare
  export RCLONE_CONFIG_R2_ENDPOINT="https://${R2_ACCOUNT_ID}.r2.cloudflarestorage.com"
  export RCLONE_CONFIG_R2_ACCESS_KEY_ID="$R2_ACCESS_KEY_ID"
  export RCLONE_CONFIG_R2_SECRET_ACCESS_KEY="$R2_SECRET_ACCESS_KEY"
  export RCLONE_CONFIG_R2_REGION=auto
  # R2 implements no per-object ACLs; asking for one makes every PUT fail. Public access is a
  # BUCKET setting (Settings -> Public access -> r2.dev subdomain), which is why this says private
  # and the bucket is what is public.
  export RCLONE_CONFIG_R2_NO_CHECK_BUCKET=true
  export RCLONE_CONFIG_R2_ACL=private
}
