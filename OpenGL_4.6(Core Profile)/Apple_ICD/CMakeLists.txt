cmake_minimum_required(VERSION 3.20)
project(Apple_ICD LANGUAGES C OBJC CXX)

include(CTest)

set(CMAKE_C_STANDARD 11)
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_C_STANDARD_REQUIRED ON)
set(CMAKE_C_EXTENSIONS OFF)

find_package(Python3 REQUIRED COMPONENTS Interpreter)
find_program(HOMEBREW_FLEX_EXECUTABLE NAMES flex
    PATHS /opt/homebrew/opt/flex/bin /usr/local/opt/flex/bin
    NO_DEFAULT_PATH
)
find_program(HOMEBREW_BISON_EXECUTABLE NAMES bison
    PATHS /opt/homebrew/opt/bison/bin /usr/local/opt/bison/bin
    NO_DEFAULT_PATH
)

if(HOMEBREW_FLEX_EXECUTABLE)
    set(FLEX_EXECUTABLE "${HOMEBREW_FLEX_EXECUTABLE}")
else()
    find_program(FLEX_EXECUTABLE NAMES flex REQUIRED)
endif()

if(HOMEBREW_BISON_EXECUTABLE)
    set(BISON_EXECUTABLE "${HOMEBREW_BISON_EXECUTABLE}")
else()
    find_program(BISON_EXECUTABLE NAMES bison REQUIRED)
endif()

# -------------------------------------------------------------
# 1. Paths
# -------------------------------------------------------------
set(ROOT_DIR "${CMAKE_CURRENT_SOURCE_DIR}")
set(MESA_ROOT "${ROOT_DIR}/../mesa")   # Mesa source tree (submodule)
set(AO46_MESA_BUILD_DIR "${MESA_ROOT}/build-ao46-asahi-arm64" CACHE PATH "Path to the Meson-built Mesa Asahi directory")
set(MESA_BUILD_DIR "${AO46_MESA_BUILD_DIR}")
option(OPENGLKHR_BUILD_DEPRECATED_GL2MTL
    "Build the deprecated GL2MTL development backend (never linked by OpenGL_4.6)"
    OFF
)
set(AO46_MESA_PYTHON
    "${MESA_ROOT}/.ao46-python/bin/python3"
)

file(GLOB AO46_SPIRV_TOOLS_INCLUDE_HINTS
    "/opt/homebrew/Cellar/spirv-tools/*/include"
    "/opt/homebrew/Cellar/molten-vk/*/libexec/include"
)

find_path(SPIRV_TOOLS_INCLUDE_DIR
    NAMES spirv-tools/libspirv.h
    PATHS
        /opt/homebrew/include
        /usr/local/include
        ${AO46_SPIRV_TOOLS_INCLUDE_HINTS}
)

find_library(SPIRV_TOOLS_LIB
    NAMES SPIRV-Tools
    PATHS /opt/homebrew/lib /usr/local/lib
)
find_library(SPIRV_TOOLS_OPT_LIB
    NAMES SPIRV-Tools-opt
    PATHS /opt/homebrew/lib /usr/local/lib
)
find_library(ZSTD_LIB
    NAMES zstd
    PATHS /opt/homebrew/lib /usr/local/lib
)
find_library(ZLIB_LIB
    NAMES z
)

if(EXISTS "${AO46_MESA_PYTHON}")
    set(AO46_PYTHON_EXECUTABLE "${AO46_MESA_PYTHON}")
else()
    set(AO46_PYTHON_EXECUTABLE "${Python3_EXECUTABLE}")
endif()

set(GLAPI_PUBLIC_GEN_DIR
    "${CMAKE_CURRENT_BINARY_DIR}/generated/glapi"
)
set(GLAPI_PUBLIC_SYMBOLS_FILE
    "${GLAPI_PUBLIC_GEN_DIR}/glapi-symbols.txt"
)
set(GLAPI_PUBLIC_MAPI_HEADER
    "${GLAPI_PUBLIC_GEN_DIR}/glapi_mapi_tmp.h"
)

file(MAKE_DIRECTORY "${GLAPI_PUBLIC_GEN_DIR}")

execute_process(
    COMMAND
        "${AO46_PYTHON_EXECUTABLE}"
        "${ROOT_DIR}/cmake/generate_glapi_symbols.py"
        "${MESA_ROOT}/src/mesa/glapi/glapi/registry/gl.xml"
        "${GLAPI_PUBLIC_SYMBOLS_FILE}"
    RESULT_VARIABLE GLAPI_PUBLIC_SYMBOLS_RESULT
    ERROR_VARIABLE GLAPI_PUBLIC_SYMBOLS_ERROR
)

if(NOT GLAPI_PUBLIC_SYMBOLS_RESULT EQUAL 0)
    message(FATAL_ERROR
        "Failed to generate ${GLAPI_PUBLIC_SYMBOLS_FILE}: ${GLAPI_PUBLIC_SYMBOLS_ERROR}"
    )
endif()

execute_process(
    COMMAND
        "${AO46_PYTHON_EXECUTABLE}"
        "${MESA_ROOT}/src/mesa/glapi/mapi_abi.py"
        --printer glapi
        --gl_symbols "${GLAPI_PUBLIC_SYMBOLS_FILE}"
        "${MESA_ROOT}/src/mesa/glapi/glapi/gen/gl_and_es_API.xml"
    OUTPUT_FILE "${GLAPI_PUBLIC_MAPI_HEADER}"
    RESULT_VARIABLE GLAPI_PUBLIC_MAPI_RESULT
    ERROR_VARIABLE GLAPI_PUBLIC_MAPI_ERROR
)

if(NOT GLAPI_PUBLIC_MAPI_RESULT EQUAL 0)
    message(FATAL_ERROR
        "Failed to generate ${GLAPI_PUBLIC_MAPI_HEADER}: ${GLAPI_PUBLIC_MAPI_ERROR}"
    )
