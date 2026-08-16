cmake_minimum_required(VERSION 3.25)

project(AVK143MesaVulkanPrerequisites LANGUAGES C OBJC)

include(CTest)

set(CMAKE_C_STANDARD 11)
set(CMAKE_C_STANDARD_REQUIRED ON)
set(CMAKE_C_EXTENSIONS OFF)

find_package(Python3 REQUIRED COMPONENTS Interpreter)

set(AVK143_MESA_ROOT
    ""
    CACHE PATH "Mesa source checkout supplying AVK143 Vulkan machinery"
)
if(NOT AVK143_MESA_ROOT)
    message(FATAL_ERROR
        "Set AVK143_MESA_ROOT to the audited Mesa source checkout before configuring AVK143."
    )
endif()
set(AVK143_MESA_BUILD_DIR
    "${AVK143_MESA_ROOT}/build-avk143-kosmickrisp-arm64"
    CACHE PATH "Mesa KosmicKrisp build supplying AVK143 prerequisite artifacts"
)

set(AVK143_VULKAN_INVENTORY
    "${CMAKE_CURRENT_SOURCE_DIR}/AVK143MesaVulkanInventory.py"
)
set(AVK143_MESA_PROVENANCE
    "${CMAKE_CURRENT_BINARY_DIR}/AVK143MesaVulkanProvenance.json"
)
set(AVK143_FRAMEWORK_HEADERS
    "${CMAKE_CURRENT_SOURCE_DIR}/Frameworks/Vulkan_1.4.3.framework/Headers"
)

find_library(AVK143_APPKIT_FRAMEWORK AppKit REQUIRED)

add_library(AVK143NSVulkanKHR STATIC
    NSVulkan_KHR/NSVulkan_KHR.m
)
target_include_directories(AVK143NSVulkanKHR
    PUBLIC
        "${AVK143_FRAMEWORK_HEADERS}"
)
target_compile_options(AVK143NSVulkanKHR PRIVATE -fobjc-arc)
target_link_libraries(AVK143NSVulkanKHR PUBLIC "${AVK143_APPKIT_FRAMEWORK}")

add_executable(AVK143CVKABISmoke
    tests/AVK143CVKABISmoke.c
)
target_include_directories(AVK143CVKABISmoke
    PRIVATE
        "${AVK143_FRAMEWORK_HEADERS}"
)

add_executable(AVK143NSVulkanKHRSmoke
    tests/AVK143NSVulkanKHRSmoke.m
)
target_compile_options(AVK143NSVulkanKHRSmoke PRIVATE -fobjc-arc)
target_link_libraries(AVK143NSVulkanKHRSmoke PRIVATE AVK143NSVulkanKHR)

add_custom_target(AVK143MesaVulkanPrerequisites ALL
    COMMAND
        "${Python3_EXECUTABLE}" "${AVK143_VULKAN_INVENTORY}"
        --mesa-root "${AVK143_MESA_ROOT}"
        --mesa-build-dir "${AVK143_MESA_BUILD_DIR}"
        --check --check-artifacts
    COMMENT "Verifying Mesa and KosmicKrisp Vulkan prerequisites for AVK143"
    VERBATIM
)

add_custom_command(
    OUTPUT "${AVK143_MESA_PROVENANCE}"
    COMMAND
        "${Python3_EXECUTABLE}" "${AVK143_VULKAN_INVENTORY}"
        --mesa-root "${AVK143_MESA_ROOT}"
        --mesa-build-dir "${AVK143_MESA_BUILD_DIR}"
        --check --check-artifacts
        --write-provenance "${AVK143_MESA_PROVENANCE}"
    DEPENDS "${AVK143_VULKAN_INVENTORY}"
    COMMENT "Recording AVK143 Mesa and KosmicKrisp provenance"
    VERBATIM
)
add_custom_target(AVK143MesaVulkanProvenance ALL
    DEPENDS "${AVK143_MESA_PROVENANCE}"
)

if(BUILD_TESTING)
    add_test(
        NAME AVK143CVKABISmoke
        COMMAND $<TARGET_FILE:AVK143CVKABISmoke>
    )

    add_test(
        NAME AVK143NSVulkanKHRSmoke
        COMMAND $<TARGET_FILE:AVK143NSVulkanKHRSmoke>
    )

    add_test(
        NAME AVK143MesaVulkanPrerequisites
        COMMAND
            "${Python3_EXECUTABLE}" "${AVK143_VULKAN_INVENTORY}"
            --mesa-root "${AVK143_MESA_ROOT}"
            --mesa-build-dir "${AVK143_MESA_BUILD_DIR}"
            --check --check-artifacts
    )
endif()
