# The hardware map: `/run/retroforge/hw`

Every board names its battery, charger, backlight, thermal zones, fan and LEDs differently, because
the kernel names them after the devicetree. The MANGMI Air X keeps its battery at
`/sys/class/power_supply/battery` next to a `bq256xx-battery` node that is the charger's companion
and knows only `charge_full_design`; its CPU temperature is spread over per-core and per-cluster
zones; its stick rings are eighteen `rgb:l1..l9` / `rgb:r1..r9` multicolour LEDs. Anything that
wants to show or drive that hardware would otherwise carry a list of per-board sysfs names.

`/usr/lib/retroforge/hw-map` resolves all of it, once per boot (and again when such a device appears
late), into one tree of links into sysfs:

| path | points at | read |
|---|---|---|
| `battery` | `/sys/class/power_supply/<battery>` | `capacity`, `status`, `voltage_now`, `current_now`, `temp`, `health`, `cycle_count`, `charge_full[_design]` |
| `charger` | `/sys/class/power_supply/<charger>` | `online`, `status` |
| `backlight` | `/sys/class/backlight/<panel>` | `brightness`, `max_brightness` |
| `thermal/cpu`, `thermal/gpu`, `thermal/battery`, `thermal/skin` | a thermal zone | `temp` (millidegrees); a role is absent when no zone fits |
| `thermal/all/<type>` | every zone, by its type name | `temp` |
| `fan` | the hwmon with a fan | `pwm1` (0-255), `fan1_input` (rpm, only with a tachometer) |
| `gpu` | the GPU's devfreq directory | `cur_freq`, `min_freq`, `max_freq` |
| `cpu` | `/sys/devices/system/cpu` | `cpufreq/policy*/scaling_cur_freq`, ... |
| `soc` | `/sys/devices/soc0` (Qualcomm socinfo) | `machine` (`SM8550`), `family`, `soc_id`, `revision`, `serial_number` |
| `leds/<group>/01..` | `/sys/class/leds/<led>` | `brightness`, `max_brightness`, `multi_intensity` |
| `hw.env` | a sourceable `KEY=value` summary of what was resolved | `RETROFORGE_HW_*`, `RETROFORGE_DEVICE_*` |

A consumer tests for a link and reads through it; a missing link means the board has no such thing.
The links point into sysfs, so values are live and nothing copies them.

## Per-board input

The board profile (`/usr/lib/retroforge/devices/<id>.conf`, through `device-env`) may pin any node with
`RETROFORGE_HW_BATTERY`, `RETROFORGE_HW_CHARGER`, `RETROFORGE_HW_BACKLIGHT`, `RETROFORGE_HW_THERMAL_{CPU,GPU,BATTERY,SKIN}`
(thermal zone *type* names), `RETROFORGE_HW_FAN` (hwmon name), `RETROFORGE_HW_GPU_DEVFREQ` and
`RETROFORGE_HW_LED_GROUPS` (`"group=glob[,glob] ..."` over `/sys/class/leds`). Everything left empty is
detected: the first battery that reports a `capacity`, the first non-battery supply with `online`
(preferring one that also reports a `status`, i.e. the charger IC over a bare Type-C source), the
first backlight, zone types matching `^(cpu|soc)`, `^gpu`, `^batt`, `skin|xo-therm|quiet|case`, the
first hwmon with `fan1_input` or `pwm1`, the `*gpu*` devfreq, and `power=power-led` when that LED
exists. `defaults.conf` documents the fields.

Every known board pins every node it has; detection is what an unknown board gets. A pinned name
the running board does not have is logged (`retroforge hw-map: RETROFORGE_HW_X=... is not on this board --
detecting instead`) and detected, so a stale pin costs a journal line rather than the link. An LED
group that matches nothing is left out and logged the same way.

## The boards

Read off RetroForge's own DTS (`kernel/dts/qcom/`) and the drivers' naming rules, and cross-checked
with what ROCKNIX `next` reads on the same boards (`packages/hardware/quirks/`). **Only the MANGMI
Air X and Air Y have been seen running RetroForge** (detection resolved the same nodes there). Every
other board's pins are checked against its compiled devicetree (below), and on a device the
journal line above is how a wrong name will show.

