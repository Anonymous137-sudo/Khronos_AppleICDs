# KosmicKrisp Semantic Delta

This release keeps Mesa and KosmicKrisp as the Vulkan semantic and Metal
execution owners. AVK143 carries only the corrections required to make the
assembled ICD's advertised behavior match the tested public Metal path.

## Correctness Changes

| Area | Correction | Why it matters |
| --- | --- | --- |
| Capability reporting | Keep only the unresolved Vulkan Memory Model capability disabled. Restore the current upstream maintenance7/8/9/10, shader FMA, shader untyped-pointer, unified-image-layout, surface-maintenance, and swapchain-maintenance declarations, including their complete dependency chains. | CTS 1.4.6.2 recognizes these extensions and validates their enumeration. Older CTS incompatibility is not a reason to suppress an implemented extension. |
| Float controls | Preserve NaN-sensitive algebraic behavior and lower weak fused multiply-add through Metal `fma`. | Avoids changing signed-zero, infinity, and NaN semantics in `shaderFloatControls2` workloads. |
| Fragment outputs | Respect component-decorated outputs and write masks during NIR blend lowering. | Prevents incorrect color-channel linkage. |
| Shader I/O arrays | Lower indirect shader I/O dereferences before mapping inputs to MSL. | Makes arrayed/indirect vertex input follow the Vulkan interface contract. |
| Descriptor lifetime | Preserve custom Vulkan allocator callbacks across ref-counted descriptor and pipeline-layout lifetimes. | Fixes ownership and teardown behavior under application allocators. |
| Custom borders | Carry custom border-color state through descriptor lowering and sampler emission. | Preserves Vulkan sampler semantics on Metal's sampler model. |

## Intentionally Not Claimed

- A nonzero `VkConformanceVersion`.
- Vulkan Memory Model or device-scope semantics that do not pass the focused
  CTS 1.4.6.2 memory-model group repeatably.
- `shaderFloat64` on hardware where it is not exposed.
- Early-fragment sample-mask ordering stricter than the reported physical-device
  properties.
- Hardware ray tracing.

The source changes live in the pinned Mesa/KosmicKrisp checkout and are paired
with the CTS artifacts released for this build. No standalone AVK143 Vulkan
semantic engine is introduced.

## CTS 1.4.6.2 correction to the previous policy

The earlier 1.4.3.2 engineering branch suppressed several extension names
because that older suite rejected extensions it did not recognize. That was a
test-suite compatibility workaround, not a valid Vulkan capability policy.
The version-2 branch removes that workaround. Extensions are now advertised
according to implementation support and checked with CTS 1.4.6.2; a failing
semantic test must be fixed or documented, not hidden by removing the extension
from enumeration.
