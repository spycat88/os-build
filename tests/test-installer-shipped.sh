#!/usr/bin/env bash
# Offline test: the internal installer ships complete inside the root.
#
#   tests/test-installer-shipped.sh
#
# WHY THIS SUITE EXISTS. An offline suite runs the installer out of the repo, with the HOST's tools on
# its PATH, so a green test-install.sh says nothing about what is on the image. Both ways that goes
# wrong have been paid for on hardware: select-target.sh died with "cannot find lib-gpt.sh" on the
# first medium that got far enough to look (2026-08-24), and mtools being absent turned rule 3b off
# silently (2026-08-21). This reads the declarations and checks that they agree with what the code
# actually calls; rootfs/guard-rootfs.sh checks the same lists against a built tree.
#
# Runs on the host with no root, no docker, no network and no built tree. Run via `make test`.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INST="$ROOT/installer"
LIST="$INST/shipped-files"
GUARD="$ROOT/rootfs/guard-rootfs.sh"
ASSEMBLE="$ROOT/rootfs/lib-assemble-boot.sh"
BASE="$ROOT/rootfs/customize-base.sh"

PASS=0; FAIL=0
ok()  { printf '  ok   %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  FAIL %s\n' "$1"; FAIL=$((FAIL + 1)); }

[ -f "$LIST" ] || { bad "no declaration at installer/shipped-files"; printf '%s: %d passed, %d failed\n' "${0##*/}" "$PASS" "$FAIL"; exit 1; }
shipped() { sed -e 's/#.*//' -e 's/[[:space:]]*$//' "$LIST" | grep -v '^$'; }

echo "--- every declared file exists ---"
n=0
while read -r f; do
  n=$((n + 1))
  [ -f "$INST/$f" ] || bad "installer/$f is declared but does not exist"
done < <(shipped)
[ "$n" -gt 0 ] && ok "$n files declared, all present" || bad "the declaration is empty"

echo "--- every path the components name is one that ships ---"
# The files staged beside them from elsewhere in the tree, and the link assemble makes.
FOREIGN="genpart.sh lib-gpt.sh lib-homestage.sh lib-slotwrite.sh lib-bls.sh partition-table.txt confirm"
missing=""
while read -r name; do
  shipped | grep -qx "$name" && continue
  case " $FOREIGN " in *" $name "*) continue ;; esac
  missing="$missing $name"
done < <(shipped | sed "s|^|$INST/|" | xargs grep -ohE '/usr/lib/retroforge/install/[A-Za-z0-9][A-Za-z0-9._-]*' \
           | sed 's|.*/||' | sort -u)
[ -z "$missing" ] && ok "no component names a file that does not ship" \
  || bad "named but not shipped:$missing"

# A sibling reached through $SELFDIR/ rather than the full path counts the same.
missing=""
while read -r name; do
  shipped | grep -qx "$name" || missing="$missing $name"
done < <(grep -ohE '\$SELFDIR/[a-z][A-Za-z0-9._-]+' "$INST/installer-session" | sed 's|.*/||' | sort -u)
[ -z "$missing" ] && ok "installer-session's siblings ship" || bad "installer-session needs:$missing"

# uiflow/ui import their siblings by module name.
missing=""
while read -r mod; do
  shipped | grep -qx "$mod.py" || missing="$missing $mod.py"
done < <(grep -hE '^(from|import) ui[a-z]+' "$INST/ui" "$INST/uiflow.py" "$INST/uiview.py" "$INST/uipad.py" \
           | awk '{print $2}' | sort -u)
[ -z "$missing" ] && ok "the UI's sibling modules ship" || bad "imported but not shipped:$missing"

echo "--- the root is staged from this list, and the guard reads it ---"
grep -q 'installer/shipped-files' "$ASSEMBLE" && ok "lib-assemble-boot.sh stages installer/shipped-files" \
  || bad "lib-assemble-boot.sh does not read installer/shipped-files"
grep -q 'installer/shipped-files' "$GUARD" && ok "guard-rootfs.sh reads installer/shipped-files" \
  || bad "guard-rootfs.sh does not read installer/shipped-files"
grep -q 'installer/shipped-files' "$ROOT/Makefile" && ok "the Makefile rebuilds the root when a shipped file changes" \
  || bad "the Makefile does not depend on the shipped installer files"
for f in lib-homestage.sh; do
  grep -q "image/$f" "$ASSEMBLE" && ok "$f is staged beside the spine" || bad "$f is not staged, and the spine resolves it by search"
