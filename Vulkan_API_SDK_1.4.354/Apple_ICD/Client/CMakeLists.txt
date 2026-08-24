if(NOT EXISTS "${AVK143_KHRONOS_LOADER_ROOT}/loader/CMakeLists.txt")
    message(FATAL_ERROR
        "Initialize Apple_ICD's Vulkan-Loader submodule at ${AVK143_KHRONOS_LOADER_ROOT}")
endif()

file(GLOB_RECURSE AVK143_LOADER_SOURCES CONFIGURE_DEPENDS
    "${AVK143_KHRONOS_LOADER_ROOT}/loader/*.c"
    "${AVK143_KHRONOS_LOADER_ROOT}/loader/*.h"
    "${AVK143_KHRONOS_LOADER_ROOT}/loader/*.cpp")
add_custom_target(AVK143KhronosLoaderSources SOURCES
    ${AVK143_LOADER_SOURCES}
    "${AVK143_KHRONOS_LOADER_ROOT}/CMakeLists.txt")
