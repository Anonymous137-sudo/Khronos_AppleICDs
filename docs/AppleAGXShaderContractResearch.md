# Apple AGX Shader Contract Research

Status: preserved direct-AGX research. This record documents shader-residency
and provenance observations; it is not a runtime admission contract. The
active backend plan is [AO46MetalBackendPlan.md](AO46MetalBackendPlan.md).

Historical scope: a profile-gated investigation recorded the missing Mesa Asahi
`AGX_BO_LOW_VA | AGX_BO_EXEC` path. This is not a private API declaration and
does not enable either flag in AO46.

## Scope

The observations below come from the active Apple M4 Pro profile on macOS
26.5.2 (25F84), using the loaded arm64e
`AGXMetalG16X.bundle/Contents/MacOS/AGXMetalG16X` image. They are valid only
for that image UUID and operating-system profile. Any other AGX family must
repeat the trace with its exact loaded bundle.

Mesa Asahi gives these flags specific meanings:

- `AGX_BO_LOW_VA` requires mapping in the queue's dedicated 4 GiB USC virtual
  address window.
- `AGX_BO_EXEC` requires an executable shader allocation and always implies
  `AGX_BO_LOW_VA`.

An ordinary Apple GPU virtual address, including a GPU address reported by a
public `MTLBuffer`, therefore cannot satisfy either requirement by itself.

## Controlled Method

`asahi_macos_shader_execution_trace` builds baseline, two-buffer, and
threadgroup public compute pipelines. Its paired mode warms one retained
device/queue/buffer set and repeats each control before validating `0x6a46` on
the CPU. Phase markers cover compilation, pipeline creation, queue creation,
buffer creation, encoder creation, binding, dispatch, commit, and completion.

`capture_agx_shader_contract_trace.sh` stops the target only after the active
Apple AGX image loads, then installs read-only LLDB breakpoints at exact
offsets derived from that arm64e image:

- Apple `createComputeProgramVariant` factory.
- Apple compute-pipeline initializer.
- Compute pipeline binding, kernel emission, deferred pass finalization, and
  USC-spill handling.
- Apple `IOGPUResourceListAddResource` calls that retain resources for the
  submitted compute command.
- `ComputeProgramVariant::finalize()` and
  `ComputeUSCStateLoader::directTGSizeOptimization()`.
- `IOGPUResourceGetGPUVirtualAddress` return values for every observed Apple
  resource in the traced path.

The callbacks record bounded live call arguments, call ordering, and opaque
read-only snapshots only. AO46 does not invoke a private selector, retain an
Apple-owned object, write private memory, or submit an Asahi batch through this
tool.

## Observations

| Observation | Result | Meaning |
| --- | --- | --- |
| Shader source compilation | 0 selector-9 allocations | Compilation does not expose a generic executable BO allocation. |
| Compute pipeline creation | 0 selector-9 allocations | Pipeline creation does not expose a generic USC allocation. |
| Queue creation | 17 selector-9 allocations | Queue setup owns several ordinary support allocations. |
| 4-byte public output buffer | 1 selector-9 allocation | Public data-buffer allocation is distinct from shader residency. |
| Encoder creation | 7 `storage=0x4430` allocations | These are command/encoder support allocations, not evidence of executable code allocation. |
| Bind, dispatch, commit | 0 selector-9 allocations | The observed submission consumes existing Apple-owned state. |
| `pinnedGPULocation` constructors | 3 calls; two observed zero values and one nonzero small placement value | This is a placement policy input, not a proven GPU virtual address or USC-window mapping. |
| `pinnedGPUAddress` constructors | 0 calls | No public fixed-address allocation path was observed. |
| address-range buffer constructor | 0 calls | No public external-memory import path was observed. |
| compute program factory | 2 entries and opaque returns for two distinct pipelines | Apple creates separate pipeline-owned program-variant objects. |
| compute-pipeline initializer | 2 entries and opaque returns | Each variant becomes part of a sealed Apple compute-pipeline object. |
| compute execution | `setPipelineCommon`, kernel emitter, and `endComputePass` all observed | The real public compute path consumes the internal pipeline only during encoding/finalization. |
| pipeline resource binding | 2 pipeline-owned resources added to an `IOGPUResourceList` | Apple retains its own pipeline companions before the submission; this is not an external-resource import ABI. |
| USC descriptor packing | called twice around execution/finalization | On this profile the named helper is a leaf `AGXUMADescRec` packer, not an allocator or an IOKit call. It exposes no Asahi BO, AGX code bytes, or independently callable allocation contract. |
| command resource binding | a two-buffer control binds index 0 writable with flag 3 and index 1 read-only with flag 1 | Context-owned resource-table slots, rather than the USC descriptor, represent this tested resource count and access intent. |
| paired public execution | 7 completed submissions, 14 USC descriptor records, 9 command resource binds | The same process can repeatedly exercise the complete Apple-owned compute carrier without cross-process pointer churn. |
| program-variant finalization | 10 bounded call/return pairs | Pipeline-owned variant finalization is an explicit Apple-owned lifecycle edge. The captured bytes are unchanged across each individual finalizer return and are not treated as an AO46 object layout. |
| USC variant consumption | 5 direct threadgroup-size helper uses | The helper's `x1` argument matches the finalized baseline or two-buffer variant object. `x0` is the loader instance, not the variant. |
| observed resource GPU addresses | 28 nonzero high addresses, 0 nonzero addresses below 4 GiB, 1 zero return | No observed `IOGPUResourceGetGPUVirtualAddress` result occupies Mesa's required low-VA USC window. This does not prove no internal USC mapping exists; it proves the traced generic resource path is not that mapping. |

The encoder's `0x4430` allocations are CPU-mapped at high GPU virtual
addresses such as `0x10000080000`. Mesa's USC contract instead requires a
profile-specific mapping in a 4 GiB window whose base is supplied to queue
creation. Treating those high addresses as low-VA USC addresses would be
incorrect.

The active bundle's static type metadata independently names a compute
pipeline's `compute_variant` and internal heap-backed loader/runtime state.
The factory's first instructions consume the selected compute function and
driver compiler options before constructing its internal program key. This
corroborates the dynamic result: executable code is owned by the Apple pipeline
compiler/runtime path, not by a transferable public data-buffer allocation.