done
grep -q 'confirm-ui.*install/confirm\|ln -s.*confirm-ui' "$ASSEMBLE" && ok "\$CONFIRM's fixed path is linked to confirm-ui" \
  || bad "nothing links /usr/lib/retroforge/install/confirm"

echo "--- every tool the install path calls is on the guard's list ---"
guard_tools="$(sed -n 's/^INSTALLER_TOOLS="\(.*\)"$/\1/p' "$GUARD")"
[ -n "$guard_tools" ] && ok "guard-rootfs.sh declares INSTALLER_TOOLS" || bad "guard-rootfs.sh declares no INSTALLER_TOOLS"
# recon()'s own list, read out of the spine so that a tool added there has to be added to the guard.
recon_tools="$(sed -n '/^recon() {/,/^}/p' "$INST/retroforge-install" \
  | sed -n '/for t in/,/; do/p' | sed -e 's/.*for t in//' -e 's/; do//' -e 's/\\//' -e 's/"\$[A-Z0-9_]*"//g')"
[ -n "${recon_tools// /}" ] && ok "recon()'s list was read" || bad "could not read recon()'s tool list"
for t in $recon_tools sgdisk mdir sfdisk sha256sum curl gamescope seatd-launch python3 zstd pgrep; do
  case " $guard_tools " in *" $t "*) ;; *) bad "$t is called on the install path but the guard does not assert it" ;; esac
done
ok "tool list compared"

echo "--- the packages behind the four tools the root used to lack ---"
pkgs="$(sed -n 's/^PKGS=(\(.*\))$/\1/p' "$BASE")"
for p in gptfdisk dosfstools mtools parted; do
  case " $pkgs " in *" $p "*) ok "PKGS declares $p" ;; *) bad "PKGS does not declare $p" ;; esac
done

echo "--- pygame is a real prebuilt of the root ---"
PIN="$ROOT/packages/pygame-ce/prebuilt.pin"
[ -f "$PIN" ] && ok "the wheel pin lives under packages/" || bad "no packages/pygame-ce/prebuilt.pin"
grep -q '^kind: zip$' "$PIN" && grep -q '^dest: /usr/lib/python3' "$PIN" \
  && ok "it unpacks into site-packages" || bad "the pin does not unpack into site-packages"
grep -q 'site-packages/pygame' "$GUARD" && ok "the guard asserts it survived the trim" \
  || bad "the guard does not assert pygame is in the root"

echo "--- the unit ends the session user before it asks anything ---"
UNIT="$ROOT/rootfs/overlay/usr/lib/systemd/system/retroforge-installer.service"
for u in retroforge-session.service user@1000.service retroforge-powerbuttond.service systemd-user-sessions.service; do
  grep -q "^Conflicts=.*$u" "$UNIT" && ok "it conflicts with $u" || bad "it does not stop $u"
  grep -q "^After=.*$u" "$UNIT" && ok "and starts after $u has stopped" || bad "nothing orders it after $u"
done
grep -q '^ExecStartPre=.*touch /run/nologin' "$UNIT" && ok "it closes logins" || bad "a paired player SSH can come back"
grep -q '^ExecStartPre=.*loginctl terminate-user 1000' "$UNIT" && ok "it ends every session of the user" \
  || bad "a player session outside the manager survives"
[ "$(grep -n 'nologin' "$UNIT" | grep ExecStartPre | cut -d: -f1)" -lt "$(grep -n 'terminate-user' "$UNIT" | grep ExecStartPre | cut -d: -f1)" ] \
  && ok "and closes them first" || bad "terminate-user runs before logins are closed"
grep -q '^ExecStartPre=.*restart inputplumber.service' "$UNIT" && ok "it gives the pad back a clean InputPlumber" \
  || bad "OGUI's input state survives into the installer"
grep -q '^\[Install\]' "$UNIT" && bad "the unit has an [Install]: it must never start on its own" \
  || ok "it has no [Install], so nothing but the row starts it"
grep -qE '^(TTYPath|StandardInput=tty)' "$UNIT" \
  && bad "the unit binds a TTY -- that made gamescope exit 0 at boot on the main image" \
  || ok "it binds no TTY, which is what bring-up paid to learn"
grep -q '^ExecStopPost=-/usr/lib/retroforge/install/save-log.sh' "$UNIT" && ok "every stop saves the log" || bad "the log is not saved on stop"
grep -q '^ExecStopPost=-/usr/lib/retroforge/install/leave' "$UNIT" && ok "and takes the device down" || bad "a stop leaves a black panel"
[ "$(grep -n 'save-log' "$UNIT" | grep ExecStopPost | cut -d: -f1)" -lt "$(grep -n 'install/leave' "$UNIT" | grep ExecStopPost | cut -d: -f1)" ] \
  && ok "in that order" || bad "the device goes down before the log is saved"
