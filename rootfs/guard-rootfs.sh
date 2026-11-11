#!/usr/bin/env bash
# retroforge sealed-root guard — assert on the BUILT TREE (Phase 4a step 4).
#
#   rootfs/guard-rootfs.sh <staged-root>
#
# The last thing that looks at a release root before it is frozen into rootfs.img. Everything
# earlier in Phase 4a is a declaration — the lock says what installs, seal.list says what is
# stripped — and a declaration that is never checked against the artifact it describes is a
# comment. This is the check.
#
# WHY ON THE TREE AND NOT ON THE SOURCE DIFF: this repo has already shipped a source change that
# was correct in the diff and wrong in the built tree (a file-mode regression that reached
# hardware and blacked out the OOBE). A guard that reads seal.list and seal-rootfs.sh and
# concludes they agree would have caught none of it. So every assertion below opens files in the
# staged tree.
#
# The staged tree IS the image: section 6 of rootfs/assemble-rootfs.sh hands exactly this
# directory to `mkfs.btrfs --rootdir`, and /var is carved out of it into var.img. Nothing between
# here and there adds content. (The one gap: this asserts the tree, not the image bytes — reading
# a btrfs image back would need a mount, which the unprivileged build deliberately avoids.)
#
# RELEASE ONLY, like the seal itself. A RETROFORGE_DEV tree keeps the package manager on purpose
# and carries DEV_PKGS that the lock does not describe, so most of this would be asserting the
# wrong thing. rootfs/assemble-rootfs.sh calls this only on the release path.
#
# What it asserts:
#   1. the seal's declaration is fully applied — every file the stripped packages own is gone,
#      expanded from the preserved database rather than from a hand-kept list
#   2. the named package-manager entry points are gone (a short, human-legible belt that does not
#      depend on the database being honest)
#   3. no dangling systemd enable-symlink — the failure mode a package removal actually leaves
#      behind, and the one that would keep a stripped unit "enabled"
#   4. rootfs/manifest.lock still describes this tree: same package set, same versions, and its
#      `stripped` rows are exactly what seal.list removes
#   5. the trim's declaration is fully applied — nothing rootfs/conf/trim.list names survived
#   6. the first-boot identity is shippable — no /etc/machine-id, AND systemd-firstboot masked
#      (the two are only safe together); plus /etc/os-release carrying the per-build identity
#      that non-retroforge software reads, agreeing with /etc/retroforge-release
#   7. the RAUC update path is installable — rauc, the keyring, system.conf and this slot's
#      own boot.img are all present, and the hook that consumes them is executable;
#   8. the system UID/GID allocation matches the pin — the ids baked into this tree's passwd and
#      group are the ones rootfs/overlay's sysusers.d pin names, not whatever sysusers counted down to
#   9. no Steam, x86-emulation or Android payload came back — those stacks were removed on
#      purpose, and a stray prebuilt pin or overlay copy would bring them back silently (the
#      Steam client, the FEX x86 guest and Proton-CachyOS are downloaded into /home on
#      demand, never shipped; no box64 or x86 binfmt_misc entry either); and (9b)
#      the shell landed where the session looks for it, without its self-updater
#  10. Python bytecode is the image's own: no host-CPython __pycache__, which rootfs/overlay's
#      verbatim copy carries in whenever an offline suite has imported one of its Python clients,
#      and the stdlib compiled by the image's interpreter (customize-base.sh)
#  11. every path is owned by a uid and gid this tree's own /etc/passwd and /etc/group declare, and
#      no setuid/setgid file arrived that the permit list does not name
#  12. a size delta against the previous build (report only — never fails a build)
set -euo pipefail
shopt -s nullglob

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
STAGE="${1:?usage: rootfs/guard-rootfs.sh <staged-root>}"
LOCK="$ROOT/rootfs/manifest.lock"
LIST="$STAGE/usr/lib/retroforge/seal.list"
TRIMLIST="$STAGE/usr/lib/retroforge/trim.list"
DB="$STAGE/usr/lib/retroforge/pkgdb"
SIZES="$ROOT/out/images/rootfs.sizes"

[ -d "$STAGE" ] || { echo "no staged root: $STAGE" >&2; exit 2; }

fail=0
bad() { echo "  GUARD FAIL: $*" >&2; fail=1; }

echo "  guarding the sealed release root (rootfs/guard-rootfs.sh)"

# Preconditions. Both artifacts are written by rootfs/seal-rootfs.sh, so their absence means the
# seal did not run — and then assertion 1 would pass vacuously over an empty declaration, which is
# the one way a guard can be worse than no guard.
[ -f "$LIST" ] || { echo "  GUARD FAIL: no $LIST — the seal did not run on this tree" >&2; exit 1; }
[ -d "$DB" ]   || { echo "  GUARD FAIL: no $DB — the seal did not run on this tree" >&2; exit 1; }
[ -f "$LOCK" ] || { echo "  GUARD FAIL: no ${LOCK#"$ROOT"/}" >&2; exit 1; }

# ------------------------------------------------------------------------------------------
# 1. The declaration is fully applied.
#
# Read the seal list from the IMAGE, not from the repo: the image's own copy is what it claims
# about itself, and checking the repo copy instead would let a stale image pass against a freshly
# edited declaration. Each name is expanded through the preserved database exactly the way the
# sealer expanded it, so this catches a file the sealer skipped — not just a name it never saw.
# ------------------------------------------------------------------------------------------
desc_field() { sed -n "/^%$2%\$/{n;p;q}" "$1"; }

pkgs=() paths=()
while read -r kind value _; do
  case "$kind" in
    pkg)  pkgs+=("$value") ;;
    path) paths+=("$value") ;;
  esac
done < "$LIST"
[ "${#pkgs[@]}" -gt 0 ] || { echo "  GUARD FAIL: $LIST declares no packages" >&2; exit 1; }

checked=0
survivors=0
declare -A OWNED       # every file the stripped packages own — assertion 2 checks itself against it
for p in "${pkgs[@]}"; do
  dbdir=""
  for d in "$DB/$p"-*/; do
    [ -f "$d/desc" ] || continue
    [ "$(desc_field "$d/desc" NAME)" = "$p" ] || continue
    dbdir="$d"; break
  done
  # The database is what makes the expansion possible; a stripped package missing from it means
  # the provenance copy is incomplete, and assertion 1 silently stops covering that package.
  [ -n "$dbdir" ] || { bad "'$p' is on the removal list but has no entry under usr/lib/retroforge/pkgdb"; continue; }

  in_files=0
  while IFS= read -r rel; do
    case "$rel" in
      '%FILES%') in_files=1; continue ;;
      '%'*)      in_files=0; continue ;;
      ''|*/)     continue ;;              # directories are shared; the sealer only rmdirs empty ones
    esac
    [ "$in_files" = 1 ] || continue
    checked=$((checked + 1))
    OWNED["$rel"]=1
    # -e is false for a dangling symlink, so test -L too — a broken link left behind is exactly
    # the kind of leftover this is looking for.
    if [ -e "$STAGE/$rel" ] || [ -L "$STAGE/$rel" ]; then
      survivors=$((survivors + 1))
      [ "$survivors" -gt 10 ] || bad "$p still owns $rel"
    fi
  done < "$dbdir/files"
done
if [ "$survivors" -gt 10 ]; then bad "... and $((survivors - 10)) more files from stripped packages"; fi
if [ "$survivors" = 0 ]; then echo "    ok  ${#pkgs[@]} stripped packages: all $checked files gone"; fi

paths_bad=0
for p in "${paths[@]}"; do
  if [ -e "$STAGE/$p" ] || [ -L "$STAGE/$p" ]; then bad "declared path still present: $p"; paths_bad=1; fi
done
if [ "$paths_bad" = 0 ]; then echo "    ok  ${#paths[@]} declared paths gone"; fi

