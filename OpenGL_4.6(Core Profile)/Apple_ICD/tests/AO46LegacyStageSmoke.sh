#!/bin/sh
set -eu

if [ "$#" -ne 1 ]; then
    echo "usage: $0 <stage-legacy-layout-script>" >&2
    exit 1
fi

stager=$1
root=$(mktemp -d "${TMPDIR:-/tmp}/ao46-legacy-stage.XXXXXX")
trap 'rm -rf "$root"' EXIT HUP INT TERM

build_dir="$root/build"
stage_root="$root/stage"
mkdir -p "$build_dir/OpenGL_4.6.framework" "$build_dir"

: >"$build_dir/OpenGL"
for file in \
    libAO46LegacyGL.dylib \
    libGLContext.dylib \
    libGLICD.dylib \
    libNSOpenGLContext.dylib \
    libAO46Core.dylib \
    libAO46MesaMetalBackend.dylib \
    libAO46MTLGallium.dylib \
    libAO46AGXMetalAdapter.dylib; do
    : >"$build_dir/$file"
done

sh "$stager" "$build_dir" "$stage_root"

test -f "$stage_root/usr/local/lib/libAO46LegacyGL.dylib"
test ! -e "$stage_root/usr/local/lib/libGL.dylib"
test ! -e "$stage_root/usr/local/lib/libGL.1.dylib"
test -f "$stage_root/usr/local/lib/libAO46MesaMetalBackend.dylib"
