# AO46 Native AGX Architecture

Status: governing design plan. The runtime selects the native Mesa/Asahi path
only. Until its macOS winsys can create an AGX Gallium screen, CGL context
creation fails explicitly; no GL2MTL fallback is selected.

## Decision

AO46 does not implement a second OpenGL driver in project code. It reuses the
upstream Mesa OpenGL implementation and the upstream Mesa Asahi Gallium driver
as the complete OpenGL 4.6 semantic and Apple-GPU execution stack.

AO46 must not add its own implementations of OpenGL object semantics, state
tracking, validation, dispatch, GLSL parsing/linking, NIR lowering, SPIR-V
ingestion, shader optimisation, AGX instruction selection, AGX shader
compilation, render-batch creation, descriptors, or AGX graphics state.

Those responsibilities stay in Mesa and Asahi. AO46 owns the macOS-facing
framework ABI and, after the frontend is functional, the platform boundary
needed to make the upstream Asahi userspace stack operate on macOS.

## Target Topology

```text
macOS application
  -> OpenGL.framework router
  -> OpenGL_4.6.framework
  -> CGL / NSOpenGL frontend
  -> Mesa OpenGL frontend and state tracker
  -> Mesa Asahi Gallium driver
  -> Asahi compiler, lib, layout, genxml, libagx
  -> AO46 Apple-AGX ABI adapter
  -> Apple AGX userspace infrastructure
  -> IOGPU user client, Apple AGX kernel driver, and firmware
  -> AGX GPU
```

`GL2MTL` remains in the source tree only as a deprecated, opt-in development
target. It is excluded from the default build and cannot be selected by the
framework runtime.

### Bounded Metal Bootstrap

The native route does not use Metal as a rendering backend. For the active,
profile-gated G16X implementation only, AO46 may retain the system Metal
device long enough to request its opaque generic IOGPU `deviceRef`. This is an
Apple-owned ownership root for the generic IOGPU C boundary, not a Metal
translation layer: AO46 creates no Metal command encoders or command buffers,
does not compile MSL, and does not submit through Metal. Resource, queue, and
submission calls remain disabled until their C ABI contracts are independently
validated by controlled evidence.

## Ownership Boundary

| Component | Owner | AO46 action |
| --- | --- | --- |
| CGL, NSOpenGL, framework ABI, pixel formats, drawable lifecycle, routing | AO46 | Maintain and integrate |
| OpenGL 4.6 API semantics, validation, objects, GLSL, SPIR-V, NIR, state tracker | Mesa | Reuse unchanged |
| AGX Gallium driver, AGX compiler, batch/state generation | Mesa Asahi | Reuse unchanged |
| BOs, GPU VM, command queues, submission, synchronization | Apple AGX userspace infrastructure | Reuse through a narrow, profile-gated adapter when a viable boundary is proven |
| Resource ownership, object translation, IOSurface presentation | AO46AGXMac | Adapt Asahi objects and macOS drawables without replacing Apple's GPU OS integration |
| Scheduling, power, resets, firmware and hardware ownership | Apple macOS | Use; do not replace |

## Source Reuse Policy

`OpenGL_4.6(Core Profile)/mesa` is the canonical upstream dependency for the
native backend. AO46 will pin a tested Mesa revision and keep a small explicit
patch queue only for upstream-compatible build or platform changes.

The native backend consumes these upstream components rather than duplicating
them in AO46 source code:

- `src/mesa/`, `src/mesa/state_tracker/`, `src/compiler/glsl/`, and
  `src/compiler/nir/`
- `src/poly/` and Mesa Gallium auxiliary code
- `src/gallium/drivers/asahi/`
- `src/asahi/compiler/`, `src/asahi/genxml/`, `src/asahi/layout/`,
  `src/asahi/lib/`, `src/asahi/libagx/`, and `src/asahi/clc/` as required

### OpenGL 4.6 Feature Provenance

AO46 is not an AGX shader compiler with a separate project-local OpenGL
implementation layered above it. The required desktop OpenGL functionality is
reused as a complete Mesa/Asahi pipeline:

| OpenGL or driver capability | Reused source |
| --- | --- |
| Core OpenGL API, objects, state, validation, and dispatch | Mesa OpenGL core and state tracker |
| GLSL 4.x and program linking | Mesa GLSL frontend |
| OpenGL SPIR-V ingestion | Mesa SPIR-V frontend |
| NIR IR, generic optimization, and lowering | Mesa NIR |
| Compute shaders | Mesa plus Asahi Gallium/compiler |
| Robust buffers and images | Mesa/Asahi lowering |
| Clip control and cull distance | Mesa/Asahi shader lowering |
| Geometry shaders | Mesa poly and Asahi compute-based implementation |
| Tessellation | Mesa poly and Asahi compute-based implementation |
| Transform feedback | Mesa/Asahi compute-based implementation |
| AGX shader generation | Asahi compiler |
| AGX graphics state and command generation | Asahi Gallium, genxml, lib, and libagx |

The project retains every upstream layer needed for that path: Mesa OpenGL
core, state tracker, GLSL, SPIR-V, NIR, generic NIR passes, poly, Gallium
auxiliary code, `gallium/drivers/asahi`, Asahi compiler, genxml, layout, lib,
libagx, and CLC helper-kernel compilation where required. These are framework
dependencies, not templates for AO46 reimplementations.

