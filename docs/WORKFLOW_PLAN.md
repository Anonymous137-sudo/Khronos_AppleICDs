# Workflow Plan

This document is the active engineering workflow plan for `Khronos_AppleICDs`.

It adopts the repo-to-full-OpenGL-4.6 engineering map originally assessed against commit `1a0d21e` and turns that assessment into the working implementation order for the driver framework from this point forward.

## Governing Mesa Metal Direction

The authoritative architecture is [`AO46MetalBackendPlan.md`](AO46MetalBackendPlan.md).

AO46 reuses Mesa for the complete OpenGL semantic stack: API behavior, objects,
validation, dispatch, GLSL, SPIR-V, NIR, and the reusable NIR-to-MSL compiler
machinery. AO46 must not grow a competing handwritten OpenGL implementation or
a separate GLSL-to-Metal compiler.

The active engineering work is split into two components beneath Mesa:
`AO46MTLGallium.m` owns Gallium callbacks, Mesa-to-MSL pipeline assembly, and
resource/state translation; `AO46AGXMetalAdapter` owns Metal device/queue,
resource lifetime, pipeline cache, fences, drawables, and performance policy.
The macOS framework work remains CGL/NSOpenGL, framework ABI, ICD and
user-space libraries, diagnostics, and staged CTS.

The direct Mesa/Asahi-to-AGX/UABI investigation is archived research. Its
traces, Ghidra reports, contracts, and fail-closed prototypes remain in the
repository as evidence, but it is not selected as the runtime path. Its
findings can inform AO46 profile gates, diagnostics, invariants, and performance
policy, never private runtime carrier injection or raw AGX submission. The
existing `GL2MTL/mtl_driver.m` is now the audited migration baseline for
`AO46MTLGallium.m`, not a separate fallback driver.

## Status Legend

- `Implemented`
  Demonstrably functional or structurally present in the current tree.
- `Partial`
  Architecturally scaffolded or only implemented for a narrow slice of behavior.
- `Required`
  Still needed before the stack can honestly claim full OpenGL 4.6 Core Profile support.

## Ground Rules

- Exported symbols are not treated as completed features unless their Khronos semantics are implemented.
- Khronos behavior, not Apple legacy behavior alone, defines the OpenGL 4.6 target.
- Every new implementation pass starts with a bug sweep and build/test verification.
- Binding-based APIs and DSA APIs must share one internal object implementation.
- Capability exposure must be driven by real backend support, not aspirational version strings.
- The driver must not advertise full OpenGL 4.6 until required behavior passes deeper semantic and conformance coverage.
- System replacement, installer behavior, and rollback safety remain first-class workstreams, not afterthoughts.

## Active Mesa Metal Backend Dashboard

- `[~]` Mesa semantic and compiler reuse: Mesa OpenGL, state tracker, GLSL,
  SPIR-V, NIR, and KosmicKrisp NIR-to-MSL sources are present. Real Mesa NIR
  compute, vertex, and fragment shaders now lower through KosmicKrisp, compile
  as MSL, and execute through AO46's bounded Mesa Metal context. The framework
  now creates supported-core state-tracker contexts through that screen; broad
  state-tracker graphics coverage remains incomplete.
- `[x]` Metal adapter bootstrap: AO46 owns one `MTLDevice`/command queue,
  shared buffer allocation, MSL compute-pipeline creation, direct command
  encoding, completion wait, and GPU readback. The hardware smoke test passes.
- `[~]` Two-part migration: `AO46AGXMetalAdapter` is now a reusable library
  linked by the framework and `AO46MTLGallium`. The promoted Gallium screen
  borrows the adapter-owned Metal device/queue rather than creating a second
  pair; lifecycle smoke coverage proves the identity and teardown contract.
  The framework selects this driver for supported-core CGL admission. Mesa
  currently realizes it as core 3.3, so GL 4.6 and window presentation remain
  profile-gated until their missing capabilities are complete.
- `[~]` Mesa Metal screen and context: AO46 has a Metal-backed `pipe_screen`
  and graphics-capable `pipe_context` with buffer and bounded 2D color
  resources, upload/blit/compute/full-surface-clear/vertex-buffer-triangle
  command submission, resource retention, fence completion, and deterministic
  buffer or texture readback. Single-draw direct or native-indirect `draw_vbo`
  triangle lists now consume retained framebuffer and vertex-buffer state.
  Direct draws carry base-instance/count state and static per-instance vertex
  divisors. Supported-core Mesa state-tracker contexts now use the promoted
  driver; GL 4.6 capability, general graphics state, and window presentation
  remain.
- `[~]` Metal resources and pipelines: `RGBA8`/`BGRA8` renderable 2D textures,
  color surfaces, aligned staging upload/readback, and Mesa-generated
  vertex/fragment render pipelines with interleaved `float4` position plus
  `float2` UV inputs and a vertex-to-fragment varying are wired. A bounded
  two-source `RGBA8` texture sampler smoke verifies four distinct combined
  regions through sparse public Metal texture/sampler slots `1` and `3`.
  A second graphics smoke reads constant-offset ranges from Mesa `UBO 0` and
  `UBO 1`, retaining their `PIPE_BIND_CONSTANT_BUFFER` resources at Metal
  buffer `0` and buffer `16`. Missing or undersized bindings are rejected.
  Direct `draw_vbo` now consumes matching vertex/fragment Gallium
  `set_constant_buffer` bindings for the reflected UBO mask; missing,
  conflicting, or undersized state fails closed. Dynamic UBO indexing/offsets,
  arrays/layouts, plus general texture views/sampler state, framebuffers,
  depth/stencil, general graphics pipelines, and general synchronization remain.
- `[x]` KosmicKrisp's public MTL4 compiler, argument tables, and bridge
  encoders are active in the AO46 adapter. MTL4 pipeline records support
  validated buffers, textures, samplers, `float2`/`float4` vertex layouts,
  texture upload/readback/clear/copy, and event-ordered queue submission. The
  texture-copy smoke verifies an upload, GPU texture copy, and readback. A
  paired classic PSO is retained only for legacy ICB fallback; it is not
  another GL translation path.
- `[~]` Bounded indexed graphics: Mesa-generated vertex and fragment MSL can
  now submit retained `uint16` or `uint32` `PIPE_BIND_INDEX_BUFFER` triangle
  lists with explicit aligned offsets and counts. AO46 validates the complete
  post-base-vertex span before encoding `drawIndexedPrimitives`, rejects invalid
  counts/ranges, splits primitive-restart runs, and retains the EBO until the
  Gallium fence retires. The bounded `draw_vbo` path covers one indexed or
  non-indexed direct triangle-list draw and a sequence of `1..64` host-visible
  indirect parameter records submitted through Metal's indirect encoder. The
  CPU only preflights each record and matching EBO range; the GPU consumes the
  records. A Mesa compute-produced `indirect_draw_count` buffer now selects a
  public Metal ICB execution range in the same command buffer, with no CPU
  count readback and a GPU clamp to the bounded sequence. The individual
  command records remain CPU-visible/prevalidated, and texture/sampler-bearing
  pipelines remain outside the ICB-count path.
  Direct indexed/non-indexed draws also emit native instance count/base-instance
  parameters and bind static per-instance vertex divisors. GPU-driven
  GPU-generated multi-record command batches and general state-tracker binding
  remain. A single shader-writable indexed record can execute directly without
  a CPU map, and TCS/TES state objects are now bound and validated against the
  bounded Mesa Poly plan.
