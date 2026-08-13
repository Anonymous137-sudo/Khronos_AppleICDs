#!/bin/sh
set -eu

# Classify only the ownership and stable digest of Apple-created resource
# policies. The input is a read-only public-workload trace; opaque descriptors
# and private object state are never emitted or reused by AO46.
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
function field_value(key, field_index, field, separator) {
    for (field_index = 1; field_index <= NF; field_index++) {
        split($field_index, field, "=")
        if (field[1] == key)
            return field[2]
    }
    return ""
}

/AO46_IOGPU_OWNERSHIP_CALL kind=resource-initialize / {
    factory = ""
    digest = ""
    resource = ""

    for (field_index = 1; field_index <= NF; field_index++) {
        split($field_index, field, "=")
        if (field[1] == "agx_heap_factory")
            factory = field[2]
        else if (field[1] == "args_digest")
            digest = field[2]
        else if (field[1] == "resource")
            resource = field[2]
    }

    if (factory == "" || digest == "" || resource == "")
        next

    policy = factory SUBSEP digest
    policy_calls[policy]++
    policy_resources[policy SUBSEP resource] = 1
    total_resources[resource] = 1
}

# A ComputeProgramVariant allocation becomes executable only when Apple-owned
# relocator publishes the exact Apple-owned allocation address. Compare those
# observed identities, never the code bytes or private allocation records.
/AO46_AGX_SHADER_EXEC_ALLOCATION_RETURN kind=heap-true-allocate / {
    if (field_value("compute_variant_owner") != "1")
        next

    address = field_value("field0")
    digest = field_value("apple_policy_digest")
    resource = field_value("apple_resource")
    if (address == "" || address == "0x0000000000000000" ||
        digest == "" || digest == "unavailable" ||
        resource == "" || resource == "0x0000000000000000")
        next

    variant_allocations[address] = digest
    variant_resources[resource] = digest
    variant_allocation_count++
}

/AO46_AGX_SHADER_CODE_HEAP_RELOCATIONS / {
    address = field_value("published_code_address")
    if (address in variant_allocations) {
        relocated_allocations[address] = 1
        relocated_policy[variant_allocations[address]] = 1
        relocation_matches++
    }
}

END {
    for (policy in policy_calls) {
        split(policy, components, SUBSEP)
        resource_count = 0
        for (entry in policy_resources) {
            split(entry, resource_components, SUBSEP)
            if (resource_components[1] == components[1] &&
                resource_components[2] == components[2])
                resource_count++
        }

        if (components[1] == "1") {
            heap_resources += resource_count
            heap_policies++
            print "AO46_AGX_CODE_HEAP_POLICY " \
                "origin=apple-heap resource_count=" resource_count \
                " stable_policy_digest=" components[2]
        } else {
            ordinary_resources += resource_count
            ordinary_policies++
        }
    }

    if (heap_resources == 0) {
        print "AO46_AGX_CODE_HEAP_POLICY_RESULT status=missing-apple-heap-origin"
        exit 1
    }

    if (variant_allocation_count == 0 || relocation_matches == 0) {
        print "AO46_AGX_CODE_HEAP_PROVENANCE_RESULT status=incomplete" \
            " compute_variant_allocations=" variant_allocation_count \
            " relocation_matches=" relocation_matches
        exit 1
    }

    for (address in relocated_allocations)
        relocated_allocation_count++
    for (digest in relocated_policy)
        relocated_policy_count++

    if (relocated_allocation_count != relocation_matches ||
        relocated_policy_count != 1) {
        print "AO46_AGX_CODE_HEAP_PROVENANCE_RESULT status=ambiguous" \
            " relocated_allocations=" relocated_allocation_count \
            " relocation_matches=" relocation_matches \
            " policy_classes=" relocated_policy_count
        exit 1
    }

    print "AO46_AGX_CODE_HEAP_PROVENANCE_RESULT status=observed" \
        " compute_variant_allocations=" variant_allocation_count \
        " relocation_matches=" relocation_matches \
        " apple_policy_classes=" relocated_policy_count

    print "AO46_AGX_CODE_HEAP_POLICY_RESULT status=observed" \
        " code_heap_resources=" heap_resources \
        " code_heap_policy_classes=" heap_policies \
        " ordinary_resources=" ordinary_resources \
        " ordinary_policy_classes=" ordinary_policies
}
' "$trace_log" | sort
