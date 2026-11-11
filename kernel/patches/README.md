# kernel/patches/

Out-of-tree kernel patches applied on top of the pinned source by `kernel/build.sh`,
unified across all supported SoCs (no per-SoC subdir).

Apply order is **lexical**, which the numbering makes identical to numeric order. The
build applies them cumulatively with `--fuzz=0`: a hunk that lands on approximate context
has drifted from what it was written against and can silently attach to the wrong place on
a later bump, so approximate is treated as failure.

## Numbering: subsystem, not device

The number says **when a patch applies**, and it is keyed on subsystem.

| Range | Band | Contents |
|---|---|---|
| `0000-0099` | core | arch/arm64, syscall ABI, prctl — the FEX-adjacent core changes; cpuidle / irqchip / soc suspend plumbing (`0030`-`0050`, SM6115) |
| `0100-0199` | clk | clk, pmdomain, interconnect, pinctrl, iommu |
| `0200-0299` | gpu | drm/msm GPU: adreno, GEM, VM_BIND, shrinker |
| `0300-0399` | dpu | drm/msm DPU: planes, flush, rotation, LUTDMA (+ its binding) |
| `0400-0479` | dsi | drm/msm DSI: host, PHY, byte clock |
| `0480-0499` | drmcore | drm core helpers that later patches build on |
| `0500-0599` | panel | drm/panel drivers, one per number |
| `0600-0699` | backlight / leds / pwm | backlight `0600s`, leds `0650s`, pwm `0680s` |
| `0700-0799` | input | touch `0700s`, joystick `0740s`, haptics + force-feedback `0770s` |
| `0800-0899` | audio | ASoC, qdsp6, codecs |
| `0900-0999` | power / misc | power-supply `0900s`, hwmon + misc devices `0970s` |
| `1000-1099` | net / usb / pci / storage / crypto | serial too (`1090`) |
| `1100-1199` | dts | arm64 `.dtsi` fixes to upstream SoC files — last, after their drivers |

Numbers are spaced by 10 (by 5 where a band is dense) so a new patch slots in without
touching its neighbours. Consecutive backports from one upstream series are one patch file,
not one per commit: the series moves and drops as a unit, and the header lists each upstream
commit (`0230` carries twelve).

**Device-keyed ranges were considered and rejected.** The patches do not partition by
device: `drivers/gpu/drm/panel/Kconfig` is co-edited by all twelve panel patches,
`0480-drm-panel-add-brightness-levels-helper` serves every panel,
`0340` covers two SoCs, and `0530-chipone-icna35xx-panel` is family-wide. A per-device
range forces an arbitrary pick for each shared patch, and those picks become the next mess.

## Adding or moving a patch

One invariant governs order, because the stack applies cumulatively:

> **Two patches that touch a common file must keep their relative order.**

Everything else is free to move. `./check-order.py` lints the convention (numbering,
naming, lexical-equals-numeric, band membership); the dependency invariant itself is proved
by the build, since `--fuzz=0` turns a wrong order into a hard failure rather than a hunk
landing quietly somewhere else.

Naming is `NNNN-lower-case-with-hyphens.patch`. Keep each patch focused and traceable to an
upstream submission or a clear bring-up reason.

## Provenance

The number cannot answer *"can I drop this on a bump?"* — that is what provenance is for:

- **Origin** — `mainline` (the same change is in mainline; the commit is cited), `posted`
  (on a kernel list, not in mainline yet), `community` (a peer tree — ROCKNIX, armada, a
  vendor/CAF driver — never posted), `retroforge` (written here, never posted).
- **Source** — msgid of the posting we carry, or the tree it came from, plus the upstream
  state that decides its fate.
- **Drop when** — what makes it removable.

Audited 2026-09-22 against v7.3-rc4 (merge status from git, review state from patchwork
replies — lore was not reachable, so "never posted" means no patchwork hit). `posted` and
`mainline` rows re-audited 2026-10-12 against v7.3-rc7, the 7.2.10 pin and the maintainer
trees (msm-next, qcom `clk-for-7.4` / `arm64-for-7.4`, pci `next`). Re-audit on
every bump: this table is a snapshot, the `Drop when` column is what to re-check.

At the 7.3.1 bump (2026-10-30) all five `mainline` rows (`0230` `0620` `0800` `1080` `1155`), four `posted` ones (`1000` `1063` `1165` `1167`) and the `community` `0145` were in v7.3 byte-for-byte and were deleted, so `mainline` is now empty; the six patches whose substance changed (`0530` `0810` `0820` `0855` `0994` `1090`) carry a "7.3.1 bump" note in their headers, and `kernel/SOURCE.pin` lists every rebase decision. `0810`, `0820` and `0825` were deleted after that (Nova-Deck b404b61a): the Pocket S2 and Pocket FIT now use mainline's `ayaneo,pocket-s2-sndcard` with linux-firmware's WSA-typed topology, and every MI2S speaker path uses mainline's per-DAI `bclk` (a new `0820` enables it on sm8750; `0826` was reduced to what SM4450 adds).

Totals before that bump: 5 `mainline`, 20 `posted`, 23 `retroforge`, 115 `community`. (`0310` and `0430` were
deleted at the 7.2.8 bump: stable backported both, byte-identical; the `0430` slot is reused
by the SM8750 DSI reparent-on-power-off patch, a different change.) Half the stack will
never land upstream, which is why provenance is a table and not a number band.

