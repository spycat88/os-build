#!/usr/bin/env bash
# retroforge read-only root assembler — stage `offload-mounts`.
#
# SOURCED by rootfs/assemble-rootfs.sh, never executed. Split out of it for issue #43; the code
# and its rationale are unchanged.
#
# Carries the offload heredoc verbatim -- do not re-indent it.
#
# Reads the assembler's globals rather than taking arguments -- $stage (the staged tree), $ROOT
# (repo root), $OUT (build outputs). Turning ~20 implicit globals into positional parameters is
# where a verbatim move stops being verbatim, so it is deliberately not done.

# STAGE offload-mounts — the offload layer (same idea as SteamOS's). The root is read-only and /var is a 256M partition, so the
# paths that grow without bound are bind-mounted out to the big shared /home partition, under
# /home/.retroforge/offload/ (SteamOS uses /home/.steamos/offload — same idea, our namespace).
#
# Shape copied from SteamOS: NOT fstab bind lines, but one .mount unit per path plus a target that
# groups them (cf. steamos-offload.target + var-log.mount et al in steamos-customizations). That
# buys explicit ordering and one place to enable.
#
# /var/lib/docker is in SteamOS's set and omitted here — we ship no container runtime.
#
# /root IS REQUIRED ON RELEASE — do not read it as dev scaffolding and trim it. Anything that runs
# as root and keeps per-user state under its HOME (gnupg/dirmngr's /root/.gnupg, for one) would
# otherwise be writing to a read-only filesystem.
#
# retroforge-offload-prepare.service creates each directory on /home before the binds run, and SEEDS
# it from whatever the read-only root already has at that path. The seeding is not cosmetic: the
# TEST build bakes an SSH key into /root/.ssh, and an empty bind over /root would shadow it and lock
# us out of the card. Same reasoning protects anything shipped in /opt or /srv.
echo "  injecting offload binds: /opt /root /srv + var/{log,tmp,cache/pacman,lib/*} -> /home/.retroforge/offload"
OFFLOAD_ROOT=/home/.retroforge/offload
# unit-name<TAB>path pairs; unit names must be the systemd-escaped path (see systemd-escape -p).
OFFLOAD_PATHS='opt root srv var/log var/tmp var/cache/pacman var/lib/flatpak var/lib/systemd/coredump'

# rauc's data-directory (rootfs/overlay/etc/rauc/system.conf), where it keeps the per-slot block-hash
# indices that make adaptive updates work, plus central.raucs. Created by the same prepare service
# because it has the same precondition -- a real directory on the /home partition, which does not
# exist in the staged tree (that /home is only a mount point).
#
# A SIBLING OF THE OFFLOAD TREE, NOT A MEMBER OF IT, and the distinction is the whole point. The
# offload paths are /var paths REDIRECTED onto /home because /var is a 256M per-slot partition.
# This is the opposite requirement: data that must live somewhere no update touches, precisely
# because post-install.sh reformats the target /var on every install. Adding it to OFFLOAD_PATHS
# would give it a bind mount from a slot-local path and quietly reintroduce the problem.
RAUC_DATA=/home/.retroforge/rauc

cat >"$stage/usr/lib/systemd/system/retroforge-offload.target" <<'UNIT'
[Unit]
Description=retroforge offload mounts (bind /opt, /root, /srv and the growable /var paths onto /home)
Documentation=file:///usr/lib/retroforge/offload-prepare.sh
# Ordered inside the local-fs stage: after /home is available, before anything that consumes these
# paths. systemd-journal-flush (sysinit.target) runs later, so /var/log is already bound by then.
After=home.mount retroforge-offload-prepare.service
Requires=retroforge-offload-prepare.service
Before=local-fs.target
UNIT

cat >"$stage/usr/lib/systemd/system/retroforge-offload-prepare.service" <<UNIT
[Unit]
Description=retroforge offload directory preparation (create + seed the bind targets on /home)
DefaultDependencies=no
RequiresMountsFor=/home
After=home.mount
Before=retroforge-offload.target local-fs.target shutdown.target
Conflicts=shutdown.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/lib/retroforge/offload-prepare.sh
UNIT

install -d -m0755 "$stage/usr/lib/retroforge"
cat >"$stage/usr/lib/retroforge/offload-prepare.sh" <<PREPARE
#!/bin/sh
# Create each offload directory on /home and seed it, ONCE, from the read-only root's copy of that
# path. Seeding matters: a bare empty bind over /root would hide the TEST build's baked
# /root/.ssh/authorized_keys. Idempotent — a directory that already exists is left strictly alone,
# so user data is never overwritten on later boots.
set -eu

