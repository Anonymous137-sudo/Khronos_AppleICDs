#!/bin/sh
set -eu

if [ "$#" -ne 1 ]; then
    echo "usage: $0 TRACE_LOG" >&2
    exit 2
fi

trace_log=$1

if [ ! -f "$trace_log" ]; then
    echo "missing AGX shader-execution trace: $trace_log" >&2
    exit 2
fi

# Allocation observation is intentionally phase-scoped. A public Metal
# allocation has no implied Mesa USC or executable-code import capability.
LC_ALL=C awk '
function failure(message) {
    print "AGX shader-execution verification failed: " message > "/dev/stderr"
    exit 1
}

function advance(expected, next_phase, label) {
    if (phase != expected) failure(label " arrived in " phase)
    phase = next_phase
}

function trace_field(line, name, value) {
    value = line
    sub(".*" name, "", value)
    sub(" .*$", "", value)
    return value
}

/AO46_AGX_SHADER_EXECUTION source-compile-begin$/ {
    advance("", "compile", "source compile")
    next
}
/AO46_AGX_SHADER_EXECUTION source-compile-ready$/ {
    advance("compile", "function", "source compile completion")
    next
}
/AO46_AGX_SHADER_EXECUTION function-ready$/ {
    if (phase != "function") failure("function arrived out of order")
    phase = "queue"
    next
}
/AO46_AGX_SHADER_EXECUTION queue-create-begin$/ { if (phase != "queue") failure("queue begin arrived out of order"); next }
/AO46_AGX_SHADER_EXECUTION queue-create-ready$/ { advance("queue", "pipeline", "queue completion"); next }
/AO46_AGX_SHADER_EXECUTION pipeline-create-begin$/ { if (phase != "pipeline") failure("pipeline begin arrived out of order"); next }
/AO46_AGX_SHADER_EXECUTION pipeline-create-ready$/ { advance("pipeline", "buffer", "pipeline completion"); next }
/AO46_AGX_SHADER_EXECUTION buffer-create-begin$/ { if (phase != "buffer") failure("buffer begin arrived out of order"); next }
/AO46_AGX_SHADER_EXECUTION buffer-create-ready$/ { advance("buffer", "command", "buffer completion"); next }
/AO46_AGX_SHADER_EXECUTION command-buffer-create-begin$/ { if (phase != "command") failure("command-buffer begin arrived out of order"); next }
/AO46_AGX_SHADER_EXECUTION command-buffer-create-ready$/ { advance("command", "encoder", "command-buffer completion"); next }
/AO46_AGX_SHADER_EXECUTION encoder-create-begin$/ { if (phase != "encoder") failure("encoder begin arrived out of order"); next }
/AO46_AGX_SHADER_EXECUTION encoder-create-ready$/ { advance("encoder", "pipeline-bind", "encoder completion"); next }
/AO46_AGX_SHADER_EXECUTION pipeline-bind-begin$/ { if (phase != "pipeline-bind") failure("pipeline bind begin arrived out of order"); next }
/AO46_AGX_SHADER_EXECUTION pipeline-bind-ready$/ { advance("pipeline-bind", "resource-bind", "pipeline bind completion"); next }
/AO46_AGX_SHADER_EXECUTION resource-bind-begin$/ { if (phase != "resource-bind") failure("resource bind begin arrived out of order"); next }
/AO46_AGX_SHADER_EXECUTION resource-bind-ready$/ { advance("resource-bind", "dispatch", "resource bind completion"); next }
/AO46_AGX_SHADER_EXECUTION dispatch-begin$/ { if (phase != "dispatch") failure("dispatch begin arrived out of order"); dispatch_started = 1; next }
/AO46_AGX_SHADER_EXECUTION dispatch-ready$/ { advance("dispatch", "commit", "dispatch completion"); next }
/AO46_AGX_SHADER_EXECUTION commit-begin$/ { if (phase != "commit") failure("commit begin arrived out of order"); next }
/AO46_AGX_SHADER_EXECUTION commit-ready$/ { if (phase != "commit") failure("commit completion arrived out of order"); phase = "completion"; next }
/AO46_AGX_SHADER_EXECUTION completion-wait-begin$/ { if (phase != "completion") failure("completion wait arrived out of order"); next }
/AO46_AGX_SHADER_EXECUTION completion-wait-ready$/ { if (phase != "completion") failure("completion ready arrived out of order"); phase = "complete"; next }
/AO46_AGX_SHADER_EXECUTION complete result=0x6a46$/ { if (phase != "complete") failure("result arrived before completion"); result = 1; next }

/MODERN_ALLOCATE_MEM handle=/ {
    if (phase != "") {
        allocations[phase]++
        classes[phase SUBSEP trace_field($0, "storage=")] = 1
    }
    next
}
/MODERN_ALLOCATE_REQUEST bytes=/ {
    if (phase != "") requests[phase]++
    next
}
/MODERN_SUBMIT queue=/ {
    if (!dispatch_started) failure("submission arrived before dispatch")
    submissions++
    next
}
/MODERN_COMPLETION queue=/ { completions++; next }
END {
    if (!result || phase != "complete") failure("control workload did not verify its output")
    if (submissions != 1) failure("control workload did not produce exactly one submission")
    if (completions < 1) failure("control workload did not produce a completion")

    for (key in classes) {
        split(key, parts, SUBSEP)
        class_count[parts[1]]++
    }

    printf "AGX_SHADER_EXECUTION_TRACE verified compile_allocations=%d pipeline_allocations=%d queue_allocations=%d buffer_allocations=%d command_allocations=%d encoder_allocations=%d pipeline_bind_allocations=%d resource_bind_allocations=%d dispatch_allocations=%d commit_allocations=%d completion_allocations=%d submissions=%d completions=%d usc_window=unproven executable=unproven\n", \
        allocations["compile"] + 0, allocations["pipeline"] + 0, allocations["queue"] + 0, \
        allocations["buffer"] + 0, allocations["command"] + 0, allocations["encoder"] + 0, \
        allocations["pipeline-bind"] + 0, allocations["resource-bind"] + 0, \
        allocations["dispatch"] + 0, allocations["commit"] + 0, allocations["completion"] + 0, \
        submissions, completions
}
' "$trace_log"
