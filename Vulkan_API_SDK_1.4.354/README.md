# Vulkan API SDK 1.4.354

AVK143 assembles Mesa's KosmicKrisp Vulkan ICD for Apple Silicon macOS through
the standard Khronos loader and ICD ABI. Vulkan applications use ordinary
`vk*` entry points and a JSON ICD manifest; this project does not provide a
framework, a custom loader, `CVK`, or `NSVulkan_KHR`.

```text
Vulkan application
  -> Khronos Vulkan Loader and vk* ABI
  -> AVK143 KosmicKrisp ICD
  -> Mesa Vulkan runtime, VTN, NIR, and KosmicKrisp
  -> public Metal implementation
  -> Apple GPU driver
```

## 2026-08-21 Engineering Release

`vulkan-api-sdk-1.4.354-cts-qualified-1.4.3.2-20260821` is the current
engineering-qualification release. It is built from Mesa's checked-in Vulkan
Headers/registry revision **1.4.354** and qualified with
`vulkan-cts-1.4.3.2`.

The 2,858,036-case local `dEQP-VK` inventory was exercised in resumable,
capability-gated waves. The final 881,906-case wave completed with **257,266
Pass**, **624,638 NotSupported**, **0 Fail**, and **2 QualityWarning** results.
The raw QPAs, case lists, output, and exit codes are release assets; the
source-controlled [release record](RELEASES/CTS_QUALIFIED_1.4.3.2_20260821.md)
contains the full ledger, binary hashes, and the two warning names.

This is not a Khronos certification or a conformant-product claim. The ICD
truthfully keeps `VkConformanceVersion` at `{ 0, 0, 0, 0 }`; `1.4.3.2` in the
release label denotes the CTS suite revision only. The
[`semantic delta`](RELEASES/SEMANTIC_DELTA.md) records capability and lowering
corrections made during qualification.

## Ownership

| Layer | Owner |
| --- | --- |
| `vk*` ABI, loader discovery, ICD dispatch | Khronos Vulkan Loader and standard Vulkan ICD ABI |
| Vulkan objects, SPIR-V ingestion, NIR, validation helpers | Mesa Vulkan runtime |
| Metal resources, command encoding, synchronization, pipeline, and WSI behavior | Mesa KosmicKrisp |
| Build configuration, staging, provenance, diagnostics, release evidence | AVK143 |

AVK143 does not introduce a second Vulkan object model or a handwritten
SPIR-V-to-Metal implementation. It packages the existing Mesa/KosmicKrisp
machinery, keeps unsupported features unadvertised, and provides the project
installation and qualification boundary.

## Runtime And Installer

Build and stage the ICD from this source checkout:

```sh
"Vulkan_API_SDK_1.4.354/Apple_ICD/scripts/build-avk143-icd.sh"
```

The staged standard-ABI artifacts are:

```text
build/AVK143/prefix/lib/libvulkan_kosmickrisp.dylib
build/AVK143/prefix/lib/avk143/libSPIRV-Tools.dylib
build/AVK143/prefix/share/vulkan/icd.d/kosmickrisp_mesa_icd.aarch64.json
```

Use the manifest with a standard loader during local testing:

```sh
export VK_DRIVER_FILES="$(pwd)/Vulkan_API_SDK_1.4.354/build/AVK143/prefix/share/vulkan/icd.d/kosmickrisp_mesa_icd.aarch64.json"
vulkaninfo
```

Build the source-bootstrap installer from the repository root:

```sh
./build_VulkanICD_KHRInstaller.sh
```

It produces `dist/VulkanICD-KHR-Installer.pkg`. The package clones or updates
the project source and installs only project-owned standard ABI paths under
`/usr/local`; it never replaces the system Vulkan loader, Metal, a macOS
framework, or Apple graphics components. The package API version remains
`1.4.354`; its separate release label is
`cts-qualified-1.4.3.2-20260821`.

At install time the ICD and its bundled SPIR-V Tools runtime are placed in
`/usr/local/lib/avk143`; the ICD manifest is placed in
`/usr/local/share/vulkan/icd.d`. The default postinstall also builds the
Khronos Loader, `vulkaninfo`, `vkcube`, and Vulkan headers/pkg-config metadata.
`vkvia` is installed when provided by the selected Vulkan-Tools revision.
The Khronos validation layer is built by default. The builder provisions the
matching Vulkan Utility Libraries, SPIR-V-Headers, and SPIRV-Tools revisions
in its isolated build tree, so it does not link against a developer's
Homebrew or MacPorts installation. Set `AVK143_BUILD_VALIDATION_LAYERS=0` for
a minimal runtime-only build. Each component is emitted into the live
installer log.

The postinstall build provisions an isolated Python environment when the
root Installer service cannot see the interactive user's `Mako`, `PyYAML`, or
`packaging` modules. Progress is streamed to the Installer log and retained
at `/var/log/VulkanICD_KHRInstaller.log`. After installation, follow it live
with:

```sh
/usr/local/bin/vulkanicd-khr-log
```

Use `vulkanicd-khr-log --once` for a non-following snapshot.

For a genuinely visible install-time stream, place the package beside
`Apple_ICD/installer/install_vulkanicd_khr_live.command` and double-click the
`.command` file, or invoke it from Terminal. It runs Apple's `installer`
utility with `-verboseR` in the foreground, which is the supported way to see
package-script output live. Installer.app itself does not provide an embedded
terminal for package scripts.

## Current Capability Policy

- `[x]` Standard loader discovery, instance/device enumeration, compute,
  descriptors, graphics, synchronization, presentation, and targeted WSI
  qualification on the staged Apple GPU runtime.
- `[x]` `shaderFloatControls2` qualification with NaN-sensitive NIR lowering
  and public Metal `fma` handling.
- `[x]` Capability gating for unsupported Vulkan Memory Model, maintenance,
  and shader properties rather than false feature advertisement.
- `[x]` Full local CTS campaign evidence published as release artifacts.
- `[~]` Two retained early-fragment sample-mask `QualityWarning` results are
  documented and represented by physical-device properties.
- `[ ]` Independent multi-host reproduction and Khronos conformance submission.
- `[ ]` Hardware ray-tracing feature path.

For build, direct ICD handshake, runtime installation, and CTS-runner details,
see [Apple ICD assembly](Apple_ICD/README.md). Historical AVK143 frontend
experiments remain in `archive/`; they are not runtime dependencies.
