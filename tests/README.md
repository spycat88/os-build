# tests/

Every offline suite in the project. They assert against the **committed tree** — the shipped
scripts, units and config files themselves, never a copy — so what passes here is what ships.

Each suite resolves its inputs from the repo root, derived as `$(dirname "$0")/..`. Nothing here
needs root, a device, a bus or a built image.

## Running them

| Command | What runs | Where |
|---|---|---|
| `make test` | Every host suite | Host. Seconds to a couple of minutes, no build |
| `make test-disk` | `test-select-target.sh`, `test-carve.sh` | Container — they need `sgdisk`, `mtools`, `dosfstools` |
| `make test-signing` | `test-verify-signing.sh` | Container — it signs real bundles, so it needs `rauc` |

`make test` depends on `verify-lock`, which checks the lock's `retroforge` rows against `packages/`
from committed files alone. That runs first because it costs a second and catches a source change
nobody adopted, before any suite spends real time.

CI runs the same three: `make test` and the two disk suites on a plain runner (which is why they
are invoked directly there rather than through `make test-disk` — a failure names which one), and
`make test-signing` against a signing-only container.

## What is here

- **Boot and update** — `test-bootctl.sh`, `test-post-install.sh`, `test-bls.sh`,
  `test-update.sh`, `test-units.sh`, `test-coredump-limit.sh`.
- **Storage and layout** — `test-partition-table.sh`, `test-select-target.sh`, `test-carve.sh`,
  with `lib-gptfixture.sh` rebuilding the real captured
  boards from `docs/internal-storage.md` as sparse GPTs for the two disk suites to share.
- **The installer** — `test-install.sh`, `test-ui.sh`, `test-installer-shipped.sh`.
- **Device behaviour** — `test-pairingd.sh`,
  `test-fan-curve.sh`, `test-cpu-scheduler.sh`, `test-power-led.sh`, `test-suspend.sh`,
  `test-gamescope-display.sh` (which /run/user/<uid>/ holds the live gamescope socket),
  `test-storage.sh`, `test-device-env.sh` (the per-board facts, incl. a dual-screen board's
  second panel), `test-session.sh` (the shell gamescope hosts), `test-ogui-patches.sh` (the logic
  our OpenGamepadUI patches add, on a stock Godot), `test-launch.sh` (how a ROM
  card starts and stops an emulator AppImage), `test-shares.sh` (the player's network
  shares), `test-oom.sh` (either OOM killer takes a running game before the session spine).
- **Graphics** — `test-mesa-source.sh`, `test-fex-guest.sh` (the downloadable x86 guest's
  Mesa overlay, `packages/mesa-x86`), `test-splash.sh`, `test-splash-status.sh`.
- **The tree itself** — `test-guard.sh`, `test-lib-pins.sh`, `test-verify-lock.sh`, and
  `test-upstream-name.sh` (no leftover upstream name anywhere).
- **Publishing** — `test-publish-bundle.sh`, `test-verify-signing.sh`.

## Adding one

Wire it into the `test` target in the `Makefile` in the same commit. A suite nothing invokes is a
suite that is not asserting anything — that failure has been paid for here more than once, which
is why `test-select-target.sh` and `test-carve.sh` now have a target and a CI job rather than a
path someone had to remember to type.

Executing the shipped artifact rather than a reimplementation of it is the other standing rule.
Several scripts under `rootfs/overlay/` carry explicit test seams (an overridable path, a
`RETROFORGE_*_PROC` env var) for exactly this reason; use those rather than copying logic into a
suite, because a copy is free to agree with itself forever.
