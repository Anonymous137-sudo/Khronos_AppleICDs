#!/bin/sh
set -eu

if [ "$#" -gt 1 ]; then
    echo "usage: $0 [user-space-prefix]" >&2
    exit 1
fi

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
project_root=$(CDPATH= cd -- "$script_dir/.." && pwd)
prefix=${1:-${OPENGLKHR_GLXINFO_PREFIX:-/usr/local}}
source_dir=${OPENGLKHR_MESA_DEMOS_SOURCE_DIR:-"$project_root/artifacts/mesa-demos-source"}
build_dir=${OPENGLKHR_MESA_DEMOS_BUILD_DIR:-"$project_root/artifacts/mesa-demos-build"}

case "$prefix" in
    /|/System|/System/*|/Library/Frameworks|/Library/Frameworks/*)
        echo "refusing glxinfo installation prefix that touches protected system locations: $prefix" >&2
        exit 1
        ;;
esac

"$script_dir/build_glxinfo_macos.sh" "$source_dir" "$build_dir" "$prefix/bin"

echo "installed upstream Mesa Demos glxinfo at $prefix/bin/glxinfo"
