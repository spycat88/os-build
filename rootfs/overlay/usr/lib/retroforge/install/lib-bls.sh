# retroforge Boot Loader Specification primitives: the slot entries OpenABL boots, and the A/B
# state they carry.
#
# SOURCED, never executed (mode 0444, like lib-slotwrite.sh).
#
# THE BOOT CHAIN IS ONE STEP. OpenABL reads \loader\entries\*.conf (Boot Loader Specification
# Type #1) off every FAT filesystem on the boot drive and starts the kernel an entry names, with that
# entry's initrd and command line. There is no second-stage loader.
#
# EACH SLOT HAS ITS OWN PARTITION for what boots it: boot-a for slot A, boot-b for slot B. An entry's
# paths resolve on the filesystem the entry sits on, so a slot's entries sit beside its files:
#
#   boot-a  \loader\entries\retroforge-a+3.conf     slot A's entry; +3 is its boot counter
#          \loader\entries\retroforge-debug-a.conf slot A, booted verbosely (uncounted)
#          \vmlinuz-<kernel version>               kernel, initramfs and DTBs, copied out of root A
#          \initramfs-<kernel version>.img
#          \dtbs\<board>.dtb
#   boot-b  the same for B
#   ESP    \loader\loader.conf                     `default retroforge-<slot>.conf` -- the primary
#
# AN ENTRY NAMES NO DEVICETREE. OpenABL installs the devicetree of its Device model setting, read
# from the \dtbs folder of the partition the entry it boots sits on, so slot A boots with slot A's
# DTBs and slot B with slot B's. The same folders are what OpenABL lists its Device models from.
#
# OpenABL ranks the entries of every filesystem on the boot drive as ONE list (as the specification
# does for an ESP and an XBOOTLDR partition), and reads loader.conf off whichever of them has one, so
# a slot that has run out of tries goes behind the other slot's entry whichever partition the
# firmware lists first.
#
# THE A/B STATE IS THE FILE NAMES, as in systemd's Automatic Boot Assessment, which OpenABL
# implements:
#
#   retroforge-a+3.conf     three tries left. OpenABL renames it before each boot:
#   retroforge-a+2-1.conf   two left, one done ... and on to
#   retroforge-a+0-3.conf   none left: "bad". OpenABL sorts it last, and the loader.conf default no
#                           longer matches it, so the other slot boots.
#
# Every boot is counted, not just the first one after an update: retroforge-bootctl mark-good (a
# healthy boot, confirmed) puts the counter back to +3. Three boots in a row that never got that far
# and the other slot takes over. systemd-bless-boot, which would drop the counter instead and stop
# the counting for good, is masked.
#
# THE DEBUG ENTRIES carry no counter and no sort-key, so OpenABL lists them after every slot entry:
# they are picked by hand from its menu, and booted unattended only when neither slot has a try
# left, which is when a verbose boot is the most useful thing left to do.
#
# RAUC drives the state through its custom bootloader backend, which is retroforge-bootctl, which
# calls these:
#
#   get-primary      the loader.conf default if that slot is good, else the other slot if it is
#   set-primary X    X's counter back to +3 and loader.conf `default retroforge-x.conf`
#   get-state X      good while X's entry has tries left (or no counter), bad otherwise or absent
#   set-state X good X's counter back to +3
#   set-state X bad  X's counter to +0: OpenABL boots the other slot first
#
# A FRESH CARD carries the same slot entries every device gets, with one difference: one image serves
# every board, so its entries carry only the command line every board shares, and OpenABL's Device
# model setting picks the DTB off the slot's partition. The first healthy boot rewrites the booted
# slot's entries with the board's own arguments added (refresh_booted in retroforge-bootctl, run by
# mark-good). The update hook and the internal installer run on a device that has already booted, so
# they read the board off the running devicetree and write the board's entries straight away.
#
# WHAT AN ENTRY SAYS comes from the root it boots, out of /usr/lib/retroforge/boot (rootfs/
# lib-assemble-boot.sh): boards.tsv and cmdline (boot/gen-bls.sh), and `release`, which names the
# build version and the kernel version.
#
# The functions take explicit arguments and touch nothing implicitly, like lib-slotwrite.sh's: <slotfs>
# is wherever that slot's boot partition is mounted, <esp> wherever the ESP is.

