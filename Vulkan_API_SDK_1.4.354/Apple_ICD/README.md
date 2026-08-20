# AVK143 Vulkan ICD Assembly

`Apple_ICD` packages the existing Mesa KosmicKrisp Vulkan driver as AVK143's
standard Khronos ICD. It does not provide a framework, a custom `CVK` ABI, an
`NSVulkan_KHR` API, or a second Vulkan object model.

The public path is:

```text
Vulkan application using vk*
  -> Khronos Vulkan Loader
  -> AVK143 KosmicKrisp ICD manifest
  -> Mesa Vulkan runtime and KosmicKrisp Metal implementation
  -> Metal
```

## Build And Stage

Run the AVK143-owned assembly script from the repository root:

```sh
"Vulkan_API_SDK_1.4.354/Apple_ICD/scripts/build-avk143-icd.sh"
"Vulkan_API_SDK_1.4.354/Apple_ICD/scripts/run-avk143-icd-smoke.sh"
```

The default staged output is accessible in `build/AVK143/prefix`:

```text
prefix/lib/libvulkan_kosmickrisp.dylib
prefix/share/vulkan/icd.d/kosmickrisp_mesa_icd.aarch64.json
```

`VK_DRIVER_FILES` selects the staged ICD for a standard Vulkan Loader:

```sh
export VK_DRIVER_FILES="$(pwd)/Vulkan_API_SDK_1.4.354/build/AVK143/prefix/share/vulkan/icd.d/kosmickrisp_mesa_icd.aarch64.json"
```

## Runtime Installation

The standard user-level install location is `~/.local`. It does not need SIP,
AuthRoot, a system framework, or a replacement system loader:

```sh
"Vulkan_API_SDK_1.4.354/Apple_ICD/scripts/install-avk143-runtime.sh"
```

This creates the standard loader-discovery manifest at
`~/.local/share/vulkan/icd.d/avk143_kosmickrisp_icd.aarch64.json` and places the
ICD dylib at `~/.local/lib/avk143/libvulkan_kosmickrisp.dylib`. The manifest
uses the installed absolute dylib path, so it remains unambiguous when multiple
Vulkan ICDs are present. A controlled prefix can be used for testing or a
managed install:

```sh
"Vulkan_API_SDK_1.4.354/Apple_ICD/scripts/install-avk143-runtime.sh" \
  --prefix /usr/local
```

The script never invokes `sudo`; a caller choosing `/usr/local` is responsible
for the required filesystem permissions. `AVK143RuntimeDiscoverySmoke` verifies
that the standard loader finds the staged manifest without `VK_DRIVER_FILES`.

The build script requires the normal KosmicKrisp dependencies: Meson, Ninja,
LLVM, libclc, SPIR-V Tools, and the SPIR-V LLVM translator. On this developer
machine it discovers their Homebrew prefixes automatically. No SIP/AuthRoot
change, system framework replacement, or private Apple graphics API is part of
this standard Vulkan ICD path.

## Verification

`AVK143ICDDispatchSmoke` verifies the standard ICD handshake directly:

- `vk_icdNegotiateLoaderICDInterfaceVersion`
- `vk_icdGetInstanceProcAddr`
- `vkEnumerateInstanceVersion`

The direct smoke does not replace a Vulkan Loader test. When a Khronos Vulkan
Loader and `vulkaninfo` are available, run them with `VK_DRIVER_FILES` set to
the staged JSON manifest for loader discovery and device-level validation.

`AVK143LoaderInstanceSmoke` is also built when CMake receives both
`AVK143_VULKAN_LOADER` and `AVK143_KOSMICKRISP_MANIFEST`. It uses the standard
loader to create a Vulkan 1.4 instance through the staged manifest and requires
at least one physical device to pass. Standard Loader and `vulkaninfo`
qualification passed on this checkout; CTS remains separate conformance work.

When `glslc` is available, `AVK143ComputeSmoke` is added as a fourth test. It
compiles a tiny SPIR-V compute shader and verifies a host-visible storage buffer
write after descriptor binding, pipeline creation, `vkQueueSubmit2`, a fence,
and readback. This is a real Mesa/Kosmickrisp workload smoke, not a custom
Vulkan implementation.
