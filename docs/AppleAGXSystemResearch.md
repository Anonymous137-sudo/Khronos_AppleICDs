# Apple AGX System Research Map

Status: preserved direct-AGX research map. It remains useful for diagnosis and
historical evidence, not as the active AO46 runtime implementation plan. See
[AO46MetalBackendPlan.md](AO46MetalBackendPlan.md).

This document defines the research boundary for the AO46 macOS winsys. It is
for understanding the locally installed Apple GPU stack, not for copying,
linking, or redistributing Apple binaries.

## Active Host Profile

The current development host is an Apple M4 Pro on macOS 26.5.2 (build
`25F84`). The loaded GPU stack identifies the active family as `G16X`:

```text
com.apple.iokit.IOGPUFamily 130.15.2
com.apple.AGXG16X 351.2
com.apple.AGXFirmwareKextRTBuddy64 351.2
com.apple.AGXFirmwareKextG16XRTBuddy 1
```

The matching user-space Metal backend is:

```text
/System/Library/Extensions/AGXMetalG16X.bundle
```

Its `AGXMetalG16X` binary depends on `IOGPU.framework`, IOKit, IOSurface, and
Metal. Metal.framework itself depends on IOKit and IOAccelerator. This confirms
the practical research path:

```text
Metal.framework
  -> AGXMetalG16X.bundle
  -> IOGPU.framework / IOKit
  -> AGXDeviceUserClient
  -> AGXG16X kernel driver and RTBuddy firmware
```

The IORegistry exposes active `AGXDeviceUserClient` instances with command
queues. These observations identify the boundary; they do not define a stable,
portable, or public AGX ABI.

On this OS build, Metal.framework, IOGPU.framework, and IOAccelerator.framework
are served from the shared cache rather than readable standalone binaries. The
active `AGXMetalG16X` bundle is on disk, so it is the static-analysis target;
shared-cache components remain available for dependency and runtime tracing.

## Full Graphics-Stack Scope

AO46 research is not limited to `AGXMetalG16X`. It is profile-scoped: we
investigate every layer that can own a contract needed by the active M4 Pro
execution path, while avoiding unrelated GPU clients and inactive hardware
families that cannot answer a G16X UABI question.

| Tier | Components | Current purpose |
| --- | --- | --- |
| Execution | active `AGXMetalG16X`, `IOGPU`, `IOAccelerator` | Resource, command-storage, queue, Trap4, and completion ownership. |
| Transport | IOKit, `AGXG16X`, `IOGPUFamily` | User-client and kernel-side boundary attribution. |
| Code provenance | `AGXCompilerCore`, `GPUCompiler`, `MTLCompiler`, `MetalSerializer` | Determine how Apple-created executable code is compiled, retained, relocated, and retired. |
| Presentation | Metal, IOSurface, QuartzCore | Drawable identity, backing storage, presentation, and Retina lifecycle. |
| Diagnostics | MetalTools, GPUToolsCapture, GPUToolsReplay, GPUToolsTransport | Read-only capture and workload attribution, never runtime dependencies. |
| ABI reference | AppleMetalOpenGLRenderer and Apple's CGL/OpenGL framework | macOS frontend and legacy ABI behavior, not a backend to link or reuse. |

Other AGX-family bundles are retained only for static comparison when they
share a question with G16X. They are not primary targets because their object
policy and UABI details can differ by GPU generation. MetalPerformanceShaders,
application metallibs, and unrelated GPU services are excluded unless a trace
establishes a direct connection to allocation, executable residency, queueing,
or presentation for AO46.

## High-Value Evidence

The active backend's local Objective-C metadata exposes the following research
anchors:

| Area | Identifier evidence | AO46 question |
| --- | --- | --- |
| Device | `AGXG16XFamilyDevice initWithAcceleratorPort:` | How does a device own the AGX user-client connection? |
| Resources | `AGXBuffer ... pinnedGPUAddress:` | Which allocation and VM operations establish a BO and GPU VA? |
| Command assembly | `AGXG16XFamilyCommandBuffer fillCommandBufferArgs:commandQueue:` | Which owned allocations form the descriptor, sidecar, and command records? |
| Submission | `AGXG16XFamilyCommandQueue_mtlnext commit:count:` | Which IOKit call commits the fully assembled submission? |
| Completion | command-buffer/queue lifecycle and notification traces | How are completion records associated with resource retirement? |
| Presentation | IOSurface dependency and controlled drawable trace | Which resources must be imported and retained for presentation? |