if ! declare -F die >/dev/null 2>&1; then
  die() { printf '[lib-bls] ERROR: %s\n' "$1" >&2; exit 1; }
fi
if ! declare -F log >/dev/null 2>&1; then
  log() { printf '[lib-bls] %s\n' "$1"; }
fi

# Tries a slot gets: after an update, and again after every confirmed boot.
BLS_TRIES=3

# Where things are, relative to a filesystem's root. Forward slashes: OpenABL turns them into the
# UEFI path separator itself, and the specification writes them this way.
BLS_ENTRIES=loader/entries
BLS_LOADER_CONF=loader/loader.conf

# Slot entries sort under one key, ahead of everything without one (the debug entries).
BLS_SORT_KEY=retroforge

bls_lc() {  # <A|B> -> a|b
  case "${1:-}" in
    A|a) echo a ;;
    B|b) echo b ;;
    *) die "'${1:-}' is not a slot (A or B)" ;;
  esac
}

bls_other() {  # <A|B> -> the other one
  case "${1:-}" in
    A|a) echo B ;;
    B|b) echo A ;;
    *) die "'${1:-}' is not a slot (A or B)" ;;
  esac
}

# --- pure: what goes in an entry ----------------------------------------------------------------

# The board row for a devicetree model, from the board table boot/gen-bls.sh generated. Empty when
# the model is not a board this build knows.
bls_board_row() {  # <boards.tsv> <model> -> id<TAB>name<TAB>dtb<TAB>model<TAB>bootargs
  [ -r "$1" ] || die "no board table at $1"
  awk -F'\t' -v m="$2" '/^#/ { next } $4 == m { print; exit }' "$1"
}

bls_board_by_id() {  # <boards.tsv> <id> -> the row
  [ -r "$1" ] || die "no board table at $1"
  awk -F'\t' -v i="$2" '/^#/ { next } $1 == i { print; exit }' "$1"
}

bls_field() {  # <row> <1-5>
  printf '%s\n' "$1" | cut -f"$2"
}

# One key of a root's `release` file (version=, kernel=). Dies when it is not there: an entry with
# no kernel version names a file that does not exist.
bls_release() {  # <release-file> <key>
  local v
  [ -r "$1" ] || die "no release file at $1 -- that root predates the BLS boot chain"
  v="$(sed -n "s/^$2=//p" "$1" | head -1)"
  [ -n "$v" ] || die "$1 names no $2"
  case "$v" in *[!A-Za-z0-9._+~-]*) die "$1: $2 '$v' is not a plain version" ;; esac
  printf '%s\n' "$v"
}

# The full command line of one slot's entry. The common part and the board's part come from the
# root being booted (its /usr/lib/retroforge/boot/cmdline and boards.tsv); the rest is this disk.
#
# PARTUUID, NOT PARTLABEL. Every retroforge medium carries the same eight GPT names, so with a card
# left in after an install to internal storage a PARTLABEL resolves to whichever disk enumerates
# first. The UUIDs are read off the disk the entry is written to, so they name it by construction,
# and nothing has to rewrite them when the slot is updated (an update writes the root's content,
# never the partition table).
#
# retroforge.slot= and rauc.slot= are stated outright: a PARTUUID carries no slot letter, the
# initramfs mounts by the first, and RAUC finds the booted slot by the second.
bls_cmdline() {  # <common> <board-bootargs> <A|B> <root-uuid> <var-uuid>
  local common="$1" board="$2" slot="${3^^}" root="$4" var="$5"
  bls_lc "$slot" >/dev/null
  [ -n "$root" ] && [ -n "$var" ] \
    || die "slot $slot: a partition UUID is missing (root '$root', var '$var')"
  printf '%s%s root=PARTUUID=%s rootfstype=btrfs rootwait ro retroforge.var=PARTUUID=%s retroforge.slot=%s rauc.slot=%s\n' \
    "$common" "${board:+ $board}" "$root" "$var" "$slot" "$slot"
}

