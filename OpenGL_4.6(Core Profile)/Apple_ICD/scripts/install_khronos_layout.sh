#!/bin/sh
set -eu

if [ "$#" -ne 1 ]; then
    echo "usage: $0 <staged-layout-root>" >&2
    exit 1
fi

stage_root=$1
prefix=${OPENGLKHR_KHRONOS_PREFIX:-/usr/local}
source_root="$stage_root/khronos"

case "$prefix" in
    /|/System|/System/*|/Library/Frameworks|/Library/Frameworks/*)
        echo "refusing Khronos installation prefix that touches protected system locations: $prefix" >&2
        exit 1
        ;;
esac

if [ ! -d "$source_root/lib" ] || [ ! -d "$source_root/include" ]; then
    echo "missing staged Khronos layout: $source_root" >&2
    exit 1
fi

mkdir -p "$prefix/lib" "$prefix/include"
ditto "$source_root/lib" "$prefix/lib"
ditto "$source_root/include" "$prefix/include"

# Resolve the staged rpath identity to the user's explicit installation
# prefix.  This avoids retaining the temporary Mesa build prefix in the
# installed standard ABI while keeping libGL.dylib and libEGL.dylib one image.
if ! command -v install_name_tool >/dev/null 2>&1; then
    echo "install_name_tool is required to install the Darwin Khronos ABI" >&2
    exit 1
fi
install_name_tool -id "$prefix/lib/libEGL.1.dylib" "$prefix/lib/libEGL.1.dylib"

if [ -d "$source_root/bin" ]; then
    mkdir -p "$prefix/bin"
    ditto "$source_root/bin" "$prefix/bin"
fi

echo "installed standard Khronos GL/EGL ABI under $prefix"
echo "SIP and Authenticated Root were not queried because no system framework was replaced"
