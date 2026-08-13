#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
capture_script="$script_dir/capture_agx_trace_control.sh"
verify_transport="$script_dir/verify_agx_uabi_transport_trace.sh"
analyze_sidecar="$script_dir/analyze_agx_sidecar_layout.sh"
analyze_sidecar_pointer="$script_dir/analyze_agx_sidecar_pointer_layout.sh"
output_dir=${AGX_UABI_TRACE_DIR:-"${TMPDIR:-/private/tmp}/ao46-agx-uabi-profile"}

mkdir -p "$output_dir"

# These controlled workloads jointly cover empty, two-queue, resource-bearing
# blit, compute, and render records, descriptor variation, and IOSurface
# submissions. They validate the observed UABI transport only; no log produced
# by this tool authorizes direct Trap4 replay.
for trace_target in \
    asahi_macos_empty_submission_trace \
    asahi_macos_two_queue_empty_submission_trace \
    asahi_macos_trace_control \
    asahi_macos_resource_record_variation_trace \
    asahi_macos_compute_resource_record_trace \
    asahi_macos_render_resource_record_trace \
    asahi_macos_compute_resource_range_trace \
    asahi_macos_render_descriptor_variation_trace \
    asahi_macos_iosurface_drawable_trace
do
    trace_log="$output_dir/$trace_target.log"
    echo "capturing UABI profile workload: $trace_target"
    AGX_TRACE_REQUIRE_EXTENDED=1 \
    AGX_TRACE_REQUIRE_TRAP_PAYLOADS=1 \
    AGX_TRACE_REQUIRE_SIDECAR_HEX=1 \
    AGX_TRACE_REQUIRE_POINTER_HEX=1 \
    AGX_TRACE_AUX_POINTERS=1 \
    AGX_TRACE_TRAP_PAYLOADS=1 \
    AGX_TRACE_AUX_EXTENDED_HEX=1 \
    AGX_TRACE_AUX_POINTER_HEX=1 \
    AGX_TRACE_OUTPUT="$trace_log" \
    OPENGLKHR_TRACE_TARGET="$trace_target" \
    "$capture_script" >/dev/null
    AGX_TRACE_REQUIRE_EXTENDED=1 \
    AGX_TRACE_REQUIRE_TRAP_PAYLOADS=1 \
    AGX_TRACE_REQUIRE_SIDECAR_HEX=1 \
    AGX_TRACE_REQUIRE_POINTER_HEX=1 \
    "$verify_transport" "$trace_log"
    "$analyze_sidecar" "$trace_log" >"${trace_log%.log}.sidecar-layout.txt"
    "$analyze_sidecar_pointer" "$trace_log" >"${trace_log%.log}.sidecar-pointer-layout.txt"
done

printf 'AGX_UABI_PROFILE_TRACE verified workloads=9 sidecar_layouts=9 pointer_layouts=9 output=%s\n' "$output_dir"