These names are research leads only. AO46 must not call private Objective-C
classes or private Metal entry points in production.

## Reproducible Inventory

Run:

```sh
OpenGL_4.6(Core Profile)/Apple_ICD/scripts/inventory_apple_agx_stack.sh
```

The script writes a host profile, loaded-module snapshot, IOKit registry
snapshot, Mach-O dependencies, code-signing metadata, hashes, and a limited
set of relevant identifiers to `<TMPDIR>/ao46-apple-agx-research` by
default. Set `AO46_APPLE_AGX_RESEARCH_DIR` to choose another output location.

It now also records the whole-stack scope in `stack-scope.txt` and produces
individual metadata reports for execution, transport, compiler, presentation,
diagnostic, and ABI-reference binaries. A shared-cache or stub report is an
expected result on current macOS releases; it identifies a runtime-tracing or
Ghidra shared-cache target rather than an unavailable subsystem.

It deliberately does not copy system files, inject code into Apple processes,
or make raw submissions. Capture a controlled AO46 Metal workload with
`wrap.dylib` separately, then correlate its IOKit events with the selected
static identifiers.

Set `AGX_TRACE_CALLERS=1` for a controlled `wrap.dylib` capture to emit the
return-address offsets in the active `AGXMetal*.bundle` for each traced IOKit
method and Trap4 submission. Those offsets are profile-specific attribution
evidence only: they identify where the observed call originated, not a
callable private ABI or an authorization to use an Objective-C layout.

If an operation has no `AGXMetal` caller, additionally set
`AGX_TRACE_CALLER_FALLBACK_IMAGES=1`. The wrapper then reports the bounded
non-wrapper image stack for that operation, making it possible to distinguish
the AGX implementation from a shared-cache submission intermediary without
turning routine traces into full-process backtraces.

### Private Winsys Ownership Map

`AGXMetalG16X.bundle` is the private winsys layer that turns Metal-owned
resource, command-buffer, and queue objects into IOGPU and IOKit operations.
It is neither the direct AO46 backend nor a component to embed. Run
`inventory_apple_agx_private_winsys.sh` to create a profile-specific static map
of its device-bootstrap, resource, command-record, and queue-commit anchors.
The map in `docs/ApplePrivateWinsysMap.md` uses that evidence to direct AO46
toward the IOKit UABI, while keeping Metal controls limited to differential
trace triggers.

### Validated G16X Caller Chain

The controlled `asahi_macos_trace_control` workload now verifies two useful
profile-specific edges:

```text
AGXBuffer ... -> selector 9 -> AGX resource allocation reply
IOGPUCommandQueueSubmitCommandBuffers
  -> IOGPUMetalCommandQueue submitCommandBuffers:
  -> Trap4 submission -> two completion records
```

Run the strict check with:

```sh
AGX_TRACE_CALLERS=1 \
AGX_TRACE_CALLER_FALLBACK_IMAGES=1 \
AGX_TRACE_REQUIRE_APPLE_BRIDGE=1 \
OpenGL_4.6(Core Profile)/Apple_ICD/scripts/capture_agx_trace_control.sh
```

`verify_agx_apple_native_bridge_trace.sh` rejects a trace that lacks either
edge. This proves a candidate resource and submit boundary for the active G16X
profile. It does not establish a supported callable interface or enable an
AO46 runtime call into IOGPU.

The read-only runtime probe reports the submission selector's current type
encoding as `v32@0:8^@16Q24`: it returns `void` and receives the queue object,
selector, an array of Objective-C command-buffer objects, and a count. A
read-only debugger lookup of the underlying
`IOGPUCommandQueueSubmitCommandBuffers` entry also observes an immediate
CoreFoundation type check on its first argument. These two observations mean
the discovered route remains Apple-object-owned; it is not a verified raw
command-record interface for Asahi. AO46 must not synthesize those private
objects or invoke either entry until a lower typed boundary is proven.

