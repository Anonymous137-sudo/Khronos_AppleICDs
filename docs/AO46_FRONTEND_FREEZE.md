# AO46 Standard ABI Resume Record

**Status:** the temporary freeze ended on 2026-08-21 after the AVK143 Vulkan
engineering release. AO46 Metal Gallium, adapter, framework, and standard ABI
work may resume from this recorded boundary.

## Completed Modern Frontend

- Mesa registers `ao46mtl` as a Gallium driver. Its screen factory calls the
  CGL-free `AO46MesaMetalBackendCreateScreen` entry point.
- Mesa's built-in `ao46mtl` EGL driver creates OpenGL desktop contexts on the
  surfaceless platform and supports both `EGL_PBUFFER_BIT` and
  `EGL_WINDOW_BIT` drawables.
- Mesa builds one Mach-O image, `libEGL.1.dylib`; `libEGL.dylib` and
  `libGL.dylib` are aliases to it. Consequently EGL and GL use one Mesa
  `glapi` dispatch/TLS host rather than two duplicate dispatch implementations.
- The driver, GL library, and EGL library do not load AO46's legacy framework,
  CGL, NSOpenGL, `libAO46Core.dylib`, or `libGLICD.dylib`.
- Staging rewrites Mesa's temporary build-prefix install name to an rpath
  identity. Installation then writes the selected user prefix into the final
  dylib identity, so the product does not retain `/private/tmp` build paths.
- `ao46mtl-egl-pbuffer-smoke` creates a standard EGL 3.3-core pbuffer context,
  obtains GL entry points through `libGL.dylib`, clears through Mesa's state
  tracker, reads back Metal-produced pixels, swaps, and tears down cleanly.
- `ao46mtl-egl-window-smoke` is a compositor-hosted standard EGL test. It
  creates a public `NSWindow`/`CAMetalLayer`, renders through the Mesa context,
  and presents through `eglSwapBuffers`. It intentionally exits `77` if the
  current process has no WindowServer drawable.
- The CGL-free backend owns public `CAMetalLayer` acquisition, sRGB
  `RGBA8`/`BGRA8` target refresh after size/backing-scale changes, swap interval
  `0`/`1`, drawable-loss recovery, and completion-based retention of the Mesa
  source texture while the presentation copy is in flight.

## Explicit Boundary

The modern product supports surfaceless pbuffers plus public Cocoa
window surfaces. `eglCreateWindowSurface` accepts a platform-native public
`CAMetalLayer`, `NSView`, or `NSWindow`; it does not provide Wayland or X11
surfaces. Its honest current capability ceiling remains the already audited
OpenGL 3.3 core subset. It is not a GL 4.x advertisement and has not run
Khronos CTS.

The legacy framework/CGL/NSOpenGL product remains a separate compatibility
path. It may share lower AO46 Metal libraries, but its objects, loader names,
and protected-system installer path are not dependencies of the standard
Khronos ABI.

## Resume Rule

The AVK143 release has explicitly returned the project to the AO46 phase. The
next modern-frontend items are expanded Gallium capabilities and staged CTS.
They must not reopen the completed standard ABI boundary or add a CGL/GLX
fallback. Legacy framework/CGL/NSOpenGL compatibility remains a separate
product and must not be mixed into the standard EGL/OpenGL execution path.
