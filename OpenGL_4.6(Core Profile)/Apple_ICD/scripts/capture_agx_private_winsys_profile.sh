#!/bin/sh
set -eu

# Compare the Apple-owned procedural command-storage path across public Metal
# workloads. This script only attaches LLDB observers; it never calls the
# private entry points or replays a captured submission.
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
capture_script="$script_dir/capture_agx_private_winsys_trace.sh"
compute_analyzer="$script_dir/analyze_agx_compute_correspondence.sh"
output_dir=${AGX_PRIVATE_WINSYS_PROFILE_DIR:-"${TMPDIR:-/private/tmp}/ao46-agx-private-winsys-profile"}

mkdir -p "$output_dir"

if [ ! -x "$compute_analyzer" ]; then
    echo "missing compute correspondence analyzer: $compute_analyzer" >&2
    exit 1
fi

for trace_target in \
    asahi_macos_trace_control \
    asahi_macos_compute_resource_record_trace \
    asahi_macos_render_resource_record_trace \
    asahi_macos_iosurface_drawable_trace
do
    output="$output_dir/$trace_target.log"
    echo "capturing Apple procedural winsys workload: $trace_target"
    OPENGLKHR_PRIVATE_WINSYS_TRACE_TARGET="$trace_target" \
    AGX_PRIVATE_WINSYS_TRACE_OUTPUT="$output" \
        "$capture_script"

    if [ "$trace_target" = asahi_macos_compute_resource_record_trace ]; then
        "$compute_analyzer" "$output"
    fi
done

printf 'AO46_AGX_PRIVATE_WINSYS_PROFILE verified workloads=4 output=%s\n' \
    "$output_dir"