The additional finalization and USC-loader probes make that ownership chain
concrete. The loader instance passes an Apple-owned finalized program variant
as its second C++ argument while preparing direct dispatch sizing. The baseline
and two-buffer controls select different retained variants. No observed
generic-resource GPU address was low enough for Mesa's USC window, and neither
this variant flow nor the bounded object snapshots supplies a constructible
executable allocation contract.

## Variant Residency Allocation Trace

The profile-gated trace now observes the actual Apple allocation path used by
`ComputeProgramVariant`, rather than inferring shader residency from generic
resource addresses or spill-descriptor data.

On the active G16X profile, the constructor's arm64e call ABI is observed as:

```text
x0  ComputeProgramVariant result object
x1  Apple HAL device
x2  AGC deserialized program reply
x3  program-name storage
x4  program binding remap
x5  indirect-argument-layout collection
w6  profile-controlled residency selector
x7  USC profile-control object
```

The constructor copies `w6` to its local branch input. Its first program
residency allocation has two statically verified alternatives:

```text
w6 == 0: Heap<true> at variant + 0xa8,  selected base = 0
w6 != 0: Heap<true> at variant + 0x1f8, selected base = 0x1000000000
```

Both alternatives call Apple-owned `AGX::Heap<true>::allocateImpl`. Its
observed ABI returns a 40-byte allocation record through `x0` and receives the
heap, requested byte count, and an Apple resource-list pointer in `x1..x3`.
The routine completes synchronously before the variant stores the record's
first field at its profile-specific `+0x618` slot.

The 32 KiB threadgroup control produced seven program-variant constructions.
All seven selected `w6 == 0` and therefore the zero-base heap. Each selection,
heap call, return record, resource list, and owning variant was correlated in a
single process. The large stress variant requested `0x2b48` bytes; its returned
allocation field was exactly the value stored in that variant's `+0x618` slot.
This establishes an Apple-owned program-residency allocation lifecycle and
shows that it changes with program content.

The nonzero branch is now a measured public control path. The
`indirect-command` workload creates one public `MTLComputePipelineDescriptor`
with `supportIndirectCommandBuffers = YES` and dispatches it through an
ordinary public compute encoder. On the active G16X profile, its capture
produced seven constructor calls: six with `w6 == 0` and one with `w6 == 1`.
The enabled constructor selected the separate heap at `variant + 0x1f8`, the
fixed base `0x1000000000`, and a first 0x5a-byte allocation whose returned
field was `0x1c0`; the constructor's observed derived value was therefore
`0x10000001c0`. The workload completed and verified its output on the CPU.
`verify_agx_shader_contract_trace.sh` now rejects an `indirect-command` trace
unless it records both the enabled selector and at least one nonzero base.

This resolves the immediate "which template" ambiguity: the active
low-residency choice is made by `ComputeProgramVariant`'s profile selector and
selects one of two Apple `Heap<true>` instances. It is not one of the 44
command-allocator resource-pool descriptors, which belong to the carrier's
separate resource-slot lifecycle. The selected heap still receives its
resource configuration from an Apple-owned allocator, so its underlying pool
class and constructor record are not an AO46 ABI.

AO46 must not mutate the factory-owned selector record or replay the internal
constructor. The remaining work is to measure the separate heap's map,
code-byte provenance, teardown, and failure behavior, then determine whether
an Asahi-generated executable can ever be admitted through that lifecycle.

This result proves a public control for the nonzero residency branch and a
fixed-base address derivation. It does not establish an import operation for
an AO46/Asahi allocation, nor does it prove the selected allocation can carry
arbitrary executable AGX code. The `AGX_BO_LOW_VA` and `AGX_BO_EXEC` gates
therefore remain disabled.

## Direct Compute Code Publication

The narrowed `indirect-command` control now creates only the public
ICB-compatible compute pipeline before dispatching it. This removes unrelated
test pipelines from the capture while preserving a real completed dispatch.
On the active profile it observes four program-variant constructions: three
with a zero selector and one with the enabled nonzero selector. The enabled
variant selects the separate `Heap<true>` path and its fixed base as described
above.

The same run observes five `LinkInfo` initializations and five
`applyInternalRelocations` calls during pipeline construction, including calls
from inside `ComputeProgramVariant`. Each relocation receives a LinkInfo that
was initialized earlier in the same process from an Apple compiler reply. The
enabled variant's LinkInfo publishes `0x10000001c0`, matching the selected
`0x1000000000` base plus the `0x1c0` field returned by its first Apple heap
allocation. The trace records identities and address arithmetic only; it never
reads compiler output, AGX code bytes, relocation records, or private object
contents.

The public control then completes its GPU dispatch and releases the pipeline.
The `ComputeProgramVariant` base destructor receives the same enabled variant,
its initialized LinkInfo, and the same compiler-reply identity. This proves the
observed direct lifetime is coherent from Apple compiler reply, through Apple
allocation and relocation, to variant teardown.

The run observes zero calls to `DynamicLibrary::allocateCodeHeap` and
`DynamicLibrary::deallocateCodeHeap`. The active direct compute variant
therefore performs its own allocation and relocation sequence; the
dynamic-library allocator is a separate linked-code path, not an
external-code-admission mechanism for this control. The profiler keeps
read-only allocation/release probes installed for workloads that do enter that
path, and the indirect-command verifier requires the direct provenance,
publication, and teardown evidence.

The heap-allocation record is now correlated to its retained Apple resource.
The selected nonzero-base allocation returns a private allocation record, not
an `IOGPUMetalResource` pointer. The record in turn retains the same
Apple-created resource reached by `Heap<true>::allocateImpl`; the direct
variant and subsequent allocations reuse that record/resource pair. Both
ordinary and remote-storage initializer probes see that resource being created
from the AGX heap factory during the same run. This corrects an earlier probe
labeling error and establishes the true ownership chain:

```text
ComputeProgramVariant
  -> Heap<true> allocation record
  -> retained Apple IOGPUMetalResource
  -> fixed-base suballocation and relocation
```

