#!/usr/bin/env bash
# Boot the real ESP GRUB under QEMU/AAVMF on a synthetic retroforge-shaped disk and check what its
# slot picker does across boots: try counting, fall-back, RAUC's OK/TRY, a missing kernel, an older
# root's boot conf, and OpenABL's model through the firmware devicetree. Each slot's efi partition
# carries a probe grub.cfg that prints what it was handed and powers off; the grubenv is read back
# off the ESP after every boot.
#
#   tests/test-esp-grub-qemu.sh out/boot/grub-esp.efi
#
# NOT part of `make test`: it needs a built grub-esp.efi (boot/grub.sh) and qemu-system-aarch64,
# AAVMF (qemu-efi-aarch64), mtools, dosfstools, gdisk, btrfs-progs and grub-common, which the build
# image does not carry. A Debian container with those packages runs it in ~10 minutes under TCG.
# QUICK=1 stops after the first boot and prints its console; BOOT_TIMEOUT caps each boot (s).
set -uo pipefail
ESPEFI="$1"
W="$(mktemp -d)"; cd "$W"
export MTOOLS_SKIP_CHECK=1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok   $*"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL $*"; }

FW=""
for f in /usr/share/qemu-efi-aarch64/QEMU_EFI.fd /usr/share/AAVMF/AAVMF_CODE.fd; do [ -f "$f" ] && { FW="$f"; break; }; done
[ -n "$FW" ] || { echo "no AAVMF firmware"; exit 2; }

MIB=$((1024*1024))
# card layout: 1 esp, 2 efi-a, 3 efi-b, 4 root-a, 5 root-b
mkdisk() {  # <with_root_b 0|1>
  rm -f disk.img; truncate -s 700M disk.img
  sgdisk -o -n1:2048:+64M -t1:ef00 -n2:0:+32M -t2:0700 -n3:0:+32M -t3:0700 \
         -n4:0:+256M -t4:8300 -n5:0:+256M -t5:8300 disk.img >/dev/null
  start() { sgdisk -i "$1" disk.img | sed -n 's/^First sector: \([0-9]*\).*/\1/p'; }
  # ESP
  truncate -s 64M esp.img; mkfs.vfat -F 32 -n RETROFORGE esp.img >/dev/null
  mmd -i esp.img ::/EFI ::/EFI/BOOT ::/EFI/steamos
  mcopy -i esp.img "$ESPEFI" ::/EFI/BOOT/BOOTAA64.EFI
  # efi-a / efi-b: a probe stage 2
  for s in A B; do
    truncate -s 32M "efi-$s.img"; mkfs.vfat -F 32 -n "GRUB-$s" "efi-$s.img" >/dev/null
    mmd -i "efi-$s.img" ::/EFI ::/EFI/steamos
    cat >probe.cfg <<EOF
retroforge_dt_model m
echo "RF-PROBE slot=$s retry=[\$rf_retry] fallback=[\$rf_fallback] model=[\$m] root=[\$root]"
halt
EOF
    mcopy -i "efi-$s.img" probe.cfg ::/EFI/steamos/grub.cfg
  done
  # roots: btrfs with a kernel, A by the old name (a root from before the zboot kernel), B the new
  for s in A B; do
    k=vmlinuz.efi; [ "$s" = A ] && k=Image
    rm -rf "rootdir-$s"; mkdir -p "rootdir-$s/boot"; echo "kernel $s" >"rootdir-$s/boot/$k"
    truncate -s 256M "root-$s.img"
    if [ "$s" = A ] || [ "$1" = 1 ]; then mkfs.btrfs -q -f -r "rootdir-$s" "root-$s.img" >/dev/null
    else mkfs.btrfs -q -f "root-$s.img" >/dev/null; fi
  done
  dd if=esp.img of=disk.img bs=512 seek="$(start 1)" conv=notrunc status=none
  dd if=efi-A.img of=disk.img bs=512 seek="$(start 2)" conv=notrunc status=none
  dd if=efi-B.img of=disk.img bs=512 seek="$(start 3)" conv=notrunc status=none
  dd if=root-A.img of=disk.img bs=512 seek="$(start 4)" conv=notrunc status=none
  dd if=root-B.img of=disk.img bs=512 seek="$(start 5)" conv=notrunc status=none
  ESPOFF=$(( $(start 1) * 512 ))
}
setenv() {  # <k=v>... -- write a fresh grubenv onto the ESP
  rm -f env.blk; grub-editenv env.blk create; grub-editenv env.blk set "$@"
  mcopy -o -i "disk.img@@$ESPOFF" env.blk ::/EFI/steamos/grubenv
}
getenv() { mcopy -o -i "disk.img@@$ESPOFF" ::/EFI/steamos/grubenv env.out 2>/dev/null; grub-editenv env.out list; }
envv() { getenv | sed -n "s/^$1=//p"; }
putconf() {  # <slot> <stamp> <invalid>
  mmd -i "disk.img@@$ESPOFF" ::/SteamOS ::/SteamOS/conf 2>/dev/null || true
  printf 'title: %s\nboot-requested-at: %s\nboot-attempts: 0\nimage-invalid: %s\n' "$1" "$2" "$3" >conf.tmp
  mcopy -o -i "disk.img@@$ESPOFF" conf.tmp "::/SteamOS/conf/$1.conf"
}
boot() {  # -> PROBE line in $P
  timeout ${BOOT_TIMEOUT:-120} qemu-system-aarch64 -M virt,acpi=off -cpu cortex-a57 -m 512 -bios "$FW" \
    -drive if=none,file=disk.img,format=raw,id=hd0 -device virtio-blk-device,drive=hd0 \
    -nic none -nographic -no-reboot -monitor none -serial stdio </dev/null >boot.log 2>&1
  P="$(tr -d '\r' <boot.log | grep -a 'RF-PROBE' | tail -1)"
  [ -n "$P" ] || { echo "---- no probe; tail of boot.log:"; tr -d '\r' <boot.log | tail -25; }
}
expect() {  # <substring> <what>
  case "$P" in *"$1"*) ok "$2" ;; *) bad "$2 -- got: ${P:-<no probe>}" ;; esac
}