# ------------------------------------------------------------------------------------------
# 2. The named entry points, spelled out.
#
# Redundant with assertion 1 while the database is honest — and that is the point. Assertion 1
# trusts usr/lib/retroforge/pkgdb to say what a package owned; this list trusts nothing, so a
# truncated or wrong database cannot make the guard pass. These are also the names a person
# reviewing this file wants to see stated: the shutdown stall (dirmngr) and the ability of a
# running device to mutate its own read-only root (pacman).
# ------------------------------------------------------------------------------------------
NAMED=(
  usr/bin/pacman usr/bin/pacman-key usr/bin/pacman-conf usr/bin/makepkg usr/bin/repo-add
  usr/bin/gpg usr/bin/gpg-agent usr/bin/dirmngr usr/bin/gpgconf
  usr/lib/systemd/system/dirmngr@.service
  usr/lib/systemd/system/timers.target.wants/archlinux-keyring-wkd-sync.timer
  etc/pacman.conf etc/pacman.d var/lib/pacman
)
named_bad=0
for n in "${NAMED[@]}"; do
  if [ -e "$STAGE/$n" ] || [ -L "$STAGE/$n" ]; then bad "package-manager runtime survived: $n"; named_bad=1; fi
  # A hand-kept list of paths that must be absent is self-fulfilling if a name is misspelled: the
  # typo is absent from every tree ever built, so the line asserts nothing, forever. Require each
  # name to be something the declaration actually removes — owned by a stripped package, or under a
  # declared path row. This uses the database to validate the LIST, never to make the assertion.
  if [ -z "${OWNED["$n"]:-}" ]; then
    covered=0
    for p in "${paths[@]}"; do
      case "$n" in "$p"|"$p"/*) covered=1; break ;; esac
    done
    if [ "$covered" = 0 ]; then
      bad "guard names '$n', which rootfs/conf/seal.list does not remove — dead assertion (typo, or the list moved on)"
      named_bad=1
    fi
  fi
done
if [ "$named_bad" = 0 ]; then echo "    ok  no pacman/gnupg/dirmngr entry point, no /var/lib/pacman"; fi

# ------------------------------------------------------------------------------------------
# 3. No dangling systemd enable-symlink.
#
# Deleting a package's files deletes its units but NOT the .wants/.requires symlinks other
# packages (or we) point at them, and a vendor enable-symlink is precisely how the keyring's
# weekly timer stayed on in the first place. A link to a unit that no longer exists is systemd
# telling us the removal was incomplete.
#
# Scoped to .wants/.requires deliberately: the tree carries ~48 pre-existing dangling absolute
# symlinks elsewhere (all from the base image, none of them ours), so a whole-tree check would
# fail every build for a condition this step did not create. A mask (-> /dev/null) is valid.
# ------------------------------------------------------------------------------------------
wants_bad=0
wants_seen=0
while IFS= read -r -d '' w; do
  for l in "$w"/*; do
    [ -L "$l" ] || continue
    wants_seen=$((wants_seen + 1))
    t="$(readlink "$l")"
    [ "$t" = /dev/null ] && continue
    case "$t" in
      /*) target="$STAGE$t" ;;
      *)  target="$w/$t" ;;
    esac
    if [ ! -e "$target" ]; then
      bad "dangling enable-symlink: ${l#"$STAGE"/} -> $t"
      wants_bad=1
    fi
  done
done < <(find "$STAGE/usr/lib/systemd" "$STAGE/etc/systemd" \
              \( -name '*.wants' -o -name '*.requires' \) -type d -print0 2>/dev/null)
if [ "$wants_bad" = 0 ]; then echo "    ok  $wants_seen enable-symlinks, all resolve"; fi

# ------------------------------------------------------------------------------------------
# 3b. The pairing daemon is never enabled at boot.
#
# retroforge-pairingd accepts an SSH key from anyone on the network. It runs only while Settings >
# General > Remote access has it on (plan ota-ui D5): no [Install], no preset, no enable link. Any
# one of the three coming back -- a preset, a build step, a restored symlink -- makes pairing
# always-on again with nothing else failing, so the sealed tree is checked, not just the overlay.
# ------------------------------------------------------------------------------------------
pair_bad=0
PAIR_UNIT="$STAGE/usr/lib/systemd/system/retroforge-pairingd.service"
if [ -f "$PAIR_UNIT" ] && grep -qE '^\[Install\]|^WantedBy=' "$PAIR_UNIT"; then
  bad "retroforge-pairingd.service has an [Install] section: something can enable pairing at boot"
  pair_bad=1
fi
while IFS= read -r -d '' l; do
  bad "pairing enabled at boot: ${l#"$STAGE"/}"
  pair_bad=1
done < <(find "$STAGE/usr/lib/systemd" "$STAGE/etc/systemd" -path '*.wants/retroforge-pairingd.service' -print0 2>/dev/null)
if grep -rqsE '^enable[[:space:]]+retroforge-pairingd' "$STAGE/usr/lib/systemd/system-preset" "$STAGE/etc/systemd/system-preset"; then
  bad "a systemd preset enables retroforge-pairingd"
  pair_bad=1
fi
if [ "$pair_bad" = 0 ]; then echo "    ok  pairing is not enabled at boot (no [Install], link or preset)"; fi

# ------------------------------------------------------------------------------------------
# 4. The lock still describes this tree.
#
# The payoff of steps 1-3: rootfs/manifest.lock is a committed, reviewed artifact, and this is
# where it stops being a claim. Two directions, both required —
#
#   set equality  every package the tree has is in the lock at the same version, and vice versa.
#                 A build that installs from the lock cannot drift, which is the argument for
#                 checking it rather than for not bothering: if it ever differs, something
#                 outside the locked install path put a package on the image.
#   stripped rows the lock's `stripped` class must be exactly seal.list's `pkg` rows. Those two
#                 files are edited by hand and are the pair that has to stay in step — the whole
#                 reason the lock carries the class at all is so ONE artifact describes the image.
#
# `prebuilt` rows are excluded: they are tarballs from packages/*/prebuilt.pin, not pacman
# packages, so they were never in a package database to begin with.
# ------------------------------------------------------------------------------------------
lock_set="$(awk '!/^#/ && NF && $4 != "prebuilt" { print $1 "-" $2 }' "$LOCK" | LC_ALL=C sort)"
tree_set="$(cd "$DB" && ls -1 | grep -vx 'ALPM_DB_VERSION' | LC_ALL=C sort)"
if [ "$lock_set" != "$tree_set" ]; then
  bad "rootfs/manifest.lock does not describe this tree:"
  diff <(printf '%s\n' "$lock_set") <(printf '%s\n' "$tree_set") \
    | sed -n 's/^</    only in lock: /p; s/^>/    only in tree: /p' >&2 || true
  echo "    (regenerate with \`make relock\` and review the diff)" >&2
else
  echo "    ok  manifest.lock matches the tree ($(printf '%s\n' "$lock_set" | wc -l) packages)"
fi

lock_stripped="$(awk '!/^#/ && $4 == "stripped" { print $1 }' "$LOCK" | LC_ALL=C sort)"
list_stripped="$(printf '%s\n' "${pkgs[@]}" | LC_ALL=C sort)"
if [ "$lock_stripped" != "$list_stripped" ]; then
  bad "the lock's 'stripped' rows and seal.list disagree:"
  diff <(printf '%s\n' "$lock_stripped") <(printf '%s\n' "$list_stripped") \
    | sed -n 's/^</    only in lock: /p; s/^>/    only in seal.list: /p' >&2 || true
fi

# ------------------------------------------------------------------------------------------
# 5. The trim's declaration is fully applied.
#
# Same argument as assertion 1, for the other declaration: rootfs/conf/trim.list is edited by hand,
# and a trim that half-ran (or did not run at all) leaves an image that is simply bigger than
# intended — the one failure mode with no symptom until a slot stops fitting, by which point the
# build that caused it is long past.
#
# Read from the IMAGE's copy, like the seal list, so a stale tree cannot pass against a freshly
# edited declaration in the repo. Globs are expanded exactly as the trimmer expanded them
# (extglob + globstar, relative to the tree), inside a subshell so those options cannot leak into
# the plain globs the rest of this script uses.
# ------------------------------------------------------------------------------------------
[ -f "$TRIMLIST" ] || { echo "  GUARD FAIL: no $TRIMLIST — the trim did not run on this tree" >&2; exit 1; }

trim_paths=() trim_globs=()
while read -r kind value _; do
  case "$kind" in
    path) trim_paths+=("$value") ;;
    glob) trim_globs+=("$value") ;;
  esac
