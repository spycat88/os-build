#!/usr/bin/env bash
# Offline test for the player's network shares: ksmbd serving roms, bios, saves and states.
#
#   tests/test-shares.sh
#
# WHY THIS EXISTS. The shares are five pieces that never change together, and each mismatch is a
# silent failure on a device with no shell UI: the kernel option (no ksmbd module -> the service
# fails), the ksmbd-tools overlay package and its PKGS row, /etc/ksmbd/ksmbd.conf, the units that
# turn it on (preset + build-time .wants fallback), and the Avahi record that makes it visible.
# The config also carries the decided policy (2026-10-03): guest read-write, mapped to player,
# exactly the four layout folders and nothing else of the home, plus [sdcard] (the card mount base).
#
# Runs on the host with no root, no device and no build.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OV="$ROOT/rootfs/overlay"
CONF="$OV/etc/ksmbd/ksmbd.conf"
LAYOUT="$OV/usr/share/user-tmpfiles.d/retroforge-home.conf"
PRESET="$OV/usr/lib/systemd/system-preset/60-retroforge-shares.preset"
WANTS="$OV/etc/systemd/system/multi-user.target.wants"
AVAHI="$OV/etc/avahi/services/smb.service"
KCONF="$ROOT/kernel/kernel.config"
BASE="$ROOT/rootfs/customize-base.sh"
PKG="$ROOT/packages/ksmbd-tools"