# The debug variant of a command line: everything the quiet boot hides, shown. No `quiet`, the full
# console log level, no splash over it, systemd's unit status on the console, and the kernel's fbdev
# console back so there is somewhere to show it.
bls_debug_cmdline() {  # <cmdline>
  local a out=""
  for a in $1; do
    case "$a" in
      quiet|loglevel=*|drm_kms_helper.fbdev_emulation=*|retroforge.splash=*|systemd.show_status=*) continue ;;
    esac
    out="${out:+$out }$a"
  done
  printf '%s loglevel=7 retroforge.splash=0 systemd.show_status=1\n' "$out"
}

bls_title() {  # <A|B> [debug]
  if [ -n "${2:-}" ]; then printf 'RetroForge (Slot %s, debug)\n' "${1^^}"
  else printf 'RetroForge (Slot %s)\n' "${1^^}"; fi
}

# One Type #1 entry. The paths are relative to the slot's own partition, which is where the entry
# sits. <sort-key> is empty for an entry that sorts after all of them (debug). No devicetree key:
# OpenABL installs its Device model's DTB from this same partition (see the header).
bls_entry_text() {  # <title> <build-version> <kernel-version> <cmdline> [sort-key]
  printf 'title %s\n' "$1"
  printf 'version %s\n' "$2"
  [ -z "${5:-}" ] || printf 'sort-key %s\n' "$5"
  printf 'linux /vmlinuz-%s\n' "$3"
  printf 'initrd /initramfs-%s.img\n' "$3"
  printf 'options %s\n' "$4"
}

bls_loader_conf_text() {  # [A|B] [timeout]
  printf '# retroforge. The default is the primary slot; RAUC moves it through retroforge-bootctl.\n'
  [ -z "${1:-}" ] || printf 'default retroforge-%s.conf\n' "$(bls_lc "$1")"
  [ -z "${2:-}" ] || printf 'timeout %s\n' "$2"
}

bls_entry_name() {  # <A|B> <tries-left> -> retroforge-a+3.conf
  printf 'retroforge-%s+%s.conf\n' "$(bls_lc "$1")" "$2"
}

bls_debug_name() {  # <A|B> -> retroforge-debug-a.conf
  printf 'retroforge-debug-%s.conf\n' "$(bls_lc "$1")"
}

# --- reading the state --------------------------------------------------------------------------

# The slot's entry file on its partition, whichever counter it carries. Status 1 when there is none.
bls_entry_file() {  # <slotfs> <A|B>
  local fs="$1" lc f
  lc="$(bls_lc "$2")"
  for f in "$fs/$BLS_ENTRIES/retroforge-$lc.conf" "$fs/$BLS_ENTRIES/retroforge-$lc+"*.conf; do
    [ -f "$f" ] && { printf '%s\n' "$f"; return 0; }
  done
  return 1
}

# Tries left on an entry file name, or "" for an uncounted one. Malformed counters read as
# uncounted, which is how OpenABL reads them too.
bls_tries_left() {  # <file>
  local name="${1##*/}" counter
  name="${name%.conf}"
  case "$name" in
    *+*) counter="${name##*+}" ;;
    *) return 0 ;;
  esac
  counter="${counter%%-*}"
  case "$counter" in
    ''|*[!0-9]*) return 0 ;;
  esac
  printf '%s\n' "$((10#$counter))"
}

bls_state() {  # <slotfs> <A|B> -> good|bad
  local f left
  f="$(bls_entry_file "$1" "$2")" || { echo bad; return 0; }
  left="$(bls_tries_left "$f")"
  if [ -z "$left" ] || [ "$left" -gt 0 ]; then echo good; else echo bad; fi
}

bls_default() {  # <esp> -> A|B, or nothing
  local conf="$1/$BLS_LOADER_CONF" d
  [ -f "$conf" ] || return 0
  d="$(sed -n 's/^[[:space:]]*default[[:space:]]\{1,\}retroforge-\([abAB]\)\.conf[[:space:]]*$/\1/p' "$conf" | tail -1)"
  [ -z "$d" ] || printf '%s\n' "${d^^}"
}

# The slot OpenABL boots next, by its own rule: the default if it has tries left, else the first
# that does. Status 1 when neither has.
bls_primary() {  # <esp> <slotfs-a> <slotfs-b> -> A|B
  local esp="$1" fsa="$2" fsb="$3" first s fs
  first="$(bls_default "$esp")"
  for s in $first A B; do
    if [ "$s" = A ]; then fs="$fsa"; else fs="$fsb"; fi
    [ "$(bls_state "$fs" "$s")" = good ] && { printf '%s\n' "$s"; return 0; }
  done
  return 1
}

