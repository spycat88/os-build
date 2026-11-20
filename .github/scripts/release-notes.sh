#!/usr/bin/env bash
# retroforge release notes — what changed since the previous release in the same tag series, written
# for the people flashing or updating a device.
#
#   .github/scripts/release-notes.sh <tag> <ref> <out-file>
#
#   <tag>  the release tag, e.g. image/v0.0.9 (an image) or ota/v0.0.9. Only its series (`image/`
#          or `ota/`) and whether it is a pre-release are read: a dispatch with publish:true has no
#          tag yet. Images were tagged `card/` up to card/v0.0.8, so the `image/` series also
#          matches those when looking for the previous image.
#   <ref>  the commit being released (GITHUB_SHA).
#
# THE MODEL RUNS ON CLOUDFLARE WORKERS AI, the account that already holds the OTA bucket:
#   CF_ACCOUNT_ID  the Cloudflare account id (CI: the CLOUDFLARE_ACCOUNT_ID secret, which R2 uses too)
#   CF_AI_TOKEN    an API token with Workers AI Read + Edit (CI: the CLOUDFLARE_AI_TOKEN secret)
# through its OpenAI-compatible chat endpoint. Override the model with RELEASE_NOTES_MODEL.
# NOT GitHub Models: that was the first choice and it was retired on 2026-07-30, inference API and all.
#
# FREE, AND IT STAYS FREE. The Workers Free plan includes 10,000 neurons a day and answers over that
# with an error, not a bill (pricing page, 2026-11-07). One summary of ~3k tokens in / 500 out on
# llama-3.3-70b fp8-fast costs ~200 neurons (mistral-small-3.1 was ~120 but looped on one bullet).
# Cloudflare states it neither trains on nor retains the input (workers-ai/platform/data-usage),
# (the repo was private when this was chosen; its commit messages are public since 2026-11).
#
# IT NEVER FAILS A RELEASE. Any failure (no token, quota spent, an empty answer) falls back to a
# plain list of commit subjects, with a ::warning:: saying why. A release held up by a summary is
# worse than a release with a list.
#
# THE INPUT IS CAPPED, so the cost per release stays flat however long the gap since the last one:
# each commit goes in as its subject plus the first paragraph of its body, cut at LOG_CAP characters.
# The commit bodies here are long and explain the WHY; the first paragraph is where the user-visible
# change usually is.
set -euo pipefail

TAG="${1:?usage: $0 <tag> <ref> <out-file>}"
REF="${2:?usage: $0 <tag> <ref> <out-file>}"
OUT="${3:?usage: $0 <tag> <ref> <out-file>}"
MODEL="${RELEASE_NOTES_MODEL:-@cf/meta/llama-3.3-70b-instruct-fp8-fast}"
ENDPOINT="${RELEASE_NOTES_ENDPOINT:-https://api.cloudflare.com/client/v4/accounts/${CF_ACCOUNT_ID:-}/ai/v1/chat/completions}"
LOG_CAP="${RELEASE_NOTES_LOG_CAP:-24000}"
PARA_CAP=600

warn() { echo "::warning::release notes: $*" >&2; }

series="${TAG%%/*}"
# Every prefix the series has been tagged under. Images moved from `card/` to `image/` on
# 2026-11-19; without the old prefix the first image/ tag would find no previous image and fall
# back to "the last 50 commits".
case "$series" in
  image)   prefixes=(image card) ;;
  *)       prefixes=("$series") ;;
esac
match=() exclude=()
for p in "${prefixes[@]}"; do
  match+=(--match "$p/v*")
  exclude+=(--exclude "$p/v*-*")
done
# The previous release in the same series, reachable from this commit and not this commit itself
# (`$REF^`, so a re-run from the tag does not find itself). A stable release compares against the
# previous STABLE one, so its notes cover everything its users have not had, betas included; a beta
# compares against whatever came last.
case "$TAG" in
  *-*) exclude=() ;;
esac
prev="$(git describe --tags --abbrev=0 "${match[@]}" "${exclude[@]}" "$REF^" 2>/dev/null || true)"
if [ -n "$prev" ]; then
  range="$prev..$REF"
else
  range="$REF"
  warn "no earlier $series/ tag reachable from $REF; summarising its last 50 commits"
fi

# One record per commit: subject, then the first paragraph of the body, capped.
log="$(git log --no-merges --max-count=200 --format='%h%x1f%s%x1f%b%x1e' $range \
  | awk -v RS='\x1e' -v FS='\x1f' -v cap="$PARA_CAP" '
      NF >= 2 {
        sha = $1; gsub(/^[ \n]+/, "", sha)
        body = $3; sub(/^[ \n]+/, "", body)
        n = index(body, "\n\n"); if (n) body = substr(body, 1, n - 1)
        gsub(/\n/, " ", body)
        if (length(body) > cap) body = substr(body, 1, cap) "..."
        printf "- %s %s\n", sha, $2
        if (body != "") printf "  %s\n", body
      }')"
