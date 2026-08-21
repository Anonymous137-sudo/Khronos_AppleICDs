# Khronos_AppleICDs

`Khronos_AppleICDs` is a third-party work-in-progress OpenGL driver project
for macOS. It has two intentionally separate OpenGL frontend products.

- **Legacy macOS compatibility:** `OpenGL.framework`,
  `OpenGL_4.6.framework`, CGL, and NSOpenGL remain an optional compatibility
  path for applications that explicitly require Apple-style interfaces.
- **Modern Khronos ABI:** Mesa-produced `libGL.dylib` and `libEGL.dylib` are
  the user-space frontend for portable OpenGL applications. This path does not
  load the framework, CGL, NSOpenGL, `libAO46Core.dylib`, or `libGLICD.dylib`.

Both frontend products target the same lower AO46 Metal Gallium backend without
sharing frontend objects or installation names.

The active direction reuses Mesa's OpenGL core, state tracker, GLSL, SPIR-V,
NIR, and NIR-to-MSL compiler machinery. `AO46MTLGallium` is the single
Mesa-facing Gallium driver, while `AO46AGXMetalAdapter` owns the lower Metal
execution boundary: device/queue, resources, pipelines, fences, and drawables.
AO46 owns the legacy framework ABI, CGL/NSOpenGL and its compatibility
libraries, plus the Metal Gallium backend used by Mesa's standard ABI build.

AO46 does not hand-write a second OpenGL semantic engine or a separate
GLSL-to-Metal compiler. The prior `GL2MTL/mtl_driver.m` implementation is the
audited migration baseline for `AO46MTLGallium`, not a fallback backend. The
historical direct AGX/UABI work is retained as research, including its raw
evidence; it informs profile policy and diagnostics but is not an active
runtime submission path or a conformance claim. See [the active Mesa Metal backend
plan](docs/AO46MetalBackendPlan.md).

## Repository Layout

- `OpenGL_4.6(Core Profile)/Apple_ICD`
  Main source tree for the legacy framework compatibility product, the shared
  Mesa Metal backend, the standard Khronos/Mesa frontend contract, test
  coverage, and packaging scripts.
- `Vulkan_API_SDK_1.4.354`
  A separate Mesa KosmicKrisp Vulkan ICD source root, named for its verified
  Mesa Vulkan-Headers/registry revision. It uses the standard Khronos
  loader/ICD ABI rather than a macOS framework or custom AppKit ABI, and has a
  source-bootstrap `VulkanICD_KHRInstaller.pkg` for `/usr/local` deployment.
- `docs/INSTALLATION.md`
  Live-install notes for developer machines, installer behavior, target paths, and update flow.
- `docs/AO46MetalBackendPlan.md`
  Governing Mesa-to-Metal backend plan, ownership boundary, and CTS delivery
  order.
- `docs/WORKFLOW_PLAN.md`
  Active workflow, implementation rules, CTS milestones, and archived direct
  AGX research dashboard.
- `docs/research/evidence/`
  Checksummed direct-AGX research evidence, trace logs, Ghidra reports, and
  project-owned analysis metadata.
- `dist/`
  Locally built `OpenGLKHR_ICD_Installer.pkg` and
  `VulkanICD_KHRInstaller.pkg` outputs.

## Frontend Builds

Build the **legacy framework compatibility** product with:

```bash
cmake -S "OpenGL_4.6(Core Profile)/Apple_ICD" -B "OpenGL_4.6(Core Profile)/Apple_ICD/artifacts/build"
cmake --build "OpenGL_4.6(Core Profile)/Apple_ICD/artifacts/build"
ctest --test-dir "OpenGL_4.6(Core Profile)/Apple_ICD/artifacts/build" --output-on-failure
```

Repo-local browsable artifacts are written under:

```text
OpenGL_4.6(Core Profile)/Apple_ICD/artifacts/build
OpenGL_4.6(Core Profile)/Apple_ICD/artifacts/stage
```