| SoC | battery / charger | CPU / GPU zone | skin zone | fan | GPU devfreq |
|---|---|---|---|---|---|
| SM8550 | `qcom-battmgr-bat` / `qcom-battmgr-usb` | `cpu7-top-thermal` / `gpuss-0-thermal` | — | `pwmfan`, tach | `3d00000.gpu` |
| SM8650 | `qcom-battmgr-bat` / `qcom-battmgr-usb` | `cpu7-top-thermal` / `gpuss0-thermal` | — | `pwmfan`, tach | `3d00000.gpu` |
| SM8250 | `battery` / `pm8150b-charger` | `cpu7-top-thermal` / `gpu-top-thermal` | `skin-msm-thermal` | `pwmfan`, no tach | `3d00000.gpu` |
| SM6115 | `battery` / `bq256xx-charger` | `cpu67-thermal` / `gpu-thermal` (+ `battery-thermal`) | — | `pwmfan`, no tach | `5900000.gpu` |
| SM4450 | `qcom-battmgr-bat` / `qcom-battmgr-usb` | `cpu6-0-thermal` / `gpu-thermal` | — | `pwmfan`, tach | `3d00000.gpu` |
| SM7750 | `qcom-battmgr-bat` / `qcom-battmgr-usb` | `cpu7-top-thermal` / `gpuss0-thermal` | — | `pwmfan`, tach | `3d00000.gpu` |

- **Battery, charger.** SM8550/SM8650 report through pmic_glink's battmgr; its USB supply has
  `online` but no `status`. (ROCKNIX's scripts read `power_supply/battery` there only because a
  ROCKNIX kernel patch renames the battmgr battery; RetroForge does not carry it.) SM8250 uses
  RetroForge's pm8150b fuel gauge (`battery`) and smb5 charger, which names itself `<pmic>-charger`
  at probe — not the `pmi8998_charger` in its template descriptor. SM6115 (the Air X and Air Y)
  has a cw221x gauge, `battery`, beside the bq256xx charger's companion `bq256xx-battery`, which
  reports no capacity; the gauge also registers the only battery thermistor zone in the fleet.