grep -q '^Conflicts=.*NetworkManager\|^Conflicts=.*rmtfs' "$UNIT" && bad "it stops the network the OS streams over" \
  || ok "it leaves the network alone"

echo "--- leave powers off only when the UI asked, and reboots otherwise ---"
LV="$INST/leave"
W="$(mktemp -d)"
printf '#!/bin/sh\nprintf "%%s\\n" "$*"\n' >"$W/systemctl"; chmod +x "$W/systemctl"
leave() { RETROFORGE_INSTALL_POWEROFF="$W/mark" RETROFORGE_SYSTEMCTL="$W/systemctl" sh "$LV"; }
[ "$(leave)" = "--no-block reboot" ] && ok "no mark reboots: a crash, Cancel or a failed install is back on the card" \
  || bad "with no mark it ran: $(leave)"
: >"$W/mark"
[ "$(leave)" = "--no-block poweroff" ] && ok "the mark powers off" || bad "with the mark it ran: $(leave)"
rm -rf "$W"
shipped | grep -qx leave && ok "and it ships" || bad "leave is not in installer/shipped-files"

echo "--- boot-medium tells a card from internal storage, and defaults to internal ---"
BM="$INST/boot-medium"
B="$(mktemp -d)"; trap 'rm -rf "$B"' EXIT
mkdir -p "$B/sys/mmcblk1/device" "$B/sys/mmcblk0/device" "$B/sys/sda" "$B/bin"
printf 'SD\n'  >"$B/sys/mmcblk1/device/type"
printf 'MMC\n' >"$B/sys/mmcblk0/device/type"
printf '#!/bin/sh\necho "$FAKE_PKNAME"\n' >"$B/bin/lsblk"
printf '#!/bin/sh\necho /dev/fake3\n'      >"$B/bin/findmnt"
chmod +x "$B/bin"/*
medium() { PATH="$B/bin:$PATH" FAKE_PKNAME="$1" RETROFORGE_SYS_BLOCK="$B/sys" "$BM" 2>/dev/null; }
[ "$(medium mmcblk1)" = card ]     && ok "an SD card is a card"              || bad "SD: $(medium mmcblk1)"
[ "$(medium mmcblk0)" = internal ] && ok "an eMMC is internal"               || bad "eMMC: $(medium mmcblk0)"
[ "$(medium sda)" = internal ]     && ok "UFS is internal"                   || bad "UFS: $(medium sda)"
[ "$(medium '')" = internal ]      && ok "not knowing is internal, so the row stays hidden" || bad "unknown: $(medium '')"
shipped | grep -qx boot-medium && ok "and it ships" || bad "boot-medium is not in installer/shipped-files"

echo "--- the polkit rule grants one verb of one unit ---"
RULE="$ROOT/rootfs/overlay/usr/share/polkit-1/rules.d/50-retroforge-installer.rules"
if [ ! -f "$RULE" ]; then
  bad "missing: ${RULE#"$ROOT"/}"
elif ! command -v node >/dev/null; then
  printf '  skip no node to evaluate the rule\n'
else
  verdicts="$(node - "$RULE" <<'JS'
const fs = require("fs");
let rule;
global.polkit = { Result: { YES: "yes", NO: "no" }, addRule: f => { rule = f; } };
eval(fs.readFileSync(process.argv[2], "utf8"));
const ask = (id, unit, verb, active = true, wheel = true, local = true) =>
  rule({ id, lookup: k => ({ unit, verb })[k] }, { active, local, isInGroup: g => g === "wheel" && wheel }) || "pass";
const M = "org.freedesktop.systemd1.manage-units", U = "retroforge-installer.service";
console.log([
  ask(M, U, "start"), ask(M, U, "stop"), ask(M, U, "restart"), ask(M, "sshd.service", "start"),
  ask(M, U, "start", false), ask(M, U, "start", true, false), ask(M, U, "start", true, true, false),
  ask("org.freedesktop.systemd1.manage-unit-files", U, "enable"),
].join(" "));
JS
)"
  [ "$verdicts" = "yes pass pass pass pass pass pass pass" ] \
    && ok "start of retroforge-installer.service, for the active local wheel session, and nothing else" \
    || bad "verdicts (start stop restart other-unit inactive non-wheel ssh enable): $verdicts"
fi

printf '%s: %d passed, %d failed\n' "${0##*/}" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
