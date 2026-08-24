# AVK Vulkan installer version 2 — CTS 1.4.6.2 draft

**Draft ID:** `vulkan-api-sdk-1.4.354-v2-cts-1.4.6.2-20260822`

**Status:** blocked engineering release candidate; not CTS-qualified and not
Khronos certified

**Target:** Apple Silicon macOS, Mesa KosmicKrisp through the standard Khronos
Loader/ICD ABI

This record contains every source, capability, test, and packaging update made
after the Vulkan CTS target changed from 1.4.3.2 to 1.4.6.2 and a new Mesa
`main` checkout was introduced. It is deliberately a draft: the mandatory
Vulkan Memory Model admission gate does not pass, the four-phase default
mustpass campaign has not run to completion, and no installer built from this
state may be described as conformant or CTS-qualified.

## Release decision

Version 2 may be published now only as an explicitly experimental developer
preview. A Vulkan 1.4 qualification or conformance claim requires a repeatable
memory-model fix followed by a clean CTS 1.4.6.2 mustpass campaign. Turning on
the memory-model bits merely to make `dEQP-VK.info` pass is rejected because
the unmodified upstream implementation fails six semantic memory-model cases.

`VkConformanceVersion` remains `{0, 0, 0, 0}`. The CTS revision in this draft
ID identifies the test suite and does not imply Khronos certification.

## Exact provenance

| Component | Revision or checksum |
| --- | --- |
| New freedesktop.org Mesa `main` base | `00e42c51b10d8e0769489156fa414f111897d515` |
| Synchronized AVK Mesa committed head | `9ac846abb57ecc4e2f2edb24871297a36abc9ac6` |
| Pre-sync recovery branch | `codex/pre-mesa-main-sync-20260822` at `4bdd6173e129e893b43ed4e11c8da3c853e48b53` |
| Proposed uncommitted capability-restoration patch SHA-256 | `251bf79cfc5206f25c564be4773ce5901ca0bd9a2affa06024aef36334c5446d` |
| Khronos Vulkan-Headers | `01393c3df0e5285b54ee6527466513f9e614be94` (`v1.4.354`) |
| Khronos Vulkan-Loader | `92f42301839b406b7d47d92b279db8f8744d8dcf` (`v1.4.354`) |
| CTS source archive | `VK-GL-CTS-vulkan-cts-1.4.6.2.zip` |
| CTS archive SHA-256 | `b2d9dc779a534b83b18db3f780486db58a7e796ec1a0ce3698c66039938a590a` |
| Built `deqp-vk` SHA-256 | `666b8693f7f9e4d64c15c6cdb35607898bed52f6f1a0b177c6dc692d21fd7592` |
| Current draft ICD SHA-256 | `021e52b98693c3d6e8d0d106d7868b44cdc09a27394ac6a8e193248943b3a4e9` |
| Current ICD JSON SHA-256 | `5c3391fdab691bbff8976f43dbdf436597ca983a86dbdbcc3d58913f525d2707` |

The proposed patch checksum is useful only before commit. Replace it with the
new committed Mesa revision after review; then rebuild and replace the runtime
hash so the final record names the exact shipped binary.

## Test host

| Field | Value |
| --- | --- |
| macOS | 26.5.2, build 25F84 |
| SoC | Apple M4 Pro |
| GPU | Apple M4 Pro, 20 cores |
| Metal | Metal 4 |
| CTS surface | hidden `fbo` unless a WSI-specific test requires a window |

Results apply to this host and compiler stack. They must not be generalized to
all Apple GPUs or Metal compiler versions without reproduction.

## Every update after CTS 1.4.6.2 and new Mesa were introduced

### Mesa synchronization

1. An isolated upstream Mesa checkout was verified clean at
   `00e42c51b10`.
2. Unmodified upstream KosmicKrisp was built in an isolated build/stage tree.
3. The five AVK/AO46 commits were rebased onto that exact upstream revision.
4. The old AVK head was preserved on
   `codex/pre-mesa-main-sync-20260822`.
5. Descriptor, sampler, image-min-LOD, maintenance9/10, and presentation
   conflicts were resolved in favor of the current upstream structures while
   retaining AVK's local correctness work.
6. Current Mesa's third `nir_lower_io_indirect_loads` argument was added with
   `lower_indirect_vertex_index = false`.
7. The obsolete AVK-private custom-border lowering was removed after upstream
   split that pass into `kk_nir_lower_custom_border.c`.
8. The synchronized source built successfully and all four integration smokes
   passed.

### Apple ICD source assembly

