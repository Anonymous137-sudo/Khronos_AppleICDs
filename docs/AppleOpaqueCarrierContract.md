# Apple Opaque Carrier Contract

Status: active, profile-gated reverse-engineering record for the direct AO46
Asahi-to-AGX path. This document describes observed call behavior on the
active G16X/macOS 26.5.2 profile. It is not an Apple API declaration. Runtime
code stays fail-closed: the only direct storage transition currently invoked is
an isolated developer smoke's paired no-resource begin/end lifecycle.

## Why This Exists

The final non-reverse-engineered search found no external command-storage
adoption or command-stream import operation. Resource-bearing compute, render,
and IOSurface controls all enter an Apple-created carrier before generic queue
submission. The direct work therefore proceeds by recovering the carrier
contract one verified piece at a time.

## Observed Storage Constructor

Read-only disassembly and three controlled workload captures identify the
entry currently named `IOGPUMetalCommandBufferStorageCreateExt`. Its observed
argument roles are:

| Register | Observed role | Status |
| --- | --- | --- |
| `x0` | Apple-owned device object | required, opaque |
| `x1` | Apple-owned storage-creation parameter record | required, 64-byte prefix captured |
| `x2` | stored in carrier-owned state | opaque |
| `x3` | selects a second resource-list pool in observed controls | boolean-like, profile-gated |

The constructor allocates an internal 928-byte carrier, initializes an
internal resource-list, retains/creates its own resource-list state, and then
initializes command shared memory. It returns null on setup failure and uses
an Apple-owned cleanup path. AO46 must not allocate this carrier directly.

## Observed Parameter Prefix

The constructor reads the following fields from the captured `x1` record:

| Offset | Observed use | Status |
| --- | --- | --- |
| `0x00` | passed to the first Apple shared-memory-pool allocation call | required opaque reference |
| `0x08` | passed to the second Apple shared-memory-pool allocation call | required opaque reference |
| `0x10` | captured but not classified by the constructor/setup path inspected so far | unknown |
| `0x18` | retained as the carrier's current resource-record base when the count is nonzero | required opaque reference |
| `0x20` | 32-bit resource-record count; all three controls observed `44` | measured scalar |
| `0x28` | source resource-list pool when `x3` is nonzero | required opaque reference |
| `0x30` | source resource-list pool for the primary carrier list | required opaque reference |
| `0x38` | captured but not classified by the constructor/setup path inspected so far | unknown |

The allocation size for the carrier's current resource records is
`count * 0x40`; the measured count produces a 2816-byte Apple-owned array.
This establishes an internal record stride, not an AO46 resource-record ABI.

## Recovered Ownership Chain

```text
Apple device
  -> two Apple shared-memory pools
  -> Apple-owned command storage
     -> shared command allocations
     -> Apple resource-list pools
     -> 44 x 0x40-byte current resource records
     -> Apple descriptor/carrier lowering
     -> queue commit and completion tokens
```

Mesa/Asahi owns the AGX command bytes and neutral BO dependency table before
this boundary. The carrier constructor requires Apple-owned pool and
resource-list references that AO46 cannot presently obtain through a direct
UABI contract.

## Executable Carrier Bootstrap

The profile-gated `AppleAGXOpaqueCarrier` bridge now retains the Apple device's
raw storage-pool pointer through runtime metadata, obtains a fresh global trace
ID, calls the observed storage-pool factory with `retainedReferences=1` and
`synchronousDebug=0`, and returns the result through Apple's storage
deallocator. The smoke validates creation and teardown only. It does not write
command bytes, bind a resource, invoke a queue, or submit work to the GPU.

This is an Apple-owned carrier, not a copied layout: the pool constructs the
928-byte storage, its shared-memory allocations, resource-list state, and
cleanup state internally. AO46 stores only the opaque returned pointer and its
trace ID while the remaining mutation contract is recovered.