done < "$TRIMLIST"
[ $(( ${#trim_paths[@]} + ${#trim_globs[@]} )) -gt 0 ] \
  || { echo "  GUARD FAIL: $TRIMLIST declares no rows" >&2; exit 1; }

trim_bad=0
for p in "${trim_paths[@]}"; do
  if [ -e "$STAGE/$p" ] || [ -L "$STAGE/$p" ]; then bad "trimmed path still present: $p"; trim_bad=1; fi
done
for g in "${trim_globs[@]}"; do
  # `|| true` is load-bearing and NOT defensive noise: compgen -G exits 1 when the pattern matches
  # nothing, which is precisely the case this assertion wants to pass. Under `set -euo pipefail`
  # that status propagated out and killed the guard with no output at all — a passing image
  # failing its own build, silently. mapfile from a process substitution keeps the status of the
  # expansion out of the shell's error handling entirely.
  mapfile -t survivors < <( (shopt -s extglob globstar dotglob; cd "$STAGE" && compgen -G "$g") || true )
  if [ "${#survivors[@]}" -gt 0 ]; then
    bad "trim pattern '$g' still matches ${#survivors[@]} path(s): ${survivors[*]:0:5}"
    trim_bad=1
  fi
done
if [ "$trim_bad" = 0 ]; then
  echo "    ok  ${#trim_paths[@]} trimmed paths + ${#trim_globs[@]} patterns, all gone"
fi

# ------------------------------------------------------------------------------------------
# 6. First-boot identity.
#
# Asserts a PAIR, because either half alone is a defect:
#
#   - /etc/machine-id must be ABSENT. systemd's first-boot detection keys on it, so a populated one
#     means preset-all never runs (the 60-retroforge-*.preset files silently do nothing) and
#     gen-mac.sh's seed chain never falls through to the per-unit SoC serial, giving every unit
#     flashed from the image the same Wi-Fi MAC. This was true of a shipped image and nothing
#     caught it: the 4c bootstrap generates one (systemd's scriptlet, mode 0444), while two
#     comments asserted it would not exist. Exactly the "declaration nobody checks" failure this
#     script exists for — the reason it is checked here and not trusted from assemble-rootfs.sh.
#
#   - systemd-firstboot.service must be MASKED. Removing machine-id is what makes
#     ConditionFirstBoot=yes true, and that unit then prompts for locale and a root password on a
#     console with no usable input, blocking sysinit.target forever on a device with no serial
#     console. So a tree with no machine-id and no mask is a BRICKED BOOT, not a cosmetic slip.
#
# Checked independently rather than as an either/or, so the log names whichever half is wrong.
# `if` context throughout: a bare `[ ... ] && x=1` that evaluates false returns 1 and, under
# `set -e`, kills the guard with no output — the same trap already documented in assertion 5.
# ------------------------------------------------------------------------------------------
echo "  6. first-boot identity"
MID="$STAGE/etc/machine-id"
FB="$STAGE/etc/systemd/system/systemd-firstboot.service"

mid_ok=1
if [ -e "$MID" ] || [ -L "$MID" ]; then
  mid_ok=0
  bad "/etc/machine-id is present ($(wc -c <"$MID" 2>/dev/null || echo '?') bytes) — first boot will not be treated as one: preset-all will not run, and every unit gets the same derived Wi-Fi MAC"
fi

fb_ok=0
if [ -L "$FB" ] && [ "$(readlink "$FB")" = /dev/null ]; then
  fb_ok=1
else
  bad "systemd-firstboot.service is not masked — with no /etc/machine-id it will run and block sysinit.target forever on a console with no input (no serial console on this device)"
fi

if [ "$mid_ok" = 1 ] && [ "$fb_ok" = 1 ]; then
  echo "    ok  no /etc/machine-id, systemd-firstboot masked"
fi

# The image's identity to software that is NOT ours. /etc/retroforge-release is what retroforge reads;
# os-release is what everything else reads, and a UI's About screen renders OS Variant /
# Version / Build straight out of it. Those fields shipped BLANK until 2026-08-09 — invisible in
# the source (the committed rootfs/conf/os-release is static by design, and the values are appended by
# the assembler), and invisible on device unless someone opens that screen. So assert the appended
# half is there, and that it AGREES with retroforge-release rather than being separately derived.
osr="$STAGE/etc/os-release"
rel="$STAGE/etc/retroforge-release"
osr_ok=1
for field in VARIANT VARIANT_ID VERSION VERSION_ID BUILD_ID; do
  grep -q "^$field=" "$osr" 2>/dev/null || { bad "/etc/os-release has no $field — os-release clients render that row blank"; osr_ok=0; }
done
if [ "$osr_ok" = 1 ]; then
  osr_ver="$(sed -n 's/^VERSION_ID=//p' "$osr" | tr -d '"')"
  rel_ver="$(sed -n 's/^RETROFORGE_VERSION=//p' "$rel" 2>/dev/null)"
  osr_build="$(sed -n 's/^BUILD_ID=//p' "$osr" | tr -d '"')"
  rel_build="$(sed -n 's/^RETROFORGE_BUILD=//p' "$rel" 2>/dev/null)"
  if [ "$osr_ver" != "$rel_ver" ] || [ "$osr_build" != "$rel_build" ]; then
    bad "os-release ($osr_ver/$osr_build) and retroforge-release ($rel_ver/$rel_build) disagree — one identity, stamped once, is the whole rule"
  else
    echo "    ok  os-release carries the per-build identity and agrees with retroforge-release"
  fi
fi

# ------------------------------------------------------------------------------------------
# 7. The RAUC update path is installable.
#
# Every part of an A/B update is inert until something needs it, and each missing piece fails at a
# different and unhelpful moment: no `rauc` binary is a missing command at install time; a missing
# keyring means bundles verify against NOTHING while still reporting success; a missing ESP GRUB or
# stage-2 config under /usr/lib/retroforge/boot means the post-install hook cannot refresh the ESP
# and the slot's efi partition, so the updated slot boots a boot chain that does not match it; and a
# missing grub-editenv fails every slot-state call RAUC's grub backend makes.
#
# lib-slotwrite.sh is on the list because the hook SOURCES it: since the primitives were factored out
# for the internal installer to share, a root without it has a post-install that dies on its first
# line. RAUC would then report a failed install of a slot it had already written -- recoverable, but
# only from the other slot, and the build is the cheap place to notice.
#
# The exec bit on the hook is checked because it is exactly the failure this project has already
# paid for once: a shipped script that lost its exec bit in a tree refactor, where the symptom was
# a black screen rather than an error (see rootfs/overlay/README.md).
# ------------------------------------------------------------------------------------------
echo "  7. RAUC update path"
rauc_ok=1
for f in usr/bin/rauc etc/rauc/keyring.pem etc/rauc/system.conf \
         usr/bin/grub-editenv \
         usr/lib/systemd/system/retroforge-boot-good.service \
         usr/lib/systemd/system/retroforge-boot-bad.service \
         usr/lib/retroforge/boot/grub-esp.efi usr/lib/retroforge/boot/steamcl.efi \
         usr/lib/retroforge/boot/steamcl-version usr/lib/retroforge/boot/fonts/default.pf2 \
         usr/lib/retroforge/boot/grubaa64.efi usr/lib/retroforge/boot/grub-a.cfg \
         usr/lib/retroforge/boot/grub-b.cfg \
         usr/lib/retroforge/boot/fonts/dejavu-mono.pf2 \
         boot/vmlinuz.efi boot/initramfs-retroforge.img \
         usr/lib/rauc/post-install.sh \
         usr/lib/retroforge/install/lib-slotwrite.sh; do
  if [ ! -s "$STAGE/$f" ]; then
    rauc_ok=0
    bad "/$f is missing or empty — the A/B update path is not installable"
  fi
done
if [ -e "$STAGE/usr/lib/rauc/post-install.sh" ] && [ ! -x "$STAGE/usr/lib/rauc/post-install.sh" ]; then
  rauc_ok=0
  bad "/usr/lib/rauc/post-install.sh is not executable — RAUC would report a successful install of a slot that was never finished"
fi
# steamcl.efi is what an older root's hook copies onto the ESP when it installs this root, so it has
# to BE the ESP GRUB; anything else there would put the steamcl chain back.
if [ -e "$STAGE/usr/lib/retroforge/boot/steamcl.efi" ] \
   && [ "$(readlink "$STAGE/usr/lib/retroforge/boot/steamcl.efi")" != grub-esp.efi ]; then
  rauc_ok=0
  bad "/usr/lib/retroforge/boot/steamcl.efi is not a link to grub-esp.efi — an older root's update hook would install something other than the ESP GRUB"
fi
if ! grep -qx 'bootloader=grub' "$STAGE/etc/rauc/system.conf" 2>/dev/null; then
  rauc_ok=0
  bad "/etc/rauc/system.conf does not say bootloader=grub — RAUC would not drive the grubenv the ESP GRUB reads"
fi
# btrfstune is what re-randomises the target slot's fsid. Without it the hook dies mid-install,
# and a slot that shares an fsid with the running root can silently hand you the wrong filesystem.
if [ ! -s "$STAGE/usr/bin/btrfstune" ]; then
  rauc_ok=0
  bad "/usr/bin/btrfstune is missing — the post-install hook cannot re-randomise the target slot's fsid"
fi
# Whose bundles the image installs: /etc/rauc/keyring.pem. A RELEASE image trusts the project CA
# (ota/rauc/retroforge-ca.pem) and nothing else, or a device in the field would install bundles signed
# by another key. A DEV card also trusts its build box's own dev OTA CA (STAGE dev-ota-key, minted by
# ota/gen-dev-signing.sh), after the project CA, so it can take dev builds as updates.
keyring="$STAGE/etc/rauc/keyring.pem"
project_ca="$ROOT/ota/rauc/retroforge-ca.pem"
img_mode="$(sed -n 's/^RETROFORGE_MODE=//p' "$STAGE/etc/retroforge-release" 2>/dev/null || true)"
if [ -s "$keyring" ] && [ -s "$project_ca" ]; then
  if [ "$img_mode" = dev ]; then
    if ! head -c "$(wc -c <"$project_ca")" "$keyring" | cmp -s - "$project_ca"; then
      rauc_ok=0
      bad "/etc/rauc/keyring.pem does not start with the project CA — this dev card would refuse every signed release bundle"
    fi
  elif ! cmp -s "$keyring" "$project_ca"; then
    rauc_ok=0
    bad "/etc/rauc/keyring.pem is not the project CA alone — a ${img_mode:-release} image would install bundles signed by another key (a dev OTA CA belongs on dev cards only)"
  fi
fi
unset keyring project_ca img_mode

# --- what the INTERNAL INSTALLER reads out of this root ------------------------------------------
# Separate from the list above because nothing on the A/B update path touches these, so an update
# would keep working with every one of them missing. They are read by the installer running from the
# recovery medium, which writes an ESP that does not exist yet: the constants it cannot mint on the
# device, out of the root whose boot chain they belong to.
#
# grubenv is the shared ESP's env block: RAUC's slot state and the user's board choice. The installer
# starts from this pristine copy so an install and a card carry the same object (boot/grub.sh emits
# it and asserts it is pristine). The 1024 is re-checked here because it is the length nothing
# downstream complains about: grub_envblk_open only requires the signature to FIT, so a short block
# reads back perfectly and is simply not the object a card carries.
if [ ! -s "$STAGE/usr/lib/retroforge/boot/grubenv" ]; then
  bad "/usr/lib/retroforge/boot/grubenv is missing — an internal install cannot seed the ESP's env block"
elif [ "$(wc -c <"$STAGE/usr/lib/retroforge/boot/grubenv")" != 1024 ]; then
  bad "/usr/lib/retroforge/boot/grubenv is $(wc -c <"$STAGE/usr/lib/retroforge/boot/grubenv") bytes, not 1024 — it would read back fine and still not match what a card carries"
else
  echo "    ok  installer artifacts: grubenv (1024 B, pristine)"
fi
# OpenABL's Device model list for the ESP's \dtbs\qcom: one per DTB the root boots.
# A missing directory is a count of 0, not an exit: find fails on it, and under pipefail that would
# end the guard here with every later assertion unrun.
n_esp_dtbs=$({ find "$STAGE/usr/lib/retroforge/boot/dtbs" -maxdepth 1 -name '*.dtb' 2>/dev/null || true; } | wc -l | tr -d ' ')
n_dtbs=$({ find "$STAGE/boot/dtbs" -maxdepth 1 -name '*.dtb' 2>/dev/null || true; } | wc -l | tr -d ' ')
if [ "$n_esp_dtbs" -gt 0 ] && [ "$n_esp_dtbs" = "$n_dtbs" ]; then
  echo "    ok  installer artifacts: $n_esp_dtbs ESP DTBs for OpenABL's Device model list"
else
  bad "/usr/lib/retroforge/boot/dtbs has $n_esp_dtbs DTBs for $n_dtbs in /boot/dtbs — OpenABL could not list every board"
fi

# var-seed.tar.zst is the /var a freshly installed slot starts from. The OTA path has no use for it
# — it rsyncs the running /var — so nothing but an install would ever notice it missing, and what
# an install would do instead is boot a slot whose /var is empty: no machine-id, no overlay upper,
# no /etc. Listed, not just stat'd, because the two things that must NOT be in it are absences, and
# an absence is what a `-s` check cannot see:
#
#   lib/retroforge/slot     per-slot, written by seed_var after unpacking. Baked in, it would be a
#                         second answer to "which slot is this" — and that file exists precisely to
#                         be the INDEPENDENT witness against the initramfs's own claim.
#   lib/retroforge/mac-wifi write-once and outranks the derivation, so a seeded copy would hand every
#                         installed device the same Wi-Fi MAC. Two on one network is the symptom.
seed="$STAGE/usr/lib/retroforge/var-seed.tar.zst"
if [ ! -s "$seed" ]; then
  bad "/usr/lib/retroforge/var-seed.tar.zst is missing — an internal install has no /var to seed a fresh slot with, and there is no running system to copy one from"
elif ! seed_list=$(tar -tf "$seed" 2>/dev/null); then
  bad "/usr/lib/retroforge/var-seed.tar.zst is not readable as a tar archive — is zstd in the build container?"
else
  seed_bad=0
  for f in ./lib/retroforge/slot ./lib/retroforge/mac-wifi; do
    if printf '%s\n' "$seed_list" | grep -qx -- "$f"; then
      seed_bad=1
      bad "var-seed.tar.zst carries $f — it is per-device/per-slot state and must be written after unpacking, not baked in"
    fi
  done
  # And the one directory whose absence is unrecoverable: the initramfs mounts /etc from the overlay
  # upper, so a slot seeded without it does not come up at all.
  printf '%s\n' "$seed_list" | grep -qx -- './lib/overlays/etc/upper/' \
    || { seed_bad=1; bad "var-seed.tar.zst has no ./lib/overlays/etc/upper/ — a slot seeded from it cannot mount /etc and will not boot"; }
  [ "$seed_bad" = 0 ] && echo "    ok  installer artifacts: var-seed.tar.zst ($(du -h "$seed" | cut -f1), no per-slot state, overlay upper present)"
fi

# genpart.sh + partition-table.txt, shipped VERBATIM. Existence is the cheap half; the half that
# matters is that they are byte-identical to the repo copies, because a drift here is silent and
# expensive. image/make-sdcard.sh builds a card from the repo table, and the installer lays an
# internal disk out from the shipped one -- if they disagree, an install produces partitions sized
# differently from the card every release was tested on. The first symptom is a rootfs image that
# will not fit its slot, discovered AFTER the OEM's userdata has been destroyed. There is no undo.
#
# The exec bit is checked for the same reason post-install.sh's is: a shipped script losing it in a
# tree refactor is a failure this project has already paid for once, and here it would strand an
# install between "GPT written" and "nothing written to it".
for f in genpart.sh partition-table.txt lib-gpt.sh; do
  shipped="$STAGE/usr/lib/retroforge/install/$f"
  if [ ! -s "$shipped" ]; then
    bad "/usr/lib/retroforge/install/$f is missing — the installer cannot lay out a GPT"
  elif ! cmp -s "$shipped" "$ROOT/image/$f"; then
    bad "/usr/lib/retroforge/install/$f differs from image/$f — an install would partition a disk to a different layout than the card this release was tested on"
  else
    echo "    ok  installer artifacts: $f byte-identical to image/$f"
  fi
done
if [ -e "$STAGE/usr/lib/retroforge/install/genpart.sh" ] && [ ! -x "$STAGE/usr/lib/retroforge/install/genpart.sh" ]; then
  bad "/usr/lib/retroforge/install/genpart.sh is not executable — the installer would write a GPT for a disk it then cannot populate"
fi
# THE INTERNAL INSTALLER, read back against installer/shipped-files. An offline suite runs it out of
# the repo with the host's tools on PATH, so this is the only check that sees the image's inventory:
# recon() would catch a missing tool on the device, but only after a release has shipped without it.
while read -r f; do
  case "$f" in ''|'#'*) continue ;; esac
  shipped="$STAGE/usr/lib/retroforge/install/$f"
  if ! cmp -s "$shipped" "$ROOT/installer/$f"; then
    bad "/usr/lib/retroforge/install/$f is missing or differs from installer/$f"
  elif [ "${f%.py}" = "$f" ] && [ ! -x "$shipped" ]; then
    bad "/usr/lib/retroforge/install/$f is not executable"
  fi
done <"$ROOT/installer/shipped-files"
cmp -s "$STAGE/usr/lib/retroforge/install/lib-homestage.sh" "$ROOT/image/lib-homestage.sh" \
  || bad "/usr/lib/retroforge/install/lib-homestage.sh is missing or differs from image/lib-homestage.sh"
[ "$(readlink "$STAGE/usr/lib/retroforge/install/confirm" 2>/dev/null)" = confirm-ui ] \
  || bad "/usr/lib/retroforge/install/confirm does not point at confirm-ui — an installer that cannot take consent cannot install"
# tests/test-installer-shipped.sh keeps this list a superset of what recon() and the components call.
INSTALLER_TOOLS="sgdisk sfdisk mdir sha256sum dd mkfs.vfat mkfs.ext4 mkfs.btrfs btrfstune btrfs blkid mount umount tar rauc dbus-daemon gdbus partprobe udevadm curl gamescope seatd-launch python3 zstd grub-editenv pgrep"
# -L as well: a link with an absolute target does not resolve inside a staged tree.
missing_tools=""
for t in $INSTALLER_TOOLS; do
  [ -x "$STAGE/usr/bin/$t" ] || [ -L "$STAGE/usr/bin/$t" ] || missing_tools="$missing_tools $t"
done
[ -z "$missing_tools" ] || bad "missing from /usr/bin:$missing_tools — the internal installer calls them"
[ -f "$STAGE/usr/lib/python3.14/site-packages/pygame/__init__.py" ] \
  || bad "pygame is not in site-packages — the installer UI cannot draw (packages/pygame-ce/prebuilt.pin)"
[ -n "$missing_tools" ] || echo "    ok  installer artifacts: ${INSTALLER_TOOLS// /, }"

# The primitives the hook and the installer share. Asserted here as well as on the RAUC list above,
# because the two readers fail differently: without it an OTA dies on post-install.sh's first line,
# while an install has no way to write parts.env and leaves stage 2 guessing the SD card's 1..8.
[ -s "$STAGE/usr/lib/retroforge/install/lib-slotwrite.sh" ] \
  || bad "/usr/lib/retroforge/install/lib-slotwrite.sh is missing — neither an update nor an install can write a slot"

# --- the two halves of adaptive streaming, both of which fail SILENTLY --------------------------
# Adaptive updates (ota/rauc/manifest.raucm.in) cut a release-to-release OTA from 3.90G to ~125M
# measured, but every way of losing them degrades to "a full download that still succeeds". Nothing
# goes red on the device, nothing goes red in CI, and the only symptom is a bill and a slow update.
# So they are asserted here, where a wrong answer is a build failure.
#
# 1. rauc must be BUILT with streaming. It is on by default upstream and the snapshot's PKGBUILD
#    passes plain arch-meson, so this holds today -- but a bump that touches meson_options.txt, or a
#    distro that flips the default, would take it away with no other trace. The binary prints its
#    own feature set (`1.15.2 create=1 ... streaming=1`), so grep it out of the shipped artefact
#    rather than trusting the recipe: what matters is the aarch64 binary in the tree, not what the
#    PKGBUILD asked for.
if ! grep -aqF 'streaming=1' "$STAGE/usr/bin/rauc" 2>/dev/null; then
  rauc_ok=0
  bad "/usr/bin/rauc was built WITHOUT streaming — every OTA silently reverts to a full-slot download"
fi
# 2. The NBD module must ship. rauc streams by creating an /dev/nbdN backed by an unprivileged
#    HTTP-Range helper; without the module `genl_ctrl_resolve(nl, "nbd")` fails and the install
#    dies. It is CONFIG_BLK_DEV_NBD=m from the arm64 defconfig with no ARCH_* gate, so today it
#    survives kernel/trim-platforms.config by accident rather than by decision -- and the open
#    "residual foreign-hardware drivers" item (issue #44) proposes exactly the kind of per-driver
#    negative pass that would take it out. No modprobe is needed at runtime (nbd.c declares
#    MODULE_ALIAS_GENL_FAMILY and genetlink request_module()s an unknown family by name), so the
#    only requirement is that the .ko is present.
if ! find "$STAGE/lib/modules" -name 'nbd.ko*' -print -quit 2>/dev/null | grep -q .; then
  rauc_ok=0
  bad "nbd.ko is not in the module tree — rauc cannot stream, so adaptive updates are dead"
fi
# --- the OTA client -----------------------------------------------------------------------------
#
# The shell drives updates through /usr/bin/retroforge-update. It has to survive the copy into $STAGE
# present AND executable: each failure is silent on a device with no serial console — the symptom
# is the update button doing nothing at all.
f="$STAGE/usr/bin/retroforge-update"
if [ ! -s "$f" ]; then
  bad "${f#"$STAGE"} is missing — the shell's update button has nothing to call"
elif [ ! -x "$f" ]; then
  bad "${f#"$STAGE"} is not executable — the shell runs it directly, so a lost mode bit is a dead button"
fi

# Presence is not installability. Every check above passed on a tree whose system.conf rejected
# every bundle we can sign: the release cert's codeSigning EKU and RAUC's default smimesign
# verification purpose disagreed, and the first thing that would have noticed was `rauc install`
# on a device with no serial console. So sign a throwaway bundle and verify it THROUGH the tree's
# own system.conf. Run against $STAGE, not rootfs/overlay, for the reason in this file's header: what
# ships is the built tree, and a source file that is correct before the copy has been wrong after.
if [ "$rauc_ok" = 1 ] && [ -s "$STAGE/etc/rauc/system.conf" ]; then
  # $ROOT-relative, not a sibling lookup: verify-signing.sh used to sit next to this script when
  # both lived in images/, and the split put the signing half under ota/ while this stayed in
  # rootfs/. A $(dirname "$0")/rauc/ reference survives a rename of THIS directory and breaks the
  # moment the two are separated -- which is exactly what happened.
  if ! signing_out="$("$ROOT/ota/rauc/verify-signing.sh" "$STAGE/etc/rauc/system.conf" 2>&1)"; then
    rauc_ok=0
    bad "the shipped system.conf cannot verify a bundle signed the way ota/gen-signing-ca.sh signs one"
    printf '%s\n' "$signing_out" | sed 's/^/      /' >&2
  fi
fi
if [ "$rauc_ok" = 1 ]; then
  echo "    ok  rauc + keyring + system.conf + /usr/lib/retroforge/boot stage-1/2 mirror + /boot kernel + executable hook"
  echo "    ok  a codeSigning-EKU bundle verifies through the shipped system.conf; an unrelated CA does not"
fi

# ------------------------------------------------------------------------------------------
# 7b. The boot-disk-scoped partition links exist, and everything that names them agrees.
#
# FOUR consumers resolve a partition by name after switch_root -- /esp and /home in /etc/fstab,
# grow-home's repart target, and rauc's slot devices -- and all four now go through
# /dev/retroforge/<GPT name>, which exists only for partitions on the disk we booted from. The rule
# and its match program are what create those links; without either, the links are simply absent and
# NOTHING SAYS SO AT RUNTIME. What the device does instead is boot with no /home and no /esp, fail
# to confirm the trial, and roll back to the other slot -- survivable by design, and a full release
# cycle to diagnose from the symptom. This is the cheap place to notice.
#
# ASSERTED AGAINST THE BUILT TREE, and the exec bit is checked for the reason assertion 7 already
# gives: a shipped script that loses its exec bit in a tree refactor is a failure with no error
# message. A udev PROGRAM that cannot be executed does not match, and a rule that does not match
# creates no link and logs nothing a user will ever see.
#
# The last two checks are the ones that catch a HALF-APPLIED change: a tree where the links exist
# but fstab still says LABEL=, or where system.conf was reverted, is a tree where the ambiguity is
# back for that consumer alone -- which is strictly worse than not having the mechanism, because the
# other three consumers now disagree with it about which disk they are on.
# ------------------------------------------------------------------------------------------
echo "  7b. boot-disk-scoped partition links"
bootdisk_ok=1
BD_RULE="$STAGE/usr/lib/udev/rules.d/69-retroforge-bootdisk.rules"
BD_PROG="$STAGE/usr/lib/retroforge/on-boot-disk"

if [ ! -s "$BD_RULE" ]; then
  bootdisk_ok=0
  bad "/usr/lib/udev/rules.d/69-retroforge-bootdisk.rules is missing — /dev/retroforge/* would never be created, so /esp, /home and the rauc slots all resolve to nothing"
fi
if [ ! -s "$BD_PROG" ]; then
  bootdisk_ok=0
  bad "/usr/lib/retroforge/on-boot-disk is missing — the rule's PROGRAM cannot match, so no link is created"
elif [ ! -x "$BD_PROG" ]; then
  bootdisk_ok=0
  bad "/usr/lib/retroforge/on-boot-disk is not executable — udev cannot run it, the rule never matches, and no link is created"
fi
# The rule has to name the program at the path the program actually occupies. They are two files in
# two different trees (udev/rules.d and retroforge/), so a move renames one and not the other.
if [ -s "$BD_RULE" ] && ! grep -q '/usr/lib/retroforge/on-boot-disk' "$BD_RULE"; then
  bootdisk_ok=0
  bad "69-retroforge-bootdisk.rules does not name /usr/lib/retroforge/on-boot-disk — its PROGRAM points somewhere else"
fi
for row in RetroForge:/esp retroforge-home:/home; do
  if ! grep -q "^/dev/retroforge/${row%%:*}[[:space:]]" "$STAGE/etc/fstab" 2>/dev/null; then
    bootdisk_ok=0
    bad "/etc/fstab does not mount ${row##*:} from /dev/retroforge/${row%%:*} — that mount follows whichever disk udev enumerated first"
  fi
done
if grep -qE '^(PARTLABEL|LABEL)=(RetroForge|retroforge-home)[[:space:]]' "$STAGE/etc/fstab" 2>/dev/null; then
  bootdisk_ok=0
  bad "/etc/fstab still carries a bare PARTLABEL=/LABEL= row for the ESP or home — the scoped link and the label row would race for the same mountpoint"
fi
if [ -s "$STAGE/etc/rauc/system.conf" ] && grep -q '^device=/dev/disk/by-partlabel/' "$STAGE/etc/rauc/system.conf"; then
  bootdisk_ok=0
  bad "etc/rauc/system.conf still names its slots by-partlabel — an OTA can write the other disk's slot"
fi
if [ "$bootdisk_ok" = 1 ]; then
  echo "    ok  69-retroforge-bootdisk.rules + executable on-boot-disk; fstab and rauc slots both name /dev/retroforge/"
fi

# ------------------------------------------------------------------------------------------
# 7c. The power-key path has the CLI it executes.
#
# retroforge-powerbuttond (key -> suspend / power off) and retroforge-suspend (arming the wake) both run
# `libinput debug-events`. Neither can fail loudly without it: the forwarder crash-loops under
# Restart= and the key simply does nothing, and the suspend engine resumes at once rather than
# sleep with no way to wake. The CLI is a package boundary that has already moved under us once —
# Arch split it into libinput-tools at 1.30 (mash-20260305) and the first image off that snapshot
# shipped with neither (HW, Pocket ACE, 2026-09-23).
# ------------------------------------------------------------------------------------------
echo "  7c. power-key path"
pk_ok=1
for f in usr/bin/libinput usr/lib/libinput/libinput-debug-events \
         usr/bin/retroforge-powerbuttond usr/bin/retroforge-suspend; do
  if [ ! -x "$STAGE/$f" ]; then
    pk_ok=0
    bad "/$f is missing or not executable — the power key cannot suspend or wake the device"
  fi
done
[ "$pk_ok" = 1 ] && echo "    ok  libinput debug-events + powerbuttond + suspend engine present and executable"

# ------------------------------------------------------------------------------------------
# 8. The system UID/GID allocation matches the pin.
#
# /usr/lib/sysusers.d/01-retroforge-enforce-ids.conf declares an id for every name in the range
# systemd-sysusers would otherwise allocate. Whether it WORKED is not visible in the declaration:
# it only takes effect if it reached the target root before the transaction whose hook allocates,
# and it wins only because `01-` sorts first. Both are properties of rootfs/customize-base.sh, one
# file away from this one, and the failure is silent — sysusers allocates by counting down from 999,
# so a pin that never applied still yields a plausible-looking passwd.
#
# What it costs to miss: the ids are recorded in the inodes of /home and of each slot's /var, and
# rootfs/overlay/usr/lib/rauc/post-install.sh copies /var wholesale across an update. So a build whose
# allocation silently moved ships an update that reassigns ownership of persisted state — noticed
# on a device, after the fact, as a service that cannot read its own state directory.
#
# Read from the STAGE, not from rootfs/overlay, for this file's usual reason: what ships is the built
# tree, and the pin is only load-bearing if it is IN it. An absent pin is a failure, not a skip.
# ------------------------------------------------------------------------------------------
echo "  8. system UID/GID allocation"
IDPIN="$STAGE/usr/lib/sysusers.d/01-retroforge-enforce-ids.conf"
PASSWD="$STAGE/etc/passwd"
GROUP="$STAGE/etc/group"

ids_ok=1
if [ ! -s "$IDPIN" ]; then
  ids_ok=0
  bad "/usr/lib/sysusers.d/01-retroforge-enforce-ids.conf is missing — nothing pins the system id range, so every id in it is a function of the package set"
elif [ ! -s "$PASSWD" ] || [ ! -s "$GROUP" ]; then
  ids_ok=0
  bad "/etc/passwd or /etc/group is missing or empty — the tree has no id allocation to check"
else
  ids_checked=0
  # Fields: <type> <name> <id> ... — only `u` and `g` lines carry an id we pin. A `-` id would mean
  # "allocate", which is the thing this file exists to prevent, so it is a failure and not a skip.
  while read -r kind name id _rest; do
    case "$kind" in u|g) ;; *) continue ;; esac
    [ -n "${id:-}" ] || continue
    if [ "$id" = "-" ]; then
      ids_ok=0
      bad "the id pin leaves '$name' unpinned ($kind line with '-') — that name is back to being allocated by package order"
      continue
    fi
    # Which files must agree: a `g` line fixes only the group, a `u` line fixes the user AND the
    # like-named group, because sysusers creates both at the same id.
    case "$kind" in
      g) files="group" ;;
      u) files="passwd group" ;;
    esac
    for which in $files; do
      case "$which" in passwd) file="$PASSWD" ;; group) file="$GROUP" ;; esac
      # Look the NAME up, not the id. A name sitting at the wrong id is exactly the failure being
      # hunted, and searching by id would simply not find it.
      got="$(awk -F: -v n="$name" '$1 == n { print $3; exit }' "$file")"
      if [ -z "$got" ]; then
        ids_ok=0
        bad "'$name' is pinned to $id but is absent from /etc/$which — the pin names something this tree does not create"
      elif [ "$got" != "$id" ]; then
        ids_ok=0
        bad "'$name' is $got in /etc/$which but the pin says $id — the pin did not apply (it must reach the target root BEFORE the pacman transaction; see rootfs/customize-base.sh)"
      fi
    done
    ids_checked=$((ids_checked + 1))
  done < <(grep -vE '^[[:space:]]*(#|$)' "$IDPIN")

  # The other direction: every account sysusers ALLOCATED must be pinned. The loop above only checks
  # names the pin already knows, so a package that starts shipping `u foo -` / `g foo -` gets a free
  # id in the range and passes silently — and moves the next time the set changes. That is what
  # systemd 259's `g empower -` did (and rtkit dropping its fixed 133): caught by the relock, not here.
  # 900-999 is the band sysusers counts down through; fixed package ids (dbus 81, polkitd 102) sit below.
  pinned_names=" $(grep -vE '^[[:space:]]*(#|$)' "$IDPIN" | awk '$1 ~ /^[ug]$/ { printf "%s ", $2 }')"
  for which in passwd group; do
    case "$which" in passwd) file="$PASSWD" ;; group) file="$GROUP" ;; esac
    while IFS=: read -r name _pw id _rest; do
      case "$pinned_names" in *" $name "*) continue ;; esac
      ids_ok=0
      bad "'$name' was allocated $id in /etc/$which by sysusers but the pin does not name it — pin it at the bottom of the range, or its id follows the package set"
    done < <(awk -F: '$3 >= 900 && $3 < 1000' "$file")
  done

  if [ "$ids_checked" = 0 ]; then
    ids_ok=0
    bad "the id pin declares no u/g entries — it is a comment, not a pin"
  elif [ "$ids_ok" = 1 ]; then
    echo "    ok  $ids_checked pinned system ids match /etc/passwd + /etc/group"
  fi
