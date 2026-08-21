#!/bin/sh
set -eu

if [ "$#" -ne 3 ]; then
    echo "usage: $0 <mesa-demos-source-cache> <mesa-demos-build-dir> <output-bin-dir>" >&2
    exit 1
fi

source_dir=$1
build_dir=$2
output_dir=$3
upstream_url=${OPENGLKHR_MESA_DEMOS_URL:-https://gitlab.freedesktop.org/mesa/demos.git}
revision=${OPENGLKHR_MESA_DEMOS_REVISION:-10418e7636cdd9595dda18c3d78a562d7248f734}

# XQuartz installs a complete X11/GL development prefix under /opt/X11. Keep
# it ahead of other pkg-config providers so glxinfo is linked consistently to
# the XQuartz client libraries instead of an unrelated MacPorts installation.
if [ -f /opt/X11/lib/pkgconfig/x11.pc ] && [ -f /opt/X11/lib/pkgconfig/gl.pc ]; then
    PKG_CONFIG_PATH="/opt/X11/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
    CPPFLAGS="-I/opt/X11/include${CPPFLAGS:+ $CPPFLAGS}"
    LDFLAGS="-L/opt/X11/lib${LDFLAGS:+ $LDFLAGS}"
    export PKG_CONFIG_PATH CPPFLAGS LDFLAGS
fi

if ! command -v git >/dev/null 2>&1; then
    echo "git is required to fetch the upstream Mesa Demos glxinfo source" >&2
    exit 1
fi

if ! command -v meson >/dev/null 2>&1; then
    echo "meson is required to build the upstream Mesa Demos glxinfo target" >&2
    exit 1
fi

if ! command -v pkg-config >/dev/null 2>&1; then
    echo "pkg-config is required to locate an X11/GLX provider" >&2
    exit 1
fi

if ! pkg-config --exists x11 gl; then
    echo "glxinfo requires X11 and GL development packages (XQuartz or MacPorts)" >&2
    exit 1
fi

if [ -e "$source_dir" ] && [ ! -d "$source_dir/.git" ]; then
    echo "Mesa Demos source cache is not a Git checkout: $source_dir" >&2
    exit 1
fi

if [ ! -d "$source_dir/.git" ]; then
    mkdir -p "$(dirname -- "$source_dir")"
    git init -q "$source_dir"
fi

# Fetch the pinned source directly. This also supports caller-provided clones
# whose upstream remote has a name other than "origin".
git -C "$source_dir" fetch --depth=1 "$upstream_url" "$revision" >/dev/null
git -C "$source_dir" checkout --detach FETCH_HEAD >/dev/null

# glxinfo is an X11/GLX utility. Build only the upstream target, with every
# unrelated Mesa Demos frontend disabled, so it cannot acquire AO46 CGL state.
meson setup "$build_dir" "$source_dir" --wipe \
    -Dgl=enabled \
    -Dx11=enabled \
    -Degl=disabled \
    -Dgles1=disabled \
    -Dgles2=disabled \
    -Dglut=disabled \
    -Dglvnd=disabled \
    -Dlibdrm=disabled \
    -Dpng=disabled \
    -Dvulkan=disabled \
    -Dwayland=disabled
meson compile -C "$build_dir" glxinfo

glxinfo_binary="$build_dir/src/xdemos/glxinfo"
if [ ! -x "$glxinfo_binary" ]; then
    echo "Mesa Demos did not produce glxinfo: $glxinfo_binary" >&2
    exit 1
fi

mkdir -p "$output_dir"
install -m 0755 "$glxinfo_binary" "$output_dir/glxinfo"
"$output_dir/glxinfo" -h >/dev/null

echo "built upstream Mesa Demos glxinfo at $output_dir/glxinfo"
