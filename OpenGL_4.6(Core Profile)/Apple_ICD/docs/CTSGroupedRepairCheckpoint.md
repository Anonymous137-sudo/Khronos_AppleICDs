# Full-inventory grouped repair checkpoint

## Baseline and scope

The complete, unfiltered 19,714-case GL 4.6 mustpass baseline is retained at
`ao46-cts/gl46-complete-discovery-20260907-r2`, relative to the workspace
containing this repository. See `AO46_GL_CTS_PIPELINE.md` for its final counts.
All bulk and isolated results belong to one unchanged binary set. The earlier
unsuffixed campaign had an asset-directory error and is not this baseline.

This repair set addresses shared causes in that full inventory. It does not
change CTS expectations, remove cases, or promote unsupported capabilities.

## Built-in shader I/O

NIR store/load types describe bit representations after optimization, not
necessarily the types required by Metal's built-in attributes. The compiler
previously emitted unsigned position vectors (sometimes only one or two
components), signed sample masks, and signed layer indices. The baseline
contains hundreds of these rejected Metal library compilations.

The I/O map now canonicalizes position to float4, point size and depth to
float, and layer/viewport/primitive ID, sample mask, and stencil to uint.
Declarations and emitted stores/loads use the same ABI metadata. Explicit
`as_type` casts preserve bits when NIR storage types differ; changing only a
declaration would instead introduce incorrect numeric conversions. Partial
position stores retain their component masks while the declared position
remains float4. Fragment depth without a conservative-depth qualifier maps
to `depth(any)` instead of asserting.

