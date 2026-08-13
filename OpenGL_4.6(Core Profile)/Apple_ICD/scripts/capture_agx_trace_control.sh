#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
project_root=$(CDPATH= cd -- "$script_dir/.." && pwd)
mesa_root=${OPENGLKHR_MESA_ROOT:-"$project_root/../mesa"}
mesa_build_dir=${OPENGLKHR_MESA_BUILD_DIR:-"$mesa_root/build-ao46-asahi-arm64"}
trace_target=${OPENGLKHR_TRACE_TARGET:-asahi_macos_trace_control}
case "$trace_target" in
    asahi_macos_trace_control|asahi_macos_shader_allocation_trace|\
    asahi_macos_shader_execution_trace|\
    asahi_macos_resource_record_variation_trace|\
    asahi_macos_resource_record_range_trace|\
    asahi_macos_compute_resource_record_trace|\
    asahi_macos_compute_resource_range_trace|\
    asahi_macos_render_resource_record_trace|\
    asahi_macos_render_resource_lifecycle_trace|\
    asahi_macos_render_descriptor_variation_trace|\
    asahi_macos_iosurface_drawable_trace|\
    asahi_macos_queue_lifecycle_trace|\
    asahi_macos_command_buffer_lifecycle_trace|\
    asahi_macos_command_buffer_pair_lifecycle_trace|\
    asahi_macos_multi_queue_command_buffer_lifecycle_trace|\
    asahi_macos_empty_submission_trace|\
    asahi_macos_two_queue_empty_submission_trace)
        ;;
    *)
        echo "unsupported AGX trace target: $trace_target" >&2
        exit 1
        ;;
esac

trace_notification_ports=${AGX_TRACE_NOTIFICATION_PORTS:-1}
trace_require_extended=${AGX_TRACE_REQUIRE_EXTENDED:-0}
trace_aux_extended=${AGX_TRACE_AUX_EXTENDED:-$trace_require_extended}
trace_require_apple_bridge=${AGX_TRACE_REQUIRE_APPLE_BRIDGE:-0}

case "$trace_require_extended" in
    0|1)
        ;;
    *)
        echo "AGX_TRACE_REQUIRE_EXTENDED must be 0 or 1" >&2
        exit 2
        ;;
esac

case "$trace_aux_extended" in
    0|1)
        ;;
    *)
        echo "AGX_TRACE_AUX_EXTENDED must be 0 or 1" >&2
        exit 2
        ;;
esac

case "$trace_require_apple_bridge" in
    0|1)
        ;;
    *)
        echo "AGX_TRACE_REQUIRE_APPLE_BRIDGE must be 0 or 1" >&2
        exit 2
        ;;
esac

trace_binary="$mesa_build_dir/src/asahi/lib/$trace_target"
trace_wrapper="$mesa_build_dir/src/asahi/lib/libwrap.dylib"
trace_output=${AGX_TRACE_OUTPUT:-"$mesa_build_dir/agx_macos_trace_control.log"}

# Keep Meson regeneration consistent with bootstrap_mesa.sh. A target rebuild
# may rerun configuration and needs the same LLVM and pkg-config discovery.
PATH="/opt/homebrew/opt/llvm/bin:/opt/homebrew/opt/bison/bin:/opt/homebrew/opt/flex/bin:/usr/local/opt/llvm/bin:/usr/local/opt/bison/bin:/usr/local/opt/flex/bin:$PATH"
PKG_CONFIG_PATH="${OPENGLKHR_PKG_CONFIG_PATH:-/private/tmp/mesa-asahi-prefix/lib/pkgconfig:/opt/homebrew/share/pkgconfig:/opt/homebrew/lib/pkgconfig}${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
export PATH PKG_CONFIG_PATH

if [ ! -d "$mesa_build_dir" ]; then
    echo "missing Mesa build directory: $mesa_build_dir" >&2
    exit 1
fi

ninja -C "$mesa_build_dir" \
    "src/asahi/lib/$trace_target" \
    src/asahi/lib/libwrap.dylib

if [ ! -x "$trace_binary" ] || [ ! -f "$trace_wrapper" ]; then
    echo "failed to build AGX trace control or wrapper" >&2
    exit 1
fi

echo "capturing $trace_target AGX trace to $trace_output"
if ! DYLD_INSERT_LIBRARIES="$trace_wrapper${DYLD_INSERT_LIBRARIES:+:$DYLD_INSERT_LIBRARIES}" \
    AGX_TRACE_UNBUFFERED=1 \
    AGX_TRACE_CALL_SHAPES=1 \
    AGX_TRACE_NOTIFICATION_PORTS="$trace_notification_ports" \
    AGX_TRACE_ALLOCATION_REQUESTS=1 \
    AGX_TRACE_SUBMISSION_DETAILS=1 \
    AGX_TRACE_RESOURCE_REFS=1 \
    AGX_TRACE_TRAP_AUX=1 \
    AGX_TRACE_AUX_ANALYSIS=1 \
    AGX_TRACE_AUX_EXTENDED="$trace_aux_extended" \
    AGX_TRACE_TRAP_PAYLOADS="${AGX_TRACE_TRAP_PAYLOADS:-0}" \
    "$trace_binary" >"$trace_output" 2>&1; then
    cat "$trace_output"
    exit 1
fi

verifier=
case "$trace_target" in
    asahi_macos_trace_control)
        verifier="$script_dir/verify_agx_resource_ownership_trace.sh"
        ;;
    asahi_macos_shader_allocation_trace)
        verifier="$script_dir/verify_agx_shader_allocation_trace.sh"
        ;;
    asahi_macos_shader_execution_trace)
        verifier="$script_dir/verify_agx_shader_execution_trace.sh"
        ;;
    asahi_macos_resource_record_variation_trace)
        verifier="$script_dir/verify_agx_resource_record_variation_trace.sh"
        ;;
    asahi_macos_resource_record_range_trace)
        verifier="$script_dir/verify_agx_resource_record_range_trace.sh"
        ;;
    asahi_macos_compute_resource_record_trace)
        verifier="$script_dir/verify_agx_compute_resource_record_trace.sh"
        ;;
    asahi_macos_compute_resource_range_trace)
        verifier="$script_dir/verify_agx_compute_resource_range_trace.sh"
        ;;
    asahi_macos_render_resource_record_trace)
        verifier="$script_dir/verify_agx_render_resource_record_trace.sh"
        ;;
    asahi_macos_render_resource_lifecycle_trace)
        verifier="$script_dir/verify_agx_render_resource_lifecycle_trace.sh"
        ;;
    asahi_macos_render_descriptor_variation_trace)
        verifier="$script_dir/verify_agx_render_descriptor_variation_trace.sh"
        ;;
    asahi_macos_iosurface_drawable_trace)
        verifier="$script_dir/verify_agx_iosurface_drawable_trace.sh"
        ;;
    asahi_macos_command_buffer_pair_lifecycle_trace)
        verifier="$script_dir/verify_agx_command_buffer_pair_lifecycle_trace.sh"
        ;;
esac

if [ -n "$verifier" ]; then
    if ! sh "$verifier" "$trace_output"; then
        cat "$trace_output"
        exit 1
    fi
fi

if [ "$trace_require_apple_bridge" = 1 ]; then
    if [ "$trace_target" != asahi_macos_trace_control ]; then
        echo "Apple-native bridge verification requires asahi_macos_trace_control" >&2
        exit 2
    fi

    if ! sh "$script_dir/verify_agx_apple_native_bridge_trace.sh" "$trace_output"; then
        cat "$trace_output"
        exit 1
    fi
fi

cat "$trace_output"
