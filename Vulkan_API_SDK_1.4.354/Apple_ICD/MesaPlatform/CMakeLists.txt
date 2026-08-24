set(AVK143_MESA_PLATFORM_DIRS
    "${AVK143_MESA_ROOT}/src/compiler/nir"
    "${AVK143_MESA_ROOT}/src/vulkan/runtime"
    "${AVK143_MESA_ROOT}/src/vulkan/util"
    "${AVK143_MESA_ROOT}/src/vulkan/wsi"
    "${AVK143_MESA_ROOT}/src/util")
set(AVK143_MESA_PLATFORM_METADATA)
foreach(directory IN LISTS AVK143_MESA_PLATFORM_DIRS)
    if(EXISTS "${directory}/meson.build")
        list(APPEND AVK143_MESA_PLATFORM_METADATA "${directory}/meson.build")
    endif()
endforeach()
add_custom_target(AVK143MesaPlatformSources SOURCES
    ${AVK143_MESA_PLATFORM_METADATA})
