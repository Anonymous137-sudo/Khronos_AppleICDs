# Standard Vulkan ABI

AVK143 exposes only the standard Khronos Vulkan ABI:

- Application entry points are the standard `vk*` functions from
  `vulkan/vulkan.h`.
- Loader-to-driver dispatch uses the standard Vulkan ICD ABI from
  `vulkan/vk_icd.h`.
- Mesa's checked-in Vulkan headers are the active header source while the
  driver is assembled.
- The Khronos Vulkan Loader owns application dispatch and ICD discovery; Mesa
  and AVK143 do not replace it with a custom `libvk` or AppKit ABI.

The current Mesa checkout records the active header revision in
`include/vulkan/vulkan_core.h`. This package is named for that verified source
revision: Vulkan API SDK 1.4.354. The public ABI stays standard Khronos Vulkan;
it is not an AVK143-specific SDK.

The `VulkanICD_KHRInstaller.pkg` bootstrap package preserves this boundary. It
installs the KosmicKrisp ICD dylib and JSON discovery manifest under
`/usr/local`, while applications continue to call their ordinary Khronos
loader's `vk*` ABI. It neither supplies a custom `libvk` nor installs a macOS
framework.
