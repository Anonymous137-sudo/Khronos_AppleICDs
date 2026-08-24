# OpenGL_4.6(Core Profile) / Apple_ICD

This is the source tree for AO46, a third-party in-development macOS OpenGL
project with separate legacy and standard-Khronos frontends.

The legacy compatibility product consists of `OpenGL.framework`,
`OpenGL_4.6.framework`, CGL, NSOpenGL, `libGLICD.dylib`, and AO46-specific
user-space bridge dylibs. It is not the frontend for new portable OpenGL apps.

The modern product is under [`khronos/`](khronos/). It uses Mesa-built standard
`libGL.dylib` and `libEGL.dylib`, with AO46's CGL-free Metal Gallium backend
installed beside them. It does not load the framework or legacy ICD/runtime.

AO46's active backend direction is Mesa-to-Metal:

- Mesa supplies OpenGL semantics, state tracking, GLSL, SPIR-V, NIR, and the
  reusable NIR-to-MSL compiler machinery.
- AO46 supplies the shared macOS Metal execution layer and the separate legacy
  framework/CGL/NSOpenGL compatibility path.
- The promoted `GL2MTL/mtl_driver.m` and `mtl_shader_compiler.m` sources now
  implement `AO46MTLGallium`, the active Mesa-facing Metal driver. They do not
  implement OpenGL semantics; Mesa remains the semantic engine.
- `AO46AGXMac` and the direct AGX/UABI work are archived research. Their
  evidence informs backend decisions but they are not the selected runtime
  route or a conformance claim.

AO46 does not reimplement OpenGL 4.6 semantics or a standalone GLSL-to-Metal
compiler. The governing design is
[`docs/AO46MetalBackendPlan.md`](../../docs/AO46MetalBackendPlan.md).

## Layout

- `framework/`
  The real `OpenGL_4.6.framework` driver for the legacy compatibility product.
- `backend/`
  Archived development backend interfaces; not part of the production runtime.
- `GL2MTL/`
  The promoted Metal Gallium screen and NIR-to-MSL connection. Mesa owns GL
  semantics; these sources own Gallium resource/state translation and Metal
  execution.
- `AO46AGXMac/`
  Archived direct-AGX research adapter. See `docs/research/evidence/` for its
  retained observations and raw analysis output.
- `runtime/`
  Framework-side runtime code that implements the driver and owns the framework-to-backend bridge.
- `client/`
  Bridge code used by shims and user-space dylibs to talk to `OpenGL_4.6.framework`.
- `icd/`
  The internal `libGLICD.dylib` dispatch bridge that talks to the framework on behalf of the shims and user-space loaders.
- `shim/`
  The Apple-path loader that is meant to live at `OpenGL.framework/Versions/A/OpenGL` and hand off into `OpenGL_4.6.framework`.
- `drivers/`
  Legacy user-space bridge dylibs such as `libAO46LegacyGL.dylib`,
  `libGLContext.dylib`, and `libNSOpenGLContext.dylib`.
- `khronos/`
  Standard Mesa `libGL`/`libEGL` frontend contract and the CGL-free AO46 Metal
  Gallium backend export used by its Mesa driver registration.
- `scripts/`
  Helper scripts for building, staging, packaging, and live installation.

## First Goal

The first framework milestone is a clean system-driver bring-up with:

- an exact-path Apple `OpenGL.framework` loader target
- a real `OpenGL_4.6.framework` target
- a framework-owned backend boundary that will select Mesa's Metal-backed path
- initial `CGL*` compatibility entrypoints
- Khronos `gl*` forwarding into Mesa

The backend milestone integrates Mesa's reusable NIR-to-MSL machinery with an
AO46 Metal screen, resource, pipeline, synchronization, and presentation
implementation. Until that work and staged CTS are complete, AO46 must not
claim macOS OpenGL 4.6 conformance.

## Current Shape

Right now this subproject is an early in-development driver:

- runtime bootstrap is implemented
- framework, client, ICD, and user-space bridge layering is implemented
- drawable attachment is framework-owned, with `libGLContext.dylib` helper entrypoints for headless or native-window binding
- `CGL*` context, renderer, pixel-format, pbuffer, option, and share-group entrypoints are routed through the framework/ICD/loader path
- `OpenGL_4.6.framework` now carries public `Headers/` and a `Modules/` definition instead of only the binary and `Info.plist`
- `gl*` entrypoints and the backend proc table are generated from a vendored Khronos-facing registry snapshot stored in this repo
- old handwritten GL2MTL state, texture, buffer, pbuffer, and raster paths are archived only; their feature lists are not claims about the production framework
- when a standard Khronos OpenGL token or function name already exists, the code now prefers that Khronos spelling directly; `AO46*` names are reserved for private driver plumbing
- supported-core offscreen CGL contexts create through the promoted Mesa Metal
  screen; GL 4.6 and native-window admission remain fail-closed rather than
  silently selecting archived GL2MTL code or claiming a direct AGX runtime
