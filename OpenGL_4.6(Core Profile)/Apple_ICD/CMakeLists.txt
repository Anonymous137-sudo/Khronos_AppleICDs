cmake_minimum_required(VERSION 3.24)

project(Apple_ICD LANGUAGES C OBJC)

set(CMAKE_C_STANDARD 11)
set(CMAKE_C_STANDARD_REQUIRED ON)
set(CMAKE_C_EXTENSIONS OFF)

add_compile_definitions(GL_SILENCE_DEPRECATION)

include(CTest)

find_package(Python3 COMPONENTS Interpreter REQUIRED)

set(AO46_GENERATED_DIR "${CMAKE_CURRENT_BINARY_DIR}/generated")
set(AO46_GENERATED_GL_CLIENT_EXPORTS "${AO46_GENERATED_DIR}/OpenGLClientExports.c")
set(AO46_GENERATED_GL_ICD_EXPORTS "${AO46_GENERATED_DIR}/OpenGLICDExports.c")
set(AO46_GENERATED_GL_RUNTIME_EXPORTS "${AO46_GENERATED_DIR}/OpenGLRuntimeExports.c")
set(AO46_GENERATED_GL_BACKEND_EXPORTS "${AO46_GENERATED_DIR}/OpenGLBackendExports.c")
set(AO46_FRAMEWORK_PUBLIC_HEADERS
    "${CMAKE_CURRENT_SOURCE_DIR}/framework/include/OpenGL_4_6.h"
    "${CMAKE_CURRENT_SOURCE_DIR}/runtime/include/AppleOpenGL46Runtime.h"
    "${CMAKE_CURRENT_SOURCE_DIR}/../../MGL/include/GL/glcorearb.h"
)
set(AO46_FRAMEWORK_MODULEMAP
    "${CMAKE_CURRENT_SOURCE_DIR}/framework/Modules/module.modulemap"
)

add_custom_command(
    OUTPUT "${AO46_GENERATED_GL_CLIENT_EXPORTS}"
    COMMAND "${Python3_EXECUTABLE}"
            "${CMAKE_CURRENT_SOURCE_DIR}/scripts/generate_gl_exports.py"
            "${CMAKE_CURRENT_SOURCE_DIR}/../../MGL/src/gl_core.c"
            "${AO46_GENERATED_GL_CLIENT_EXPORTS}"
            client
    DEPENDS
        "${CMAKE_CURRENT_SOURCE_DIR}/scripts/generate_gl_exports.py"
        "${CMAKE_CURRENT_SOURCE_DIR}/../../MGL/src/gl_core.c"
    VERBATIM
)

add_custom_command(
    OUTPUT "${AO46_GENERATED_GL_ICD_EXPORTS}"
    COMMAND "${Python3_EXECUTABLE}"
            "${CMAKE_CURRENT_SOURCE_DIR}/scripts/generate_gl_exports.py"
            "${CMAKE_CURRENT_SOURCE_DIR}/../../MGL/src/gl_core.c"
            "${AO46_GENERATED_GL_ICD_EXPORTS}"
            icd
    DEPENDS
        "${CMAKE_CURRENT_SOURCE_DIR}/scripts/generate_gl_exports.py"
        "${CMAKE_CURRENT_SOURCE_DIR}/../../MGL/src/gl_core.c"
    VERBATIM
)

add_custom_command(
    OUTPUT "${AO46_GENERATED_GL_RUNTIME_EXPORTS}"
    COMMAND "${Python3_EXECUTABLE}"
            "${CMAKE_CURRENT_SOURCE_DIR}/scripts/generate_gl_exports.py"
            "${CMAKE_CURRENT_SOURCE_DIR}/../../MGL/src/gl_core.c"
            "${AO46_GENERATED_GL_RUNTIME_EXPORTS}"
            runtime
    DEPENDS
        "${CMAKE_CURRENT_SOURCE_DIR}/scripts/generate_gl_exports.py"
        "${CMAKE_CURRENT_SOURCE_DIR}/../../MGL/src/gl_core.c"
    VERBATIM
)

add_custom_command(
    OUTPUT "${AO46_GENERATED_GL_BACKEND_EXPORTS}"
    COMMAND "${Python3_EXECUTABLE}"
            "${CMAKE_CURRENT_SOURCE_DIR}/scripts/generate_gl_exports.py"
            "${CMAKE_CURRENT_SOURCE_DIR}/../../MGL/src/gl_core.c"
            "${AO46_GENERATED_GL_BACKEND_EXPORTS}"
            backend
    DEPENDS
        "${CMAKE_CURRENT_SOURCE_DIR}/scripts/generate_gl_exports.py"
        "${CMAKE_CURRENT_SOURCE_DIR}/../../MGL/src/gl_core.c"
    VERBATIM
)

add_library(OpenGL46RuntimeObjects OBJECT
    runtime/src/AppleOpenGL46Runtime.c
)

target_include_directories(OpenGL46RuntimeObjects
    PUBLIC
        backend/include
        runtime/include
        "${CMAKE_CURRENT_SOURCE_DIR}/../../MGL/include"
        "${CMAKE_CURRENT_SOURCE_DIR}/../../MGL/include/GL"
)

