# Apple Private Winsys Map

Status: profile-specific research map for the direct AO46 Asahi-to-AGX path.
This document identifies the Apple-owned layers around the macOS AGX user
client. It does not copy Apple code, link AO46 to private implementation
classes, or make an undocumented constructor callable.

## Boundary

On the active G16X host, the relevant stack is:

```text
Metal public API
  -> AGXMetalG16X.bundle private winsys
     -> IOGPU.framework private generic layer
        -> IOKit AGXDeviceUserClient UABI
           -> AGX kernel driver and firmware
```

`AGXMetalG16X.bundle` is the private winsys between Metal's public objects and
the IOKit user client. It is not a reusable driver library for Mesa: its methods
consume Apple-owned Objective-C/C++ object graphs. AO46's direct route must
instead make Mesa/Asahi command records satisfy the lower IOKit UABI through a
small, profile-gated adapter.

## Observed Responsibilities

| Layer | Evidence on the active profile | Apple-owned responsibility | AO46 direct-adapter counterpart |
| --- | --- | --- | --- |
| Device bootstrap | `AGXG16SDevice initWithAcceleratorPort:` | Own accelerator port and private device state | `agx_macos_device_session_open` owns the IOKit connection and profile gate |
| Resources and VM | `AGXBuffer ... pinnedGPUAddress:`, `backingResource`, `resourceInArgs` | Construct resource objects, suballocate, assign GPU VAs | `agx_macos_bo` must eventually provide allocation, mapping, VM binding, and lifetime |
| Command records | `beginCommandBuffer`, `reserveKernelCommandBufferSpace:`, `fillCommandBufferArgs:` | Allocate and populate Apple command records/descriptors | Mesa Asahi remains the AGX command generator; AO46 needs only a proven command-carrier and resource binding contract |
| Queue commit | `commit:count:`, `noMergeCommit:count:options:commitFeedback:error:` | Collect command buffers, attach completion state, cross to IOGPU | AO46 needs a profiled queue ID, submit descriptor/carrier, and ownership transfer |
| IOGPU handoff | IOGPU queue/resource anchors and controlled traces | Translate private state into user-client selectors and Trap4 | AO46 keeps direct UABI work profile-gated; unknown records are not replayed |
| Completion | notification queue and public command-buffer controls | Consume completion records, retire private objects | AO46 maps proven queue/token pairs into Mesa fences and releases BO pins only after final completion |

## Procedural Command-Storage Seam

The active `AGXMetalG16X` binary imports a narrower procedural seam from
`IOGPU.framework`. These names are present in the driver import table:

```text
IOGPUMetalCommandBufferStorageBeginKernelCommands
IOGPUMetalCommandBufferStorageBeginSegment
IOGPUMetalCommandBufferStorageGrowKernelCommandBuffer
IOGPUMetalCommandBufferStorageEndKernelCommands
IOGPUMetalCommandBufferStorageEndSegment
IOGPUMetalCommandBufferStorageAllocResourceAtIndex
IOGPUMetalCommandBufferStorageAllocSidebandBuffer
IOGPUMetalCommandBufferStorageGrowSidebandBuffer
IOGPUMetalCommandBufferStorageMergeResidencySetList
IOGPUMetalCommandBufferStorageFinalizeResidencySetList
IOGPUMetalResidencySetListCreate / IOGPUMetalResidencySetListDestroy
IOGPUResourceListAddResource / IOGPUResourceListMerge / IOGPUResourceListMergeLists
```

This is the first concrete private-winsys candidate below the AGX Metal
Objective-C objects. It suggests Apple separates command bytes, sideband data,
resource list entries, and residency finalization before queue submission. The
names alone do not establish argument or ownership contracts, so AO46 must
profile each function from Apple-driven workloads before considering a direct
adapter. They are not called by the framework or Mesa integration.

`capture_agx_private_winsys_trace.sh` performs that first profiling step. It
runs the existing resource-bearing control and records only the entry registers
of these functions while Apple drives them. The active profile's two blit
submissions prove two storage `BeginKernelCommands` and `BeginSegment` calls,
two matching `EndSegment` calls, 26 resource-entry allocations, and 40
resource-list additions. The storage identity is distinct from the resource-list
identity. This workload does not reach the imported explicit end-kernel or
residency-finalization functions, so they remain candidate paths rather than
assumed lifecycle requirements. The capture does not call a private function
from AO46 or replay a captured command.

