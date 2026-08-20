#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
project_root=$(CDPATH= cd -- "$script_dir/../.." && pwd)
mesa_root=${AVK143_MESA_ROOT:-"$project_root/mesa"}
build_dir=${AVK143_MESA_BUILD_DIR:-"$project_root/build/mesa-kosmickrisp-arm64-v1.4.354"}
stage_dir=${AVK143_STAGE_DIR:-"$project_root/build/AVK143"}
prefix="$stage_dir/prefix"

if [ ! -f "$mesa_root/meson.build" ]; then
   printf '%s\n' "AVK143 Mesa source is missing: $mesa_root" >&2
   exit 1
fi

if command -v brew >/dev/null 2>&1; then
   llvm_prefix=${AVK143_LLVM_PREFIX:-"$(brew --prefix llvm)"}
   libclc_prefix=${AVK143_LIBCLC_PREFIX:-"$(brew --prefix libclc)"}
   spirv_tools_prefix=${AVK143_SPIRV_TOOLS_PREFIX:-"$(brew --prefix spirv-tools)"}
   spirv_llvm_prefix=${AVK143_SPIRV_LLVM_PREFIX:-"$(brew --prefix spirv-llvm-translator)"}
else
   : "${AVK143_LLVM_PREFIX:?Set AVK143_LLVM_PREFIX when Homebrew is unavailable}"
   : "${AVK143_LIBCLC_PREFIX:?Set AVK143_LIBCLC_PREFIX when Homebrew is unavailable}"
   : "${AVK143_SPIRV_TOOLS_PREFIX:?Set AVK143_SPIRV_TOOLS_PREFIX when Homebrew is unavailable}"
   : "${AVK143_SPIRV_LLVM_PREFIX:?Set AVK143_SPIRV_LLVM_PREFIX when Homebrew is unavailable}"
   llvm_prefix=$AVK143_LLVM_PREFIX
   libclc_prefix=$AVK143_LIBCLC_PREFIX
   spirv_tools_prefix=$AVK143_SPIRV_TOOLS_PREFIX
   spirv_llvm_prefix=$AVK143_SPIRV_LLVM_PREFIX
fi

export PATH="$llvm_prefix/bin:$PATH"
export PKG_CONFIG_PATH="$libclc_prefix/share/pkgconfig:$llvm_prefix/lib/pkgconfig:$spirv_tools_prefix/lib/pkgconfig:$spirv_llvm_prefix/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"

mkdir -p "$stage_dir"

if [ -f "$build_dir/build.ninja" ]; then
   meson setup --reconfigure "$build_dir" "$mesa_root" \
      --buildtype=debugoptimized \
      -Dprefix="$prefix" \
      -Dplatforms=macos \
      -Dvulkan-drivers=kosmickrisp \
      -Dgallium-drivers= \
      -Dopengl=false \
      -Dzstd=disabled \
      --prefer-static
else
   meson setup "$build_dir" "$mesa_root" \
      --buildtype=debugoptimized \
      -Dprefix="$prefix" \
      -Dplatforms=macos \
      -Dvulkan-drivers=kosmickrisp \
      -Dgallium-drivers= \
      -Dopengl=false \
      -Dzstd=disabled \
      --prefer-static
fi

ninja -C "$build_dir" \
   src/kosmickrisp/vulkan/libvulkan_kosmickrisp.dylib \
   src/kosmickrisp/vulkan/kosmickrisp_mesa_icd.aarch64.json
meson install -C "$build_dir"

icd_library="$prefix/lib/libvulkan_kosmickrisp.dylib"
icd_manifest="$prefix/share/vulkan/icd.d/kosmickrisp_mesa_icd.aarch64.json"
if [ ! -f "$icd_library" ] || [ ! -f "$icd_manifest" ]; then
   printf '%s\n' "AVK143 ICD staging did not produce the expected standard artifacts" >&2
   exit 1
fi

printf '%s\n' "AVK143 ICD library: $icd_library"
printf '%s\n' "AVK143 ICD manifest: $icd_manifest"
printf '%s\n' "Use with: VK_DRIVER_FILES=$icd_manifest <Vulkan application>"
