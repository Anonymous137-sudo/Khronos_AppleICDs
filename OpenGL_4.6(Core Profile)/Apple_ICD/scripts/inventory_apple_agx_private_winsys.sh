#!/bin/sh
set -eu

# Index metadata from the active on-disk AGX driver without copying, loading,
# or calling its private implementation. The output is profile evidence for
# the direct Asahi-to-AGX user-client adapter, not a private API declaration.
script_name=$(basename -- "$0")
output_dir=${AO46_APPLE_AGX_WINSYS_RESEARCH_DIR:-"${TMPDIR:-/private/tmp}/ao46-apple-agx-private-winsys"}

agx_family=$(kmutil showloaded 2>/dev/null | awk '
  match($0, /com\.apple\.AGXG[0-9A-Z]+/) {
    print substr($0, RSTART + length("com.apple.AGX"),
                 RLENGTH - length("com.apple.AGX"))
    exit
  }
')

if [ -z "$agx_family" ]; then
    echo "$script_name: could not identify a loaded Apple AGX family" >&2
    exit 1
fi

agx_bundle="/System/Library/Extensions/AGXMetal${agx_family}.bundle"
agx_binary="$agx_bundle/Contents/MacOS/AGXMetal${agx_family}"

if [ ! -f "$agx_binary" ]; then
    echo "$script_name: active AGX winsys binary is unavailable: $agx_binary" >&2
    exit 1
fi

mkdir -p "$output_dir"

{
    echo "AO46 Apple AGX private winsys inventory"
    echo "generated_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "agx_family=$agx_family"
    echo "agx_bundle=$agx_bundle"
    echo "agx_binary=$agx_binary"
    shasum -a 256 "$agx_binary"
    sw_vers
    uname -m
} >"$output_dir/profile.txt"

otool -L "$agx_binary" >"$output_dir/dependencies.txt" 2>&1
nm -u -arch arm64e "$agx_binary" | \
    rg '(_IOConnect|_IODataQueue|_IOService|_IORegistry|_IOGPU|_IOSurface)' \
    >"$output_dir/iokit-imports.txt" || true
nm -u -arch arm64e "$agx_binary" | \
    rg '^_IOGPUMetalCommandBufferStorage|^_IOGPU(ResourceList|MetalResidencySetList|ResourceGroupUpdateResources)' \
    >"$output_dir/procedural-command-storage-anchors.txt" || true

nm -m -arch arm64e "$agx_binary" | \
    rg 'AGX(Buffer|Texture|Heap).*(backingResource|initWithDevice:.*pinnedGPU|initWithDevice:.*resourceInArgs)|AGXG.*(Device.*initWithAcceleratorPort|CommandBuffer.*(beginCommandBuffer|fillCommandBufferArgs|reserveKernelCommandBufferSpace|endCommandBuffer)|CommandQueue.*(commit:count|noMergeCommit|commandBuffer))' \
    >"$output_dir/private-winsys-anchors.txt" || true

{
    echo "[device-bootstrap]"
    nm -m -arch arm64e "$agx_binary" | \
        rg 'AGXG.*Device.*initWithAcceleratorPort' || true
    echo
    echo "[resource-and-gpu-va]"
    nm -m -arch arm64e "$agx_binary" | \
        rg 'AGXBuffer.*(backingResource|parentGPU(Address|Size)|initWithDevice:.*(pinnedGPU|resourceInArgs)|initWithHeap:)' || true
    echo
    echo "[command-record-assembly]"
    nm -m -arch arm64e "$agx_binary" | \
        rg 'AGXG.*CommandBuffer.*(beginCommandBuffer|fillCommandBufferArgs|reserveKernelCommandBufferSpace|closeKernelCommands|endCommandBuffer)' || true
    echo
    echo "[queue-commit]"
    nm -m -arch arm64e "$agx_binary" | \
        rg 'AGXG.*CommandQueue.*(commit:count|noMergeCommit|commandBuffer)' || true
} >"$output_dir/winsys-ownership-map.txt" 2>&1

cat <<EOF
AO46_APPLE_AGX_PRIVATE_WINSYS complete output=$output_dir family=$agx_family
EOF