PASS=0; FAIL=0; CASE=""
ok()  { PASS=$((PASS+1)); printf '  ok   %s -- %s\n' "$CASE" "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s -- %s\n' "$CASE" "$1"; }

for f in "$CONF" "$LAYOUT" "$PRESET" "$AVAHI" "$KCONF" "$BASE" "$PKG/source.pin" "$PKG/PKGBUILD"; do
  [ -f "$f" ] || { echo "missing input: $f" >&2; exit 1; }
done

# ksmbd.conf value of <key> in [<section>] (tabs/spaces around "=" ignored, ';' comments skipped).
val() {
  awk -v sec="[$1]" -v key="$2" '
    /^[[:space:]]*;/ {next}
    /^[[:space:]]*\[/ {gsub(/[[:space:]]/, ""); in_s = ($0 == sec); next}
    in_s { line = $0; sub(/^[[:space:]]+/, "", line); n = index(line, "=")
           if (n) { k = substr(line, 1, n-1); v = substr(line, n+1); sub(/[[:space:]]+$/, "", k)
                    sub(/^[[:space:]]+/, "", v); if (k == key) { print v; exit } } }' "$CONF"
}
shares() { grep -E '^[[:space:]]*\[[^]]+\]' "$CONF" | tr -d '[] \t' | grep -vxE 'global|ipc\$'; }

# =================================================================================================
CASE="share policy"
[ "$(val global 'map to guest')" = "bad user" ] && ok "any login maps to the guest account (map to guest = bad user)" || bad "map to guest is '$(val global 'map to guest')'"
[ "$(val global 'guest account')" = player ] && ok "guest account is player: copied files are the player's" || bad "guest account is '$(val global 'guest account')', not player"
# The home is 0700 (Steam's saved sign-in is in it): guests still reach the four folders because
# they are the player; any other guest account would be locked out of every share.
PRIVATE="$OV/usr/lib/tmpfiles.d/retroforge-home-private.conf"
grep -qE '^z[[:space:]]+/home/player[[:space:]]+0700[[:space:]]+player[[:space:]]+player' "$PRIVATE" 2>/dev/null \
  && ok "the home is made the player's alone (0700) at every boot" || bad "no tmpfiles line makes /home/player 0700"
[ "$(shares | sort | tr '\n' ' ')" = "bios roms saves states " ] && ok "exactly four shares in /etc: bios roms saves states" || bad "shares are: $(shares | tr '\n' ' ')"
# [sdcard]: the card itself, bind-mounted at a fixed path by automount.sh while it is in, and LISTED
# only then: ksmbd runs on /run/retroforge/ksmbd.conf, which sdcard-share writes from /etc plus the
# card's section (asked 2026-11-26: no card, no share in the list).
CARDCONF="$OV/usr/share/retroforge/ksmbd/sdcard.conf"
SHAREBIN="$OV/usr/lib/retroforge/storage/sdcard-share"
[ "$(CONF="$CARDCONF" val sdcard path)" = /run/retroforge/sdcard ] && ok "[sdcard] serves the card's bind mount, /run/retroforge/sdcard" || bad "[sdcard] path is '$(CONF="$CARDCONF" val sdcard path)'"
[ "$(CONF="$CARDCONF" val sdcard 'guest ok')" = yes ] && [ "$(CONF="$CARDCONF" val sdcard 'read only')" = no ] && ok "[sdcard] guest read-write" || bad "[sdcard] is not guest read-write"
DROPIN="$OV/usr/lib/systemd/system/ksmbd.service.d/retroforge.conf"
grep -qx 'ExecStart=' "$DROPIN" && grep -qx 'ExecStart=/usr/bin/ksmbd.mountd -C /run/retroforge/ksmbd.conf' "$DROPIN" \
  && ok "ksmbd runs on the generated config" || bad "ksmbd.mountd is not started on /run/retroforge/ksmbd.conf"
grep -qx 'ExecStartPre=/usr/lib/retroforge/storage/sdcard-share auto' "$DROPIN" \
  && ok "and writes it before every start" || bad "nothing writes /run/retroforge/ksmbd.conf before ksmbd starts"
TS="$(mktemp -d)"; mkdir -p "$TS/share"
gen() { RETROFORGE_KSMBD_BASE="$CONF" RETROFORGE_KSMBD_SDCARD="$CARDCONF" RETROFORGE_KSMBD_CONF="$TS/out.conf" \
  RETROFORGE_SDCARD_SHARE="$TS/share" bash "$SHAREBIN" "$@" 2>/dev/null; }
gen off; [ "$(CONF="$TS/out.conf" shares | sort | tr '\n' ' ')" = "bios roms saves states " ] && ok "no card: the four shares, no sdcard" || bad "no card: $(CONF="$TS/out.conf" shares | tr '\n' ' ')"
gen on; [ "$(CONF="$TS/out.conf" shares | sort | tr '\n' ' ')" = "bios roms saves sdcard states " ] && ok "a card in: sdcard is listed" || bad "card in: $(CONF="$TS/out.conf" shares | tr '\n' ' ')"
gen auto; [ "$(CONF="$TS/out.conf" shares | grep -c sdcard)" = 0 ] && ok "auto with nothing mounted: hidden" || bad "auto lists sdcard with no card mounted"
rm -rf "$TS"
SVC="$OV/usr/lib/systemd/system/retroforge-sdcard-share.service"
grep -qx 'BindsTo=run-retroforge-sdcard.mount' "$SVC" && grep -q 'sdcard-share on --reload' "$SVC" && grep -q 'sdcard-share off --reload' "$SVC" \
  && ok "the share is listed with the card's bind and hidden when it goes" || bad "retroforge-sdcard-share.service does not follow the card's bind"
AUTO="$OV/usr/lib/retroforge/storage/automount.sh"
grep -q '^Wants=retroforge-sdcard-share.service$' "$AUTO" && ok "the bind pulls the listing in" || bad "nothing starts retroforge-sdcard-share.service"
grep -q '^SHARE=/run/retroforge/sdcard$' "$AUTO" && ok "automount.sh binds the card at the share's path" || bad "automount.sh does not bind the card at /run/retroforge/sdcard"
for s in $(shares); do
  p="$(val "$s" path)"
  [ "$p" = "/home/player/$s" ] && ok "[$s] serves /home/player/$s" || bad "[$s] path is '$p'"
  grep -Eq "^d[[:space:]]+%h/$s[[:space:]]" "$LAYOUT" && ok "[$s] folder is created by the layout" || bad "[$s]: the layout does not create ~/$s"
  [ "$(val "$s" 'guest ok')" = yes ] && [ "$(val "$s" 'read only')" = no ] && ok "[$s] guest read-write" || bad "[$s] is not guest read-write"
done
[ "$(val 'ipc$' 'guest ok')" = yes ] && ok "[ipc\$] guest ok: a guest can list the shares (ksmbd-tools adds it without)" \
  || bad "[ipc\$] lacks guest ok = yes: guests cannot list the shares"
[ "$(readlink "$OV/etc/systemd/user/basic.target.wants/systemd-tmpfiles-setup.service" 2>/dev/null)" = /usr/lib/systemd/user/systemd-tmpfiles-setup.service ] \
  && ok "user tmpfiles enabled (creates the shared folders at login; user presets never run in an image build)" \
  || bad "user systemd-tmpfiles-setup.service is not enabled: the shared folders are never created (HW 2026-10-03)"
grep -Eiq '^[[:space:]]*path[[:space:]]*=[[:space:]]*/home/player/?[[:space:]]*$|path[[:space:]]*=.*(emulators|\.local|\.config)' "$CONF" \
  && bad "a share exposes the whole home or private folders" || ok "neither the whole home nor emulators/settings are shared"

# =================================================================================================
CASE="enabled by default"
for u in ksmbd.service avahi-daemon.service; do
  grep -qx "enable $u" "$PRESET" && ok "preset enables $u" || bad "preset does not enable $u"
  [ "$(readlink "$WANTS/$u" 2>/dev/null)" = "/usr/lib/systemd/system/$u" ] && ok "build-time multi-user.target.wants/$u fallback" || bad "no multi-user.target.wants/$u link"
done
grep -q 'RequiresMountsFor=/home' "$OV/usr/lib/systemd/system/ksmbd.service.d/retroforge.conf" 2>/dev/null \
  && ok "ksmbd waits for /home (a separate nofail partition)" || bad "ksmbd.service is not ordered after /home"

# =================================================================================================
CASE="discovery (Avahi)"
if python3 - "$AVAHI" <<'PY'
import sys, xml.etree.ElementTree as ET
s = ET.parse(sys.argv[1]).getroot().find('service')
sys.exit(0 if s is not None and s.findtext('type') == '_smb._tcp' and s.findtext('port') == '445' else 1)
PY
then ok "smb.service is valid XML announcing _smb._tcp on 445"; else bad "smb.service is not a valid _smb._tcp/445 record"; fi

# =================================================================================================
CASE="kernel and packages"
grep -qx 'CONFIG_SMB_SERVER=m' "$KCONF" && ok "kernel: CONFIG_SMB_SERVER=m (ksmbd module)" || bad "kernel.config lacks CONFIG_SMB_SERVER=m"
pkgs="$(sed -n 's/^PKGS=(\(.*\))$/\1/p' "$BASE")"
for p in ksmbd-tools avahi; do
  case " $pkgs " in *" $p "*) ok "$p is in PKGS" ;; *) bad "$p is not in PKGS" ;; esac
done
pin_name="$(sed -n 's/^name:[[:space:]]*//p' "$PKG/source.pin")"
pkg_name="$(sed -n 's/^pkgname=//p' "$PKG/PKGBUILD")"
[ "$pin_name" = ksmbd-tools ] && [ "$pkg_name" = ksmbd-tools ] && ok "source.pin and PKGBUILD both name ksmbd-tools" || bad "pin '$pin_name' / PKGBUILD '$pkg_name'"
grep -q -- '-Dsystemdsystemunitdir=/usr/lib/systemd/system' "$PKG/PKGBUILD" && ok "PKGBUILD installs ksmbd.service where the preset expects it" || bad "PKGBUILD does not pin the systemd unit dir"

printf '\ntest-shares.sh: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
