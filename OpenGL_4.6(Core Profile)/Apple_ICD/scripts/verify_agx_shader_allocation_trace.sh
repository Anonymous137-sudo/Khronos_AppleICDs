#!/bin/sh
set -eu

if [ "$#" -ne 1 ]; then
    echo "usage: $0 TRACE_LOG" >&2
    exit 2
fi

trace_log=$1

if [ ! -f "$trace_log" ]; then
    echo "missing AGX shader-allocation trace: $trace_log" >&2
    exit 2
fi

# This control deliberately creates no queue, buffer, encoder, or command
# buffer. It measures only allocation classes visible while Apple compiles a
# shader and builds a pipeline; it does not assign private storage bits to
# Mesa's LOW_VA or EXEC flags.
LC_ALL=C awk '
function failure(message) {
    print "AGX shader-allocation verification failed: " message > "/dev/stderr"
    exit 1
}

function field(line, name, value) {
    value = line
    sub(".*" name, "", value)
    sub(" .*$", "", value)
    return value
}

/AO46_AGX_SHADER_ALLOCATION source-compile-begin$/ {
    if (phase != "") failure("nested source compile phase")
    phase = "compile"
    compile_started = 1
    next
}
/AO46_AGX_SHADER_ALLOCATION source-compile-ready$/ {
    if (phase != "compile") failure("source compile phase was not closed")
    phase = ""
    compile_ready = 1
    next
}
/AO46_AGX_SHADER_ALLOCATION pipeline-create-begin$/ {
    if (phase != "" || !compile_ready) failure("pipeline began before compile")
    phase = "pipeline"
    pipeline_started = 1
    next
}
/AO46_AGX_SHADER_ALLOCATION pipeline-create-ready max_threads=[1-9][0-9]*$/ {
    if (phase != "pipeline") failure("pipeline phase was not closed")
    phase = ""
    pipeline_ready = 1
    next
}
/MODERN_ALLOCATE_MEM handle=/ {
    if (phase == "") next
    storage = field($0, "storage=")
    allocations[phase]++
    classes[phase SUBSEP storage] = 1
    next
}
/MODERN_ALLOCATE_REQUEST bytes=/ {
    if (phase != "") requests[phase]++
    next
}
/MODERN_SUBMIT |MODERN_TRAP4_TRANSPORT|AO46_AGX_COMPUTE_RANGE dispatch/ {
    submitted = 1
    next
}
/AO46_AGX_SHADER_ALLOCATION complete no-submit=1$/ {
    if (phase != "") failure("completion inside an allocation phase")
    complete = 1
}
END {
    if (!compile_started || !compile_ready || !pipeline_started || !pipeline_ready || !complete)
        failure("control workload did not complete every shader phase")
    if (submitted)
        failure("shader allocation control submitted GPU work")

    for (key in classes) {
        split(key, parts, SUBSEP)
        class_count[parts[1]]++
    }

    printf "AGX_SHADER_ALLOCATION_TRACE verified compile_requests=%d compile_allocations=%d compile_classes=%d pipeline_requests=%d pipeline_allocations=%d pipeline_classes=%d low_va=unproven executable=unproven\n", \
        requests["compile"] + 0, allocations["compile"] + 0, class_count["compile"] + 0, \
        requests["pipeline"] + 0, allocations["pipeline"] + 0, class_count["pipeline"] + 0
}
' "$trace_log"
