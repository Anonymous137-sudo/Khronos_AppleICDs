#!/bin/sh
set -eu

if [ "$#" -ne 5 ]; then
    echo "usage: $0 <cmake> <khronos-stage-script> <legacy-stage-script> <mesa-build-script> <mesa-root>" >&2
    exit 1
fi

cmake_file=$1
khronos_stage=$2
legacy_stage=$3
mesa_build=$4
mesa_root=$5

grep -q 'OUTPUT_NAME "libAO46LegacyGL"' "$cmake_file"
! grep -q 'add_library(LibEGLDriver' "$cmake_file"
! grep -q 'AO46EGL.c' "$cmake_file"

grep -q 'libAO46LegacyGL.dylib' "$legacy_stage"
! grep -q 'libAO46Core.dylib' "$khronos_stage"
! grep -q 'libGLICD.dylib' "$khronos_stage"
grep -q -- '-Degl=enabled' "$mesa_build"
grep -q -- '-Dglx=disabled' "$mesa_build"
grep -q -- '-Dglvnd=disabled' "$mesa_build"
grep -q -- '-Dao46mtl-backend-path=' "$mesa_build"
grep -q -- '-Dao46mtl-include-path=' "$mesa_build"
! grep -q -- '-Dglx=dri' "$mesa_build"
! grep -q 'standard ABI is frozen' "$mesa_build"
grep -q 'glxinfo-binary' "$khronos_stage"
grep -q "'ao46mtl-backend-path'" "$mesa_root/meson.options"
test -f "$mesa_root/src/gallium/drivers/ao46mtl/ao46mtl_screen.c"
test -f "$mesa_root/src/egl/drivers/ao46mtl/egl_ao46mtl.c"

echo "AO46 frontend split audit passed"
