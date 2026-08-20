#!/bin/sh
set -eu

if [ "$#" -ne 1 ]; then
    echo "usage: $0 <install-khronos-layout-script>" >&2
    exit 1
fi

installer=$1
root=$(mktemp -d "${TMPDIR:-/tmp}/ao46-khronos-install.XXXXXX")
trap 'rm -rf "$root"' EXIT HUP INT TERM

mesa_prefix="$root/mesa"
ao46_build="$root/ao46-build"
stage_root="$root/stage"
prefix="$root/prefix"
tool_dir="$root/tools"
install_name_log="$root/install-name.log"
mkdir -p "$mesa_prefix/lib" "$ao46_build" "$tool_dir"
mkdir -p "$stage_root/khronos/include/GL"
mkdir -p "$stage_root/khronos/include/EGL" "$stage_root/khronos/include/KHR"

# The fixture dylibs are intentionally empty files.  Record the Darwin
# install-name rewrites instead of running the host tool on those placeholders.
cat >"$tool_dir/install_name_tool" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$AO46_INSTALL_NAME_LOG"
EOF
chmod 0755 "$tool_dir/install_name_tool"

: >"$mesa_prefix/lib/libEGL.1.dylib"
ln -s libEGL.1.dylib "$mesa_prefix/lib/libEGL.dylib"
ln -s libEGL.1.dylib "$mesa_prefix/lib/libGL.dylib"
for file in libAO46MesaMetalBackend.dylib libAO46MTLGallium.dylib libAO46AGXMetalAdapter.dylib; do
    : >"$ao46_build/$file"
done
: >"$root/glxinfo"
chmod 0755 "$root/glxinfo"
for file in GL/glcorearb.h EGL/egl.h EGL/eglext.h EGL/eglplatform.h KHR/khrplatform.h; do
    : >"$stage_root/khronos/include/$file"
done

script_dir=$(CDPATH= cd -- "$(dirname -- "$installer")" && pwd)
PATH="$tool_dir:$PATH" AO46_INSTALL_NAME_LOG="$install_name_log" \
    "$script_dir/stage_khronos_layout.sh" "$mesa_prefix" "$ao46_build" "$stage_root" "$root/glxinfo"
PATH="$tool_dir:$PATH" AO46_INSTALL_NAME_LOG="$install_name_log" \
    OPENGLKHR_KHRONOS_PREFIX="$prefix" sh "$installer" "$stage_root"

test -f "$prefix/lib/libGL.dylib"
test -f "$prefix/lib/libEGL.dylib"
test -f "$prefix/lib/libEGL.1.dylib"
test "$(readlink "$prefix/lib/libGL.dylib")" = libEGL.1.dylib
test -f "$prefix/lib/openglkhr/libAO46MesaMetalBackend.dylib"
test -f "$prefix/include/GL/glcorearb.h"
test -f "$prefix/include/EGL/egl.h"
test -f "$prefix/include/KHR/khrplatform.h"
test -x "$prefix/bin/glxinfo"
test ! -e "$prefix/lib/libAO46Core.dylib"
test ! -e "$prefix/lib/libGLICD.dylib"
grep -q -- '-id @rpath/libEGL.1.dylib' "$install_name_log"
grep -Fq -- "-id $prefix/lib/libEGL.1.dylib" "$install_name_log"
