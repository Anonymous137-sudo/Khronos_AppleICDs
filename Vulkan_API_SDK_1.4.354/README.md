# Vulkan API SDK 1.4.354

AVK143 assembles a standard Khronos Vulkan ICD for Apple Silicon macOS by
building Mesa's KosmicKrisp Vulkan driver and its public Metal implementation.

The active public contract is **Vulkan API 1.4**, built from Mesa's checked-in
Vulkan-Headers/registry revision **1.4.354**. Vulkan does not use an
OpenGL-style "Core Profile" designation, so the repository and installer
documentation use API and header revisions rather than profile terminology.

```text
Vulkan application
  -> Khronos Vulkan Loader and vk* ABI
  -> AVK143 KosmicKrisp ICD
  -> Mesa Vulkan runtime, VTN, NIR, and KosmicKrisp
  -> public Metal implementation
  -> Apple GPU driver
```

## Ownership

| Layer | Owner |
| --- | --- |
| `vk*` ABI, loader discovery, ICD dispatch | Khronos Vulkan Loader and standard Vulkan ICD ABI |
| Vulkan objects, SPIR-V ingestion, NIR, validation helpers | Mesa Vulkan runtime |
| Metal resource, command, synchronization, pipeline, and WSI behavior | Mesa KosmicKrisp |
| Build configuration, staging, provenance, diagnostics, and regression tests | AVK143 |

AVK143 does not expose `CVK`, `NSVulkan_KHR`, or a `.framework`. Those earlier
experiments are retained only under `archive/` and are not part of the active
driver path.

## Current Milestone

- `[x]` Build Mesa KosmicKrisp as a macOS Vulkan ICD from this checkout.
- `[x]` Generate a standard ICD JSON manifest and export the standard loader
  handshake functions.
- `[x]` Build against the actual Mesa 1.4.354 header/registry snapshot; no
  unverified SDK version is claimed by the ICD manifest or package name.
- `[x]` Stage the build under AVK143's project-owned output tree.
- `[x]` Verify standard-loader discovery, Vulkan 1.4 instance creation, and
  physical-device enumeration against the staged manifest.
- `[x]` Run `vulkaninfo`, a standard user-prefix discovery smoke, and a
  descriptor-backed compute/fence/readback smoke on the Apple GPU.
- `[ ]` Run targeted Vulkan 1.4 CTS groups before claiming conformance.
- `[ ]` Implement and validate the separate hardware ray-tracing feature path.

## Version Boundary

The active Mesa source advertises Vulkan API 1.4 with header patch revision
1.4.354, which is the maximum verified driver package in this tree. An isolated
probe of the official 1.4.360 registry exposed a Mesa generator compatibility
failure involving cooperative-matrix feature aliases. AVK143 therefore does not
paper over that mismatch by editing `VK_HEADER_VERSION`; any future 1.4.360
update must include the corresponding upstream Mesa generator support.

See [Apple ICD assembly](Apple_ICD/README.md) for the build and direct ICD
handshake workflow.