# --- writing the state --------------------------------------------------------------------------
# EVERY WRITE IS ONE RENAME OR ONE CREATE, so a power cut leaves the old state or the new one. vfat's
# rename replaces the target's directory entry in place. Content goes to a name OpenABL does not
# read (.conf.new) and is renamed into place once it is on disk.

bls_sync() {
  sync -f "$1" 2>/dev/null || sync
}

# Moves the slot's counter to <left> tries. Status 1 when the slot has no entry.
bls_set_tries() {  # <slotfs> <A|B> <left>
  local fs="$1" slot="$2" left="$3" f dst
  f="$(bls_entry_file "$fs" "$slot")" || return 1
  dst="$fs/$BLS_ENTRIES/$(bls_entry_name "$slot" "$left")"
  if [ "$f" != "$dst" ]; then
    mv -f "$f" "$dst" || die "cannot rename ${f##*/} to ${dst##*/}"
  fi
  bls_sync "$fs/$BLS_ENTRIES"
}

# Takes away everything that boots the slot: its entry and its debug entry, so nothing on its
# partition is bootable while the partition is being rewritten.
bls_remove() {  # <slotfs> <A|B>
  local fs="$1" f
  while f="$(bls_entry_file "$fs" "$2")"; do
    rm -f "$f" || die "cannot remove ${f##*/}"
  done
  rm -f "$fs/$BLS_ENTRIES/$(bls_debug_name "$2")" || die "cannot remove slot $2's debug entry"
  bls_sync "$fs"
}

# Writes a file into place through a temporary name OpenABL ignores.
bls_put() {  # <path> <content>
  local dst="$1"
  mkdir -p "${dst%/*}" || die "cannot create ${dst%/*}"
  printf '%s' "$2" >"$dst.new" || die "cannot write $dst.new"
  bls_sync "$dst.new"
  mv -f "$dst.new" "$dst" || die "cannot rename $dst.new over $dst"
  bls_sync "${dst%/*}"
}

# The slot's entry, armed with <left> tries. Replaces whatever entry the slot had.
bls_write_entry() {  # <slotfs> <A|B> <text> [left]
  local fs="$1" slot="$2" text="$3" left="${4:-$BLS_TRIES}" name f
  name="$(bls_entry_name "$slot" "$left")"
  mkdir -p "$fs/$BLS_ENTRIES" || die "cannot create $fs/$BLS_ENTRIES"
  printf '%s' "$text" >"$fs/$BLS_ENTRIES/$name.new" || die "cannot write $name.new"
  bls_sync "$fs/$BLS_ENTRIES/$name.new"
  while f="$(bls_entry_file "$fs" "$slot")"; do
    rm -f "$f" || die "cannot remove ${f##*/}"
  done
  mv -f "$fs/$BLS_ENTRIES/$name.new" "$fs/$BLS_ENTRIES/$name" || die "cannot rename $name.new into place"
  bls_sync "$fs/$BLS_ENTRIES"
}

bls_write_debug() {  # <slotfs> <A|B> <text>
  bls_put "$1/$BLS_ENTRIES/$(bls_debug_name "$2")" "$3"
}

bls_set_default() {  # <esp> <A|B> [timeout]
  bls_put "$1/$BLS_LOADER_CONF" "$(bls_loader_conf_text "$2" "${3:-}")"$'\n'
}

