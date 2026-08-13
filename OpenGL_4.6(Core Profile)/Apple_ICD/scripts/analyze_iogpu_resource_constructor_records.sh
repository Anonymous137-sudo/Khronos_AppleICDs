#!/bin/sh
set -eu

if [ "$#" -ne 1 ]; then
    echo "usage: $0 CAPTURE_LOG" >&2
    exit 2
fi

capture_log=$1
if [ ! -f "$capture_log" ]; then
    echo "missing IOGPU resource constructor capture: $capture_log" >&2
    exit 2
fi

# This analyzer names only the experimental inputs. Diff offsets are evidence
# candidates, not undocumented Apple field names or a runtime record layout.
LC_ALL=C awk '
function failure(message) {
    print "IOGPU resource record analysis failed: " message > "/dev/stderr"
    exit 1
}
function field(line, name, value) {
    value = line
    sub(".*" name, "", value)
    sub(" .*$", "", value)
    sub(/\r$/, "", value)
    return value
}
function little_endian_u64(hex, offset,    value, byte_index) {
    value = "0x"
    for (byte_index = 7; byte_index >= 0; --byte_index)
        value = value substr(hex, (offset + byte_index) * 2 + 1, 2)
    return value
}
function first_record(phase, storage,    record_index) {
    for (record_index = 1; record_index <= count[phase]; ++record_index) {
        if (record_storage[phase, record_index] == storage)
            return record[phase, record_index]
    }
    return ""
}
function compare(left_name, right_name, storage, label,    left, right, offset,
                 changed, summary) {
    left = first_record(left_name, storage)
    right = first_record(right_name, storage)
    if (left == "" || right == "") {
        print "AO46_IOGPU_RESOURCE_RECORD_DIFF relation=" label \
              " storage_token=" storage " result=no-comparable-record"
        return
    }

    changed = 0
    summary = ""
    for (offset = 0; offset < 104; ++offset) {
        if (substr(left, offset * 2 + 1, 2) == substr(right, offset * 2 + 1, 2))
            continue
        changed++
        if (changed <= 16)
            summary = summary sprintf("%s0x%02x", summary ? "," : "", offset)
    }
    print "AO46_IOGPU_RESOURCE_RECORD_DIFF relation=" label \
          " storage_token=" storage " changed_bytes=" changed \
          " first_offsets=" (summary ? summary : "none")
}
function only_changed_at(left, right, allowed_offset,    offset, changed) {
    changed = 0
    for (offset = 0; offset < 104; ++offset) {
        if (substr(left, offset * 2 + 1, 2) == substr(right, offset * 2 + 1, 2))
            continue
        if (offset != allowed_offset)
            return 0
        changed++
    }
    return changed == 1
}
function only_changed_within(left, right, first_offset, last_offset,
                             offset, changed) {
    changed = 0
    for (offset = 0; offset < 104; ++offset) {
        if (substr(left, offset * 2 + 1, 2) == substr(right, offset * 2 + 1, 2))
            continue
        if (offset < first_offset || offset > last_offset)
            return 0
        changed++
    }
    return changed > 0
}
/^AO46_RESOURCE_CONSTRUCTOR_CONTROL phase=/ {
    active_phase = field($0, "phase=")
    next
}
/^AO46_RESOURCE_CONSTRUCTOR_CONTROL device_ref=/ {
    generic_device_ref = field($0, "device_ref=")
    if (generic_device_ref !~ /^0x[0-9a-f]{16}$/ ||
        generic_device_ref == "0x0000000000000000")
        failure("invalid-generic-device-root")
    next
}
/^AO46_RESOURCE_CONSTRUCTOR_CONTROL mapping / {
    shared = field($0, "shared=")
    writecombined = field($0, "writecombined=")
    untracked = field($0, "untracked=")
    private_pointer = field($0, "private_pointer=")
    shared_edge = field($0, "shared_edge=")
    writecombined_edge = field($0, "writecombined_edge=")
    untracked_edge = field($0, "untracked_edge=")
    if (shared != "1" || writecombined != "1" || untracked != "1" ||
        private_pointer !~ /^[01]$/ ||
        shared_edge != "46a0" || writecombined_edge != "464f" ||
        untracked_edge != "4655")
        failure("invalid-public-mapping-contract")
    mapping_observed = 1
    next
}
/^AO46_RESOURCE_CONSTRUCTOR_CONTROL public_mapping / {
    phase = field($0, "phase=")
    contents = field($0, "contents=")
    logical_size = field($0, "logical_size=")
    gpu_address = field($0, "gpu_address=")
    if (phase == "" || contents !~ /^0x0000000[0-9a-f]{9}$/ ||
        logical_size !~ /^[1-9][0-9]*$/ ||
        gpu_address !~ /^0x[0-9a-f]{16}$/ ||
        gpu_address == "0x0000000000000000" || phase in public_contents)
        failure("invalid-public-mapping-range")

    # The active-profile CPU pointers remain below 2^53, so POSIX awk can
    # compare their ranges exactly. Reject a different address shape rather
    # than silently accepting an imprecise numeric conversion.
    public_contents[phase] = contents
    public_logical_size[phase] = logical_size
    public_gpu_address[phase] = gpu_address
    public_mapping_count++
    next
}
/^AO46_RESOURCE_CONSTRUCTOR_CONTROL allocation_failure / {
    phase = field($0, "phase=")
    limit = field($0, "limit=")
    requested = field($0, "requested=")
    rejected = field($0, "rejected=")
    if (phase != "oversized-failure" || limit !~ /^[1-9][0-9]*$/ ||
        requested !~ /^[1-9][0-9]*$/ || requested <= limit || rejected != "1" ||
        allocation_failure_observed)
        failure("invalid-public-allocation-failure")
    allocation_failure_observed = 1
    next
}
/^AO46_IOGPU_RESOURCE_FRAME / {
    capture_id = field($0, "capture_id=")
    phase = field($0, "phase=")
    device = field($0, "device=")
    arguments = field($0, "args=")
    bytes = field($0, "bytes=")
    hook = field($0, "return_hook=")
    data = field($0, "data=")
    x3 = field($0, "x3=")
    x4 = field($0, "x4=")
    x5 = field($0, "x5=")
    x6 = field($0, "x6=")
    x7 = field($0, "x7=")

    if (phase == "unknown")
        phase = active_phase
    if (capture_id == "" || phase == "" || device == "0x0000000000000000" ||
        generic_device_ref == "" || device != generic_device_ref ||
        bytes != "104" || hook != "1" ||
        x3 !~ /^0x[0-9a-f]{16}$/ || x4 !~ /^0x[0-9a-f]{16}$/ ||
        x5 !~ /^0x[0-9a-f]{16}$/ || x6 !~ /^0x[0-9a-f]{16}$/ ||
        x7 !~ /^0x[0-9a-f]{16}$/ ||
        length(data) != 208 || data ~ /[^0-9a-f]/)
        failure("invalid-frame")
    if (first_device == "")
        first_device = device
    else if (first_device != device)
        failure("device-changed")

    count[phase]++
    constructor_count++
    record[phase, count[phase]] = data
    record_tail[phase, count[phase]] = x3 "," x4 "," x5 "," x6 "," x7
    capture_phase[capture_id] = phase
    capture_device[capture_id] = device
    capture_arguments[capture_id] = arguments
    # This little-endian 32-bit token is only a grouping key. Its public
    # meaning is not inferred by this analyzer.
    record_storage[phase, count[phase]] = substr(data, 20 * 2 + 1, 8)
    capture_storage[capture_id] = record_storage[phase, count[phase]]
    capture_record[capture_id] = data
    # macOS awk is POSIX awk and does not portably accept hexadecimal numeric
    # literals. Byte 72 is record offset 0x48.
    capture_requested_size[capture_id] = little_endian_u64(data, 72)
    pending_selector_capture = capture_id
}
/^AO46_IOGPU_RESOURCE_SELECTOR9 / {
    phase = field($0, "phase=")
    arguments = field($0, "args=")
    bytes = field($0, "bytes=")
    data = field($0, "data=")
    capture_id = pending_selector_capture
    if (capture_id == "" || (capture_id in selector_forwarded) ||
        arguments != capture_arguments[capture_id] || bytes != "104" ||
        data != capture_record[capture_id])
        failure("invalid-selector9-resource-forwarding")

    selector_forwarded[capture_id] = 1
    selector_count++
    pending_selector_capture = ""
    next
}
/^AO46_IOGPU_RESOURCE_CREATE_RETURN / {
    capture_id = field($0, "capture_id=")
    device = field($0, "device=")
    resource = field($0, "resource=")
    if (capture_id == "" || !(capture_id in capture_phase) ||
        device != capture_device[capture_id] || !(capture_id in selector_forwarded))
        failure("invalid-constructor-return")
    if (resource == "0x0000000000000000") {
        if (capture_phase[capture_id] != "oversized-failure")
            failure("unexpected-null-constructor-return")
        failed_returns[capture_id] = 1
        failed_constructor_count++
        next
    }
    if (resource in returned_resources)
        failure("duplicate-returned-resource")

    returned_resources[resource] = capture_id
    returned_count++
}
/^AO46_IOGPU_RESOURCE_OBJECT / {
    capture_id = field($0, "capture_id=")
    resource = field($0, "resource=")
    fields = field($0, "fields=")
    data_bytes = field($0, "data_bytes=")
    data_size = field($0, "data_size=")
    resident_data_size = field($0, "resident_data_size=")
    gpu_va = field($0, "gpu_virtual_address=")
    gpu_va_length = field($0, "gpu_virtual_address_length=")

    if (capture_id == "" || !(capture_id in capture_phase) || resource == "")
        failure("invalid-resource-object-snapshot")
    if (resource == "0x0000000000000000" && fields == "null") {
        if (!(capture_id in failed_returns) || capture_phase[capture_id] != "oversized-failure")
            failure("invalid-null-resource-object")
        failed_object_snapshots++
        next
    }
    if (!(resource in returned_resources) ||
        returned_resources[resource] != capture_id ||
        data_bytes !~ /^0x[0-9a-f]{16}$/ || data_size !~ /^0x[0-9a-f]{16}$/ ||
        resident_data_size !~ /^0x[0-9a-f]{16}$/ ||
        gpu_va !~ /^0x[0-9a-f]{16}$/ ||
        gpu_va_length !~ /^0x[0-9a-f]{16}$/ ||
        gpu_va == "0x0000000000000000")
        failure("invalid-resource-object-snapshot")
    if (resource in snapshot_gpu_va)
        failure("duplicate-resource-object-snapshot")

    snapshot_data_bytes[resource] = data_bytes
    snapshot_data_size[resource] = data_size
    snapshot_resident_data_size[resource] = resident_data_size
    snapshot_gpu_va[resource] = gpu_va
    snapshot_gpu_va_length[resource] = gpu_va_length
    snapshot_storage[resource] = capture_storage[capture_id]
    snapshot_count++
}
/^AO46_IOGPU_RESOURCE_ACCESSOR / {
    capture_id = field($0, "capture_id=")
    accessor_name = field($0, "function=")
    resource = field($0, "resource=")
    hook = field($0, "return_hook=")
    if (capture_id == "" || (accessor_name != "gpu-virtual-address" &&
        accessor_name != "gpu-virtual-address-length") ||
        resource == "0x0000000000000000" || !(resource in returned_resources) ||
        hook != "1")
        failure("invalid-gpu-va-accessor")
    accessor_function[capture_id] = accessor_name
    accessor_resource[capture_id] = resource
    accessor_calls++
}
/^AO46_IOGPU_RESOURCE_ACCESSOR_RETURN / {
    capture_id = field($0, "capture_id=")
    accessor_name = field($0, "function=")
    resource = field($0, "resource=")
    value = field($0, "value=")
    if (!(capture_id in accessor_function) || accessor_name != accessor_function[capture_id] ||
        resource != accessor_resource[capture_id] || value == "0x0000000000000000")
        failure("invalid-gpu-va-accessor-return")
    if (accessor_name == "gpu-virtual-address") {
        if (resource in resource_gpu_va)
            failure("duplicate-resource-gpu-va")
        if (!(resource in snapshot_gpu_va) || snapshot_gpu_va[resource] != value)
            failure("resource-object-gpu-va-mismatch")
        resource_gpu_va[resource] = value
        unique_gpu_va[value] = 1
        gpu_va_returns++
    } else {
        gpu_va_length_returns++
    }
    accessor_returns++
}
/^AO46_IOGPU_RESOURCE_RELEASE / {
    phase = field($0, "phase=")
    resource = field($0, "resource=")
    if (phase == "unknown")
        phase = active_phase
    if (phase != "release" || resource == "0x0000000000000000" ||
        !(resource in returned_resources))
        failure("invalid-release-frame")
    if (resource in released_resources)
        failure("duplicate-resource-release")
    releases++
    released_resources[resource] = 1
}
END {
    required["shared-4k-a"] = 1
    required["shared-4k-b"] = 1
    required["shared-128k"] = 1
    required["private-4k"] = 1
    required["writecombined-4k"] = 1
    required["shared-untracked-4k"] = 1
    required["shared-8k"] = 1
    required["shared-16k"] = 1
    required["shared-16k-b"] = 1
    required["shared-16k-writecombined"] = 1
    required["shared-32k"] = 1
    required["shared-16k-after-failure"] = 1
    required["shared-16k-after-failure-b"] = 1
    for (phase in required) {
        if (!count[phase])
            failure("missing-phase-" phase)
        print "AO46_IOGPU_RESOURCE_RECORD phase=" phase " calls=" count[phase]
        for (record_index = 1; record_index <= count[phase]; ++record_index) {
            print "AO46_IOGPU_RESOURCE_RECORD phase=" phase \
                  " record=" record_index \
                  " storage_token=" record_storage[phase, record_index]
            tail_values = record_tail[phase, record_index]
            tail_seen[tail_values] = 1
        }
    }

    compare("shared-4k-a", "shared-4k-b", "300c0000",
            "duplicate-shared-baseline")
    compare("shared-4k-a", "shared-128k", "70040000", "size-4k-to-128k")
    compare("shared-4k-a", "private-4k", "70040000",
            "storage-shared-to-private")
    compare("shared-4k-a", "writecombined-4k", "70040000",
            "cache-default-to-writecombined")
    compare("shared-4k-a", "shared-untracked-4k", "300c0000",
            "hazard-tracked-to-untracked")
    compare("shared-16k", "shared-16k-b", "70040000",
            "direct-size-repeat")
    compare("shared-16k", "shared-16k-writecombined", "70040000",
            "direct-cache-variation")
    compare("shared-16k", "shared-16k-after-failure", "70040000",
            "direct-post-null-recovery")
    compare("shared-16k-after-failure", "shared-16k-after-failure-b",
            "70040000", "direct-post-null-recovery-repeat")

    direct_repeat_left = first_record("shared-16k", "70040000")
    direct_repeat_right = first_record("shared-16k-b", "70040000")
    if (direct_repeat_left == "" || direct_repeat_right == "" ||
        direct_repeat_left != direct_repeat_right)
        failure("direct-repeat-record-policy-changed")
    direct_cache_record = first_record("shared-16k-writecombined", "70040000")
    direct_recovery_record = first_record("shared-16k-after-failure", "70040000")
    direct_recovery_repeat_record = first_record("shared-16k-after-failure-b", "70040000")
    if (direct_cache_record == "" || direct_recovery_record == "" ||
        direct_recovery_repeat_record == "" ||
        !only_changed_at(direct_repeat_left, direct_cache_record, 5) ||
        substr(direct_repeat_left, 193, 8) != substr(direct_cache_record, 193, 8) ||
        !only_changed_within(direct_repeat_left, direct_recovery_record, 96, 99) ||
        !only_changed_within(direct_recovery_record, direct_recovery_repeat_record,
                             96, 99))
        failure("direct-tail-or-post-null-recovery-policy-changed")
    print "AO46_IOGPU_RESOURCE_TAIL_POLICY direct_cache_delta=0x05 " \
          "post_null_delta=0x60-0x63 recovery_delta=0x60-0x63 " \
          "rule=tail-is-allocator-owned-opaque-metadata"

    shared = first_record("shared-4k-a", "70040000")
    writecombined = first_record("writecombined-4k", "70040000")
    if (shared == "" || writecombined == "")
        failure("missing-writecombined-comparison-record")
    if (substr(shared, 1, 16) != "0000000000000000" ||
        substr(writecombined, 1, 16) != "0000000000040000")
        failure("writecombined-attribute-mask-changed")

    print "AO46_IOGPU_RESOURCE_RECORD_FIELD " \
          "offset=0x00 width=8 relation=writecombined " \
          "value=0x0000040000000000 semantic=attributes.write_combined"

    if (!releases)
        failure("no-resource-release-observed")
    if (constructor_count != returned_count + failed_constructor_count)
        failure("constructor-return-count-mismatch")
    if (selector_count != constructor_count)
        failure("constructor-selector9-count-mismatch")
    if (returned_count != releases)
        failure("constructor-release-count-mismatch")
    if (snapshot_count != returned_count)
        failure("constructor-object-snapshot-count-mismatch")
    unique_releases = 0
    for (resource in released_resources)
        unique_releases++
    if (unique_releases != returned_count)
        failure("constructor-release-identity-mismatch")
    print "AO46_IOGPU_RESOURCE_LIFECYCLE release_calls=" releases \
          " unique_resources=" unique_releases \
          " constructor_calls=" constructor_count \
          " returned_resources=" returned_count \
          " trigger=public-metal-buffer-release"
    print "AO46_IOGPU_RESOURCE_SELECTOR9_POLICY constructor_calls=" constructor_count \
          " forwarded_records=" selector_count " record_bytes=104 " \
          " rule=full-record-including-opaque-tail-reaches-selector9"
    if (!allocation_failure_observed || failed_constructor_count != 1 ||
        failed_object_snapshots != 1)
        failure("missing-public-allocation-failure")
    print "AO46_IOGPU_RESOURCE_FAILURE_POLICY public_oversized_request=1 " \
          "generic_constructor_calls=1 null_returns=1 resource_objects=0 " \
          "resource_releases=0 rule=apple-constructor-null-return-is-non-owning"
    if (!mapping_observed)
        failure("missing-public-mapping-contract")
    print "AO46_IOGPU_RESOURCE_MAPPING shared=1 writecombined=1 untracked=1 " \
          "private_pointer=" private_pointer \
          " trigger=public-metal-contents"
    if (accessor_calls != accessor_returns)
        failure("gpu-va-accessor-return-count-mismatch")
    if (gpu_va_returns != returned_count)
        failure("resource-gpu-va-coverage-mismatch")
    unique_gpu_va_count = 0
    for (gpu_va in unique_gpu_va)
        unique_gpu_va_count++
    print "AO46_IOGPU_RESOURCE_GPU_VA observation_calls=" accessor_calls \
          " completed_returns=" accessor_returns \
          " resource_addresses=" gpu_va_returns \
          " unique_addresses=" unique_gpu_va_count \
          " length_returns=" (gpu_va_length_returns + 0)

    # A generic IOGPU resource object and a GPU VA are not interchangeable.
    # Public Metal can create several resource objects for one VA, so a future
    # AO46 bridge must retain/release object identities independently of BO VA
    # tracking. This gate establishes that relationship without assigning field
    # meanings to Apple-owned private 104-byte records.
    aliased_resource_objects = 0
    for (resource in returned_resources) {
        if (!(resource in resource_gpu_va))
            failure("missing-resource-gpu-va")
        if (!(resource in released_resources))
            failure("resource-not-released")

        gpu_va = resource_gpu_va[resource]
        va_resource_count[gpu_va]++
        va_phase_list[gpu_va] = va_phase_list[gpu_va] \
            (va_phase_list[gpu_va] ? "," : "") capture_phase[returned_resources[resource]]
    }

    for (gpu_va in va_resource_count) {
        resource_count = va_resource_count[gpu_va]
        if (resource_count > 1)
            aliased_resource_objects += resource_count - 1
        print "AO46_IOGPU_RESOURCE_VA_GROUP gpu_va=" gpu_va \
              " resource_objects=" resource_count \
              " phases=" va_phase_list[gpu_va] \
              " relation=apple-resource-object-to-gpu-va"
    }
    print "AO46_IOGPU_RESOURCE_OWNERSHIP resource_objects=" returned_count \
          " unique_gpu_va=" unique_gpu_va_count \
          " aliased_resource_objects=" aliased_resource_objects \
          " rule=object-lifetime-is-independent-of-gpu-va"

    # Every observed non-data-bearing resource must be wholly described by one
    # data-bearing GPU-VA range. This derives a range relation only; it does
    # not assign a private field name or authorize object construction.
    paired_suballocations = 0
    non_data_resource_objects = 0
    for (resource in returned_resources) {
        if (snapshot_storage[resource] != "300c0000")
            continue

        non_data_resource_objects++
        suballocation_start = resource_gpu_va[resource] + 0
        suballocation_end = suballocation_start + (snapshot_gpu_va_length[resource] + 0)
        backing_resource = ""
        for (candidate in returned_resources) {
            if (snapshot_storage[candidate] != "70040000")
                continue

            backing_start = resource_gpu_va[candidate] + 0
            backing_end = backing_start + (snapshot_gpu_va_length[candidate] + 0)
            if (suballocation_start >= backing_start &&
                suballocation_end <= backing_end) {
                if (backing_resource != "")
                    failure("ambiguous-suballocation-backing-range")
                backing_resource = candidate
            }
        }
        if (backing_resource == "")
            failure("missing-suballocation-backing-range")

        paired_suballocations++
        suballocation_phase = capture_phase[returned_resources[resource]]
        suballocation_record = capture_record[returned_resources[resource]]
        record_contents_pointer = little_endian_u64(suballocation_record, 56)
        record_backing_pointer = little_endian_u64(suballocation_record, 64)
        if (record_contents_pointer != public_contents[suballocation_phase] ||
            record_backing_pointer != snapshot_data_bytes[backing_resource])
            failure("suballocation-record-pointer-link-changed")
        print "AO46_IOGPU_RESOURCE_SUBALLOCATION phase=" \
              suballocation_phase \
              " backing_phase=" capture_phase[returned_resources[backing_resource]] \
              " gpu_va_offset=" sprintf("0x%x", suballocation_start - (resource_gpu_va[backing_resource] + 0)) \
              " record_contents_field=0x38 record_backing_field=0x40 " \
              " relation=non-data-resource-contained-by-data-backing-range"
    }
    if (paired_suballocations != non_data_resource_objects)
        failure("incomplete-suballocation-backing-policy")

    for (resource in returned_resources) {
        phase = capture_phase[returned_resources[resource]]
        if (phase == "shared-16k" && snapshot_storage[resource] == "70040000")
            direct_repeat_left_resource = resource
        if (phase == "shared-16k-b" && snapshot_storage[resource] == "70040000")
            direct_repeat_right_resource = resource
    }
    if (direct_repeat_left_resource == "" || direct_repeat_right_resource == "" ||
        direct_repeat_left_resource == direct_repeat_right_resource ||
        resource_gpu_va[direct_repeat_left_resource] == resource_gpu_va[direct_repeat_right_resource])
        failure("direct-repeat-identity-policy-changed")
    print "AO46_IOGPU_RESOURCE_RECORD_REPEAT phases=shared-16k,shared-16k-b " \
          "record_bytes=104 distinct_resources=1 distinct_gpu_va=1 " \
          "tail_word_0x60=0x" substr(direct_repeat_left, 193, 8) \
          " rule=tail-does-not-distinguish-direct-resource-identity"

    data_bearing_objects = 0
    sized_data_objects = 0
    sized_gpu_va_objects = 0
    for (resource in returned_resources) {
        storage = snapshot_storage[resource]
        requested_size = capture_requested_size[returned_resources[resource]]
        if (storage != "70040000" && storage != "300c0000")
            failure("unknown-resource-record-token")
        if (substr(snapshot_gpu_va_length[resource], 16, 3) != "000")
            failure("resource-gpu-va-range-is-not-page-aligned")

        storage_objects[storage]++
        if (snapshot_data_bytes[resource] != "0x0000000000000000") {
            data_bearing_objects++
            storage_data_bearing[storage]++
        }
        if (snapshot_data_size[resource] != "0x0000000000000000")
            sized_data_objects++
        if (snapshot_gpu_va_length[resource] != "0x0000000000000000")
            sized_gpu_va_objects++

        if (storage == "70040000") {
            if (requested_size == "0x0000000000000000" ||
                snapshot_data_bytes[resource] == "0x0000000000000000" ||
                snapshot_data_size[resource] != requested_size ||
                snapshot_resident_data_size[resource] != requested_size ||
                snapshot_gpu_va_length[resource] != requested_size) {
                failure("data-bearing-resource-size-policy-changed")
            }
            direct_object_sizes[requested_size] = 1
        } else if (snapshot_data_bytes[resource] != "0x0000000000000000" ||
                   snapshot_data_size[resource] == "0x0000000000000000" ||
                   snapshot_resident_data_size[resource] == "0x0000000000000000") {
            failure("non-data-resource-mapping-policy-changed")
        }
    }
    if (!storage_objects["70040000"] || !storage_objects["300c0000"] ||
        storage_data_bearing["70040000"] != storage_objects["70040000"] ||
        storage_data_bearing["300c0000"] != 0)
        failure("resource-record-token-mapping-policy-changed")
    direct_size_count = 0
    for (requested_size in direct_object_sizes)
        direct_size_count++
    if (direct_size_count < 3 || !direct_object_sizes["0x0000000000004000"] ||
        !direct_object_sizes["0x0000000000008000"] ||
        !direct_object_sizes["0x0000000000020000"])
        failure("missing-direct-resource-size-series")
    print "AO46_IOGPU_RESOURCE_OBJECT_FIELDS resource_objects=" returned_count \
          " data_bearing=" data_bearing_objects \
          " nonzero_data_sizes=" sized_data_objects \
          " nonzero_gpu_va_lengths=" sized_gpu_va_objects \
          " rule=read-only-accessor-backed-observation"

    mapped_ranges = 0
    offset_mapped_ranges = 0
    public_gpu_va_matches = 0
    for (phase in required) {
        if (!(phase in public_contents))
            failure("missing-public-mapping-" phase)

        mapping_start = public_contents[phase] + 0
        mapping_end = mapping_start + public_logical_size[phase]
        matched_resource = ""
        for (resource in returned_resources) {
            if (snapshot_data_bytes[resource] == "0x0000000000000000")
                continue

            backing_start = snapshot_data_bytes[resource] + 0
            backing_end = backing_start + (snapshot_data_size[resource] + 0)
            if (mapping_start >= backing_start && mapping_end <= backing_end) {
                matched_resource = resource
                mapping_offset = mapping_start - backing_start
                break
            }
        }
        if (matched_resource == "")
            failure("public-mapping-not-contained-by-data-bearing-resource")

        # The public Metal gpuAddress must name a GPU VA owned by at least one
        # generic IOGPU resource created for the same public allocation. This
        # is an ownership correlation, not authorization to create either
        # private resource record or submit an Asahi command stream.
        phase_gpu_va_match = ""
        for (resource in returned_resources) {
            if (capture_phase[returned_resources[resource]] != phase)
                continue
            if (resource_gpu_va[resource] == public_gpu_address[phase]) {
                phase_gpu_va_match = resource
                break
            }
        }
        if (phase_gpu_va_match == "")
            failure("public-metal-gpu-address-not-owned-by-phase-resource")
        public_gpu_va_matches++

        mapped_ranges++
        if (mapping_offset != 0)
            offset_mapped_ranges++
        print "AO46_IOGPU_RESOURCE_MAPPING_BACKING phase=" phase \
              " logical_size=" public_logical_size[phase] \
              " backing_phase=" capture_phase[returned_resources[matched_resource]] \
              " offset=" sprintf("0x%x", mapping_offset) \
              " relation=public-contents-contained-by-data-bearing-resource"
    }
    if (public_mapping_count != 13 || mapped_ranges != public_mapping_count ||
        !offset_mapped_ranges)
        failure("public-mapping-containment-policy-changed")
    print "AO46_IOGPU_RESOURCE_MAPPING_POLICY public_ranges=" mapped_ranges \
          " offset_ranges=" offset_mapped_ranges \
          " rule=public-contents-requires-observed-data-backing-range"
    print "AO46_IOGPU_RESOURCE_PUBLIC_METAL_GPU_VA public_buffers=" \
          public_mapping_count " matching_generic_resource_vas=" \
          public_gpu_va_matches \
          " rule=public-metal-allocation-identifies-an-observed-gpu-va"
    print "AO46_IOGPU_RESOURCE_RECORD_POLICY data_bearing_token=70040000 " \
          "direct_size_field=0x48 non_data_token=300c0000 " \
          "direct_size_series=0x4000,0x8000,0x20000 " \
          "suballocation_backings=" paired_suballocations " " \
          "gpu_va_ranges=nonzero-page-aligned " \
          "rule=token-is-observed-not-a-public-field-name"

    tail_variants = 0
    for (tail in tail_seen)
        tail_variants++
    print "AO46_IOGPU_RESOURCE_ABI base_registers=x0,x1,x2 " \
          "tail_registers=x3,x4,x5,x6,x7 tail_variants=" tail_variants \
          " rule=tail-registers-observed-not-callable"
    print "AO46_IOGPU_RESOURCE_DEVICE_ROOT device_ref=" generic_device_ref \
          " constructor_x0=matched rule=metal-device-ref-is-generic-root"
}
' "$capture_log"