The first entry/return correlation tracks the storage operations without
inventing an ABI return. Read-only disassembly of `BeginSegment` shows it reads
and updates storage-owned segment state, initializes or grows a segment list,
and resets a storage-owned resource list. It does not write an ABI result to
`x0` after the internal reset call, so the nonzero `x0` seen at return is caller
residue, not a command-memory pointer. `AllocResourceAtIndex` likewise has no
usable pointer result in the observed trace. These operations must therefore be
modeled as storage mutations until an explicit data-buffer allocation function
is profiled. The caller chain is measured as Apple blit work to
`AGX::ContextCommon::newCommand`, then `IOGPUMetalCommandBufferStorageBeginSegment`.

The same read-only profile separates storage construction from command use:

```text
public command-buffer creation
  -> AGXG16X command-buffer constructor
     -> IOGPUMetalCommandBufferStorageCreateExt
        -> storage shared-memory setup
           -> BeginKernelCommands

Apple blit command encoding
  -> AGX::ContextCommon::newCommand
     -> BeginSegment
```

`BeginKernelCommands` creates and updates storage-owned segment-list metadata;
it is not a usable command-byte allocator by itself. Its growth helper depends
on an opaque Apple `IOGPUMetalDeviceShmemPool`. This confirms the direct adapter
must obtain an already initialized Apple carrier and use its procedural storage
operations; it must not reconstruct the carrier or its shared-memory pool. The
next contract to profile is the Apple-owned carrier handoff into the procedural
functions, followed by resource-list binding and queue commit.

The carrier handoff is now correlated in the resource-bearing control. One
`CreateExt` return becomes the storage used by both submissions; its same
resource-list address is reset before each segment. Each generic queue submit
has a 64-byte descriptor and auxiliary pointer that immediately reappear in
the matching Trap4 call. Descriptor and auxiliary addresses may differ between
serial submissions. The observed completion-token pair can recur in reverse
order only after both tokens of its prior queue submission have retired. A
future Asahi adapter must therefore key retirement on the queue and token
generation, never on descriptor or carrier pointer identity.

### Private Command-Buffer State: Identified Ownership Boundary

The command-buffer state required by the generic queue is now identified by
ownership and lowering behavior on the active G16X profile. It is an
Apple-owned `IOGPUMetalCommandBuffer` object together with an opaque
`IOGPUMetalCommandBufferStorageCreateExt` allocation. It is not a standalone
generic `IOGPUCommandBuffer` object: read-only Objective-C runtime inventory
finds no `IOGPUCommandBuffer`, `IOGPUCommandQueue`, or `IOGPUResource` class
on this profile, only their `IOGPUMetal*` counterparts.

The public empty-command-buffer control proves this transition twice in one
queue lifecycle:

```text
public MTLCommandBuffer
  -> Apple-owned IOGPUMetalCommandBuffer instance
     -> fillCommandBufferArgs:commandQueue:
        -> 64-byte generic queue descriptor + opaque auxiliary carrier
           -> IOGPUCommandQueueSubmitCommandBuffers
```

For each submission, the `fillCommandBufferArgs:` output pointer is exactly
the descriptor pointer received by the generic submit function. Generic submit
receives a null object-array argument, so it is consuming Apple-lowered data,
not a command-buffer pointer supplied by its caller. One storage object is
created before the first fill and remains cached across the two public command
buffers; each descriptor is retired only after its public completion. The
queue-contract analyzer enforces these pointer identities and lifecycle
ordering on every capture.

This finds the private state sufficiently to set an exact boundary, but not to
construct it. The four-workload profile records a non-null Apple command-buffer
object as `self`, an Objective-C selector in `x1`, a non-null argument-record
pointer in `x2`, and a non-null Apple queue object in `x3` for each fill. Its
`x2` value is the only fill value that crosses into generic submit, as that
submit's descriptor. There is no observed API that accepts an Asahi command
record in place of the Apple object. AO46 must therefore keep the carrier bridge
non-callable until an independent documented/import boundary is found. It must
not synthesize the object, storage allocation, or auxiliary carrier.

### Metal 4 Allocator Audit

The active SDK and runtime expose Metal 4 command allocators, queues, and
command buffers. Read-only Objective-C metadata shows that
`IOGPUMetal4CommandAllocator` can obtain and return an
`IOGPUMetalCommandBufferStorage` for `IOGPUMetal4CommandBuffer`; this is still
an Apple-owned object lifecycle. The supported `MTL4CommandAllocator` API
attaches allocator-owned memory to an `MTL4CommandBuffer` so that Metal
encoders can write commands. It does not accept an external AGX byte stream,
an Asahi command record, a resource-table import, or an arbitrary descriptor.