OFFLOAD="$OFFLOAD_ROOT"

# rauc's data-directory. No bind, no seeding, no mode mirroring -- 0700 root, created if absent and
# never touched again, because everything in it is rauc's own state. An existing directory is left
# alone: it holds the block-hash indices of both slots, and deleting them costs the next update a
# full-size download (it re-hashes on demand, so it degrades in bandwidth, not in correctness).
mkdir -p "$RAUC_DATA"
chmod 0700 "$RAUC_DATA"

for rel in $OFFLOAD_PATHS; do
  dst="\$OFFLOAD/\$rel"
  [ -d "\$dst" ] && continue
  mkdir -p "\$dst"
  # cp -a of the root's existing content (may be empty; /opt and /srv usually are).
  if [ -d "/\$rel" ] && [ -n "\$(ls -A "/\$rel" 2>/dev/null)" ]; then
    cp -a "/\$rel/." "\$dst/" || echo "[retroforge-offload] seeding \$dst from /\$rel failed" >&2
  fi
  # Mirror the root's mode/owner so e.g. /root stays 0700 root:root and /var/tmp stays 1777.
  if [ -d "/\$rel" ]; then
    chmod --reference="/\$rel" "\$dst" 2>/dev/null || :
    chown --reference="/\$rel" "\$dst" 2>/dev/null || :
  fi
done

# root's authorized_keys is the one seeded file that must FOLLOW the image rather than stay as first
# seeded. A dev card bakes the build's RETROFORGE_SSH_PUBKEY into /root/.ssh, but the loop above only
# seeds a directory that does not exist yet -- so once /home had an offload/root (any earlier boot:
# a previous flash whose /home survived, an OTA, a release first boot) a new key never reached the
# bound /root and ssh root@ kept rejecting it. So the image is the source of truth on every boot: a
# dev root's key is copied over, and a release root (which ships none) REMOVES any left behind, so
# installing a release build over a dev card -- by OTA, with /home kept -- locks root out again
# instead of leaving the dev key working. Nothing else writes root's keys (pairingd only ever
# touches the session user's), so there is nothing of the user's here to lose.
if [ -f /root/.ssh/authorized_keys ]; then
  install -d -m0700 -o root -g root "\$OFFLOAD/root/.ssh"
  install -m0600 -o root -g root /root/.ssh/authorized_keys "\$OFFLOAD/root/.ssh/authorized_keys" \\
    || echo "[retroforge-offload] refreshing root's authorized_keys failed" >&2
else
  rm -f "\$OFFLOAD/root/.ssh/authorized_keys"
fi
PREPARE
chmod 0755 "$stage/usr/lib/retroforge/offload-prepare.sh"

# One .mount unit per offload path. The unit FILENAME must be the escaped mount point, else systemd
# refuses to load it ("Where= setting doesn't match unit name").
for rel in $OFFLOAD_PATHS; do
  unit="$(echo "$rel" | tr '/' '-').mount"
  cat >"$stage/usr/lib/systemd/system/$unit" <<UNIT
[Unit]
Description=retroforge offload bind of /$rel onto $OFFLOAD_ROOT/$rel
Documentation=file:///usr/lib/retroforge/offload-prepare.sh
DefaultDependencies=no
RequiresMountsFor=/home
After=retroforge-offload-prepare.service
Requires=retroforge-offload-prepare.service
Before=local-fs.target shutdown.target
Conflicts=shutdown.target
PartOf=retroforge-offload.target

[Mount]
What=$OFFLOAD_ROOT/$rel
Where=/$rel
Type=none
Options=bind

[Install]
WantedBy=retroforge-offload.target
UNIT
  install -d -m0755 "$stage/etc/systemd/system/retroforge-offload.target.wants"
  ln -sf "/usr/lib/systemd/system/$unit" "$stage/etc/systemd/system/retroforge-offload.target.wants/$unit"
done

# Enable the target itself (preset-proof, same pattern as grow-home: 60 < the stock 99 "disable *").
echo "enable retroforge-offload.target" \
  >>"$stage/usr/lib/systemd/system-preset/60-retroforge-storage.preset"
install -d -m0755 "$stage/etc/systemd/system/local-fs.target.wants"
ln -sf /usr/lib/systemd/system/retroforge-offload.target \
       "$stage/etc/systemd/system/local-fs.target.wants/retroforge-offload.target"