echo "== a fresh image: A only =="
mkdisk 0
setenv "ORDER=A B" A_OK=1 A_TRY=0 B_OK=0 B_TRY=0
boot; expect 'slot=A retry=[] fallback=[]' "boots A, not a retry"
[ -n "${QUICK:-}" ] && { echo "---- boot.log"; tr -d '\r' <boot.log | tail -60; exit 0; }
[ "$(envv A_TRY)" = 1 ] && ok "A_TRY counted to 1" || bad "A_TRY=$(envv A_TRY)"
case "$P" in *'model=[linux,dummy-virt]'*) ok "retroforge_dt_model reads the firmware's tree" ;; *) bad "model: $P" ;; esac
case "$P" in *'root=[hd0,gpt2]'*) ok "hands over on efi-A (hd0,gpt2)" ;; *) bad "root: $P" ;; esac
boot; expect 'slot=A retry=[1]' "second try of A is a retry"
[ "$(envv A_TRY)" = 2 ] && ok "A_TRY=2" || bad "A_TRY=$(envv A_TRY)"
boot; [ "$(envv A_TRY)" = 3 ] && ok "A_TRY=3 after the third try" || bad "A_TRY=$(envv A_TRY)"
boot; expect 'slot=A retry=[] fallback=[1]' "no tries left and B empty: A without counting, as a fall-back"
[ "$(envv A_TRY)" = 3 ] && ok "the last-resort boot is not counted" || bad "A_TRY=$(envv A_TRY)"

echo "== RAUC's mark-good (TRY=0) ends the trial =="
setenv "ORDER=A B" A_OK=1 A_TRY=0 B_OK=0 B_TRY=0
boot; expect 'slot=A retry=[]' "A"

echo "== an update into B: B first, three tries, then back to A =="
mkdisk 1
setenv "ORDER=B A" A_OK=1 A_TRY=0 B_OK=1 B_TRY=0
boot; expect 'slot=B retry=[] fallback=[]' "boots the new slot B"
case "$P" in *'root=[hd0,gpt3]'*) ok "hands over on efi-B (hd0,gpt3)" ;; *) bad "root: $P" ;; esac
boot; boot
[ "$(envv B_TRY)" = 3 ] && ok "B used its three tries" || bad "B_TRY=$(envv B_TRY)"
boot; expect 'slot=A retry=[] fallback=[]' "the fourth boot goes to A, with no menu"
[ "$(envv A_TRY)" = 1 ] && ok "and counts A's try" || bad "A_TRY=$(envv A_TRY)"

echo "== RAUC's mark-bad (OK=0) =="
setenv "ORDER=B A" A_OK=1 A_TRY=0 B_OK=0 B_TRY=0
boot; expect 'slot=A' "a slot that is not OK is skipped"

echo "== a slot with no kernel is never chosen =="
mkdisk 0
setenv "ORDER=B A" A_OK=1 A_TRY=0 B_OK=1 B_TRY=0
boot; expect 'slot=A' "B has no kernel: A"

echo "== an older root's hook re-armed the boot conf =="
mkdisk 1
setenv "saved_entry=mangmi-air-x-mq66"
putconf A 20261001000000 0
putconf B 20261031120000 0
boot; expect 'slot=B retry=[] fallback=[]' "follows the conf to B, the newer"
[ "$(envv ORDER)" = "B A" ] && ok "ORDER=B A copied in" || bad "ORDER=$(envv ORDER)"
[ "$(envv A_OK)" = 1 ] && [ "$(envv B_OK)" = 1 ] && ok "both slots OK" || bad "A_OK=$(envv A_OK) B_OK=$(envv B_OK)"
[ "$(envv rf_bcsync)" = "B:20261031120000" ] && ok "the selection is noted" || bad "rf_bcsync=$(envv rf_bcsync)"
[ "$(envv saved_entry)" = mangmi-air-x-mq66 ] && ok "the saved board survives" || bad "saved_entry=$(envv saved_entry)"
boot; [ "$(envv B_TRY)" = 2 ] && ok "an unchanged conf is not followed again (B_TRY=2)" || bad "B_TRY=$(envv B_TRY)"
putconf A 20261101000000 0
boot; expect 'slot=A retry=[]' "a newer re-arm of A is followed"
[ "$(envv ORDER)" = "A B" ] && ok "ORDER=A B" || bad "ORDER=$(envv ORDER)"
putconf B 20261102000000 1
boot; expect 'slot=A' "a conf marked invalid is not followed"

echo "== a lost grubenv =="
mkdisk 1
mdel -i "disk.img@@$ESPOFF" ::/EFI/steamos/grubenv 2>/dev/null || true
boot; expect 'slot=A' "still boots A"

echo
echo "qemu-esp-test: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