- `[~]` Framework and ICD: the router, framework, CGL/NSOpenGL bridge, client,
  ICD, user-space libraries, generated dispatch, and smoke harnesses exist;
  they still need a live Mesa Metal screen and real capability reporting.
- `[~]` Drawable and presentation: CGL now resolves public `NSView`,
  `NSWindow`, or `CAMetalLayer` inputs to an AO46-owned Metal layer, allocates
  a Mesa color target matching its backing dimensions and format, copies the
  target into an acquired drawable, and presents it through the MTL4 timeline.
  The source and drawable remain retained until the completion fence retires.
  `NSOpenGLContext` preserves the target across `flushBuffer`; update handles
  AppKit backing-size changes, and swap interval controls display sync. The
  automated layer smoke covers CGL attach/update/detach plus a retry-safe
  no-drawable flush without a compositor. A failed drawable acquire marks the
  target lost and rebuilds it before that retry, so callers do not need an
  explicit `CGLUpdateContext`. Supported `RGBA8`/`BGRA8` layers default to
  explicit sRGB; AO46 rejects wide-gamut layers until its transfer policy is
  validated. The RGB32 buffer-texture path now derives a selected-slot binding
  vector from the actual Gallium sampler-view subrange for both Mesa graphics
  stages, uses it to create the NIR-lowered Metal pipeline, and validates the
  same slots at draw submission. The live vertex view now reaches bounded
  Gallium `draw_vbo` state submission, and a hardware smoke verifies
  independent vertex slot `3` and fragment slot `2` roots without a staging
  copy. It now combines independent fragment slots `2` and `4`, then rebinds
  slot `2` to verify that the draw uses the live Gallium range without
  recompiling the pipeline. Unbinding a required slot fail-closes the draw,
  while one sparse Gallium multi-slot update restores both fragment roots. It remains a
  prerequisite rather than admission for
  `ARB_texture_buffer_object_rgb32`.
  The adapter also has a hardware-verified public `IOSurface` import path for
  non-planar `RGBA8`/`BGRA8` textures. An opt-in visible WindowServer smoke
  covers real `NSWindow`/`CAMetalLayer` presentation without making headless
  CTest runs flaky. Successful compositor hosting and full device/context-loss
  recovery remain.
- `[~]` CTS admission: local framework and contract smoke coverage exists.
  Targeted Mesa rendering tests and staged Khronos CTS begin only after the
  first real Metal-backed offscreen path is deterministic.

## Workflow Rules For Each Pass

- Start with the configured Mesa/Metal build and `ctest`; do not use a stale
  build directory whose CMake cache names another checkout.
- Use the six lanes in [`AO46MetalBackendPlan.md`](AO46MetalBackendPlan.md) as
  the active checklist: Gallium contract, resources/formats, NIR-to-MSL
  pipelines, command/synchronization, macOS frontends/drawables, and CTS.
- Use a parallel feature cadence rather than a strict version-by-version
  order: finish one nearest low-dependency GL blocker, advance one higher-core
  capability backed by existing Mesa/KosmicKrisp machinery, and maintain the
  parallel AVK143 Vulkan plan in
  [`Vulkan_API_SDK_1.4.354/README.md`](../Vulkan_API_SDK_1.4.354/README.md).
  This does not relax capability gates: each reported feature still needs a
  real implementation and regression coverage.
- Each pass has one primary lane and runs targeted regression checks for every
  affected secondary lane. A lane may advance only with tested implementation
  work and its stated exit condition. A TODO, documentation-only change,
  version string, or fallback backend is not progress.
- Keep Mesa as the sole OpenGL semantic and shader authority. Keep all Gallium
  callbacks in `AO46MTLGallium.m` and all low-level Metal execution/lifetime
  work in `AO46AGXMetalAdapter`.
- Before introducing an AO46-local backend subsystem, consult and verify
  [`MesaMetalReuseInventory.md`](MesaMetalReuseInventory.md). Prefer direct KK
  reuse, then a bounded KK/Asahi algorithm port with upstream attribution and
  a regression test; never import Asahi's AGX/DRM execution core.
- Expand smoke coverage whenever a resource, pipeline, submission, drawable,
  or framework state becomes real. Use test results to gate capability exposure.
- Report `[x]`, `[~]`, and `[ ]` for all six active lanes after every pass.
- Keep public repo documentation aligned with the current implementation boundary.

## Historical Direct AGX Research Notes

The notes below remain valuable evidence for Apple-GPU ownership and lifecycle
design, but they do not constrain the active Mesa/Metal implementation queue.
- Before accepting static Apple GPU identifiers on a new macOS/AGX profile,
  capture `inventory_apple_agx_stack.sh` output and correlate it with a
  controlled `wrap.dylib` trace. Static metadata alone never authorizes UABI
  implementation.
- Treat Apple AGX userspace identifiers as investigation anchors only. A
  native bridge operation requires controlled dynamic evidence, an explicit
  profile gate, and a hardware smoke test; it must not call guessed private
  Objective-C layouts or make copied Apple binaries an AO46 dependency.
- For an opaque allocator, carrier, sidecar, or USC blocker, begin with Ghidra
  headless C-style reconstruction of the exact arm64e profile image and its
  local call graph. Use controlled dynamic capture only to resolve a specific
  static ambiguity such as a profile branch, argument meaning, or lifecycle
  order. Temporary binary copies and raw pseudocode stay outside the
  repository; commit only AO46-owned exporter scripts and independently stated
  behavioral facts. Decompilation narrows the next experiment and ownership
  model, but it never by itself authorizes a private call or a fabricated Apple
  object.
- Treat `AGX_BO_LOW_VA` and `AGX_BO_EXEC` as separate native contracts. The
  current M4 Pro evidence is recorded in
  [`AppleAGXShaderContractResearch.md`](AppleAGXShaderContractResearch.md);
  neither capability may be exposed from public-buffer or encoder-allocation
  observations alone.
- `[x]` The G16X public compute execution chain is mapped through pipeline
  binding, kernel emission, Apple resource-list retention, USC-spill handling,
  and completion. `[ ]` This is not a Mesa shader-BO import contract: AO46
  still needs a standalone low-VA allocation/mapping path and an executable
  AGX-code import path before `pipe_screen` admission.
- `[x]` Direct profile analysis now identifies the actual Apple
  `ComputeProgramVariant` residency allocator: `Heap<true>::allocateImpl`
  returns a 40-byte allocation record that is retained by the variant and
  scales with the compiled program. The active public controls cover seven
  zero-base selections. `[~]` Its nonzero selector switches to a distinct heap
  and a `0x1000000000` fixed base, but the public trigger, mapping, executable
  provenance, and AO46/Asahi import contract remain unproven. The exact
  evidence and next gate are maintained in
  [`AppleAGXShaderContractResearch.md`](AppleAGXShaderContractResearch.md).
