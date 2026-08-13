"""LLDB callbacks for an Apple-driven private AGX winsys trace."""

import lldb


_next_capture_id = 1
_pending_returns = {}
_return_breakpoints = {}
_kernel_command_bases = {}


def _register(frame, name):
    value = frame.FindRegister(name)
    return value.GetValueAsUnsigned() if value.IsValid() else 0


def _schedule_return(frame, metadata):
    process = frame.GetThread().GetProcess()
    target = process.GetTarget()
    return_address = _register(frame, "x30")

    if not return_address:
        return False

    if return_address not in _return_breakpoints:
        breakpoint = target.BreakpointCreateByAddress(return_address)
        breakpoint.SetScriptCallbackFunction(
            "agx_private_winsys_capture.capture_private_return"
        )
        _return_breakpoints[return_address] = breakpoint.GetID()
        _pending_returns[return_address] = []

    _pending_returns[return_address].append(metadata)
    return True


def _capture(frame, name, capture_return=False, return_metadata=None):
    global _next_capture_id

    storage = _register(frame, "x0")
    capture_id = 0
    scheduled = False

    if capture_return:
        capture_id = _next_capture_id
        _next_capture_id += 1
        metadata = {
            "capture_id": capture_id,
            "name": name,
            "storage": storage,
        }
        if return_metadata:
            metadata.update(return_metadata)
        scheduled = _schedule_return(frame, metadata)

    print(
        "AO46_AGX_PRIVATE_WINSYS_CALL "
        f"name={name} "
        f"capture_id={capture_id} return_hook={int(scheduled)} "
        f"x0={storage:#018x} "
        f"x1={_register(frame, 'x1'):#018x} "
        f"x2={_register(frame, 'x2'):#018x} "
        f"x3={_register(frame, 'x3'):#018x} "
        f"x4={_register(frame, 'x4'):#018x} "
        f"x5={_register(frame, 'x5'):#018x}"
    )
    return False


def _capture_bytes(frame, address, byte_count):
    if not address:
        return "unavailable"

    error = lldb.SBError()
    data = frame.GetThread().GetProcess().ReadMemory(address, byte_count, error)
    if not error.Success() or len(data) != byte_count:
        return "unavailable"

    return data.hex()


def capture_private_return(frame, _bp_loc, _internal_dict):
    pending = _pending_returns.get(frame.GetPC(), [])
    metadata = pending.pop(0) if pending else None

    if not metadata:
        print("AO46_AGX_PRIVATE_WINSYS_RETURN capture_id=0 name=unknown")
        return False

    print(
        "AO46_AGX_PRIVATE_WINSYS_RETURN "
        f"capture_id={metadata['capture_id']} name={metadata['name']} "
        f"storage={metadata['storage']:#018x} "
        f"x0={_register(frame, 'x0'):#018x} "
        f"x1={_register(frame, 'x1'):#018x}"
    )
    if metadata["name"] == "begin-kernel-commands":
        _kernel_command_bases[metadata["storage"]] = _register(frame, "x1")
    if metadata["name"] == "alloc-resource-at-index":
        storage = metadata["storage"]
        index = metadata["slot_index"]
        count = _read_u32(frame, storage + 0x318)
        records = _read_pointer(frame, storage + 0x300)
        record = records + index * 0x40 if records and index < count else 0
        record_resource = _read_pointer(frame, record + 0x20) if record else 0
        print(
            "AO46_AGX_PRIVATE_WINSYS_SLOT "
            f"phase=after storage={storage:#018x} index={index:#018x} count={count} "
            f"records={records:#018x} record={record:#018x} "
            f"record_resource={record_resource:#018x} "
            f"record_bytes={_capture_bytes(frame, record, 0x40)}"
        )
    return False


def capture_begin_kernel_commands(frame, _bp_loc, _internal_dict):
    return _capture(frame, "begin-kernel-commands", capture_return=True)


