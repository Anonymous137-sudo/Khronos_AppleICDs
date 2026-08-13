# Apple AGX Compute Carrier Research

Status: active, profile-gated reverse-engineering record. This document records
observed behavior of an Apple-created compute command carrier. It is not a
declaration of a portable Apple ABI, and it does not authorize AO46 to replay
private object layouts on another operating-system or AGX profile.

## Profile And Method

The observations apply only to the active M4 Pro profile on macOS 26.5.2
(25F84), using the loaded arm64e
`AGXMetalG16X.bundle/Contents/MacOS/AGXMetalG16X` image. The investigation
combines profile-local static disassembly with read-only LLDB probes while a
public Metal compute workload completes successfully.

Three execution controls are compared:

- `baseline`: one thread writes `0x6a46`.
- `two-buffers`: one thread copies an input buffer to an output buffer.
- `threadgroup`: 32 threads use a 256-element threadgroup array and write the
  same result.

The paired capture warms the same device, queue, three pipeline objects, and
two retained buffers, then records two submissions for each control. This
removes cross-process address-space noise and first-use pool growth from the
sidecar differential. All probes observe existing Apple objects and memory
only. AO46 does not call a private selector, construct a private object, write
Apple-owned memory, or submit an AO46/Asahi batch during this investigation.

## Measured Command Construction

`ContextCommon::newCommand(unsigned long, bool)` is the local constructor for
the observed compute carrier. On the baseline workload it receives a requested
payload size of `0x330` bytes and does the following:

1. Reserves cursor space from an Apple command-buffer storage object, growing
   that storage when needed.
2. Writes an 8-byte segment header. The observed little-endian words are
   `0x00010000` and the requested payload length (`0x330`).
3. Calls `IOGPUMetalCommandBufferStorageBeginSegment(storage, segment_header)`.
4. Initializes the command record in the segment and adds storage/allocator
   resources to the active Apple resource list.
5. Returns the command body at `segment_header + 8`.

This establishes a concrete carrier lifetime and storage relationship. It also
establishes that the constructor operates on an already-created Apple command
storage object; it is not a generic allocation helper for arbitrary Asahi
command bytes.

For the measured compute pass:

| Observed element | Relationship to returned command body | Evidence |
| --- | ---: | --- |
| Compute subrecord supplied to `setupComputeCommand` | `+0xc0` | Live pointers differ by `0xc0`. |
| USC descriptor destination | compute subrecord `+0x150` | Static caller plus live destination pointer. |
| First USC descriptor destination | command body `+0x210` | Derived from the two measured offsets. |
| Segment header | command body `-0x8` | Constructor return and storage-begin probe agree. |

These are observed layout relationships for this exact image, not a reusable
wire-format specification.

## Segment Close And Queue Lowering

`ContextCommon::endCommand` recovers the same segment header by subtracting the
stored segment length from the current storage cursor. The paired
`IOGPUMetalCommandBufferStorageEndSegment(storage)` probe sees that exact
header after the command has been finalized. This closes the measured storage
lifecycle:

```text
newCommand
  -> BeginSegment(storage, header)
  -> command body / compute subrecord / USC descriptor / resource bindings
  -> endCommand
  -> EndSegment(storage)
  -> fillCommandBufferArgs(command buffer, queue)
  -> queue submission and completion
```

The public command buffer's `fillCommandBufferArgs:commandQueue:` receives a
zeroed 64-byte record. On return, the active profile sets its first two
32-bit words to `2` and `1`; the two 64-bit values at offsets `0x10` and
`0x18` exactly match the completion-token pair observed by the public submit
trace. The queue-facing descriptor therefore has a demonstrated
completion/control role.

It does **not** contain a visible command-storage pointer or an arbitrary
Asahi CDM/VDM stream in this workload. The remaining carrier sidecar/Trap4
relationship must be traced separately; manufacturing it from these fields
would be another opaque-carrier guess.

## Sidecar Differential Status

`capture_agx_shader_contract_trace.sh` now supports an explicit
`AGX_SHADER_CONTRACT_CAPTURE_SIDECAR=1` diagnostic mode. It captures one
bounded 4 KiB Trap4 sidecar and up to seven bounded pointer targets. The normal
shader-contract trace leaves this off.

`analyze_agx_sidecar_control_delta.sh` compares two fresh baseline captures
and two fresh variant captures. It reports only 64-bit words stable within each
workload but different between them. On the baseline/two-buffer compute
control, it reports zero candidates: process-local allocation and pointer
churn dominate the raw sidecar across launches.

An existing two-submission, single-process blit control removes that
cross-process ambiguity. Its 4 KiB sidecars differ at many word positions as
the second command uses more resources, and the independent mapped-resource
scanner observes two GPU-resource references for the first submission versus
four for the second. That proves resource-sensitive data reaches the public
submission path, but it does not yet establish which sidecar words are the
resource table. Several followed sidecar pointers classify as host Mach-O or
string data, so they are excluded from resource-table candidates.

The compute paired control applies the stricter two-repeat filter to one
warm-up, two baseline submissions, two two-buffer submissions, and two
threadgroup submissions. Two independent captures completed all seven public
dispatches and observed seven segment-close, queue-lowering, Trap4, and
completion lifecycles. The cross-capture intersection reports:

| Differential | Stable 64-bit p4 sidecar candidates | Result |
| --- | ---: | --- |
| Baseline vs. two-buffer | 0 | The added read-only buffer is not a reproducible direct p4 sidecar field on this profile. |
| Baseline vs. threadgroup | 0 | No reproducible shader-sensitive p4 word was found for this control pair. |

The two-buffer path still records two distinct command-table bindings: index
`0` writable and index `1` read-only. The correct current conclusion is that
resource count/access is represented by the closed command record and its
Apple resource-list transition, not by a decoded p4 resource-table word. One
in-run shader candidate at `0x4f8` did not recur in the independent capture
and is rejected rather than retained as a candidate.

## USC Descriptor Packer

The active G16X symbol named
`SpillInfoGen3::allocateUSCSpillBuffer(AGXUMADescRec*, ...)` is misleading for
this concrete path. Its body is a leaf descriptor packer: it performs no call
to an allocator, IOKit, a resource-list API, or a queue API.

The routine writes a 72-byte `AGXUMADescRec` destination. Static inspection
shows these stable mechanical relationships:

| Destination bytes | Observed source/calculation |
| --- | --- |
| `0x00..0x0f` | two 4 KiB-page-scaled, 8-byte-aligned calculated spans |
| `0x10..0x17` | sign-extended 32-bit source value at source `+0x20` |
| `0x18..0x27` | copied 16-byte source range at source `+0x08` |
| `0x30..0x37` | two 32-bit values copied from source `+0x2c` |
| `0x38..0x3f` | calculated spill/dispatch quantities |
| `0x40..0x47` | zeroed on this profile path |

It reads profile configuration through a source-owned pointer at source
`+0x40`, derives counts and alignment, then populates the destination. The
first descriptor differs between the baseline and threadgroup workloads,
confirming that this record encodes pipeline/dispatch-specific state. The
second descriptor, rebuilt during finalization, is identical across the two
controls and is therefore a separate stable end-pass configuration on this
workload.

The descriptor packer by itself does **not** create the backing USC resource or
map executable code. It is now a concrete input/output transformation to model
in an AO46-native carrier, but its dependencies still need their own resource
and virtual-memory contracts.

## Resource Binding Transition

Immediately after the first USC descriptor is packed, the compute path calls
`ComputeContext::bindBufferResourceToCommand(unsigned int index, bool write)`.
For both controls the measured inputs are `index = 0` and `write = true`.
The `two-buffers` control extends that result with a second resource: it calls
the same routine with `index = 1` and `write = false`.

The profiled function:

1. Selects an existing context-owned resource from a pointer table at
   `context + 0x57e8 + index * 8`.
2. Uses the resource's internal binding record at `resource + 0x20`.
3. Calls `IOGPUResourceListAddResource(active_list, resource + 0x20, 3)` for
   the observed writable binding.
4. Updates internal active/passive usage and coalescing tracking.

The second control call proves the flag relationship on this profile:

| Binding | Input `write` | Observed resource-list flag |
| --- | ---: | ---: |
| Output buffer at index `0` | true | `3` |
| Input buffer at index `1` | false | `1` |

The two resource records are distinct, and the associated USC descriptor is
byte-identical to the one-buffer baseline. Resource count and access mode are
therefore represented by the command resource table rather than this USC
descriptor for the tested kernel shape.

This is the missing connection between a command-specific descriptor and an
Apple resource list. It is **not** an import mechanism: the routine accepts an
index into Apple-owned context state, rather than an arbitrary resource record
or an Asahi BO pointer.

## What This Changes For AO46

- `[x]` The Apple compute carrier is no longer treated as a single opaque
  object. Its segment header, carrier body, compute subrecord, USC descriptor,
  and resource-binding transition have measured relationships.
- `[x]` AO46 can keep its neutral Asahi batch/resource package and derive a
  matching internal model: command segment, compute subrecord, descriptor
  inputs, and retained resource uses.
- `[~]` The raw Apple command-storage lifecycle and the resource table are now
  mapped only for the profiled public control. They are still Apple-owned state
  and cannot yet be safely constructed or adopted by AO46.
- `[ ]` Low-VA USC mapping and executable AGX-code residency remain separate
  blockers. The descriptor packer does not solve either one.
- `[ ]` Direct queue commit and live completion/fence delivery remain separate
  blockers. The public control proves their ordering, not an AO46 call ABI.

## Next Evidence Gates

1. `[x]` A two-buffer control correlates command indexes `0`/`1`, write/read
   intent, resource-list flags `3`/`1`, and distinct retained records.
2. Vary dispatch dimensions and local-memory pressure independently to classify
   every changing USC descriptor word as dispatch, pipeline, or finalization
   state.
3. `[x]` The storage segment closes before public queue lowering, whose
   returned descriptor is correlated with the live completion-token pair.
   `[x]` Repeated same-process controls with a second-capture intersection
   rule out a reproducible direct p4 resource-count or shader-control field
   for these workloads.
4. Correlate a controlled Asahi-style command/resource package with those
   remaining sidecar regions before attempting any raw carrier construction.
5. Derive a profile-gated AO46 command-carrier representation from these
   semantic observations. It must validate an Asahi batch/resource package
   before any future raw-UABI submission experiment.
6. Only enable a real submission path after resource ownership, USC/executable
   mapping, queue admission, and completion behavior are all independently
   demonstrated on the same profile.