### Platform Replacement Boundary

Only Linux-specific Asahi platform code is replaced:

| Linux Asahi component | AO46 macOS disposition |
| --- | --- |
| `winsys/asahi/drm` | Replace with AO46 macOS winsys |
| Asahi DRM UAPI, dma-buf, sync-file | Do not ship |
| Linux Asahi kernel GPU driver | Do not ship |
| Apple AGX kernel driver and firmware | Use as supplied by macOS |
| `wrap.dylib` and `agxdecode` | Retain only as development/trace tools |

The preferred lower-level path is Mesa OpenGL -> Asahi Gallium -> AGX userspace
driver -> AO46 Apple-AGX ABI adapter -> Apple's AGX userspace infrastructure ->
IOGPU user client -> Apple's kernel driver -> Apple firmware -> GPU. No Mesa or
Asahi GL semantic code is replaced at this boundary.

The adapter is deliberately not a Metal renderer, an OpenGL-to-Metal
translation layer, or a new GPU operating system. It must pass Asahi-created
resources, contexts, queues, command records, and synchronization requests to
an existing Apple AGX userspace boundary that is low enough to preserve Asahi's
AGX shaders and command generation. Apple infrastructure continues to own the
macOS-specific GPU VM, queue, kernel, firmware, reset, and scheduling contract.

This route is the primary investigation target because it avoids duplicating a
large private UABI per Apple GPU generation. It becomes a runtime path only
after a controlled profile proves all of the following without a Metal command
encoder in the hot path: device/context ownership, resource allocation and GPU
VA, a native command submission, completion/fence delivery, and resource
retirement. Until then, the existing trace-validated direct-UABI work remains a
preserved fallback research path and all native screen creation stays
fail-closed.

The Linux DRM stack is not included in the macOS runtime. In particular,
`src/gallium/winsys/asahi/drm/`, Linux DRM UAPI, dma-buf, sync-file, and the
Linux Asahi kernel driver are not shipped by AO46.

The porting seam is broader than the thin Gallium winsys directory. Current
Mesa sources place DRM-specific BO allocation, GPU-VA binding, queue creation,
submission, and synchronization in `src/asahi/lib/agx_device.c` as well. The
AO46 adapter must satisfy that platform contract without changing the GL
frontend, NIR, or Asahi compiler logic, but it should delegate to Apple's
existing userspace machinery wherever a validated boundary exists.

`AppleNativeAGXBridgePlan.md` defines the required proof points, the adapter
contract, and the non-negotiable fallback policy for that decision.

## Current Native Device Boundary

The macOS platform adapter now initializes Mesa's upstream `agx_device` data
model from one profiled AGX session. It creates traced direct AGX BOs through
Mesa's normal `agx_bo_create` path, retains the GPU VA returned by the native
user client, exposes the validated CPU mapping, and accepts only the exact
fixed binding already established by that direct allocation.

This is not general GPU VM support. Relocatable mappings, unbind, command
submission, and completion-backed synchronization are still rejected. The
framework's native bootstrap owns the same private adapter for lifecycle and
capability diagnostics, releasing it before its BO set is destroyed. The
macOS `agx_screen_create_macos` entry point checks an explicit positive
readiness contract before taking ownership of an adapter, so these partial
operations can never be mistaken for a usable `pipe_screen` or GL context.

For carrier-resource identity, the runtime now has a second, deliberately
separate allocation path. `AppleAGXMetalBOProvider` creates an Apple-owned
CPU-visible allocation first and exposes it to Mesa as an ordinary `agx_bo`.
That single allocation supplies the Mesa mapping and GPU VA as well as the
profile-validated `IOGPUMetalBuffer + 0x40` binding consumed by Apple's carrier
resource list. It replaces neither the raw UABI research BO path nor AGX
submission; it prevents an invalid attempt to bind a raw selector-9 BO as if it
were an unrelated Apple buffer. The provider now declares ordinary CPU-visible
data, USC low-VA placement, and executable shader provenance separately. Only
the data capability is currently proven; the other two remain explicit screen
gates.

`agx_macos_mesa_submission_package` is the first ownership-preserving handoff
from Mesa into the profiled command-record path. It accepts only live
macOS-backed Mesa `agx_bo` subranges, resolves every CPU/GPU address through
the active native BO set, and retains both the native BO pins and the matching
Mesa BO references until retirement. The hardware smoke validates one 64 KiB
Mesa BO as a CPU-mapped record with two disjoint resource ranges. It does not
accept Mesa's Linux `drm_asahi_submit` packet, construct an Apple command
record, enable repeated raw allocation, or submit work.

The native build now removes `xf86drm.h` from the shared `agx_device.h` and
`agx_state.h` headers. Linux DRM calls remain confined to the Linux device,
batch, fence, and pipe implementation files, which is the required separation
before a macOS BO/VM/queue/synchronization implementation can replace them.

## Delivery Order

1. Keep the AO46 framework, CGL, and NSOpenGL frontend connected to Mesa's GL
   frontend. Remove bespoke GL semantics from the critical path rather than
   extending them.
2. Build Mesa/Asahi as a pinned dependency on macOS, retaining upstream OpenGL
   and AGX source without a project-local rewrite.
3. Make the framework select Mesa Asahi only, failing context creation until
   AO46AGXMac has a validated screen implementation.
