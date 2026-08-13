# Apple Native AGX Bridge Plan

Status: preferred macOS platform direction. The first bounded bridge bootstrap
is implemented and tested on the active G16X profile: it retains Apple's
opaque generic device reference and resolves the observed generic C symbols.
The existing direct-UABI research implementation remains a fail-closed
fallback. A supported Apple-owned allocation broker now retains public
`MTLBuffer` objects and their public GPU VAs, but no generic resource, queue,
submission, or Mesa screen bridge is claimed.

## Goal

AO46 uses Mesa OpenGL and Mesa Asahi as the complete OpenGL 4.6 and AGX
rendering implementation. Instead of recreating macOS GPU VM, queue,
submission, synchronization, and firmware-facing machinery, AO46 should reuse
Apple's existing AGX userspace infrastructure through the lowest practical
boundary.

```text
OpenGL.framework / CGL / NSOpenGL
  -> AO46 framework runtime
  -> Mesa OpenGL and state tracker
  -> Asahi Gallium, compiler, libagx, AGX command generation
  -> AO46 Apple-AGX ABI adapter
  -> Apple AGX userspace infrastructure
  -> IOGPU user client
  -> Apple AGX kernel driver, firmware, and GPU
```

The target is below Apple Metal command encoding and above the IOGPU user
client. AO46 must not translate OpenGL to Metal, compile to MSL, or send work
through a Metal rendering backend.

## Adapter Contract

The only AO46-specific runtime layer at this boundary is an adapter with these
conceptual operations:

```text
open_device(profile)
create_context(device)
allocate_resource(context, allocation_properties)
map_resource(resource)
create_queue(context)
submit(queue, asahi_command_records, resource_uses)
wait_or_poll(completion)
retire_resource(resource)
```

It adapts Mesa/Asahi objects into validated Apple-side objects. It must not
reimplement GL semantics, AGX compilation, AGX command generation, GPU virtual
memory policy, firmware protocols, or scheduling.

## Acceptance Gate

The Apple-native route becomes usable only after one specific macOS/AGX profile
has controlled evidence for every operation below:

- Device and context ownership can be created and destroyed safely.
- One Apple-side resource has stable allocation, mapping, and GPU-VA behavior.
- One Asahi-owned command record is accepted without a Metal command encoder.
- Submission produces a matching completion/fence event.
- A resource remains retained until completion, then retires correctly.
- Device loss and a mismatched OS/GPU profile fail closed.

The proof workload begins with offscreen clear/readback. Presentation and CTS
are not admission tests for the bridge itself.

## Evidence Rules

Static names in `AGXMetal*.bundle`, IOGPU, or private framework metadata are
research leads, not an ABI. A candidate operation needs all of the following:

1. A local hardware/OS inventory from `inventory_apple_agx_stack.sh`.
2. A controlled `wrap.dylib` trace that varies one input at a time.
3. A stable relationship between the operation, its objects, and its IOKit
   effects on that exact profile.
4. A minimal AO46 adapter implementation with a hardware smoke test.

Apple private binaries are not copied, linked into AO46, redistributed, or
called through guessed Objective-C object layouts. The investigation seeks a
callable system boundary, not a dependency on private implementation objects.

`AppleAGXNativeBridgeSymbolProbe` is the first loader-level gate. It resolves
the dynamically observed `IOGPUCommandQueueSubmitCommandBuffers` anchor from
the active shared-cache image and verifies its image and name, but never calls
it. Profiles that do not expose that exact anchor are skipped; a resolved
address does not establish a function signature or authorize runtime use.

