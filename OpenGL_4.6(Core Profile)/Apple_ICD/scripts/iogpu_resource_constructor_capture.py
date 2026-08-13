"""LLDB callback for the Apple-owned IOGPU resource constructor control.

The callback only reads Apple-owned call frames, argument records, and the
returned resource fields backed by exported read-only accessors. Returning
False resumes execution; AO46 never calls the private function itself.
"""

import lldb


RECORD_BYTES = 0x68
RESOURCE_SNAPSHOT_OFFSET = 0x18
RESOURCE_SNAPSHOT_BYTES = 0x30
PHASE_SYMBOL = "ao46_resource_constructor_phase"
_next_capture_id = 1
_pending_returns = {}
_return_breakpoints = {}


def _register(frame, name):
    value = frame.FindRegister(name)
    return value.GetValueAsUnsigned() if value.IsValid() else 0


def _phase(frame, process):
    variable = frame.GetThread().GetProcess().GetTarget().FindFirstGlobalVariable(
        PHASE_SYMBOL
    )
    if not variable.IsValid():
        return "unknown"

    address = variable.GetAddress().GetLoadAddress(process.GetTarget())
    error = lldb.SBError()
    value = process.ReadCStringFromMemory(address, 32, error)
    return value if error.Success() and value else "unknown"


def _schedule_return(frame, metadata):
    target = frame.GetThread().GetProcess().GetTarget()
    return_address = _register(frame, "x30")
    if not return_address:
        return False

    if return_address not in _return_breakpoints:
        return_breakpoint = target.BreakpointCreateByAddress(return_address)
        return_breakpoint.SetScriptCallbackFunction(
            "iogpu_resource_constructor_capture.capture_resource_constructor_return"
        )
        _return_breakpoints[return_address] = return_breakpoint.GetID()
        _pending_returns[return_address] = []

    _pending_returns[return_address].append(metadata)
    return True


def _resource_snapshot(process, resource):
    error = lldb.SBError()
    data = process.ReadMemory(
        resource + RESOURCE_SNAPSHOT_OFFSET, RESOURCE_SNAPSHOT_BYTES, error
    )
    if not error.Success() or len(data) != RESOURCE_SNAPSHOT_BYTES:
        return None

    # These offsets are the current profile's exported accessor backing
    # fields. Read them only to correlate Apple-created objects with public
    # Metal; AO46 does not dereference or construct a resource object.
    def read_u64(offset):
        return int.from_bytes(data[offset : offset + 8], byteorder="little")

    return {
        "data_bytes": read_u64(0x00),
        "data_size": read_u64(0x08),
        "resident_data_size": read_u64(0x10),
        "gpu_virtual_address": read_u64(0x20),
        "gpu_virtual_address_length": read_u64(0x28),
    }


def capture_resource_constructor(frame, _bp_loc, _internal_dict):
    global _next_capture_id

    process = frame.GetThread().GetProcess()
    device = _register(frame, "x0")
    arguments = _register(frame, "x1")
    argument_bytes = _register(frame, "x2")
    tail_registers = [_register(frame, f"x{index}") for index in range(3, 8)]
    capture_id = _next_capture_id
    _next_capture_id += 1
    error = lldb.SBError()
    data = process.ReadMemory(arguments, argument_bytes, error)
    scheduled = _schedule_return(
        frame,
        {
            "capture_id": capture_id,
            "kind": "constructor",
            "device": device,
            "arguments": arguments,
            "phase": _phase(frame, process),
        },
    )

    if argument_bytes != RECORD_BYTES or not error.Success() or len(data) != RECORD_BYTES:
        print(
            "AO46_IOGPU_RESOURCE_FRAME "
            f"capture_id={capture_id} phase={_phase(frame, process)} device={device:#018x} "
            f"args={arguments:#018x} bytes={argument_bytes} "
            f"x3={tail_registers[0]:#018x} x4={tail_registers[1]:#018x} "
            f"x5={tail_registers[2]:#018x} x6={tail_registers[3]:#018x} "
            f"x7={tail_registers[4]:#018x} return_hook={int(scheduled)} data=invalid"
        )
    else:
        print(
            "AO46_IOGPU_RESOURCE_FRAME "
            f"capture_id={capture_id} phase={_phase(frame, process)} device={device:#018x} "
            f"args={arguments:#018x} bytes={argument_bytes} "
            f"x3={tail_registers[0]:#018x} x4={tail_registers[1]:#018x} "
            f"x5={tail_registers[2]:#018x} x6={tail_registers[3]:#018x} "
            f"x7={tail_registers[4]:#018x} return_hook={int(scheduled)} data={data.hex()}"
        )

    return False


