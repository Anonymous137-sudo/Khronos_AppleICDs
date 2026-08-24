#!/bin/sh
set -eu

if [ "$#" -ne 2 ]; then
    echo "usage: $0 <mesa-root> <mesa-build-dir>" >&2
    exit 1
fi

mesa_root=$1
mesa_build_dir=$2

if [ ! -f "$mesa_root/meson.build" ]; then
    echo "missing Mesa source tree: $mesa_root" >&2
    exit 1
fi
command -v meson >/dev/null 2>&1 || { echo "meson is required" >&2; exit 1; }
command -v ninja >/dev/null 2>&1 || { echo "ninja is required" >&2; exit 1; }

PATH="/opt/homebrew/opt/llvm/bin:/opt/homebrew/opt/bison/bin:/opt/homebrew/opt/flex/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"
export PATH

if [ -f "$mesa_build_dir/build.ninja" ]; then
    meson setup --reconfigure "$mesa_build_dir" "$mesa_root" \
        -Dplatforms=macos \
        -Dopengl=true \
        -Degl=disabled \
        -Dglx=disabled \
        -Dgallium-drivers=asahi \
        -Dvulkan-drivers=kosmickrisp \
        -Dllvm=enabled \
        -Dgallium-rusticl=false \
        -Dtools=
else
    meson setup "$mesa_build_dir" "$mesa_root" \
        --buildtype=release \
        --default-library=static \
        -Dplatforms=macos \
        -Dopengl=true \
        -Degl=disabled \
        -Dglx=disabled \
        -Dgallium-drivers=asahi \
        -Dvulkan-drivers=kosmickrisp \
        -Dllvm=enabled \
        -Dgallium-rusticl=false \
        -Dtools=
fi

# Build the common Mesa/NIR archives and the complete KosmicKrisp Metal/Vulkan
# artifact set from this same Meson graph. This prevents CMake from combining
# objects produced by incompatible Mesa configurations.
meson compile -C "$mesa_build_dir" \
    glapi mesa gallium mesa_util mesa_util_c11 mesa_util_simd \
    compiler nir glsl glsl_util libpoly_nir asahi \
    msl_compiler \
    mtl_bridge \
    libkk_shaders \
    vulkan_kosmickrisp

echo "built unified AO46 Mesa/KosmicKrisp artifacts in $mesa_build_dir"