`AppleAGXNativeBridgeRuntimeProbe` then records the Objective-C type metadata
for `IOGPUMetalCommandQueue submitCommandBuffers:count:` without creating an
object, reading an ivar, or invoking the method. This limits the next evidence
step to a declared call shape rather than a guessed private object layout.
The current G16X encoding, `v32@0:8^@16Q24`, requires an array of Apple
command-buffer objects. The underlying C submit anchor also begins by checking
its first argument as a CoreFoundation object. Therefore neither entry is an
AO46 submission API yet: a Mesa/Asahi command record cannot be passed to it
without inventing private object state, which the project explicitly forbids.
The runtime probe treats any different encoding as an unsupported profile and
skips it rather than accepting a potentially incompatible command contract.
Set `AO46_AGX_BRIDGE_DISCOVER=1` for a bounded, read-only inventory of the
candidate IOGPU command/resource classes and their declared methods. The
inventory never creates an object or reads an ivar; it exists only to determine
whether a non-Metal command carrier is discoverable before work is spent on an
adapter design. On the current G16X profile, that check finds no generic IOGPU
queue, command-buffer, or resource class: the available classes are
`IOGPUMetal*` subclasses of Metal base classes. That Objective-C path is not
admissible for Asahi command records. However, the loaded image separately
exports generic C anchors for resource creation/GPU-VA and command-queue
creation/submission, device creation, and command-buffer storage creation. The
symbol probe now gates that candidate C boundary. Controlled traces establish
the generic-device constructor records and the C submit handoff of the 64-byte
descriptor plus auxiliary carrier. It remains research-only until ownership,
the complete typed contract, and a safe AO46 operation are verified.

The device-bootstrap decision is now explicit and implemented. On the
trace-validated G16X profile, `AppleAGXNativeBridge` retains
`MTLCreateSystemDefaultDevice`, verifies that it is an `IOGPUMetalDevice`,
verifies the exact `deviceRef` encoding (`^{__IOGPUDevice=}16@0:8`), and
retains the returned opaque generic device reference. It also resolves the
observed generic resource, queue, command-storage, and submission symbols
from IOGPU.framework and verifies their image provenance. The bridge does not
call `IOGPUDeviceCreate`, create a Metal command encoder or command buffer,
create a generic resource or queue, or submit GPU work. Its only purpose is to
give the forthcoming C adapter an Apple-owned device root without guessing an
object layout. `AppleAGXNativeBridgeBootstrapSmoke` proves open, current, and
teardown lifecycles on the active profile.

`capture_iogpu_resource_constructor.sh` is the BO and lifecycle evidence tool.
It is not linked to AO46: a public-Metal control allocates duplicate shared
4 KiB, shared 8/16/32 KiB, shared 128 KiB, private 4 KiB, and write-combined
4 KiB buffers, then
LLDB records the generic `IOGPUResourceCreate` and `IOGPUResourceRelease`
frames Apple uses. The script binds its breakpoints only after IOGPU has
loaded, so it does not rely on an address from another process or invoke a
private symbol from AO46. Capturing frames is evidence for a typed adapter; it
does not enable either function in the runtime.

On the active G16X profile, the current control records seventeen constructor calls
with one stable generic device reference and exact 104-byte (`0x68`) argument
records. Sixteen calls return distinct generic resource pointers, while the
bounded oversized request returns null; all sixteen later release calls consume
exactly the successful pointer set when the public buffers are destroyed. This
proves the observed generic create/return/release ownership loop without AO46
calling any private function.
The same public-Metal control calls `IOGPUResourceGetGPUVirtualAddress` for all
16 returned resource pointers and receives a nonzero GPU virtual address for
each. Thirteen addresses are unique: some separate Apple resource objects share a
GPU VA. The verifier treats that as an object-lifetime rule, not an AO46
aliasing policy. In particular, AO46 must not use a GPU VA or raw allocation
handle as a substitute for a generic resource object's retain/release identity.
The capture also records ARM64 `x3..x7` on every constructor entry. Those tail
registers are intentionally classified as observed-but-uncallable until
controlled variation or a stable declaration proves whether they are part of
the function contract or caller scratch state. The current host's read-only
disassembly shows `IOGPUResourceCreate` saves only `x0`, `x1`, and `x2` before
overwriting the tail registers. The public control also proves that the same
`IOGPUMetalDevice` `deviceRef` retained by `AppleAGXNativeBridge` is exactly
the `x0` generic device root for every constructor call. This establishes an
observed three-argument constructor boundary, but does not authorize AO46 to
call it: the 104-byte input record still has unclassified fields and needs a
typed construction policy. The workload did not call
`IOGPUResourceGetGPUVirtualAddressLength`, so its return contract remains
unmeasured. One record class repeats as a duplicate-shared baseline and differs
only at byte `0x39`, so that byte is explicitly treated as opaque address
churn. The shared 4 KiB, shared 128 KiB, and private 4 KiB comparable records
are byte-identical, demonstrating that those high-level inputs do not map
directly to that record under Apple allocation/suballocation policy. The
write-combined comparison proves one semantic: the 64-bit word at offset `0x00`
contains `attributes.write_combined` with mask `1 << 42`. The other changed
bytes, including `0x60..0x63`, remain opaque until a controlled input proves
their meaning.

