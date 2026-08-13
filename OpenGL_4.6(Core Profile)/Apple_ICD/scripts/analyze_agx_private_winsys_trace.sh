#!/bin/sh
set -eu

if [ "$#" -ne 1 ]; then
    echo "usage: $0 TRACE_LOG" >&2
    exit 2
fi

trace_log=$1
if [ ! -f "$trace_log" ]; then
    echo "missing private winsys trace: $trace_log" >&2
    exit 2
fi

expected_submissions=${AGX_PRIVATE_WINSYS_EXPECTED_SUBMISSIONS:-2}
require_reused_bindings=${AGX_PRIVATE_WINSYS_REQUIRE_REUSED_BINDINGS:-1}
case "$expected_submissions:$require_reused_bindings" in
    1:0|1:1|2:0|2:1|3:0|3:1|4:0|4:1)
        ;;
    *)
        echo "invalid private winsys trace expectations" >&2
        exit 2
        ;;
esac

LC_ALL=C awk -v expected_submissions="$expected_submissions" \
    -v require_reused_bindings="$require_reused_bindings" '
function fail(message) {
    failed = 1
    print "AGX private winsys trace analysis failed: " message > "/dev/stderr"
    exit 1
}
function field(line, name, value) {
    value = line
    sub(".*" name, "", value)
    sub(" .*$", "", value)
    sub(/\r$/, "", value)
    return value
}
/^MODERN_SUBMIT queue=/ {
    modern_submission_count++
    queue = field($0, "queue=")
    header = field($0, "header=")
    token0 = field($0, "completion0=")
    token1 = field($0, "completion1=")
    if (queue == "0" || header != "2/1" || token0 == "0" ||
        token1 == "0" || token0 == token1 ||
        (token0 in active_completion_token_submission) ||
        (token1 in active_completion_token_submission))
        fail("invalid-observed-completion-token-pair")
    if ((token0 in latest_completion_token_submission) ||
        (token1 in latest_completion_token_submission)) {
        previous0 = latest_completion_token_submission[token0]
        previous1 = latest_completion_token_submission[token1]
        if (previous0 == "" || previous1 == "" || previous0 != previous1 ||
            submission_completion_count[previous0] != 2)
            fail("premature-or-mixed-completion-token-reuse")
        serial_completion_token_reuse++
    }
    submission_queue[modern_submission_count] = queue
    submission_token0[modern_submission_count] = token0
    submission_token1[modern_submission_count] = token1
    active_completion_token_submission[token0] = modern_submission_count
    active_completion_token_submission[token1] = modern_submission_count
    latest_completion_token_submission[token0] = modern_submission_count
    latest_completion_token_submission[token1] = modern_submission_count
    next
}
/^MODERN_COMPLETION queue=/ {
    queue = field($0, "queue=")
    token = field($0, "token=")
    if (!(token in active_completion_token_submission))
        fail("completion-not-owned-by-observed-submission")
    submission_id = active_completion_token_submission[token]
    if (submission_queue[submission_id] != queue ||
        (submission_id SUBSEP token) in completed_completion_tokens)
        fail("invalid-or-duplicate-observed-completion")
    completed_completion_tokens[submission_id SUBSEP token] = 1
    submission_completion_count[submission_id]++
    if (submission_completion_count[submission_id] == 2) {
        delete active_completion_token_submission[submission_token0[submission_id]]
        delete active_completion_token_submission[submission_token1[submission_id]]
    }
    modern_completion_count++
    next
}
/^AO46_AGX_[A-Z0-9_]+ complete([[:space:]]|$)/ {
    workload_completed = 1
    completion_markers++
}
/^AO46_AGX_PRIVATE_WINSYS_SLOT / {
    phase = field($0, "phase=")
    storage = field($0, "storage=")
    slot_index_value = field($0, "index=")
    record = field($0, "record=")
    if (phase != "before" && phase != "after")
        fail("invalid-carrier-slot-phase")
    if (storage == "0x0000000000000000" || slot_index_value == "" ||
        record == "0x0000000000000000")
        fail("invalid-carrier-slot-snapshot")
    slot_key = storage SUBSEP slot_index_value
    if (phase == "before") {
        descriptor = field($0, "slot_descriptor=")
        if (descriptor == "0x0000000000000000")
            fail("invalid-carrier-slot-descriptor")
        if (slot_key in slot_descriptor) {
            if (slot_descriptor[slot_key] != descriptor)
                fail("carrier-slot-descriptor-changed")
            reused_slot_snapshots++
        }
        slot_descriptor[slot_key] = descriptor
        slot_record[slot_key] = record
    } else {
        record_resource = field($0, "record_resource=")
        if (!(slot_key in slot_descriptor) || slot_record[slot_key] != record ||
            record_resource == "0x0000000000000000")
            fail("invalid-materialized-carrier-slot")
        allocation_id = allocation_by_slot[slot_key]
        if (allocation_id == "" ||
            allocation_pooled_resource[allocation_id] == "" ||
            record_resource != allocation_pooled_resource[allocation_id])
            fail("carrier-slot-resource-pool-mismatch")
        slot_record_resource[slot_key] = record_resource
    }
    next
}
/^AO46_AGX_PRIVATE_WINSYS_SEGMENT_POINTER / {
    storage = field($0, "storage=")
    pointer = field($0, "pointer=")
    kernel_base = field($0, "kernel_base=")
    kernel_delta = field($0, "kernel_delta=")
    if (storage == "0x0000000000000000" ||
        pointer == "0x0000000000000000" ||
        kernel_base == "0x0000000000000000" || kernel_delta != "0xac")
        fail("invalid-segment-kernel-pointer-contract")
    segment_kernel_pointer_contracts++
    next
}
/^AO46_AGX_PRIVATE_WINSYS_CALL / {
    event_order++
    name = field($0, "name=")
    capture_id = field($0, "capture_id=")
    hook = field($0, "return_hook=")
    x0 = field($0, "x0=")
    x1 = field($0, "x1=")
    x2 = field($0, "x2=")
    x3 = field($0, "x3=")
    x4 = field($0, "x4=")
    x5 = field($0, "x5=")
    if (name == "" || x0 == "0x0000000000000000")
        fail("invalid-private-winsys-call")
    calls[name]++
    if (name == "begin-kernel-commands" || name == "begin-segment" ||
        name == "end-segment" || name == "alloc-resource-at-index") {
        if (storage_identity == "")
            storage_identity = x0
        else if (storage_identity != x0)
            fail("storage-identity-changed")
        observed_storages[x0] = 1
    }
    if (name == "resource-list-reset")
        resource_resets[x0]++
    if (name == "command-buffer-fill") {
        fill_index = fill_count + 1
        if (x0 == "0x0000000000000000" ||
            x1 == "0x0000000000000000" ||
            x2 == "0x0000000000000000" ||
            x3 == "0x0000000000000000" || storage_create_returns == 0)
            fail("invalid-apple-command-buffer-fill")
        fill_command_buffer[fill_index] = x0
        fill_descriptor[fill_index] = x2
        fill_queue[fill_index] = x3
        fill_order[fill_index] = event_order
        fill_count++
    }
    if (name == "resource-release") {
        resource_release_calls++
        if (x0 in command_resource_allocation) {
            if (!workload_completed)
                fail("command-resource-released-before-workload-complete")
            if (modern_completion_count != modern_submission_count * 2)
                fail("command-resource-released-before-token-retirement")
            released_command_resources[x0] = 1
        }
    }
    if (name == "alloc-resource-at-index") {
        if (active_allocation != "" || ready_allocation != "")
            fail("overlapping-command-resource-allocation")
        active_allocation = capture_id
        allocation_storage[capture_id] = x0
        allocation_index[capture_id] = x1
        allocation_usage[capture_id] = x2
        allocation_by_slot[x0 SUBSEP x1] = capture_id
        allocation_count++
    }
    if (name == "command-buffer-begin-segment") {
        if (x0 == "0x0000000000000000" ||
            x2 == "0x0000000000000000" ||
            pending_command_buffer_segment != "")
            fail("invalid-command-buffer-segment-begin")
        pending_command_buffer_segment = x2
        command_buffer_segment_begins++
    }
    if (name == "begin-segment") {
        if (pending_command_buffer_segment != "") {
            if (x1 != pending_command_buffer_segment)
                fail("command-buffer-storage-segment-mismatch")
            pending_command_buffer_segment = ""
            correlated_command_buffer_segments++
        } else {
            direct_storage_segment_begins++
        }
    }
    if (name == "resource-pool-create-pooled-resource") {
        slot_key = allocation_storage[active_allocation] SUBSEP \
                   allocation_index[active_allocation]
        if (active_allocation == "" ||
            allocation_resource_pool_call[active_allocation] != "" ||
            x0 != slot_descriptor[slot_key])
            fail("invalid-apple-resource-pool-handoff")
        allocation_resource_pool_call[active_allocation] = capture_id
        resource_pool_call_allocation[capture_id] = active_allocation
    }
    if (name == "resource-list-add-resource") {
        if (resource_list == "")
            resource_list = x0
        else if (resource_list != x0)
            fail("resource-list-identity-changed")
        if (!(x0 in resource_resets))
            fail("resource-list-used-before-reset")
        if (ready_allocation != "") {
            allocation_id = ready_allocation
            if (x1 == "0x0000000000000000" ||
                x3 != allocation_result_mode[allocation_id])
                fail("invalid-apple-resource-binding-record")
            if (allocation_materialized[allocation_id]) {
                if (x1 == allocation_resource[allocation_id])
                    fail("invalid-materialized-resource-binding-record")
                if (x1 in materialized_binding_records)
                    fail("binding-record-materialized-more-than-once")
                materialized_binding_records[x1] = 1
                materialized_resource_bindings++
            } else if (!(x1 in materialized_binding_records)) {
                fail("reused-resource-binding-record-not-materialized")
            } else {
                reused_resource_bindings++
            }
            if (x1 in binding_record_mode) {
                if (binding_record_mode[x1] != x3)
                    fail("resource-binding-record-mode-changed")
            } else {
                binding_record_mode[x1] = x3
            }
            allocation_binding_record[allocation_id] = x1
            bound_allocation_records[x1] = 1
            correlated_resource_bindings++
            ready_allocation = ""
        } else {
            inherited_resource_bindings++
        }
        last_resource_add_order = event_order
    }
    if (name == "queue-submit") {
        submit_index = queue_submits + 1
        if (x1 != "0x0000000000000000" ||
            x2 != "0x0000000000000001" ||
            x3 == "0x0000000000000000" ||
            x4 != "0x0000000000000040" ||
            x5 == "0x0000000000000000" || last_resource_add_order == 0 ||
            last_resource_add_order >= event_order || fill_count != submit_index ||
            fill_order[submit_index] >= event_order ||
            fill_descriptor[submit_index] != x3)
            fail("invalid-queue-submit-handoff")
        last_submit_descriptor = x3
        last_submit_auxiliary = x5
        descriptor_addresses[x3] = 1
        queue_submits++
    }
    if (name == "trap4") {
        if (queue_submits == 0 || traps >= queue_submits ||
            x1 != "0x0000000000000000" ||
            x2 == "0x0000000000000000" ||
            x3 != "0x0000000000000040" ||
            x4 != last_submit_descriptor || x5 != last_submit_auxiliary)
            fail("invalid-trap4-handoff")
        traps++
    }
    if (name == "command-storage-create" || name == "resource-create" ||
        name == "resource-gpu-address" ||
        name == "begin-kernel-commands" || name == "begin-segment" ||
        name == "alloc-resource-at-index" ||
        name == "resource-pool-create-pooled-resource" ||
        name == "command-buffer-init" || name == "storage-pool-create") {
        if (capture_id == "0" || hook != "1" || (capture_id in pending_returns))
            fail("invalid-return-hook")
        pending_returns[capture_id] = name SUBSEP x0
        if (name == "resource-create" && active_allocation != "") {
            if (allocation_resource_create[active_allocation] != "")
                fail("multiple-apple-resources-for-command-allocation")
            allocation_resource_create[active_allocation] = capture_id
            resource_create_allocation[capture_id] = active_allocation
        }
        if (name == "resource-gpu-address") {
            if (!(x0 in created_resources))
                fail("gpu-va-query-before-resource-create")
            if (active_allocation != "") {
                if (allocation_resource[active_allocation] != x0 ||
                    allocation_gpu_va_query[active_allocation] != "")
                    fail("invalid-command-resource-gpu-va-query")
                allocation_gpu_va_query[active_allocation] = capture_id
                gpu_va_query_allocation[capture_id] = active_allocation
            }
        }
        return_calls++
    }
    events++
}
/^AO46_AGX_PRIVATE_WINSYS_RETURN / {
    capture_id = field($0, "capture_id=")
    name = field($0, "name=")
    entry_storage = field($0, "storage=")
    return_value = field($0, "x0=")
    return_x1 = field($0, "x1=")
    if (!(capture_id in pending_returns) ||
        pending_returns[capture_id] != name SUBSEP entry_storage)
        fail("invalid-private-winsys-return")
    if (name == "command-storage-create") {
        if (return_value == "0x0000000000000000")
            fail("command-storage-create-returned-null")
        created_storages[return_value] = 1
        storage_create_returns++
    }
    if (name == "storage-pool-create") {
        if (return_value == "0x0000000000000000")
            fail("storage-pool-create-returned-null")
        pool_created_storages[return_value] = 1
        storage_pool_create_returns++
    }
    if (name == "command-buffer-init") {
        if (return_value == "0x0000000000000000")
            fail("command-buffer-init-returned-null")
        command_buffer_init_returns++
    }
    if (name == "resource-create") {
        if (return_value == "0x0000000000000000")
            fail("apple-resource-create-returned-null")
        created_resources[return_value] = 1
        if (capture_id in resource_create_allocation) {
            allocation_id = resource_create_allocation[capture_id]
            allocation_resource[allocation_id] = return_value
            command_resource_allocation[return_value] = allocation_id
        }
        resource_create_returns++
    }
    if (name == "resource-gpu-address") {
        if (!(entry_storage in created_resources))
            fail("gpu-va-result-without-apple-resource")
        resource_gpu_va[entry_storage] = return_value
        if (capture_id in gpu_va_query_allocation) {
            allocation_id = gpu_va_query_allocation[capture_id]
            if (return_value == "0x0000000000000000")
                fail("command-resource-has-no-gpu-va")
            allocation_gpu_va[allocation_id] = return_value
        }
        gpu_va_returns++
    }
    if (name == "resource-pool-create-pooled-resource") {
        if (!(capture_id in resource_pool_call_allocation) ||
            return_value == "0x0000000000000000")
            fail("invalid-apple-resource-pool-return")
        allocation_id = resource_pool_call_allocation[capture_id]
        allocation_pooled_resource[allocation_id] = return_value
        resource_pool_returns++
    }
    if (name == "alloc-resource-at-index") {
        if (capture_id != active_allocation ||
            return_value != "0x0000000000000000" ||
            entry_storage != allocation_storage[capture_id] ||
            return_x1 == "0x0000000000000000")
            fail("incomplete-command-resource-allocation")
        if (allocation_resource_pool_call[capture_id] == "" ||
            allocation_pooled_resource[capture_id] == "")
            fail("missing-carrier-resource-pool-result")
        if (allocation_resource[capture_id] != "") {
            if (allocation_gpu_va[capture_id] == "")
                fail("materialized-command-resource-has-no-gpu-va")
            allocation_materialized[capture_id] = 1
            materialized_allocation_count++
        } else {
            reused_allocation_count++
        }
        allocation_result_mode[capture_id] = return_x1
        ready_allocation = capture_id
        active_allocation = ""
        completed_allocation_count++
    }
    delete pending_returns[capture_id]
    returns[name]++
    return_events++
}
END {
    if (failed)
        exit 1
    if (events == 0)
        fail("no-procedural-winsys-calls")
    if (calls["begin-kernel-commands"] == 0 ||
        calls["begin-segment"] == 0 || calls["end-segment"] == 0 ||
        storage_identity == "")
        fail("incomplete-command-storage-lifecycle")
    if (calls["begin-segment"] != calls["end-segment"] ||
        calls["begin-kernel-commands"] < calls["begin-segment"])
        fail("unbalanced-command-storage-lifecycle")
    if (command_buffer_segment_begins != correlated_command_buffer_segments ||
        pending_command_buffer_segment != "")
        fail("incomplete-command-buffer-segment-lifecycle")
    if (segment_kernel_pointer_contracts != calls["begin-segment"])
        fail("incomplete-segment-kernel-pointer-contract")
    if (calls["alloc-resource-at-index"] == 0 ||
        calls["resource-list-add-resource"] == 0 || resource_list == "" ||
        resource_list == storage_identity || !(resource_list in resource_resets))
        fail("missing-resource-residency-work")
    if (allocation_count == 0 || completed_allocation_count != allocation_count ||
        active_allocation != "" || ready_allocation != "" ||
        correlated_resource_bindings != allocation_count ||
        materialized_allocation_count == 0 ||
        materialized_resource_bindings != materialized_allocation_count ||
        reused_resource_bindings != reused_allocation_count ||
        (require_reused_bindings == 1 && reused_allocation_count == 0) ||
        resource_create_returns == 0) {
        print "AGX private winsys resource lifecycle: allocations=" allocation_count \
              " completed=" completed_allocation_count \
              " correlated=" correlated_resource_bindings \
              " materialized=" materialized_allocation_count \
              " materialized_bindings=" materialized_resource_bindings \
              " reused=" reused_allocation_count \
              " reused_bindings=" reused_resource_bindings \
              " creates=" resource_create_returns > "/dev/stderr"
        fail("incomplete-apple-resource-binding-lifecycle")
    }
    if (resource_pool_returns != allocation_count)
        fail("incomplete-resource-pool-materialization")
    if (storage_create_returns == 0 || !(storage_identity in created_storages))
        fail("carrier-handoff-missing")
    if (storage_pool_create_returns == 0 ||
        !(storage_identity in pool_created_storages) ||
        command_buffer_init_returns == 0)
        fail("carrier-initializer-handoff-missing")
    for (storage_value in observed_storages) {
        if (!(storage_value in created_storages))
            fail("unconstructed-storage-used")
    }
    if (queue_submits != expected_submissions || traps != queue_submits)
        fail("incomplete-queue-trap4-handoff")
    if (fill_count != queue_submits)
        fail("incomplete-apple-command-buffer-handoff")
    if (return_calls == 0 || return_events != return_calls)
        fail("incomplete-private-winsys-returns")
    for (capture_id in pending_returns)
        fail("unmatched-private-winsys-return")
    if (completion_markers != 1)
        fail("missing-or-ambiguous-public-workload-completion")
    if (modern_submission_count != queue_submits ||
        modern_completion_count != modern_submission_count * 2)
        fail("incomplete-observed-completion-retirement")
    for (submission_id = 1; submission_id <= modern_submission_count;
         ++submission_id) {
        if (submission_completion_count[submission_id] != 2)
            fail("submission-did-not-retire-both-observed-tokens")
    }
    for (resource in command_resource_allocation) {
        materialized_command_resources++
        if (!(resource in released_command_resources))
            fail("materialized-command-resource-not-released")
        released_command_resource_count++
    }
    if (materialized_command_resources != materialized_allocation_count ||
        released_command_resource_count != materialized_command_resources)
        fail("incomplete-command-resource-retirement")
    for (descriptor in descriptor_addresses)
        descriptor_count++
    print "AO46_AGX_PRIVATE_WINSYS_TRACE verified calls=" events \
          " begin_kernel=" calls["begin-kernel-commands"] \
          " begin_segment=" calls["begin-segment"] \
          " end_segment=" calls["end-segment"] \
          " resource_entries=" calls["alloc-resource-at-index"] \
          " resource_list_adds=" calls["resource-list-add-resource"] \
          " apple_resources=" resource_create_returns \
          " gpu_va_queries=" gpu_va_returns \
          " materialized_command_resources=" materialized_command_resources \
          " released_after_completion=" released_command_resource_count \
          " resource_release_calls=" (resource_release_calls + 0) \
          " completion_pair_submissions=" modern_submission_count \
          " observed_completions=" modern_completion_count \
          " serial_completion_token_reuse=" (serial_completion_token_reuse + 0) \
          " materialized_binding_records=" (materialized_resource_bindings + 0) \
          " reused_binding_records=" (reused_resource_bindings + 0) \
          " inherited_resource_bindings=" (inherited_resource_bindings + 0) \
          " storage_create_return_samples=" returns["command-storage-create"] \
          " storage_pool_create_return_samples=" returns["storage-pool-create"] \
          " command_buffer_init_return_samples=" returns["command-buffer-init"] \
          " begin_kernel_return_samples=" returns["begin-kernel-commands"] \
          " begin_segment_return_samples=" returns["begin-segment"] \
          " command_buffer_segment_begins=" (command_buffer_segment_begins + 0) \
          " direct_storage_segment_begins=" direct_storage_segment_begins \
          " segment_kernel_pointer_contracts=" segment_kernel_pointer_contracts \
          " resource_entry_return_samples=" returns["alloc-resource-at-index"] \
          " resource_pool_return_samples=" returns["resource-pool-create-pooled-resource"] \
          " reused_slot_snapshots=" (reused_slot_snapshots + 0) \
          " distinct_storage_and_resource_list=1" \
          " carrier_handoff=1 resource_list_reset=" resource_resets[resource_list] \
          " queue_submits=" queue_submits " trap4=" traps \
          " expected_submits=" expected_submissions \
          " apple_command_buffer_fills=" fill_count \
          " fill_descriptor_identity=1" \
          " generic_object_array=null" \
          " descriptor_addresses=" descriptor_count \
          " serial_descriptor_reuse=" (descriptor_count < queue_submits ? 1 : 0) \
          " residency_finalize=" (calls["finalize-residency-set-list"] + 0) \
          " residency_merge=" (calls["merge-residency-set-list"] + 0) \
          " resource_group_updates=" (calls["resource-group-update"] + 0)
}
' "$trace_log"
