#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
runtime_prefix=${VULKANICD_KHR_RUNTIME_PREFIX:-${AVK143_RUNTIME_PREFIX:-/usr/local}}

case "$runtime_prefix" in
    ''|/)
        printf '%s\n' "VulkanICD_KHR runtime prefix must be a writable user-space prefix" >&2
        exit 1
        ;;
esac

"$script_dir/build-avk143-icd.sh"
exec "$script_dir/install-avk143-runtime.sh" --prefix "$runtime_prefix"
