#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
project_root=$(CDPATH= cd -- "$script_dir/.." && pwd)

PATH="/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/local/sbin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"

build_dir=${OPENGLKHR_BUILD_DIR:-"$project_root/artifacts/build"}
mesa_build_dir=${OPENGLKHR_MESA_BUILD_DIR:-"$project_root/../mesa/build-ao46-asahi-arm64"}
mesa_khronos_build_dir=${OPENGLKHR_KHRONOS_MESA_BUILD_DIR:-"$project_root/artifacts/mesa-khronos-build"}
mesa_khronos_prefix=${OPENGLKHR_KHRONOS_MESA_PREFIX:-"$project_root/artifacts/mesa-khronos-prefix"}
mesa_demos_source_dir=${OPENGLKHR_MESA_DEMOS_SOURCE_DIR:-"$project_root/artifacts/mesa-demos-source"}
mesa_demos_build_dir=${OPENGLKHR_MESA_DEMOS_BUILD_DIR:-"$project_root/artifacts/mesa-demos-build"}
glxinfo_output_dir=${OPENGLKHR_GLXINFO_OUTPUT_DIR:-"$project_root/artifacts/glxinfo-bin"}
build_glxinfo=${OPENGLKHR_BUILD_GLXINFO:-1}
install_mode=${OPENGLKHR_INSTALL_MODE:-khronos}

case "$install_mode" in
    khronos)
        stage_dir=${OPENGLKHR_STAGE_DIR:-"$project_root/artifacts/stage-khronos"}
        stage_script="$script_dir/stage_khronos_layout.sh"
        install_script="$script_dir/install_khronos_layout.sh"
        ;;
    legacy-system)
        stage_dir=${OPENGLKHR_STAGE_DIR:-"$project_root/artifacts/stage-legacy-system"}
        stage_script="$script_dir/stage_personal_layout.sh"
        install_script="$script_dir/install_system_layout.sh"
        ;;
    *)
        echo "unsupported OPENGLKHR_INSTALL_MODE: $install_mode (expected khronos or legacy-system)" >&2
        exit 1
        ;;
esac

if ! command -v cmake >/dev/null 2>&1; then
    echo "cmake is required to build the OpenGLKHR ICD source tree" >&2
    exit 1
fi

if [ "$install_mode" = khronos ]; then
    OPENGLKHR_BOOTSTRAP_ONLY=1 "$script_dir/bootstrap_mesa.sh"
else
    "$script_dir/bootstrap_mesa.sh"
fi
cmake -S "$project_root" -B "$build_dir" -DAO46_MESA_BUILD_DIR="$mesa_build_dir"
if [ "$install_mode" = khronos ]; then
    cmake --build "$build_dir" --target AO46MesaMetalBackend
    OPENGLKHR_AO46_BACKEND_DIR="$build_dir" \
    OPENGLKHR_AO46_BACKEND_INCLUDE_DIR="$project_root/khronos/include" \
    "$script_dir/build_mesa_khronos_frontend.sh" \
        "$project_root/../mesa" "$mesa_khronos_build_dir" "$mesa_khronos_prefix"
    glxinfo_binary=
    if [ "$build_glxinfo" = 1 ]; then
        "$script_dir/build_glxinfo_macos.sh" \
            "$mesa_demos_source_dir" "$mesa_demos_build_dir" "$glxinfo_output_dir"
        glxinfo_binary="$glxinfo_output_dir/glxinfo"
    elif [ "$build_glxinfo" != 0 ]; then
        echo "OPENGLKHR_BUILD_GLXINFO must be 0 or 1" >&2
        exit 1
    else
        echo "glxinfo build disabled; continuing with the core Khronos GL/EGL install"
    fi
    "$stage_script" "$mesa_khronos_prefix" "$build_dir" "$stage_dir" \
        "$glxinfo_binary"
else
    cmake --build "$build_dir"
    "$stage_script" "$build_dir" "$stage_dir"
fi
"$install_script" "$stage_dir"

echo "source build and $install_mode install complete"
