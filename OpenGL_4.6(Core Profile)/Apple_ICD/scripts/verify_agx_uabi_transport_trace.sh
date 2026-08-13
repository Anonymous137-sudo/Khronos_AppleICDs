#!/bin/sh
set -eu

if [ "$#" -ne 1 ]; then
    echo "usage: $0 TRACE_LOG" >&2
    exit 2
fi

trace_log=$1
require_extended=${AGX_TRACE_REQUIRE_EXTENDED:-0}
require_payload=${AGX_TRACE_REQUIRE_TRAP_PAYLOADS:-0}
require_sidecar_hex=${AGX_TRACE_REQUIRE_SIDECAR_HEX:-0}
require_pointer_hex=${AGX_TRACE_REQUIRE_POINTER_HEX:-0}

if [ ! -f "$trace_log" ]; then
    echo "missing AGX UABI transport trace: $trace_log" >&2
    exit 2
fi

case "$require_extended:$require_payload:$require_sidecar_hex:$require_pointer_hex" in
    0:0:0:0|0:0:0:1|0:0:1:0|0:0:1:1|0:1:0:0|0:1:0:1|0:1:1:0|0:1:1:1|1:0:0:0|1:0:0:1|1:0:1:0|1:0:1:1|1:1:0:0|1:1:0:1|1:1:1:0|1:1:1:1)
        ;;
    *)
        echo "AGX trace requirement variables must be 0 or 1" >&2
        exit 2
        ;;
esac

# Validate only facts that hold at the public-to-AGX transport boundary. The
# 4 KiB carrier and its pointer graph remain opaque evidence, not a payload
# schema or a permission to replay IOConnectTrap4 from the runtime. A bounded
# pointer target can be host string data or opaque host data; neither class is
# an AGX resource table or an importable submission interface.
LC_ALL=C awk -v require_extended="$require_extended" -v require_payload="$require_payload" -v require_sidecar_hex="$require_sidecar_hex" -v require_pointer_hex="$require_pointer_hex" '
function failure(message) {
    print "AGX UABI transport verification failed: " message > "/dev/stderr"
    exit 1
}

function field(line, name, value) {
    value = line
    sub(".*" name, "", value)
    sub(" .*$", "", value)
    sub(/\r$/, "", value)
    return value
}

