add_custom_target(AVK143ICDMetadata SOURCES
    "${CMAKE_CURRENT_LIST_DIR}/avk143_kosmickrisp_icd.json.in"
    "${AVK143_MESA_ROOT}/src/kosmickrisp/vulkan/meson.build"
    "${AVK143_MESA_ROOT}/src/vulkan/util/vk_icd_gen.py")
