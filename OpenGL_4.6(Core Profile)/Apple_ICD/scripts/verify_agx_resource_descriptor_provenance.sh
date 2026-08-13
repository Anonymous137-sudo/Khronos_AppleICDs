#!/bin/sh
set -eu

# Verify a bounded descriptor-provenance fact from the public compute control:
# Apple's 0x68-byte IOGPUResourceCreate inputs do not embed either public
# MTLBuffer identity or its public GPU VA. This keeps later import work from
# treating a Mesa BO's VA as a fabricated Apple resource descriptor.

if [ "$#" -ne 1 ] || [ ! -r "$1" ]; then
    echo "usage: $0 TRACE_LOG" >&2
    exit 2
fi

LC_ALL=C awk '
function token(line, key, value) {
    value = substr(line, index(line, key) + length(key))
    sub(/[[:space:]]+.*/, "", value)
    return value
}

function little_endian_64(value, hex, result, position) {
    hex = value
    sub(/^0x/, "", hex)
    while (length(hex) < 16)
        hex = "0" hex
    result = ""
    for (position = 15; position >= 1; position -= 2)
        result = result substr(hex, position, 2)
    return result
}

/^AO46_AGX_COMPUTE_RECORD public-resource / {
    name = token($0, "name=")
    object[name] = little_endian_64(token($0, "object="))
    gpu_va[name] = little_endian_64(token($0, "gpu_va="))
    resource_count++
}

/^AO46_AGX_PRIVATE_WINSYS_RESOURCE_CREATE_RECORD / {
    records[++record_count] = $0
}

END {
    if (resource_count != 2 || !object["input"] || !object["output"] ||
        !gpu_va["input"] || !gpu_va["output"] || record_count == 0) {
        print "incomplete public-resource provenance trace" > "/dev/stderr"
        exit 1
    }

    for (name in object) {
        for (position = 1; position <= record_count; ++position) {
            if (index(records[position], object[name]) != 0)
                direct_object_refs++
            if (index(records[position], gpu_va[name]) != 0)
                direct_gpu_va_refs++
        }
    }

    printf("AO46_AGX_RESOURCE_DESCRIPTOR_PROVENANCE resources=%d records=%d direct_object_refs=%d direct_gpu_va_refs=%d status=%s\n",
           resource_count, record_count, direct_object_refs, direct_gpu_va_refs,
           (direct_object_refs == 0 && direct_gpu_va_refs == 0) ? "indirect" : "changed")

    exit (direct_object_refs == 0 && direct_gpu_va_refs == 0) ? 0 : 1
}
' "$1"
