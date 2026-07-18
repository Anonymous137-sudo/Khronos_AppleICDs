# Workflow Plan

This document is the active engineering workflow plan for `Khronos_AppleICDs` as of July 18, 2026.

It adopts the repo-to-full-OpenGL-4.6 engineering map originally assessed against commit `1a0d21e` and turns that assessment into the working implementation order for the driver framework from this point forward.

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
- Expand existing smoke coverage whenever a new object family or state path becomes real.
- Treat the Metal execution backend, object semantics, and platform integration as one system.
- Keep public repo documentation aligned with the current implementation boundary.

## Workstreams

1. `Implemented` System-facing driver architecture
   Scope: Apple-path `OpenGL.framework` loader, `OpenGL_4.6.framework`, `libGLICD.dylib`, `libgl2mtl.dylib`, `libGL.dylib`, `libGLContext.dylib`, `libNSOpenGLContext.dylib`, client/runtime bridge, headers, and module metadata.
   Still required: stable ABI between layers, version negotiation, universal-binary strategy, code-signing strategy, hardened-runtime compatibility, atomic replacement and rollback, runtime capability probing, per-application backend selection, and crash isolation where possible.

2. `Partial` OpenGL entry-point dispatch
   Scope: generated client, ICD, framework, and backend exports already exist.
   Still required: complete OpenGL 4.6 registry coverage with real semantics, context-specific dispatch, extension/version gating, no-context behavior, alias handling, fast validated dispatch, and tracing/validation support.

3. `Partial` CGL and macOS context integration
   Scope: renderer enumeration, pixel formats, contexts, share groups, pbuffers, offscreen drawables, CGL shim testing, and NSOpenGL bridge.
   Still required: precise context creation semantics, debug/robust/no-error profiles, cross-thread migration, drawable acquisition and loss behavior, Retina/backing-scale handling, swap interval, fullscreen behavior, color-space handling, and undocumented Apple-quirk compatibility where needed.

4. `Partial` Context state foundation
   Scope: current error state, draw/read buffers, pack/unpack alignment, clear values, masks, viewport, scissor, line width, point size, polygon mode, cull/front-face state, depth range, depth function, and several core queries.
   Still required: broader scalar/vector/integer/64-bit/indexed/object-specific queries, program-interface queries, multisample positions, debug and robustness state, transform-feedback state, compute limits, and extension-aware query behavior.

5. `Partial` Object model and lifetime management
   Scope: internal objects already exist for contexts, share groups, textures, buffers, pbuffers, drawables, and parts of VAO-associated state.
   Still required: precise object-family semantics for buffers, VAOs, textures, samplers, shaders, programs, pipelines, framebuffers, renderbuffers, queries, transform feedback, and sync objects, including sharing rules, zombie objects, default objects, labels, immutable-state rules, and thread-safe lookup.

6. `Partial` Buffer-object subsystem
   Scope: `glGenBuffers`, `glBindBuffer`, `glBufferData`, `glBufferSubData`, `glGetBufferParameteriv`, indexed-draw buffer use, and VAO-owned EBO state.
   Still required: broader buffer targets, mapping APIs, immutable storage, persistent/coherent mapping behavior, buffer copies and clears, indexed bindings, DSA buffer APIs, robust readback, and a real Metal buffer allocation/synchronization strategy.

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

33. `Partial` Metal GPU execution backend
    Scope: `libgl2mtl.dylib` exists and already handles state, storage, and basic raster behavior.
    Still required: real Metal device/queue/encoder ownership, GPU resources, render and compute pipelines, binding allocator, command recording, dirty-state tracking, resolves, and visibility-point handling.

34. `Required` Capability and format database
    Scope: not implemented yet.
    Required: central capability tables driven by GPU family, Metal features, macOS version, format support, limits, and alignment rules, with one source of truth for queries, extension exposure, validation, and fallback policy.

35. `Required` Emulation layer for Metal gaps
    Scope: not implemented yet.
    Required: explicit fallback strategies for geometry shaders, transform feedback, wide lines, point rules, polygon modes, certain queries, clipping behavior, unusual texture views, some atomic semantics, and cross-context synchronization corner cases.

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
