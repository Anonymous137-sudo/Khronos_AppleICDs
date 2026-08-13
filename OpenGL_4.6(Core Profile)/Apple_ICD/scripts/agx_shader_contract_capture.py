"""Read-only LLDB callbacks for Apple AGX shader-contract investigation."""

import hashlib
import lldb
import os


_pending_returns = {}
_return_breakpoints = {}
_pending_usc_descriptor_returns = {}
_usc_descriptor_return_breakpoints = {}
_pending_command_returns = {}
_command_return_breakpoints = {}
_open_storage_segments = {}
_pending_queue_argument_returns = {}
_queue_argument_return_breakpoints = {}
_pending_resource_gpu_address_returns = {}
_resource_gpu_address_return_breakpoints = {}
_pending_variant_finalize_returns = {}
_variant_finalize_return_breakpoints = {}
_usc_spill_internal_buffers = set()
_pending_internal_buffer_grow_returns = {}
_internal_buffer_grow_return_breakpoints = {}
_pending_internal_buffer_gpu_address_returns = {}
_internal_buffer_gpu_address_return_breakpoints = {}
_pending_compute_variant_constructor_returns = {}
_compute_variant_constructor_return_breakpoints = {}
_pending_heap_true_allocate_returns = {}
_heap_true_allocate_return_breakpoints = {}
_pending_variant_first_heap_selections = []
_variant_selected_bases = {}
_variant_devices = {}
_variant_compiler_replies = {}
_link_info_compiler_replies = {}
_pending_iogpu_pool_create_returns = {}
_iogpu_pool_create_return_breakpoints = {}
_pending_code_heap_returns = {}
_code_heap_return_breakpoints = {}
_active_code_heap_allocations = {}
_apple_resource_policies = {}
_apple_resource_labels = {}
_iogpu_symbolic_breakpoints = {}
_agx_startup_symbolic_breakpoints = {}
_agx_startup_profile_breakpoints = {}
_pending_usc_async_returns = {}
_usc_async_return_breakpoints = {}
_agx_module_base = 0
_agx_startup_event_sequence = 0


# These are the return PCs for calls made directly by the profiled G16X
# ComputeProgramVariant constructor. They identify allocation ownership only;
# their surrounding object slots are never replayed as an ABI.
_COMPUTE_VARIANT_HEAP_TRUE_RETURN_OFFSETS = {
    0x68DCFC,
    0x68DDE8,
    0x68DEAC,
    0x68DF7C,
    0x690828,
    0x690A80,
}


def _register(frame, name):
    value = frame.FindRegister(name)
    return value.GetValueAsUnsigned() if value.IsValid() else 0


def _thread_id(frame):
    """Return a stable key for read-only nested lifecycle correlation."""
    return frame.GetThread().GetThreadID()


def _stack_prefix(frame):
    stack_pointer = _register(frame, "sp")
    if not stack_pointer:
        return "unavailable"

    error = lldb.SBError()
    data = frame.GetThread().GetProcess().ReadMemory(stack_pointer, 0x20, error)
    return data.hex() if error.Success() and len(data) == 0x20 else "unavailable"


def _stack_word(frame, index):
    """Read one caller ABI argument word spilled after x0..x7 on arm64."""
    # A breakpoint may resolve after the callee prologue, where `sp` already
    # points at callee-local storage. LLDB's CFA recovers the incoming stack
    # boundary, which is where the AAPCS stack-passed arguments reside.
    stack_pointer = frame.GetCFA()
    if not stack_pointer:
        return 0

    error = lldb.SBError()
    data = frame.GetThread().GetProcess().ReadMemory(
        stack_pointer + (index * 8), 8, error
    )
    return int.from_bytes(data, "little") if error.Success() and len(data) == 8 else 0


def _memory_prefix(frame, address, byte_count):
    if not address:
        return "unavailable"

    error = lldb.SBError()
    data = frame.GetThread().GetProcess().ReadMemory(address, byte_count, error)
    return data.hex() if error.Success() and len(data) == byte_count else "unavailable"


def _memory_digest(frame, address, byte_count):
    """Compare opaque policy records without retaining their private bytes."""
    if not address:
        return "unavailable"

    error = lldb.SBError()
    data = frame.GetThread().GetProcess().ReadMemory(address, byte_count, error)
    if not error.Success() or len(data) != byte_count:
        return "unavailable"
    return hashlib.sha256(data).hexdigest()[:16]


def _cstring_prefix(frame, address, byte_count=128):
    """Read an Apple-produced diagnostic label without invoking Objective-C."""
    if not address:
        return "unavailable"

    error = lldb.SBError()
    data = frame.GetThread().GetProcess().ReadMemory(address, byte_count, error)
    if not error.Success() or not data:
        return "unavailable"

    value = data.split(b"\0", 1)[0]
    if not value or any(byte < 0x20 or byte > 0x7e for byte in value):
        return "unavailable"
    return value.decode("ascii")


def _word_at(frame, address):
    if not address:
        return 0

    error = lldb.SBError()
    data = frame.GetThread().GetProcess().ReadMemory(address, 8, error)
    return int.from_bytes(data, "little") if error.Success() and len(data) == 8 else 0


def _dword_at(frame, address):
    if not address:
        return 0

    error = lldb.SBError()
    data = frame.GetThread().GetProcess().ReadMemory(address, 4, error)
    return int.from_bytes(data, "little") if error.Success() and len(data) == 4 else 0


def _agx_offset(address):
    if not _agx_module_base or address < _agx_module_base:
        return 0

    return address - _agx_module_base


def _next_startup_event_sequence():
    global _agx_startup_event_sequence
    _agx_startup_event_sequence += 1
    return _agx_startup_event_sequence


def _schedule_return(frame, kind):
    process = frame.GetThread().GetProcess()
    target = process.GetTarget()
    return_address = _register(frame, "x30")

    if not return_address:
        return False

    if return_address not in _return_breakpoints:
        breakpoint = target.BreakpointCreateByAddress(return_address)
        breakpoint.SetScriptCallbackFunction(
            "agx_shader_contract_capture.capture_static_return"
        )
        _return_breakpoints[return_address] = breakpoint.GetID()
        _pending_returns[return_address] = []

    _pending_returns[return_address].append(kind)
    return True


def capture_static_return(frame, _bp_loc, _internal_dict):
    pending = _pending_returns.get(frame.GetPC(), [])
    # Calls sharing a return address can nest. Match the active callee first
    # rather than treating the pending set as a FIFO queue.
    kind = pending.pop() if pending else "unknown"
    result = _register(frame, "x0")
    print(
        "AO46_AGX_SHADER_CONTRACT_RETURN "
        f"kind={kind} result={result:#018x} "
        f"bytes={_memory_prefix(frame, result, 0x100)}"
    )
    return False


def _schedule_usc_descriptor_return(frame, descriptor):
    """Snapshot the descriptor after the pure USC helper has populated it."""
    process = frame.GetThread().GetProcess()
    target = process.GetTarget()
    return_address = _register(frame, "x30")

    if not return_address or not descriptor:
        return False

    if return_address not in _usc_descriptor_return_breakpoints:
        breakpoint = target.BreakpointCreateByAddress(return_address)
        breakpoint.SetScriptCallbackFunction(
            "agx_shader_contract_capture.capture_usc_descriptor_return"
        )
        _usc_descriptor_return_breakpoints[return_address] = breakpoint.GetID()
        _pending_usc_descriptor_returns[return_address] = []

    _pending_usc_descriptor_returns[return_address].append(descriptor)
    return True


def capture_usc_descriptor_return(frame, _bp_loc, _internal_dict):
    pending = _pending_usc_descriptor_returns.get(frame.GetPC(), [])
    descriptor = pending.pop() if pending else 0
    print(
        "AO46_AGX_SHADER_USC_RETURN "
        "kind=usc-spill-descriptor "
        f"descriptor={descriptor:#018x} "
        f"descriptor_bytes={_memory_prefix(frame, descriptor, 0x48)}"
    )
    return False


def _schedule_command_return(frame):
    process = frame.GetThread().GetProcess()
    target = process.GetTarget()
    return_address = _register(frame, "x30")

    if not return_address:
        return False

    if return_address not in _command_return_breakpoints:
        breakpoint = target.BreakpointCreateByAddress(return_address)
        breakpoint.SetScriptCallbackFunction(
            "agx_shader_contract_capture.capture_new_command_return"
        )
        _command_return_breakpoints[return_address] = breakpoint.GetID()
        _pending_command_returns[return_address] = 0

    _pending_command_returns[return_address] += 1
    return True


def capture_new_command_return(frame, _bp_loc, _internal_dict):
    pending = _pending_command_returns.get(frame.GetPC(), 0)
    if pending:
        _pending_command_returns[frame.GetPC()] = pending - 1
    command_record = _register(frame, "x0")
    print(
        "AO46_AGX_SHADER_COMMAND_RETURN "
        "kind=new-command "
        f"command_record={command_record:#018x} "
        f"segment_header={command_record - 8 if command_record else 0:#018x} "
        f"segment_header_bytes={_memory_prefix(frame, command_record - 8, 8)} "
        f"record_bytes={_memory_prefix(frame, command_record, 0x180)}"
    )
    return False


def _capture_buffer_constructor(frame, kind):
    # Objective-C uses x0/x1 for self/_cmd. The remaining values are captured
    # only as the live Apple call ABI; they are not interpreted as an AO46
    # constructor layout or replayed by this tool.
    print(
        "AO46_AGX_SHADER_CONTRACT_CALL "
        f"kind={kind} "
        f"self={_register(frame, 'x0'):#018x} "
        f"device={_register(frame, 'x2'):#018x} "
        f"length={_register(frame, 'x3'):#018x} "
        f"alignment={_register(frame, 'x4'):#018x} "
        f"pointer_tag={_register(frame, 'x5'):#018x} "
        f"options={_register(frame, 'x6'):#018x} "
        f"register7={_register(frame, 'x7'):#018x} "
        f"stack0={_stack_word(frame, 0):#018x} "
        f"stack1={_stack_word(frame, 1):#018x} "
        f"stack={_stack_prefix(frame)}"
    )
    return False


