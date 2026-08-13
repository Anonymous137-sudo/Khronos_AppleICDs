#!/bin/sh
set -eu

# Correlate opaque identities from a read-only public compute trace. This never
# retains compiler bytes or treats Apple object state as an AO46 ABI.
if [ "$#" -ne 1 ]; then
    echo "usage: $0 TRACE_LOG" >&2
    exit 2
fi

trace_log=$1
if [ ! -f "$trace_log" ]; then
    echo "missing trace log: $trace_log" >&2
    exit 2
fi

LC_ALL=C awk '
function field_value(key, field_index, pair) {
    for (field_index = 1; field_index <= NF; field_index++) {
        split($field_index, pair, "=")
        if (pair[1] == key)
            return pair[2]
    }
    return ""
}
function present(value) {
    return value != "" && value != "0x0000000000000000"
}

/AO46_AGX_SHADER_VARIANT_CALL kind=compute-program-constructor / {
    variant = field_value("variant")
    reply = field_value("reply")
    if (present(variant) && present(reply)) {
        variant_reply[variant] = reply
        constructors++
    }
    next
}

/AO46_AGX_SHADER_EXEC_ALLOCATION_RETURN kind=heap-true-allocate / {
    if (field_value("compute_variant_owner") != "1")
        next

    variant = field_value("variant")
    # Later internal allocations can share the constructor caller range without
    # carrying the first-residency variant association. They are not evidence
    # for, or against, the compiler-result ownership edge.
    if (!present(variant))
        next

    reply = field_value("compiler_reply")
    resource = field_value("apple_resource")
    if (!present(variant) || !present(reply) || !present(resource) ||
        variant_reply[variant] != reply) {
        invalid_allocation = 1
        next
    }

    reply_bound_allocations++
    if (field_value("selected_base") != "0x0000000000000000")
        low_va_reply_bound_allocations++
    next
}

/AO46_AGX_SHADER_CODE_LINK_INFO kind=initialize / {
    link_info = field_value("link_info")
    reply = field_value("compiler_reply")
    if (present(link_info) && present(reply))
        link_reply[link_info] = reply
    next
}

/AO46_AGX_SHADER_CODE_HEAP_RELOCATIONS / {
    link_info = field_value("link_info")
    if (present(link_info) && present(link_reply[link_info]))
        relocated_replies[link_reply[link_info]] = 1
    next
}

/AO46_AGX_SHADER_VARIANT_TEARDOWN kind=compute-program-base-destructor / {
    reply = field_value("compiler_reply")
    constructor_reply = field_value("constructor_reply")
    if (field_value("reply_matches") == "1" && present(reply) &&
        reply == constructor_reply && (reply in relocated_replies))
        coherent_teardowns++
    else
        invalid_teardown = 1
    next
}

END {
    if (constructors == 0 || reply_bound_allocations == 0 ||
        low_va_reply_bound_allocations == 0 || coherent_teardowns == 0 ||
        invalid_allocation || invalid_teardown) {
        print "AO46_AGX_COMPILER_HEAP_RESULT status=incomplete" \
            " constructors=" (constructors + 0) \
            " reply_bound_allocations=" (reply_bound_allocations + 0) \
            " low_va_reply_bound_allocations=" (low_va_reply_bound_allocations + 0) \
            " coherent_teardowns=" (coherent_teardowns + 0)
        exit 1
    }

    print "AO46_AGX_COMPILER_HEAP_RESULT status=observed" \
        " constructors=" constructors \
        " reply_bound_allocations=" reply_bound_allocations \
        " low_va_reply_bound_allocations=" low_va_reply_bound_allocations \
        " coherent_teardowns=" coherent_teardowns
}
' "$trace_log"