The no-work smoke now reads the profile-gated table fields and proves an
important lifecycle distinction: a carrier returned directly by the storage
pool has no slot table yet. Apple initializes the non-null record base, slot
descriptor table, and 44-slot count later in its command-buffer initializer.
The matching public compute capture proves that, after that initialization,
the selected slot descriptor is the exact input to
`IOGPUMetalResourcePoolCreatePooledResource`; the returned Apple-owned pooled
resource appears at offset `0x20` of that slot's `0x40` record. AO46 still has
no Mesa-BO-to-Apple-slot allocation policy and makes no resource-pool call.

## Initializer Boundary

The public compute and two-submit controls now capture this verified ordering:

```text
IOGPUMetalCommandBuffer initWithQueue:retainedReferences:synchronousDebugMode:
  -> IOGPUMetalCommandBufferStoragePoolCreateStorage
  -> IOGPUMetalCommandBufferStorageCreateExt (first use only)
  -> configured command storage
  -> BeginKernelCommands / resource-slot allocation
```

On the active profile, the public initializer carries an Apple command queue
plus `retainedReferences=1` and `synchronousDebug=0`. The control workload
uses two command buffers but observes one `StorageCreateExt` result returned by
two storage-pool factory calls, proving storage reuse is Apple-managed. Each
of the 26 slot admissions still calls the resource-pool factory; 13 entries
materialize a raw Apple resource while the other 13 reuse their existing
binding identity. AO46 must therefore recover or obtain the Apple command
buffer/queue lifecycle before it can reach an initialized carrier. It must not
attempt to synthesize the 44 descriptors or reset their records.

The runtime metadata gate also identifies the ownership seam without invoking
it: `IOGPUMetalCommandQueue` contains a raw generic-queue pointer at offset
`680`, while `IOGPUMetalCommandBuffer` contains its raw storage pointer at
offset `712`. The probe now requires the initializer type encodings to remain
available. These fields are evidence for a profile gate, not permission to
manufacture either Objective-C object or write through their pointers.

`AppleAGXConfiguredCarrierSmoke` now verifies the usable no-work bootstrap:
Apple's public queue and command-buffer factories create the internal queue,
command-buffer object, and configured storage; AO46 then reads the storage
pointer through the profiled metadata and confirms all 44 descriptors exist.
This uses the Apple factory only for object ownership. It does not create a
Metal encoder, translate an OpenGL command, bind an AO46 resource, commit the
buffer, or submit GPU work.

## Segment Entry Boundary

The active G16X backend does not invoke the Objective-C `beginSegment:` method
for the captured compute or two-submit controls. Instead it calls
`IOGPUMetalCommandBufferStorageBeginSegment` directly once per submission.
The call's second argument is an Apple-created kernel-command pointer exactly
`0xac` bytes after the base returned by
`IOGPUMetalCommandBufferStorageBeginKernelCommands`. The trace verifier now
enforces that relationship over both workloads before accepting any subsequent
resource-slot allocation. This identifies the segment-entry input as
Apple-owned command memory, not an Asahi stream pointer or a descriptor AO46
may synthesize.

`AppleAGXConfiguredCarrierKernelCommandsRead` now retrieves that command
range through the exact profiled Objective-C getter encoding rather than a
guessed offset. The active profile reports a 16 KiB range with the cursor at
`start + 0xac`. `AppleAGXNoResourceSegmentSmoke` then calls precisely one
`BeginSegment(storage, current)` / `EndSegment(storage)` pair in an isolated
process. It verifies that the 44-slot table remains initialized afterwards;
it admits no resources, writes no command bytes, commits no queue, and does
not cause GPU execution.

## Resource Descriptor Provenance

A public compute control now logs two buffer identities and GPU VAs before
tracing each Apple-driven `IOGPUResourceCreate` input. The capture contains
29 total 104-byte resource-create records, including seven records reached
through carrier-slot materialization. Neither public `MTLBuffer` object
identity nor either public GPU VA occurs directly in any captured record.

That is a useful negative result: a carrier descriptor is not a shallow
`{ gpu_va, size }` record, so a direct AO46/Mesa BO must not be copied into
one. The remaining relationship is an Apple-owned wrapper or subobject held
indirectly by the descriptor graph. The automated
`verify_agx_resource_descriptor_provenance.sh` gate enforces this fact for the
compute control before a trace is accepted.

