# Image-query CTS checkpoint

## Scope

This pass extends the existing Mesa/KosmicKrisp compiler and AO46 Metal
resource binding. It does not replace Mesa shader semantics or establish
full OpenGL conformance.

Changes cover static image size/sample-query lowering and MSL type inference,
rectangle image coordinate representation, single-face cube image views,
buffer-texture row stride and backing-buffer range validation, and selected
mip views for 3D images. The hardware storage-image smoke now uses imageSize
to guard its load/store path.

## Verification

- Framework, compiler archive, Gallium library, and adapter smoke rebuilt.
- All 30 registered CTest tests passed after the final changes.
- Full KHR-GL46.shader_image_size.* group: 74 cases, two workers, one case
  per shard, 40-second timeout, isolated crash reruns.
- Final results: 11 Pass, 21 Fail, 36 NotSupported, 6 CrashOrMissing.
- Initial image-query run in this investigation: 1 Pass, 13 Fail,
  36 NotSupported, 24 CrashOrMissing.
- Evidence directory relative to the workspace parent: ao46-cts/image-query-fix-r6.
- CTS binary identifies as vulkan-cts-1.4.6.2-452-gcf7edb26d3be2d8763595ed08fdc41f3c1b1966f;
  the executed cases are OpenGL KHR-GL46 cases, not Vulkan cases.

NotSupported is not counted as Pass. These results are a targeted group,
not an updated full-suite total. Earlier intermediate runs retain their logs.

## Remaining evidence

- Advanced compute float query returns (2, 2, 18) where (2, 2, 3) is expected
  for image unit 4: inspect cube-array face versus cube-count representation.
- Fragment shader compilation rejects a signed primitive_id stage input.
- Six geometry-stage cases still crash and require separate lowering/execution
  fixes. They are not resolved by the static-image compiler changes.
- Multisample and other unsupported cases remain classified, not waived.

No release, capability uplift, commit, or push is implied by this checkpoint.

## Follow-up: view-state initialization and primitive ID

The cube-array discrepancy was a view-type mismatch, not missing division by
six. Runtime diagnostics showed a texturecube_array shader input bound to a
2D-array Metal view because is_2d_view_of_3d was not initialized on every Mesa
state-tracker conversion. Initialize it to false before selecting the 3D case,
and only consult it for 3D resources in AO46's view-type selection.

Fragment primitive-ID inputs now use the unsigned type required by Metal.
The NIR load uses an explicit bit-preserving conversion to its inferred result
type rather than changing GLSL signedness.

Verification after rebuilding libmesa.a, libmsl_compiler.a, and AO46:

- All 30 registered CTest tests passed.
- Image-size group: 19 Pass, 13 Fail, 36 NotSupported, 6 CrashOrMissing
  across 74 cases, up from 11 Pass in the preceding checkpoint.
- Evidence: ao46-cts/image-query-next-r1.
- Additional image load/store coverage: 18 Pass, 20 Fail, 2 NotSupported,
  11 CrashOrMissing across 51 cases.
- Evidence: ao46-cts/image-load-store-view-regression. This is a current
  snapshot, not proof of a before/after improvement for that separate group.
- Both runs used two workers, individual shards, and isolated crash reruns.
- git diff --check passed for the Mesa changes and AO46 driver file.

The six image-size geometry cases still abort on unlowered dereferences.
TCS/TES image-size cases still fail. These execution paths, and the broader
image load/store failures, are not resolved by this follow-up.

## Follow-up: geometry compute image lowering

The common AO46MesaComputePipelineCreateWithStaticBuffers path now applies the
same static-image lowering used by ordinary compute compilation before KK
preprocessing. Geometry main/count/pre compilation uses this path. Reflection
records required image units, including when an earlier caller already rewrote
the image intrinsics. The buffer-only direct/indirect dispatch helpers reject
image-dependent pipelines rather than submitting with unbound textures.

AO46MesaNIRComputeSmoke now verifies that repeated lowering retains image unit
3 in reflection and compiles a real image-size query into Metal texture slot 19.

Verification:

- Full configured build completed and all 30 CTest tests passed.
- Image-size group: 19 Pass, 19 Fail, 36 NotSupported, zero crashes (74 cases).
- Evidence: ao46-cts/image-query-geometry-r1.
- Image load/store: 20 Pass, 23 Fail, 2 NotSupported, 6 CrashOrMissing (51 cases).
- Evidence: ao46-cts/image-load-store-geometry-r1.
- This removes six image-size crashes and five load/store crashes relative to
  the preceding follow-up, with two additional load/store passes.

