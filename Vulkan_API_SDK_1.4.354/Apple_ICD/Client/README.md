# Khronos client boundary

Applications enter AVK143 through the unmodified Khronos Vulkan Loader. The
`Vulkan-Loader` submodule is pinned to `v1.4.354`, matching the SDK headers and
the driver-facing loader/ICD contract. It is source for building and testing
the client boundary; it is not forked or patched into a private AVK ABI.

`AVK143KhronosLoaderSources` makes the loader implementation visible from the
top-level Apple_ICD CMake project. The production loader is built by
`scripts/build-avk143-vulkan-tools.sh`, which prefers this checked-in submodule.