- the active Metal bootstrap owns a native device, queue, shared buffer,
  compute pipeline, command buffer, completion wait, and GPU readback path;
  it now includes a bounded Mesa `pipe_screen` and graphics-capable
  `pipe_context` where a Mesa NIR shader is lowered through KosmicKrisp,
  compiled as MSL, dispatched, and verified through Gallium fence-backed
  readback. Mesa NIR vertex and fragment stages also compile into one bounded
  interleaved vertex-buffer triangle Metal render pipeline, including one
  vertex-to-fragment varying and fenced color-texture readback. The bootstrap
  has bounded `RGBA8`/`BGRA8` 2D texture allocation, aligned staging
  upload/readback, and color-surface clear. It additionally verifies static
  Mesa NIR `PIPE_TEXTURE_2D` sampling in both graphics stages: a vertex-stage
  `texture(2)`/`sampler(2)` binding and fragment-stage sparse
  `texture(1)`/`sampler(1)` plus `texture(3)`/`sampler(3)` bindings use
  bounded non-mipmapped Gallium sampler states. `nearest`/`linear` filtering
  and `clamp-to-edge`/`repeat` addressing map directly to public Metal; a slot
  shared by both stages must retain the same view and sampler or the draw fails
  closed. This is not yet a broad conformance claim. Mesa now independently
  selects an audited OpenGL 4.1 core ceiling from the promoted screen's
  capability set, while requests above that ceiling continue to fail closed.
- direct AGX device-profile, BO, queue, submission, and shader-residency work
  is retained as research evidence rather than treated as the active blocker
  for the Metal backend

## Three-Lane Feature Status

The active Metal Gallium driver advances older and modern functionality in
parallel, but reports only the core version whose complete Mesa capability
gate is satisfied:

- **Older feature lane:** general `RGB32_FLOAT`, `RGB32_UINT`, and
  `RGB32_SINT` `PIPE_BUFFER` sampler views carry Mesa-selected byte ranges into
  direct Metal buffer roots and pass graphics readback. Bounded Mesa stream
  output now captures two vertex varyings simultaneously into independently
  ranged Gallium targets, preserves both target-relative offsets across an
  unbind/rebind pause, appends a second draw, and verifies all twelve GPU
  records. Gallium stream-output statistics queries report exact
  generated/written primitive counts, and
  `count_from_stream_output` drives a fenced two-triangle draw from the retained
  target. All eleven Mesa OpenGL 4.0 gates are now active, including RGB32
  buffer textures, transform feedback 2/3, and tessellation. The promoted screen
  admits validated Mesa TCS/TES state, default tessellation levels, and
  patch-vertex state. It also executes the bounded Mesa-poly TCS, tessellation-
  count, prefix-sum, tessellator, generated-index, and TES render sequence
  through the production `AO46MTLGallium` context. The same hardware smoke now
  runs against both the retained reference screen and the promoted screen. A
  second promoted-screen path now derives its plan and checked transient
  package directly from ordinary Gallium TCS/TES, patch, framebuffer, and
  `draw_vbo` state; it executes two patches without any AO46-only package or
  pipeline binding. That path now also clones the bound Mesa VS into a
  64-thread software vertex prepass, constructs `poly_vertex_params`, retains
  the packed VS-output allocation, and proves a TCS `gl_in[0]` read through the
  normal Gallium state path. The compute VS prepass now lowers general Gallium
  vertex-buffer `load_input`, honors nonzero first vertex and base instance,
  consumes validated `DrawArraysIndirect` records, and queues retained
  multi-draw patch packages asynchronously on one ordered Metal queue. Mesa's
  poly TCS, count, prefix-sum, tessellator, generated-index, and TES stages use
  one terminal completion wait rather than serial CPU waits between stages.
- **OpenGL 4.3 lane:** Mesa SSBO NIR lowering is connected to compute, vertex,
  and fragment compilation. Static graphics bindings and bounded dynamic
  compute indexing use retained Gallium buffer ranges and pass hardware
  readback. Constant-index Mesa storage images now lower through KK to typed
  direct Metal texture arguments; a Gallium image-load/read-modify-write
  dispatch reads two initialized integer texels, updates them with
  `imageStore`, and reads the exact results back through a fence. A separate
  `R32_UINT` workload dispatches two `imageAtomicAdd` operations in separate
  launches, crosses an encoder-local `PIPE_BARRIER_IMAGE` Metal texture
  barrier, and verifies the exact final value through Gallium readback. A separate
  four-invocation SSBO `atomicAdd` workload updates a retained `MTLBuffer` from
  5 to 17 and verifies it through Gallium mapping. It is now split into two
  dispatches separated by `pipe_context::memory_barrier`; the promoted driver
  emits an encoder-local Metal buffer barrier and retains a finished-submission
  fallback when no compatible encoder is active. General image arrays,
  image queries, arbitrary descriptor indexing, complete robustness, and full
  state-tracker conformance remain pending.
