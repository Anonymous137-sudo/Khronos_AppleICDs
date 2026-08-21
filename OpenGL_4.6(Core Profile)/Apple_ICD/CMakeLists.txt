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
set(AO46_MESA_KOSMICKRISP_BUILD_DIR "${MESA_ROOT}/build-ao46-kosmickrisp-arm64" CACHE PATH
    "Path to a Mesa build with KosmicKrisp libkk generated artifacts"
)
set(AO46_MESA_LIBKK_GENERATED_DIR
    "${AO46_MESA_KOSMICKRISP_BUILD_DIR}/src/kosmickrisp/libkk"
)
set(AO46_MESA_KOSMICKRISP_BRIDGE_DIR
    "${AO46_MESA_KOSMICKRISP_BUILD_DIR}/src/kosmickrisp/bridge"
)
set(AO46_MESA_KOSMICKRISP_COMPILER_DIR
    "${AO46_MESA_KOSMICKRISP_BUILD_DIR}/src/kosmickrisp/compiler"
)
set(AO46_MESA_KOSMICKRISP_VULKAN_DIR
    "${AO46_MESA_KOSMICKRISP_BUILD_DIR}/src/kosmickrisp/vulkan"
)
option(OPENGLKHR_BUILD_ARCHIVED_AGX_RESEARCH
    "Build archived direct-AGX/UABI research targets (never linked by OpenGL_4.6)"
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
    "${MESA_BUILD_DIR}/src/asahi/genxml"
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
    "${MESA_ROOT}/src/asahi"
    "${MESA_ROOT}/src/asahi/compiler"
    "${MESA_ROOT}/src/asahi/layout"
    "${MESA_ROOT}/src/asahi/lib"
    "${MESA_ROOT}/src/asahi/libagx"
    "${MESA_ROOT}/src/virtio/vdrm"
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
find_library(MESA_POLY_NIR_LIB    NAMES libpoly_nir    PATHS "${MESA_BUILD_DIR}/src/poly/nir" NO_DEFAULT_PATH)
find_library(MESA_GLSL_UTIL_LIB   NAMES glsl_util      PATHS "${MESA_BUILD_DIR}/src/compiler/glsl" NO_DEFAULT_PATH)
find_library(MESA_GLSL_LIB        NAMES glsl           PATHS "${MESA_BUILD_DIR}/src/compiler/glsl" NO_DEFAULT_PATH)
find_library(MESA_BLAKE3_LIB NAMES blake3
    PATHS "${MESA_BUILD_DIR}/src/util/blake3" NO_DEFAULT_PATH)
find_library(AO46_MESA_KOSMICKRISP_BRIDGE_LIB NAMES mtl_bridge
    PATHS "${AO46_MESA_KOSMICKRISP_BRIDGE_DIR}" NO_DEFAULT_PATH)
find_library(AO46_MESA_KOSMICKRISP_COMPILER_LIB NAMES msl_compiler
    PATHS "${AO46_MESA_KOSMICKRISP_COMPILER_DIR}" NO_DEFAULT_PATH)
find_library(AO46_MESA_KOSMICKRISP_VULKAN_LIB NAMES kk
    PATHS "${AO46_MESA_KOSMICKRISP_VULKAN_DIR}" NO_DEFAULT_PATH)
find_library(AO46_MESA_ASAHI_GALLIUM_REFERENCE_LIB NAMES asahi
    PATHS "${MESA_BUILD_DIR}/src/gallium/drivers/asahi" NO_DEFAULT_PATH)
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
   NOT MESA_POLY_NIR_LIB OR
   NOT MESA_GLSL_UTIL_LIB OR
   NOT MESA_GLSL_LIB OR
   NOT MESA_BLAKE3_LIB OR
   NOT AO46_MESA_KOSMICKRISP_BRIDGE_LIB OR
   NOT AO46_MESA_KOSMICKRISP_COMPILER_LIB OR
   NOT AO46_MESA_KOSMICKRISP_VULKAN_LIB OR
   NOT AO46_MESA_ASAHI_GALLIUM_REFERENCE_LIB OR
   NOT LLVM_LIB)
    message(FATAL_ERROR
        "Required Mesa GL/NIR archives were not found under '${MESA_BUILD_DIR}'. "
        "Point AO46_MESA_BUILD_DIR at a completed Mesa build with LLVM and "
        "BLAKE3 available.")
endif()

# AO46 consumes KosmicKrisp's Metal bridge directly. Do not silently fall
# back to a second, handwritten resource layer when this Mesa artifact is absent.
if(NOT EXISTS "${AO46_MESA_LIBKK_GENERATED_DIR}/libkk_shaders.c" OR
   NOT EXISTS "${AO46_MESA_LIBKK_GENERATED_DIR}/libkk_shaders.h")
    message(FATAL_ERROR
        "Mesa KosmicKrisp artifacts are required under '${AO46_MESA_KOSMICKRISP_BUILD_DIR}'. "
        "Build the Mesa kosmickrisp configuration before configuring AO46.")
endif()

add_library(AO46MesaKosmicKrispBridge STATIC IMPORTED GLOBAL)
set_target_properties(AO46MesaKosmicKrispBridge PROPERTIES
    IMPORTED_LOCATION "${AO46_MESA_KOSMICKRISP_BRIDGE_LIB}"
)

add_library(AO46MesaMSLCompiler STATIC IMPORTED GLOBAL)
set_target_properties(AO46MesaMSLCompiler PROPERTIES
    IMPORTED_LOCATION "${AO46_MESA_KOSMICKRISP_COMPILER_LIB}"
)
target_link_libraries(AO46MesaMSLCompiler INTERFACE ${MESA_BLAKE3_LIB})
# The compiler archive is built from Mesa's NIR sources. Keep its archive
# dependencies attached to the imported target so static-link ordering cannot
# accidentally select a different NIR build or leave nir_* unresolved.
target_link_libraries(AO46MesaMSLCompiler INTERFACE
    ${MESA_NIR_LIB}
    ${MESA_COMPILER_LIB}
    ${MESA_UTIL_LIB}
    ${MESA_UTIL_SIMD_LIB}
    ${MESA_UTIL_C11_LIB}
)

# These archives retain the full upstream feature implementation for bounded
# AO46 ports. Neither is linked into the OpenGL framework: libkk is a Vulkan
# frontend and libasahi emits AGX/DRM work, not Metal command buffers.
add_library(AO46MesaKosmicKrispVulkanReference STATIC IMPORTED GLOBAL)
set_target_properties(AO46MesaKosmicKrispVulkanReference PROPERTIES
    IMPORTED_LOCATION "${AO46_MESA_KOSMICKRISP_VULKAN_LIB}"
)

add_library(AO46MesaAsahiGalliumReference STATIC IMPORTED GLOBAL)
set_target_properties(AO46MesaAsahiGalliumReference PROPERTIES
    IMPORTED_LOCATION "${AO46_MESA_ASAHI_GALLIUM_REFERENCE_LIB}"
)

add_custom_target(AO46MesaUpstreamPortingArtifacts
    DEPENDS
        "${AO46_MESA_KOSMICKRISP_VULKAN_LIB}"
        "${AO46_MESA_ASAHI_GALLIUM_REFERENCE_LIB}"
)

# Adapter sources are compiled into both production libraries and smoke tests.
include_directories("${MESA_ROOT}/src")
link_libraries(AO46MesaKosmicKrispBridge)

if(NOT SPIRV_TOOLS_INCLUDE_DIR OR NOT SPIRV_TOOLS_LIB OR NOT ZSTD_LIB OR NOT ZLIB_LIB)
    message(FATAL_ERROR
        "Required framework-side dependencies were not found. "
        "Need SPIR-V Tools headers/library plus zstd and zlib.")
endif()

# Mesa's libkk build emits the poly tessellation MSL kernels used by AO46.
set(AO46_HAVE_MESA_LIBKK 1)
add_library(AO46MesaPolyKernelArtifacts STATIC
    "${AO46_MESA_LIBKK_GENERATED_DIR}/libkk_shaders.c"
)
target_include_directories(AO46MesaPolyKernelArtifacts
    PRIVATE
        "${AO46_MESA_LIBKK_GENERATED_DIR}"
        "${MESA_INCLUDE_DIRS}"
)
target_compile_definitions(AO46MesaPolyKernelArtifacts
    PRIVATE
        ${MESA_COMPILE_DEFINITIONS}
)

