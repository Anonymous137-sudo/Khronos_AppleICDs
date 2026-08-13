#!/bin/sh
set -eu

# Trace logs also contain diagnostic hexdumps whose ASCII columns may not be
# valid text in the current locale. Sidecar capture itself is byte-oriented.
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

# Consume only the optional 4 KiB capture records emitted by wrap.dylib. The
# report identifies stable and variable 64-bit word locations; it does not
# assign undocumented AGX sidecar semantics to either class.
awk '
function die(message) {
    print "AGX_SIDECAR_LAYOUT error=" message > "/dev/stderr"
    exit 1
}

/^MODERN_SUBMIT_AUX_EXTENDED_HEX bytes=/ {
    bytes = $0
    sub(/^.*bytes=/, "", bytes)
    sub(/ .*/, "", bytes)
    hex = $0
    sub(/^.* data=/, "", hex)
    sub(/\r$/, "", hex)

    if (bytes != 4096)
        die("unexpected-sidecar-bytes-" bytes)
    if (length(hex) != bytes * 2)
        die("truncated-hex-record")
    if (hex !~ /^[0-9A-Fa-f]+$/)
        die("non-hex-record")

    captures++
    for (word = 0; word < bytes / 8; ++word) {
        value = substr(hex, word * 16 + 1, 16)
        if (!(word in first))
            first[word] = value
        else if (first[word] != value)
            changed[word] = 1
        if (value != "0000000000000000")
            nonzero[word] = 1
    }
}

END {
    if (captures == 0)
        die("no-extended-sidecar-records")

    print "AGX_SIDECAR_LAYOUT captures=" captures " bytes=4096 words=512"
    for (word = 0; word < 512; ++word) {
        if (!(word in nonzero))
            continue
        offset = sprintf("0x%03x", word * 8)
        if (word in changed)
            print "AGX_SIDECAR_LAYOUT variable offset=" offset
        else
            print "AGX_SIDECAR_LAYOUT stable offset=" offset " value=0x" first[word]
    }
}
' "$@"
