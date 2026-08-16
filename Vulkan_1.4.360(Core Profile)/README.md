# Vulkan 1.4.360 (Core Profile)

## Status

This is the reserved home for the AVK143 native Vulkan project. A compile-
checked framework/CVK ABI contract and a static public-AppKit
`NSVulkan_KHR` lifecycle component are present, but no Vulkan framework
binary, ICD binary, loader replacement, or runtime dependency is created yet.
The runtime boundary activates only after its Mesa and Metal ownership map is
approved.

The project uses Mesa's Vulkan runtime and driver interfaces directly. It does
not share a runtime ABI with the separate graphics project.

## Product Boundary

```text
macOS Vulkan application
  -> Vulkan_1.4.3.framework / libvk*.dylib routing boundary
  -> CVK ABI and NSVulkan_KHR frontend
  -> AVK143 ICD boundary
  -> Mesa Vulkan runtime and KosmicKrisp Vulkan driver machinery
  -> AVK143MetalAdapter
  -> public Metal device, queue, resources, pipelines, events, and drawable
  -> Apple GPU driver and WindowServer
```

`AVK143` is the product prefix. Its platform-facing surface is
`Vulkan_1.4.3.framework`, the required `libvk*.dylib` client libraries,
`NSVulkan_KHR` for the AppKit-facing compatibility surface, and the CVK ABI for
native context, device, surface, and presentation contracts. The exact loader
library aliases, ICD manifest location, framework install location, and app
bundle routing remain design inputs rather than assumptions. The implementation
must not replace macOS's system Metal libraries or call private AGX submission
interfaces.

Public framework and ABI declarations use Apple-style `CVK*` types and
`kCVK*` values, with `NSVulkan_KHR` for AppKit. `AVK143*` is reserved for
private framework, ICD, Mesa-platform, Metal-adapter, and build machinery; an
application never needs an `AVK143`-prefixed ABI symbol.

## Ownership

| Layer | Owner | Rule |
| --- | --- | --- |
| Vulkan API semantics, object lifetime, validation, dispatch | Mesa Vulkan runtime | Reuse directly; do not reimplement Vulkan objects in AVK143. |
| SPIR-V ingestion, NIR, optimization, lowering | Mesa VTN/NIR | Reuse directly. |
| Vulkan command, descriptor, queue, synchronization, and image machinery | Mesa KosmicKrisp Vulkan source | Reuse and port only through its public Metal-facing contracts. |
| Metal resource, command, pipeline, event, residency, and presentation lifetime | `AVK143MetalAdapter` | Thin macOS execution boundary; no Vulkan semantic duplication. |
| Loader/ICD ABI, CVK ABI, `NSVulkan_KHR`, packaging, diagnostics | AVK143 framework/ICD layer | AVK143 owns macOS integration only. |
| GPU scheduling, firmware, memory protection, hardware management | macOS | Use public Metal; never recreate a private winsys. |

The initial upstream inventory is relative to the shared Mesa checkout. The
AVK143 build records that checkout as `AVK143_MESA_ROOT`:

- `$AVK143_MESA_ROOT/src/vulkan/runtime`
- `$AVK143_MESA_ROOT/src/compiler/spirv`
- `$AVK143_MESA_ROOT/src/compiler/nir`
- `$AVK143_MESA_ROOT/src/kosmickrisp/vulkan`
- `$AVK143_MESA_ROOT/src/kosmickrisp/compiler`
- `$AVK143_MESA_ROOT/src/kosmickrisp/bridge`

AVK143 must build and link its own audited Mesa Vulkan/KK artifacts only after
its CVK ABI and Metal adapter ownership are explicitly defined.

Configure the prerequisite build with the audited Mesa checkout and its
corresponding KosmicKrisp artifact directory. AVK143 deliberately does not
assume another project's checkout or build-directory name:

```sh
cmake -S "Vulkan_1.4.360(Core Profile)" -B /private/tmp/avk143-prerequisites \
  -DAVK143_MESA_ROOT=/path/to/mesa \
  -DAVK143_MESA_BUILD_DIR=/path/to/mesa/build-avk143-kosmickrisp-arm64
cmake --build /private/tmp/avk143-prerequisites
ctest --test-dir /private/tmp/avk143-prerequisites --output-on-failure
```

## Planned Layout

