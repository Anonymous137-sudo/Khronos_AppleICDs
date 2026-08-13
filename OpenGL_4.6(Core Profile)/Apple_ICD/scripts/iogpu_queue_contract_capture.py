"""LLDB callbacks for the Apple-owned generic IOGPU queue control."""

import lldb


QUEUE_ARGUMENT_BYTES = 0x410
SUBMIT_DESCRIPTOR_BYTES = 0x40
PHASE_SYMBOL = "ao46_queue_contract_phase"
SERIAL_SYMBOL = "ao46_queue_contract_submission_serial"
_next_capture_id = 1
_pending_returns = {}
_return_breakpoints = {}


def _register(frame, name):
    value = frame.FindRegister(name)
    return value.GetValueAsUnsigned() if value.IsValid() else 0


def _phase(frame, process):
    variable = process.GetTarget().FindFirstGlobalVariable(PHASE_SYMBOL)
    if not variable.IsValid():
        return "unknown"

    address = variable.GetAddress().GetLoadAddress(process.GetTarget())
    error = lldb.SBError()
    value = process.ReadCStringFromMemory(address, 32, error)
    return value if error.Success() and value else "unknown"


def _serial(process):
    value = process.GetTarget().FindFirstGlobalVariable(SERIAL_SYMBOL)
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
            "iogpu_queue_contract_capture.capture_generic_return"
        )
        _return_breakpoints[return_address] = breakpoint.GetID()
        _pending_returns[return_address] = []
    _pending_returns[return_address].append(metadata)
    return True


def capture_queue_create(frame, _bp_loc, _internal_dict):
    global _next_capture_id

    process = frame.GetThread().GetProcess()
    device = _register(frame, "x0")
    arguments = _register(frame, "x1")
    argument_bytes = _register(frame, "x2")
    error = lldb.SBError()
    data = process.ReadMemory(arguments, argument_bytes, error)
    capture_id = _next_capture_id
    _next_capture_id += 1
    scheduled = _schedule_return(
        frame,
        {
            "capture_id": capture_id,
            "kind": "queue-create",
            "phase": _phase(frame, process),
            "device": device,
            "arguments": arguments,
        },
    )
    prefix = data[:64].hex() if error.Success() else "invalid"
    print(
        "AO46_IOGPU_QUEUE_CREATE "
        f"capture_id={capture_id} phase={_phase(frame, process)} "
        f"device={device:#018x} args={arguments:#018x} bytes={argument_bytes} "
        f"prefix={prefix} return_hook={int(scheduled)}"
    )
    return False


def capture_generic_return(frame, _bp_loc, _internal_dict):
    pending = _pending_returns.get(frame.GetPC(), [])
    metadata = pending.pop(0) if pending else None
    if not metadata:
        print("AO46_IOGPU_QUEUE_RETURN capture_id=0 object=0x0000000000000000")
        return False

    returned = _register(frame, "x0")
    if metadata["kind"] == "queue-create":
        print(
            "AO46_IOGPU_QUEUE_CREATE_RETURN "
            f"capture_id={metadata['capture_id']} phase={metadata['phase']} "
            f"device={metadata['device']:#018x} args={metadata['arguments']:#018x} "
            f"queue={returned:#018x}"
        )
    elif metadata["kind"] == "command-storage":
        print(
            "AO46_IOGPU_COMMAND_STORAGE_RETURN "
            f"capture_id={metadata['capture_id']} phase={metadata['phase']} "
            f"serial={metadata['serial']} x0={metadata['x0']:#018x} "
            f"x1={metadata['x1']:#018x} x2={metadata['x2']:#018x} "
            f"x3={metadata['x3']:#018x} storage={returned:#018x}"
        )
    else:
        print(
            "AO46_IOGPU_QUEUE_RETURN "
            f"capture_id={metadata['capture_id']} object={returned:#018x}"
        )
    return False


def capture_queue_submit(frame, _bp_loc, _internal_dict):
    process = frame.GetThread().GetProcess()
    queue = _register(frame, "x0")
    command_buffers = _register(frame, "x1")
    buffer_count = _register(frame, "x2")
    descriptor = _register(frame, "x3")
    descriptor_bytes = _register(frame, "x4")
    auxiliary = _register(frame, "x5")
    serial = _serial(process)
    error = lldb.SBError()
    data = process.ReadMemory(descriptor, descriptor_bytes, error)
    descriptor_hex = data.hex() if error.Success() else "invalid"
    command_buffer = 0
    if command_buffers and buffer_count:
        object_error = lldb.SBError()
        object_bytes = process.ReadMemory(command_buffers, buffer_count * 8,
                                          object_error)
        if object_error.Success() and len(object_bytes) >= 8:
            command_buffer = int.from_bytes(object_bytes[:8], "little")
    print(
        "AO46_IOGPU_QUEUE_SUBMIT "
        f"phase={_phase(frame, process)} serial={serial} queue={queue:#018x} "
        f"command_buffers={command_buffers:#018x} "
        f"command_buffer={command_buffer:#018x} buffer_count={buffer_count} "
        f"descriptor={descriptor:#018x} "
        f"descriptor_bytes={descriptor_bytes} auxiliary={auxiliary:#018x} "
        f"data={descriptor_hex}"
    )
    return False


def capture_command_buffer_fill(frame, _bp_loc, _internal_dict):
    process = frame.GetThread().GetProcess()
    print(
        "AO46_IOGPU_COMMAND_BUFFER_FILL "
        f"phase={_phase(frame, process)} serial={_serial(process)} "
        f"command_buffer={_register(frame, 'x0'):#018x} "
        f"arguments={_register(frame, 'x2'):#018x} "
        f"command_queue={_register(frame, 'x3'):#018x}"
    )
    return False


def capture_queue_release(frame, _bp_loc, _internal_dict):
    process = frame.GetThread().GetProcess()
    print(
        "AO46_IOGPU_QUEUE_RELEASE "
        f"phase={_phase(frame, process)} queue={_register(frame, 'x0'):#018x}"
    )
    return False


def capture_command_storage(frame, _bp_loc, _internal_dict):
    global _next_capture_id

    process = frame.GetThread().GetProcess()
    x0 = _register(frame, "x0")
    x1 = _register(frame, "x1")
    x2 = _register(frame, "x2")
    x3 = _register(frame, "x3")
    capture_id = _next_capture_id
    _next_capture_id += 1
    scheduled = _schedule_return(
        frame,
        {
            "capture_id": capture_id,
            "kind": "command-storage",
            "phase": _phase(frame, process),
            "serial": _serial(process),
            "x0": x0,
            "x1": x1,
            "x2": x2,
            "x3": x3,
        },
    )
    print(
        "AO46_IOGPU_COMMAND_STORAGE_CREATE "
        f"capture_id={capture_id} return_hook={int(scheduled)} "
        f"phase={_phase(frame, process)} serial={_serial(process)} "
        f"x0={x0:#018x} x1={x1:#018x} x2={x2:#018x} x3={x3:#018x}"
    )
    return False