endif()
set(MESA_INCLUDE_DIRS
    "${ROOT_DIR}/vendor/MGL/include"
    "${MESA_BUILD_DIR}/include"
    "${MESA_BUILD_DIR}/src"
    "${MESA_BUILD_DIR}/src/compiler"
    "${MESA_BUILD_DIR}/src/compiler/glsl"
    "${MESA_BUILD_DIR}/src/compiler/nir"
    "${MESA_BUILD_DIR}/src/compiler/spirv"
    "${MESA_BUILD_DIR}/src/gallium/auxiliary"
    "${MESA_BUILD_DIR}/src/mesa"
    "${MESA_BUILD_DIR}/src/mesa/program"
    "${MESA_BUILD_DIR}/src/util"
    "${MESA_BUILD_DIR}/src/util/format"
    "${MESA_ROOT}/include"
    "${MESA_ROOT}/src"
    "${MESA_ROOT}/src/compiler"
    "${MESA_ROOT}/src/compiler/spirv"
    "${MESA_ROOT}/src/mesa"
    "${MESA_ROOT}/src/mesa/glapi"
    "${MESA_ROOT}/src/mesa/main"
    "${MESA_ROOT}/src/mesa/program"
    "${MESA_ROOT}/src/gallium/auxiliary"
    "${MESA_ROOT}/src/gallium/include"
    "${MESA_ROOT}/src/compiler/nir"
    "${MESA_ROOT}/src/compiler/glsl"
    "${MESA_ROOT}/src/util"
    "${MESA_ROOT}/src/kosmickrisp"
    # Add KosmicKrisp if it lives inside Mesa (adjust path if needed)
    "${MESA_ROOT}/src/kosmickrisp/compiler"  # for nir_to_msl.h
)

set(MESA_COMPILE_DEFINITIONS
    NDEBUG
    __STDC_CONSTANT_MACROS
    __STDC_FORMAT_MACROS
    __STDC_LIMIT_MACROS
    HAVE_OPENGL=1
    HAVE_OPENGL_ES_1=1
    HAVE_OPENGL_ES_2=1
    HAVE_SOFTPIPE
    HAVE_SWRAST
    MESA_SYSTEM_HAS_KMS_DRM=0
    BUILDING_MESA
    VK_ENABLE_BETA_EXTENSIONS
    VIDEO_CODEC_VC1DEC=0
    VIDEO_CODEC_H264DEC=0
    VIDEO_CODEC_H264ENC=0
    VIDEO_CODEC_H265DEC=0
    VIDEO_CODEC_H265ENC=0
    VIDEO_CODEC_AV1DEC=1
    VIDEO_CODEC_AV1ENC=1
    VIDEO_CODEC_VP9DEC=1
    VIDEO_CODEC_MPEG12DEC=1
    VIDEO_CODEC_JPEGDEC=1
    HAVE_MACOS_PLATFORM
    USE_LIBGLVND=0
    HAVE_GFX_COMPUTE
    GLAPI_EXPORT_PROTO_ENTRY_POINTS=1
    ALLOW_KCMP
    MESA_DEBUG=0
    ENABLE_SHADER_CACHE
    HAVE___BUILTIN_BSWAP32
    HAVE___BUILTIN_BSWAP64
    HAVE___BUILTIN_CLZ
    HAVE___BUILTIN_CLZLL
    HAVE___BUILTIN_CTZ
    HAVE___BUILTIN_EXPECT
    HAVE___BUILTIN_FFS
    HAVE___BUILTIN_FFSLL
    HAVE___BUILTIN_POPCOUNT
    HAVE___BUILTIN_POPCOUNTLL
    HAVE___BUILTIN_UNREACHABLE
    HAVE___BUILTIN_TYPES_COMPATIBLE_P
    HAVE___BUILTIN_ADD_OVERFLOW
    HAVE_FUNC_ATTRIBUTE_CONST
    HAVE_FUNC_ATTRIBUTE_FLATTEN
    HAVE_FUNC_ATTRIBUTE_MALLOC
    HAVE_FUNC_ATTRIBUTE_PURE
    HAVE_FUNC_ATTRIBUTE_UNUSED
    HAVE_FUNC_ATTRIBUTE_WARN_UNUSED_RESULT
    HAVE_FUNC_ATTRIBUTE_WEAK
    HAVE_FUNC_ATTRIBUTE_FORMAT
    HAVE_FUNC_ATTRIBUTE_PACKED
    HAVE_FUNC_ATTRIBUTE_RETURNS_NONNULL
    HAVE_FUNC_ATTRIBUTE_NORETURN
    HAVE_FUNC_ATTRIBUTE_COLD
    HAVE_FUNC_ATTRIBUTE_VISIBILITY
    HAVE_UINT128
    HAVE_FMEMOPEN
    USE_GCC_ATOMIC_BUILTINS
    HAS_SCHED_H
    HAVE_SYS_SYSCTL_H
    HAVE_XLOCALE_H
    HAVE_DLFCN_H
    HAVE_SYS_SHM_H
    HAVE_CET_H
    HAVE_POLL_H
    HAVE_STRTOF
    HAVE_MKOSTEMP
    HAVE_FLOCK
    HAVE_STRTOK_R
    HAVE_SYSCONF
    HAVE_BSD_QSORT_R
    HAVE_STRUCT_TIMESPEC
    HAVE_POSIX_MEMALIGN
    HAVE_DIRENT_D_TYPE
    HAVE_STRTOD_L
    HAVE_DLADDR
    HAVE_ZLIB
    HAVE_ZSTD
    HAVE_COMPRESSION
    HAVE_PTHREAD
    DRAW_LLVM_AVAILABLE=1
    AMD_LLVM_AVAILABLE=0
    GALLIVM_USE_ORCJIT=0
    HAVE_SPIRV_TOOLS
    THREAD_SANITIZER=0
    HAVE_LIBUNWIND
    HAVE_RENDERDOC_INTEGRATION=0
    XXH_FORCE_ALIGN_CHECK=0
    XXH_FORCE_MEMORY_ACCESS=0
)