fi

# ------------------------------------------------------------------------------------------
# 9. No Steam, x86-emulation or Android payload came back.
#
# retroforge ships none of them: no Steam client or upstream's Steam contracts, no FEX/Proton x86 stack,
# no Android container, no Decky. Each used to arrive through a path that is easy to re-open by
# accident — a prebuilt pin, an overlay file, an assembler stage — and none of them would fail a build
# on its own; the image would simply grow gigabytes and carry dead services. Named paths rather than a
# glob over names, so a typo'd entry is visible in review.
#
# Steam itself is NOT shipped, and is not missing either. The OGUI Steam plugin launches games with
# `steam ... steam://rungameid/<id>`, so the image carries /usr/bin/steam: a wrapper that runs Valve's
# arm64 client from the player's home, raw on the host (gtk2, libibus and lsof are in the base for it).
# The client is installed from Main menu > Emulators > Steam Client (/usr/lib/retroforge/steam-install,
# through steam-bootstrap: ~3 GB after the client's own update, which the install runs too); until
# then the wrapper downloads nothing and says where to install it. None of what is downloaded is
# pinned to a version: steam.pin names the client channel (steamdeck_stable), and each download is
# checked against what that channel publishes. Everything else Steam needs on arm64 is downloaded the same way, into the
# player's home, by a helper whose channel pin is in usr/share/retroforge/steam/:
#   - no steamcmd: the RetroForge plugin lists the player's Steam games from the client's own files
#     (/usr/lib/retroforge/steam-library), so nothing needs the OGUI Steam plugin's second sign-in.
#     steamcmd used to be a prebuilt (packages/steamcmd, at usr/lib/retroforge/steamcmd), then a
#     download; that path stays listed.
#   - the x86 guest Valve's FEX tool needs for x86 games and x86 Protons (ld.so, glibc, x86 Mesa;
#     SteamOS ships it as usr/share/guestos/fex-mesa): steam-x86-guest follows FEX's ArchLinux RootFS
#     channel (x86-guest.pin, ~1.4 GB; installed with Steam Client) and mounts it with squashfuse while
#     Steam runs, with our own x86 Mesa laid over it (fuse-overlayfs). That Mesa, built by
#     packages/mesa-x86 from packages/mesa's pin, is the image's one x86 payload:
#     /usr/lib/retroforge/x86-mesa (rootfs/lib-assemble-x86-mesa.sh). Libraries only, run by nothing
#     on the host.
#     usr/share/guestos stays listed.
#   - Proton-CachyOS arm64, on the player's Download (Apps > Proton, retroforge-proton) and for store games,
#     with DXVK-Sarek on where the GPU needs it (Adreno 610/613): steam-compat-tools keeps its
#     newest arm64 release in the Steam library's compatibilitytools.d (proton-cachyos-arm64.pin), or
#     on ARMv8.0 CPUs its ARMv8.0 rebuild (proton-cachyos-armv8.pin), also part of Steam Client's install there. usr/share/steam/compatibilitytools.d stays listed.
# The root carries only the wrapper, those helpers and their pins. FEX itself is
# Steam's: the arm64 client adds it to a game as a dependency, as it does Proton ("adding FEX dependency
# to %s %u" and STEAM_COMPAT_FEX_CONFIG in steamclient.so; not yet seen on hardware), so nothing x86
# belongs here. See docs/steam-arm64.md.
#
# No box64 or box86 either, and no binfmt_misc registration for x86 binaries from anything. PortMaster's
# box64 ports each bring their own box64 and call it by path, and its box86 ports are armhf, which
# PortMaster already hides here. Valve's client starts x86 code through STEAM_COMPAT_EMULATOR (its FEX
# tool), not binfmt. A system-wide FEX or box64 registered for x86 ELF would take those execs instead,
# inside Steam's containers too, and with two registered the kernel tries the newest first (ROCKNIX
# unregisters its own before starting arm64 Steam). So the named paths below cover both projects'
# binaries and binfmt.d files, and every binfmt.d file is also checked for an x86 ELF magic, whatever
# it is called (qemu-user's included).
# ------------------------------------------------------------------------------------------
echo "  9. no Steam / x86 / Android payload"
REMOVED=(
  usr/bin/retroforge-steam usr/bin/retroforge-steamos-manager usr/bin/steamos-polkit-helpers
  usr/bin/steamos-update usr/bin/steamos-select-branch usr/bin/retroforge-select-branch
  usr/share/decky-loader usr/share/decky-plugins usr/lib/systemd/system/plugin_loader.service
  usr/bin/FEXInterpreter usr/share/fex-emu usr/share/guestos usr/share/steam/compatibilitytools.d
  usr/bin/FEX usr/bin/FEXLoader usr/bin/FEXServer
  usr/lib/binfmt.d/FEX-x86.conf usr/lib/binfmt.d/FEX-x86_64.conf
  usr/bin/box64 usr/bin/box86 usr/lib/binfmt.d/box64.conf usr/lib/binfmt.d/box86.conf
  usr/lib/binfmt.d/box32.conf etc/binfmt.d/box64.conf etc/binfmt.d/box86.conf
  usr/bin/podman usr/bin/retroforge-android usr/share/retroforge-android
  usr/lib/retroforge/steamcmd
)
removed_bad=0
for n in "${REMOVED[@]}"; do
  if [ -e "$STAGE/$n" ] || [ -L "$STAGE/$n" ]; then bad "removed stack came back: /$n"; removed_bad=1; fi
