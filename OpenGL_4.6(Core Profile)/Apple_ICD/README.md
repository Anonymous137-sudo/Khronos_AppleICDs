# OpenGL_4.6(Core Profile) / Apple_ICD

This is the source tree for the `OpenGL_4.6(Core Profile)` stack, a third-party in-development macOS OpenGL 4.6 core-profile system driver project.

The public and system driver layers are `OpenGL.framework`, `OpenGL_4.6.framework`, `libGLICD.dylib`, and `libgl2mtl.dylib`.

## Layout

- `framework/`
  The real `OpenGL_4.6.framework` driver. This is the system-space OpenGL 4.6 core-profile entrypoint.
- `backend/`
  The internal `libgl2mtl.dylib` backend boundary where OpenGL state and commands are translated toward Metal-facing execution.
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

The first milestone is a clean system-driver bring-up with:

- an exact-path Apple `OpenGL.framework` loader target
- a real `OpenGL_4.6.framework` target
- a framework-owned backend boundary that talks directly to `libgl2mtl.dylib`
- initial `CGL*` compatibility entrypoints
- initial Khronos `gl*` forwarding entrypoints

## Current Shape

Right now this subproject is an early in-development driver:

- runtime bootstrap is implemented
- framework, client, ICD, and user-space bridge layering is implemented
- drawable attachment is framework-owned, with `libGLContext.dylib` helper entrypoints for headless or native-window binding
- `CGL*` context, renderer, pixel-format, pbuffer, option, and share-group entrypoints are routed through the framework/ICD/loader path
- `OpenGL_4.6.framework` now carries public `Headers/` and a `Modules/` definition instead of only the binary and `Info.plist`
- `gl*` entrypoints and the backend proc table are generated from a vendored Khronos-facing registry snapshot stored in this repo
- `libgl2mtl.dylib` now implements the first real GL-visible backend behavior through standard Khronos entrypoints including `glGetString`, `glGetStringi`, `glGetError`, `glGetIntegerv`, `glGetBooleanv`, `glViewport`, `glScissor`, `glEnable`, `glDisable`, `glClearColor`, `glClearDepth`, `glClearStencil`, `glColorMask`, `glDepthMask`, `glClear`, `glReadBuffer`, `glReadPixels`, `glDrawArrays`, `glDrawElements`, `glDrawRangeElements`, `glFlush`, and `glFinish`
- the texture-object path now includes `glActiveTexture`, `glBindTexture`, `glGenTextures`, `glDeleteTextures`, `glTexParameterf`, `glTexParameteri`, `glTexImage2D`, `glTexSubImage2D`, `glTexStorage2D`, `glGenerateMipmap`, `glGetTexParameteriv`, `glGetTexLevelParameteriv`, `glGetTexImage`, and `glPixelStorei`
- the buffer-object path now includes `glGenBuffers`, `glCreateBuffers`, `glBindBuffer`, `glBindBufferBase`, `glBindBufferRange`, `glBufferData`, `glBufferSubData`, `glBufferStorage`, `glMapBuffer`, `glMapBufferRange`, `glUnmapBuffer`, `glFlushMappedBufferRange`, `glGetBufferParameteriv`, `glGetBufferParameteri64v`, `glGetBufferPointerv`, `glGetBufferSubData`, `glCopyBufferSubData`, `glClearBufferData`, `glClearBufferSubData`, plus the first DSA buffer equivalents: `glNamedBufferStorage`, `glNamedBufferData`, `glNamedBufferSubData`, `glCopyNamedBufferSubData`, `glClearNamedBufferData`, `glClearNamedBufferSubData`, `glMapNamedBuffer`, `glMapNamedBufferRange`, `glUnmapNamedBuffer`, `glFlushMappedNamedBufferRange`, `glGetNamedBufferParameteriv`, `glGetNamedBufferParameteri64v`, `glGetNamedBufferPointerv`, and `glGetNamedBufferSubData`
- broader generic buffer-target state is now present for pixel pack/unpack, uniform, transform-feedback, atomic-counter, shader-storage, draw-indirect, and dispatch-indirect bindings, with indexed `glGetIntegeri_v` and `glGetInteger64i_v` coverage for the current indexed buffer families
- element-array state now flows through the backend with proper `GL_ELEMENT_ARRAY_BUFFER_BINDING` reporting, so indexed draw calls use VAO-owned EBO state instead of only non-indexed vertex pulls
- texture-unit state, immutable/mutable 2D texture storage, sampler uniform routing, generated mipmap chains, row-aligned texture upload/readback, and a minimal textured-triangle raster path now flow through the backend
- offscreen memory and framework-owned pbuffers now bind through the backend storage path, so clear/readback tests exercise real pixel data instead of only metadata bookkeeping
- `CGLTexImagePBuffer` and `AO46TexImagePBuffer` now have a real backend import lane for the currently attached pbuffer image when a compatible texture is bound
- when a standard Khronos OpenGL token or function name already exists, the code now prefers that Khronos spelling directly; `AO46*` names are reserved for private driver plumbing
- the current `libgl2mtl.dylib` backend implementation is still a minimal internal scaffold; deeper Metal command translation, shader/pipeline work, synchronization, and resource execution are still TODO

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