This completes the direct Apple-produced allocation-record, resource-owner,
relocation, and teardown reconstruction. It does not permit AO46 to replace
the Apple resource, establish the queue's low-VA mapping policy, or prove
admission of Asahi-generated executable bytes. `AGX_BO_LOW_VA` and
`AGX_BO_EXEC` therefore remain disabled.

An early, load-pending probe also covers the preceding device lifetime. It
observes Apple device initialization and all 44 resource-pool initializations
from `setupHWResourcePools` before the compute pipeline is created. The active
nonzero variant selects the G16X device-resident code heap identified by the
same profile-gated Ghidra reconstruction. This links the variant's low-base
suballocations to the initialized Apple device/pool owner without exporting a
private template or replaying a constructor.

Digest-only comparison confirms that the heap's constructor policy record is
derived from, but is not byte-identical to, a device pool template after live
allocation state is applied. The next reconstruction target is therefore the
internal template-copy transformation, followed by the queue mapping policy;
it is not a generic resource-import search.

## Headless Decompiler Reconstruction

The opaque residency, resource, and queue paths are now investigated with a
static-first method. Ghidra 12.1.2 imports a temporary thin arm64e copy of the
active G16X bundle and imports IOGPU through its original dyld-cache filesystem
reference. The latter matters because the on-disk IOGPU framework is a
dyld-cache stub, not a standalone Mach-O image. The generated C-style reports
stay in a temporary directory; AO46 retains only its exporter scripts and the
behavioral conclusions below. The companion blocker-graph exporter starts with
the shader-variant constructor, heap allocator, USC consumer, and AGX command
argument lowering, recording direct callers and callees before a runtime probe
is considered.

The exact active G16X universal binary used for this pass has SHA-256
`fe7518dbd4b362f293070fa07b3f8bb367db5d859792e237d34f5ba36b4b0e34`.
Any OS or AGX-bundle change invalidates these conclusions until the capture and
decompile are repeated.

The paired analysis establishes the following profile-scoped facts:

- The `Heap<true>` queued allocator creates an Apple `IOGPUMetalResource` from
  a heap-owned configuration record. The record passed by the observed shader
  residency path is 0x68 bytes, but it is an input to an Apple-owned allocation
  lifecycle, not an AO46 allocation descriptor.
- The generic resource initializer validates the Apple device, creates the
  underlying IOGPU resource, obtains client-shared state, records the returned
  GPU virtual address, creates allocation identifiers, and registers the
  resource with the Apple device. The public accessors merely expose selected
  results of that lifecycle.
- The pooled-resource factory serializes reuse under its own lock and keeps
  pool-private links and generation state. Replaying a retained resource record
  or fabricating a pooled resource would skip this lifetime accounting.
- Resource-list insertion deduplicates an existing resource identity and merges
  usage flags. It retains resources for a carrier but neither constructs a
  resource nor assigns its GPU virtual address.
- Apple command-buffer initialization obtains storage from an Apple command
  storage pool. Argument filling exports storage-owned shared-memory IDs and
  installs Apple-owned scheduling and completion callbacks. Commit finalizes
  that storage's shared-memory header before the queue submits it.
- The C queue creation path passes a zeroed 0x408-byte Apple queue argument
  block through user-client selector 7 and attaches a notification queue. The
  low-level submit path has a bounded single-buffer Trap4 fast path and a
  selector-29 multi-buffer path, but both consume command-buffer argument
  records emitted from Apple-owned command storage.

The static-first expansion identifies three narrower candidates for the three
remaining gates:

- **Data BO adoption:** IOGPU contains an `IOGPUMetalBuffer` initializer that
  receives an `IOGPUAddressRange` array, count, length, options, a GPU-address
  value, and an Apple `IOGPUNewResourceArgs` record. It sets an internal
  address-range mode before entering the same Apple resource-construction
  lifecycle. This is a candidate to map, not a usable AO46 constructor: it
  still requires an Apple device, Apple-owned object construction, a valid
  resource-argument record, and a verified address-range ownership policy.
- **Low-VA executable BO:** `DynamicLibrary::allocateCodeHeap` is the specific
  Apple code-residency consumer. It allocates from `Heap<true>`, copies compiled
  code, applies internal relocations, and derives the fixed `0x1000000000`
  address from the returned allocation. This establishes that code provenance
  and relocation happen inside the Apple code-heap lifecycle; it does not show
  an input that accepts an Asahi AGX code BO.
- **Command storage:** the storage pool creates or reuses an Apple storage
  object, associates its Apple segment-list header and resource-list state, and
  finalization closes headers and residency state. The current static evidence
  contains no parameter for an arbitrary Asahi CDM/VDM stream. The next static
  question is whether a caller below this pool can attach an external segment
  through a non-fabricated ownership path.

This changes the remaining work from “find an arbitrary transferable object”
to a specific proof obligation: establish whether Asahi allocations and command
records can be admitted into the resource-creation and command-storage
lifecycles without fabricating their private state. Static reconstruction tells
us which fields and ownership edges must be measured; it does not authorize an
AO46 call to an unproven private constructor or selector.

## Code Heap Lifetime Reconstruction

A second static Ghidra pass now reconstructs the active profile's
`DynamicLibrary` code-heap lifetime. This is a distinct Apple code-residency
manager, not proof that Mesa's USC allocation can use the same contract.

`allocateCodeHeap` is reference-counted. On its first live reference, it asks
Apple `Heap<true>` instances for the code-related allocations, retains the
returned backing records, copies Apple-produced code bytes into the primary
heap allocation, applies Apple relocation metadata, and derives the code
address by adding `0x1000000000` to that allocation's Apple-managed address.
Subsequent users retain the same residency rather than recreating it.

`deallocateCodeHeap` performs the matching final-release path: it synchronously
releases each Apple heap allocation and clears the residency records only when
the reference count reaches zero. This establishes allocation, relocation,
sharing, and teardown as one coherent Apple-owned code-loader lifecycle. It
does not expose a parameter that admits external AGX code, an AO46 BO, or an
arbitrary low-VA mapping.

## Low-VA Heap Layout

The expanded static graph maps the low-level allocation shape used beneath the
Apple code heap. `Heap<true>` serializes allocation on its own queue and its
queued resource factory allocates an internal `IOGPUMetalResource`, invokes
its `initWithDevice:options:args:argsSize:` lifecycle, then records that
resource's size and GPU/virtual addresses in the returned allocation tuple.
The tuple is not merely a GPU address: it retains mapping, backing-resource,
allocation, and heap ownership state used by the matching queued deallocation
path.