def capture_buffer_pinned_location(frame, _bp_loc, _internal_dict):
    # The location is the first stack argument: x7 is the preceding
    # isSuballocDisabled argument for this Objective-C signature.
    _capture_buffer_constructor(frame, "buffer-pinned-location")
    print(
        "AO46_AGX_SHADER_PLACEMENT "
        "kind=pinned-location "
        f"suballoc_disabled={_register(frame, 'x7'):#018x} "
        f"pinned_location={_stack_word(frame, 0):#018x}"
    )
    return False


def capture_buffer_pinned_address(frame, _bp_loc, _internal_dict):
    # Both the deallocator and fixed GPU address spill past x7 for this
    # signature. The second word is the requested address, if any.
    _capture_buffer_constructor(frame, "buffer-pinned-address")
    print(
        "AO46_AGX_SHADER_PLACEMENT "
        "kind=pinned-address "
        f"deallocator={_stack_word(frame, 0):#018x} "
        f"pinned_address={_stack_word(frame, 1):#018x}"
    )
    return False


def capture_buffer_address_ranges(frame, _bp_loc, _internal_dict):
    return _capture_buffer_constructor(frame, "buffer-address-ranges")


def capture_buffer_resource_in_args_basic(frame, _bp_loc, _internal_dict):
    # initWithDevice:length:alignment:options:isSuballocDisabled:
    # resourceInArgs:pinnedGPULocation:. `resourceInArgs` is in x7 and the
    # location spills at the incoming caller stack boundary.
    resource_args = _register(frame, "x7")
    print(
        "AO46_AGX_SHADER_RESOURCE_CONSTRUCTOR "
        "kind=resource-in-args-basic "
        f"device={_register(frame, 'x2'):#018x} "
        f"length={_register(frame, 'x3'):#018x} "
        f"alignment={_register(frame, 'x4'):#018x} "
        f"options={_register(frame, 'x5'):#018x} "
        f"suballoc_disabled={_register(frame, 'x6'):#018x} "
        f"resource_args={resource_args:#018x} "
        f"pinned_location={_stack_word(frame, 0):#018x} "
        f"resource_args_bytes={_memory_prefix(frame, resource_args, 0x68)}"
    )
    return False


def capture_buffer_resource_in_args_tagged(frame, _bp_loc, _internal_dict):
    # initWithDevice:length:alignment:pointerTag:options:isSuballocDisabled:
    # resourceInArgs:pinnedGPULocation:. The last two values spill after x7.
    resource_args = _stack_word(frame, 0)
    print(
        "AO46_AGX_SHADER_RESOURCE_CONSTRUCTOR "
        "kind=resource-in-args-tagged "
        f"device={_register(frame, 'x2'):#018x} "
        f"length={_register(frame, 'x3'):#018x} "
        f"alignment={_register(frame, 'x4'):#018x} "
        f"pointer_tag={_register(frame, 'x5'):#018x} "
        f"options={_register(frame, 'x6'):#018x} "
        f"suballoc_disabled={_register(frame, 'x7'):#018x} "
        f"resource_args={resource_args:#018x} "
        f"pinned_location={_stack_word(frame, 1):#018x} "
        f"resource_args_bytes={_memory_prefix(frame, resource_args, 0x68)}"
    )
    return False


def capture_buffer_external_storage(frame, _bp_loc, _internal_dict):
    # gpuAddress: constructors are plausible import candidates. Do not infer
    # which word is a GPU address until a controlled live call is observed.
    return _capture_cpp_factory(frame, "buffer-external-storage")


def capture_compute_pipeline_factory(frame, _bp_loc, _internal_dict):
    print(
        "AO46_AGX_SHADER_CONTRACT_CALL "
        "kind=compute-pipeline-factory "
        f"self={_register(frame, 'x0'):#018x} "
        f"descriptor={_register(frame, 'x2'):#018x} "
        f"error_out={_register(frame, 'x3'):#018x}"
    )
    return False


def capture_command_allocator_factory(frame, _bp_loc, _internal_dict):
    print(
        "AO46_AGX_SHADER_CONTRACT_CALL "
        "kind=command-allocator-factory "
        f"self={_register(frame, 'x0'):#018x}"
    )
    return False


def _capture_cpp_factory(frame, kind):
    # The C++ factory ABI is captured as opaque argument words. These words
    # identify an Apple-owned program path but are never treated as a stable
    # private object layout or supplied back to the runtime.
    return_hook = _schedule_return(frame, kind)
    print(
        "AO46_AGX_SHADER_CONTRACT_CALL "
        f"kind={kind} "
        f"arg0={_register(frame, 'x0'):#018x} "
        f"arg1={_register(frame, 'x1'):#018x} "
        f"arg2={_register(frame, 'x2'):#018x} "
        f"arg3={_register(frame, 'x3'):#018x} "
        f"arg4={_register(frame, 'x4'):#018x} "
        f"arg5={_register(frame, 'x5'):#018x} "
        f"arg6={_register(frame, 'x6'):#018x} "
        f"arg7={_register(frame, 'x7'):#018x} "
        f"return_hook={int(return_hook)} "
        f"stack={_stack_prefix(frame)}"
    )
    return False


def capture_compute_program_factory(frame, _bp_loc, _internal_dict):
    return _capture_cpp_factory(frame, "compute-program-factory")


def _code_heap_state(frame, library):
    # These are measured state-presence indicators, not a constructible object
    # layout. They let a public control prove allocation/publication/release
    # sequencing without retaining any Apple state in AO46.
    return (
        _dword_at(frame, library + 0x484),
        int(_word_at(frame, library + 0x2d0) != 0),
        int(_word_at(frame, library + 0x300) != 0),
    )


def _schedule_code_heap_return(frame, kind, library):
    process = frame.GetThread().GetProcess()
    target = process.GetTarget()
    return_address = _register(frame, "x30")

    if not return_address or not library:
        return False

    if return_address not in _code_heap_return_breakpoints:
        breakpoint = target.BreakpointCreateByAddress(return_address)
        breakpoint.SetScriptCallbackFunction(
            "agx_shader_contract_capture.capture_code_heap_return"
        )
        _code_heap_return_breakpoints[return_address] = breakpoint.GetID()
        _pending_code_heap_returns[return_address] = []

    _pending_code_heap_returns[return_address].append((kind, library))
    return True


def _capture_code_heap_lifecycle(frame, kind):
    library = _register(frame, "x0")
    thread_id = _thread_id(frame)
    if kind == "allocate" and library:
        _active_code_heap_allocations.setdefault(thread_id, []).append(library)
    references, allocation_present, code_address_present = _code_heap_state(
        frame, library
    )
    return_hook = _schedule_code_heap_return(frame, kind, library)
    print(
        "AO46_AGX_SHADER_CODE_HEAP_CALL "
        f"kind={kind} library={library:#018x} "
        f"thread={thread_id} "
        f"references={references} allocation_present={allocation_present} "
        f"code_address_present={code_address_present} "
        f"caller_offset={_agx_offset(_register(frame, 'x30')):#x} "
        f"return_hook={int(return_hook)}"
    )
    return False


def capture_code_heap_allocate(frame, _bp_loc, _internal_dict):
    return _capture_code_heap_lifecycle(frame, "allocate")


def capture_code_heap_release(frame, _bp_loc, _internal_dict):
    return _capture_code_heap_lifecycle(frame, "release")


def capture_code_heap_return(frame, _bp_loc, _internal_dict):
    pending = _pending_code_heap_returns.get(frame.GetPC(), [])
    kind, library = pending.pop() if pending else ("unknown", 0)
    references, allocation_present, code_address_present = _code_heap_state(
        frame, library
    )
    print(
        "AO46_AGX_SHADER_CODE_HEAP_RETURN "
        f"kind={kind} library={library:#018x} "
        f"references={references} allocation_present={allocation_present} "
        f"code_address_present={code_address_present}"
    )
    if kind == "allocate" and library:
        active = _active_code_heap_allocations.get(_thread_id(frame), [])
        if active and active[-1] == library:
            active.pop()
        if not active:
            _active_code_heap_allocations.pop(_thread_id(frame), None)
    return False


def capture_code_link_info_initialize(frame, _bp_loc, _internal_dict):
    # The compiler reply stays entirely Apple-owned. Recording only its
    # identity proves that the LinkInfo later used for relocation originated
    # in the same Apple compiler-result lifecycle.
    link_info = _register(frame, "x0")
    compiler_reply = _register(frame, "x1")
    _link_info_compiler_replies[link_info] = compiler_reply
    print(
        "AO46_AGX_SHADER_CODE_LINK_INFO "
        "kind=initialize "
        f"link_info={link_info:#018x} "
        f"compiler_reply={compiler_reply:#018x} "
        f"device={_register(frame, 'x2'):#018x} "
        f"caller_offset={_agx_offset(_register(frame, 'x30')):#x}"
    )
    return False


def capture_code_heap_relocations(frame, _bp_loc, _internal_dict):
    # Relocations are Apple-owned code publication. Record the already
    # published destination and opaque companion-view identities, never AGX
    # bytes or relocation records.
    published_code_address = _register(frame, "x1")
    print(
        "AO46_AGX_SHADER_CODE_HEAP_RELOCATIONS "
        f"link_info={_register(frame, 'x0'):#018x} "
        f"published_code_address={published_code_address:#018x} "
        f"fixed_base={int((published_code_address & 0x1000000000) != 0)} "
        f"view0={_register(frame, 'x2'):#018x} "
        f"view1={_register(frame, 'x3'):#018x} "
        f"view2={_register(frame, 'x4'):#018x} "
        f"view3={_register(frame, 'x5'):#018x} "
        f"view4={_register(frame, 'x6'):#018x} "
        f"view5={_register(frame, 'x7'):#018x} "
        f"caller_offset={_agx_offset(_register(frame, 'x30')):#x}"
    )
    return False


