# boot/

The UEFI boot chain is one step:

```
ABL (OpenABL)  →  kernel + initramfs + DTB of one Boot Loader Specification entry,
                  \loader\entries\retroforge-<slot>+N.conf on that slot's boot partition,
                  picked by the ESP's loader.conf default and the entry's boot counter
```

There is no second-stage loader. OpenABL reads Boot Loader Specification Type #1 entries
(`\loader\entries\*.conf`) and starts the kernel an entry names, with that entry's `initrd`,
`devicetree` and `options`. Each slot has its own FAT partition for what boots it, and an entry's
paths resolve on the partition the entry sits on:

```
boot-a  \loader\entries\retroforge-a+3.conf      slot A's entry, three tries left
        \loader\entries\retroforge-debug-a.conf  slot A booted verbosely, uncounted
        \vmlinuz-<kernel version>            slot A's kernel, initramfs and DTBs, copied out of root A
        \initramfs-<kernel version>.img
        \dtbs\<board>.dtb
boot-b  the same for B
ESP     \loader\loader.conf                    default retroforge-<primary>.conf
```

A slot entry looks like this:

```
title RetroForge (Slot A)
version <build version>
sort-key retroforge
linux /vmlinuz-<kernel version>
initrd /initramfs-<kernel version>.img
options <kernel command line>
```

An entry names no `devicetree`. OpenABL installs the DTB of its **Device model** setting, read from
the `\dtbs` of the partition the entry it boots sits on (`HandoverPrepare` with the entry's own
filesystem, `Efi/Models.c`), so slot A boots with boot-a's DTBs and slot B with boot-b's. Set the
Device model in OpenABL's menu once per device.

The debug entry is the same with the title `RetroForge (Slot A, debug)`, no `sort-key`, no counter,
and a verbose command line: no `quiet` or splash, `loglevel=7`, and systemd's unit status on the
console. With no sort-key it lists after both slot entries, so it is picked by hand from OpenABL's
menu, and is booted unattended only when neither slot has a try left.

OpenABL ranks the entries of every FAT filesystem on the boot drive as one list, as the
specification does for an ESP plus an XBOOTLDR partition, and reads `loader.conf` from whichever of
them has one (spycat88/openabl, branch `bls-boot-entries`). Without that, the ranking and the
default would be per partition, and a slot out of tries would still be booted first whenever the
firmware listed its partition first.

The booted system mounts the ESP at `/esp` and the two boot partitions at
`/run/retroforge/bootfs/a` and `/run/retroforge/bootfs/b`, all from `/etc/fstab` (the boot partitions
by automount).

| File | Purpose |
|---|---|
| `gen-bls.sh <out>` | Generate `boards.tsv` (id⇥name⇥dtb⇥model⇥bootargs, one row per bootable board) and `cmdline` (the args every entry carries). No toolchain — `tests/test-bls.sh` runs it directly. Both are installed in the root under `/usr/lib/retroforge/boot/`. |
| `boards.map` | Build-time board catalog: `id⇥name⇥dtb⇥bootargs`. Cross-checked against the runtime device profiles by `tests/test-bls.sh`. |
| `splash-dtbs.sh <out> <dtb>...` | The DTBs with a splash region added where a tree has none: each boot partition's `dtbs\` (see below). |

