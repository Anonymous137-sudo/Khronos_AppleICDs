#!/bin/sh
set -eu

# Compare two repeat captures of a baseline workload against two repeat
# captures of one variant. Only words stable within each workload and different
# between workloads are reported. This filters per-process pointer and
# allocator churn without assigning a private sidecar ABI meaning to a word.
LC_ALL=C
export LC_ALL

if [ "$#" -ne 4 ]; then
    echo "usage: $0 BASELINE_A BASELINE_B VARIANT_A VARIANT_B" >&2
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
    print "AGX_SIDECAR_CONTROL_DELTA error=" message > "/dev/stderr"
    exit 1
}

/^MODERN_SUBMIT_AUX_EXTENDED_HEX bytes=/ {
    bytes = $0
    sub(/^.*bytes=/, "", bytes)
    sub(/ .*/, "", bytes)
    hex = $0
    sub(/^.* data=/, "", hex)
    sub(/\r$/, "", hex)

    if (bytes != 4096 || length(hex) != bytes * 2 ||
        hex !~ /^[0-9A-Fa-f]+$/)
        die("invalid-sidecar-record")
    if (++captures > 4)
        die("expected-one-sidecar-record-per-trace")

    for (word = 0; word < 512; ++word)
        value[captures SUBSEP word] = substr(hex, word * 16 + 1, 16)
}

END {
    if (captures != 4)
        die("expected-four-sidecar-records-got-" captures)

    candidates = 0
    print "AGX_SIDECAR_CONTROL_DELTA baseline_captures=2 variant_captures=2"
    for (word = 0; word < 512; ++word) {
        baseline_a = value[1 SUBSEP word]
        baseline_b = value[2 SUBSEP word]
        variant_a = value[3 SUBSEP word]
        variant_b = value[4 SUBSEP word]

        if (baseline_a != baseline_b || variant_a != variant_b ||
            baseline_a == variant_a)
            continue

        ++candidates
        printf "AGX_SIDECAR_CONTROL_DELTA candidate offset=0x%03x baseline=0x%s variant=0x%s\n", \
            word * 8, baseline_a, variant_a
    }
    print "AGX_SIDECAR_CONTROL_DELTA candidates=" candidates
}
' "$@"