1. `Client/Vulkan-Loader` now pins the official Khronos Loader.
2. `stdvkabi_khr/Vulkan-Headers` now pins the official Khronos public ABI.
3. `Client`, `Drivers`, `ICD`, `MesaPlatform`, and `Runtime` CMake/source-owner
   directories describe the full ICD assembly without duplicating Mesa.
4. The canonical complete Mesa/KosmicKrisp checkout remains the sibling
   `../mesa` directory.
5. Build and smoke targets consume the official Khronos headers instead of
   treating Mesa's internal header copy as the application ABI.
6. Runtime staging carries a private relocatable SPIR-V Tools dependency and
   loader-relative rpaths.
7. Vulkan Tools integration reuses the pinned Loader and Headers sources.

### CTS migration and execution controls

1. The default CTS source, binary, loader, and results roots moved from 1.4.3.2
   to 1.4.6.2.
2. The preparation script verifies the 1.4.6.2 source and builds a matching
   Khronos Loader and `deqp-vk`.
3. The runner records suite/source/binary/manifest/loader provenance and does
   not silently fall back to 1.4.3.2.
4. `info` and `memory_model` became mandatory admission gates.
5. The official 1.4.6.2 default mustpass inventory was flattened after
   excluding those two separately executed gates.
6. The remaining 3,230,231 cases were divided into four deterministic phases:
   807,558, 807,558, 807,558, and 807,557 cases.
7. Four workers run asynchronously through per-user `launchd` with hidden FBO
   surfaces and 1,000-case child-process recycling.
8. Each chunk and phase preserves stdout, QPA, exit status, summaries, and
   issue lists. Failures, crashes, timeouts, resource errors, and unexpected
   warnings prevent completion markers.
9. The mega launcher refuses to run until `info.complete` and
   `memory_model.complete` are both genuine.

## Extension-restoration audit

The 1.4.3.2 branch had removed extension names to avoid failures caused by an
older suite not recognizing newer extensions. That policy was incorrect. CTS
1.4.6.2 recognizes the current extension set, so version 2 restores the
current-upstream declarations and their dependency chain.

| Extension bit | 1.4.3.2 branch | Version 2 | Reason and CTS 1.4.6.2 evidence |
| --- | ---: | ---: | --- |
| `VK_KHR_maintenance9` | off | on | Restored by Mesa sync; feature query/device creation pass; one single-queue synchronization2 semantic sample passes. |
| `VK_KHR_maintenance10` | off | on | Restored by Mesa sync; feature query/device creation pass; one monolithic dynamic-render resolve semantic sample passes. |
| `VK_KHR_shader_fma` | off | on | Restored to match upstream and existing `shaderFmaFloat16/32` feature bits; both API feature tests pass. |
| `VK_KHR_shader_untyped_pointers` | off | on | Restored to match upstream and existing `shaderUntypedPointers`; both API feature tests pass. |
| `VK_KHR_unified_image_layouts` | off | on | Restored to match upstream and existing `unifiedImageLayouts`; both API feature tests pass. `unifiedImageLayoutsVideo` remains false. |
| `VK_KHR_surface_maintenance1` | off | on | Restored instance dependency required by KHR swapchain maintenance. Instance dependency CTS passes. |
| `VK_EXT_surface_maintenance1` | off | on | Restored instance dependency required by EXT swapchain maintenance. Instance dependency CTS passes. |
| `VK_KHR_swapchain_maintenance1` | off | on | Restored to match upstream and existing `swapchainMaintenance1`; API feature tests pass. |
| `VK_EXT_swapchain_maintenance1` | off | on | Restored with `VK_EXT_surface_maintenance1`; device dependency CTS now passes. |

An intermediate build restored `VK_EXT_swapchain_maintenance1` without its
instance dependency. CTS correctly failed
`dEQP-VK.info.device_extension_dependencies`. Restoring
`VK_EXT_surface_maintenance1` and `VK_KHR_surface_maintenance1` fixed the
dependency chain. This intermediate failure is retained as evidence that CTS
1.4.6.2 is policing the new declarations rather than accepting them blindly.

### The one extension difference intentionally retained from upstream

| Extension or feature bit | Upstream `00e42c51` | Version 2 draft | Reason |
| --- | ---: | ---: | --- |
| `VK_KHR_vulkan_memory_model` | true | false | Upstream semantic group has six failures. |
| `vulkanMemoryModel` | true | false | Mandatory `info` failure is retained instead of making a false semantic claim. |
| `vulkanMemoryModelDeviceScope` | true | false | Device/queue-family message-passing and write-after-read cases fail. |
| `vulkanMemoryModelAvailabilityVisibilityChains` | implicit false | false | Not enabled or claimed. |