/AGX_TRAP4_SUBMIT payload_size=40 / {
    trap_count++
    next
}
/MODERN_TRAP4_TRANSPORT queue=/ {
    if (transport_count >= submission_count + 1)
        failure("Trap4 transport was not immediately followed by one submission")

    transport_count++
    transport_queue[transport_count] = field($0, "queue=")
    transport_index[transport_count] = field($0, "index=")
    transport_size[transport_count] = field($0, "descriptor_bytes=")
    transport_offset[transport_count] = field($0, "carrier_offset=")
    transport_prefix[transport_count] = field($0, "carrier_prefix=")
    transport_valid[transport_count] = field($0, "valid=")
    next
}
/MODERN_SUBMIT queue=/ {
    submission_count++
    queue[submission_count] = field($0, "queue=")
    header[submission_count] = field($0, "header=")
    token0[submission_count] = field($0, "completion0=")
    token1[submission_count] = field($0, "completion1=")

    if (transport_count != submission_count ||
        transport_queue[submission_count] != queue[submission_count] ||
        transport_index[submission_count] != "0" ||
        transport_size[submission_count] != "64" ||
        transport_offset[submission_count] != "132" ||
        transport_prefix[submission_count] != "256" ||
        transport_valid[submission_count] != "1")
        failure("Trap4 transport shape changed")

    if (queue[submission_count] == "0" || header[submission_count] != "2/1" ||
        token0[submission_count] == "0" || token1[submission_count] == "0" ||
        token0[submission_count] == token1[submission_count])
        failure("submit descriptor contract changed")
    next
}
/MODERN_SUBMIT_AUX pointer=/ {
    if (!submission_count || aux_count >= submission_count)
        failure("auxiliary carrier was not associated with one submission")
    aux_count++
    aux_offset[aux_count] = field($0, "descriptor_offset=")
    aux_prefix[aux_count] = field($0, "readable_prefix=")
    if (aux_offset[aux_count] != "132" || aux_prefix[aux_count] != "256")
        failure("auxiliary carrier contract changed")
    next
}
/MODERN_SUBMIT_CARRIER queue=/ {
    if (!submission_count || carrier_count >= submission_count)
        failure("carrier observation was not associated with one submission")
    carrier_count++
    carrier_queue[carrier_count] = field($0, "queue=")
    carrier_offset[carrier_count] = field($0, "offset=")
    carrier_prefix[carrier_count] = field($0, "prefix=")
    if (carrier_queue[carrier_count] != queue[carrier_count] ||
        carrier_offset[carrier_count] != "132" || carrier_prefix[carrier_count] != "256")
        failure("carrier snapshot contract changed")
    next
}
/MODERN_SUBMIT_AUX_EXTENDED bytes=/ {
    if (!submission_count || extended_count >= submission_count)
        failure("extended carrier was not associated with one submission")
    extended_count++
    extended_bytes[extended_count] = field($0, "bytes=")
    if (extended_bytes[extended_count] != "4096")
        failure("extended carrier no longer has a 4 KiB readable prefix")
    next
}
/^MODERN_SUBMIT_AUX_EXTENDED_HEX bytes=/ {
    if (!submission_count || extended_hex_count >= submission_count)
        failure("extended sidecar hex was not associated with one submission")

    line = $0
    hex_bytes = field(line, "bytes=")
    hex = line
    sub(/^.* data=/, "", hex)
    if (hex_bytes != "4096" || length(hex) != 8192 || hex ~ /[^0-9A-Fa-f]/)
        failure("extended sidecar hex record changed or was truncated")

    extended_hex_count++
    next
}
/MODERN_SUBMIT_CARRIER_EXTENDED queue=/ {
    if (!submission_count || extended_carrier_count >= submission_count)
        failure("extended carrier snapshot was not associated with one submission")
    extended_carrier_count++
    extended_queue[extended_carrier_count] = field($0, "queue=")
    extended_prefix[extended_carrier_count] = field($0, "prefix=")
    extended_slot[extended_carrier_count] = field($0, "opaque_slot=")
    if (extended_queue[extended_carrier_count] != queue[extended_carrier_count] ||
        extended_prefix[extended_carrier_count] != "4096" ||
        extended_slot[extended_carrier_count] != "0x1ff800000")
        failure("extended carrier invariant changed")
    next
}
/^MODERN_SUBMIT_AUX_POINTER offset=/ {
    pointer_count++
    pointer_offset[pointer_count] = field($0, "offset=")
    pointer_value[pointer_count] = field($0, "pointer=")
    pointer_readable[pointer_count] = field($0, "readable=")
    if (pointer_readable[pointer_count] != "512")
        failure("sidecar pointer target was no longer bounded to 512 bytes")
    next
}
/^MODERN_SUBMIT_AUX_POINTER_HEX offset=/ {
    if (pointer_hex_count >= pointer_count)
        failure("pointer-target hex was not ordered after a pointer observation")

    pointer_hex_count++
    hex_offset = field($0, "offset=")
    hex_pointer = field($0, "pointer=")
    hex_bytes = field($0, "bytes=")
    hex = $0
    sub(/^.* data=/, "", hex)
    if (hex_offset != pointer_offset[pointer_hex_count] ||
        hex_pointer != pointer_value[pointer_hex_count] ||
        hex_bytes != "512" || length(hex) != 1024 ||
        hex ~ /[^0-9A-Fa-f]/)
        failure("pointer-target hex record changed or was truncated")
    next
}
/^MODERN_SUBMIT_AUX_POINTER_CLASS offset=/ {
    if (pointer_class_count >= pointer_hex_count)
        failure("pointer classification was not ordered after target evidence")

    pointer_class_count++
    class_offset = field($0, "offset=")
    pointer_class[pointer_class_count] = field($0, "class=")
    if (class_offset != pointer_offset[pointer_class_count])
        failure("pointer classification did not match its origin")
    if (pointer_class[pointer_class_count] == "ascii-cstring-table")
        pointer_ascii_count++
    else if (pointer_class[pointer_class_count] == "unclassified")
        pointer_opaque_count++
    else
        failure("sidecar pointer target reported an unknown classification")
    next
}
/MODERN_COMPLETION queue=/ {
    completion_queue = field($0, "queue=")
    completion_token = field($0, "token=")
    matched = 0

    for (i = submission_count; i >= 1; --i) {
        if (queue[i] != completion_queue)
            continue
        if (completion_token == token0[i] && !completion0[i]) {
            completion0[i] = 1
            matched = 1
            break
        }
        if (completion_token == token1[i] && !completion1[i]) {
            completion1[i] = 1
            matched = 1
            break
        }
    }

    if (!matched)
        failure("completion was not matched to one live descriptor token")
    completion_count++
    next
}
END {
    if (!submission_count)
        failure("trace contained no AGX submission")
    if (require_payload == "1" && trap_count != submission_count)
        failure("Trap4 payload capture count did not match submissions")
    if (aux_count != submission_count || carrier_count != submission_count)
        failure("one or more submissions lacked a validated auxiliary carrier")
    if (require_extended == "1" &&
        (extended_count != submission_count ||
         extended_carrier_count != submission_count))
        failure("one or more submissions lacked extended carrier evidence")
    if (require_sidecar_hex == "1" && extended_hex_count != submission_count)
        failure("one or more submissions lacked a complete extended sidecar hex record")
    if (require_pointer_hex == "1" &&
        (pointer_count < submission_count || pointer_hex_count != pointer_count ||
         pointer_class_count != pointer_count))
        failure("one or more sidecar pointers lacked complete bounded target evidence")
    if (completion_count != submission_count * 2)
        failure("submissions did not produce exactly two completion records each")

    for (i = 1; i <= submission_count; ++i) {
        if (!completion0[i] || !completion1[i])
            failure("submission did not retire both descriptor tokens")
    }

    extended_label = require_extended == "1" ? "yes" : "optional"
    sidecar_hex_label = require_sidecar_hex == "1" ? "yes" : "optional"
    pointer_hex_label = require_pointer_hex == "1" ? "yes" : "optional"
    printf "AGX_UABI_TRANSPORT_TRACE verified submissions=%d completions=%d extended=%s sidecar_hex=%s pointer_hex=%s pointer_ascii=%d pointer_opaque=%d\n", \
        submission_count, completion_count, extended_label, sidecar_hex_label, pointer_hex_label, pointer_ascii_count, pointer_opaque_count
}
' "$trace_log"