done
[ "$removed_bad" = 0 ] && echo "    ok  none of ${#REMOVED[@]} Steam / x86 / Android paths present"
# Any binfmt.d entry whose magic is an x86 ELF header, under whatever name: e_machine (bytes 18-19)
# 0x03 (i386) or 0x3e (x86_64), written as binfmt.d files write it, "\x7fELF" then one \xHH per byte.
# Anchored on that position, because e_type (bytes 16-17) is \x03\x00 for any PIE.
x86_binfmt_bad=0
for f in "$STAGE"/usr/lib/binfmt.d/*.conf "$STAGE"/etc/binfmt.d/*.conf; do
  [ -f "$f" ] || continue
  if grep -qiE '\\x7fELF(\\x[0-9a-f]{2}){14}\\x(03|3e)\\x00' "$f"; then
    bad "x86 binfmt_misc registration in the image: /${f#"$STAGE"/}"; x86_binfmt_bad=1
  fi
done
[ "$x86_binfmt_bad" = 0 ] && echo "    ok  no binfmt.d entry registers x86 binaries"

# ------------------------------------------------------------------------------------------
# 9b. The shell is there, and its self-updater is not.
#
# OpenGamepadUI arrives as an overlay package (packages/opengamepadui: upstream's aarch64 release
# with a patched, rebuilt pck); a packaging mistake builds fine while the shell lands somewhere
# RETROFORGE_SESSION_CMD cannot find it — a black panel at first boot. Its self-updater is trimmed
# (rootfs/conf/trim.list): on a RAUC root the slot carries the shell version.
# ------------------------------------------------------------------------------------------
echo "  9b. the shell"
shell_ok=1
for f in usr/bin/opengamepadui usr/share/opengamepadui/opengamepad-ui.aarch64 \
         usr/share/opengamepadui/reaper; do
  if [ ! -x "$STAGE/$f" ]; then
    shell_ok=0; bad "/$f is missing or not executable — the session has no shell to start"
  fi
done
for f in usr/share/opengamepadui/opengamepad-ui.pck \
         usr/share/opengamepadui/libopengamepadui-core.linux.template_release.aarch64.so; do
  [ -s "$STAGE/$f" ] || { shell_ok=0; bad "/$f is missing — OGUI cannot start without it"; }
done
for f in Makefile .gdignore; do
  [ -e "$STAGE/$f" ] && { shell_ok=0; bad "/$f in the image root — the OGUI release tarball was unpacked at the wrong level"; }
done
for f in usr/lib/systemd/user/systemd-sysext-updater.service usr/share/opengamepadui/scripts/make_nice \
         usr/share/polkit-1/actions/org.shadowblip.setcap.policy; do
  [ -e "$STAGE/$f" ] && { shell_ok=0; bad "/$f survived the trim — OGUI's self-updater must not ship"; }
done
[ "$shell_ok" = 1 ] && echo "    ok  OpenGamepadUI present and executable, its self-updater absent"

# ------------------------------------------------------------------------------------------
# 10. Python bytecode is the image's own: no host bytecode rode in, and the stdlib has its own.
#
# rootfs/overlay/ is injected with `cp -a` of the WORKING TREE, and the offline suites import its
# Python clients as modules — CPython then writes a __pycache__ next to the source, inside the
# very tree that gets copied. .gitignore covers the repo and does nothing for that copy; the
# assembler prunes it, and this is the check that the prune actually ran.
#
# Not cosmetic, and not hypothetical: v0.2.x dev cards shipped .pyc compiled by the BUILD HOST's
# CPython (3.14) into an image whose interpreter is 3.13, so the device could never load a byte
# of it — dead weight that also silently defeats the startup caching it looks like it provides.
# Found on hardware 2026-08-10, not by any check.
#
# The image's own bytecode is the other side of it. The root is read-only, so Python cannot cache
# at runtime, and without bytecode every Python program compiled each module it imported on every
# run (~1.9 s of the helpers before each Steam launch on the Air X, 2026-10-24). customize-base.sh
# compiles the stdlib with the image's interpreter as checked-hash .pyc, which a host run does not
# write by default. So every __pycache__ is under the image's usr/lib/python3.N, holds only
# cpython-3N .pyc whose header says checked-hash, and os.py has one (the compile ran).
# ------------------------------------------------------------------------------------------
pydir="$(cd "$STAGE" && ls -d usr/lib/python3.*/os.py 2>/dev/null | head -1 || true)"
pydir="${pydir%/os.py}"
pytag="cpython-$(sed 's|^usr/lib/python||; s|\.||' <<<"$pydir")"
pycache="$(find "$STAGE" -name __pycache__ -type d -printf '%P\n' | { grep -v "^$pydir/" || true; } | LC_ALL=C sort)"
pyc_wrong="$({ [ -z "$pydir" ] || find "$STAGE/$pydir" -path '*/__pycache__/*' -type f -printf '%P\n'; } | python3 -c '
import struct, sys
root, tag = sys.argv[1:3]
for p in sys.stdin.read().splitlines():
    with open(f"{root}/{p}", "rb") as f:
        head = f.read(8)
    if not p.endswith(f".{tag}.pyc") or len(head) < 8 or struct.unpack("<I", head[4:])[0] != 3:
        print(p)