The follow-up public-buffer blit control recovers the first usable ownership
handoff. For both source and destination, the resource list consumes
`IOGPUMetalBuffer + 0x40` exactly once. It does **not** consume
`resourceRef + 0x40`: `resourceRef` identifies the lower generic IOGPU
resource, while the buffer-relative address is the Apple-owned list-binding
view. `AppleAGXMetalResourceRef` profile-gates this relationship using the
runtime `_res` metadata and exposes it only as a borrowed pointer. The
automated `verify_agx_public_buffer_binding_trace.sh` confirms the two real
list admissions under a completed blit.

This is a binding path for an existing Apple-owned `MTLBuffer`; it cannot be
attached to a separately allocated raw selector-9 `agx_macos_bo`, because the
two allocations have different GPU VAs and lifetimes. The direct path remains
useful for UABI observation, but is not a carrier-resource identity.

`AppleAGXCarrierResourceBindingSmoke` now proves that narrow handoff directly:
it creates a configured carrier, retains one public shared buffer, reads its
borrowed binding view, begins one storage segment, invokes
`IOGPUResourceListAddResource(storage + 0x90, buffer + 0x40)`, and ends the
segment. The smoke neither allocates an Apple descriptor nor writes AGX bytes,
commits a queue, or submits work.

## Apple-Owned Mesa BO Provider

The Mesa-BO ownership gap is now closed for CPU-visible ordinary BOs. The
optional `AppleAGXMetalBOProvider` is attached before the first Mesa allocation
and makes a public Apple `MTLBuffer` the lifetime root of that `agx_bo`. It
returns the same allocation's CPU mapping, public GPU VA, and profile-verified
`IOGPUMetalBuffer + 0x40` carrier binding to the C-only Mesa adapter. Its
process-local `uapi_handle` is intentionally only a Mesa identity, never an
Apple resource handle.

`AppleAGXMesaBOCarrierBindingSmoke` proves the complete no-submit slice on the
active profile:

```text
Mesa agx_bo allocation (64 KiB, CPU-visible)
  -> retained Apple MTLBuffer allocation
  -> matching GPU VA and CPU mapping
  -> validated IOGPUMetalBuffer + 0x40 binding
  -> IOGPUResourceListAddResource during one balanced carrier segment
  -> Mesa BO teardown releases the same Apple allocation
```

This is an allocation and resource-list bridge, not Metal command translation.
It does not create a Metal encoder, copy Asahi command bytes into a Metal
command buffer, commit a queue, or submit GPU work. The provider accepts only
ordinary CPU-visible BOs. Its ABI declares CPU-mappable data, USC low-VA, and
executable-code capabilities separately: an Apple public buffer exposes only
the first. Low-VA and executable shader BOs remain unavailable until their
distinct UABI contracts are proven, so this does not unblock `pipe_screen` or
CTS by itself.

## Static Carrier Reconstruction

The current G16X IOGPU component was imported directly from the active dyld
shared cache into Ghidra. The carrier subgraph was reconstructed from C-style
pseudocode and direct caller/callee relationships only; this pass did not use
runtime tracing or invoke any private API.

The resulting ownership and lowering path is:

```text
Apple command-buffer / command-allocator
  -> Apple command storage and its shared-memory pools
  -> BeginKernelCommands / BeginSegment
     -> reset active Apple resource list
     -> materialize resource-pool entries in 0x40-byte storage records
  -> EndSegment / storage finalization
  -> fill Apple queue-argument record
  -> generic IOGPU queue submit
```

`BeginKernelCommands` transitions the storage between kernel-command and
segment-list header modes, retaining cursor-relative offsets in storage-owned
shared memory. `BeginSegment` then initializes a segment-local Apple resource
list and descriptor range. `EndSegment` closes the record and advances the
next resource-group cursor. Storage growth allocates a larger Apple shared
memory object, copies the previous contents, rebases every storage cursor,
and resets the active resource list. These operations prove that the shared
memory lifetime and rebasing policy are part of the storage contract, not an
independent command-byte allocation API.

