# AO46 Mesa Metal Backend Plan

Status: governing work-in-progress architecture. The standard Khronos ABI
frontend is complete and frozen at its surfaceless/pbuffer GL 3.3 boundary
while AVK143 is developed; this plan governs AO46 work when it resumes. It
supersedes the direct AGX/UABI route as the active runtime strategy; the direct
route and its captured evidence remain preserved research.

## Goal

AO46 is a macOS OpenGL framework and ICD project, not a second implementation
of the OpenGL specification. The active backend route reuses Mesa's OpenGL
semantic engine and its existing NIR-to-MSL machinery, then supplies the
macOS-specific Metal execution layer and framework integration required to
reach staged Khronos CTS.

```text
macOS application
  -> OpenGL.framework router
  -> OpenGL_4.6.framework
  -> CGL / NSOpenGL / libGL* / libGLICD frontends
  -> Mesa OpenGL core, state tracker, GLSL, SPIR-V, and NIR
  -> AO46MTLGallium (Mesa Gallium callbacks and NIR-to-MSL integration)
  -> AO46AGXMetalAdapter (Metal device, queues, resources, pipelines, fences)
  -> Apple GPU driver and hardware
```

## Ownership

| Area | Owner | AO46 action |
| --- | --- | --- |
| OpenGL objects, validation, state, dispatch, GLSL, SPIR-V, NIR | Mesa | Reuse; do not reimplement |
| NIR-to-MSL lowering and supporting compiler passes | Mesa KosmicKrisp | Reuse and integrate |
| Gallium callbacks, resource/state translation, and Mesa-to-MSL pipeline assembly | AO46MTLGallium | Modernize the existing Gallium driver base; do not create a second driver |
| Metal resource, pipeline, command, synchronization, and presentation lifecycle | AO46AGXMetalAdapter | Own the narrow macOS execution boundary |
| CGL, NSOpenGL, framework ABI, loader, ICD, user-space libraries, pixel formats, drawables | AO46 | Maintain and complete |
| GPU scheduling, memory protection, firmware, and hardware management | macOS | Use through Metal; do not replace |

The reusable compiler boundary currently lives under
`mesa/src/kosmickrisp/compiler/`. AO46 must integrate that machinery rather
than maintain a separate GLSL-to-MSL compiler or duplicate NIR lowering.

The checked [Mesa Metal Gallium Reuse Inventory](MesaMetalReuseInventory.md)
maps each KosmicKrisp, Poly, and Asahi candidate to direct reuse, a bounded
Gallium/Metal algorithm port, reference-only study, or exclusion. Every new
backend feature must consult that map before adding AO46-local machinery.

## Two-Part Execution Boundary

`AO46MTLGallium.m` is the only Mesa-facing driver component. It owns Gallium
callbacks, resource/state translation, draw submission decisions, and the
KosmicKrisp NIR-to-MSL integration. Its starting point is the existing
`GL2MTL/mtl_driver.m` implementation, which must be audited and migrated under
the AO46 name rather than recreated beside it.

`AO46AGXMetalAdapter` sits strictly below `AO46MTLGallium.m`. It owns the
`MTLDevice`, queue/command-buffer lifecycle, resource allocation and retention,
pipeline cache, fence completion, drawable ownership, and profile-specific
performance policy. It does not contain Gallium callbacks, OpenGL state, GLSL,
or NIR lowering.

The archived direct AGX/UABI research informs profile gating, invariant checks,
resource-lifetime diagnostics, queue ordering, and performance investigation.
It does not revive private carrier injection, private Apple object construction,
or raw AGX submission as an AO46 runtime path.

## Non-Negotiable Reuse Rules

- Mesa remains the sole source of OpenGL API semantics and capability logic.
- AO46 does not hand-write GL object models, GLSL parsing/linking, SPIR-V
  ingestion, state validation, or independent shader lowering.
- The historical `GL2MTL` driver source is the migration baseline for
  `AO46MTLGallium`; its old name and former excluded build target are not the
  active product surface.
- Metal capabilities determine advertised versions, extensions, limits, and
  formats. AO46 never reports OpenGL 4.6 merely because a context requested it.
- A feature is complete only after the Mesa path, Metal backend behavior,
  framework/ICD exposure, regression coverage, and relevant CTS slice agree.