- `[x]` Headless reconstruction now confirms that the residency allocator's
  0x68 configuration is consumed by an Apple-owned resource creation path,
  while pooled resource, command-storage, queue, resource-list, Trap4, and
  selector-29 submission work retain Apple-owned lifetime state. `[~]` The
  remaining direct-adapter work is therefore a concrete adoption/import proof,
  not guessing record fields; details are maintained in
  [`AppleAGXShaderContractResearch.md`](AppleAGXShaderContractResearch.md).
- `[x]` The profile-gated compute carrier is now decomposed into its Apple
  command-storage segment, compute subrecord, USC descriptor packing, and
  context-owned resource-list transition. The observed relationships and next
  controlled differentials live in `AppleAGXComputeCarrierResearch.md`. The
  segment close and queue-lowering descriptor are also correlated to the live
  completion pair. A repeated same-process compute control with an independent
  second-capture intersection now proves that no reproducible p4 sidecar word
  tracks the two-buffer resource count or this threadgroup shader change;
  bindings remain in the closed command record/resource-list transition. The
  same profile trace maps finalized Apple program variants into the USC loader
  and excludes all 28 observed nonzero generic-resource GPU addresses from
  Mesa's low-VA USC window. Raw queue commit, sidecar admission,
  low-VA/executable residency, and completion ABI evidence still remain
  required before a native `pipe_screen` can exist.
- Historical direction: the direct bridge was intended to pass Asahi resources
  and command records below Metal command encoding. It remains fail-closed
  research and is not a fallback for the active Mesa/Metal backend.

## Archived Direct AGX Research Dashboard

The following six-lane record preserves the completed and blocked direct
AGX/UABI investigation. It is not the active implementation queue.

### Direct macOS UABI Phases

- `[x]` Phase 1, UABI contract layer: `agx_macos_uabi` is the versioned,
  profile-gated boundary between Mesa platform glue and the macOS AGX
  implementation. It declares device session, API configuration, BO
  allocation/mapping, fixed-VA validation, command infrastructure,
  notification queue, and completion polling as current operations. VM bind,
  resource binding, carrier construction, and batch submission are declared
  but unavailable. The contract rejects stale API generations and is now the
  source of Mesa device capability reporting. Its smoke test verifies current,
  unsupported, unconfigured, and stale-generation cases.
- `[x]` Phase 2, device-session ownership and loss handling: the direct AGX
  session now has explicit `closed`, `open`, `configured`, and `lost` states.
  A loss transition advances its generation before disabling admission, making
  every UABI contract, BO set, queue, command-infrastructure object, Mesa
  device, screen bootstrap, and Apple-native bridge stale at once while
  preserving their saved handles for teardown. The state smoke proves that a
  lost session cannot re-admit UABI BO work. Automatic GPU-reset detection and
  recovery remain Phase 7 work because no live completion queue exists yet to
  report a reset.
- `[~]` Phase 3, general BO and VM management: the direct macOS `agx_bo_bind`
  replacement now routes Mesa's canonical single-BO bind helper through the
  existing exact native-allocation mapping validation. On the profiled host,
  the experimental Mesa smoke allocated a direct 64 KiB BO, exercised the
  common helper, and rejected partial maps and unbinds. Arbitrary GPU-VA
  allocation, remapping, subrange binds, unbind, heap management, and
  relocatable VM mappings remain unavailable until a specific macOS UABI is
  proven.
- `[x]` Phase 3a, Apple-owned Mesa BO resource identity: the optional
  `AppleAGXMetalBOProvider` now backs an ordinary CPU-visible Mesa `agx_bo`
  with one retained Apple allocation. The BO's CPU mapping, GPU VA, lifetime,
  and verified `IOGPUMetalBuffer + 0x40` resource-list binding are therefore
  one object, and the carrier smoke admits that exact binding in a balanced
  no-submit segment. This does not grant low-VA, executable, remap, unbind, or
  command-submission capability.
- `[~]` Phase 4, native queue ordering: a carrier-backed lease now receives a
  queue-local monotonic serial only as it enters flight. Final completion may
  retire only the next serial, preventing out-of-order retirement or carrier
  replay; device-loss abandonment invalidates outstanding order evidence.
  This is host-side lifecycle ordering around the proven notification queue,
  not an invented Apple command-queue or submission ABI. Native queue submit
  and hardware completion delivery remain required for Phase 4 completion.
- `[~]` Phase 5, carrier and resource binding: a finalized neutral
  `agx_submit_info` must now target the current native notification queue, and
  every known render/compute GPU address is checked both against native BO
  ownership and against its retained Asahi resource table. This includes
  VDM/CDM streams, helpers, sampler heaps, ISP buffers, depth/stencil and
  compression buffers, attachments, and timestamp objects. The existing
  bounded carrier snapshot and resource-record encoder retain this package
  until ordered completion. Provider-backed CPU-visible Mesa BOs now have an
  independently verified Apple resource-list identity; batch admission still
  needs a complete Asahi BO set, command-storage mutation, and queue commit.
- `[~]` Phase 6, real Asahi batch submission: finalized Asahi batches already
  enter the native `submit_info` consumer rather than generating a Linux DRM
  packet. That boundary now validates the complete input before reading its
  queue or resource fields, rejects ambiguous timestamp-object identities, and
  proves timestamp write offsets start within their retained native BOs. Native
  carrier import/adoption and queue submission remain the completion blockers.
- `[~]` Phase 7, completion-to-Gallium fence retirement: native sync handles
  already retain an in-flight package and signal only after both observed
  completion tokens retire it. Gallium's `pipe_fence_finish` now treats loss
  of that macOS completion source as an unsignaled fence instead of asserting.
  Live command submission is still required before these completions represent
  real GPU work.
- `[~]` Phase 8, native `pipe_screen`, offscreen rendering, presentation, and
  staged CTS: the framework now publishes a capability-derived native-screen
  readiness map covering its session, Apple bridge, bootstrap, Mesa device,
  BO/VM operations, submit, completion, IOSurface lifecycle, live
  `pipe_screen`, and presentation. `AppleOpenGLAsahiGetNativePhaseStatus`
  makes the Phase 2-8 completion requirements executable and smoke-tested.
  CGL remains fail-closed until the map satisfies the real
  `agx_screen_create_macos` prerequisites and a presentation path exists; no
  placeholder screen is exposed.

### Phase 2-8 Completion Gate

Before Phase 9 begins, `AppleOpenGLAsahiGetNativePhaseStatus` must report
`COMPLETE` for every phase below on the target hardware profile, and the
corresponding runtime smoke must exercise the exit condition. This is an
implementation gate, not a documentation-only checklist.

- `[x]` Phase 2: profiled AGX session lifecycle, generation invalidation, and loss rejection.
- `[~]` Phase 3: multiple Mesa BOs plus general VM bind, remap, and unbind.
- `[~]` Phase 4: native queue accepts a validated submission package.
- `[~]` Phase 5: carrier/resource bindings reach the AGX user client without Metal state.
- `[~]` Phase 6: an Asahi-generated batch writes a controlled output buffer.
- `[~]` Phase 7: live GPU completion retires a Gallium fence and all retained BO pins.
- `[~]` Phase 8: `pipe_screen`/`pipe_context`, offscreen draw/readback, IOSurface presentation, then staged CTS admission.