' "$STAGE/$pydir" "$pytag" | LC_ALL=C sort)"
if [ -n "$pycache" ]; then
  bad "host Python bytecode in the tree — the assembler's __pycache__ prune did not run:"
  printf '      %s\n' $pycache >&2
elif [ -n "$pyc_wrong" ]; then
  bad "bytecode in $pydir the bootstrap did not compile (not $pytag checked-hash):"
  printf '      %s\n' $(head -20 <<<"$pyc_wrong") >&2
elif [ -z "$pydir" ]; then
  echo "    ok  no Python in the tree, no __pycache__ staged"
elif [ ! -f "$STAGE/$pydir/__pycache__/os.$pytag.pyc" ]; then
  bad "no bytecode for the image's Python ($pydir): every Python program compiles its imports on every run"
else
  echo "    ok  Python bytecode is the image's own ($pydir, $pytag checked-hash)"
fi

# ------------------------------------------------------------------------------------------
# 11. Every path is owned by an id this tree declares, and nothing is unexpectedly setuid.
#
# Every assertion above asks about the package set or about a declaration. None of them opens a
# file's OWNER, which is how a /usr owned end to end by uid 1001 passed all of them on every build
# it shipped in: the package set was right, the seal was right, the tree was wrong. That is the
# second correct-diff/wrong-tree defect here — the first was the git-644 mode regression that
# blacked out the OOBE — and the lesson written down after that one, "diff the MODE manifest of
# built trees", stayed prose. This is it as an assertion.
#
# WHY THE TREE'S OWN passwd IS THE ORACLE, rather than a list of approved ids kept in this file: a
# uid means nothing without a name database, and the one that ships in the image is the one the
# device resolves against. An id absent from it is unresolvable BY CONSTRUCTION — `ls` renders a
# bare number and anything checking ownership by name fails — so the question here is not "is this
# id approved" but "can the shipped system name its own files at all". That needs no list, and so
# has nothing to go stale. Assertion 8 asks the complementary question, whether the ids the tree
# declares are the PINNED ones; neither implies the other, and the 1001 tree passed 8.
#
# The overlay-ownership stage is NOT this check. It reclaims exactly one uid — the repo checkout's,
# `stat`'d off the script at run time — so it ignored 1001 in silence while its own comment cited
# the uid-1000 symptom. A blind reclaim is a fix; this is the measurement that says it worked.
#
# SETUID IS A SEPARATE QUESTION ON THE SAME `find`, and worth the second walk. rootfs/overlay is
# copied out of a git checkout, and git cannot carry a setuid bit at all — so every entry below
# arrived from a package or from a third-party prebuilt, and those unpack at `/` with nothing
# constraining what they place there. A new setuid-root binary is the highest-consequence thing
# such a tarball can add quietly: invisible in a diff of the pins, invisible in the lock (prebuilt
# rows carry a hash, not a file list), and indistinguishable from a legitimate one once installed.
#
# The list is what a release tree MEASURES, not what a distribution usually ships. It is a PERMIT
# list read in one direction only: an entry disappearing is not a failure (trimming a package takes
# its setuid binary with it, which is the direction we want), an arrival is.
# ------------------------------------------------------------------------------------------
echo "  11. file ownership and setuid"
OWN_PASSWD="$STAGE/etc/passwd"
OWN_GROUP="$STAGE/etc/group"