## Active Milestones

1. **Mesa-to-Metal bootstrap**
   Build the Mesa NIR-to-MSL components in the normal AO46 backend graph,
   create one `MTLDevice`/queue-backed screen, and prove an offscreen clear and
   readback through Mesa-owned GL state.

   Current implementation: the normal framework build now includes Mesa's
   KosmicKrisp NIR-to-MSL library and AO46 has a direct Metal adapter for
   device/queue ownership, shared buffers, MSL compute-pipeline creation,
   command encoding, completion waits, and readback. Its hardware smoke tests
   pass. AO46 now creates a Mesa-owned Metal `pipe_screen` and a bounded
   graphics-capable `pipe_context` for buffer transfers, compute dispatches,
   and direct triangle-list draws.
   A smoke shader built as Mesa NIR is lowered by KosmicKrisp, retained with
   generated MSL and interface metadata in an AO46 pipeline record, dispatched
   through that context, and verified through a Gallium fence-backed readback.
   The screen also supports bounded `RGBA8`/`BGRA8` 2D textures, color
   surfaces, full-surface render-pass clears, and aligned texture-to-buffer
   readback. Normal GL contexts remain blocked until general graphics state,
   shader, texture-view, and render-pass callbacks are live.

2. **Resource and pipeline execution**
   Implement Mesa-owned buffer, texture, sampler, framebuffer, shader, and
   pipeline binding over Metal resources and pipeline states. Add hazards,
   synchronization, errors, and readback without duplicating GL validation.

3. **macOS integration completion**
   Connect CGL and NSOpenGL context creation, pixel formats, IOSurface and
   CAMetalLayer drawables, Retina resize, swap interval, present, and context
   loss to the live Mesa/Metal screen.

4. **Feature exposure and CTS**
   Enable only capabilities proven by Mesa plus the Metal backend. Start with
   offscreen Mesa tests, then targeted GL CTS groups, then progressively wider
   CTS runs. Fix framework/ICD correctness and performance regressions as each
   capability becomes live.

5. **AO46 specialization**
   Harden the framework router, `libGLICD.dylib`, `libGL.dylib`,
   `libGLContext.dylib`, and NSOpenGL bridge for real macOS application
   lifecycles, compatibility quirks, packaging, rollback, and diagnostics.

## Six-Lane Metal Workflow

Every implementation pass starts with a clean active build and test run, then
advances one primary lane while checking the regressions owned by every other
lane. A lane moves only when code and its measured exit condition both land.
Adding a symbol, version string, TODO, or placeholder does not count as
progress.

### Lane 1: Mesa Gallium Contract

- `[~]` Mesa state tracker, GL API, and NIR libraries link into the framework.
- `[~]` AO46-owned `pipe_screen` now has create/destroy, hardware identity,
  conservative capability reporting, bounded buffer/2D-color-format admission,
  and Metal-backed Gallium resource lifetime. Mesa's audited state tracker
  currently realizes this set as OpenGL 3.3 core, and accepts bounded compute
  or graphics `pipe_context` creation.
- `[~]` `pipe_context` creation, destruction, buffer upload/map, GPU blit,
  compute dispatch, direct graphics `draw_vbo`, and Metal-backed
  `pipe_fence_handle` completion are implemented. Submitted resources are
  retained through fence retirement. General Mesa state-tracker admission
  remains blocked.
- `[~]` `AO46MTLGallium` now builds as the promoted Mesa-facing Gallium target.
  Its adapter-backed screen entry point borrows one live
  `AO46AGXMetalAdapter` device/queue pair and releases its retained references
  with the final screen. The framework creates this screen for CGL/Mesa context
  negotiation, with smoke coverage for screen identity and lifecycle. Mesa
  currently realizes this capability set as core 3.3 after the standard
  `u_vbuf` packed-vertex fallback is enabled, so GL 4.6 requests stay
  fail-closed while their missing Gallium capabilities are audited.
- Exit: Mesa creates a context through AO46 and reports only capabilities the
  Metal backend has tested.

### Lane 2: Resources And Formats

