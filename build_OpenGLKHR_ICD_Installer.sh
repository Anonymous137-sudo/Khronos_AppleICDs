#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
project_root="$script_dir/OpenGL_4.6(Core Profile)/Apple_ICD"

exec "$project_root/scripts/build_installer_pkg.sh" "$@"
