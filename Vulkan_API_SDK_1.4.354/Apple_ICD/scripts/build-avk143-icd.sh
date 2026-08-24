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

# Installer scripts run as root, so user-site Python modules are not reliable.
python_candidate=${AVK143_PYTHON:-}
if [ -z "$python_candidate" ]; then
   for candidate in \
      /usr/local/bin/python3.13 \
      /Library/Frameworks/Python.framework/Versions/3.13/bin/python3 \
      /opt/homebrew/bin/python3.13 \
      /opt/homebrew/bin/python3 \
      /usr/bin/python3; do
      if [ -x "$candidate" ]; then
         python_candidate=$candidate
         break
      fi
   done
fi
if [ -z "$python_candidate" ]; then
   python_candidate=$(command -v python3 || true)
fi
if [ -z "$python_candidate" ]; then
   printf '%s\n' 'AVK143 requires Python 3.10 or newer to build Mesa' >&2
   exit 1
fi

python_venv=${AVK143_PYTHON_VENV:-"$project_root/build/avk143-python"}
if ! "$python_candidate" -c 'import mako, yaml, packaging' >/dev/null 2>&1; then
   printf '%s\n' "AVK143 Python modules are missing; preparing isolated environment: $python_venv"
   if [ ! -x "$python_venv/bin/python" ]; then
      mkdir -p "$(dirname -- "$python_venv")"
      "$python_candidate" -m venv "$python_venv"
   fi
   "$python_venv/bin/python" -m pip install \
      --disable-pip-version-check --no-input Mako PyYAML packaging
   python_candidate="$python_venv/bin/python"
fi
export AVK143_PYTHON="$python_candidate"
export PATH="$(dirname -- "$python_candidate"):$PATH"
printf '%s\n' "AVK143 Python: $python_candidate"

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

# The build-tree install name and Homebrew SPIR-V Tools path must not escape
# into an installed ICD. Keep the small required SPIR-V runtime beside the
# ICD and make the pair relocatable within the AVK143 runtime directory.
spirv_library="$spirv_tools_prefix/lib/libSPIRV-Tools.dylib"
private_lib_dir="$prefix/lib/avk143"
private_spirv_library="$private_lib_dir/libSPIRV-Tools.dylib"
if [ ! -f "$spirv_library" ]; then
   printf '%s\n' "AVK143 SPIR-V Tools runtime is missing: $spirv_library" >&2
   exit 1
fi
mkdir -p "$private_lib_dir"
install -m 755 "$spirv_library" "$private_spirv_library"
install_name_tool -id '@rpath/libSPIRV-Tools.dylib' "$private_spirv_library"
install_name_tool -id '/usr/local/lib/avk143/libvulkan_kosmickrisp.dylib' "$icd_library"
install_name_tool -change "$spirv_library" '@rpath/libSPIRV-Tools.dylib' "$icd_library"
install_name_tool -add_rpath '@loader_path' "$icd_library" 2>/dev/null || true
install_name_tool -add_rpath '@loader_path/avk143' "$icd_library" 2>/dev/null || true

# Release binaries must not carry compiler/debug source paths.
strip -S "$icd_library" 2>/dev/null || true

printf '%s\n' "AVK143 ICD library: $icd_library"
printf '%s\n' "AVK143 ICD manifest: $icd_manifest"
printf '%s\n' "AVK143 private SPIR-V runtime: $private_spirv_library"
printf '%s\n' "Use with: VK_DRIVER_FILES=$icd_manifest <Vulkan application>"