4. Locate and validate a low-level Apple AGX userspace boundary for device,
   resources, queues, submission, and completion; implement only a thin AO46
   adapter over evidence-backed operations.
5. Retain the direct-UABI prototype as a fail-closed fallback research route
   for operations not proven available through Apple userspace infrastructure.
6. Enable one known macOS-and-SoC profile at a time, compare command traces,
   then run Mesa and Khronos conformance testing before advertising it.
7. Keep GL2MTL archived for source comparison only; do not link or select it
   in production builds.

## Validation Rules

- Mesa derives the advertised GL version and extensions from the active
  backend's verified capability set. AO46 must not force OpenGL 4.6 reporting.
- The macOS AGX UABI is version-profiled and trace-validated. No unvalidated
  OS release may receive raw submissions.
- AO46 does not replace the Apple kernel AGX driver, firmware, scheduler, VM
  manager, power management, or fault handling.
- GL2MTL is an explicit deprecated build target only. Production builds and
  runtime selection do not reference it.

## Current Evidence

Mesa documents `wrap.dylib` as an IOKit tracing tool for the macOS AGX UABI;
it is useful for observation and validation, not evidence that a general
purpose macOS backend already exists. Mesa's Asahi driver is conformant for
OpenGL 4.6 on supported Linux Apple Silicon configurations. That result cannot
be claimed for AO46 until the macOS platform port passes its own test suite.

### Locally Validated Native UABI Profile

The development host currently exposes `AGXAcceleratorG16X` (`gpu,t6040`):
G16S, 20 GPU cores in two clusters, USC generation 3, a 40-bit GPU VA queue
field, and a 1241 MiB parameter-buffer limit. AO46's Darwin-only probe opens
the existing macOS AGX service and performs the observed 64-byte capability
query. The probe itself does not create queues, allocate resources, or submit
commands.

The first native profile gate is complete in the development tooling. The probe
recognizes only the locally validated `t6040-g16s-usc3` combination: chip
`t6040`, GPU generation 16 variant `S`, USC generation 3, observed queue bits
`40/0x7f`, nonzero topology, and a nonzero parameter-buffer limit. Unknown
profiles are rejected before future native winsys operations can be enabled.
This remains a discovery/profile gate, not a raw allocation or submission API.

`agx_macos_device_session_open` is the reusable macOS winsys ownership layer
for that gate. It opens one AGX IOKit user client, snapshots its hardware
identity and selector-0 capability response, accepts only an enabled profile,
and owns the matching close operation. AO46's Asahi backend retains one such
profiled session for its backend lifetime; the development controls use the
same API with short-lived sessions. Opening a session itself only performs
device/profile discovery; later test-only operations have separate gates.

### Test-Only Direct BO Lifecycle

`agx_macos_bo_create` now replays the fully captured allocation contract on the
profiled host: selector 9, a 104-byte request, and the matching 88-byte
response. It supports only the four trace-validated shared sizes (64, 128, 256,
and 512 KiB), changing only the measured 64 KiB unit-count candidate at offset
`0x4a`, plus the traced 64 KiB write-combined and private contracts. The latter
change only the verified attribute or storage bit; private responses must have
no CPU mapping. The adapter verifies a nonzero handle, GPU VA, expected mapping
state, and returned size before exposing the BO; `agx_macos_bo_destroy` releases
that handle through the observed Trap1 index 1 path. The opt-in
`asahi_macos_bo_smoke` hardware probe has successfully allocated and immediately
released every supported contract on `t6040-g16s-usc3`. Its bounded CPU-map
checks also wrote and read sentinels at both ends of every CPU-visible BO,
rejected an out-of-range map, and rejected private BO mapping. This validates
the returned CPU mapping lifetime only; GPU cache visibility is a later
submission-level requirement.

`agx_macos_bo_create_at_least` is the first Mesa-facing allocation policy. It
rounds a request to the smallest trace-validated root BO (64, 128, 256, or
512 KiB for shared allocations; 64 KiB for write-combined/private), validates
the returned GPU VA against a requested power-of-two alignment up to 64 KiB,
and rejects larger or otherwise unsupported requests. The hardware smoke
validated small and cross-bucket requests for all three storage modes. It does
not cache BOs: reuse must wait for real submission completion before it can be
safe.

`agx_macos_bo_set` adds the first explicit direct-resource ownership boundary.
It serializes a bounded set of live direct allocations, rejects duplicate
handles or overlapping GPU ranges, resolves a live resource by handle or an
address within its GPU range, and releases tracked BOs before the session
closes. The hardware smoke held three simultaneous 64 KiB shared BOs with
distinct handles and non-overlapping GPU ranges, then released them in reverse
order. This does not establish a universal 64 KiB GPU-VA alignment guarantee:
the second live allocation was only 32 KiB-aligned, so a concurrent resource
request uses its actual byte-alignment requirement while the stricter policy
test remains separate. The BO set is still a small ownership primitive, not a
Mesa cache or allocator.

This is deliberately not a general allocator. It accepts only the documented
size-and-storage pairs, with no import, export, suballocation, or GPU-VM bind
parameter, and it is not called by the framework, screen factory, or Gallium
driver. It runs only when `AGX_MACOS_EXPERIMENTAL_BO=1` is set and only after
the exact device-profile gate succeeds. Runtime backend selection stays
disabled until this lifecycle is expanded and then validated together with
queue setup, completion, command submission, resource ownership, and cleanup.