# The slot's kernel, initramfs and DTBs, out of a mounted root, onto the slot's partition, named by
# the kernel version the root's `release` gives. <rootmnt> is the root being installed -- never the
# running one -- so a root and the files that boot it come from one build. The DTBs are
# /usr/lib/retroforge/boot/dtbs, the copies with a splash region where the board's tree has none
# (boot/splash-dtbs.sh says why OpenABL needs one), not the bare /boot/dtbs.
#
# The CALLER takes the slot's entries away first (bls_remove): the files are replaced, and an entry
# pointing at them in the meantime would be a try spent on files that are not there. Whatever an
# older build left (a kernel of another version) goes, so the partition holds one build.
bls_install_slot_files() {  # <slotfs> <rootmnt>
  local fs="$1" rootmnt="$2" kver d
  kver="$(bls_release "$rootmnt/usr/lib/retroforge/boot/release" kernel)"
  [ -f "$rootmnt/boot/vmlinuz" ] || die "the root at $rootmnt has no /boot/vmlinuz"
  [ -f "$rootmnt/boot/initramfs-retroforge.img" ] || die "the root at $rootmnt has no /boot/initramfs-retroforge.img"
  compgen -G "$rootmnt/usr/lib/retroforge/boot/dtbs/*.dtb" >/dev/null \
    || die "the root at $rootmnt has no DTBs in /usr/lib/retroforge/boot/dtbs"
  rm -rf "$fs"/vmlinuz-* "$fs"/initramfs-*.img "$fs/dtbs" "$fs"/*.new \
    || die "cannot clear the old boot files off $fs"
  mkdir -p "$fs/dtbs" || die "cannot create $fs/dtbs"
  cp "$rootmnt/boot/vmlinuz" "$fs/vmlinuz-$kver.new" || die "cannot copy the kernel to $fs"
  cp "$rootmnt/boot/initramfs-retroforge.img" "$fs/initramfs-$kver.img.new" || die "cannot copy the initramfs to $fs"
  for d in "$rootmnt"/usr/lib/retroforge/boot/dtbs/*.dtb; do
    cp "$d" "$fs/dtbs/" || die "cannot copy ${d##*/} to $fs"
  done
  bls_sync "$fs"
  mv -f "$fs/vmlinuz-$kver.new" "$fs/vmlinuz-$kver" || die "cannot move the kernel into place"
  mv -f "$fs/initramfs-$kver.img.new" "$fs/initramfs-$kver.img" || die "cannot move the initramfs into place"
  bls_sync "$fs"
}

bls_slot_files_present() {  # <slotfs>
  compgen -G "$1/vmlinuz-*" >/dev/null
}

# --- on a running device ------------------------------------------------------------------------

# A partition's PARTUUID, lower case, from its device node; empty when blkid cannot say, which the
# callers check, so a failing blkid is never a silent exit under set -e -o pipefail. BLKID is the
# offline suites' seam.
bls_dev_partuuid() {  # <dev>
  local u
  u="$("${BLKID:-blkid}" -s PARTUUID -o value "$1" 2>/dev/null)" || u=""
  printf '%s\n' "$u" | tr 'A-Z' 'a-z'
}

# The devicetree model this system booted with: how a running device names its board. DT_MODEL is
# the offline suites' seam.
bls_running_model() {
  tr -d '\0' <"${DT_MODEL:-/sys/firmware/devicetree/base/model}" 2>/dev/null || true
}

# The two entry texts for one slot of THIS device, from the boot data of the root being booted
# (<bootdir> is that root's /usr/lib/retroforge/boot) and the slot's root and var UUIDs: the
# slot's entry, or with `debug` its debug entry. Dies when the running board is not one that root
# knows: an entry with the wrong DTB or without the board's arguments is a slot that does not boot,
# so it is refused before anything is written.
bls_device_entry() {  # <bootdir> <A|B> <root-uuid> <var-uuid> [debug]
  local bootdir="$1" slot="${2^^}" model row version kver cmd
  [ -r "$bootdir/boards.tsv" ] && [ -r "$bootdir/cmdline" ] && [ -r "$bootdir/release" ] \
    || die "no board table, command line or release in $bootdir -- that root predates the BLS boot chain"
  version="$(bls_release "$bootdir/release" version)"
  kver="$(bls_release "$bootdir/release" kernel)"
  model="$(bls_running_model)"
  [ -n "$model" ] || die "cannot read this device's devicetree model"
  row="$(bls_board_row "$bootdir/boards.tsv" "$model")"
  [ -n "$row" ] || die "this device's model '$model' is not a board that root knows"
  cmd="$(bls_cmdline "$(head -1 "$bootdir/cmdline")" "$(bls_field "$row" 5)" "$slot" "$3" "$4")"
  if [ -n "${5:-}" ]; then
    bls_entry_text "$(bls_title "$slot" debug)" "$version" "$kver" "$(bls_debug_cmdline "$cmd")"
  else
    bls_entry_text "$(bls_title "$slot")" "$version" "$kver" "$cmd" "$BLS_SORT_KEY"
  fi
}