## Phase 9: Native Execution Closure

Phase 9 closes the three native paths on which Phases 3-8 depend. It does not
introduce a fallback renderer or a parallel OpenGL implementation.

- `[~]` VM and BO path: a native pre-queue bootstrap now proves two distinct
  Apple BOs can be adopted by Mesa and a third Mesa-requested BO can grow the
  same set, including a valid 16 KiB-page-aligned GPU VA that is not 64 KiB
  aligned. The BO-provider ABI now treats CPU-visible data, USC low-VA mapping,
  and executable shader code as separate capabilities, and a no-submit shader
  compilation/pipeline trace measures the Apple allocation classes without
  pretending they are an importable contract. The remaining work is general VM
  bind, remap, unbind, a proven low-VA mapping, and executable shader-BO
  support. Mesa's Asahi linker requires
  `AGX_BO_EXEC | AGX_BO_LOW_VA`, so screen admission reports both missing
  contracts explicitly instead of failing on its first shader allocation. Exit
  condition: Mesa resource, shader, and command BOs can coexist through
  allocation/teardown stress without aliasing an Apple allocation identity.
- `[~]` Carrier and queue path: map one validated `agx_submit_info` package to
  a native resource/object binding set, command carrier, queue commit, and
  ordered completion source. `agx_device.queue_id` now carries the same
  generation-validated native queue identifier enforced by `submit_info` and
  completion polling. Neutral package admission now proves one encoder/record
  BO plus two distinct resource BOs are retained and retired together. Exit
  condition: a retained Asahi compute batch reaches the AGX user client without
  a Linux DRM packet or Metal command translation.
- `[~]` Execution and presentation path: enable timestamp/query object binding,
  live fence retirement, `agx_screen_create_macos`, offscreen readback, and
  IOSurface presentation. Exit condition: a real `pipe_context` clears and
  reads back deterministic pixels, followed by staged CTS admission.

- `[~]` 1. GPU-VA resource ownership and BO lifetime: trace-validated direct
  BO allocation, full-range lookup, submission pinning, and state-gated
  retirement exist. Managed CPU maps are explicitly pinned and protected by
  single-use mapping capabilities, rejecting altered or replayed map handles
  before they can release BO ownership. The framework-owned native screen
  bootstrap starts and tears down the BO set with its AGX session. A native
  Mesa `agx_bo` adapter now owns trace-validated direct allocation, CPU
  mapping, and an exact fixed-VA bind admission check for returned AGX
  mappings. Generic VM/heap management, relocatable mappings, and unbind
  remain. Creation, lookup, pinning, and CPU mapping all reject a stale API
  generation. Direct allocation and
  direct CPU mapping also require the configured allocating session, while
  release, unmap, and cleanup remain available for device-loss retirement.
  The Mesa submission adapter now validates a real macOS-backed `agx_bo`'s
  command-record range and resource subranges against that same native BO set,
  then retains both the native allocation and its Mesa wrapper until package
  retirement. Its opt-in hardware smoke now proves two native bootstrap BOs
  plus a third Mesa-requested 64 KiB BO in one direct session, each with a
  distinct native handle and GPU VA; the adapter accepts Apple-returned VAs at
  Asahi's 16 KiB page granularity, not an invented 64 KiB boundary. A repeated
  raw direct allocation still fails closed without freeing the original live
  BO. A refreshed
  `agx_submit_info` consumer also validates finalized Asahi compute/render
  batch structure and rejects known command-stream, helper, sampler, or
  attachment ranges that are not owned by the active native BO set. Valid work
  reaches the carrier-import boundary without a Linux DRM packet; it remains
  non-submittable until that import boundary exists. The handoff now carries
  each actual `batch->cdm.bo` or `batch->vdm.bo` source with its command;
  macOS rejects a stream range unless it resolves to the same source BO and
  native handle. It also proves every binary and timeline sync handle belongs
  to the current Mesa device before carrier admission. Timestamp-bearing
  batches now carry declared timestamp source BOs, which macOS validates
  without constructing a private Apple object. Every finalized batch now
  carries its complete Asahi BO dependency set as a neutral resource table;
  macOS checks every command-referenced range against it. The native screen
  factory now requires this direct `submit_info` boundary rather than a Linux
  `drm_asahi_submit` callback. A refreshed
  public-Metal `IOGPUResourceCreate` trace proves that resource-object lifetime
  is independent of GPU-VA identity: sixteen returned objects map to thirteen VAs on
  the profiled host. Raw selector-9 allocation is admitted only through the
  generation-owned BO set, which rejects reused allocation identities; typed
  Apple resource objects remain a separate future requirement rather than an
  inferred replacement for that ownership rule. An expanded 4/8/16/32/128 KiB public-Metal
  series now proves a size-aware object policy: observed `70040000` records are
  data-bearing and their little-endian word at record offset `0x48` matches the
  object's data/resident/GPU-VA allocation size (measured at 16 KiB, 32 KiB,
  and 128 KiB), while observed `300c0000` records are non-data-bearing
  suballocation objects. These are profile-specific evidence keys, not ABI
  field names. The unresolved cookie/generation region, paired-object relation,
  failure cleanup, and generic mapping coherence keep typed resource creation
  disabled. A public `MTLBuffer.contents` inventory now also proves all thirteen
  public CPU ranges are contained by ten data-bearing generic resource ranges,
  with three offset suballocations. This is an ownership/range observation only;
  it does not permit AO46 to map or write generic resources. A duplicate 16 KiB
  direct allocation has an identical 104-byte record but distinct resource and
  GPU-VA identities, while cache mode changes only `0x05` and allocator/failure
  transitions change only `0x60..0x63`; that tail is opaque allocator-owned
  metadata. Every non-data object has one containing data-bearing GPU-VA range,
  and its record fields `0x38`/`0x40` match the public mapping/backing CPU
  pointers. A public oversized request returns null from the generic constructor
  without creating or releasing an object, and two subsequent allocations
  recover successfully. A separate public-Metal hardware smoke proves
  bidirectional CPU/GPU visibility through a private buffer. Resolve-only
  read-only accessors are verified. The constructor trace now also verifies all
  17 complete records reach IOKit selector `9` unchanged; the stateful tail is
  a kernel-facing input, not an AO46-constructible field. A documented kernel
  UABI or Apple-owned allocator path, generic resource mapping/coherency API,
  and unknown partial-failure cleanup still block a typed AO46 constructor.
  The Apple-owned allocator condition is now met separately: the public
  `AppleAGXMetalAllocation` broker retains `MTLBuffer` ownership and exposes
  its public `gpuAddress` and allowed CPU mapping. A fresh 13-buffer trace
  proves every such GPU VA matches a generic resource VA from the corresponding
  Apple allocation phase, and its smoke test covers shared/private allocation
  and teardown. This avoids constructing the opaque selector-9 record, but it
  does not expose a generic resource object or satisfy resource-sidecar and
  direct-submission requirements. `AppleAGXMetalResourceSet` now provides the
  next safe handoff: it validates full public GPU-VA ranges, pins the command
  record allocation and every resource in a copy-safe lease, and uses only the
  observed Mesa resource-record slots to encode blit/compute addresses. Its
  hardware smoke rejects an invalid range without changing the record, checks
  the blit-producer, blit-consumer, and compute layouts against full public
  GPU-VA ranges, blocks teardown while pinned, and rejects a stale copied
  lease. The Apple resource-sidecar object relation and direct submission
  remain separate blockers. The Apple-owned command-carrier
  constructor is now measured with a return identity: the public empty-command
  control creates and returns one storage object before the first of two
  64-byte carriers and ordered public completions. Its analyzer enforces that
  ordering. Read-only profile disassembly confirms that this constructor
  consumes a private parameter object and initializes internal resource lists,
  so it remains Apple-owned and resolve-only rather than an AO46 call path.
  The public-to-generic handoff is now traced: each public `MTLCommandBuffer`
  enters `-[IOGPUMetalCommandBuffer fillCommandBufferArgs:commandQueue:]` as
  `self`, and the method's argument-record pointer becomes the exact 64-byte
  descriptor observed by generic queue submission. Generic submit has a null
  command-buffer pointer on this profile, which proves the public object is
  lowered by Apple rather than accepted by the generic C entry point. This is
  a verified Apple-owned handoff for observation and public completion, not a
  documented Asahi batch-injection ABI; AO46 must not invoke the private fill
  method or synthesize its descriptor.
  The Metal 4 allocator audit is now complete on the active profile:
  `MTL4CommandAllocator` supplies storage only for an attached
  `MTL4CommandBuffer` to encode Metal commands. Read-only runtime metadata
  confirms matching private storage getters on Apple objects, but the public
  API has no external AGX-command, resource-table, or descriptor import.
  A four-workload procedural capture (blit, compute, render, and IOSurface)
  reaches the same storage, binding-record, Apple command-buffer fill,
  descriptor, Trap4, and completion sequence each time. For every submission,
  the fill method's `arguments` pointer is exactly the 64-byte descriptor
  passed to generic queue submit; generic submit's object-array pointer is
  null. This closes the Apple-command-carrier discovery gate with a negative
  result: the current OS/GPU profile exposes no usable Asahi import boundary,
  so direct private injection remains disabled.
