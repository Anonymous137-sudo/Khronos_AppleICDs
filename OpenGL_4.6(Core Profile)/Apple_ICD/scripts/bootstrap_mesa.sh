#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
project_root=$(CDPATH= cd -- "$script_dir/.." && pwd)
mesa_root=${OPENGLKHR_MESA_ROOT:-"$project_root/../mesa"}
mesa_build_dir=${OPENGLKHR_MESA_BUILD_DIR:-"$mesa_root/build"}
mesa_python_root=${OPENGLKHR_MESA_PYTHON_ROOT:-"$mesa_root/.ao46-python"}

# Mesa's macOS parser stack expects newer bison/flex than the system defaults.
PATH="/opt/homebrew/opt/bison/bin:/opt/homebrew/opt/flex/bin:/usr/local/opt/bison/bin:/usr/local/opt/flex/bin:/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/local/sbin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"

if [ ! -d "$mesa_root" ]; then
    echo "missing Mesa source tree: $mesa_root" >&2
    exit 1
fi

if ! command -v meson >/dev/null 2>&1; then
    echo "meson is required to bootstrap the Mesa build" >&2
    exit 1
fi

if [ -n "${OPENGLKHR_SKIP_MESA_BOOTSTRAP:-}" ]; then
    exit 0
fi

bootstrap_python=
for candidate in python3.14 python3.13 python3.12 python3.11 python3.10 python3; do
    if command -v "$candidate" >/dev/null 2>&1; then
        bootstrap_python=$(command -v "$candidate")
        break
    fi
done

if [ -z "$bootstrap_python" ]; then
    echo "a Python 3.10+ interpreter is required to bootstrap Mesa" >&2
    exit 1
fi

if ! command -v bison >/dev/null 2>&1; then
    echo "bison is required to bootstrap Mesa (install a newer Homebrew bison and ensure it is on PATH)" >&2
    exit 1
fi

if ! command -v flex >/dev/null 2>&1; then
    echo "flex is required to bootstrap Mesa" >&2
    exit 1
fi

if ! "$bootstrap_python" -c 'import re, subprocess, sys; out = subprocess.check_output(["bison", "--version"], text=True).splitlines()[0]; m = re.search(r"(\d+)\.(\d+)", out); sys.exit(0 if m and tuple(map(int, m.groups())) > (2, 3) else 1)'; then
    echo "Mesa requires bison newer than the system /usr/bin/bison 2.3. Install Homebrew bison and ensure its bin directory precedes /usr/bin on PATH." >&2
    exit 1
fi

if [ ! -x "$mesa_python_root/bin/python3" ]; then
    "$bootstrap_python" -m venv "$mesa_python_root"
fi

"$mesa_python_root/bin/python3" -m pip install --upgrade pip >/dev/null
"$mesa_python_root/bin/python3" -m pip install --upgrade mako packaging PyYAML >/dev/null

PATH="$mesa_python_root/bin:$PATH"

if [ -n "${OPENGLKHR_MESA_WIPE:-}" ]; then
    rm -rf "$mesa_build_dir"
fi

if [ -f "$mesa_build_dir/build.ninja" ] || [ -d "$mesa_build_dir/meson-info" ]; then
    meson setup \
        --wipe \
        "$mesa_build_dir" \
        "$mesa_root" \
        --buildtype=release \
        --default-library=static \
        -Dplatforms=macos \
        -Dgallium-drivers=softpipe \
        -Dglx=disabled \
        -Dllvm=disabled \
        -Dvulkan-drivers= \
        -Dgallium-rusticl=false
else
    meson setup \
        "$mesa_build_dir" \
        "$mesa_root" \
        --buildtype=release \
        --default-library=static \
        -Dplatforms=macos \
        -Dgallium-drivers=softpipe \
        -Dglx=disabled \
        -Dllvm=disabled \
        -Dvulkan-drivers= \
        -Dgallium-rusticl=false
fi

meson compile -C "$mesa_build_dir" \
    glapi \
    mesa \
    gallium \
    mesa_util \
    mesa_util_c11 \
    mesa_util_simd \
    compiler \
    nir \
    glsl \
    glsl_util \
    pipe_loader_static \
    softpipe