The active G16X import table contains procedural storage allocation, segment,
resource-list, and residency functions, but no `Import`, `Adopt`, or external
command-storage entry point. `IOGPUMetalIndirectCommandBuffer` is also a
Metal resource wrapper, not a raw AGX-command carrier. These results rule out
Metal 4 allocators and indirect command buffers as an Asahi injection path on
this profile; they do not rule out a future documented lower UABI.

`capture_agx_private_winsys_profile.sh` now verifies the procedural seam over
four Apple-driven public workloads. The current G16X profile records the same
ownership chain in each case:

| Workload | Submits | Command-resource entries | Result |
| --- | ---: | ---: | --- |
| Blit control | 2 | 26 | One cached storage object; bindings are materialized then reused. |
| Compute | 1 | 7 | One storage object; all command entries materialize Apple binding records. |
| Render | 1 | 17 | One storage object; all command entries materialize Apple binding records. |
| IOSurface render | 1 | 17 | One storage object; drawable work uses the same resource-list path. |

Every workload reaches the same Apple-owned `fillCommandBufferArgs:commandQueue:`
handoff before the generic 64-byte descriptor plus opaque auxiliary carrier,
then Trap4 and two completion records. The profile checker now proves that the
fill method's `arguments` pointer is the exact descriptor pointer of the next
generic submit, while generic submit's object-array argument remains null.
This ties resource-bearing work to the same Apple command-buffer lowering seen
in the empty control. It also rules out treating the generic queue entry point
as an external Asahi-record import boundary on this profile: no workload
exposes command-storage adoption or an Asahi-record import contract.

### Apple Resource Binding Boundary

The resource-bearing control now traces two paths inside
`IOGPUMetalCommandBufferStorageAllocResourceAtIndex`. The first materializes a
command resource through Apple-owned `IOGPUResourceCreate`, immediately queries
that resource's GPU virtual address, and returns a success/mode pair. The next
`IOGPUResourceListAddResource` call preserves the returned mode, but receives a
distinct address as its resource argument. That address is an
Apple-owned binding record, not the `IOGPUResourceCreate` result and not a Mesa
BO pointer. A later segment successfully reuses those binding-record addresses
without another resource-create or GPU-VA query.

The adapter boundary is therefore explicit:

```text
Asahi BO range
  -> Apple-owned resource allocation and GPU-VA resolution
  -> storage-owned binding record
  -> IOGPU resource-list entry
  -> Apple queue submission
```

`analyze_agx_private_winsys_trace.sh` enforces both paths for the control
workload. It rejects a missing resource creation or GPU VA on materialization,
a failed allocation result, a mismatched mode, a raw resource object where
Apple supplies the binding record, or a reused binding record that was not
previously materialized. It also rejects a binding record materialized more
than once and a mode change across later reuse, establishing its
storage-owned identity on the active profile. This does not authorize AO46 to
construct either private object: a future direct adapter must obtain both from
the Apple-owned allocation path.

The same analyzer now correlates materialized command resources with
IOGPUResourceRelease. Across the controlled blit, compute, render, and
IOSurface workloads, every traced materialized resource remains alive through
the single public workload-completion marker and is released afterward. This
is lifecycle-ordering evidence for Apple-driven work, not a permission for
AO46 to construct, bind, or release private resource records.

The combined capture also enables the existing public transport wrapper in
the traced process: each resource release is now checked against the two
observed descriptor completion tokens for every carrier in that exact trace.
This is still read-only observation; it does not turn either the wrapper or
the private command-storage interfaces into an AO46 submission path.

`IOGPUResourceGroupUpdateResources` is a separately imported procedural
symbol, so AO46 profiled it as the final non-Metal resource-carrier candidate.
It is not reached by the controlled compute, render, or IOSurface workloads;
each reaches the storage-owned resource-list path above instead. The inventory
keeps the symbol visible and the analyzer reports its call count, but zero
calls across these resource-bearing workloads mean it is not a command-carrier
constructor, adoption operation, or submission handoff on the active profile.

Mesa admission now accepts an active Asahi encoder span and resolves it through
the owning `struct agx_bo`. Its CPU-mapped resource record must be contained in
that same command BO, not merely overlap its GPU VA. This gives the future
carrier bridge one concrete ownership chain from Asahi command bytes through
the native BO lease, while still refusing to submit until the Apple carrier
contract is callable.