The dynamic-library loader acquires up to five of these tuples as one
reference-counted residency group. It copies Apple-produced bytes into the
allocated mappings, applies internal relocations after the group is complete,
and exposes the primary executable address through its fixed code-address
derivation. The final release synchronously returns every tuple through its
originating heap before clearing the group.

This identifies the exact internal reconstruction path for
`AGX_BO_LOW_VA | AGX_BO_EXEC`: the AGX resource-pool setup, the selected
heap's internal IOGPU resource construction, its mapping policy, and the
matching release path must be analyzed as one lifecycle. A single public data
allocation, a copied allocation tuple, or an injected AGX stream would omit
required ownership and teardown state.

## Heap Owner And Pool Boundary

The centre-of-gravity Ghidra pass separates the code heap's allocation logic
from the native-resource constructor it relies on. `Heap<true>` is a
queue-serialized suballocator: it first reuses an appropriate backing resource
when possible, otherwise it requests a new Apple resource using a heap-owned
configuration, then returns an allocation tuple tied to that backing resource.
Its paired deallocation either returns the range to the heap or releases the
backing resource according to the allocation's ownership state.

The configuration does not originate in the generic IOGPU resource functions.
On this profile, AGX device setup constructs a 44-entry hardware resource-pool
vector and hands it to the command allocator in a single
`setHwResourcePool:count:` operation. IOGPU later consumes the selected slot's
Apple-owned device, options, and new-resource argument template to reuse or
construct native backing storage. The static pass now resolves the remaining
factory control flow: a 44-entry jump table reduces to eight construction
templates, which all reach the same private native pool initializer with a
resource class and a 104-byte resource-argument record. The per-template
semantic role remains unresolved, so raw policy values are not treated as a
low-VA or executable authorization contract.

`DynamicLibrary::initializeCodeHeap` is also now classified correctly: it
adopts a compiler-reply-derived `HeapSet` and retains code-loader bookkeeping
for Apple-produced program data. It is not the heap constructor and does not
accept external AGX program bytes. A non-shader caller such as rasterization
rate-map setup can also use `Heap<true>`, so use of that generic heap cannot by
itself establish the executable or USC contract required by Mesa.

The next low-VA reconstruction target is therefore precise: recover the
dedicated slot class and ownership policy used by the nonzero code-residency
branch, including its native backing allocation, queue USC mapping, failure
cleanup, and final release. Only then can AO46 determine whether an Asahi code
allocation may be created within the same lifecycle.

## Direct Execution Boundary

The verified public compute dispatch follows this profile-gated sequence:

1. `setComputePipelineState:` accepts an Apple compute-pipeline object and
   forwards to internal `setPipelineCommon`.
2. The regular kernel emitter consumes that internal pipeline while encoding
   the dispatch.
3. The pipeline binds two Apple-owned companion resources into an
   `IOGPUResourceList`; the application buffer is retained by a separate
   binding call.
4. Apple invokes its USC-spill helper around the same command path.
5. `endComputePass` finalizes the command immediately before the observed
   Trap4 submission and completion that produces `0x6a46`.

The command-carrier construction, compute-subrecord placement, USC descriptor
packing, and context-owned resource transition are now documented separately
in [`AppleAGXComputeCarrierResearch.md`](AppleAGXComputeCarrierResearch.md).
Those profile-gated measurements make the internal data flow concrete, but do
not yet provide a callable raw-UABI submission contract.

This maps where the relevant ownership lives. It does **not** demonstrate that
an arbitrary `agx_macos_bo`, an Asahi USC allocation, or Asahi-generated AGX
code can enter this list. `IOGPUResourceListAddResource` is a resource
retention operation; it is not evidence of an allocation, GPU-VA mapping, or
executable-code import contract.

## USC Template And Activation Chain

The profile's two previously separate low-VA questions now have a verified
Apple-owned startup chain. Ghidra resolves `heapConfigs` as a one-time G16X
template producer. The device initializer invokes that producer and
materializes its generated heap configuration into device-resident state. The
observed compute variant selects its primary code allocation from one of those
runtime-owned heaps, while extended program paths also use a separate profile
heap. These are profile-local ownership edges, not a general-purpose
descriptor that AO46 can copy.

The matching runtime control now records the exact startup order without
capturing template bytes or the private three-word IOKit reference payload:

```text
heapConfigs dispatch-once
  -> USC profile kernel initialization
  -> global USC configuration records 0 and 1
  -> AGX call site: IOKit selector 0x107 (three references, no input payload)
  -> successful return
  -> deferred 44-slot resource-pool setup
```

The direct `AGX + 0x2d16d4` probe is necessary here. A generic
`IOConnectCallAsyncScalarMethod` symbol breakpoint did not reliably observe
this stub-mediated call, while the profiled AGX call-site probe proves its
execution and success. The selector is therefore established as an Apple
USC-profile activation/notification handoff, not yet as evidence that it maps
an arbitrary external BO or authorizes arbitrary executable code. AO46 does
not call it.

## Code-Heap Mapping Ownership

The selected target is now resolved far enough to correct the earlier
investigation premise. The active profile does not perform a second, generic
queue-VM map from the `ComputeProgramVariant` or dynamic-library code-loader
paths after USC activation. Instead, the code-heap allocator serializes each
request, creates or reuses an Apple-owned `IOGPUMetalResource` through its
heap-owned configuration, and derives the allocation's GPU-visible range from
that resource's virtual and GPU address pair. The allocator returns a tuple
that retains both the range and its native resource until the matching heap
release.

The code loader then copies Apple-produced program data into those retained
ranges, applies its internal relocations, and derives the fixed code-domain
address used by the enabled program variant. This establishes the complete
Apple-owned allocation, address-translation, relocation, and teardown chain
for the observed code heap. It does not turn the private resource constructor,
its policy record, or the code-loader input into an AO46 ABI.