- `[~]` The Metal adapter owns shared-buffer allocation and CPU-visible
  readback. The Gallium screen now maps `PIPE_BUFFER` resources to those
  `MTLBuffer` allocations with explicit create/destroy lifetime and a tested
  shared CPU mapping. Buffer upload/map/unmap, native GPU blit, and
  completion-aware readback are also covered by the bounded Gallium context.
  Compute resource bindings remain retained until their submission fence is
  released.
- `[~]` `PIPE_TEXTURE_2D` `RGBA8`/`BGRA8` single-level, single-sample resources
  map to private `MTLTexture` objects. AO46 creates color surfaces, encodes
  full-surface clears and one bounded fullscreen-triangle render pass, copies
  them to aligned staging buffers, and validates both channel layouts through
  Gallium fences. The current fragment path additionally supports one or more
  static texture slots with matching immutable nearest/clamp sampler views;
  each maps to a public `MTLTexture` and `MTLSamplerState` and stays retained
  through fence completion. An aligned shared `MTLBuffer` can upload one
  bounded texture region with a native blit before sampling. Dynamic handles,
  other sampler behavior, vertex sampling, depth, mipmaps, and multisampling
  remain fail-closed.
- `[x]` The MTL4 transfer path now performs buffer blits plus texture upload,
  clear, readback, and texture-to-texture copies through KosmicKrisp bridge
  encoders. The same retained fence package owns the allocator, command buffer,
  and argument table until feedback reports completion. Gallium routes bounded
  `RGBA8`/`BGRA8` texture copies through this path, including the presentation
  copy used by window drawables.
- `[x]` The adapter imports non-planar `RGBA8`/`BGRA8` IOSurfaces as retained
  public Metal textures. The hardware smoke clears an imported `BGRA` surface,
  waits on its AO46 fence, and verifies the CPU-visible IOSurface bytes.
- `[~]` Packed `R32G32B32` buffer sampler views now derive a selected-slot
  binding vector from exact Gallium view ranges, including nonzero byte
  offsets. That vector controls both RGB32 NIR lowering/pipeline creation and
  submission-time `MTLBuffer` validation, so a pipeline cannot use a stale
  static smoke binding. The pipeline can now discover every compatible RGB32
  buffer-texture slot directly from Mesa NIR before deriving the matching live
  sampler-view contract. A hardware smoke rejects an undersized bound range and
  fetches the first texel of a valid subrange without a staging copy. Two
  independent fragment roots now execute together, and a same-shaped rebound
  view is resolved again at `draw_vbo` time without rebuilding the pipeline.
  Unbinding either required view now fail-closes the draw; a sparse Gallium
  multi-slot update restores both roots without recompiling the pipeline.
  This proves that current Gallium sampler state, not a stale bootstrap
  binding, determines each direct Metal range. This is a
  prerequisite for `ARB_texture_buffer_object_rgb32`, not admission for the
  extension: general texture-buffer views and state-tracker binding remain.
  The pipeline creation boundary now consumes the live fragment sampler-view
  state held by the Gallium context rather than a parallel caller-owned array.
  It still needs generic Mesa shader-state creation and state-tracker-driven
  view selection before this can become an extension gate.
- `[ ]` Add general texture views, sampler behavior, framebuffer attachments,
  depth, mipmaps, and multisampling.
- `[ ]` Build one format and usage database shared by resource creation,
  `pipe_screen` capability reporting, and framework pixel formats.
- Exit: Mesa-controlled buffer upload/download and texture render/readback are
  deterministic without copying or revalidating GL state in AO46.

### Lane 3: Mesa NIR-To-MSL Pipelines

- `[x]` A real Mesa NIR compute shader lowers through KosmicKrisp, and AO46
  retains its generated MSL, `main_entrypoint`, local size, required root
  buffer/sampler-table ABI, and Metal pipeline limits in a pipeline record.
- `[x]` Real Mesa NIR vertex and fragment shaders now lower through
  KosmicKrisp, retain stage-specific MSL/reflection, and create an `RGBA8`
  Metal render pipeline. The graphics smoke consumes interleaved `float4`
  position and color NIR inputs through MSL `VertexIn` attributes `0` and `1`,
  bound from a `PIPE_BUFFER` at Metal slot `2`; slots `0` and `1` remain the
  Mesa root-buffer/sampler-table ABI. The vertex color crosses
  `VARYING_SLOT_VAR0` into the fragment stage before writing `color(0)`.
