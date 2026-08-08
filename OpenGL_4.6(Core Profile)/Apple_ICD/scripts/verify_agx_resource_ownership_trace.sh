#!/bin/sh
set -eu

if [ "$#" -ne 1 ]; then
    echo "usage: $0 TRACE_LOG" >&2
    exit 2
fi

trace_log=$1

if [ ! -f "$trace_log" ]; then
    echo "missing AGX resource-ownership trace: $trace_log" >&2
    exit 2
fi

# This validates only the controlled Metal blit workload. Handles are allocated
# by the OS and therefore vary per run; their relationships must not.
# Trace hexdumps include raw process bytes; parse them as bytes rather than
# requiring the active locale to decode every line as valid text.
LC_ALL=C awk '
function failure(message) {
    print "AGX resource-ownership trace verification failed: " message > "/dev/stderr"
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
    allocation_size[handle] = trace_field(line, "size=")
    allocation_reused[handle] = trace_field(line, "reused=")

    if (awaiting != "") {
        handles[awaiting] = handle
        if (awaiting == "recycled")
            recycled_after_private_release = private_released
        awaiting = ""
    }
}

function record_reference(phase, line, source, target, offset) {
    if (phase == "" ||
        line !~ /MODERN_RESOURCE_REFERENCE source_handle=.*source_offset=.*target_handle=/)
        return

    source = trace_field(line, "source_handle=")
    offset = trace_field(line, "source_offset=")
    target = trace_field(line, "target_handle=")

    if (record_handle[phase] == "")
        record_handle[phase] = source
    else if (record_handle[phase] != source)
        multiple_records[phase] = 1

    references[phase, target] = 1
    record_slots[phase, offset] = target
}

/AO46_AGX_TRACE_CONTROL allocate shared-default-source$/ {
    awaiting = "source"
    next
}
/AO46_AGX_TRACE_CONTROL allocate shared-write-combined-staging$/ {
    awaiting = "staging"
    next
}
/AO46_AGX_TRACE_CONTROL allocate private-transfer$/ {
    awaiting = "private"
    next
}
/AO46_AGX_TRACE_CONTROL allocate shared-default-destination$/ {
    awaiting = "destination"
    next
}
{
    record_allocation($0)
}
/AO46_AGX_TRACE_CONTROL producer-copy shared-to-private$/ {
    phase = "producer"
    next
}
/AO46_AGX_TRACE_CONTROL consumer-copy private-via-write-combined-to-shared$/ {
    phase = "consumer"
    next
}
/MODERN_RESOURCE_REFERENCE / {
    record_reference(phase, $0)
    next
}
/MODERN_SUBMIT queue=/ {
    queue = $0
    sub(/.*queue=/, "", queue)
    sub(/ .*/, "", queue)
    if (phase == "producer")
        producer_queue = queue
    else if (phase == "consumer")
        consumer_queue = queue
    next
}
/MODERN_COMPLETION queue=/ {
    if (phase != "")
        completion_count[phase]++
    next
}
/AO46_AGX_TRACE_CONTROL release private-transfer$/ {
    private_released = 1
    producer_completed_before_release = completion_count["producer"] >= 2
    consumer_completed_before_release = completion_count["consumer"] >= 2
    next
}
/AO46_AGX_TRACE_CONTROL allocate shared-default-recycled$/ {
    awaiting = "recycled"
    next
}
/AO46_AGX_TRACE_CONTROL complete bytes=65536 allocations=9$/ {
    complete = 1
}
END {
    if (!complete)
        failure("control workload did not complete")

    if (handles["source"] == "" || handles["staging"] == "" ||
        handles["private"] == "" || handles["destination"] == "")
        failure("controlled buffer handles were not captured")

    if (producer_queue == "" || consumer_queue == "" ||
        producer_queue == consumer_queue)
        failure("submissions did not use two distinct queues")

    if (!references["producer", handles["source"]] ||
        !references["producer", handles["private"]])
        failure("producer resource set does not contain source and private buffers")

    if (!references["consumer", handles["private"]] ||
        !references["consumer", handles["staging"]] ||
        !references["consumer", handles["destination"]])
        failure("consumer resource set does not contain private, staging, and destination buffers")

    if (record_handle["producer"] == "" ||
        record_handle["producer"] != record_handle["consumer"] ||
        multiple_records["producer"] || multiple_records["consumer"])
        failure("submissions did not use one stable mapped resource record")

    record = record_handle["producer"]
    if (allocation_cpu[record] == "" || allocation_cpu[record] == "0" ||
        allocation_size[record] == "")
        failure("resource record is not a known CPU-mapped allocation")

    if (record_slots["producer", "0"] != handles["source"] ||
        record_slots["producer", "0x8"] != handles["private"] ||
        record_slots["consumer", "0"] != handles["private"] ||
        record_slots["consumer", "0x8"] != handles["staging"] ||
        record_slots["consumer", "0x20"] != handles["staging"] ||
        record_slots["consumer", "0x28"] != handles["destination"])
        failure("resource record prefix does not match the controlled blit layout")

    if (!private_released || !producer_completed_before_release ||
        !consumer_completed_before_release || !recycled_after_private_release ||
        handles["recycled"] != handles["private"] ||
        allocation_reused[handles["recycled"]] != "1")
        failure("private buffer was not recycled after both submission completions")

    printf "AGX_RESOURCE_OWNERSHIP_TRACE verified producer_queue=%s consumer_queue=%s record=%s record_cpu=%s source=%s private=%s staging=%s destination=%s\n", \
        producer_queue, consumer_queue, record, allocation_cpu[record], \
        handles["source"], handles["private"], handles["staging"], \
        handles["destination"]
}
' "$trace_log"