# Measured against a built release tree 2026-08-30. Paths are relative to the tree root.
SETUID_PERMITTED=(
  usr/bin/chage usr/bin/chfn usr/bin/chsh usr/bin/expiry usr/bin/gpasswd usr/bin/groupmems
  usr/bin/newgrp usr/bin/passwd usr/bin/sg usr/bin/su usr/bin/unix_chkpwd   # shadow
  usr/bin/mount usr/bin/umount                                             # util-linux
  usr/bin/fusermount usr/bin/fusermount3                                   # fuse2 / fuse3
  usr/bin/pkexec usr/lib/polkit-1/polkit-agent-helper-1                     # polkit
  usr/lib/dbus-daemon-launch-helper                                        # dbus
  usr/lib/ssh/ssh-keysign                                                  # openssh
  usr/bin/ksu                                                              # krb5
  usr/bin/wall usr/bin/write                                               # setgid tty, not setuid
)

if [ ! -s "$OWN_PASSWD" ] || [ ! -s "$OWN_GROUP" ]; then
  bad "/etc/passwd or /etc/group is missing or empty — the tree cannot name its own files, so ownership cannot be checked at all"
else
  # One walk, reported by OWNER rather than by path: a subtree that got copied with the wrong
  # identity is thousands of files and a single wrong id, and it is the id — plus one example to
  # locate it — that says which step wrote them. A per-file list would bury that under its own size.
  #
  # Tab-separated because %P is a path and may contain spaces. TOTAL rides out on the same stream
  # (the `measure` helper below does the same thing) and is split back off with sed, not grep:
  # `grep -v` finds nothing when the tree is clean, and a non-zero grep under `pipefail` would kill
  # the guard here with no output — the third time that shape has been hit in this repo.
  own_scan="$(
    find "$STAGE" -printf '%U\t%G\t%P\n' \
    | awk -F'\t' -v pw="$OWN_PASSWD" -v gr="$OWN_GROUP" '
        BEGIN {
          while ((getline line < pw) > 0) { split(line, f, ":"); uid[f[3]] = 1 }
          while ((getline line < gr) > 0) { split(line, f, ":"); gid[f[3]] = 1 }
        }
        {
          who = ""
          if (!($1 in uid)) who = "uid " $1
          if (!($2 in gid)) who = (who == "" ? "" : who " + ") "gid " $2
          if (who == "") next
          n[who]++
          # `find` lists the tree root first and its %P is empty. Take a deeper path as the example
          # the moment one appears: "/" locates nothing, and if the root itself is misowned so is
          # everything under it, which the count already says.
          if (!(who in eg) || eg[who] == "/") eg[who] = ($3 == "" ? "/" : "/" $3)
        }
        END {
          printf "TOTAL\t%d\n", NR
          for (k in n) printf "%s  —  %d path%s, e.g. %s\n", k, n[k], (n[k] == 1 ? "" : "s"), eg[k]
        }'
  )"
  own_scanned="$(sed -n 's/^TOTAL\t//p' <<<"$own_scan")"
  own_offenders="$(sed '/^TOTAL\t/d' <<<"$own_scan" | LC_ALL=C sort)"

  if [ -n "$own_offenders" ]; then
    bad "paths owned by an id /etc/passwd or /etc/group does not declare — the shipped system cannot resolve them to a name:"
    while IFS= read -r line; do printf '      %s\n' "$line" >&2; done <<<"$own_offenders"
  else
    echo "    ok  $own_scanned paths, every uid and gid declared by this tree"
  fi