def capture_command_storage_create(frame, _bp_loc, _internal_dict):
    # This is a bounded read-only capture of the constructor's parameter
    # record. It records bytes the function reads directly, never an object
    # layout synthesized by AO46.
    params = _register(frame, "x1")
    print(
        "AO46_AGX_PRIVATE_WINSYS_STORAGE_CREATE_PARAMS "
        f"address={params:#018x} bytes={_capture_bytes(frame, params, 0x40)}"
    )
    return _capture(frame, "command-storage-create", capture_return=True)


def capture_command_buffer_fill(frame, _bp_loc, _internal_dict):
    # arm64 Objective-C ABI: x0 is self; x2 and x3 are the method arguments.
    return _capture(frame, "command-buffer-fill")


def capture_command_buffer_init(frame, _bp_loc, _internal_dict):
    # The initializer is the known boundary between a pool-created allocation
    # and an Apple-configured command carrier. x0 is the command-buffer
    # object; x2, x3, and x4 retain the queue/reference/debug inputs.
    return _capture(frame, "command-buffer-init", capture_return=True)


def capture_command_buffer_begin_segment(frame, _bp_loc, _internal_dict):
    # Objective-C arguments begin at x2. The segment pointer must flow into
    # the storage-level begin call before an Apple resource slot can be used.
    return _capture(frame, "command-buffer-begin-segment")


def capture_storage_pool_create(frame, _bp_loc, _internal_dict):
    # x0 is the Apple storage pool and x1 is the global trace ID. The factory
    # owns construction; this callback only proves its ordering and result.
    return _capture(frame, "storage-pool-create", capture_return=True)


def capture_begin_segment(frame, _bp_loc, _internal_dict):
    storage = _register(frame, "x0")
    segment_pointer = _register(frame, "x1")
    kernel_base = _kernel_command_bases.get(storage, 0)
    kernel_delta = segment_pointer - kernel_base if kernel_base else 0
    print(
        "AO46_AGX_PRIVATE_WINSYS_SEGMENT_POINTER "
        f"storage={storage:#018x} pointer={segment_pointer:#018x} "
        f"kernel_base={kernel_base:#018x} kernel_delta={kernel_delta:#x}"
    )
    return _capture(frame, "begin-segment", capture_return=True)


def capture_grow_kernel_command_buffer(frame, _bp_loc, _internal_dict):
    return _capture(frame, "grow-kernel-command-buffer")


def capture_end_kernel_commands(frame, _bp_loc, _internal_dict):
    return _capture(frame, "end-kernel-commands")


def capture_end_segment(frame, _bp_loc, _internal_dict):
    return _capture(frame, "end-segment")


def capture_alloc_resource_at_index(frame, _bp_loc, _internal_dict):
    # The storage slot table and resource record array are initialized by the
    # Apple carrier factory. Snapshot only the slots selected by an
    # Apple-driven workload, before and after it materializes the binding.
    storage = _register(frame, "x0")
    index = _register(frame, "x1")
    count = _read_u32(frame, storage + 0x318)
    slots = _read_pointer(frame, storage + 0x310)
    records = _read_pointer(frame, storage + 0x300)
    slot_descriptor = _read_pointer(frame, slots + index * 8) if slots and index < count else 0
    record = records + index * 0x40 if records and index < count else 0
    print(
        "AO46_AGX_PRIVATE_WINSYS_SLOT "
        f"phase=before storage={storage:#018x} index={index:#018x} count={count} "
        f"slots={slots:#018x} records={records:#018x} "
        f"slot_descriptor={slot_descriptor:#018x} record={record:#018x} "
        f"slot_descriptor_bytes={_capture_bytes(frame, slot_descriptor, 0x68)} "
        f"record_bytes={_capture_bytes(frame, record, 0x40)}"
    )
    return _capture(frame, "alloc-resource-at-index", capture_return=True,
                    return_metadata={"slot_index": index})