if(OPENGLKHR_BUILD_ARCHIVED_AGX_RESEARCH)
    find_library(MESA_ASAHI_GALLIUM_LIB NAMES asahi
        PATHS "${MESA_BUILD_DIR}/src/gallium/drivers/asahi" NO_DEFAULT_PATH)
    find_library(MESA_ASAHI_COMPILER_LIB NAMES asahi_compiler
        PATHS "${MESA_BUILD_DIR}/src/asahi/compiler" NO_DEFAULT_PATH)
    find_library(MESA_ASAHI_CORE_LIB NAMES asahi_lib
        PATHS "${MESA_BUILD_DIR}/src/asahi/lib" NO_DEFAULT_PATH)
    find_library(MESA_ASAHI_DECODE_LIB NAMES asahi_decode
        PATHS "${MESA_BUILD_DIR}/src/asahi/lib" NO_DEFAULT_PATH)
    find_library(MESA_AGX_DISASM_LIB NAMES agx2_disasm
        PATHS "${MESA_BUILD_DIR}/src/asahi/isa" NO_DEFAULT_PATH)
    find_library(MESA_ASAHI_LAYOUT_LIB NAMES asahi_layout
        PATHS "${MESA_BUILD_DIR}/src/asahi/layout" NO_DEFAULT_PATH)
    find_library(MESA_POLY_NIR_LIB NAMES libpoly_nir
        PATHS "${MESA_BUILD_DIR}/src/poly/nir" NO_DEFAULT_PATH)
    find_library(MESA_ASAHI_MACOS_WINSYS_LIB NAMES asahi_macos_winsys
        PATHS "${MESA_BUILD_DIR}/src/asahi/lib" NO_DEFAULT_PATH)

    if(NOT MESA_ASAHI_CORE_LIB OR NOT MESA_ASAHI_DECODE_LIB OR
       NOT MESA_AGX_DISASM_LIB OR NOT MESA_ASAHI_LAYOUT_LIB OR
       NOT MESA_ASAHI_MACOS_WINSYS_LIB)
        message(FATAL_ERROR
            "Archived AGX research requires the historical Asahi archives "
            "under '${MESA_BUILD_DIR}'.")
    endif()

    find_program(AO46_NINJA_EXECUTABLE NAMES ninja REQUIRED)
    find_program(AO46_LLVM_AR_EXECUTABLE NAMES llvm-ar
        HINTS /opt/homebrew/opt/llvm/bin /usr/local/opt/llvm/bin
        REQUIRED)
    get_filename_component(AO46_LLVM_BIN_DIR "${AO46_LLVM_AR_EXECUTABLE}" DIRECTORY)
    add_custom_target(AO46MesaMacOSWinsysArchive
        COMMAND "${CMAKE_COMMAND}" -E env "MAKEFLAGS="
                "PATH=${AO46_LLVM_BIN_DIR}:$ENV{PATH}"
                "${AO46_NINJA_EXECUTABLE}" -C "${MESA_BUILD_DIR}"
                "src/asahi/lib/libasahi_macos_winsys.a"
        BYPRODUCTS "${MESA_ASAHI_MACOS_WINSYS_LIB}"
        COMMENT "Synchronizing archived Mesa macOS AGX winsys research"
        VERBATIM
    )
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
# This must be shared by Gallium and the framework: embedding it in both would
# register duplicate Objective-C MTL4 completion classes in one process.
add_library(AO46AGXMetalAdapter SHARED
    MesaPlatform/AO46MetalAdapter.m
    MesaPlatform/AO46MetalDrawable.m
    MesaPlatform/AO46MetalWindow.m
)

target_include_directories(AO46AGXMetalAdapter
    PUBLIC
        MesaPlatform
)

target_compile_options(AO46AGXMetalAdapter PRIVATE -fobjc-arc)

target_link_libraries(AO46AGXMetalAdapter
    PUBLIC
        "-framework Foundation"
        "-framework Metal"
        "-framework QuartzCore"
        "-framework AppKit"
        "-framework IOSurface"
)

set_target_properties(AO46AGXMetalAdapter PROPERTIES
    OUTPUT_NAME "AO46AGXMetalAdapter"
    BUILD_RPATH "@loader_path"
    INSTALL_RPATH "@loader_path"
    BUILD_WITH_INSTALL_RPATH TRUE
)

add_library(OpenGL46RuntimeObjects OBJECT
    runtime/src/AppleOpenGL46Runtime.c
    MesaPlatform/AO46MesaBridge.c
)

target_include_directories(OpenGL46RuntimeObjects
    PUBLIC
        runtime/include
        MesaPlatform
        "${MESA_INCLUDE_DIRS}"
        "${AO46_MESA_LIBKK_GENERATED_DIR}"
)

target_compile_definitions(OpenGL46RuntimeObjects
    PRIVATE
        ${MESA_COMPILE_DEFINITIONS}
        GL_SILENCE_DEPRECATION
        AO46_HAVE_MESA_LIBKK=${AO46_HAVE_MESA_LIBKK}
)

set_source_files_properties(
    MesaPlatform/AO46MetalAdapter.m
    MesaPlatform/AO46MetalDrawable.m
    MesaPlatform/AO46MetalWindow.m
    MesaPlatform/AO46MetalBackend.m
    PROPERTIES COMPILE_OPTIONS "-fobjc-arc"
)

# -------------------------------------------------------------
# 5. Metal Shader Translation (NIR -> MSL)
# -------------------------------------------------------------
# AO46 links Mesa's KosmicKrisp compiler archive directly. Recompiling its
# sources here would create a divergent local copy of the Metal backend.

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
# 7. AO46 Mesa-Facing Gallium Driver
# -------------------------------------------------------------
# `mtl_driver.m` is the audited migration baseline for the required,
# promoted AO46 Mesa-facing Gallium implementation.
add_library(AO46MTLGallium SHARED
    GL2MTL/mtl_driver.m
    GL2MTL/mtl_shader_compiler.m
    MesaPlatform/AO46MetalGalliumScreen.c
    MesaPlatform/AO46MesaRGB32BufferTextureBinding.c
    MesaPlatform/AO46MesaNIRBufferTexture.c
    MesaPlatform/AO46MesaRGB32BufferTexturePipeline.c
    MesaPlatform/AO46MesaPolyTessellation.c
    MesaPlatform/AO46MesaPolyKernelCatalog.c
    MesaPlatform/AO46MesaPolyKernelExecutor.c
    MesaPlatform/AO46MesaMSLComputePipeline.c
    MesaPlatform/AO46MesaMSLRenderPipeline.c
)

target_include_directories(AO46MTLGallium
    PRIVATE
        GL2MTL
        MesaPlatform
        "${MESA_INCLUDE_DIRS}"
)

target_compile_definitions(AO46MTLGallium
    PRIVATE
        ${MESA_COMPILE_DEFINITIONS}
)

target_link_libraries(AO46MTLGallium
    PRIVATE
        AO46AGXMetalAdapter
        AO46MesaMSLCompiler
        ${MESA_GLSL_LIB}
        ${MESA_GLSL_UTIL_LIB}
        ${MESA_NIR_LIB}
        ${MESA_POLY_NIR_LIB}
        ${MESA_COMPILER_LIB}
        ${MESA_GALLIUM_AUX}
        ${MESA_UTIL_LIB}
        ${MESA_UTIL_SIMD_LIB}
        ${MESA_UTIL_C11_LIB}
        AO46MesaPolyKernelArtifacts
        "-lc++"
        "-framework Metal"
        "-framework QuartzCore"
        "-framework AppKit"
        "-framework Foundation"
)

set_target_properties(AO46MTLGallium PROPERTIES
    OUTPUT_NAME "AO46MTLGallium"
    BUILD_RPATH "@loader_path"
    INSTALL_RPATH "@loader_path"
    BUILD_WITH_INSTALL_RPATH TRUE
)
add_dependencies(AO46MTLGallium AO46MesaUpstreamPortingArtifacts)

# This is the shared hardware-facing layer.  It deliberately contains no CGL,
# NSOpenGL, or framework ABI entry points, so Mesa's standard GL/EGL frontend
# can consume the same Gallium screen without loading the legacy stack.
add_library(AO46MesaMetalBackend SHARED
    MesaPlatform/AO46MetalBackend.m
    khronos/src/AO46MesaMetalBackendExport.c
    khronos/src/AO46MesaMetalBackendWindow.m
)

target_include_directories(AO46MesaMetalBackend
    PUBLIC
        MesaPlatform
        khronos/include
        "${MESA_INCLUDE_DIRS}"
)

target_link_libraries(AO46MesaMetalBackend
    PRIVATE
        AO46AGXMetalAdapter
        AO46MTLGallium
        ${MESA_GALLIUM_AUX}
        ${MESA_UTIL_LIB}
        ${MESA_UTIL_SIMD_LIB}
        ${MESA_UTIL_C11_LIB}
        "-framework Foundation"
        "-framework Metal"
        "-framework QuartzCore"
        "-framework AppKit"
)

target_compile_options(AO46MesaMetalBackend PRIVATE -fobjc-arc)

set_target_properties(AO46MesaMetalBackend PROPERTIES
    OUTPUT_NAME "AO46MesaMetalBackend"
    BUILD_RPATH "@loader_path"
    INSTALL_RPATH "@loader_path"
    BUILD_WITH_INSTALL_RPATH TRUE
)

# -------------------------------------------------------------
# 8. Legacy Runtime + Framework Compatibility
# -------------------------------------------------------------
# This CGL/NSOpenGL runtime belongs exclusively to the legacy framework path.
# Standard Khronos GL/EGL clients use Mesa's own libGL/libEGL build, not this
# library and not any CGL object.
add_library(AO46Core SHARED
    "${MESA_ROOT}/src/mesa/glapi/glapi/libgl_public.c"
    "${GLAPI_PUBLIC_MAPI_HEADER}"
    $<TARGET_OBJECTS:OpenGL46RuntimeObjects>
)

target_include_directories(AO46Core
    PRIVATE
        runtime/include
        MesaPlatform
        "${GLAPI_PUBLIC_GEN_DIR}"
        "${MESA_INCLUDE_DIRS}"
)

target_compile_definitions(AO46Core
    PRIVATE
        ${MESA_COMPILE_DEFINITIONS}
)

target_link_libraries(AO46Core
    PRIVATE
        AO46MesaMetalBackend
        AO46AGXMetalAdapter
        AO46MTLGallium
        ${MESA_ST_MESA_LIB}
        ${MESA_GLAPI_LIB}
        ${MESA_GLSL_LIB}
        AO46MesaGLCPP
        ${MESA_GLSL_UTIL_LIB}
        ${MESA_NIR_LIB}
        ${MESA_POLY_NIR_LIB}
        ${MESA_COMPILER_LIB}
        AO46MesaMSLCompiler
        AO46MesaVTN
        ${SPIRV_TOOLS_LIB}
        ${SPIRV_TOOLS_OPT_LIB}
        ${MESA_GALLIUM_AUX}
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
        "-framework Metal"
)

if(AO46_HAVE_MESA_LIBKK)
    target_link_libraries(AO46Core PRIVATE AO46MesaPolyKernelArtifacts)
endif()

set_target_properties(AO46Core PROPERTIES
    OUTPUT_NAME "AO46Core"
    BUILD_RPATH "@loader_path"
    INSTALL_RPATH "@loader_path"
)

# The framework is retained only for legacy macOS applications that expect
# CGL/NSOpenGL routing. It is not a dependency of the Khronos ABI path.
add_library(OpenGL_4_6 SHARED
    framework/src/OpenGL46Framework.c
    ${AO46_FRAMEWORK_PUBLIC_HEADERS}
    ${AO46_FRAMEWORK_MODULEMAP}
)