def _schedule_variant_finalize_return(frame, variant):
    process = frame.GetThread().GetProcess()
    target = process.GetTarget()
    return_address = _register(frame, "x30")

    if not return_address or not variant:
        return False

    if return_address not in _variant_finalize_return_breakpoints:
        breakpoint = target.BreakpointCreateByAddress(return_address)
        breakpoint.SetScriptCallbackFunction(
            "agx_shader_contract_capture.capture_compute_program_finalize_return"
        )
        _variant_finalize_return_breakpoints[return_address] = breakpoint.GetID()
        _pending_variant_finalize_returns[return_address] = []

    _pending_variant_finalize_returns[return_address].append(variant)
    return True


def capture_compute_program_finalize(frame, _bp_loc, _internal_dict):
    # The variant remains Apple-owned. Bounded snapshots establish the finalizer
    # lifecycle only; AO46 never reads these words as a constructible ABI.
    variant = _register(frame, "x0")
    return_hook = _schedule_variant_finalize_return(frame, variant)
    print(
        "AO46_AGX_SHADER_VARIANT_CALL "
        "kind=compute-program-finalize "
        f"variant={variant:#018x} "
        f"variant_bytes={_memory_prefix(frame, variant, 0x100)} "
        f"return_hook={int(return_hook)}"
    )
    return False


def capture_compute_program_finalize_return(frame, _bp_loc, _internal_dict):
    pending = _pending_variant_finalize_returns.get(frame.GetPC(), [])
    variant = pending.pop() if pending else 0
    print(
        "AO46_AGX_SHADER_VARIANT_RETURN "
        "kind=compute-program-finalize "
        f"variant={variant:#018x} "
        f"variant_bytes={_memory_prefix(frame, variant, 0x100)}"
    )
    return False


def _schedule_compute_variant_constructor_return(frame, variant):
    process = frame.GetThread().GetProcess()
    target = process.GetTarget()
    return_address = _register(frame, "x30")

    if not return_address or not variant:
        return False

    if return_address not in _compute_variant_constructor_return_breakpoints:
        breakpoint = target.BreakpointCreateByAddress(return_address)
        breakpoint.SetScriptCallbackFunction(
            "agx_shader_contract_capture.capture_compute_variant_constructor_return"
        )
        _compute_variant_constructor_return_breakpoints[return_address] = (
            breakpoint.GetID()
        )
        _pending_compute_variant_constructor_returns[return_address] = []

    _pending_compute_variant_constructor_returns[return_address].append(variant)
    return True


def capture_compute_variant_constructor(frame, _bp_loc, _internal_dict):
    # The constructor is the profile's real program-residency owner. Capture
    # its opaque inputs and its completed object only to correlate Apple heap
    # allocations with the fixed USC-base arithmetic seen in disassembly.
    variant = _register(frame, "x0")
    device = _register(frame, "x1")
    compiler_reply = _register(frame, "x2")
    _variant_devices[variant] = device
    _variant_compiler_replies[variant] = compiler_reply
    return_hook = _schedule_compute_variant_constructor_return(frame, variant)
    print(
        "AO46_AGX_SHADER_VARIANT_CALL "
        "kind=compute-program-constructor "
        f"variant={variant:#018x} "
        f"device={device:#018x} "
        f"reply={compiler_reply:#018x} "
        f"profile_flag={_register(frame, 'x6'):#018x} "
        f"profile_control={_register(frame, 'x7'):#018x} "
        f"return_hook={int(return_hook)}"
    )
    return False


def capture_compute_variant_constructor_return(frame, _bp_loc, _internal_dict):
    pending = _pending_compute_variant_constructor_returns.get(frame.GetPC(), [])
    variant = pending.pop() if pending else 0
    # The offsets below are only profile-specific evidence slots. Static
    # analysis shows constructor code derives fixed-base values from these
    # allocations; no AO46 code consumes or writes the object fields.
    print(
        "AO46_AGX_SHADER_VARIANT_RETURN "
        "kind=compute-program-constructor "
        f"variant={variant:#018x} "
        f"slot_0x618={_word_at(frame, variant + 0x618):#018x} "
        f"slot_0x638={_word_at(frame, variant + 0x638):#018x} "
        f"slot_0xcb0={_word_at(frame, variant + 0xCB0):#018x} "
        f"slot_0xce0={_word_at(frame, variant + 0xCE0):#018x} "
        f"slot_0xdb0={_word_at(frame, variant + 0xDB0):#018x}"
    )
    return False


def capture_compute_variant_first_heap_select(frame, _bp_loc, _internal_dict):
    # This probe is placed immediately after the constructor's profile branch
    # selecting the fixed USC base. It captures the actual selected value, not
    # an inference from a later allocation record.
    variant = _register(frame, "x23")
    heap = _register(frame, "x22")
    resource_list = _register(frame, "x3")
    selected_base = _register(frame, "x21")
    device = _variant_devices.get(variant, 0)
    compiler_reply = _variant_compiler_replies.get(variant, 0)
    _variant_selected_bases[variant] = selected_base
    _pending_variant_first_heap_selections.append(
        (variant, heap, resource_list, selected_base)
    )
    print(
        "AO46_AGX_SHADER_VARIANT_RESIDENCY "
        "kind=first-heap-selection "
        f"variant={variant:#018x} heap={heap:#018x} "
        f"device={device:#018x} "
        f"compiler_reply={compiler_reply:#018x} "
        f"device_heap_offset={heap - device if device and heap >= device else 0:#x} "
        f"resource_list={resource_list:#018x} "
        f"selected_base={selected_base:#018x}"
    )
    return False


def capture_compute_variant_base_destructor(frame, _bp_loc, _internal_dict):
    # The base destructor is the end of the direct compute-variant lifetime.
    # LinkInfo resides with its Apple-owned variant; recording pointer identity
    # confirms the exact compiler-result/relocation package is retired here.
    variant = _register(frame, "x0")
    link_info = variant + 8 if variant else 0
    compiler_reply = _link_info_compiler_replies.get(link_info, 0)
    constructor_reply = _variant_compiler_replies.get(variant, 0)
    selected_base = _variant_selected_bases.get(variant, 0)
    print(
        "AO46_AGX_SHADER_VARIANT_TEARDOWN "
        "kind=compute-program-base-destructor "
        f"variant={variant:#018x} "
        f"link_info={link_info:#018x} "
        f"link_info_initialized={int(link_info in _link_info_compiler_replies)} "
        f"compiler_reply={compiler_reply:#018x} "
        f"constructor_reply={constructor_reply:#018x} "
        f"reply_matches={int(compiler_reply != 0 and compiler_reply == constructor_reply)} "
        f"selected_base={selected_base:#018x}"
    )
    return False


def _take_variant_first_heap_selection(heap, resource_list):
    for index in range(len(_pending_variant_first_heap_selections) - 1, -1, -1):
        variant, candidate_heap, candidate_resources, selected_base = (
            _pending_variant_first_heap_selections[index]
        )
        if candidate_heap == heap and candidate_resources == resource_list:
            del _pending_variant_first_heap_selections[index]
            return variant, selected_base

    return 0, 0


def _schedule_heap_true_allocate_return(
    frame, allocation, heap, requested_bytes, resource_list, caller_pc,
    variant, selected_base, code_heap_owner
):
    process = frame.GetThread().GetProcess()
    target = process.GetTarget()
    return_address = _register(frame, "x30")

    if not return_address or not allocation:
        return False

    if return_address not in _heap_true_allocate_return_breakpoints:
        breakpoint = target.BreakpointCreateByAddress(return_address)
        breakpoint.SetScriptCallbackFunction(
            "agx_shader_contract_capture.capture_heap_true_allocate_return"
        )
        _heap_true_allocate_return_breakpoints[return_address] = breakpoint.GetID()
        _pending_heap_true_allocate_returns[return_address] = []

    _pending_heap_true_allocate_returns[return_address].append(
        (allocation, heap, requested_bytes, resource_list, caller_pc,
         variant, selected_base, code_heap_owner)
    )
    return True


def capture_heap_true_allocate(frame, _bp_loc, _internal_dict):
    # C++ sret ABI: x0 receives the 40-byte Allocation result, followed by
    # (Heap*, requested_bytes, IOGPUMetalResource const**). Read it only after
    # Apple returns; this callback never invokes allocation or mapping APIs.
    allocation = _register(frame, "x0")
    heap = _register(frame, "x1")
    requested_bytes = _register(frame, "x2")
    resource_list = _register(frame, "x3")
    caller_pc = _register(frame, "x30")
    caller_offset = _agx_offset(caller_pc)
    variant_owned = caller_offset in _COMPUTE_VARIANT_HEAP_TRUE_RETURN_OFFSETS
    variant, selected_base = (0, 0)
    if caller_offset == 0x68DCFC:
        variant, selected_base = _take_variant_first_heap_selection(
            heap, resource_list
        )
    active_code_heap = _active_code_heap_allocations.get(_thread_id(frame), [])
    code_heap_owner = active_code_heap[-1] if active_code_heap else 0
    return_hook = _schedule_heap_true_allocate_return(
        frame, allocation, heap, requested_bytes, resource_list, caller_pc,
        variant, selected_base, code_heap_owner
    )
    print(
        "AO46_AGX_SHADER_EXEC_ALLOCATION_CALL "
        "kind=heap-true-allocate "
        f"allocation={allocation:#018x} heap={heap:#018x} "
        f"requested_bytes={requested_bytes:#018x} "
        f"resource_list={resource_list:#018x} "
        f"caller_offset={caller_offset:#x} "
        f"compute_variant_owner={int(variant_owned)} "
        f"variant={variant:#018x} selected_base={selected_base:#018x} "
        f"code_heap_owner={code_heap_owner:#018x} "
        f"return_hook={int(return_hook)}"
    )
    return False