# -------------------------------------------------------------
# 2. Find Mesa static libraries (built via Meson)
# -------------------------------------------------------------
find_library(MESA_GLAPI_LIB       NAMES glapi          PATHS "${MESA_BUILD_DIR}/src/mesa/glapi/shared-glapi" NO_DEFAULT_PATH)
find_library(MESA_ST_MESA_LIB     NAMES mesa           PATHS "${MESA_BUILD_DIR}/src/mesa" NO_DEFAULT_PATH)
find_library(MESA_GALLIUM_AUX     NAMES gallium        PATHS "${MESA_BUILD_DIR}/src/gallium/auxiliary" NO_DEFAULT_PATH)
find_library(MESA_UTIL_LIB        NAMES mesa_util mesautil PATHS "${MESA_BUILD_DIR}/src/util" NO_DEFAULT_PATH)
find_library(MESA_UTIL_C11_LIB    NAMES mesa_util_c11  PATHS "${MESA_BUILD_DIR}/src/c11/impl" NO_DEFAULT_PATH)
find_library(MESA_UTIL_SIMD_LIB   NAMES mesa_util_simd PATHS "${MESA_BUILD_DIR}/src/util" NO_DEFAULT_PATH)
find_library(MESA_COMPILER_LIB    NAMES compiler       PATHS "${MESA_BUILD_DIR}/src/compiler" NO_DEFAULT_PATH)
find_library(MESA_NIR_LIB         NAMES nir            PATHS "${MESA_BUILD_DIR}/src/compiler/nir" NO_DEFAULT_PATH)
find_library(MESA_GLSL_UTIL_LIB   NAMES glsl_util      PATHS "${MESA_BUILD_DIR}/src/compiler/glsl" NO_DEFAULT_PATH)
find_library(MESA_GLSL_LIB        NAMES glsl           PATHS "${MESA_BUILD_DIR}/src/compiler/glsl" NO_DEFAULT_PATH)
find_library(MESA_ASAHI_GALLIUM_LIB NAMES asahi
    PATHS "${MESA_BUILD_DIR}/src/gallium/drivers/asahi" NO_DEFAULT_PATH)
find_library(MESA_ASAHI_COMPILER_LIB NAMES asahi_compiler
    PATHS "${MESA_BUILD_DIR}/src/asahi/compiler" NO_DEFAULT_PATH)
find_library(MESA_ASAHI_CORE_LIB NAMES asahi_lib
    PATHS "${MESA_BUILD_DIR}/src/asahi/lib" NO_DEFAULT_PATH)
find_library(MESA_ASAHI_LAYOUT_LIB NAMES asahi_layout
    PATHS "${MESA_BUILD_DIR}/src/asahi/layout" NO_DEFAULT_PATH)
find_library(MESA_POLY_NIR_LIB NAMES libpoly_nir
    PATHS "${MESA_BUILD_DIR}/src/poly/nir" NO_DEFAULT_PATH)
find_library(MESA_ASAHI_MACOS_WINSYS_LIB NAMES asahi_macos_winsys
    PATHS "${MESA_BUILD_DIR}/src/asahi/lib" NO_DEFAULT_PATH)
find_library(MESA_BLAKE3_LIB NAMES blake3
    PATHS "${MESA_BUILD_DIR}/src/util/blake3" NO_DEFAULT_PATH)
find_library(LLVM_LIB NAMES LLVM LLVM-22
    PATHS /opt/homebrew/opt/llvm/lib /usr/local/opt/llvm/lib NO_DEFAULT_PATH)

# If not found, the user must build Mesa first or adjust paths.
if(NOT MESA_GLAPI_LIB OR
   NOT MESA_ST_MESA_LIB OR
   NOT MESA_GALLIUM_AUX OR
   NOT MESA_UTIL_LIB OR
   NOT MESA_UTIL_C11_LIB OR
   NOT MESA_UTIL_SIMD_LIB OR
   NOT MESA_COMPILER_LIB OR
   NOT MESA_NIR_LIB OR
   NOT MESA_GLSL_UTIL_LIB OR
   NOT MESA_GLSL_LIB OR
   NOT MESA_ASAHI_GALLIUM_LIB OR
   NOT MESA_ASAHI_COMPILER_LIB OR
   NOT MESA_ASAHI_CORE_LIB OR
   NOT MESA_ASAHI_LAYOUT_LIB OR
   NOT MESA_POLY_NIR_LIB OR
   NOT MESA_ASAHI_MACOS_WINSYS_LIB OR
   NOT MESA_BLAKE3_LIB OR
   NOT LLVM_LIB)
    message(FATAL_ERROR
        "Required Mesa/Asahi archives were not found under '${MESA_BUILD_DIR}'. "
        "OpenGL_4.6 has no GL2MTL or softpipe runtime fallback. Run "
        "scripts/bootstrap_mesa.sh after completing the macOS Asahi winsys "
        "port, or point AO46_MESA_BUILD_DIR at a completed Asahi build with "
        "LLVM and BLAKE3 available.")
endif()

if(NOT SPIRV_TOOLS_INCLUDE_DIR OR NOT SPIRV_TOOLS_LIB OR NOT ZSTD_LIB OR NOT ZLIB_LIB)
    message(FATAL_ERROR
        "Required framework-side dependencies were not found. "
        "Need SPIR-V Tools headers/library plus zstd and zlib.")
endif()

# -------------------------------------------------------------
# 3. Public headers (for framework)
# -------------------------------------------------------------
set(AO46_FRAMEWORK_PUBLIC_HEADERS
    "${CMAKE_CURRENT_SOURCE_DIR}/framework/include/OpenGL_4_6.h"
    "${CMAKE_CURRENT_SOURCE_DIR}/runtime/include/AppleOpenGL46Runtime.h"
    "${CMAKE_CURRENT_SOURCE_DIR}/vendor/MGL/include/GL/glcorearb.h"   # keep for type definitions
)

