# Vulkan CTS 1.4.6.2 bring-up — 2026-08-22

This is active-development evidence, not a conformance result and not a
replacement for the published 1.4.3.2 engineering-release ledger.

## Provenance

- CTS source archive: `VK-GL-CTS-vulkan-cts-1.4.6.2.zip`
- CTS archive SHA-256:
  `b2d9dc779a534b83b18db3f780486db58a7e796ec1a0ce3698c66039938a590a`
- `deqp-vk` SHA-256:
  `666b8693f7f9e4d64c15c6cdb35607898bed52f6f1a0b177c6dc692d21fd7592`
- AVK143 ICD SHA-256:
  `e6dc48be0613a23ffbf300340f74d8cb04eb2d648fc39e22b49107f4e58f69cb`
- Vulkan-Headers and Vulkan-Loader: official Khronos `v1.4.354` sources
- Surface type: `fbo`

The harness was prepared with
`Apple_ICD/scripts/prepare-avk143-vulkan-cts.sh` and executed with
`AVK143_CTS_GROUPS=info Apple_ICD/scripts/run-avk143-vulkan-cts.sh`.

## Results

The four-case early-fragment preflight completed with two `Pass` and the same
two permitted `QualityWarning` outcomes retained by the previous release.

The 1.4.6.2 `dEQP-VK.info` admission group produced:

- 19 `Pass`
- 1 `NotSupported` (a peer-memory query requiring at least two physical devices)
- 1 failure: `dEQP-VK.info.device_mandatory_features`

The failure is the mandatory Vulkan 1.4 memory-model contract:
`vulkanMemoryModel` and `vulkanMemoryModelDeviceScope`. KosmicKrisp does not
advertise them because this Metal compiler accepts only
`memory_order_relaxed` for device atomic loads, stores, exchanges,
compare-exchanges, and read-modify-write operations.

An implementation experiment used device-scoped `atomic_thread_fence`,
volatile/coherent ordinary accesses, and atomic coherent scalar payloads. One
full `dEQP-VK.memory_model` pass completed cleanly, but repeated qualification
runs were nondeterministic. Subsequent isolated runs produced three to six
failures among device/queue-family message-passing and write-after-read cases;
changing the fence count only changed which cases failed, and a compute-stage
variant eventually failed as well. The last isolated run produced:

- 3,267 `Pass`
- 14,028 `NotSupported`
- 5 failures
- 0 warnings

The experimental feature advertisement and lowering changes were therefore
reverted rather than recording a flaky pass. There is no valid `info.complete`
or `memory_model.complete` marker, and the mega runner refuses to launch until
both admission gates are genuinely complete.

## Four-phase default-mustpass campaign

`Apple_ICD/scripts/run-avk143-vulkan-cts-mega.sh` flattened the official
1.4.6.2 `vk-default.txt` index. The already-separate `info` and `memory_model`
admission groups are excluded from the parallel shards, leaving 3,230,231
cases split into phases of 807,558, 807,558, 807,558, and 807,557 cases. The
flattened shard inventory SHA-256 is
`fc96146cc59b87a022809776bb8fee620ea9d07dbce674211d5fa9e12874c5cd`.

All four phases run concurrently under per-user `launchd` ownership with
`--deqp-surface-type=fbo`, hidden visibility, watchdogs, isolated/no shader
cache, and image/shader/decompiled-SPIR-V logging disabled. This avoids
onscreen WindowServer surfaces while preserving QPA and concise text evidence.
Each phase is internally divided into 1,000-case process batches so Metal and
CTS resources are returned to macOS frequently; all four phase workers remain
parallel while the batch processes recycle.
Every completed phase generates `summary.txt` and `issues.tsv`; a phase is not
marked complete when it contains a failure, crash, timeout, resource error, or
unexpected quality warning. A preliminary launch also detected and corrected
the need for 1,000-case process recycling: long-lived workers reduced system
free memory to 1–2%, while the recycled design held it near 83–85% with four
workers. The four-phase campaign is prepared but intentionally stopped at the
memory-model admission gate.

## Mesa main/KosmicKrisp comparison and sync

The separately cloned freedesktop.org Mesa `main` was inspected and tested at
commit `00e42c51b10d8e0769489156fa414f111897d515`. Upstream KosmicKrisp now
advertises `VK_KHR_vulkan_memory_model`, `vulkanMemoryModel`, and
`vulkanMemoryModelDeviceScope`, but its NIR-to-MSL atomic lowering still emits
relaxed Metal atomics combined with device-scope sequentially-consistent
fences. The advertised contract is therefore not sufficient on this system.