The standard Khronos product is built through Mesa's registered `ao46mtl`
Gallium target and its built-in EGL pbuffer/Cocoa-window driver. `libGL.dylib`
and `libEGL.dylib` are aliases to one Mesa `libEGL.1.dylib` image, so they
share the same `glapi` dispatch state. Standard `EGL_WINDOW_BIT` surfaces use a
public `CAMetalLayer`, `NSView`, or `NSWindow`, while the backend performs the
Metal copy/present and resize/loss lifecycle without linking CGL or NSOpenGL.
The build contract is documented in
[`khronos/README.md`](<OpenGL_4.6(Core Profile)/Apple_ICD/khronos/README.md>).
The installer will not substitute CGL, Mesa's Apple GLX bridge, or a software
renderer to make this path appear complete.

Passing the current smoke suite validates a real standard-EGL pbuffer context,
Mesa state-tracker clear/readback, and teardown through the shared Metal
Gallium backend. The opt-in window smoke validates the same EGL context path
through a public Cocoa drawable when a live WindowServer session is available.
The practical capability level is still OpenGL 3.3 core, not OpenGL 4.6 or CTS
conformance.

## Vulkan ICD

`Vulkan_API_SDK_1.4.354` is a separate standard Vulkan ICD product. It builds
Mesa's KosmicKrisp driver against the checked-in Vulkan-Headers/registry
revision 1.4.354 and exposes it through the Khronos loader's ordinary `vk*` /
JSON-ICD contract. It does not provide a `.framework`, `CVK`,
`NSVulkan_KHR`, custom loader, or private AGX submission path.

The current engineering release is
`vulkan-api-sdk-1.4.354-cts-qualified-1.4.3.2-20260821`. It provides the full
local 2,858,036-case `dEQP-VK` inventory ledger in staged release evidence. Its
final 881,906-case wave completed with 257,266 passes, 624,638 correctly
feature-gated `NotSupported` results, zero failures, and two retained
early-fragment `QualityWarning` results. Raw QPAs, worker output, the runtime
binary, manifest, and installer are published as GitHub release assets; the
source record is [Vulkan API SDK 1.4.354/RELEASES](Vulkan_API_SDK_1.4.354/RELEASES/).

This is an engineering qualification release, not a Khronos certification.
The ICD retains `VkConformanceVersion = { 0, 0, 0, 0 }`; `1.4.3.2` identifies
the CTS suite revision in the release label, never an official conformance
version. The semantic corrections that made capability reporting and Metal
lowering match the tested behavior are documented in the release record.

The temporary AO46 implementation freeze is now lifted. Vulkan's standard ICD
release remains independent while AO46 resumes Metal Gallium completion and
OpenGL CTS work.

Build the package with:

```bash
./build_VulkanICD_KHRInstaller.sh
```

It creates `dist/VulkanICD_KHRInstaller.pkg`. Installation builds source and
stages only project-owned standard ABI files under `/usr/local`, including the
KosmicKrisp ICD dylib, ICD JSON manifest, and build/update commands. It does
not replace Apple system files and does not require SIP/AuthRoot to be disabled.

## Installer

Build the GitHub-bootstrap installer package with:

```bash
./build_OpenGLKHR_ICD_Installer.sh
```

The generated package is written to:

```text
dist/OpenGLKHR_ICD_Installer.pkg
```

The installer clones or updates this repository into:

```text
/usr/local/src/Khronos_AppleICDs
```

The installer is a developer-only WIP mechanism. Do not treat a successful
install as proof of system-wide application compatibility or OpenGL 4.6
conformance; staged CTS is an explicit project milestone.

The default `khronos` installation mode installs only the standard ABI under
`/usr/local` and never replaces Apple system files:

```text
/usr/local/lib/libGL.dylib
/usr/local/lib/libEGL.dylib
/usr/local/lib/libEGL.1.dylib
/usr/local/lib/openglkhr/
/usr/local/include/{GL,EGL,KHR}
```

This mode does not query SIP or Authenticated Root. The optional
`legacy-system` mode replaces the framework compatibility paths below and is
the only mode protected by the developer-machine gate:

```text
/System/Library/Frameworks/OpenGL.framework
/System/Library/Frameworks/OpenGL_4.6.framework
/usr/local/lib/libAO46LegacyGL.dylib
```

For rebuilds after install:

```bash
/usr/local/bin/openglkhr-icd-build
```

For pulling newer commits and reinstalling:

```bash
/usr/local/bin/openglkhr-icd-update
```

To choose the protected legacy compatibility install explicitly:

```bash
OPENGLKHR_INSTALL_MODE=legacy-system /usr/local/bin/openglkhr-icd-build
```
