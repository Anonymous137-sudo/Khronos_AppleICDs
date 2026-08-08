# Workflow Plan

This document is the active engineering workflow plan for `Khronos_AppleICDs`.

It adopts the repo-to-full-OpenGL-4.6 engineering map originally assessed against commit `1a0d21e` and turns that assessment into the working implementation order for the driver framework from this point forward.

## Governing Native AGX Pivot

The authoritative architecture is [`AO46AGXNativeArchitecture.md`](AO46AGXNativeArchitecture.md).

AO46 no longer plans to manually implement OpenGL 4.6 semantics, GLSL, NIR
lowering, shader stages, object validation, or AGX GPU execution. The full Mesa
OpenGL implementation and full Mesa Asahi Gallium driver remain upstream code
and are the only source of those behaviours. AO46 code is limited to macOS
framework/CGL/NSOpenGL integration and, later, the macOS platform adapter below
Asahi's userspace driver.

The Metal-oriented workstreams and phase descriptions below are retained as a
record of the deprecated development backend and its existing tests. They are not a mandate
to build a parallel GL implementation. All future feature work must first ask
whether upstream Mesa/Asahi already provides the behavior; if it does, AO46
integrates that existing implementation instead of recreating it.

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

## Workflow Rules For Each Pass

- Start with `cmake --build` and `ctest` in the repo-local `artifacts/build`.
- Prefer one coherent vertical slice per pass: object model, API surface, backend behavior, and tests together.
- Every native-winsys pass advances all six readiness lanes in parallel:
  1. GPU-VA resource ownership and BO lifetime.
  2. Submission UABI observation and sidecar validation.
  3. Completion, fence, retirement, and failure handling.
  4. Native Mesa `pipe_screen` and context admission.
  5. IOSurface, CAMetalLayer, resize, and presentation lifecycle.
  6. Offscreen rendering, readback, and CTS admission.
  A lane may advance only with tested implementation work, a newly controlled
  hardware observation, or an explicitly verified blocker. A TODO,
  documentation-only change, version string, or fallback backend is not
  progress. Each pass reports `[x]`, `[~]`, or `[ ]` for every lane.
- Expand existing smoke coverage whenever a new object family or state path becomes real.
- Treat Mesa/Asahi as the sole GL semantic and hardware-driver implementation.
- Keep the Metal execution backend isolated as a deprecated development target;
  it must not become a framework runtime fallback.
- Keep public repo documentation aligned with the current implementation boundary.

## Native Winsys Six-Lane Dashboard

- `[~]` 1. GPU-VA resource ownership and BO lifetime: trace-validated direct
  BO allocation, full-range lookup, submission pinning, and state-gated
  retirement exist. Managed CPU maps are explicitly pinned and protected by
  single-use mapping capabilities, rejecting altered or replayed map handles
  before they can release BO ownership. The framework-owned native screen
  bootstrap starts and tears down the BO set with its AGX session. VM/heap
  management and Mesa `agx_bo` adaptation remain.
- `[~]` 2. Submission UABI observation and sidecar validation: the observed
  64-byte descriptor, headers, outer carrier offset, 256-byte diagnostic
  prefix, and a 4 KiB immutable admission snapshot are validated. Fresh
  render and compute captures both prove the 4 KiB carrier and the nonzero
  opaque slot at `0x790`; the slot is captured but never dereferenced or
  decoded. `libwrap.dylib` applies the same extended validator to live trace
  carriers. Submission admission now normalizes aliased resource ranges to
  one BO pin per batch, and a lease may enter the in-flight state only with
  that extended trace-valid evidence. The sidecar pointer graph, command
  payload encoding, and direct Trap4 submission remain disabled. Fresh
  controlled resource-range and render-lifecycle traces continue to validate
  the carrier and resource/completion relationships without changing that
  boundary.
- `[~]` 3. Completion, fence, retirement, and failure handling: notification
  queues, token matching, resource-lease retirement, device-loss abandonment,
  foreign-record preservation, and screen-bootstrap queue ownership exist.
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
  CGL smoke matrix. The macOS `agx_screen_create` replacement and real
  `pipe_context` remain.
- `[~]` 5. IOSurface, CAMetalLayer, resize, and presentation lifecycle:
  IOSurface creation, explicit write/read handoff, generation-tracked
  transactional resize, stable native IOSurface identity, and explicit
  `(IOSurfaceID, generation)` stale-drawable tokens exist. Mesa and CMake
  smoke coverage verifies that resize and destruction invalidate old tokens;
  the hardware trace verifies IOSurface import, clear, and readback. Framework-
  owned native bootstrap ownership also exists.
  CAMetalLayer import/export, drawable acquisition, and present remain.