An isolated build of that unmodified upstream commit produced the following
CTS 1.4.6.2 results:

- `dEQP-VK.info`: 20 `Pass`, 1 `NotSupported`, 0 failures
- `dEQP-VK.memory_model`: 3,266 `Pass`, 14,028 `NotSupported`, 6 failures,
  0 warnings

The six failures were message-passing or write-after-read litmus cases using
device or queue-family scope. They included both integer and floating-point
payloads, fragment-stage variants, coherent and noncoherent access, and both
buffer and physical-buffer guards. Consequently, upstream Mesa `main` has not
fixed the memory-model correctness issue; it currently hides the mandatory
feature failure by advertising semantics that fail the focused CTS group.

The AVK Mesa submodule was nevertheless synchronized to that upstream base.
The five AVK/AO46 commits were rebased on `00e42c51b10`, with the pre-sync head
preserved as branch `codex/pre-mesa-main-sync-20260822`. Current AVK Mesa head
is `9ac846abb57ecc4e2f2edb24871297a36abc9ac6`. Conflict resolution retained
new upstream descriptor, sampler, maintenance, and present-extension work;
retained AVK's existing CTS/compiler fixes; and deliberately kept the three
memory-model capability bits disabled. Two current-Mesa integration drifts
were also corrected: the new `nir_lower_io_indirect_loads` argument and the
upstream custom-border lowering split.

The synchronized driver builds successfully. Its four integration smokes all
pass (standard headers, standard Loader instance, KosmicKrisp compute, and ICD
package), and the installed ICD SHA-256 is
`329f63b30041e1d810be846969540b09274faee40c691441ce9232da75a5460d`.
The fresh CTS 1.4.6.2 `info` admission rerun remains intentionally blocked at
19 `Pass`, 1 `NotSupported`, and the single mandatory-feature failure for
`vulkanMemoryModel` and `vulkanMemoryModelDeviceScope`. No mega-phase worker
or `deqp-vk` process was launched.

## Next-pass device-atomic ordering probe

The first post-sync memory-model pass tested the most direct correction:
emitting `memory_order_seq_cst` for device atomic loads, stores, read-modify-
write operations, exchanges, and compare-exchanges while leaving threadgroup
atomics unchanged. The driver and generated MSL compiler built, but Metal
rejected the first focused CTS shader during `newLibraryWithSource`.

Apple's Metal compiler reported that the device-address-space overload of
`atomic_fetch_add_explicit` is disabled unless its order argument is
`memory_order_relaxed`. CTS consequently terminated the probe with
`VK_ERROR_INVALID_SHADER_NV`; this was a compile-time backend restriction, not
a memory-model test result. The experimental feature advertisement and atomic
ordering edits were fully reverted, the honest driver was rebuilt, and all
four integration smokes passed again. No source change or CTS completion
marker was committed from this probe, and no mega-phase worker was launched.

The same pass also checked the restored maintenance9/10 exposure independently
of the blocked core gate. Both extension feature-query and unsupported-feature
device-creation cases passed for maintenance9 and maintenance10. A monolithic
maintenance10 dynamic-render multisample-resolve case passed, as did a
maintenance9 single-queue synchronization2 image-transition case. Two
additional samples were correctly `NotSupported` because they required,
respectively, graphics-pipeline-library support and more than one queue
family. These focused results support retaining the upstream maintenance9/10
advertisement; they are not substitutes for their full mustpass coverage.

## Version-2 extension restoration

A final comparison against upstream `00e42c51` found that the older 1.4.3.2
qualification patch still suppressed five device-extension declarations even
after maintenance9/10 were restored: shader FMA, shader untyped pointers,
unified image layouts, and the KHR/EXT swapchain-maintenance1 aliases. Version
2 restores those declarations as well as their KHR/EXT surface-maintenance1
instance dependencies.

CTS 1.4.6.2 detected an intermediate missing dependency when the EXT
swapchain-maintenance alias was restored before `VK_EXT_surface_maintenance1`.
After the complete dependency chain was enabled, all instance and device
extension dependency checks passed. Eight focused API feature-query and
device-creation cases for shader FMA, untyped pointers, unified image layouts,
and swapchain maintenance passed. The final `info` result returned to 19
`Pass`, 1 expected two-device `NotSupported`, and exactly one failure: the
separately documented mandatory Vulkan Memory Model features.

The version-2 policy is therefore explicit: extensions recognized by CTS
1.4.6.2 remain advertised when their implementation is present; they are not
hidden to reproduce an older suite's enumeration behavior. The memory-model
extension remains the sole intentional extension-table difference from the
tested upstream capability set because its semantic group fails.