`AllocResourceAtIndex` accepts only a bounded index into an Apple-initialized
slot table. It asks an Apple resource pool to create a pooled resource, stores
that object in the slot's 0x40-byte record, and derives the other record fields
from the resulting Apple resource. It does not accept a GPU VA, size, raw BO,
or external command-resource record. An AO46 Asahi BO therefore cannot be
substituted for a slot record by copying fields.

## Resource Pool Owner Construction

The centre-of-gravity static pass now identifies where the slot classes
originate. On the active G16X profile, the AGX device's
`setupHWResourcePools` routine prepares a fixed vector of 44 hardware resource
pool entries. `AGXG16XFamilyCommandAllocator_mtlnext::initResourcePools:`
passes that exact vector and count to the Apple command allocator's one-time
`setHwResourcePool:count:` setup. This joins the previously recovered
44-descriptor carrier table to its owning device-level constructor chain.

The device routine derives the pool policy from Apple-owned default argument
tables and applies a profile-selected data-buffer cacheability override before
a bounded 44-entry jump table selects one of eight construction templates. All
eight templates converge on the same private pool initializer,
`initWithDevice:resourceClass:resourceArgs:resourceArgsSize:options:`. Each
iteration supplies a selected resource class, a 104-byte new-resource argument
record, and the policy selected for that slot before storing the resulting
Apple-owned pool in the vector.

This resolves the factory structure: it is not an unbounded indirect call or a
record layout AO46 must invent. The still-open question is semantic: which of
the eight templates, if any, corresponds to the dedicated low-VA executable
shader-residency class, and which queue/authorization state it requires. The
constructor remains private and is not an AO46-callable API.

The matching IOGPU reconstruction closes the other half of the lifecycle:
`IOGPUMetalResourcePoolCreatePooledResource` reuses a compatible idle native
resource under its own lock or creates one through the generic Apple resource
constructor with the pool-owned device/options/argument configuration. It then
records pool generation and ownership before returning the resource to the
slot. The release path returns a compatible resource to the pool or destroys
it through the same Apple-owned lifetime chain.

```text
AGX device policy tables
  -> setupHWResourcePools (44 slot classes)
  -> command allocator setHwResourcePool:count:
  -> carrier slot admission
  -> IOGPU pooled-resource reuse or generic native-resource construction
  -> generation-aware pool retirement
```

This is significant because it narrows the remaining constructor work to the
device-side factory and each slot class's complete configuration. AO46 must
reconstruct that creation path coherently before it can admit a raw retained
BO; it cannot supply an `IOGPUMetalResource` after slot admission or fabricate
the current-record fields.

At commit, the legacy path finalizes storage before queue lowering. Its
`fillCommandBufferArgs:commandQueue:` method emits shared-memory identifiers
and Apple-owned scheduled/completed callback blocks into the per-command
queue-argument record. The generic queue submit receives an array of these
records with a device-selected stride, and selects the short Trap4 transport
only for a single record below the generic size threshold. The descriptor is
therefore a transport envelope; it is not the command-storage or resource-list
format.

The MTL4 path reaches the same conclusion independently. It requires both an
Apple command allocator and Apple command storage, finalizes storage, attaches
completion state retaining the allocator, storage, generation, and submission
ID, then asks the command buffer to fill its queue record before generic queue
submission. No function in this reconstructed chain accepts an arbitrary
CDM/VDM byte stream, a raw Asahi BO, or an externally constructed resource
record.

This closes the descriptor-format ambiguity but not the carrier-import gate:
AO46 now knows exactly which state remains Apple-owned. Any future direct UABI
implementation must reproduce the complete shared-memory, segment, resource
pool, finalization, and completion lifecycle coherently; it cannot safely
insert an Asahi stream at the queue descriptor boundary.

## Shared Memory And Allocator Lifecycle

