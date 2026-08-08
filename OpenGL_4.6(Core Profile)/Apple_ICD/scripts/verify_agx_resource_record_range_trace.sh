#!/bin/sh
set -eu

if [ "$#" -ne 1 ]; then
    echo "usage: $0 TRACE_LOG" >&2
    exit 2
fi

trace_log=$1

if [ ! -f "$trace_log" ]; then
    echo "missing AGX resource-record range trace: $trace_log" >&2
    exit 2
fi

# This validates only the controlled non-zero-range Metal blit workload. It
# records observed address relationships and never creates a raw UABI command.
LC_ALL=C awk '
function failure(message) {
    print "AGX resource-record range verification failed: " message > "/dev/stderr"
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

function record_reference(phase, line, source, target, offset, delta) {
    if (phase == "" ||
        line !~ /MODERN_RESOURCE_REFERENCE source_handle=.*source_offset=.*target_handle=.*gpu_delta=/)
        return

    source = trace_field(line, "source_handle=")
    offset = trace_field(line, "source_offset=")
    target = trace_field(line, "target_handle=")
    delta = trace_field(line, "gpu_delta=")

    if (record_handle[phase] == "")
        record_handle[phase] = source
    else if (record_handle[phase] != source)
        multiple_records[phase] = 1

    record_target[phase, offset] = target
    record_delta[phase, offset] = delta
}

/AO46_AGX_RESOURCE_RANGE allocate source-shared$/ {
    awaiting = "source"
    next
}
/AO46_AGX_RESOURCE_RANGE allocate private-transfer$/ {
    awaiting = "private"
    next
}
/AO46_AGX_RESOURCE_RANGE allocate staging-write-combined$/ {
    awaiting = "staging"
    next
}
/AO46_AGX_RESOURCE_RANGE allocate destination-shared$/ {
    awaiting = "destination"
    next
}
{
    record_allocation($0)
}
/AO46_AGX_RESOURCE_RANGE producer source-0x1000-to-private-0x3000$/ {
    phase = "producer"
    next
}
/AO46_AGX_RESOURCE_RANGE consumer private-0x3000-via-staging-0x5000-to-destination-0x7000$/ {
    phase = "consumer"
    next
}
/MODERN_RESOURCE_REFERENCE / {
    record_reference(phase, $0)
    next
}
/MODERN_SUBMIT queue=/ {
    queue = trace_field($0, "queue=")
    if (phase != "")
        submission_queue[phase] = queue
    next
}
/MODERN_COMPLETION queue=/ {
    if (phase != "")
        completion_count[phase]++
    next
}
/AO46_AGX_RESOURCE_RANGE complete copy_size=8192 source_offset=4096 private_offset=12288 staging_offset=20480 destination_offset=28672$/ {
    complete = 1
}
END {
    if (!complete)
        failure("control workload did not complete")

    if (handles["source"] == "" || handles["private"] == "" ||
        handles["staging"] == "" || handles["destination"] == "")
        failure("controlled buffer handles were not captured")

    if (submission_queue["producer"] == "" ||
        submission_queue["consumer"] == "" ||
        submission_queue["producer"] == submission_queue["consumer"])
        failure("submissions did not use two distinct queues")

    if (record_handle["producer"] == "" ||
        record_handle["producer"] != record_handle["consumer"] ||
        multiple_records["producer"] || multiple_records["consumer"])
        failure("submissions did not retain one stable mapped resource record")

    record = record_handle["producer"]
    if (allocation_cpu[record] == "" || allocation_cpu[record] == "0")
        failure("resource record is not a known CPU-mapped allocation")

    if (record_target["producer", "0"] != handles["source"] ||
        record_delta["producer", "0"] != "1000" ||
        record_target["producer", "0x8"] != handles["private"] ||
        record_delta["producer", "0x8"] != "3000" ||
        record_target["consumer", "0"] != handles["private"] ||
        record_delta["consumer", "0"] != "3000" ||
        record_target["consumer", "0x8"] != handles["staging"] ||
        record_delta["consumer", "0x8"] != "5000" ||
        record_target["consumer", "0x20"] != handles["staging"] ||
        record_delta["consumer", "0x20"] != "5000" ||
        record_target["consumer", "0x28"] != handles["destination"] ||
        record_delta["consumer", "0x28"] != "7000")
        failure("resource record did not preserve the controlled byte offsets")

    if (completion_count["producer"] < 2 || completion_count["consumer"] < 2)
        failure("a controlled submission did not produce two completions")

    printf "AGX_RESOURCE_RECORD_RANGE_TRACE verified producer_queue=%s consumer_queue=%s record=%s record_cpu=%s source=%s@0x1000 private=%s@0x3000 staging=%s@0x5000 destination=%s@0x7000\n", \
        submission_queue["producer"], submission_queue["consumer"], record, \
        allocation_cpu[record], handles["source"], handles["private"], \
        handles["staging"], handles["destination"]
}
' "$trace_log"
