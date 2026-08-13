#!/bin/sh
set -eu

# Collect only metadata and selected identifiers from the installed Apple GPU
# stack. This is a research aid for the AO46 macOS winsys; it never copies,
# loads, or links proprietary system binaries.
script_name=$(basename -- "$0")
output_dir=${AO46_APPLE_AGX_RESEARCH_DIR:-"${TMPDIR:-/private/tmp}/ao46-apple-agx-research"}
metal_binary=/System/Library/Frameworks/Metal.framework/Metal
iosurface_binary=/System/Library/Frameworks/IOSurface.framework/IOSurface
iogpu_binary=/System/Library/PrivateFrameworks/IOGPU.framework/IOGPU
ioaccelerator_binary=/System/Library/PrivateFrameworks/IOAccelerator.framework/IOAccelerator
agx_compiler_binary=/System/Library/PrivateFrameworks/AGXCompilerCore.framework/AGXCompilerCore
gpu_compiler_binary=/System/Library/PrivateFrameworks/GPUCompiler.framework/GPUCompiler
mtl_compiler_binary=/System/Library/PrivateFrameworks/MTLCompiler.framework/MTLCompiler
metal_serializer_binary=/System/Library/PrivateFrameworks/MetalSerializer.framework/MetalSerializer
metal_tools_binary=/System/Library/PrivateFrameworks/MetalTools.framework/MetalTools
gpu_tools_capture_binary=/System/Library/PrivateFrameworks/GPUToolsCapture.framework/GPUToolsCapture
gpu_tools_replay_binary=/System/Library/PrivateFrameworks/GPUToolsReplay.framework/GPUToolsReplay
gpu_tools_transport_binary=/System/Library/PrivateFrameworks/GPUToolsTransport.framework/GPUToolsTransport
legacy_gl_renderer_binary=/System/Library/Extensions/AppleMetalOpenGLRenderer.bundle/Contents/MacOS/AppleMetalOpenGLRenderer

mkdir -p "$output_dir"

agx_family=$(kmutil showloaded 2>/dev/null | awk '
  match($0, /com\.apple\.AGXG[0-9A-Z]+/) {
    print substr($0, RSTART + length("com.apple.AGX"), RLENGTH - length("com.apple.AGX"))
    exit
  }
')

if [ -z "$agx_family" ]; then
    echo "$script_name: could not identify a loaded Apple AGX family" >&2
    exit 1
fi

agx_bundle="/System/Library/Extensions/AGXMetal${agx_family}.bundle"
agx_binary="$agx_bundle/Contents/MacOS/AGXMetal${agx_family}"
agx_kernel_binary="/System/Library/Extensions/AGX${agx_family}.kext/Contents/MacOS/AGX${agx_family}"
iogpu_kernel_binary=/System/Library/Extensions/IOGPUFamily.kext/Contents/MacOS/IOGPUFamily

if [ ! -f "$agx_binary" ]; then
    echo "$script_name: active AGX Metal binary is unavailable: $agx_binary" >&2
    exit 1
fi

{
    echo "AO46 Apple AGX research inventory"
    echo "generated_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "agx_family=$agx_family"
    echo "agx_bundle=$agx_bundle"
    sw_vers
    uname -a
    system_profiler SPDisplaysDataType
} >"$output_dir/host.txt"

{
    kmutil showloaded | rg 'com\.apple\.(AGX|iokit\.IOGPUFamily)'
    ioreg -r -c "AGXAccelerator${agx_family}" -l
} >"$output_dir/kernel-and-registry.txt" 2>&1 || true

record_binary()
{
    label=$1
    binary=$2

    {
        echo "label=$label"
        echo "path=$binary"
        if [ -e "$binary" ]; then
            echo "on_disk=yes"
            shasum -a 256 "$binary"
            if command -v file >/dev/null 2>&1; then
                file "$binary"
            else
                echo "file_utility=unavailable"
            fi
            codesign -dv --verbose=2 "$binary" 2>&1 || true
        else
            # Some Apple system libraries are represented by the shared cache
            # rather than a readable standalone file on the sealed volume.
            echo "on_disk=no shared_cache_or_stub=yes"
        fi
        dyld_info -dependents "$binary" || true
    } >"$output_dir/$label-macho.txt" 2>&1
}

record_binary metal "$metal_binary"
record_binary iosurface "$iosurface_binary"
record_binary iogpu "$iogpu_binary"
record_binary ioaccelerator "$ioaccelerator_binary"
record_binary "agxmetal-$agx_family" "$agx_binary"
record_binary "agx-kernel-$agx_family" "$agx_kernel_binary"
record_binary iogpu-family-kernel "$iogpu_kernel_binary"
record_binary agx-compiler-core "$agx_compiler_binary"
record_binary gpu-compiler "$gpu_compiler_binary"
record_binary mtl-compiler "$mtl_compiler_binary"
record_binary metal-serializer "$metal_serializer_binary"
record_binary metal-tools "$metal_tools_binary"
record_binary gpu-tools-capture "$gpu_tools_capture_binary"
record_binary gpu-tools-replay "$gpu_tools_replay_binary"
record_binary gpu-tools-transport "$gpu_tools_transport_binary"
record_binary legacy-apple-metal-gl-renderer "$legacy_gl_renderer_binary"

{
    plutil -p "$agx_bundle/Contents/Info.plist"
    nm -m -arch arm64e "$agx_binary" |
        rg 'AGX.*(initWithAcceleratorPort|pinnedGPUAddress|fillCommandBufferArgs|CommandQueue.*commit|CommandBuffer.*commit)' || true
    if [ -e "$iogpu_binary" ]; then
        nm -m -arch arm64e "$iogpu_binary" |
            rg 'IOGPU.*(Device|CommandQueue|CommandBuffer|Resource|Fence|SharedEvent|Submit)' || true
    else
        echo "IOGPU identifiers unavailable: framework is shared-cache-only on this OS build"
    fi
} >"$output_dir/targeted-identifiers.txt" 2>&1

{
    echo "AO46 graphics-stack scope"
    echo "tier=execution active_agx=$agx_binary iogpu=$iogpu_binary ioaccelerator=$ioaccelerator_binary"
    echo "tier=transport iokit=/System/Library/Frameworks/IOKit.framework/IOKit agx_kernel=$agx_kernel_binary iogpu_kernel=$iogpu_kernel_binary"
    echo "tier=code_provenance agx_compiler=$agx_compiler_binary gpu_compiler=$gpu_compiler_binary mtl_compiler=$mtl_compiler_binary metal_serializer=$metal_serializer_binary"
    echo "tier=presentation metal=$metal_binary iosurface=$iosurface_binary"
    echo "tier=diagnostics metal_tools=$metal_tools_binary capture=$gpu_tools_capture_binary replay=$gpu_tools_replay_binary transport=$gpu_tools_transport_binary"
    echo "tier=abi_reference legacy_renderer=$legacy_gl_renderer_binary"
    echo "excluded=other_AGX_families unrelated_GPU_clients MetalPerformanceShaders"
} >"$output_dir/stack-scope.txt"

cat <<EOF
AO46_APPLE_AGX_RESEARCH complete output=$output_dir family=$agx_family
EOF