set(AO46_FRAMEWORK_MODULEMAP
    "${CMAKE_CURRENT_SOURCE_DIR}/framework/Modules/module.modulemap"
)

# -------------------------------------------------------------
# 4. Runtime + Bridge (MesaPlatform)
# -------------------------------------------------------------
add_library(OpenGL46RuntimeObjects OBJECT
    runtime/src/AppleOpenGL46Runtime.c
    MesaPlatform/AO46MesaBridge.c
    MesaPlatform/AppleOpenGLAsahi.c
    "${MESA_ROOT}/src/asahi/lib/agx_macos_device.c"
    "${MESA_ROOT}/src/asahi/lib/agx_macos_bo.c"
    "${MESA_ROOT}/src/asahi/lib/agx_macos_queue.c"
    "${MESA_ROOT}/src/asahi/lib/agx_macos_command.c"
    "${MESA_ROOT}/src/asahi/lib/agx_macos_submission_observation.c"
    "${MESA_ROOT}/src/asahi/lib/agx_macos_submission_lease.c"
    "${MESA_ROOT}/src/asahi/lib/agx_macos_iosurface.m"
    "${MESA_ROOT}/src/asahi/lib/agx_macos_screen_bootstrap.c"
)

target_include_directories(OpenGL46RuntimeObjects
    PUBLIC
        runtime/include
        MesaPlatform
        "${MESA_INCLUDE_DIRS}"
)

target_compile_definitions(OpenGL46RuntimeObjects
    PRIVATE
        ${MESA_COMPILE_DEFINITIONS}
)

# -------------------------------------------------------------
# 5. Metal Shader Translation (NIR -> MSL)
# -------------------------------------------------------------
set(AO46_MSL_NIR_ALGEBRAIC_C
    "${CMAKE_CURRENT_BINARY_DIR}/generated/msl_nir_algebraic.c"
)

add_custom_command(
    OUTPUT "${AO46_MSL_NIR_ALGEBRAIC_C}"
    COMMAND "${CMAKE_COMMAND}" -E make_directory "${CMAKE_CURRENT_BINARY_DIR}/generated"
    COMMAND /bin/sh -c "\"${AO46_PYTHON_EXECUTABLE}\" \"${MESA_ROOT}/src/kosmickrisp/compiler/msl_nir_algebraic.py\" -p \"${MESA_ROOT}/src/compiler/nir\" > \"${AO46_MSL_NIR_ALGEBRAIC_C}\""
    DEPENDS
        "${MESA_ROOT}/src/kosmickrisp/compiler/msl_nir_algebraic.py"
        "${MESA_ROOT}/src/compiler/nir/nir_algebraic.py"
    VERBATIM
)

if(OPENGLKHR_BUILD_DEPRECATED_GL2MTL)
add_library(AO46MetalMSLCompiler STATIC EXCLUDE_FROM_ALL
    "${AO46_MSL_NIR_ALGEBRAIC_C}"
    "${MESA_ROOT}/src/kosmickrisp/compiler/nir_to_msl.c"
    "${MESA_ROOT}/src/kosmickrisp/compiler/msl_type_inference.c"
    "${MESA_ROOT}/src/kosmickrisp/compiler/msl_iomap.c"
    "${MESA_ROOT}/src/kosmickrisp/compiler/msl_nir_gather_common.c"
    "${MESA_ROOT}/src/kosmickrisp/compiler/msl_nir_lower_common.c"
    "${MESA_ROOT}/src/kosmickrisp/compiler/msl_nir_lower_subgroups.c"
    "${MESA_ROOT}/src/util/blake3/blake3.c"
    "${MESA_ROOT}/src/util/blake3/blake3_dispatch.c"
    "${MESA_ROOT}/src/util/blake3/blake3_portable.c"
    "${MESA_ROOT}/src/util/blake3/blake3_neon.c"
)

target_include_directories(AO46MetalMSLCompiler
    PRIVATE
        "${MESA_INCLUDE_DIRS}"
)

target_compile_definitions(AO46MetalMSLCompiler
    PRIVATE
        ${MESA_COMPILE_DEFINITIONS}
)
endif()

# -------------------------------------------------------------
# 6. Mesa Companion Libraries (glcpp + SPIR-V/vtn)
# -------------------------------------------------------------
set(AO46_GLCPP_GEN_DIR
    "${CMAKE_CURRENT_BINARY_DIR}/generated/glcpp"
)
set(AO46_GLCPP_PARSE_C
    "${AO46_GLCPP_GEN_DIR}/glcpp-parse.c"
)
set(AO46_GLCPP_PARSE_H
    "${AO46_GLCPP_GEN_DIR}/glcpp-parse.h"
)
set(AO46_GLCPP_LEX_C
    "${AO46_GLCPP_GEN_DIR}/glcpp-lex.c"
)

add_custom_command(
    OUTPUT "${AO46_GLCPP_PARSE_C}" "${AO46_GLCPP_PARSE_H}"
    COMMAND "${CMAKE_COMMAND}" -E make_directory "${AO46_GLCPP_GEN_DIR}"
    COMMAND "${BISON_EXECUTABLE}" -o "${AO46_GLCPP_PARSE_C}" -p glcpp_parser_ "--defines=${AO46_GLCPP_PARSE_H}" "${MESA_ROOT}/src/compiler/glsl/glcpp/glcpp-parse.y"
    DEPENDS "${MESA_ROOT}/src/compiler/glsl/glcpp/glcpp-parse.y"
    VERBATIM
)

add_custom_command(
    OUTPUT "${AO46_GLCPP_LEX_C}"
    COMMAND "${CMAKE_COMMAND}" -E make_directory "${AO46_GLCPP_GEN_DIR}"
    COMMAND "${FLEX_EXECUTABLE}" -o "${AO46_GLCPP_LEX_C}" "${MESA_ROOT}/src/compiler/glsl/glcpp/glcpp-lex.l"
    DEPENDS "${MESA_ROOT}/src/compiler/glsl/glcpp/glcpp-lex.l" "${AO46_GLCPP_PARSE_H}"
    VERBATIM
)