SM4450 port (2026-10-26): 40 patches from ROCKNIX SM4450 (`ROCKNIX/distribution` next `c378e634`), audited against 7.2.11 — NOT taken because our stack already carries them: `0016` rsinput (`0745`), `0019` boot-scanout stop (`0370` is its v2), `0041` qmp v4 DP pre-emphasis, `0045` soc-serial (`1015`), `0046`-`0048` WCN3950 (`1021`-`1023`); NOT taken by policy: `0054` (renames `qcom-battmgr-bat` to `battery` on every battmgr board, which every SM8550+ profile pins) and `0034` (inverts aw88166 `PCM Playback Volume`, which would turn the Thor UCM's `0` from full scale into -127 dB). `0286` and `0862` are scoped here to SM4450.

SM8750 port (2026-10-19, issue #121): 36 patches added from ROCKNIX SM8750 + armada, all
audited against 7.2.11 — NOT taken because already upstream at this pin: ROCKNIX `0050`
(gdsc_gx_disable), `0055` (aw99706 fixes), `0517` (typec-mux EPROBE_DEFER), the sgm3804
regulator, the vpu35/gen80000 firmware (LINUX_FW.pin); NOT taken by policy: the whole
suspend-to-RAM set (ROCKNIX `0504`/`0508`, armada's S2R layer, SoCCP), the stick-ring
RGB half of konkr_sysbtn, rsinput `1300` global-default recalibration (per-board module
params on the Odin 3 boards.map row instead). The hv-haptics HAP530/V5 driver generation
was deferred at first (it swaps the rumble stack under every shipping board) and then
taken for issue #122 — see the `0780`–`0796` rows.

| Patch | Origin | Source | Drop when |
|---|---|---|---|
| `0010` | community | Sergio Lopez, Asahi downstream (muvm/FEX); same as ROCKNIX `0504`. Never posted. | never — downstream prctl ABI |
| `0020` | community | Billy Laws, FEX downstream handler. A cut-down RFC (André Almeida, v2 `<20251117160841.334224-2-andrealmeid@igalia.com>`) was opposed by Will Deacon: arm64 will not carry x86 unaligned-atomic emulation. We fixed a missing exception-table entry on `Load128`'s `stlxp` (kernel oops on SM8250, which lacks LSE2 and traps every unaligned atomic), and made backpatch cache maintenance fault-safe (`caches_clean_inval_user_pou()` instead of `flush_icache_range()` on user code; from Kettle Linux `1389`). | never |
| `0110` | posted | Lucid Ole hunk = Esteban Urrutia "SM8450 QoL (dispcc)" v3 3/3 `<20260713-sm8450-qol-dispcc-v3-0-56fd05822270@proton.me>`, re-applied to qcom `clk-for-7.4` as `eb34e2804ce4` (2026-09-23; the earlier `2295d6a84179` never reached mainline), no Cc: stable. The sm8550 mdp-ops hunk is our retarget of v3 1/3 and was never sent — Dmitry asked for exactly this on other dispcc controllers. | guard: when `eb34e2804ce4` reaches our pin (v7.4); mdp ops: when sent and merged |
| `0111` | community | ROCKNIX SM4450 `0011` (sunshineinabox): the sm4450 twin of mainline `73df1b79026d` (sm8450 dispcc mdp ops). Never posted. | when an sm4450 equivalent lands |
| `0112` | community | ROCKNIX SM4450 `0012`: splash quiesce + DSI RCG parent enable on dispcc-sm4450. Never posted. | never |
| `0120` | posted | Oleg Keri, "pmdomain: qcom: rpmhpd: don't clamp gfx and gmxc before sync_state" `<20261021080517.2161-1-okerixx@gmail.com>`, Acked-by Akhil P Oommen, Tested-by on SM8750; via andrebraga ROCKNIX SM8750 `Kernel_7.3` `0052`. Replaced 2026-11-03 the armada-scoped presync floor (armada `0121`, ex-ROCKNIX `ef264a238d`). Unlike that one it is GLOBAL: the shared `gfx`/`gmxc` domains skip the pre-sync_state clamp on every SoC, so SM8250/SM8550/SM8650 GPUs also boot unclamped now (HW check owed on each). | when merged |
| `0121` | community | ROCKNIX SM4450 `0002`: LCX domain for SM4450 in rpmhpd. Never posted. | when upstreamed |
| `0130` | community | map220v via ROCKNIX `0122`. Never posted. The same change for x1e80100 is being reverted in 7.3 (hard resets) — high-risk to post. | never |
| `0131` | posted | Tengfei Fan, "[PATCH 2/3] interconnect: qcom: Add SM4450 interconnect provider driver" `<20230908064427.26999-3-quic_tengfan@quicinc.com>` (2023-09-08, not merged), via ROCKNIX SM4450 `0006` with its binding header. | when upstreamed |
| `0132` | retroforge | Written 2026-10-24 (`.claude/plans/kernel-tuning.plan.md`). Never posted. `icc-rpm` resends every node's bandwidth on every vote at 7.2.11; the downstream RPM-SMD bus driver (msm-4.19 `msm_bus_rpm_smd.c`) sends only dirty entries. Only the SM6115 uses `icc-rpm` in this fleet. | when upstream `qcom_icc_rpm_set()` skips unchanged requests |
| `0142` | posted | Abel Vesa "clk: qcom: Tie CX power domains to GCCs" v5 24/42 + 25/42 + 26/42 `<20260924-qcom-tie-cx-to-gcc-v5-*-38732033e5b5@oss.qualcomm.com>`, applied to qcom `clk-for-7.4` (sm8550 `fe2a50974f4a`, sm8650 `e4e6177235c6`; sm8750 26/42 added 2026-11-02, upstream a5808a3a). `.use_rpm = true`: runtime PM on GCC, so CX can drop once every GCC consumer has released its clocks and GDSCs. Needs `1150`'s `power-domains` in DT. | v7.4 |
| `0151` | community | Teguh Sobirin, ROCKNIX SM8750 `0044` (`Fixes: 3267c774f3ff`), upstream `0150` (our `0150` is the sm6115 USB-GDSC patch). Suspend-motivated upstream fix (PWRSTS_RET_ON so PCIe GDSCs survive gdsc_disable()); kept for GDSC-policy parity with sm8550/sm8650, whose upstream GCCs already use RET_ON — inert here without kernel sleep. | when 7.2.y/7.3 takes the fix |
| `0210` | community | map220v via ROCKNIX `0004`. Never posted; reuses `a750_ifpc_reglist` (unverified for A740). | when A740 IFPC lands upstream |
| `0220` | posted | Rob Clark v2 `<20260912145922.24115-1-robin.clark@oss.qualcomm.com>` (+ `-2-`), applied to msm-next 2026-09-27 as `bbe4401e118c` (THP) + `8eeca96ad138` (shrinker modparam), code identical to ours. Patchwork still says `new`. | v7.4 |
| `0240` | retroforge | Written here, from GPU runtime-PM traces on the Pocket S2. Works around the trigger (suspend soon after resume); why the A750 GMU never reaches IFPC is not known. Never posted; no prior report found on linux-arm-msm, patchwork or drm/msm issues. | when upstream fixes the A750 GMU idle wait, or sets its own A750 `inactive_period` |
| `0250` | community | gennro, kettlelinux `1350` via armada `0620` (PR #662). Not posted. Masks `a6xx_hfi_irq()`'s clear to CM3_FAULT, as kgsl does; the root cause of the A740 `GPU_SET` OOB timeout wedge. | when mainline stops the HFI handler clearing polled bits |
| `0255` | community | gennro, kettlelinux `1351` via armada `0621` (PR #662). Not posted. Bounds the `fault_coredump_done` wait (2 s) that deadlocks against `recover_worker`. | when mainline bounds that wait |
| `0260` | community | armada `0622` (PR #662). Not posted. Masks `GMU2HOST_INTR_MASK` before the GMU boots, so resume replies do not raise the HFI irq. | with `0250`, or when mainline programs the mask before `a6xx_hfi_start()` |
| `0266` | community | gennro, Kettle Linux `1180`, body byte-identical. On GMU-bandwidth-voting GPUs (A740, A750) the boot bus vote set at resume was never dropped, holding DDR at the boot OPP's bandwidth while the GPU stays powered (measured on the Pocket FIT: GPU `ebi` peak 8.17 GB/s whenever active). | when mainline drops the boot vote |
| `0270` | community | virtudude, via Kettle Linux `1210`, body byte-identical. `msm_gpu_convert_priority()` inverts the within-ring order (userspace 2 → `DRM_SCHED_PRIORITY_KERNEL`, 0 → `NORMAL`), so on one ring a Turnip queue (a game) outranks freedreno GL (Xwayland, the UI) and can starve it. Matters most on the single-ring A650 (SM8250) and A610 (SM6115), where the game-priority layer cannot move games to another ring. | when upstreamed |
| `0280` | posted | Jie Zhang, "drm/msm/a8xx: Add support for Adreno 830 GPU" (pakala-gpu v1 1/4) `<20260809-pakala-gpu-v1-1-207ad1fac1c7@oss.qualcomm.com>`, via andrebraga ROCKNIX SM8750 `Kernel_7.3` `0034` (peer: in mainline for 7.4). Replaced 2026-11-03 the community catalog row (ROCKNIX SM8750 `0049`). Chip ID `0x44050001`, which our Mesa `0001` already lists. | v7.4 |
| `0281` | posted | Konrad Dybcio, "drm/msm/a6xx: Send AB GMU votes on A8xx" `<20261030-topic-a8xx_ab_vote-v1-1-66afb5bc50b9@oss.qualcomm.com>`, via andrebraga ROCKNIX SM8750 `Kernel_7.3` `0083` (linux-arm-msm queue). | when merged |
| `0282` | posted | Connor Abbott, "drm/msm: Fix GMEM_BASE on a8xx" v2 `<20261029-drm-msm-gmem-base-fix-v2-1-26b338471b46@gmail.com>`, via andrebraga ROCKNIX SM8750 `Kernel_7.3` `0084`. | when merged |
| `0283` | posted | Rahul Pon, "drm/msm/a8xx: report the GMEM size of the active slices" v2 `<20260930183840.1171-1-theflyingrahul@gmail.com>`, via andrebraga ROCKNIX SM8750 `Kernel_7.3` `0085`; one context line regenerated after `0282`. | when merged |
| `0284` | mainline | upstream `0285`. Akhil P Oommen, Hawi GPU series `<20260923-hawi-gpu-v1-*-0c3c79a1a470@oss.qualcomm.com>`: `128a0edde507`, `eab0aff8965e`, `b5269bf0e1ad`, `86f80884fb7f`, all v7.4-rc1. `eab0aff8965e` alone (andrebraga ROCKNIX SM8750 `Kernel_7.3` `2010`) makes a GPU corner above the top MX corner fail GMU init on every GMU GPU; `86f80884fb7f` clamps it and needs `b5269bf0e1ad`. `020b8eaa1db8` (BX rail) skipped. | v7.4 |
| `0330` | posted | Dmitry Baryshkov v4 `<20261003-fd-kms-fix-smmu-v4-0-2a44d4d8ac77@oss.qualcomm.com>` (we take 1–3, 5–9 of 10; skip MDP5-only 4 and drm/ci 10), latest. Replaced v3 on 2026-10-12: 3/10 now queues and schedules a retired framebuffer under one lock so vblank-off cannot free it in between; 5/6 add CWB/CDM reservation clears. v4 names a prerequisite, "KMS destroy fixes" `<20261003-msm-kms-destroy-fixes-v1-*>` (init/teardown error paths), which we do not carry. Not in msm-next. | when merged |
| `0340` | community | tiopex, ROCKNIX `ec3d53baac` (generic part split into ROCKNIX `0013-drm-msm-dpu-fix-inline-rotation`). Never posted; the width/height check, `test_bit` and CW/CCW fixes are real mainline bugs. | when the generic fixes are sent and merged |
| `0341` | community | enij90 (armada-tb321fu `ee94cd65` `0818`), taken via ROCKNIX PR #3508 (`0018`); header renumbered to our `0340`. Never posted. Measured by writeback on SM8650; only affects pipes that rotate inline. | with `0340`, or when mainline programs a rotation-aware QSEED4 preload |
| `0342` | community | Content-equivalent of ROCKNIX SM8750 `0068`, re-expressed on `0340`'s core: the four SM8750 VIG pipes get `VIG_SM8550_MASK_SDMA` + a scaler-3.4 rot_v2 sblk reusing the shared `dpu_rot_sm8550_cfg_v201` (ROCKNIX mints byte-identical SM8750-named copies; armada `0066` merged all three SoCs the same way). | with `0340` |
| `0343` | posted | Rob Clark, "drm/msm/dpu: Fix GAMMA LUT for sm8750 related DPUs" `<20260930152645.22194-1-robin.clark@oss.qualcomm.com>`, Reviewed-by Dmitry Baryshkov, via andrebraga ROCKNIX SM8750 `Kernel_7.3` `0082`: the SM8750 DSPP gains its register GC block, so CRTCs expose GAMMA_LUT. `0360` was rebased onto it (its note that SM8750 GC is a LUT-bus block is superseded). | when merged |
| `0350` | community | tiopex, ROCKNIX `60bb58c1db`. Never posted. | never |
| `0351` | community | sunshineinabox, ROCKNIX PR #3377 (SM8250 `0208`), hand-merged onto `0350` with `0350`'s values as the defaults; the PR's own set is in the header as a cmdline profile. Never posted. | never |
| `0352` | community | sunshineinabox, ROCKNIX PR #3377 (SM8250 `0210`), rebased onto `0351`. Never posted. | never |
| `0360` | community | armada `7e9147a` + `12366dc` (virtudude), a port of the downstream SDE reg-dma engine. Never posted. | never |
| `0365` | community | armada `0069`. Never posted. | with `0360` |
| `0370` | community | sunshineinabox (ROCKNIX). Subject says v2, but no posting was found. | never |
| `0380` | community | sunshineinabox, ROCKNIX PR #3377 (`0012`, `0014`, `0015`, squashed). Vendor-DT catalog values, never posted. | never |
| `0385` | community | sunshineinabox, ROCKNIX PR #3377 (SM8250 `0201` + `0202` as of `566a53ef`, squashed), plus our no-rotator guard for inline-rotation SoCs and the 0330 `msm_framebuffer_cleanup()` / 0230 `msm_gem_new()` signatures. Never posted. Enabled per board by `dts/qcom/sm8250-sde-rotator.dtsi`. | never |
| `0390` | community | armada `0078` (PR #629). Never posted. Command-mode only: the INTF TE path read the video timing engine's line counter, which does not run there; it now reads the tear-check counter, as the pingpong TE path already did. Video-mode panels are untouched. | when mainline fixes the INTF-TE scanout position |
| `0395` | retroforge | Upstream issue #110: on a dual-interface video-mode panel, per-interface CTL flushes that straddle the programmable fetch start underrun the next frame (black blink). One wait per kickoff, on the master, keeps them on one side. Never posted; generic, worth sending once HW-proven. | when mainline guards the kickoff against the fetch start |
| `0396` | retroforge | A command-mode frame is sent to the panel at kickoff and shown from the first TE after its transfer starts, but the page flip event went out after the transfer stamped with the PREVIOUS TE. gamescope schedules from that stamp, one refresh early, so a limited frame missed every second refresh (Pocket Max: 60 fps @ 120 Hz ran 40). The event is now armed from the CTL start irq for the next vblank, as on video mode. HW: Pocket FIT all caps solid; Pocket Max solid except where the `0385` rotator fence delays the kickoff (cap = refresh). Never posted; generic. | when mainline reports command-mode flips at the vblank they show at |
| `0410` | retroforge | From ROCKNIX SM8250 `0001`. Partial revert of mainline `2d51cfb77daa` (bpc×3 for video mode). | when no shipped panel needs it, or upstream fixes it |
| `0420` | retroforge | v1 was ROCKNIX SM8250 `0016`; the xfer/modeset race fix is ours. Never posted. | when upstreamed |
| `0430` | community | Teguh Sobirin, ROCKNIX SM8750 `0048`, rebased to 7.2.11 (one struct context line drifted). Reparents the byte/pixel RCGs back to their original (XO) parent in `msm_dsi_host_power_off()` — the SM8750 dispcc stalls its RCG update when the selected source (the powered-down PHY PLL) is dead. NOT the same patch as the old `0430` (stable took that one, "round byte clock after reparenting"). | when upstream restores the RCG parent on disable |
| `0440` | community | armada `0048b` (virtudude). Never posted. Replaces our re-apply of Neil Armstrong `93c97bc8d85d`, reverted by `44784327815b` in 7.3-rc1 / 7.2.6 because it broke non-bonded panels; this keeps the revert and adds the missing slave-PHY mux write. Neil's rework not posted. | when Neil's bonded-mode rework lands |
| `0480` | community | armada `0059` (virtudude). Not submitted; needs a panel-common binding first. | never |
| `0490` | posted | Jianfeng Liu v2 `<20250925040530.20731-1-liujianfeng1994@gmail.com>`. NAKed by Dmitry Baryshkov on design; he points to `b54a38af7138` (in 7.1, already in our tree) as the real fix. | now, if DP audio works without it on SM8550/SM8650 |
| `0505` | retroforge | Also ROCKNIX SM8550 `0051`. Driver-generator output, FIXME authorship. | never |
| `0510` | retroforge | Also ROCKNIX SM8550 `0052`. Same as `0505`. | never |
| `0515` | community | ROCKNIX. Superseded by mainline `4c0fe6422f3a` (st7703, `ayaneo,pocket-ds-lower-panel`). | v7.3 — change the DT compatible |
| `0520` | posted | Xilin Wu "AYN Odin 2 support" v1 04/10 `<20240424-ayn-odin2-initial-v1-4-e0aa05c991fd@gmail.com>`. v2 never sent. | never, unless mainline `panel-synaptics-tddi` can take TD4328 |
| `0525` | community | Teguh Sobirin via ROCKNIX `0056`. Never posted. | never |
| `0530` | community | Teguh Sobirin via ROCKNIX `0057`, plus our levels/linear scale, plus gennro's no-backlight-DSI-while-off fix (Kettle Linux `1386`, adapted to our levels map; drops `.get_brightness`). Mainline has its own `f747473a838e`, also Teguh's driver, posted by Aaron Kling (v2 `<20260514-icna35xx-v2-2-45acd1dfa566@gmail.com>`) (same file name, per-board compatibles none of our DTs use, no Mangmi/EVO); fix pending: Aaron Kling "Fix picture parameter set". At 7.3.1 ours was RENAMED to sit beside it, as `0535` was: `panel-ddic-icna35xx.c`, `DRM_PANEL_DDIC_ICNA35XX`, driver `panel-ddic-icna35xx`; `0531`-`0533` follow it. Mainline's stays off. | when the mainline driver covers icna3512/icna3520/Pocket Max (rebase ours as a delta on it) |
| `0531` | community | gennro, Kettle Linux `1330`, body byte-identical: the Odin 2 Portal's ICNA3512 60/120 Hz setup bytes made exactly what AYN's Android DT sends. | never |
| `0532` | community | gennro, Kettle Linux `1340`, body byte-identical: 50, 145 and 165 Hz modes on the Portal (register 0x48 values measured from TE-driven vblanks). | never |
| `0533` | community | Jacob Cook, ROCKNIX SM8750 `0518`, rebased onto our `0530`-`0532` driver (live-reprogram guard uses `panel.prepared`; their tree has a local `enabled` flag). sysfs `frame_len_120`/`frame_len_60` on the Odin 3 panel, applied live and persisted for later inits; the per-device calibration quirk writes them. | never — calibration knob |
| `0535` | community | Teguh Sobirin via ROCKNIX, plus the 120 ms sleep-out wait (Kettle Linux `21-sm8250/0058`). Mainline 7.2 has a different version, `panel-chipwealth-ch13726a` (`3ee01b8647b5`), Thor only: also Teguh's driver, posted by Aaron Kling (RFC `<20260222-ch13726a-v1-2-e501d78e105a@gmail.com>`). It used the same `.name`, `panel-ch13726a-amoled`, which was harmless while that driver was off; SM4450 turns it on (`0536`, RP Classic) and it links first, so ours is renamed `panel-ddic-ch13726a` (seen on the RG 55G1: "Driver 'panel-ch13726a-amoled' is already registered, aborting"). | when the Retroid variants are added to the mainline driver |
| `0540` | community | KancyJoe via ROCKNIX SM8650 `0062`. Superseded by mainline `1190fc8d7b8a` (`panel-renesas-r63419`, same compatibles). | v7.3 — DT supplies become `vsp`/`vsn`; width is 78 mm there, 79 here |
| `0545` | retroforge | Also ROCKNIX SM8650 `0063`. Never posted. | never |
| `0550` | community | ROCKNIX. Never posted; possibly an R63419 variant (unverified). | never |
| `0555` | community | Teguh Sobirin via ROCKNIX `0104`. Aaron Kling posted a different version (`<20260814-rp6-panel-v1-4-111c1aeccf0f@gmail.com>`, `retroidpocket,rp6-panel`); v2 owed after Neil's review. | when Aaron's series lands — switch compatible |
| `0556` | community | Jacob Pyke via ROCKNIX SM8250 `0105` (co-authored by spycat88), rebased onto `0555` (probe hunk context only). Adds `vtdr6130,rp5` / `vtdr6130,rpflip2` with the SM8250 supplies for the Pocket 5 / Flip2 Visionox panel variants, and the missing F0 byte in the page-select write (which also changes the Pocket 6 sequence, matching ROCKNIX SM8550 `0104`). ROCKNIX's frame-length calibration on top (SM8250 `0506`) is not carried. Never posted. | when Aaron's RP6 series lands — fold into it |
| `0560` | posted | Teguh Sobirin via ROCKNIX `0105`. Posted by Jacob Pyke with Teguh as author, as Ilitek IL97680A panels for the Nova and Duo: `<20261025133741.100490-3-jacob@pyk.ee>` (2026-10-25). | when upstreamed |
| `0610` | community | Teguh Sobirin via ROCKNIX `0058`. Never posted. | never |
| `0630` | community | ROCKNIX SM8750 `0056`. The AW99706 driver itself is upstream in 7.2.11 and ROCKNIX's `0055` fixes are already in; this one (enable HWEN before the chip-id read) is not. | when upstreamed |
| `0635` | community | ROCKNIX SM8750 `0057`: the KONKR Pocket FIT Elite's cfg7 wiring for AW99706. | never |
| `0650` | community | Teguh Sobirin via ROCKNIX `0033`. Never posted. | never |
| `0660` | community | ROCKNIX SM6115 `0013` (2026-10 state): aw200xx vdd supply + power off in suspend. Supersedes the SM8250 `0061` vdd-only version this slot used to carry; serves the Pocket Max, Air X and Air Y. | when upstreamed |
| `0680` | posted | BigfootACA, in Xilin Wu's Odin 2 v1 02/10 `<20240424-ayn-odin2-initial-v1-2-e0aa05c991fd@gmail.com>`. v2 never sent. ROCKNIX fix `4609c5017f` folded in (`set_bit()` on a `u8[3]`: alignment fault + overflow, #74). | never |
| `0705` | retroforge | Also ROCKNIX `0015`. Aaron Kling posted an equivalent (patchwork 14518751); Dmitry Torokhov pushed back. | never |
| `0710` | community | Teguh Sobirin via ROCKNIX `0053`; Alexandre Hamamdjian posted it with Teguh as author, `<20260723-b4-ft5426-v1-3-d4b4e32be042@gmail.com>`. The DT property was rejected by Conor Dooley (series 1133142) — the fix belongs in an I2C adapter quirk. | never |
| `0715` | community | ROCKNIX (Pocket S 1K/2K). Never posted. | never |
| `0720` | community | Teguh Sobirin via ROCKNIX `0059`. Never posted. | never |
| `0725` | retroforge | Also ROCKNIX `0032`. A hack. | never |
| `0730` | retroforge | Port of the SynapticsHostSW `synaptics_dsx` vendor driver. | never |
| `0735` | retroforge | Kconfig for `0730`. | with `0730` |
| `0738` | community | Chipone vendor driver via kevinkreiser/chipone_tddi → ROCKNIX. ROCKNIX SM8750 has a ~380-line clean-room replacement (`0061-input-touchscreen-add-chipone-tddi`). | never |
| `0745` | retroforge | Driver by Teguh Sobirin; ROCKNIX SM8550 `0031`. Never posted. | never |
| `0750` | community | ROCKNIX SM8250 `0008` (Molly Sophia, BigfootACA, Teguh Sobirin). Never posted. | never |
| `0755` | community | ROCKNIX SM8250 `0060` (sunshineinabox) at its 2026-10 state: Pocket Max + Air Y Pro variants of the MCU joypad. Makefile hunk re-rolled around `0750`. | never |
| `0580` `0736` `0990` `1175` | community | ROCKNIX SM8250 `0064` `0065` `0066` `0067` (Philippe Simons): MANGMI Air Y Pro panel, Hynitron CST66xx touch, pm8150l LCDB regulator + its dtsi node. Added 2026-10-09. Dmitry Baryshkov's own LCDB driver (`be8c264748`, a different implementation) and binding are in linux-next with the same `qcom,pm8150l-lcdb` compatible, so `0990`/`1175` must follow that binding or go at the bump that carries it. | never |
| `0030` `0040` `0050` | community | ROCKNIX SM6115 `0017` `0018` `0019` (cpuidle-psci late init, PSCI SYSTEM_SUSPEND fallback driver, MPM wake timer via genpd). Never posted. SM6115 port, 2026-10-09. | never |
| `0055` | community | ROCKNIX SM8550 `0502` (Ashley; SM8750 `0504` is the same line): drop `IRQF_NO_SUSPEND` from the IPCC mailbox IRQ, so ADSP charger notifications over pmic_glink stop pulling the SoC out of suspend every few minutes (its author: RP6, 30+ minute sleeps). Applies to every IPCC SoC in the unified kernel, not just SM8550. Never posted. SM8550 suspend, 2026-11-11. HW: one 60 s RTC-woken deep suspend resumed on the Retroid Pocket Nova (7.3.3) with this in; no A/B without it. | never |
| `0135` | posted | ROCKNIX SM6115 `0010`, Xilin Wu: `clk-rcg2` set_duty_cycle() boundary overflow. | when merged |
| `0155` | community | ROCKNIX SM4450 `0013`: gpucc-sm4450 hlos1_vote_gpu_smmu clock (+ binding id). Never posted. | when upstreamed |
| `0156` | community | ROCKNIX SM4450 `0014`: let the kernel enable the SM4450 GX GDSC (the A613 has no GMU). Never posted. | when upstreamed |
| `0157` | community | ROCKNIX SM4450 `0017`: gpucc-sm4450 gfx3d RCG for GMU-less use. Never posted. | when upstreamed |
| `0158` | community | ROCKNIX SM4450 `0018`: gpucc-sm4450 retains GX GDSC regs across collapse. Never posted. | when upstreamed |
| `0161` | community | upstream `0160`. André Braga, andrebraga ROCKNIX SM8750 `Kernel_7.3` `0515` @ `1c1c374bdc`, not posted, body identical. scmi-cpufreq builds the CPU OPP tables from firmware and never sets an OPP, so `opp-peak-kBps` in a CPU's DT OPP table cast no interconnect vote; it now adds the DT table and sets the OPP on each frequency change (fast switches hand the vote to a worker through irq_work). Inert without the `1182` tables. Runtime switch: `/sys/devices/system/cpu/cpufreq/policy*/bandwidth_votes`. HW A/B owed. | when upstreamed, or dropped on a failed A/B |
| `0165` | community | André Braga, andrebraga ROCKNIX SM8750 `Kernel_7.3` `0526` @ `1c1c374bdc`, not posted, body identical. icc-bwmon votes the measured CPU traffic as peak only, which aggregates as a max and never adds to the GPU's traffic; it now also votes it as average, as downstream bwmon does. Affects every SoC with bwmon (SM8550, SM8650, SM8750). Runtime switch: `icc_bwmon.vote_avg`. HW A/B owed. | when upstreamed, or dropped on a failed A/B |
| `0170` | community | André Braga, andrebraga ROCKNIX SM8750 `Kernel_7.3` `0517` + its binding `0516` @ `1c1c374bdc`, not posted; MAINTAINERS hunk dropped. Perf PMU for the SM8750 LLCC's per-CPU read-miss counters (downstream llcc-pmu-ver2), the miss source for `0175`. | when upstreamed, or with `0175` |
| `0175` | community | André Braga, andrebraga ROCKNIX SM8750 `Kernel_7.3` `0523` + its binding `0522` @ `1c1c374bdc`, not posted; MAINTAINERS hunk dropped. CPU memory latency voter: while a CPU misses often per instruction it votes the LLCC/DDR frequency its DT table maps the CPU frequency to (downstream memlat runs in the kernel on SM8750). Binds only from the `1181` (upstream `1180`) DT nodes. Runtime switch: the driver's sysfs `enable`. HW A/B owed. | when upstreamed, or dropped on a failed A/B |
| `0190` | posted | Nizat Mikayilli, "iommu/arm-smmu-qcom: Add SM8550 MDSS compatible" v1 `<20261107-b4-smmu-sm8550-v1-1-777d0a41170b@dxdmail.cc>`, body byte-identical (b4); no replies as of 2026-11-09. Gives SM8550 MDSS an identity domain at boot, so the bootloader splash still scanning out at kernel entry does not fault on an empty translating domain before `0370` stops it. Aimed at the Pocket ACE's 10 boot-time `cbfrsynra=0x1c00` context faults (`kernel/SOURCE.pin`, KNOWN BOOT NOISE). HW gate: that count goes to 0. | when merged |
| `0195` | retroforge | `0190` for `qcom,sm8650-mdss`: same splash handoff on the SM8650 boards (ayaneo-common's `cont_splash_region`, chainloaded EFI). Taken while the Pocket FIT reboots now and then during kernel boot, with no trace of why; not shown to be the cause. Never posted. | with `0190`, or when posted and merged |
| `0140` `0150` `0160` | community | ROCKNIX SM6115 `0006` `0008` `0035` (gcc-sm6115 GP clocks on rcg2_gp_ops, USB GDSC retention, LPASS LPI pinctrl functions; `0007`, the video GDSC HW_CTRL trigger that was our `0145`, is in v7.3 and was deleted at the 7.3.1 bump). `0006` is Xilin Wu's sc7280 pattern applied to sm6115. | never |
| `0387` `0388` | community | ROCKNIX SM6115 `0207` `0211` (sunshineinabox): SmartDMA on the sm6115 catalog, VBIF AXI non-shareable. The rest of ROCKNIX's SM6115 DPU set is already here: `0205`/`0208`/`0210` are `0350`/`0351`/`0352`, `0200`-`0202` are `0385`. | never |
| `0565` `0566` `0567` | community | ROCKNIX SM6115 `0001` (Philippe Simons), `0060` (Noxwell), `0065` (sunshineinabox): ROCKNIX's own `panel-hx83112a.c` for the Air X MQ66 — created, then given per-panel data with Air X and Retroid Duo Lite variants, then the Air X's staged power sequence. The upstream `panel-himax-hx83112a.c` is a different driver and stays off, as in ROCKNIX's config. | never |
| `0570` `0575` `0585` | community | ROCKNIX SM6115 `0002` `0003` `0005` (Philippe Simons): MANGMI Air X panels BM5460BB1 / TD4310 and the Air Y's GH7005. At ROCKNIX `next`'s 2026-10-06 state. Never posted. | never |
| `0685` | community | ROCKNIX SM6115 `0012` (Philippe Simons): pm6125 PWM on the LPG driver + its dtsi node. | never |
| `0737` `0739` | community | ROCKNIX SM6115 `0011` `0046`: Himax HX83112A SPI touchscreen (Air X MQ66); Hynitron CST3530 in the cstxxx driver (Air Y), behind the Odin2 Mini's `0720`. | never |
| `0760` | community | ROCKNIX SM6115 `0009` (Philippe Simons): MANGMI Air X serdev MCU joypad. Makefile hunk re-rolled around `0755`. | never |
| `0625` `0798` | community | ROCKNIX SM6115 `0047` `0020`: pwm_bl brightness-scale (the Air Y's 511-step backlight), pwm-vibra minimum duty cycle. | never |
| `0841` `0842` `0843` `0861` | community | ROCKNIX SM6115 `0051` `0053` `0054` `0052`: ES8326 sysclk from MCLK / vdd supply / stereo controls; MI2S jack detection in qcom common. | never |
| `0855` | community | ROCKNIX SM6115 `0080`: let the LPASS rx/tx/va/wsa macros and the SoundWire controller idle. v7.3 took the runtime-PM half (references in the clock-gate paths, autosuspend after probe) for all four macros, so from 7.3.1 this is only the system-sleep handlers that run the runtime paths for a device still active at suspend. Power only, not a boot requirement; the Air X instantiates the rx/tx/va macros (`qcom,sm6115-lpass-*-macro`) and wires the VA macro into `VA_CODEC_DMA_TX_0`. Found by the 2026-10-09 audit after the first port skipped it. | never |
| `0215` | community | ROCKNIX SM6115 `0004` (Philippe Simons): the Adreno 610 **speed-bin 221** in the a6xx catalog, with the stock sm6115 GPU OPP table (bin masks widened, the 1050 MHz point and the rpmpd turbo_high level it needs, gpucc). Without it the Air X boots with `missing support for speed-bin: 221` followed by `_opp_is_supported: Invalid opp-supported-hw property (-22)`: no valid GPU OPP, and turnip finds no usable device. Deferred as perf on the first port, promoted by the first boot (2026-10-10). | never |
| `0285` | community | ROCKNIX SM4450 `0001`: Adreno 613 a6xx catalog entry. Never posted. | when the A613 catalog lands upstream |
| `0286` | community | ROCKNIX SM4450 `0015`, SCOPED HERE to the A613: the original skipped the SPTPRAC read on every GPU but A630/A615, which reaches every a6xx/a7xx board of the combined kernel through devcoredump. | with `0285` |
| `0287` | community | upstream `0286`. André Braga, andrebraga ROCKNIX SM8750 `Kernel_7.3` `2291` + its binding `2290` @ `1c1c374bdc`, not posted. The GMU voted DDR for the GPU OPP's bandwidth, so DDR rose only with the GPU clock; it now floats the vote within a per-OPP `qcom,opp-peak-kBps-range` from the GBIF traffic counters, as downstream gpubw_mon does, and votes AB as the measured traffic. Rebased onto `0266` (Nova-Deck `0265`) instead of upstream's "Fix stale boot up BW vote" (his `2011`); context regenerated here over our `0265` (gpu_busy_percent) and the A613 `0285`/`0286`, code unchanged. The bandwidth-table rewrite runs on every bcms GPU (A740/A750 too), and only A8xx measures. Runtime switch: `msm.gpu_bus_dcvs`. HW A/B owed; SM8550/SM8650 GPU regression check owed. | when upstreamed, or dropped on a failed A/B |
| `0288` | posted | Akhil P Oommen, "drm/msm/a6xx: Add HFI support for CLX feature" `<20260516-a8xx-clx-support-v1-1-62508bf651ac@oss.qualcomm.com>` (msm-next, v7.4) + "drm/msm/a6xx: Request CLX enable from secure world" `<20261024-assorted-fixes-oct-v1-7-2977f974ddb7@oss.qualcomm.com>` (posted, reviewed), via andrebraga ROCKNIX SM8750 `Kernel_7.3` `2295` + `2296`. GPU peak-current limiting on the GX/MX rails; inert without a catalog table (`0289`). | when both are in the pinned release |
| `0289` | community | André Braga, andrebraga ROCKNIX SM8750 `Kernel_7.3` `2297` @ `1c1c374bdc`, not posted, body identical. A830 CLX catalog table, values from downstream kgsl gen8_0_0. A current limiter: may cap peak GPU clocks, so it is in the A/B. | when upstreamed, or dropped on a failed A/B |
| `0398` | community | ROCKNIX SM4450 `0009`: SM4450 DPU catalog + MDSS + UBWC. Rebased on `0340`, which already carries the identical `rotation_v201_formats`. Never posted. | when upstreamed |
| `0399` | posted | upstream `0397`. Michael Burch v2 `<20261013172703.12273-1-me@michaelburch.net>`, Cc stable, body byte-identical, via andrebraga ROCKNIX SM8750 `Kernel_7.3` `2020`. `frame_pending` counted after kickoff could leak, keeping a video-mode encoder out of idle and its vsync interrupt on. The commit's BW-release leg is inert here: `enable_bw_release` is a debugfs knob, off by default. | when merged |
| `0536` | community | ROCKNIX SM4450 `0010`: per-board init tables and the RP Classic (Rev Q, G1392) modes in the upstream chipwealth-ch13726a driver (not `0535`'s DDIC driver). Never posted. | never |
| `0590` | community | ROCKNIX SM4450 `0050`: FocalTech FT7131M panel (Anbernic RG 55G1). Kconfig/Makefile re-placed. Never posted. | never |
| `0690` | community | ROCKNIX SM4450 `0023`: PM6450 PWM in leds-qcom-lpg; of_match row re-placed after `0685`. Never posted. | when upstreamed |
| `0691` | community | ROCKNIX SM4450 `0060` (sunshineinabox): inversed PWM polarity in leds-qcom-lpg (the RG 55G1 backlight). Opt-in by polarity: was -EINVAL. Never posted. | when upstreamed |
| `0711` | community | ROCKNIX SM4450 `0061`: edt-ft5x06 follows the panel power state, engaged only when the touch node names a `panel` (no other board of ours does). Never posted. | never |
| `0871` | retroforge | Replaces ROCKNIX SM6115 `0037` (strict S16_LE on every stream), scoped to the `qcom,qrb4210-rb2-sndcard` compatible so it coexists with `0870`. | never |
| `0872` `0874` | posted | ROCKNIX SM6115 `0042` `0045`, Val Packett: sm8250 codec_fmt on all codec DAIs, v2 6/6 `<20260506204142.659778-7-val@packett.cool>`; MI2S AFE port clock shutdown, v1 5/6 `<20260423050801.210840-7-val@packett.cool>` (ours is closer to v1 than v2 5/6 `<20260506204142.659778-6-val@packett.cool>`). Apply verbatim on `0870`/`0871`. | when merged |
| `0873` | community | ROCKNIX SM6115 `0044` (credited to Val Packett there): sm8250 QUATERNARY MI2S startup cases. Not found in Val's postings. | never |
| `0896` | posted | ROCKNIX SM6115 `0041`, Val Packett: q6afe clk vote response type mismatch. Applies after `0895`. RESEND v2 (2026-10-16) is in linux-next as `f3c7bee984`. | at the bump that carries `f3c7bee984` |
| `0925` | community | ROCKNIX SM6115 `0027` (Philippe Simons): CellWise CW2215/2217/2218 gauge. | never |
| `0945`-`0965` | community | ROCKNIX SM6115 `0028`-`0032` (2026-10 state): bq256xx SGM41515 chip info, init reset + DT limits, OTG VBUS regulator, IINDPM by Type-C precedence (replaced the source-type version), software JEITA. | never |
| `1015` `1016` `1017` | community | ROCKNIX SM6115 `0021` `0078` `0079`: Wi-Fi/BT addresses from the SoC serial (spycat88); ath10k WCN3990 firmware workarounds (incl. the per-board firmware-name directory the vendor board files live in) and the STA vdev-start deferral. `1016` is entirely Malte Schababerle's two posted patches (`<20260322124822.230492-2-m.schababerle@gmail.com>`, `-3-`, 2026-03-22, not merged), squashed by Noxwell. | never |
| `1018` | retroforge | Written here 2026-11-01 from an Air X boot log on 7.3.1. v7.3's core HELLO (Chris Lew, "net: qrtr: Send HELLO message on endpoint register") drops packets until our HELLO is out, so the name service's answer to an early remote HELLO is lost and the modem never sees rmtfs/tftp (watchdog reset 40 s later, Wi-Fi late or absent). Flushes the pending HELLO work instead of dropping. Not posted; no upstream fix found. | when mainline stops losing announcements sent before the core HELLO |
| `1019` | retroforge | Replaces ROCKNIX extra-firmware PR #14, which set the `mfp` feature in its WCN3990 `firmware-5.bin` copies. Follows qcacld-3.0 `wma_send_peer_assoc()` and ath11k/ath12k, which flag every PMF peer; every stock WCN3990 firmware dumped (WLAN.HL.2.0 to HL.3.4.3) has PMF offload. Never posted; generic, worth sending. | when upstreamed |
| `1020`-`1023` | posted / community | ROCKNIX SM6115 `0023`-`0026`: WCN3950 Bluetooth. `1020` is a squash of Manivannan Sadhasivam's pwrseq `is_fixed` + hci_qca BT_EN detection series (posted; not in v7.3, which renamed `pwrseq_power_on/off` to `pwrseq_enable/disable` under it), minus ROCKNIX's `is_fixed` on the WCN3990-family BT target, which the posting lacks (a BT_EN-less WCN3950 then never powered off); the other three are ROCKNIX's. | `1020` when merged; rest never |
| `1045` `1051`-`1056` | community | ROCKNIX SM6115 `0022` `0055`-`0059` `0067`: dwc3-qcom VBUS override deferred over suspend; fusb302 TX completion / collision / TX_START / PD 3.0 on the AW35615 / reset on shutdown, tcpm requeue on -EAGAIN. | never |
| `1090` | community | ROCKNIX SM6115 `0034`: GENI UART IRQ masked over system suspend. | never |
| `1170` | community | ROCKNIX SM6115 `0016`: MPM wake controller. (`0015`, the sm6115.dtsi venus node that was our `1165`, is in v7.3 and was deleted at the 7.3.1 bump.) ROCKNIX dropped its thermal-labels patch on 2026-10-05 and so did we. | never |
| `0761` | community | ROCKNIX SM8750 `0058`, upstream `0760` (our `0760` is the MANGMI Air X serdev joypad): clean-room reimplementation of the stock `tc_mcu_joystick.ko` — the AYANEO-family SPI register-map MCU gamepad (regs 0x8080-0x8088, ASCII "AYANEO" magic) on the KONKR Pocket FIT Elite. Protocol unrelated to the Mangmi SPI joypad (`0755`), reuse investigated and rejected 2026-10-19. | never |
| `0762` | community | ROCKNIX SM4450 `0053`: singleadc-joypad for the RG 55G1 (GPIO buttons + SPI stick MCU). Makefile re-placed. Never posted. | never |
| `0763` | ours | REWRITE of ROCKNIX SM4450 `0055` (batocera): same MCU frame protocol (Daniel Martin's decode of the stock `single_mcu_joy.ko`), but the 16 ring segments are multicolor LED class devices `rgb:l1..l8` / `rgb:r1..r8` (mode 5 only) instead of the stock-named sysfs knobs, and one mutex covers the frame and its transfer. HW-OK RG 55G1 2026-10-27. | never |
| `0764` | community | ROCKNIX SM4450 `0058` (batocera): stick LEDs parked across suspend, reworked onto our `0763` (a parked flag under the frame lock). | never |
| `0765` | community | ROCKNIX SM8750 `0069`, STRIPPED of its RGB-LED half (multicolor LED, `effect` sysfs, LED PM notifier + `tx_inhibited`): retroforge has no stick-ring LED surface and no kernel sleep. Buttons + key-remap sysfs only. Armada `0069a` (same driver also binds the SM8650 Pocket FIT MCU, whose Menu/Equals/K + LC/RC may be dead on our KPF today) is NOT taken — pending the KPF hardware check; it also carries a `gamepad_mode` attr because it displaces `0980` on that board. | never |
| `0770` | posted | Caleb Connolly v7 `<20221015172915.1436236-3-caleb@connolly.tech>`, stalled since 2022. Fenglin Wu's PMIH driver (v7, 2026-08-28) uses the same file and the generic `qcom,spmi-haptics` compatible. | when David Heidelberg's pmi8998 haptics lands |
| `0775` | community | spycat88, ROCKNIX SM8250 `0013`. | never |
| `0776` | community | gennro, Kettle Linux `1380`, byte-identical body. Never posted. Fixes `0750`'s RX stack overflow and frame loss, and its ops-after-open oops. | with `0750` |
| `0780` | community | CAF/CLO downstream `qcom-hv-haptics`, HAP530/HAP_CFG_V5 generation, via ROCKNIX SM8750 `1000` (issue #122; replaced the HAP525-only generation from ROCKNIX SM8550 `1000`, which rejected the Odin 3's PMIH0108 block at probe). Kconfig hunk regenerated against this tree; the per-play boost-status debug line demoted from dev_err to dev_dbg (it logged twice per rumble event). | never |
| `0781` | community | armada `1001-input-qcom-haptics-update-assign-str`: Linux 7.1's one-argument `__assign_str()` in the driver's tracepoint header. | with `0780` |
| `0785` | community | ROCKNIX SM8750 `1001`, the V5 rebase of the old SM8550 `1002` sine support; body regenerated here against `0780` (same hunks, git-diff format). | with `0780` |
| `0790` | community | Gianni Spadoni's rsinput FF bridge as rebased by armada (`1002-input-rsinput-sm8750-ff`), byte-identical: gated on the `rumble-haptics` DT property (set in `qcs8550-ayn-common.dtsi` + `cq8725s-ayn-common.dtsi`) so a combined kernel does not hand FF to rsinput boards without the Qualcomm haptics block. ROCKNIX's own SM8750 `1002` has a malformed final hunk — do not take it. | with `0780` |
| `0791` | retroforge | Written here for `0745`, after Kettle Linux `1100` (armada `0515`) and `1380`; resyncs a byte on a bad checksum instead of skipping the claimed frame length. Never posted. | with `0745` |
| `0795` | community | armada `1003`, rsinput struct + suspend hunks regenerated: fixes the reproduced "scheduling while atomic" hard-lock on rumble stop (issue #128; ROCKNIX still carries the bug). Bridge is mutex-serialized process context; rsinput playback defers to a work item. The original's rsinput dev-PM suspend hunk is dropped — our rsinput has no PM ops and sleep is a userspace cgroup freeze. Supersedes gh123man's deferral (ROCKNIX PR #3116) this slot used to carry. | with `0780` |
| `0796` | community | armada `1004` (virtudude), byte-identical. A zero-amplitude update erases the effect at once instead of braking 5 s later; balances the V5 driver's transient runtime-PM reference on in-place gain updates. | with `0780` |
| `0797` | community | ROCKNIX SM4450 `0059` (Jacob Cook): rsinput `digital-triggers`, opt-in per DT. Rebased on `0745`/`0790`/`0791` and after `0795`/`0796`, which touch the same file. | never |
| `0799` | community | ROCKNIX SM8750 `0508` (tiopex), rebased on `0745`/`0790`/`0791`/`0797`: rsinput re-runs its MCU reset and framed-report setup on resume. Adds about 300 ms to an AYN board's resume. SM8550 suspend, 2026-11-11. HW: one 60 s RTC-woken deep suspend resumed on the Retroid Pocket Nova (7.3.3) with this in; no A/B without it. | never |
| `0805` | retroforge | Written here, after the downstream DP codec's startup cable check (msm-4.19 techpack/audio `msm_ext_disp_audio_codec_rx_dai_startup`). Adds the `dp_audio_startup` msm_dp never implemented, so on SM8250 only (`qcom,sm8250-dp`) an unplugged DP open fails before q6afe starts port 0x6020 (a 3 s no-reply timeout there). Never posted. | when upstream msm_dp refuses an unplugged DP audio open itself |
| `0820` | retroforge | Nova-Deck, written at their 7.3.1 bump (2026-10-30). Sets `mi2s_bclk_enable` in the sm8750 card data, as mainline already does for sm8450/8550/8650, so the per-DAI `bclk` (`dai@12` under `&q6apmbedai`) is driven for the Odin 3 and FIT Elite amps. Replaces the old `0820` (card-level `i2s_clk`, PRIMARY only; also ROCKNIX SM8550 `0036`) + `0825` (ROCKNIX SM8750 `0060`, widened to every MI2S BE), superseded by mainline `088c4404b3d7` + `cc8495c1d45a`. Never posted. | when mainline's sm8750 card data enables the MI2S bclk |
| `0826` | retroforge | Our side of ROCKNIX SM4450 `0030` (Philippe Simons), since 7.3.1 a delta on mainline's MI2S `hw_params`: codec format on every codec DAI of the link (the two SM4450 amps), RP Classic mono fixup by card name, and BCLK counted over at least two slots so that mono stream keeps 1536000. The clock itself is `dai@93` under `&q6apmbedai`. | when mainline formats every codec DAI and the RP Classic runs stereo |
| `0830` | retroforge | Teguh Sobirin's AYN series; its firmware-name part went upstream as `fc1fbafc18a0` (v7.1). Remainder never posted. | never |
| `0831` | community | ROCKNIX SM4450 `0031` (sunshineinabox), adapted from Val Packett's aw88261 series: PLL from hw_params/set_fmt. Applies to every aw88166 board (Odin 2 family, Thor, Thor Lite, Odin 3) — HW check owed there. | when the aw88261 series lands and is ported |
| `0832` | community | ROCKNIX SM4450 `0032`: aw88166 log spam to dev_dbg. | with `0831` |
| `0833` | community | ROCKNIX SM4450 `0033`: aw88166 fade in/out removed. | with `0831` |
| `0835` | community | ROCKNIX SM8750 `0059`: aw88395-lib skips monitor sections in V1 ACF parse — the Elite's aw88261 calibration blob carries them. | when upstreamed |
| `0840` | community | Luke Johnson, ROCKNIX `0200`. Never posted; generic, worth sending. | when upstreamed |
| `0845` | community | seilent, Kettle Linux `1230`, body byte-identical. Never posted; generic, worth sending. | when upstreamed |
| `0846` | retroforge | The `0845` fix for `wcd939x`, whose ramp error has the same shape (and a right ramp that inherits the left value). Never posted; generic, worth sending. | when upstreamed |
| `0847` | retroforge | The `wcd939x` HPH and ADC volume dB scales were wrong (`line_gain` 0 dB + 0.07 dB steps, i.e. 1.4 dB over 21 steps); declared as `wcd938x` does: -30..0 dB in 1.5 dB steps, ADC 0..30 dB. Never posted; generic, worth sending. | when upstreamed |
| `0848` | community | ROCKNIX SM8750 `0063`: wcd939x routes the USBSS analog-audio switch on integrated-jack insert. | when upstreamed |
| `0849` | community | ROCKNIX SM4450 `0056` (batocera): wcd937x HPHL/HPHR Volume dB scale (TLV only, raw values unchanged). | when upstreamed |
| `0850` | retroforge | Also ROCKNIX `0612`. Related RFC: Jorijn van der Graaf `<20260705033830.305907-1-jorijnvdgraaf@catcrafts.net>`; Srinivas reproduced the missing clock but no fix yet. 2026-10-19: folded in armada `0613`'s scoping — the prepare-time start now applies to playback MI2S DAIs only, so it cannot change prepare/trigger ordering for unrelated LPASS DAIs (ours started every playback DAI early). 2026-11-02: Senary MI2S added, for the RG 55G1's aw88166 pair. | when upstream fixes MI2S clocking before graph start |
| `0852` | retroforge | ROCKNIX SM6115 `0310`: q6prm takes a GPR basic response as the reply, as q6apm already does. Never posted. | when upstreamed |
| `0856` | community | ROCKNIX SM8750 `0072`: lpass-rx-macro HPH PCM mode. First of the HPH PCM HiFi trio (here `0856`/`0858`/`0859`; upstream `0856`-`0858` — our `0857` is the Kettle stale-jack patch); benefits every wcd939x board, not just SM8750. | when upstreamed |
| `0857` | community | Kettle Linux `1240` (written for the KONKR Pocket FIT), body byte-identical. Never posted. Preventive: no stale-jack report on record here. | when upstreamed |
| `0858` | community | ROCKNIX SM8750 `0073`, upstream `0857`: wcd939x HPH PCM HiFi mode. | with `0856` |
| `0859` | community | ROCKNIX SM8750 `0074`, upstream `0858`: soundwire qcom PCM data-port format enable. | with `0856` |
| `0860` | retroforge | Written here 2026-11-08 on the RG 55G1 (7.3.1). Since push-pull, an open playback stream woke the SoC within ~10 ms of every deep suspend: the DSP's watermark events arrive over GLINK, and the qcom DPCM links are `ignore_suspend`, so nothing stopped the graph. q6apm-dai's own sleep callback now stops every started graph (push-pull, and capture's read re-queue), outside the stream lock; on resume a running stream reports an xrun and user space prepares it again. HW-tested on the 55G1 with playback running (power-key wake, playback back after wake); capture and the prepared-stream resume path are untested. Never posted; generic, worth sending. | when upstreamed |
| `0862` | community | ROCKNIX SM4450 `0039`, SCOPED HERE to SM4450: link manager EE0 so the clock-stop wake reaches the CPU. The original flipped SWRM_EE_CPU for every v1.7/v2+ controller, i.e. every SM8550+ board; here the EE is chosen per machine. | never |
| `0863` | community | upstream `0859`. Anze, ROCKNIX SM8750 `0603` (armada carries the same code), body byte-identical. Never posted. A runtime-suspended wcd939x lets the SoundWire link stop its clock, so MBHC's interrupt never reaches the host: `pm_runtime_forbid()` both slaves while a jack is set. Replaces the SM8650-only udev rule, which never covered SM8750. | when upstreamed |
| `0864` | retroforge | Written here 2026-11-09 on the Pocket FIT (7.3.3). The controller did not survive an unbind/re-probe, which `0988` does on every ADSP stop: the IRQ is requested rising-edge while DT says level-high, so the kept mapping failed the next probe (`type mismatch, failed to map hwirq`), now disposed on unbind; runtime PM was never disabled, so the next probe resumed a half-set-up bus and oopsed in `sdw_bus_exit_clk_stop()`, now `devm_pm_runtime_enable()`; and the DAI names were devm strings the card keeps pointers to, so the card never rebound, now static. Never posted; generic. | when upstreamed |
| `0865` | posted | Marek Szyprowski v1 `<20261022090923.769464-1-m.szyprowski@samsung.com>`, applied to broonie `sound for-7.4` as `c80f86ed857e`; no Cc: stable. Requests the shared powerdown line asserted so the `GPIO_SHARED` proxy's default is powerdown and any one powered amp holds it de-asserted — the Pocket Max deadlock (both amps on TLMM 127). Upstream's 4th hunk dropped: its `regcache_sync()` error path is not in 7.2. Replaced ROCKNIX `0860` (`GPIOD_FLAGS_BIT_NONEXCLUSIVE`), inert since `ARCH_QCOM` selects `HAVE_SHARED_GPIOS` and gpiolib proxies the line itself; mainline dropped that flag too (`d01fbee5c0d3`). | v7.4 |
| `0870` | community | ROCKNIX. Effectively reverts `89be3c15a58b`. | never |
| `0880` | community | Teguh Sobirin, ROCKNIX `0012`. | never |
| `0890` | community | Daniel Martin (Batocera), ROCKNIX `0300`. Never posted; generic, worth sending. | when upstreamed |
| `0893` | retroforge | Written here for issue #94: `q6core_is_adsp_ready()` reported "ready" on any non-answer; only `ADSP_EUNSUPPORTED` means that now, and it polls every 50 ms as downstream does. Never posted. | with `0895` |
| `0895` | retroforge | Written here for issue #94, after the downstream `q6core_is_avs_up()` gate and `afe_callback()` vote handling. Needs `0893`. Never posted. | when upstream gates q6afe on DSP readiness |
| `0897` | posted | Mohit Sharma, "Fix GPR callback registration race during probe" 1/2 + 2/2 `<20261022144130.2443667-2-mohit.sharma@oss.qualcomm.com>` (+ `-3-`), Cc stable, via andrebraga ROCKNIX SM8750 `Kernel_7.3` `2039` + `2128`. Should end the `CMD timeout for [1001021]` 5 s stall in q6apm probe, unproven here. Replaced 2026-11-08 our `0853` (sunshineinabox, the same `apr.c` change without the q6apm/q6prm guards; said to end the stall on our AudioReach boards). | when merged |
| `0910` | community | ROCKNIX `0011`, with the charger-status fix from ROCKNIX PR #3396 (the SMB5 `BATTERY_CHARGER_STATUS_1` enum and the BAT_OV bit; ours had SMB2's) and the pm8150b float-voltage scale plus the charge current from ROCKNIX PR #3382 (xenocideend). Charger alternative posted: `qcom_smbx` SMB5 v4 `<20260820-submit-qcom-smbx-send-v1-v4-*@snyders.xyz>` (under review). | charger: when SMB5 lands; FG: never |
| `0915` | community | gennro, Kettle Linux `21-sm8250/0116`, body byte-identical: the PM8150B fuel gauge (`0910`) reports `charge_now` (capacity x design) and `charge_full` (design), so time-remaining from charge / current is no longer 0. | with `0910` |
| `0920` | community | ROCKNIX `0063` (sunshineinabox). Never posted. | never |
| `0930` | posted | Jan-Michael Brummer `<20260829054546.86210-2-jan.brummer@tabos.org>`. Konrad asked for `CHARGE_EMPTY` gating; v2 expected. | when merged |
| `0940` | posted | Same series, `-3-`. | when merged |
| `0941` | posted | Joonhoe Kim, "power: supply: qcom_battmgr: Allow setting the USB input current limit" `<20261007123939.1679-1-26rote@gmail.com>` (2026-10-07), carried by ROCKNIX SM4450 `0051`. Ours also caches the new limit and does not reject negative values. | when upstreamed |
| `0942` | community | ROCKNIX SM4450 `0052`: battmgr reports the USB adapter type. | when upstreamed |
| `0943` | posted | upstream `0945`. Xu Qianhui, "power: supply: qcom_battmgr: do not report power_now on SM8750" `<20261027132949.242685-1-xiaqinghuan@mail.ustc.edu.cn>`, via andrebraga ROCKNIX SM8750 `Kernel_7.3` `0086`: SM8750 gets its own variant + battery descriptor without POWER_NOW (the QBG firmware publishes its max-load value there). Probe hunk regenerated around our `0930`. The peer's companion battery RENAME (`0503`) is deliberately NOT taken. | when merged |
| `0951` | mainline | upstream `0950`. Georgi Djakov `<20260928132823.1426513-1-djakov@kernel.org>`, `51c262cf2aa9` in v7.4-rc1, no stable tag, body byte-identical, via andrebraga ROCKNIX SM8750 `Kernel_7.3` `2216`. `temp_map` was indexed as a row when it points at the whole map: out-of-bounds read at every PMIC temp-alarm probe. | v7.4 |
| `0970` | community | ROCKNIX `0500`. A hack. | never |
| `0975` | posted | Anandu Krishnan E, "misc: fastrpc: fix context leak and hang on signal-interrupted invoke" v3 `<20261002-anandu-fastrpc-interrupted-invoke-v3-v3-1-31e90439d2ba@oss.qualcomm.com>` (Fixes 387f625585d1, Cc stable), rebased onto 7.3.3. `put_work_scheduled` set with `xchg()` instead of under `fl->lock`, as armada-os `529261d` did: `fastrpc_rpmsg_callback()` runs in hard IRQ. A suspend interrupted the sensors listener's pending DSP call and the retry re-sent it, so reopening the sensors after resume crashed the ADSP (armada). | when merged |
| `0980` | retroforge | Never posted. | never |
| `0985` | community | ROCKNIX SM4450 `0003`: SM4450 ADSP + WPSS in qcom_q6v5_pas. Never posted. | when upstreamed |
| `0986` | community | ROCKNIX SM4450 `0008`: SM4450 in arm-smmu-qcom. Never posted. | when upstreamed |
| `0987` | community | armada `0556` (Noahcdls, armada-os `cacf1e3`; Kettle Linux carries it unchanged as `1451`). Never posted. The SM8750 SoCCP in qcom_q6v5_pas: reloads the unit's `soccp.mbn` (PAS 51) over the bootloader's early image, and holds a 1200 kBps aggre2 NoC to DDR vote from probe until the TCSR D-state register shows D3 (checked at handover and in `pm.prepare`). Modelled on upstream's Kaanapali SoCCP (Jingyi Wang, merged for 7.3), which attaches instead (`early_boot`); SM8750's early image ignores SMP2P. Context regenerated over our `0985`; ours adds one line, `recovery_disabled` for the SoCCP, as the vendor kernel (CodeLinaro `kernel.lnx.6.6.r1-rel`) runs it, since the vote is not retaken after a crash. armada measured a FIT Elite asleep at 14 mA with CX shutdown and DDR low power, against 188 mA; HW check owed here. | when an upstream SM8750 SoCCP lands |
| `0988` | retroforge | Written here 2026-11-09 on the Pocket FIT (7.3.3); written as `0987`, renumbered and its context regenerated over the SoCCP `0987` when both landed on main. Any ADSP stop (crash recovery, debugfs crash, sysfs stop) reset the FIT seconds later: fw_devlink's dangling-consumer pickup makes the remoteproc the supplier of the LPASS macros and LPI pinctrl (their q6prm clocks live under the ADSP), so they stayed bound while q6prm went away and TrustZone powered LPASS down. A PAS subdevice now releases every device clocked from under the remote after glink stops and before the shutdown call, and attaches them again on start. Upstream has the same report ("fw_devlink: incorrect ancestor fallback for intermediate bus topologies", Qualcomm, 2026-07-01) and only a proposed driver-core change, which would not re-probe the macros after the restart. Never posted. | when fw_devlink or the LPASS drivers handle ADSP restart upstream |
| `0991` | community | ROCKNIX SM8750 `0026` + `0027` squashed (Teguh Sobirin), upstream `0990` (our `0990` is the pm8150l LCDB regulator): the CQ8725S SoC-ID (SM8750 gaming SKU, AYN Odin 3) in dt-bindings + socinfo. Posted by Aaron Kling with Teguh as author: `<20260605-cq8725s-soc-id-v1-1-bb1ef93de649@gmail.com>`, `-2-`. | when the ID lands upstream |
| `0992` | community | ROCKNIX SM4450 `0005`: SM4450 domains in qcom_pd_mapper. Never posted. | when upstreamed |
| `0993` | community | ROCKNIX SM4450 `0004`: PM6450 RPMh regulators. Never posted. | when upstreamed |
| `0994` | community | ROCKNIX SM4450 `0022`: RPMh PBS trigger resource type. Never posted. | with `0995` |
| `0995` | community | ROCKNIX SM4450 `0060`: PM6450 SD LDOs switched through PBS. | never |
| `1002` | community | ROCKNIX SM8750 `0039`: ath12k WCN7860 hardware definition. The chip is not in upstream ath12k (nor its firmware in linux-firmware — blobs live in qcom-firmwares). | when WCN7860 lands upstream |
| `1003` | community | ROCKNIX SM8750 `0040`: send the QDSS config when the firmware signals CNSS_QDSS_CFG_MISS (`qdss.cfg` ships with the WCN7860 firmware set). | with `1002` |
| `1004` | community | ROCKNIX SM8750 `0041`: do not take the QDSS_CFG_MISS path on chips whose firmware does not want it. | with `1002` |
| `1006` | community | ROCKNIX SM8750 `0045`: Bluetooth qca support for WCN7860 (`qca/gngbt*` blobs in qcom-firmwares). | when WCN7860 BT lands upstream |
| `1007` | posted | Birk Skyum v2 `<20261014180201.57109-1-birk.skyum@pm.me>`, Cc stable, body byte-identical, via andrebraga ROCKNIX SM8750 `Kernel_7.3` `2147`. In-band sleep state survived power-off, so a Bluetooth off/on inside 2 s ended in `-110` and a controller crash dump. | when merged |
| `1010` | community | Edouard Durand. Never posted; the bug is still in v7.3-rc4. | when sent and merged |
| `1011` | posted | Runyu Xiao, "[PATCH v4 ath-current] wifi: ath12k: convert scan timeout to wiphy delayed work", via Kettle Linux `1280`, body byte-identical: stop (wiphy mutex held) synchronously cancelled a scan-timeout worker that waits for the same mutex — a deadlock. | when it lands in 7.2.y |
| `1024` | posted | Shenghan Gao `<20260715065218.41232-1-gsh20040816@gmail.com>` (ath-current), via armada `1021`, upstream `1021` (our `1021`-`1023` are the WCN3950 Bluetooth set): ath12k single-pdev frequency-range fix, under our `1010`/`1011` scan stack. | when upstreamed |
| `1025` | community | armada `1022`, upstream `1022`: split WCN7860 scans by firmware-reported ranges. | with `1002` |
| `1026` | community | armada `1023`, upstream `1023`: protect TX during associated-range scans. | when upstreamed |
| `1027` | posted | Baochen Qiang `<20261029-ath12k-mcs15-v1-1-3bcfab101f00@oss.qualcomm.com>`, accepted to ath-current, body byte-identical, via andrebraga ROCKNIX SM8750 `Kernel_7.3` `2247`. WCN7850 firmware cannot TX EHT-MCS15; with a peer advertising it, TX stops for minutes while still associated. | when merged |
| `1028` | posted | Birk Skyum `<20261020213505.31624-1-birk.skyum@pm.me>`, body byte-identical, via andrebraga ROCKNIX SM8750 `Kernel_7.3` `2271`. A vdev restart counted as a start, so every later station-stats request blocked 3 s under the wiphy lock. | when merged |
| `1031` | community | upstream `1024`. André Braga, andrebraga ROCKNIX SM8750 `Kernel_7.3` `0513` @ `1c1c374bdc`, not posted, body identical (offsets only). `ath12k_pci_power_down()` keyed on INIT_DONE, which stays clear while firmware boots, so a device removed mid-boot or mid-recovery kept MHI up; the next probe oopsed in `mhi_queue` through the stale QRTR endpoint. Tracks the power state with its own flag. | when upstreamed |
| `1032` | community | upstream `1029`. André Braga, andrebraga ROCKNIX SM8750 `Kernel_7.3` `0511` @ `1c1c374bdc`, not posted. Recovery finished a RUNNING scan as completed, so userspace connected off partial results while the firmware was down; it is now ABORTING. Context regenerated on our `1011` (upstream `1015`); composes with our `1025` (upstream `1022`) (noted under the patch's `---`). | when upstreamed |
| `1029` | retroforge | Written here 2026-11-01 from a traced Air X boot: a WCN3950 from cold rails is up ~130 ms after its power-on pulse (its CTS pulses then), past hci_qca's 100 ms, so the first version read was lost and every boot waited out the 2 s timeout for the retry. 200 ms for the WCN3950 only. Never posted. | if upstream waits long enough |
| `1030` | community | spycat88, ROCKNIX `0071`. A hack. | never |
| `1040` | community | Kars Mulder's Linux-Pollrate-Patch via ROCKNIX `0506`. | never |
| `1042` | community | Anze, ROCKNIX SM8750 `0509`: restore the pre-`0c8ee850572` ucsi behaviour — clear the USB role when the partner advertises no USB data — on ports without the USB4_IMPLIES_USB quirk (our pmic_glink UCSI ports on every SoC). Peer motivation is a suspend hard-hang we cannot hit; the stale role on charger-only partners is wrong regardless. | when the upstream regression is fixed |
| `1043` | community | ROCKNIX SM4450 `0049`: ucsi_glink UCSI_DELAY_DEVICE_PDOS quirk for SM4450. | when upstreamed |
| `1044` | community | armada `0509` (was the ungated ROCKNIX SM8750 `0509` (soc), 2026-10-19): pmic_glink_altmode defers until the typec mux/switch is ready — gated to SM8750, whose wcd_usbss supplier registers late. Ungated it black-screens every board whose DT declares no mode-switch (the AYANEO SM8550 family): the permanent defer blocks the DP aux bridges and the msm DRM aggregate never binds. | when upstreamed |
| `1050` | community | Jacob Cook, ROCKNIX `5e52df2b9fba` (SM8250 `0018`, merged with PR #3382), written from the vendor smb5 `smblib_set_prop_pr_swap_in_progress` sequence. Never posted. | when mainline `qcom_pmic_typec_port` handles PR swap termination |
| `1057` | community | ROCKNIX SM8750 `0043`, upstream `1052` (our `1052`-`1056` are the fusb302/tcpm set): power-sequencing qcom-wcn entry for WCN7860. | when WCN7860 lands upstream |
| `1058` | community | ROCKNIX SM8750 `0042`, upstream `1053`: PCI pwrctrl-pwrseq match for WCN7860. | with `1057` |
| `1059` | community | ROCKNIX SM8750 `0606`, upstream `1056`: the 7.2 merge window rewrote `clk_regmap_phy_mux_ops` (enable/disable -> rate ops) and no caller was added, so the PCIe pipe-clk mux never leaves XO; qmp-pcie now does `clk_set_rate(ULONG_MAX)` to select the PHY source. Without it the WCN7860 LTSSM parks in Poll.Active ("Device found, but not active"). Generic — our other SoCs' PCIe presumably survives via a different mux path; re-check on the next bump. | when upstream adds the set_rate call |
| `1060` | posted | Manivannan Sadhasivam `<20260907143349.317495-1-mani@kernel.org>`, applied to the PCI tree as `626acf6efc69`, in pci `next` (not `for-linus`), so v7.4-rc1. Not in v7.3-rc7 or 7.2.y, no Cc: stable — yet 7.2.6+ needs it. | when we pin ≥ v7.4 |
| `1061` | posted | upstream `1057`. Michael Burch, Revert "phy: qcom: qmp-pcie: Skip PHY reset if already up" `<20261013-qmp-pcie-skip-reset-revert-v1@michaelburch.net>`, via andrebraga ROCKNIX SM8750 `Kernel_7.3` `2199`: 7.3's skip-reset relies on 2/4-4/4 of the link-retention series, which did not land. | when the link-retention series lands, or the skip is reverted upstream |
| `1062` | community | ROCKNIX SM4450 `0040`: qmp-combo SM4450 USB3/DP configuration. | when upstreamed |
| `1065` | community | gennro, Kettle Linux `1390`, body byte-identical: `1060` read the first iommu-map entry before checking the property holds one. | with `1060` (check the applied `626acf6efc69` has the bound) |
| `1066` | community | armada `0514a`: `parse_iommu_maps()` in of/property walks `iommu-map` with a fixed four-cell stride, wrong for the SM8750 PCIe's `#iommu-cells = <2>` (five-cell entries since 7.2.6's `366a540432a3`) — fw_devlink then links the controller to garbage phandles. Complements our `1060`/`1065`, which fixed the same stride bug inside pcie-qcom. | when upstream honours `#iommu-cells` there |
| `1067` | posted | Krishna Chaitanya Chundru + Manivannan Sadhasivam, "PCI: qcom: shutdown" v7 1/3-3/3 `<20261029-shutdown-v7-0-3fd7a76a6991@oss.qualcomm.com>`, squashed, via andrebraga ROCKNIX SM8750 `Kernel_7.3` `0077`-`0079` (backported to 7.3 there): the link goes to L2 on shutdown/reboot. 3/3's ECAM hunk regenerated for our tree. | when merged |
| `1070` | community | gennro, Kettle Linux `1160`, body byte-identical: the lane clocks were enabled twice per runtime resume (hibern8 setup + resume) and disabled once, so the UFS clocks never gate. | when mainline guards `ufs_qcom_enable_lane_clks()` |
| `1075` | community | jaewun, Kettle Linux `20-sm8550/0207`, body byte-identical: `ufs_qcom_host_reset()` left the IRQ disabled on its error exits. | when upstreamed |
| `1081` | community | jaewun, Kettle Linux `20-sm8550/1007`, body byte-identical: `ufs_qcom_clk_scale_notify()` dropped a hibern8-exit failure and returned 0, bypassing the clock-scaling rollback. | when upstreamed |
| `1082` | community | jaewun, Kettle Linux `20-sm8550/1008`, body byte-identical: HW auto-hibern8 and SW clk-gating hibern8 both park the link; the redundant SW enter on an already-parked link can time out and mark it broken. Keeps the SW path. | when upstreamed |
| `1083` | community | jaewun, Kettle Linux `20-sm8550/1010`, body byte-identical: on `no_phy_retention` hosts (SM8550/SM8650) keep the M-PHY powered while the link is only parked in HIBERN8. | when upstreamed |
| `1084` | community | jaewun, Kettle Linux `20-sm8550/1015`, body byte-identical: RX LineCfg on for link startup, off right after, as downstream does. | when upstreamed |
| `1085` | community | gennro, Kettle Linux `1385`, body byte-identical: fixes `1083`'s PHY power count when the link state differs between clocks-off and clocks-on. | with `1083` |
| `1086` | community | gh123man, Kettle Linux `1401`, body byte-identical: recover a failed clock-gating hibern8 enter inline instead of leaving the link unusable. Kettle's `1400` (clock-gating hold across system PM) is NOT taken: we never enter system suspend. | when upstreamed |
| `1087` | community | gennro, Kettle Linux `40-kettle/1402`, body byte-identical: gives the SM8550 UFS PHY a `vdda-qref` supply at downstream's 30 mA, so LDO L1E (the QREF reference-clock buffer) stays in HPM with the screen off. Wired to `vreg_l1e_0p88` in `qcs8550-ayaneo-pocket-common.dtsi` and `qcs8550-ayn-common.dtsi`. Kettle's trigger is a PHY recalibration on resume from s2idle, which we never reach; ours is the fake suspend, which blanks the DSI PHY (L1E's only declared load) while `1083` keeps the UFS PHY powered in HIBERN8 parking. Untested on hardware by Kettle or us; needs a UFS-booted SM8550 board. | when upstreamed |
| `1088` | community | ROCKNIX SM8750 `0066`: ufs-qcom `sm8750` compatible. | when upstreamed |
| `1089` | community | ROCKNIX SM4450 `0043`: qmp-ufs SM4450 UFS PHY (the RG 55G1's UFS). | when upstreamed |
| `1091` | community | ROCKNIX SM4450 `0024` (sunshineinabox): geni UART restarts RX DMA after the read command terminates itself. Every geni-UART DMA user (BT, rsinput) — HW check owed on an rsinput board. | when upstreamed |
| `1092` | retroforge | The UFS PHY takes its reset from the host, so fw_devlink demotes host->PHY to sync-state-only, and the host probes before the PHY. It powers up regulators and clocks, defers in `ufs_qcom_init()`, then powers them down 24 ms later. On the Pocket FIT that overlaps SDC2's async probe (the boot card) and resets the board in about half the boots. With ufs-qcom blacklisted, 8/8 reboots were clean, against 4/6 resets before. This patch checks for the PHY at the top of probe instead. | when upstream orders the probe or fixes the cycle |
| `1099` | posted | Vishnu Reddy 1/2 `<20261007-fix-disable-irq-safely-v1-1-45746f9a92de@oss.qualcomm.com>`, Cc stable, body byte-identical, via andrebraga ROCKNIX SM8750 `Kernel_7.3` `2050`. `disable_irq()` under `core->lock` deadlocks against the threaded handler; this returns to `disable_irq_nosync()` as on 7.2. 2/2 is NOT taken: it reworks `core->lock` across six files and a question from the 2026-11-02 review is unanswered. | with 2/2 when merged |
| `1105` | posted | Krishna Chaitanya Chundru root_port v2 15/15 `<20260917-root_port_v2-v2-15-6272b7caae9a@oss.qualcomm.com>`, applied to qcom `arm64-for-7.4` as `bbc442a64823`. 7.3 has the `pcie0_port0`/`pcie1_port0` labels, so at 7.3.1 only the `phys` move is left. | v7.4 |
| `1110` | posted | Same series, 12/15 `<20260917-root_port_v2-v2-12-6272b7caae9a@oss.qualcomm.com>`, applied to qcom `arm64-for-7.4` as `c51818ded215`. | v7.4 |
| `1115` | community | ROCKNIX SM8250 `0005`. Never posted. | never |
| `1117` | community | Kettle Linux `21-sm8250/0110`, body byte-identical: the A650 had no interconnect path and never voted DDR bandwidth (`qnm_gpu` 0/0, Pocket Max); adds `gfx-mem` and the stock per-OPP peak votes. | never |
| `1120` | community | Our A650 overclock ladder, in the shape of Kettle Linux `21-sm8250/0111` (from ROCKNIX `9998-gpu-tuning`): 650/670 `NOM_L1`, 700 `TURBO`, 725/750 `TURBO_L1`, each with the 587 MHz DDR vote of `1117`. Replaced ROCKNIX `9998-gpu-opp-table`, which ran 650-800 MHz all at `NOM_L1`; 800 dropped. Unlike Kettle, the steps stay reachable by the governor. | never |
| `1125` | community | ROCKNIX SM8250 `0004`; nodes for the out-of-tree `0770`/`0910` drivers. | with `0770`/`0910` |
| `1130` | community | spycat88, ROCKNIX `0102`. Upstream wants `rtc_offset` in board DTS, not the PMIC dtsi. | never |
| `1135` | posted | Krishna Chaitanya Chundru "Fix wake-gpios polarity" v2 06/18 `<20260917-root_port-v2-6-0d627d0856d5@oss.qualcomm.com>`, applied to qcom `arm64-for-7.4` as `adf55ad00669`; no Fixes:/Cc: stable, so 7.3.y will not get it. | v7.4 |
| `1137` | posted | Konrad Dybcio "Straighten out CPU votes" 7/7 `<20261020-topic-icc_defines_ao-v1-7-cae8d22649ac@oss.qualcomm.com>`, body byte-identical (b4), reviewed by Abel Vesa, applied to qcom `arm64-for-7.5` as `dd68b2a63e89`. Tags the CPU→DDR path of all eight sm8250 CPUs `QCOM_ICC_TAG_ACTIVE_ONLY`, so the cpufreq bandwidth vote drops when the CPU subsystem power-collapses. 1/7–6/7 are other SoCs, not taken. Fixes: but no Cc stable. | v7.5, or 7.3.y if stable picks it |
| `1140` | posted | Konrad Dybcio RFC v1 `<20250728-topic-gpucc_power_plumbing-v1-0-09c2480fe3e6@oss.qualcomm.com>` (modified). Ulf asked for a rebase in 2025-08; never resent. | never, unless Konrad resends |
| `1145` | community | armada `0070` (virtudude). | with `0360` |
| `1150` | posted | Abel Vesa "clk: qcom: Tie CX power domains to GCCs" v5 `<20260924-qcom-tie-cx-to-gcc-v5-*-38732033e5b5@oss.qualcomm.com>`, the eight patches for our SoCs: bindings 3/7/8/9 (`clk-for-7.4`, sm8250 `98e936c9d46a`) and DTS 36/39/40/41 (`arm64-for-7.4`: sm8250 `389a0144c511`, sm8550 `df50f5c5690a`, sm8650 `108a8d51fba8`). Replaced Neil Armstrong's v1 (sm8450/8550/8650, abandoned after v2) on 2026-10-12, which also ADDS sm8250. The sm8750 binding 9 + DTS 41 were added 2026-11-02 (upstream a5808a3a; the SM8750 bring-up had missed them). The gcc driver halves 24/25/26 (`.use_rpm`, sm8550/sm8650/sm8750 — v5 has none for sm8250) are `0142`, in the clk band. | v7.4 |
| `1155` | posted | Nizat Mikayilli, "arm64: dts: qcom: sm8550: Add missing CPU7 3.36GHz OPP" v1 `<20261104-sm8550-prime-3p36ghz-v1-1-c72630265379@dxdmail.cc>`, body byte-identical (b4), applied to qcom `arm64-for-7.5` as `2fd7a169faf3`; Fixes: but no Cc stable. The cpufreq-hw LUT offers 3.36 GHz on CPU7 with no matching OPP, so the step was dropped (`cpu cpu7: Voltage update failed freq=3360000`, seen on the Pocket ACE). Konrad: a superset OPP table is fine, the LUT decides what is reachable. | v7.5, or 7.3.y if stable picks it |
| `1160` | posted | Konrad Dybcio and Taniya Das, "[PATCH v5 3/3] arm64: dts: qcom: sm8750: Add GPU clock & IOMMU nodes" `<20260305-gpucc_sm8750_v2-v5-3-78292b40b053@oss.qualcomm.com>` (2026-03-05). ROCKNIX SM8750 `0033` carries it byte-identical under the ROCKNIX name. The nodes are in linux-next. | at the bump that carries the nodes |
| `1161` | posted | upstream `1165`. Jie Zhang, "arm64: dts: qcom: sm8750: Add GPU and GMU nodes" (pakala-gpu v1 3/4), via andrebraga ROCKNIX SM8750 `Kernel_7.3` `0035`. Replaced 2026-11-03 ROCKNIX `0038` and armada's RSCC widening (old `1166`): the upstream node maps 0x6d000, which already covers RSCC at 0x50000, and the GMU no longer overlaps gxclkctl. GPU node re-placed in address order before gxclkctl. | v7.4 |
| `1162` | posted | upstream `1167`. Gaurav Kohli, "arm64: dts: qcom: sm8750: Add GPU cooling" (pakala-gpu v1 4/4), via andrebraga ROCKNIX SM8750 `Kernel_7.3` `0036`. | v7.4 |
| `1163` | posted | upstream `1168`. Krishna Chaitanya Chundru, "arm64: dts: qcom: sm8750: Add t-power-on-us property for PCIe root port" `<20260911-t_pwr_on-v1-7-c9eee197d082@oss.qualcomm.com>`, via andrebraga ROCKNIX SM8750 `Kernel_7.3` `0080`: programs T_POWER_ON for L1.2 exit. | when merged |
| `1164` | posted | upstream `1169`. Peter Chen, "arm64: dts: qcom: sm8750: Set snps,resume-hs-terminations for USB controller" `<20261019021547.1694088-3-peter.chen@oss.qualcomm.com>`, via andrebraga ROCKNIX SM8750 `Kernel_7.3` `0081`: GUCTL1 RESUME_OPMODE_HS_HOST, required with the M31 eUSB2 PHY. | when merged |
| `1165` | community | upstream `1170`. André Braga, andrebraga ROCKNIX SM8750 `Kernel_7.3` `0512` @ `1c1c374bdc`, not posted, body identical. sm8750.dtsi left uart14's CTS/RTS out of the default state (sm8550/sm8650 include it), so the WCN7860 Bluetooth UART ran 3.2 Mbaud with no flow control. Only the Elite dts overrode pinctrl-0 (dropped with this); the Odin 3 had none. | when upstream sm8750.dtsi carries `qup_uart14_cts_rts` |
| `1166` | posted | upstream `1171`. Jianping Li, "Make ADSP remote heaps no-map" v1 3/4 + 4/4 `<20261015071511.977-4-jianping.li@oss.qualcomm.com>` (+ `-5-`), reviewed; 4/4 via andrebraga ROCKNIX SM8750 `Kernel_7.3` `2052`, 3/4 from the list. Must stay in place before the fastrpc change that assigns the whole heap to the ADSP at probe (Cc stable) reaches 7.3.y: the pages would still be CMA-reusable. | when merged |
| `1168` | community | ROCKNIX SM8750 `0076`, upstream `1175` (our `1175` is the pm8150l LCDB node): sm8750 CPU `capacity-dmips-mhz`. | when upstreamed |
| `1178` | community | ROCKNIX SM8750 `0075`: sm8750 CPU thermal cooling maps. | when upstreamed |
| `1180` | community | ROCKNIX SM4450 `0057` (batocera): sm4450.dtsi CPU capacity + power coefficients. | when upstreamed |
| `1181` | community | upstream `1180`. André Braga, andrebraga ROCKNIX SM8750 `Kernel_7.3` `0524` @ `1c1c374bdc`, not posted, body identical. sm8750 LLCC PMU and memlat nodes, monitors and tables from the Odin 3 vendor DT and post_boot tunables. Feeds `0170`/`0175`. | with `0175` |
| `1182` | community | Aaron Kling, "arm64: dts: qcom: sm8750: add cpu OPP table with DDR and LLCC bandwidths" v1 `<20260605-sm8750-ddr-bw-scaling-v1-1-f39f918c95a7@gmail.com>`, as reworked in andrebraga ROCKNIX SM8750 `Kernel_7.3` `2289` @ `1c1c374bdc` (LLCC on CPU→LLCC, DDR on LLCC→EBI, per the vendor qcom,dcvs nodes; levels from the Odin 3 memlat tables; cpu6 4204800/4320000 kHz turbo OPPs added). Not droppable on the v1 landing as-is. Feeds `0161` (upstream `0160`). | when an equivalent lands, or dropped on a failed A/B |
| `1185` | community | armada `0556a` (ex-`0557`, Noahcdls, armada-os `cacf1e3`; Kettle Linux `1452`). Never posted. sm8750.dtsi: the `smp2p-soccp` edge (IPCC client 46, SMEM 617/616, remote pid 19), `remoteproc_soccp` (`qcom,sm8750-soccp-pas`, not in any binding, enabled in the SoC file on purpose) and a plain `tcsr` syscon at 0x1fc0000 for `qcom,soccp-dstate`. Boards add only `firmware-name`, which msm-firmware-loader serves from the modem partition's `image/soccp.mbn`. Context regenerated over our `1160`-`1184`, content unchanged. | with `0987` |
| `1184` | community | André Braga, andrebraga ROCKNIX SM8750 `Kernel_7.3` `2292` @ `1c1c374bdc`, not posted, body identical. sm8750 GPU OPP bandwidth ranges from the Odin 3 vendor gpu-pwrlevels bus-min/bus-max. Feeds `0287` (upstream `0286`). | with `0286` |

## Mapping from the old numbering

The stack was renumbered from an ad-hoc scheme. This table resolves older references in
commits, docs and issues (`0518-0524`, `0525`, `0530-0532`, `0507`, …). The rename was
verified by applying both orderings to a clean 7.2.7 tree and diffing: the two patched
trees are byte-identical.

| New | Band | Was |
|---|---|---|
| `0010-enable-64-bit-processes-to-use-compat-input-syscalls.patch` | core | `0504-Enable-64-bit-processes-to-use-compat-input-syscalls.patch` |
| `0020-arm64-emulate-unaligned-atomics.patch` | core | `0505-arm64-emulate-unaligned-atomics.patch` |
| `0110-clk-qcom-dispcc-sm8550-mdp-rcg-ops-and-lucid-ole-pll-guard.patch` | clk | `0002-clk-qcom-dispcc-sm8550-mdp-rcg-ops-and-lucid-ole-pll-guard.patch` |
| `0120-pmdomain-qcom-rpmhpd-presync-floor-gmu-rails.patch` | clk | `0121-pmdomain-qcom-rpmhpd-presync-floor-gmu-rails.patch` |
| `0130-interconnect-qcom-sm8550-enable-qos-configuration.patch` | clk | `0122-interconnect__qcom__sm8550__Enable_QoS_configuration.patch` |
| `0210-drm-msm-a6xx-enable-ifpc-on-adreno-740.patch` | gpu | `0004-drm-msm-a6xx-Enable-IFPC-on-Adreno-740.patch` |
| `0220-drm-msm-thp-for-gem-buffers-and-shrinker-modparam-v2.patch` | gpu | `0513-drm-msm-thp-for-gem-buffers-and-shrinker-modparam-v2.patch` |
| `0310-drm-msm-dpu-clear-pending-peripheral-flush-state.patch` | dpu | `0509-drm-msm-dpu-clear-pending-peripheral-flush-state.patch` |
| *(dropped — regresses IGT upstream)* | dpu | `0510-drm-msm-dpu-clear-pending-flush-state-before-physical-cleanup.patch` |
| `0330-drm-msm-fix-smmu-fault-dumps.patch` | dpu | `0515-drm-msm-fix-smmu-fault-dumps.patch` |
| `0340-drm-msm-dpu-enable-true-inline-rotation-on-sm8550-and-sm8650.patch` | dpu | `0528-drm-msm-dpu-enable-true-inline-rotation-on-sm8550-and-sm8650.patch` |
| `0350-drm-msm-dpu-enable-the-qseed-detail-enhancer.patch` | dpu | `0529-drm-msm-dpu-enable-the-qseed-detail-enhancer.patch` |
| `0360-drm-msm-dpu-drive-dspp-igc-and-3d-gamut-through-lutdma.patch` | dpu | `0530-drm-msm-dpu-drive-dspp-igc-and-3d-gamut-through-lutdma.patch` |
| `0365-dt-bindings-display-msm-dpu-add-the-optional-lutdma-register-set.patch` | dpu | `0531-dt-bindings-display-msm-dpu-add-the-optional-lutdma-register-set.patch` |
| `0370-dpu-quiesce-boot-scanout.patch` | dpu | `dpu-quiesce-boot-scanout.patch` |
| `0410-msm-dsi-restore-wide-bus-bpp-calculation.patch` | dsi | `0003-msm-dsi-restore-wide_bus-bpp-calculation.patch` |
| `0420-msm-dsi-keep-link-clocks-up-while-display-active.patch` | dsi | `0005-msm-dsi-keep-link-clocks-up-while-display-active.patch` |
| `0430-drm-msm-dsi-round-byte-clock-after-reparenting.patch` | dsi | `0525-drm-msm-dsi-round-byte-clock-after-reparenting.patch` |
| `0440-revert-revert-drm-msm-dsi-fix-pll-init-in-bonded-mode.patch` | dsi | `0534-Revert-Revert-drm-msm-dsi-fix-PLL-init-in-bonded-mode.patch` |
| `0480-drm-panel-add-brightness-levels-helper.patch` | drmcore | `0074-drm-panel-add-brightness-levels-helper.patch` |
| `0490-add-hw-params-callback-function-to-drm-connector-hdmi-audio-ops.patch` | drmcore | `0006-add-hw_params-callback-function-to-drm_connector_hdmi_audio_ops.patch` |
| `0505-gpu-panel-add-pocket-ace-panel-driver.patch` | panel | `0051-gpu-panel-add-Pocket-ACE-panel-driver.patch` |
| `0510-gpu-panel-add-pocket-dmg-panel-driver.patch` | panel | `0052-gpu-panel-add-Pocket-DMG-panel-driver.patch` |
| `0515-gpu-panel-add-pocket-ds-lower-panel-driver.patch` | panel | `0054-gpu-panel-add-Pocket-DS-lower-panel-driver.patch` |
| `0520-synaptics-td4328-lcd-panel.patch` | panel | `0056_Synaptics-TD4328-LCD-panel.patch` |
| `0525-xm-plus-xm91080g-panel.patch` | panel | `0057_Xm-Plus-XM91080G-panel.patch` |
| `0530-chipone-icna35xx-panel.patch` | panel | `0058_Chipone-ICNA35XX-panel.patch` |
| `0535-ddic-ch13726a-panel.patch` | panel | `0059_DDIC-CH13726A-panel.patch` |
| `0540-gpu-drm-panel-add-wt0630-panel.patch` | panel | `0066-gpu-drm-panel-add-wt0630-panel.patch` |
| `0545-gpu-drm-panel-add-pocket-fit-panel.patch` | panel | `0067-gpu-drm-panel-add-pocket-fit-panel.patch` |
| `0550-gpu-drm-panel-add-wt0600-1k-panel.patch` | panel | `0068-gpu-drm-panel-add-wt0600-1k-panel.patch` |
| `0555-drm-panel-add-retroid-pocket-6-panel.patch` | panel | `0104-drm-panel-Add-Retroid-Pocket-6-panel.patch` |
| `0560-drm-panel-add-retroid-pocket-nova-panel.patch` | panel | `0105-drm-panel-Add-Retroid-Pocket-Nova-panel.patch` |
| `0610-ayn-odin2-mini-backlight.patch` | backlight | `0060_AYN-Odin2-Mini--backlight.patch` |
| `0650-leds-add-driver-for-heroic-htr3212.patch` | leds | `0033_leds--Add-driver-for-HEROIC-HTR3212.patch` |
| `0660-leds-aw200xx-optional-vdd-supply.patch` | leds | `0040_leds--aw200xx-optional-vdd-supply.patch` |
| `0680-sn3112-pwm-driver.patch` | pwm | `0034_sn3112-pwm-driver.patch` |
| `0705-touchscreen-edt-ft5x06-allow-to-override-input-name.patch` | touch | `0015-touchscreen-edt-ft5x06-allow-to-override-input-name.patch` |
| `0710-edt-ft5x06-add-no-regmap-bulk-read-option.patch` | touch | `0053-edt-ft5x06-add-no_regmap_bulk_read-option.patch` |
| `0715-input-goodix-override-resolution-from-dt.patch` | touch | `0055-input-goodix-override-resolution-from-dt.patch` |
| `0720-ayn-odin2-mini-hynitron-cstxxx.patch` | touch | `0061_AYN-Odin2-Mini--hynitron--cstxxx.patch` |
| `0725-rmi4-silence-spam-irq-errors.patch` | touch | `0032-rmi4-silence-spam-irq-errors.patch` |
| `0730-input-touchscreen-add-synaptics-dsx-driver.patch` | touch | `0063-input-touchscreen-add-synaptics-dsx-driver.patch` |
| `0735-input-touchscreen-add-synaptics-dsx-kconfig.patch` | touch | `0064-input-touchscreen-add-synaptics-dsx-kconfig.patch` |
| `0738-input-add-chipone-tddi-touchscreen.patch` | touch | `0069-input-add-chipone-tddi-touchscreen.patch` |
| `0745-input-add-driver-for-rsinput-gamepad.patch` | joystick | `0031_input--Add-driver-for-RSInput-Gamepad.patch` |
| `0750-input-add-driver-for-retroid-pocket-gamepad.patch` | joystick | `0035_input--Add-driver-for-Retroid-Pocket-gamepad.patch` |
| `0755-input-add-driver-for-mangmi-pocket-max-spi-joypad.patch` | joystick | `0037_input--Add-driver-for-MANGMI-Pocket-Max-SPI-joypad.patch` |
| `0770-input-add-driver-for-qcom-spmi-haptics.patch` | haptics | `0038_input--Add-driver-for-qcom-spmi-haptics.patch` |
| `0775-input-retroid-gamepad-add-force-feedback.patch` | haptics | `0039_input--retroid-gamepad-add-force-feedback.patch` |
| `0780-input-add-qcom-hv-haptics-hap530-v5-driver.patch` | haptics | `1000-add-qcom-haptics-driver.patch` |
| `0785-haptics-driver-support-periodic-sine-and-fixes.patch` | haptics | `1002-haptics-driver-support-periodic-sine-and-fixes.patch` |
| `0790-input-rsinput-add-scoped-haptics-ff-bridge.patch` | haptics | `1003-rsinput-add-ff.patch` |
| `0795-input-haptics-fix-rumble-bridge-atomic-sleep.patch` | haptics | `1004-input-qcom-haptics-defer-rsinput-playback.patch` |
| `0830-asoc-codecs-aw88166-ayn-odin2-specific-modifications.patch` | audio | `0047_ASoC--codecs--aw88166--AYN-Odin2-Specific-modifica.patch` |
| `0840-asoc-wcd938x-add-dmic-dapm-inputs.patch` | audio | `0200-ASoC-wcd938x-add-DMIC-DAPM-inputs.patch` |
| `0850-asoc-qdsp6-q6apm-lpass-start-playback-port-at-prepare.patch` | audio | `0201-ASoC-qdsp6-q6apm-lpass-start-playback-port-at-prepare.patch` |
| `0870-asoc-qcom-sm8250-force-s16-le-only-for-compressed.patch` | audio | `0203-ASoC-qcom-sm8250-force-S16_LE-only-for-compressed.patch` |
| `0880-asoc-qcom-q6asm-dai-change-default-periods.patch` | audio | `0204-ASoC-qcom-q6asm-dai-change-default-periods.patch` |
| `0890-asoc-wcd938x-guard-the-soundwire-interrupt-callback.patch` | audio | `0205-ASoC-wcd938x-guard-the-soundwire-interrupt-callback.patch` |
| `0910-power-supply-add-qcom-pm8150b-charger-and-fg.patch` | power | `0072-power-supply-add-qcom-pm8150b-charger-and-fg.patch` |
| `0920-power-supply-add-hl7139-charge-pump.patch` | power | `0073-power-supply-add-hl7139-charge-pump.patch` |
| `0930-power-supply-qcom-battmgr-fix-charge-full-on-sm8350-class-firmware.patch` | power | `0526-power-supply-qcom-battmgr-fix-charge-full-on-sm8350-class-firmware.patch` |
| `0940-power-supply-qcom-battmgr-expose-charge-now-on-sm8350-class-firmware.patch` | power | `0527-power-supply-qcom-battmgr-expose-charge-now-on-sm8350-class-firmware.patch` |
| `0970-rocknix-set-boot-fanspeed.patch` | misc | `0500-ROCKNIX-set-boot-fanspeed.patch` |
| `0980-misc-add-ayaneo-serial-mcu.patch` | misc | `1005-misc-add-ayaneo-serial-mcu.patch` |
| `1010-wifi-ath12k-send-the-computed-scan-priority-to-the-firmware.patch` | net | `0507-wifi-ath12k-send-the-computed-scan-priority-to-the-firmware.patch` |
| `1030-hack-fix-usb-boot-hang.patch` | usb | `0071-HACK-fix-usb-boot-hang.patch` |
| `1040-usbcore-add-interrupt-interval-override.patch` | usb | `0506-usbcore-add-interrupt-interval-override.patch` |
| `1060-pci-qcom-honor-iommu-providers-iommu-cells-in-config-sid-1-9-0.patch` | pci | `0535-pci-qcom-honor-iommu-providers-iommu-cells-in-config-sid-1-9-0.patch` |
| `1105-pcie-update-sm8550-dtsi.patch` | dts | `0000-pcie-update-sm8550-dtsi.patch` |
| `1110-pcie-update-sm8650-dtsi.patch` | dts | `0001-pcie-update-sm8650-dtsi.patch` |
| `1115-arm64-dts-qcom-sm8250-add-uart16.patch` | dts | `0008-arm64-dts-qcom-sm8250-add-uart16.patch` |
| `1120-arm64-dts-qcom-sm8250-extend-gpu-opp-table.patch` | dts | `0009-arm64-dts-qcom-sm8250-extend-gpu-opp-table.patch` |
| `1125-arm64-dts-qcom-pm8150b-add-charger-fg-haptics.patch` | dts | `0010-arm64-dts-qcom-pm8150b-add-charger-fg-haptics.patch` |
| `1130-arm64-dts-qcom-pm8150-add-rtc-offset-nvmem.patch` | dts | `0011-arm64-dts-qcom-pm8150-add-rtc-offset-nvmem.patch` |
| `1135-arm64-dts-qcom-sm8250-fix-pcie-wake-gpio-polarity.patch` | dts | `0012-arm64-dts-qcom-sm8250-fix-pcie-wake-gpio-polarity.patch` |
| `1140-arm64-dts-qcom-gpu-cc-power-requirements-reality-check.patch` | dts | `0120-20250728_konradybcio_gpu_cc_power_requirements_reality_check.patch` |
| `1145-arm64-dts-qcom-add-the-dpu-lutdma-register-set.patch` | dts | `0532-arm64-dts-qcom-add-the-dpu-lutdma-register-set.patch` |
| `1150-arm64-dts-qcom-sm8250-8550-8650-8750-add-gcc-cx-power-domain.patch` | dts | `20260424_neil_armstrong_arm64_dts_qcom_sm8_456_50_add_missing_cx_power_domain_to_gcc.patch` |

## SM6115 port (2026-10-09)

ROCKNIX's `devices/SM6115/patches/linux` set, at `next`'s 2026-10-06 state (which added the MANGMI
Air Y and refreshed the Air X), was brought over for the two boards, renumbered into the bands
above (the table lists each). The SM6125 Retroid Pocket Duo Lite patches in that directory
(`0060`-`0077`, `0080`) are a different SoC and were not taken. Not brought over:
`0004` (A610 speed-bin / 1050 MHz overclock — a performance decision for the tuning pass),
`0013` (aw200xx vdd — `0660` already), `0200`-`0202` and `0205`/`0208`/`0210` (the SDE rotator
and QSEED work — `0385` and `0350`-`0352` already, both carrying the sm6115 compatible), and
`0037` (replaced by the scoped `0871`). The whole stack applies with `--fuzz=0` on v7.2.9.

The same day brought the MANGMI Air Y Pro (SM8250) over from ROCKNIX's SM8250 tree: `0580`,
`0736`, `0990`, `1175`, and `0755` refreshed to the driver revision that knows the board.
