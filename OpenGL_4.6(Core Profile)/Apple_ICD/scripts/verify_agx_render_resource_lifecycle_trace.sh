#!/bin/sh
set -eu

if [ "$#" -ne 1 ]; then
    echo "usage: $0 TRACE_LOG" >&2
    exit 2
fi

trace_log=$1

if [ ! -f "$trace_log" ]; then
    echo "missing AGX render lifecycle trace: $trace_log" >&2
    exit 2
fi

# Each target is rendered and read back before it is released. This validates
# only ordering and completion transport around two public Metal lifecycles,
# not an inferred layout for render descriptors or AGX resource lists.
LC_ALL=C awk '
function failure(message) {
    print "AGX render lifecycle verification failed: " message > "/dev/stderr"
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

/AO46_AGX_RENDER_LIFECYCLE allocate target-a-rgba8$/ {
    if (allocated_a++)
        failure("target A was allocated more than once")
    awaiting_target = "a"
    next
}
/AO46_AGX_RENDER_LIFECYCLE allocate target-b-rgba8$/ {
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
/AO46_AGX_RENDER_LIFECYCLE render target-a$/ {
    if (render_a++)
        failure("target A was rendered more than once")
    active_render = "a"
    next
}
/AO46_AGX_RENDER_LIFECYCLE release target-a-after-completion$/ {
    if (active_render != "a" || submissions["a"] != 1 || completions["a"] != 2)
        failure("target A was released before its render completed")
    released_a = 1
    active_render = ""
    next
}
/AO46_AGX_RENDER_LIFECYCLE render target-b$/ {
    if (!released_a)
        failure("target B began before target A was released")
    if (render_b++)
        failure("target B was rendered more than once")
    active_render = "b"
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
/MODERN_COMPLETION queue=/ {
    if (active_render != "")
        completions[active_render]++
    next
}
/AO46_AGX_RENDER_LIFECYCLE complete targets=2 width=64 height=64 bytes=16384$/ {
    complete = 1
}
END {
    if (!complete)
        failure("control workload did not complete its pixel verification")

    for (which in target_handle) {
        if (target_handle[which] == "" || target_gpu[which] == "" ||
            target_cpu[which] == "" || target_cpu[which] == "0" ||
            target_size[which] != "8000")
            failure("shared RGBA8 target allocation was incomplete")
    }

    if (!allocated_a || !allocated_b || awaiting_target != "" || !released_a ||
        !render_a || !render_b)
        failure("target lifecycle markers were incomplete")

    if (submissions["a"] != 1 || submissions["b"] != 1 ||
        completions["a"] != 2 || completions["b"] != 2 ||
        queues["a"] == "" || queues["b"] == "" ||
        headers["a"] != "2/1" || headers["b"] != "2/1")
        failure("render submission or completion contract changed")

    if (aux_counts["a"] != 1 || aux_counts["b"] != 1 ||
        aux_offsets["a"] != "132" || aux_offsets["b"] != "132" ||
        aux_readables["a"] != "256" || aux_readables["b"] != "256")
        failure("render auxiliary descriptor carrier changed")

    reused_handle = target_handle["a"] == target_handle["b"] ? "yes" : "no"
    printf "AGX_RENDER_RESOURCE_LIFECYCLE_TRACE verified queue_a=%s target_a=%s queue_b=%s target_b=%s reused_handle=%s\n", \
        queues["a"], target_handle["a"], queues["b"], target_handle["b"], \
        reused_handle
}
' "$trace_log"
