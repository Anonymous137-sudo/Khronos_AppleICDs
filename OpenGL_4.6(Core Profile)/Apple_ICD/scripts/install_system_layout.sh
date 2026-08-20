#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

if [ "$#" -ne 1 ]; then
    echo "usage: $0 <staged-layout-root>" >&2
    exit 1
fi

stage_root=$1
dest_root=${OPENGLKHR_DESTROOT:-/}

sh "$script_dir/require_developer_mac.sh" "$dest_root"

framework_root="$dest_root/System/Library/Frameworks"
usr_local_lib="$dest_root/usr/local/lib"
open_gl46_src="$stage_root/System/Library/Frameworks/OpenGL_4.6.framework"
open_gl_src="$stage_root/System/Library/Frameworks/OpenGL.framework"
lib_src="$stage_root/usr/local/lib"
open_gl46_dst="$framework_root/OpenGL_4.6.framework"
open_gl_dst="$framework_root/OpenGL.framework"

if [ ! -d "$open_gl46_src" ]; then
    echo "missing staged framework: $open_gl46_src" >&2
    exit 1
fi

if [ ! -d "$open_gl_src" ]; then
    echo "missing staged OpenGL shim: $open_gl_src" >&2
    exit 1
fi

if [ ! -d "$lib_src" ]; then
    echo "missing staged user-space library directory: $lib_src" >&2
    exit 1
fi

mkdir -p "$framework_root" "$usr_local_lib"

rm -rf "$open_gl46_dst"
rm -rf "$open_gl_dst"
ditto "$open_gl46_src" "$open_gl46_dst"
ditto "$open_gl_src" "$open_gl_dst"

rm -f \
    "$usr_local_lib/libAO46LegacyGL.dylib" \
    "$usr_local_lib/libGLContext.dylib" \
    "$usr_local_lib/libGLICD.dylib" \
    "$usr_local_lib/libNSOpenGLContext.dylib" \
    "$usr_local_lib/libgl2mtl.dylib" \
    "$usr_local_lib/libAO46Core.dylib" \
    "$usr_local_lib/libAO46MesaMetalBackend.dylib" \
    "$usr_local_lib/libAO46MTLGallium.dylib" \
    "$usr_local_lib/libAO46AGXMetalAdapter.dylib"
ditto "$lib_src" "$usr_local_lib"

echo "installed OpenGLKHR ICD stack to $framework_root and $usr_local_lib"