- `[x]` The shared MTL4 adapter owns KosmicKrisp's public `MTL4Compiler`.
  Compute, vertex, and fragment pipelines compile through that bridge when
  MTL4 submission is available, including AO46's `float2`/`float4` vertex
  layouts. Each pipeline also retains a classic PSO solely for existing ICB
  and pre-MTL4 fallback encoders; MTL4 PSOs never cross into those encoders.
- `[x]` AO46's KosmicKrisp integration can optionally lower static NIR sampler
  indices to public MSL `sampler(N)` parameters, avoiding an attempt to write
  opaque sampler handles into a Metal buffer. The fragment texture smoke uses
  Mesa-generated sparse `texture(1)`/`sampler(1)` and
  `texture(3)`/`sampler(3)` bindings end to end. Its UVs are `float2` data
  from a real vertex buffer, interpolated through `VARYING_SLOT_VAR0`, rather
  than a fixed fragment coordinate; both sampled textures contribute distinct
  regions to the fence-read output.
- `[x]` Constant-offset Mesa `load_ubo` operations for bindings `0..15` are
  reflected as an exact required binding mask and per-UBO byte range. Binding
  `0` uses Metal buffer `0`; bindings `1..15` use Metal buffers `16..30` so
  vertex-buffer slots `2..15` remain stable. Supplied Gallium
  `PIPE_BIND_CONSTANT_BUFFER` resources are rejected when missing, duplicate,
  or undersized and remain retained until fence completion. Dynamic UBO
  indexing/offsets and arrays/layouts remain unsupported. Direct `draw_vbo`
  consumes matching vertex/fragment `set_constant_buffer` state for the exact
  reflected binding mask and rejects conflicting stage bindings.
- `[x]` Direct Mesa vertex-stage pointer buffers are reflected and range-checked
  independently from fragment buffers at Metal slots `2..15`; slots `0` and
  `1` remain the immutable KosmicKrisp graphics root/sampler ABI. A
  zero-attribute procedural vertex stage is accepted without a fake vertex
  descriptor. Mesa poly's TES lowering compiles this path with
  `poly_tess_params` at slot `3`, renders an indexed tessellation-coordinate
  triangle through the native Metal encoder, and verifies RGBA output after a
  real completion/readback. The same pointer range now has a retained
  `PIPE_BUFFER` representation for bounded Gallium indexed draws, including
  the zero-attribute procedural TES stage. Mesa's immutable libkk prefix-sum
  and triangle kernels now also submit through Gallium's resource and fence
  model: one retained package holds their root, sampler table, tessellation
  parameters, heap, generated indices, and generated coordinates. The bounded
  smoke consumes Mesa's generated index data in the TES draw and verifies the
  final RGBA output. Mesa-lowered TCS now writes the six triangle tessellation levels into
  that same retained package through a
  KosmicKrisp-generated compute pipeline at static buffer slot `3`. The
  bounded integer triangle case now queues TCS, a Mesa count pass, prefix sum,
  Mesa's emitting tessellation pass, and TES rendering without host waits
  between stages; its final render fence retains the complete package until the
  final RGBA readback. The
  terminal TES draw is admitted through bounded
  `draw_vbo(PIPE_PRIM_PATCHES)` state: it requires `set_patch_vertices(3)`,
  one exact retained `poly_tess_params` range at static vertex slot `3`, and
  one generated `uint32` triangle-index range. A retained Mesa poly execution
  sequence now makes that patch draw submit TCS, count, prefix sum, emitting
  tessellation, and TES rendering in queue order, with no host waits between
  stages and one terminal render fence. Mesa writes the standard five-word
  indexed-indirect descriptor into the package; AO46 submits it natively to
  Metal without CPU inspection, bounded by the declared generated-index heap.
  Immutable count/emit roots prevent mode writes racing the queue, and every
  GPU-address compute binding is declared read/write to Metal for cross-stage
  visibility. The retained draw explicitly carries its input-vertex count, so
  any one-instance plan-aligned patch count is admitted when its package has a
  sufficient Mesa heap. The Mesa plan now retains the TES domain and dispatches
  the matching libkk triangle, quad, or isoline kernel; the adapter accepts the
  corresponding triangle, line, or point output topology. That topology is
  now derived from the finalized Mesa TES domain and point-mode state, not
  selected by the caller. The Gallium context owns explicit TCS/TES NIR state
  objects and default tessellation levels, and rejects a patch draw unless both
  bound stages match the retained Mesa Poly plan. Generic state-tracker stage
  compilation/execution, dynamic tessellation state binding, and broader
  generated heap sizing remain open.
