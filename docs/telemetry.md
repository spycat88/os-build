# Device telemetry

Every boot, `retroforge-telemetry.service` sends one small anonymous report to
`https://telemetry.retroforge.org/v1/report`, so the project knows which devices, SoCs and releases
are in use and how fast an update rolls out. It is on by default and can be switched off at any time.

| Piece | Where |
|---|---|
| Client | `rootfs/overlay/usr/bin/retroforge-telemetry` (Python 3, stdlib only) |
| Boot unit | `rootfs/overlay/usr/lib/systemd/system/retroforge-telemetry.service` + preset + `multi-user.target.wants` link |
| Image setting | `rootfs/overlay/etc/retroforge/telemetry.conf` |
| Server, schema, deploy notes | `telemetry-server/` (not part of the image) |
| Test | `tests/test-telemetry.sh` (client against the real server on localhost, fake sysfs) |

## When it runs

At boot, after `network-online.target`. Attempt 1 straight away; on failure it waits 5 minutes and
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

## Opting out

Any one of these stops the report; the unit then exits 0 without touching the network.

| How | Scope |
|---|---|
| `retroforge-telemetry disable` (writes `TELEMETRY=off` to `/home/player/.config/retroforge/telemetry.conf`) | the user; on `/home`, so it survives every OTA and slot switch. `enable` undoes it |
| `TELEMETRY=off` in `/etc/retroforge/telemetry.conf` | the image: ship a build that never reports |
| `retroforge.telemetry=0` on the kernel command line | one boot / a bootloader entry |
| `RETROFORGE_TELEMETRY=off` in the environment | testing |

Order of precedence: environment, cmdline, user file, image file, then the default (on). So a user
can opt in on an image shipped with it off, and the cmdline overrides both. The switch is re-read
before each attempt, so turning it off during the 5-minute wait is obeyed.

`retroforge-telemetry status` shows whether it is on, why, the device ID and the last result. A
toggle in the shell's settings can call `retroforge-telemetry enable|disable` (it runs as `player`, no
root needed).
