#!/bin/sh
set -eu

if [ "$#" -ne 1 ]; then
    echo "usage: $0 TRACE_LOG" >&2
    exit 2
fi

trace_log=$1

if [ ! -f "$trace_log" ]; then
    echo "missing AGX render resource-record trace: $trace_log" >&2
    exit 2
fi

# The render control verifies its 64x64 RGBA8 pixels before this script runs.
# This parser validates only the stable public trace contract around that work:
# the allocation immediately following the target marker, one render submit,
# and the two completion records. Render descriptor internals remain opaque.
LC_ALL=C awk '
function failure(message) {
    print "AGX render resource-record verification failed: " message > "/dev/stderr"
    exit 1
}

function trace_field(line, field_name, value) {
    value = line
    sub(".*" field_name, "", value)
    sub(" .*$", "", value)
    return value
}

/AO46_AGX_RENDER_RECORD allocate color-target-rgba8$/ {
    if (target_marker++)
        failure("color target was allocated more than once")
    awaiting_target = 1
    next
}
/MODERN_ALLOCATE_MEM handle=/ {
    if (awaiting_target) {
        target_handle = trace_field($0, "handle=")
        target_gpu = trace_field($0, "gpu=")
        target_cpu = trace_field($0, "cpu=")
        target_size = trace_field($0, "size=")
        awaiting_target = 0
    }
    next
}
/AO46_AGX_RENDER_RECORD render fullscreen-triangle-to-color-target$/ {
    if (render_marker++)
        failure("render was submitted more than once")
    render_started = 1
    next
}
/MODERN_SUBMIT queue=/ {
    if (render_started) {
        submission_count++
        submission_queue = trace_field($0, "queue=")
        submission_header = trace_field($0, "header=")
    }
    next
}
/MODERN_SUBMIT_AUX pointer=/ {
    if (render_started) {
        aux_count++
        aux_offset = trace_field($0, "descriptor_offset=")
        aux_readable = trace_field($0, "readable_prefix=")
    }
    next
}
/MODERN_COMPLETION queue=/ {
    if (render_started)
        completion_count++
    next
}
/AO46_AGX_RENDER_RECORD complete width=64 height=64 bytes=16384$/ {
    complete = 1
}
END {
    if (!complete)
        failure("control workload did not complete its pixel verification")

    if (!target_marker || awaiting_target || target_handle == "" ||
        target_gpu == "" || target_cpu == "" || target_cpu == "0" ||
        target_size != "8000")
        failure("64x64 shared color target allocation was not captured")

    if (!render_marker || submission_count != 1 || submission_queue == "" ||
        submission_header != "2/1")
        failure("render submission contract changed")

    if (aux_count != 1 || aux_offset != "132" || aux_readable != "256")
        failure("render auxiliary descriptor carrier changed")

    if (completion_count != 2)
        failure("render submission did not produce two completions")

    printf "AGX_RENDER_RESOURCE_RECORD_TRACE verified queue=%s target=%s gpu=%s cpu=%s bytes=16384\n", \
        submission_queue, target_handle, target_gpu, target_cpu
}
' "$trace_log"
