#!/bin/sh
set -eu

if [ "$#" -ne 3 ]; then
    printf '%s\n' "usage: $0 <stage-script> <vulkaninfo> <runtime-home>" >&2
    exit 2
fi

stage_script=$1
vulkaninfo=$2
runtime_home=$3
runtime_prefix="$runtime_home/.local"

mkdir -p "$runtime_home"
"$stage_script" --prefix "$runtime_prefix"

env -u VK_DRIVER_FILES -u VK_ICD_FILENAMES \
    HOME="$runtime_home" \
    XDG_DATA_HOME="$runtime_prefix/share" \
    "$vulkaninfo" --summary > "$runtime_home/vulkaninfo-summary.txt"

grep -q 'driverID.*DRIVER_ID_MESA_KOSMICKRISP' "$runtime_home/vulkaninfo-summary.txt"
grep -q '^GPU0:' "$runtime_home/vulkaninfo-summary.txt"

printf '%s\n' "AVK143 runtime discovery passed through standard loader search paths"