### Test-Only API Configuration and Notification Queue Setup

The profile-gated session can now replay the observed selector-7 `SET_API`
initialization: a 1040-byte request containing the client executable path in
both captured locations and the stable `2/-1/1` trailer. The kernel accepts
this request and returns the observed 16-byte configured response. The first
observed reply carries generation 1; a later trace-validated reconfiguration
returns generation 2 before a second queue becomes activatable. The adapter
therefore records a strictly increasing opaque generation rather than treating
configuration as a one-shot action. It is a session-local operation and is not
called by the framework runtime.

With that state present, the test-only notification-queue adapter successfully
creates selector-16's 16-byte data-queue response, allocates and binds its Mach
notification port, and activates it through selector `0x1c`. This proves the
completion-transport setup sequence, not command-queue creation or GPU
submission. The isolated no-submit Metal control establishes notification-queue
teardown as selector `0x08`, local notification-port release, then selector
`0x11`. The direct hardware smoke configures two queues, replays that sequence
for each queue, and completes successfully without relying on session close.

The controlled trace now snapshots notification-port rights at the selector
boundary without interposing Mach. Queue 1 had one receive right immediately
before its selector-`0x08` trace and no valid receive, send, or send-once right
by its selector-`0x11` trace. Selector `0x0f` is absent from the queue-only
no-submit control and rejects direct queue calls, so it is not
notification-queue teardown. It also appears in the uncommitted command-buffer
control below, but its ownership remains opaque and it is intentionally not
issued by the native queue adapter.

The separate `asahi_macos_command_buffer_lifecycle_trace` creates one Metal
device, one command queue, and one command buffer, then releases all three
without encoding or committing work. It observes selector `0x06` and the two
selector-`0x0e` command-pair probes at command-buffer creation, followed by
the established `0x08`/`0x11` queue teardown and opaque `0x0f` values `2` and
`1`. It observes no `IOConnectTrap4`, so it is not a submission trace. The
trace drains a nested autorelease pool because `commandBuffer` is autoreleased;
this releases the command buffer before its owning queue. The notification-port
sampler is valid for this control and remains enabled by default.

`asahi_macos_empty_submission_trace` is the first controlled submission
reference. It creates one command buffer, encodes no commands and no resources,
commits it, and waits for `MTLCommandBufferStatusCompleted`. On the profiled
host, that produces one successful index-zero `IOConnectTrap4`: its first
argument is the observed queue ID `1`, the descriptor is 0x40 bytes, and the
auxiliary pointer is 0x84 bytes after the descriptor. The descriptor reports
header words `2/1` and two opaque completion tokens; the notification queue
then returns two 40-byte records with exactly those tokens. This validates an
empty Metal submission reference only. Descriptor field meanings, auxiliary
sidecar ownership, completion-record layout, and direct Trap4 replay remain
unimplemented and forbidden in the AO46 runtime.

A two-queue empty-submission control validates the queue association. Its two
successful Trap4 calls use first arguments `1` and `2`, matching their distinct
notification queue IDs. Both descriptors retain header words `2/1`; however,
their two completion tokens recur in reverse order between queues. The UABI
observation layer therefore identifies a completion by the pair of its queue
ID and token, never by token alone. It decodes the observed 0x40-byte descriptor
and matches the leading 64-bit token of a 40-byte completion record, but it
cannot submit, allocate, bind, or wait on GPU work.

The two-buffer companion control creates two uncommitted command buffers from
the same queue. Selector `0x06` occurs only for the first buffer, while the
`0x0e` `0x4000/0` and `0x4000/1` pair repeats for each buffer. After queue
teardown, four opaque `0x0f` calls occur (`2`, `4`, `1`, and `3`), compared
with two for the single-buffer control. A two-queue companion then creates one
uncommitted buffer on each queue: the first queue emits `0x06` and the two
`0x0e` calls, while the second emits neither. Consequently, the selector scope
depends on unmodeled Metal state; the test-only winsys retains only the initial
three-call sequence and does not provide a generic per-buffer operation. It
does not assign meanings to any returned pair or `0x0f` value, and it does not
issue either selector from the framework runtime.

The adapter can now snapshot the returned `IODataQueueMemory` with acquire
loads. The direct hardware probe reconfigured the API generation, then created
and activated two distinct notification queues, each with a nonzero capacity
and an empty `head == tail` ring. It released their local Mach ports and
immediately closed the owning AGX session. This is a safe test cleanup strategy,
not a standalone queue-destruction implementation; runtime queues remain
disabled until command-queue ownership and submission contracts are verified.

`agx_macos_notification_queue_poll` now uses the public IODataQueue client
operation to dequeue one future completion record without blocking. A typed
40-byte `agx_macos_completion_record` matches the only observed completion
record size and rejects any other successful dequeue size. It peeks and checks
the next public `IODataQueueEntry` before moving the ring head, so an unknown
record remains queued rather than being consumed. The bounded drain helper
uses the same single-consumer contract. The direct probe validates typed peek,
poll, and empty drain as `kIOReturnUnderrun` or zero records on both queues;
consuming actual completion records remains blocked on command submission.

### Test-Only Command-Infrastructure Initialization