The expanded public-Metal size series now covers 4 KiB, 8 KiB, 16 KiB, 32 KiB,
and 128 KiB shared buffers. On the profiled host, records grouped by the
observed token `70040000` are data-bearing resource objects: their nonzero
CPU-data pointer, data size, resident-data size, and GPU-VA range length all
equal the little-endian 64-bit value at record offset `0x48`. The verifier has
measured direct values `0x4000`, `0x8000`, and `0x20000`. Records grouped by
the observed token `300c0000` instead have a zero CPU-data pointer, nonzero
data/resident sizes, and may share or be offset within a data-bearing object's
GPU-VA range. These tokens are evidence grouping keys, not public Apple type
names, and the record value is an allocation-object size, not necessarily the
logical public buffer size: 4 KiB and 8 KiB buffers are suballocation objects
in this trace while 16 KiB and 32 KiB create direct data-bearing objects.

This closes the size and object-role portion of the mapping policy, but not
typed resource construction. The `0x60..0x63` tail's construction semantics,
private partial-failure cleanup, and a writable generic-resource
mapping/coherency policy remain unproven. AO46 therefore keeps
`IOGPUResourceCreate` and related private entry points resolve-only and does
not build or invoke a 104-byte record at runtime.

Two equal 16 KiB direct shared allocations now produce byte-identical 104-byte
records, including `0x60..0x63`, despite returning distinct resource objects,
CPU-data pointers, and GPU VAs. At the same size, a write-combined allocation
changes only the known attribute byte `0x05`, not the tail. In contrast, the
two direct allocations immediately after the observed null return each differ
from their predecessors only at `0x60..0x63`. The tail is therefore
allocator-owned opaque metadata, not a per-object identity, a cache-mode field,
or a value AO46 may synthesize. Every observed
non-data-bearing resource object now also has exactly one containing
data-bearing GPU-VA range, with measured offsets of `0`, `0x1000`, or `0x2000`.
The record's little-endian fields at `0x38` and `0x40` equal, respectively, the
public CPU mapping pointer and that backing object's CPU-data pointer in every
observed case. This is a profile-gated record/pointer link, not permission to
construct either object.

Three fresh-process captures repeat the same tail sequence. A debugger-only
`IOConnectCallMethod` trace now verifies that every one of the 17 constructor
records reaches IOKit selector `9` with the identical argument pointer, byte
count, and all 104 bytes. Profile disassembly shows the exported constructor
passes that record to selector `9` without reading the input tail itself. The
tail is therefore a kernel-facing input boundary. Completing its construction
semantics requires an Apple-owned allocator path or a documented kernel UABI;
there is no safe user-space value to infer or replay into AO46.