The repeatable control analyzer now joins the live compute-variant allocation
records to relocation publication by address identity. The current USC-stress
control matched all seven observed compute-variant allocations to seven
Apple relocation publications, with one stable Apple-owned policy class. This
is direct evidence that the selected retained resource backs Apple-produced
compute code through relocation. It is not evidence that arbitrary Asahi code
can be admitted to that resource or to the restricted code aperture.

The remaining issue is therefore narrower than a missing generic map call:
the profile-specific resource policy must be shown to admit an AO46/Asahi
executable code allocation under the same ownership and authorization
lifecycle. That policy boundary is now the correct `AGXG16X` kernel/UABI
reverse-engineering target.

## AGXG16X Kernel Target Availability

The active system identifies `com.apple.AGXG16X` as the graphics kernel
extension for `AGXAcceleratorG16X`, with `IOGPUFamily` as a dependency. Its
load record confirms that the G16X driver is present on the running arm64 host.
A matching arm64e `BootKernelCollection` is now available locally and has been
used only through temporary read-only Ghidra projects. The x86_64
`SystemKernelExtensions.kc` remains unsuitable for this work. AO46 does not
infer kernel policy from a different architecture or fabricate it from
user-space heap records.

## Kernel Resource And Mapping Ownership

The arm64e `IOGPUFamily` and `AGXG16X` passes identify the kernel-side
ownership chain beneath the existing user-space research:

```text
IOGPU device user client
  -> generic device resource admission and namespace ownership
  -> resource kind selection
  -> generic memory or client-address-range backing
  -> optional accelerator-specific restricted mapping
  -> AGX GART/UAT aperture mapping and page-table update
```

The generic resource path validates the submitted resource category and backing
ownership before it chooses one of the Apple-owned allocation routes. Normal
data resources can remain on the generic mapping path. The client-address-range
route separately rejects protected backing and conditionally delegates mapping
to an accelerator virtual hook. Its call shape structurally matches
`AGXAccelerator::createRestrictedRangeMapping`, which in turn reaches the AGX
secure GART/UAT mapping machinery. This establishes that low-VA/restricted
mapping is an Apple-kernel-owned policy path, not a user-space VA calculation or
a generic data-BO remap.

The GART pass also confirms that the driver distinguishes dedicated allocation
ranges and rejects default or unmapped range classes. The unified address
translator enforces alignment, range ownership, and protection before it updates
page tables and invalidates translation state. Queue-side compute setup then
consumes the resulting protected resource state. These findings narrow the
remaining executable question to policy admission: which Apple-created resource
class is permitted to enter the code aperture and how its executable provenance
is established.

The follow-up virtual-dispatch pass places the code-range query and restricted
mapping operation in the same secure-GART implementation family. They are
reached through Apple-owned virtual dispatch, not a direct resource-creation or
queue user-client method. This rules out treating the normal resource path as a
code-aperture shortcut and keeps the next investigation focused on the resource
class chosen before that secure-GART dispatch.

The generic user-client start path also records a restricted-client capability
derived from Apple-controlled GPU entitlement state. Its dispatcher admits only
configured operations and maintains distinct normal and restricted method
tables. This does not yet prove that the code-aperture route requires restricted
status, but it proves that low-level resource admission is policy-controlled.
Disabling SIP or authenticated root must not be treated as evidence that an
otherwise unadmitted resource request will succeed.

## Internal Resource Admission Refinement

The kernel graph now separates two layers that had previously appeared as one
opaque resource path. `AGXResource` interprets Apple-owned creation policy and
selects mapping behavior, but its base aperture methods do not create an
aperture mapping themselves. The actual protected backing lifecycle is owned by
`AGXInternalResource`: it creates kernel-owned backing, prepares firmware
mappings, and only then participates in queue and compute setup.

The secure-map commit path validates this existing allocation/mapping ownership
before it changes GPU page tables. Its callers are kernel resource, queue, and
firmware-management lifecycles, not a generic client resource-import route.
Together with the code-heap capture, this establishes that executable admission
is an Apple-produced resource-provenance transition. An arbitrary AO46/Asahi BO
cannot gain code-aperture status merely by choosing a low virtual address or by
following the ordinary data-resource path.

This closes the resource-class ownership question. The remaining executable
gate is now specifically the Apple compiler/heap producer-to-internal-resource
handoff: how the selected code-heap policy causes an internal resource to be
created, populated, relocated, mapped, and later released. AO46 continues to
treat that lifecycle as opaque and does not invoke a private constructor or
submit a reconstructed request.

A combined user-space and kernel pass now maps that handoff at a high level:

```text
Apple compiler result
  -> Apple dynamic-library code-heap initialization
  -> device-owned code heap selection
  -> retained Apple resource construction
  -> Apple code copy and relocation
  -> internal resource / secure mapping lifecycle
  -> queue-side consumption
```

The code heap receives both Apple compiler output and a device-owned heap
configuration before it creates the retained resource. This is a closed
provenance chain, not a general-purpose "map executable bytes" operation. The
finding narrows the remaining work to the compiler-result validation and
handoff that admits code into that chain; it does not justify fabricating a
compiler result, resource policy, or executable mapping request.

## Compiler Reply Admission Boundary

The compute compiler callback maps an Apple-produced reply and passes it to
`AGCDeserializedReply`. A failed parse is converted into a compilation error
and does not reach the compute-variant callback. A successful parse is then
consumed by the variant factory, `ComputeProgramVariant`, link-info setup, and
the already-mapped code-heap path.

The static parser graph contains structural parsing, bounds handling, and
named-record lookup. It does not contain a cryptographic verifier, AGX resource
creation, or secure-mapping admission operation. This shows that reply
deserialization is a structural gate, not the executable-provenance authority.
The relevant authority is upstream: the Apple compiler request/reply service
that produces the reply bound to a pipeline request, device configuration, and
compiler task.

AO46 must not fabricate a deserialized reply merely because the parser accepts
well-formed input. The next investigation therefore moves from the reply
consumer to the service-side request/result binding, while the direct winsys
continues to keep executable BO capability disabled.

## Compiler Service Producer Boundary

The service-side Ghidra pass identifies `MTLCompilerService` as the producer
authority for accepted compiler replies. Its message path validates the request
class, connection identity and context, compiler-version compatibility, plugin
selection, request-data presence and bounds, and sandbox state before it begins
compilation. The service then creates a per-connection compiler context and
binds the selected compiler-plugin interface to that context.

