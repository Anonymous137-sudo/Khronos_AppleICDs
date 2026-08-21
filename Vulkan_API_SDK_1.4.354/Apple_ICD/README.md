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

## Bootstrap Package

`VulkanICD_KHRInstaller.pkg` is the source-bootstrap package for this standard
ABI product. Build it from the repository root:

```sh
./build_VulkanICD_KHRInstaller.sh
```

The resulting `dist/VulkanICD_KHRInstaller.pkg` installs only its bootstrap
commands/configuration, then clones or updates this repository below
`/usr/local/src/Khronos_AppleICDs`, initializes the Mesa and vendor submodules,
builds this ICD from its recorded repository-relative project path, and stages
it below `/usr/local`:

```text
/usr/local/lib/avk143/libvulkan_kosmickrisp.dylib
/usr/local/share/vulkan/icd.d/avk143_kosmickrisp_icd.aarch64.json
```

Rebuild the pinned source revision with:

```sh
/usr/local/bin/vulkanicd-khr-build
```

Fast-forward the repository/submodules, rebuild, and reinstall with:

```sh
/usr/local/bin/vulkanicd-khr-update
```

The package never replaces the Khronos loader, Metal, or a macOS framework. It
also does not require SIP/AuthRoot changes. Its postinstall log is written to
`/var/log/VulkanICD_KHRInstaller.log`; failures leave the source checkout and
log available for inspection rather than claiming a successful driver install.

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
at least one physical device to pass. The Mesa 1.4.354 header snapshot and the
runtime API version match. Standard Loader and `vulkaninfo` qualification passed
on this checkout. Focused `shaderFloatControls2` coverage and the broader CTS
campaign are now recorded in the current engineering release: the final
881,906-case wave has zero failures, two retained `QualityWarning` results, and
capability-gated unsupported cases remain `NotSupported`. See the current
release record for the complete, checksummed ledger. CTS is qualification
evidence, not a conformance claim.

When `glslc` is available, `AVK143ComputeSmoke` is added as a fourth test. It
compiles a tiny SPIR-V compute shader and verifies a host-visible storage buffer
write after descriptor binding, pipeline creation, `vkQueueSubmit2`, a fence,
and readback. This is a real Mesa/Kosmickrisp workload smoke, not a custom
Vulkan implementation.

## Full CTS Campaign

`scripts/run-avk143-vulkan-cts.sh` runs the official non-experimental
`dEQP-VK` root groups against the staged ICD. It writes a QPA log and standard
output per group, marks only successful groups complete, and resumes at root
group boundaries on the next invocation. A full campaign contains 2,858,036
cases in the Vulkan CTS 1.4.3.2 inventory, so it is intentionally a long-running
qualification job rather than a single foreground smoke command.

### Current Release Evidence

The `vulkan-api-sdk-1.4.354-cts-qualified-1.4.3.2-20260821` engineering
release includes the source-controlled ledger in
[`../RELEASES/CTS_QUALIFIED_1.4.3.2_20260821.md`](../RELEASES/CTS_QUALIFIED_1.4.3.2_20260821.md)
and raw final-wave QPAs as GitHub release assets. The final eight-worker wave
covered 881,906 cases: 257,266 `Pass`, 624,638 `NotSupported`, zero `Fail`, and
two `QualityWarning` results. The two warnings are retained as QPA warnings,
not changed into passes, because the reported early-fragment sample-mask
ordering is permitted but nonpreferred on the public Metal path.

This evidence does not change `VkConformanceVersion`, which remains zero until
Khronos certifies a submitted implementation. The `1.4.3.2` release component
is the CTS suite revision, while the runtime/header package is Vulkan API SDK
1.4.354.

After the local CTS harness has been built under `build/cts`, the runner
automatically uses its `VK-GL-CTS` checkout and Khronos Loader prefix:

```sh
"Vulkan_API_SDK_1.4.354/Apple_ICD/scripts/run-avk143-vulkan-cts.sh"
```

Set `AVK143_CTS_ROOT`, `AVK143_CTS_BINARY`, or `AVK143_VULKAN_LOADER_DIR` only
when qualifying against an external toolchain. Use `AVK143_CTS_GROUPS="info
compute"` to rerun selected groups while fixing a failure, and set
`AVK143_CTS_RESULTS_DIR` to keep separate campaigns. The runner never treats
`NotSupported` as a pass for a feature claim; QPA outcomes remain the source of
truth for qualification.

### Early-Fragment Quality Preflight

Each new CTS wave runs `qualify-avk143-early-fragment-quality.sh` before root
groups by default. It records a four-case targeted qualification for static
sample masking with early fragment tests: the two core cases report the
Vulkan-permitted `QualityWarning` ordering, while their
`VK_KHR_maintenance5` counterparts must pass according to the physical-device
properties exposed by the ICD. This prevents a later driver change from turning
the known ordering into a silent regression, false capability report, failure,
or crash.

The two core outcomes remain in the raw CTS QPA as `QualityWarning`; the runner
does not relabel them as passes. They are tracked as qualified rather than
unresolved because Metal exposes no public fixed-function sample-mask state and
the CTS itself defines this ordering as allowed but nonpreferred. Set
`AVK143_CTS_QUALIFY_EARLY_FRAGMENT=0` only for focused bring-up where that
preflight is intentionally not applicable.