`AppleAGXMetalAllocation` is the now-proven Apple-owned allocation path. It
uses only `MTLDevice newBufferWithLength:options:`, retains the resulting
`MTLBuffer` as the allocation lifetime authority, records its public
`gpuAddress`, and exposes `contents` only for public shared/write-combined
allocations. A fresh constructor capture proves all thirteen public buffers'
`gpuAddress` values exactly match a generic resource GPU VA from the same
allocation phase. `AppleAGXMetalAllocationSmoke` validates shared and private
64 KiB allocation, address identity, CPU mapping admission, and teardown on
the active profile. This is an allocator and GPU-VA handoff, not a Metal
rendering backend: it does not expose the private generic resource pointer,
bind an Asahi record into the Apple resource sidecar, or submit a command.

`AppleAGXMetalResourceSet` now connects that supported allocation path to the
separately observed Mesa/Asahi resource-record layouts. It owns a bounded set
of public allocations, derives GPU-VA ranges only after full containment
checks, and pins the record allocation plus every bound resource in a
copy-safe lease before it writes the verified blit or compute address slots.
The hardware smoke proves that an out-of-range binding leaves the record
unchanged; it validates the blit-producer, blit-consumer, and compute layouts
against full public GPU-VA ranges; teardown blocks while the lease is live; and
a stale copied lease cannot release resources again. It still does not
construct an Apple resource sidecar or make a submission callable; the lease
is the ownership handoff that those future operations must consume.

The corresponding Apple-owned command-carrier allocation path is now measured
but remains non-callable. A public empty-command-buffer control shows one
`IOGPUMetalCommandBufferStorageCreateExt` return before its first of two
64-byte queue carriers, followed by ordered public completions. The analyzer
enforces that constructor-return-before-first-submit lifetime invariant. On
this profile, read-only disassembly shows the constructor consumes a private
parameter object and initializes internal resource-list state before returning
storage. AO46 must therefore obtain that carrier only through an Apple-owned
public command-buffer lifecycle until a separate documented bridge boundary is
available; it must not construct the parameter object or call the constructor.

The public-to-generic handoff is now proven more precisely. For each public
`MTLCommandBuffer`, Apple invokes the typed private method
`-[IOGPUMetalCommandBuffer fillCommandBufferArgs:commandQueue:]` with the exact
public command-buffer object as `self`. Its arguments pointer is passed
unchanged as the 64-byte descriptor to `IOGPUCommandQueueSubmitCommandBuffers`.
The generic submit function's `x1` is null on this profile, so it does not
receive an Objective-C command-buffer array or expose a raw replacement carrier.
This gives AO46 a safe ownership boundary to observe: create and commit a public
Metal command buffer and Apple constructs the descriptor/storage itself. It is
not an Asahi submission ABI: AO46 has no supported way to provide an Asahi batch
to that private fill method, and the runtime continues to make no private call.

The public failure control requests one byte beyond `MTLDevice.maxBufferLength`.
Apple still enters `IOGPUResourceCreate` with a 104-byte record, returns null,
and emits no resource-object snapshot, GPU-VA lookup, or resource release for
that request. Two further direct allocations then succeed and are released
normally. This proves the observed null-return path is non-owning and public
allocation recovers afterward. It does not prove how an AO46-initiated private
constructor would clean up an unknown partial failure, so no call helper is
enabled.

The control also inventories the public `MTLBuffer.contents` range for every
allocation. All thirteen public ranges are contained in one of the ten observed
data-bearing generic resource ranges: three are offset suballocations (the
second 4 KiB shared buffer, the 8 KiB shared buffer, and the untracked 4 KiB
buffer), while the remaining ten begin at their data-bearing object's CPU-data
pointer. This establishes a profile-gated ownership and range relationship
between public Metal mappings and generic resource objects. It does not prove
that AO46 may obtain, map, or write a generic resource through private APIs,
nor does it establish CPU/GPU cache-coherency requirements.

