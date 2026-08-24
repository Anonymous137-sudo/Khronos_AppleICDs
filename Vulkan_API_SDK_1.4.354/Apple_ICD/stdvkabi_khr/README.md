# Standard Vulkan ABI

AVK143 exposes only the standard Khronos Vulkan ABI:

- Application entry points are the standard `vk*` functions from
  `vulkan/vulkan.h`.
- Loader-to-driver dispatch uses the standard Vulkan ICD ABI from
  `vulkan/vk_icd.h`.
- The pinned `Vulkan-Headers` submodule is the public SDK/loader ABI source.
- Mesa's matching checked-in headers remain internal to Mesa's Meson build.
- The Khronos Vulkan Loader owns application dispatch and ICD discovery; Mesa
  and AVK143 do not replace it with a custom `libvk` or AppKit ABI.

Both sources report Vulkan header revision 1.4.354. Keeping the official
Khronos header source here makes the application/loader ABI auditable while
the sibling Mesa checkout stays self-contained. The public ABI is not an
AVK143-specific SDK.

The `VulkanICD-KHR-Installer.pkg` bootstrap package preserves this boundary. It
installs the KosmicKrisp ICD dylib and JSON discovery manifest under
`/usr/local`, while applications continue to call their ordinary Khronos
loader's `vk*` ABI. It neither supplies a custom `libvk` nor installs a macOS
framework.