These attribute requirements follow Apple's
[Metal Shading Language specification](https://developer.apple.com/metal/Metal-Shading-Language-Specification.pdf),
including the fragment-output table (depth float, coverage/stencil uint).
User-defined varying linking remains separate from this built-in correction.

Output reads also distinguish vertex varying locations from fragment render
target locations, retain component selection, and use 64-bit output masks.

`AO46MesaNIRGraphicsSmoke` now checks partial integer-storage position writes,
output reloads, layer/viewport/primitive declarations, signed fragment layer
reads, and depth/sample-mask/stencil casts. The real GPU draw/readback uses
split bitwise position stores and a signed NIR coverage mask.

## SSBO index analysis ordering

The baseline contains 781 cases with the generic unbounded-SSBO diagnostic.
The simple-compute reproducer showed binding zero represented as vector
construction/extract operations from Mesa explicit-I/O lowering. AO46 checked
its range before propagating and folding those constants, rejecting a valid
static binding. It also unnecessarily expanded the associated robust-size
lookup over all slots.

Reuse Mesa `nir_opt_copy_prop` and `nir_opt_constant_folding` to a fixed point
before robust-size lowering and before SSBO range analysis. No buffer limit
or unbounded-index guard is removed. The SSBO regression directly checks the
unoptimized packed-address shape and exact reflected root mask; its existing
hardware readback and genuinely unbounded-index rejection remain covered.

The diagnostic reproducer `KHR-GL46.compute_shader.simple-compute` changes
from Fail to Pass. That single result is debugging evidence, not the full
candidate qualification. `AO46_DEBUG_NIR_ON_ERROR` enables an opt-in NIR dump
for SSBO rejection without adding normal-run log volume.

## Verification

The compiler archive and legacy runtime were rebuilt. All 30 existing CTest
regressions pass with `MTL_DEBUG_LAYER=1`, including the expanded graphics
and SSBO tests. Seven Python bookkeeping regressions pass.

The whole 19,714-case compiler candidate verification completed at
`ao46-cts/gl46-grouped-fixes-20260907-r1`, with the same four workers, batch
size, asset directory, validation setting, timeout, and unfiltered case list.
Its final results are 10,521 Pass, 1 CompatibilityWarning, 4,714 NotSupported,
3,462 Fail, 1,000 CrashOrMissing, 7 ResourceError, 4 InternalError, and 5 Timeout.
All bulk work and isolation finished. Compared with the corrected baseline,
822 actionable cases became Pass, but 279 previous Pass cases became crashes
or timeouts. The net gain of 543 Pass results is not a clean qualification.
`analyze_ao46_gl_cts.py --baseline ...` retains exact status transitions and
previous Pass results that become non-Pass; converting Crash to Fail or Fail
to NotSupported does not count as a fix.

A sampled copy-image stall waits inside Metal command-buffer allocation.
The resource-copy implementation has paths that create a command buffer and
then return without committing it. The sampled
stack is diagnostic evidence, not proof that every stalled case has that cause.

## September 9 grouped repairs

- Copy-region validation and byte-staging allocation precede command-buffer
  acquisition. An autorelease pool bounds temporary submission lifetimes.
  Equal-block-size reinterpretation copies preserve bits through staging;
  array-to-3D and 3D-to-array copies retain the selected Z slices.
- Legitimate attachmentless render passes use Gallium's framebuffer width,
  height, sample count, and layer count. Failed attachment view creation is
  not silently treated as an attachmentless pass. Depth-only passes no longer
  bind that texture to the stencil attachment.
- A compute barrier that includes framebuffer scope ends/submits the encoder
  through the existing ordering path instead of passing Metal's render-target
  scope to a compute encoder or discarding the requested dependency.
- Mesa's six medium-precision conversion opcodes use the existing typed MSL
  conversion emitter. They have the same conversion semantics as their 16-bit
  counterparts; the `mp` distinction permits later optimizer removal, not an
  unsupported runtime operation. The former `ALU i2imp` placeholder caused
  rejected MSL in sample-mask and other workloads.

The adapter regression verifies 1,024 rejected copies do not exhaust queue
slots, checks bit-exact slice/format copies including untouched slices, and
checks all 64 SSBO values written by a fragment shader without attachments.
The latter also executes a medium-precision integer conversion. The compute
indirect-count regression includes framebuffer scope before verifying the
resulting draw. The compiler test checks all six medium-precision conversion
forms and their vector destination types. All 30 local CTest cases pass with
Metal validation enabled; eight CTS bookkeeping tests pass. The analyzer now
retains Metal's detailed validation reason after its generic assertion header,
so texture-type and layer-count failures no longer share one opaque bucket.

Whole-list verification of this unchanged candidate completed at
`ao46-cts/gl46-grouped-fixes-20260909-r1`. Its manifest retains binary, runtime,
asset, and case-list fingerprints; logs, QPA records, local regression results,
and tracked parent/Mesa worktree patches are retained alongside it. These
patches include earlier uncommitted work and are not a standalone commit.

All 19,714 cases and 2,653 isolation reruns finished in 712.043 seconds:
10,997 Pass, 1 CompatibilityWarning, 4,714 NotSupported, 3,274 Fail,
712 CrashOrMissing, 7 ResourceError, 4 InternalError, and 5 Timeout.
Compared with the September 7 compiler candidate, 476 cases became Pass and
no previous Pass was lost. Another 86 crashes became ordinary failures;
54 former failures instead reached a crash. Neither transition counts as
a correctness fix. The remaining actionable inventory is 4,002 cases.

## September 11 array-view repairs

Sampler-view texture types now follow Gallium's requested target for 1D/2D
arrays even when only one layer is selected. A cube-array view containing
exactly six faces remains a cube array, not a plain cube. Previously these
views contradicted the array types emitted by the shader compiler.

Render passes with attachments also set their layer count using Mesa's
`util_framebuffer_get_num_layers`; an ordinary one-layer framebuffer still
requires a nonzero Metal layer count when the vertex shader writes layer zero.
The existing attachmentless default-parameter handling remains intact.

The hardware regression selects a nonzero starting layer (or cube), then
checks distinct RGBA values from each array type in both VS and FS. It clears
the output before each draw, so stale pixels cannot make a dropped draw pass.
The vertex shader writes layer zero to exercise the render-pass contract.
The 1D test uses native non-mip sampling; explicit LOD on native 1D textures
is a separately observed compiler/resource lowering gap, not solved by this
array identity fix. No shader operation is silently dropped by the driver.

All 30 local CTest regressions and eight bookkeeping tests pass for this
candidate. The unchanged 19,714-case verification completed at
`ao46-cts/gl46-grouped-fixes-20260911-r1` with four workers and full isolation:
11,020 Pass, 1 CompatibilityWarning, 4,714 NotSupported, 3,424 Fail,
539 CrashOrMissing, 7 ResourceError, 4 InternalError, and 5 Timeout.
All 2,105 isolation reruns finished; total elapsed time was 699.078 seconds.
Compared with the September 9 run, 23 crashes became Pass and 150 became
ordinary Fail. No previous Pass was lost. Only the 23 Pass transitions count
as corrected CTS cases; 3,979 actionable cases remain in this snapshot.

## Compiler-loop convergence

The retained `fp64-shard140.sample.txt` locates one `frexp_double` stall in
`ao46_mesa_simplify_buffer_indices`, predominantly repeated NIR constant
folding. Source inspection of Mesa's `merge_vec_and_mov` and
`copy_propagate_alu` establishes why copy propagation needs dead-code cleanup:
it can replace a swizzled move with a vector while retaining the dead original
move. Without DCE, AO46's fixed-point loop repeatedly rebuilds it.

The loop now includes Mesa `nir_opt_dce`. No iteration cap, timeout extension,
skipped shader, or suppressed diagnostic substitutes for convergence. The
SSBO test includes a swizzled vector with distinct components reproducing this
shape. Its unbounded-index rejection test stores the loaded value, keeping
that access observable through legitimate dead-code elimination.

The entire 659-case FP64 preflight at
`ao46-cts/gl46-fold-loop-preflight-20260911` finished in 105.888 seconds with
656 Pass and three semantic Fail results, using a 30-second shard timeout
and two workers. All four former FP64 timeouts now pass; the remaining three
FP64 failures are not declared fixed. This focused debugging run is separate
from full-list qualification of the compiler change.

The unchanged full-list candidate at
`ao46-cts/gl46-grouped-fixes-20260911-r2` completed all 19,714 cases and
2,066 isolation reruns in 380.809 seconds: 11,027 Pass,
1 CompatibilityWarning, 4,714 NotSupported, 3,422 Fail, 539 CrashOrMissing,
7 ResourceError, 4 InternalError, and zero Timeout results. Compared with
the preceding September 11 run, seven actionable cases became Pass and
no previous Pass was lost. Four are the FP64 timeouts; the other three are
compute SSO, compute-generated indexed indirect drawing, and matrix indexing.
The former `vertex_attrib_64bit.vao` timeout now finishes as an ordinary Fail,
not a correctness fix. The remaining actionable inventory is 3,972 cases.
Raw logs, QPA records, fingerprints, worktree snapshots, and exact case-level
status transitions remain with the campaign. All 30 local CTest regressions
and eight bookkeeping tests pass for this candidate.

## September 12 typed staging readback

The constant-expression group was not uniformly a GLSL constant-folding
failure. A retained `array_abs_int_fragment` trace shows correct generated
MSL (`int(2)`) and a submitted point draw, followed by zero staging readback.
Direct Gallium point rendering succeeds with generated positions and both
two- and four-component vertex buffers, including both viewport orientations.
Adding the R32_SINT-to-RGBA32_SINT staging blit makes all six regression
variants fail on the previous driver. AO46's format-conversion callback
silently rejected all integer formats, while its floating-point conversion
always passed through RGBA8, clamping and quantizing values unnecessarily.

The existing CPU color conversion now reuses Mesa `util_format_translate`
instead of handwritten unpack-to-RGBA8/repack glue. Signed, unsigned, and
floating-point conversions retain their respective typed paths. The scope
remains uncompressed, single-sample color conversions without resizing;
mixed integer classes, depth/stencil, and other unsupported blit shapes are
not declared implemented. Scissor clipping is applied before selecting
format conversion, preserving source offsets and untouched destination pixels.

The regression also checks values beyond float's exact integer range,
negative and large unsigned integers, out-of-[0,1] and precision-sensitive
floats, default missing channels, and scissored subrectangles with sentinels.
All 30 local CTest regressions pass with Metal validation, and eight harness
bookkeeping tests pass. The entire 1,392-case constant-expression debugging
run at `ao46-cts/gl46-typed-readback-preflight-20260912` finishes with
944 Pass and 448 Fail, compared with 314 Pass and 1,078 Fail in the previous
whole-list inventory. This is diagnostic group evidence, not full candidate
qualification.

The corresponding full-list campaign at
`ao46-cts/gl46-grouped-fixes-20260912-r1` completed all 19,714 cases in
207.736 seconds: 11,768 Pass, 1 CompatibilityWarning, 4,714 NotSupported,
2,681 Fail, 539 CrashOrMissing, 7 ResourceError, and 4 InternalError. Relative
to the September 11 clean baseline, 747 actionable cases became Pass but six
previous Pass cases became Fail. The candidate was therefore not accepted as
a regression-free qualification even though its net strict-Pass gain was 741.

## September 13 submission and multisample repairs

Compute shader buffers are now declared to Metal with explicit read/write
resource usage according to their Gallium binding. The MSL path dereferences
these buffers through raw device pointers; relying on `setBuffer` alone left
compute-produced indirect, vertex, and index records intermittently unordered
for later encoders. Both compute-to-indirect CTS cases pass in three repeated
isolated campaigns after this change. The complete
`gl46-grouped-fixes-20260913-r1` run retains 11,772 Pass,
1 CompatibilityWarning, 4,714 NotSupported, 2,677 Fail, 539 CrashOrMissing,
7 ResourceError, and 4 InternalError in 223.881 seconds. It recovers four of
the September 12 lost Pass results; the remaining two pass ten out of ten
times in fresh processes and fail only after preceding fragment-link failures
inside the same 32-case process.

Gallium represents ordinary single-sample resources with `nr_samples == 0`.
The Metal resolve gate incorrectly required exactly one, allowing valid
multisample-to-single-sample resolves to fall through to an invalid raw copy.
AO46 now normalizes that representation. The reverse direction uses a bounded
render expansion: a typed fullscreen shader reads the requested single-sample
source region and broadcasts it to every sample in a 2D multisample target.
Raw texture copies reject any remaining sample-count mismatch before creating
a Metal encoder. The adapter regression uploads RGBA8 data, expands it to four
samples, resolves it, and verifies exact bytes through Gallium mapping.

Metal validates every statically declared texture argument even when runtime
control flow does not sample it. Sample-variable shaders can legally leave an
inactive normalized view bound to a GLSL integer sampler; binding it directly
to MSL's integer texture argument aborted validation. AO46 now derives static
sample/fetch scalar classes from NIR and supplies a matching dummy texture only
for incompatible inactive bindings. Texture-size, level, and other query
instructions are excluded because their integer result type is not the sampled
texture type. In fresh-process runs of both 190/191-case sample-variable
groups, all 144 prior Metal aborts disappear, 56 become strict Pass, 128 become
ordinary Fail, and no prior Pass is lost.

The intermediate 32-case campaign at
`ao46-cts/gl46-grouped-fixes-20260913-r2` completed in 198.818 seconds with
11,822 Pass, 1 CompatibilityWarning, 4,714 NotSupported, 2,805 Fail,
361 CrashOrMissing, 7 ResourceError, and 4 InternalError. Compared with r1,
58 actionable cases became Pass and 178 crash outcomes disappeared. Eight
prior Pass results were contaminated by an earlier abort in their shared
process; every one passes when rerun independently. A final one-case-per-process
whole-list campaign is required for authoritative per-case totals.

No commit, push, installer update, or release is performed by this checkpoint.

## September 13 isolated qualification and resource repairs

The required one-case-per-process qualification completed at
`ao46-cts/gl46-isolated-candidate-20260913-r1`. It ran all 19,714 mustpass
cases in 1,264.549 seconds and produced 11,831 Pass, 1 CompatibilityWarning,
4,714 NotSupported, 2,803 Fail, 354 CrashOrMissing, 7 ResourceError, and
4 InternalError results. Relative to the September 11 baseline, 804
actionable cases became Pass and no previous Pass became non-Pass. This is
the authoritative status snapshot for the submission, resolve, and inactive
typed-texture repairs; unlike a shared-process campaign, an abort cannot
contaminate a later case in the same worker.

Metal exposes some packed pixel formats as ordinary textures but rejects
them as texture-buffer views. AO46 now excludes RGB9E5 and BGR10A2 from the
buffer-texture capability and separately excludes shader-write BGRA8 buffer
views while preserving legal read views. The production adapter smoke checks
those distinctions. In the 1,577-case packed-pixel PBO group this, together
with the attachment and depth/stencil fixes below, changes 1,432 Pass,
101 Fail, and 44 Crash results into 1,470 Pass, 107 Fail, and zero Crash
results. Ordinary semantic failures remain failures.

Render-pass construction now verifies the native Metal attachment objects,
not only the Gallium surface wrappers. A requested attachment whose native
view could not be created is rejected before encoding instead of becoming an
invalid targetless Metal render pass. This removed 35 targeted validation
aborts; the affected unsupported rendering shapes now terminate as ordinary
Fail or NotSupported results rather than crashing the process.

Packed depth/stencil CPU transfers no longer use Metal's illegal combined
`getBytes`/`replaceRegion` path. Z24S8 and Z32FS8 use aligned shared staging
buffers, separate depth and stencil blits, and explicit bidirectional packing.
Z24 quantization multiplies in double precision so depth 1.0 maps to
0x00ffffff without overflowing. A byte-exact hardware regression exercises
both formats, and four representative depth/stencil CTS cases pass.

Mipmap generation is a no-op for a one-level texture and rejects packed
depth/stencil generation before creating an invalid color blit. Six former
Metal aborts now complete without crashing: four depth shadow-query cases
Pass, while direct-state-access mipmap generation and a native 1D sampler
case remain ordinary unresolved results. General native 1D mipmapping still
requires a coherent 1D-to-2D resource and shader ABI and is not claimed.

## KosmicKrisp stage-I/O arrays and vertex ranges

Four stale single-slot assertions were removed from KosmicKrisp's stage-I/O
map. The remaining failure demonstrated that dynamically indexed MSL struct
members are not a supported ABI. AO46 therefore advertises no indirect stage
inputs or outputs to Mesa, allowing Mesa's existing lowering to produce
static slot accesses before NIR-to-MSL emission. This is capability-accurate
lowering, not assertion suppression.

An 89-case matrix/array and vertex-input reproducer changed from 50 Pass,
3 Fail, and 36 Crash results to 76 Pass, 12 Fail, and one Crash after the
stage-I/O correction. The last abort was a real Metal vertex-range violation:
the declared float4 element needed 16 readable bytes after its offset while
the supplied buffer retained only 12. AO46 now computes the minimum declared
span and uses a zero-filled retained staging buffer only for undersized tail
ranges; valid buffers remain zero-copy. That final case passes under Metal
validation, eliminating the original 36-crash cluster. The 12 remaining
semantic failures are not promoted.

The fast whole-list campaign at
`ao46-cts/gl46-grouped-fixes-20260913-r3` predates the final stage-I/O and
vertex-range corrections. It completed in 162.965 seconds with 11,939 Pass,
1 CompatibilityWarning, 4,728 NotSupported, 2,911 Fail, 124 CrashOrMissing,
7 ResourceError, and 4 InternalError results. It found 109 new Pass results
relative to the isolated r1 snapshot. Its one apparent lost Pass succeeds in
a fresh-process recheck, establishing shared-process contamination rather
than a deterministic regression.

Because r3 predates the last compiler and vertex fixes, it remains diagnostic
evidence rather than an authoritative aggregate.

The replacement one-case-per-process qualification completed at
`ao46-cts/gl46-isolated-candidate-20260913-r2`. It ran all 19,714 cases plus
80 isolated crash/missing confirmations in 823.169 seconds: 11,973 Pass,
1 CompatibilityWarning, 4,728 NotSupported, 2,920 Fail, 80 CrashOrMissing,
7 ResourceError, and 5 InternalError results. Compared directly with isolated
r1, 142 actionable cases became Pass and zero previous Pass results became
non-Pass. Another 117 crashes became ordinary Fail, 14 became NotSupported,
and one became InternalError; those transitions improve process safety but do
not count as correctness fixes. The remaining actionable inventory is 3,012.

The largest remaining crash signatures are now bounded and concrete: 20 bad
four-dimensional texture paths, 18 invalid depth/stencil texture-dimension
descriptors, 36 texture read-overload compiler failures split across three
signatures, nine unsupported/unbounded image bindings, eight duplicate static
UBO bindings, seven invalid Metal texture views, and two native 1D-array
mipmap descriptors. Smaller isolated pipeline-link, unsupported sample-count,
and texture/view signatures remain in the retained report. These are the next
grouped repair inputs; they are not hidden by shared worker state.

The current source passes all 30 CTest regressions with Metal validation,
all eight Python CTS bookkeeping tests, and both parent and Mesa `diff --check`.
No commit, push, installer update, release, or conformance claim is performed
by this checkpoint.