- `[~]` 2. Submission UABI observation and sidecar validation: the observed
  64-byte descriptor, headers, outer carrier offset, 256-byte diagnostic
  prefix, and a 4 KiB immutable admission snapshot are validated. The render
  descriptor-variation verifier can now require that 4 KiB capture explicitly
  (`AGX_TRACE_REQUIRE_EXTENDED=1`), proving each render's extended snapshot and
  nonzero opaque slot before accepting the trace. Fresh
  render and compute captures both prove the 4 KiB carrier and the nonzero
  opaque slot at `0x790`; the slot is captured but never dereferenced or
  decoded. `libwrap.dylib` applies the same extended validator to live trace
  carriers. Submission admission now normalizes aliased resource ranges to
  one BO pin per batch, and a lease may enter the in-flight state only with
  that extended trace-valid evidence. The sidecar pointer graph, command
  payload encoding, and direct Trap4 submission remain disabled. Fresh
  two-command-buffer no-submit traces now enforce the observed selector-6
  first-buffer scope and selector-`0x0e` `0x4000/0,1` pair for each buffer,
  while rejecting any Trap4 or completion event. This is UABI evidence only:
  framework bootstrap owns the generation-scoped command-pair prerequisites,
  but it does not build or dispatch a Trap4 submission.
  Controlled raw 4 KiB carrier capture is now available to the offline layout
  analyzer, which distinguishes stable and varying word locations without
  claiming sidecar semantics. The resource-variation gate now proves that the
  controlled blit resource bindings occur in a separate CPU-mapped command
  record and that the sidecar contains zero direct or indirect resource
  references. The confirmed resource addresses are encoded in those records
  only: blit producer `0x0/0x8`, blit consumer `0x0/0x8/0x20/0x28`, and
  compute `0x1ba0/0x1ba8`. Each encoder requires
  full-range native BO ownership before it changes a record. The Trap4 builder
  now produces a validated, integrity-checked in-memory outer-packet preview
  from captured evidence, but intentionally has no submit operation. The
  submission package now composes the command-record backing range, resource
  ranges, BO pins, immutable carrier, and preview into one admission unit;
  it rejects a package without an explicit record backing range. It now also
  requires a current notification-queue bind before an admitted package may
  enter flight, rejects foreign completion tokens, and drops its immutable
  carrier after the second matching completion releases every BO pin. This is
  a non-submittable lifecycle contract, not a private submission call.
  Controlled resource-range and render-lifecycle traces continue to validate
  the carrier and resource/completion relationships without changing that
  boundary.

  `capture_agx_uabi_profile.sh` now repeats that validation over nine hardware
  workloads: empty, two-queue, blit control, blit resource record, compute
  record, compute range, render record, render variation, and IOSurface.
  Its transport verifier rejects a mismatch in Trap4 index, queue, descriptor
  size, carrier shape, completion pairing, or the profiled extended-pointer
  invariant before a trace can be accepted as UABI evidence. The profile also
  requires one exact 4 KiB hexadecimal carrier record per submission and
  writes one sidecar-layout report per workload. These reports classify stable
  and varying words without assigning undocumented field semantics. The same
  profile now requires a bounded 512-byte hexadecimal target capture for every
  readable sidecar pointer and writes a separate pointer-layout report keyed by
  the originating sidecar offset. On the profiled host, the captured `0x368`,
  `0x790`, `0xa58`, and `0xab8` targets are verified ASCII C-string tables
  with no tracked GPU-resource references. Other bounded targets may remain
  `unclassified`; they are explicitly excluded from resource-table candidates
  rather than being interpreted. Pointer targets remain evidence only. The
  first Mesa-to-record connection is complete: a macOS-backed Mesa
  `agx_bo` is admitted only when its CPU-mapped record range and every resource
  GPU-VA subrange resolve to the active native BO set, and its Mesa reference
  survives until the native package retires. The Mesa adapter now also validates
  the mapped BO span shape used by Asahi VDM/CDM encoders before a future
  command-record adapter can retain it. The remaining task is to connect actual
  Asahi batch command semantics to an independently proven Apple
  command-record allocation, extend the proven BO-set path to typed resources,
  and establish outer transport ownership; AO46 must not reinterpret the Linux
  `drm_asahi_submit` packet as an Apple command record.
- `[~]` 3. Completion, fence, retirement, and failure handling: notification
  queues, token matching, resource-lease retirement, device-loss abandonment,
  foreign-record preservation, and screen-bootstrap queue ownership exist.
  Direct-submit admission now additionally binds a carrier-backed lease to a
  live notification queue generation and its current AGX session before it may
  become in-flight or consume a completion. Lease admission, submission, and
  direct completion recording also require a current BO-set generation. The
  package smoke rejects a repeated valid token while its peer token and every
  BO pin are still required, so only two distinct observed tokens can retire
  the package.
  The private-winsys capture now combines read-only private-call observation
  with the public transport wrapper in one target process, proving that traced
  materialized command resources outlive both observed descriptor tokens.
  The serial control shows completion-token values may recur on a later queue
  only after their earlier pair retires, so queue/token generation is the
  required ownership key rather than descriptor-pointer identity.
  The owned opaque carrier snapshot includes a non-cryptographic integrity check,
  so an accidental in-process mutation cannot advance a lease to submission.
  Submission also requires a lease-specific queue bind; binding the exposed
  fence alone cannot make a carrier-backed lease eligible.
  A live BO set also blocks device-loss retirement, so normal in-flight work
  cannot be abandoned before the owning session has been invalidated.
  Queue state, peek, dequeue, and
  drain paths apply the same check, rejecting an ID-only or stale-queue
  completion path before it touches completion memory.
