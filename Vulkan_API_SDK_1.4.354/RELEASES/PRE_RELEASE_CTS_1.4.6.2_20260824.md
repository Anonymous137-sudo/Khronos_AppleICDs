# Vulkan ICD 1.4.354 Preview

This is an **experimental developer prerelease**, not a Khronos-certified or
CTS-qualified Vulkan implementation. It assembles the standard Khronos Loader
and ABI, Mesa's Vulkan runtime, the KosmicKrisp Metal ICD, Vulkan Tools, Vulkan
Headers, and the Khronos validation layer for Apple Silicon macOS.

## Exact source state

- Mesa upstream base: `4641f0094f29752f2774e5c0cbfc75d5c76a2f26`
- AVK143 Mesa head: `4dad9a83b94761f08f745e9b52cbe9817b28299e`
- Vulkan-Headers: `01393c3df0e5285b54ee6527466513f9e614be94` (`v1.4.354`)
- Vulkan-Loader: `92f42301839b406b7d47d92b279db8f8744d8dcf` (`v1.4.354`)
- CTS source: `vulkan-cts-1.4.6.2`
- Driver-reported API: Vulkan 1.4.359
- `VkConformanceVersion`: `{0, 0, 0, 0}`
- Runtime package SHA-256: `1405b83de9ecbdad4c59506b8e176d43407ab238624c524cf198103a01d5daa9`
- CTS evidence archive SHA-256: `a0f618e13c42021eb92314e7a3a5b18dcf5ec653004a94511266d2660e076583`
- Packaged ICD SHA-256: `bac43689f719f870f35181e7185094d72046cc23a618cc06e5ee45737731dfaa`
- Packaged ICD manifest SHA-256: `44a11ca70ac0978fdd90b2b78c461867d97c70713d3824c101cf34370ea9ce94`

The OpenGL sibling driver was rebased onto the same Mesa upstream base while
preserving its downstream Gallium and KosmicKrisp integration. Its honest
Mesa-selected context ceiling increased from OpenGL 3.3 to OpenGL 4.1; OpenGL
CTS qualification remains pending.

## CTS 1.4.6.2 evidence

Testing was performed on macOS 26.5.2 (25F84), Apple M4 Pro (20 GPU cores),
and Metal 4. The complete 3,230,231-case default campaign was **not** admitted
because the mandatory memory-model gate did not pass.

The focused CTS evidence was captured before the final conflict-free Mesa
upstream refresh. That refresh preserves the tested downstream capability
patches and passes the ICD handshake, `vulkaninfo`, and project smoke suite,
but a focused CTS rerun is still required before promoting this prerelease.

| Group | Pass | NotSupported | Fail | Warnings |
| --- | ---: | ---: | ---: | ---: |
| Clean upstream `dEQP-VK.info` | 20 | 1 | 0 | 0 |
| Clean upstream `dEQP-VK.memory_model` | 3,266 | 14,028 | 6 | 0 |
| Final preview `dEQP-VK.info` | 19 | 1 | 1 | 0 |
| Restored-extension focused API tests | 12 | 0 | 0 | 0 |
| Maintenance9/10 semantic samples | 2 | 0 | 0 | 0 |

The final `info` failure is intentional: Vulkan Memory Model capability bits
remain disabled rather than advertising behavior that failed six semantic
tests. The six exact cases and rejected experiments are recorded in
`V2_CTS_1.4.6.2_DRAFT_20260822.md` and `SEMANTIC_DELTA.md`.
The evidence archive contains path-redacted copies of the named QPA and stdout
files; test names, outcomes, and diagnostic messages are unchanged.

## Package contents

- KosmicKrisp Vulkan ICD and private SPIR-V Tools dependency
- Khronos Vulkan Loader (`libvulkan.1.dylib`)
- `vulkaninfo` and `vkcube`
- Khronos validation layer
- Vulkan headers and `vulkan.pc`
- loader discovery manifests under `/usr/local/share/vulkan`

The package is unsigned and ad-hoc signs its relocatable Mach-O payload. It is
intended for development Macs. All generated manifests and binaries are
checked for personal paths and build-machine metadata before packaging.

## Known semantic issues

Six Vulkan Memory Model litmus tests fail nondeterministically or semantically
across device and queue-family scopes. No workaround is enabled, no
conformance version is claimed, and the full CTS campaign remains blocked
until those failures are fixed and the complete official mustpass list runs.
