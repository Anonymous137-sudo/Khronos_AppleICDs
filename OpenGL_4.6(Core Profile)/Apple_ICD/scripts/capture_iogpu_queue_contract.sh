#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
project_root=$(CDPATH= cd -- "$script_dir/.." && pwd)
build_dir=${AO46_BUILD_DIR:-"$project_root/artifacts/apple-agx-bridge-build"}
output=${AO46_IOGPU_QUEUE_CAPTURE:-"${TMPDIR:-/private/tmp}/ao46-iogpu-queue-contract.log"}
control="$build_dir/AppleAGXQueueContractControl"
capture_module="$script_dir/iogpu_queue_contract_capture.py"
analyzer="$script_dir/analyze_iogpu_queue_contract.sh"

cmake --build "$build_dir" --target AppleAGXQueueContractControl

if [ ! -x "$control" ] || [ ! -f "$capture_module" ] ||
   [ ! -x "$analyzer" ]; then
    echo "missing Apple AGX queue contract control or capture tooling" >&2
    exit 1
fi

lldb --batch \
    -o 'breakpoint set --name ao46_queue_contract_capture_ready' \
    -o run \
    -o 'breakpoint set --name IOGPUCommandQueueCreate' \
    -o 'breakpoint set --name IOGPUCommandQueueRelease' \
    -o 'breakpoint set --name IOGPUCommandQueueSubmitCommandBuffers' \
    -o 'breakpoint set --name IOGPUMetalCommandBufferStorageCreateExt' \
    -o 'breakpoint set --name "-[IOGPUMetalCommandBuffer fillCommandBufferArgs:commandQueue:]"' \
    -o "command script import '$capture_module'" \
    -o 'breakpoint command add -F iogpu_queue_contract_capture.capture_queue_create 2' \
    -o 'breakpoint command add -F iogpu_queue_contract_capture.capture_queue_release 3' \
    -o 'breakpoint command add -F iogpu_queue_contract_capture.capture_queue_submit 4' \
    -o 'breakpoint command add -F iogpu_queue_contract_capture.capture_command_storage 5' \
    -o 'breakpoint command add -F iogpu_queue_contract_capture.capture_command_buffer_fill 6' \
    -o continue \
    -- "$control" >"$output" 2>&1

if ! grep -q 'exited with status = 0' "$output"; then
    cat "$output" >&2
    echo "IOGPU queue control did not exit successfully" >&2
    exit 1
fi

"$analyzer" "$output"
printf 'AO46_IOGPU_QUEUE_CAPTURE output=%s\n' "$output"