```text
Vulkan_1.4.360(Core Profile)/
  README.md                         This contract and checklist
  Frameworks/Vulkan_1.4.3.framework Future public headers and module map
  lib/libvk*.dylib                  Future client loader/dispatch libraries
  CVK/                              Future CVK ABI and native object boundary
  NSVulkan_KHR/                     Public AppKit lifecycle bridge
  ICD/                              Future ICD manifest and dispatch boundary
  MesaPlatform/                     Mesa Vulkan runtime integration only
  MetalAdapter/                     AVK143MetalAdapter implementation
  WSI/                              CAMetalLayer, IOSurface, resize, present
  Installer/                        Future packaging and rollback integration
  tests/                            Smoke, integration, and CTS harnesses
```

The public framework headers, module map, CVK ABI contract, and a compiled,
headless-tested `NSVulkan_KHR` AppKit lifecycle library exist at this stage.
This is not a driver: no loader, ICD, Vulkan object, Metal command, or
`CAMetalLayer` surface is created yet. The lifecycle library may retain and
resize an application-supplied `CAMetalLayer`, but never installs or presents
through it and never creates a Vulkan surface.

## Execution Architecture

```text
VkInstance / VkPhysicalDevice / VkDevice
  -> Mesa runtime dispatch and extension validation
  -> KK command buffers, descriptors, pipeline objects, and synchronization
  -> Mesa VTN: SPIR-V -> NIR
  -> KK compiler: NIR -> MSL
  -> AVK143MetalAdapter: public Metal resource/pipeline/queue encoding
  -> CVK surface/presentation ABI
  -> NSVulkan_KHR / CAMetalLayer / IOSurface WSI when a VkSurfaceKHR is present
```

The adapter may reuse audited Metal lifecycle patterns such as MTL4 queue
ownership, event timelines, resource retention, pipeline caching, and
presentation policy, but all reused types and entry points are renamed under
`AVK143`. It has a Vulkan-specific lifetime model. No foreign context, native
window ABI, or capability flag crosses this boundary.

## Parallel Workflow

Each implementation pass follows the AVK143 evidence-first rule:

1. Finish one nearest verified blocker with the smallest real dependency set.
2. Advance one higher-version capability where Mesa/KosmicKrisp already owns
   the semantic or compiler machinery.
3. Run the affected smoke tests, then update only the capability gates backed
   by those tests.

No capability is exposed because a header, function pointer, version string,
or placeholder exists. Mesa remains the Vulkan semantic authority; AVK143 owns
only the macOS ABI and Metal execution boundary.

## Implementation Checklist

### Lane 0: Reproducible Upstream Base

- `[~]` Record the configured Mesa/KosmicKrisp revision, dirty-tree state, and
  SHA-256 hashes for the reused generated artifacts in an AVK143 build-local
  provenance manifest. The active checkout is intentionally reported as dirty,
  so it is not yet a release pin.
- `[x]` Add the standalone `AVK143MesaVulkanPrerequisites` CMake target and
  CTest, which verify Mesa Vulkan runtime, VTN/NIR, KosmicKrisp Vulkan command
  sources, compiler/bridge sources, generated entrypoints, `libkk.a`, and the
  Metal bridge archive from one configured checkout.
- `[x]` Verify the active checkout: 7/7 required source inputs, 6/6 generated
  build inputs, and the `kk_instance_entrypoints` / `kk_device_entrypoints`
  archive symbols are present.
- Exit: AVK143 verifies its upstream prerequisites and records the exact
  reusable input provenance without linking an ICD or exposing a loader entry
  point. A clean revision pin remains required before an AVK143 runtime target
  is introduced.

### Lane 1: CVK, NSVulkan_KHR, Loader, And ICD Boundary

- `[x]` Audit the public Apple CGL and NSOpenGL ABI/AppKit lifecycle pattern
  before expanding CVK or defining `NSVulkan_KHR`. The source-controlled
  evidence map keeps C handles opaque, separates current-context selection
  from ownership, and requires non-owning AppKit drawable attachment plus
  explicit update/flush/loss transitions.
- `[~]` Define `Vulkan_1.4.3.framework` umbrella header and module-map policy.
  The checked header-only surface exports CVK types only; it exposes no Vulkan
  loader entry points or framework binary.
- `[~]` Define the CVK ABI's stable opaque handles, versioned create records,
  error model, surface kinds, submission-retirement contract, and a C-only
  AppKit drawable snapshot. Its C11 smoke locks the structure/version
  invariants while runtime ownership remains open.
- `[ ]` Define `libvk*.dylib` aliases, loader-facing ICD manifest, and dynamic
  library identity.
- `[~]` Define the initial `NSVulkan_KHR` AppKit ownership boundary. The
  compiled public surface lifecycle owner holds an `NSView` weakly and
  separates attach, update/backing-size change, and clear/detach transitions.
  It exports those transitions as a versioned C-only CVK snapshot without an
  Objective-C pointer. It can retain and configure an application-supplied
  `CAMetalLayer` without replacing `NSView.layer`; it creates neither a layer
  nor a Vulkan surface and does not present yet.