Mesa sync adoption also now requires an in-flight package to be bound to the
device's exact current queue connection, queue ID, and API generation before
it can own completion retirement. One admitted package can now be assigned to
a unique group of output sync handles, allowing one verified completion to
retire the batch binary fence and flush timeline fence together. Binary outputs
explicitly rearm reusable batch handles, while a timeline output must advance
past its prior completion. Multiple in-flight timeline points are retained
separately and may complete out of order; only their contiguous completed
prefix advances the visible timeline. Batch admission rejects zero handles,
invalid binary/timeline values, duplicate outputs, and already-owned output
handles before it can reach the carrier boundary.
  A rejected bootstrap teardown now leaves its queue and other ready state
  intact when a BO map or submission pin remains live. Completion and
  device-loss retirement now also discard the immutable carrier snapshot.
  The live bootstrap smoke now proves an admitted carrier-backed in-flight
  lease blocks teardown until the explicit device-loss retirement path releases
  its BO pins. Fresh two-queue range and render-lifecycle controls complete
  their observed token pairs before releasing traced resources. Real
  submit-originated completion records, GPU resets, and device-loss recovery
  remain.
- `[~]` 4. Native Mesa `pipe_screen` and context admission: CGL profiles route
  to Mesa admission, validate the intended 3.2-4.6 request range, and reject
  safely while native blockers remain. With
  `AO46_ENABLE_NATIVE_SCREEN_BOOTSTRAP=1`, the framework itself now exercises
  the device/BO/command/queue/drawable ownership root; this route is in the
  CGL smoke matrix. Mesa's Asahi `agx_screen_create` now separates its Linux
  DRM fd/device acquisition from the complete downstream Gallium screen,
  compiler, capability, resource, and context setup. The macOS factory will
  reuse that exact finalization path after it can initialize an `agx_device`
  with real parameters, VM, BO, queue, and synchronization operations.
  `agx_screen_create_macos` now owns that direct non-DRM handoff: it accepts
  only a fully populated native device, transfers it into the upstream screen
  finalization, and fails cleanly if native synchronization is unavailable.
  The framework's opt-in native route now owns the same private Mesa
  `agx_device` over its bootstrap BO set and exposes its precise capability
  state for diagnostics. The adapter supplies real profiled BO allocation,
  mapping, and fixed-VA mapping validation, while explicitly reporting that
  generic VM binding, submission, and completion sync are unavailable. A real
  `pipe_context` remains blocked on those missing capabilities.
- `[~]` 5. IOSurface, CAMetalLayer, resize, and presentation lifecycle:
  IOSurface creation, explicit write/read handoff, generation-tracked
  transactional resize, stable native IOSurface identity, and explicit
  `(IOSurfaceID, generation)` stale-drawable tokens exist. Mesa and CMake
  smoke coverage verifies that resize and destruction invalidate old tokens.
  Lifecycle operations are serialized, and a live CPU map makes resize and
  teardown return busy rather than invalidating client-visible memory;
  the hardware trace verifies IOSurface import, clear, and readback. The
  framework now atomically copies an unlocked `IOSurfaceID`/generation/layout snapshot
  under its bootstrap lock, so a future `pipe_screen` never borrows a drawable
  pointer across resize. It can also acquire a retained IOSurface lease and
  later reject it as stale after resize before rebinding. Framework-owned
  native bootstrap ownership also exists.
  CAMetalLayer import/export, drawable acquisition, and present remain.
- `[~]` 6. Offscreen rendering, readback, and CTS admission: the native
  bootstrap now performs a hardware-tested IOSurface write/read round trip.
  Its resource admission now also requires the same immutable carrier gate as
  future graphics work. The framework profile smoke verifies the native screen
  blocker before its Mesa clear/readback section can run. Real Mesa offscreen
  rendering and staged CTS remain blocked on lanes 2 and 4.

## Historical Framework Audit

The following workstreams record earlier framework and handwritten-backend
assessment. They remain useful for bug triage, but no new OpenGL semantics are
to be implemented from these lists when Mesa already owns them. Active work
routes such behavior through Mesa and concentrates AO46 changes on the Metal
backend, framework/ICD integration, CTS failures, and macOS specialization.

## Workstreams

1. `Implemented` System-facing driver architecture
   Scope: Apple-path `OpenGL.framework` loader, `OpenGL_4.6.framework`, `libGLICD.dylib`, `libGL.dylib`, `libGLContext.dylib`, `libNSOpenGLContext.dylib`, client/runtime bridge, headers, and module metadata.
   Still required: stable ABI between layers, version negotiation, universal-binary strategy, code-signing strategy, hardened-runtime compatibility, atomic replacement and rollback, runtime capability probing, per-application compatibility settings, and crash isolation where possible.

2. `Partial` OpenGL entry-point dispatch
   Scope: generated client, ICD, framework, and backend exports already exist.
   Still required: complete OpenGL 4.6 registry coverage with real semantics, context-specific dispatch, extension/version gating, no-context behavior, alias handling, fast validated dispatch, and tracing/validation support.

3. `Partial` CGL and macOS context integration
   Scope: renderer enumeration, pixel formats, contexts, share groups, pbuffers, offscreen drawables, CGL shim testing, and NSOpenGL bridge. CGL core-profile requests now map directly to Mesa state-tracker requests; insufficient Mesa support returns `kCGLBadPixelFormat` rather than silently lowering the requested version.
   Still required: debug/robust/no-error profiles, cross-thread migration, drawable acquisition and loss behavior, Retina/backing-scale handling, swap interval, fullscreen behavior, color-space handling, and undocumented Apple-quirk compatibility where needed.

4. `Partial` Context state foundation
   Scope: current error state, draw/read buffers, pack/unpack alignment, clear values, masks, viewport, scissor, line width, point size, polygon mode, cull/front-face state, depth range, depth function, and several core queries.
   Still required: broader scalar/vector/integer/64-bit/indexed/object-specific queries, program-interface queries, multisample positions, debug and robustness state, transform-feedback state, compute limits, and extension-aware query behavior.

5. `Partial` Object model and lifetime management
   Scope: internal objects already exist for contexts, share groups, textures, buffers, pbuffers, drawables, and parts of VAO-associated state.
   Still required: precise object-family semantics for buffers, VAOs, textures, samplers, shaders, programs, pipelines, framebuffers, renderbuffers, queries, transform feedback, and sync objects, including sharing rules, zombie objects, default objects, labels, immutable-state rules, and thread-safe lookup.