add_library(OpenGL46FrameworkClient STATIC
    client/src/AppleOpenGL46Client.c
)

target_include_directories(OpenGL46FrameworkClient
    PUBLIC
        runtime/include
        client/include
        "${CMAKE_CURRENT_SOURCE_DIR}/../../MGL/include"
        "${CMAKE_CURRENT_SOURCE_DIR}/../../MGL/include/GL"
)

add_library(LibGLICDDriver SHARED
    icd/src/AppleOpenGLICD.c
    "${AO46_GENERATED_GL_ICD_EXPORTS}"
)

target_include_directories(LibGLICDDriver
    PRIVATE
        runtime/include
        client/include
        icd/include
        "${AO46_GENERATED_DIR}"
        "${CMAKE_CURRENT_SOURCE_DIR}/../../MGL/include"
        "${CMAKE_CURRENT_SOURCE_DIR}/../../MGL/include/GL"
)

target_link_libraries(LibGLICDDriver PRIVATE OpenGL46FrameworkClient)

set_target_properties(LibGLICDDriver PROPERTIES
    PREFIX ""
    OUTPUT_NAME "libGLICD"
    BUILD_WITH_INSTALL_NAME_DIR ON
    INSTALL_NAME_DIR "/usr/local/lib"
)

add_library(LibGL2MTLBackend SHARED
    backend/src/GLDriverCore.c
    backend/src/libgl2mtl.c
    "${AO46_GENERATED_GL_BACKEND_EXPORTS}"
)

target_include_directories(LibGL2MTLBackend
    PRIVATE
        backend/include
        "${AO46_GENERATED_DIR}"
        "${CMAKE_CURRENT_SOURCE_DIR}/../../MGL/include"
        "${CMAKE_CURRENT_SOURCE_DIR}/../../MGL/include/GL"
)

set_target_properties(LibGL2MTLBackend PROPERTIES
    PREFIX ""
    OUTPUT_NAME "libgl2mtl"
    BUILD_WITH_INSTALL_NAME_DIR ON
    INSTALL_NAME_DIR "/usr/local/lib"
)

add_library(OpenGL_4_6 SHARED
    framework/src/OpenGL46Framework.c
    ${AO46_FRAMEWORK_PUBLIC_HEADERS}
    "${AO46_FRAMEWORK_MODULEMAP}"
    "${AO46_GENERATED_GL_RUNTIME_EXPORTS}"
    $<TARGET_OBJECTS:OpenGL46RuntimeObjects>
)

set_source_files_properties(${AO46_FRAMEWORK_PUBLIC_HEADERS} PROPERTIES
    HEADER_FILE_ONLY ON
    MACOSX_PACKAGE_LOCATION Headers
)

set_source_files_properties("${AO46_FRAMEWORK_MODULEMAP}" PROPERTIES
    HEADER_FILE_ONLY ON
    MACOSX_PACKAGE_LOCATION Modules
)

target_include_directories(OpenGL_4_6
    PRIVATE
        backend/include
        runtime/include
        "${CMAKE_CURRENT_SOURCE_DIR}/../../MGL/include"
        "${CMAKE_CURRENT_SOURCE_DIR}/../../MGL/include/GL"
)

if(APPLE)
    target_link_libraries(OpenGL_4_6 PRIVATE "-framework Foundation")
endif()

target_link_libraries(OpenGL_4_6 PRIVATE LibGL2MTLBackend)

set_target_properties(OpenGL_4_6 PROPERTIES
    FRAMEWORK TRUE
    FRAMEWORK_VERSION A
    OUTPUT_NAME "OpenGL_4.6"
    MACOSX_FRAMEWORK_IDENTIFIER "local.opengl46.driver"
    PUBLIC_HEADER "${AO46_FRAMEWORK_PUBLIC_HEADERS}"
)

add_library(AppleOpenGLShim SHARED
    shim/src/CGLShim.c
    "${AO46_GENERATED_GL_ICD_EXPORTS}"
)

