# Khronos_AppleICDs

`Khronos_AppleICDs` is a macOS graphics-driver integration project built around
existing Mesa and KosmicKrisp machinery. It contains two independent products:

- **Vulkan:** a standard Khronos-loader ICD assembled from Mesa KosmicKrisp and
  public Metal for Apple Silicon macOS.
- **OpenGL:** the resumed AO46 workstream, with a standard Mesa EGL/OpenGL ABI
  path plus a separate, optional Apple-style framework compatibility path.

The products share research and build infrastructure, but they do not share
application-facing ABIs, loaders, or installation names.

## Current Status

| Product | Current state | Important boundary |
| --- | --- | --- |
| **Vulkan API SDK 1.4.354** | Published engineering release, qualified with `vulkan-cts-1.4.3.2` evidence. | Not Khronos certified; `VkConformanceVersion` is `{ 0, 0, 0, 0 }`. |
| **AO46 standard OpenGL/EGL** | Active Mesa Metal Gallium development, with verified standard EGL/OpenGL 3.3-core smoke coverage. | Not an OpenGL 4.6 or CTS-conformance claim. |
| **AO46 legacy framework path** | Experimental compatibility product for software requiring CGL/NSOpenGL/framework-style interfaces. | Separate from the standard EGL/OpenGL ABI and developer-machine only. |

## Vulkan Release

