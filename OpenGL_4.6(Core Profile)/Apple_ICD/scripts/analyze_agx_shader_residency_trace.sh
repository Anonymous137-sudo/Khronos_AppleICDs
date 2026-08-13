#!/bin/sh
set -eu

# Classify returned resource GPU addresses from the read-only shader control.
# Mesa requires executable AGX BOs in a 4 GiB USC window. This analyzer only
# states whether that address class was observed; it never treats a public or
# Apple-owned allocation as executable merely because it has a GPU VA.
if [ "$#" -ne 1 ]; then
    echo "usage: $0 SHADER_TRACE_LOG" >&2
    exit 2
fi

trace_log=$1
if [ ! -f "$trace_log" ]; then
    echo "missing AGX shader-residency trace: $trace_log" >&2
    exit 2
fi

LC_ALL=C awk '
function die(message) {
    print "AGX_SHADER_RESIDENCY error=" message > "/dev/stderr"
    exit 1
}
function field(line, name, value) {
    value = line
    sub(".*" name, "", value)
    sub(" .*$", "", value)
    return value
}
{ sub(/\r$/, "") }
/AO46_AGX_SHADER_CONTRACT_RETURN kind=compute-program-factory/ {
    program_variants++
    next
}
/AO46_AGX_SHADER_USC_RETURN kind=usc-spill-descriptor/ {
    usc_descriptors++
    next
}
/AO46_AGX_SHADER_VARIANT_CALL kind=compute-program-constructor/ {
    variant_constructors++
    profile_flag = field($0, "profile_flag=")
    if (profile_flag == "0x0000000000000000")
        zero_profile_flags++
    else if (profile_flag == "0x0000000000000001")
        enabled_profile_flags++
    else
        unexpected_profile_flags++
    next
}
/AO46_AGX_SHADER_VARIANT_RETURN kind=compute-program-constructor/ {
    variant_constructor_returns++
    next
}
/AO46_AGX_SHADER_VARIANT_RESIDENCY kind=first-heap-selection/ {
    variant_heap_selections++
    if (field($0, "selected_base=") == "0x0000000000000000")
        zero_base_selections++
    else
        nonzero_base_selections++
    next
}
/AO46_AGX_SHADER_EXEC_ALLOCATION_RETURN kind=heap-true-allocate/ {
    if (field($0, "compute_variant_owner=") == "1")
        variant_heap_allocations++
    next
}
/AO46_AGX_SHADER_CODE_HEAP_CALL / {
    kind = field($0, "kind=")
    if (kind == "allocate")
        code_heap_allocations++
    else if (kind == "release")
        code_heap_releases++
    else
        die("unknown-code-heap-lifecycle-call")
    next
}
/AO46_AGX_SHADER_CODE_HEAP_RETURN / {
    kind = field($0, "kind=")
    if (kind == "allocate")
        code_heap_allocation_returns++
    else if (kind == "release")
        code_heap_release_returns++
    else
        die("unknown-code-heap-lifecycle-return")
    next
}
/AO46_AGX_SHADER_CODE_HEAP_RELOCATIONS / {
    direct_relocations++
    if (field($0, "fixed_base=") == "1")
        fixed_base_relocations++
    next
}
/AO46_AGX_SHADER_CODE_LINK_INFO / {
    if (field($0, "kind=") == "initialize")
        code_link_initializations++
    next
}
/AO46_AGX_SHADER_VARIANT_TEARDOWN / {
    variant_teardowns++
    if (field($0, "selected_base=") != "0x0000000000000000")
        enabled_variant_teardowns++
    next
}
/AO46_AGX_SHADER_VARIANT_CALL kind=compute-program-finalize/ {
    variant_finalizations++
    next
}
/AO46_AGX_SHADER_VARIANT_RETURN kind=compute-program-finalize/ {
    variant_finalize_returns++
    next
}
/AO46_AGX_SHADER_VARIANT_USE kind=compute-direct-tg-size/ {
    variant_usc_uses++
    next
}
/AO46_AGX_SHADER_RESOURCE_RETURN kind=resource-gpu-address/ {
    address = field($0, "return_word=")
    if (address !~ /^0x[0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F]$/)
        die("invalid-gpu-address-return")
    if (address == "0x0000000000000000")
        zero_addresses++
    else if (substr(address, 1, 10) == "0x00000000")
        low_va_addresses++
    else
        high_va_addresses++
    next
}
END {
    if (!program_variants || !usc_descriptors)
        die("missing-program-or-usc-observation")
    if (code_heap_allocations != code_heap_allocation_returns ||
        code_heap_releases != code_heap_release_returns)
        die("unbalanced-code-heap-lifecycle")
    printf "AGX_SHADER_RESIDENCY program_variants=%d variant_constructors=%d variant_constructor_returns=%d profile_flag_zero=%d profile_flag_enabled=%d profile_flag_unexpected=%d variant_heap_selections=%d base_selection_zero=%d base_selection_nonzero=%d variant_heap_allocations=%d code_link_initializations=%d direct_relocations=%d fixed_base_relocations=%d variant_teardowns=%d enabled_variant_teardowns=%d code_heap_allocations=%d code_heap_allocation_returns=%d code_heap_releases=%d code_heap_release_returns=%d variant_finalizations=%d variant_finalize_returns=%d variant_usc_uses=%d usc_descriptors=%d gpu_address_high=%d gpu_address_low_nonzero=%d gpu_address_zero=%d nonzero_residency=%s low_va_executable=unproven\n", \
        program_variants, variant_constructors, variant_constructor_returns, \
        zero_profile_flags, enabled_profile_flags, unexpected_profile_flags, \
        variant_heap_selections, zero_base_selections, nonzero_base_selections, \
        variant_heap_allocations, code_link_initializations, direct_relocations, \
        fixed_base_relocations, variant_teardowns, enabled_variant_teardowns, \
        code_heap_allocations, code_heap_allocation_returns, \
        code_heap_releases, code_heap_release_returns, \
        variant_finalizations, variant_finalize_returns, variant_usc_uses, \
        usc_descriptors, high_va_addresses, low_va_addresses, zero_addresses, \
        nonzero_base_selections ? "observed" : "unobserved"
}
' "$trace_log"
