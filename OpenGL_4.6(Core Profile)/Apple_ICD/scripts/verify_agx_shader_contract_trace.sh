#!/bin/sh
set -eu

if [ "$#" -ne 1 ]; then
    echo "usage: $0 TRACE_LOG" >&2
    exit 2
fi

trace_log=$1
if [ ! -f "$trace_log" ]; then
    echo "missing AGX shader-contract trace: $trace_log" >&2
    exit 2
fi

# A zero constructor count is a valid result: it proves this workload reached
# a different internal owner. Do not turn it into a guessed contract.
LC_ALL=C awk '
function fail(message) {
    print "AGX shader-contract verification failed: " message > "/dev/stderr"
    exit 1
}
function field(line, name, value) {
    value = line
    sub(".*" name, "", value)
    sub(" .*$", "", value)
    return value
}
{ sub(/\r$/, "") }
/^AO46_AGX_SHADER_EXECUTION complete result=0x6a46/ { complete = 1 }
/AO46_AGX_SHADER_EXECUTION source-compile-begin$/ { phase = "compile"; next }
/AO46_AGX_SHADER_EXECUTION source-compile-ready$/ { phase = "function"; next }
/AO46_AGX_SHADER_EXECUTION workload=/ {
    workload = field($0, "workload=")
    next
}
/AO46_AGX_SHADER_EXECUTION paired-phase=/ {
    label = field($0, "paired-phase=")
    if (label == "")
        fail("paired workload phase marker was incomplete")
    paired_phase[label]++
    next
}
/AO46_AGX_SHADER_EXECUTION function-ready$/ { phase = "queue"; next }
/AO46_AGX_SHADER_EXECUTION queue-create-ready$/ { phase = "pipeline"; next }
/AO46_AGX_SHADER_EXECUTION pipeline-create-ready$/ { phase = "buffer"; next }
/AO46_AGX_SHADER_EXECUTION buffer-create-ready$/ { phase = "command"; next }
/AO46_AGX_SHADER_EXECUTION command-buffer-create-ready$/ { phase = "encoder"; next }
/AO46_AGX_SHADER_EXECUTION encoder-create-ready$/ { phase = "pipeline-bind"; next }
/AO46_AGX_SHADER_EXECUTION pipeline-bind-ready$/ { phase = "resource-bind"; next }
/AO46_AGX_SHADER_EXECUTION resource-bind-ready$/ { phase = "dispatch"; next }
/AO46_AGX_SHADER_EXECUTION dispatch-ready$/ { phase = "commit"; next }
/AO46_AGX_SHADER_EXECUTION commit-ready$/ { phase = "completion"; next }
/AO46_AGX_SHADER_CONTRACT_STATIC_INSTALL / {
    kind = field($0, "kind=")
    if (kind == "" || field($0, "address=") == "0x0000000000000000")
        fail("static probe did not resolve a code address")
    static_installs[kind]++
    next
}
/AO46_AGX_SHADER_CONTRACT_CALL / {
    kind = field($0, "kind=")
    if (kind == "") fail("constructor call without a kind")
    calls[kind]++
    phase_calls[phase SUBSEP kind]++
    next
}
/AO46_AGX_SHADER_CONTRACT_RETURN / {
    kind = field($0, "kind=")
    result = field($0, "result=")
    if (kind == "unknown" || result == "0x0000000000000000")
        fail("invalid static shader-factory return")
    returns[kind]++
    next
}
/AO46_AGX_SHADER_PLACEMENT / {
    kind = field($0, "kind=")
    if (kind == "pinned-location" && field($0, "pinned_location=") != "0x0000000000000000")
        nondefault_placement++
    if (kind == "pinned-address" && field($0, "pinned_address=") != "0x0000000000000000")
        fixed_address_placement++
    next
}
/AO46_AGX_SHADER_RESOURCE_CONSTRUCTOR / {
    kind = field($0, "kind=")
    if (kind == "") fail("resource constructor without a kind")
    resource_constructor_calls[kind]++
    resource_constructor_phases[phase SUBSEP kind]++
    next
}
/AO46_AGX_SHADER_EXECUTION_CALL / {
    kind = field($0, "kind=")
    if (kind == "") fail("execution call without a kind")
    execution_calls[kind]++
    execution_phase_calls[phase SUBSEP kind]++
    next
}
/AO46_AGX_SHADER_USC_CALL / {
    kind = field($0, "kind=")
    if (kind == "") fail("USC trace call without a kind")
    usc_calls[kind]++
    usc_phase_calls[phase SUBSEP kind]++
    next
}
/AO46_AGX_SHADER_USC_RETURN / {
    kind = field($0, "kind=")
    descriptor = field($0, "descriptor=")
    bytes = field($0, "descriptor_bytes=")
    if (kind != "usc-spill-descriptor" || descriptor == "0x0000000000000000" ||
        bytes == "unavailable")
        fail("USC descriptor post-return capture was incomplete")
    usc_descriptor_returns++
    next
}
/AO46_AGX_SHADER_VARIANT_CALL / {
    kind = field($0, "kind=")
    if (kind == "compute-program-finalize") {
        if (field($0, "variant=") == "0x0000000000000000" ||
            field($0, "variant_bytes=") == "unavailable")
            fail("variant-finalize capture was incomplete")
        variant_finalizations++
    } else if (kind == "compute-program-constructor") {
        if (field($0, "variant=") == "0x0000000000000000" ||
            field($0, "device=") == "0x0000000000000000" ||
            field($0, "reply=") == "0x0000000000000000")
            fail("compute-program constructor capture was incomplete")
        profile_flag = field($0, "profile_flag=")
        if (profile_flag == "0x0000000000000000")
            zero_profile_flags++
        else if (profile_flag == "0x0000000000000001") {
            enabled_profile_flags++
        } else
            unexpected_profile_flags++
        variant_constructors++
    } else {
        fail("unknown program-variant capture")
    }
    next
}
/AO46_AGX_SHADER_VARIANT_RETURN / {
    kind = field($0, "kind=")
    if (kind == "compute-program-finalize") {
        if (field($0, "variant=") == "0x0000000000000000" ||
            field($0, "variant_bytes=") == "unavailable")
            fail("variant-finalize post-return capture was incomplete")
        variant_finalize_returns++
    } else if (kind == "compute-program-constructor") {
        if (field($0, "variant=") == "0x0000000000000000")
            fail("compute-program constructor post-return capture was incomplete")
        variant_constructor_returns++
    } else {
        fail("unknown program-variant post-return capture")
    }
    next
}
/AO46_AGX_SHADER_EXEC_ALLOCATION_CALL / {
    if (field($0, "kind=") != "heap-true-allocate" ||
        field($0, "allocation=") == "0x0000000000000000" ||
        field($0, "heap=") == "0x0000000000000000" ||
        field($0, "requested_bytes=") == "0x0000000000000000")
        fail("Apple heap allocation capture was incomplete")
    heap_true_allocations++
    next
}
/AO46_AGX_SHADER_EXEC_ALLOCATION_RETURN / {
    if (field($0, "kind=") != "heap-true-allocate" ||
        field($0, "allocation=") == "0x0000000000000000" ||
        field($0, "allocation_bytes=") == "unavailable")
        fail("Apple heap allocation post-return capture was incomplete")
    heap_record = field($0, "heap_record=")
    apple_resource = field($0, "apple_resource=")
    if (field($0, "selected_base=") != "0x0000000000000000") {
        if (heap_record == "0x0000000000000000" ||
            apple_resource == "0x0000000000000000")
            fail("enabled heap allocation did not retain its record and Apple resource")
        enabled_heap_records[heap_record]++
        enabled_heap_apple_resources[apple_resource]++
    }
    heap_true_allocation_returns++
    next
}
/AO46_AGX_SHADER_CODE_HEAP_CALL / {
    kind = field($0, "kind=")
    library = field($0, "library=")
    if ((kind != "allocate" && kind != "release") ||
        library == "0x0000000000000000" ||
        field($0, "return_hook=") != "1")
        fail("code-heap lifecycle call capture was incomplete")
    code_heap_calls[kind]++
    next
}
/AO46_AGX_SHADER_CODE_HEAP_RETURN / {
    kind = field($0, "kind=")
    library = field($0, "library=")
    if ((kind != "allocate" && kind != "release") ||
        library == "0x0000000000000000")
        fail("code-heap lifecycle return capture was incomplete")
    code_heap_returns[kind]++
    if (kind == "allocate" &&
        (field($0, "allocation_present=") != "1" ||
         field($0, "code_address_present=") != "1"))
        fail("code-heap allocation did not publish its residency state")
    if (kind == "release" &&
        (field($0, "allocation_present=") != "0" ||
         field($0, "code_address_present=") != "0"))
        fail("code-heap release did not clear its residency state")
    next
}
/AO46_AGX_SHADER_CODE_LINK_INFO / {
    if (field($0, "kind=") != "initialize" ||
        field($0, "link_info=") == "0x0000000000000000" ||
        field($0, "compiler_reply=") == "0x0000000000000000" ||
        field($0, "device=") == "0x0000000000000000")
        fail("code LinkInfo initialization capture was incomplete")
    initialized_link_info[field($0, "link_info=")]++
    code_link_initializations++
    next
}
/AO46_AGX_SHADER_CODE_HEAP_RELOCATIONS / {
    link_info = field($0, "link_info=")
    if (link_info == "0x0000000000000000" ||
        field($0, "published_code_address=") == "0x0000000000000000" ||
        !initialized_link_info[link_info])
        fail("code-heap relocation capture was incomplete")
    if (field($0, "fixed_base=") == "1")
        fixed_base_relocations++
    code_heap_relocations++
    next
}
/AO46_AGX_SHADER_VARIANT_TEARDOWN / {
    if (field($0, "kind=") != "compute-program-base-destructor" ||
        field($0, "variant=") == "0x0000000000000000" ||
        field($0, "link_info_initialized=") != "1" ||
        field($0, "compiler_reply=") == "0x0000000000000000")
        fail("compute-program teardown did not retain its LinkInfo provenance")
    variant_teardowns++
    if (field($0, "selected_base=") != "0x0000000000000000")
        enabled_variant_teardowns++
    next
}
/AO46_IOGPU_OWNERSHIP_SYMBOLIC_INSTALL / {
    kind = field($0, "kind=")
    if (kind == "" || field($0, "breakpoint=") == "0")
        fail("IOGPU ownership probe was not installed")
    iogpu_symbolic_installs[kind]++
    next
}
/AO46_IOGPU_OWNERSHIP_SYMBOLIC_RESOLUTION / {
    kind = field($0, "kind=")
    if (kind == "" || field($0, "locations=") == "0")
        fail("IOGPU ownership probe did not resolve after IOGPU loaded")
    iogpu_symbolic_resolutions[kind]++
    next
}
/AO46_AGX_STARTUP_SYMBOLIC_INSTALL / {
    kind = field($0, "kind=")
    if (kind == "" || field($0, "breakpoint=") == "0")
        fail("AGX startup ownership probe was not installed")
    agx_startup_symbolic_installs[kind]++
    next
}
/AO46_AGX_STARTUP_SYMBOLIC_RESOLUTION / {
    kind = field($0, "kind=")
    if (kind == "" || field($0, "locations=") == "0")
        fail("AGX startup ownership probe did not resolve after AGX loaded")
    agx_startup_symbolic_resolutions[kind]++
    next
}
/AO46_AGX_STARTUP_CALL / {
    kind = field($0, "kind=")
    device = field($0, "device=")
    if (kind != "device-initialize" || device == "0x0000000000000000")
        fail("AGX startup ownership capture was incomplete")
    agx_startup_calls[kind]++
    agx_startup_devices[device]++
    next
}
/AO46_AGX_USC_PROBE_INSTALL / {
    kind = field($0, "kind=")
    if (kind == "" || field($0, "address=") == "0x0000000000000000")
        fail("USC startup probe did not resolve a code address")
    usc_probe_installs[kind]++
    next
}
/AO46_AGX_USC_STARTUP / {
    kind = field($0, "kind=")
    sequence = field($0, "sequence=") + 0
    if (kind == "" || !sequence)
        fail("USC startup event was incomplete")
    usc_startup_events[kind]++
    if (!usc_startup_first_sequence[kind])
        usc_startup_first_sequence[kind] = sequence
    next
}
/AO46_AGX_USC_AUTHORIZATION_CALL / {
    if (field($0, "selector=") != "0x107" ||
        field($0, "connection=") == "0x0000000000000000" ||
        field($0, "notification_port=") == "0x0000000000000000" ||
        field($0, "return_hook=") != "1" ||
        field($0, "source=") != "profiled-agx-callsite")
        fail("USC async authorization capture was incomplete")
    usc_authorization_calls++
    usc_authorization_call_sequence = field($0, "sequence=") + 0
    next
}
/AO46_AGX_USC_AUTHORIZATION_RETURN / {
    if (field($0, "connection=") == "0x0000000000000000" ||
        field($0, "notification_port=") == "0x0000000000000000")
        fail("USC async authorization return lost its provenance")
    usc_authorization_returns++
    if (field($0, "result=") == "0x0000000000000000")
        usc_authorization_successes++
    next
}
/AO46_IOGPU_OWNERSHIP_CALL / {
    kind = field($0, "kind=")
    if (kind == "resource-initialize") {
        resource = field($0, "resource=")
        if (resource == "0x0000000000000000" ||
            field($0, "device=") == "0x0000000000000000" ||
            field($0, "args=") == "0x0000000000000000" ||
            field($0, "args_size=") == "0x0000000000000000" ||
            field($0, "args_digest=") == "unavailable")
            fail("IOGPU resource initialization capture was incomplete")
        iogpu_initialized_resources[resource]++
        iogpu_resource_args_digests[resource] = field($0, "args_digest=")
        if (field($0, "agx_heap_factory=") == "1")
            agx_heap_resource_initializations++
    } else if (kind == "resource-remote-initialize") {
        resource = field($0, "resource=")
        if (resource == "0x0000000000000000" ||
            field($0, "device=") == "0x0000000000000000" ||
            field($0, "args=") == "0x0000000000000000" ||
            field($0, "args_size=") == "0x0000000000000000" ||
            field($0, "args_digest=") == "unavailable")
            fail("IOGPU remote resource initialization capture was incomplete")
        iogpu_remote_initialized_resources[resource]++
        iogpu_remote_resource_args_digests[resource] = field($0, "args_digest=")
        if (field($0, "agx_heap_factory=") == "1")
            agx_heap_resource_initializations++
    } else if (kind == "resource-pool-initialize") {
        if (field($0, "pool=") == "0x0000000000000000" ||
            field($0, "device=") == "0x0000000000000000" ||
            field($0, "args=") == "0x0000000000000000" ||
            field($0, "args_size=") == "0x0000000000000000" ||
            field($0, "args_digest=") == "unavailable")
            fail("IOGPU resource-pool initialization capture was incomplete")
        iogpu_pool_args_digests[field($0, "args_digest=")]++
        if (field($0, "agx_pool_setup=") == "1") {
            agx_device_pool_initializations++
            agx_pool_owner_devices[field($0, "device=")]++
        }
    } else if (kind == "resource-pool-create") {
        if (field($0, "pool=") == "0x0000000000000000" ||
            field($0, "return_hook=") != "1")
            fail("IOGPU pooled-resource creation capture was incomplete")
    } else if (kind == "pooled-resource-release") {
        if (field($0, "resource=") == "0x0000000000000000")
            fail("IOGPU pooled-resource release capture was incomplete")
    } else {
        fail("unknown IOGPU ownership capture")
    }
    iogpu_ownership_calls[kind]++
    next
}
/AO46_IOGPU_OWNERSHIP_RETURN / {
    if (field($0, "kind=") != "resource-pool-create" ||
        field($0, "pool=") == "0x0000000000000000" ||
        field($0, "resource=") == "0x0000000000000000")
        fail("IOGPU pooled-resource creation return was incomplete")
    iogpu_pool_create_returns++
    next
}
/AO46_AGX_SHADER_VARIANT_RESIDENCY / {
    if (field($0, "kind=") != "first-heap-selection" ||
        field($0, "variant=") == "0x0000000000000000" ||
        field($0, "heap=") == "0x0000000000000000" ||
        field($0, "resource_list=") == "0x0000000000000000")
        fail("compute-program residency selection capture was incomplete")
    variant_heap_selections++
    if (field($0, "selected_base=") == "0x0000000000000000")
        zero_base_selections++
    else {
        nonzero_base_selections++
        if (field($0, "device=") == "0x0000000000000000" ||
            field($0, "device_heap_offset=") != "0x1b08")
            fail("enabled variant did not select the G16X device code heap")
    }
    next
}
/AO46_AGX_SHADER_VARIANT_USE / {
    kind = field($0, "kind=")
    if (kind != "compute-direct-tg-size" ||
        field($0, "variant=") == "0x0000000000000000")
        fail("variant USC-consumer capture was incomplete")
    variant_usc_uses++
    next
}
/AO46_AGX_SHADER_RESOURCE_BIND_CALL / {
    kind = field($0, "kind=")
    resource = field($0, "resource=")
    bytes = field($0, "resource_record_bytes=")
    if (kind != "bind-buffer-resource-to-command" ||
        resource == "0x0000000000000000" || bytes == "unavailable")
        fail("command resource binding capture was incomplete")
    command_resource_binds++
    next
}
/AO46_AGX_SHADER_COMMAND_CALL / {
    kind = field($0, "kind=")
    if (kind == "new-command") {
        requested_bytes = field($0, "requested_bytes=")
        if (requested_bytes == "0x0000000000000000")
            fail("new-command capture was incomplete")
        command_calls++
    } else if (kind == "end-command") {
        header = field($0, "segment_header=")
        if (header == "0x0000000000000000")
            fail("end-command did not recover its segment header")
        end_command_calls++
    } else {
        fail("unknown command lifecycle call")
    }
    next
}
/AO46_AGX_SHADER_COMMAND_RETURN / {
    kind = field($0, "kind=")
    command_record = field($0, "command_record=")
    header = field($0, "segment_header_bytes=")
    record = field($0, "record_bytes=")
    if (kind != "new-command" || command_record == "0x0000000000000000" ||
        header == "unavailable" || record == "unavailable")
        fail("new-command return capture was incomplete")
    command_returns++
    next
}
/AO46_AGX_SHADER_COMMAND_STORAGE_CALL / {
    kind = field($0, "kind=")
    storage = field($0, "storage=")
    header = field($0, "segment_header_bytes=")
    if ((kind != "begin-segment" && kind != "end-segment") ||
        storage == "0x0000000000000000" || header == "unavailable")
        fail("command-storage segment capture was incomplete")
    if (kind == "begin-segment") {
        storage_segments++
    } else {
        record = field($0, "record_bytes=")
        if (record == "unavailable")
            fail("command-storage close omitted its command record")
        storage_segment_ends++
    }
    next
}
/AO46_AGX_SHADER_QUEUE_CALL / {
    kind = field($0, "kind=")
    argument_record = field($0, "argument_record=")
    bytes = field($0, "argument_bytes=")
    if (kind != "fill-command-buffer-args" ||
        argument_record == "0x0000000000000000" || bytes == "unavailable")
        fail("queue lowering capture was incomplete")
    queue_lowering_calls++
    next
}
/AO46_AGX_SHADER_QUEUE_RETURN / {
    kind = field($0, "kind=")
    argument_record = field($0, "argument_record=")
    bytes = field($0, "argument_bytes=")
    if (kind != "fill-command-buffer-args" ||
        argument_record == "0x0000000000000000" || bytes == "unavailable")
        fail("queue lowering return capture was incomplete")
    queue_lowering_returns++
    next
}
/AO46_AGX_SHADER_RESOURCE_LIST_CALL / {
    kind = field($0, "kind=")
    if (kind == "") fail("resource-list trace call without a kind")
    resource_list_calls[kind]++
    resource_list_phase_calls[phase SUBSEP kind]++
    next
}
/AO46_AGX_SHADER_RESOURCE_CALL / {
    kind = field($0, "kind=")
    if (kind == "") fail("resource trace call without a kind")
    resource_calls[phase SUBSEP kind]++
    next
}
/AO46_AGX_SHADER_EXECUTION complete result=0x6a46/ { complete = 1 }
END {
    if (!complete) fail("control workload did not complete")
    if (static_installs["compute-program-factory"] != 1 ||
        static_installs["compute-pipeline-init"] != 1 ||
        static_installs["compute-pipeline-bind"] != 1 ||
        static_installs["compute-program-address-table"] != 1 ||
        static_installs["compute-end-encoding"] != 1 ||
        static_installs["compute-append-program-tables"] != 1 ||
        static_installs["compute-set-pipeline-common"] != 1 ||
        static_installs["compute-execute-kernel"] != 1 ||
        static_installs["compute-end-pass"] != 1 ||
        static_installs["usc-spill-buffer"] != 1 ||
        static_installs["compute-pipeline-resources"] != 1 ||
        static_installs["setup-compute-command"] != 1 ||
        static_installs["new-command"] != 1 ||
        static_installs["end-command"] != 1 ||
        static_installs["bind-buffer-resource-to-command"] != 1 ||
        static_installs["compute-program-constructor"] != 1 ||
        static_installs["compute-variant-first-heap-select"] != 1 ||
        static_installs["compute-program-finalize"] != 1 ||
        static_installs["compute-program-base-destructor"] != 1 ||
        static_installs["heap-true-allocate"] != 1 ||
        static_installs["code-heap-allocate"] != 1 ||
        static_installs["code-heap-release"] != 1 ||
        static_installs["code-link-info-initialize"] != 1 ||
        static_installs["code-heap-relocations"] != 1 ||
        static_installs["compute-direct-tg-size"] != 1)
        fail("static shader probes were not installed exactly once")
    if (iogpu_symbolic_installs["resource-initialize"] != 1 ||
        iogpu_symbolic_installs["resource-remote-initialize"] != 1 ||
        iogpu_symbolic_installs["resource-pool-initialize"] != 1 ||
        iogpu_symbolic_installs["resource-pool-create"] != 1 ||
        iogpu_symbolic_installs["pooled-resource-release"] != 1)
        fail("static IOGPU ownership probes were not installed exactly once")
    if (iogpu_symbolic_resolutions["resource-initialize"] != 1 ||
        iogpu_symbolic_resolutions["resource-remote-initialize"] != 1 ||
        iogpu_symbolic_resolutions["resource-pool-initialize"] != 1 ||
        iogpu_symbolic_resolutions["resource-pool-create"] != 1 ||
        iogpu_symbolic_resolutions["pooled-resource-release"] != 1)
        fail("pending IOGPU ownership probes did not resolve after framework load")
    if (agx_startup_symbolic_installs["device-initialize"] != 1 ||
        agx_startup_symbolic_resolutions["device-initialize"] != 1 ||
        !agx_startup_calls["device-initialize"] ||
        agx_device_pool_initializations != 44)
        fail("AGX device startup/pool lifecycle was not fully observed")
    if (usc_probe_installs["heap-config-template"] != 1 ||
        usc_probe_installs["profile-kernel-initialization"] != 1 ||
        usc_probe_installs["profile-global-configuration"] != 1 ||
        usc_probe_installs["async-authorization-callsite"] != 1 ||
        usc_probe_installs["resource-pool-setup"] != 1 ||
        !usc_startup_events["heap-config-template"] ||
        !usc_startup_events["profile-kernel-initialization"] ||
        !usc_startup_events["profile-global-configuration"] ||
        !usc_startup_events["resource-pool-setup"] ||
        !usc_authorization_calls ||
        usc_authorization_returns != usc_authorization_calls ||
        usc_authorization_successes != usc_authorization_calls)
        fail("USC template/configuration lifecycle was not fully observed")
    if (usc_startup_first_sequence["heap-config-template"] >= usc_startup_first_sequence["profile-kernel-initialization"] ||
        usc_startup_first_sequence["profile-kernel-initialization"] >= usc_startup_first_sequence["profile-global-configuration"] ||
        usc_startup_first_sequence["profile-global-configuration"] >= usc_authorization_call_sequence)
        fail("USC template/configuration/authorization order was not preserved")
    if (usc_descriptor_returns != usc_calls["usc-spill-descriptor"])
        fail("USC descriptor call/return capture did not balance")
    if (variant_finalize_returns != variant_finalizations)
        fail("variant finalization call/return capture did not balance")
    if (variant_constructor_returns != variant_constructors)
        fail("variant constructor call/return capture did not balance")
    if (heap_true_allocation_returns != heap_true_allocations)
        fail("Apple heap allocation call/return capture did not balance")
    if (code_heap_calls["allocate"] != code_heap_returns["allocate"] ||
        code_heap_calls["release"] != code_heap_returns["release"])
        fail("code-heap lifecycle capture did not balance")
    if (variant_heap_selections != variant_constructors)
        fail("compute-program residency selection did not cover each constructor")
    if (!command_calls || command_returns != command_calls || !end_command_calls ||
        !storage_segments || storage_segment_ends != storage_segments ||
        !queue_lowering_calls || queue_lowering_returns != queue_lowering_calls)
        fail("command-carrier lifecycle was not fully observed")
    if (workload == "paired" &&
        (command_resource_binds < 9 || paired_phase["warmup"] != 1 ||
         paired_phase["baseline-a"] != 1 || paired_phase["baseline-b"] != 1 ||
         paired_phase["two-buffers-a"] != 1 ||
         paired_phase["two-buffers-b"] != 1 ||
         paired_phase["threadgroup-a"] != 1 ||
         paired_phase["threadgroup-b"] != 1))
        fail("paired workload did not preserve all three controlled submissions")
    if (workload == "two-buffers" && command_resource_binds < 2)
        fail("two-buffer workload did not bind both command resources")
    if (workload == "indirect-command" &&
        (!enabled_profile_flags || !nonzero_base_selections ||
         !code_link_initializations || !code_heap_relocations ||
         !fixed_base_relocations || !variant_teardowns ||
         !enabled_variant_teardowns ||
         !iogpu_ownership_calls["resource-initialize"] ||
         !agx_heap_resource_initializations ||
         !iogpu_ownership_calls["resource-pool-initialize"] ||
         !iogpu_ownership_calls["resource-pool-create"] ||
         !iogpu_pool_create_returns))
        fail("indirect-command workload did not complete direct code relocation")
    for (apple_resource in enabled_heap_apple_resources) {
        if (!iogpu_initialized_resources[apple_resource] &&
            !iogpu_remote_initialized_resources[apple_resource])
            fail("enabled heap Apple resource has no observed initialization lifecycle")
        digest = iogpu_resource_args_digests[apple_resource]
        if (digest == "")
            digest = iogpu_remote_resource_args_digests[apple_resource]
        if (digest == "")
            fail("enabled heap Apple resource has no captured policy digest")
        enabled_heap_resource_digests[digest]++
    }
    for (device in agx_startup_devices) {
        if (!agx_pool_owner_devices[device])
            fail("AGX resource pools were not rooted in the initialized Apple device")
    }
    if (workload != "two-buffers" && workload != "paired" &&
        command_resource_binds < 1)
        fail("single-buffer workload did not bind its command resource")
    printf "AGX_SHADER_CONTRACT_TRACE verified pipeline_factory=%d program_factory=%d program_factory_returns=%d pipeline_init=%d pipeline_init_returns=%d pipeline_bind=%d program_address_table=%d program_address_table_returns=%d end_encoding=%d append_program_tables=%d set_pipeline_common=%d execute_kernel=%d end_pass=%d usc_descriptor_records=%d usc_descriptor_returns=%d usc_template_events=%d usc_kernel_events=%d usc_global_events=%d usc_authorization_calls=%d usc_authorization_returns=%d variant_constructors=%d variant_constructor_returns=%d variant_finalizations=%d variant_finalize_returns=%d zero_profile_flags=%d enabled_profile_flags=%d unexpected_profile_flags=%d heap_true_allocations=%d heap_true_allocation_returns=%d code_heap_allocations=%d code_heap_allocation_returns=%d code_heap_releases=%d code_heap_release_returns=%d code_link_initializations=%d code_heap_relocations=%d fixed_base_relocations=%d variant_teardowns=%d enabled_variant_teardowns=%d iogpu_resource_initializations=%d iogpu_remote_resource_initializations=%d agx_heap_resource_initializations=%d iogpu_resource_pool_initializations=%d iogpu_resource_pool_creates=%d iogpu_resource_pool_create_returns=%d iogpu_pooled_resource_releases=%d variant_heap_selections=%d zero_base_selections=%d nonzero_base_selections=%d variant_usc_uses=%d pipeline_resource_bind=%d setup_compute_command=%d command_calls=%d command_returns=%d end_command_calls=%d storage_segments=%d storage_segment_ends=%d queue_lowering_calls=%d queue_lowering_returns=%d command_resource_binds=%d iogpu_resource_list_add=%d nondefault_pinned_location=%d fixed_pinned_address=%d resource_in_args_basic=%d resource_in_args_tagged=%d pipeline_resource_creates=%d pipeline_gpu_va_queries=%d pinned_location=%d pinned_address=%d address_ranges=%d command_allocator=%d pipeline_phase_program_factory=%d pipeline_phase_set_pipeline_common=%d dispatch_phase_execute_kernel=%d commit_phase_end_pass=%d commit_phase_usc_spill=%d dispatch_phase_pipeline_resource_bind=%d encoder_phase_setup_command=%d dispatch_phase_resource_list_add=%d commit_phase_resource_list_add=%d pipeline_phase_pinned_location=%d pipeline_phase_pinned_address=%d encoder_phase_pinned_location=%d encoder_phase_pinned_address=%d usc_window=%s executable=unproven\n", \
        calls["compute-pipeline-factory"] + 0, \
        calls["compute-program-factory"] + 0, returns["compute-program-factory"] + 0, \
        calls["compute-pipeline-init"] + 0, returns["compute-pipeline-init"] + 0, \
        calls["compute-pipeline-bind"] + 0, \
        calls["compute-program-address-table"] + 0, returns["compute-program-address-table"] + 0, \
        calls["compute-end-encoding"] + 0, calls["compute-append-program-tables"] + 0, \
        execution_calls["compute-set-pipeline-common"] + 0, \
        execution_calls["compute-execute-kernel"] + 0, \
        execution_calls["compute-end-pass"] + 0, \
        usc_calls["usc-spill-descriptor"] + 0, \
        usc_descriptor_returns + 0, \
        usc_startup_events["heap-config-template"] + 0, \
        usc_startup_events["profile-kernel-initialization"] + 0, \
        usc_startup_events["profile-global-configuration"] + 0, \
        usc_authorization_calls + 0, usc_authorization_returns + 0, \
        variant_constructors + 0, variant_constructor_returns + 0, \
        variant_finalizations + 0, variant_finalize_returns + 0, \
        zero_profile_flags + 0, enabled_profile_flags + 0, \
        unexpected_profile_flags + 0, \
        heap_true_allocations + 0, heap_true_allocation_returns + 0, \
        code_heap_calls["allocate"] + 0, code_heap_returns["allocate"] + 0, \
        code_heap_calls["release"] + 0, code_heap_returns["release"] + 0, \
        code_link_initializations + 0, \
        code_heap_relocations + 0, \
        fixed_base_relocations + 0, \
        variant_teardowns + 0, enabled_variant_teardowns + 0, \
        iogpu_ownership_calls["resource-initialize"] + 0, \
        iogpu_ownership_calls["resource-remote-initialize"] + 0, \
        agx_heap_resource_initializations + 0, \
        iogpu_ownership_calls["resource-pool-initialize"] + 0, \
        iogpu_ownership_calls["resource-pool-create"] + 0, \
        iogpu_pool_create_returns + 0, \
        iogpu_ownership_calls["pooled-resource-release"] + 0, \
        variant_heap_selections + 0, zero_base_selections + 0, \
        nonzero_base_selections + 0, \
        variant_usc_uses + 0, \
        usc_calls["compute-pipeline-resources"] + 0, \
        usc_calls["setup-compute-command"] + 0, \
        command_calls + 0, command_returns + 0, end_command_calls + 0, \
        storage_segments + 0, storage_segment_ends + 0, queue_lowering_calls + 0, \
        queue_lowering_returns + 0, \
        command_resource_binds + 0, \
        resource_list_calls["iogpu-resource-list-add"] + 0, \
        nondefault_placement + 0, fixed_address_placement + 0, \
        resource_constructor_calls["resource-in-args-basic"] + 0, \
        resource_constructor_calls["resource-in-args-tagged"] + 0, \
        resource_calls["pipeline" SUBSEP "resource-create"] + 0, \
        resource_calls["pipeline" SUBSEP "resource-gpu-address"] + 0, \
        calls["buffer-pinned-location"] + 0, calls["buffer-pinned-address"] + 0, \
        calls["buffer-address-ranges"] + 0, \
        calls["command-allocator-factory"] + 0, \
        phase_calls["pipeline" SUBSEP "compute-program-factory"] + 0, \
        execution_phase_calls["pipeline-bind" SUBSEP "compute-set-pipeline-common"] + 0, \
        execution_phase_calls["dispatch" SUBSEP "compute-execute-kernel"] + 0, \
        execution_phase_calls["commit" SUBSEP "compute-end-pass"] + 0, \
        usc_phase_calls["commit" SUBSEP "usc-spill-buffer"] + 0, \
        usc_phase_calls["dispatch" SUBSEP "compute-pipeline-resources"] + 0, \
        usc_phase_calls["encoder" SUBSEP "setup-compute-command"] + 0, \
        resource_list_phase_calls["dispatch" SUBSEP "iogpu-resource-list-add"] + 0, \
        resource_list_phase_calls["commit" SUBSEP "iogpu-resource-list-add"] + 0, \
        phase_calls["pipeline" SUBSEP "buffer-pinned-location"] + 0, \
        phase_calls["pipeline" SUBSEP "buffer-pinned-address"] + 0, \
        phase_calls["encoder" SUBSEP "buffer-pinned-location"] + 0, \
        phase_calls["encoder" SUBSEP "buffer-pinned-address"] + 0, \
        nonzero_base_selections ? "observed" : "unobserved"
}
' "$trace_log"
