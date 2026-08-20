#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
project_root=$(CDPATH= cd -- "$script_dir/../.." && pwd)
mesa_root=${AVK143_MESA_ROOT:-"$project_root/mesa"}
stage_dir=${AVK143_STAGE_DIR:-"$project_root/build/AVK143"}
icd_library=${AVK143_ICD_LIBRARY:-"$stage_dir/prefix/lib/libvulkan_kosmickrisp.dylib"}
smoke_dir="$stage_dir/smoke"
smoke_binary="$smoke_dir/AVK143ICDDispatchSmoke"

if [ ! -f "$icd_library" ]; then
   printf '%s\n' "AVK143 ICD library is missing: $icd_library" >&2
   printf '%s\n' "Run Apple_ICD/scripts/build-avk143-icd.sh first." >&2
   exit 1
fi

mkdir -p "$smoke_dir"
cc -std=c11 -Wall -Wextra -Werror -DVK_NO_PROTOTYPES \
   -I "$mesa_root/include" \
   "$project_root/Apple_ICD/tests/AVK143ICDDispatchSmoke.c" \
   -o "$smoke_binary"
"$smoke_binary" --headers-only
"$smoke_binary" "$icd_library" 1 4