No other current-upstream extension name is suppressed by the version-2
capability-restoration patch.

## Other deliberate property differences from upstream

| Property | Upstream | Version 2 | Rationale |
| --- | --- | --- | --- |
| `VkConformanceVersion` | `{1,4,3,2}` | `{0,0,0,0}` | AVK has not received Khronos certification. |
| `roundingModeIndependence` | `NONE` | `32_BIT_ONLY` | CTS-observed fp32 RTE behavior differs from fp16/fp64. |
| `shaderRoundingModeRTEFloat16` | true | false | Do not claim an fp16 rounding mode not validated by the public Metal path. |
| API-version helper | Separate local functions | Shared bounded `kk_get_api_version()` | Keeps instance and physical-device reporting consistent and honors only lower overrides. |

## CTS 1.4.6.2 result ledger

### Clean unmodified upstream Mesa/KosmicKrisp

| Group | Pass | NotSupported | Fail | Warnings |
| --- | ---: | ---: | ---: | ---: |
| `dEQP-VK.info` | 20 | 1 | 0 | 0 |
| `dEQP-VK.memory_model` | 3,266 | 14,028 | 6 | 0 |

The six failures are:

```text
dEQP-VK.memory_model.message_passing.ext.u32.coherent.atomic_fence.atomicwrite.queuefamily.payload_local.buffer.guard_local.buffer.frag
dEQP-VK.memory_model.message_passing.ext.u32.coherent.atomic_atomic.atomicwrite.device.payload_local.buffer.guard_local.physbuffer.frag
dEQP-VK.memory_model.message_passing.ext.f32.coherent.atomic_atomic.atomicwrite.device.payload_local.buffer.guard_local.physbuffer.frag
dEQP-VK.memory_model.message_passing.ext.f32.coherent.atomic_atomic.atomicwrite.queuefamily.payload_local.physbuffer.guard_local.physbuffer.frag
dEQP-VK.memory_model.message_passing.ext.f32.noncoherent.atomic_atomic.atomicwrite.device.payload_local.physbuffer.guard_local.physbuffer.frag
dEQP-VK.memory_model.write_after_read.ext.u32.noncoherent.atomic_atomic.atomicrmw.device.payload_local.buffer.guard_local.physbuffer.frag
```

### Rejected AVK memory-model experiments

1. Device-scoped `atomic_thread_fence`, volatile/coherent ordinary accesses,
   atomic coherent scalar payloads, and different fence counts produced one
   clean full run but three-to-six failures on repetition. A compute-stage
   variant eventually failed, so the apparent pass was nondeterministic.
2. Mapping device atomic load/store/RMW/exchange/CAS operations directly to
   `memory_order_seq_cst` was rejected by Apple's Metal compiler. The device
   overload is disabled unless the order is `memory_order_relaxed`; CTS ended
   with `VK_ERROR_INVALID_SHADER_NV` before executing the litmus test.
3. Every experimental feature advertisement and lowering edit was reverted.
   No completion marker or semantic source commit was made from these runs.

### Version-2 final capability state

After restoring the full extension dependency chain, `dEQP-VK.info` reports:

| Result | Count |
| --- | ---: |
| Pass | 19 |
| NotSupported | 1 |
| Fail | 1 |
| Warnings | 0 |

The sole failure is `dEQP-VK.info.device_mandatory_features`, naming
`vulkanMemoryModel` and `vulkanMemoryModelDeviceScope`. Device and instance
extension enumeration and dependency tests pass. The one `NotSupported` result
requires a device group containing at least two physical devices.

### Restored-extension focused tests

| Coverage | Pass | NotSupported | Fail | Warning |
| --- | ---: | ---: | ---: | ---: |
| Eight shader-FMA, untyped-pointer, unified-layout, and swapchain-maintenance API feature tests | 8 | 0 | 0 | 0 |
| Four maintenance9/10 API feature tests | 4 | 0 | 0 | 0 |
| Maintenance10 monolithic dynamic-render resolve sample | 1 | 0 | 0 | 0 |
| Maintenance9 single-queue synchronization2 sample | 1 | 0 | 0 | 0 |
| Fast-linked maintenance10 sample | 0 | 1 | 0 | 0 |
| Concurrent multi-queue maintenance9 sample | 0 | 1 | 0 | 0 |

The two skips are expected: the first requires unsupported graphics-pipeline
library functionality and the second requires more than one queue family.

