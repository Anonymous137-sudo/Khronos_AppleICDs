#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
project_root=$(CDPATH= cd -- "$script_dir/.." && pwd)

PATH="/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/local/sbin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"

build_dir=${OPENGLKHR_BUILD_DIR:-"$project_root/artifacts/build"}
stage_dir=${OPENGLKHR_STAGE_DIR:-"$project_root/artifacts/stage"}
mesa_build_dir=${OPENGLKHR_MESA_BUILD_DIR:-"$project_root/../mesa/build"}

if ! command -v cmake >/dev/null 2>&1; then
    echo "cmake is required to build the OpenGLKHR ICD source tree" >&2
    exit 1
fi

"$script_dir/bootstrap_mesa.sh"
cmake -S "$project_root" -B "$build_dir" -DAO46_MESA_BUILD_DIR="$mesa_build_dir"
cmake --build "$build_dir"
"$script_dir/stage_personal_layout.sh" "$build_dir" "$stage_dir"
"$script_dir/install_system_layout.sh" "$stage_dir"

echo "source build and live install complete"