The resulting context owns separate service and dispatch handles. The service
invokes its bound compiler implementation with the validated request and emits
only that implementation's callback bytes as the XPC reply. The consumer-side
deserializer then structurally parses those bytes before variant construction.

```text
Apple pipeline request
  -> MTLCompilerService validation and connection context
  -> selected compiler-plugin interface
  -> plugin compiler service and callback
  -> XPC reply bytes
  -> AGCDeserializedReply structural parse
  -> variant, code heap, and secure mapping lifecycle
```

This closes the request/result ownership boundary without creating a callable
private XPC ABI. The next technical target was the selected `GPUCompiler`
implementation behind the plugin interface. That layer and its AGX-specific
compiler implementation are now mapped below. AO46 must not replay the
service request or manufacture reply bytes.

## GPUCompiler And AGXCompilerCore Boundary

The cache-resident `GPUCompiler` implementation provides the generic AIR
module pipeline. It selects a native target/plugin, validates and lowers the
compiler-owned AIR modules, and asks the selected target implementation to
emit an executable image. Its ordinary buffer output is a Metal-library product
with reflection data, rather than an API for admitting an arbitrary AGX binary.

The selected hardware compiler is `AGXCompilerCore`. Its compute-program path
prepares binding metadata from an Apple-owned LLVM/AIR module and calls the
AGX compiler context. The resulting compiled-object bytes are then
deserialized, validated, and packaged into the binary reply consumed by the
already-mapped AGX program-variant and code-heap path.

```text
Apple LLVM/AIR module
  -> GPUCompiler target/plugin selection and lowering
  -> AGXCompilerCore compute-program compilation
  -> Apple compiled object and validated binary reply
  -> AGCDeserializedReply
  -> program variant, code heap, relocation, and secure mapping
```

This is an important correction to the integration model. The concrete AGX
compiler is the producer of the accepted executable result; its baseline input
is compiler-owned LLVM/AIR state, not a raw AGX instruction stream. The static
evidence does not expose a separate admission route for an Asahi executable.
AO46 therefore cannot enable `AGX_BO_LOW_VA` or `AGX_BO_EXEC` by treating the
compiler reply parser or the generic GPUCompiler output buffer as an import
ABI.

### Compute-Program Source Gate

The concrete `AGCLLVMComputePrograms` source object clarifies where the
executable-provenance authority begins. Before invoking the compiler context,
it augments its Apple-owned LLVM module with compute binding metadata, selects
an entry point from that module, and passes both the module and its private
program object to `AGCLLVMCtx::compile`. The context then obtains
object-specific backend configuration, constructs an AGX compile request, and
executes the selected compile plan.

This separates two ideas that must not be conflated:

```text
Asahi-generated AGX machine code
  != Apple compiler-result provenance

LLVM/AIR module plus Apple program-object configuration
  -> AGX compile plan
  -> validated compiler reply
  -> Apple low-VA code-heap lifecycle
```

The low-VA heap is therefore a consumer of already-admitted compiler output,
not the place that grants executable provenance. No supported AO46 entry point
for supplying an alternate module or program-object configuration has been
identified. The adapter must continue to leave executable and low-VA BO
capabilities disabled until a legitimate allocation/admission contract exists.

The static type references add one further constraint: the concrete
compute-program type uses the base backend-request helper in this build rather
than a dedicated raw-code-import override. Its compilation behavior is instead
assembled from module metadata, program state, compiler-context profile, and
the resulting compiler reply. This rules out treating the virtual helper as a
small executable-code admission hook while preserving the next real target:
the compiler-result validation and resource-admission transition.

The subsequent reply pass rules out a second false lead. The recovered
`validateBackendReply` stage notifies the program object and may emit
diagnostics; the following reply-packaging stage serializes metadata for the
consumer. Neither stage allocates executable storage, authorizes a low-VA
mapping, or admits alternate code. The next authority-bearing transition is
the AGX compile-plan execution and its handoff into the retained code-resource
lifecycle.

### AGX Compile-Plan Boundary

A targeted Ghidra pass over the active `GPUCompiler` `libLLVM.dylib` recovers
the AGX compile-plan factory, generic plan executor, and assembler-plan
executor. They configure the compiler request, run compiler passes, and produce
the compiler reply consumed by `AGXCompilerCore`. This implementation does not
create an IOGPU resource, select a code heap, establish a USC mapping, or submit
to AGX.

The result fixes the layer boundary:

```text
LLVM AGX compile plan
  -> compiler reply only
  -> AGXCompilerCore program/variant ownership
  -> Apple code-resource and restricted-mapping lifecycle
```

Consequently, the executable-admission authority is not hidden inside an LLVM
assembler option. The next reconstruction target remains the consumer-side
transition that accepts the compiler reply and turns it into an Apple-owned
code resource. AO46 must not reinterpret compiler output as an executable BO
until that resource-admission lifecycle is understood and reproducible.

## AO46 Provenance Gate

The macOS winsys now represents the verified portion of this lifecycle in C.
An executable Mesa BO must carry a current, generation-bound provenance record
for compiler reply, Apple-owned code resource, and its already-authorized
low-VA mapping. The provider validates that the returned BO range matches that
record exactly. Ordinary data buffers and a provider capability bit alone are
not sufficient to satisfy `AGX_BO_LOW_VA` or `AGX_BO_EXEC`.

The arm64e consumer-boundary pass further resolves the state ordering: an
Apple-owned code resource is populated and internally relocated before its
low-VA executable mapping is published, and final release returns the resource
through its originating heap. AO46 records those transitions as provenance
states only. It neither receives code bytes nor reconstructs an Apple resource
configuration, relocation record, or private allocation call.

### Cross-Component Consumer Result

The focused arm64e Ghidra pass now connects the direct compute variant with the
IOGPU resource owner. The active `ComputeProgramVariant` selects its
profile-owned code heap, obtains an allocation from that heap, initializes
reply-owned link state, copies and relocates Apple-produced program data, and
then derives the low-VA range. The corresponding IOGPU resource path creates or
recycles the native resource through a retained pool and device-owned
configuration before the user-client returns its mapping results. Release is
serialized back through the same heap.

