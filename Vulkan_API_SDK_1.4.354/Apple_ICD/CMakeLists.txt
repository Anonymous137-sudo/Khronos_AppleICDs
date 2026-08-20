cmake_minimum_required(VERSION 3.21)

project(AVK143ICDAssembly LANGUAGES C)

set(AVK143_MESA_ROOT
    "${CMAKE_CURRENT_LIST_DIR}/../mesa"
    CACHE PATH "Mesa checkout supplying the AVK143 KosmicKrisp ICD")
set(AVK143_KOSMICKRISP_ICD
    ""
    CACHE FILEPATH "Built libvulkan_kosmickrisp.dylib to validate")
set(AVK143_KOSMICKRISP_MANIFEST
    ""
    CACHE FILEPATH "Standard Vulkan ICD manifest for loader validation")
set(AVK143_VULKAN_LOADER
    ""
    CACHE FILEPATH "Standard Khronos Vulkan loader dylib for integration tests")
set(AVK143_VULKANINFO
    ""
    CACHE FILEPATH "Standard VulkanInfo executable for runtime-discovery tests")

if(NOT EXISTS "${AVK143_MESA_ROOT}/include/vulkan/vk_icd.h")
    message(FATAL_ERROR
        "AVK143_MESA_ROOT must contain Mesa's standard Vulkan headers and ICD ABI")
endif()

add_executable(AVK143ICDDispatchSmoke
    tests/AVK143ICDDispatchSmoke.c)
target_compile_definitions(AVK143ICDDispatchSmoke PRIVATE VK_NO_PROTOTYPES)
target_include_directories(AVK143ICDDispatchSmoke PRIVATE
    "${AVK143_MESA_ROOT}/include")
target_link_libraries(AVK143ICDDispatchSmoke PRIVATE ${CMAKE_DL_LIBS})

if(AVK143_VULKAN_LOADER)
    add_executable(AVK143LoaderInstanceSmoke
        tests/AVK143LoaderInstanceSmoke.c)
    target_include_directories(AVK143LoaderInstanceSmoke PRIVATE
        "${AVK143_MESA_ROOT}/include")
    target_link_libraries(AVK143LoaderInstanceSmoke PRIVATE
        "${AVK143_VULKAN_LOADER}")

    find_program(AVK143_GLSLC_EXECUTABLE NAMES glslc)
    if(AVK143_GLSLC_EXECUTABLE)
        set(AVK143_COMPUTE_SHADER
            "${CMAKE_CURRENT_BINARY_DIR}/AVK143ComputeSmoke.spv")
        add_custom_command(
            OUTPUT "${AVK143_COMPUTE_SHADER}"
            COMMAND "${AVK143_GLSLC_EXECUTABLE}"
                -fshader-stage=compute
                -o "${AVK143_COMPUTE_SHADER}"
                "${CMAKE_CURRENT_SOURCE_DIR}/tests/AVK143ComputeSmoke.comp"
            DEPENDS tests/AVK143ComputeSmoke.comp
            VERBATIM)
        add_custom_target(AVK143ComputeShader DEPENDS "${AVK143_COMPUTE_SHADER}")

        add_executable(AVK143ComputeSmoke
            tests/AVK143ComputeSmoke.c)
        add_dependencies(AVK143ComputeSmoke AVK143ComputeShader)
        target_include_directories(AVK143ComputeSmoke PRIVATE
            "${AVK143_MESA_ROOT}/include")
        target_link_libraries(AVK143ComputeSmoke PRIVATE
            "${AVK143_VULKAN_LOADER}")
    endif()
endif()

include(CTest)
if(BUILD_TESTING)
    add_test(
        NAME AVK143StandardVulkanHeaders
        COMMAND $<TARGET_FILE:AVK143ICDDispatchSmoke> --headers-only)

    if(AVK143_KOSMICKRISP_ICD)
        add_test(
            NAME AVK143KosmicKrispICDDispatch
            COMMAND $<TARGET_FILE:AVK143ICDDispatchSmoke>
                "${AVK143_KOSMICKRISP_ICD}" 1 4)
    endif()

    if(AVK143_VULKAN_LOADER AND AVK143_KOSMICKRISP_MANIFEST)
        add_test(
            NAME AVK143StandardLoaderInstance
            COMMAND $<TARGET_FILE:AVK143LoaderInstanceSmoke>
                "${AVK143_KOSMICKRISP_MANIFEST}")

        if(TARGET AVK143ComputeSmoke)
            add_test(
                NAME AVK143MesaKosmicKrispCompute
                COMMAND $<TARGET_FILE:AVK143ComputeSmoke>
                    "${AVK143_KOSMICKRISP_MANIFEST}"
                    "${AVK143_COMPUTE_SHADER}")
        endif()

        if(AVK143_VULKANINFO)
            add_test(
                NAME AVK143StandardRuntimeDiscovery
                COMMAND "${CMAKE_CURRENT_SOURCE_DIR}/tests/AVK143RuntimeDiscoverySmoke.sh"
                    "${CMAKE_CURRENT_SOURCE_DIR}/scripts/stage-avk143-runtime.sh"
                    "${AVK143_VULKANINFO}"
                    "${CMAKE_CURRENT_BINARY_DIR}/runtime-home")
            get_filename_component(AVK143_VULKAN_LOADER_DIR
                "${AVK143_VULKAN_LOADER}" DIRECTORY)
            set_tests_properties(AVK143StandardRuntimeDiscovery PROPERTIES
                ENVIRONMENT "DYLD_LIBRARY_PATH=${AVK143_VULKAN_LOADER_DIR}")
        endif()
    endif()

    find_program(AVK143_PKGBUILD_EXECUTABLE NAMES pkgbuild)
    find_program(AVK143_PKGUTIL_EXECUTABLE NAMES pkgutil)
    if(AVK143_PKGBUILD_EXECUTABLE AND AVK143_PKGUTIL_EXECUTABLE)
        add_test(
            NAME AVK143VulkanICDPackage
            COMMAND "${CMAKE_CURRENT_SOURCE_DIR}/tests/AVK143InstallerPackageSmoke.sh"
                "${CMAKE_CURRENT_SOURCE_DIR}/scripts/build_vulkanicd_khrinstaller_pkg.sh")
    endif()
endif()