The native winsys can replay only the initial three-call pre-submit sequence
observed for the first command buffer in the single-queue control: selector 6
with no input, followed by selector `0x0e` with scalar pairs `0x4000/0` and
`0x4000/1`. Each call returns a nonzero opaque 16-byte pair. The opt-in
`asahi_macos_command_smoke` validates that one initial sequence on the
profiled host after session configuration and notification-queue setup. The
two-buffer trace proves the `0x0e` pair can repeat, while the two-queue control
shows the scope still depends on unmodeled Metal state. Consequently this
replay is isolated to the explicit smoke and is not initialized by the native
screen bootstrap or framework runtime. It records the initial pairs with the
active API generation but does not assign field meanings to them.

This is command infrastructure only. It creates no Mesa command queue, does not
allocate a command buffer, does not build a Trap4 descriptor, and cannot submit
GPU work. Its queue setup and no-submit queue teardown are now validated, but
the command infrastructure itself has no resource or submission lifecycle. It
is not called by the framework runtime.

The macOS Meson configuration now builds the upstream Gallium Asahi archive and
the generic Asahi support archive without compiling Linux's `agx_device.c` or
`agx_device_virtio.c`. Those units remain unchanged and are selected only for
KMS/DRM builds. This is a build boundary, not a replacement device backend:
attempting to create a native screen remains blocked until AO46AGXMac provides
the BO, VM, queue, submission, and completion operations.

The production CMake framework now closes over this Mesa archive set, including
Mesa's LLVM and BLAKE3 dependencies, with `OPENGLKHR_BUILD_DEPRECATED_GL2MTL`
off. Because the current factory fails before `agx_screen_create`, static-link
selection does not make AGX execution code active in the framework yet. The
successful framework link proves dependency closure only; it is not evidence
of native rendering or OpenGL conformance on macOS.

`src/asahi/lib/tests/agx_macos_trace_control.m` is a development-only workload
for that next gate. It creates 4 KiB, 64 KiB, 128 KiB, 256 KiB, and 512 KiB
shared buffers, plus 64 KiB shared-write-combined and private transfer
resources; then it transfers data through the 64 KiB resources on two Metal
command queues, checks the copied bytes, releases the private allocation, and
creates one shared allocation for a controlled reuse sample.
`Apple_ICD/scripts/capture_agx_trace_control.sh` builds it with Mesa's
`wrap.dylib` and records allocation, raw request, queue, Trap4, and completion
observations. Its opt-in notification-port records identify the exact
  receive, send, and send-once right counts around each proven AGX
  queue-lifecycle selector. This captures the port state visible at `0x08` and
  `0x11` without interposing Mach itself. Selector `0x0f` is opaque and does
  not trigger a notification-port lookup. Before it creates a Metal device, the trace
workload itself opens, validates, closes, and reopens the direct AGX IOKit user
client.
For this trace target only, the capture script also runs
`Apple_ICD/scripts/verify_agx_resource_ownership_trace.sh`. The verifier maps
the dynamic allocation handles from the trace markers and requires the producer
submission to reference the source and private buffers, while the consumer must
reference private, write-combined staging, and destination buffers on a distinct
queue. It also requires the same CPU-mapped internal record to carry both
resource sets at the observed offsets `0x00`, `0x08`, `0x20`, and `0x28`, and
requires the private allocation to be recycled only after both completion pairs.
This is a regression gate for the controlled workload, not a decoded general
command-resource ABI.
`asahi_macos_resource_record_variation_trace` extends that evidence without
changing the baseline trace: it transfers 4 KiB through a simple shared/private
copy and 128 KiB through a shared/private/write-combined two-step copy. Its
dedicated verifier requires one CPU-mapped record to carry all four submissions
on the same two queue identities, with the same observed prefix roles. The 4
KiB allocation replies may be internal suballocations with opaque metadata, so
the control validates only the resource-reference relationship and successful
data transfer, not their allocation-record field meanings.
`asahi_macos_resource_record_range_trace` then copies 8 KiB through two queues
with source, private, staging, and destination offsets of `0x1000`, `0x3000`,
`0x5000`, and `0x7000`. Its verifier confirms that the same blit record slots
retain their resource roles and that their observed GPU deltas equal those byte
offsets. This is evidence that the captured values are GPU addresses plus
resource offsets for this blit profile, not a general field definition.
`asahi_macos_compute_resource_record_trace` compiles a small Metal kernel and
validates its input/output transform. It finds the app buffers in a distinct
CPU-mapped record at offsets `0x1ba0` and `0x1ba8`; another record references
pipeline-owned resources and remains opaque. The compute and blit record shapes
must therefore remain separate until broader controls establish a common model.
Set `AGX_TRACE_TRAP_PAYLOADS=1` to dump a bounded Trap4 descriptor; any other
value, including the default `0`, leaves that payload dump disabled.
`src/asahi/lib/tests/agx_macos_queue_lifecycle_trace.m` is the corresponding
no-submit control: it creates one Metal device and two command queues, then
releases them with explicit trace markers. Set
`OPENGLKHR_TRACE_TARGET=asahi_macos_queue_lifecycle_trace` when invoking the
capture script to isolate command-queue setup and teardown from resource and
submission traffic.
Neither the trace workload nor the standalone `asahi_macos_winsys_probe` is
linked into the AO46 framework or used for runtime rendering.