6. `Partial` Buffer-object subsystem
   Scope: `glGenBuffers`, `glCreateBuffers`, `glBindBuffer`, `glBindBufferBase`, `glBindBufferRange`, `glBufferData`, `glBufferSubData`, `glBufferStorage`, `glMapBuffer`, `glMapBufferRange`, `glUnmapBuffer`, `glFlushMappedBufferRange`, `glGetBufferParameteriv`, `glGetBufferParameteri64v`, `glGetBufferPointerv`, `glGetBufferSubData`, `glCopyBufferSubData`, `glClearBufferData`, `glClearBufferSubData`, `glNamedBufferStorage`, `glNamedBufferData`, `glNamedBufferSubData`, `glCopyNamedBufferSubData`, `glClearNamedBufferData`, `glClearNamedBufferSubData`, `glMapNamedBuffer`, `glMapNamedBufferRange`, `glUnmapNamedBuffer`, `glFlushMappedNamedBufferRange`, `glGetNamedBufferParameteriv`, `glGetNamedBufferParameteri64v`, `glGetNamedBufferPointerv`, `glGetNamedBufferSubData`, indexed binding queries via `glGetIntegeri_v` and `glGetInteger64i_v`, broader generic buffer targets, indexed-draw buffer use, and VAO-owned EBO state.
   Still required: persistent/coherent mapping behavior, deeper target-specific semantics for PBO/indirect/uniform/storage consumers, broader 64-bit/object query coverage, and a real Metal buffer allocation/synchronization strategy.

7. `Partial` Vertex arrays and attribute input
   Scope: VAO state, basic floating-point attribute pulling, and static per-instance vertex divisors exist for the current draw path.
   Still required: full VAO lifecycle, integer/double attributes, normalized and packed formats, dynamic divisor state, complete base-vertex/base-instance rules, multiple binding models, DSA VAO APIs, state queries, and shader-based or repacked vertex pulling for hard layouts.

8. `Required` Shader-language implementation
   Scope: this is one of the largest missing systems.
   Required: GLSL 4.60 preprocessor, parser, semantic analysis, all shader stages, compiler IR, optimization pipeline, and GLSL-to-Metal semantic lowering.

9. `Partial` Shader and program objects
   Scope: basic shader/program creation, source upload, compile, link, validate, and minimal uniform discovery already exist for the current smoke path.
   Still required: complete shader/program semantics, full uniform model, UBO reflection/layout, program pipelines, and binary/cache handling.

10. `Required` SPIR-V support
    Scope: `ARB_gl_spirv`-class ingestion for OpenGL 4.6.
    Required: `glShaderBinary`, `glSpecializeShader`, SPIR-V validation, capability filtering, binding/location translation, diagnostics, and shared IR strategy.

11. `Partial` Texture subsystem
    Scope: active texture state, 2D textures, aligned upload/readback, texture sub-images, immutable storage beginnings, generated mipmaps, basic sampling, and pbuffer import are in flight.
    Still required: broader texture targets, complete storage/transfer family, richer format coverage, full sampling behavior, PBO transfers, texture views, multisample textures, and robust readback.

12. `Required` Sampler objects
    Scope: sampler state still lives on textures today.
    Required: independent sampler objects, binding/query behavior, LOD state, border color, compare mode/function, anisotropy, and multi-bind samplers.

13. `Partial` Framebuffer and renderbuffer objects
    Scope: framework-owned offscreen storage, pbuffers, clear/readback, draw/read-buffer state, and pbuffer-to-texture import provide a framebuffer-like base.
    Still required: full FBO lifecycle, attachments, completeness validation, renderbuffers, blits/resolves, layered rendering, clear-buffer APIs, and completeness caching.

14. `Partial` Drawing commands
    Scope: `glDrawArrays`, `glDrawElements`, `glDrawRangeElements`, `glFlush`, and `glFinish` exist with basic indexed/non-indexed pulling, bounded base-vertex, primitive restart, a `1..64` record indirect sequence, and static direct-instancing input.
    Vertex-element state now has a bounded Gallium lifecycle for contiguous `float2`/`float4` inputs, including per-instance divisors, and rejects layouts that disagree with the Metal pipeline descriptor.
    Still required: generalized GPU-generated indirect argument records and
    unbounded batches, transform-feedback drawing, general patches/adjacency,
    conditional rendering, general vertex formats/sparse attributes, and
    broader draw validation. A bounded GPU-produced indirect-count path exists
    only for prevalidated ICB command records.

15. `Required` Tessellation pipeline
    Scope: not implemented yet.
    Required: patch state, tessellation-control/evaluation shaders, spacing/topology modes, per-patch interfaces, and Metal tessellation lowering.

16. `Required` Geometry shaders
    Scope: not implemented yet.
    Required: geometry-stage compile/link behavior, input/output topology rules, layered rendering hooks, `EmitVertex`/`EndPrimitive`, and likely compute- or multi-pass-based emulation.

17. `Partial` Rasterization
    Scope: viewport, scissor, culling state, front-face state, polygon mode, line width, point size, depth range, and basic triangle rasterization exist.
    Still required: point/line rasterization behavior, polygon offset, provoking vertex, clipping, clip/cull distances, depth clamping, multiple viewports/scissors, and clip-control behavior.

18. `Required` Multisampling
    Scope: not implemented yet beyond reported limits.
    Required: multisampled textures/renderbuffers, sample coverage/masks, alpha-to-coverage, sample shading, position queries, resolves, and per-sample execution semantics.

19. `Partial` Fragment operations
    Scope: clear color/depth/stencil, color mask, depth mask, and parts of depth state exist.
    Still required: full depth testing, stencil testing, blending, logic ops, dithering, sRGB conversion, per-target masks, sample-mask behavior, helper-invocation rules, and strict post-fragment ordering.

20. `Required` Transform feedback
    Scope: not implemented yet.
    Required: transform-feedback objects, bindings, interleaved/separate modes, varyings, begin/pause/resume/end behavior, overflow handling, draw-from-capture behavior, and likely shader instrumentation.

21. `Required` Queries
    Scope: not implemented yet.
    Required: occlusion, timer, primitive/pipeline statistics, transform-feedback overflow, 32/64-bit results, query-buffer output, and conditional rendering.

22. `Partial` Synchronization
    Scope: `glFlush` and `glFinish` are the current baseline.
    Still required: sync objects, waits, timeouts, resource visibility guarantees, memory barriers, texture/SSBO/image/atomic barriers, and Metal fence/shared-event translation.

23. `Required` Compute shaders
    Scope: not implemented yet.
    Required: compute compile/link path, dispatch, work-group semantics, shared memory, barriers, indirect dispatch, and full Metal compute-pipeline translation.

24. `Required` Shader Storage Buffer Objects
    Scope: not implemented yet.
    Required: SSBO bindings, reflection, `std430` layout, unsized arrays, qualifiers, barriers, atomics, and backend storage-buffer translation.

25. `Required` Image load/store
    Scope: not implemented yet.
    Required: image-unit bindings, layered/mip-level image access, loads/stores/atomics, format compatibility, aliasing rules, and image barriers.

26. `Required` Atomic counters and shader atomics
    Scope: not implemented yet.
    Required: atomic-counter buffers, reflection, counter ops, buffer/image atomics, and ordering/visibility behavior.

27. `Required` Direct State Access
    Scope: not implemented yet.
    Required: DSA creation/configuration/query APIs across buffers, textures, VAOs, framebuffers, renderbuffers, samplers, pipelines, and transform feedback, all routed through the same object implementations as bindful APIs.

