#!/bin/sh
set -eu

# Observe Apple-created objects during one public compute dispatch. This tool
# never invokes a private selector or copies private object state into AO46.
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
project_root=$(CDPATH= cd -- "$script_dir/.." && pwd)
mesa_root=${OPENGLKHR_MESA_ROOT:-"$project_root/../mesa"}
mesa_build_dir=${OPENGLKHR_MESA_BUILD_DIR:-"$mesa_root/build-ao46-asahi-arm64"}
trace_binary="$mesa_build_dir/src/asahi/lib/asahi_macos_shader_execution_trace"
trace_wrapper="$mesa_build_dir/src/asahi/lib/libwrap.dylib"
capture_module="$script_dir/agx_shader_contract_capture.py"
verifier="$script_dir/verify_agx_shader_contract_trace.sh"
output=${AGX_SHADER_CONTRACT_TRACE_OUTPUT:-"${TMPDIR:-/private/tmp}/ao46-agx-shader-contract-trace.log"}
workload=${AGX_SHADER_CONTRACT_WORKLOAD:-baseline}
sidecar_capture=${AGX_SHADER_CONTRACT_CAPTURE_SIDECAR:-0}
signpost_capture=${AGX_SHADER_CONTRACT_ENABLE_SIGNPOSTS:-0}
# The active profiled M4 Pro backend is G16X. Other devices must supply their
# exact loaded bundle through AGX_SHADER_CONTRACT_BUNDLE; offsets never cross
# an AGX-family boundary.
agx_bundle=${AGX_SHADER_CONTRACT_BUNDLE:-/System/Library/Extensions/AGXMetalG16X.bundle/Contents/MacOS/AGXMetalG16X}

PATH="/opt/homebrew/opt/llvm/bin:/opt/homebrew/opt/bison/bin:/opt/homebrew/opt/flex/bin:/usr/local/opt/llvm/bin:/usr/local/opt/bison/bin:/usr/local/opt/flex/bin:$PATH"
PKG_CONFIG_PATH="${OPENGLKHR_PKG_CONFIG_PATH:-/private/tmp/mesa-asahi-prefix/lib/pkgconfig:/opt/homebrew/share/pkgconfig:/opt/homebrew/lib/pkgconfig}${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
export PATH PKG_CONFIG_PATH

case "$workload" in
    baseline|threadgroup|two-buffers|usc-stress|indirect-command|paired) ;;
    *)
        echo "unsupported AGX shader-contract workload: $workload" >&2
        exit 2
        ;;
esac

case "$sidecar_capture" in
    0|1) ;;
    *)
        echo "AGX shader-contract sidecar capture must be 0 or 1" >&2
        exit 2
        ;;
esac

case "$signpost_capture" in
    0|1) ;;
    *)
        echo "AGX shader-contract signpost capture must be 0 or 1" >&2
        exit 2
        ;;
esac

if [ "$workload" = paired ] && [ "$sidecar_capture" = 1 ] &&
   { [ ! -x "$script_dir/analyze_agx_sidecar_paired_delta.sh" ] ||
     [ ! -x "$script_dir/analyze_agx_shader_residency_trace.sh" ]; }; then
    echo "missing AGX paired-capture analyzers" >&2
    exit 1
fi

if [ "$workload" = indirect-command ] &&
   { [ ! -x "$script_dir/analyze_agx_shader_residency_trace.sh" ] ||
     [ ! -x "$script_dir/analyze_agx_compiler_heap_trace.sh" ]; }; then
    echo "missing AGX shader-residency analyzer" >&2
    exit 1
fi

sidecar_environment=
if [ "$sidecar_capture" = 1 ]; then
    sidecar_environment="'AGX_TRACE_TRAP_AUX=1' 'AGX_TRACE_AUX_ANALYSIS=1' 'AGX_TRACE_AUX_EXTENDED=1' 'AGX_TRACE_AUX_EXTENDED_HEX=1' 'AGX_TRACE_AUX_POINTERS=1' 'AGX_TRACE_AUX_POINTER_HEX=1' 'AGX_TRACE_RESOURCE_REFS=1'"
fi