The CGL-to-Mesa state-tracker path also has a strict profile contract. AO46
maps its supported CGL core profiles (3.2, 4.1, and 4.6) directly to Mesa's
`st_context_attribs`; Mesa accepts or rejects the exact requested minimum
version. AO46 no longer lowers a CGL 4.6 request to a lower-capability screen.
The focused profile-negotiation smoke test confirms that a 4.6 request is
either created at 4.6 or rejected explicitly. The native runtime currently
uses the rejection branch while its winsys is incomplete.

Controlled Metal traces on that profile establish the following observation
contract for the development tools:

- Resource allocation uses selector 9 with a 104-byte request and an 88-byte
  reply. Shared, write-combined, and private Metal buffers expose distinct
  verified attribute/storage bits; a private allocation has no CPU mapping.
- Fresh-process traces produce byte-identical 104-byte requests for each
  direct 64 KiB, 128 KiB, 256 KiB, and 512 KiB control allocation. In that
  sample, the
  write-combined request differs from its shared counterpart only in the
  verified attribute bit and the private request only in the verified storage
  bit. The direct size sequence changes an otherwise opaque little-endian
  16-bit quantity at byte offset `0x4a` as `1`, `2`, `4`, and `8`; it is a
  measured 64 KiB-unit-count candidate, not a decoded UABI field. A 4 KiB
  shared Metal buffer instead follows an internal suballocation path whose
  backing request differs across fresh processes, so it is excluded from the
  direct request schema.
- The development trace workload opens and closes the direct `AGXAccelerator`
  user client twice before it creates its Metal device. On the profiled host,
  both opens identify
  `AGXAcceleratorG16X` as `t6040-g16s-usc3` and return an identical 64-byte
  selector-0 capability response; the following Metal allocations retain the
  direct `1/2/4/8` size-unit sequence. This proves profile/capability stability
  across a user-client reopen, not the semantics of an allocation selector or
  authorization to replay one.
- Fresh-process empty-command-buffer and blit controls both make one selector
  6 call with no input and a 16-byte reply, followed by two selector `0x0e`
  calls with scalar inputs `0x4000/0` and `0x4000/1` and 16-byte replies.
  Those calls happen while Metal obtains the first command buffer, before the
  test begins encoding. The two-buffer no-submit control establishes the
  narrower lifecycle rule: selector 6 is first-buffer initialization, while
  the `0x0e` `0x4000/0,1` pair repeats when the same queue obtains a second
  uncommitted command buffer. The trace verifier enforces that observation and
  rejects any Trap4 or completion event. The calls remain only
  command-infrastructure observations, not resource binding, command encoding,
  or a submission interface.
- A submitted Metal command buffer, including an empty one, reaches the AGX
  service through `IOConnectTrap4(index = 0)`, not through the historical
  selector-based submit interface.
- The observed trap takes a queue value, a 64-byte descriptor, and two
  process pointers. Two changing 64-bit values in that descriptor are echoed
  as the leading values of completion data-queue records. The remaining
  descriptor and auxiliary fields remain opaque until independently decoded.
- Detailed traces now correlate those two descriptor values directly with the
  completion records on the queue selected by the trap. They are completion
  transport tokens, not durable fence IDs: completed submissions may reuse or
  reverse the same pair, including on a different queue. The descriptor's two
  leading 32-bit fields also vary with workload/lifetime and remain opaque.
- The auxiliary trap pointer has been observed at descriptor offset `0x84` in
  controlled empty, blit, and cross-queue traces. A development-only bounds
  check confirms a readable 256-byte prefix and shows workload-dependent
  contents. AO46 does not assign field meanings or consume that block at
  runtime.
- The auxiliary analyzer records a per-queue baseline and reports changed byte
  ranges. Empty-only submissions change the same ranges as a blit submission,
  and no aligned value in the traced prefix directly matched a live allocation
  CPU or GPU range. Those bytes are therefore ordinary submission churn, not
  yet evidence of resource references.
- Linux's `drm_asahi_submit` is useful as a semantic reference for the Asahi
  platform seam, but it is not the macOS Trap4 layout: the observed 64-byte
  descriptor and 256-byte auxiliary prefix have different shape and ownership.
  AO46 must not copy Linux DRM field definitions into this UABI.
- An opt-in 4 KiB bounds-checked scan and one-hop scan of readable auxiliary
  pointers found no direct or indirect live allocation CPU/GPU references in
  the controlled cross-queue copy. The observed readable targets are stable
  framework-side links, not a validated resource list. AO46 must therefore
  locate command-resource ownership through a separate traced interface rather
  than treating the Trap4 sidecar as a Mesa/Asahi submission payload.
- Each controlled Metal command queue creates a distinct modern notification
  queue. Selector `0x10` receives the scalar pair `0x100, 0x28` and returns a
  16-byte record containing a mapped completion data-queue address and queue
  ID. macOS then binds a notification port with type zero and that ID as its
  reference, invokes selector `0x1c` with the ID twice, and supplies the same
  ID as `IOConnectTrap4`'s first parameter. Two-queue traces verified IDs 1
  and 2 independently through this whole path.
- A no-submit two-queue control validates selector `0x08`, local notification
  port release, and selector `0x11` as the notification-queue teardown path.
  Selector `0x0f` is absent from that control but occurs during fuller
  workloads with a queue-like scalar; it remains opaque and is not part of the
  AO46 notification-queue adapter.
