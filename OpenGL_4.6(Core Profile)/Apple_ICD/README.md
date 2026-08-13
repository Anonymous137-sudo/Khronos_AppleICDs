# OpenGL_4.6(Core Profile) / Apple_ICD

This is the source tree for the `OpenGL_4.6(Core Profile)` stack, a third-party in-development macOS OpenGL core-profile framework project.

The public and system driver layers are `OpenGL.framework`,
`OpenGL_4.6.framework`, `libGLICD.dylib`, and the user-space bridge dylibs.

AO46's active backend direction is Mesa-to-Metal:

- Mesa supplies OpenGL semantics, state tracking, GLSL, SPIR-V, NIR, and the
  reusable NIR-to-MSL compiler machinery.
- AO46 supplies the macOS Metal execution layer, framework ABI, CGL/NSOpenGL,
  drawable lifecycle, ICD, and user-space bridge integration.
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
  The real `OpenGL_4.6.framework` driver. This is the system-space OpenGL 4.6 core-profile entrypoint.
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
  User-space bridge dylibs such as `libGL.dylib`, `libGLContext.dylib`, and `libNSOpenGLContext.dylib`.
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
- the current runtime still fails CGL context creation while no live Mesa Metal
  screen exists; it does not silently select archived GL2MTL code or claim a
  direct AGX runtime
- direct AGX device-profile, BO, queue, submission, and shader-residency work
  is retained as research evidence rather than treated as the active blocker
  for the Metal backend

## Build

```bash
cmake -S "OpenGL_4.6(Core Profile)/Apple_ICD" -B "OpenGL_4.6(Core Profile)/Apple_ICD/artifacts/build"
cmake --build "OpenGL_4.6(Core Profile)/Apple_ICD/artifacts/build"
```

## Live Install

The GitHub-bootstrap installer flow builds from source on the machine and installs into:

- `/System/Library/Frameworks/OpenGL.framework`
- `/System/Library/Frameworks/OpenGL_4.6.framework`
- `/usr/local/lib`

Before a live install to `/`, the installer hard-checks that SIP and Authenticated Root are disabled, and prints the developer-machine warning intended for this in-development driver.

## Smoke Coverage

This tree includes runtime and bridge smoke harnesses:

- `tests/AO46RuntimeCompatSmoke.c`
  Exercises renderer enumeration, pixel-format negotiation, context creation, offscreen binding, core `gl*` state, clears, readback, draw calls, indexed draws, bindful and DSA buffer readback/copy/clear paths, indexed buffer-target binding queries, 64-bit buffer queries, immutable and mutable buffer storage/mapping, `glPixelStorei`, `glTexSubImage2D`, `glTexStorage2D`, `glGenerateMipmap`, textured sampling, and pbuffer-to-texture import.
- `tests/AO46CGLShimCompatSmoke.c`
  Drives the Apple-path `CGL*` surface directly and verifies current-context and share-group routing.
- `tests/AO46NSOpenGLCompatSmoke.m`
  Covers the higher-level `libNSOpenGLContext.dylib` bridge.

Run the smoke sweep with:

```bash
ctest --test-dir "OpenGL_4.6(Core Profile)/Apple_ICD/artifacts/build" --output-on-failure
```