target_include_directories(AppleOpenGLShim
    PRIVATE
        runtime/include
        client/include
        icd/include
        "${AO46_GENERATED_DIR}"
        "${CMAKE_CURRENT_SOURCE_DIR}/../../MGL/include"
        "${CMAKE_CURRENT_SOURCE_DIR}/../../MGL/include/GL"
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

add_library(LibGLDriver SHARED
    drivers/src/libGL.c
    "${AO46_GENERATED_GL_ICD_EXPORTS}"
)

target_include_directories(LibGLDriver
    PRIVATE
        runtime/include
        client/include
        icd/include
        "${AO46_GENERATED_DIR}"
        "${CMAKE_CURRENT_SOURCE_DIR}/../../MGL/include"
        "${CMAKE_CURRENT_SOURCE_DIR}/../../MGL/include/GL"
)

target_link_libraries(LibGLDriver PRIVATE LibGLICDDriver)

set_target_properties(LibGLDriver PROPERTIES
    PREFIX ""
    OUTPUT_NAME "libGL"
)

add_library(LibGLContextDriver SHARED
    drivers/src/libGLContext.c
    shim/src/CGLShim.c
)

target_include_directories(LibGLContextDriver
    PRIVATE
        runtime/include
        client/include
        icd/include
        drivers/include
        "${CMAKE_CURRENT_SOURCE_DIR}/../../MGL/include"
        "${CMAKE_CURRENT_SOURCE_DIR}/../../MGL/include/GL"
)

target_link_libraries(LibGLContextDriver PRIVATE LibGLICDDriver)

set_target_properties(LibGLContextDriver PROPERTIES
    PREFIX ""
    OUTPUT_NAME "libGLContext"
)

add_library(LibNSOpenGLContextDriver SHARED
    drivers/src/libNSOpenGLContext.m
)

target_include_directories(LibNSOpenGLContextDriver
    PRIVATE
        runtime/include
        client/include
        drivers/include
        "${CMAKE_CURRENT_SOURCE_DIR}/../../MGL/include"
        "${CMAKE_CURRENT_SOURCE_DIR}/../../MGL/include/GL"
)

target_link_libraries(LibNSOpenGLContextDriver PRIVATE OpenGL46FrameworkClient)

if(APPLE)
    target_link_libraries(LibNSOpenGLContextDriver PRIVATE "-framework AppKit")
    target_link_libraries(LibNSOpenGLContextDriver PRIVATE "-framework Foundation")
    target_compile_options(LibNSOpenGLContextDriver PRIVATE "-fobjc-arc")
endif()

set_target_properties(LibNSOpenGLContextDriver PROPERTIES
    PREFIX ""
    OUTPUT_NAME "libNSOpenGLContext"
)

add_executable(AO46RuntimeCompatSmoke
    tests/AO46RuntimeCompatSmoke.c
)

target_include_directories(AO46RuntimeCompatSmoke
    PRIVATE
        runtime/include
        "${CMAKE_CURRENT_SOURCE_DIR}/../../MGL/include"
        "${CMAKE_CURRENT_SOURCE_DIR}/../../MGL/include/GL"
)

target_link_libraries(AO46RuntimeCompatSmoke PRIVATE OpenGL_4_6)

if(BUILD_TESTING)
    add_test(
        NAME AO46RuntimeCompatSmoke
        COMMAND "${CMAKE_COMMAND}" -E env
                "DYLD_FRAMEWORK_PATH=${CMAKE_CURRENT_BINARY_DIR}"
                "DYLD_LIBRARY_PATH=${CMAKE_CURRENT_BINARY_DIR}"
                "$<TARGET_FILE:AO46RuntimeCompatSmoke>"
    )
endif()

add_executable(AO46CGLShimCompatSmoke
    tests/AO46CGLShimCompatSmoke.c
)

target_include_directories(AO46CGLShimCompatSmoke
    PRIVATE
        runtime/include
        icd/include
        "${CMAKE_CURRENT_SOURCE_DIR}/../../MGL/include"
        "${CMAKE_CURRENT_SOURCE_DIR}/../../MGL/include/GL"
)

if(BUILD_TESTING)
    add_test(
        NAME AO46CGLShimCompatSmoke
        COMMAND "${CMAKE_COMMAND}" -E env
                "DYLD_FRAMEWORK_PATH=${CMAKE_CURRENT_BINARY_DIR}"
                "DYLD_LIBRARY_PATH=${CMAKE_CURRENT_BINARY_DIR}"
                "AO46_SHIM_PATH=$<TARGET_FILE:AppleOpenGLShim>"
                "AO46_FRAMEWORK_PATH=$<TARGET_FILE:OpenGL_4_6>"
                "$<TARGET_FILE:AO46CGLShimCompatSmoke>"
    )
endif()

add_executable(AO46NSOpenGLCompatSmoke
    tests/AO46NSOpenGLCompatSmoke.m
)

target_include_directories(AO46NSOpenGLCompatSmoke
    PRIVATE
        runtime/include
        client/include
        drivers/include
        "${CMAKE_CURRENT_SOURCE_DIR}/../../MGL/include"
        "${CMAKE_CURRENT_SOURCE_DIR}/../../MGL/include/GL"
)

target_link_libraries(AO46NSOpenGLCompatSmoke PRIVATE LibNSOpenGLContextDriver)

if(APPLE)
    target_link_libraries(AO46NSOpenGLCompatSmoke PRIVATE "-framework AppKit")
    target_link_libraries(AO46NSOpenGLCompatSmoke PRIVATE "-framework Foundation")
    target_compile_options(AO46NSOpenGLCompatSmoke PRIVATE "-fobjc-arc")
endif()

if(BUILD_TESTING)
    add_test(
        NAME AO46NSOpenGLCompatSmoke
        COMMAND "${CMAKE_COMMAND}" -E env
                "DYLD_FRAMEWORK_PATH=${CMAKE_CURRENT_BINARY_DIR}"
                "DYLD_LIBRARY_PATH=${CMAKE_CURRENT_BINARY_DIR}"
                "$<TARGET_FILE:AO46NSOpenGLCompatSmoke>"
    )
endif()