The entries themselves are written on the device, or into the card image, by one set of functions
in `rootfs/overlay/usr/lib/retroforge/install/lib-bls.sh`, because what goes in them is per disk
(the PARTUUIDs of the slot's partitions) and per device (the board).

## The slot state: three tries, then the other slot

The A/B state is in the entry file names, as in systemd's Automatic Boot Assessment, which OpenABL
implements. Before it boots a counted entry, OpenABL renames it: `retroforge-a+3.conf` becomes
`retroforge-a+2-1.conf`, then `+1-2`, then `+0-3`. An entry with no tries left is "bad": OpenABL
sorts it last and the `loader.conf` default no longer matches it, so the other slot boots.

Every boot is counted. `retroforge-boot-good.service` confirms a healthy boot with
`retroforge-bootctl mark-good`, which runs `rauc status mark-good booted` and so puts the booted
slot's counter back to `+3`. Three boots in a row that never get that far and the other slot takes
over. `systemd-bless-boot.service`, which would strip the counter and end the counting, is masked.

RAUC drives this through `bootloader=custom`, with `retroforge-bootctl` as the backend:

| RAUC asks | retroforge-bootctl does |
|---|---|
| `get-primary` | the `loader.conf` default if that slot is good, else the other slot if it is |
| `set-primary X` | X's counter back to `+3`, then `default retroforge-x.conf` |
| `get-state X` | `good` while X's entry has tries left, `bad` when it has none or there is no entry |
| `set-state X good` | X's counter back to `+3` |
| `set-state X bad` | X's counter to `+0`: OpenABL boots the other slot |
| `get-current` | the booted slot, from `retroforge.slot=` on the kernel command line |

## An update

RAUC writes the inactive slot's root, then runs `/usr/lib/rauc/post-install.sh`, which:

1. removes the target slot's entries from its boot partition, so nothing boots a half-written slot;
2. seeds the target's `/var`;
3. builds the new entries from the NEW root's `boards.tsv`, `cmdline` and `release` (build and
   kernel version), for the board the running devicetree names, and replaces the target's boot
   partition's kernel, initramfs and DTBs with the new root's;
4. writes the debug entry and `retroforge-<slot>+3.conf` there, and makes the slot the
   `loader.conf` default on the ESP.

The new slot then gets its three tries. If none reaches `mark-good`, OpenABL falls back to the old
slot, whose entry was never touched.

A root from before this boot chain has no `boards.tsv` or `release` to write an entry from, so the
hook refuses it, and the GRUB-era hook refuses a BLS root (it has no `grub-esp.efi`). Moving between
the two is a reflash.

## A fresh card, and the board

One image serves every board. So a card leaves the build with one entry per populated slot,
`retroforge-a+3.conf` (and `retroforge-b+3.conf` only when built with `RETROFORGE_SLOT_B=1`), each with its debug entry, on that
slot's own boot partition, and a `loader.conf` on the ESP saying `default retroforge-a.conf`. The
entries carry only the command line every board shares; the DTB is OpenABL's Device model setting.
The first healthy boot's `mark-good` then rewrites the booted slot's entry and debug entry with the
board's own arguments added (looked up by the running devicetree's `model` in `boards.tsv`), in
place, so the counter is RAUC's to reset. On a board the root does not know it warns and confirms
the boot anyway.

The internal installer and the update hook run on a device that has already booted, so they read
the board off the running devicetree and write the board's entries straight away.

The boot partitions' `\dtbs` are also what OpenABL lists its Device models from (the name, the
panel rotation). They are the real DTBs plus a `/reserved-memory/splash_region` where a tree has
none, because OpenABL 1.2 powers the display down at the hand-over when the tree it installed has no
splash region.

## The kernel command line

The EFI stub **overwrites** `/chosen/bootargs` with the loader's command line, so every argument
has to be on the entry's `options` line or it is silently dropped — which is why the board args are
not in the DTS `/chosen/bootargs`. They come together in `bls_cmdline`:

| Part | Source |
|---|---|
| common args | `BOOT_CMDLINE` + `SESSION_CMDLINE` in `gen-bls.sh`, shipped as `cmdline` |
| board args | the fourth column of `boards.map` |
| `root=` `retroforge.var=` | per slot, as `PARTUUID=`, read off the disk the entry is written for |
| `retroforge.slot=` `rauc.slot=` | per slot, stated outright — a PARTUUID carries no slot letter, and RAUC finds the booted slot from `rauc.slot=` |

The specs are `PARTUUID=` because every retroforge medium carries the same eight GPT names: with a
card inserted on a device installed to internal storage, `PARTLABEL=` resolves to whichever disk
enumerates first.

## Building

```sh
make bootdata
```

`boards.tsv`, `cmdline` and `release` reach the root through `rootfs/lib-assemble-boot.sh`, and a card through
`image/make-sdcard.sh`. An updated slot takes them from inside the root it just installed, so a
root and the entry that boots it always come from one build.