fi

declare -A SETUID_OK
for permitted in "${SETUID_PERMITTED[@]}"; do SETUID_OK["$permitted"]=1; done

suid_seen=0
suid_new=()
while IFS= read -r rel; do
  [ -n "$rel" ] || continue
  suid_seen=$((suid_seen + 1))
  [ -n "${SETUID_OK[$rel]:-}" ] || suid_new+=("$rel")
done < <(find "$STAGE" -type f -perm /6000 -printf '%P\n' | LC_ALL=C sort)

if [ "${#suid_new[@]}" -gt 0 ]; then
  bad "setuid/setgid files the permit list does not name — a git checkout cannot set that bit, so these came from a package or a prebuilt tarball:"
  for rel in "${suid_new[@]}"; do printf '      /%s\n' "$rel" >&2; done
else
  echo "    ok  $suid_seen setuid/setgid files, all permitted"
fi

# FILE CAPABILITIES, checked here because they are the same class of thing as the setuid bit above
# and fail in the opposite direction: a setuid bit that ARRIVES is the danger, a capability that
# GOES MISSING is. The file-capabilities stage grants gamescope cap_sys_nice so it can request
# realtime Vulkan queues (upstream gates that request on the capability and silently skips it
# otherwise). The grant is an xattr, so it has to survive cp -a, rsync -X and mkfs.btrfs --rootdir
# to reach the image — and if it does not, nothing anywhere reports it: gamescope starts, composites
# at normal priority, and every measurement taken afterwards answers the wrong question. Assert it
# on the tree that gets baked rather than trusting the setcap call that produced it.
if [ -f "$STAGE/usr/bin/gamescope" ]; then
  gs_cap="$(getcap "$STAGE/usr/bin/gamescope" 2>/dev/null || true)"
  case "$gs_cap" in
    *cap_sys_nice*) echo "    ok  gamescope carries cap_sys_nice (realtime Vulkan queues)" ;;
    *) bad "gamescope has NO cap_sys_nice — the grant did not survive into the tree, and its realtime queue request will be silently skipped (getcap: ${gs_cap:-<nothing>})" ;;
  esac
else
  bad "no /usr/bin/gamescope in the tree to check for cap_sys_nice"
fi

# ------------------------------------------------------------------------------------------
# 12. Size delta (report only).
#
# Never fails a build — there is no defensible threshold, and a guard that blocks on growth would
# be disabled the first time a legitimate package got bigger. Its job is to put the number in
# front of whoever reads the build log, next to the assertions, so a 200 MiB jump is noticed in
# the build that caused it rather than when the slot stops fitting. Per top-level directory,
# because "the image grew" is not actionable and "usr grew" is.
# ------------------------------------------------------------------------------------------
measure() {
  du -sk "$STAGE" | awk '{print "TOTAL", $1}'
  # -type d rather than a `*/` glob: bin, sbin, lib and lib64 are usrmerge SYMLINKS into usr, and
  # a glob with a trailing slash makes du follow them — which counts usr's 8.5 GiB four extra
  # times and turns every real change under usr into five identical bogus deltas. TOTAL is du on
  # the tree itself, which does not follow them, so only the per-directory rows were ever wrong.
  while IFS= read -r d; do
    du -sk "$STAGE/$d" | awk -v n="$d" '{print n, $1}'
  done < <(find "$STAGE" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | LC_ALL=C sort)
}
new="$(measure)"

echo "    size: $(awk '$1=="TOTAL"{printf "%.1f MiB", $2/1024}' <<<"$new") staged"
if [ -f "$SIZES" ]; then
  # Report TOTAL always; per-directory only past 1 MiB, so ordinary churn stays quiet.
  awk -v prev="$SIZES" '
    BEGIN { while ((getline line < prev) > 0) { split(line, f, " "); if (f[1] !~ /^#/) old[f[1]] = f[2] } }
    { d = $2 - (($1 in old) ? old[$1] : 0)
      if ($1 == "TOTAL" || d >= 1024 || d <= -1024)
        printf "    delta %-14s %+8.1f MiB%s\n", $1, d/1024, (($1 in old) ? "" : "  (new)") }
  ' <<<"$new" >&2
  awk -v prev="$SIZES" '
    BEGIN { while ((getline line < prev) > 0) { split(line, f, " "); if (f[1] !~ /^#/) old[f[1]] = f[2] } }
    { seen[$1] = 1 }
    END { for (k in old) if (!(k in seen)) printf "    delta %-14s   GONE\n", k }
  ' <<<"$new" >&2
else
  echo "    (no previous build recorded — no delta)" >&2
fi
if [ "$fail" != 0 ]; then
  echo "  the sealed root does not match its declaration — refusing to build an image from it" >&2
  exit 1
fi

# Record the baseline only now. The delta above is printed either way (it is diagnostic, and most
# useful next to a failure), but a tree the guard just REJECTED must not become what the next
# build measures itself against — that would report the rejected tree's size as normal and hide
# the very change that caused the rejection.
#
# Best-effort write, deliberately: this is the guard's only side effect, and a report artifact must
# never be what fails a release build. (It is also what runs when someone points this script at a
# tree by hand outside the container, where out/ is root-owned.)
if ! { install -d -m0755 "$(dirname "$SIZES")" \
       && { echo "# retroforge staged-root sizes in KiB — written by rootfs/guard-rootfs.sh, read as the next build's baseline."
            printf '%s\n' "$new"; } >"$SIZES"; } 2>/dev/null; then
  echo "    (could not record sizes to ${SIZES#"$ROOT"/} — next build reports no delta)" >&2
fi

echo "  guard passed"