- `[x]` One Mesa-generated graphics pipeline can submit retained `uint16` and
  `uint32` triangle-list index ranges with explicit aligned byte offsets and
  counts. The AO46 adapter scans the entire EBO to derive and validate the
  post-base-vertex span, then emits Metal base-vertex draws. Primitive-restart
  triangle runs are split into separate Metal draws; the Gallium fence retains
  the EBO alongside the surface and VBO. A host-visible sequence of `1..64`
  indexed or non-indexed indirect records is range-validated and emitted with
  Metal's native indirect encoder in one ordered command buffer, retaining its
  command-argument buffer through fence completion. A Mesa compute-produced
  32-bit `indirect_draw_count` buffer now feeds a public Metal indirect-command
  buffer execution range in the same command buffer, so the count is neither
  mapped nor read by the CPU; zero and oversized values are clamped on the GPU
  to the declared `1..64` sequence. The indirect argument records themselves
  remain CPU-visible and range-validated before ICB encoding. The Mesa poly path also
  accepts one GPU-produced indexed descriptor only when its static generated
  heap capacity and attribute-free TES pipeline have been validated. Direct indexed/non-indexed
  draws carry native instance-count and base-instance values, while static
  vertex descriptors can step per instance. One Mesa-produced, shader-writable
  `uint32` indexed indirect record is also submitted directly without a CPU
  map, independent of the tessellation package. GPU-generated multi-record
  batches, unbounded batches, texture/sampler-bearing ICB count pipelines, and
  general state-tracker `draw_vbo` remain unsupported.
- `[~]` Compute dispatch and one bounded vertex-buffer triangle are verified
  through Gallium fence-backed readback. The graphics pipeline validates that
  fragment-stage inputs were produced by the vertex stage. RGB32 buffer-texture
  lowering now works in both vertex and fragment Mesa NIR stages: each stage
  derives its direct MTLBuffer range from its live Gallium sampler view, and a
  hardware smoke executes independent vertex slot `3` and fragment slot `2`
  roots with no staging copy. The live vertex RGB32 view now also enters the
  bounded Gallium `draw_vbo` submission path rather than a helper-only draw,
  and an undersized fragment view rejects that state-tracker submission.
  General vertex layouts, varying classes, textures, specialization inputs,
  cache keys, errors, and invalidation remain.
- `[~]` Gallium now creates an immutable compute state from a cloned Mesa NIR
  shader and routes a full-workgroup `launch_grid` call through the same
  KosmicKrisp NIR-to-MSL pipeline, Metal queue, and Gallium fence retirement
  path. The smoke verifies output readback and rejects partial workgroups,
  indirect grids, dynamic shared memory, and unbounded global bindings. This
  now accepts its required buffer ranges through Gallium's standard
  `set_shader_buffers` callback, allowing a state-tracker-owned compute
  binding set rather than only the legacy `pipe_grid_info::globals` hook. The
  compute-state compiler now reflects every valid Mesa/KosmicKrisp direct
  pointer root at bindings `2..15` before MSL generation. A smoke uses
  independent read-only input and writable output roots at `2` and `3`, so
  live Gallium ranges and the writable mask, rather than the root ABI alone,
  determine submission access.
  dispatch contract now carries the callback's writable bit into classic Metal
  resource-usage declarations; legacy direct callers retain conservative
  read/write declarations until converted. A conservative Gallium
  `memory_barrier` waits for the committed Metal work it protects, covering the
  current buffer shader/mapped boundary without inventing cache semantics. A
  three-word `PIPE_BIND_COMMAND_ARGS_BUFFER` now reaches the public Metal
  indirect compute encoder without CPU readback; a two-workgroup command is
  verified by fenced readback, malformed offset records are rejected before
  submission, and the argument buffer is retained through fence retirement.
  The MTL4-specific indirect encoding path is not yet implemented.
  This is a real `ARB_compute_shader` foundation, not GL 4.3 admission: general
  Mesa compute-state binding, complete SSBO semantics, images, atomics,
  texture/image barriers, and broad indirect-compute state remain unimplemented.