def _read_pointer(frame, address):
    data = _read_bytes(frame, address, 8)
    return int.from_bytes(data, byteorder="little") if data is not None else 0


def _read_u32(frame, address):
    data = _read_bytes(frame, address, 4)
    return int.from_bytes(data, byteorder="little") if data is not None else 0


def _read_bytes(frame, address, byte_count):
    if not address:
        return None

    error = lldb.SBError()
    data = frame.GetThread().GetProcess().ReadMemory(address, byte_count, error)
    return data if error.Success() and len(data) == byte_count else None


def capture_alloc_sideband_buffer(frame, _bp_loc, _internal_dict):
    return _capture(frame, "alloc-sideband-buffer")


def capture_grow_sideband_buffer(frame, _bp_loc, _internal_dict):
    return _capture(frame, "grow-sideband-buffer")


def capture_merge_residency_set_list(frame, _bp_loc, _internal_dict):
    return _capture(frame, "merge-residency-set-list")


def capture_finalize_residency_set_list(frame, _bp_loc, _internal_dict):
    return _capture(frame, "finalize-residency-set-list")


def capture_residency_set_list_create(frame, _bp_loc, _internal_dict):
    return _capture(frame, "residency-set-list-create")


def capture_residency_set_list_destroy(frame, _bp_loc, _internal_dict):
    return _capture(frame, "residency-set-list-destroy")


def capture_resource_list_add_resource(frame, _bp_loc, _internal_dict):
    # The second argument is the opaque list-binding record consumed by the
    # carrier. Record it separately so a controlled public buffer's generic
    # resource reference can be compared without dereferencing either object.
    print(
        "AO46_AGX_PRIVATE_WINSYS_RESOURCE_LIST_BINDING "
        f"list={_register(frame, 'x0'):#018x} "
        f"binding={_register(frame, 'x1'):#018x}"
    )
    return _capture(frame, "resource-list-add-resource")


def capture_resource_list_reset(frame, _bp_loc, _internal_dict):
    return _capture(frame, "resource-list-reset")


def capture_resource_list_merge(frame, _bp_loc, _internal_dict):
    return _capture(frame, "resource-list-merge")


def capture_resource_list_merge_lists(frame, _bp_loc, _internal_dict):
    return _capture(frame, "resource-list-merge-lists")


def capture_resource_group_update(frame, _bp_loc, _internal_dict):
    return _capture(frame, "resource-group-update", capture_return=True)


def capture_queue_submit(frame, _bp_loc, _internal_dict):
    return _capture(frame, "queue-submit")


def capture_trap4(frame, _bp_loc, _internal_dict):
    return _capture(frame, "trap4")


def capture_resource_create(frame, _bp_loc, _internal_dict):
    # IOGPUResourceCreate consumes one opaque 0x68-byte record. Capture the
    # input verbatim from Apple-driven work so the descriptor provenance can
    # be correlated with public buffer GPU ranges without AO46 constructing or
    # passing a record itself.
    record = _register(frame, "x1")
    print(
        "AO46_AGX_PRIVATE_WINSYS_RESOURCE_CREATE_RECORD "
        f"address={record:#018x} bytes={_capture_bytes(frame, record, 0x68)}"
    )
    return _capture(frame, "resource-create", capture_return=True)


def capture_resource_gpu_address(frame, _bp_loc, _internal_dict):
    return _capture(frame, "resource-gpu-address", capture_return=True)


def capture_resource_release(frame, _bp_loc, _internal_dict):
    return _capture(frame, "resource-release")


def capture_resource_pool_create_pooled_resource(frame, _bp_loc, _internal_dict):
    # The pool owns the opaque source descriptor. Capturing its before/after
    # calls links a carrier slot to the Apple-created resource without ever
    # supplying a descriptor from AO46.
    return _capture(frame, "resource-pool-create-pooled-resource", capture_return=True)