The geometry pipeline records are constructed but are not yet scheduled by
draw_vbo. Compiling them without dereference aborts does not establish geometry
execution. GS image-size cases now report ordinary failures. TCS/TES image-size
execution remains incomplete. The remaining load/store crashes include an
emit_static_images type-consistency assertion in basic-allTargets-atomic.

## Follow-up: signed image atomics

NIR uses unsigned types for sign-independent atomic operations, including add
and compare-exchange. Static image declarations must instead follow the typed
image format. The MSL emitter now uses that format for integer atomics and
bit-preserving casts for operands/results, including compare-exchange scratch.
This retains signed min/max semantics without confusing them with the NIR
representation of add/exchange.

The hardware adapter smoke now covers both R32_UINT and R32_SINT images with
mixed loads, stores, atomic add, and compare-exchange. The signed run begins at
-20, includes signed min against +1, and verifies -6 after two dispatches.
The unsigned run still verifies 19. All 30 CTest tests passed after rebuilding.

CTS results:

- Image load/store: 19 Pass, 28 Fail, 2 NotSupported, 2 CrashOrMissing.
  Evidence: ao46-cts/image-atomic-types-r1.
- Four former atomic compiler crashes now reach ordinary output failures;
  their full CTS semantics are not solved.
- advanced-sync-bufferUpdate passed in the preceding batch but failed in
  this batch and an isolated rerun at buffer index 1. Its shader has only an
  imageStore, not atomics. Causality remains unproven; retain this discrepancy
  rather than claiming a regression-free load/store group.
  Isolated evidence: ao46-cts/image-buffer-update-isolated.
- Image-size coverage is unchanged: 19 Pass, 19 Fail, 36 NotSupported, no
  crashes. Evidence: ao46-cts/image-query-atomic-regression.
- The two remaining load/store crashes are multiple-uniforms (vertex attribute
  references a buffer with no stride) and non-layered_binding (unsupported
  native 3D-to-2D texture-view creation).

Geometry scheduling, tessellation execution, image target coverage, and
synchronization correctness remain required work; no conformance claim follows.

## Follow-up: invalid native descriptors

Zero-stride Gallium vertex elements now use Metal constant stepping with a
nonzero layout extent covering all attributes sharing the buffer. The hardware
adapter smoke multiplies generated vertex positions by a zero-stride float4
attribute backed by one retained buffer element, exercising repeated fetches
through the existing graphics/readback tests.

Non-layered 3D image binding no longer attempts a native 3D-to-2D Metal view.
It returns a failed binding with a diagnostic identifying the mip and depth
plane. This is crash prevention, not implementation of the missing image-slice
semantics. Correct execution still needs native 3D image operations with the
bound depth coordinate, consistent image-size results, and matching shader
specialization/resource binding. Copying a temporary slice is not an alias-safe
replacement for that contract.

Verification: all 30 CTest tests passed, including zero-stride hardware coverage.
All 51 image load/store cases completed without process crashes: 19 Pass,
30 Fail, 2 NotSupported. Evidence: ao46-cts/image-view-crashes-r1.
The annotated multiple-uniforms and non-layered_binding cases both remain Fail.
The former now reports incorrect copied/negated image values rather than a
vertex-descriptor abort; the latter explicitly reports unsupported slice
lowering. Neither should be marked CTS-complete.

## Follow-up: buffer image access and submitted-work completion

Buffer-backed image views now include Metal ShaderWrite usage when Gallium
requests write access; sampler-only buffer views remain ShaderRead-only.

The advanced-sync-bufferUpdate failure was reproduced independently. A memory
barrier submitted the render command buffer and discarded its completion
handle. A later CPU read map requested FINISH, but with no current command
buffer there was nothing left to wait on. The context now retains its last
adapter submission, waits on it for synchronous finish/read maps, and retires
it during replacement or context destruction. Ordinary barriers remain
nonblocking on the legacy Metal submission path.

The SSBO hardware regression now explicitly flushes asynchronously before
buffer_map(PIPE_MAP_READ), rather than performing a finish first. All 30 CTest
tests pass. The isolated advanced-sync-bufferUpdate CTS case passes with
Metal validation enabled (ao46-cts/image-buffer-finish-r1).

