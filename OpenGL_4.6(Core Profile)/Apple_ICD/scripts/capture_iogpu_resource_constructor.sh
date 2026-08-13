#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
project_root=$(CDPATH= cd -- "$script_dir/.." && pwd)
build_dir=${AO46_BUILD_DIR:-"$project_root/artifacts/apple-agx-bridge-build"}
output=${AO46_IOGPU_RESOURCE_CAPTURE:-"${TMPDIR:-/private/tmp}/ao46-iogpu-resource-constructor.log"}
control="$build_dir/AppleAGXResourceConstructorControl"
capture_module="$script_dir/iogpu_resource_constructor_capture.py"
analyzer="$script_dir/analyze_iogpu_resource_constructor_records.sh"

cmake --build "$build_dir" --target AppleAGXResourceConstructorControl

if [ ! -x "$control" ] || [ ! -f "$capture_module" ] ||
   [ ! -x "$analyzer" ]; then
    echo "missing Apple AGX resource constructor control: $control" >&2
    exit 1
fi

lldb --batch \
    -o 'breakpoint set --name ao46_resource_constructor_capture_ready' \
    -o run \
    -o 'image lookup --name IOGPUResourceCreate' \
    -o 'breakpoint set --name IOGPUResourceCreate' \
    -o 'breakpoint set --name IOGPUResourceRelease' \
    -o 'breakpoint set --name IOGPUResourceGetGPUVirtualAddress' \
    -o 'breakpoint set --name IOGPUResourceGetGPUVirtualAddressLength' \
    -o 'breakpoint set --name IOConnectCallMethod' \
    -o "command script import '$capture_module'" \
    -o 'breakpoint command add -F iogpu_resource_constructor_capture.capture_resource_constructor 2' \
    -o 'breakpoint command add -F iogpu_resource_constructor_capture.capture_resource_release 3' \
    -o 'breakpoint command add -F iogpu_resource_constructor_capture.capture_resource_gpu_virtual_address 4' \
    -o 'breakpoint command add -F iogpu_resource_constructor_capture.capture_resource_gpu_virtual_address_length 5' \
    -o 'breakpoint command add -F iogpu_resource_constructor_capture.capture_resource_selector9 6' \
    -o continue \
    -- "$control" >"$output" 2>&1

if ! grep -q 'IOGPUResourceCreate' "$output" ||
   ! grep -q 'exited with status = 0' "$output"; then
    cat "$output" >&2
    echo "IOGPU resource constructor capture did not reach the expected call frame" >&2
    exit 1
fi

"$analyzer" "$output"

printf 'AO46_IOGPU_RESOURCE_CONSTRUCTOR_CAPTURE output=%s\n' "$output"
