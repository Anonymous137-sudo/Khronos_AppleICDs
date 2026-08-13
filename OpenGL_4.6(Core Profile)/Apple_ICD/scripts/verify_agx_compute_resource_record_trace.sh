#!/bin/sh
set -eu

if [ "$#" -ne 1 ]; then
    echo "usage: $0 TRACE_LOG" >&2
    exit 2
fi

trace_log=$1

if [ ! -f "$trace_log" ]; then
    echo "missing AGX compute resource-record trace: $trace_log" >&2
    exit 2
fi

# This validates only the controlled Metal compute dispatch. Pipeline-owned
# records remain opaque; the gate isolates the record that names app buffers.
LC_ALL=C awk '
function failure(message) {
    print "AGX compute resource-record verification failed: " message > "/dev/stderr"
    exit 1
}

function trace_field(line, field_name, value) {
    value = line
    sub(".*" field_name, "", value)
    sub(" .*$", "", value)
    return value
}

function record_allocation(line, handle) {
    if (line !~ /MODERN_ALLOCATE_MEM handle=/)
        return

    handle = trace_field(line, "handle=")
    allocation_cpu[handle] = trace_field(line, "cpu=")
    if (awaiting != "") {
        handles[awaiting] = handle
        awaiting = ""
    }
}

function record_reference(line, source, target, offset, delta) {
    if (line !~ /MODERN_RESOURCE_REFERENCE source_handle=.*source_offset=.*target_handle=.*gpu_delta=/)
        return

    source = trace_field(line, "source_handle=")
    target = trace_field(line, "target_handle=")
    offset = trace_field(line, "source_offset=")
    delta = trace_field(line, "gpu_delta=")

    if (target != handles["input"] && target != handles["output"])
        return

    if (app_record == "")
        app_record = source
    else if (app_record != source)
        app_record_conflict = 1

    app_record_target[offset] = target
    app_record_delta[offset] = delta
}

/AO46_AGX_COMPUTE_RECORD allocate input-shared$/ {
    awaiting = "input"
    next
}
/AO46_AGX_COMPUTE_RECORD allocate output-shared$/ {
    awaiting = "output"
    next
}
{
    record_allocation($0)
}
/AO46_AGX_COMPUTE_RECORD dispatch transform-input-to-output([[:space:]]|$)/ {
    dispatch_started = 1
    next
}
/MODERN_RESOURCE_REFERENCE / {
    if (dispatch_started)
        record_reference($0)
    next
}
/MODERN_SUBMIT queue=/ {
    if (dispatch_started) {
        submission_count++
        submission_queue = trace_field($0, "queue=")
    }
    next
}
/MODERN_COMPLETION queue=/ {
    if (dispatch_started)
        completion_count++
    next
}
/AO46_AGX_COMPUTE_RECORD complete elements=1024 bytes=4096$/ {
    complete = 1
}
END {
    if (!complete)
        failure("control workload did not complete")

    if (handles["input"] == "" || handles["output"] == "")
        failure("compute input or output handle was not captured")

    if (submission_count != 1 || submission_queue == "")
        failure("compute control did not produce exactly one submission")

    if (app_record == "" || app_record_conflict ||
        allocation_cpu[app_record] == "" || allocation_cpu[app_record] == "0")
        failure("compute app-resource record is not one known CPU-mapped allocation")

    if (app_record_target["0x1ba0"] != handles["input"] ||
        app_record_delta["0x1ba0"] != "0" ||
        app_record_target["0x1ba8"] != handles["output"] ||
        app_record_delta["0x1ba8"] != "0")
        failure("compute app-resource record did not preserve the observed input/output slots")

    if (completion_count < 2)
        failure("compute dispatch did not produce two completions")

    printf "AGX_COMPUTE_RESOURCE_RECORD_TRACE verified queue=%s record=%s record_cpu=%s input=%s@0x1ba0 output=%s@0x1ba8\n", \
        submission_queue, app_record, allocation_cpu[app_record], handles["input"], \
        handles["output"]
}
' "$trace_log"
