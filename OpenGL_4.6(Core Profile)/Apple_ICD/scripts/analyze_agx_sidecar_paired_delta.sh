#!/bin/sh
set -eu

# Compare two repeat captures of three controls in one process. Each supplied
# trace carries its own repeated controls. A reported offset must be stable
# within every control pair and recur across every supplied trace, filtering
# first-use pool growth, completion tokens, allocator churn, and a one-off
# in-process coincidence. A result is a candidate, never a private ABI field.
if [ "$#" -lt 1 ]; then
    echo "usage: $0 PAIRED_TRACE_LOG [PAIRED_TRACE_LOG ...]" >&2
    exit 2
fi

trace_log=$1
if [ ! -f "$trace_log" ]; then
    echo "missing paired AGX shader-contract trace: $trace_log" >&2
    exit 2
fi

LC_ALL=C awk '
function die(message) {
    print "AGX_SIDECAR_PAIRED_DELTA error=" message > "/dev/stderr"
    failed = 1
    exit 1
}
function capture_sidecar(run, label, bytes, hex, word) {
    if (seen[run SUBSEP label]++)
        die("duplicate-sidecar-for-" label "-in-run-" run)
    if (bytes != 4096 || length(hex) != bytes * 2 || hex !~ /^[0-9A-Fa-f]+$/)
        die("invalid-sidecar-for-" label)

    for (word = 0; word < 512; ++word)
        value[run SUBSEP label SUBSEP word] = substr(hex, word * 16 + 1, 16)
}
{ sub(/\r$/, "") }
FNR == 1 { ++run }
/AO46_AGX_SHADER_EXECUTION paired-phase=/ {
    phase = $0
    sub(/^.*paired-phase=/, "", phase)
    next
}
/^MODERN_SUBMIT_AUX_EXTENDED_HEX bytes=/ {
    if (phase == "")
        die("sidecar-without-paired-phase")
    if (phase == "warmup")
        next
    bytes = $0
    sub(/^.*bytes=/, "", bytes)
    sub(/ .*/, "", bytes)
    hex = $0
    sub(/^.* data=/, "", hex)
    capture_sidecar(run, phase, bytes, hex)
    next
}
/^MODERN_RESOURCE_REFERENCE / {
    if (phase != "")
        resource_refs[run SUBSEP phase]++
    next
}
END {
    if (failed)
        exit 1
    for (current_run = 1; current_run <= run; ++current_run) {
        if (!seen[current_run SUBSEP "baseline-a"] ||
            !seen[current_run SUBSEP "baseline-b"] ||
            !seen[current_run SUBSEP "two-buffers-a"] ||
            !seen[current_run SUBSEP "two-buffers-b"] ||
            !seen[current_run SUBSEP "threadgroup-a"] ||
            !seen[current_run SUBSEP "threadgroup-b"])
            die("expected-two-sidecars-per-control-in-run-" current_run)

        for (word = 0; word < 512; ++word) {
            baseline_a = value[current_run SUBSEP "baseline-a" SUBSEP word]
            baseline_b = value[current_run SUBSEP "baseline-b" SUBSEP word]
            resource_a = value[current_run SUBSEP "two-buffers-a" SUBSEP word]
            resource_b = value[current_run SUBSEP "two-buffers-b" SUBSEP word]
            shader_a = value[current_run SUBSEP "threadgroup-a" SUBSEP word]
            shader_b = value[current_run SUBSEP "threadgroup-b" SUBSEP word]

            if (baseline_a != baseline_b) {
                ++unstable_baseline
                continue
            }

            if (resource_a != resource_b)
                ++unstable_resource
            else if (baseline_a != resource_a) {
                resource_hits[word]++
                resource_baseline[word] = baseline_a
                resource_variant[word] = resource_a
            }

            if (shader_a != shader_b)
                ++unstable_shader
            else if (baseline_a != shader_a) {
                shader_hits[word]++
                shader_baseline[word] = baseline_a
                shader_variant[word] = shader_a
            }
        }
    }

    print "AGX_SIDECAR_PAIRED_DELTA controls=baseline,two-buffers,threadgroup repeats=2 runs=" run
    for (word = 0; word < 512; ++word) {
        if (resource_hits[word] == run) {
            ++resource_candidates
            printf "AGX_SIDECAR_PAIRED_DELTA candidate=resource offset=0x%03x baseline=0x%s variant=0x%s runs=%d\n", \
                word * 8, resource_baseline[word], resource_variant[word], run
        }
        if (shader_hits[word] == run) {
            ++shader_candidates
            printf "AGX_SIDECAR_PAIRED_DELTA candidate=shader offset=0x%03x baseline=0x%s variant=0x%s runs=%d\n", \
                word * 8, shader_baseline[word], shader_variant[word], run
        }
    }
    for (current_run = 1; current_run <= run; ++current_run) {
        baseline_refs += resource_refs[current_run SUBSEP "baseline-a"] + resource_refs[current_run SUBSEP "baseline-b"]
        resource_refs_total += resource_refs[current_run SUBSEP "two-buffers-a"] + resource_refs[current_run SUBSEP "two-buffers-b"]
        shader_refs += resource_refs[current_run SUBSEP "threadgroup-a"] + resource_refs[current_run SUBSEP "threadgroup-b"]
    }
    printf "AGX_SIDECAR_PAIRED_DELTA resource_candidates=%d shader_candidates=%d unstable_baseline=%d unstable_resource=%d unstable_shader=%d resource_refs_baseline=%d resource_refs_two_buffers=%d resource_refs_threadgroup=%d\n", \
        resource_candidates, shader_candidates, unstable_baseline, unstable_resource, unstable_shader, \
        baseline_refs, resource_refs_total, shader_refs
}
' "$@"
