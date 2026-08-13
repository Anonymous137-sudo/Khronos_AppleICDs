#!/bin/sh
set -eu

# Validate the observed Apple-owned handoff for already-created MTLBuffers:
# IOGPUResourceListAddResource receives IOGPUMetalBuffer + 0x40, rather than
# the generic resourceRef + 0x40. No AO46 code writes or submits this record.

if [ "$#" -ne 1 ] || [ ! -r "$1" ]; then
    echo "usage: $0 TRACE_LOG" >&2
    exit 2
fi

# LLDB includes non-ASCII bytes in unrelated hexdump annotations. Retain the
# ASCII trace protocol before POSIX awk parses key/value records.
LC_ALL=C tr -cd '\11\12\15\40-\176' < "$1" | LC_ALL=C awk '
function token(line, key, value) {
    value = substr(line, index(line, key) + length(key))
    sub(/[[:space:]]+.*/, "", value)
    return value
}

function pointer(value, hex) {
    hex = value
    sub(/^0x/, "", hex)
    if (hex == "" || hex ~ /[^0-9a-f]/)
        return ""
    while (length(hex) < 16)
        hex = "0" hex
    return "0x" hex
}

/^AO46_AGX_BUFFER_BINDING public-resource / {
    name = token($0, "name=")
    binding[name] = pointer(token($0, "buffer_plus_0x40="))
    ref[name] = pointer(token($0, "resource_ref="))
    generic_binding[name] = pointer(token($0, "resource_ref_plus_0x40="))
    if ((name != "source" && name != "destination") || !binding[name] ||
        !ref[name] || !generic_binding[name] ||
        binding[name] == generic_binding[name]) {
        bad = 1
    }
    resources++
}

/^AO46_AGX_PRIVATE_WINSYS_RESOURCE_LIST_BINDING / {
    candidate = pointer(token($0, "binding="))
    if (candidate == binding["source"])
        source_bindings++
    if (candidate == binding["destination"])
        destination_bindings++
    resource_list_bindings++
}

/^AO46_AGX_PRIVATE_WINSYS_CALL name=begin-segment / { begin_segments++ }
/^AO46_AGX_PRIVATE_WINSYS_CALL name=end-segment / { end_segments++ }
/^AO46_AGX_PRIVATE_WINSYS_CALL name=trap4 / { submissions++ }
/^AO46_AGX_BUFFER_BINDING complete/ { complete = 1 }

END {
    if (bad || resources != 2 || !binding["source"] || !binding["destination"] ||
        source_bindings != 1 || destination_bindings != 1 ||
        resource_list_bindings < 2 || begin_segments != 1 || end_segments != 1 ||
        submissions != 1 || !complete) {
        print "public buffer resource-list binding contract failed" > "/dev/stderr"
        exit 1
    }

    printf("AO46_AGX_PUBLIC_BUFFER_BINDING source=%d destination=%d list_entries=%d status=verified\n",
           source_bindings, destination_bindings, resource_list_bindings)
}
'
