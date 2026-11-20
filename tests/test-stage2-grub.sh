#!/usr/bin/env bash
# Offline parity test for the phase-5 stage-2 GRUB data model.
#
# Three files have to agree about what a board IS, and each of them is edited for a different
# reason, so they drift silently:
#
#   boot/boards.map                              build-time catalog: id / menu name / dtb / bootargs
#   kernel/dts/qcom/*.dts                        the DTBs that actually ship
#   rootfs/overlay/usr/lib/retroforge/devices/*.conf   the identity the RUNNING system reports
#
# and then boot/gen-grub-cfg.sh turns the first into a grub.cfg whose per-slot cmdline has to match
# image/partition-table.txt. A mismatch anywhere is a board that cannot be selected, a menu entry
# that boots the wrong DTB, or a slot that mounts the other slot's /var.
#
#   tests/test-stage2-grub.sh
#
# Everything runs on the host with no root, no device and no cross-build: the configs under test
# are GENERATED here into a temp dir, so this never skips and never asserts against a stale
# out/boot from some earlier build. Run via `make test`.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEVICES="$ROOT/rootfs/overlay/usr/lib/retroforge/devices"
BOARDS="$ROOT/boot/boards.map"
TABLE="$ROOT/image/partition-table.txt"
DTS="$ROOT/kernel/dts/qcom"
GEN="$ROOT/boot/gen-grub-cfg.sh"

