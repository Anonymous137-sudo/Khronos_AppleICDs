#!/bin/sh
set -eu

if [ "$#" -ne 3 ]; then
    echo "usage: $0 <mesa-root> <mesa-build-dir> <mesa-install-prefix>" >&2
    exit 1
fi

mesa_root=$1
mesa_build_dir=$2
mesa_install_prefix=$3
driver=${OPENGLKHR_KHRONOS_MESA_DRIVER:-ao46mtl}
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
project_root=$(CDPATH= cd -- "$script_dir/.." && pwd)
backend_dir=${OPENGLKHR_AO46_BACKEND_DIR:-"$project_root/artifacts/build"}
backend_include_dir=${OPENGLKHR_AO46_BACKEND_INCLUDE_DIR:-"$project_root/khronos/include"}

if [ ! -f "$mesa_root/meson.build" ]; then
    echo "missing Mesa source tree: $mesa_root" >&2
    exit 1
fi

if [ ! -f "$mesa_root/src/gallium/drivers/$driver/meson.build" ]; then
    echo "Mesa driver '$driver' is not registered in $mesa_root" >&2
    exit 1
fi

if [ ! -f "$backend_dir/libAO46MesaMetalBackend.dylib" ]; then
    echo "missing AO46 Mesa backend: $backend_dir/libAO46MesaMetalBackend.dylib" >&2
    exit 1
fi

if [ ! -f "$backend_include_dir/AO46MesaMetalBackend.h" ]; then
    echo "missing AO46 Mesa backend header: $backend_include_dir/AO46MesaMetalBackend.h" >&2
    exit 1
fi

if ! command -v meson >/dev/null 2>&1; then
    echo "meson is required to build Mesa's standard libGL/libEGL frontend" >&2
    exit 1
fi

if [ -x /opt/homebrew/opt/bison/bin/bison ]; then
    PATH="/opt/homebrew/opt/bison/bin:$PATH"
fi

# Do not enable Mesa's Darwin GLX target here. It loads Apple's legacy
# OpenGL.framework/CGL implementation and would merge the two frontend
# products. AO46's built-in EGL driver and libGL alias share Mesa glapi.
meson setup --wipe "$mesa_build_dir" "$mesa_root" \
    --prefix "$mesa_install_prefix" \
    -Dopengl=true \
    -Degl=enabled \
    -Dglx=disabled \
    -Dgles1=disabled \
    -Dgles2=disabled \
    -Dglvnd=disabled \
    -Dgallium-drivers="$driver" \
    -Dvulkan-drivers= \
    -Dtools= \
    -Dplatforms=macos \
    -Dao46mtl-backend-path="$backend_dir" \
    -Dao46mtl-include-path="$backend_include_dir"
meson compile -C "$mesa_build_dir"
meson install -C "$mesa_build_dir"

test -f "$mesa_install_prefix/lib/libEGL.dylib"

test -f "$mesa_install_prefix/lib/libGL.dylib"
test -f "$mesa_install_prefix/lib/libEGL.1.dylib"

echo "built Mesa-owned standard Khronos GL/EGL frontend at $mesa_install_prefix"