signpost_environment=
if [ "$signpost_capture" = 1 ]; then
    # This is a public diagnostics setting. It only asks os_log to enable its
    # normal activity path so Apple may emit the label conversion we observe.
    signpost_environment="'OS_ACTIVITY_MODE=enable'"
fi

ninja -C "$mesa_build_dir" src/asahi/lib/asahi_macos_shader_execution_trace src/asahi/lib/libwrap.dylib

compute_program_factory=$(nm -arch arm64e -nm "$agx_bundle" 2>/dev/null |
    awk '/createComputeProgramVariant/ && $NF !~ /_block_invoke/ { print $1; exit }')
compute_pipeline_init=$(nm -arch arm64e -nm "$agx_bundle" 2>/dev/null |
    awk '/\-\[AGXG[[:alnum:]]+FamilyComputePipeline initWithDevice:pipelineStateDescriptor:\]/ { print $1; exit }')
compute_pipeline_bind=$(nm -arch arm64e -nm "$agx_bundle" 2>/dev/null |
    awk '/\-\[AGXG[[:alnum:]]+FamilyComputeContext setComputePipelineState:\]/ { print $1; exit }')
compute_program_table=$(nm -arch arm64e -nm "$agx_bundle" 2>/dev/null |
    awk '/\-\[AGXG[[:alnum:]]+FamilySampledComputeContext endEncodingAndRetrieveProgramAddressTable\]/ { print $1; exit }')
compute_end_encoding=$(nm -arch arm64e -nm "$agx_bundle" 2>/dev/null |
    awk '/\-\[AGXG[[:alnum:]]+FamilyComputeContext endEncoding\]/ { print $1; exit }')
compute_append_tables=$(nm -arch arm64e -nm "$agx_bundle" 2>/dev/null |
    awk '/ComputeContext.*appendProgramAddressTablesEv/ { print $1; exit }')
compute_set_pipeline=$(nm -arch arm64e -nm "$agx_bundle" 2>/dev/null |
    awk '/ComputeContext.*setPipelineCommonEPNS.*ComputePipeline/ { print $1; exit }')
compute_execute_kernel=$(nm -arch arm64e -nm "$agx_bundle" 2>/dev/null |
    awk '/ComputeContext.*executeKernelThreadsInternalE19eAGXDataBufferPools/ { print $1; exit }')
compute_end_pass=$(nm -arch arm64e -nm "$agx_bundle" 2>/dev/null |
    awk '/ComputeContext.*endComputePassEb19eAGXDataBufferPools/ { print $1; exit }')
usc_spill_buffer=$(nm -arch arm64e -nm "$agx_bundle" 2>/dev/null |
    awk '/SpillInfoGen3.*allocateUSCSpillBuffer/ { print $1; exit }')
compute_pipeline_resources=$(nm -arch arm64e -nm "$agx_bundle" 2>/dev/null |
    awk '/ComputePipeline.*bindResourcesEP15MTLResourceListP17IOGPUResourceList/ { print $1; exit }')
setup_compute_command=$(nm -arch arm64e -nm "$agx_bundle" 2>/dev/null |
    awk '/ContextSwitcherGen3.*setupComputeCommand/ { print $1; exit }')
new_command=$(nm -arch arm64e -nm "$agx_bundle" 2>/dev/null |
    awk '/ContextCommon.*newCommandEmb/ { print $1; exit }')
end_command=$(nm -arch arm64e -nm "$agx_bundle" 2>/dev/null |
    awk '/ContextCommon.*endCommandEv/ { print $1; exit }')
bind_buffer_to_command=$(nm -arch arm64e -nm "$agx_bundle" 2>/dev/null |
    awk '/ComputeContext.*bindBufferResourceToCommandEjb/ { print $1; exit }')
compute_variant_finalize=$(nm -arch arm64e -nm "$agx_bundle" 2>/dev/null |
    awk '/ComputeProgramVariant.*finalizeEv/ { print $1; exit }')
compute_variant_destructor=$(nm -arch arm64e -nm "$agx_bundle" 2>/dev/null |
    awk '/__ZN3AGX21ComputeProgramVariantINS_6HAL2008EncodersENS1_7ClassesEED2Ev$/ { print $1; exit }')
