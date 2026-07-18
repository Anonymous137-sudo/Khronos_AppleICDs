# OpenGL_4.6(Core Profile) / Apple_ICD

This is the Apple ICD source tree for the `OpenGL_4.6(Core Profile)` stack, a personal macOS OpenGL 4.6 replacement experiment.

The public/system driver layers are `OpenGL.framework`, `OpenGL_4.6.framework`, `libGLICD.dylib`, and `libgl2mtl.dylib`. MGL is now treated as a source of reusable implementation ideas and components, not as a runtime dependency or the public face of the stack.

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
  The Apple-path compatibility shim that is meant to live at `OpenGL.framework/Versions/A/OpenGL` and forward into `OpenGL_4.6.framework`.
- `drivers/`
  User-space bridge dylibs such as `libGL.dylib`, `libGLContext.dylib`, and `libNSOpenGLContext.dylib`.
- `scripts/`
  Helper scripts for assembling the personal on-disk layout.

## First Goal

The first milestone is not "full replacement". It is a clean skeleton with:

- an exact-path OpenGL framework shim target
- a real `OpenGL_4.6.framework` target
- a framework-owned backend boundary that talks directly to `libgl2mtl.dylib`
- initial `CGL*` compatibility entrypoints
- initial `gl*` forwarding entrypoints

## Current Shape

Right now this subproject is a scaffold:

