#!/bin/sh
set -eu

if [ "$#" -ne 1 ]; then
    echo "usage: $0 TRACE_LOG" >&2
    exit 2
fi

trace_log=$1

if [ ! -f "$trace_log" ]; then
    echo "missing AGX trace log: $trace_log" >&2
    exit 2
fi

require() {
    pattern=$1
    description=$2

    if ! grep -Eq "$pattern" "$trace_log"; then
        echo "missing Apple-native bridge evidence: $description" >&2
        exit 1
    fi
}

# The selector-9 resource allocation must be owned by the active AGXMetal
# buffer implementation, not merely observed on the common user-client.
require 'AGX_TRACE_CALLER operation=method .* id=0x9 .*AGXBuffer' \
    'AGXBuffer allocation caller for selector 9'
require 'MODERN_ALLOCATE_MEM handle=[0-9]+ gpu=[0-9a-f]+ .*size=' \
    'resource allocation reply'

# Current G16X submission crosses from Metal into IOGPU before Trap4. These
# names are a profile-specific trace anchor, never a declaration of ABI.
require 'AGX_TRACE_CALLER_FALLBACK operation=trap4 .*IOGPU.framework.*/IOGPU .*symbol=IOGPUCommandQueueSubmitCommandBuffers' \
    'IOGPU command-queue submit caller'
require 'AGX_TRACE_CALLER_FALLBACK operation=trap4 .*IOGPUMetalCommandQueue .*submitCommandBuffers:' \
    'IOGPU command-queue method caller'
require 'MODERN_SUBMIT queue=[0-9]+ header=2/1' \
    'validated Trap4 submission transport'
require 'MODERN_COMPLETION queue=[0-9]+ token=[0-9a-f]+ bytes=40' \
    'completion record after submission'

echo "AGX_APPLE_NATIVE_BRIDGE_TRACE verified allocation=AGXBuffer submit=IOGPUCommandQueueSubmitCommandBuffers"
