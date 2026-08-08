#!/bin/sh
set -eu

if [ "$#" -ne 1 ]; then
    echo "usage: $0 TRACE_LOG" >&2
    exit 2
fi

trace_log=$1

if [ ! -f "$trace_log" ]; then
    echo "missing AGX IOSurface drawable trace: $trace_log" >&2
    exit 2
fi

# IOSurface allocation internals are still platform-owned. This verifies the
# stable boundary around an IOSurface-backed render submission only.
LC_ALL=C awk '
function failure(message) {
    print "AGX IOSurface drawable verification failed: " message > "/dev/stderr"
    exit 1
}

function trace_field(line, field_name, value) {
    value = line
    sub(".*" field_name, "", value)
    sub(" .*$", "", value)
    return value
}

/AO46_AGX_IOSURFACE drawable id=[0-9]+ size=64x64 row-bytes=256$/ {
    if (drawable_marker++)
        failure("IOSurface drawable was created more than once")
    next
}
/AO46_AGX_IOSURFACE submit clear-render-pass$/ {
    if (submit_marker++)
        failure("IOSurface render was submitted more than once")
    submitted = 1
    next
}
/MODERN_SUBMIT queue=/ {
    if (submitted) {
        submission_count++
        submission_queue = trace_field($0, "queue=")
        submission_header = trace_field($0, "header=")
    }
    next
}
/MODERN_SUBMIT_AUX pointer=/ {
    if (submitted) {
        aux_count++
        aux_offset = trace_field($0, "descriptor_offset=")
        aux_readable = trace_field($0, "readable_prefix=")
    }
    next
}
/MODERN_COMPLETION queue=/ {
    if (submitted)
        completion_count++
    next
}
/AO46_AGX_IOSURFACE complete id=[0-9]+$/ {
    complete = 1
}
END {
    if (!drawable_marker || !submit_marker || !complete)
        failure("IOSurface render did not complete its pixel validation")

    if (submission_count != 1 || submission_queue == "" ||
        submission_header != "2/1" || aux_count != 1 ||
        aux_offset != "132" || aux_readable != "256" ||
        completion_count != 2)
        failure("IOSurface submission boundary changed")

    printf "AGX_IOSURFACE_DRAWABLE_TRACE verified queue=%s completions=2 carrier=132/256\n", \
        submission_queue
}
' "$trace_log"