- Exit: one Mesa shader program produces an AO46 Metal pipeline without any
  project-local GLSL compiler or shader lowering.

### Lane 4: Command Encoding And Synchronization

- `[~]` The adapter encodes Mesa-generated compute and native blit command
  buffers, waits for real completion, validates GPU-written data, and exposes
  retained `pipe_fence_handle` objects through Gallium.
- `[x]` Consecutive MTL4 submissions use a shared public `MTLEvent` timeline
  for GPU-side ordering. Gallium avoids a CPU wait for MTL4-to-MTL4 work while
  retaining explicit waits at classic/MTL4 queue boundaries.
- `[x]` A format-checked Metal render pipeline accepts Mesa-generated vertex
  and fragment MSL, binds an AO46 color surface plus one retained interleaved
  Gallium vertex buffer, and submits exactly one three-vertex draw. The target
  and VBO remain retained until the returned Gallium fence retires.
- `[x]` The bounded render encoder validates required static texture/sampler
  masks, rejects target-feedback sampling, binds each resource at its
  Mesa-generated public Metal slot, and retains sampled textures with the draw.
- `[x]` The bounded render encoder binds the exact reflected set of validated
  Gallium UBO resources for both shader stages: `UBO 0` at Metal buffer `0`
  and `UBO 1..15` at Metal buffers `16..30`. Pipelines with no reflected UBO
  data retain the immutable adapter-owned buffer `0` instead. The bounded
  `draw_vbo` path sources these bindings from retained Gallium
  `set_constant_buffer` state, requiring matching resource/range state when
  both vertex and fragment stages bind the same UBO index.
- `[x]` The bounded render encoder accepts validated `uint16` and `uint32`
  triangle-list index ranges with aligned offsets and emits
  `drawIndexedPrimitives`. It applies validated base-vertex offsets and splits
  primitive-restart triangle runs. Invalid counts and index ranges are rejected
  before command encoding and the retained EBO is released only with its
  submitted Gallium fence.
- `[x]` The render encoder validates and binds reflected vertex-stage direct
  buffer ranges before ordinary vertex attributes, rejecting slot collisions.
  The Mesa poly TES smoke exercises this route both directly and through a
  retained Gallium `PIPE_BUFFER` with a public Metal GPU-address coordinate
  heap and indexed draw; it does not depend on private AGX UABI submission or
  a project-local tessellation compiler.
- `[~]` Bounded full-surface clears and the vertex-buffer proof have correct
  render-pass boundaries, including retained `uint16`/`uint32` indexed triangle
  lists. `pipe_context::draw_vbo` handles one direct indexed or non-indexed
  triangle-list submission with a native instance count/base instance and
  static per-instance vertex descriptors, or a bounded sequence of matching
  indirect records dispatched through Metal. A Mesa-produced GPU count selects
  a bounded ICB execution range without a CPU readback; its records are still
  prevalidated CPU-visible data and texture/sampler-bearing pipelines do not
  enter this ICB path. Mesa state-tracker clear and general graphics state
  remain unimplemented.
- `[~]` Map Metal completion to Gallium fences, flushes, and submitted-resource
  retirement. Failure-state handling and broader hazard tracking remain open.
- Exit: a Mesa offscreen clear and draw complete through a real fence with
  deterministic CPU readback.

### Lane 5: macOS Frontends And Drawables

- `[~]` Framework, CGL, NSOpenGL, ICD, `libGL`, and `libGLContext` surfaces
  build and retain fail-closed context handling.
- `[~]` Route supported-core offscreen CGL contexts through the promoted
  Gallium screen. GL 4.6 and window-drawable admission remain fail-closed until
  their Gallium capability and IOSurface/CAMetalLayer paths are live.