def capture_heap_true_allocate_return(frame, _bp_loc, _internal_dict):
    pending = _pending_heap_true_allocate_returns.get(frame.GetPC(), [])
    allocation, heap, requested_bytes, resource_list, caller_pc, variant, selected_base, code_heap_owner = (
        pending.pop() if pending else (0, 0, 0, 0, 0, 0, 0, 0)
    )
    caller_offset = _agx_offset(caller_pc)
    allocation_field0 = _word_at(frame, allocation)
    heap_record = _word_at(frame, allocation + 0x18)
    # Ghidra identifies this as an AGX allocation record. Its retained Apple
    # resource is a separate identity, so never compare the two as pointers.
    apple_resource = _word_at(frame, heap_record + 0x128) if heap_record else 0
    policy_origin, policy_digest = _apple_resource_policies.get(
        apple_resource, ("unknown", "unavailable")
    )
    heap_label = _apple_resource_labels.get(apple_resource, "unobserved")
    allocation_heap = _word_at(frame, allocation + 0x20)
    heap_args = heap + 0x20 if heap else 0
    # The selection probe supplies the actual base value chosen by Apple's
    # constructor. Record only that observed arithmetic; it is not a general
    # GPU-VA conversion rule and is never sent back to the runtime.
    fixed_base_candidate = allocation_field0 + selected_base if variant else 0
    compiler_reply = _variant_compiler_replies.get(variant, 0)
    print(
        "AO46_AGX_SHADER_EXEC_ALLOCATION_RETURN "
        "kind=heap-true-allocate "
        f"allocation={allocation:#018x} heap={heap:#018x} "
        f"requested_bytes={requested_bytes:#018x} "
        f"resource_list={resource_list:#018x} "
        f"caller_offset={caller_offset:#x} "
        f"compute_variant_owner={int(caller_offset in _COMPUTE_VARIANT_HEAP_TRUE_RETURN_OFFSETS)} "
        f"variant={variant:#018x} selected_base={selected_base:#018x} "
        f"compiler_reply={compiler_reply:#018x} "
        f"code_heap_owner={code_heap_owner:#018x} "
        f"field0={allocation_field0:#018x} "
        f"heap_record={heap_record:#018x} apple_resource={apple_resource:#018x} "
        f"apple_policy_origin={policy_origin} "
        f"apple_policy_digest={policy_digest} "
        f"apple_heap_label={heap_label} "
        f"allocation_heap={allocation_heap:#018x} "
        f"heap_args_digest={_memory_digest(frame, heap_args, 0x68)} "
        f"observed_base_plus_field0={fixed_base_candidate:#018x} "
        f"allocation_bytes={_memory_prefix(frame, allocation, 0x28)}"
    )
    return False


def capture_iogpu_resource_initialize(frame, _bp_loc, _internal_dict):
    # The selected AGX heap reaches this Apple-owned constructor. Capture the
    # live object and opaque argument identities only, never descriptor bytes
    # or a reconstructible constructor layout.
    caller = frame.GetThread().GetFrameAtIndex(1)
    caller_location = _frame_location(caller)
    args = _register(frame, "x4")
    args_size = _register(frame, "x5")
    resource = _register(frame, "x0")
    policy_origin = "apple-heap" if (
        "AGXMetalG16X" in caller_location and
        "Heap<true>::allocateImpl" in caller_location
    ) else "other"
    policy_digest = _memory_digest(frame, args, args_size)
    _apple_resource_policies[resource] = (policy_origin, policy_digest)
    print(
        "AO46_IOGPU_OWNERSHIP_CALL "
        "kind=resource-initialize "
        f"resource={resource:#018x} "
        f"device={_register(frame, 'x2'):#018x} "
        f"options={_register(frame, 'x3'):#018x} "
        f"args={args:#018x} args_size={args_size:#018x} "
        f"args_digest={policy_digest} "
        # This identifies the ownership edge without treating Apple's object
        # layout or constructor arguments as an AO46 ABI.
        f"agx_heap_factory={int(policy_origin == 'apple-heap')} "
        f"caller={caller_location}"
    )
    return False


def capture_heap_resource_label_return(frame, _bp_loc, _internal_dict):
    # This runs immediately after Apple's existing conversion of the retained
    # resource label. x0 is its returned C string and x20 is the resource;
    # neither an Objective-C method nor an object layout is invoked or
    # reconstructed by this probe.
    resource = _register(frame, "x20")
    label = _cstring_prefix(frame, _register(frame, "x0"))
    _apple_resource_labels[resource] = label
    print(
        "AO46_AGX_HEAP_RESOURCE_LABEL "
        f"resource={resource:#018x} label={label} source=apple-signpost"
    )
    return False


def capture_heap_resource_signpost(frame, _bp_loc, _internal_dict):
    # The allocator calls this helper on both creation and teardown. The event
    # confirms resource lifecycle activity, while the separate return probe
    # records the resource label only when Apple emits that conversion itself.
    resource = _register(frame, "x1")
    print(
        "AO46_AGX_HEAP_RESOURCE_EVENT "
        f"resource={resource:#018x} "
        f"action={_register(frame, 'x2'):#018x} source=apple-signpost"
    )
    return False


def capture_iogpu_remote_resource_initialize(frame, _bp_loc, _internal_dict):
    # Heap<true> can retain resources created through the separate remote-store
    # path. Keep it distinct from the ordinary initializer so the trace can
    # establish which Apple lifecycle owns the selected code heap.
    caller = frame.GetThread().GetFrameAtIndex(1)
    caller_location = _frame_location(caller)
    args = _register(frame, "x5")
    args_size = _register(frame, "x6")
    print(
        "AO46_IOGPU_OWNERSHIP_CALL "
        "kind=resource-remote-initialize "
        f"resource={_register(frame, 'x0'):#018x} "
        f"device={_register(frame, 'x2'):#018x} "
        f"remote_storage={_register(frame, 'x3'):#018x} "
        f"options={_register(frame, 'x4'):#018x} "
        f"args={args:#018x} args_size={args_size:#018x} "
        f"args_digest={_memory_digest(frame, args, args_size)} "
        f"agx_heap_factory={int('AGXMetalG16X' in caller_location and 'Heap<true>::allocateImpl' in caller_location)} "
        f"caller={caller_location}"
    )
    return False


def capture_iogpu_resource_pool_initialize(frame, _bp_loc, _internal_dict):
    caller = frame.GetThread().GetFrameAtIndex(1)
    caller_location = _frame_location(caller)
    args = _register(frame, "x4")
    args_size = _register(frame, "x5")
    print(
        "AO46_IOGPU_OWNERSHIP_CALL "
        "kind=resource-pool-initialize "
        f"pool={_register(frame, 'x0'):#018x} "
        f"device={_register(frame, 'x2'):#018x} "
        f"resource_class={_register(frame, 'x3'):#018x} "
        f"args={args:#018x} args_size={args_size:#018x} "
        f"args_digest={_memory_digest(frame, args, args_size)} "
        f"options={_register(frame, 'x6'):#018x} "
        f"agx_pool_setup={int('AGXMetalG16X' in caller_location and 'setupHWResourcePools' in caller_location)} "
        f"caller={caller_location}"
    )
    return False


def _schedule_iogpu_pool_create_return(frame, pool):
    process = frame.GetThread().GetProcess()
    target = process.GetTarget()
    return_address = _register(frame, "x30")
    if not return_address or not pool:
        return False

    if return_address not in _iogpu_pool_create_return_breakpoints:
        breakpoint = target.BreakpointCreateByAddress(return_address)
        breakpoint.SetScriptCallbackFunction(
            "agx_shader_contract_capture.capture_iogpu_pool_create_return"
        )
        _iogpu_pool_create_return_breakpoints[return_address] = breakpoint.GetID()
        _pending_iogpu_pool_create_returns[return_address] = []

    _pending_iogpu_pool_create_returns[return_address].append(pool)
    return True


def capture_iogpu_pool_create(frame, _bp_loc, _internal_dict):
    pool = _register(frame, "x0")
    caller = frame.GetThread().GetFrameAtIndex(1)
    return_hook = _schedule_iogpu_pool_create_return(frame, pool)
    print(
        "AO46_IOGPU_OWNERSHIP_CALL "
        "kind=resource-pool-create "
        f"pool={pool:#018x} "
        f"status_out={_register(frame, 'x1'):#018x} "
        f"caller={_frame_location(caller)} "
        f"return_hook={int(return_hook)}"
    )
    return False


def capture_iogpu_pool_create_return(frame, _bp_loc, _internal_dict):
    pending = _pending_iogpu_pool_create_returns.get(frame.GetPC(), [])
    pool = pending.pop() if pending else 0
    print(
        "AO46_IOGPU_OWNERSHIP_RETURN "
        "kind=resource-pool-create "
        f"pool={pool:#018x} "
        f"resource={_register(frame, 'x0'):#018x}"
    )
    return False


def capture_iogpu_pooled_resource_release(frame, _bp_loc, _internal_dict):
    caller = frame.GetThread().GetFrameAtIndex(1)
    print(
        "AO46_IOGPU_OWNERSHIP_CALL "
        "kind=pooled-resource-release "
        f"resource={_register(frame, 'x0'):#018x} "
        f"caller={_frame_location(caller)}"
    )
    return False


def capture_compute_direct_tg_size(frame, _bp_loc, _internal_dict):
    # This is a C++ instance method: x0 is the USC-state-loader instance and
    # x1 is the finalized ComputeProgramVariant consumed by the helper.
    print(
        "AO46_AGX_SHADER_VARIANT_USE "
        "kind=compute-direct-tg-size "
        f"loader={_register(frame, 'x0'):#018x} "
        f"variant={_register(frame, 'x1'):#018x} "
        f"driver_arguments={_register(frame, 'x2'):#018x} "
        f"threadgroup_size={_register(frame, 'x3'):#018x} "
        f"enabled={_register(frame, 'x4'):#018x}"
    )
    return False


def _schedule_internal_buffer_grow_return(frame, internal_buffer):
    process = frame.GetThread().GetProcess()
    target = process.GetTarget()
    return_address = _register(frame, "x30")

    if not return_address or not internal_buffer:
        return False

    if return_address not in _internal_buffer_grow_return_breakpoints:
        breakpoint = target.BreakpointCreateByAddress(return_address)
        breakpoint.SetScriptCallbackFunction(
            "agx_shader_contract_capture.capture_internal_buffer_grow_return"
        )
        _internal_buffer_grow_return_breakpoints[return_address] = breakpoint.GetID()
        _pending_internal_buffer_grow_returns[return_address] = []

    _pending_internal_buffer_grow_returns[return_address].append(internal_buffer)
    return True