add_library(AO46MesaGLCPP STATIC
    "${AO46_GLCPP_PARSE_C}"
    "${AO46_GLCPP_PARSE_H}"
    "${AO46_GLCPP_LEX_C}"
    "${MESA_ROOT}/src/compiler/glsl/glcpp/pp.c"
)

target_include_directories(AO46MesaGLCPP
    PRIVATE
        "${MESA_INCLUDE_DIRS}"
        "${MESA_ROOT}/src/compiler/glsl/glcpp"
        "${AO46_GLCPP_GEN_DIR}"
)

target_compile_definitions(AO46MesaGLCPP
    PRIVATE
        ${MESA_COMPILE_DEFINITIONS}
)

set(AO46_SPIRV_GEN_DIR
    "${CMAKE_CURRENT_BINARY_DIR}/generated/spirv"
)
set(AO46_SPIRV_INFO_C
    "${AO46_SPIRV_GEN_DIR}/spirv_info.c"
)
set(AO46_SPIRV_INFO_H
    "${AO46_SPIRV_GEN_DIR}/spirv_info.h"
)
set(AO46_VTN_GATHER_TYPES_C
    "${AO46_SPIRV_GEN_DIR}/vtn_gather_types.c"
)
set(AO46_VTN_GENERATOR_IDS_H
    "${AO46_SPIRV_GEN_DIR}/vtn_generator_ids.h"
)

add_custom_command(
    OUTPUT "${AO46_SPIRV_INFO_C}" "${AO46_SPIRV_INFO_H}"
    COMMAND "${CMAKE_COMMAND}" -E make_directory "${AO46_SPIRV_GEN_DIR}"
    COMMAND "${AO46_PYTHON_EXECUTABLE}" "${MESA_ROOT}/src/compiler/spirv/spirv_info_gen.py" --json "${MESA_ROOT}/src/compiler/spirv/spirv.core.grammar.json" --out-h "${AO46_SPIRV_INFO_H}" --out-c "${AO46_SPIRV_INFO_C}"
    DEPENDS
        "${MESA_ROOT}/src/compiler/spirv/spirv_info_gen.py"
        "${MESA_ROOT}/src/compiler/spirv/spirv.core.grammar.json"
    VERBATIM
)

add_custom_command(
    OUTPUT "${AO46_VTN_GATHER_TYPES_C}"
    COMMAND "${CMAKE_COMMAND}" -E make_directory "${AO46_SPIRV_GEN_DIR}"
    COMMAND "${AO46_PYTHON_EXECUTABLE}" "${MESA_ROOT}/src/compiler/spirv/vtn_gather_types_c.py" "${MESA_ROOT}/src/compiler/spirv/spirv.core.grammar.json" "${AO46_VTN_GATHER_TYPES_C}"
    DEPENDS
        "${MESA_ROOT}/src/compiler/spirv/vtn_gather_types_c.py"
        "${MESA_ROOT}/src/compiler/spirv/spirv.core.grammar.json"
    VERBATIM
)

add_custom_command(
    OUTPUT "${AO46_VTN_GENERATOR_IDS_H}"
    COMMAND "${CMAKE_COMMAND}" -E make_directory "${AO46_SPIRV_GEN_DIR}"
    COMMAND "${AO46_PYTHON_EXECUTABLE}" "${MESA_ROOT}/src/compiler/spirv/vtn_generator_ids_h.py" "${MESA_ROOT}/src/compiler/spirv/spir-v.xml" "${AO46_VTN_GENERATOR_IDS_H}"
    DEPENDS
        "${MESA_ROOT}/src/compiler/spirv/vtn_generator_ids_h.py"
        "${MESA_ROOT}/src/compiler/spirv/spir-v.xml"
    VERBATIM
)

add_library(AO46MesaVTN STATIC
    "${AO46_SPIRV_INFO_C}"
    "${AO46_SPIRV_INFO_H}"
    "${AO46_VTN_GATHER_TYPES_C}"
    "${AO46_VTN_GENERATOR_IDS_H}"
    "${MESA_ROOT}/src/compiler/spirv/gl_spirv.c"
    "${MESA_ROOT}/src/compiler/spirv/spirv_to_nir.c"
    "${MESA_ROOT}/src/compiler/spirv/vtn_alu.c"
    "${MESA_ROOT}/src/compiler/spirv/vtn_amd.c"
    "${MESA_ROOT}/src/compiler/spirv/vtn_cfg.c"
    "${MESA_ROOT}/src/compiler/spirv/vtn_cmat.c"
    "${MESA_ROOT}/src/compiler/spirv/vtn_debug.c"
    "${MESA_ROOT}/src/compiler/spirv/vtn_glsl450.c"
    "${MESA_ROOT}/src/compiler/spirv/vtn_opencl.c"
    "${MESA_ROOT}/src/compiler/spirv/vtn_structured_cfg.c"
    "${MESA_ROOT}/src/compiler/spirv/vtn_subgroup.c"
    "${MESA_ROOT}/src/compiler/spirv/vtn_variables.c"
)

target_include_directories(AO46MesaVTN
    PRIVATE
        "${MESA_INCLUDE_DIRS}"
        "${SPIRV_TOOLS_INCLUDE_DIR}"
        "${AO46_SPIRV_GEN_DIR}"
)

target_compile_definitions(AO46MesaVTN
    PRIVATE
        ${MESA_COMPILE_DEFINITIONS}
)

# -------------------------------------------------------------
# 7. Archived GL2MTL Development Target
# -------------------------------------------------------------
# This target is intentionally outside the production framework dependency graph.
if(OPENGLKHR_BUILD_DEPRECATED_GL2MTL)
add_library(LibGL2MTLBackend SHARED EXCLUDE_FROM_ALL
    GL2MTL/mtl_driver.m
    GL2MTL/mtl_shader_compiler.m
)

