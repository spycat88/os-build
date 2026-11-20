# gamescope patches

retroforge patches applied on top of the local gamescope PKGBUILD source (the Valve gamescope tag
named by `pkgver` in [`../PKGBUILD`](../PKGBUILD)), in the order listed by `patches:` in
[`../source.pin`](../source.pin). Each is applied with `patch -p1` from the gamescope source
root (the `gamescope/` checkout inside makepkg's `$srcdir`) by
[`packages/build-overlay.sh`](../../build-overlay.sh).

## Expected here

```
0001-drmbackend-rotated-output-max-height.patch
0002-sanitize-nightmode-atom.patch
0003-drmbackend-fake-output-mm.patch
0004-fps-limit-atom-persist.patch
0005-steamcontrolled-steam-focus-fallback.patch
0006-focus-candidate-instrumentation.patch   (present but NOT in source.pin — diagnostic, see below)
0007-vendor-wayland-protocols-wrap.patch
0014-drm-color-manage-direct-scanout-via-the-dpu-ctm.patch
0016-steamcompmgr-arm64-virtual-white.patch
0017-color-neutral-virtual-white-keeps-scanout.patch
0018-drm-sdr-color-management-through-the-dpu-output-luts.patch
0019-rendervulkan-fragment-shader-composite.patch   (--composite-graphics, passed by default from etc/retroforge/session.conf)
0020-libliftoff-treat-enodev-as-no-fit.patch        (patches the libliftoff SUBMODULE; only with 0021)
0021-libliftoff-give-planes-the-layer-zpos.patch    (patches the libliftoff SUBMODULE)
0025-steamcompmgr-elapsed-time-fps-limiter.patch     (ConVar limiter_use_elapsed_time, default on)
0026-rendervulkan-upscale-cache-compressed.patch        (ROCKNIX fork 0018)
0027-rendervulkan-composite-blit-rotated-copy.patch     (ROCKNIX fork 0019; --composite-blit, passed by default from etc/retroforge/session.conf)
0028-drmbackend-pre-rotate-layers-the-plane-cannot-rotate.patch   (ROCKNIX fork 0021, re-rolled by hand on 0014/0018)
0029-rendervulkan-safe-compute-fallback.patch           (ROCKNIX fork 0025)
0030-composite-blit-keeps-the-dpu-colour-management.patch   (ours: 0027 under 0014/0018)
0031-composite-blit-build-under-werror-format-security.patch   (ours: one-line build fix for 0027)
0047-drm-offer-an-edid-less-internal-panels-native-modes-as-refresh-rates.patch   (Kettle Linux 0019, via Nova-Deck 0026)
0048-steamcompmgr-refresh-only-request-takes-the-exact-mode.patch   (Nova-Deck 0027)
0049-steamcompmgr-steam-on-another-xwayland-sees-the-focus.patch   (ours: Steam Input under OpenGamepadUI)
```

`0008`-`0013` are **retired** (see below), and so are `0022`-`0024`, which is why the pre-rotation
series took `0026`-`0030`. The numbering is kept as-is rather than compacted, so
older commit messages and memories still resolve.

`0001` — **REUSED 2026-09-12 for `--rotated-output-max-height`** (the number was freed when the
original 0001 went upstream; that history is kept below). Adds an opt-in flag that clamps the
LOGICAL output height when a panel is scanned out rotated, aspect-preserving with both axes even,
and scales the CRTC rects back up to the real mode so the plane upscales for free. `SRC_W/H` stay
at texture size. 90/270 only — 0/180 do not transpose, so the rotator limit does not apply.

Why: the DPU inline rotator caps the PRE-ROTATION source at **1088 lines**, but the plane
advertises `ROTATE_90` as a STATIC capability it cannot qualify per-mode. On Pocket S2 (1440 wide)
gamescope therefore believes it can rotate at scanout, stops compositing the rotation, and every
atomic commit is refused — a black panel. Rendering the session at 1920x1080 instead of 2560x1440
puts every layer under the cap, so the board keeps scanout rotation instead of paying a GPU
composite per present. HW-validated on Pocket S2 2026-09-12: idle UI and in-game both **0 ms**
gamescope GPU (was 21% in game), **-834 mW**, the game→UI transition no longer wedges, touch still
lands correctly (virtual-keyboard test), and the operator could not distinguish the upscaled UI
from native. Cost: UI at 1080p upscaled to a 1440p panel, and games cap at 1080p.

**`drm_set_refresh()` closed on Pocket FIT 2026-09-12**, from the card built off this tree. Forced
the clamp on a board that does not need it (`--rotated-output-max-height 720`, logical output
1920x1080 -> 1280x720) and drove mode changes with a game running: **three modesets, 144 -> 120 ->
144 Hz**, each re-applying the clamp, each landing on a real rate from the panel's
`{60, 90, 120, 144}`, panel lit throughout, plane still `1280x720 / rotation=8`, zero underruns and
zero rotator rejections. That is the path that would have broken: 1280x720 matches no mode on this
connector, so without the fix the first mode change would have generated a timing the panel cannot
display. Not shown: 60 or 90 specifically — gamescope picks the rate by its own policy and ignored
the requested values, so only the transitions it chose could be observed.

**Regression check, same card, same board, stock config:** the gate (`native width > 1088`) does not
fire on the FIT's 1080-wide panel, gamescope gets NO flag, the clamp log is empty, and planes stay
`1920x1080 -> 1080x1920 rotation=8`. The patch is invisible on boards that do not need it.

Set from `rootfs/overlay/etc/retroforge/session.conf` on panels over the cap. An unknown argument
makes gamescope EXIT, so if this patch is ever dropped, that session.conf line must change back to
`--force-composition-rotation` in the same commit.

---

The ORIGINAL `0001` — **GONE, and deliberately not replaced: it is UPSTREAM as of 3.16.28.** It rotated the
portrait-native Pocket S2 panel in gamescope's **GPU composite** step (the msm DPU cannot
`ROTATE_90` a LINEAR plane; root cause in `docs/archive/bringup-phase2.md` step 1e), and it was upstream PR
[#2228](https://github.com/ValveSoftware/gamescope/pull/2228), merged verbatim as `38fb50fc`
("Add composited output rotation for displays that can't rotate at scanout"). Verified before
dropping: the shipped tree carries the same `drm_plane_supported_rotations()` helper and the same
`g_bForceCompositionRotation || !bScanoutCanRotate` condition our patch tested, so the autodetect
behaviour our session depends on is byte-for-byte the one we had. Still needs no launch flag —
gamescope reads the panel orientation from the DRM connector (our DTS declares `rotation=<90>`) and
auto-engages compositor rotation when the primary plane can't rotate at scanout;
`--force-composition-rotation` remains available for hardware that advertises a rotation it cannot
actually present. The `0002`-`0006` numbering is kept as-is rather than renumbered, so old commit
messages and memories still resolve.

`0002` — sanitize the night-mode color atom. **Self-disarming since 2026-09-29.** The beta client
`1790545198` packs the atom correctly (hue 0..1/6 in `vec[1]`, saturation 0.5..1.0 in `vec[2]`);
stable `1788652215` is still broken, and its `vec[1]` is saturation, 0.5..1.0. So `vec[1] < 1/3`
selects the stock decode. Retire the workaround branch only once stable's BINARIES are fixed: hash
`steamrtarm64/steamclient.so` against a known-stable device. After a channel switch, don't trust the
manifest version: under `-noverifyfiles`, going beta -> stable rewrites the manifest but leaves the
beta binaries in place, and that fooled us once.

`0003` — `GAMESCOPE_FAKE_OUTPUT_MM` env override for the reported output physical size (upstream
contribution by tiopex). This is the lever that fixes SteamUI's auto-scale on our panel — *not* the
`wl_output` mm swap described below.

`0004` — make the legacy `GAMESCOPE_FPS_LIMIT` X atom actually stick. Our arm64 Steam client never
connects to gamescope's Wayland socket, so that atom is the only channel QuickAccess's frame cap has;
upstream never exercises the path because Valve's x86 client drives the cap over `gamescope_control`.

`0005` — let a Steam window take **global** focus under `SteamControlled`. `--steam` selects that
strategy, which withholds the generic `vecPossibleFocusWindows[0]` fallback from the global pass and
leaves `focusControlWindow` / `ctxFocusControlAppIDs` as the only routes to focus — both published by
Steam, so neither exists while the bootstrapper is up. The client-update dialog is `window_is_steam()`
but `appID == 0`, so it matches neither, never gets focus, and the panel stays black for the whole
update (measured 13.5 min, zero flips). Adds a narrow last-resort route: global pass only,
`SteamControlled` only, only when focus is already NULL, and only ever selects a Steam window — never
a game — so a live client's choice can't be overridden. Full derivation in the patch header.

`0006` — **diagnostic, kept in the tree but deliberately ABSENT from `source.pin`'s `patches:` line,
so a stock build does not carry it.** It logs why each window is or is not a focus candidate, which
one wins, and the winner's commit-queue state. This is the instrument that localized `0005` and then
confirmed it on HW, and that caught a baselayer-appid reorder (the retired `0023`), which is why it is kept
rather than deleted — the next focus mystery should not have to re-derive it.

To use it: add it back to `source.pin`, rebuild, and `export GAMESCOPE_DEBUG_FOCUS=1` in
`/etc/retroforge/session.conf` (the only way to catch a defect at boot, before SSH is up), or
`gamescopectl debug_focus_candidates 1` live once a session is reachable. Output goes to
the journal (`journalctl -b -u retroforge-session`) — grep that for `cand:`.

`0007` — declares a `subprojects/wayland-protocols.wrap` so meson vendors wayland-protocols. Needed
by the 3.16.28 bump: it moved the wlroots submodule to 0.20, which requires
`wayland-protocols >= 1.47`, and the pinned holo snapshot ships 1.45 — the build failed at configure
time. Paired with `wayland-protocols` in `-Dforce_fallback_for` in `../PKGBUILD`; **both halves are
required**, the wrap alone does nothing while a system copy is visible. Cheap to carry because
wayland-protocols is data (XML protocol definitions + a pkg-config file), not a library we link.
Full rationale, and why this beats bumping `build/snapshot.pin`, is in the patch header.

**The 3.16.28 dependency ladder, and why it stops at one patch.** gamescope 3.16.26+ needs
wlroots 0.20, which needs wayland-protocols ≥ 1.47, and the pinned holo base ships 1.45. That is the
whole problem, and `0007` is the whole fix — *provided the vendored protocols are pinned to 1.48*.
Reaching for the newest (1.49) adds two more links that do not otherwise exist: 1.49 uses a `frozen=`
attribute the base's wayland-scanner 1.24.0 cannot parse, which forces vendoring a newer wayland for
its scanner, which then fails against gamescope's own `protocol/meson.build`
(`get_variable(pkgconfig:)` cannot read an InternalDependency). **Take the oldest version that clears
the floor, not the newest that exists** — the rule that would have saved three builds here.

There is no intermediate gamescope tag that avoids this: 3.16.25 is the last release on wlroots 0.19,
and 3.16.26 — the first with composite rotation upstream — is already on 0.20. Any version new enough
to let us drop `0001` needs `0007`.

**While it is in `source.pin`, `fetchlock.sh` reports the gamescope row as built from UNADOPTED
sources.** That is expected on a dev image and is exactly why it must come back out, with a
`make relock`, before any commit or release build.

`0008`-`0013` — **RETIRED 2026-09-14 when HDR was dropped (issue #93).** The EDID-synthesis +
HDR series (third-party, by virtudude and enjihn) is gone from the tree and from `source.pin`, along
with `rootfs/overlay/usr/share/gamescope/scripts/10-retroforge/` and `tests/test-display-profile.sh`.

**Why, in one line: `--hdr-itm-enabled` maps nothing.** In gamescope 3.16.28 the shader branch is
guarded by `c_itm_enable`, specialization constant 7, which is only ever set from
`PipelineInfo_t::itm_enable` — and **no call site passes it**, so it is permanently false and
`bt2446a_inverse_tonemapping()` can never execute. `g_bHDRItmEnable` has exactly three consumers in
the whole tree, all of them `bNeedsFullComposite |= g_bHDRItmEnable`. The flag's only real effect is
to force a full Vulkan composite on every present. Verified against the pristine 3.16.28 source —
this is upstream behaviour, not something our patches broke. Confirmed by eye on a Pocket Max:
toggling `GAMESCOPE_HDR_ITM_ENABLE` live on a dark scene in Trine changed nothing visible.

That forced composite costs any board with a working DPU inline rotator its scanout rotation:
**~0.2 W idle and 650-830 mW in game**, measured. Paying that for a no-op ended the argument.

`--hdr-enabled` (output HDR, the gamma-2.2 path) *did* change the image — a visibly lifted black
floor — but it was never judged worth its own composite cost, and with ITM inert there was no reason
to keep the pair. `0011` and `0013` went with them: both exist to feed HDR formats to clients.

**Consequence for `0014`, `0015` and `0018`: all three were RE-ROLLED**, because they had been built
on top of the series and carried HDR-introduced context — `create_color_mgmt_luts`'s
`bTraditionalHDROutput` parameter, the `DrmHdrOutputRequiresVulkanComposition` call site, and
test-list entries for tests that no longer exist. Their intent is unchanged; the hunks now sit on the
pristine signatures. Regenerated with `git diff` against a clean 3.16.28 checkout, never hand-edited
— see the per-patch RE-ROLLED notes in their headers. `0018`'s test additions went with the series
because every one of them tested `DrmHdrOutputRequiresVulkanComposition` itself.

`0015` — **RETIRED 2026-10-26 with the 3.17.0 bump, and the number stays unused.** It made
`BIsWideGamut()` inclusive (`r.y <= 0.320f`, upstream still has `<`), because DCI-P3 red is exactly
`(0.680, 0.320)` and the retired `retroforge.internal-amoled.lua` profile declared it for every panel,
classifying them **narrow**. Nothing reaches that tie any more: an EDID-less DSI connector keeps
`displaycolorimetry_709` (red `(0.640, 0.330)`, narrow either way), we ship no gamescope display
scripts, and an EDID stores chromaticity in 10 bits, so a P3 red reads `0.3203` or `0.3193`, never
exactly `0.320`. Only a display script declaring P3 red exactly would hit it; revive the one
character with such a script. If you do: the narrow branch of `buildSDRColorimetry()` sweeps panel
native → generic wide gamut with a saturation remap, the wide branch Rec.709 → panel native with
none, and an A/B needs a COMPOSITED frame (Pocket Max, or `GAMESCOPE_COMPOSITE_FORCE=1`), since
`0014` scans out without the gamut mapping.

`0016` — **recover the virtual white point's `y` on arm64.** `GAMESCOPE_DISPLAY_VIRTUAL_WHITE` is the
colour temperature slider's wire format and the arm64 Steam client packs it through **the same Xlib
`format=32` LP64 fault documented on `0002`**: it hands `XChangeProperty` a `float[2] {x, y}` — 8
bytes — and Xlib reads two 8-byte longs off it, transmitting the low half of each. Element 0 is `x`;
element 1 is an out-of-bounds read of the client's stack.

This one is worse than `0002`'s in a specific way. `calcColorTransform()` engages the chromatic
adaptation on `destVirtualWhite.y > 0.01f`, so the overread is not merely ignored: a large positive
stack value builds an adaptation to a **nonsense white point** and a small or negative one disables
the slider outright, and `0002`'s investigation showed that element re-rolling per install rather
than sitting at a constant. Both failures look like a panel problem from the outside.

The pair is recoverable because Steam does not choose it freely — both coordinates come off the CIE
daylight locus and the client's 6500 K `x` is D65's — so `x` alone fixes `y` to within 0.002 across
the slider's range via the locus quadratic `-3x² + 2.87x - 0.275`. Element 1 is taken whenever it
decodes as a plausible daylight `y` (0.20–0.45), which is what a **fixed** client would send, and
derived otherwise. That makes the workaround self-disarming instead of something to remember to
remove. `#if defined(__aarch64__)` — this is a defect in one client build, not in the property.

Unlike `0002`'s hue, nothing here is destroyed beyond recovery: `x` alone determines the answer, so
the slider genuinely works after this rather than merely stopping doing harm.

**Knowing this costs a frame is part of the deal.** `calcScanoutLinearScale()` returns `nullopt`
when a virtual white is set and is not the panel's own — a white-point adaptation is a real matrix
and the DPU cannot carry it — so a colour temperature anywhere off neutral **forces a composite**
and gives up direct scanout for as long as it is set. That is correct rather than regrettable; the
alternative is applying it wrong. It also made this patch a regression until `0017` landed — see
there, and read it before touching either.

**Do NOT use the live plane count as the test signal for this** (an earlier draft of this file
said to, and it is wrong). On a single-layer Steam UI, a composited frame and a directly scanned-out
one BOTH present exactly one plane with `rotation=8`, because the composite output is itself scanned
out rotated. The two are indistinguishable that way. The discriminator is the CRTC's **CTM**: with
night mode on it reads a non-identity diagonal on the scanout path and snaps to identity the moment
a frame composites. Plane count only separates the two when there are genuinely two layers to scan
out, which is where the "2 planes" readings elsewhere in this project come from.

`0017` — **a virtual white equal to the panel's own white keeps direct scanout.** `0014`'s
expressibility test refuses whenever *any* virtual white point is set. Correct for an adaptation
between two different white points; wrong for the one that ships, because the Steam client publishes
the panel's own white whenever the colour temperature slider sits at neutral — where it sits out of
the box — and adapting a white point to itself is the identity, which is a diagonal and therefore
expressible. Without this, the default configuration composited **every frame** to apply a transform
that does nothing.

**It was latent in `0014` from the start and `0016` is what made it reachable**: before `0016` the
arm64 client's `y` arrived as a zero overread, so the gate never fired. Any correctly-packing client
would have tripped it too. Caught on Pocket ACE 2026-09-13 — night mode at 0.5/0.95 with the client's
own virtual white left the CTM at identity, and clearing the virtual white *alone* brought back
`diag(1.0, 0.72315, 0.52500)`, matching `hsv_to_rgb(25°, 0.475, 1.0) = (1.0, 0.72292, 0.525)` to 2e-4.

**The tolerance is measured.** An exact comparison does not
work: on a board with no display profile the panel white is the synthetic EDID's 10-bit quantised
D65, `0.3125000`, against the client's neutral `0.3127789` — a gap of **2.8e-4**. One notch of the
slider moves x by **7.4e-3**, twenty-six times that. `0.001` sits 3.6× above the gap and 7.4× below a
notch. Do not widen it toward the notch or narrow it toward the quantisation gap without re-measuring.
A test asserting both bounds with the measured numbers was dropped with the rest of the series'
`tests/` hunks on 2026-10-26 (3.17.0 bump), so these numbers are the only record.

`0018` — **the whole SDR chain in the DPU's own LUTs, not just a diagonal.** Third-party
(virtudude), carried with one addition of ours. `0014` exists because the DPU exposes no degamma
block, which leaves only a per-channel diagonal expressible — so a colour temperature change, a
gamut mapping or a look LUT each cost a full composite on every frame they are live. That limit is
mainline's, not the hardware's: on DPU 9.0+ the colour LUT blocks sit behind a LUT bus with no
memory-mapped write path, reachable only by the LUTDMA engine, which mainline does not drive.
Kernel patches `0530`-`0532` port that engine and expose the DSPP inverse gamma as a 256-entry
CRTC `DEGAMMA_LUT` and the 17³ gamut block as a `DPU_3D_LUT` blob. This patch drives them: the
shader leaves its gamma 2.2 shaper and 3D LUT unbound and the DPU applies the same pair post-blend,
on the scanout path *and* the composite path.

**`0014` is not superseded — it is the fallback**, and the two are ordered rather than merged. Only
a kernel with the LUTDMA engine offers `DPU_3D_LUT`, and the SM8250 boards have no such engine, so
both can be present at once. When the output LUTs are applied: the CTM is held at the **identity**
(`drm_update_crtc_ctm()` is given `false`, exactly as for a composited frame and for the same
reason — the transform is already being applied elsewhere); `drm_scanout_is_color_managed()` returns
true outright, skipping the expressibility test entirely; and `drm_scanout_ctm_is_active()` returns
false, so partial composition stays available, because the post-blend LUTs correct both halves and
there is no split to manage.

**One hunk of the author's patch is deliberately not carried**, and the measurement that justifies
it is worth keeping. It forced a full composite for every SDR layer whenever the output LUTs were
not carrying the chain — correct in a tree without `0014`, redundant here, and strictly the more
conservative of the two tests, so keeping both let it win everywhere and made `0014` unreachable.
On Pocket FIT with `drm_output_luts 0` and night mode at maximum that read **one live content
plane and an identity CTM** — the composite, not the diagonal — and on the SM8250 boards, which
have no `DPU_3D_LUT` at all, it would have been the permanent state. Dropping it loses nothing:
with the LUTs on both tests allow scanout, with an inexpressible transform both composite, and
only the diagonal case differs.

**HW PASS, Pocket FIT (SM8650, engine v3), 2026-09-13.** A non-neutral colour temperature — a
Bradford white-point adaptation, non-diagonal, so it cost a full composite on *every frame it was
live* — now scans out: **2 live content planes** with the adaptation in `DPU_3D_LUT` and the CTM at
identity, against **1 plane** with the LUTs off. Night mode at maximum reprograms the 3D LUT while
the CTM stays identity, and with the LUTs off falls back to `diag(1.0, 0.41667, 0)` on scanout.
Sixteen enable/disable transitions — each one a modeset — with zero LUTDMA / `CTL_FLUSH` /
underrun / SMMU-fault lines.

**Pocket S2 (SM8650, engine v3) is the board that mattered**, because
`--rotated-output-max-height` clamps its 1440x2560 panel to a 1080 render the DPU upscales, putting
the pre-rotation height 8 lines under the inline rotator's 1088 cap — so anything that grew a layer
would re-open the black-UI failure. It did not: in all four states (LUTs on/off under night mode,
colour temperature, and the restore) it held **two live content planes both at `rotation=8`**,
inline rotation and the DPU upscale intact, with **zero `invalid height for inline rot` rejections**
in dmesg and zero in the session log. Same A/B answers as the other two boards.

**Pocket ACE (qcs8550, engine v2) gives identical answers**, on all three states: LUTs on + night
mode max = 2 planes / identity CTM / populated 3D LUT; LUTs off + night mode max = 2 planes /
`diag(1.0, 0.41667, 0)` / cleared; LUTs on + colour temperature = 2 planes / identity / populated.
That board is the author's own verified engine revision, so it re-gates their leg against our
re-roll rather than testing new silicon. Zero display or LUTDMA errors after boot — its 10
arm-smmu faults in the first second are the pre-existing splash handoff, unchanged in count.

**The two paths are not pixel-identical, by construction, and an operator can see it.** `0014`'s
`calcScanoutLinearScale()` deliberately ignores the SDR gamut mapping, because direct scanout never
applied it; the 3D LUT runs the full `calcColorTransform()` chain and does. At the default
`sdrGamutWideness` of 0.5 that mapping is live, so toggling `drm_output_luts` under a fixed night
mode gives *"subtle differences in some colours, nothing completely off"* — saturated content moves,
neutrals do not. **Forcing `sdrGamutWideness` to 0 makes the two indistinguishable to the eye**,
which is the measurement that identifies the cause; do that before chasing anything else here. It
is a **fix, not a regression**: the composite path always applied the gamut mapping, so the LUTs
make scanout and composite agree, where `0014` left them differing by exactly this and let the
difference appear and disappear as frames switched paths.

**Being post-blend has a real consequence**: a translucent overlay is corrected as the blended
pixel, not per layer. Per-plane offload is the follow-up. Turning the LUTs on or off changes which
display blocks the CRTC owns and therefore needs a **modeset** — the kernel asks for one, and the
patch keeps them on across a composited frame rather than toggling. The runtime switch is the
convar `drm_output_luts` (default on); set it explicitly (`gamescopectl drm_output_luts 0`), since
a bare convar name *sets it false*.

`0022` and `0023` — **RETIRED, and the numbers stay unused.** Both existed for native-Wayland
(xdg-shell) titles under Steam — Lepton's Android guest above all: `0022` deferred Steam's own window
in focus selection (and hid the Quick Access menu while such a title ran), and `0023` replaced it by
reporting xdg titles in `GAMESCOPE_FOCUSABLE_APPS`/`_WINDOWS`, following a shared-Android appID root
property, and passing touch through. retroforge ships no Android container and its shell and emulators
are XWayland clients, so neither has a user. If a native-Wayland emulator ever needs to be focusable
under `--steam`, part (1) of `0023` — reporting an xdg window with a resolved appID — is the piece
to revive.

(A patch that once held the `0003` slot swapped `wl_output`'s `phys_width/phys_height` on the rotated
path as a coherence fix, but HW showed it does NOT move SteamUI's auto-scale — the swap is
diagonal-invariant and Steam keys off mm *magnitude*; the actual UI-scale fix is the panel-mm bump in
the Pocket S2 panel patch — which was itself later overturned: HW showed the Steam client stopped
honouring panel mm for gamepad-UI scale entirely, and `GAMESCOPE_FAKE_OUTPUT_MM` above is the lever
that replaced it. **That `kernel/patches/0062` citation is stale** — renumbering moved 0062 onto the
SY7758 backlight driver, which has nothing to do with panel size. It was dropped once the incremental overlay build made a gamescope-only
recompile cheap, and the number was later reused by the `GAMESCOPE_FAKE_OUTPUT_MM` patch above.)

`0020` + `0021` — **libliftoff plane stacking on msm** (sunshineinabox; ROCKNIX PR #3377 gamescope
`0020` and `0022`, bodies unchanged). libliftoff never writes plane zpos, and our DPU gives one CRTC
several PRIMARY planes, all at zpos 0, so hardware stacking falls back to plane object id. Stock
liftoff got it right only by accident: its traversal order matched that id order, and nothing
backtracked. `0021` writes the layer's zpos into any plane whose zpos is a mutable range. `0020` makes
msm's `-ENODEV` (no free SSPP, from `dpu_plane_assign_resource_in_stage()`) a "no fit" rather than
an abort, which means MORE backtracking, so **never carry `0020` without `0021`**. The symptom was
MangoHud intermittently missing (it sat behind the game). It did not reproduce on Pocket ACE on
2026-09-17, because there the allocation never backtracked. Both patch the
**submodule**, so `../PKGBUILD`'s `prepare()` checks the submodules out BEFORE its `cd gamescope`,
the line build-overlay.sh injects the patch step after.

`0024` — **RETIRED 2026-10-06, and the number stays unused.** It reserved extra commit lead before
vblank while the planes rotated (`GAMESCOPE_SCANOUT_ROTATION_TIME_US`, 1 ms on every board here), as a
workaround for the Pocket S2's one-frame black blink. That blink was a kernel bug: the two DSI
interfaces' CTL flushes straddling the DPU's programmable fetch start (upstream issue #110), fixed in
`kernel/patches/0395`. The lead cost ~1.25 ms of latency on every board, and on SM8250 its reserve
ratcheted up on the offline rotator's late flips and took games from 60 to 40 fps (upstream, Pocket Max).

`0025` — **the fixed-refresh frame limiter releases by elapsed time, not by vblank count**
(virtudude; armada PR #629, ported from upstream 4caee07; retired with the 3.17.0 bump, then back
the same day as Nova-Deck's `0036`, rebased onto 62707e1e's boundary-crossing gate with the gate
body unchanged — we keep our number). With a frame cap below the refresh rate and no VRR — every
board we ship, DSI has no VRR — 3.17.0 releases a limited frame only when the display vblank count
crosses a limiter boundary, so a frame that misses its boundary vblank is shown one vblank late and
a game that cannot quite hold its cap alternates short and long frames. `0025` gates on
`last_commit_first_latch_time` + the limited period with half a refresh period of slack, the same
scheme gamescope already uses for VRR. ConVar `limiter_use_elapsed_time` (default on); `0` restores
stock 3.17.0's gate live. A/B'd upstream on 3.17.0, 2026-10-26:
- Pocket Max, PGRC loaded to ~67 fps uncapped, 144 Hz cap 72: stock left 15-53% of commits at
  20.8 ms (3 vblanks); `0025` held 99% at 13.9 ms.
- Pocket FIT, PGRC light (~140 uncapped), 72 @144, 60 @120, 30 @120: indistinguishable from stock
  (98.7-99.4% on cadence, no extra early frames), so releasing up to half a refresh early does not
  make a light game alternate short/long frames.
`kernel/patches/0390` (real vblank timestamps on command-mode panels) is independent: that one fixed
the cap running fast, this one the stutter when a game cannot hold it.

**The 3.17.0 bump (2026-10-26, ported from Nova-Deck 09b8a3c4).** Every patch was restacked on the
tag as a git series and regenerated with `git diff`, headers kept apart from dated notes. `0014`,
`0017` and `0018` are Nova-Deck's own 3.17.0 re-rolls (we carried them byte for byte, and they lost
their `tests/` hunks: we build with `-Denable_tests=false`, so those never compiled). Real
conflicts, each with a RE-ROLLED note in its header: `0019` (rgba8 gone from the dst images it
wraps), `0027` (upstream now sets `bTransferSrc` itself), `0029` (pooled upscale images and
`oTextureSeqNo`), `0030` (the composite now sits in `if ( !bReuseLastComposite )`), `0035`
(`present_timing` replaced `present_id`). From a pristine 3.17.0 checkout the whole series applies
at --fuzz=0 and the patched tree is identical to the restack tree, libliftoff included.

`0019` — **revision swapped 2026-10-09** for the ROCKNIX fork's current copy of the same patch
(sunshineinabox, fork `0013`, dated 2026-09-10; same `--composite-graphics` flag and
`GAMESCOPE_COMPOSITE_GRAPHICS` env, same behaviour). The body differs from the 3.16.29 port we
carried in three places: `insertBarrier()` now counts `VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT` as a
write (the fragment pass writes the output as an attachment; the old barrier knew only shader and
transfer writes), `cs_sgsr` sits after the fragment shaders in `meson.build` and `rendervulkan.cpp`,
and the "on tilers the fragment pass writes tile-linear" comment went. The swap is what lets
`0026`-`0029` apply at --fuzz=0: they were written against that revision.

`0026`-`0029` — **pre-rotation: rotate with a blit instead of compositing** (sunshineinabox and
kapdon; ROCKNIX fork `next:projects/ROCKNIX/packages/apps/gamescope/patches` 0018/0019/0021/0025 —
the gamescope half of what ROCKNIX calls `DEVICE_PRE_ROTATION`; the Mesa half is
`packages/mesa/patches/0002`-`0013`). Our SM8xxx boards rotate at scanout (`0001`) and never reach
any of it. It is for a panel the plane cannot rotate — SM6115 (MANGMI Air X), which ROCKNIX runs
with `--force-composition-rotation` — where stock gamescope composites EVERY frame on the GPU to
turn it, which on an A610 is most of the frame budget.
  - `0026` keeps the FSR/SGSR upscale-cache image compressed: the preemptive upscale composites
    into an override image, the fragment path (`0019`) was off for every override, so that one
    buffer needed STORAGE usage and turnip left it linear — the buffer that actually reached the
    plane under FSR.
  - `0027` adds `--composite-blit` / `GAMESCOPE_COMPOSITE_BLIT=1`: a frame of exactly one
    unscaled, unoffset sRGB layer at output size with no CTM is copied to the output by the
    transfer engine, rotated with `VK_QCOM_rotated_copy_commands` (Mesa `0002`) when the output
    is rotated. Anything else takes the composite shader. Each decline reason is logged once.
  - `0028` is the DRM backend. With `--composite-blit`, layers the plane cannot rotate are blitted
    into panel-oriented copies (`pBlitRotatedTex`) and scanned out unrotated in their old
    placement, so the plane still scales them: overlays first (the base keeps a rotating pipe),
    then every layer, and every layer where the plane cannot rotate at all (`PrepareScanout()`).
    Only when the planes cannot take even that are the overlays composited into one layer drawn
    in panel orientation and scanned out beside the base; a frame that fits no other way is
    composited whole. The blank Steam overlay plane is painted only where turning a plane on is
    slow (AMD colour management, `NeedsBlankOverlayPlane()`). **Re-rolled by hand on `0014`/`0018`**:
    four `Present()` hunks met our CTM/LUT lines. The merge keeps `!drm_scanout_is_color_managed()`
    after the pre-rotation-aware rotation test, routes both scanout attempts through
    `PrepareScanout()` after the existing `drm_update_crtc_ctm()` calls, and keeps
    `drm_scanout_ctm_is_active()`'s promotion to a full composite ahead of `FillPartialFrame`.
    The patch header lists the four.
  - `0029` (kapdon) keeps attachment-only outputs compressed on the normal path and, when a
    graphics pipeline fails, composites with compute into a storage-capable scratch image and
    copies back, without publishing an unsignaled upscale-cache entry.

`0030` — **a blitted frame keeps the DPU's colour management** (ours, 2026-10-09). `0027`'s copy
is raw, "like direct scanout of that layer" — true on ROCKNIX, where direct scanout is not colour
managed. Here it is: `0014` puts the composite's transform in the CRTC CTM and `0018` the whole SDR
chain in the output LUTs, and a frame the DPU cannot colour manage is forced through the composite
so the shader applies it. A blit on that path would have skipped the shader with the CTM held at
the identity — night mode silently gone, the exact failure `0014` closed. `0030` has the DRM
backend tell the composite whether a raw copy would be colour managed
(`FrameInfo_t::scanoutIsColorManaged`, from `drm_scanout_is_color_managed()`), the blit declines
when it would not (decline reason 12), and a frame that was blitted (`compositeBlitted`) takes the
CTM as a direct scanout does. The output LUTs already apply post-blend to a composited frame and
go on doing so; the plane blits of `0028` were already covered, they sit on the direct-scanout
path whose CTM call precedes them. **Not yet HW-validated on any board** — the series went in
with the SM6115 port and is first exercised when an Air X boots; the regression to watch on the
SM8xxx boards is night mode with `--composite-blit` on a frame that composites anyway (the issue
#106 case on SM8250).

`0031` — **`0027` under makepkg's `-Werror=format-security`** (ours, 2026-10-09). The fork's
`decline()` is a generic lambda; its argument-less reasons instantiate `infof( pszReason )`, a
non-literal format with no arguments, which Arch's CFLAGS make a hard error (ROCKNIX builds
without the flag). `if constexpr ( sizeof...( args ) == 0 )` sends those through `"%s"`. Found on
the first overlay build of the series; the merged `0028` and `0030` compiled clean.

`0032` — **screenshots on a GPU without cached-coherent memory** (ours, 2026-10-10). The A610
has no HOST_CACHED|HOST_COHERENT memory type; a mappable image fell to index -1 and the
screenshot SIGSEGV'd. Falls back to VISIBLE|COHERENT and fails cleanly when nothing fits.

`0033` — **touch on SPI and other SoC touchscreens** (ours, 2026-10-10). Touch is rotated only
when the device is associated with a connector, and the heuristic knew I2C and USB. The Air X's
Himax panel is on SPI: taps landed wrong and scrolling ran backwards.

`0034` — **an unchanged layer keeps its rotated copy** (ours, 2026-10-10). `0028` copied every
layer every frame; the launcher's static overlay over a running game was copied once per game
frame (~0.5 ms each on the A610, half of gamescope's GPU submits). The layer now carries the
commit its texture came from, and the per-slot ring hands back the last copy when texture,
commit and rotation match. Measured on the Air X with God of War: 301 -> 150 gamescope submits
in 3 s, overlay plane fb constant.

`0035` — **a client's pre-rotated buffer is scanned out as is** (ours, 2026-10-10). Mesa's
`vk_wsi_wayland_prerotate` (packages/mesa 0006) copies each present into a rotated buffer in the
client and tags it with a wl_surface buffer transform; gamescope ignored the transform and
rotated it again. The commit now carries the transform, and one equal to the display's rotation
(wl 90/180/270 = `g_uPreRotation` 1/2/3) marks the layer `bPreRotated`, which the DRM backend
of `0028` already places and scans out with no rotation. It is sized as its unrotated self and
never pre-emptively upscaled; `vulkan_composite` and `vulkan_screenshot` copy it back unrotated
(cached per commit) and restore the frame afterwards. Covers X11 Vulkan games and OpenGamepadUI,
whose presents go through the gamescope WSI layer into Mesa's Wayland WSI. Measured on the Air
X: gamescope GPU submits zero in menu and game, total GPU time and fps unchanged.

`0036` — **a touch does not show the cursor** (ours, 2026-10-11). In the default touch click mode
(Left) a touch warps the pointer to the finger and clicks, and the warp revealed the arrow for the
10 s cursor timeout. Passthrough mode hides it but OpenGamepadUI (Godot on Xwayland) does not act
on passed-through touches. Touch-driven warps are now synthetic and hide the cursor; a real mouse
or trackpad shows it again. Air Y: taps still select cards, GAMESCOPE_CURSOR_VISIBLE_FEEDBACK stays 0.

`0040` — **`--secondary-output <connector>`: a second panel next to the main one** (ours,
2026-10-12; dual-screen boards, plan `.claude/plans/gamescope-dual-output.plan.md` step 2). The
secondary output claims its connector, the CRTC and primary plane already driving it (else the
last free ones; never the main output's last ones) and its preferred mode. Taking another CRTC
than the boot console's was the first HW bug: that CRTC stayed active with no connector, so both
the secondary modeset and every main-output modeset failed with EINVAL (both panels black, Thor
Lite 2026-10-12). The main output's selection, modesets and foreign-plane cleanup skip these
objects, and the plane is not registered with libliftoff (liftoff zeroes every plane it knows and
does not use). It is committed with its own raw, non-blocking atomic requests (never jointly with
the main output: the panels are not genlocked), re-modesets after a VT switch or forced modeset,
and its flip events carry their own user data. It shows
black until the compositor paints it (later patches); ConVar `drm_debug_secondary_pattern` flips
it between two greys every vblank and logs the flip rate. No flag, no change.

`0041` — **second-screen windows go to the secondary output** (ours, 2026-10-12; plan step 3).
A window whose `GAMESCOPE_OUTPUT` property is 1, or (without the property) whose title matches
the regex in its Xwayland root's `GAMESCOPE_SECONDARY_WINDOW_TITLE` string property (set by
retroforge-launch from the emulator's `secondary_window_title`, before the emulator starts; no
property, no title rule: gamescope itself names no emulator), is never a focus candidate for the
main output, so it also drops out of
`GAMESCOPE_FOCUSABLE_WINDOWS` and of a `GAMESCOPECTRL_BASELAYER_WINDOW` match (OpenGamepadUI names
the newest window of a game, which was melonDS's `[w2]`). A separate secondary focus shows the
newest such window, sized to the panel with its orientation applied; client resizes of it are
clamped. Painting it is the next patch. Only active with `--secondary-output`.

`0042` — **the secondary output is painted, direct scanout first** (ours, 2026-10-12; plan step
4). On each vblank with new content and no flip pending: on an unrotated panel, a single opaque
buffer the size of the output goes on the secondary plane as is (each FB checked once with a
TEST_ONLY commit); otherwise the frame is composited into one of three panel-sized images,
`vulkan_composite` applying the panel's rotation to that override target (one unscaled layer: the
composite-blit rotated copy). **The plane is never asked to rotate**: on SM8250, 90/270 planes go
through the single offline SDE rotator of kernel patch 0385, which the main output already uses and
which times jobs against one CRTC. (The top-panel stall first seen with a rotated bottom plane --
DPU "frame done timeout", garbage until a session restart -- was the DPU handing an SSPP from one
CRTC to the other while it was still fetching, and happened without rotation too: kernel patch
0397.) The backend holds the queued/visible FBs (client buffers stay locked while on
screen). No colour management on that panel; the main output's repaint/pacing state is untouched.

`0043` — **the secondary touchscreen drives the secondary output** (ours, 2026-10-12; plan step
5). `--secondary-touch-device <input name>` (Thor family: the DTS label, `bottom_touchscreen`)
takes that digitizer off the main panel: its touches are rotated by the secondary panel's
orientation, scaled to its logical size and always passed through to the window shown there,
whose surface the compositor hands to wlserver. They never move the pointer or keyboard focus,
and their ids are offset so the two digitizers never collide. Needs kernel patch 0397 on SM8250
(two outputs committed independently).

`0044` — **the secondary output's direct scanout, rotated on the plane** (ours, 2026-10-12). Lifts
0042's "never rotate": an app buffer with the logical output's aspect goes on the secondary plane
rotated (and scaled) to the panel, each FB and rotation checked once with TEST_ONLY; a refused one
is composited. On SM8250 the plane rotation uses the offline SDE rotator of kernel 0385 that the
main output also uses: HW-clean on the Thor Lite with kernel 0397 (Mario Kart DS, both panels
scanning out melonDS's own buffers, no composite, no DPU/rotator messages). ConVar
`drm_secondary_plane_rotation` (default on) turns it off at runtime.

`0045` — **the secondary output gets its own area of the X screen** (ours, 2026-10-12). Windows
routed by 0041 stayed at 0,0 under the fullscreen main window, and Xwayland routes pointer and
touch by X geometry and stacking, so 0043's touches on the second panel reached the main window.
The game's Xwayland (every server but the shell's when there are several) now gets a second
wl_output for the secondary output, announced to the right of the main one (a bind listener
resends the position wlroots zeroes on bind): the X screen becomes [main][secondary], like sway's
output layout on ROCKNIX, and routed windows are placed and kept in that area. steamcompmgr's
root_width/height keep meaning the main output's area; focus windows are composited regardless
of their X origin, so both panels stay on direct scanout. HW 2026-10-12, Thor Lite: bottom-panel
touch works in melonDS and Azahar, gamescope does no GPU work during play.

`0046` — **the secondary panel is off while nothing is shown there** (ours, 2026-10-12; plan step
7). Once no window has been routed to the secondary output for 2 s (the shell, single-screen
games, boot) its CRTC goes ACTIVE=0 with the plane detached: a DPMS off on its own non-blocking
commit, the mode and the connector's CRTC kept, so the next routed window turns it back on with
the usual first-commit modeset straight onto its frame. The off commit carries an event and
counts as the pending flip. The debug pattern keeps it on; a VT switch redoes the off commit.
ConVar `secondary_output_off_when_unused` (default on). HW 2026-10-12, Thor Lite: the panel's
backlight follows (bl_power 4 off / 0 on), melonDS turns it on directly onto rotated direct
scanout, off 2 s after exit, no DPU timeouts; OGUI menu 360 mA off vs 412 mA on (~0.19 W).

`0047` — **an EDID-less internal panel's native modes become its refresh rates** (gennro, Kettle
Linux `0019`, body unchanged; Nova-Deck's `0026`, renumbered because our `0026` is ROCKNIX's
upscale cache). gamescope fills the dynamic refresh rates of an internal panel that no display
script describes from the connector's modes at the preferred size — but that fallback sits in
`ParseEDID()` after the EDID is parsed, and a DSI panel has no EDID, so it never ran. With the
list empty, Steam's refresh-rate slider only capped fps and the panel never left its top mode.
Measured upstream on the Pocket FIT before the patch (modes 144/120/90/60, slider at 60): CRTC
still 1080x1920@144, `GAMESCOPE_DYNAMIC_REFRESH` = `GAMESCOPE_DISPLAY_REFRESH_RATE_FEEDBACK` = 144,
and a 60 fps-capped game ran at a solid 48 fps (each frame waiting three 144 Hz vblanks). After it,
the slider switches the CRTC (HW-checked upstream on the FIT, 2026-10-14). Kettle's opt-in knobs on
top of it (`ui_refresh_hz`, generated lower rates, `refresh_hz`, `auto_refresh_max_hz`) are not
taken. `ui_refresh_hz` was tried upstream and dropped: it did run the Steam UI at 60 Hz, but
Steam's Quick Access slider kept showing its own stored request (144), so the screen said one rate
while the panel ran another. With no game open, gamescope ignores Steam's request anyway
(`GAMESCOPE_DISPLAY_DYNAMIC_REFRESH_BASED_ON_GAME_PRESENCE`) and runs the panel's highest mode.
Applied last, after the secondary-output series, at fuzz 0.

`0048` — **a refresh-only request switches to that exact mode** (Nova-Deck's `0027`, body
unchanged, renumbered because our `0027` is ROCKNIX's composite blit). With the frame limiter off,
a refresh-rate pick arrives as `set_app_target_refresh_cycle( N, ONLY_CHANGE_REFRESH_RATE )`, and
stock gamescope runs it through the cap's refresh-doubling search: the HIGHEST valid rate N
divides. On a 60/120 panel a 60 Hz pick therefore ran at 120 and the panel never left its top mode
(HW upstream, Odin 3, 2026-10-23: `set display refresh rate: 60` / `refresh cycle: 60 - 0x7`, CRTC
still 120); the Pocket Max went 144 → 120 on "60". `0048` takes the exact rate when the panel
offers it, and only for refresh-only requests — caps keep the doubling, which is what holds a
30 fps game at the panel's top rate for latency. Needs `0047` for an EDID-less panel to have a
rate list at all. Applied after `0047`, at fuzz 0.

`0049` — **Steam on another XWayland sees the focus.** Steam reads `GAMESCOPE_FOCUSED_APP`,
`_FOCUSED_APP_GFX`, `_FOCUSED_WINDOW`, `_FOCUSABLE_APPS` and `_FOCUSABLE_WINDOWS` from the root of
the XWayland it runs on; gamescope sets them on the first one only. Under OpenGamepadUI the shell
is on `:0` and Steam on `:1`, so Steam recognised a game only when the game connected to the client
itself (Proton's `steam.exe` does). A native x86 game under FEX got Steam's Desktop controller
config (`OnFocusWindowChanged to window type: k_nGameIDControllerConfigs_Desktop`) and no Steam
Input. Every later XWayland now gets those atoms for its own windows, and none while the focus is
on another XWayland (the shell's own UI), which is what Steam saw before. Steam's own windows
(`window_is_steam`, or a `steam`/`steamwebhelper` process) are reported as `769`: OpenGamepadUI tags
them with its id for the Steam client, and Steam took its Big Picture window under that id for a
game. HW 2026-10-23, MANGMI Air X, SuperTux (native, FEX) started from the Steam client OGUI
opened: with the atoms copied to `:1` by hand, Steam logged `game window type: AppID 1572920` and
its virtual pad (`28de:11ff`) carried 6 button / 179 axis events where it had 0. Steam's window
under OGUI's id gave a "Last Resort" gamepad config for app 1984639; under 769 it gave `ClientUI`.
Needs OGUI patch 0025 (a game Steam starts keeps its own `STEAM_GAME`).

`0050` — **the boot splash stays up until the shell draws.** gamescope takes DRM master at
its start (~9 s into a boot on the MANGMI Air X) and commits nothing until the shell's first frame
(~17 s). The panel keeps the splash drawer's last frame, but once the drawer has dropped master its
activity bar reaches glass only on a video-mode panel; a command-mode one shows committed frames
only. The drawer (`apps/retroforge-splash`) now writes its frame, in panel orientation, and the
bar's 40 frames as strips of it to `/run/retroforge/splash/handoff`, which `retroforge-session`
names in `GAMESCOPE_BOOT_SPLASH`. Until the shell is drawing, gamescope paints only that: one
screen-sized XRGB8888 layer, double-buffered, the next strip copied into the buffer off screen each
40 ms tick. "Drawing" is three shell frames within 0.5 s, not its first frame: OpenGamepadUI puts
up one empty, transparent frame, then loads for ~7 s before its boot video (HW 2026-10-31, MANGMI
Air X), and ending on that first frame left the panel black for those 7 s. At the latest the splash
goes 20 s after the shell's first frame, and 60 s after gamescope's start. The images take the plane's modifiers (UBWC on msm), and the layer is
pre-rotated, so it scans out with no copy wherever `g_uPreRotation` is set. A panel rotated in the
composite, or a frame drawn for another orientation, gets no splash. Applies with or without
`0049`.

`0054` — **the layer bounds the FIFO queue.** The layer hands the driver MAILBOX and implements
FIFO itself through the gamescope_swapchain protocol, so the swapchain's images are all that limits
how far a game runs ahead. With 3 images, a game faster than the panel keeps 2 frames waiting in
gamescope and then blocks in `vkAcquireNextImageKHR` after it has already read its input.
`vkQueuePresentKHR` on a FIFO swapchain now returns only once at most one of its frames is still
waiting to be latched, so the game blocks before it reads its next input. `GAMESCOPE_WSI_FIFO_QUEUE`
sets the limit (0-3, `off` restores the old queue), and `GAMESCOPE_WSI_FIFO_QUEUE_LIMITED` sets it
while gamescope's frame limiter is active (also 1: with 0, a game needing 31 ms per frame under a
30 fps cap ran at 20 fps). An untimed present gets an internal serial through `set_present_timing`,
which gamescope reports once the frame is latched or discarded, for windows it does not show too.
Presents using `VK_GOOGLE_display_timing` are left alone: that protocol reports no discarded frames,
so a wait on it could stall. The wait starts with the swapchain's first report and gives up after
100 ms. MAILBOX, and swapchains that fall back to Xwayland, are untouched.
HW 2026-11-08, RG 55G1 (61 Hz), Vulkan probe through the layer, synthetic press -> top of the panel,
`off` vs default: a light game 57.0 -> 42-44 ms at 59-61 fps either way; a 30 fps cap 112.7 ->
84.4 ms; 17 ms frames 56.6 vs 56.3 fps; 31 ms frames under the cap 30.5 fps either way.

`0055` — **late input sampling** (opt-in, `GAMESCOPE_WSI_LATE_SAMPLING=1`). With the queue bounded, a
light game still reads its input right after the previous frame was taken and then waits most of a
refresh for the next latch. The layer now holds such a game until it has just enough time left: it
waits for its own frame's present_timing report, then sleeps until the next frame's vblank minus
gamescope's latch lead (3 ms), the slowest release-to-ready time of the last 128 frames, and a margin
(`GAMESCOPE_WSI_LATE_SAMPLING_MARGIN`, default 2000 us). It engages only while all of that fits in one
frame interval, and otherwise keeps `0054`'s bound, so a heavy game loses no frames. A paced frame
shown more than 1.5 intervals after the one before widens the margin by 1.5 ms (decaying 1 us per frame
on time); 4 such misses in 10 s pause it for 10 s. The report arrives, and its latch time is stamped,
when gamescope takes the commit as done, which for FIFO can be most of a refresh before the latch that
shows it; its pixel-out time is the vblank, which is why the hold can run past one interval. Mesa's
`vkWaitForPresentKHR` is not a latch clock here: once a game is held it returns when the game is
released. HW 2026-11-08, RG 55G1, ground truth from `dpu_plane_set_scanout` + vblank timestamps,
synthetic press -> top of the panel: stock 55.0 ms, `0054` 42.9, `0055` light game 15.4 (p90 22.4), with a
6 ms spike every second 23.6, 30 fps cap 24.6 (stock 113, `0054` 84), every frame shown in each; 10 ms
frames stay unpaced (41.5); 17 ms frames 56.1 fps and 31 ms frames under the cap 30.5 fps, as without it.

`0056` — **the KMS device is closed under the wlserver lock** (ours, 2026-11-04). On shutdown
`steamcompmgr_exit()` destroys the DRM backend on the `gamescope-xwm` thread, and `finish_drm()`
closes card0 through libseat from there while `gamescope-wl` still dispatches the same libseat
connection. libseat is not thread-safe. When the dispatch read first, it found seatd's
`DEVICE_CLOSED` reply where it expects only a background event (`Unexpected response: expected
background event, got opcode 32772`), failed with `Bad message`, and wlroots destroyed the session
from its event loop. gamescope's `session_active` listener was still attached, so
`wlr_session_destroy` asserted: SIGABRT on a `systemctl stop retroforge-session`. The event loop
dispatches with the wlserver lock held, so the close now takes it too. HW 2026-11-04, MANGMI Air X,
stop/start cycles 25 s after the session came up: stock aborted on 7 of 32 stops, with the patch on
none of 20. The Air X journal of the 2026-11-07 image without it has the same assert on 23 of 53
stops. mangoapp's own abort on a stop (`X connection to :0 broken`, then `terminate called without
an active exception`) is a different race and happens with or without this patch. Not fixed
upstream as of master 89b9e6e.

Drop the patch files here with those exact names (or rename and update `source.pin`'s
`patches:` line). **Until a declared patch is present, `make overlay` / `make base` fail fast**
with a clear "missing patch" message from `build-overlay.sh`.