target_include_directories(OpenGL_4_6
    PRIVATE
        runtime/include
        "${MESA_INCLUDE_DIRS}"
)

target_link_libraries(OpenGL_4_6 PRIVATE AO46Core)
target_link_options(OpenGL_4_6 PRIVATE
    "-Wl,-reexport_library,$<TARGET_FILE:AO46Core>"
)
add_dependencies(OpenGL_4_6 AO46Core)

set_target_properties(OpenGL_4_6 PROPERTIES
    FRAMEWORK TRUE
    FRAMEWORK_VERSION A
    OUTPUT_NAME "OpenGL_4.6"
    MACOSX_FRAMEWORK_IDENTIFIER "local.opengl46.driver"
    PUBLIC_HEADER "${AO46_FRAMEWORK_PUBLIC_HEADERS}"
    INSTALL_RPATH "/usr/local/lib"
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
set_target_properties(LibGLICDDriver PROPERTIES
    OUTPUT_NAME "GLICD"
    BUILD_RPATH "@loader_path"
    INSTALL_RPATH "@loader_path"
)

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
# 12. Legacy User-Space Shims
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
target_link_libraries(LibGLDriver PRIVATE AO46Core)
target_link_options(LibGLDriver PRIVATE
    "-Wl,-reexport_library,$<TARGET_FILE:AO46Core>"
)
add_dependencies(LibGLDriver AO46Core)

set_target_properties(LibGLDriver PROPERTIES
    PREFIX ""
    # Reserve the standard libGL.dylib name for Mesa's Khronos ABI build.
    OUTPUT_NAME "libAO46LegacyGL"
    BUILD_RPATH "@loader_path"
    INSTALL_RPATH "@loader_path"
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

    add_test(
        NAME AO46KhronosInstallModeSmoke
        COMMAND sh "${ROOT_DIR}/tests/AO46KhronosInstallModeSmoke.sh"
                   "${ROOT_DIR}/scripts/install_khronos_layout.sh"
    )

    add_test(
        NAME AO46FrontendSplitAudit
        COMMAND sh "${ROOT_DIR}/tests/AO46FrontendSplitAudit.sh"
                   "${ROOT_DIR}/CMakeLists.txt"
                   "${ROOT_DIR}/scripts/stage_khronos_layout.sh"
                   "${ROOT_DIR}/scripts/stage_personal_layout.sh"
                   "${ROOT_DIR}/scripts/build_mesa_khronos_frontend.sh"
                   "${MESA_ROOT}"
    )

    add_test(
        NAME AO46LegacyStageSmoke
        COMMAND sh "${ROOT_DIR}/tests/AO46LegacyStageSmoke.sh"
                   "${ROOT_DIR}/scripts/stage_personal_layout.sh"
    )

    add_executable(AO46MesaMetalBackendSmoke
        tests/AO46MesaMetalBackendSmoke.c
    )

    target_include_directories(AO46MesaMetalBackendSmoke
        PRIVATE
            khronos/include
            "${MESA_INCLUDE_DIRS}"
    )

    target_link_libraries(AO46MesaMetalBackendSmoke
        PRIVATE
            AO46MesaMetalBackend
    )

    add_test(
        NAME AO46MesaMetalBackendSmoke
        COMMAND $<TARGET_FILE:AO46MesaMetalBackendSmoke>
    )

    set_tests_properties(AO46MesaMetalBackendSmoke PROPERTIES
        ENVIRONMENT "DYLD_LIBRARY_PATH=${CMAKE_CURRENT_BINARY_DIR}"
    )

    add_executable(AO46MesaMetalBackendWindowSmoke
        tests/AO46MesaMetalBackendWindowSmoke.m
    )

    target_include_directories(AO46MesaMetalBackendWindowSmoke
        PRIVATE
            khronos/include
            "${MESA_INCLUDE_DIRS}"
    )

    target_compile_options(AO46MesaMetalBackendWindowSmoke PRIVATE -fobjc-arc)

    target_link_libraries(AO46MesaMetalBackendWindowSmoke
        PRIVATE
            AO46MesaMetalBackend
            "-framework Metal"
            "-framework QuartzCore"
    )

    add_test(
        NAME AO46MesaMetalBackendWindowSmoke
        COMMAND $<TARGET_FILE:AO46MesaMetalBackendWindowSmoke>
    )

    set_tests_properties(AO46MesaMetalBackendWindowSmoke PROPERTIES
        ENVIRONMENT "DYLD_LIBRARY_PATH=${CMAKE_CURRENT_BINARY_DIR}"
    )

    add_test(
        NAME AO46MesaReuseInventory
        COMMAND "${AO46_PYTHON_EXECUTABLE}"
            "${ROOT_DIR}/scripts/inventory_mesa_reuse.py"
            --mesa-root "${MESA_ROOT}"
            --check
            --check-artifacts
    )

    if(TARGET AO46MTLGallium)
        add_executable(AO46MTLGalliumAdapterSmoke
            tests/AO46MTLGalliumAdapterSmoke.m
        )

        target_include_directories(AO46MTLGalliumAdapterSmoke
            PRIVATE
                GL2MTL
                MesaPlatform
                "${MESA_INCLUDE_DIRS}"
        )

    target_link_libraries(AO46MTLGalliumAdapterSmoke
        PRIVATE
            AO46MTLGallium
            AO46AGXMetalAdapter
    )

        target_compile_options(AO46MTLGalliumAdapterSmoke PRIVATE -fobjc-arc)

        add_test(
            NAME AO46MTLGalliumAdapterSmoke
            COMMAND $<TARGET_FILE:AO46MTLGalliumAdapterSmoke>
        )
    endif()

    add_executable(AO46CGLShimCompatSmoke
        tests/AO46CGLShimCompatSmoke.c
    )

    # The smoke dlopens the shim instead of linking it, so retain an explicit
    # build dependency for target-specific test builds.
    add_dependencies(AO46CGLShimCompatSmoke AppleOpenGLShim)

    add_test(
        NAME AO46CGLShimCompatSmoke
        COMMAND $<TARGET_FILE:AO46CGLShimCompatSmoke>
    )

    set_tests_properties(AO46CGLShimCompatSmoke PROPERTIES
        ENVIRONMENT
            "AO46_SHIM_PATH=$<TARGET_FILE:AppleOpenGLShim>;AO46_FRAMEWORK_PATH=$<TARGET_FILE:OpenGL_4_6>;DYLD_FRAMEWORK_PATH=${CMAKE_CURRENT_BINARY_DIR};DYLD_LIBRARY_PATH=${CMAKE_CURRENT_BINARY_DIR}"
    )

    add_executable(AO46MetalAdapterSmoke
        tests/AO46MetalAdapterSmoke.m
        MesaPlatform/AO46MetalAdapter.m
    )

    target_include_directories(AO46MetalAdapterSmoke
        PRIVATE
            MesaPlatform
    )

    target_link_libraries(AO46MetalAdapterSmoke
        PRIVATE
            "-framework Foundation"
            "-framework Metal"
            "-framework IOSurface"
    )

    target_compile_options(AO46MetalAdapterSmoke PRIVATE -fobjc-arc)

    add_test(
        NAME AO46MetalAdapterSmoke
        COMMAND $<TARGET_FILE:AO46MetalAdapterSmoke>
    )

    add_executable(AO46MetalWindowPolicySmoke
        tests/AO46MetalWindowPolicySmoke.m
    )

    target_include_directories(AO46MetalWindowPolicySmoke
        PRIVATE
            MesaPlatform
    )

    target_link_libraries(AO46MetalWindowPolicySmoke
        PRIVATE
            AO46AGXMetalAdapter
    )

    target_compile_options(AO46MetalWindowPolicySmoke PRIVATE -fobjc-arc)

    add_test(
        NAME AO46MetalWindowPolicySmoke
        COMMAND $<TARGET_FILE:AO46MetalWindowPolicySmoke>
    )

    set_tests_properties(AO46MetalWindowPolicySmoke PROPERTIES
        ENVIRONMENT
            "DYLD_LIBRARY_PATH=${CMAKE_CURRENT_BINARY_DIR}"
    )

    add_executable(AO46MetalGalliumScreenSmoke
        tests/AO46MetalGalliumScreenSmoke.c
        MesaPlatform/AO46MetalAdapter.m
        MesaPlatform/AO46MetalGalliumScreen.c
    )

    target_include_directories(AO46MetalGalliumScreenSmoke
        PRIVATE
            MesaPlatform
            "${MESA_INCLUDE_DIRS}"
    )

    target_link_libraries(AO46MetalGalliumScreenSmoke
        PRIVATE
            ${MESA_GALLIUM_AUX}
            ${MESA_UTIL_LIB}
            ${MESA_UTIL_SIMD_LIB}
            ${MESA_UTIL_C11_LIB}
            "-framework Foundation"
            "-framework Metal"
    )

    add_test(
        NAME AO46MetalGalliumScreenSmoke
        COMMAND $<TARGET_FILE:AO46MetalGalliumScreenSmoke>
    )

    add_executable(AO46MetalGalliumTextureSmoke
        tests/AO46MetalGalliumTextureSmoke.c
        MesaPlatform/AO46MetalAdapter.m
        MesaPlatform/AO46MetalGalliumScreen.c
    )

    target_include_directories(AO46MetalGalliumTextureSmoke
        PRIVATE
            MesaPlatform
            "${MESA_INCLUDE_DIRS}"
    )

    target_link_libraries(AO46MetalGalliumTextureSmoke
        PRIVATE
            ${MESA_GALLIUM_AUX}
            ${MESA_UTIL_LIB}
            ${MESA_UTIL_SIMD_LIB}
            ${MESA_UTIL_C11_LIB}
            "-framework Foundation"
            "-framework Metal"
    )

    add_test(
        NAME AO46MetalGalliumTextureSmoke
        COMMAND $<TARGET_FILE:AO46MetalGalliumTextureSmoke>
    )

    add_executable(AO46MesaNIRComputeSmoke
        tests/AO46MesaNIRComputeSmoke.c
        MesaPlatform/AO46MetalAdapter.m
        MesaPlatform/AO46MetalGalliumScreen.c
        MesaPlatform/AO46MesaMSLComputePipeline.c
    )

    target_include_directories(AO46MesaNIRComputeSmoke
        PRIVATE
            MesaPlatform
            "${MESA_INCLUDE_DIRS}"
    )

    target_compile_definitions(AO46MesaNIRComputeSmoke
        PRIVATE
            ${MESA_COMPILE_DEFINITIONS}
    )

    target_link_libraries(AO46MesaNIRComputeSmoke
        PRIVATE
            AO46MesaMSLCompiler
            ${MESA_NIR_LIB}
            ${MESA_COMPILER_LIB}
            ${MESA_GALLIUM_AUX}
            ${MESA_UTIL_LIB}
            ${MESA_UTIL_SIMD_LIB}
            ${MESA_UTIL_C11_LIB}
            ${MESA_BLAKE3_LIB}
            "-framework Foundation"
            "-framework Metal"
    )

    add_test(
        NAME AO46MesaNIRComputeSmoke
        COMMAND $<TARGET_FILE:AO46MesaNIRComputeSmoke>
    )

    add_executable(AO46MesaNIRComputeStateSmoke
        tests/AO46MesaNIRComputeStateSmoke.c
        MesaPlatform/AO46MetalAdapter.m
        MesaPlatform/AO46MetalGalliumScreen.c
        MesaPlatform/AO46MesaMSLComputePipeline.c
        MesaPlatform/AO46MesaPolyTessellation.c
        MesaPlatform/AO46MesaPolyKernelCatalog.c
        MesaPlatform/AO46MesaPolyKernelExecutor.c
    )

    target_include_directories(AO46MesaNIRComputeStateSmoke
        PRIVATE
            MesaPlatform
            "${MESA_INCLUDE_DIRS}"
            "${AO46_MESA_LIBKK_GENERATED_DIR}"
    )

    target_compile_definitions(AO46MesaNIRComputeStateSmoke
        PRIVATE
            ${MESA_COMPILE_DEFINITIONS}
            AO46_HAVE_MESA_LIBKK=${AO46_HAVE_MESA_LIBKK}
    )

    target_link_libraries(AO46MesaNIRComputeStateSmoke
        PRIVATE
            AO46MesaPolyKernelArtifacts
            AO46MesaMSLCompiler
            ${MESA_POLY_NIR_LIB}
            ${MESA_NIR_LIB}
            ${MESA_COMPILER_LIB}
            ${MESA_GALLIUM_AUX}
            ${MESA_UTIL_LIB}
            ${MESA_UTIL_SIMD_LIB}
            ${MESA_UTIL_C11_LIB}
            ${MESA_BLAKE3_LIB}
            "-lc++"
            "-framework Foundation"
            "-framework Metal"
            "-framework IOSurface"
    )

    add_test(
        NAME AO46MesaNIRComputeStateSmoke
        COMMAND $<TARGET_FILE:AO46MesaNIRComputeStateSmoke>
    )

    add_executable(AO46MesaNIRSSBOSmoke
        tests/AO46MesaNIRSSBOSmoke.c
        MesaPlatform/AO46MetalAdapter.m
        MesaPlatform/AO46MetalGalliumScreen.c
        MesaPlatform/AO46MesaMSLComputePipeline.c
        MesaPlatform/AO46MesaPolyTessellation.c
        MesaPlatform/AO46MesaPolyKernelCatalog.c
        MesaPlatform/AO46MesaPolyKernelExecutor.c
    )

    target_include_directories(AO46MesaNIRSSBOSmoke
        PRIVATE
            MesaPlatform
            "${MESA_INCLUDE_DIRS}"
            "${AO46_MESA_LIBKK_GENERATED_DIR}"
    )

    target_compile_definitions(AO46MesaNIRSSBOSmoke
        PRIVATE
            ${MESA_COMPILE_DEFINITIONS}
            AO46_HAVE_MESA_LIBKK=${AO46_HAVE_MESA_LIBKK}
    )

    target_link_libraries(AO46MesaNIRSSBOSmoke
        PRIVATE
            AO46MesaPolyKernelArtifacts
            AO46MesaMSLCompiler
            ${MESA_POLY_NIR_LIB}
            ${MESA_NIR_LIB}
            ${MESA_COMPILER_LIB}
            ${MESA_GALLIUM_AUX}
            ${MESA_UTIL_LIB}
            ${MESA_UTIL_SIMD_LIB}
            ${MESA_UTIL_C11_LIB}
            ${MESA_BLAKE3_LIB}
            "-lc++"
            "-framework Foundation"
            "-framework Metal"
            "-framework IOSurface"
    )

    add_test(
        NAME AO46MesaNIRSSBOSmoke
        COMMAND $<TARGET_FILE:AO46MesaNIRSSBOSmoke>
    )

    add_executable(AO46MesaPolyTessellationSmoke
        tests/AO46MesaPolyTessellationSmoke.c
        MesaPlatform/AO46MesaPolyTessellation.c
        MesaPlatform/AO46MetalAdapter.m
        MesaPlatform/AO46MetalGalliumScreen.c
        MesaPlatform/AO46MesaMSLRenderPipeline.c
    )

    target_include_directories(AO46MesaPolyTessellationSmoke
        PRIVATE
            MesaPlatform
            "${MESA_INCLUDE_DIRS}"
    )

    target_compile_definitions(AO46MesaPolyTessellationSmoke
        PRIVATE
            ${MESA_COMPILE_DEFINITIONS}
    )

    target_link_libraries(AO46MesaPolyTessellationSmoke
        PRIVATE
            AO46MesaMSLCompiler
            ${MESA_POLY_NIR_LIB}
            ${MESA_NIR_LIB}
            ${MESA_COMPILER_LIB}
            ${MESA_GALLIUM_AUX}
            ${MESA_UTIL_LIB}
            ${MESA_UTIL_SIMD_LIB}
            ${MESA_UTIL_C11_LIB}
            ${MESA_BLAKE3_LIB}
            "-lc++"
            "-framework Foundation"
            "-framework Metal"
    )

    add_test(
        NAME AO46MesaPolyTessellationSmoke
        COMMAND $<TARGET_FILE:AO46MesaPolyTessellationSmoke>
    )

    if(AO46_HAVE_MESA_LIBKK)
        add_executable(AO46MesaPolyKernelCatalogSmoke
            tests/AO46MesaPolyKernelCatalogSmoke.m
            MesaPlatform/AO46MesaPolyTessellation.c
            MesaPlatform/AO46MesaPolyKernelCatalog.c
            MesaPlatform/AO46MesaPolyKernelExecutor.c
            MesaPlatform/AO46MetalAdapter.m
            MesaPlatform/AO46MetalGalliumScreen.c
            MesaPlatform/AO46MesaMSLComputePipeline.c
        )

        target_include_directories(AO46MesaPolyKernelCatalogSmoke
            PRIVATE
                MesaPlatform
                "${AO46_MESA_LIBKK_GENERATED_DIR}"
                "${MESA_INCLUDE_DIRS}"
        )

        target_compile_definitions(AO46MesaPolyKernelCatalogSmoke
            PRIVATE
                ${MESA_COMPILE_DEFINITIONS}
                AO46_HAVE_MESA_LIBKK=1
        )

        target_link_libraries(AO46MesaPolyKernelCatalogSmoke
            PRIVATE
            AO46MesaPolyKernelArtifacts
            AO46MesaMSLCompiler
            ${MESA_POLY_NIR_LIB}
            ${MESA_NIR_LIB}
            ${MESA_COMPILER_LIB}
            ${MESA_GALLIUM_AUX}
            ${MESA_UTIL_LIB}
            ${MESA_UTIL_SIMD_LIB}
            ${MESA_UTIL_C11_LIB}
            ${MESA_BLAKE3_LIB}
            "-lc++"
            "-framework Foundation"
            "-framework Metal"
        )

        target_compile_options(AO46MesaPolyKernelCatalogSmoke PRIVATE -fobjc-arc)

        add_test(
            NAME AO46MesaPolyKernelCatalogSmoke
            COMMAND $<TARGET_FILE:AO46MesaPolyKernelCatalogSmoke>
        )

        add_executable(AO46MesaPolyGalliumChainSmoke
            tests/AO46MesaPolyGalliumChainSmoke.m
            MesaPlatform/AO46MesaPolyTessellation.c
            MesaPlatform/AO46MesaPolyKernelCatalog.c
            MesaPlatform/AO46MesaPolyKernelExecutor.c
            MesaPlatform/AO46MetalAdapter.m
            MesaPlatform/AO46MetalGalliumScreen.c
            MesaPlatform/AO46MesaMSLComputePipeline.c
            MesaPlatform/AO46MesaMSLRenderPipeline.c
        )

        target_include_directories(AO46MesaPolyGalliumChainSmoke
            PRIVATE
                MesaPlatform
                "${AO46_MESA_LIBKK_GENERATED_DIR}"
                "${MESA_INCLUDE_DIRS}"
        )

        target_compile_definitions(AO46MesaPolyGalliumChainSmoke
            PRIVATE
                ${MESA_COMPILE_DEFINITIONS}
                AO46_HAVE_MESA_LIBKK=1
        )

        target_link_libraries(AO46MesaPolyGalliumChainSmoke
            PRIVATE
                AO46MesaPolyKernelArtifacts
                AO46MesaMSLCompiler
                ${MESA_POLY_NIR_LIB}
                ${MESA_NIR_LIB}
                ${MESA_COMPILER_LIB}
                ${MESA_GALLIUM_AUX}
                ${MESA_UTIL_LIB}
                ${MESA_UTIL_SIMD_LIB}
                ${MESA_UTIL_C11_LIB}
                ${MESA_BLAKE3_LIB}
                "-lc++"
                "-framework Foundation"
                "-framework Metal"
        )

        target_compile_options(AO46MesaPolyGalliumChainSmoke PRIVATE -fobjc-arc)

        add_test(
            NAME AO46MesaPolyGalliumChainSmoke
            COMMAND $<TARGET_FILE:AO46MesaPolyGalliumChainSmoke>
        )
    endif()

    add_executable(AO46MesaNIRGraphicsSmoke
        tests/AO46MesaNIRGraphicsSmoke.c
        MesaPlatform/AO46MetalAdapter.m
        MesaPlatform/AO46MetalGalliumScreen.c
        MesaPlatform/AO46MesaMSLRenderPipeline.c
    )

    target_include_directories(AO46MesaNIRGraphicsSmoke
        PRIVATE
            MesaPlatform
            "${MESA_INCLUDE_DIRS}"
    )

    target_compile_definitions(AO46MesaNIRGraphicsSmoke
        PRIVATE
            ${MESA_COMPILE_DEFINITIONS}
    )

    target_link_libraries(AO46MesaNIRGraphicsSmoke
        PRIVATE
            AO46MesaMSLCompiler
            ${MESA_NIR_LIB}
            ${MESA_COMPILER_LIB}
            ${MESA_GALLIUM_AUX}
            ${MESA_UTIL_LIB}
            ${MESA_UTIL_SIMD_LIB}
            ${MESA_UTIL_C11_LIB}
            ${MESA_BLAKE3_LIB}
            "-framework Foundation"
            "-framework Metal"
    )

    add_test(
        NAME AO46MesaNIRGraphicsSmoke
        COMMAND $<TARGET_FILE:AO46MesaNIRGraphicsSmoke>
    )

    add_executable(AO46MesaNIRBufferTextureGraphicsSmoke
        tests/AO46MesaNIRBufferTextureGraphicsSmoke.c
        MesaPlatform/AO46MetalAdapter.m
        MesaPlatform/AO46MetalGalliumScreen.c
        MesaPlatform/AO46MesaMSLRenderPipeline.c
    )

    target_include_directories(AO46MesaNIRBufferTextureGraphicsSmoke
        PRIVATE
            MesaPlatform
            "${MESA_INCLUDE_DIRS}"
    )

    target_compile_definitions(AO46MesaNIRBufferTextureGraphicsSmoke
        PRIVATE
            ${MESA_COMPILE_DEFINITIONS}
    )

    target_link_libraries(AO46MesaNIRBufferTextureGraphicsSmoke
        PRIVATE
            AO46MesaMSLCompiler
            ${MESA_NIR_LIB}
            ${MESA_COMPILER_LIB}
            ${MESA_GALLIUM_AUX}
            ${MESA_UTIL_LIB}
            ${MESA_UTIL_SIMD_LIB}
            ${MESA_UTIL_C11_LIB}
            ${MESA_BLAKE3_LIB}
            "-framework Foundation"
            "-framework Metal"
    )

    add_test(
        NAME AO46MesaNIRBufferTextureGraphicsSmoke
        COMMAND $<TARGET_FILE:AO46MesaNIRBufferTextureGraphicsSmoke>
    )

    add_executable(AO46MesaNIRTextureSmoke
        tests/AO46MesaNIRTextureSmoke.c
        MesaPlatform/AO46MetalAdapter.m
        MesaPlatform/AO46MetalGalliumScreen.c
        MesaPlatform/AO46MesaMSLRenderPipeline.c
    )

    target_include_directories(AO46MesaNIRTextureSmoke
        PRIVATE
            MesaPlatform
            "${MESA_INCLUDE_DIRS}"
    )

    target_compile_definitions(AO46MesaNIRTextureSmoke
        PRIVATE
            ${MESA_COMPILE_DEFINITIONS}
    )

    target_link_libraries(AO46MesaNIRTextureSmoke
        PRIVATE
            AO46MesaMSLCompiler
            ${MESA_NIR_LIB}
            ${MESA_COMPILER_LIB}
            ${MESA_GALLIUM_AUX}
            ${MESA_UTIL_LIB}
            ${MESA_UTIL_SIMD_LIB}
            ${MESA_UTIL_C11_LIB}
            ${MESA_BLAKE3_LIB}
            "-framework Foundation"
            "-framework Metal"
    )

    add_test(
        NAME AO46MesaNIRTextureSmoke
        COMMAND $<TARGET_FILE:AO46MesaNIRTextureSmoke>
    )

    add_executable(AO46MesaNIRUniformSmoke
        tests/AO46MesaNIRUniformSmoke.c
        MesaPlatform/AO46MetalAdapter.m
        MesaPlatform/AO46MetalGalliumScreen.c
        MesaPlatform/AO46MesaMSLRenderPipeline.c
    )

    target_include_directories(AO46MesaNIRUniformSmoke
        PRIVATE
            MesaPlatform
            "${MESA_INCLUDE_DIRS}"
    )

    target_compile_definitions(AO46MesaNIRUniformSmoke
        PRIVATE
            ${MESA_COMPILE_DEFINITIONS}
    )

    target_link_libraries(AO46MesaNIRUniformSmoke
        PRIVATE
            AO46MesaMSLCompiler
            ${MESA_NIR_LIB}
            ${MESA_COMPILER_LIB}
            ${MESA_GALLIUM_AUX}
            ${MESA_UTIL_LIB}
            ${MESA_UTIL_SIMD_LIB}
            ${MESA_UTIL_C11_LIB}
            ${MESA_BLAKE3_LIB}
            "-framework Foundation"
            "-framework Metal"
    )

    add_test(
        NAME AO46MesaNIRUniformSmoke
        COMMAND $<TARGET_FILE:AO46MesaNIRUniformSmoke>
    )

    add_executable(AO46MesaNIRIndexedSmoke
        tests/AO46MesaNIRIndexedSmoke.c
        MesaPlatform/AO46MetalAdapter.m
        MesaPlatform/AO46MetalGalliumScreen.c
        MesaPlatform/AO46MesaMSLComputePipeline.c
        MesaPlatform/AO46MesaMSLRenderPipeline.c
    )

    target_include_directories(AO46MesaNIRIndexedSmoke
        PRIVATE
            MesaPlatform
            "${MESA_INCLUDE_DIRS}"
    )

    target_compile_definitions(AO46MesaNIRIndexedSmoke
        PRIVATE
            ${MESA_COMPILE_DEFINITIONS}
    )

    target_link_libraries(AO46MesaNIRIndexedSmoke
        PRIVATE
            AO46MesaMSLCompiler
            ${MESA_NIR_LIB}
            ${MESA_COMPILER_LIB}
            ${MESA_GALLIUM_AUX}
            ${MESA_UTIL_LIB}
            ${MESA_UTIL_SIMD_LIB}
            ${MESA_UTIL_C11_LIB}
            ${MESA_BLAKE3_LIB}
            "-framework Foundation"
            "-framework Metal"
    )

    add_test(
        NAME AO46MesaNIRIndexedSmoke
        COMMAND $<TARGET_FILE:AO46MesaNIRIndexedSmoke>
    )

    if(OPENGLKHR_BUILD_ARCHIVED_AGX_RESEARCH)
    add_executable(AppleOpenGLAsahiBackendSmoke
        tests/AppleOpenGLAsahiBackendSmoke.c
        MesaPlatform/AppleOpenGLAsahi.c
        MesaPlatform/AppleAGXNativeBridge.m
        MesaPlatform/AppleAGXMetalAllocation.m
        MesaPlatform/AppleAGXMetalResourceRef.m
        MesaPlatform/AppleAGXMetalBOProvider.m
        "${MESA_ROOT}/src/asahi/lib/agx_macos_device.c"
        "${MESA_ROOT}/src/asahi/lib/agx_macos_uabi.c"
        "${MESA_ROOT}/src/asahi/lib/agx_macos_bo.c"
        "${MESA_ROOT}/src/asahi/lib/agx_macos_shader_provenance.c"
        "${MESA_ROOT}/src/asahi/lib/agx_macos_queue.c"
        "${MESA_ROOT}/src/asahi/lib/agx_macos_command.c"
        "${MESA_ROOT}/src/asahi/lib/agx_macos_submission_observation.c"
        "${MESA_ROOT}/src/asahi/lib/agx_macos_submission_build.c"
        "${MESA_ROOT}/src/asahi/lib/agx_macos_submission_lease.c"
        "${MESA_ROOT}/src/asahi/lib/agx_macos_iosurface.m"
        "${MESA_ROOT}/src/asahi/lib/agx_macos_screen_bootstrap.c"
        "${MESA_ROOT}/src/asahi/lib/agx_macos_mesa_device.c"
    )

    target_include_directories(AppleOpenGLAsahiBackendSmoke
        PRIVATE
            MesaPlatform
            "${MESA_INCLUDE_DIRS}"
    )

    # The smoke compiles the same direct Mesa device adapter as the framework,
    # so it must use Mesa's generated platform configuration as well.
    target_compile_definitions(AppleOpenGLAsahiBackendSmoke
        PRIVATE
            ${MESA_COMPILE_DEFINITIONS}
    )

    target_link_libraries(AppleOpenGLAsahiBackendSmoke
        PRIVATE
            ${MESA_ASAHI_CORE_LIB}
            ${MESA_ASAHI_DECODE_LIB}
            ${MESA_AGX_DISASM_LIB}
            ${MESA_ASAHI_LAYOUT_LIB}
            ${MESA_UTIL_LIB}
            ${MESA_UTIL_SIMD_LIB}
            ${MESA_UTIL_C11_LIB}
            ${MESA_BLAKE3_LIB}
            "-lc++"
            "-framework IOKit"
            "-framework CoreFoundation"
            "-framework Foundation"
            "-framework IOSurface"
            "-framework Metal"
    )

    add_test(
        NAME AppleOpenGLAsahiBackendSmoke
        COMMAND $<TARGET_FILE:AppleOpenGLAsahiBackendSmoke>
    )

    # Development-only proof that the submit anchor observed in a controlled
    # trace can be resolved from the active shared-cache image. It never calls
    # the private symbol and is skipped on profiles without that exact anchor.
    add_executable(AppleAGXNativeBridgeSymbolProbe
        tests/AppleAGXNativeBridgeSymbolProbe.c
    )

    add_test(
        NAME AppleAGXNativeBridgeSymbolProbe
        COMMAND $<TARGET_FILE:AppleAGXNativeBridgeSymbolProbe>
    )

    set_tests_properties(AppleAGXNativeBridgeSymbolProbe PROPERTIES
        SKIP_RETURN_CODE 77
    )

    # Read only the Objective-C type metadata of the traced IOGPU submission
    # method. This is not an invocation path and does not inspect object state.
    add_executable(AppleAGXNativeBridgeRuntimeProbe
        tests/AppleAGXNativeBridgeRuntimeProbe.m
    )

    target_link_libraries(AppleAGXNativeBridgeRuntimeProbe
        PRIVATE
            "-lobjc"
    )

    add_test(
        NAME AppleAGXNativeBridgeRuntimeProbe
        COMMAND $<TARGET_FILE:AppleAGXNativeBridgeRuntimeProbe>
    )

    set_tests_properties(AppleAGXNativeBridgeRuntimeProbe PROPERTIES
        SKIP_RETURN_CODE 77
    )

    # Retains only Apple's opaque generic device root and resolves the C entry
    # points observed in trace. It performs no private resource, queue, or GPU
    # submission call.
    add_executable(AppleAGXNativeBridgeBootstrapSmoke
        tests/AppleAGXNativeBridgeBootstrapSmoke.m
        MesaPlatform/AppleAGXNativeBridge.m
        "${MESA_ROOT}/src/asahi/lib/agx_macos_device.c"
    )

    target_include_directories(AppleAGXNativeBridgeBootstrapSmoke
        PRIVATE
            MesaPlatform
            "${MESA_INCLUDE_DIRS}"
    )

    target_compile_definitions(AppleAGXNativeBridgeBootstrapSmoke
        PRIVATE
            ${MESA_COMPILE_DEFINITIONS}
    )

    target_link_libraries(AppleAGXNativeBridgeBootstrapSmoke
        PRIVATE
            "-framework Metal"
            "-framework IOKit"
            "-framework CoreFoundation"
            "-lobjc"
    )

    add_test(
        NAME AppleAGXNativeBridgeBootstrapSmoke
        COMMAND $<TARGET_FILE:AppleAGXNativeBridgeBootstrapSmoke>
    )

    set_tests_properties(AppleAGXNativeBridgeBootstrapSmoke PROPERTIES
        SKIP_RETURN_CODE 77
    )

    # Constructs and returns one Apple-owned command carrier using the
    # profile-validated storage pool. It does not bind resources or submit.
    add_executable(AppleAGXOpaqueCarrierSmoke
        tests/AppleAGXOpaqueCarrierSmoke.m
        MesaPlatform/AppleAGXNativeBridge.m
        MesaPlatform/AppleAGXOpaqueCarrier.m
        "${MESA_ROOT}/src/asahi/lib/agx_macos_device.c"
    )

    target_include_directories(AppleAGXOpaqueCarrierSmoke
        PRIVATE
            MesaPlatform
            "${MESA_INCLUDE_DIRS}"
    )

    target_compile_definitions(AppleAGXOpaqueCarrierSmoke
        PRIVATE
            ${MESA_COMPILE_DEFINITIONS}
    )

    target_link_libraries(AppleAGXOpaqueCarrierSmoke
        PRIVATE
            "-framework Metal"
            "-framework IOKit"
            "-framework CoreFoundation"
            "-lobjc"
    )

    add_test(
        NAME AppleAGXOpaqueCarrierSmoke
        COMMAND $<TARGET_FILE:AppleAGXOpaqueCarrierSmoke>
    )

    set_tests_properties(AppleAGXOpaqueCarrierSmoke PROPERTIES
        SKIP_RETURN_CODE 77
    )

    # Uses the profiled Apple queue and command-buffer initializers to obtain
    # configured carrier storage, then reads its slot table. It performs no
    # encoding, resource binding, commit, or GPU submission.
    add_executable(AppleAGXConfiguredCarrierSmoke
        tests/AppleAGXConfiguredCarrierSmoke.m
        MesaPlatform/AppleAGXNativeBridge.m
        MesaPlatform/AppleAGXOpaqueCarrier.m
        MesaPlatform/AppleAGXConfiguredCarrier.m
        "${MESA_ROOT}/src/asahi/lib/agx_macos_device.c"
    )

    target_include_directories(AppleAGXConfiguredCarrierSmoke
        PRIVATE
            MesaPlatform
            "${MESA_INCLUDE_DIRS}"
    )

    target_compile_definitions(AppleAGXConfiguredCarrierSmoke
        PRIVATE
            ${MESA_COMPILE_DEFINITIONS}
    )

    target_link_libraries(AppleAGXConfiguredCarrierSmoke
        PRIVATE
            "-framework Metal"
            "-framework IOKit"
            "-framework CoreFoundation"
            "-lobjc"
    )

    add_test(
        NAME AppleAGXConfiguredCarrierSmoke
        COMMAND $<TARGET_FILE:AppleAGXConfiguredCarrierSmoke>
    )

    set_tests_properties(AppleAGXConfiguredCarrierSmoke PROPERTIES
        SKIP_RETURN_CODE 77
    )

    # Isolated direct storage-level lifecycle check. It calls exactly the
    # profile-validated begin/end pair using Apple-owned command memory, then
    # exits without resource admission, command bytes, commit, or submission.
    add_executable(AppleAGXNoResourceSegmentSmoke
        tests/AppleAGXNoResourceSegmentSmoke.m
        MesaPlatform/AppleAGXNativeBridge.m
        MesaPlatform/AppleAGXOpaqueCarrier.m
        MesaPlatform/AppleAGXConfiguredCarrier.m
        "${MESA_ROOT}/src/asahi/lib/agx_macos_device.c"
    )

    target_include_directories(AppleAGXNoResourceSegmentSmoke
        PRIVATE
            MesaPlatform
            "${MESA_INCLUDE_DIRS}"
    )

    target_compile_definitions(AppleAGXNoResourceSegmentSmoke
        PRIVATE
            ${MESA_COMPILE_DEFINITIONS}
    )

    target_link_libraries(AppleAGXNoResourceSegmentSmoke
        PRIVATE
            "-framework Metal"
            "-framework IOKit"
            "-framework CoreFoundation"
            "-lobjc"
    )

    add_test(
        NAME AppleAGXNoResourceSegmentSmoke
        COMMAND $<TARGET_FILE:AppleAGXNoResourceSegmentSmoke>
    )

    set_tests_properties(AppleAGXNoResourceSegmentSmoke PROPERTIES
        SKIP_RETURN_CODE 77
    )

    # Identifies the Apple-owned generic resource behind one public buffer.
    # It only compares read-only resource identity and address reporting.
    add_executable(AppleAGXMetalResourceRefSmoke
        tests/AppleAGXMetalResourceRefSmoke.m
        MesaPlatform/AppleAGXNativeBridge.m
        MesaPlatform/AppleAGXMetalResourceRef.m
        "${MESA_ROOT}/src/asahi/lib/agx_macos_device.c"
    )

    target_include_directories(AppleAGXMetalResourceRefSmoke
        PRIVATE
            MesaPlatform
            "${MESA_INCLUDE_DIRS}"
    )

    target_compile_definitions(AppleAGXMetalResourceRefSmoke
        PRIVATE
            ${MESA_COMPILE_DEFINITIONS}
    )

    target_link_libraries(AppleAGXMetalResourceRefSmoke
        PRIVATE
            "-framework Metal"
            "-framework IOKit"
            "-framework CoreFoundation"
            "-lobjc"
    )

    add_test(
        NAME AppleAGXMetalResourceRefSmoke
        COMMAND $<TARGET_FILE:AppleAGXMetalResourceRefSmoke>
    )

    set_tests_properties(AppleAGXMetalResourceRefSmoke PROPERTIES
        SKIP_RETURN_CODE 77
    )

    # Admits one retained Apple-owned buffer through the profiled carrier
    # resource-list boundary, then exits before command encoding or submission.
    add_executable(AppleAGXCarrierResourceBindingSmoke
        tests/AppleAGXCarrierResourceBindingSmoke.m
        MesaPlatform/AppleAGXNativeBridge.m
        MesaPlatform/AppleAGXOpaqueCarrier.m
        MesaPlatform/AppleAGXConfiguredCarrier.m
        MesaPlatform/AppleAGXMetalResourceRef.m
        "${MESA_ROOT}/src/asahi/lib/agx_macos_device.c"
    )

    target_include_directories(AppleAGXCarrierResourceBindingSmoke
        PRIVATE
            MesaPlatform
            "${MESA_INCLUDE_DIRS}"
    )

    target_compile_definitions(AppleAGXCarrierResourceBindingSmoke
        PRIVATE
            ${MESA_COMPILE_DEFINITIONS}
    )

    target_link_libraries(AppleAGXCarrierResourceBindingSmoke
        PRIVATE
            "-framework Metal"
            "-framework IOKit"
            "-framework CoreFoundation"
            "-lobjc"
    )

    add_test(
        NAME AppleAGXCarrierResourceBindingSmoke
        COMMAND $<TARGET_FILE:AppleAGXCarrierResourceBindingSmoke>
    )

    set_tests_properties(AppleAGXCarrierResourceBindingSmoke PROPERTIES
        SKIP_RETURN_CODE 77
    )

    # Allocates a real Mesa BO through the Apple-owned provider, verifies the
    # retained buffer's carrier binding, and admits it without encoding or
    # submitting GPU work.
    add_executable(AppleAGXMesaBOCarrierBindingSmoke
        tests/AppleAGXMesaBOCarrierBindingSmoke.m
        MesaPlatform/AppleAGXNativeBridge.m
        MesaPlatform/AppleAGXOpaqueCarrier.m
        MesaPlatform/AppleAGXConfiguredCarrier.m
        MesaPlatform/AppleAGXMetalAllocation.m
        MesaPlatform/AppleAGXMetalResourceRef.m
        MesaPlatform/AppleAGXMetalBOProvider.m
    )

    target_include_directories(AppleAGXMesaBOCarrierBindingSmoke
        PRIVATE
            MesaPlatform
            "${MESA_INCLUDE_DIRS}"
    )

    target_compile_definitions(AppleAGXMesaBOCarrierBindingSmoke
        PRIVATE
            ${MESA_COMPILE_DEFINITIONS}
    )

    target_link_libraries(AppleAGXMesaBOCarrierBindingSmoke
        PRIVATE
            ${MESA_ASAHI_MACOS_WINSYS_LIB}
            ${MESA_ASAHI_CORE_LIB}
            ${MESA_ASAHI_DECODE_LIB}
            ${MESA_AGX_DISASM_LIB}
            ${MESA_ASAHI_LAYOUT_LIB}
            ${MESA_UTIL_LIB}
            ${MESA_UTIL_SIMD_LIB}
            ${MESA_UTIL_C11_LIB}
            ${MESA_BLAKE3_LIB}
            "-lc++"
            "-framework Metal"
            "-framework IOKit"
            "-framework CoreFoundation"
            "-lobjc"
    )
    add_dependencies(AppleAGXMesaBOCarrierBindingSmoke AO46MesaMacOSWinsysArchive)

    add_test(
        NAME AppleAGXMesaBOCarrierBindingSmoke
        COMMAND $<TARGET_FILE:AppleAGXMesaBOCarrierBindingSmoke>
    )

    set_tests_properties(AppleAGXMesaBOCarrierBindingSmoke PROPERTIES
        SKIP_RETURN_CODE 77
    )

    # Exercises the supported Apple-owned allocation path. This retains public
    # MTLBuffer objects and observes their public GPU VAs; it never invokes an
    # IOGPU private resource, queue, or submission entry point.
    add_executable(AppleAGXMetalAllocationSmoke
        tests/AppleAGXMetalAllocationSmoke.m
        MesaPlatform/AppleAGXNativeBridge.m
        MesaPlatform/AppleAGXMetalAllocation.m
        "${MESA_ROOT}/src/asahi/lib/agx_macos_device.c"
    )

    target_include_directories(AppleAGXMetalAllocationSmoke
        PRIVATE
            MesaPlatform
            "${MESA_INCLUDE_DIRS}"
    )

    target_compile_definitions(AppleAGXMetalAllocationSmoke
        PRIVATE
            ${MESA_COMPILE_DEFINITIONS}
    )

    target_link_libraries(AppleAGXMetalAllocationSmoke
        PRIVATE
            "-framework Metal"
            "-framework IOKit"
            "-framework CoreFoundation"
            "-lobjc"
    )

    add_test(
        NAME AppleAGXMetalAllocationSmoke
        COMMAND $<TARGET_FILE:AppleAGXMetalAllocationSmoke>
    )

    set_tests_properties(AppleAGXMetalAllocationSmoke PROPERTIES
        SKIP_RETURN_CODE 77
    )

    # Couples public Metal allocation lifetime to only the independently
    # observed resource-address slots in a CPU-mapped command record. It does
    # not build a sidecar or submit a command through IOGPU or Metal.
    add_executable(AppleAGXMetalResourceSetSmoke
        tests/AppleAGXMetalResourceSetSmoke.m
        MesaPlatform/AppleAGXNativeBridge.m
        MesaPlatform/AppleAGXMetalAllocation.m
        MesaPlatform/AppleAGXMetalResourceSet.m
        "${MESA_ROOT}/src/asahi/lib/agx_macos_device.c"
        "${MESA_ROOT}/src/asahi/lib/agx_macos_bo.c"
        "${MESA_ROOT}/src/asahi/lib/agx_macos_queue.c"
        "${MESA_ROOT}/src/asahi/lib/agx_macos_submission_observation.c"
        "${MESA_ROOT}/src/asahi/lib/agx_macos_submission_build.c"
        "${MESA_ROOT}/src/asahi/lib/agx_macos_submission_lease.c"
    )

    target_include_directories(AppleAGXMetalResourceSetSmoke
        PRIVATE
            MesaPlatform
            "${MESA_INCLUDE_DIRS}"
    )

    target_compile_definitions(AppleAGXMetalResourceSetSmoke
        PRIVATE
            ${MESA_COMPILE_DEFINITIONS}
    )

    target_link_libraries(AppleAGXMetalResourceSetSmoke
        PRIVATE
            ${MESA_UTIL_LIB}
            ${MESA_UTIL_SIMD_LIB}
            ${MESA_UTIL_C11_LIB}
            ${MESA_BLAKE3_LIB}
            "-framework Metal"
            "-framework IOKit"
            "-framework CoreFoundation"
            "-lobjc"
            "-lc++"
    )

    add_test(
        NAME AppleAGXMetalResourceSetSmoke
        COMMAND $<TARGET_FILE:AppleAGXMetalResourceSetSmoke>
    )

    set_tests_properties(AppleAGXMetalResourceSetSmoke PROPERTIES
        SKIP_RETURN_CODE 77
    )

    # This control is launched only by capture_iogpu_resource_constructor.sh.
    # It uses public Metal allocation so LLDB can observe Apple's generic IOGPU
    # constructor; it is not a framework runtime or a CTest workload.
    add_executable(AppleAGXResourceConstructorControl
        tests/AppleAGXResourceConstructorControl.m
    )

    target_link_libraries(AppleAGXResourceConstructorControl
        PRIVATE
            "-framework Metal"
            "-lobjc"
    )

    # This public-Metal hardware smoke establishes CPU/GPU visibility through
    # a private buffer without invoking an IOGPU private entry point.
    add_executable(AppleAGXResourceCoherenceSmoke
        tests/AppleAGXResourceCoherenceSmoke.m
    )

    target_link_libraries(AppleAGXResourceCoherenceSmoke
        PRIVATE
            "-framework Metal"
            "-lobjc"
    )

    add_test(
        NAME AppleAGXResourceCoherenceSmoke
        COMMAND $<TARGET_FILE:AppleAGXResourceCoherenceSmoke>
    )

    # This public-Metal control emits no render or compute encoder work. Its
    # debugger-only capture validates Apple's generic queue contract.
    add_executable(AppleAGXQueueContractControl
        tests/AppleAGXQueueContractControl.m
    )

    target_link_libraries(AppleAGXQueueContractControl
        PRIVATE
            "-framework Metal"
            "-lobjc"
    )

    target_compile_options(AppleAGXQueueContractControl PRIVATE -fblocks)

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

    add_executable(AGXMacOSUABIContractSmoke
        "${MESA_ROOT}/src/asahi/lib/tests/agx_macos_uabi_contract_smoke.c"
        "${MESA_ROOT}/src/asahi/lib/agx_macos_device.c"
        "${MESA_ROOT}/src/asahi/lib/agx_macos_uabi.c"
    )

    target_include_directories(AGXMacOSUABIContractSmoke
        PRIVATE
            "${MESA_ROOT}/src/asahi/lib"
    )

    target_link_libraries(AGXMacOSUABIContractSmoke
        PRIVATE
            "-framework IOKit"
            "-framework CoreFoundation"
    )

    add_test(
        NAME AGXMacOSUABIContractSmoke
        COMMAND $<TARGET_FILE:AGXMacOSUABIContractSmoke>
    )

    add_executable(AGXMacOSDeviceSessionStateSmoke
        "${MESA_ROOT}/src/asahi/lib/tests/agx_macos_device_session_state_smoke.c"
        "${MESA_ROOT}/src/asahi/lib/agx_macos_device.c"
        "${MESA_ROOT}/src/asahi/lib/agx_macos_uabi.c"
    )

    target_include_directories(AGXMacOSDeviceSessionStateSmoke
        PRIVATE
            "${MESA_ROOT}/src/asahi/lib"
    )

    target_link_libraries(AGXMacOSDeviceSessionStateSmoke
        PRIVATE
            "-framework IOKit"
            "-framework CoreFoundation"
    )

    add_test(
        NAME AGXMacOSDeviceSessionStateSmoke
        COMMAND $<TARGET_FILE:AGXMacOSDeviceSessionStateSmoke>
    )

    add_executable(AGXMacOSSubmissionBuildSmoke
        "${MESA_ROOT}/src/asahi/lib/tests/agx_macos_submission_build_smoke.c"
        "${MESA_ROOT}/src/asahi/lib/agx_macos_device.c"
        "${MESA_ROOT}/src/asahi/lib/agx_macos_bo.c"
        "${MESA_ROOT}/src/asahi/lib/agx_macos_queue.c"
        "${MESA_ROOT}/src/asahi/lib/agx_macos_submission_observation.c"
        "${MESA_ROOT}/src/asahi/lib/agx_macos_submission_build.c"
        "${MESA_ROOT}/src/asahi/lib/agx_macos_submission_lease.c"
    )

    target_include_directories(AGXMacOSSubmissionBuildSmoke
        PRIVATE
            "${MESA_ROOT}/src/asahi/lib"
    )

    target_link_libraries(AGXMacOSSubmissionBuildSmoke
        PRIVATE
            "-framework IOKit"
            "-framework CoreFoundation"
    )

    add_test(
        NAME AGXMacOSSubmissionBuildSmoke
        COMMAND $<TARGET_FILE:AGXMacOSSubmissionBuildSmoke>
    )

    add_executable(AGXMacOSSubmissionLeaseSmoke
        "${MESA_ROOT}/src/asahi/lib/tests/agx_macos_submission_lease_smoke.c"
        "${MESA_ROOT}/src/asahi/lib/agx_macos_device.c"
        "${MESA_ROOT}/src/asahi/lib/agx_macos_bo.c"
        "${MESA_ROOT}/src/asahi/lib/agx_macos_queue.c"
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

    # The framework compiles this adapter in OpenGL46RuntimeObjects. This
    # private smoke links the same Mesa archives directly because agx_bo_* is
    # intentionally not exported from the framework ABI.
    add_executable(AGXMacOSMesaDeviceSmoke
        "${MESA_ROOT}/src/asahi/lib/tests/agx_macos_mesa_device_smoke.c"
    )

    target_include_directories(AGXMacOSMesaDeviceSmoke
        PRIVATE
            "${MESA_INCLUDE_DIRS}"
    )

    target_compile_definitions(AGXMacOSMesaDeviceSmoke
        PRIVATE
            ${MESA_COMPILE_DEFINITIONS}
    )

    target_link_libraries(AGXMacOSMesaDeviceSmoke
        PRIVATE
            ${MESA_ASAHI_MACOS_WINSYS_LIB}
            ${MESA_ASAHI_CORE_LIB}
            ${MESA_ASAHI_DECODE_LIB}
            ${MESA_AGX_DISASM_LIB}
            ${MESA_ASAHI_LAYOUT_LIB}
            ${MESA_UTIL_LIB}
            ${MESA_UTIL_SIMD_LIB}
            ${MESA_UTIL_C11_LIB}
            ${MESA_BLAKE3_LIB}
            "-lc++"
            "-framework IOKit"
            "-framework CoreFoundation"
            "-framework Foundation"
            "-framework IOSurface"
    )
    add_dependencies(AGXMacOSMesaDeviceSmoke AO46MesaMacOSWinsysArchive)

    add_test(
        NAME AGXMacOSMesaDeviceSmoke
        COMMAND $<TARGET_FILE:AGXMacOSMesaDeviceSmoke>
    )

    add_executable(AGXMacOSShaderProvenanceSmoke
        "${MESA_ROOT}/src/asahi/lib/tests/agx_macos_shader_provenance_smoke.c"
        "${MESA_ROOT}/src/asahi/lib/agx_macos_device.c"
        "${MESA_ROOT}/src/asahi/lib/agx_macos_shader_provenance.c"
    )

    target_include_directories(AGXMacOSShaderProvenanceSmoke
        PRIVATE
            "${MESA_INCLUDE_DIRS}"
    )

    target_compile_definitions(AGXMacOSShaderProvenanceSmoke
        PRIVATE
            ${MESA_COMPILE_DEFINITIONS}
    )

    target_link_libraries(AGXMacOSShaderProvenanceSmoke
        PRIVATE
            "-framework IOKit"
            "-framework CoreFoundation"
    )

    add_test(
        NAME AGXMacOSShaderProvenanceSmoke
        COMMAND $<TARGET_FILE:AGXMacOSShaderProvenanceSmoke>
    )

    add_executable(AGXSubmitInfoSmoke
        "${MESA_ROOT}/src/asahi/lib/tests/agx_submit_info_smoke.c"
    )

    target_include_directories(AGXSubmitInfoSmoke
        PRIVATE
            "${MESA_INCLUDE_DIRS}"
    )

    target_compile_definitions(AGXSubmitInfoSmoke
        PRIVATE
            ${MESA_COMPILE_DEFINITIONS}
    )

    target_link_libraries(AGXSubmitInfoSmoke
        PRIVATE
            ${MESA_ASAHI_CORE_LIB}
            ${MESA_ASAHI_DECODE_LIB}
            ${MESA_AGX_DISASM_LIB}
            ${MESA_ASAHI_LAYOUT_LIB}
            ${MESA_UTIL_LIB}
            ${MESA_UTIL_SIMD_LIB}
            ${MESA_UTIL_C11_LIB}
            ${MESA_BLAKE3_LIB}
            "-lc++"
    )

    add_test(
        NAME AGXSubmitInfoSmoke
        COMMAND $<TARGET_FILE:AGXSubmitInfoSmoke>
    )

    endif()

    add_executable(AO46RuntimeCompatSmoke
        tests/AO46RuntimeCompatSmoke.c
    )

    target_include_directories(AO46RuntimeCompatSmoke
        PRIVATE
            runtime/include
            client/include
            drivers/include
            MesaPlatform
            "${MESA_INCLUDE_DIRS}"
    )

    target_compile_definitions(AO46RuntimeCompatSmoke
        PRIVATE
            GL_SILENCE_DEPRECATION
    )

    target_link_libraries(AO46RuntimeCompatSmoke
        PRIVATE
            OpenGL_4_6
            AO46MesaMetalBackend
    )

    add_test(
        NAME AO46RuntimeCompatSmoke
        COMMAND $<TARGET_FILE:AO46RuntimeCompatSmoke>
    )

    set_tests_properties(AO46RuntimeCompatSmoke PROPERTIES
        ENVIRONMENT
            "AO46_FRAMEWORK_PATH=$<TARGET_FILE:OpenGL_4_6>;DYLD_FRAMEWORK_PATH=${CMAKE_CURRENT_BINARY_DIR};DYLD_LIBRARY_PATH=${CMAKE_CURRENT_BINARY_DIR}"
    )

    add_executable(AO46MesaWindowLayerSmoke
        tests/AO46MesaWindowLayerSmoke.m
    )

    target_include_directories(AO46MesaWindowLayerSmoke
        PRIVATE
            runtime/include
            MesaPlatform
            "${MESA_INCLUDE_DIRS}"
    )

    target_compile_definitions(AO46MesaWindowLayerSmoke
        PRIVATE
            GL_SILENCE_DEPRECATION
    )

    target_link_libraries(AO46MesaWindowLayerSmoke
        PRIVATE
            OpenGL_4_6
            "-framework CoreGraphics"
            "-framework QuartzCore"
    )

    target_compile_options(AO46MesaWindowLayerSmoke PRIVATE -fobjc-arc)

    add_test(
        NAME AO46MesaWindowLayerSmoke
        COMMAND $<TARGET_FILE:AO46MesaWindowLayerSmoke>
    )

    set_tests_properties(AO46MesaWindowLayerSmoke PROPERTIES
        ENVIRONMENT
            "AO46_FRAMEWORK_PATH=$<TARGET_FILE:OpenGL_4_6>;DYLD_FRAMEWORK_PATH=${CMAKE_CURRENT_BINARY_DIR};DYLD_LIBRARY_PATH=${CMAKE_CURRENT_BINARY_DIR}"
    )

    # A real present requires a WindowServer, so this stays opt-in rather than CTest.
    add_executable(AO46MesaWindowPresentationSmoke
        tests/AO46MesaWindowPresentationSmoke.m
    )

    target_include_directories(AO46MesaWindowPresentationSmoke
        PRIVATE
            runtime/include
            MesaPlatform
            "${MESA_INCLUDE_DIRS}"
    )

    target_compile_definitions(AO46MesaWindowPresentationSmoke
        PRIVATE
            GL_SILENCE_DEPRECATION
    )

    target_link_libraries(AO46MesaWindowPresentationSmoke
        PRIVATE
            OpenGL_4_6
            "-framework AppKit"
            "-framework QuartzCore"
    )

    target_compile_options(AO46MesaWindowPresentationSmoke PRIVATE -fobjc-arc)

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
            AO46MesaMetalBackend
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

    add_executable(AO46MesaCapabilityAuditSmoke
        tests/AO46MesaCapabilityAuditSmoke.c
    )

    target_include_directories(AO46MesaCapabilityAuditSmoke
        PRIVATE
            runtime/include
            MesaPlatform
            "${MESA_INCLUDE_DIRS}"
    )

    target_link_libraries(AO46MesaCapabilityAuditSmoke
        PRIVATE
            OpenGL_4_6
    )

    add_test(
        NAME AO46MesaCapabilityAuditSmoke
        COMMAND $<TARGET_FILE:AO46MesaCapabilityAuditSmoke>
    )

    set_tests_properties(AO46MesaCapabilityAuditSmoke PROPERTIES
        ENVIRONMENT
            "AO46_FRAMEWORK_PATH=$<TARGET_FILE:OpenGL_4_6>;DYLD_FRAMEWORK_PATH=${CMAKE_CURRENT_BINARY_DIR};DYLD_LIBRARY_PATH=${CMAKE_CURRENT_BINARY_DIR}"
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

    # Several smoke targets compile the adapter directly to isolate Mesa layers.
    # Keep their framework set in sync with the adapter's IOSurface import ABI.
    foreach(AO46_DIRECT_ADAPTER_TARGET
        AO46MetalAdapterSmoke
        AO46MetalGalliumScreenSmoke
        AO46MetalGalliumTextureSmoke
        AO46MesaNIRComputeSmoke
        AO46MesaNIRComputeStateSmoke
        AO46MesaNIRSSBOSmoke
        AO46MesaPolyTessellationSmoke
        AO46MesaPolyKernelCatalogSmoke
        AO46MesaPolyGalliumChainSmoke
        AO46MesaNIRGraphicsSmoke
        AO46MesaNIRBufferTextureGraphicsSmoke
        AO46MesaNIRTextureSmoke
        AO46MesaNIRUniformSmoke
        AO46MesaNIRIndexedSmoke
    )
        if(TARGET ${AO46_DIRECT_ADAPTER_TARGET})
            if(NOT AO46_DIRECT_ADAPTER_TARGET STREQUAL "AO46MetalAdapterSmoke")
                target_sources(${AO46_DIRECT_ADAPTER_TARGET}
                    PRIVATE
                        MesaPlatform/AO46MesaRGB32BufferTextureBinding.c
                        MesaPlatform/AO46MesaNIRBufferTexture.c
                        MesaPlatform/AO46MesaRGB32BufferTexturePipeline.c
                        MesaPlatform/AO46MesaMSLRenderPipeline.c
                )
                target_compile_definitions(${AO46_DIRECT_ADAPTER_TARGET}
                    PRIVATE
                        ${MESA_COMPILE_DEFINITIONS}
                )
                if(AO46_DIRECT_ADAPTER_TARGET STREQUAL "AO46MetalGalliumScreenSmoke" OR
                   AO46_DIRECT_ADAPTER_TARGET STREQUAL "AO46MetalGalliumTextureSmoke")
                    target_link_libraries(${AO46_DIRECT_ADAPTER_TARGET}
                        PRIVATE
                            AO46MesaMSLCompiler
                            ${MESA_NIR_LIB}
                            ${MESA_COMPILER_LIB}
                            ${MESA_BLAKE3_LIB}
                            "-lc++"
                    )
                endif()
            endif()
            target_link_libraries(${AO46_DIRECT_ADAPTER_TARGET}
                PRIVATE
                    "-framework IOSurface"
            )
        endif()
    endforeach()
endif()
