# Device telemetry

Every boot, `retroforge-telemetry.service` sends one small anonymous report to
`https://telemetry.retroforge.org/report.php`, so the project knows which devices, SoCs and releases
are in use and how fast an update rolls out. **Only if the user said yes**: first-boot setup asks,
after the Wi-Fi step, with a toggle that starts on. Without a recorded yes the service never runs.

| Piece | Where |
|---|---|
| Client | `rootfs/overlay/usr/bin/retroforge-telemetry` (Python 3, stdlib only) |
| Boot unit | `rootfs/overlay/usr/lib/systemd/system/retroforge-telemetry.service` + preset + `multi-user.target.wants` link |
| Consent trigger | `retroforge-telemetry.path`: starts the service when the answer is written, so a yes reports in the same boot |
| Consent screen | OpenGamepadUI patch `packages/opengamepadui/patches/0060-first-boot-asks-for-telemetry-consent.patch` |
| Image setting | `rootfs/overlay/etc/retroforge/telemetry.conf` |
| Server, schema, deploy notes | `telemetry-server/` (PHP + SQLite, with a stats page; not part of the image) |
| Test | `tests/test-telemetry.sh` (client against the real server on localhost, fake sysfs) |

## When it runs

At boot, after `network-online.target`, and when the consent file is written. Either way it first checks for a yes. Attempt 1 straight away; on failure it waits 5 minutes and
tries again, three attempts in all. It exits on the first success, or after the third failure until
the next boot. The unit is `Type=exec` so it never delays boot, and `Restart=no` so systemd never
adds a fourth try. The last result is kept in `/var/lib/retroforge/telemetry.json`.

## What is sent

`retroforge-telemetry show` prints the exact JSON, and sends nothing. Example:

```json
{
  "schema": 1,
  "device_id": "e807f1fcf82d132f9bb0",
  "os_name": "RetroForge",
  "os_version_id": "1.2.0",
  "os_version": "1.2.0 (abc123)",
  "os_build_id": "20261126T000000Z",
  "os_variant": "unified",
  "os_git": "abc123",
  "build_mode": "release",
  "soc": "SM8550",
  "device_model": "AYN Odin 2",
  "device_profile": "ayn-odin-2",
  "kernel": "6.18.0",
  "arch": "aarch64",
  "cpu_count": 8,
  "ram_mb": 15625,
  "storage_gb": 256,
  "install_target": "ufs",
  "ota_channel": "stable",
  "boot_slot": "B",
  "uptime_s": 42
}
```

- **device_id** is `md5sum /sys/devices/soc0/serial_number | cut -c1-20`: the md5 of the serial file's
  bytes (trailing newline included, as `md5sum` reads it), keeping the first 20 hex digits. It stays the
  same across reflashes, card swaps and factory resets, and the serial itself never leaves the device. A
  board that reports no serial sends nothing.
- **soc** is qcom socinfo's `machine`, falling back to the device profile's SoC class.
- **install_target** is the bus of the disk the root was booted from (`ufs`, `sd`, `emmc`, `usb`,
  `nvme`), read from the initramfs handoff `/run/retroforge/boot`; **storage_gb** is that disk's size.
- **country** is not sent. The server derives it from the request IP with a GeoIP database and does
  not store the IP.

Nothing else is collected: no IP address, MAC, hostname, Wi-Fi name, user files, game list or usage.

## Consent

Nothing is sent unless `/home/player/.config/retroforge/telemetry.conf` says `TELEMETRY=on`.

- **First boot** shows a "Help improve RetroForge" step after the Wi-Fi step (also when Wi-Fi was
  skipped or the device was already online). It says what is sent and has one toggle,
  "Send anonymous device statistics", on to start with. Next writes `TELEMETRY=on` or `TELEMETRY=off`.
- **No file is a no.** Before setup is finished, and on a device that was set up before this screen
  existed, the service is skipped.
- The unit's `ExecCondition=retroforge-telemetry consented` checks this before anything runs, so
  with a no systemd skips the unit outright (it shows as "condition failed", not as a failure).
- `retroforge-telemetry enable` / `disable` rewrite the same file (as `player`, no root needed). A
  Settings toggle can call them.
- The file is on `/home`, which both A/B slots share, so the answer survives every OTA. A factory
  reset clears `/home`, so setup asks again.

These turn it off even over a yes, and nothing can turn it on over a no:

| How | Scope |
|---|---|
| `TELEMETRY=off` in `/etc/retroforge/telemetry.conf` | the image: ship a build that never reports |
| `retroforge.telemetry=0` on the kernel command line | one boot / a bootloader entry |
| `RETROFORGE_TELEMETRY=off` in the environment | testing |

The answer is re-read before each attempt, so withdrawing it during the 5-minute wait is obeyed.
`retroforge-telemetry status` shows whether it is on, why, the device ID and the last result.