This is a complete ownership ordering, but not an executable import contract:
the IOGPU remote-resource initializer requires an existing compatible native
resource, while generic resource creation consumes the Apple-owned
configuration. Neither boundary accepts an arbitrary Asahi BO or AGX code
stream. The AO46 provenance gate therefore correctly requires all of:

```text
validated compiler reply
  -> Apple code resource
  -> Apple copy and relocation completion
  -> Apple-authorized low-VA mapping
  -> matching heap-owned retirement
```

The C state machine mirrors that ordering and keeps `AGX_BO_LOW_VA` and
`AGX_BO_EXEC` unavailable until a legitimate producer-to-resource admission
operation exists. The temporary Ghidra reports contain the raw pseudocode and
are not checked into this repository.

The unresolved Apple consumer-side handoff is deliberately one transition in
that state machine: it must create and retain the Apple code resource, then
report the authorized mapping. Until that transition is implemented and
validated, the UABI contract keeps low-VA and executable capabilities disabled.

The next evidence task is to correlate this compiler-produced result with the
specific low-VA code-heap resource retained by the active AGX profile. That
will establish whether any supported producer boundary exists between an AO46
shader compiler and Apple's executable-resource lifecycle, without inventing
private request layouts or compiler provenance.

That correlation is now captured by the `indirect-command` public control. On
the active profile, four program variants are constructed; one selects the
nonzero low-VA code heap. The trace verifies that the same opaque compiler
reply identity is retained by that variant, its first Apple-owned code-heap
allocation, link/relocation publication, and final teardown. The relation is
checked by `analyze_agx_compiler_heap_trace.sh` and is a required regression
gate for that workload.

This proves the ownership chain, not AO46 admission: the code bytes still come
from Apple's compiler result and the heap resource is still Apple-created. No
AO46/Asahi executable input is accepted by this result.

Call-site classification rules out the tempting but incorrect
`AGXResource::newKernelResource` branch: its users are TA-channel, scene,
render-target, and hardware-buffer lifecycle setup. The code-residency path
instead crosses the user/kernel boundary through Apple's retained resource
ownership chain:

```text
AGX Heap<true>
  -> IOGPUMetalResource Apple initializer
  -> generic IOGPU resource creation
  -> kernel resource admission
  -> conditional AGX restricted mapping
  -> secure GART/UAT mapping
```

This is the correct point for differential classification. AO46 must first
determine which Apple-owned code-heap policy selects the restricted executable
route, then validate it in an isolated, profile-gated probe. A raw Asahi BO or
AGX byte stream cannot substitute for the Apple-owned resource lifecycle.

This is a reverse-engineering evidence milestone, not a callable AO46 UABI.
The method-dispatch and resource records remain opaque and profile-specific;
AO46 neither constructs them nor sends an inferred request to the user client.
A profile-gated probe remains a later research phase once the selected template,
its resource lifetime, and its failure cleanup are fully established. Such a
probe must begin with an Apple-created ordinary-data control and must not begin
by fabricating executable policy or submitting Asahi code.

## Consequences For AO46

- `[x]` CPU-visible data BOs can remain backed by one retained public Apple
  allocation and use the verified resource-list binding path.
- `[x]` The BO-provider capability split is correct: public Apple buffers
  advertise CPU-mappable data only.
- `[x]` `0x4430` encoder allocations are excluded as USC/executable candidates.
- `[x]` Apple pipeline variants are identified as the code-residency owner for
  this profile, without assuming their object layout is an import ABI.
- `[x]` The Apple compute execution chain and its resource-list ownership are
  mapped through one real GPU completion.
- `[x]` The program-variant finalization and dispatch-side USC-consumer edges
  are measured on the active profile.
- `[x]` Headless Ghidra reconstruction now covers the profile's program
  residency allocator, generic resource creation, pooled-resource lifecycle,
  resource-list insertion, command-storage argument generation, queue setup,
  and submission branches. Reports stay outside the repository and are paired
  with dynamic captures; no reconstructed Apple object is invoked by AO46.
- `[x]` `ComputeProgramVariant`'s first Apple heap allocation is correlated
  with its owning variant, retained resource list, allocation result, and
  profile-controlled base selection. The stress shader changes that allocation
  size (`0x2b48` in the captured control).
- `[x]` The correlation analyzer proves the active profile's Apple compute
  allocation-to-relocation ownership edge: every observed compute-variant code
  address is published by Apple relocation under a single Apple-owned policy
  class. AO46 does not import code into that class.
- `[x]` The active public ICB-compatible control reaches one enabled
  `ComputeProgramVariant` selector, its separate nonzero-base heap, and the
  direct internal-relocation path. The control does not enter
  `DynamicLibrary::allocateCodeHeap`, proving that this common compute case is
  not an external-code-admission path through the dynamic-library allocator.
- `[x]` The direct enabled-variant lifecycle is correlated from an
  Apple compiler-reply identity through its initialized `LinkInfo`, its
  fixed-base relocation result, and the same variant's base-destructor entry
  after the completed public dispatch. The capture retains no code bytes or
  reconstructible private object state.
- `[x]` The traced generic-resource GPU-address path is excluded as Mesa's
  low-VA executable shader path.
- `[x]` The separate Apple dynamic-library code heap now has a recovered
  reference-counted allocation, code-copy, relocation, and final-release
  teardown chain, including its `0x1000000000` code-address derivation.
- `[x]` The underlying queued `Heap<true>` allocation/deallocation contract is
  mapped as an Apple-resource-backed allocation tuple, not a bare low-VA
  address. The dynamic-library loader groups up to five such tuples under one
  residency lifetime.
- `[x]` The selected direct-compute allocation record is now differentiated
  from its retained `IOGPUMetalResource` and correlated to that resource's
  observed `Heap<true>` initialization. The same record/resource pair is
  reused by later suballocations in the control workload.
- `[x]` The AGX device-to-allocator resource-pool owner chain is identified:
  44 slot classes are prepared by `setupHWResourcePools` and attached once to
  the Apple command allocator. IOGPU owns the selected pool's reuse,
  construction, generation, and retirement lifecycle.
- `[x]` The device startup, all 44 pool initializations, the enabled variant's
  device-resident code-heap selection, and its retained-resource allocation
  record are observed in one profile-gated run.
