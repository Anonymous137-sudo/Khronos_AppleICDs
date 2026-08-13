#!/bin/sh
set -eu

# Trace Apple-owned procedural command-storage calls while the existing
# resource-bearing control drives the hardware. AO46 never calls these private
# entry points; LLDB observes their Apple-driven invocation only.
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
project_root=$(CDPATH= cd -- "$script_dir/.." && pwd)
mesa_root=${OPENGLKHR_MESA_ROOT:-"$project_root/../mesa"}
mesa_build_dir=${OPENGLKHR_MESA_BUILD_DIR:-"$mesa_root/build-ao46-asahi-arm64"}
trace_target=${OPENGLKHR_PRIVATE_WINSYS_TRACE_TARGET:-asahi_macos_trace_control}
trace_binary="$mesa_build_dir/src/asahi/lib/$trace_target"
trace_wrapper="$mesa_build_dir/src/asahi/lib/libwrap.dylib"
capture_module="$script_dir/agx_private_winsys_capture.py"
analyzer="$script_dir/analyze_agx_private_winsys_trace.sh"
transport_verifier="$script_dir/verify_agx_uabi_transport_trace.sh"
resource_provenance_verifier="$script_dir/verify_agx_resource_descriptor_provenance.sh"
public_buffer_binding_verifier="$script_dir/verify_agx_public_buffer_binding_trace.sh"
output=${AGX_PRIVATE_WINSYS_TRACE_OUTPUT:-"${TMPDIR:-/private/tmp}/ao46-agx-private-winsys-trace.log"}

case "$trace_target" in
    asahi_macos_trace_control)
        expected_submissions=2
        require_reused_bindings=1
        ;;
    asahi_macos_compute_resource_record_trace|\
    asahi_macos_render_resource_record_trace|\
    asahi_macos_iosurface_drawable_trace)
        expected_submissions=1
        require_reused_bindings=0
        ;;
    asahi_macos_public_buffer_binding_trace)
        expected_submissions=1
        require_reused_bindings=0
        ;;
    *)
        echo "unsupported private winsys trace target: $trace_target" >&2
        exit 2
        ;;
esac

PATH="/opt/homebrew/opt/llvm/bin:/opt/homebrew/opt/bison/bin:/opt/homebrew/opt/flex/bin:/usr/local/opt/llvm/bin:/usr/local/opt/bison/bin:/usr/local/opt/flex/bin:$PATH"
PKG_CONFIG_PATH="${OPENGLKHR_PKG_CONFIG_PATH:-/private/tmp/mesa-asahi-prefix/lib/pkgconfig:/opt/homebrew/share/pkgconfig:/opt/homebrew/lib/pkgconfig}${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
export PATH PKG_CONFIG_PATH

ninja -C "$mesa_build_dir" "src/asahi/lib/$trace_target" src/asahi/lib/libwrap.dylib

if [ ! -x "$trace_binary" ] || [ ! -f "$trace_wrapper" ] ||
   [ ! -f "$capture_module" ] || [ ! -x "$analyzer" ] ||
   [ ! -x "$transport_verifier" ] ||
   [ ! -x "$resource_provenance_verifier" ] ||
   [ ! -x "$public_buffer_binding_verifier" ]; then
    echo "missing private winsys trace target or capture tooling" >&2
    exit 1
fi