- runtime bootstrap is implemented
- framework/client layering is implemented
- the framework runtime no longer `dlopen`s `libmgl.dylib`; it links directly against the internal `libgl2mtl.dylib` backend instead
- `libgl2mtl.dylib` now owns a project-local `GLDriverCore` context/state layer derived from MGL defaults, so the backend no longer includes MGL's private `glm_context.h` directly
- `libgl2mtl.dylib` now defines the internal AO46 backend API used by the framework for context lifetime, drawable binding, swap/present, and GL proc lookup
- `libGLICD.dylib` now sits between the framework client and the public `libGL*`/`CGL*` shims
- a small `CGL*` layer is implemented
- drawable attachment is framework-owned, with `libGLContext.dylib` helper entrypoints for headless or native-window binding
- drawable detach/rebind is now explicit, and `CGLClearDrawable` is no longer a stub
- `CGLSetParameter`, `CGLGetParameter`, and `CGLGetProcAddress` are now present for early-loader compatibility
- `CGLGetShareGroup` is now exported, and shared context creation now preserves a real AO46 share-group identity instead of rejecting the share argument outright
- `CGLEnable`, `CGLDisable`, `CGLIsEnabled`, `CGLSetVirtualScreen`, `CGLGetVirtualScreen`, `CGLSetGlobalOption`, `CGLGetGlobalOption`, `CGLSetOption`, `CGLGetOption`, `CGLLockContext`, and `CGLUnlockContext` are now implemented through the framework/ICD/shim pipeline
- `CGLQueryRendererInfo`, `CGLDestroyRendererInfo`, and `CGLDescribeRenderer` now expose a synthetic AO46 renderer to old CGL callers
- synthetic renderer reporting now includes concrete multisample capability limits instead of only boolean accelerated/non-accelerated answers
- pixel format selection now accepts both `3.2 core` and `4.x core` style requests instead of hard-rejecting `3.2 core` apps
- the runtime now also accepts `kCGLOGLPVersion_GL4_6_Core` for callers that want to request the modern profile explicitly
- `CGLCopyContext`, `CGLCreatePBuffer`, `CGLDestroyPBuffer`, `CGLDescribePBuffer`, `CGLTexImagePBuffer`, `CGLRetainPBuffer`, `CGLGetPBufferRetainCount`, `CGLSetOffScreen`, `CGLGetOffScreen`, `CGLSetFullScreen`, `CGLSetFullScreenOnDisplay`, `CGLSetPBuffer`, and `CGLGetPBuffer` are now routed through framework-owned legacy drawable state
- `CGLChoosePixelFormat` and `CGLDescribePixelFormat` now cover a much broader compatibility set, including alpha/sample/pbuffer/offscreen/window/display-mask and related startup probe attributes
- `libNSOpenGLContext.dylib` now provides the first user-space `NSOpenGL*` bridge layer: real `NSOpenGLSetOption`/`GetOption`/`GetVersion` symbols and AO46-prefixed Cocoa-style pixel-format/context/pbuffer wrappers that ride on the CGL path
- the AO46 `NSOpenGL` wrapper layer now also carries AppKit-facing drawable semantics such as `view` binding, `setView:`, and `createTexture:fromView:internalFormat:` on top of the existing framework/ICD path
- `AO46NSOpenGLPixelFormat` now also supports Apple-style `NSData` reconstruction and keyed archiving, so older Cocoa code that persists pixel-format selections has a compatible bridge path
- `OpenGL_4.6.framework` now carries public `Headers/` and a `Modules/` definition instead of only the binary and `Info.plist`
- `gl*` entrypoints and the backend proc table are generated from `MGL/src/gl_core.c`, but the runtime no longer forwards into an external `libmgl.dylib`
- `libgl2mtl.dylib` now implements the first actual GL-visible backend behavior through the standard Khronos entrypoints: `glGetString`, `glGetStringi`, `glGetError`, `glGetIntegerv`, `glGetBooleanv`, `glViewport`, `glScissor`, `glEnable`, `glDisable`, `glClearColor`, `glClearDepth`, `glClearStencil`, `glColorMask`, `glDepthMask`, `glClear`, `glReadBuffer`, `glReadPixels`, `glDrawArrays`, `glDrawElements`, `glDrawRangeElements`, `glFlush`, `glFinish`, and the first texture-object path through `glActiveTexture`, `glBindTexture`, `glGenTextures`, `glDeleteTextures`, `glTexParameteri`, `glTexImage2D`, `glGetTexLevelParameteriv`, and `glGetTexImage`
- element-array state now flows through the backend with proper `GL_ELEMENT_ARRAY_BUFFER_BINDING` reporting, so indexed draw calls use VAO-owned EBO state instead of only non-indexed vertex pulls
- texture-unit state, 2D texture storage, sampler uniform routing, and a minimal textured-triangle raster path now flow through the backend, so the framework can exercise real GL object upload/bind/sample semantics instead of only flat vertex-color draws
- offscreen memory and framework-owned pbuffers now bind through the backend storage path, so clear/readback tests exercise real pixel data instead of only metadata bookkeeping
- `CGLTexImagePBuffer` / `AO46TexImagePBuffer` now have a real backend import lane when a 2D texture is bound, while older compatibility probes still tolerate the pre-existing no-op case instead of hard-failing
- when a standard Khronos OpenGL token or function name already exists, the code now prefers that Khronos spelling directly; `AO46*` names are reserved for private driver plumbing
- the build no longer requires glslang headers just to compile the current Apple_ICD driver skeleton; only the OpenGL registry headers from the repo are needed at this stage
- the full symbol surface is still TODO
- the current `libgl2mtl.dylib` backend implementation is still a minimal internal scaffold; deeper Metal command translation, shader/pipeline work, and resource execution are still TODO
- share-group identity is now tracked and exposed, but backend-level shared GL object/resource semantics are still TODO
- full AppKit-owned `NSOpenGLContext` class replacement is still TODO

## Build

```bash
cmake -S "OpenGL_4.6(Core Profile)/Apple_ICD" -B build-opengl46-core
cmake --build build-opengl46-core
```

## Personal Layout Staging

The staging script assembles the layout we want to test on a personal machine:

```bash
"OpenGL_4.6(Core Profile)/Apple_ICD/scripts/stage_personal_layout.sh" build-opengl46-core /tmp/opengl46-core-stage
```

That creates:

- `System/Library/Frameworks/OpenGL.framework/...`
- `System/Library/Frameworks/OpenGL_4.6.framework/...`
- `usr/local/lib/libGL.dylib`
- `usr/local/lib/libGLICD.dylib`
- `usr/local/lib/libGLContext.dylib`
- `usr/local/lib/libgl2mtl.dylib`
- `usr/local/lib/libNSOpenGLContext.dylib`