- `[~]` 6. Offscreen rendering, readback, and CTS admission: the native
  bootstrap now performs a hardware-tested IOSurface write/read round trip.
  Its resource admission now also requires the same immutable carrier gate as
  future graphics work. The framework profile smoke verifies the native screen
  blocker before its Mesa clear/readback section can run. Real Mesa offscreen
  rendering and staged CTS remain blocked on lanes 2 and 4.

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
   Scope: VAO state and basic floating-point attribute pulling exist for the current draw path.
   Still required: full VAO lifecycle, integer/double attributes, normalized and packed formats, attribute divisors, base-vertex/base-instance rules, primitive restart, multiple binding models, DSA VAO APIs, state queries, and shader-based or repacked vertex pulling for hard layouts.

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
    Scope: `glDrawArrays`, `glDrawElements`, `glDrawRangeElements`, `glFlush`, and `glFinish` exist with basic indexed and non-indexed pulling.
    Still required: instancing, base-vertex/base-instance, multi-draw, indirect drawing, transform-feedback drawing, primitive restart, patches, adjacency, conditional rendering, and broader draw validation.

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
    Required: indirect draw parameter support, pipeline-statistics queries, polygon offset clamp, no-error contexts, expanded shader atomic-counter ops, shader draw parameters, group-vote operations, SPIR-V ingestion, anisotropic filtering, and transform-feedback overflow queries.

33. `Archived` GL2MTL development backend
    Scope: retained for source comparison and its existing tests only. It is excluded from production framework selection.
    Still required: no production work; Mesa/Asahi owns semantic and hardware-driver execution.

34. `Required` Capability and format database
    Scope: not implemented yet.
    Required: central capability tables driven by GPU family, macOS version, format support, limits, and alignment rules, with one source of truth for queries, extension exposure, validation, and rejection policy.

35. `Archived` GL2MTL gap workstream
    Scope: historical design notes for the deprecated development target.
    Still required: no production work; Mesa/Asahi owns conformance behavior and reports only verified backend capability.

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

1. Phase 1: Core object correctness
   Deliver: object namespace and lifetime system, complete buffer storage/mapping, full VAO and vertex attribute configuration, texture object foundation, framebuffer/renderbuffer completeness, broader state queries, and stronger error handling.

2. Phase 2: Real Metal graphics path
   Deliver: `MTLDevice` and queue ownership, real GPU buffer/texture resources, GLSL vertex/fragment compiler path, linker/reflection, Metal render pipelines, depth/stencil and blending, indexed/instanced rendering, and window presentation.

3. Phase 3: Modern resource model
   Deliver: UBOs, sampler objects, immutable storage, DSA, texture arrays and multisampling, framebuffer blits/resolves, persistent mappings, and multi-bind APIs.

4. Phase 4: Compute and memory
   Deliver: compute shaders, SSBOs, images, atomics, atomic counters, memory barriers, sync objects, and indirect dispatch.

5. Phase 5: Advanced graphics stages
   Deliver: tessellation, geometry-shader emulation, transform-feedback emulation, layered rendering, indirect drawing, multi-draw indirect, pipeline statistics, and complex queries.

6. Phase 6: OpenGL 4.6 completion
   Deliver: SPIR-V ingestion, specialization, group-vote operations, shader draw parameters, indirect parameter buffers, anisotropic filtering, polygon offset clamp, no-error contexts, and transform-feedback overflow queries.

7. Phase 7: Shipping quality
   Deliver: Khronos conformance, multi-context stress, CAD/scientific testing, Minecraft and shader-pack testing, performance optimization, compatibility database, safe installer and rollback, and long-duration stability coverage.

## Immediate Execution Policy

- We follow the phase order above unless a lower-level dependency forces a reorder.
- Each feature pass should land with tests, documentation, and backend semantics together.
- We prefer finishing object families completely enough to be dependable before advertising adjacent high-level features.
- Current practical focus remains Phase 1 and the early edge of Phase 2.

## Current Repository Summary

### Strongly established

- system framework architecture
- Apple-path interception
- ICD layering
- framework/runtime/client separation
- CGL and NSOpenGL integration
- generated API dispatch
- context and share-group foundations
- real buffer and texture beginnings
- real offscreen storage
- basic drawing and readback
- meaningful smoke tests
- installer architecture

### Partially established

- VAO and VBO behavior
- texture system
- rasterization
- framebuffer-like storage
- GL state model
- Metal translation boundary
- compatibility behavior

### Major systems still to be built

- GLSL 4.60 compiler
- shader linker and reflection
- full GPU-backed Metal execution
- complete VAO and buffer system
- UBO, SSBO, image, and atomic model
- complete texture and FBO systems
- compute shaders
- tessellation
- geometry emulation
- transform feedback
- complete synchronization
- queries
- DSA
- SPIR-V
- conformance and optimization
