#!/bin/sh
set -eu

if [ "$#" -ne 1 ]; then
    echo "usage: $0 COMPUTE_TRACE_LOG" >&2
    exit 2
fi

trace_log=$1
if [ ! -f "$trace_log" ]; then
    echo "missing compute correspondence trace: $trace_log" >&2
    exit 2
fi

# This deliberately proves only public-buffer to Apple-resource VA ownership.
# It does not infer command-storage fields, sidecar offsets, or any submission
# ABI from pointer proximity.
LC_ALL=C awk '
function value(line, key, result) {
    result = line
    sub(".*" key, "", result)
    sub(" .*$", "", result)
    return result
}
function normalized_hex(value) {
    sub(/^0x0*/, "0x", value)
    return value == "0x" ? "0x0" : value
}
function fail(message) {
    print "AGX compute correspondence failed: " message > "/dev/stderr"
    exit 1
}
/^AO46_AGX_COMPUTE_RECORD public-resource / {
    name = value($0, "name=")
    gpu_va = normalized_hex(value($0, "gpu_va="))
    bytes = value($0, "bytes=")
    if ((name != "input" && name != "output") || gpu_va == "" ||
        gpu_va == "0x0" || bytes + 0 != 4096 || public_va[name] != "")
        fail("invalid-public-buffer-marker")
    public_va[name] = gpu_va
    public_count++
}
/^AO46_AGX_COMPUTE_RECORD dispatch / {
    elements = value($0, "elements=")
    threads = value($0, "threads_per_group=")
    if (elements + 0 != 1024 || threads + 0 != 32)
        fail("invalid-public-dispatch-marker")
    dispatches++
}
/^AO46_AGX_PRIVATE_WINSYS_RETURN / {
    name = value($0, "name=")
    gpu_va = normalized_hex(value($0, "x0="))
    if (name == "resource-gpu-address" && gpu_va != "0x0000000000000000")
        apple_va[gpu_va] = 1
}
END {
    if (public_count != 2 || dispatches != 1 ||
        public_va["input"] == "" || public_va["output"] == "")
        fail("incomplete-public-compute-workload")
    if (!(public_va["input"] in apple_va) ||
        !(public_va["output"] in apple_va))
        fail("public-buffer-va-not-observed-in-apple-resource-set")

    print "AO46_AGX_COMPUTE_CORRESPONDENCE verified" \
          " public_buffers=2 public_buffer_va_ownership=1" \
          " dispatch_elements=1024 threads_per_group=32" \
          " cdm_stream_base=unknown sampler_heap=unknown helper=unknown" \
          " submission_import=unavailable"
}
' "$trace_log"