def capture_usc_spill_info_constructor(frame, _bp_loc, _internal_dict):
    # The constructor receives the Apple HAL device in x1 and the owned
    # DeviceInternalBuffer in x2. Record the association so later generic
    # internal-buffer activity can be correlated without treating either
    # object as an AO46-constructible layout.
    spill_info = _register(frame, "x0")
    device = _register(frame, "x1")
    internal_buffer = _register(frame, "x2")
    if internal_buffer:
        _usc_spill_internal_buffers.add(internal_buffer)
    print(
        "AO46_AGX_SHADER_USC_INTERNAL_BUFFER "
        "kind=spill-info-constructor "
        f"spill_info={spill_info:#018x} "
        f"device={device:#018x} "
        f"internal_buffer={internal_buffer:#018x} "
        f"spill_info_bytes={_memory_prefix(frame, spill_info, 0x50)} "
        f"internal_buffer_bytes={_memory_prefix(frame, internal_buffer, 0x40)}"
    )
    return False


def capture_internal_buffer_grow(frame, _bp_loc, _internal_dict):
    # This profile's merged DeviceInternalBuffer::grow routine is an
    # Apple-owned allocation path. The requested length and post-call object
    # state are measured read-only; AO46 never calls or replays the routine.
    internal_buffer = _register(frame, "x0")
    return_hook = _schedule_internal_buffer_grow_return(frame, internal_buffer)
    print(
        "AO46_AGX_SHADER_USC_INTERNAL_BUFFER "
        "kind=internal-buffer-grow "
        f"internal_buffer={internal_buffer:#018x} "
        f"requested_length={_register(frame, 'x1'):#018x} "
        f"spill_manager_match={int(internal_buffer in _usc_spill_internal_buffers)} "
        f"internal_buffer_bytes={_memory_prefix(frame, internal_buffer, 0x40)} "
        f"return_hook={int(return_hook)}"
    )
    return False


def capture_internal_buffer_grow_return(frame, _bp_loc, _internal_dict):
    pending = _pending_internal_buffer_grow_returns.get(frame.GetPC(), [])
    internal_buffer = pending.pop() if pending else 0
    print(
        "AO46_AGX_SHADER_USC_INTERNAL_BUFFER_RETURN "
        "kind=internal-buffer-grow "
        f"internal_buffer={internal_buffer:#018x} "
        f"spill_manager_match={int(internal_buffer in _usc_spill_internal_buffers)} "
        f"internal_buffer_bytes={_memory_prefix(frame, internal_buffer, 0x40)}"
    )
    return False


def _schedule_internal_buffer_gpu_address_return(frame, resource, caller):
    process = frame.GetThread().GetProcess()
    target = process.GetTarget()
    return_address = _register(frame, "x30")

    if not return_address or not resource:
        return False

    if return_address not in _internal_buffer_gpu_address_return_breakpoints:
        breakpoint = target.BreakpointCreateByAddress(return_address)
        breakpoint.SetScriptCallbackFunction(
            "agx_shader_contract_capture.capture_internal_buffer_gpu_address_return"
        )
        _internal_buffer_gpu_address_return_breakpoints[return_address] = breakpoint.GetID()
        _pending_internal_buffer_gpu_address_returns[return_address] = []

    _pending_internal_buffer_gpu_address_returns[return_address].append(
        (resource, caller)
    )
    return True


def capture_internal_buffer_gpu_address(frame, _bp_loc, _internal_dict):
    resource = _register(frame, "x0")
    caller = _frame_location(frame.GetThread().GetFrameAtIndex(1))
    return_hook = _schedule_internal_buffer_gpu_address_return(
        frame, resource, caller
    )
    print(
        "AO46_AGX_SHADER_USC_INTERNAL_ADDRESS_CALL "
        f"resource={resource:#018x} caller={caller} "
        f"return_hook={int(return_hook)}"
    )
    return False


def capture_internal_buffer_gpu_address_return(frame, _bp_loc, _internal_dict):
    pending = _pending_internal_buffer_gpu_address_returns.get(frame.GetPC(), [])
    resource, caller = pending.pop() if pending else (0, "unknown")
    print(
        "AO46_AGX_SHADER_USC_INTERNAL_ADDRESS_RETURN "
        f"resource={resource:#018x} caller={caller} "
        f"gpu_address={_register(frame, 'x0'):#018x}"
    )
    return False


def capture_device_setup_buffer_return(frame, _bp_loc, _internal_dict):
    # This breakpoint lands immediately after the profiled AGX device setup
    # calls the internal IOGPUMetalBuffer initializer. It records the returned
    # Apple-owned resource before any higher-level object stores it.
    print(
        "AO46_AGX_SHADER_USC_DEVICE_SETUP_BUFFER "
        "kind=buffer-init-return "
        f"resource={_register(frame, 'x0'):#018x} "
        f"resource_bytes={_memory_prefix(frame, _register(frame, 'x0'), 0x40)}"
    )
    return False


def capture_device_setup_buffer_gpu_address_return(frame, _bp_loc, _internal_dict):
    # This is the immediate return from gpuAddress for the same profile-scoped
    # device-setup buffer. A returned address is evidence only about this
    # Apple-owned allocation, never permission to map an AO46 BO there.
    print(
        "AO46_AGX_SHADER_USC_DEVICE_SETUP_BUFFER "
        "kind=buffer-gpu-address-return "
        f"gpu_address={_register(frame, 'x0'):#018x}"
    )
    return False


def capture_compute_pipeline_init(frame, _bp_loc, _internal_dict):
    return _capture_cpp_factory(frame, "compute-pipeline-init")


def capture_compute_pipeline_bind(frame, _bp_loc, _internal_dict):
    # This Objective-C method connects an Apple-owned pipeline variant to the
    # command encoder. It returns void, so the post-call x0 value is not an
    # object/result contract and is intentionally not recorded.
    print(
        "AO46_AGX_SHADER_CONTRACT_CALL "
        "kind=compute-pipeline-bind "
        f"context={_register(frame, 'x0'):#018x} "
        f"pipeline={_register(frame, 'x2'):#018x}"
    )
    return False


def capture_compute_program_address_table(frame, _bp_loc, _internal_dict):
    # The returned table is Apple-owned. A bounded snapshot classifies whether
    # it is an object/value handoff, not a layout to reproduce in AO46.
    return_hook = _schedule_return(frame, "compute-program-address-table")
    print(
        "AO46_AGX_SHADER_CONTRACT_CALL "
        "kind=compute-program-address-table "
        f"context={_register(frame, 'x0'):#018x} "
        f"return_hook={int(return_hook)}"
    )
    return False


def _capture_compute_encoding_phase(frame, kind):
    print(
        "AO46_AGX_SHADER_CONTRACT_CALL "
        f"kind={kind} "
        f"context={_register(frame, 'x0'):#018x} "
        f"arg1={_register(frame, 'x1'):#018x} "
        f"arg2={_register(frame, 'x2'):#018x} "
        f"arg3={_register(frame, 'x3'):#018x}"
    )
    return False


def capture_compute_end_encoding(frame, _bp_loc, _internal_dict):
    return _capture_compute_encoding_phase(frame, "compute-end-encoding")


def capture_compute_append_program_tables(frame, _bp_loc, _internal_dict):
    return _capture_compute_encoding_phase(frame, "compute-append-program-tables")


def capture_compute_set_pipeline_common(frame, _bp_loc, _internal_dict):
    print(
        "AO46_AGX_SHADER_EXECUTION_CALL "
        "kind=compute-set-pipeline-common "
        f"context={_register(frame, 'x0'):#018x} "
        f"pipeline={_register(frame, 'x1'):#018x}"
    )
    return False


def capture_compute_execute_kernel(frame, _bp_loc, _internal_dict):
    print(
        "AO46_AGX_SHADER_EXECUTION_CALL "
        "kind=compute-execute-kernel "
        f"context={_register(frame, 'x0'):#018x} "
        f"arg1={_register(frame, 'x1'):#018x} "
        f"arg2={_register(frame, 'x2'):#018x} "
        f"arg3={_register(frame, 'x3'):#018x} "
        f"arg4={_register(frame, 'x4'):#018x}"
    )
    return False


def capture_compute_end_pass(frame, _bp_loc, _internal_dict):
    print(
        "AO46_AGX_SHADER_EXECUTION_CALL "
        "kind=compute-end-pass "
        f"context={_register(frame, 'x0'):#018x} "
        f"arg1={_register(frame, 'x1'):#018x} "
        f"arg2={_register(frame, 'x2'):#018x}"
    )
    return False


def capture_usc_spill_buffer(frame, _bp_loc, _internal_dict):
    # On the profiled G16X build this symbol is a leaf descriptor packer: it
    # writes its result to x1 and makes no allocation or IOKit call. Capture
    # the source and post-return destination snapshots for differential
    # classification only; AO46 never reproduces this private record layout.
    source = _register(frame, "x0")
    descriptor = _register(frame, "x1")
    return_hook = _schedule_usc_descriptor_return(frame, descriptor)
    print(
        "AO46_AGX_SHADER_USC_CALL "
        "kind=usc-spill-descriptor "
        f"source={source:#018x} "
        f"descriptor={descriptor:#018x} "
        f"mode={_register(frame, 'x2'):#018x} "
        f"source_bytes={_memory_prefix(frame, source, 0x50)} "
        f"descriptor_before={_memory_prefix(frame, descriptor, 0x48)} "
        f"return_hook={int(return_hook)}"
    )
    return False


def capture_compute_pipeline_resources(frame, _bp_loc, _internal_dict):
    print(
        "AO46_AGX_SHADER_USC_CALL "
        "kind=compute-pipeline-resources "
        f"pipeline={_register(frame, 'x0'):#018x} "
        f"metal_resource_list={_register(frame, 'x1'):#018x} "
        f"iogpu_resource_list={_register(frame, 'x2'):#018x}"
    )
    return False


