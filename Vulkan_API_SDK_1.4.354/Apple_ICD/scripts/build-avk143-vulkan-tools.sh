#!/bin/sh
set -eu

runtime_prefix=${AVK143_RUNTIME_PREFIX:-/usr/local}
build_root=${AVK143_TOOLS_BUILD_ROOT:-"$(CDPATH= cd -- "$(dirname -- "$0")/../../build" && pwd)/VulkanTools"}
loader_root="$build_root/Vulkan-Loader"
tools_root="$build_root/Vulkan-Tools"
headers_root="$build_root/Vulkan-Headers"

loader_url=${AVK143_LOADER_REPO_URL:-https://github.com/KhronosGroup/Vulkan-Loader.git}
tools_url=${AVK143_TOOLS_REPO_URL:-https://github.com/KhronosGroup/Vulkan-Tools.git}
headers_url=${AVK143_HEADERS_REPO_URL:-https://github.com/KhronosGroup/Vulkan-Headers.git}
layers_url=${AVK143_LAYERS_REPO_URL:-https://github.com/KhronosGroup/Vulkan-ValidationLayers.git}
utility_url=${AVK143_UTILITY_REPO_URL:-https://github.com/KhronosGroup/Vulkan-Utility-Libraries.git}
loader_branch=${AVK143_LOADER_BRANCH:-main}
tools_branch=${AVK143_TOOLS_BRANCH:-main}
headers_branch=${AVK143_HEADERS_BRANCH:-main}
layers_branch=${AVK143_LAYERS_BRANCH:-main}
utility_branch=${AVK143_UTILITY_BRANCH:-main}

for command in git cmake; do
    command -v "$command" >/dev/null 2>&1 || {
        printf '%s\n' "AVK143 Vulkan tools require $command" >&2
        exit 1
    }
done

clone_or_update() {
    url=$1
    branch=$2
    destination=$3
    if [ ! -d "$destination/.git" ]; then
        git clone --depth 1 --branch "$branch" "$url" "$destination"
    else
        git -C "$destination" fetch --depth 1 origin "$branch"
        git -C "$destination" checkout -q "$branch"
        git -C "$destination" reset --hard -q "origin/$branch"
    fi
}

mkdir -p "$build_root"
clone_or_update "$loader_url" "$loader_branch" "$loader_root"
clone_or_update "$tools_url" "$tools_branch" "$tools_root"
clone_or_update "$headers_url" "$headers_branch" "$headers_root"
if [ "${AVK143_BUILD_VALIDATION_LAYERS:-1}" = 1 ]; then
    layers_root="$build_root/Vulkan-ValidationLayers"
    clone_or_update "$layers_url" "$layers_branch" "$layers_root"
    utility_root=${AVK143_UTILITY_ROOT:-"$build_root/Vulkan-Utility-Libraries"}
    if [ ! -d "$utility_root/.git" ]; then
        clone_or_update "$utility_url" "$utility_branch" "$utility_root"
    fi
fi

loader_build="$build_root/loader-build"
tools_build="$build_root/tools-build"
loader_prefix="$build_root/loader-prefix"
tools_prefix="$build_root/tools-prefix"
headers_build="$build_root/headers-build"
headers_prefix="$build_root/headers-prefix"
utility_build="$build_root/utility-build"
utility_prefix=${AVK143_UTILITY_PREFIX:-"$build_root/utility-prefix"}

cmake -S "$headers_root" -B "$headers_build" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="$headers_prefix"
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

cmake -S "$tools_root" -B "$tools_build" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="$tools_prefix" \
    -DCMAKE_PREFIX_PATH="$headers_prefix;$loader_prefix" \
    -DAPPLE_USE_SYSTEM_ICD=ON \
    -DBUILD_CUBE=ON \
    -DBUILD_VULKANINFO=ON \
    -DBUILD_TESTS=OFF
cmake --build "$tools_build" --target vulkaninfo vkcube

if [ "${AVK143_BUILD_VALIDATION_LAYERS:-1}" = 1 ]; then
    cmake -S "$utility_root" -B "$utility_build" -G Ninja \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX="$utility_prefix" \
        -DCMAKE_PREFIX_PATH="$headers_prefix" \
        -DBUILD_TESTS=OFF
    cmake --build "$utility_build"
    cmake --install "$utility_build"

    layers_build="$build_root/layers-build"
    layers_prefix="$build_root/layers-prefix"
    spirv_headers_prefix="$layers_root/external/SPIRV-Headers/build/install"
    spirv_tools_prefix="$layers_root/external/SPIRV-Tools/build/install"
    cmake -S "$layers_root" -B "$layers_build" -G Ninja \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX="$layers_prefix" \
        -DCMAKE_PREFIX_PATH="$headers_prefix;$loader_prefix;$utility_prefix;$spirv_headers_prefix;$spirv_tools_prefix" \
        -DSPIRV_HEADERS_INSTALL_DIR="$spirv_headers_prefix" \
        -DSPIRV_TOOLS_INSTALL_DIR="$spirv_tools_prefix" \
        -DBUILD_TESTS=OFF \
        -DBUILD_WERROR=OFF \
        -DUPDATE_DEPS=ON \
        -DUPDATE_DEPS_DIR="$layers_root/external"
    # Current ValidationLayers exposes the module as `vvl`; its install
    # artifact remains libVkLayer_khronos_validation.dylib.
    cmake --build "$layers_build" --target vvl
    cmake --install "$layers_build"
fi

runtime_lib="$runtime_prefix/lib"
runtime_bin="$runtime_prefix/bin"
mkdir -p "$runtime_lib" "$runtime_bin"

loader_library=$(find "$loader_prefix" -type f -name 'libvulkan*.dylib' -print -quit)
[ -n "$loader_library" ] || { printf '%s\n' 'AVK143 Vulkan Loader build produced no dylib' >&2; exit 1; }
install -m 755 "$loader_library" "$runtime_lib/libvulkan.1.dylib"
ln -sf libvulkan.1.dylib "$runtime_lib/libvulkan.dylib"
strip -S "$runtime_lib/libvulkan.1.dylib" 2>/dev/null || true
if [ -d "$loader_prefix/loader/vulkan.framework" ]; then
    rm -rf "$runtime_prefix/lib/vulkan.framework"
    cp -R "$loader_prefix/loader/vulkan.framework" "$runtime_prefix/lib/vulkan.framework"
fi

for tool in vulkaninfo vkcube; do
    tool_path=$(find "$tools_build" -type f -perm -111 -name "$tool" -print -quit)
    [ -n "$tool_path" ] || { printf '%s\n' "AVK143 Vulkan-Tools build produced no $tool" >&2; exit 1; }
    install -m 755 "$tool_path" "$runtime_bin/$tool"
    strip -S "$runtime_bin/$tool" 2>/dev/null || true
done
install_name_tool -add_rpath '@loader_path/../lib' "$runtime_bin/vkcube" 2>/dev/null || true
if find "$tools_build" -type f -perm -111 -name vkvia -print -quit | grep -q .; then
    tool_path=$(find "$tools_build" -type f -perm -111 -name vkvia -print -quit)
    install -m 755 "$tool_path" "$runtime_bin/vkvia"
    printf '%s\n' "AVK143 vkvia installed: $runtime_bin/vkvia"
else
    printf '%s\n' 'AVK143 vkvia: unavailable in the selected Khronos Vulkan-Tools revision'
fi

if [ "${AVK143_BUILD_VALIDATION_LAYERS:-1}" = 1 ]; then
    layer_library=$(find "$layers_prefix" -type f -name 'libVkLayer_khronos_validation*.dylib' -print -quit)
    [ -n "$layer_library" ] || {
        printf '%s\n' 'AVK143 validation layer build produced no dylib' >&2
        exit 1
    }
    install -m 755 "$layer_library" "$runtime_lib/libVkLayer_khronos_validation.dylib"
    strip -S "$runtime_lib/libVkLayer_khronos_validation.dylib" 2>/dev/null || true
    install_name_tool -add_rpath '@loader_path' \
        "$runtime_lib/libVkLayer_khronos_validation.dylib" 2>/dev/null || true
    layer_manifest=$(find "$layers_prefix" -type f -name 'VkLayer_khronos_validation.json' -print -quit)
    if [ -n "$layer_manifest" ]; then
        mkdir -p "$runtime_prefix/share/vulkan/explicit_layer.d"
        install -m 644 "$layer_manifest" \
            "$runtime_prefix/share/vulkan/explicit_layer.d/VkLayer_khronos_validation.json"
    fi
fi

# Keep headers and pkg-config metadata aligned with the checked-in Mesa Vulkan
# registry. These are developer artifacts, not part of the ICD link closure.
mkdir -p "$runtime_prefix/include" "$runtime_lib/pkgconfig"
if [ -d "$headers_prefix/include/vulkan" ]; then
    rm -rf "$runtime_prefix/include/vulkan"
    cp -R "$headers_prefix/include/vulkan" "$runtime_prefix/include/vulkan"
fi
if [ -f "$loader_prefix/lib/pkgconfig/vulkan.pc" ]; then
    install -m 644 "$loader_prefix/lib/pkgconfig/vulkan.pc" "$runtime_lib/pkgconfig/vulkan.pc"
fi

printf '%s\n' "AVK143 Vulkan Loader installed: $runtime_lib/libvulkan.1.dylib"
printf '%s\n' "AVK143 Vulkan-Tools installed: $runtime_bin/vulkaninfo $runtime_bin/vkcube"
printf '%s\n' "AVK143 Vulkan headers installed: $runtime_prefix/include/vulkan"
if [ "${AVK143_BUILD_VALIDATION_LAYERS:-1}" != 1 ]; then
    printf '%s\n' 'AVK143 validation layer: disabled (set AVK143_BUILD_VALIDATION_LAYERS=1 to enable)'
fi
if [ "${AVK143_BUILD_VALIDATION_LAYERS:-1}" = 1 ]; then
    printf '%s\n' "AVK143 validation layer installed: $runtime_lib/libVkLayer_khronos_validation.dylib"
fi