The bounded class inventory provides a stronger result for the current G16X
profile: `IOGPUCommandQueue`, `IOGPUCommandBuffer`, and `IOGPUResource` are
absent. The available `IOGPUMetalCommandQueue`, `IOGPUMetalCommandBuffer`, and
`IOGPUMetalResource` classes inherit from Metal base classes. Although the
command-buffer class exposes `fillCommandBufferArgs:commandQueue:` and
kernel-command-buffer allocation methods, each still requires Apple-owned
Metal-side objects. This disproves the Objective-C path as a generic raw-AGX
carrier; it is not evidence that AO46 may construct or mutate those objects.

The same runtime image exposes a separate CoreFoundation-style C candidate:
`IOGPUResourceCreate`, resource GPU-VA accessors, `IOGPUCommandQueueCreate`,
queue connection/ID accessors, release functions, and
`IOGPUCommandQueueSubmitCommandBuffers`. It also exposes
`IOGPUDeviceCreate` and `IOGPUMetalCommandBufferStorageCreateExt`. The symbol
probe requires all of these anchors on the active profile.

Controlled debugger captures now establish the first constructor and submit
shapes without invoking any AO46 bridge code. Resource creation and queue
creation both receive the same generic device object. The resource path passes
a 104-byte argument record; the queue path passes a 1040-byte argument record,
matching the observed selector-9 allocation and selector-7 API configuration
record sizes. A real submission reaches
`IOGPUCommandQueueSubmitCommandBuffers` with a generic queue, a 64-byte
descriptor pointer/length pair, and the auxiliary carrier pointer that later
reaches Trap4. The command-buffer-storage constructor is also reached from the
real command-buffer path. These are profile-specific call-shape observations,
not declarations to copy into the AO46 runtime yet.

The device inventory exposes the bootstrap seam:
`IOGPUMetalDevice` has `initWithAcceleratorPort:` and a typed `deviceRef`
accessor returning an opaque `IOGPUDevice` reference. That is the same generic
object family received by the C resource and queue constructors. Standard
Metal setup did not call `IOGPUDeviceCreate` in the captured workload, so its
constructor contract remains unknown. AO46 may not use the private `deviceRef`
accessor in production merely because the type is observable. The project must
either trace `IOGPUDeviceCreate` through a controlled caller or explicitly
choose a narrowly scoped Metal bootstrap solely to obtain an Apple-owned device
reference, with no Metal rendering or command encoding in the AO46 runtime.
AO46 has chosen the latter for the active G16X profile. The runtime bridge now
retains `MTLCreateSystemDefaultDevice`, verifies `IOGPUMetalDevice` and the
exact `deviceRef` Objective-C encoding, then retains the returned opaque
generic reference. It resolves but never calls the generic IOGPU resource,
queue, storage, and submit functions. The next evidence still has to prove the
resource and queue argument records plus their ownership before any such call
is enabled.

### Generic Resource Differential Capture

`capture_iogpu_resource_constructor.sh` is a debugger-only controlled workload
that creates five public Metal buffers and observes the Apple generic C
boundary. On the active G16X profile it records eight
`IOGPUResourceCreate` entries, each with the same non-null generic device and
a 104-byte argument record. The debugger also captures each constructor return:
the eight distinct returned resource pointers are exactly the eight pointers
later passed to `IOGPUResourceRelease` after the public buffers are released.
AO46 does not call either function.

The measured input deltas prove only one record field: the first little-endian
64-bit word changes from zero to `0x0000040000000000` for a write-combined
buffer, matching `1 << 42`; it is therefore recorded as
`attributes.write_combined`. Duplicate shared buffers establish that byte
`0x39` has address-like churn, so it is excluded from field inference. The
comparable shared-size and shared/private records are identical, which means
their high-level Metal inputs do not directly identify a generic-record field
on this profile. The public control calls
`IOGPUResourceGetGPUVirtualAddress` for every one of the eight returned
resources and observes eight nonzero returns representing five unique GPU
virtual addresses. The repeated addresses are consistent with Apple-managed
suballocation; they do not establish an AO46 allocation or aliasing rule. The
same workload does not call `IOGPUResourceGetGPUVirtualAddressLength`, so that
accessor remains unmeasured. AO46 must not create a generic resource until the
remaining input fields, mapping behavior, and a first typed resource call have
direct evidence.