The existing submission lease maps a queue-bound pair of observed completion
tokens to one Mesa-facing retirement event. It keeps every referenced BO pinned
after submission and releases those pins only when both tokens arrive from the
same notification queue and API generation. Live notification records still
now enter the native and Mesa submission-package poll path directly. A foreign,
malformed, duplicate, or wrong-generation record remains unconsumed; the second
matching token clears carrier metadata and releases native plus Mesa BO
references. Mesa sync adoption now also requires the package to be bound to the
same current queue connection, queue ID, and API generation as the device
registry, so a separate queue cannot claim its retirement. A Gallium
`pipe_fence_handle` still needs to own this package once the native
`pipe_screen` can submit it. The macOS sync registry now permits one
queue-bound package to be owned by a unique group of output handles, so the
single native completion can retire both an Asahi batch's binary fence and
flush timeline fence together. Binary outputs explicitly rearm reusable batch
handles, while timeline outputs must advance monotonically after their prior
completion. The registry now retains multiple in-flight points for one
timeline: their packages may retire out of order, but only the contiguous
completed prefix advances the visible timeline. The
platform-neutral batch validator also rejects zero sync handles, invalid
binary/timeline values, duplicate outputs, and already-owned output handles
before it reaches the unavailable carrier import boundary.

The submission-package smoke now separately delivers one valid token, repeats
that token, and then delivers its peer. The repeated token is rejected while
the package and every BO pin remain live; only the distinct second token can
retire the package. This keeps duplicate completion delivery from collapsing
the two-token retirement model.

## What Is Reusable

Mesa/Asahi already supplies GL semantics, NIR lowering, AGX shader generation,
AGX command generation, and Gallium resource use tracking. AO46 should reuse
those upstream components unchanged wherever possible.

The Apple private winsys supplies the macOS-specific device, VM, queue,
submission, completion, and presentation infrastructure. It is evidence for
the shape and sequencing of the direct adapter, not source to embed or an API
surface to call from the framework.

## Current Direct-Winsys Position

- `[x]` Profile-gated direct AGX device session and capability query.
- `[x]` Test-only BO allocation/release contracts, API configuration, and
  notification queue lifecycle on the active profile.
- `[x]` Static ownership map of the AGX private winsys, including buffer,
  command-buffer, and queue-commit anchors.
- `[~]` Native Mesa batch admission: the macOS `agx_submit_info` consumer
  accepts only structurally valid compute/render work whose known stream,
  helper, sampler, and attachment ranges belong to the active direct BO set.
  `agx_batch_submit` now supplies the actual `batch->cdm.bo` or
  `batch->vdm.bo` source for every command, and the adapter rejects a native
  range unless it resolves to that same source BO and native handle. It
  now also accepts only binary and timeline sync handles that belong to the
  current Mesa device registry, rejecting a foreign handle or a binary sync
  with timeline data before carrier admission.
  Timestamp-bearing Asahi batches now also carry an explicit timestamp object
  handle and source BO. The adapter verifies that BO belongs to the active
  native set and that every command timestamp names a declared object; this
  does not construct an Apple timestamp object.
  Each finalized batch now also supplies its complete Asahi BO dependency set
  as a neutral resource table. macOS verifies every table entry and requires
  stream, helper, sampler, attachment, and timestamp BO references to be
  contained by it. The table and sync array remain live through optional trace
  decoding, fixing the previous trace-only use-after-free.
  The macOS `pipe_screen` factory now requires this neutral `submit_info`
  boundary rather than a non-null Linux `drm_asahi_submit` callback; the
  direct device exposes no Linux packet-submit operation.
  intentionally stops at `ENOTSUP` after that validation because it has no
  carrier-import operation.
- `[~]` Outer IOKit transport, descriptor shape, and queue/token completion
  association are observed by direct trace.
- `[ ]` A full direct queue/command-carrier lifecycle that accepts an Asahi
  batch, binds all resource objects, submits it, and retires a Mesa fence.
- `[ ]` `pipe_screen`, offscreen render/readback, CGL drawable integration,
  and staged CTS.

## Reproducible Inventory

Run:

```sh
OpenGL_4.6(Core Profile)/Apple_ICD/scripts/inventory_apple_agx_private_winsys.sh
```

It records the active AGX bundle hash, dynamic-library dependencies, IOKit
imports, procedural command-storage anchors, and selected private method names to
`/private/tmp/ao46-apple-agx-private-winsys` by default. It reads metadata from
the on-disk driver only. It does not copy a system binary, inject a process,
call a private method, or submit work.

## Direction

The project should treat direct IOKit/UABI work as the execution path and use
public Metal controls only for differential evidence that cannot yet be
obtained from the direct trace controls. We do not build another Metal
translation layer, and we do not make Mesa depend on `AGXMetalG16X` private
classes.