inside the chosen staging root.

## Repo-Local Artifacts

If you want a browsable build inside the source tree instead of only under `/tmp`, use:

```bash
"OpenGL_4.6(Core Profile)/Apple_ICD/scripts/build_local_artifacts.sh"
```

That creates:

- `OpenGL_4.6(Core Profile)/Apple_ICD/artifacts/build`
- `OpenGL_4.6(Core Profile)/Apple_ICD/artifacts/stage`

## GitHub Installer

The `OpenGLKHR_ICD_Installer.pkg` flow is now designed as a GitHub-backed bootstrap installer rather than a source-bundle package.

Its intended shape is:

- the package installs small bootstrap scripts and repository metadata only
- `postinstall` clones or updates the `Khronos_AppleICDs` repository into `/usr/local/src/Khronos_AppleICDs`
- the cloned `OpenGL_4.6(Core Profile)/Apple_ICD` source is built locally on the machine
- the live install then copies into:
  - `/System/Library/Frameworks/OpenGL.framework`
  - `/System/Library/Frameworks/OpenGL_4.6.framework`
  - `/usr/local/lib`

The repo-level helper commands are meant to be:

- `/usr/local/bin/openglkhr-icd-build`
  Rebuild and reinstall the currently cloned source tree.
- `/usr/local/bin/openglkhr-icd-update`
  Pull the latest commit from the GitHub repository, rebuild, and reinstall.

## `libGLContext` Helpers

The convenience `libGLContext.dylib` layer now provides helper entrypoints for apps, games, and mods that want to bind a context explicitly:

- `AO46LibGLContextCreateHeadless`
- `AO46LibGLContextCreateForWindow`
- `AO46LibGLContextAttachHeadless`
- `AO46LibGLContextAttachWindow`
- `AO46LibGLContextClearDrawable`

`libNSOpenGLContext.dylib` now sits one layer higher for callers that want `NSOpenGL`-style object wrappers without touching AppKit's deprecated implementation directly.

## Framework Bundle Shape

The built `OpenGL_4.6.framework` now includes:

- `Headers/OpenGL_4_6.h`
- `Headers/AppleOpenGL46Runtime.h`
- `Headers/glcorearb.h`
- `Modules/module.modulemap`

so the bundle looks and behaves more like a real framework instead of just a binary wrapper.

## Smoke Coverage

This tree now also includes a smoke harness for driver-boundary checks:

- `tests/AO46RuntimeCompatSmoke.c`
  A runtime compatibility probe that exercises renderer enumeration, deeper renderer sample capability reporting, broader pixel-format negotiation/description coverage, the `kCGLOGLPVersion_GL4_6_Core` profile token, share-group identity for shared contexts, pbuffers, offscreen/fullscreen compatibility entrypoints, global options, context creation, enable state, virtual screens, drawable attach/clear, flush/update, locking, compatibility-state copy, the first real GL backend path through `glGetString`, `glGetIntegerv`, `glClear`, `glScissor`, `glReadPixels`, `glDrawArrays`, `glDrawElements`, and `glGetError`, and the first texture-object lane through upload, query, textured sampling, and pbuffer-to-texture import.
- `tests/AO46CGLShimCompatSmoke.c`
  A shim-level probe that drives the Apple-path `CGL*` surface directly and verifies `CGLGetShareGroup`, shared-context creation, and current-context round-trips.
- `tests/AO46NSOpenGLCompatSmoke.m`
  A higher-level smoke probe for the new `libNSOpenGLContext.dylib` bridge, covering `NSOpenGL` global options/version reporting, AO46-prefixed pixel-format/context/pbuffer wrappers, pixel-format `NSData` and archive round-trips, AppKit-style view binding, and drawable switching between views and pbuffers.

Run it with:

```bash
ctest --test-dir "OpenGL_4.6(Core Profile)/Apple_ICD/artifacts/build" --output-on-failure
```