- A controlled two-queue buffer handoff verified resource ownership through
  the real AGX path: four simultaneous 64 KiB shared, write-combined, private,
  and shared buffers received separate handles; queue 1 copied through the
  private buffer and queue 2 copied from it into host-visible memory. The
  returned bytes matched after both command buffers completed.
- A separate opt-in diagnostic scan fingerprints at most 64 KiB of each
  CPU-mapped allocation at the Trap4 boundary and searches changed mappings
  for direct GPU VAs of other live allocations. Fresh empty-command controls
  report no such references. A controlled blit reports one exact edge from
  allocation handle 23 at byte offset `0x28` to the GPU base of handle 21;
  in an empty/blit/empty sequence the edge appears only for the blit. Overlap
  between root allocations and suballocations is resolved to the exact base
  or tightest matching range before it is reported. This is a promising
  command-resource ownership candidate, not a decoded command format or a
  runtime submission contract.
- The modern allocation reply provides the CPU mapping when one exists; the
  profiled path did not call `IOConnectMapMemory64` for these buffers. A later
  shared allocation reused the released private buffer's handle and GPU VA but
  returned a new CPU mapping and storage attributes. Trace state therefore
  replaces records on handle reuse instead of treating a handle as a permanent
  resource identity.

This is a host-and-OS-specific trace record, not a portable AGX UABI contract.
`wrap.dylib` can inspect these payloads only when
`AGX_TRACE_TRAP_PAYLOADS=1`; it caps the diagnostic read at 4096 bytes. No
AO46 runtime code may issue an allocation or submission until every field it
uses has a validated definition and an explicit profile gate.

`capture_agx_uabi_profile.sh` now runs empty, two-queue, blit, compute,
render, and IOSurface controls as one transport-profile suite. Its generic
verifier requires the traced `IOConnectTrap4(index = 0)` call, a 64-byte
descriptor, queue-scoped `2/1` outer header, a carrier at offset `132`, two
matching 40-byte completions, and a bounded 4 KiB sidecar capture with the
observed `0x1ff800000` pointer slot. This completes the *observed outer UABI
transport profile* for the currently profiled device. It does not complete the
opaque sidecar's command/resource schema, so it deliberately does not expose a
direct-submit routine or enable the native Mesa screen.

The wrapper can additionally emit a complete bounded 4 KiB carrier as an
opt-in hexadecimal trace record. The nine-workload UABI profile now requires
one complete hexadecimal record per submission and stores a layout report for
each workload. `analyze_agx_sidecar_layout.sh` reports its stable and varying
64-bit word locations across controlled captures without assigning
undocumented semantics. That evidence confirmed that the sidecar is not the
resource table. Instead, AO46 now has a range-authorized encoder for
the independently traced CPU-mapped command records: blit producer addresses
at `0x0/0x8`, blit consumer addresses at `0x0/0x8/0x20/0x28`, and compute
addresses at `0x1ba0/0x1ba8`. It verifies the full requested GPU-VA range
against the native BO set before modifying any word. These layouts are
resource-record encoders only, not an AGX command-stream or sidecar decoder.
The accompanying Trap4 preview builder copies intact captured descriptor and
carrier evidence into the observed `queue, 64, descriptor, descriptor+0x84`
argument shape, verifies it, and has no dispatch API. A preview is explicitly
non-submittable, preventing stale process-local pointers from becoming replay.
The submission package composes a CPU-mapped command record, its explicit
backing-BO range, resource ranges, BO pins, immutable carrier, and preview in
one fail-closed admission unit. It cannot be created without the record range
and still has no direct-submit operation.

The profile also records at most the already-readable 512-byte target of each
sidecar pointer and checks that every target capture is ordered after its
originating pointer observation. Its pointer-layout report is keyed by the
sidecar offset and classifies target words as stable or varying. Neither the
capture nor the report exposes target bytes to the runtime or treats a pointer
as an AGX object/resource binding.

Current nine-workload evidence classifies the observed `0x368`, `0x790`,
`0xa58`, and `0xab8` pointer targets as bounded ASCII C-string tables with no
tracked GPU-resource references. They are host-process metadata, not resource
table candidates. The verifier rejects a new or changed classification instead
of allowing the future direct-submit path to interpret a dangling host pointer.