### Integration smokes

```text
AVK143StandardVulkanHeaders       Passed
AVK143StandardLoaderInstance     Passed
AVK143MesaKosmicKrispCompute     Passed
AVK143VulkanICDPackage           Passed
```

## Output/evidence manifest

The following generated files are local build evidence and should be attached
to the version-2 GitHub prerelease or packed into a checksummed evidence archive
rather than committed as large Git blobs:

| Evidence | Repository-relative generated path |
| --- | --- |
| Clean-upstream `info` stdout/QPA | `build/AVK143-upstream-main/cts/vulkan-1.4.6.2/info.{stdout,qpa}` |
| Clean-upstream memory-model stdout/QPA | `build/AVK143-upstream-main/cts/vulkan-1.4.6.2/memory_model.{stdout,qpa}` |
| Synchronized honest `info` | `build/AVK143/cts/vulkan-1.4.6.2-mesa-sync-00e42c51/info.{stdout,qpa}` |
| Rejected seq-cst probe | `build/AVK143/cts/memory-model-next-pass/seq-cst-probe/{stdout.txt,result.qpa}` |
| Maintenance9/10 focused evidence | `build/AVK143/cts/maintenance-next-pass/` |
| Intermediate dependency failure | `build/AVK143/cts/vulkan-1.4.6.2-v2-extension-restore/info.{stdout,qpa}` |
| Final capability `info` | `build/AVK143/cts/vulkan-1.4.6.2-v2-final-capabilities/info.{stdout,qpa}` |
| Eight restored-extension API tests | `build/AVK143/cts/vulkan-1.4.6.2-v2-restored-extension-features/` |
| Four-phase configuration and eventual results | `build/AVK143/cts/vulkan-1.4.6.2/mega-mustpass/` |

Before publication, create one deterministic evidence archive, record its
SHA-256 here and in the machine-readable manifest, and verify that every QPA
names the final shipped ICD build.

## Unsupported and unclaimed behavior

- Vulkan Memory Model and device scope are not advertised in this draft.
- `vulkanMemoryModelAvailabilityVisibilityChains` is not advertised.
- A nonzero `VkConformanceVersion` is not advertised.
- Hardware ray tracing is not advertised.
- Optional false feature/property bits remain false when inherited from
  upstream or when the implementation is absent; they are not changed merely
  to reduce CTS coverage.
- The early-fragment sample-count tests previously producing two
  `QualityWarning` results remain documented and must be rerun with 1.4.6.2.
- One queue family means multi-queue-family CTS cases may legitimately report
  `NotSupported`; this is not a waiver for single-queue failures.
- Graphics-pipeline-library-dependent variants may report `NotSupported` when
  that optional extension is not advertised.

## Remaining qualification gates

1. Implement repeatable device/queue-family Vulkan Memory Model semantics.
2. Enable `VK_KHR_vulkan_memory_model`, `vulkanMemoryModel`, and
   `vulkanMemoryModelDeviceScope` only with that implementation.
3. Pass each of the six known litmus failures repeatedly.
4. Complete at least three consecutive full `dEQP-VK.memory_model` runs with
   zero failures, crashes, timeouts, resource errors, or warnings.
5. Pass `dEQP-VK.info` with only the expected two-device peer-memory skip.
6. Rerun the early-fragment preflight and classify every warning accurately.
7. Launch and complete all four 1.4.6.2 mega phases.
8. Fix each discovered issue immediately and restart its affected chunk.
9. Rebuild from a clean checkout, repeat focused regressions, and hash the
   exact final ICD and manifest.
10. Build and smoke-test the installer, then test installation, loader
    discovery, `vulkaninfo`, compute, and `vkcube.app` outside the source tree.

## Commit plan

The version-2 change should be reviewable as separate commits:

1. Mesa main synchronization and current-Mesa compiler integration.
2. Restoration of upstream extension names and complete surface/swapchain
   dependency chains.
3. Official Khronos Loader/Headers and Apple ICD source assembly.
4. CTS 1.4.6.2 preparation, focused runner, and four-phase campaign.
5. Version-2 capability audit, semantic delta, and draft release manifest.
6. A later memory-model implementation commit, only after focused proof.
7. Final qualification hashes and installer metadata, only after all gates.

The nested Mesa commit must be pushed to a reachable branch before the outer
repository commits its submodule pointer. Generated `build/`, CTS build trees,
QPA archives, packages, Finder metadata, and unrelated OpenGL work must not be
included in the Vulkan release commits.
