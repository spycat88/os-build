# Plan: Factory reset (issue #40)

**Source**: https://github.com/retroforge-linux/os-build/issues/40
**Complexity**: Large (initramfs + a root-level wipe + the installer's consent UI)
**Status**: done 2026-11-15. HW: soft + hard on a Pocket S2 card boot, hard on a Pocket ACE card boot (and its next boot); the internal-install leg was skipped by decision

## Summary

Settings > General gets a **Factory reset** row with two levels. **Soft** keeps the four shares
(`roms`, `bios`, `saves`, `states`) and returns everything else to a freshly flashed device; **hard**
leaves only the OS. Neither touches the OS slots (the device keeps the version it runs), a second SD
card or Android's partitions. The request is recorded on the ESP after on-device consent, and the
next boot carries it out from the initramfs, which runs a reset script out of the read-only OS root.

## Decisions

- **D1** Soft keeps exactly `/home/player/{roms,bios,saves,states}`. Everything else in `/home` goes:
  `.config`, `.local/share` (Steam client and installed PC games, store tokens, ROM art, Proton),
  `~/emulators`, `.ssh`, the offload tree `/home/.retroforge`.
- **D2** Soft wipes Wi-Fi like everything else (both `/var` slots reseeded): the first-boot Wi-Fi step
  comes back.
- **D3** Consent reuses the internal installer's gate: a root unit that ends the session, writes
  `/run/nologin`, and runs the installer UI in a "reset" mode (what is kept / wiped, then the pad
  sequence). A paired SSH session cannot wipe a device without someone at it agreeing.
- **D4** No `blkdiscard` on hard reset: `mkfs.ext4` only.

## Settled by the code (no work)

- **Device identity**: the stable Wi-Fi/BT addresses come from GRUB (`retroforge_radiomac`,
  `boot/gen-grub-cfg.sh:401`), not `/var`: the same after any reset.
- **Dev images**: the dev SSH key is seeded into `/root` from the read-only root by
  `retroforge-offload-prepare` at every boot, and the var seed is built from the same tree as the
  image's var images (`rootfs/assemble-rootfs.sh:431-456`), so a reset dev image should stay reachable
  (checked on HW).
- **A factory `/var` is not an empty one**: it is `/usr/lib/retroforge/var-seed.tar.zst` (~13 MiB),
  laid down by `seed_var` (`install/lib-slotwrite.sh`), as the installer does.

## Design

1. **Request**: the reset UI writes `retroforge/factory-reset` on the shared ESP (`level=soft|hard`,
   a nonce, `tries=0`), fsyncs, reboots. The ESP survives the wipe and a rollback.
2. **Initramfs** (`image/initramfs/init`): after mounting the root read-only and BEFORE mounting
   `var`, if the request exists: bind `/dev /proc /sys` and the tmpfs `/run` into `$SYSROOT`, then
   `chroot $SYSROOT /usr/lib/retroforge/factory-reset`. The only new initramfs binary is `chroot`.
3. **`/usr/lib/retroforge/factory-reset`** (in the OS, testable offline):
   - the disk = the one holding the booted `var`; its `retroforge-home`, `var-a`, `var-b` found by
     `PARTNAME=` in each partition's sysfs `uevent` (no udev in the initramfs), the scoping
     `69-retroforge-bootdisk.rules` gives the running system: a second card is never touched;
   - bump `tries`; past 3, log to `/dev/kmsg`, leave the request, boot normally (no reboot loop);
   - `/home` soft: delete everything but `player/{roms,bios,saves,states}` (and `lost+found`);
     hard: `mkfs.ext4` with the installer's flags and label, then `stage_player_home`;
   - `var-a`, `var-b`: `seed_var <dev> A|B <mnt under /run> var-seed.tar.zst`;
   - remove the request LAST and sync. Every step is idempotent: a power cut redoes the reset.
4. Boot continues on the fresh `var`: no machine-id -> systemd first boot (preset-all); OGUI's
   first-boot steps return (`~/.config` gone); `retroforge-grow-home` has nothing to grow.

## Patterns to mirror

| Category | Source | Pattern |
|---|---|---|
| Slot `/var` | `rootfs/overlay/usr/lib/retroforge/install/lib-slotwrite.sh` `seed_var` | reformat + unpack the seed + slot file, chained EXIT trap |
| Player home | `image/lib-homestage.sh` `stage_player_home` | the one layout shared by image and installer |
| Home mkfs | `installer/retroforge-install` | flags and label of the installer's home |
| Root gate | `retroforge-installer.service`, `50-retroforge-installer.rules` | Conflicts with the session, `/run/nologin`, polkit start for local active wheel |
| Consent | `installer/uiflow.py`, `installer/confirm-ui` | pad-sequence consent inside the one UI client |
| Plugin row | `apps/ogui-retroforge-plugin/plugin/retroforge_os.gd` `_on_install_pressed` | OGUI dialog first, then start the unit `--no-block` |
| Initramfs logging | `image/initramfs/init` `log`/`warn` | `<6>`/`<3>` to `/dev/kmsg` |
| Disk tests | `tests/test-post-install.sh` | the real script against sandbox disks |

## Files

| File | Action |
|---|---|
| `rootfs/overlay/usr/lib/retroforge/factory-reset` | CREATE |
| `image/initramfs/init`, `image/mkinitramfs.sh` | UPDATE (request check, mounts, chroot; `chroot` in BINS) |
| `rootfs/overlay/usr/lib/systemd/system/retroforge-reset.service` | CREATE (the installer unit's gate, reset mode) |
| `rootfs/overlay/usr/share/polkit-1/rules.d/50-retroforge-reset.rules` | CREATE |
| `installer/uiflow.py`, `installer/ui`, `installer/installer-session` | UPDATE (reset mode: level, kept/wiped, consent, request, reboot) |
| `apps/ogui-retroforge-plugin/plugin/retroforge_os.gd` | UPDATE (Settings > General row, Soft/Hard, confirm, start) |
| `image/partition-table.txt`, `docs/install-internal.md` | UPDATE ("a factory reset is a reflash" no more) |
| `tests/test-factory-reset.sh` | CREATE |
| `tests/test-ui.sh`, `tests/test-plugin.sh`, initramfs test | UPDATE |

## Phases

1. `factory-reset` + `tests/test-factory-reset.sh` on loop-device disks with a decoy second card:
   soft keeps exactly the kept set; hard leaves a staged empty home; both var slots seed-equal with
   the right slot file; the decoy untouched; an interrupted reset resumes; the try cap holds.
2. Initramfs hook (request check, mounts, chroot) + its test.
3. Gate and UI: `retroforge-reset.service`, polkit rule, installer UI reset mode (`test-ui.sh`),
   plugin row (`test-plugin.sh`).
4. Docs; HW: soft and hard, card boot and internal install with a second ROM card inserted; a dev
   image stays reachable; MAC unchanged.

## Risks

| Risk | Likelihood | Mitigation |
|---|---|---|
| A reset that fails every boot loops the device | Low | try counter in the request; past 3, boot normally, log why |
| The wipe reaches a second card or Android | Low | partitions only on the disk holding the booted var; decoy-disk test |
| `seed_var` in a chroot on a read-only root needs writable scratch | Medium | mount points under the tmpfs `/run`; Phase 1-2 tests |
| A long hard reset looks like a hang | Low | a status on the initramfs splash |
| A rollback to an OS without `factory-reset` meets a request | Low | the old initramfs ignores it; the next new one carries it out |

## Acceptance

- [x] Soft and hard from Settings, consent on the device, reset at the next boot
- [x] Offline tests above pass; existing suites green
- [x] HW: card boots (S2, ACE), dev image reachable, MAC unchanged; internal install + other storage untouched: skipped
