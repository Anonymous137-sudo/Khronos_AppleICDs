#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
icd_root=$(CDPATH= cd -- "$script_dir/.." && pwd)
project_root=$(CDPATH= cd -- "$icd_root/.." && pwd)
cts_version=1.4.6.2
cts_root=${AVK143_CTS_ROOT:-"${HOME}/Downloads/VK-GL-CTS-vulkan-cts-${cts_version}"}
work_root=${AVK143_CTS_WORK_ROOT:-"$project_root/build/cts-${cts_version}"}
cts_build=${AVK143_CTS_BUILD_DIR:-"$work_root/build-cts"}
headers_root=${AVK143_HEADERS_ROOT:-"$icd_root/stdvkabi_khr/Vulkan-Headers"}
loader_root=${AVK143_LOADER_ROOT:-"$icd_root/Client/Vulkan-Loader"}
headers_build="$work_root/build-headers"
headers_prefix="$work_root/headers-prefix"
loader_build="$work_root/build-loader"
loader_prefix="$work_root/prefix"

for command in cmake ninja python3; do
    command -v "$command" >/dev/null 2>&1 || {
        printf '%s\n' "AVK143 CTS preparation requires $command" >&2
        exit 1
    }
done

if [ ! -f "$cts_root/external/vulkancts/mustpass/main/vk-default.txt" ]; then
    printf '%s\n' "Vulkan CTS ${cts_version} source is missing: $cts_root" >&2
    printf '%s\n' "Set AVK143_CTS_ROOT to the extracted VK-GL-CTS-vulkan-cts-${cts_version} directory." >&2
    exit 1
fi
if [ ! -f "$headers_root/include/vulkan/vulkan.h" ]; then
    printf '%s\n' "Pinned Vulkan-Headers source is missing: $headers_root" >&2
    exit 1
fi
if [ ! -f "$loader_root/loader/CMakeLists.txt" ]; then
    printf '%s\n' "Pinned Vulkan-Loader source is missing: $loader_root" >&2
    exit 1
fi

mkdir -p "$work_root"

# Release archives intentionally omit fetched third-party source payloads.
if [ ! -f "$cts_root/external/glslang/src/CMakeLists.txt" ]; then
    printf '%s\n' "Fetching checksummed CTS ${cts_version} dependencies"
    python3 "$cts_root/external/fetch_sources.py"
fi

cmake -S "$headers_root" -B "$headers_build" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="$headers_prefix" \
    -DVULKAN_HEADERS_ENABLE_TESTS=OFF
cmake --build "$headers_build"
cmake --install "$headers_build"

cmake -S "$loader_root" -B "$loader_build" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="$loader_prefix" \
    -DCMAKE_PREFIX_PATH="$headers_prefix" \
    -DBUILD_TESTS=OFF \
    -DBUILD_WSI_WAYLAND_SUPPORT=OFF \
    -DBUILD_WSI_XCB_SUPPORT=OFF \
    -DBUILD_WSI_XLIB_SUPPORT=OFF
cmake --build "$loader_build" --target vulkan
cmake --install "$loader_build"

cmake -S "$cts_root" -B "$cts_build" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_OSX_ARCHITECTURES=arm64 \
    -DDEQP_TARGET=default \
    -DSELECTED_BUILD_TARGETS=deqp-vk
cmake --build "$cts_build" --target deqp-vk

cts_binary="$cts_build/external/vulkancts/modules/vulkan/deqp-vk"
if [ ! -x "$cts_binary" ]; then
    printf '%s\n' "CTS build did not produce deqp-vk: $cts_binary" >&2
    exit 1
fi

printf '%s\n' "CTS version: $cts_version" > "$work_root/source-version.txt"
printf '%s\n' "CTS source: $cts_root" >> "$work_root/source-version.txt"
printf '%s\n' "CTS binary: $cts_binary"
printf '%s\n' "Khronos Loader: $loader_prefix/lib"
