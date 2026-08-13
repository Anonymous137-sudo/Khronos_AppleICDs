#!/bin/sh
set -eu

if [ "$#" -ne 1 ]; then
    echo "usage: $0 CAPTURE_LOG" >&2
    exit 2
fi

capture_log=$1
if [ ! -f "$capture_log" ]; then
    echo "missing IOGPU queue capture: $capture_log" >&2
    exit 2
fi

LC_ALL=C awk '
function failure(message) {
    print "IOGPU queue contract analysis failed: " message > "/dev/stderr"
    exit 1
}
function field(line, name, value) {
    value = line
    sub(".*" name, "", value)
    sub(" .*$", "", value)
    sub(/\r$/, "", value)
    return value
}
/^AO46_QUEUE_CONTRACT_CONTROL phase=/ {
    active_phase = field($0, "phase=")
    next
}
/^AO46_IOGPU_QUEUE_CREATE / {
    event_order++
    capture_id = field($0, "capture_id=")
    phase = field($0, "phase=")
    device = field($0, "device=")
    bytes = field($0, "bytes=")
    prefix = field($0, "prefix=")
    hook = field($0, "return_hook=")
    if (phase == "unknown")
        phase = active_phase
    if (capture_id == "" || phase != "queue-create" ||
        device == "0x0000000000000000" || bytes != "1040" ||
        length(prefix) != 128 || prefix ~ /[^0-9a-f]/ || hook != "1")
        failure("invalid-queue-create")
    create_device[capture_id] = device
    creates++
}
/^AO46_IOGPU_QUEUE_CREATE_RETURN / {
    event_order++
    capture_id = field($0, "capture_id=")
    device = field($0, "device=")
    queue = field($0, "queue=")
    if (!(capture_id in create_device) || device != create_device[capture_id] ||
        queue == "0x0000000000000000" || (queue in created_queues))
        failure("invalid-queue-return")
    created_queues[queue] = 1
    returned++
}
/^AO46_QUEUE_CONTRACT_PUBLIC_COMMAND_BUFFER / {
    serial = field($0, "serial=")
    command_buffer = field($0, "object=")
    if (serial !~ /^[12]$/ || command_buffer == "0x0000000000000000" ||
        (serial in public_command_buffers))
        failure("invalid-public-command-buffer")
    public_command_buffers[serial] = command_buffer
    public_command_buffer_count++
}
/^AO46_IOGPU_QUEUE_SUBMIT / {
    event_order++
    phase = field($0, "phase=")
    serial = field($0, "serial=")
    queue = field($0, "queue=")
    count = field($0, "buffer_count=")
    command_buffers = field($0, "command_buffers=")
    command_buffer = field($0, "command_buffer=")
    descriptor = field($0, "descriptor=")
    bytes = field($0, "descriptor_bytes=")
    auxiliary = field($0, "auxiliary=")
    data = field($0, "data=")
    if (phase == "unknown")
        phase = active_phase
    if (serial == "0") {
        serial = phase
        sub("^empty-submit-", "", serial)
    }
    if (serial !~ /^[12]$/ || phase != "empty-submit-" serial ||
        (serial in submitted_serials) || !(queue in created_queues) ||
        !(serial in public_command_buffers) ||
        command_buffers != "0x0000000000000000" ||
        command_buffer != "0x0000000000000000" ||
        !(serial in fill_orders) || fill_orders[serial] >= event_order ||
        descriptor != fill_arguments[serial] ||
        descriptor == "0x0000000000000000" || count != "1" ||
        bytes != "64" || auxiliary == "0x0000000000000000" ||
        length(data) != 128 || data ~ /[^0-9a-f]/ ||
        storage_return_order == 0 || storage_return_order >= event_order)
        failure("invalid-queue-submit")
    submitted_serials[serial] = 1
    descriptor_addresses[descriptor] = 1
    submits++
}
/^AO46_IOGPU_COMMAND_BUFFER_FILL / {
    event_order++
    phase = field($0, "phase=")
    serial = field($0, "serial=")
    command_buffer = field($0, "command_buffer=")
    arguments = field($0, "arguments=")
    command_queue = field($0, "command_queue=")
    if (phase == "unknown")
        phase = active_phase
    if (serial == "0") {
        serial = phase
        sub("^empty-submit-", "", serial)
    }
    if (serial !~ /^[12]$/ || phase != "empty-submit-" serial ||
        !(serial in public_command_buffers) ||
        command_buffer != public_command_buffers[serial] ||
        arguments == "0x0000000000000000" ||
        command_queue == "0x0000000000000000" || (serial in fill_orders))
        failure("invalid-command-buffer-fill")
    fill_orders[serial] = event_order
    fill_arguments[serial] = arguments
    fills++
}
/^AO46_IOGPU_COMMAND_STORAGE_CREATE / {
    event_order++
    capture_id = field($0, "capture_id=")
    phase = field($0, "phase=")
    serial = field($0, "serial=")
    hook = field($0, "return_hook=")
    if (phase == "unknown")
        phase = active_phase
    if (serial == "0") {
        serial = phase
        sub("^empty-submit-", "", serial)
    }
    if (serial !~ /^[12]$/ || phase != "empty-submit-" serial ||
        (serial in storage_serials) || capture_id == "" || hook != "1")
        failure("invalid-command-storage")
    storage_serials[serial] = 1
    storage_serial_by_capture[capture_id] = serial
    storage_create_order = event_order
    storage_calls++
}
/^AO46_IOGPU_COMMAND_STORAGE_RETURN / {
    event_order++
    capture_id = field($0, "capture_id=")
    storage = field($0, "storage=")
    if (!(capture_id in storage_serial_by_capture) ||
        storage == "0x0000000000000000" || (storage in storage_objects))
        failure("invalid-command-storage-return")
    storage_objects[storage] = 1
    if (storage_create_order == 0 || storage_return_order != 0 ||
        storage_create_order >= event_order)
        failure("invalid-command-storage-return-order")
    storage_return_order = event_order
    storage_returns++
}
/^AO46_QUEUE_CONTRACT_COMPLETION / {
    event_order++
    serial = field($0, "serial=")
    completed_count = field($0, "completed_count=")
    status = field($0, "status=")
    if (serial !~ /^[12]$/ || completed_count != serial ||
        (serial in completed_serials) || status == "")
        failure("invalid-public-completion")
    completed_serials[serial] = 1
    completions++
}
/^AO46_IOGPU_QUEUE_RELEASE / {
    event_order++
    phase = field($0, "phase=")
    queue = field($0, "queue=")
    if (phase == "unknown")
        phase = active_phase
    if (phase != "release" || !(queue in created_queues) || (queue in released_queues))
        failure("invalid-queue-release")
    released_queues[queue] = 1
    releases++
}
END {
    if (creates != 1 || returned != 1 || submits != 2 || fills != 2 ||
        public_command_buffer_count != 2 || storage_calls != 1 ||
        storage_returns != 1 || completions != 2 || releases != 1 ||
        !(1 in submitted_serials) ||
        !(2 in submitted_serials) || !(1 in storage_serials) ||
        !(1 in completed_serials) ||
        !(2 in completed_serials))
        failure("incomplete-queue-lifecycle")
    unique_descriptor_addresses = 0
    for (descriptor in descriptor_addresses)
        unique_descriptor_addresses++
    print "AO46_IOGPU_QUEUE_CONTRACT verified creates=" creates \
          " returns=" returned " submits=" submits \
          " command_storage=" storage_calls \
          " storage_returns=" storage_returns " completions=" completions \
          " releases=" releases " descriptor_bytes=64 " \
          " descriptor_addresses=" unique_descriptor_addresses \
          " storage_before_first_submit=1 " \
          " public_command_buffers=2 " \
          " public_command_buffer_fills=2 " \
          " fill_descriptor_identity=1 " \
          " generic_object_array=null"
}
' "$capture_log"