A static Ghidra pass over the active IOGPU image now reconstructs the owning
shared-memory-pool and MTL4 command-allocator lifecycles. The reports remain
outside the repository and this section records only the resulting behavioral
contract; it does not declare a callable Apple interface.

An Apple shared-memory pool serializes reuse under its own lock. Its create
path either reuses a compatible cached `IOGPUMetalDeviceShmem` object or asks
the Apple device to create a new one with the pool's configured size and type.
The resulting shared-memory object owns a nonzero device allocation identity,
CPU-visible address, and size, and destroys that device allocation during its
own teardown. A larger requested pool size evicts incompatible cached objects;
release returns eligible objects to the pool rather than treating them as
independent byte buffers. Storage growth and rebasing must therefore retain
this pool ownership rather than substituting an AO46 allocation.

The MTL4 allocator is similarly an Apple-owned lifecycle. Its device factory
constructs an allocator aliased to the device pools, while its resource-pool
vector is immutable once storage creation parameters have been populated.
Storage acquisition records the allocator's busy state. Completion returns a
storage object to that allocator only when the completion carries the live
allocator generation; stale generations are not recycled into the new
allocator state. The Apple callback chain retains the allocator, generation,
storage, and submission identity together.

This is a concrete ownership milestone: command storage cannot be safely
created from a copied parameter record, nor can completion be represented by a
bare queue token. The remaining direct work is now limited to recovering the
allocator base-configuration inputs, resource-pool creation policy, and a
valid admission path for AO46-owned command and resource data.

## Storage Admission Layout

The direct static layout pass maps command storage as four cooperating
Apple-owned regions, rather than a single opaque command byte buffer:

| Region | Construction role | Admission constraint |
| --- | --- | --- |
| Kernel-command shared memory | Owns the command header, command cursor, and bounds. | Obtained from the first configured Apple shared-memory pool. |
| Segment-list shared memory | Owns segment headers, descriptor groups, and active segment state. | Obtained from the second configured Apple shared-memory pool. |
| Command-resource slot table | Holds a bounded set of Apple pool classes and their materialized resource records. | A slot index selects an Apple resource pool; a raw GPU address or BO is not accepted. |
| Residency output | Receives the finalized retained-resource group identifiers. | It is reset for each segment and only finalized after Apple resource admission. |

Fresh storage initializes all four regions as one transaction. If the second
shared-memory acquisition fails, it returns the first allocation through the
same pool path and destroys the incomplete storage. Reused storage resets its
resource-list state before reacquiring shared memory. This maps the critical
partial-failure cleanup edge that was previously unknown.

Normal retirement is now mapped as well. Storage updates the trim level of
every active shared-memory region, resets the resource and segment state, then
returns itself to its owning storage pool when the pool accepts it. The terminal
free path destroys the generic resource list, releases current and extra
resources, releases Apple list-pool state, and only then frees the storage
allocation. This makes reuse, purge, and final destruction distinct states in
the lifecycle.

Resource admission is now equally concrete. An index is bounds-checked against
the configured slot count, its matching Apple resource pool creates a pooled
resource, and the storage record is populated from that returned resource's
Apple-managed identity, address range, and allocation metadata. Segment
finalization emits the retained-resource identifiers only after enforcing its
two-group limits. Therefore an AO46 BO cannot be encoded as a synthetic slot
record even if its GPU VA and size are known.

The generic resource-list object owns independently allocated indexing and
deduplication state. A segment reset replaces its descriptor-region bounds,
clears its indexed residency state, and rejects regions outside the active
shared-memory range. This rules out treating an Asahi dependency array as the
Apple resource-list payload: it must first become a set of admitted Apple
resources.

The address-range buffer initializer is also statically mapped. It initializes
an Apple new-resource argument block from the address-range array and then
enters the generic Apple resource constructor. This is a construction branch,
not an after-the-fact raw-resource import: a direct implementation still needs
the complete Apple device, address-range ownership, and new-resource argument
policy that precedes the generic constructor.

## Next Reverse-Engineering Gates