- **OpenGL 4.5/4.6 lane:** clip-control depth modes compile as distinct Mesa
  NIR/Metal pipeline variants and pass hardware clipping tests. The bounded
  indirect-parameters path consumes a GPU-produced count buffer after an
  explicit shader-buffer plus indirect-buffer barrier; both the ordinary and
  per-record DrawID/BaseInstance paths pass hardware readback. Gallium texture
  barriers map sampler/framebuffer visibility to encoder-local Metal scopes
  with a finished-submission fallback. Shaders that
  do not consume draw parameters keep the asynchronous Metal indirect-command
  path. DrawID/BaseVertex/BaseInstance shaders use a bounded completion wait to
  resolve the count, then execute the selected indirect records with exact
  per-record parameter bindings; Metal's inherited ICB buffer state cannot vary
  that Mesa root per command on the current path. Mesa `load_draw_id` also reaches a retained
  per-draw parameter buffer and selects distinct geometry for a validated
  multi-draw readback. The same ABI now carries signed BaseVertex and
  BaseInstance explicitly; a nonzero indexed/base-instance hardware draw
  validates all three shader draw parameters together. Plain indirect
  multi-draw also binds DrawID and BaseInstance independently for each retained
  command record, including a nonzero vertex start. Gallium's
  `texture_barrier` callback is now backed by Metal texture/render-target
  barriers inside an active render encoder, with conservative finished
  submission outside that scope; the hardware smoke exercises this callback
  before fence retirement.

The audited Mesa-selected core ceiling is now OpenGL 4.1. This closes the
OpenGL 4.0 capability gate, but it is not a Khronos conformance result and does
not claim complete OpenGL 4.2, 4.3, 4.5, or 4.6 contexts.

## Build

```bash
cmake -S "OpenGL_4.6(Core Profile)/Apple_ICD" -B "OpenGL_4.6(Core Profile)/Apple_ICD/artifacts/build"
cmake --build "OpenGL_4.6(Core Profile)/Apple_ICD/artifacts/build"
```

## Install Modes

The default `khronos` installer mode installs Mesa's standard `libGL`/`libEGL`
ABI under `/usr/local` and does not query SIP or Authenticated Root. It has a
real Mesa AO46 Gallium driver-registration prerequisite and will fail rather
than silently select the legacy framework or software rendering.

The explicit `legacy-system` installer mode builds from source and installs:

- `/System/Library/Frameworks/OpenGL.framework`
- `/System/Library/Frameworks/OpenGL_4.6.framework`
- `/usr/local/lib`

Only `legacy-system` hard-checks that SIP and Authenticated Root are disabled,
because it replaces protected system frameworks.

## Smoke Coverage

This tree includes runtime and bridge smoke harnesses:

- `tests/AO46RuntimeCompatSmoke.c`
  Exercises renderer enumeration, pixel-format negotiation, context creation, offscreen binding, core `gl*` state, clears, readback, draw calls, indexed draws, bindful and DSA buffer readback/copy/clear paths, indexed buffer-target binding queries, 64-bit buffer queries, immutable and mutable buffer storage/mapping, `glPixelStorei`, `glTexSubImage2D`, `glTexStorage2D`, `glGenerateMipmap`, textured sampling, and pbuffer-to-texture import.
- `tests/AO46CGLShimCompatSmoke.c`
  Drives the Apple-path `CGL*` surface directly and verifies current-context and share-group routing.
- `tests/AO46NSOpenGLCompatSmoke.m`
  Covers the higher-level `libNSOpenGLContext.dylib` bridge.
- `tests/AO46MesaNIRTextureSmoke.c`
  Uploads two four-quadrant `RGBA8` textures from a Gallium buffer, carries
  UVs through Mesa NIR vertex/fragment stages, exercises a vertex-stage
  repeat-plus-linear sample at sparse slot `2`, binds nearest/clamp
  fragment-stage `PIPE_TEXTURE_2D` views/states at sparse slots `1` and `3`,
  and verifies the combined sampled regions after Gallium fence retirement. A
  missing vertex-stage view is rejected before command encoding.