The current release is [Vulkan API SDK 1.4.354 - CTS-qualified 1.4.3.2
(engineering)](https://github.com/Anonymous137-sudo/Khronos_AppleICDs/releases/tag/vulkan-api-sdk-1.4.354-cts-qualified-1.4.3.2-20260821).

It provides a standard Vulkan ICD route:

```text
Vulkan application
  -> Khronos Vulkan Loader and vk* ABI
  -> Mesa KosmicKrisp ICD
  -> Mesa Vulkan runtime, VTN, NIR, and Metal execution
  -> Apple GPU driver
```

The published evidence includes the staged macOS arm64 runtime, ICD JSON
manifest, source-bootstrap installer, raw final-wave QPAs, case list, worker
output, exit codes, semantic-delta record, and SHA-256 checksums.

The final 881,906-case CTS wave recorded:

| Outcome | Count |
| --- | ---: |
| Pass | 257,266 |
| NotSupported | 624,638 |
| Fail | 0 |
| QualityWarning | 2 |

The two `QualityWarning` outcomes are retained as warnings in the raw QPAs and
documented in the release record. They are not relabeled as passes. The
release label's `1.4.3.2` component identifies the CTS suite revision, not an
official Vulkan conformance version.

Read the [Vulkan release record](Vulkan_API_SDK_1.4.354/RELEASES/CTS_QUALIFIED_1.4.3.2_20260821.md),
[semantic delta](Vulkan_API_SDK_1.4.354/RELEASES/SEMANTIC_DELTA.md), and
[Vulkan build/ICD guide](Vulkan_API_SDK_1.4.354/Apple_ICD/README.md).

## AO46 OpenGL

AO46 uses Mesa as the OpenGL semantic engine. Mesa owns OpenGL state,
validation, GLSL, SPIR-V, NIR, and capability logic; AO46 provides macOS
integration and the Metal execution boundary.

```text
Modern OpenGL application
  -> Mesa libGL.dylib / libEGL.dylib
  -> Mesa OpenGL core and state tracker
  -> AO46MTLGallium
  -> AO46AGXMetalAdapter
  -> public Metal and Apple GPU driver
```

The modern path is CGL-free and uses the standard Khronos ABI. It supports
surfaceless/pbuffer contexts and public Cocoa window drawables through
`CAMetalLayer`, `NSView`, or `NSWindow`. Current hardware smoke coverage proves
EGL context creation, Mesa state-tracker rendering, Metal readback, swap, and
teardown at the audited **OpenGL 3.3 core** ceiling.

The legacy path remains distinct:

```text
Legacy macOS application
  -> OpenGL.framework / OpenGL_4.6.framework compatibility path
  -> CGL / NSOpenGL / AO46 compatibility libraries
  -> AO46 Metal Gallium backend
```

It exists only for applications that explicitly require Apple-style OpenGL
interfaces. It is not the runtime dependency of the standard EGL/OpenGL path.

AO46 work resumed after the Vulkan release. See the [active Mesa Metal backend
plan](docs/AO46MetalBackendPlan.md), [resume record](docs/AO46_FRONTEND_FREEZE.md),
and [workflow dashboard](docs/WORKFLOW_PLAN.md).

## Quick Start

### Vulkan ICD

Build the standard source-bootstrap installer:

```sh
./build_VulkanICD_KHRInstaller.sh
```

It produces `dist/VulkanICD-KHR-Installer.pkg`. The installer builds project
source and installs only project-owned standard ABI files under `/usr/local`.
It does not replace the Vulkan loader, Metal, a macOS framework, or Apple
system files; SIP/AuthRoot changes are not required.

For local source staging instead of installation:

```sh
"Vulkan_API_SDK_1.4.354/Apple_ICD/scripts/build-avk143-icd.sh"
export VK_DRIVER_FILES="$(pwd)/Vulkan_API_SDK_1.4.354/build/AVK143/prefix/share/vulkan/icd.d/kosmickrisp_mesa_icd.aarch64.json"
```

### AO46 Standard OpenGL/EGL

The standard Khronos frontend builds through Mesa's registered `ao46mtl`
Gallium target. Its detailed build and runtime contract is in
[the AO46 Khronos frontend guide](<OpenGL_4.6(Core Profile)/Apple_ICD/khronos/README.md>).

The compatibility-framework product is separate and intentionally opt-in:

```sh
./build_OpenGLKHR_ICD_Installer.sh
```

Use `legacy-system` only on a developer machine that intentionally accepts the
framework compatibility experiment. It is not necessary for Vulkan or the
standard EGL/OpenGL ABI.

## Repository Map

| Path | Purpose |
| --- | --- |
| `Vulkan_API_SDK_1.4.354/` | Standard Mesa KosmicKrisp Vulkan ICD, release records, installer, and CTS tooling. |
| `OpenGL_4.6(Core Profile)/Apple_ICD/` | AO46 framework compatibility code, Mesa Metal Gallium integration, standard EGL/OpenGL frontend, tests, and packaging. |
| `docs/` | Architecture, installation, workflow, research evidence, and project decisions. |
| `dEQP-VK-cases.xml` | Committed Vulkan CTS inventory catalog used by the release ledger. |
| `dist/` | Locally generated installer packages; release packages are attached to GitHub Releases. |

Mesa and MoltenVK are pinned as source submodules. Generated build trees,
shader caches, QPA logs, and other host-specific artifacts are deliberately
kept out of Git and published as checksummed release assets when relevant.

## What This Project Does Not Claim

- Vulkan conformance certification or a nonzero `VkConformanceVersion`.
- OpenGL 4.6 completeness, an OpenGL CTS result, or a general system-wide
  replacement for Apple's deprecated OpenGL implementation.
- A custom Vulkan loader, `CVK`, `NSVulkan_KHR`, or a Vulkan framework.
- A private Apple AGX submission path in the active runtime.

The historic direct-AGX/UABI investigation remains project research. It informs
diagnostics and performance analysis; it is not an active submission backend.

## Documentation

- [Vulkan API SDK 1.4.354](Vulkan_API_SDK_1.4.354/README.md)
- [Vulkan release evidence](Vulkan_API_SDK_1.4.354/RELEASES/README.md)
- [Installer and deployment guide](docs/INSTALLATION.md)
- [AO46 Metal backend plan](docs/AO46MetalBackendPlan.md)
- [Project workflow plan](docs/WORKFLOW_PLAN.md)
- [Mesa/Metal reuse inventory](docs/MesaMetalReuseInventory.md)
