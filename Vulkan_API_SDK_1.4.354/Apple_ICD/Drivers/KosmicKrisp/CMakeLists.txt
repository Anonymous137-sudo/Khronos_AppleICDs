set(AVK143_KK_ROOT "${AVK143_MESA_ROOT}/src/kosmickrisp")
if(NOT EXISTS "${AVK143_KK_ROOT}/vulkan/meson.build")
    message(FATAL_ERROR "KosmicKrisp Vulkan sources are missing: ${AVK143_KK_ROOT}")
endif()

file(GLOB_RECURSE AVK143_KK_SOURCES CONFIGURE_DEPENDS
    "${AVK143_KK_ROOT}/*.c" "${AVK143_KK_ROOT}/*.h"
    "${AVK143_KK_ROOT}/*.m" "${AVK143_KK_ROOT}/*.metal"
    "${AVK143_KK_ROOT}/*.cl" "${AVK143_KK_ROOT}/*.py"
    "${AVK143_KK_ROOT}/meson.build")
add_custom_target(AVK143KosmicKrispSources SOURCES ${AVK143_KK_SOURCES})

add_custom_target(AVK143KosmicKrispICD
    COMMAND "${CMAKE_COMMAND}" -E env
        "AVK143_MESA_ROOT=${AVK143_MESA_ROOT}"
        "${CMAKE_CURRENT_LIST_DIR}/../../scripts/build-avk143-icd.sh"
    WORKING_DIRECTORY "${CMAKE_CURRENT_LIST_DIR}/../../.."
    COMMENT "Build and stage Mesa KosmicKrisp as the AVK143 standard Vulkan ICD"
    USES_TERMINAL)
add_dependencies(AVK143KosmicKrispICD AVK143KosmicKrispSources)
