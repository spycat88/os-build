# boot/

The UEFI boot chain:

```
ABL (OpenABL)  →  the ESP GRUB (\EFI\BOOT\bootaa64.efi)  →  stage-2 grub.cfg (the slot's efi-A/B)  →  kernel in the slot root
                  picks the SLOT from RAUC's state in        picks the BOARD (OpenABL's Device
                  \EFI\steamos\grubenv, counts its tries     model, else the saved choice, else
                                                             a menu), loads vmlinuz.efi + initramfs +
                                                             that board's DTB from the slot root
```

Two choices, made in two places. Which **slot** boots is RAUC's state (`bootloader=grub`:
`ORDER`, `A_OK`/`A_TRY`, `B_OK`/`B_TRY` in the ESP's grubenv), read by the ESP GRUB, which gives a
slot three tries before it boots the other one. Which **board** this is — one image serves all of
them — comes from OpenABL's Device model when it is set, and otherwise from the stage-2 menu,
asked once and saved.

| File | Purpose |
|---|---|
| `grub.pin` | Pinned source: the **GNU GRUB 2.14 release tarball** from ftp.gnu.org. |
| `patches/grub/` | Our delta on it: framebuffer rotation, the `retroforge` module, and the `Makefile.core.def` stanza that builds it. Applied lexically, like `kernel/patches/`. |
| `grub.sh` | Cross-build → `out/boot/{grub-esp.efi, grubaa64.efi, grub-a.cfg, grub-b.cfg, fonts/, grubenv, grub-editenv, steamcl-version}`. |
| `gen-esp-cfg.sh <out>` | Generate the slot picker embedded in `grub-esp.efi`. No toolchain. |
| `gen-grub-cfg.sh <A\|B> <out>` | Generate one slot's stage-2 `grub.cfg`. No toolchain — `tests/test-stage2-grub.sh` runs both generators directly. |
| `boards.map` | Build-time board catalog: `id⇥name⇥dtb⇥bootargs`. Cross-checked against the runtime device profiles by that test. |
| `esp-dtbs.sh <out> <dtb>...` | The DTBs the ESP carries in `\dtbs\qcom` for OpenABL's Device model list (see below). |

## The ESP GRUB

`grub-esp.efi` is GRUB with `gen-esp-cfg.sh`'s config in a memdisk; its embedded config is the one
plain command `normal (memdisk)/esp.cfg` (an embedded config runs under the rescue parser, which has
no `if`). The config reads the grubenv, picks the first slot in `ORDER` that is OK, has tries left
(`TRY` 0, 1 or 2) and has both a stage-2 config and a kernel, counts the try, sets `$root`/`$prefix`
to that slot's efi partition and sources the stage-2 `grub.cfg` there, as if it had been loaded off
that partition.
It tells the stage-2 config, through `rf_retry`/`rf_fallback`, whether this boot is another try or
a fall-back, which is when the stage-2 menu is shown.

RAUC reads any `TRY` above 0 as "not good", and its `set-primary`, `mark-good` and `mark-bad`
write `TRY=0`, so the three-try count means nothing to it. `retroforge-boot-good.service` confirms a
healthy boot with `rauc status mark-good booted`; a failed health check demotes with `mark-bad`.

Where the slots are comes from `\EFI\steamos\parts.env` on the ESP, else from the first partition
on the boot disk that carries one, else the card layout's indices.

**Roots from before the ESP GRUB.** The first update into a root that has it is installed by the
older root's hook, which copies `/usr/lib/retroforge/boot/steamcl.efi` onto the ESP — so that name
is a link to `grub-esp.efi`, and the hook installs the ESP GRUB without knowing it. Such roots arm
a slot by writing `\SteamOS\conf\<slot>.conf`; the ESP GRUB follows a change there once
(`rf_bcsync`), and boots an older root through its own stage-2 config. Roots with the ESP GRUB never
write those files, so once no older root is left this never fires. The post-install hook refuses
to install a root without `grub-esp.efi`: going back past the switch is a reflash.

## The board, and OpenABL's Device model

OpenABL installs the DTB of its Device model setting, read from the boot drive, before it starts
an EFI program. `retroforge_dt_model` reads that tree's root `model`, and the stage-2 config maps it
to the entry for that board (every board .dts's root model). A model we know wins over the saved
choice and replaces it, so once a Device model is set the board is changed in OpenABL's menu. Only
the name is used: the entry boots the slot's own DTB.

The ESP's `\dtbs\qcom` copies are what OpenABL lists and installs. They are the real DTBs plus a
`/reserved-memory/splash_region` where a tree has none, because OpenABL 1.2 powers the display down
at the hand-over when the tree it installed has no splash region.

With no Device model, the first boot stops at the stage-2 board menu and waits; the choice is
saved in the grubenv (`saved_entry`) and the menu is hidden from then on. It comes back for 3s on a
retry of a board that has never had a boot confirmed (`mark-good` records `rf_board_ok`), and when no
slot has tries left — not on every retry, because a device shut down before its confirmation is not
a wrong board.

## The kernel command line

There is no `boot/cmdline` any more. The EFI stub **overwrites** `/chosen/bootargs` with the
loader's command line, so every argument has to be on the `linux` line or it is silently dropped —
which is why the board args moved out of the DTS `/chosen/bootargs` too. They come together in
`gen-grub-cfg.sh`:

| Part | Source |
|---|---|
| common args | `BOOT_CMDLINE` in `gen-grub-cfg.sh` |
| board args | the fourth column of `boards.map` |
| `root=` `retroforge.var=` `retroforge.efi=` | per slot, as `PARTUUID=` read out of the GPT at boot with `probe --part-uuid`; `PARTLABEL=` from `image/partition-table.txt` is the announced fallback |
| `retroforge.slot=` `rauc.slot=` | per slot, stated outright — a PARTUUID carries no slot letter, and RAUC finds the booted slot from `rauc.slot=` |

The specs are `PARTUUID=` because every retroforge medium carries the same eight GPT names: with a
card inserted on a device installed to internal storage, `PARTLABEL=` resolves to whichever disk
enumerates first. The UUIDs are derived from the disk at boot, so they name that disk by
construction and no update has to rewrite them. This needs `probe` in the embedded `MODULES` — an
unembedded module is an "unknown command" that leaves the variable unset and takes the fallback on
every boot, so `tests/test-stage2-grub.sh` asserts the module list.

## The retroforge module

`grub-esp.efi` and `grubaa64.efi` embed one module of ours:

```
retroforge_dt_model VAR                 # VAR := the root model of the devicetree the firmware installed
retroforge_conf_get FILE KEY VAR        # VAR := the value of `KEY:` in FILE (an older root's boot conf)
retroforge_bootattempts <image-name>    # only older roots' stage-2 configs still call this
```

The first two only read, through GRUB's own drivers, and leave `VAR` unset when there is nothing to
report. The third writes `\SteamOS\conf\<image>.conf` through the firmware's `EFI_FILE_PROTOCOL`
(GRUB's `fat` driver is read-only); it stays for as long as older roots' stage-2 configs exist.

## Building

```sh
make grub
```

The binaries reach an image through `image/make-sdcard.sh`, and reach an updated slot through the
RAUC post-install hook, which takes them from `/usr/lib/retroforge/boot/` inside the root it just
installed — so a root and the software that boots it always come from one build.
