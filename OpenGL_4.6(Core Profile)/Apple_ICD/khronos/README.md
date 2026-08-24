# Standard Khronos GL and EGL Frontend

This directory owns the modern, user-space AO46 frontend policy.

It does not implement `egl*`, `gl*`, CGL, NSOpenGL, pixel-format, or framework
entry points.  Mesa owns the Khronos ABI and OpenGL semantics through its
upstream `libEGL` and `libGL` build products.  AO46 contributes a separate
`libAO46MesaMetalBackend.dylib` containing the Metal Gallium screen factory and
its direct dependencies.

## Runtime boundary

```text
Modern Khronos application
  -> Mesa libEGL.dylib / libGL.dylib
  -> Mesa EGL + OpenGL state tracker
  -> AO46 Mesa Gallium driver registration
  -> libAO46MesaMetalBackend.dylib
  -> libAO46MTLGallium.dylib + libAO46AGXMetalAdapter.dylib
  -> Metal
```

The legacy product is intentionally outside this graph:

```text
Legacy macOS application
  -> OpenGL_4.6.framework
  -> CGL / NSOpenGL compatibility runtime
  -> libAO46Core.dylib
  -> libAO46MesaMetalBackend.dylib
```

The two products can share the Metal/Gallium backend, but neither modern
`libGL` nor modern `libEGL` may link against `libAO46Core.dylib`, `libGLICD`,
or `OpenGL_4.6.framework`.

## Completed Build Contract

`scripts/build_mesa_khronos_frontend.sh` builds Mesa's standard ABI artifacts
with the in-tree `ao46mtl` Gallium target and built-in EGL driver. It
deliberately refuses CGL, the framework, Apple's Darwin GLX implementation, or
a software driver for this product.

The completed integration is one coherent path:

- `ao46mtl` creates its screen through `AO46MesaMetalBackendCreateScreen`;
- a Mesa built-in EGL driver supplies `EGL_PLATFORM_SURFACELESS_MESA` desktop
  OpenGL contexts with both `EGL_PBUFFER_BIT` and `EGL_WINDOW_BIT` surfaces;
- `libEGL.1.dylib` carries both EGL and GL entry points; and
- `libEGL.dylib` and `libGL.dylib` are aliases to that one image, preserving
  one shared Mesa `glapi` dispatch/TLS host.

The pbuffer smoke creates a standard EGL 3.3-core context, calls `gl*` through
the `libGL.dylib` alias, verifies hardware readback, then tears down all EGL
objects. The built `ao46mtl-egl-window-smoke` is an opt-in compositor test: it
creates a public `NSWindow`/`CAMetalLayer`, renders through the same Mesa EGL
context, and presents with `eglSwapBuffers`. It exits `77` when the process has
no WindowServer drawable, so it is not registered as a headless test.

`eglCreateWindowSurface` accepts a public `CAMetalLayer`, `NSView`, or
`NSWindow` as its platform-native `EGLNativeWindowType`. AO46 owns the retained
layer, resize and backing-scale refresh, swap interval `0`/`1`, drawable loss,
and completion-based source-resource retirement. The current presentation scope
is sRGB `RGBA8`/`BGRA8`; it does not provide Wayland or X11 surfaces. The
frontend boundary is complete, while the active backend currently exposes the
Mesa-selected OpenGL 4.1 ceiling. That measured version is not a Khronos CTS
conformance claim.

From a live desktop session, run the visible smoke after a Mesa build with:

```sh
DYLD_LIBRARY_PATH="<mesa-build>/src/egl:<ao46-backend-build>" \
  "<mesa-build>/src/egl/ao46mtl-egl-window-smoke"
```

The completed supporting boundary remains useful: the CGL-free
`libAO46MesaMetalBackend.dylib` export is the only AO46 entry point a future
Mesa target needs. It must not pull legacy framework, CGL, NSOpenGL,
`libAO46Core.dylib`, or `libGLICD.dylib` into the modern path.

## Terminal diagnostics

`scripts/build_glxinfo_macos.sh` fetches a pinned upstream Mesa Demos revision
and builds its `glxinfo` target on macOS. The standard source installer stages
it at `PREFIX/bin/glxinfo` alongside the Khronos ABI.

It can also be installed independently, without the AO46 Mesa-driver build:

```sh
./scripts/install_glxinfo_macos.sh
```

`glxinfo` is specifically an X11/GLX diagnostic. It needs an X11 GL provider
such as XQuartz or MacPorts and a running X server (`DISPLAY`), and reports the
GLX stack it opens. It does not create an EGL context and is not evidence that
the separate AO46 Mesa/EGL frontend is installed or selected.

The OpenGL source installer follows its build in
`/var/log/OpenGLKHR_ICD_Installer.log`. Run `openglkhr-icd-log` in another
Terminal window, or `openglkhr-icd-log --once` after the build. `glxinfo` is
enabled by default; on a machine without X11 development packages, use
`OPENGLKHR_BUILD_GLXINFO=0 openglkhr-icd-update` to install the core GL/EGL
stack without that optional diagnostic, then install XQuartz and run
`scripts/install_glxinfo_macos.sh` separately.

The source installer uses `/opt/X11` when its XQuartz `x11.pc` and `gl.pc`
files are present. The checked-in `XQuartz/` directory is source material for
the X server and is not rebuilt as part of the OpenGL installer. AO46's Mesa
and KosmicKrisp artifacts are produced by one unified Meson build before the
framework is configured, so the NIR archive and the KosmicKrisp NIR-to-MSL
compiler always come from the same Mesa configuration.
