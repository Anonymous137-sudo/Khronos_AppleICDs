#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
project_root="$script_dir/Vulkan_API_SDK_1.4.354/Apple_ICD"

exec "$project_root/scripts/build_vulkanicd_khrinstaller_pkg.sh" "$@"