28. `Required` Multi-bind APIs
    Scope: not implemented yet.
    Required: multi-bind buffer, texture, sampler, image, and vertex-buffer entry points with efficient shared validation paths.

29. `Required` Debug output
    Scope: not implemented yet.
    Required: debug callbacks, filtering, message insertion, debug groups, object labels, stable IDs, thread-safe delivery, and meaningful translation diagnostics.

30. `Required` Robustness and context loss
    Scope: not implemented yet.
    Required: reset-status queries, robust reads, context-loss propagation, drawable loss handling, command-buffer failure mapping, and recovery policy.

31. `Required` No-error contexts
    Scope: not implemented yet.
    Required: context creation flag, validation bypass for valid apps, optimized dispatch, and preserved memory safety.

32. `Required` OpenGL 4.6-specific feature delta
    Scope: final 4.6 feature completion.
    Required: generalized GPU-generated indirect argument records and
    unbounded batches, pipeline-statistics queries, polygon offset clamp,
    no-error contexts, expanded shader atomic-counter ops, shader draw
    parameters, group-vote operations, SPIR-V ingestion, anisotropic filtering,
    and transform-feedback overflow queries. The current bounded GPU count path
    is not sufficient for this OpenGL 4.6 requirement.

33. `Partial` AO46MTLGallium migration
    Scope: audit and migrate `GL2MTL/mtl_driver.m` into the single Mesa-facing
    `AO46MTLGallium.m` driver. The promoted build target now exists; remove the
    remaining legacy source naming only after equivalent or stronger regression
    coverage is in place.
    Still required: capability audit, adapter ABI extraction, active framework
    integration, and per-feature Metal regression coverage.

34. `Required` Capability and format database
    Scope: not implemented yet.
    Required: central capability tables driven by GPU family, macOS version, format support, limits, and alignment rules, with one source of truth for queries, extension exposure, validation, and rejection policy.

35. `Required` AO46AGXMetalAdapter boundary
    Scope: keep Metal queue/resource/pipeline/fence/drawable services below
    `AO46MTLGallium.m`, informed by profile-gated research without depending on
    private AGX runtime contracts.
    Still required: extracted adapter ABI, capability policy, resource hazards,
    presentation lifecycle, and regression coverage.

36. `Partial` Error semantics
    Scope: `glGetError` and internal error tracking already exist.
    Still required: full error precedence, `GL_INVALID_FRAMEBUFFER_OPERATION`, `GL_OUT_OF_MEMORY`, context-loss errors, no-error behavior, async backend error mapping, and richer shader/program diagnostics.

37. `Partial` Shared objects and multiple contexts
    Scope: share groups and current-context routing already exist.
    Still required: simultaneous multi-threaded contexts, shared visibility guarantees, deletion races, VAO non-sharing rules, default-object isolation, safe migration between threads, and deadlock-safe share-group teardown.

38. `Implemented` Testing already employed
    Scope: current smoke tests cover renderer enumeration, pixel formats, context creation, offscreen binding, state queries, clears, readback, indexed/non-indexed drawing, buffer updates, pixel-store alignment, texture sub-images, texture sampling, pbuffer import, current-context behavior, share groups, and NSOpenGL compatibility.

39. `Required` Testing still required
    Scope: unit tests, API semantic tests, rendering tests, concurrency tests, and formal conformance remain outstanding.
    Required: boundary-value coverage, deleted-object references, invalid interfaces, misalignment, overlapping copies, reference images, depth/stencil/blend correctness, multithread stress, and Khronos conformance suites.

40. `Required` Performance engineering
    Scope: not implemented yet.
    Required: pipeline/shader caches, batching, dirty-bit tracking, suballocation, transient rings, async compilation, upload staging, cache eviction, hazard elision, async readback, and profiling infrastructure for CPU/GPU cost and cache-hit telemetry.

41. `Partial` Installer and system safety
    Scope: live install targets are real, SIP/AuthRoot checks exist, and the installer bootstraps from the GitHub repo.
    Still required: original-framework backup, cryptographic verification, atomic replacement, rollback and uninstall commands, interrupted-install recovery, per-file/version manifests, compatibility checks, automatic rollback after failed smoke tests, and per-app compatibility switches.

42. `Implemented` Suggested implementation order
    Scope: the engineering map already provides a sane phase sequence, and this document adopts it as the official order for future work.

## Phase Order

1. Phase 1: Mesa Metal screen bring-up
   Deliver: one Mesa-owned `pipe_screen`/`pipe_context` using `MTLDevice`, a
   Metal queue, Mesa's NIR-to-MSL output, deterministic offscreen clear, and
   CPU readback. No hand-written GL semantics.

2. Phase 2: Mesa resource and pipeline path
   Deliver: Mesa-owned buffers, textures, samplers, shaders, framebuffers,
   draw calls, hazards, and synchronization mapped to Metal resources and
   pipelines, with capability reporting driven by proven behavior.

3. Phase 3: macOS drawable and framework integration
   Deliver: CGL/NSOpenGL context admission, IOSurface/CAMetalLayer lifecycle,
   Retina updates, swap/present, ICD dispatch, user-space libraries, error
   propagation, and context loss behavior against the live Mesa Metal screen.

4. Phase 4: targeted feature exposure and CTS
   Deliver: enable Mesa features only where the Metal backend supports them,
   run targeted OpenGL CTS groups, then expand through compute, storage/image,
   synchronization, advanced stages, and the verified OpenGL 4.6 delta.

5. Phase 5: AO46 specialization and release-quality work
   Deliver: compatibility handling for real applications, performance and
   pipeline caches, multi-context stress, diagnostics, installer rollback,
   long-duration reliability tests, and broader CTS coverage.

## Immediate Execution Policy

- We follow the phase order above unless a lower-level dependency forces a reorder.
- Each pass begins with the available build/test sweep, then advances the Mesa
  Metal backend, AO46 framework/ICD integration, or CTS failure resolution.
- Each capability lands with its Mesa path, Metal behavior, framework exposure,
  regression coverage, and updated feature gate together.
- Current practical focus is Phase 1: a live Mesa-controlled Metal screen with
  deterministic offscreen rendering and readback.

## Current Repository Summary

### Strongly established

- system framework architecture
- Apple-path interception
- ICD layering
- framework/runtime/client separation
- CGL and NSOpenGL integration
- generated API dispatch
- context and share-group foundations
- meaningful smoke tests
- installer architecture
- preserved direct-AGX research evidence and Ghidra analysis

### Partially established

- Mesa semantic/compiler reuse boundary
- NIR-to-MSL compiler sources in the build graph
- Metal backend build scaffolding
- framework/ICD capability and failure plumbing
- CGL/NSOpenGL drawable integration

### Major systems still to be built

- live Mesa Metal `pipe_screen` and `pipe_context`
- Metal resource, shader/pipeline, command, synchronization, and readback path
- IOSurface/CAMetalLayer presentation and resize lifecycle
- real framework/ICD capability gates backed by the Metal screen
- staged Khronos CTS execution and failure resolution
- application compatibility, performance, rollback, and stability work