- **Zones.** CPU is the prime core's sensor (Cortex-X3 / X4 / A77 on cpu7), the one a game's main
  thread heats; the SM8550/SM8650 fan trips hang on the same zone. Top over middle/bottom is a
  choice, not a measurement. SM8650 names its GPU zones `gpuss0..7`, without SM8550's hyphen. No
  board has a battery thermistor zone (the battery's own `temp` is in `battery/`); the SM8250
  boards' `skin-msm-thermal` is a PM8150L ADC thermistor. hw-map's unpinned pattern would take
  `cpu0-thermal` (a little core) on SM8250. SM6115 has a zone per core and per cluster; the A73
  pair's `cpu67-thermal` runs hottest (measured on the Air X). SM4450's zones live in the board DTS,
  not sm4450.dtsi; `cpu6-0` is one of the two A78s, picked, not measured.
- **Fan.** A pwm-fan everywhere, hwmon `pwmfan`. The SM8250 and SM6115 nodes have no tachometer
  (`interrupts`), so `pwm1` without `fan1_input`; on SM6115 the PWM itself is a GPIO.

| board | backlight | LED groups |
|---|---|---|
| AYN Odin 2 | `backlight` (pwm) | `power`, `ring-left`/`ring-right` = `left-joystick,left-side` / `right-…` |
| AYN Odin 2 Mini | `odin2miniled-backlight` | `power` |
| AYN Odin 2 Portal | `ae96000.dsi.0` | `ring-left`/`ring-right` = `rgb:l*` / `rgb:r*` |
| AYN Thor | `ae96000.dsi.0` (top) | `ring-left`/`ring-right` = `rgb:l*` / `rgb:r*` |
| Retroid Pocket 6, Nova | `ae94000.dsi.0` | `ring-left`/`ring-right` = `rgb:l*` / `rgb:r*` |
| AYANEO Pocket ACE, S 1K, S 2K | `sy7758-backlight` | `power` |
| AYANEO Pocket DMG, EVO | `ae94000.dsi.0` | `power` |
| AYANEO Pocket DS | `ae94000.dsi.0` (top) | `power` |
| AYANEO Pocket S2, KONKR Pocket FIT (SM8650) | `sy7758-backlight` | `power` |
| AYN Thor Lite | `ae94000.dsi.0` (primary) | `ring-left`/`ring-right` = `rgb:l*` / `rgb:r*` |
| Retroid Pocket 5, Flip2, Mini, Mini V2 | `ae94000.dsi.0` | `ring-left`/`ring-right` = `rgb:l*` / `rgb:r*` |
| MANGMI Pocket Max | `ae94000.dsi.0` | `ring-left`/`ring-right` = `*:indicator-0..7` / `8..15` |
| MANGMI Air Y Pro (SM8250) | `backlight` (PM8150L WLED) | as the Pocket Max |
| MANGMI Air X MQ65, MQ66, MQ66B (SM6115) | `backlight` (pwm) | `ring-left`/`ring-right` = `rgb:l*` / `rgb:r*` (9 pixels each) |
| MANGMI Air Y (SM6115) | `backlight` (pwm) | `ring` = `rgb:l*` (10 pixels) |
| Retroid Pocket Classic, Rev Q, Classic 6 Rev Q (SM4450) | `ae94000.dsi.0` | — |
| Anbernic RG 55G1 (SM4450) | `backlight` (pwm, inverted) | `power` = `*:indicator` (red/green/amber on/off gpio-leds); `ring-left`/`ring-right` = `rgb:l*` / `rgb:r*` (8 segments each) |
| Retroid Pocket Duo (SM7750) | `ae94000.dsi.0` (top) | — (red/green charging and blue status LEDs, no power LED) |

`power` is the PM8550 LPG's multicolor `power-led`. A panel that drives its own brightness over
DCS registers its backlight under its DSI device, `<host>.dsi.0`, so the name follows the DSI
*host*, not the connector number: the Odin 2 Portal's only panel is on dsi1 (`ae96000`) although
its connector is DSI-1.

Where detection alone goes wrong, or is right only by sort order:

- **A charge pump.** The Air Y Pro enables an HL7139 whose `hl7139-charger` sorts before
  `pm8150b-charger` and reports `online` and `status`, but `online` means "pump engaged" and reads
  0 with a cable in.
- **Two backlights.** The Thor's bottom screen (`ae94000.dsi.0`) sorts before its top, primary
  one; the Thor Lite's secondary is `ae96000.dsi.0`; the RP6 and Nova also register an unused
  pwm `backlight` node copied from the Odin 2.
- **Stick rings.** The AYN/Retroid rings are `leds-group-multicolor` devices over HTR3212 channels
  whose `multi_index` reads `blue green red` — write by name, never by position. The Pocket Max's
  and Air Y Pro's are 48 single-colour aw20036 channels (`{red,green,blue}:indicator-N`) with no
  multicolor device over them; powerd gives each channel its own component of the colour. On the Portal, Thor, RP6 and Nova the shared dtsi's
  `power-led` also registers, but ROCKNIX drives only the rings there, so it is not grouped.

Known gaps, from the source:

- **Odin 2:** both SN3112 PWM chips under the stick lights are `status = "disabled"` in the DTS,
  so its two ring groups resolve empty (and are logged) until they are enabled.
- **AYANEO DMG, EVO, S2 (and the KONKR, which ROCKNIX treats as an S2):** the stick RGB rings
  belong to the serial MCU; RetroForge's `ayaneo-serial-mcu` driver exposes no LED device for them.
- **AYANEO Pocket DS:** the bottom screen's SY7758 node has no `enable-gpios`, which RetroForge's
  SY7758 driver requires, so `sy7758-backlight` should fail to probe there; the bottom panel then
  never attaches to dsi1, which may hold up the whole display. Unconfirmed on a device.

## Consumers

- The OpenGamepadUI plugin's **Quick bar > Hardware** card (`apps/ogui-retroforge-plugin/plugin/hardware_card.gd`
  over `hardware_info.gd`) shows battery, charger, temperatures, fan, clocks, backlight and LED
  groups from this tree, hiding whatever the board lacks. No board-specific code.
