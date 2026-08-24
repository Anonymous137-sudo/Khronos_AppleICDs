add_custom_target(AVK143RuntimeAssembly SOURCES
    "${CMAKE_CURRENT_LIST_DIR}/README.md"
    "${CMAKE_CURRENT_LIST_DIR}/../scripts/stage-avk143-runtime.sh"
    "${CMAKE_CURRENT_LIST_DIR}/../scripts/install-avk143-runtime.sh")
add_dependencies(AVK143RuntimeAssembly AVK143ICDMetadata)
