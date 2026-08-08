#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
project_root=$(CDPATH= cd -- "$script_dir/.." && pwd)

build_dir=${1:-"$project_root/artifacts/build"}
stage_dir=${2:-"$project_root/artifacts/stage"}
mesa_build_dir=${OPENGLKHR_MESA_BUILD_DIR:-"$project_root/../mesa/build-ao46-asahi-arm64"}

rm -rf "$build_dir" "$stage_dir"

"$script_dir/bootstrap_mesa.sh"
cmake -S "$project_root" -B "$build_dir" -DAO46_MESA_BUILD_DIR="$mesa_build_dir"
cmake --build "$build_dir"
"$script_dir/stage_personal_layout.sh" "$build_dir" "$stage_dir"

echo "local build artifacts available at $build_dir"
echo "local staged layout available at $stage_dir"