`AppleAGXResourceCoherenceSmoke` now separately performs two public-Metal
hardware round trips through a private buffer: CPU-written shared memory is
blitted to private storage and back to a second public mapping, then the second
mapping is CPU-written and copied back through private storage to the first.
Both byte-pair checks pass on the active profile. This proves public
`MTLBuffer.contents` coherence across executed GPU work; it is deliberately not
generalized to a generic IOGPU resource mapping or cache-management ABI.

The bridge now resolves `IOGPUResourceGetDataBytes`,
`IOGPUResourceGetDataSize`, and `IOGPUResourceGetResidentDataSize` alongside
the existing GPU-VA accessors. LLDB confirms the size, resident-size, GPU-VA,
and GPU-VA-length exports use one resource argument and load their observed
object fields. The data-pointer accessor is also exported but performs an
additional type check. These are resolve-only diagnostics: AO46 invokes none
of them and does not treat their presence as a generic mapping ABI.

`AppleAGXNativeBridge.h` now preserves this profile-gated evidence as a typed
104-byte record and typed constructor/accessor/release declarations. Its
`AppleAGXNativeBridgeHasObservedResourceContract` check verifies only the
generic device root and resolved symbol set. There is deliberately no AO46
function that invokes the constructor: record construction, generic resource
mapping, and release-on-failure policy remain admission blockers.

The same control proves that public shared and write-combined allocations
expose writable CPU memory on this profile. It writes and verifies sentinel
bytes at both ends of each 4 KiB buffer. A private allocation also returns a
non-null public `contents` pointer on this unified-memory host; pointer
presence alone is therefore explicitly not classified as an AO46 CPU mapping,
coherency guarantee, or permission to map a generic resource.

A shared allocation with public `MTLHazardTrackingModeUntracked` now provides
one additional allocation-mode differential. It creates one generic resource,
has a writable public CPU pointer, and differs from the comparable shared
record at ten bytes (`0x39`, `0x3a`, `0x3b`, `0x42`, `0x43`, `0x50`, and
`0x60..0x63`). Those bytes remain opaque: the existing duplicate baseline has
already identified `0x39` as address churn, and the control does no GPU work
that could establish a hazard-tracking field or generic-resource mapping rule.

`capture_iogpu_queue_contract.sh` is the matching debugger-only queue and
empty-submit control. A public Metal command queue produces one generic
`IOGPUCommandQueueCreate` call with a 1040-byte (`0x410`) argument record; its
return pointer is later passed unchanged to `IOGPUCommandQueueRelease`. A
blank public command buffer, with no render, compute, blit, draw, or dispatch
encoder, reaches `IOGPUMetalCommandBufferStorageCreateExt` and
`IOGPUCommandQueueSubmitCommandBuffers`. The typed command-buffer fill receives
the public command-buffer object and descriptor pointer; the generic submit then
receives the same queue, a buffer count of one, an exact 64-byte descriptor, and
a separate auxiliary carrier pointer, but a null `x1` rather than an object
array. The public command buffer completes successfully. This establishes the
observed Apple-owned queue lifecycle and descriptor shape, not an AO46 submission
ABI: AO46 still does not create a generic queue, invoke the constructor, submit a
descriptor, or map Apple completion data into a Mesa fence.

An ordered two-submit variant now proves that one returned generic queue accepts
two blank public command buffers in sequence. It observes one command-storage
constructor, two generic submissions with distinct descriptor addresses, and
two public completion-handler callbacks with completed status. The storage
object is therefore observed as Apple-owned cached state across this particular
empty-submit sequence. This does not expose its layout, a generic completion
record, or an Asahi-compatible command carrier.

The refreshed nine-workload UABI profile observes sixteen submissions across
empty, two-queue, blit, compute, render, descriptor-variation, and IOSurface
controls. Each preserves the 64-byte descriptor, 4 KiB carrier capture, and
two matching completion tokens. The bounded sidecar scanner finds no direct or
indirect GPU-resource reference in those carrier snapshots. This is now a
validated separation, not an unresolved sidecar field: the controlled
four-submit resource-variation trace proves that one CPU-mapped command record
carries the differentiated resource GPU VAs at `0x0`, `0x8`, `0x20`, and
`0x28`, while the sidecar has zero resource references. AO46 must bind
resources through those command records and keep the sidecar opaque.

