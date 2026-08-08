#!/bin/sh
set -eu

if [ "$#" -ne 1 ]; then
    echo "usage: $0 TRACE_LOG" >&2
    exit 2
fi

trace_log=$1

if [ ! -f "$trace_log" ]; then
    echo "missing AGX resource-record variation trace: $trace_log" >&2
    exit 2
fi

# This validates only the controlled 4 KiB and 128 KiB Metal blit workloads.
# It records observed relationships and never interprets the command record as
# a submit format.
LC_ALL=C awk '
function failure(message) {
    print "AGX resource-record variation verification failed: " message > "/dev/stderr"
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

    record_slots[phase, offset] = target
}

/AO46_AGX_RESOURCE_VARIATION allocate source-4k-shared$/ {
    awaiting = "source_4k"
    next
}
/AO46_AGX_RESOURCE_VARIATION allocate private-4k$/ {
    awaiting = "private_4k"
    next
}
/AO46_AGX_RESOURCE_VARIATION allocate destination-4k-shared$/ {
    awaiting = "destination_4k"
    next
}
/AO46_AGX_RESOURCE_VARIATION allocate source-128k-shared$/ {
    awaiting = "source_128k"
    next
}
/AO46_AGX_RESOURCE_VARIATION allocate private-128k$/ {
    awaiting = "private_128k"
    next
}
/AO46_AGX_RESOURCE_VARIATION allocate staging-128k-write-combined$/ {
    awaiting = "staging_128k"
    next
}
/AO46_AGX_RESOURCE_VARIATION allocate destination-128k-shared$/ {
    awaiting = "destination_128k"
    next
}
{
    record_allocation($0)
}
/AO46_AGX_RESOURCE_VARIATION producer-4k shared-to-private$/ {
    phase = "producer_4k"
    next
}
/AO46_AGX_RESOURCE_VARIATION consumer-4k private-to-shared$/ {
    phase = "consumer_4k"
    next
}
/AO46_AGX_RESOURCE_VARIATION producer-128k shared-to-private$/ {
    phase = "producer_128k"
    next
}
/AO46_AGX_RESOURCE_VARIATION consumer-128k private-via-write-combined-to-shared$/ {
    phase = "consumer_128k"
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
/AO46_AGX_RESOURCE_VARIATION complete bytes_4k=4096 bytes_128k=131072$/ {
    complete = 1
}
END {
    if (!complete)
        failure("control workload did not complete")

    if (handles["source_4k"] == "" || handles["private_4k"] == "" ||
        handles["destination_4k"] == "" || handles["source_128k"] == "" ||
        handles["private_128k"] == "" || handles["staging_128k"] == "" ||
        handles["destination_128k"] == "")
        failure("controlled buffer handles were not captured")

    if (submission_queue["producer_4k"] == "" ||
        submission_queue["consumer_4k"] == "" ||
        submission_queue["producer_4k"] != submission_queue["producer_128k"] ||
        submission_queue["consumer_4k"] != submission_queue["consumer_128k"] ||
        submission_queue["producer_4k"] == submission_queue["consumer_4k"])
        failure("submissions did not retain two stable queue identities")

    if (record_handle["producer_4k"] == "" ||
        record_handle["producer_4k"] != record_handle["consumer_4k"] ||
        record_handle["producer_4k"] != record_handle["producer_128k"] ||
        record_handle["producer_4k"] != record_handle["consumer_128k"] ||
        multiple_records["producer_4k"] || multiple_records["consumer_4k"] ||
        multiple_records["producer_128k"] || multiple_records["consumer_128k"])
        failure("submissions did not retain one stable mapped resource record")

    record = record_handle["producer_4k"]
    if (allocation_cpu[record] == "" || allocation_cpu[record] == "0")
        failure("resource record is not a known CPU-mapped allocation")

    if (record_slots["producer_4k", "0"] != handles["source_4k"] ||
        record_slots["producer_4k", "0x8"] != handles["private_4k"] ||
        record_slots["consumer_4k", "0"] != handles["private_4k"] ||
        record_slots["consumer_4k", "0x8"] != handles["destination_4k"] ||
        record_slots["producer_128k", "0"] != handles["source_128k"] ||
        record_slots["producer_128k", "0x8"] != handles["private_128k"] ||
        record_slots["consumer_128k", "0"] != handles["private_128k"] ||
        record_slots["consumer_128k", "0x8"] != handles["staging_128k"] ||
        record_slots["consumer_128k", "0x20"] != handles["staging_128k"] ||
        record_slots["consumer_128k", "0x28"] != handles["destination_128k"])
        failure("resource record prefix did not remain stable across variations")

    for (phase_name in completion_count) {
        if (completion_count[phase_name] < 2)
            failure("a controlled submission did not produce two completions")
    }

    if (completion_count["producer_4k"] < 2 ||
        completion_count["consumer_4k"] < 2 ||
        completion_count["producer_128k"] < 2 ||
        completion_count["consumer_128k"] < 2)
        failure("a controlled submission did not produce two completions")

    printf "AGX_RESOURCE_RECORD_VARIATION_TRACE verified producer_queue=%s consumer_queue=%s record=%s record_cpu=%s source_4k=%s private_4k=%s destination_4k=%s source_128k=%s private_128k=%s staging_128k=%s destination_128k=%s\n", \
        submission_queue["producer_4k"], submission_queue["consumer_4k"], \
        record, allocation_cpu[record], handles["source_4k"], \
        handles["private_4k"], handles["destination_4k"], handles["source_128k"], \
        handles["private_128k"], handles["staging_128k"], handles["destination_128k"]
}
' "$trace_log"