- `[x]` The device-side pool factory is recovered as eight bounded policy
  templates feeding one native resource-pool initializer. No AO46 source calls
  that private initializer or fabricates its 104-byte resource arguments.
- `[x]` The selected low-VA code heap is now connected to the one-time G16X
  USC template producer and to a successful Apple USC-profile activation
  handoff. The evidence is profile-gated and retains no private template or
  IOKit reference data.
- `[x]` The selected code-heap allocation's native mapping owner is identified:
  `Heap<true>` retains an Apple resource and translates its virtual and GPU
  address range while allocating. The inspected code-loader and variant paths
  contain no separate generic queue-map operation after USC activation.
- `[x]` The common Apple heap allocator is now correlated with its retained
  resource policy at allocation return. The public stress control observes two
  stable Apple heap-policy families across three retained resources, distinct
  from the ordinary buffer-resource families in the same process.
- `[x]` Static profile analysis identifies separate Apple template families for
  generic, code, indirect-command generic, and indirect-command code heaps.
  Their initialization precedes heap allocation; no template bytes or request
  records are treated as an AO46 ABI.
- `[x]` Matching arm64e `IOGPUFamily` and `AGXG16X` kernel images establish the
  resource admission -> restricted mapping -> secure GART/UAT ownership chain.
  This is retained as high-level behavior only; no selector, record layout, or
  private request payload is treated as an AO46 ABI.
- `[x]` The internal resource boundary is now classified: generic resource
  initialization selects policy, while kernel-owned internal resources create
  backing and prepare firmware mappings before secure page-table commit. This
  excludes ordinary user BOs as a substitute for executable resource
  provenance.
- `[x]` The compiler-result -> code-heap -> retained-resource -> relocation ->
  secure-mapping chain is mapped across the active user-space and kernel
  profiles. Both the code bytes and heap configuration are Apple-owned inputs
  to that lifecycle; no external executable import contract is inferred.
- `[x]` Compute reply admission is separated into structural parsing and
  downstream variant construction. Parse failures stop the callback, while
  successful replies reach variant/link initialization; the parser itself is
  not the executable-provenance authority.
- `[x]` The upstream compiler-service producer boundary is mapped: validated
  requests are bound to a per-connection compiler-plugin context, whose service
  returns the reply bytes later consumed by the structural parser. This does
  not define or invoke a private XPC ABI.
- `[x]` The cache-resident `GPUCompiler` target-selection path and the concrete
  `AGXCompilerCore` compute-program producer are mapped. Apple-owned LLVM/AIR
  input is lowered to an Apple-produced compiled object, then validated and
  packaged into the reply consumed by AGX program variants. This is evidence
  of ownership, not a callable compiler or binary-import ABI.
- `[x]` The active public indirect-command control now regression-checks a
  coherent compiler-result -> program variant -> Apple low-VA code-heap
  allocation -> relocation -> teardown identity chain. It proves Apple's
  provenance ownership for that branch without retaining compiler bytes or
  introducing an AO46 executable import path.
- `[x]` The concrete compute-program source path is mapped through its
  Apple-owned LLVM module, metadata preparation, compiler-context plan, and
  validated reply. The relevant base backend-request helper is not a raw
  executable-code import facility.
- `[x]` Compiler-reply validation and packaging are classified as
  program-object notification, diagnostics, and metadata serialization. They
  are not an executable allocation, mapping, or alternate-code admission path.
- `[x]` The generic client-address-range route is distinguished from ordinary
  data-resource mapping and conditionally reaches the AGX restricted-mapping
  hook. It confirms that a low-VA mapping must be granted by the Apple resource
  lifecycle rather than derived from an arbitrary Asahi BO address.
- `[x]` The focused arm64e consumer and kernel review now closes the ownership
  model for the observed direct-compute branch: a validated compiler reply is
  consumed into an Apple-owned code resource, Apple performs code copy and
  relocation, the resulting range is published in the restricted low-VA
  aperture, and retirement returns to the originating Apple heap. The generic
  and remote IOGPU resource paths require an already-compatible native Apple
  resource; they do not admit a foreign executable BO.
- `[x]` Restricted mapping is an accelerator policy operation over an already
  admitted resource. AO46 therefore models shader-code admission as a distinct
  UABI and framework-readiness gate, rather than treating executable memory or
  low-VA mapping as sufficient evidence on their own.
- `[x]` The generic user-client creates and retains an Apple-gated restricted
  capability state before it dispatches resource, queue, or submission work.
  The code-aperture policy is not yet tied to that state, but AO46 now treats
  entitlement and method admission as separate proof gates rather than assuming
  root configuration bypasses either one.
- `[~]` Apple has an internal program-residency branch that selects a separate
  heap and `0x1000000000` base. Its selector, direct relocation, teardown, and
  `IOGPUMetalResource` construction boundary are now dynamically or statically
  proven. The USC activation call is also proven, but the executable-resource
  policy and an AO46-compatible admission path remain open.
- `[~]` Reconstruct the internal AGX resource-pool to IOGPU resource-creation
  chain for the dedicated low-VA allocation. The generic resource and
  pool-consumer side, AGX device-level owner, and code-heap policy families are
  known. The remaining gate is the runtime association of the dedicated
  executable template with its heap plus its queue mapping/authorization
  semantics.
- `[ ]` Recover an AO46-usable internal executable-code path that retains the
  necessary Apple allocation, relocation, mapping, and teardown ownership for
  Asahi-generated AGX bytes.
- `[ ]` `AGX_BO_LOW_VA` and `AGX_BO_EXEC` must remain unavailable; admitting
  `pipe_screen` without both would be a false capability claim.

## Next Evidence Gates

1. Trace AGX compile-plan execution into its code-resource handoff, then
   determine whether a supported producer boundary exists for AO46-generated
   shader input. The generic GPUCompiler and reply parser are not that
   boundary.
2. Prove the resulting lifecycle using a standalone Asahi shader BO before
   enabling the corresponding provider capabilities.
3. Only then create a live `pipe_screen`, submit a controlled Asahi compute
   batch, and proceed to offscreen readback and CTS.

Until these gates are met, the direct winsys remains correctly fail-closed for
shader BOs even though ordinary provider-backed resource BOs are available.
