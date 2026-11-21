# mesa patches

retroforge patches applied on top of the upstream mesa release source (currently `26.3.1`), in
the order listed by `patches:` in [`../source.pin`](../source.pin). Each is applied with
`patch -p1` from the mesa source root (the `mesa-<version>/` tree inside makepkg's `$srcdir`)
by [`packages/build-overlay.sh`](../../build-overlay.sh), inserted right after the first `cd`
in the PKGBUILD's `prepare()`.

Numbers are not reused: the gaps (0001, 0002, 0015, 0016) are patches upstream took, listed under
Dropped.

## Dropped

- **0001-add-a830-chip-id.patch** — dropped at 26.3.1 (2026-11-21). 26.3 registers both msm
  chip ids it added (`0xffff44050000` and `0xffff44050001`, the latter as "830v1"). The one id
  upstream still lacks is the KGSL `0x44050000`, and this image runs the msm kernel driver, never
  KGSL, so nothing here could reach it.
- **0002-tu-implement-VK_QCOM_rotated_copy_commands.patch** — dropped at 26.3.1 (2026-11-21).
  26.3 ships Turnip's `VK_QCOM_rotated_copy_commands` (`docs/features.txt`: DONE (tu)); every hunk
  of the patch was already in the tree. gamescope's rotated blits (`packages/gamescope`) keep using
  the extension, now upstream's.
- **0015, 0016** (`tu/autotune: Track binning pass for RP duration`, `Stabilize RP hash for
  replays`) — dropped at 26.3.1 as planned: they were backports of `79e16e72329` and `af16b1ceb1e`.

- **0002-freedreno-ir3-vulkan-disable-bindless-ubo-const-lowering.patch** — dropped 2026-08-19
  (this file's history has the full write-up). It was a ROCKNIX-origin workaround (added there
  2026-05-12, never upstreamed) that made ir3's UBO-range analysis treat a bindless UBO load as a
  constant range only when the offset was also constant. ROCKNIX removed it on 2026-08-11 as "no
  longer needed" (`ROCKNIX/distribution#3167`), the UBO-range analysis it patched was reworked
  between mesa 26.0.0 and 26.2.0, and this file already marked it a removal candidate.

  **HW retest still owed:** being wrong costs miscompiled shaders — a hang or corruption in a
  Vulkan title, found by a player, not by a build. On the next flashed card, play the Vulkan test
  titles (Super Meat Boy, Garage Circuit Rally, plus at least one Proton title) and watch for
  corruption. If anything reproduces, restore the patch from git history AND record what
  reproduced — the note that was always missing from it.

Patches apply `-p1` against the upstream mesa tree, in the order listed in
[`../source.pin`](../source.pin)'s `patches:` line. If a declared patch is missing or fails to
apply, `build-overlay.sh` / `makepkg` fails fast before the package is built.

## Pre-rotated presents (0003-0013), added 2026-10-09

The twelve commits sunshineinabox carries on top of upstream Mesa in ROCKNIX
(`projects/ROCKNIX/packages/graphics/mesa/patches/0001`-`0012` on `next`, which pins the same
26.2.4 tarball we do; also the fork at gitlab.freedesktop.org/sunshineinabox/mesa, `89ba0269`).
In order (the first, `tu` implementing `VK_QCOM_rotated_copy_commands`, is upstream since 26.3):
the Wayland WSI sorts surface formats, gets `vkCmdBlitImage2` in its dispatch table, supports a rotated `preTransform`, and
gains OPTIONAL pre-rotated presents (`vk_wsi_wayland_prerotate` driconf / env, 90/180/270: the
swapchain image is blitted, rotated, into a panel-oriented buffer at present time and committed
with the matching `wl_surface.set_buffer_transform`, re-sent on every present); it keeps the
modifier across feedback changes while doing so. Gallium's blit info learns a rotation, the util
blitter and freedreno implement it, DRI passes it through `dri2_blit_image`, and EGL's Wayland
platform gets the same optional pre-rotation (`egl_wayland_prerotate`).

What it is for: a board whose display plane cannot rotate (SM6115) otherwise pays a GPU composite
per frame in the compositor. With these the CLIENT rotates once at present, cheaply (a transfer
blit, `VK_QCOM_rotated_copy_commands` on Adreno), and a compositor that honours buffer transforms
(KWin, sway) scans the buffer out directly. ROCKNIX sets the two variables per board from
`prerotate_env` in its `001-functions`. Under gamescope the client side is NOT used: gamescope
rotates layers itself, and its own rotated-blit patches (`packages/gamescope`) use the same
`VK_QCOM_rotated_copy_commands`, upstream in Turnip since 26.3. Off unless the variable is set, so every
other board is unaffected. Applied cleanly on 26.2.4 (checked 2026-10-09). Rebased onto 26.3.1
(2026-11-21): two doc/caps lines next to new upstream ones (`needs_split_planar_samplers`, a2xx-only
`depth_clip_disable`), and EGL now calls upstream's merged `dri_create_image` (26.3 folded
`dri_create_image_with_modifiers` into it) and `dri2_surface_get_dri_drawable()` (26.3 removed the
display vtbl's `get_dri_drawable`).

## A610 registers from the stock blob (0014), added 2026-10-23

Mesa shares one register table (`a6xx_gen1_low`) between the A605 and the A610. 0014 gives the
A610 its own entry, using what the stock Android 14 driver (`Adreno610v1`) writes when it sets up
a context on the Air X. The values come from libwrap captures of a draw, a copy and a compute
dispatch, diffed against Turnip on drm-shim. In the table, TPL1_DBG_ECO_CNTL becomes 0x8000,
SP_CHICKEN_BITS 0x400 and UCHE_UNKNOWN_0E12 0x10000001. It adds the blob's writes of
UCHE_UNKNOWN_0E11, VFD_DBG_ECO_CNTL, RB_UNKNOWN_8E09 (0x4, the same value the A710 uses with one
CCU), SP_UNKNOWN_0CE2-0CE7 and RB_UNKNOWN_8A00-8A30. Two props change: `prim_alloc_threshold`
(3, the blob's value) and `highest_bank_bit` (14). The bank bit is only a fallback, since Turnip
asks the kernel, and every A610 SoC (SM6115, SM4250, SM6125) reports 14 there and in KGSL.

Left out on purpose: UCHE_CLIENT_PF, because the msm kernel sets it to 0x81 for its fault
handler and the blob's 0x4 would clear that. Also left out: values Turnip hardcodes for every A6XX
(TPL1_UNKNOWN_B605, GRAS_MODE_CNTL, TPL1_MODE_CNTL rounding), which would need code changes.
None of the new registers fall in the A610's CP protect list (`a630_protect`, kernel 7.2.11).
With 0014, Turnip's A610 init stream matches the blob for every register above.

Rebased onto 26.3.1 (2026-11-21): 26.3 dropped the `magic_regs` dict and writes `RB_DBG_ECO_CNTL`
and `RB_RBP_CNTL` through `raw_magic_regs` instead (`a6xx_gen1_low` ends with them now). The A610
table gets the same two writes at the values it inherited before (0x04100000, 0x1), and no longer
passes `magic_regs=`, which 26.3's `A6xxGPUInfo` rejects at build time.

**HW test still owed:** this was checked on drm-shim only. On the Air X, run a Vulkan title and a
GL one and watch for hangs or corruption.

## Turnip autotune (0017-0019), added 2026-11-08

The GMEM/sysmem choice from per-GPU costs, split the way it is meant to go upstream.

Built on upstream `79e16e72329` and `af16b1ceb1e` (the RP duration covers the binning pass, the RP
hash is stable across replays), which this series carried as 0015/0016 until 26.3 shipped them.

Rebased onto 26.3.1 (2026-11-21). Upstream's autotune now uses `static_cast` throughout and the
new lines follow it. The shader cache moved to one templated read/write routine
(`tu_shader_cache_process_blob`), so 0017's `nir_tex_count` is one `io.u32()` there. The msm max-clock
query sits after upstream's reworked `MSM_PARAM_GMEM_BASE` read. 0019's
`force_render_mode_reason` is upstream's rename of `gmem_disable_reason`, and its vs-params payload
count moved into upstream's rewritten `tu6_emit_vs_params`, which now loads `num_vec4` vec4s (2
with software multiview). That function still built `tu_draw_state` positionally, which would have put
the iova into the `payload_dwords` field 0017 adds first. It is designated now.
- **0017** — the bandwidth algorithm predicts both modes in microseconds instead of comparing byte
  counts. Costs come from a table per GPU (A610, A613, A650, A740, A750, A830) built from probe
  reports on retail devices, in cycles at the kernel's max clock and leaning cheap. A GPU without a
  row borrows the closest-sized one of its generation, preferring a bigger one.
  `TU_AUTOTUNE_CALIB=off` keeps the byte-count model.
- **0018** — `TU_AUTOTUNE_FLAGS=adapt` (or drirc `tu_autotune_flags`) times every render pass and
  corrects its prediction from what was measured for that pass, kept apart by draw count since one
  pass can be 5 draws one frame and 500 the next. Close calls now and then run in the other mode. `drirc.d/01-retroforge-turnip.conf` turns it on. On SM8550/SM8650,
  `retroforge-launch` sets `TU_AUTOTUNE_FLAGS=preempt_optimize`, which replaces the drirc flags,
  so adapt is off there unless the launcher adds it.
- **0019** — developer tool: `TU_AUTOTUNE_CALIB=force` probes the costs on the running GPU
  (0.6 s on A610/A613) and `export=<path>` writes them out, which is how table rows are made.
  Also `dump`, `log`, `payload`, `replay` and `noshade`.

## EGL regression revert (0020), added 2026-11-21

Arch's `0002` from `mesa 1:26.3.1-2` (heftig, 2026-11-20), unchanged: it reverts upstream
`338afb32f86` ("mesa: don't advertise APIs that are not built"). In 26.3.1 that commit leaves
Wayland GL clients with "No EGL configuration available" (mesa work item 16934, reported on
radeonsi with GTK4, `gles1=disabled` as in our build too). The revert puts back 26.2's
`_mesa_get_version()`, so nothing changes compared to the mesa this image shipped before. Drop it
when a release fixes 16934 upstream, or when Arch drops it.

## A8xx GL hangs (0021, 0022), added 2026-11-21

Ported from Nova-Deck `b7585c0` (their `0003`/`0004`, renumbered: our `0003`/`0004` are the
pre-rotation series). Both are FeralAI's, armada PR #894 `0016`/`0017` (merged 2026-11-14), never
posted upstream, bodies identical to the source. A8xx only (SM8750 / A830 here), so every other
board builds the same code as before.

- **0021-freedreno-a8xx-wait-for-zpass-sample-counts.patch** — on A830 the GPU can hang at high
  clocks when it moves on after a ZPASS_DONE end event before the sample count write has landed.
  Turnip already waits there (`emit_counter_barrier()` after the occlusion-query end event in
  `tu_query_pool.cc`); freedreno had the same helper but used it only for pipeline-statistics
  queries. This calls it after every ZPASS_DONE end event: occlusion pause and resume, and the
  autotune end event. No switch: it mirrors Turnip and costs one WFI per query end. Applies at a
  90-line offset on 26.3.1 (upstream drift in `fd6_gmem.cc`, same as Nova-Deck sees).

- **0022-freedreno-a8xx-rb-done-ts-after-each-draw.patch** — on A830, freedreno GMEM rendering can
  hang the GPU during bursts of small blended draws (reported: Doom 2016 and Half-Life 2 under
  GL). An RB_DONE_TS event with a memory write after every draw prevents it. Empirical: no root
  cause.

  Nova-Deck A/B'd it 2026-11-14 on an Odin 3 with `0021` applied, in one build that carried a
  runtime switch for the event. Half-Life 2 (GL, under FEX) with the event off: `hangcheck detected
  gpu lockup` from `hl2_linux` twice in about 3½ minutes, each recovered by a GPU reset. With the
  event on: no lockup. The event costs frame rate (measured there, not quantified); the switch was
  dropped and the event is unconditional. The original commit says every 8th draw did NOT prevent
  the hang, so any cheaper variant needs the same HL2 A/B (`dmesg | grep -c hangcheck`).

**HW check owed here:** not run on our Odin 3. A GL title on it, `dmesg | grep -c hangcheck` after.

## Adreno 722 (0023-0028), added 2026-11-21

For the Retroid Pocket Duo (SM7750 "Eliza", Adreno 722, chip id `0x43020100`, which 26.3 lists).
Taken from armada (`armada-os/armada` `b91b786`, `packages/mesa/patches/0005`-`0009` and `0013`),
bodies unchanged; line numbers regenerated so the series applies to 26.3.1 with no offset. Never
posted upstream. Only `0028` reaches beyond the A722 (every A7xx gen1: A710, A720, A722, A725,
A730), and no other board here has one of those, so every other board builds the same code.

- **0023-freedreno-a722-blob-regs.patch** — A722 `raw_magic_regs` from blob command-stream traces
  (Vauzi-17's A722 entry, `SP_UNKNOWN_AB01` from sherft2607's Duo Turnip) instead of the A730
  placeholder. Armada measured about 4% more FPS, no GPU faults.
- **0024-freedreno-a722-skip-bv-bin-preamble.patch** — the A722 has no BV pipe. Turnip registered a
  reduced BV bin-restore preamble that replaced the BR one, so a gamescope preemption between GMEM
  bins resumed with the compositor's `RB_BUFFER_CNTL`: CCU write faults at iova 0 and stale tiles.
- **0025-freedreno-a722-no-lpac.patch** — the A722 has no LPAC (KGSL `gen7_17_0` is in the
  `gen7_14_0` family).
- **0026-freedreno-a722-disable-uav-ubwc.patch** — UBWC on internal storage images renders flashing
  black blocks (Megabonk). Images with an explicit DRM modifier keep UBWC, so gamescope's composite
  can still be rotated by the DPU.
- **0027-freedreno-a722-tile-align-32.patch** — 32-row tile alignment, as the A720 and the blob
  traces.
- **0028-freedreno-a7xx-gen1-no-early-preamble.patch** — early preambles make HUD sprites flicker
  on A7xx gen1 (`IR3_SHADER_DEBUG=noearlypreamble` fixed it).

**HW test owed:** none of this has run on a Duo here. Needs the kernel side too (A722 GPU nodes,
Eliza GPUCC, `1115`/`1116`).