- `[~]` CGL now accepts an `NSView`, `NSWindow`, or caller-owned `CAMetalLayer`,
  resolves it to a public AO46 device layer, and creates a Mesa-owned color
  target with matching `RGBA8`/`BGRA8` dimensions. At swap it copies that target
  into an acquired drawable through the MTL4 timeline, signals/presents it, and
  retains source and drawable resources until completion. `NSOpenGLContext`
  no longer destroys the target by reattaching it for every `flushBuffer`.
  `update` rebuilds the target after an AppKit backing-size change. A failed
  drawable acquire marks the target lost and rebuilds it before the next swap
  retry, without requiring an explicit caller update; swap interval maps to the
  layer's display-sync policy. The CGL layer lifecycle smoke covers attach,
  update, parameter change, a no-drawable retry, and detach. AO46 defaults
  unconfigured supported layers to explicit sRGB and
  rejects non-sRGB layers until it has a validated wide-gamut transfer policy.
  An on-screen compositor smoke and full device/context-loss recovery remain.
  The opt-in WindowServer smoke opens a real `NSWindow`/`NSView`/`CAMetalLayer`,
  clears through CGL, and requires a successful compositor present; it is not a
  CTest because headless agents legitimately have no drawable.
- Exit: a CGL offscreen context and a window drawable both execute the same
  Mesa Metal path without legacy OpenGL.framework execution.

### Lane 6: Verification And CTS

- `[~]` Framework, CGL/NSOpenGL, direct Metal adapter, Mesa NIR compute,
  vertex-input/varying graphics, and static-texture-sampling smoke tests pass.
- `[~]` Deterministic Mesa-derived rendering tests cover compute, a fixed
  vertex/fragment draw, static-divisor direct instancing, `uint16`/`uint32`
  indexed triangle lists, base vertex, primitive restart, direct and bounded
  native-indirect `draw_vbo`, texture readback, buffer mapping, shader
  compilation, and fences. General framebuffer and state-tracker coverage
  remain.
- `[ ]` Run targeted Khronos CTS groups only after each matching backend slice
  is implemented; record failures before expanding capability exposure.
- Exit: CTS results, capability strings, framework behavior, and regression
  tests agree for every advertised feature.

## Delivery Confidence

These are engineering estimates, not conformance claims or calendar promises.
They must be reassessed after Lane 1, Lane 3, and Lane 4 have their exit
conditions.

| Milestone | Current confidence | Why |
| --- | --- | --- |
| Mesa context plus deterministic Metal offscreen clear/readback | 55-70% | Mesa owns the GL semantics and AO46 has a working Metal command/readback foundation, but the Gallium screen, resources, and real NIR pipeline are still new driver work. |
| Early targeted CTS groups | 35-50% | Requires the first three lanes plus correct fences and format behavior, not merely a working clear. |
| Broad OpenGL 4.6 Core CTS conformance | 15-30% | Mesa removes the semantic-engine burden, but a production-quality Gallium Metal driver still needs broad resource, shader, synchronization, presentation, and edge-case coverage. |

The new Metal route is materially more tractable than the direct AGX/UABI
route because it removes opaque carrier, executable-code admission, and custom
kernel-ABI work. It is still a substantial graphics-driver project; the first
real success gate is Lane 4, not the existing adapter smoke.

## Direct AGX Research

The direct Mesa/Asahi-to-AGX investigation is preserved because it produced
valuable observations about macOS GPU ownership, resource lifetimes, queues,
carrier behavior, shader residency, and presentation. It is not selected as a
runtime backend or a conformance claim.

- Architecture and conclusions: [AO46AGXNativeArchitecture.md](AO46AGXNativeArchitecture.md)
- Research maps and contracts: `docs/Apple*Research.md`,
  `docs/Apple*Plan.md`, and `docs/Apple*Contract.md`
- Captured trace evidence: [phase2-session](research/evidence/phase2-session)
- Raw Ghidra reports and logs: [ghidra-20260813](research/evidence/ghidra-20260813)

## Current Claim Boundary

AO46 is an in-development macOS OpenGL framework project. The framework,
router, CGL/NSOpenGL bridge, user-space ICD libraries, generated dispatch, and
test scaffolding are useful foundations. The Metal execution backend is not yet
complete, no full OpenGL 4.6 conformance claim is made, and system-wide
installation remains a developer-only experiment until staged CTS establishes
real capability coverage.