# The wrapper observes public descriptor/token transport while LLDB observes
# only Apple-driven private calls. Combining them in one target process gives
# one ordered trace without invoking a private entry point from AO46.
lldb --batch \
    -o "settings set target.env-vars 'DYLD_INSERT_LIBRARIES=$trace_wrapper' 'AGX_TRACE_UNBUFFERED=1' 'AGX_TRACE_CALL_SHAPES=1' 'AGX_TRACE_NOTIFICATION_PORTS=1' 'AGX_TRACE_ALLOCATION_REQUESTS=1' 'AGX_TRACE_SUBMISSION_DETAILS=1' 'AGX_TRACE_RESOURCE_REFS=1' 'AGX_TRACE_TRAP_AUX=1' 'AGX_TRACE_AUX_ANALYSIS=1' 'AGX_TRACE_AUX_EXTENDED=1'" \
    -o 'breakpoint set --name IOGPUMetalCommandBufferStorageBeginKernelCommands' \
    -o 'breakpoint set --name IOGPUMetalCommandBufferStorageBeginSegment' \
    -o 'breakpoint set --name IOGPUMetalCommandBufferStorageGrowKernelCommandBuffer' \
    -o 'breakpoint set --name IOGPUMetalCommandBufferStorageEndKernelCommands' \
    -o 'breakpoint set --name IOGPUMetalCommandBufferStorageEndSegment' \
    -o 'breakpoint set --name IOGPUMetalCommandBufferStorageAllocResourceAtIndex' \
    -o 'breakpoint set --name IOGPUMetalCommandBufferStorageAllocSidebandBuffer' \
    -o 'breakpoint set --name IOGPUMetalCommandBufferStorageGrowSidebandBuffer' \
    -o 'breakpoint set --name IOGPUMetalCommandBufferStorageMergeResidencySetList' \
    -o 'breakpoint set --name IOGPUMetalCommandBufferStorageFinalizeResidencySetList' \
    -o 'breakpoint set --name IOGPUMetalResidencySetListCreate' \
    -o 'breakpoint set --name IOGPUMetalResidencySetListDestroy' \
    -o 'breakpoint set --name IOGPUResourceListAddResource' \
    -o 'breakpoint set --name IOGPUResourceListMerge' \
    -o 'breakpoint set --name IOGPUResourceListMergeLists' \
    -o 'breakpoint set --name IOGPUResourceListReset' \
    -o 'breakpoint set --name IOGPUResourceGroupUpdateResources' \
    -o 'breakpoint set --name IOGPUMetalCommandBufferStorageCreateExt' \
    -o 'breakpoint set --name IOGPUCommandQueueSubmitCommandBuffers' \
    -o 'breakpoint set --name IOConnectTrap4' \
    -o 'breakpoint set --name IOGPUResourceCreate' \
    -o 'breakpoint set --name IOGPUResourceGetGPUVirtualAddress' \
    -o 'breakpoint set --name IOGPUResourceRelease' \
    -o 'breakpoint set --name "-[IOGPUMetalCommandBuffer fillCommandBufferArgs:commandQueue:]"' \
    -o 'breakpoint set --name IOGPUMetalResourcePoolCreatePooledResource' \
    -o 'breakpoint set --name "-[IOGPUMetalCommandBuffer initWithQueue:retainedReferences:synchronousDebugMode:]"' \
    -o 'breakpoint set --name IOGPUMetalCommandBufferStoragePoolCreateStorage' \
    -o 'breakpoint set --name "-[IOGPUMetalCommandBuffer beginSegment:]"' \
    -o "command script import '$capture_module'" \
    -o 'breakpoint command add -F agx_private_winsys_capture.capture_begin_kernel_commands 1' \
    -o 'breakpoint command add -F agx_private_winsys_capture.capture_begin_segment 2' \
    -o 'breakpoint command add -F agx_private_winsys_capture.capture_grow_kernel_command_buffer 3' \
    -o 'breakpoint command add -F agx_private_winsys_capture.capture_end_kernel_commands 4' \
    -o 'breakpoint command add -F agx_private_winsys_capture.capture_end_segment 5' \
    -o 'breakpoint command add -F agx_private_winsys_capture.capture_alloc_resource_at_index 6' \
    -o 'breakpoint command add -F agx_private_winsys_capture.capture_alloc_sideband_buffer 7' \
    -o 'breakpoint command add -F agx_private_winsys_capture.capture_grow_sideband_buffer 8' \
    -o 'breakpoint command add -F agx_private_winsys_capture.capture_merge_residency_set_list 9' \
    -o 'breakpoint command add -F agx_private_winsys_capture.capture_finalize_residency_set_list 10' \
    -o 'breakpoint command add -F agx_private_winsys_capture.capture_residency_set_list_create 11' \
    -o 'breakpoint command add -F agx_private_winsys_capture.capture_residency_set_list_destroy 12' \
    -o 'breakpoint command add -F agx_private_winsys_capture.capture_resource_list_add_resource 13' \
    -o 'breakpoint command add -F agx_private_winsys_capture.capture_resource_list_merge 14' \
    -o 'breakpoint command add -F agx_private_winsys_capture.capture_resource_list_merge_lists 15' \
    -o 'breakpoint command add -F agx_private_winsys_capture.capture_resource_list_reset 16' \
    -o 'breakpoint command add -F agx_private_winsys_capture.capture_resource_group_update 17' \
    -o 'breakpoint command add -F agx_private_winsys_capture.capture_command_storage_create 18' \
    -o 'breakpoint command add -F agx_private_winsys_capture.capture_queue_submit 19' \
    -o 'breakpoint command add -F agx_private_winsys_capture.capture_trap4 20' \
    -o 'breakpoint command add -F agx_private_winsys_capture.capture_resource_create 21' \
    -o 'breakpoint command add -F agx_private_winsys_capture.capture_resource_gpu_address 22' \
    -o 'breakpoint command add -F agx_private_winsys_capture.capture_resource_release 23' \
    -o 'breakpoint command add -F agx_private_winsys_capture.capture_command_buffer_fill 24' \
    -o 'breakpoint command add -F agx_private_winsys_capture.capture_resource_pool_create_pooled_resource 25' \
    -o 'breakpoint command add -F agx_private_winsys_capture.capture_command_buffer_init 26' \
    -o 'breakpoint command add -F agx_private_winsys_capture.capture_storage_pool_create 27' \
    -o 'breakpoint command add -F agx_private_winsys_capture.capture_command_buffer_begin_segment 28' \
    -o run \
    -- "$trace_binary" >"$output" 2>&1

if ! grep -q 'exited with status = 0' "$output"; then
    cat "$output" >&2
    echo "private winsys trace target did not exit successfully" >&2
    exit 1
fi

if [ "$trace_target" = asahi_macos_public_buffer_binding_trace ]; then
    "$public_buffer_binding_verifier" "$output"
else
    AGX_PRIVATE_WINSYS_EXPECTED_SUBMISSIONS="$expected_submissions" \
    AGX_PRIVATE_WINSYS_REQUIRE_REUSED_BINDINGS="$require_reused_bindings" \
        "$analyzer" "$output"
    "$transport_verifier" "$output"
fi
if [ "$trace_target" = asahi_macos_compute_resource_record_trace ]; then
    "$resource_provenance_verifier" "$output"
fi
printf 'AO46_AGX_PRIVATE_WINSYS_CAPTURE output=%s\n' "$output"
