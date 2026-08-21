#!/bin/sh
set -eu

if [ "$#" -ne 1 ]; then
    printf '%s\n' "usage: $0 <runtime-prefix>" >&2
    exit 2
fi

prefix=$1
icd="$prefix/lib/avk143/libvulkan_kosmickrisp.dylib"
spirv="$prefix/lib/avk143/libSPIRV-Tools.dylib"
manifest="$prefix/share/vulkan/icd.d/avk143_kosmickrisp_icd.aarch64.json"

for file in "$icd" "$spirv" "$manifest"; do
    if [ ! -f "$file" ]; then
        printf '%s\n' "runtime-neutrality smoke failed: missing $file" >&2
        exit 1
    fi
done

deps=$(otool -L "$icd")
printf '%s\n' "$deps" | grep -q '@rpath/libSPIRV-Tools.dylib'
if printf '%s\n' "$deps" | grep -Eq '/opt/homebrew|/Users/|/private/|/usr/local/src|build/AVK143'; then
    printf '%s\n' 'runtime-neutrality smoke failed: ICD has a host-specific dependency path' >&2
    exit 1
fi

spirv_deps=$(otool -L "$spirv")
if printf '%s\n' "$spirv_deps" | grep -Eq '/opt/homebrew|/Users/|/private/|/usr/local/src|build/AVK143'; then
    printf '%s\n' 'runtime-neutrality smoke failed: SPIR-V runtime has a host-specific dependency path' >&2
    exit 1
fi

if (strings "$icd"; strings "$spirv") |
    grep -Eq '/Users/|/private/|/opt/homebrew|/usr/local/src|build/AVK143'; then
    printf '%s\n' 'runtime-neutrality smoke failed: release metadata contains a host path' >&2
    exit 1
fi

nm -gU "$icd" | grep -q '_vk_icdGetInstanceProcAddr'
nm -gU "$icd" | grep -q '_vk_icdNegotiateLoaderICDInterfaceVersion'
grep -q 'libvulkan_kosmickrisp.dylib' "$manifest"

printf '%s\n' "AVK143 runtime neutrality smoke passed: $prefix"