`agx_macos_submission_package` now provides one non-submittable admission and
retirement path for the future Asahi carrier: it retains command/resource BO
ranges, requires binding to a current notification-queue generation before it
can enter flight, accepts only matching completion tokens, and discards the
carrier after the final completion releases every pin. Its smoke covers foreign
token rejection, first-token retention, and final-token retirement. It does
not create a generic resource or queue, call a private submit function, or
create a `pipe_screen`.

## Parallel Six-Lane Work

| Lane | Apple-native bridge objective | Current state |
| --- | --- | --- |
| 1. BO and GPU-VA | Correlate Apple resource objects with allocation, mapping, and GPU-VA effects | `[~]` Apple-owned device root, a dynamically verified three-argument generic-resource boundary, create/return/release ownership, a measured null-return and public-recovery path, 104-byte records, `attributes.write_combined`, allocator-owned tail variation, nonzero GPU-VA returns, record-to-backing pointer links, public mapping range containment, and public CPU/GPU coherence are measured. The current public control proves sixteen resource objects across thirteen GPU VAs, so object lifetime is explicitly separate from VA/handle tracking. One real Mesa `agx_bo` now resolves to a current native BO for command/resource subrange admission; private-pointer semantics, GPU-VA-length, generic mapping, complete typed-resource inputs, and the first typed AO46 resource remain. Repeated raw allocation is intentionally not a path to multi-BO support. |
| 2. Submission | Correlate command assembly and queue commit with a callable submission boundary | `[~]` Apple-owned queue create/return/release, cached command storage, 64-byte descriptor-plus-carrier submits, and a 16-submit UABI profile are measured. A public `MTLCommandBuffer` is now traced into the typed Apple fill method, which supplies the exact descriptor subsequently consumed by generic submission; generic submit has no raw command-buffer pointer. The resource-variation gate proves resource GPU VAs belong to a separate CPU-mapped command record, not the sidecar. A Mesa package now retains real Mesa BOs alongside native BO pins and encodes only their verified ranges; the encoder-span adapter also validates mapped VDM/CDM-style BO spans before a future Apple command-record adapter may retain them. Actual batch extraction, a documented Apple command-record injection mechanism, outer transport ownership, and the first safe submit remain. |
| 3. Completion | Correlate queue ownership and completions with fence and retirement behavior | `[~]` Public completion callbacks and every profiled descriptor's two token matches are observed; package-level queue binding and BO retirement are tested without submission, while a generic completion source, live notification wiring, Mesa fence exposure, and retirement ordering remain unproven |
| 4. Mesa screen | Populate an `agx_device` through the bridge and call Mesa's shared screen finalization | `[ ]` Blocked on lanes 1-3; diagnostic Mesa-device and drawable paths now revalidate the retained Apple device root before reporting ready |
| 5. Drawable | Import IOSurface resources through the same ownership model | `[~]` IOSurface trace exists; bridge import/present unproven |
| 6. CTS | Run offscreen Mesa rendering and staged CTS only after a real screen exists | `[ ]` Blocked on lane 4 |

## Decision Rule

If the evidence shows that Apple exposes no viable boundary below its own Metal
encoder, AO46 does not pretend otherwise. The current G16X Objective-C class
inventory is negative, but the generic C resource/queue anchors are a separate
candidate now under controlled observation. If that C contract also cannot
accept Asahi-owned resources and commands, the project returns to the preserved
trace-validated direct-UABI route, keeping it fail-closed and implementing only
macOS platform operations proven by controlled traces. Either route retains the
same Mesa/Asahi semantic and AGX rendering engine.