The exact 51-case core image-load/store group now reports 20 Pass, 29 Fail,
2 NotSupported, and no process crashes without Metal validation enabled
(ao46-cts/image-buffer-finish-core). This is one additional pass compared with
the preceding checkpoint, not completion of image-load/store semantics.

A broader 90-case run, including ES 3.1 compatibility cases and Metal
validation, reports 31 Pass, 53 Fail, 2 NotSupported, and 4 CrashOrMissing
(ao46-cts/image-buffer-finish-group). Validation exposes 2D-array textures
bound to shaders expecting 2D images in basic-glsl-misc, its ES fragment
counterpart, and non-layered_binding. The ES basic-allTargets-atomicFS case
asserts in emit_src_component in msl_type_inference.c. These remain actionable
failures; the non-validation no-crash result does not establish valid bindings.

Closer inspection of multiple-uniforms shows its vertex and fragment portions
succeed, while geometry, TCS, and TES portions report incorrect data. General
stage scheduling remains required, rather than another generic format fix.

## Follow-up: single-layer array bindings and dead vector emission

Image view creation now honors Gallium single_layer_view when selecting native
1D/2D and multisample views of array resources, including cube faces. Layer
count is not used to infer layeredness: a genuinely layered one-layer array
must remain an array. The hardware storage-image smoke now writes and reads
the second layer of a 2D array through a non-array shader image binding.

LLDB localized the ES basic-allTargets-atomicFS assertion to an untyped vec4
feeding an unused ALU result. Running Mesa nir_opt_dce immediately before MSL
type gathering/emission removes that dead chain without assigning an arbitrary
type or suppressing assertions. A direct emitter regression supplies a dead
vector chain without compiler preprocessing to cover this boundary.

With Metal validation enabled, all 90 image-load/store cases now complete:
31 Pass, 57 Fail, 2 NotSupported, zero crashes. The four former crash cases
become ordinary failures, not passes. Evidence: ao46-cts/image-dead-vector-r1.
The core 51-case run with validation also completes with 20 Pass, 29 Fail,
2 NotSupported (ao46-cts/image-single-layer-r1).

Both new regressions pass with Metal validation. The full debug-layer CTest
run reports 29/30 passing: AO46MesaNIRBufferTextureGraphicsSmoke aborts because
buffer offsets 12 and 36 do not satisfy its shader's 8-byte alignment. This
separate RGB32 binding contract requires correction; normal-mode success is
not evidence of a valid Metal binding.

The former atomic compiler assertion now reaches a Metal pipeline-creation
error for air.atomic_fetch_add_explicit_texture_cube.s.v4i32. Cube-image
atomic lowering, non-layered 3D slice semantics, and general geometry/TCS/TES
execution remain unresolved.

## Follow-up: executable cube atomics and RGB32 ranges

Static raw buffer bindings now use a byte-addressed RawBuffer declaration
instead of the 8-byte-aligned root Buffer container. The root/UBO ABI is
unchanged, and loads continue to use typed casts. The existing RGB32 hardware
test retains offsets 12 and 36 and now passes Metal validation with correct
readback; its offsets were not rounded or copied into staging storage.

Static cube image declarations and native image views now use 2D face arrays.
NIR's flattened face index is passed as the array layer; cube-array image-size
queries divide face count by six, consistent with Mesa nir_lower_image.
Sampled cube textures remain on the sampler path.

With Metal validation enabled, the 90-case image-load/store group improves
from 31 to 34 Pass: 54 Fail, 2 NotSupported, zero crashes. Newly passing cases:

- KHR-GL46.shader_image_load_store.basic-allTargets-atomicCS
- KHR-GL46.shader_image_load_store.basic-allTargets-atomicVS
- KHR-GL46.es_31_compatibility.shader_image_load_store.basic-allTargets-atomicVS

Evidence: ao46-cts/image-cube-array-r1. All 30 regression tests now pass with
Metal validation, including RGB32 offset readback. Compiler source-shape
assertions were updated to expect RawBuffer for static resource bindings.

The next 74-case image-size batch retains 19 Pass, 19 Fail, 36 NotSupported,
zero crashes (ao46-cts/image-cube-size-r1). The isolated ES fragment atomic
case now creates its pipeline and submits the draw, but returns zero output
records; fragment execution/coordinate and buffer-range handling require
further diagnosis (ao46-cts/image-fragment-atomic-trace). Non-layered 3D
slice semantics and geometry/TCS/TES scheduling are not completed here.
