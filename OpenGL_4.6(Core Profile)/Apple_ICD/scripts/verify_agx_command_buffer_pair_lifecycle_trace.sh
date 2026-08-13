#!/bin/sh
set -eu

if [ "$#" -ne 1 ]; then
    echo "usage: $0 TRACE_LOG" >&2
    exit 2
fi

trace_log=$1

if [ ! -f "$trace_log" ]; then
    echo "missing AGX command-buffer pair lifecycle trace: $trace_log" >&2
    exit 2
fi

# This is an observation-only control. It validates the pre-submit selector
# ordering for two uncommitted Metal command buffers and rejects any trace that
# crosses into Trap4 submission or completion handling.
LC_ALL=C awk '
function failure(message) {
    print "AGX command-buffer pair lifecycle verification failed: " message > "/dev/stderr"
    exit 1
}

function expect_stage(next_stage, message) {
    if (stage != next_stage - 1)
        failure(message)
    stage = next_stage
}

/AO46_AGX_COMMAND_BUFFER_PAIR_TRACE create-device$/ {
    expect_stage(1, "device marker was out of order")
    next
}
/AO46_AGX_COMMAND_BUFFER_PAIR_TRACE create-queue$/ {
    expect_stage(2, "queue marker was out of order")
    next
}
/AO46_AGX_COMMAND_BUFFER_PAIR_TRACE create-first$/ {
    expect_stage(3, "first command-buffer marker was out of order")
    buffer = 1
    next
}
/AO46_AGX_COMMAND_BUFFER_PAIR_TRACE create-second$/ {
    expect_stage(4, "second command-buffer marker was out of order")
    buffer = 2
    next
}
/AO46_AGX_COMMAND_BUFFER_PAIR_TRACE release-pair$/ {
    expect_stage(5, "pair release marker was out of order")
    buffer = 0
    next
}
/AO46_AGX_COMMAND_BUFFER_PAIR_TRACE release-queue$/ {
    expect_stage(6, "queue release marker was out of order")
    next
}
/AO46_AGX_COMMAND_BUFFER_PAIR_TRACE release-device$/ {
    expect_stage(7, "device release marker was out of order")
    next
}
/AO46_AGX_COMMAND_BUFFER_PAIR_TRACE complete$/ {
    expect_stage(8, "completion marker was out of order")
    next
}

/MODERN_NOTIFICATION_QUEUE data_queue=.* id=[0-9]+ config=/ {
    notification_queues++
    next
}
/AGX_CALL selector=6 scalar_in=0 struct_in=0 scalar_out_capacity=0 struct_out_capacity=16$/ {
    if (buffer != 1)
        failure("selector 6 was not limited to the first command buffer")
    selector6++
    next
}
/AGX_CALL selector=14 scalar_in=2 struct_in=0 scalar_out_capacity=0 struct_out_capacity=16$/ {
    if (buffer != 1 && buffer != 2)
        failure("selector 14 occurred outside command-buffer creation")
    selector14++
    awaiting_pair = buffer
    next
}
/: call E \(out .*\) 4000 [01]$/ {
    if (!awaiting_pair)
        failure("selector 14 scalar pair was not preceded by its call shape")

    input = $0
    sub(".* 4000 ", "", input)
    pair_inputs[++pair_count] = input
    pair_buffers[pair_count] = awaiting_pair
    awaiting_pair = 0
    next
}
/MODERN_QUEUE_LIFECYCLE selector=8 id=[0-9]+$/ {
    queue_close++
    next
}
/MODERN_QUEUE_LIFECYCLE selector=17 id=[0-9]+$/ {
    queue_destroy++
    next
}
/IOConnectTrap4|MODERN_SUBMIT |MODERN_COMPLETION / {
    failure("uncommitted control crossed into submission or completion")
}
END {
    if (stage != 8)
        failure("lifecycle markers did not complete")
    if (notification_queues != 1)
        failure("control did not retain one notification queue")
    if (selector6 != 1 || selector14 != 4 || awaiting_pair)
        failure("selector call count or shape changed")
    if (pair_count != 4 || pair_inputs[1] != "0" || pair_inputs[2] != "1" ||
        pair_inputs[3] != "0" || pair_inputs[4] != "1" ||
        pair_buffers[1] != 1 || pair_buffers[2] != 1 ||
        pair_buffers[3] != 2 || pair_buffers[4] != 2)
        failure("per-command-buffer selector 14 pairs changed")
    if (queue_close != 1 || queue_destroy != 1)
        failure("notification queue teardown changed")

    print "AGX_COMMAND_BUFFER_PAIR_LIFECYCLE_TRACE verified selector6=first-only selector14=0,1-per-buffer no-submit"
}
' "$trace_log"
