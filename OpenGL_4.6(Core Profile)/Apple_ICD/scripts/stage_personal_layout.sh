#!/bin/sh
set -eu

if [ "$#" -ne 2 ]; then
    echo "usage: $0 <build-dir> <stage-root>" >&2
    exit 1
fi

build_dir=$1
stage_root=$2

open_gl_framework_root="$stage_root/System/Library/Frameworks/OpenGL.framework"
open_gl46_framework_root="$stage_root/System/Library/Frameworks/OpenGL_4.6.framework"
usr_local_lib="$stage_root/usr/local/lib"

mkdir -p "$open_gl_framework_root/Versions/A"
mkdir -p "$open_gl46_framework_root"
mkdir -p "$usr_local_lib"

if [ -d "$build_dir/OpenGL_4.6.framework" ]; then
    rm -rf "$open_gl46_framework_root"
    cp -R "$build_dir/OpenGL_4.6.framework" "$open_gl46_framework_root"
elif [ -d "$build_dir/OpenGL_4_6.framework" ]; then
    rm -rf "$open_gl46_framework_root"
    cp -R "$build_dir/OpenGL_4_6.framework" "$open_gl46_framework_root"
fi

if [ -f "$build_dir/OpenGL" ]; then
    cp "$build_dir/OpenGL" "$open_gl_framework_root/Versions/A/OpenGL"
fi

ln -sfn A "$open_gl_framework_root/Versions/Current"
ln -sfn Versions/Current/OpenGL "$open_gl_framework_root/OpenGL"

if [ -f "$build_dir/libGL.dylib" ]; then
    cp "$build_dir/libGL.dylib" "$usr_local_lib/libGL.dylib"
    ln -sfn libGL.dylib "$usr_local_lib/libGL.1.dylib"
fi

if [ -f "$build_dir/libGLContext.dylib" ]; then
    cp "$build_dir/libGLContext.dylib" "$usr_local_lib/libGLContext.dylib"
fi

if [ -f "$build_dir/libNSOpenGLContext.dylib" ]; then
    cp "$build_dir/libNSOpenGLContext.dylib" "$usr_local_lib/libNSOpenGLContext.dylib"
fi

if [ -f "$build_dir/libGLICD.dylib" ]; then
    cp "$build_dir/libGLICD.dylib" "$usr_local_lib/libGLICD.dylib"
fi

echo "staged OpenGL_4.6(Core Profile)/Apple_ICD layout at $stage_root"