target_include_directories(LibGL2MTLBackend
    PRIVATE
        GL2MTL
        "${MESA_INCLUDE_DIRS}"
)

target_compile_definitions(LibGL2MTLBackend
    PRIVATE
        ${MESA_COMPILE_DEFINITIONS}
)

target_link_libraries(LibGL2MTLBackend
    PRIVATE
        AO46MetalMSLCompiler
        ${MESA_GLSL_LIB}
        ${MESA_GLSL_UTIL_LIB}
        ${MESA_NIR_LIB}
        ${MESA_COMPILER_LIB}
        ${MESA_GALLIUM_AUX}
        ${MESA_UTIL_LIB}
        ${MESA_UTIL_SIMD_LIB}
        ${MESA_UTIL_C11_LIB}
        "-lc++"
        "-framework Metal"
        "-framework QuartzCore"
        "-framework AppKit"
        "-framework Foundation"
)

endif()

# -------------------------------------------------------------
# 8. Main Framework (OpenGL_4.6.framework)
# -------------------------------------------------------------
add_library(OpenGL_4_6 SHARED
    framework/src/OpenGL46Framework.c
    "${MESA_ROOT}/src/mesa/glapi/glapi/libgl_public.c"
    "${GLAPI_PUBLIC_MAPI_HEADER}"
    ${AO46_FRAMEWORK_PUBLIC_HEADERS}
    ${AO46_FRAMEWORK_MODULEMAP}
    $<TARGET_OBJECTS:OpenGL46RuntimeObjects>
)

target_include_directories(OpenGL_4_6
    PRIVATE
        runtime/include
        MesaPlatform
        "${GLAPI_PUBLIC_GEN_DIR}"
        "${MESA_INCLUDE_DIRS}"
)

target_compile_definitions(OpenGL_4_6
    PRIVATE
        ${MESA_COMPILE_DEFINITIONS}
)

target_link_libraries(OpenGL_4_6
    PRIVATE
        ${MESA_ST_MESA_LIB}
        ${MESA_GLAPI_LIB}
        ${MESA_GLSL_LIB}
        AO46MesaGLCPP
        ${MESA_GLSL_UTIL_LIB}
        ${MESA_NIR_LIB}
        ${MESA_COMPILER_LIB}
        AO46MesaVTN
        ${SPIRV_TOOLS_LIB}
        ${SPIRV_TOOLS_OPT_LIB}
        ${MESA_GALLIUM_AUX}
        ${MESA_ASAHI_GALLIUM_LIB}
        ${MESA_ASAHI_COMPILER_LIB}
        ${MESA_ASAHI_CORE_LIB}
        ${MESA_ASAHI_LAYOUT_LIB}
        ${MESA_POLY_NIR_LIB}
        ${MESA_ASAHI_MACOS_WINSYS_LIB}
        ${MESA_UTIL_LIB}
        ${MESA_BLAKE3_LIB}
        ${LLVM_LIB}
        ${ZSTD_LIB}
        ${ZLIB_LIB}
        ${MESA_UTIL_SIMD_LIB}
        ${MESA_UTIL_C11_LIB}
        # C++ standard library (Mesa uses C++)
        "-lc++"
        "-framework Foundation"
        "-framework IOKit"
        "-framework CoreFoundation"
        "-framework IOSurface"
)

set_target_properties(OpenGL_4_6 PROPERTIES
    FRAMEWORK TRUE
    FRAMEWORK_VERSION A
    OUTPUT_NAME "OpenGL_4.6"
    MACOSX_FRAMEWORK_IDENTIFIER "local.opengl46.driver"
    PUBLIC_HEADER "${AO46_FRAMEWORK_PUBLIC_HEADERS}"
)

# -------------------------------------------------------------
# 9. ICD (libGLICD.dylib) – remains a thin wrapper
# -------------------------------------------------------------
add_library(LibGLICDDriver SHARED
    icd/src/AppleOpenGLICD.c
)

target_include_directories(LibGLICDDriver
    PRIVATE
        runtime/include
        client/include
        icd/include
        "${MESA_INCLUDE_DIRS}"
)

target_link_libraries(LibGLICDDriver PRIVATE OpenGL46FrameworkClient)  # we need to define this next

# Note: We will keep AppleOpenGL46Client as a static library for the ICD to link against.

# -------------------------------------------------------------
# 10. Client (AppleOpenGL46Client) – used by ICD and shims
# -------------------------------------------------------------
add_library(OpenGL46FrameworkClient STATIC
    client/src/AppleOpenGL46Client.c
)

target_include_directories(OpenGL46FrameworkClient
    PUBLIC
        runtime/include
        client/include
        "${MESA_INCLUDE_DIRS}"
)

# Link the client to the framework (so it can dlopen it)
target_link_libraries(OpenGL46FrameworkClient PRIVATE OpenGL_4_6)

# -------------------------------------------------------------
# 11. Shim: CGL (AppleOpenGLShim) – the OpenGL.framework router
# -------------------------------------------------------------
add_library(AppleOpenGLShim SHARED
    shim/src/CGLShim.c
)

target_include_directories(AppleOpenGLShim
    PRIVATE
        runtime/include
        client/include
        icd/include
        "${MESA_INCLUDE_DIRS}"
)

target_link_libraries(AppleOpenGLShim PRIVATE LibGLICDDriver)

set_target_properties(AppleOpenGLShim PROPERTIES
    PREFIX ""
    OUTPUT_NAME "OpenGL"
    SUFFIX ""
    BUILD_WITH_INSTALL_NAME_DIR ON
    INSTALL_NAME_DIR "/System/Library/Frameworks/OpenGL.framework/Versions/A"
)

if(APPLE)
    target_link_options(AppleOpenGLShim PRIVATE "-Wl,-not_for_dyld_shared_cache")
endif()

# -------------------------------------------------------------
# 12. GLX Shims (libGL.dylib, libGLContext.dylib)
# -------------------------------------------------------------
add_library(LibGLDriver SHARED
    drivers/src/libGL.c
)