def capture_setup_compute_command(frame, _bp_loc, _internal_dict):
    print(
        "AO46_AGX_SHADER_USC_CALL "
        "kind=setup-compute-command "
        f"switcher={_register(frame, 'x0'):#018x} "
        f"command_record={_register(frame, 'x1'):#018x} "
        f"iogpu_resource_list={_register(frame, 'x2'):#018x} "
        f"allocator={_register(frame, 'x3'):#018x}"
    )
    return False


def capture_new_command(frame, _bp_loc, _internal_dict):
    context = _register(frame, "x0")
    requested_bytes = _register(frame, "x1")
    reset_cursor = _register(frame, "x2")
    return_hook = _schedule_command_return(frame)
    print(
        "AO46_AGX_SHADER_COMMAND_CALL "
        "kind=new-command "
        f"context={context:#018x} "
        f"requested_bytes={requested_bytes:#018x} "
        f"reset_cursor={reset_cursor:#018x} "
        f"return_hook={int(return_hook)}"
    )
    return False


def capture_end_command(frame, _bp_loc, _internal_dict):
    # At entry the profiled ContextCommon keeps the current storage cursor and
    # segment length at these offsets. Their difference is the segment header
    # that newCommand created; this is a read-only consistency check between
    # the two Apple-owned lifecycle calls.
    context = _register(frame, "x0")
    cursor = _word_at(frame, context + 0x7B0)
    segment_length = _word_at(frame, context + 0x7C0)
    segment_header = cursor - segment_length if cursor >= segment_length else 0
    print(
        "AO46_AGX_SHADER_COMMAND_CALL "
        "kind=end-command "
        f"context={context:#018x} "
        f"cursor={cursor:#018x} "
        f"segment_length={segment_length:#018x} "
        f"segment_header={segment_header:#018x} "
        f"segment_header_bytes={_memory_prefix(frame, segment_header, 8)}"
    )
    return False


def capture_command_storage_begin_segment(frame, _bp_loc, _internal_dict):
    storage = _register(frame, "x0")
    segment_header = _register(frame, "x1")
    _open_storage_segments.setdefault(storage, []).append(segment_header)
    print(
        "AO46_AGX_SHADER_COMMAND_STORAGE_CALL "
        "kind=begin-segment "
        f"storage={storage:#018x} "
        f"segment_header={segment_header:#018x} "
        f"segment_header_bytes={_memory_prefix(frame, segment_header, 8)}"
    )
    return False


def capture_command_storage_end_segment(frame, _bp_loc, _internal_dict):
    storage = _register(frame, "x0")
    pending = _open_storage_segments.get(storage, [])
    segment_header = pending.pop() if pending else 0
    command_record = segment_header + 8 if segment_header else 0
    print(
        "AO46_AGX_SHADER_COMMAND_STORAGE_CALL "
        "kind=end-segment "
        f"storage={storage:#018x} "
        f"segment_header={segment_header:#018x} "
        f"segment_header_bytes={_memory_prefix(frame, segment_header, 8)} "
        f"record_bytes={_memory_prefix(frame, command_record, 0x180)}"
    )
    return False


def capture_fill_command_buffer_args(frame, _bp_loc, _internal_dict):
    # This is the observed Apple-owned lowering boundary after command storage
    # closes. The argument record is only captured to correlate lifetime and
    # ordering with the storage segment; it is not constructed or invoked.
    argument_record = _register(frame, "x2")
    return_hook = _schedule_queue_argument_return(frame, argument_record)
    print(
        "AO46_AGX_SHADER_QUEUE_CALL "
        "kind=fill-command-buffer-args "
        f"command_buffer={_register(frame, 'x0'):#018x} "
        f"argument_record={argument_record:#018x} "
        f"queue={_register(frame, 'x3'):#018x} "
        f"argument_bytes={_memory_prefix(frame, argument_record, 0x40)} "
        f"return_hook={int(return_hook)}"
    )
    return False


def _schedule_queue_argument_return(frame, argument_record):
    process = frame.GetThread().GetProcess()
    target = process.GetTarget()
    return_address = _register(frame, "x30")

    if not return_address or not argument_record:
        return False

    if return_address not in _queue_argument_return_breakpoints:
        breakpoint = target.BreakpointCreateByAddress(return_address)
        breakpoint.SetScriptCallbackFunction(
            "agx_shader_contract_capture.capture_fill_command_buffer_args_return"
        )
        _queue_argument_return_breakpoints[return_address] = breakpoint.GetID()
        _pending_queue_argument_returns[return_address] = []

    _pending_queue_argument_returns[return_address].append(argument_record)
    return True


def capture_fill_command_buffer_args_return(frame, _bp_loc, _internal_dict):
    pending = _pending_queue_argument_returns.get(frame.GetPC(), [])
    argument_record = pending.pop() if pending else 0
    print(
        "AO46_AGX_SHADER_QUEUE_RETURN "
        "kind=fill-command-buffer-args "
        f"argument_record={argument_record:#018x} "
        f"argument_bytes={_memory_prefix(frame, argument_record, 0x40)}"
    )
    return False


def capture_bind_buffer_resource_to_command(frame, _bp_loc, _internal_dict):
    # G16X selects a retained context resource from a pointer table before it
    # calls IOGPUResourceListAddResource. The slot and record are observed
    # read-only to establish ownership and flags across workloads; they are
    # never copied back into an Apple object or submitted by this probe.
    context = _register(frame, "x0")
    binding_index = _register(frame, "x1")
    write = _register(frame, "x2")
    slot_address = context + 0x57E8 + (binding_index * 8) if context else 0
    resource = _word_at(frame, slot_address)
    print(
        "AO46_AGX_SHADER_RESOURCE_BIND_CALL "
        "kind=bind-buffer-resource-to-command "
        f"context={context:#018x} "
        f"binding_index={binding_index:#018x} "
        f"write={write:#018x} "
        f"slot={slot_address:#018x} "
        f"resource={resource:#018x} "
        f"resource_record={resource + 0x20 if resource else 0:#018x} "
        f"resource_record_bytes={_memory_prefix(frame, resource + 0x20, 0x40)}"
    )
    return False


def capture_resource_list_add(frame, _bp_loc, _internal_dict):
    # These C calls bind Apple-owned resources into the submission list. The
    # captured words establish object flow only; they are not re-used by AO46.
    caller = frame.GetThread().GetFrameAtIndex(1)
    print(
        "AO46_AGX_SHADER_RESOURCE_LIST_CALL "
        "kind=iogpu-resource-list-add "
        f"list={_register(frame, 'x0'):#018x} "
        f"resource={_register(frame, 'x1'):#018x} "
        f"arg2={_register(frame, 'x2'):#018x} "
        f"arg3={_register(frame, 'x3'):#018x} "
        f"caller={_frame_location(caller)}"
    )
    return False


def _frame_location(frame):
    function = frame.GetFunctionName() or "unknown"
    module = frame.GetModule().GetFileSpec().GetFilename() or "unknown"
    return f"{module}:{function}"


def capture_resource_create(frame, _bp_loc, _internal_dict):
    # IOGPUResourceCreate receives an Apple-owned opaque descriptor. This
    # callback records a bounded prefix and its caller only; AO46 never
    # constructs or mutates the descriptor.
    record = _register(frame, "x1")
    caller = frame.GetThread().GetFrameAtIndex(1)
    print(
        "AO46_AGX_SHADER_RESOURCE_CALL "
        "kind=resource-create "
        f"resource={_register(frame, 'x0'):#018x} "
        f"record={record:#018x} "
        f"record_bytes={_memory_prefix(frame, record, 0x68)} "
        f"caller={_frame_location(caller)}"
    )
    return False


def capture_resource_gpu_address(frame, _bp_loc, _internal_dict):
    resource = _register(frame, "x0")
    caller = frame.GetThread().GetFrameAtIndex(1)
    return_hook = _schedule_resource_gpu_address_return(frame, resource)
    print(
        "AO46_AGX_SHADER_RESOURCE_CALL "
        "kind=resource-gpu-address "
        f"resource={resource:#018x} "
        f"caller={_frame_location(caller)} "
        f"return_hook={int(return_hook)}"
    )
    return False


def _schedule_resource_gpu_address_return(frame, resource):
    process = frame.GetThread().GetProcess()
    target = process.GetTarget()
    return_address = _register(frame, "x30")

    if not return_address or not resource:
        return False

    if return_address not in _resource_gpu_address_return_breakpoints:
        breakpoint = target.BreakpointCreateByAddress(return_address)
        breakpoint.SetScriptCallbackFunction(
            "agx_shader_contract_capture.capture_resource_gpu_address_return"
        )
        _resource_gpu_address_return_breakpoints[return_address] = breakpoint.GetID()
        _pending_resource_gpu_address_returns[return_address] = []

    _pending_resource_gpu_address_returns[return_address].append(resource)
    return True


def capture_resource_gpu_address_return(frame, _bp_loc, _internal_dict):
    pending = _pending_resource_gpu_address_returns.get(frame.GetPC(), [])
    resource = pending.pop() if pending else 0
    print(
        "AO46_AGX_SHADER_RESOURCE_RETURN "
        "kind=resource-gpu-address "
        f"resource={resource:#018x} "
        f"return_word={_register(frame, 'x0'):#018x}"
    )
    return False