PASS=0; FAIL=0; SKIP=0; CASE=""
ok()   { PASS=$((PASS+1)); printf '  ok   %s -- %s\n' "$CASE" "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL %s -- %s\n' "$CASE" "$1"; }
skip() { SKIP=$((SKIP+1)); printf '  skip %s -- %s\n' "$CASE" "$1"; }

for f in "$BOARDS" "$TABLE" "$GEN"; do
  [ -e "$f" ] || { echo "missing input: $f" >&2; exit 1; }
done
[ -d "$DTS" ] || { echo "missing dts dir: $DTS" >&2; exit 1; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT

part_num()   { awk -v n="$1" '/^[[:space:]]*#/||/^[[:space:]]*$/{next} {i++; if ($1==n) {print i; exit}}' "$TABLE"; }
part_label() { awk -v n="$1" '/^[[:space:]]*#/||/^[[:space:]]*$/{next} {if ($1==n) {print $5; exit}}' "$TABLE"; }

# --- 1. every catalog row names a real board DTB (bootargs may be empty) ------------------------
CASE="board catalog -> DTB"
unset pids;  declare -A pids
unset pdtbs; declare -A pdtbs
ncat=0
while IFS=$'\t' read -r id name dtb ba; do
  [ -n "$id" ] || continue
  [[ $id == \#* ]] && continue
  ncat=$((ncat+1))
  [ -n "$name" ] || bad "$id has no menu name in the catalog"
  [ -n "$dtb" ] || { bad "$id has no DTB in the catalog"; continue; }
  pids["$id"]=1
  pdtbs["$dtb"]=1
  [ -f "$DTS/$dtb.dts" ] && ok "$id -> $dtb.dts" || bad "$id names missing DTB $dtb.dts"
done < "$BOARDS"
[ "$ncat" -gt 0 ] && ok "$ncat boards in the catalog" || bad "the catalog is empty"

# --- 2. the catalog and the runtime device profiles agree on identity ---------------------------
# The menuentry id is what the user picks; RETROFORGE_DEVICE_ID is what device-env reports at
# runtime. They are the same identity and must stay spelled the same, or a board is selectable
# under a name the OS has never heard of.
CASE="catalog <-> device profiles"
unset confids; declare -A confids
for f in "$DEVICES"/*.conf; do
  [ "$(basename "$f")" = "defaults.conf" ] && continue
  id=$(sed -n 's/^RETROFORGE_DEVICE_ID=//p' "$f" | head -1 | tr -d "'\"")
  [ -n "$id" ] && confids["$id"]=1 || bad "$(basename "$f") has no RETROFORGE_DEVICE_ID"
done
[ "${#confids[@]}" -eq "$ncat" ] \
  && ok "${#confids[@]} device profiles, ${ncat} catalog rows" \
  || bad "${#confids[@]} device profiles vs $ncat catalog rows"
for id in "${!pids[@]}"; do
  [ -n "${confids[$id]:-}" ] && ok "catalog id '$id' has a device profile" \
                             || bad "catalog id '$id' has no device profile"
done
for id in "${!confids[@]}"; do
  [ -n "${pids[$id]:-}" ] && ok "device profile '$id' has a catalog row" \
                          || bad "device profile '$id' is missing from the catalog"
done

# --- 2b. device-env can actually REACH every profile --------------------------------------------
# A fourth file has to agree and nothing checked it until a six-board SoC import made the gap
# obvious. rootfs/overlay/usr/lib/retroforge/device-env maps the devicetree `model` string to a profile
# name with a hand-written case. Miss a board there and it does not fail: it falls through to
# defaults.conf, so the running system reports device-id `unknown`, exports no SOC_CLASS (powerd
# loses its underclock table) and no panel dims (retroforge-session falls back to a generic
# landscape 1920x1080 on the wrong connector). No error, just a subtly wrong session.
CASE="device-env <-> profiles"
DEVENV="$ROOT/rootfs/overlay/usr/lib/retroforge/device-env"
if [ ! -r "$DEVENV" ]; then
  bad "cannot read $DEVENV"
else
  # Case arms look like:  "AYN Thor Lite")   profile=ayn-thor-lite ;;
  unset envprof; declare -A envprof
  unset envmodel; declare -A envmodel
  while IFS= read -r line; do
    m=$(printf '%s' "$line" | sed -n 's/^[[:space:]]*"\([^"]*\)").*profile=\([A-Za-z0-9._-]*\).*/\1/p')
    p=$(printf '%s' "$line" | sed -n 's/^[[:space:]]*"\([^"]*\)").*profile=\([A-Za-z0-9._-]*\).*/\2/p')
    [ -n "$p" ] || continue
    envprof["$p"]=1
    envmodel["$m"]=1
  done < "$DEVENV"

  for id in "${!confids[@]}"; do
    [ -n "${envprof[$id]:-}" ] && ok "device-env can select profile '$id'" \
      || bad "device-env has no model string mapping to '$id' -- that board silently gets defaults.conf"
  done
  for p in "${!envprof[@]}"; do
    [ -r "$DEVICES/$p.conf" ] && ok "device-env's '$p' arm has a profile file" \
      || bad "device-env maps a model to '$p', but $p.conf does not exist"
  done

  # And the case KEYS must be real model strings, or the match never fires on hardware. Compare
  # against the root `model` of every board .dts (following one level of #include for the boards
  # that inherit their root node from a sibling .dts).
  for dts in "$DTS"/*.dts; do
    mdl=$(sed -n 's/^[[:space:]]*model = "\(.*\)";.*/\1/p' "$dts" | head -1)
    [ -n "$mdl" ] || continue
    [ -n "${envmodel[$mdl]:-}" ] && ok "model '$mdl' is matched by device-env" \
      || bad "$(basename "$dts") declares model '$mdl', which device-env's case never matches"
  done
fi

# --- 3. every shipped DTB is reachable from the menu --------------------------------------------
# A DTB with no catalog row is only legal when it is a hardware variant deriving from one (the
# RP6's top-dpad revision). Anything else ships a board nobody can boot.
CASE="DTB -> menuentry"
ndtb=0
for dts in "$DTS"/*.dts; do
  base=$(basename "$dts" .dts)
  ndtb=$((ndtb+1))
  if [ -n "${pdtbs[$base]:-}" ]; then
    ok "$base covered by a catalog row"
  elif [ -n "${pdtbs[${base%-top-dpad}]:-}" ] && [ "$base" != "${base%-top-dpad}" ]; then
    ok "$base covered by the derived ${base%-top-dpad} entry"
  else
    bad "$base has no catalog row and no parent to derive from"
  fi
done
ok "$ndtb board DTBs, $ncat catalog rows, $((ndtb - ncat)) derived"

# --- 4. the stage-2 module set carries what the config calls -------------------------------------
# A config that calls a module which was never embedded gets "unknown command", leaves the target
# variable unset, and carries on -- so `probe --part-uuid` missing from grubaa64.efi is not a boot
# failure, it is every boot silently taking the PARTLABEL fallback with one console line to show
# for it. probe is stock GRUB and builds unconditionally; it was simply never in MODULES.
#
# This is asserted here rather than in a boot/grub.sh test because the coupling is here: the
# generated config is the only caller, and the two files are edited for different reasons.
CASE="stage-2 module set"
MODLINE=$(sed -n '/^MODULES="/,/"$/p' "$ROOT/boot/grub.sh" | tr -d '\\\n')
if [ -z "$MODLINE" ]; then
  bad "cannot find the MODULES= assignment in boot/grub.sh"
else
  for m in probe regexp loadenv retroforge; do
    printf '%s' "$MODLINE" | grep -qw -- "$m" \
      && ok "boot/grub.sh embeds $m" \
      || bad "boot/grub.sh does not embed $m -- the config's $m calls are 'unknown command'"
  done
fi

# --- 5. the generated grub.cfg files ------------------------------------------------------------
CASE="generated grub.cfg"
for slot in A B; do
  lc="${slot,,}"
  cfg="$T/grub-$lc.cfg"
  if ! "$GEN" "$slot" "$cfg" >/dev/null 2>"$T/generr"; then
    bad "gen-grub-cfg.sh $slot failed: $(head -1 "$T/generr")"
    continue
  fi
  ok "gen-grub-cfg.sh $slot produced a config"

  # one menuentry per board, ids intact
  n_entries=$(grep -c '^menuentry ' "$cfg")
  [ "$n_entries" -eq "$ndtb" ] && ok "grub-$lc.cfg has $n_entries entries (one per DTB)" \
                               || bad "grub-$lc.cfg has $n_entries entries, expected $ndtb"
  for id in "${!pids[@]}"; do
    grep -q -- "--id $id\$\|--id $id " "$cfg" && ok "grub-$lc.cfg has an entry for $id" \
                                              || bad "grub-$lc.cfg is missing an entry for $id"
  done

  # the menu order: the catalog's rows in device-id order, each derived (top-dpad) entry right
  # after its parent. A board appended at the end of boards.map would land out of place.
  ids_menu=$(sed -n 's/^menuentry .* --id \([^ ]*\) .*/\1/p' "$cfg")
  ids_want=$(awk -F'\t' '/^#/||!NF{next} {print $1 "\t" $3}' "$BOARDS" | LC_ALL=C sort -t$'\t' -k1,1 \
             | while IFS=$'\t' read -r id dtb; do
                 echo "$id"; grep -x -- "$dtb-top-dpad" <<<"$ids_menu"
               done)
  [ "$ids_menu" = "$ids_want" ] && ok "grub-$lc.cfg lists the boards in device-id order" \
                                || bad "grub-$lc.cfg menu order: $(tr '\n' ' ' <<<"$ids_menu")"

  # the per-slot cmdline. Every entry must name THIS slot's root, var and efi partitions -- one
  # entry pointing at the other slot is a boot that silently mounts the wrong /var.
  for key in 'root=$rootspec' 'retroforge.var=$varspec' 'retroforge.efi=$efispec' "retroforge.slot=$slot"; do
    n=$(grep -cF -- "$key" "$cfg")
    [ "$n" -eq "$n_entries" ] && ok "grub-$lc.cfg: all $n entries carry $key" \
                              || bad "grub-$lc.cfg: $n of $n_entries entries carry $key"
  done
  other=$([ "$slot" = A ] && echo b || echo a)
  grep -q -- "PARTLABEL=$(part_label "rootfs-$other")" "$cfg" \
    && bad "grub-$lc.cfg references the OTHER slot's root" \
    || ok "grub-$lc.cfg never references the other slot"
  grep -q -- "retroforge.slot=${other^^}" "$cfg" \
    && bad "grub-$lc.cfg tells the initramfs it is slot ${other^^}" \
    || ok "grub-$lc.cfg never claims to be slot ${other^^}"

  # PARTUUID, and the PARTLABEL fallback behind it. The three specs are set ONCE at the top and
  # referenced by every entry, so this is where the partition identity actually gets decided.
  for v in rootuuid varuuid efiuuid; do
    grep -q -- "probe --part-uuid --set=$v " "$cfg" \
      && ok "grub-$lc.cfg derives \$$v with probe --part-uuid" \
      || bad "grub-$lc.cfg never sets \$$v"
  done
  # The PARTUUID assignment must be reachable only when all three probes produced something. probe
  # sets the literal string "none" for a device with no partition rather than failing, so an
  # emptiness test alone would happily put root=PARTUUID=none on the cmdline.
  grep -q 'set rootspec="PARTUUID=\$rootuuid"' "$cfg" \
    && ok "grub-$lc.cfg names the root by PARTUUID when the probe succeeds" \
    || bad "grub-$lc.cfg never uses the probed PARTUUID"
  n_none=$(grep -o '!= "none"' "$cfg" | wc -l)
  [ "$n_none" -eq 3 ] && ok "grub-$lc.cfg rejects all three 'none' probe results" \
                      || bad "grub-$lc.cfg guards $n_none of 3 probe results against \"none\""
  # The fallback arm has to still emit the form that shipped before, or a probe regression is a
  # black screen instead of a message.
  for key in "set rootspec=\"PARTLABEL=$(part_label "rootfs-$lc")\"" \
             "set varspec=\"PARTLABEL=$(part_label "var-$lc")\"" \
             "set efispec=\"PARTLABEL=$(part_label "efi-$lc")\""; do
    grep -qF -- "$key" "$cfg" && ok "grub-$lc.cfg falls back to: $key" \
                              || bad "grub-$lc.cfg has no PARTLABEL fallback for ${key%%=*}"
  done
  # ...and the fallback must be the DEFAULT, assigned before the conditional overrides it. Set the
  # other way round, a failed probe leaves the specs unset and the kernel gets root= with no value.
  ln_fb=$(grep -n 'set rootspec="PARTLABEL=' "$cfg" | cut -d: -f1)
  ln_uu=$(grep -n 'set rootspec="PARTUUID=' "$cfg" | cut -d: -f1)
  [ -n "$ln_fb" ] && [ -n "$ln_uu" ] && [ "$ln_fb" -lt "$ln_uu" ] \
    && ok "grub-$lc.cfg defaults to PARTLABEL and upgrades to PARTUUID" \
    || bad "grub-$lc.cfg sets the PARTUUID spec before the PARTLABEL default, which then clobbers it"

  # Partition indices. They are no longer baked into the device specs: an internal install appends
  # our eight to the OEM's GPT at per-vendor indices, so the specs read variables and the numbers
  # come from parts.env on this slot's efi partition, falling back to the table's own order.
  for spec in "set esp=\"\$bootdisk,gpt\$esp_idx\"" \
              "set slotroot=\"\$bootdisk,gpt\$root_idx\"" \
              "probe --part-uuid --set=varuuid  (\$bootdisk,gpt\$var_idx)"; do
    grep -qF -- "$spec" "$cfg" && ok "grub-$lc.cfg addresses by index variable: ${spec%% *} ${spec#* }" \
      || bad "grub-$lc.cfg does not use an index VARIABLE here -- a baked index is wrong on internal: $spec"
  done
  # ...and the defaults behind those variables are the table's order, so a card is unchanged.
  for kv in "set esp_idx=$(part_num esp)" \
            "set root_idx=$(part_num "rootfs-$lc")" \
            "set var_idx=$(part_num "var-$lc")"; do
    grep -qx -- "$kv" "$cfg" && ok "grub-$lc.cfg defaults to: $kv" \
      || bad "grub-$lc.cfg's index default disagrees with ${TABLE#"$ROOT"/}: expected '$kv'"
  done

  # parts.env. It is read from (\$root) -- the efi partition steamcl chainloaded us from -- because
  # the ESP's own index is one of the numbers in it, so an ESP-resident map could not be located
  # without already knowing what it says.
  grep -q 'load_env -f (\$root)/EFI/steamos/parts.env ' "$cfg" \
    && ok "grub-$lc.cfg loads parts.env from the slot's own efi partition" \
    || bad "grub-$lc.cfg does not load (\$root)/EFI/steamos/parts.env"
  grep -q 'if \[ -f (\$root)/EFI/steamos/parts.env \]; then' "$cfg" \
    && ok "grub-$lc.cfg guards the load with -f, so an image without one is silent" \
    || bad "grub-$lc.cfg loads parts.env unguarded -- every pre-existing image would print an error"
  # Per-slot keys: slot A must take its indices from A's keys, and never from B's. The map is one
  # file shared by both slots, so picking the wrong key is a config that mounts the other slot's
  # /var -- the same failure the per-slot cmdline assertions above guard, one layer earlier.
  grep -qF -- "set root_idx=\"\$nd_root_$lc\"" "$cfg" \
    && ok "grub-$lc.cfg takes its root index from \$nd_root_$lc" \
    || bad "grub-$lc.cfg does not take its root index from \$nd_root_$lc"
  grep -qF -- "set var_idx=\"\$nd_var_$lc\"" "$cfg" \
    && ok "grub-$lc.cfg takes its var index from \$nd_var_$lc" \
    || bad "grub-$lc.cfg does not take its var index from \$nd_var_$lc"
  if grep -qF -- "_idx=\"\$nd_root_$other\"" "$cfg" || grep -qF -- "_idx=\"\$nd_var_$other\"" "$cfg"; then
    bad "grub-$lc.cfg takes an index from slot ${other^^}'s keys"
  else
    ok "grub-$lc.cfg never takes an index from slot ${other^^}'s keys"
  fi
  # ALL-OR-NOTHING. A file missing one key must not yield a map half from the install and half from
  # this build -- a root from one layout with a /var from another boots something nobody assembled.
  # So: exactly three -n tests, in ONE condition, and the three assignments only inside it.
  n_ntest=$(grep -c -- '-n "\$nd_' "$cfg")
  [ "$n_ntest" -eq 1 ] && ok "grub-$lc.cfg validates the loaded keys in a single condition" \
    || bad "grub-$lc.cfg has $n_ntest conditions testing nd_* keys, expected 1 (partial maps must be impossible)"
  n_keys=$(grep -o -- '-n "\$nd_[a-z_]*"' "$cfg" | wc -l)
  [ "$n_keys" -eq 3 ] && ok "grub-$lc.cfg requires all 3 consumed keys before using any" \
    || bad "grub-$lc.cfg tests $n_keys of the 3 keys it consumes"
  n_assign=$(grep -c -- 'set [a-z]*_idx="\$nd_' "$cfg")
  [ "$n_assign" -eq 3 ] && ok "grub-$lc.cfg upgrades all 3 indices together" \
    || bad "grub-$lc.cfg assigns $n_assign indices from parts.env, expected 3"
  # Defaults must be assigned BEFORE the load, or the upgrade is what gets clobbered.
  ln_def=$(grep -n "^set esp_idx=" "$cfg" | cut -d: -f1)
  ln_env=$(grep -n 'load_env -f (\$root)/EFI/steamos/parts.env ' "$cfg" | cut -d: -f1)
  [ -n "$ln_def" ] && [ -n "$ln_env" ] && [ "$ln_def" -lt "$ln_env" ] \
    && ok "grub-$lc.cfg sets the built-in indices before reading parts.env" \
    || bad "grub-$lc.cfg reads parts.env before its defaults, which then overwrite it"
  # The indices have to be settled before anything is addressed with them.
  ln_use=$(grep -n 'set esp="\$bootdisk,gpt\$esp_idx"' "$cfg" | cut -d: -f1)
  [ -n "$ln_use" ] && [ -n "$ln_env" ] && [ "$ln_env" -lt "$ln_use" ] \
    && ok "grub-$lc.cfg reads parts.env before it addresses a partition" \
    || bad "grub-$lc.cfg addresses partitions before parts.env is read"

  # THE DEVICE DERIVATION, executed rather than grepped. GRUB's `regexp` compiles with
  # REG_EXTENDED, so a POSIX ERE engine here (sed -E) is the same matcher the device runs -- which
  # makes this the one assertion that can catch a pattern that parses, ships, and never matches.
  # It did: the first version required literal parens around $root, but GRUB sets `root` to the
  # BARE device name (kern/main.c) and only parenthesises it for $prefix. The config fell through
  # to its search fallback on every boot, and the sole symptom was a message and a 3s pause.
  pat=$(sed -n "s/^regexp -s bootdisk '\(.*\)' \"\$root\"\$/\1/p" "$cfg")
  if [ -z "$pat" ]; then
    bad "grub-$lc.cfg has no 'regexp -s bootdisk' line"
  else
    ok "grub-$lc.cfg derives the boot disk with: $pat"
    for form in 'hd0,gpt2' '(hd0,gpt2)' 'hd0,gpt10'; do
      got=$(printf '%s' "$form" | sed -E "s|$pat|\1|")
      [ "$got" = "hd0" ] && ok "grub-$lc.cfg: \$root='$form' -> bootdisk=hd0" \
                         || bad "grub-$lc.cfg: \$root='$form' -> '$got', expected 'hd0' (the fallback search would run every boot)"
    done
  fi

  # the saved board choice. savedefault is called by every entry and is NOT a GRUB builtin, so a
  # config that does not DEFINE it saves nothing and silently prints an error per entry.
  grep -q '^function savedefault {' "$cfg" && ok "grub-$lc.cfg defines savedefault" \
                                           || bad "grub-$lc.cfg calls savedefault without defining it"
  n_save=$(grep -c '^  savedefault$' "$cfg")
  [ "$n_save" -eq "$n_entries" ] && ok "grub-$lc.cfg: all $n_save entries call savedefault" \
                                 || bad "grub-$lc.cfg: $n_save of $n_entries entries call savedefault"
  grep -q 'load_env -f (\$esp)/EFI/steamos/grubenv' "$cfg" \
    && ok "grub-$lc.cfg loads the ESP grubenv" || bad "grub-$lc.cfg does not load the grubenv"
  grep -q 'save_env -f (\$esp)/EFI/steamos/grubenv' "$cfg" \
    && ok "grub-$lc.cfg saves to the ESP grubenv" || bad "grub-$lc.cfg does not save the grubenv"
  # A config that never sets a timeout waits forever (GRUB treats unset as -1). With a known board
  # the menu is hidden with no wait, and it comes back for 3s exactly when the ESP GRUB says this
  # boot is a retry or a fall-back -- the only way back from a wrong board on a keyboard-less device.
  grep -q '^    set timeout=0$' "$cfg" && grep -q '^    set timeout_style=hidden$' "$cfg" \
    && ok "grub-$lc.cfg boots a known board with the menu hidden" \
    || bad "grub-$lc.cfg has no hidden, no-wait path for a known board"
  grep -q '^  if \[ -n "\$rf_fallback" \]; then set rf_menu=1; fi$' "$cfg" \
    && grep -q '^  if \[ -n "\$rf_retry" -a "\${saved_entry}" != "\$rf_board_ok" \]; then set rf_menu=1; fi$' "$cfg" \
    && grep -q '^    set timeout=3$' "$cfg" \
    && ok "grub-$lc.cfg shows the menu for 3s on a fall-back, or a retry of a board never confirmed" \
    || bad "grub-$lc.cfg does not gate the retry menu on an unconfirmed board"
  grep -q '^load_env -f (\$esp)/EFI/steamos/grubenv saved_entry rf_board_ok$' "$cfg" \
    && ok "grub-$lc.cfg loads the confirmed board" || bad "grub-$lc.cfg never loads rf_board_ok"
  grep -q '^  set timeout=-1$' "$cfg" && ok "grub-$lc.cfg waits when no board is known" \
                                      || bad "grub-$lc.cfg does not wait on a fresh image"

  # Tries are the ESP GRUB's to count now (boot/gen-esp-cfg.sh). A stage-2 config that still
  # bumped the old boot conf would write a file only older roots read.
  grep -q 'retroforge_bootattempts' "$cfg" \
    && bad "grub-$lc.cfg still counts boot attempts in the old boot conf" \
    || ok "grub-$lc.cfg leaves the try count to the ESP GRUB"
  # RAUC's grub backend knows the booted slot only from rauc.slot= on the command line.
  n_rauc=$(grep -c "^  linux .* rauc.slot=$slot\$" "$cfg")
  [ "$n_rauc" = "$n_entries" ] && ok "grub-$lc.cfg: every entry tells RAUC it is slot $slot" \
                               || bad "grub-$lc.cfg: $n_rauc of $n_entries entries carry rauc.slot=$slot"

  # OpenABL's Device model. Every board .dts's root model must map to the entry that boots it, and
  # the mapping must come before the saved choice is used, or the model never wins.
  grep -q '^retroforge_dt_model abl_model$' "$cfg" \
    && ok "grub-$lc.cfg reads OpenABL's Device model" || bad "grub-$lc.cfg never reads OpenABL's Device model"
  for dts in "$DTS"/*.dts; do
    base=$(basename "$dts" .dts)
    mdl=$(sed -n 's/^[[:space:]]*model = "\(.*\)";.*/\1/p' "$dts" | head -1)
    [ -n "$mdl" ] || continue
    want="$base"
    while IFS=$'\t' read -r rid rname rdtb rba; do
      [ -n "$rid" ] && [[ $rid != \#* ]] && [ "$rdtb" = "$base" ] && { want="$rid"; break; }
    done <"$BOARDS"
    grep -qxF "if [ \"\$abl_model\" = \"$mdl\" ]; then set abl_board=$want; fi" "$cfg" \
      && ok "grub-$lc.cfg maps model '$mdl' to $want" \
      || bad "grub-$lc.cfg does not map OpenABL's model '$mdl' to $want"
  done
  ln_map=$(grep -n '^retroforge_dt_model abl_model$' "$cfg" | cut -d: -f1)
  ln_def=$(grep -n '^  set default="\${saved_entry}"$' "$cfg" | cut -d: -f1)
  [ -n "$ln_map" ] && [ -n "$ln_def" ] && [ "$ln_map" -lt "$ln_def" ] \
    && ok "grub-$lc.cfg applies OpenABL's model before it picks the default" \
    || bad "grub-$lc.cfg picks the default before it reads OpenABL's model"
  ln_term=$(grep -n '^terminal_output gfxterm$' "$cfg" | cut -d: -f1)

  # Radio addresses. The fixup applies when `linux` boots, so the command has to run before any
  # menuentry can be chosen, and after the terminal is up so its failure can be read.
  ln_mac=$(grep -n '^if retroforge_radiomac; then$' "$cfg" | cut -d: -f1)
  ln_entry=$(grep -n '^menuentry ' "$cfg" | head -1 | cut -d: -f1)
  [ -n "$ln_mac" ] && [ -n "$ln_term" ] && [ -n "$ln_entry" ] \
    && [ "$ln_mac" -gt "$ln_term" ] && [ "$ln_mac" -lt "$ln_entry" ] \
    && ok "grub-$lc.cfg arms retroforge_radiomac after the terminal and before the first entry" \
    || bad "grub-$lc.cfg does not call retroforge_radiomac between terminal_output and the menu"

  # Console. rotation is read once, when the video driver builds the framebuffer render target, so
  # a `set rotation=` that lands AFTER terminal_output parses fine, ships, and does nothing — the
  # ordering is the whole assertion. The colours have no such constraint.
  ln_rot=$(grep -n '^set rotation=270$' "$cfg" | cut -d: -f1)
  [ -n "$ln_rot" ] \
    && ok "grub-$lc.cfg rotates the framebuffer 270" \
    || bad "grub-$lc.cfg does not set rotation=270 — patch 0001 is inert without it"
  [ -n "$ln_rot" ] && [ -n "$ln_term" ] && [ "$ln_rot" -lt "$ln_term" ] \
    && ok "grub-$lc.cfg sets rotation before terminal_output gfxterm" \
    || bad "grub-$lc.cfg sets rotation after the terminal is up, where it is a no-op"
  # Per-SoC overrides: an SM6115 or SM4450 board gets `set rotation=90` keyed on its saved entry, between the
  # default and terminal_output (boot/gen-grub-cfg.sh soc_grub_rotation); every other board gets none.
  ln_term=$(grep -n '^terminal_output gfxterm$' "$cfg" | cut -d: -f1)
  while IFS=$'\t' read -r id name dtb ba; do
    [ -n "$id" ] && [[ $id != \#* ]] && [ -n "$dtb" ] || continue
    # Mirror of boot/gen-grub-cfg.sh soc_grub_rotation: SM6115/SM4450 -> 90, the landscape Air Y Pro -> 0.
    case "$dtb" in
      sm6115-mangmi-air-y)     want=0 ;;
      sm8250-mangmi-air-y-pro) want=0 ;;
      sm6115-*)                want=90 ;;
      sm4450-*)                want=90 ;;
      *)                       want="" ;;
    esac
    ln_any=$(grep -n "^if \[ \"\${saved_entry}\" = \"$id\" \]; then set rotation=" "$cfg" | cut -d: -f1)
    if [ -n "$want" ]; then
      ln_ov=$(grep -n "^if \[ \"\${saved_entry}\" = \"$id\" \]; then set rotation=$want; fi$" "$cfg" | cut -d: -f1)
      [ -n "$ln_ov" ] && [ "$ln_ov" -gt "$ln_rot" ] && [ "$ln_ov" -lt "$ln_term" ] \
        && ok "grub-$lc.cfg rotates the menu $want for $id, before the terminal" \
        || bad "grub-$lc.cfg has no rotation=$want override for $id between the default and terminal_output"
    else
      [ -z "$ln_any" ] && ok "grub-$lc.cfg keeps the default rotation for $id" \
        || bad "grub-$lc.cfg overrides rotation for $id, which needs the 270 default"
    fi
  done < "$BOARDS"
  grep -q '^set menu_color_normal=cyan/blue$' "$cfg" \
    && ok "grub-$lc.cfg sets menu_color_normal" \
    || bad "grub-$lc.cfg does not set menu_color_normal"
  grep -q '^set menu_color_highlight=white/blue$' "$cfg" \
    && ok "grub-$lc.cfg sets menu_color_highlight" \
    || bad "grub-$lc.cfg does not set menu_color_highlight"

  # Every arm that prints a diagnostic must hold it on screen long enough to READ. gfxterm draws in
  # the boot font, already at the only scale lever we have, and 3s was measured too short on a
  # Pocket S2 panel (2026-08-06). A pause that drifts back down makes the message useless on the one
  # class of device that has no other diagnostic at all.
  n_short=$(grep -cE '^ *sleep [1-9]$' "$cfg")
  [ "$n_short" -eq 0 ] && ok "grub-$lc.cfg holds every diagnostic for 10s or more" \
    || bad "grub-$lc.cfg has $n_short arm(s) pausing under 10s — unreadable on a handheld panel"
  n_sleep=$(grep -cE '^ *sleep 10$' "$cfg")
  [ "$n_sleep" -eq 4 ] && ok "grub-$lc.cfg: all 4 diagnostic arms pause 10s" \
    || bad "grub-$lc.cfg has $n_sleep 10s pauses, expected 4 (an arm lost its dwell, or gained one)"

  if command -v grub-script-check >/dev/null 2>&1; then
    grub-script-check "$cfg" 2>"$T/gscerr" \
      && ok "grub-$lc.cfg parses under grub-script-check" \
      || bad "grub-$lc.cfg is not valid GRUB script: $(head -1 "$T/gscerr")"
  else
    skip "grub-script-check not installed (it is in the build container)"
  fi
done

# --- 6. the ESP GRUB's slot picker ---------------------------------------------------------------
# boot/gen-esp-cfg.sh, embedded in grub-esp.efi. It reads RAUC's slot state the way RAUC's reference
# grub.cfg does, follows an older root's boot conf when it changes, and hands over by setting $root
# and $prefix to the chosen slot's efi partition.
CASE="ESP slot picker"
espcfg="$T/esp.cfg"
if "$ROOT/boot/gen-esp-cfg.sh" "$espcfg" >/dev/null; then
  ok "generated"
  grep -q '^load_env -f "\$env" ORDER A_OK A_TRY B_OK B_TRY rf_bcsync$' "$espcfg" \
    && ok "reads RAUC's ORDER/OK/TRY and its boot-conf note" || bad "does not load RAUC's slot state"
  grep -q '^set env="(\$esp)/EFI/steamos/grubenv"$' "$espcfg" \
    && ok "uses the grubenv system.conf names" || bad "reads some other grubenv"
  sysconf="$ROOT/rootfs/overlay/etc/rauc/system.conf"
  grep -qx 'bootloader=grub' "$sysconf" && grep -qx 'grubenv=/esp/EFI/steamos/grubenv' "$sysconf" \
    && ok "system.conf drives the same block (bootloader=grub, grubenv=/esp/EFI/steamos/grubenv)" \
    || bad "system.conf does not point RAUC's grub backend at the ESP grubenv"
  # Three tries, then the slot is skipped: TRY values 0, 1 and 2 still boot; anything else does not.
  grep -q '^  if \[ -n "\$t" -a "\$t" != 0 -a "\$t" != 1 -a "\$t" != 2 \]; then continue; fi$' "$espcfg" \
    && ok "a slot is skipped once its three tries are used" || bad "the try limit is not 0/1/2"
  grep -q '^  if \[ "\$try" = 2 \]; then set nt=3; elif \[ "\$try" = 1 \]; then set nt=2; else set nt=1; fi$' "$espcfg" \
    && ok "each boot counts one try" || bad "the try is not counted up one at a time"
  # Only the chosen slot's TRY is written: save_env deletes a variable that is unset, and RAUC fails
  # every call that reads a missing one.
  grep -q 'save_env -f "\$env" \$tryvar' "$espcfg" && ! grep -q 'save_env -f "\$env" A_TRY B_TRY' "$espcfg" \
    && ok "writes only the chosen slot's TRY" || bad "writes TRY variables it did not set"
  # A slot is a candidate only with a stage-2 config and a kernel, so an empty B is never chosen.
  grep -q '/boot/vmlinuz.efi ]; then set kern=1; fi' "$espcfg" && grep -q '/boot/Image ]; then set kern=1; fi' "$espcfg" \
    && grep -q '/EFI/steamos/grub.cfg -a "\$kern" = 1' "$espcfg" \
    && ok "checks the slot's grub.cfg and kernel (vmlinuz.efi or an older root's Image) before choosing it" || bad "chooses a slot without checking it is there"
  grep -q '^set prefix="(\$root)/EFI/steamos"$' "$espcfg" && tail -1 "$espcfg" | grep -qx 'source \$prefix/grub.cfg' \
    && ok "hands over by sourcing the slot's grub.cfg from its efi partition" || bad "does not source \$prefix/grub.cfg for the hand-over"
  # The old boot conf: only a CHANGE since the last look moves ORDER, so a device with no older root
  # left never has RAUC's state overridden.
  grep -q '^  if \[ "\$bc_sel:\$bc_at" != "\$rf_bcsync" \]; then$' "$espcfg" \
    && ok "follows the old boot conf only when it changed" || bad "follows the old boot conf unconditionally"
  # Partition indices: the build-time ones must be the card's, and parts.env must override them.
  for kv in "efi_a_idx=$(awk '/^[[:space:]]*#/||/^[[:space:]]*$/{next} {i++; if ($1=="efi-a") print i}' "$TABLE")" \
            "efi_b_idx=$(awk '/^[[:space:]]*#/||/^[[:space:]]*$/{next} {i++; if ($1=="efi-b") print i}' "$TABLE")" \
            "root_a_idx=$(awk '/^[[:space:]]*#/||/^[[:space:]]*$/{next} {i++; if ($1=="rootfs-a") print i}' "$TABLE")" \
            "root_b_idx=$(awk '/^[[:space:]]*#/||/^[[:space:]]*$/{next} {i++; if ($1=="rootfs-b") print i}' "$TABLE")"; do
    grep -qx "set $kv" "$espcfg" && ok "built-in $kv" || bad "built-in index is not $kv"
  done
  grep -q '^  load_env -f "\$pe" nd_efi_a nd_efi_b nd_root_a nd_root_b$' "$espcfg" \
    && ok "parts.env overrides the built-in indices" || bad "does not read parts.env"
  # The commands it calls have to be embedded (boot/grub.sh MODULES).
  for m in loadenv regexp btrfs retroforge; do
    printf '%s' "$MODLINE" | grep -qw -- "$m" && ok "$m is embedded" || bad "$m is not in boot/grub.sh MODULES"
  done
  if command -v grub-script-check >/dev/null 2>&1; then
    grub-script-check "$espcfg" 2>"$T/gscerr" \
      && ok "parses under grub-script-check" \
      || bad "does not parse: $(head -1 "$T/gscerr")"
  else
    skip "grub-script-check not installed (it is in the build container)"
  fi
else
  bad "boot/gen-esp-cfg.sh failed"
fi

# --- 7. the board bootargs left the device trees ------------------------------------------------
# They live on the `linux` line now. They have to: the EFI stub OVERWRITES /chosen/bootargs with
# the loader's command line, so anything still in a dtsi is silently dropped.
CASE="dtsi bootargs stripped"
n_ba=0
for f in "$DTS"/*.dtsi; do
  grep -q 'bootargs *=' "$f" && { n_ba=$((n_ba+1)); bad "$(basename "$f") still carries /chosen/bootargs"; }
done
[ "$n_ba" -eq 0 ] && ok "no /chosen/bootargs remain in the dtsi files"

printf '\n%s: %d passed, %d failed, %d skipped\n' "$(basename "$0")" "$PASS" "$FAIL" "$SKIP"
[ "$FAIL" -eq 0 ]
