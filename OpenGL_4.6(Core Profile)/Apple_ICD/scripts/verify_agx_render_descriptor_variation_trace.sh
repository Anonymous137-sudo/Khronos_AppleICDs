#!/bin/sh
set -eu

if [ "$#" -ne 1 ]; then
    echo "usage: $0 TRACE_LOG" >&2
    exit 2
fi

trace_log=$1

if [ ! -f "$trace_log" ]; then
    echo "missing AGX render descriptor-variation trace: $trace_log" >&2
    exit 2
fi

# This captures repeat-versus-geometry-change descriptor snapshots. The public
# Metal control verifies pixels; this script proves capture ordering and outer
# carrier shape only. Changed auxiliary bytes remain intentionally undecoded.
LC_ALL=C awk '
function failure(message) {
    print "AGX render descriptor-variation verification failed: " message > "/dev/stderr"
    exit 1
}

function trace_field(line, field_name, value) {
    value = line
    sub(".*" field_name, "", value)
    sub(" .*$", "", value)
    return value
}

function capture_target(which) {
    target_handle[which] = trace_field($0, "handle=")
    target_gpu[which] = trace_field($0, "gpu=")
    target_cpu[which] = trace_field($0, "cpu=")
    target_size[which] = trace_field($0, "size=")
    awaiting_target = ""
}

/AO46_AGX_RENDER_VARIATION allocate target-a-64x64-rgba8$/ {
    if (allocated_a++)
        failure("target A was allocated more than once")
    awaiting_target = "a"
    next
}
/AO46_AGX_RENDER_VARIATION allocate target-b-128x32-rgba8$/ {
    if (allocated_b++)
        failure("target B was allocated more than once")
    awaiting_target = "b"
    next
}
/MODERN_ALLOCATE_MEM handle=/ {
    if (awaiting_target != "")
        capture_target(awaiting_target)
    next
}
/AO46_AGX_RENDER_VARIATION render target-a-first$/ {
    if (render_first++)
        failure("first target-A render was repeated")
    active_render = "first"
    next
}
/AO46_AGX_RENDER_VARIATION render target-a-repeat$/ {
    if (render_repeat++)
        failure("repeat target-A render was repeated")
    active_render = "repeat"
    next
}
/AO46_AGX_RENDER_VARIATION render target-b-128x32$/ {
    if (render_variation++)
        failure("target-B variation render was repeated")
    active_render = "variation"
    next
}
/MODERN_SUBMIT queue=/ {
    if (active_render != "") {
        submissions[active_render]++
        queues[active_render] = trace_field($0, "queue=")
        headers[active_render] = trace_field($0, "header=")
    }
    next
}
/MODERN_SUBMIT_AUX pointer=/ {
    if (active_render != "") {
        aux_counts[active_render]++
        aux_offsets[active_render] = trace_field($0, "descriptor_offset=")
        aux_readables[active_render] = trace_field($0, "readable_prefix=")
    }
    next
}
/MODERN_SUBMIT_AUX_DIFF queue=.*baseline=256$/ {
    baseline_count++
    next
}
/MODERN_SUBMIT_AUX_DIFF queue=.*changed=[0-9]+ bytes=256$/ {
    changed_snapshot_count++
    next
}
/MODERN_COMPLETION queue=/ {
    if (active_render != "")
        completions[active_render]++
    next
}
/AO46_AGX_RENDER_VARIATION complete submissions=3 bytes=16384$/ {
    complete = 1
}
END {
    if (!complete)
        failure("control workload did not complete its pixel verification")

    if (!allocated_a || !allocated_b || awaiting_target != "" ||
        target_handle["a"] == "" || target_handle["b"] == "" ||
        target_handle["a"] == target_handle["b"] ||
        target_gpu["a"] == "" || target_gpu["b"] == "" ||
        target_cpu["a"] == "" || target_cpu["b"] == "" ||
        target_cpu["a"] == "0" || target_cpu["b"] == "0" ||
        target_size["a"] != "8000" || target_size["b"] != "8000")
        failure("simultaneously live shared render targets were not captured")

    if (!render_first || !render_repeat || !render_variation ||
        baseline_count != 1 || changed_snapshot_count != 2)
        failure("repeat-versus-variation trace ordering was incomplete")

    if (submissions["first"] != 1 || submissions["repeat"] != 1 ||
        submissions["variation"] != 1 || completions["first"] != 2 ||
        completions["repeat"] != 2 || completions["variation"] != 2 ||
        headers["first"] != "2/1" || headers["repeat"] != "2/1" ||
        headers["variation"] != "2/1" || aux_counts["first"] != 1 ||
        aux_counts["repeat"] != 1 || aux_counts["variation"] != 1 ||
        aux_offsets["first"] != "132" || aux_offsets["repeat"] != "132" ||
        aux_offsets["variation"] != "132" || aux_readables["first"] != "256" ||
        aux_readables["repeat"] != "256" || aux_readables["variation"] != "256")
        failure("render submission carrier contract changed")

    if (queues["first"] == "" || queues["first"] != queues["repeat"] ||
        queues["first"] != queues["variation"])
        failure("render variation did not remain on one queue")

    printf "AGX_RENDER_DESCRIPTOR_VARIATION_TRACE verified queue=%s target_a=%s target_b=%s snapshots=baseline+2-changed\n", \
        queues["first"], target_handle["a"], target_handle["b"]
}
' "$trace_log"