The control additionally writes and verifies sentinels at both ends of public
shared and write-combined 4 KiB buffers. Their public CPU mapping works on the
active host. Calling `contents` on the private control buffer also returns a
non-null pointer here, but that fact does not establish a coherent mapping or
generic-resource contract; AO46 records it as opaque unified-memory behavior
and does not use it in the winsys.

The same resource control now adds a public shared
`MTLHazardTrackingModeUntracked` allocation. It exposes writable public memory
and creates one generic resource. Its comparable 104-byte record differs at
ten byte positions, including known address churn at `0x39`; the remaining
positions are evidence candidates only. The control has no GPU workload, so
it does not establish a generic hazard-tracking field, synchronization rule,
or typed creation ABI.

### Generic Queue and Empty-Submit Differential Capture

`capture_iogpu_queue_contract.sh` creates a public Metal command queue, submits
one blank command buffer, waits for public completion, and releases the queue.
The control creates no render, compute, blit, draw, or dispatch encoder. On the
active G16X profile it observes one `IOGPUCommandQueueCreate` call with a
1040-byte (`0x410`) argument record and a successful returned generic queue
pointer. `IOGPUMetalCommandBufferStorageCreateExt` is then reached before
`IOGPUCommandQueueSubmitCommandBuffers`; the submit receives the same queue
pointer, `buffer_count=1`, an exact 64-byte descriptor, and a separate
auxiliary pointer. `IOGPUCommandQueueRelease` later receives the exact returned
queue pointer.

An ordered two-submit control uses the same public queue and waits after each
blank command buffer. It captures one command-storage creation, two generic
submissions with distinct 64-byte descriptor addresses, and two public
completion-handler callbacks reporting completed status. The observed storage
object is cached across those two empty submissions. No render, compute, blit,
draw, or dispatch encoder is created in this control.

This measures Apple-owned queue construction, storage, descriptor submission,
and teardown through the generic C layer. It does not establish the descriptor
field meanings, a resource-binding sidecar graph, a generic completion record,
or a Mesa/Asahi fence mapping. AO46 does not invoke these private functions;
the control exists solely to derive a typed, fail-closed adapter contract.

### Cross-Workload Carrier and Completion Profile

The nine-workload UABI profile records sixteen submissions covering empty,
two-queue, blit, compute, render, descriptor-variation, and IOSurface public
controls. Every submission retained the profiled outer transport: one 64-byte
descriptor, a 4 KiB bounded carrier snapshot, and exactly two matching
completion records. The bounded direct and indirect sidecar resource scans
found no GPU-resource reference in this profile. This is expected transport
separation, not a missing resource-table decode: the controlled four-submit
blit variation proves that resource GPU VAs reside in one separately allocated,
CPU-mapped command record at `0x0`, `0x8`, `0x20`, and `0x28`. The verifier
rejects a profile in which those controlled bindings instead appear in the
sidecar. Known resource-address slots therefore stay limited to the separate
command records, and the opaque carrier is never interpreted as a resource
table.

The local `agx_macos_submission_package` mirrors this evidence only. It
requires a current notification-queue binding before its pinned carrier can
enter the in-flight state, rejects foreign completion tokens, and releases all
pins after the second matching token. The smoke is a synthetic lifecycle test;
it does not invoke a private queue, resource, or submit API.

## Research Order

1. Correlate device creation and `AGXDeviceUserClient` ownership.
2. Vary pinned and non-pinned Metal buffer allocation to map BO and GPU-VA
   operations.
3. Trace command-buffer assembly through the `fillCommandBufferArgs` and
   queue-commit anchors, while varying one resource family at a time.
4. Decode object/resource tables only when static and dynamic evidence agree
   for this OS and GPU profile. Keep the sidecar opaque unless a future,
   independent profile proves it carries a transport field that AO46 needs.
5. Implement the matching small `agx_macos_*` operation, add a controlled
   hardware test, and reject all other OS/GPU profiles until revalidated.

This work accelerates the AO46 winsys without turning private Apple code into a
runtime dependency or weakening the project's fail-closed submission policy.