- `[ ]` Create `VkInstance`, physical-device enumeration, and extension
  reporting through Mesa runtime objects.
- `[ ]` Add a loader smoke that creates and destroys an instance without a
  surface.
- Exit: `vkCreateInstance` reaches a Mesa-owned instance and reports only
  tested properties.

### Lane 2: Device, Queues, And Command Objects

- `[ ]` Reuse KK device, queue, command-pool, and command-buffer machinery.
- `[ ]` Define the `AVK143MetalAdapter` device/queue ownership contract.
- `[ ]` Record and submit an empty command buffer through a public Metal queue.
- `[ ]` Map Metal completion to Vulkan fences and semaphores.
- Exit: one queue completes a command buffer with correct lifetime retirement.

### Lane 3: Memory, Resources, And Descriptors

- `[ ]` Map `VkBuffer` and `VkDeviceMemory` to retained MTLBuffers.
- `[ ]` Map initial `VkImage` formats and layouts to MTLTextures.
- `[ ]` Reuse KK descriptor-set and push-constant behavior; map its binding ABI
  to public Metal argument tables.
- `[ ]` Add validated upload, copy, barrier, and readback smoke coverage.
- Exit: a descriptor-backed buffer or image operation returns deterministic
  data without a staging-only shortcut.

### Lane 4: SPIR-V, NIR, And Pipelines

- `[ ]` Use Mesa VTN to ingest SPIR-V into NIR.
- `[ ]` Reuse KK NIR-to-MSL lowering and reflection.
- `[ ]` Build compute and graphics pipelines through the public MTL4 compiler
  and retain them in Mesa/KK pipeline records.
- `[ ]` Add specialization-constant and pipeline-cache validation.
- Exit: one SPIR-V compute shader and one graphics shader run through the
  complete Mesa/KK/Metal pipeline.

### Lane 5: Synchronization And Hazards

- `[ ]` Map pipeline barriers, resource access masks, queue ownership, events,
  fences, and timeline semaphores to Metal events and encoder ordering.
- `[ ]` Retain resources until all dependent submissions retire.
- `[ ]` Add cross-queue and read/write hazard smoke coverage.
- Exit: queue ordering and visibility are correct without host waits in the
  normal command path.

### Lane 6: WSI And Presentation

- `[ ]` Implement `VK_KHR_surface` / `VK_KHR_swapchain` policy for AppKit and
  `CAMetalLayer` drawables.
- `[ ]` Add acquire, present, resize, backing-scale, drawable-loss, and
  color-space handling.
- `[ ]` Add a compositor-hosted opt-in smoke plus deterministic headless
  offscreen coverage.
- Exit: an application can acquire, render, present, resize, and recover a
  swapchain without leaking or reusing stale drawables.

### Lane 7: Version And Extension Gates

- `[ ]` Establish a test-backed Vulkan 1.0 baseline before advertising later
  core versions.
- `[ ]` Add version gates for each required Vulkan 1.1, 1.2, 1.3, and 1.4
  feature group only after its driver, synchronization, and validation paths
  are present.
- `[ ]` Derive extension strings from the active feature matrix, never from a
  fixed list.
- Exit: reported API version, extension list, properties, limits, and runtime
  behavior agree.

### Lane 8: Verification And CTS

- `[ ]` Add unit smokes for every new resource, pipeline, queue, and WSI path.
- `[ ]` Run targeted Vulkan CTS groups as each feature gate becomes eligible.
- `[ ]` Record failures and regressions before raising a version gate.
- `[ ]` Run broad CTS only after all preceding lanes are complete.
- Exit: CTS results support every version and extension claim.

## Reuse Rules

- Prefer a direct Mesa/KosmicKrisp contract over an AVK143 rewrite.
- If a contract is not directly reusable, port only the algorithm and retain
  upstream attribution, a narrow adapter boundary, and a regression test.
- Do not import Asahi AGX batch, BO, shader compiler, DRM, or winsys code into
  this Metal execution path.
- Do not use private Apple GPU submission APIs. Reverse-engineering records may
  inform diagnostics and performance invariants but are not runtime contracts.
- Do not claim Vulkan 1.4.360, portability, or conformance until CTS evidence
  exists.

## First Approved Coding Gate

The first code pass begins after the Vulkan map specifies the exact loader/ICD
identity, CVK ABI, `NSVulkan_KHR` ownership, intended framework layout,
Mesa/KosmicKrisp source ownership, public Metal adapter boundary, WSI policy,
and installer/rollback policy. Until then, this README is the authoritative
plan and AVK143 has no active runtime.