The first resource-type, two-queue, size-scaling, and lifetime controls now
confirm that the candidate mapped-allocation edges track the requested workload
resources. The direct BO lifecycle gate owns a small concurrent shared-BO set,
API-generation-aware notification queue setup, and pre-submit command
infrastructure are proven separately. Command-queue ownership, command-buffer
lifecycle state, one empty Trap4 submission, and a non-empty two-queue blit
with trace-validated resource ownership are now captured by controlled traces.
The blit control additionally establishes one CPU-mapped resource-record prefix
and private-BO completion/reuse lifecycle. A separate 4 KiB and 128 KiB
variation control confirms the same prefix roles across simple and two-step
copies, including write-combined staging. Non-zero blit ranges prove the
captured GPU deltas track public byte offsets, while a compute encoder uses a
different app-buffer record region and separate pipeline-owned records.
`asahi_macos_compute_resource_range_trace` now binds a 64 KiB input buffer at
`0x1000` and a 64 KiB output buffer at `0x3000`; its trace verifies the compute
record's `0x1ba0` and `0x1ba8` entries preserve those byte offsets.
`asahi_macos_render_resource_record_trace` also establishes a separate native
render control: it renders a fullscreen triangle to a 64x64 shared RGBA8 target
and verifies every readback pixel as `(64, 128, 191, 255)`. Its trace verifier
confirms the color-target allocation, one `2/1` render submission, and two
completion records. The generic mapped-address scan does not directly expose
the color target, so render descriptor/resource-list internals are deliberately
treated as opaque rather than inferred from unrelated allocations.
Both render controls now verify their submission's outer auxiliary-descriptor
carrier: it is observed at byte offset `132` from the 64-byte submit record and
has a readable 256-byte prefix. This is only a stable transport boundary; the
contents are not assigned resource-list field meanings.
`asahi_macos_render_resource_lifecycle_trace` extends that control with two
successive shared color targets on one queue. It verifies target A's pixels and
two completion records before releasing it, then allocates, renders, and
verifies target B with its own completion pair. Its verifier reports whether
the second public Metal allocation happened to reuse the first handle, but does
not require either reuse or uniqueness as an ABI rule. The next native winsys
gate is targeted render descriptor tracing plus record lifetime and
synchronization modelling. `asahi_macos_render_descriptor_variation_trace`
holds a 64x64 target live for two identical submissions, then adds a distinct
live 128x32 target with the same 16 KiB pixel payload. It records one baseline
and two changed auxiliary snapshots while verifying all three pixel readbacks,
submissions, and completion pairs. Fresh-process comparisons did not isolate a
stable changed inner range, so those bytes remain diagnostic evidence rather
than an ABI definition. Runtime backend selection remains disabled until those
relationships are independently validated.

### Context And Submission Admission

`agx_macos_submission_fence` owns one observed queue and its two completion
tokens. It accepts each matching 40-byte completion record once, rejects
duplicate or wrong-queue records, and completes only after both tokens arrive.
`agx_macos_notification_queue_poll_fence` peeks before it consumes: an
unmatched, malformed, or duplicate record remains queued rather than being
lost by the wrong submission owner. `agx_macos_bo_set` also supports range
retention and range release, so a future command may pin only a GPU
virtual-address range that is wholly contained by one tracked BO.
`agx_macos_bo_set` now pins BO handles while a future submission may reference
them; direct destroy and set cleanup return busy until the pin is released. The
profiled direct-BO smoke exercises that lifetime rule on hardware.
`agx_macos_submission_lease` joins those pins to one observed two-token fence:
it retains every full GPU-VA range before admission, rolls all pins back if a
later range is invalid, rejects wrong-queue completions, and releases only when
both valid tokens arrive. It is deliberately an admission-and-retirement layer,
not a Trap4 descriptor builder or submit call.
`agx_macos_notification_queue_poll_lease` connects one known queue record to
that retirement path without consuming foreign or duplicate records. It is
compiled into the framework and its lease behavior is covered by smoke tests;
end-to-end direct-queue polling remains pending until AO46 owns a validated
submission descriptor and can safely generate its completion records.

`agx_macos_iosurface` is the reusable macOS drawable primitive: it creates a
RGBA8 IOSurface with explicit CPU-read lock ownership and refuses reuse of a
live object. `asahi_macos_iosurface_drawable_trace` creates that 64x64 surface,
imports it as a Metal render target, clears it, and validates the CPU-visible
pixels. Its wrapped hardware trace preserves the established outer `2/1`
submission shape, the 132-byte auxiliary carrier offset, and two completion
records. This is drawable import/export groundwork only: it does not yet
implement a CAMetalLayer acquire/present lifecycle or unblock framework
presentation.

AO46 now exposes named context blockers instead of creating a partial context:
a profiled AGX session is present, but `macos-pipe-screen`,
`validated-agx-submission`, and `iosurface-presentation` remain required.
This does not enable direct Trap4 replay. Mesa's upstream `agx_screen_create`
takes a Linux DRM file descriptor and cannot be called from the macOS framework
until the AO46 macOS winsys supplies an equivalent native screen implementation.

The Gallium implementation now separates that Linux fd/DRM acquisition from
the downstream screen finalization. The shared finalization retains upstream
Asahi's real pipe-screen callbacks, NIR/compiler configuration, capability
initialization, resource transfer setup, fences, and context creation hooks.
`agx_screen_create_macos` now exposes that macOS handoff and transfers one
fully initialized native `agx_device` into the same finalization path. It
requires real BO allocation, binding, mapping, parameter, object-binding, and
submit operations, and it fails cleanly if completion-backed synchronization
is unavailable. The framework cannot call it yet: substituting an IOKit
`io_connect_t` for the Linux fd is invalid. The native initializer still
requires trace-validated global parameters, GPU VM setup, Mesa `agx_bo`
adaptation, command-queue creation, direct submission encoding, and
completion-backed synchronization.

References:

- https://docs.mesa3d.org/drivers/asahi.html
- https://asahilinux.org/2024/02/conformant-gl46-on-the-m1/
- `OpenGL_4.6(Core Profile)/mesa/src/asahi/lib/agx_device.c`
- `OpenGL_4.6(Core Profile)/mesa/src/gallium/drivers/asahi/`