def capture_resource_constructor_return(frame, bp_loc, _internal_dict):
    return_address = frame.GetPC()
    pending = _pending_returns.get(return_address, [])
    metadata = pending.pop(0) if pending else None
    if not metadata:
        print("AO46_IOGPU_RESOURCE_CREATE_RETURN capture_id=0 resource=0x0000000000000000")
        return False

    value = _register(frame, "x0")
    if metadata["kind"] == "constructor":
        print(
            "AO46_IOGPU_RESOURCE_CREATE_RETURN "
            f"capture_id={metadata['capture_id']} phase={metadata['phase']} "
            f"device={metadata['device']:#018x} args={metadata['arguments']:#018x} "
            f"resource={value:#018x}"
        )
        if not value:
            # A public oversized allocation reaches Apple's constructor but
            # returns no object. Do not read a null object as a snapshot.
            print(
                "AO46_IOGPU_RESOURCE_OBJECT "
                f"capture_id={metadata['capture_id']} resource={value:#018x} "
                "fields=null"
            )
            return False

        snapshot = _resource_snapshot(frame.GetThread().GetProcess(), value)
        if snapshot is None:
            print(
                "AO46_IOGPU_RESOURCE_OBJECT "
                f"capture_id={metadata['capture_id']} resource={value:#018x} "
                "fields=invalid"
            )
        else:
            print(
                "AO46_IOGPU_RESOURCE_OBJECT "
                f"capture_id={metadata['capture_id']} resource={value:#018x} "
                f"data_bytes={snapshot['data_bytes']:#018x} "
                f"data_size={snapshot['data_size']:#018x} "
                f"resident_data_size={snapshot['resident_data_size']:#018x} "
                f"gpu_virtual_address={snapshot['gpu_virtual_address']:#018x} "
                f"gpu_virtual_address_length={snapshot['gpu_virtual_address_length']:#018x}"
            )
    else:
        print(
            "AO46_IOGPU_RESOURCE_ACCESSOR_RETURN "
            f"capture_id={metadata['capture_id']} function={metadata['function']} "
            f"phase={metadata['phase']} resource={metadata['resource']:#018x} "
            f"value={value:#018x}"
        )
    return False


def _capture_resource_accessor(frame, function):
    global _next_capture_id

    process = frame.GetThread().GetProcess()
    capture_id = _next_capture_id
    _next_capture_id += 1
    resource = _register(frame, "x0")
    scheduled = _schedule_return(
        frame,
        {
            "capture_id": capture_id,
            "kind": "accessor",
            "function": function,
            "phase": _phase(frame, process),
            "resource": resource,
        },
    )
    print(
        "AO46_IOGPU_RESOURCE_ACCESSOR "
        f"capture_id={capture_id} function={function} phase={_phase(frame, process)} "
        f"resource={resource:#018x} return_hook={int(scheduled)}"
    )
    return False


def capture_resource_gpu_virtual_address(frame, _bp_loc, _internal_dict):
    return _capture_resource_accessor(frame, "gpu-virtual-address")


def capture_resource_gpu_virtual_address_length(frame, _bp_loc, _internal_dict):
    return _capture_resource_accessor(frame, "gpu-virtual-address-length")


def capture_resource_selector9(frame, _bp_loc, _internal_dict):
    """Record the IOKit selector-9 handoff made by ResourceCreate.

    This is a debugger-only observation. It proves whether the exact record
    captured at the exported constructor reaches the lower IOKit boundary; it
    does not invoke or modify the call.
    """

    process = frame.GetThread().GetProcess()
    selector = _register(frame, "x1")
    arguments = _register(frame, "x4")
    argument_bytes = _register(frame, "x5")
    if selector != 9 or argument_bytes != RECORD_BYTES:
        return False

    error = lldb.SBError()
    data = process.ReadMemory(arguments, argument_bytes, error)
    print(
        "AO46_IOGPU_RESOURCE_SELECTOR9 "
        f"phase={_phase(frame, process)} args={arguments:#018x} "
        f"bytes={argument_bytes} data="
        f"{data.hex() if error.Success() and len(data) == RECORD_BYTES else 'invalid'}"
    )
    return False


def capture_resource_release(frame, _bp_loc, _internal_dict):
    process = frame.GetThread().GetProcess()
    resource = _register(frame, "x0")
    print(
        "AO46_IOGPU_RESOURCE_RELEASE "
        f"phase={_phase(frame, process)} resource={resource:#018x}"
    )
    return False
