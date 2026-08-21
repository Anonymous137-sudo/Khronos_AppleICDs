#!/bin/sh
set -eu

usage() {
    printf '%s\n' "usage: $0 --prefix <runtime-prefix>"
    exit 2
}

prefix=''
while [ "$#" -gt 0 ]; do
    case "$1" in
        --prefix)
            [ "$#" -ge 2 ] || usage
            prefix=$2
            shift 2
            ;;
        *)
            usage
            ;;
    esac
done

[ -n "$prefix" ] || usage

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
project_root=$(CDPATH= cd -- "$script_dir/../.." && pwd)
source_library="$project_root/build/AVK143/prefix/lib/libvulkan_kosmickrisp.dylib"
source_spirv="$project_root/build/AVK143/prefix/lib/avk143/libSPIRV-Tools.dylib"
runtime_library="$prefix/lib/avk143/libvulkan_kosmickrisp.dylib"
runtime_spirv="$prefix/lib/avk143/libSPIRV-Tools.dylib"
manifest_dir="$prefix/share/vulkan/icd.d"
manifest="$manifest_dir/avk143_kosmickrisp_icd.aarch64.json"

if [ ! -f "$source_library" ] || [ ! -f "$source_spirv" ]; then
    printf '%s\n' "AVK143 staged ICD is missing: $source_library" >&2
    printf '%s\n' "Run Apple_ICD/scripts/build-avk143-icd.sh first." >&2
    exit 1
fi

mkdir -p "$(dirname -- "$runtime_library")" "$manifest_dir"
install -m 755 "$source_library" "$runtime_library"
install -m 755 "$source_spirv" "$runtime_spirv"

cat > "$manifest" <<EOF
{
    "file_format_version": "1.0.1",
    "ICD": {
        "library_path": "$runtime_library",
        "api_version": "1.4.354"
    }
}
EOF

printf '%s\n' "AVK143 runtime staged at: $prefix"
printf '%s\n' "AVK143 loader manifest: $manifest"