compute_variant_constructor=$(nm -arch arm64e -nm "$agx_bundle" 2>/dev/null |
    awk '/ComputeProgramVariant.*C2ERNS.*AGCDeserializedReply/ { print $1; exit }')
# Exact post-CSEL instruction in the profiled G16X constructor. The callback
# only observes which base Apple's constructor selected before heap allocation.
compute_variant_first_heap_select=68dcec
heap_true_allocate=$(nm -arch arm64e -nm "$agx_bundle" 2>/dev/null |
    awk '/HeapILb1EE12allocateImplEmPPK18IOGPUMetalResource$/ { print $1; exit }')
# Entry and return around Apple's allocator signpost helper. The return probe
# records the C string already returned by Apple's resource-label conversion.
heap_resource_signpost=7ec810
# Return PC after Apple's resource-label UTF8String conversion inside the
# profile-specific allocator signpost helper. This records a diagnostic label
# only and never evaluates an Objective-C expression in the target process.
heap_resource_label_return=7ec8a0
code_heap_allocate=$(nm -arch arm64e -nm "$agx_bundle" 2>/dev/null |
    awk '/DynamicLibrary.*16allocateCodeHeapEv$/ { print $1; exit }')
code_heap_release=$(nm -arch arm64e -nm "$agx_bundle" 2>/dev/null |
    awk '/DynamicLibrary.*18deallocateCodeHeapEv$/ { print $1; exit }')
code_link_info_initialize=$(nm -arch arm64e -nm "$agx_bundle" 2>/dev/null |
    awk '/DynamicLoader.*LinkInfo10initializeERK20AGCDeserializedReply/ { print $1; exit }')
code_heap_relocations=$(nm -arch arm64e -nm "$agx_bundle" 2>/dev/null |
    awk '/DynamicLoader.*24applyInternalRelocations/ { print $1; exit }')
compute_direct_tg_size=$(nm -arch arm64e -nm "$agx_bundle" 2>/dev/null |
    awk '/ComputeUSCStateLoader.*directTGSizeOptimization/ { print $1; exit }')
spill_info_ctor=$(nm -arch arm64e -nm "$agx_bundle" 2>/dev/null |
    awk '/SpillInfoGen3.*USCSpillBufferResourceInfo/ && $NF ~ /C2E/ { print $1; exit }')
internal_buffer_grow=$(nm -arch arm64e -nm "$agx_bundle" 2>/dev/null |
    awk '/DeviceInternalBuffer.*DepthRWBounceBufferInfo.*growEj/ { print $1; exit }')
