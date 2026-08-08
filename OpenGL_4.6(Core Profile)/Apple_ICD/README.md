# OpenGL_4.6(Core Profile) / Apple_ICD

This is the source tree for the `OpenGL_4.6(Core Profile)` stack, a third-party in-development macOS OpenGL core-profile framework project.

The public and system driver layers are `OpenGL.framework`,
`OpenGL_4.6.framework`, `libGLICD.dylib`, and the user-space bridge dylibs.

AO46 has one production execution path and one archived development target:

- `AO46AGXMac` is the planned native path. It reuses upstream Mesa's OpenGL
  frontend and Asahi Gallium driver stack in full, then replaces only the Linux
  platform boundary with a macOS implementation.
- `GL2MTL` is a deprecated development-only target. It is excluded from the
  default build and is never linked into `OpenGL_4.6.framework`.

AO46 does not reimplement OpenGL 4.6 semantics, the GLSL/NIR compiler stack,
or the Asahi AGX driver. Those are Mesa/Asahi responsibilities. The
project-side responsibilities are macOS framework ABI, CGL/NSOpenGL
integration, drawable lifecycle, and eventually the macOS AGX platform adapter.

The governing design is in
[`docs/AO46AGXNativeArchitecture.md`](../../docs/AO46AGXNativeArchitecture.md).

## Layout

- `framework/`
  The real `OpenGL_4.6.framework` driver. This is the system-space OpenGL 4.6 core-profile entrypoint.
- `backend/`
  Archived development backend interfaces; not part of the production runtime.
- `GL2MTL/`
  Deprecated Metal development code. It is not built or linked by default.
- `AO46AGXMac/`
  The planned macOS platform adapter beneath Mesa's upstream Asahi userspace
  driver. It will contain device, BO, GPU-VA, queue, submission,
  synchronization, IOSurface, and presentation integration without duplicating
  Mesa OpenGL or Asahi compiler code.
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
- a framework-owned backend boundary that selects Mesa Asahi only
- initial `CGL*` compatibility entrypoints
- Khronos `gl*` forwarding into Mesa

The native-backend milestone then builds the upstream Mesa/Asahi stack as a
pinned dependency, adds the AO46AGXMac platform boundary, and validates one
macOS/GPU profile at a time. Until that work is complete, AO46 must not claim
native AGX execution or macOS OpenGL 4.6 conformance.

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
- the runtime now selects only the native Mesa Asahi backend. It fails CGL
  context creation explicitly until the macOS winsys can create an AGX screen;
  it never falls back to `libgl2mtl.dylib`
- the device-profile query, 64-byte capability request, and profile gate are
  implemented for the current host; BO, GPU-VA, queue, submission, and GPU
  synchronization operations remain the blocking macOS winsys work

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