- `tests/AO46MesaNIRSSBOSmoke.c`
  Lowers static and bounded-dynamic Mesa `load_ssbo`, `store_ssbo`, and atomic
  operations through Mesa's generic SSBO pass into AO46's direct `MTLBuffer`
  roots. It verifies a nonzero writable range, sparse and dynamically selected
  ranges, a 32-invocation atomic-add counter, and a serialized atomic exchange
  with its returned values through Gallium fence-backed readback. The active
  vertex/fragment compiler and binder additionally verify a static fragment
  SSBO through graphics readback. Unbounded indexing, robust size queries,
  descriptor tables, cross-dispatch barrier semantics, and complete
  state-tracker SSBO conformance remain fail-closed, so this is a proven
  feature path rather than a complete GL 4.3 claim.
- `tests/AO46MesaNIRBufferTextureGraphicsSmoke.c`
  Compiles RGB32 `FLOAT`, `UINT`, and `SINT` `PIPE_BUFFER` sampler views over
  typeless Gallium buffers through the live sampler-state path. Mesa-selected
  offsets and sizes feed direct Metal address roots; the unsigned variant
  performs fence-backed hardware draw/readback and binding-reuse validation.
- `tests/AO46MesaNIRUniformSmoke.c`
  Loads two fragment-color terms through Mesa NIR `UBO 0` and `UBO 1`, rejects
  missing or undersized bindings, maps nonzero UBO bindings to Metal buffers
  `16..30`, and verifies their summed fenced `RGBA8` output. It also binds
  those resources with Gallium `set_constant_buffer`, rejects missing or
  conflicting vertex/fragment state, and submits the pipeline through
  `draw_vbo`.
- `tests/AO46MesaNIRGraphicsSmoke.c`
  Binds separate per-vertex position and per-instance color buffers through
  Mesa-generated MSL. A two-instance `draw_vbo` with a static divisor of one
  proves native Metal instance stepping through fenced `RGBA8` readback.
- `tests/AO46MesaNIRIndexedSmoke.c`
  Draws Mesa-generated triangle lists from retained `uint16` and `uint32`
  `PIPE_BIND_INDEX_BUFFER` ranges. It rejects malformed counts and out-of-range
  indices before encoding, applies validated base-vertex offsets, splits
  primitive-restart triangle runs, and verifies both indexed and non-indexed
  `pipe_context::draw_vbo` submissions through fenced `RGBA8` output. It also
  validates and natively submits a sequence of `1..64` host-visible indexed or
  non-indexed indirect argument records in one ordered Metal submission,
  retaining the command-argument buffer until fence retirement. A
  Mesa-compute-produced `indirect_draw_count` buffer now selects a public Metal
  ICB execution range in the same command buffer without CPU readback; zero
  and oversized values are GPU-clamped to the bounded sequence. The argument
  records remain CPU-visible and prevalidated. Mesa poly tessellation additionally produces
  one bounded GPU-resident indexed-draw record after its TCS/count/prefix/emit
  stages; AO46 submits that record directly to Metal without a CPU readback.
  A separate attribute-free GPU-authored two-record sequence carries distinct
  base-instance values into Mesa-generated vertex/fragment MSL and verifies
  both outputs after readback; it is groundwork for, not an implementation of,
  general shader-draw-parameter support.
  The plan selects Mesa libkk's triangle, quad, or isoline kernel and the
  adapter derives the matching native triangle/line/point output topology from
  finalized Mesa TES state.
  The production `AO46MTLGallium` target now compiles with Mesa libkk's
  generated kernel catalog and owns this complete bounded sequence rather than
  relying on a test-only or reference-screen copy. Its PIPE_BUFFER resources
  are registered with the low-level MTL4 residency tracker for the lifetime of
  the Gallium resource. The terminal fence covers the generated indexed TES
  draw, while each prerequisite compute stage is ordered and validated before
  that draw. The driver-owned path reuses Mesa's patch-output count, per-vertex
  output mask, output stride, partitioning, point/isoline mode, orientation,
  and default tessellation-level contracts when constructing
  `poly_tess_params`. Its transient heap is overflow checked and sized from the
  number of patches rather than from a smoke-test constant.
  Direct indexed/
  non-indexed draws also carry instance count and base instance to Metal and
  support static per-instance vertex divisors. A bounded `1..64` sequence of
  shader-writable `uint32` indexed argument records can also execute directly
  without a CPU map; the smoke draws complementary halves from two records, so
  both records are required for its verified output. The patch path owns
  TCS/TES NIR state objects and requires both to match the Mesa Poly plan.
  Unbounded GPU-generated batches, generic tessellation-stage execution, and
  general Gallium graphics state remain outside this bounded path.

Run the smoke sweep with:

```bash
ctest --test-dir "OpenGL_4.6(Core Profile)/Apple_ICD/artifacts/build" --output-on-failure
```