def install_static_breakpoints(debugger, _command, result, _internal_dict):
    """Install profile-scoped local-symbol probes after the AGX bundle loads."""
    global _agx_module_base

    target = debugger.GetSelectedTarget()
    bundle_name = os.environ.get("AGX_SHADER_CONTRACT_BUNDLE_NAME", "")
    probes = (
        ("compute-program-factory", "AGX_SHADER_CONTRACT_PROGRAM_FACTORY_OFFSET",
         "agx_shader_contract_capture.capture_compute_program_factory"),
        ("compute-pipeline-init", "AGX_SHADER_CONTRACT_PIPELINE_INIT_OFFSET",
         "agx_shader_contract_capture.capture_compute_pipeline_init"),
        ("compute-pipeline-bind", "AGX_SHADER_CONTRACT_PIPELINE_BIND_OFFSET",
         "agx_shader_contract_capture.capture_compute_pipeline_bind"),
        ("compute-program-address-table", "AGX_SHADER_CONTRACT_PROGRAM_TABLE_OFFSET",
         "agx_shader_contract_capture.capture_compute_program_address_table"),
        ("compute-end-encoding", "AGX_SHADER_CONTRACT_END_ENCODING_OFFSET",
         "agx_shader_contract_capture.capture_compute_end_encoding"),
        ("compute-append-program-tables", "AGX_SHADER_CONTRACT_APPEND_TABLES_OFFSET",
         "agx_shader_contract_capture.capture_compute_append_program_tables"),
        ("compute-set-pipeline-common", "AGX_SHADER_CONTRACT_SET_PIPELINE_OFFSET",
         "agx_shader_contract_capture.capture_compute_set_pipeline_common"),
        ("compute-execute-kernel", "AGX_SHADER_CONTRACT_EXECUTE_KERNEL_OFFSET",
         "agx_shader_contract_capture.capture_compute_execute_kernel"),
        ("compute-end-pass", "AGX_SHADER_CONTRACT_END_PASS_OFFSET",
         "agx_shader_contract_capture.capture_compute_end_pass"),
        ("usc-spill-buffer", "AGX_SHADER_CONTRACT_USC_SPILL_OFFSET",
         "agx_shader_contract_capture.capture_usc_spill_buffer"),
        ("compute-pipeline-resources", "AGX_SHADER_CONTRACT_PIPELINE_RESOURCES_OFFSET",
         "agx_shader_contract_capture.capture_compute_pipeline_resources"),
        ("setup-compute-command", "AGX_SHADER_CONTRACT_SETUP_COMMAND_OFFSET",
         "agx_shader_contract_capture.capture_setup_compute_command"),
        ("new-command", "AGX_SHADER_CONTRACT_NEW_COMMAND_OFFSET",
         "agx_shader_contract_capture.capture_new_command"),
        ("end-command", "AGX_SHADER_CONTRACT_END_COMMAND_OFFSET",
         "agx_shader_contract_capture.capture_end_command"),
        ("bind-buffer-resource-to-command", "AGX_SHADER_CONTRACT_BIND_BUFFER_OFFSET",
         "agx_shader_contract_capture.capture_bind_buffer_resource_to_command"),
        ("compute-program-constructor", "AGX_SHADER_CONTRACT_VARIANT_CONSTRUCTOR_OFFSET",
         "agx_shader_contract_capture.capture_compute_variant_constructor"),
        ("compute-variant-first-heap-select", "AGX_SHADER_CONTRACT_VARIANT_FIRST_HEAP_SELECT_OFFSET",
         "agx_shader_contract_capture.capture_compute_variant_first_heap_select"),
        ("compute-program-finalize", "AGX_SHADER_CONTRACT_VARIANT_FINALIZE_OFFSET",
         "agx_shader_contract_capture.capture_compute_program_finalize"),
        ("compute-program-base-destructor", "AGX_SHADER_CONTRACT_VARIANT_DESTRUCTOR_OFFSET",
         "agx_shader_contract_capture.capture_compute_variant_base_destructor"),
        ("heap-true-allocate", "AGX_SHADER_CONTRACT_HEAP_TRUE_ALLOCATE_OFFSET",
         "agx_shader_contract_capture.capture_heap_true_allocate"),
        ("heap-resource-signpost", "AGX_SHADER_CONTRACT_HEAP_RESOURCE_SIGNPOST_OFFSET",
         "agx_shader_contract_capture.capture_heap_resource_signpost"),
        ("heap-resource-label-return", "AGX_SHADER_CONTRACT_HEAP_RESOURCE_LABEL_RETURN_OFFSET",
         "agx_shader_contract_capture.capture_heap_resource_label_return"),
        ("code-heap-allocate", "AGX_SHADER_CONTRACT_CODE_HEAP_ALLOCATE_OFFSET",
         "agx_shader_contract_capture.capture_code_heap_allocate"),
        ("code-heap-release", "AGX_SHADER_CONTRACT_CODE_HEAP_RELEASE_OFFSET",
         "agx_shader_contract_capture.capture_code_heap_release"),
        ("code-link-info-initialize", "AGX_SHADER_CONTRACT_CODE_LINK_INFO_INITIALIZE_OFFSET",
         "agx_shader_contract_capture.capture_code_link_info_initialize"),
        ("code-heap-relocations", "AGX_SHADER_CONTRACT_CODE_HEAP_RELOCATIONS_OFFSET",
         "agx_shader_contract_capture.capture_code_heap_relocations"),
        ("compute-direct-tg-size", "AGX_SHADER_CONTRACT_DIRECT_TG_SIZE_OFFSET",
         "agx_shader_contract_capture.capture_compute_direct_tg_size"),
        ("usc-spill-info-constructor", "AGX_SHADER_CONTRACT_SPILL_INFO_CTOR_OFFSET",
         "agx_shader_contract_capture.capture_usc_spill_info_constructor"),
        ("device-internal-buffer-grow", "AGX_SHADER_CONTRACT_INTERNAL_BUFFER_GROW_OFFSET",
         "agx_shader_contract_capture.capture_internal_buffer_grow"),
        ("device-setup-buffer-return", "AGX_SHADER_CONTRACT_DEVICE_SETUP_BUFFER_RETURN_OFFSET",
         "agx_shader_contract_capture.capture_device_setup_buffer_return"),
        ("device-setup-buffer-gpu-address-return", "AGX_SHADER_CONTRACT_DEVICE_SETUP_BUFFER_GPU_ADDRESS_RETURN_OFFSET",
         "agx_shader_contract_capture.capture_device_setup_buffer_gpu_address_return"),
    )
    module = None
    agx_modules = []
    for candidate in target.module_iter():
        path = str(candidate.GetFileSpec())
        if "AGX" in path:
            agx_modules.append(path)
        if candidate.GetFileSpec().GetFilename() == bundle_name or \
           path.endswith(bundle_name):
            module = candidate
            break

    if not module:
        print(
            "AO46_AGX_SHADER_CONTRACT_STATIC_MISS "
            f"expected={bundle_name} candidates={'|'.join(agx_modules)}"
        )
        return

    base = module.GetObjectFileHeaderAddress().GetLoadAddress(target)
    if base == lldb.LLDB_INVALID_ADDRESS:
        print("AO46_AGX_SHADER_CONTRACT_STATIC_MISS reason=no-load-address")
        return

    _agx_module_base = base

    for kind, environment_name, callback in probes:
        try:
            offset = int(os.environ[environment_name], 0)
        except (KeyError, ValueError):
            print(
                "AO46_AGX_SHADER_CONTRACT_STATIC_MISS "
                f"reason=missing-{environment_name}"
            )
            return

        address = base + offset
        breakpoint = target.BreakpointCreateByAddress(address)
        breakpoint.SetScriptCallbackFunction(callback)
        print(
            "AO46_AGX_SHADER_CONTRACT_STATIC_INSTALL "
            f"kind={kind} base={base:#018x} offset={offset:#x} "
            f"address={address:#018x} breakpoint={breakpoint.GetID()}"
        )


def install_iogpu_ownership_breakpoints(debugger, _command, result, _internal_dict):
    """Install profile-scoped read-only probes in the loaded IOGPU image."""
    target = debugger.GetSelectedTarget()
    probes = (
        ("resource-initialize", "AO46_IOGPU_RESOURCE_INITIALIZE_OFFSET",
         "agx_shader_contract_capture.capture_iogpu_resource_initialize"),
        ("resource-pool-initialize", "AO46_IOGPU_RESOURCE_POOL_INITIALIZE_OFFSET",
         "agx_shader_contract_capture.capture_iogpu_resource_pool_initialize"),
        ("resource-pool-create", "AO46_IOGPU_RESOURCE_POOL_CREATE_OFFSET",
         "agx_shader_contract_capture.capture_iogpu_pool_create"),
        ("pooled-resource-release", "AO46_IOGPU_POOLED_RESOURCE_RELEASE_OFFSET",
         "agx_shader_contract_capture.capture_iogpu_pooled_resource_release"),
    )
    module = None
    for candidate in target.module_iter():
        path = str(candidate.GetFileSpec())
        if candidate.GetFileSpec().GetFilename() == "IOGPU" or \
           path.endswith("/IOGPU.framework/Versions/A/IOGPU"):
            module = candidate
            break

    if not module:
        print("AO46_IOGPU_OWNERSHIP_STATIC_MISS reason=module-not-loaded")
        return

    base = module.GetObjectFileHeaderAddress().GetLoadAddress(target)
    if base == lldb.LLDB_INVALID_ADDRESS:
        print("AO46_IOGPU_OWNERSHIP_STATIC_MISS reason=no-load-address")
        return

    for kind, environment_name, callback in probes:
        try:
            offset = int(os.environ[environment_name], 0)
        except (KeyError, ValueError):
            print(f"AO46_IOGPU_OWNERSHIP_STATIC_MISS reason=missing-{environment_name}")
            return

        address = base + offset
        breakpoint = target.BreakpointCreateByAddress(address)
        breakpoint.SetScriptCallbackFunction(callback)
        print(
            "AO46_IOGPU_OWNERSHIP_STATIC_INSTALL "
            f"kind={kind} base={base:#018x} offset={offset:#x} "
            f"address={address:#018x} breakpoint={breakpoint.GetID()}"
        )


