# Installation

`Khronos_AppleICDs` ships a bootstrap installer that pulls the repository and
builds one of two deliberately separate OpenGL frontend products.

This is a developer-only WIP installer. The active project direction is the
Mesa-to-Metal backend described in
[`AO46MetalBackendPlan.md`](AO46MetalBackendPlan.md); current builds do not
establish system-wide OpenGL 4.6 compatibility or Khronos CTS conformance.
The direct AGX/UABI investigation is preserved research, not the runtime path
installed by this workflow.

## Standard Khronos Mode

`khronos` is the default mode. It installs Mesa-produced standard ABI libraries
and standard Khronos headers below a user-space prefix, defaulting to
`/usr/local`:

```text
/usr/local/lib/libGL.dylib
/usr/local/lib/libEGL.dylib
/usr/local/lib/libEGL.1.dylib
/usr/local/lib/openglkhr/libAO46MesaMetalBackend.dylib
/usr/local/lib/openglkhr/libAO46MTLGallium.dylib
/usr/local/lib/openglkhr/libAO46AGXMetalAdapter.dylib
/usr/local/include/GL
/usr/local/include/EGL
/usr/local/include/KHR
/usr/local/bin/glxinfo
```

This product uses Mesa's `libEGL.1.dylib` implementation; `libEGL.dylib` and
`libGL.dylib` are aliases to that one Mach-O image and therefore share one
Mesa `glapi` dispatch host. It does not load
`OpenGL_4.6.framework`, CGL, NSOpenGL, `libAO46Core.dylib`, or `libGLICD.dylib`.
Because it makes no system-framework replacement, it does **not** query or
require SIP/AuthRoot state.

The Mesa-side AO46 Gallium registration, built-in EGL pbuffer/Cocoa-window
driver, and non-GLX `libGL` alias are implemented. The default installer builds
and stages that path rather than silently replacing it with CGL, Mesa's Apple
GLX bridge, or a software renderer. Standard EGL window surfaces accept public
`CAMetalLayer`, `NSView`, or `NSWindow` handles, retain resources until the
Metal presentation copy completes, and rebuild after a drawable size/loss
transition. The current capability remains the audited OpenGL 3.3-core subset;
this is not a GL 4.x claim or CTS conformance.

The installer also builds upstream Mesa Demos `glxinfo` when X11/GLX development
packages are available. `glxinfo` is an X11/GLX terminal diagnostic, not an EGL
conformance check: it requires an X11 GL provider such as XQuartz or MacPorts
and a running X server, then reports the GLX stack it opens. It remains separate
from the AO46 Khronos EGL path.

To install the diagnostic independently, without rebuilding the standard ABI:

```bash
"OpenGL_4.6(Core Profile)/Apple_ICD/scripts/install_glxinfo_macos.sh"
```

## Vulkan ICD Mode

Vulkan is a separate standard Khronos ICD product, not a framework or an
Apple-specific ABI. `VulkanICD_KHRInstaller.pkg` builds Mesa's KosmicKrisp
driver from the repository checkout and installs only project-owned paths:

```text
/usr/local/lib/avk143/libvulkan_kosmickrisp.dylib
/usr/local/share/vulkan/icd.d/avk143_kosmickrisp_icd.aarch64.json
/usr/local/bin/vulkanicd-khr-build
/usr/local/bin/vulkanicd-khr-update
```

Build the package from the repository root:

```bash
./build_VulkanICD_KHRInstaller.sh
```

The package uses the standard loader JSON discovery mechanism. Applications
continue to call the normal `vk*` ABI through their Khronos Vulkan Loader; the
installer does not ship a custom loader, install a `.framework`, or replace
Metal/Apple system files. It therefore does **not** query or require
SIP/AuthRoot state.

After the package completes, rebuild the checked-out source with:

```bash
/usr/local/bin/vulkanicd-khr-build
```

Fast-forward the repository and its source submodules before rebuilding with:

```bash
/usr/local/bin/vulkanicd-khr-update
```

The active package is named for the verified Mesa Vulkan-Headers/registry
revision 1.4.354. The staged ICD has passed an initial Vulkan CTS 1.4.3.2 slice
(six compute cases and an offscreen triangle). The first info sweep still has
two extension-enumeration failures for `VK_KHR_surface_maintenance1` and
`VK_KHR_maintenance9`, so this remains a development package and is not a
Vulkan CTS conformance claim.

## Legacy Framework Mode

`legacy-system` is an opt-in compatibility product for applications that
require Apple's framework/CGL/NSOpenGL model. It installs:

```text
/System/Library/Frameworks/OpenGL.framework
/System/Library/Frameworks/OpenGL_4.6.framework
/usr/local/lib/libAO46LegacyGL.dylib
/usr/local/lib/libGLContext.dylib
/usr/local/lib/libGLICD.dylib
/usr/local/lib/libNSOpenGLContext.dylib
```

This mode is separate from the standard ABI product and must be selected
explicitly:

```bash
OPENGLKHR_INSTALL_MODE=legacy-system /usr/local/bin/openglkhr-icd-build
```

## Repository Location

The cloned working repository is stored at:

```text
/usr/local/src/Khronos_AppleICDs
```

## Safety Gate For Legacy Mode

Only `legacy-system` checks:

- `csrutil status`
- `csrutil authenticated-root status`

The install proceeds only when those protections are disabled, or when Authenticated Root is not supported by that macOS release.

Passing this gate only allows a local experiment. It is not an endorsement of
the install as stable, complete, or safe for daily application workloads.

When the legacy machine passes the gate, the installer prints:

```text
device identified as a developer mac
warning: the driver is currently Indev/WIP and may cause uncertain behaviour
install at your own responsibility to maintain system stability
```

## Build And Install Flow

Build the bootstrap package:

```bash
./build_OpenGLKHR_ICD_Installer.sh
```

Install the standard Khronos ABI from the cloned repository:

```bash
/usr/local/bin/openglkhr-icd-build
```

Pull the latest commit, rebuild, and reinstall:

```bash
/usr/local/bin/openglkhr-icd-update
```

## Local Verification

For repo-local builds and tests:

```bash
cmake -S "OpenGL_4.6(Core Profile)/Apple_ICD" -B "OpenGL_4.6(Core Profile)/Apple_ICD/artifacts/build"
cmake --build "OpenGL_4.6(Core Profile)/Apple_ICD/artifacts/build"
ctest --test-dir "OpenGL_4.6(Core Profile)/Apple_ICD/artifacts/build" --output-on-failure
```