target_include_directories(LibGLDriver
    PRIVATE
        runtime/include
        client/include
        icd/include
        "${MESA_INCLUDE_DIRS}"
)

target_link_libraries(LibGLDriver PRIVATE LibGLICDDriver)

set_target_properties(LibGLDriver PROPERTIES
    PREFIX ""
    OUTPUT_NAME "libGL"
)

add_library(LibGLContextDriver SHARED
    drivers/src/libGLContext.c
)

target_include_directories(LibGLContextDriver
    PRIVATE
        runtime/include
        client/include
        icd/include
        drivers/include
        "${MESA_INCLUDE_DIRS}"
)

target_link_libraries(LibGLContextDriver PRIVATE LibGLICDDriver)

set_target_properties(LibGLContextDriver PROPERTIES
    PREFIX ""
    OUTPUT_NAME "libGLContext"
)

# -------------------------------------------------------------
# 12. NSOpenGL Bridge (libNSOpenGLContext.dylib)
# -------------------------------------------------------------
add_library(LibNSOpenGLContextDriver SHARED
    drivers/src/libNSOpenGLContext.m
)

target_include_directories(LibNSOpenGLContextDriver
    PRIVATE
        runtime/include
        client/include
        drivers/include
        "${MESA_INCLUDE_DIRS}"
)

target_link_libraries(LibNSOpenGLContextDriver PRIVATE OpenGL46FrameworkClient)

if(APPLE)
    target_link_libraries(LibNSOpenGLContextDriver PRIVATE "-framework AppKit" "-framework Foundation")
    target_compile_options(LibNSOpenGLContextDriver PRIVATE "-fobjc-arc")
endif()

set_target_properties(LibNSOpenGLContextDriver PROPERTIES
    PREFIX ""
    OUTPUT_NAME "libNSOpenGLContext"
)

