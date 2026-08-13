#!/bin/sh
set -eu

# Pointer-target capture is a byte-oriented diagnostic record. The analysis
# only classifies changes by originating sidecar offset; it assigns no AGX ABI
# meaning to the pointer target or any of its words.
LC_ALL=C
export LC_ALL

if [ "$#" -lt 1 ]; then
    echo "usage: $0 TRACE_LOG [TRACE_LOG ...]" >&2
    exit 2
fi

for trace_log in "$@"; do
    if [ ! -f "$trace_log" ]; then
        echo "missing trace log: $trace_log" >&2
        exit 2
    fi
done

awk '
function die(message) {
    print "AGX_SIDECAR_POINTER_LAYOUT error=" message > "/dev/stderr"
    exit 1
}

/^MODERN_SUBMIT_AUX_POINTER_HEX offset=/ {
    offset = $0
    sub(/^.*offset=/, "", offset)
    sub(/ .*/, "", offset)
    bytes = $0
    sub(/^.*bytes=/, "", bytes)
    sub(/ .*/, "", bytes)
    hex = $0
    sub(/^.* data=/, "", hex)
    sub(/\r$/, "", hex)

    if (bytes != 512)
        die("unexpected-pointer-target-bytes-" bytes)
    if (length(hex) != bytes * 2)
        die("truncated-hex-record")
    if (hex !~ /^[0-9A-Fa-f]+$/)
        die("non-hex-record")

    captures++
    target_captures[offset]++
    for (word = 0; word < bytes / 8; ++word) {
        key = offset SUBSEP word
        value = substr(hex, word * 16 + 1, 16)
        if (!(key in first))
            first[key] = value
        else if (first[key] != value)
            changed[key] = 1
        if (value != "0000000000000000")
            nonzero[key] = 1
    }
}

/^MODERN_SUBMIT_AUX_POINTER_CLASS offset=/ {
    offset = $0
    sub(/^.*offset=/, "", offset)
    sub(/ .*/, "", offset)
    classification = $0
    sub(/^.*class=/, "", classification)
    sub(/\r$/, "", classification)

    if (!(offset in target_class))
        target_class[offset] = classification
    else if (target_class[offset] != classification)
        target_class[offset] = "mixed"
}

END {
    if (captures == 0)
        die("no-pointer-target-records")

    print "AGX_SIDECAR_POINTER_LAYOUT captures=" captures " bytes=512 words=64"
    for (offset in target_captures) {
        stable = 0
        variable = 0
        for (word = 0; word < 64; ++word) {
            key = offset SUBSEP word
            if (!(key in nonzero))
                continue
            if (key in changed)
                variable++
            else
                stable++
        }
        print "AGX_SIDECAR_POINTER_LAYOUT target_offset=" offset \
              " captures=" target_captures[offset] \
              " classification=" \
                 ((offset in target_class) ? target_class[offset] : "unclassified") \
              " stable_nonzero=" stable " variable_nonzero=" variable
    }
}
' "$@"
