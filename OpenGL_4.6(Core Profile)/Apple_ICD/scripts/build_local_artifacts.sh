#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
project_root=$(CDPATH= cd -- "$script_dir/.." && pwd)

build_dir=${1:-"$project_root/artifacts/build"}
stage_dir=${2:-"$project_root/artifacts/stage"}

rm -rf "$build_dir" "$stage_dir"

cmake -S "$project_root" -B "$build_dir"
cmake --build "$build_dir"
"$script_dir/stage_personal_layout.sh" "$build_dir" "$stage_dir"

echo "local build artifacts available at $build_dir"
echo "local staged layout available at $stage_dir"