- **retroforge-powerd** drives the `fan` link's hwmon (a two-speed gpio-fan is switched on/off at
  the curve's first step) and every LED in `leds/<group>/` (colour on multicolor LEDs; a
  `red:`/`green:`/`blue:` channel LED at its component of the colour; of on/off coloured LEDs
  (`max_brightness` 1, e.g. the RG 55G1's red/green/amber lamps) only the one nearest the colour,
  lit whenever the brightness is above 0; brightness on all; off for
  suspend). It falls back to scanning sysfs only when the map is absent or names
  no LEDs. Its D-Bus interface (`org.retroforge.Power1`) is how a UI changes them: `FanCurve`,
  `LedCount`, `LedEnabled`, `LedColor` (R, G, B), `LedBrightness` (0-255), kept in
  `/etc/retroforge/power.conf.d/50-{fan-curves,leds}.conf`. `retroforge-powerd.service` starts after
  `retroforge-hw.service`.
- The plugin's Hardware card also carries the LED controls (Lights, Brightness, colour), through
  powerd's D-Bus interface only (`power_client.gd`), hidden when `LedCount` is 0.
- Scripts: `. /run/retroforge/hw/hw.env` or read through the links. `soc/serial_number` is the
  per-unit serial ROCKNIX reads on these SoCs.

## Layering

Board differences live in data: the profile names nodes, hw-map resolves them, the daemons
(PowerStation, InputPlumber, UPower, and retroforge-powerd for fan and LEDs) drive them, and the UI
talks to the daemons over D-Bus. A new board is a profile (and DTS), not code.

## Checking the pins without a board

Every name a profile pins is the devicetree plus a fixed rule in the driver that registers it, so
`tools/check-hw-paths.py` reads each board's DTB, works out what the kernel will register the way
the kernel does, and checks every pin against it:

- **Zones:** the zone's node name, when the zone is available, its sensor provider is enabled and
  the name fits `THERMAL_NAME_LENGTH`.
- **LEDs:** `led_compose_name()` (label, else `color:function[-enumerator]`), for each LED whose
  controller is enabled; a multicolor group only when every member registers, a PWM LED only when
  every PWM provider is enabled.
- **Backlights:** pwm-backlight's device name, the WLED's label, the SY7758's and the Odin 2
  Mini's fixed names (an SY7758 without `enable-gpios` does not probe), and `<dsi device>.<reg>`
  for a panel that dims over DCS. The checker's `PANELS` table says which panels do, and the test
  holds it against each panel driver in `kernel/patches`. It also checks that the pinned backlight
  dims the profile's `RETROFORGE_PRIMARY_CONNECTOR`, using msm's connector order: DSI hosts in address
  order, a bridge (the Odin 2's lt8912b) taking its own connector type, and a bonded pair counting
  once.
- **Supplies, fan, GPU:** the supplies the enabled drivers register, `pwmfan`/`gpio_fan`, and the
  Adreno's device name.

Each DTB's `model` goes through the real `device-env`, so the pins checked are the ones a booted
board gets.

```sh
make kernel && make check-hw-paths          # the DTBs the build staged in out/dtbs
make check-hw-paths LINUX_SRC=~/linux       # or compile kernel/dts/qcom here, with RetroForge's DT patches
```

Known gaps live in `tools/check-hw-paths.xfail` (the Odin 2's stick lights, whose SN3112 chips the
DTS disables). A listed check that starts passing fails the run, so a fixed gap must come off the
list. Notes in the output flag hardware that will not register even where no pin names it, such
as the Pocket DS's SY7758 without its enable.

What this cannot see is anything only a device knows: whether a diode is fitted, which ring is the
left one, which zone runs hottest, or whether a GPIO really is an enable.

## Tests

`tests/test-hw-map.sh` drives the real script against a fabricated sysfs (`RETROFORGE_HW_SYS`,
`RETROFORGE_HW_RUN`, `RETROFORGE_HW_DEVICE_ENV`), including stale pins, single-colour LED globs and the
`soc` link, and checks every board profile: each pins battery, charger, backlight, CPU/GPU zones,
fan and devfreq; zone types keep their `-thermal` suffix and fit the kernel's 19 characters; LED
groups parse; and the pins survive `device-env`'s quoting. `tests/test-hw-dtb.sh` covers the checker's
naming rules on fabricated devicetrees (with `dtc`) and its `PANELS` table against the panel
drivers, and runs the whole fleet when `out/dtbs` or `RETROFORGE_LINUX_SRC` is there.