- `[x]` Identify the carrier constructor and the fields it reads directly.
- `[x]` Measure the storage parameter prefix across compute, render, and
  IOSurface workloads.
- `[x]` Recover the command-buffer storage-pool factory chain and create/return
  a carrier through its Apple-owned lifecycle.
- `[x]` Establish the initial carrier lifetime and cleanup path with a no-work
  hardware smoke.
- `[x]` Verify the pool-created carrier's unconfigured state and the separate
  Apple-descriptor-to-pooled-resource record chain under a public compute
  workload.
- `[x]` Verify that the Apple command-buffer initializer configures and safely
  reuses the carrier across two public submissions.
- `[x]` Obtain an initialized 44-slot carrier through the profile-gated
  Apple-owned queue/command-buffer factory lifecycle, without submission.
- `[x]` Recover and verify the Apple-owned kernel-pointer contract for the
  direct storage-level segment transition.
- `[x]` Obtain the active kernel pointer from the configured carrier through
  a profile-gated getter and exercise a paired no-resource begin/end segment
  smoke.
- `[x]` Establish an Apple-owned allocation policy for CPU-visible Mesa BOs:
  one retained Apple allocation now supplies the Mesa BO's GPU VA, CPU mapping,
  teardown root, and carrier resource-list binding without fabricating a
  descriptor.
- `[x]` Statically reconstruct the command-carrier path from Apple storage
  setup through segment/resource-record handling, queue-argument lowering,
  and generic queue submission. The result proves descriptor-versus-storage
  ownership and rules out a shallow raw-stream or raw-resource insertion.
- `[x]` Reconstruct the shared-memory pool's create, reuse, resize, release,
  and device-allocation teardown lifecycle. Its allocations remain
  Apple-owned, pool-managed objects.
- `[x]` Reconstruct MTL4 allocator ownership: device-pool aliasing,
  one-time resource-pool-vector setup, busy-storage accounting, and
  generation-gated completion retirement.
- `[x]` Map storage admission as a transactional two-shared-memory,
  slot-table, and residency-output lifecycle, including its first-allocation
  failure cleanup, pooled retirement/terminal free split, and per-segment
  resource-list reset/finalization rules.
- `[x]` Map the address-range resource constructor branch through generic
  resource creation. It confirms that address ranges require an Apple-owned
  new-resource construction policy rather than a shallow BO wrapper.
- `[~]` Separate the provider ABI's data, low-VA, and executable capabilities,
  and capture public shader-compilation/pipeline allocation classes with a
  no-submit differential control. The current trace identifies allocation
  classes but does not prove an externally allocatable USC range or executable
  authorization, so do not force those flags through an ordinary public
  allocation.
- `[x]` Identify the device-owned resource-pool vector and allocator handoff:
  the active profile constructs 44 slot classes in `setupHWResourcePools` and
  attaches them once through `setHwResourcePool:count:`.
- `[x]` Reconstruct the pool-factory control flow: the 44 slots select eight
  bounded construction templates, all converging on the private native
  pool-initializer with a selected resource class and 104-byte argument record.
- `[~]` Assign semantic roles to the eight construction templates. Their
  control flow, cache-policy input, and common construction lifecycle are
  known; low-VA, executable, pipeline, and ordinary-data class meanings are
  not yet proven and must not be inferred from the raw policy values.
- `[~]` Recover the heap and allocator base-configuration inputs before
  treating procedural storage operations as a direct UABI surface. Allocation,
  rebasing, teardown, callback ownership, and the device-level pool owner are
  now mapped, but the final construction inputs remain Apple-owned.
- `[ ]` Drive an Apple-owned shader-residency workload through the dedicated
  class, then prove its mapping, failure cleanup, and retirement behavior
  before considering direct AO46/Asahi resource admission.
- `[ ]` Recover descriptor lowering and queue commit inputs for an admitted
  carrier.
- `[ ]` Connect its live completion records to the existing Mesa fence package.

The runtime remains fail-closed until every unchecked gate has a controlled
hardware smoke test on this exact profile.
