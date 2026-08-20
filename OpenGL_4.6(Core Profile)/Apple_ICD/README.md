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
- `GL2MTL` is archived development material, not the active semantic engine or
  a framework fallback.
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
  Archived Metal development code. It is not the production OpenGL semantic
  engine and is not linked by default.
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
  upload/readback, and color-surface clear. It additionally verifies a static
  fragment NIR texture sum driven by a vertex-buffer UV varying, through sparse
  public Metal `texture(1)`/`sampler(1)` and `texture(3)`/`sampler(3)`
  arguments plus immutable nearest/clamp Gallium sampler views. This is not yet
  a broad OpenGL feature claim. The current state tracker reaches an audited
  OpenGL 3.3 core ceiling, while GL 4.6 requests continue to fail closed.
- direct AGX device-profile, BO, queue, submission, and shader-residency work
  is retained as research evidence rather than treated as the active blocker
  for the Metal backend

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
  UVs through Mesa NIR vertex/fragment stages, binds constrained
  `PIPE_TEXTURE_2D` sampler views/states at sparse slots `1` and `3`, and
  verifies their combined sampled regions after Gallium fence retirement.
- `tests/AO46MesaNIRSSBOSmoke.c`
  Lowers static-index Mesa `load_ssbo`, `store_ssbo`, and atomic operations
  through Mesa's generic SSBO pass into AO46's direct `MTLBuffer` roots. It
  verifies read/write output plus a 32-invocation atomic-add counter through
  Gallium fence-backed readback. Dynamic indexing, robust size queries,
  descriptor tables, cross-dispatch barrier semantics, and complete
  state-tracker SSBO binding remain fail-closed, so this is groundwork rather
  than a GL 4.3 feature claim.
- `tests/AO46MesaNIRBufferTextureGraphicsSmoke.c`
  Compiles static RGB32 `FLOAT`, `UINT`, and `SINT` `PIPE_BUFFER` sampler
  views through the live Gallium sampler-state path. Its unsigned variant also
  performs the existing fence-backed hardware draw/readback and binding-reuse
  validation; generalized Mesa sampler views remain pending.
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
  The plan selects Mesa libkk's triangle, quad, or isoline kernel and the
  adapter derives the matching native triangle/line/point output topology from
  finalized Mesa TES state.
  Direct indexed/
  non-indexed draws also carry instance count and base instance to Metal and
  support static per-instance vertex divisors. A single shader-writable indexed
  argument record can also execute directly without a CPU map. The patch path
  owns TCS/TES NIR state objects and requires both to match the Mesa Poly plan.
  GPU-generated multi-record batches, generic tessellation-stage execution,
  and general Gallium graphics state remain outside this bounded path.

Run the smoke sweep with:

```bash
ctest --test-dir "OpenGL_4.6(Core Profile)/Apple_ICD/artifacts/build" --output-on-failure
```