device_setup_buffer_return=$(otool -arch arm64e -tvV "$agx_bundle" 2>/dev/null |
    awk '
        /-\[AGXG16XFamilyDevice initWithAcceleratorPort:simultaneousInstances:\]:/ { in_device_init = 1; next }
        in_device_init && /_objc_msgSend\$initWithDevice:pointer:length:options:sysMemSize:vidMemSize:args:argsSize:deallocator:/ {
            if (getline) { print $1; exit }
        }
    ')
device_setup_buffer_gpu_address_return=$(otool -arch arm64e -tvV "$agx_bundle" 2>/dev/null |
    awk '
        /-\[AGXG16XFamilyDevice initWithAcceleratorPort:simultaneousInstances:\]:/ { in_device_init = 1; next }
        in_device_init && /_objc_msgSend\$initWithDevice:pointer:length:options:sysMemSize:vidMemSize:args:argsSize:deallocator:/ { saw_setup_buffer = 1; next }
        saw_setup_buffer && /_objc_msgSend\$gpuAddress/ {
            if (getline) { print $1; exit }
        }
    ')

if [ ! -x "$trace_binary" ] || [ ! -f "$trace_wrapper" ] ||
   [ ! -f "$capture_module" ] || [ ! -x "$verifier" ] ||
   [ -z "$compute_program_factory" ] || [ -z "$compute_pipeline_init" ] ||
   [ -z "$compute_pipeline_bind" ] || [ -z "$compute_program_table" ] ||
   [ -z "$compute_end_encoding" ] || [ -z "$compute_append_tables" ] ||
   [ -z "$compute_set_pipeline" ] || [ -z "$compute_execute_kernel" ] ||
   [ -z "$compute_end_pass" ] || [ -z "$usc_spill_buffer" ] ||
   [ -z "$compute_pipeline_resources" ] || [ -z "$setup_compute_command" ] ||
   [ -z "$new_command" ] || [ -z "$end_command" ] ||
   [ -z "$bind_buffer_to_command" ] || [ -z "$compute_variant_finalize" ] ||
   [ -z "$compute_variant_destructor" ] ||
   [ -z "$compute_variant_constructor" ] || [ -z "$compute_variant_first_heap_select" ] ||
   [ -z "$heap_true_allocate" ] || [ -z "$code_heap_allocate" ] ||
   [ -z "$code_heap_release" ] || [ -z "$code_link_info_initialize" ] ||
   [ -z "$code_heap_relocations" ] ||
   [ -z "$compute_direct_tg_size" ] || [ -z "$spill_info_ctor" ] ||
   [ -z "$internal_buffer_grow" ] || [ -z "$device_setup_buffer_return" ] ||
   [ -z "$device_setup_buffer_gpu_address_return" ]; then
    echo "missing AGX shader-contract trace tooling" >&2
    exit 1
fi

AGX_SHADER_CONTRACT_BUNDLE_NAME=$(basename "$agx_bundle") \
AGX_SHADER_CONTRACT_PROGRAM_FACTORY_OFFSET="0x$compute_program_factory" \
AGX_SHADER_CONTRACT_PIPELINE_INIT_OFFSET="0x$compute_pipeline_init" \
AGX_SHADER_CONTRACT_PIPELINE_BIND_OFFSET="0x$compute_pipeline_bind" \
AGX_SHADER_CONTRACT_PROGRAM_TABLE_OFFSET="0x$compute_program_table" \
AGX_SHADER_CONTRACT_END_ENCODING_OFFSET="0x$compute_end_encoding" \
AGX_SHADER_CONTRACT_APPEND_TABLES_OFFSET="0x$compute_append_tables" \
AGX_SHADER_CONTRACT_SET_PIPELINE_OFFSET="0x$compute_set_pipeline" \
AGX_SHADER_CONTRACT_EXECUTE_KERNEL_OFFSET="0x$compute_execute_kernel" \
AGX_SHADER_CONTRACT_END_PASS_OFFSET="0x$compute_end_pass" \
AGX_SHADER_CONTRACT_USC_SPILL_OFFSET="0x$usc_spill_buffer" \
AGX_SHADER_CONTRACT_PIPELINE_RESOURCES_OFFSET="0x$compute_pipeline_resources" \
AGX_SHADER_CONTRACT_SETUP_COMMAND_OFFSET="0x$setup_compute_command" \
AGX_SHADER_CONTRACT_NEW_COMMAND_OFFSET="0x$new_command" \
AGX_SHADER_CONTRACT_END_COMMAND_OFFSET="0x$end_command" \
AGX_SHADER_CONTRACT_BIND_BUFFER_OFFSET="0x$bind_buffer_to_command" \
AGX_SHADER_CONTRACT_VARIANT_CONSTRUCTOR_OFFSET="0x$compute_variant_constructor" \
AGX_SHADER_CONTRACT_VARIANT_FIRST_HEAP_SELECT_OFFSET="0x$compute_variant_first_heap_select" \
AGX_SHADER_CONTRACT_VARIANT_FINALIZE_OFFSET="0x$compute_variant_finalize" \
AGX_SHADER_CONTRACT_VARIANT_DESTRUCTOR_OFFSET="0x$compute_variant_destructor" \
AGX_SHADER_CONTRACT_HEAP_TRUE_ALLOCATE_OFFSET="0x$heap_true_allocate" \
AGX_SHADER_CONTRACT_HEAP_RESOURCE_SIGNPOST_OFFSET="0x$heap_resource_signpost" \
AGX_SHADER_CONTRACT_HEAP_RESOURCE_LABEL_RETURN_OFFSET="0x$heap_resource_label_return" \
AGX_SHADER_CONTRACT_CODE_HEAP_ALLOCATE_OFFSET="0x$code_heap_allocate" \
AGX_SHADER_CONTRACT_CODE_HEAP_RELEASE_OFFSET="0x$code_heap_release" \
AGX_SHADER_CONTRACT_CODE_LINK_INFO_INITIALIZE_OFFSET="0x$code_link_info_initialize" \
AGX_SHADER_CONTRACT_CODE_HEAP_RELOCATIONS_OFFSET="0x$code_heap_relocations" \
AGX_SHADER_CONTRACT_DIRECT_TG_SIZE_OFFSET="0x$compute_direct_tg_size" \
AGX_SHADER_CONTRACT_SPILL_INFO_CTOR_OFFSET="0x$spill_info_ctor" \
AGX_SHADER_CONTRACT_INTERNAL_BUFFER_GROW_OFFSET="0x$internal_buffer_grow" \
AGX_SHADER_CONTRACT_DEVICE_SETUP_BUFFER_RETURN_OFFSET="0x$device_setup_buffer_return" \
AGX_SHADER_CONTRACT_DEVICE_SETUP_BUFFER_GPU_ADDRESS_RETURN_OFFSET="0x$device_setup_buffer_gpu_address_return" \
lldb --batch \
    -o "settings set target.env-vars 'DYLD_INSERT_LIBRARIES=$trace_wrapper' 'AGX_TRACE_UNBUFFERED=1' 'AGX_TRACE_CALL_SHAPES=1' 'AGX_TRACE_ALLOCATION_REQUESTS=1' 'AGX_TRACE_SUBMISSION_DETAILS=1' 'AO46_AGX_SHADER_CONTRACT_WORKLOAD=$workload' 'AO46_AGX_SHADER_CONTRACT_PRELOAD_BUNDLE=$agx_bundle' 'AO46_AGX_SHADER_CONTRACT_DEBUG_STOP=1' $sidecar_environment $signpost_environment" \
    -o 'breakpoint set --name "-[AGXBuffer initWithDevice:length:alignment:pointerTag:options:isSuballocDisabled:pinnedGPULocation:]"' \
    -o 'breakpoint set --name "-[AGXBuffer initWithDevice:length:alignment:options:isSuballocDisabled:pinnedGPULocation:]"' \
    -o 'breakpoint set --name "-[AGXBuffer initWithDevice:length:options:isSuballocDisabled:pinnedGPULocation:]"' \
    -o 'breakpoint set --name "-[AGXBuffer initWithDevice:bytes:length:alignment:pointerTag:options:deallocator:pinnedGPUAddress:]"' \
    -o 'breakpoint set --name "-[AGXBuffer initWithDevice:length:alignment:options:pointerTag:pinnedGPUAddress:placementSparsePageSize:]"' \
    -o 'breakpoint set --name "-[AGXBuffer initWithDevice:addressRanges:addressRangeCount:length:alignment:options:pinnedGPUAddress:]"' \
    -o 'breakpoint set --name "-[AGXBuffer initWithDevice:length:alignment:options:isSuballocDisabled:resourceInArgs:pinnedGPULocation:]"' \
    -o 'breakpoint set --name "-[AGXBuffer initWithDevice:length:alignment:pointerTag:options:isSuballocDisabled:resourceInArgs:pinnedGPULocation:]"' \
    -o 'breakpoint set --name "-[AGXBuffer initWithDevice:pointer:length:alignment:options:sysMemSize:gpuAddress:gpuTag:args:argsSize:deallocator:]"' \
    -o 'breakpoint set --name "-[AGXG16XFamilyDevice newComputePipelineStateWithDescriptor:error:]"' \
    -o 'breakpoint set --name "-[AGXG16XFamilyDevice newCommandAllocator]"' \
    -o 'breakpoint set --name IOGPUResourceCreate' \
    -o 'breakpoint set --name IOGPUResourceGetGPUVirtualAddress' \
    -o 'breakpoint set --name IOGPUResourceListAddResource' \
    -o 'breakpoint set --name MTLResourceListAddResource' \
    -o 'breakpoint set --name IOGPUMetalCommandBufferStorageBeginSegment' \
    -o 'breakpoint set --name IOGPUMetalCommandBufferStorageEndSegment' \
    -o 'breakpoint set --name "-[IOGPUMetalCommandBuffer fillCommandBufferArgs:commandQueue:]"' \
    -o 'breakpoint set --name "-[IOGPUMetalBuffer gpuAddress]"' \
    -o "command script import '$capture_module'" \
    -o 'breakpoint command add -F agx_shader_contract_capture.capture_buffer_pinned_location 1' \
    -o 'breakpoint command add -F agx_shader_contract_capture.capture_buffer_pinned_location 2' \
    -o 'breakpoint command add -F agx_shader_contract_capture.capture_buffer_pinned_location 3' \
    -o 'breakpoint command add -F agx_shader_contract_capture.capture_buffer_pinned_address 4' \
    -o 'breakpoint command add -F agx_shader_contract_capture.capture_buffer_pinned_address 5' \
    -o 'breakpoint command add -F agx_shader_contract_capture.capture_buffer_address_ranges 6' \
    -o 'breakpoint command add -F agx_shader_contract_capture.capture_buffer_resource_in_args_basic 7' \
    -o 'breakpoint command add -F agx_shader_contract_capture.capture_buffer_resource_in_args_tagged 8' \
    -o 'breakpoint command add -F agx_shader_contract_capture.capture_buffer_external_storage 9' \
    -o 'breakpoint command add -F agx_shader_contract_capture.capture_compute_pipeline_factory 10' \
    -o 'breakpoint command add -F agx_shader_contract_capture.capture_command_allocator_factory 11' \
    -o 'breakpoint command add -F agx_shader_contract_capture.capture_resource_create 12' \
    -o 'breakpoint command add -F agx_shader_contract_capture.capture_resource_gpu_address 13' \
    -o 'breakpoint command add -F agx_shader_contract_capture.capture_resource_list_add 14' \
    -o 'breakpoint command add -F agx_shader_contract_capture.capture_resource_list_add 15' \
    -o 'breakpoint command add -F agx_shader_contract_capture.capture_command_storage_begin_segment 16' \
    -o 'breakpoint command add -F agx_shader_contract_capture.capture_command_storage_end_segment 17' \
    -o 'breakpoint command add -F agx_shader_contract_capture.capture_fill_command_buffer_args 18' \
    -o 'breakpoint command add -F agx_shader_contract_capture.capture_internal_buffer_gpu_address 19' \
    -o 'script agx_shader_contract_capture.install_iogpu_symbolic_ownership_breakpoints(lldb.debugger, "", lldb.SBCommandReturnObject(), {})' \
    -o 'script agx_shader_contract_capture.install_agx_startup_symbolic_breakpoints(lldb.debugger, "", lldb.SBCommandReturnObject(), {})' \
    -o run \
    -o 'script agx_shader_contract_capture.install_static_breakpoints(lldb.debugger, "", lldb.SBCommandReturnObject(), {})' \
    -o 'script agx_shader_contract_capture.verify_iogpu_symbolic_ownership_breakpoints(lldb.debugger, "", lldb.SBCommandReturnObject(), {})' \
    -o 'script agx_shader_contract_capture.verify_agx_startup_symbolic_breakpoints(lldb.debugger, "", lldb.SBCommandReturnObject(), {})' \
    -o continue \
    -- "$trace_binary" >"$output" 2>&1

if ! grep -q 'exited with status = 0' "$output"; then
    cat "$output" >&2
    echo "AGX shader-contract target did not exit successfully" >&2
    exit 1
fi

"$verifier" "$output"
if [ "$workload" = indirect-command ]; then
    "$script_dir/analyze_agx_shader_residency_trace.sh" "$output"
    "$script_dir/analyze_agx_compiler_heap_trace.sh" "$output"
fi
if [ "$workload" = paired ] && [ "$sidecar_capture" = 1 ]; then
    "$script_dir/analyze_agx_sidecar_paired_delta.sh" "$output"
    "$script_dir/analyze_agx_shader_residency_trace.sh" "$output"
fi
printf 'AO46_AGX_SHADER_CONTRACT_CAPTURE output=%s\n' "$output"