def install_iogpu_symbolic_ownership_breakpoints(debugger, _command, result, _internal_dict):
    """Install read-only IOGPU probes before AGX/device initialization."""
    target = debugger.GetSelectedTarget()
    probes = (
        ("resource-initialize",
         "-[IOGPUMetalResource initWithDevice:options:args:argsSize:]",
         "agx_shader_contract_capture.capture_iogpu_resource_initialize"),
        ("resource-remote-initialize",
         "-[IOGPUMetalResource initWithDevice:remoteStorageResource:options:args:argsSize:]",
         "agx_shader_contract_capture.capture_iogpu_remote_resource_initialize"),
        ("resource-pool-initialize",
         "-[IOGPUMetalResourcePool initWithDevice:resourceClass:resourceArgs:resourceArgsSize:options:]",
         "agx_shader_contract_capture.capture_iogpu_resource_pool_initialize"),
        ("resource-pool-create", "IOGPUMetalResourcePoolCreatePooledResource",
         "agx_shader_contract_capture.capture_iogpu_pool_create"),
        ("pooled-resource-release", "IOGPUMetalPooledResourceRelease",
         "agx_shader_contract_capture.capture_iogpu_pooled_resource_release"),
    )
    for kind, name, callback in probes:
        breakpoint = target.BreakpointCreateByName(name)
        breakpoint.SetScriptCallbackFunction(callback)
        _iogpu_symbolic_breakpoints[kind] = breakpoint.GetID()
        print(
            "AO46_IOGPU_OWNERSHIP_SYMBOLIC_INSTALL "
            f"kind={kind} name={name} breakpoint={breakpoint.GetID()} "
            f"locations={breakpoint.GetNumLocations()} "
            f"pending={int(breakpoint.GetNumLocations() == 0)}"
        )


def _install_agx_startup_profile_breakpoints(frame):
    """Install G16X-only lifecycle probes after the bundle has loaded."""
    target = frame.GetThread().GetProcess().GetTarget()
    bundle_name = os.environ.get("AGX_SHADER_CONTRACT_BUNDLE_NAME", "")
    module = None
    for candidate in target.module_iter():
        path = str(candidate.GetFileSpec())
        if candidate.GetFileSpec().GetFilename() == bundle_name or \
           path.endswith(bundle_name):
            module = candidate
            break

    if not module:
        print("AO46_AGX_USC_PROBE_MISS reason=agx-module-not-loaded")
        return

    base = module.GetObjectFileHeaderAddress().GetLoadAddress(target)
    if base == lldb.LLDB_INVALID_ADDRESS:
        print("AO46_AGX_USC_PROBE_MISS reason=no-load-address")
        return

    probes = (
        ("heap-config-template", 0x2E703C,
         "agx_shader_contract_capture.capture_usc_heap_config_template"),
        ("profile-kernel-initialization", 0x32DAD4,
         "agx_shader_contract_capture.capture_usc_profile_kernel_initialization"),
        ("profile-global-configuration", 0x32DCFC,
         "agx_shader_contract_capture.capture_usc_profile_global_configuration"),
        ("async-authorization-callsite", 0x2D16D4,
         "agx_shader_contract_capture.capture_usc_async_authorization_callsite"),
        ("resource-pool-setup", 0x2C4B74,
         "agx_shader_contract_capture.capture_agx_resource_pool_setup"),
    )
    for kind, offset, callback in probes:
        if kind in _agx_startup_profile_breakpoints:
            continue
        breakpoint = target.BreakpointCreateByAddress(base + offset)
        breakpoint.SetScriptCallbackFunction(callback)
        _agx_startup_profile_breakpoints[kind] = breakpoint.GetID()
        print(
            "AO46_AGX_USC_PROBE_INSTALL "
            f"kind={kind} base={base:#018x} offset={offset:#x} "
            f"address={base + offset:#018x} breakpoint={breakpoint.GetID()}"
        )


def _capture_agx_usc_startup_event(frame, kind, **fields):
    caller = frame.GetThread().GetFrameAtIndex(1)
    details = " ".join(
        f"{name}={value:#018x}" for name, value in fields.items()
    )
    print(
        "AO46_AGX_USC_STARTUP "
        f"sequence={_next_startup_event_sequence()} kind={kind} {details} "
        f"caller={_frame_location(caller)}"
    )
    return False


def capture_usc_heap_config_template(frame, _bp_loc, _internal_dict):
    # The template producer is observed only to establish startup order. Its
    # generated records remain Apple-owned and are not read or reconstructed.
    return _capture_agx_usc_startup_event(
        frame, "heap-config-template", context=_register(frame, "x0")
    )


def capture_usc_profile_kernel_initialization(frame, _bp_loc, _internal_dict):
    return _capture_agx_usc_startup_event(
        frame, "profile-kernel-initialization", control=_register(frame, "x0")
    )


def capture_usc_profile_global_configuration(frame, _bp_loc, _internal_dict):
    return _capture_agx_usc_startup_event(
        frame,
        "profile-global-configuration",
        control=_register(frame, "x0"),
        configuration_index=_register(frame, "x1"),
    )


def capture_agx_resource_pool_setup(frame, _bp_loc, _internal_dict):
    return _capture_agx_usc_startup_event(
        frame,
        "resource-pool-setup",
        device=_register(frame, "x0"),
        pool_output=_register(frame, "x1"),
    )


def _schedule_usc_async_callsite_return(frame, connection, notification_port,
                                         call_sequence):
    target = frame.GetThread().GetProcess().GetTarget()
    # This breakpoint is immediately after the profiled G16X `bl` instruction,
    # so x0 is the IOKit status from the exact selector-0x107 handoff.
    return_address = frame.GetPC() + 4
    if return_address not in _usc_async_return_breakpoints:
        breakpoint = target.BreakpointCreateByAddress(return_address)
        breakpoint.SetScriptCallbackFunction(
            "agx_shader_contract_capture.capture_usc_async_authorization_return"
        )
        _usc_async_return_breakpoints[return_address] = breakpoint.GetID()
        _pending_usc_async_returns[return_address] = []

    _pending_usc_async_returns[return_address].append(
        (connection, notification_port, call_sequence)
    )
    return True


def capture_usc_async_authorization_callsite(frame, _bp_loc, _internal_dict):
    # Ghidra identifies this one profiled call site as the handoff immediately
    # following global USC configuration. Record only scalar identities/counts;
    # the three-word Apple reference payload is intentionally not retained.
    selector = _register(frame, "x1")
    if selector != 0x107:
        print(
            "AO46_AGX_USC_AUTHORIZATION_MISS "
            f"reason=unexpected-selector selector={selector:#x}"
        )
        return False

    connection = _register(frame, "x0")
    notification_port = _register(frame, "x2")
    event_sequence = _next_startup_event_sequence()
    return_hook = _schedule_usc_async_callsite_return(
        frame, connection, notification_port, event_sequence
    )
    print(
        "AO46_AGX_USC_AUTHORIZATION_CALL "
        f"sequence={event_sequence} selector={selector:#x} "
        f"connection={connection:#018x} notification_port={notification_port:#018x} "
        f"reference_count={_register(frame, 'x4'):#018x} "
        f"input_count={_register(frame, 'x6'):#018x} return_hook={int(return_hook)} "
        "source=profiled-agx-callsite"
    )
    return False


def capture_usc_async_authorization_return(frame, _bp_loc, _internal_dict):
    pending = _pending_usc_async_returns.get(frame.GetPC(), [])
    connection, notification_port, call_sequence = (
        pending.pop() if pending else (0, 0, 0)
    )
    print(
        "AO46_AGX_USC_AUTHORIZATION_RETURN "
        f"sequence={_next_startup_event_sequence()} call_sequence={call_sequence} "
        f"connection={connection:#018x} notification_port={notification_port:#018x} "
        f"result={_register(frame, 'x0'):#018x}"
    )
    return False


def capture_agx_device_initialize(frame, _bp_loc, _internal_dict):
    # Observe the Apple-owned device lifetime that contains the selected heap.
    # The callback does not expose or replay the initializer's private ABI.
    _install_agx_startup_profile_breakpoints(frame)
    print(
        "AO46_AGX_STARTUP_CALL "
        "kind=device-initialize "
        f"device={_register(frame, 'x0'):#018x} "
        f"accelerator_port={_register(frame, 'x2'):#018x}"
    )
    return False


def install_agx_startup_symbolic_breakpoints(debugger, _command, result, _internal_dict):
    """Install load-pending AGX device probes before the process starts."""
    target = debugger.GetSelectedTarget()
    probes = (
        ("device-initialize",
         "-[AGXG16XFamilyDevice initWithAcceleratorPort:simultaneousInstances:]",
         "agx_shader_contract_capture.capture_agx_device_initialize"),
    )
    for kind, name, callback in probes:
        breakpoint = target.BreakpointCreateByName(name)
        breakpoint.SetScriptCallbackFunction(callback)
        _agx_startup_symbolic_breakpoints[kind] = breakpoint.GetID()
        print(
            "AO46_AGX_STARTUP_SYMBOLIC_INSTALL "
            f"kind={kind} name={name} breakpoint={breakpoint.GetID()} "
            f"locations={breakpoint.GetNumLocations()} "
            f"pending={int(breakpoint.GetNumLocations() == 0)}"
        )


def verify_agx_startup_symbolic_breakpoints(debugger, _command, result, _internal_dict):
    """Report load-time resolution for the AGX device ownership probes."""
    target = debugger.GetSelectedTarget()
    for kind, breakpoint_id in _agx_startup_symbolic_breakpoints.items():
        breakpoint = target.FindBreakpointByID(breakpoint_id)
        locations = breakpoint.GetNumLocations() if breakpoint.IsValid() else 0
        print(
            "AO46_AGX_STARTUP_SYMBOLIC_RESOLUTION "
            f"kind={kind} breakpoint={breakpoint_id} locations={locations}"
        )


def verify_iogpu_symbolic_ownership_breakpoints(debugger, _command, result, _internal_dict):
    """Report whether pending symbolic probes resolved after IOGPU loaded."""
    target = debugger.GetSelectedTarget()
    for kind, breakpoint_id in _iogpu_symbolic_breakpoints.items():
        breakpoint = target.FindBreakpointByID(breakpoint_id)
        locations = breakpoint.GetNumLocations() if breakpoint.IsValid() else 0
        print(
            "AO46_IOGPU_OWNERSHIP_SYMBOLIC_RESOLUTION "
            f"kind={kind} breakpoint={breakpoint_id} locations={locations}"
        )
