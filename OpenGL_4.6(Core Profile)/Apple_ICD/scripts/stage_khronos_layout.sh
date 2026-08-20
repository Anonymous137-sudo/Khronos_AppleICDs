#!/bin/sh
set -eu

if [ "$#" -ne 3 ] && [ "$#" -ne 4 ]; then
    echo "usage: $0 <mesa-install-prefix> <ao46-build-dir> <stage-root> [glxinfo-binary]" >&2
    exit 1
fi

mesa_prefix=$1
build_dir=$2
stage_root=$3
glxinfo_binary=${4:-}
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
project_root=$(CDPATH= cd -- "$script_dir/.." && pwd)
mesa_root=${OPENGLKHR_MESA_ROOT:-"$project_root/../mesa"}
layout_root="$stage_root/khronos"
lib_dir="$layout_root/lib"
backend_lib_dir="$lib_dir/openglkhr"
include_dir="$layout_root/include"

mesa_lib_dir="$mesa_prefix/lib"
if [ ! -d "$mesa_lib_dir" ]; then
    echo "missing Mesa standard-library directory: $mesa_lib_dir" >&2
    exit 1
fi

for library in libEGL.1.dylib libEGL.dylib libGL.dylib; do
    if [ ! -f "$mesa_lib_dir/$library" ]; then
        echo "missing Mesa Khronos ABI library: $mesa_lib_dir/$library" >&2
        exit 1
    fi
done

for library in \
    libAO46MesaMetalBackend.dylib \
    libAO46MTLGallium.dylib \
    libAO46AGXMetalAdapter.dylib; do
    if [ ! -f "$build_dir/$library" ]; then
        echo "missing AO46 Khronos backend library: $build_dir/$library" >&2
        exit 1
    fi
done

for header in \
    "$mesa_root/include/GL/glcorearb.h" \
    "$mesa_root/include/EGL/egl.h" \
    "$mesa_root/include/EGL/eglext.h" \
    "$mesa_root/include/EGL/eglplatform.h" \
    "$mesa_root/include/KHR/khrplatform.h"; do
    if [ ! -f "$header" ]; then
        echo "missing Khronos header: $header" >&2
        exit 1
    fi
done

if [ -n "$glxinfo_binary" ] && [ ! -x "$glxinfo_binary" ]; then
    echo "missing executable glxinfo diagnostic: $glxinfo_binary" >&2
    exit 1
fi

rm -rf "$layout_root"
mkdir -p "$lib_dir" "$backend_lib_dir" \
    "$include_dir/GL" "$include_dir/EGL" "$include_dir/KHR"

for library in libEGL.1.dylib libEGL.dylib; do
    cp -R "$mesa_lib_dir/$library" "$lib_dir/$library"
done
ln -sfn libEGL.1.dylib "$lib_dir/libGL.dylib"

# Meson records the temporary build prefix as the installed dylib identity on
# Darwin.  The staged product is relocatable, so keep an rpath identity here;
# install_khronos_layout.sh replaces it with the selected final user prefix.
if ! command -v install_name_tool >/dev/null 2>&1; then
    echo "install_name_tool is required to stage the Darwin Khronos ABI" >&2
    exit 1
fi
install_name_tool -id '@rpath/libEGL.1.dylib' "$lib_dir/libEGL.1.dylib"

for library in \
    libAO46MesaMetalBackend.dylib \
    libAO46MTLGallium.dylib \
    libAO46AGXMetalAdapter.dylib; do
    cp "$build_dir/$library" "$backend_lib_dir/$library"
done

install -m 0644 "$mesa_root/include/GL/glcorearb.h" "$include_dir/GL/glcorearb.h"
install -m 0644 "$mesa_root/include/EGL/egl.h" "$include_dir/EGL/egl.h"
install -m 0644 "$mesa_root/include/EGL/eglext.h" "$include_dir/EGL/eglext.h"
install -m 0644 "$mesa_root/include/EGL/eglplatform.h" "$include_dir/EGL/eglplatform.h"
install -m 0644 "$mesa_root/include/KHR/khrplatform.h" "$include_dir/KHR/khrplatform.h"

if [ -n "$glxinfo_binary" ]; then
    mkdir -p "$layout_root/bin"
    install -m 0755 "$glxinfo_binary" "$layout_root/bin/glxinfo"
fi

echo "staged Mesa-owned standard Khronos OpenGL/EGL layout at $layout_root"
