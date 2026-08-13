# AO46 Mesa Metal Backend Plan

Status: active work-in-progress architecture. This is the governing delivery
plan for AO46. It supersedes the direct AGX/UABI route as the active runtime
strategy; the direct route and its captured evidence remain preserved research.

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
  -> Mesa KosmicKrisp NIR-to-MSL compiler machinery
  -> AO46 Metal backend
  -> Metal device, command queue, resources, pipelines, and presentation
  -> Apple GPU driver and hardware
```

## Ownership

| Area | Owner | AO46 action |
| --- | --- | --- |
| OpenGL objects, validation, state, dispatch, GLSL, SPIR-V, NIR | Mesa | Reuse; do not reimplement |
| NIR-to-MSL lowering and supporting compiler passes | Mesa KosmicKrisp | Reuse and integrate |
| Metal resource, pipeline, command, synchronization, and presentation lifecycle | AO46 Metal backend | Implement for macOS using public Metal APIs |
| CGL, NSOpenGL, framework ABI, loader, ICD, user-space libraries, pixel formats, drawables | AO46 | Maintain and complete |
| GPU scheduling, memory protection, firmware, and hardware management | macOS | Use through Metal; do not replace |

The reusable compiler boundary currently lives under
`mesa/src/kosmickrisp/compiler/`. AO46 must integrate that machinery rather
than maintain a separate GLSL-to-MSL compiler or duplicate NIR lowering.

## Non-Negotiable Reuse Rules

- Mesa remains the sole source of OpenGL API semantics and capability logic.
- AO46 does not hand-write GL object models, GLSL parsing/linking, SPIR-V
  ingestion, state validation, or independent shader lowering.
- The historical `GL2MTL` sources are not the production semantic engine.
  They remain archived development material only.
- Metal capabilities determine advertised versions, extensions, limits, and
  formats. AO46 never reports OpenGL 4.6 merely because a context requested it.
- A feature is complete only after the Mesa path, Metal backend behavior,
  framework/ICD exposure, regression coverage, and relevant CTS slice agree.

## Active Milestones

1. **Mesa-to-Metal bootstrap**
   Build the Mesa NIR-to-MSL components in the normal AO46 backend graph,
   create one `MTLDevice`/queue-backed screen, and prove an offscreen clear and
   readback through Mesa-owned GL state.

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