# -------------------------------------------------------------
# 13. Tests (optional)
# -------------------------------------------------------------
if(BUILD_TESTING)
    enable_testing()

    add_executable(AppleOpenGLAsahiBackendSmoke
        tests/AppleOpenGLAsahiBackendSmoke.c
        MesaPlatform/AppleOpenGLAsahi.c
        "${MESA_ROOT}/src/asahi/lib/agx_macos_device.c"
        "${MESA_ROOT}/src/asahi/lib/agx_macos_bo.c"
        "${MESA_ROOT}/src/asahi/lib/agx_macos_queue.c"
        "${MESA_ROOT}/src/asahi/lib/agx_macos_command.c"
        "${MESA_ROOT}/src/asahi/lib/agx_macos_submission_observation.c"
        "${MESA_ROOT}/src/asahi/lib/agx_macos_submission_lease.c"
        "${MESA_ROOT}/src/asahi/lib/agx_macos_iosurface.m"
        "${MESA_ROOT}/src/asahi/lib/agx_macos_screen_bootstrap.c"
    )

    target_include_directories(AppleOpenGLAsahiBackendSmoke
        PRIVATE
            MesaPlatform
            "${MESA_INCLUDE_DIRS}"
    )

    target_link_libraries(AppleOpenGLAsahiBackendSmoke
        PRIVATE
            "-framework IOKit"
            "-framework CoreFoundation"
            "-framework Foundation"
            "-framework IOSurface"
    )

    add_test(
        NAME AppleOpenGLAsahiBackendSmoke
        COMMAND $<TARGET_FILE:AppleOpenGLAsahiBackendSmoke>
    )

    add_executable(AGXMacOSSubmissionObservationSmoke
        "${MESA_ROOT}/src/asahi/lib/tests/agx_macos_submission_observation_smoke.c"
        "${MESA_ROOT}/src/asahi/lib/agx_macos_submission_observation.c"
    )

    target_include_directories(AGXMacOSSubmissionObservationSmoke
        PRIVATE
            "${MESA_ROOT}/src/asahi/lib"
    )

    add_test(
        NAME AGXMacOSSubmissionObservationSmoke
        COMMAND $<TARGET_FILE:AGXMacOSSubmissionObservationSmoke>
    )

    add_executable(AGXMacOSSubmissionLeaseSmoke
        "${MESA_ROOT}/src/asahi/lib/tests/agx_macos_submission_lease_smoke.c"
        "${MESA_ROOT}/src/asahi/lib/agx_macos_bo.c"
        "${MESA_ROOT}/src/asahi/lib/agx_macos_submission_observation.c"
        "${MESA_ROOT}/src/asahi/lib/agx_macos_submission_lease.c"
    )

    target_include_directories(AGXMacOSSubmissionLeaseSmoke
        PRIVATE
            "${MESA_ROOT}/src/asahi/lib"
    )

    target_link_libraries(AGXMacOSSubmissionLeaseSmoke
        PRIVATE
            "-framework IOKit"
            "-framework CoreFoundation"
    )

    add_test(
        NAME AGXMacOSSubmissionLeaseSmoke
        COMMAND $<TARGET_FILE:AGXMacOSSubmissionLeaseSmoke>
    )

    add_executable(AGXMacOSIOSurfaceDrawableTrace
        "${MESA_ROOT}/src/asahi/lib/tests/agx_macos_iosurface_drawable_trace.m"
        "${MESA_ROOT}/src/asahi/lib/agx_macos_device.c"
        "${MESA_ROOT}/src/asahi/lib/agx_macos_iosurface.m"
    )

    target_include_directories(AGXMacOSIOSurfaceDrawableTrace
        PRIVATE
            "${MESA_ROOT}/src/asahi/lib"
    )

    target_link_libraries(AGXMacOSIOSurfaceDrawableTrace
        PRIVATE
            "-framework IOKit"
            "-framework CoreFoundation"
            "-framework Foundation"
            "-framework IOSurface"
            "-framework Metal"
    )

    add_executable(AGXMacOSIOSurfaceSmoke
        "${MESA_ROOT}/src/asahi/lib/tests/agx_macos_iosurface_smoke.m"
        "${MESA_ROOT}/src/asahi/lib/agx_macos_iosurface.m"
    )

    target_include_directories(AGXMacOSIOSurfaceSmoke
        PRIVATE
            "${MESA_ROOT}/src/asahi/lib"
    )

    target_link_libraries(AGXMacOSIOSurfaceSmoke
        PRIVATE
            "-framework Foundation"
            "-framework IOSurface"
    )

    add_test(
        NAME AGXMacOSIOSurfaceSmoke
        COMMAND $<TARGET_FILE:AGXMacOSIOSurfaceSmoke>
    )

    add_executable(AGXMacOSScreenBootstrapSmoke
        "${MESA_ROOT}/src/asahi/lib/tests/agx_macos_screen_bootstrap_smoke.c"
        "${MESA_ROOT}/src/asahi/lib/agx_macos_device.c"
        "${MESA_ROOT}/src/asahi/lib/agx_macos_bo.c"
        "${MESA_ROOT}/src/asahi/lib/agx_macos_queue.c"
        "${MESA_ROOT}/src/asahi/lib/agx_macos_submission_observation.c"
        "${MESA_ROOT}/src/asahi/lib/agx_macos_submission_lease.c"
        "${MESA_ROOT}/src/asahi/lib/agx_macos_command.c"
        "${MESA_ROOT}/src/asahi/lib/agx_macos_iosurface.m"
        "${MESA_ROOT}/src/asahi/lib/agx_macos_screen_bootstrap.c"
    )

    target_include_directories(AGXMacOSScreenBootstrapSmoke
        PRIVATE
            "${MESA_ROOT}/src/asahi/lib"
    )

    target_link_libraries(AGXMacOSScreenBootstrapSmoke
        PRIVATE
            "-framework IOKit"
            "-framework CoreFoundation"
            "-framework Foundation"
            "-framework IOSurface"
    )

    add_test(
        NAME AGXMacOSScreenBootstrapSmoke
        COMMAND $<TARGET_FILE:AGXMacOSScreenBootstrapSmoke>
    )

    add_executable(AO46RuntimeCompatSmoke
        tests/AO46RuntimeCompatSmoke.c
    )

    target_include_directories(AO46RuntimeCompatSmoke
        PRIVATE
            runtime/include
            client/include
            drivers/include
            "${MESA_INCLUDE_DIRS}"
    )

    target_link_libraries(AO46RuntimeCompatSmoke
        PRIVATE
            OpenGL_4_6
    )

    add_test(
        NAME AO46RuntimeCompatSmoke
        COMMAND $<TARGET_FILE:AO46RuntimeCompatSmoke>
    )

    set_tests_properties(AO46RuntimeCompatSmoke PROPERTIES
        ENVIRONMENT
            "AO46_FRAMEWORK_PATH=$<TARGET_FILE:OpenGL_4_6>;DYLD_FRAMEWORK_PATH=${CMAKE_CURRENT_BINARY_DIR};DYLD_LIBRARY_PATH=${CMAKE_CURRENT_BINARY_DIR}"
    )

    add_executable(AO46MesaProfileNegotiationSmoke
        tests/AO46MesaProfileNegotiationSmoke.c
    )

    target_include_directories(AO46MesaProfileNegotiationSmoke
        PRIVATE
            runtime/include
            MesaPlatform
            "${MESA_INCLUDE_DIRS}"
    )

    target_link_libraries(AO46MesaProfileNegotiationSmoke
        PRIVATE
            OpenGL_4_6
    )

    add_test(
        NAME AO46MesaProfileNegotiationSmoke
        COMMAND $<TARGET_FILE:AO46MesaProfileNegotiationSmoke>
    )

    set_tests_properties(AO46MesaProfileNegotiationSmoke PROPERTIES
        ENVIRONMENT
            "AO46_FRAMEWORK_PATH=$<TARGET_FILE:OpenGL_4_6>;DYLD_FRAMEWORK_PATH=${CMAKE_CURRENT_BINARY_DIR};DYLD_LIBRARY_PATH=${CMAKE_CURRENT_BINARY_DIR}"
    )

    add_test(
        NAME AO46MesaProfileNegotiationNativeBootstrapSmoke
        COMMAND $<TARGET_FILE:AO46MesaProfileNegotiationSmoke>
    )

    set_tests_properties(AO46MesaProfileNegotiationNativeBootstrapSmoke PROPERTIES
        ENVIRONMENT
            "AO46_ENABLE_NATIVE_SCREEN_BOOTSTRAP=1;AO46_FRAMEWORK_PATH=$<TARGET_FILE:OpenGL_4_6>;DYLD_FRAMEWORK_PATH=${CMAKE_CURRENT_BINARY_DIR};DYLD_LIBRARY_PATH=${CMAKE_CURRENT_BINARY_DIR}"
    )

    add_executable(AO46NSOpenGLCompatSmoke
        tests/AO46NSOpenGLCompatSmoke.m
    )

    target_include_directories(AO46NSOpenGLCompatSmoke
        PRIVATE
            runtime/include
            client/include
            drivers/include
            "${MESA_INCLUDE_DIRS}"
    )

    target_link_libraries(AO46NSOpenGLCompatSmoke
        PRIVATE
            LibNSOpenGLContextDriver
            OpenGL46FrameworkClient
            "-framework AppKit"
            "-framework Foundation"
    )

    add_test(
        NAME AO46NSOpenGLCompatSmoke
        COMMAND $<TARGET_FILE:AO46NSOpenGLCompatSmoke>
    )

    set_tests_properties(AO46NSOpenGLCompatSmoke PROPERTIES
        ENVIRONMENT
            "AO46_FRAMEWORK_PATH=$<TARGET_FILE:OpenGL_4_6>;DYLD_FRAMEWORK_PATH=${CMAKE_CURRENT_BINARY_DIR};DYLD_LIBRARY_PATH=${CMAKE_CURRENT_BINARY_DIR}"
    )
endif()