[ -n "$prev" ] || log="$(printf '%s\n' "$log" | awk '/^- /{n++} n<=50')"
subjects="$(git log --no-merges --max-count=200 --format='- %s' $range)"
[ -n "$prev" ] || subjects="$(printf '%s\n' "$subjects" | head -50)"

if [ -z "$subjects" ]; then
  echo "No changes since ${prev:-the previous release}." >"$OUT"
  exit 0
fi
if [ "${#log}" -gt "$LOG_CAP" ]; then
  log="$(printf '%s\n' "$subjects" | head -c "$LOG_CAP")"
fi

fallback() {
  warn "$1; using the commit list"
  {
    echo "### Changes since ${prev:-the start}"
    echo
    printf '%s\n' "$subjects"
  } >"$OUT"
  exit 0
}

[ -n "${CF_AI_TOKEN:-}" ] || fallback "no CF_AI_TOKEN (the CLOUDFLARE_AI_TOKEN secret)"
[ -n "${CF_ACCOUNT_ID:-}" ] || [ -n "${RELEASE_NOTES_ENDPOINT:-}" ] || fallback "no CF_ACCOUNT_ID (the CLOUDFLARE_ACCOUNT_ID secret)"
command -v jq >/dev/null || fallback "jq is not installed"

system='You write the release notes for RetroForge, a Linux OS for handheld game consoles (Snapdragon handhelds from AYN, AYANEO, Retroid, Anbernic, Mangmi, KONKR and others). The readers are players, not developers. You are given the commit log since the previous release, in Conventional Commits form (feat, fix, perf, ...; the scope is in parentheses).

Write short, friendly Markdown notes that tell a player what is better for them:
- Use only these level-3 sections, in this order, and leave out any that would be empty: "### New", "### Fixes", "### Devices".
- AT MOST 10 BULLETS IN TOTAL; fewer is better. Group every commit about the same topic into ONE bullet (all the firmware commits are one bullet, all the installer commits are one bullet). Never write two bullets that say the same thing.
- Plain words only. Never mention kernels, modules, drivers, firmware loaders, partitions, ADSP, AudioReach, PD, WPSS, GPR, udev, snapshots, packages or file names. Say what the player sees: sound, Wi-Fi, sleep, battery, screen, controls, games, installing, updating.
- Friendly and light, like a good app-store changelog. Lead with the benefit. No exclamation marks, no emoji, no marketing superlatives.
- Only claim an effect the commit itself states. A "perf" commit may become "faster" or "smoother"; a "fix" commit may become "no longer ..." or "works again". Never attach a reason or a benefit the commit does not give.
- If a commit names only a chip (SM8250, SM6115, SM4450, ...), say "more Snapdragon devices" or similar; never guess device models. Name a device only when the commit names it.
- Leave out CI, release, workflow, test, build, pin, relock, snapshot, refactor and documentation commits, and anything a player would not notice.
- No version number, no title, no preamble, no closing remarks.

Bad: "The system should boot faster, as the loader maps super without a partition scan."
Good: "Faster startup."
Bad: "The Air X and Air Y now use their own ADSP on AudioReach."
Good: "Reworked sound on the AYANEO Air X and Air Y."'

body="$(jq -n --arg model "$MODEL" --arg system "$system" \
  --arg user "Release ${TAG#*/}. Commits since ${prev:-the start}:"$'\n\n'"$log" \
  '{model: $model, temperature: 0.3, max_tokens: 800, frequency_penalty: 0.5,
    messages: [{role: "system", content: $system}, {role: "user", content: $user}]}')"

resp="$(curl -sS --max-time 120 -w '\n%{http_code}' "$ENDPOINT" \
  -H "Authorization: Bearer $CF_AI_TOKEN" \
  -H 'Content-Type: application/json' \
  -d "$body" 2>&1)" || fallback "request to Workers AI failed: $(printf '%s' "$resp" | tail -c 300)"
code="$(printf '%s' "$resp" | tail -n1)"
resp="$(printf '%s' "$resp" | sed '$d')"
[ "$code" = 200 ] || fallback "Workers AI answered HTTP $code: $(printf '%s' "$resp" | tr '\n' ' ' | head -c 300)"

# OpenAI-shaped from this endpoint; the native /ai/run shape ({result: {response}}) is accepted too,
# so pointing RELEASE_NOTES_ENDPOINT at it needs no other change.
notes="$(printf '%s' "$resp" | jq -r '.choices[0].message.content // .result.response // empty' 2>/dev/null || true)"
# A small model can loop on one bullet until max_tokens: a cut-off answer is not published, and a
# repeated line is dropped.
[ "$(printf '%s' "$resp" | jq -r '.choices[0].finish_reason // empty' 2>/dev/null || true)" != length ] \
  || fallback "Workers AI ran out of tokens (a looping answer)"
notes="$(printf '%s\n' "$notes" | awk '/^[-*] / { if (seen[$0]++) next } { print }')"
[ -n "${notes//[[:space:]]/}" ] || fallback "Workers AI returned no text"

printf '%s\n' "$notes" >"$OUT"
echo "release notes: $MODEL summarised $(printf '%s\n' "$subjects" | wc -l) commits since ${prev:-the start}" >&2
