# KosmicKrisp Semantic Delta

This release keeps Mesa and KosmicKrisp as the Vulkan semantic and Metal
execution owners. AVK143 carries only the corrections required to make the
assembled ICD's advertised behavior match the tested public Metal path.

## Correctness Changes

| Area | Correction | Why it matters |
| --- | --- | --- |
| Capability reporting | Disable unsupported Vulkan Memory Model, maintenance, and shader capability bits instead of advertising them. | Applications and CTS must receive `NotSupported`, not a false feature promise. |
| Float controls | Preserve NaN-sensitive algebraic behavior and lower weak fused multiply-add through Metal `fma`. | Avoids changing signed-zero, infinity, and NaN semantics in `shaderFloatControls2` workloads. |
| Fragment outputs | Respect component-decorated outputs and write masks during NIR blend lowering. | Prevents incorrect color-channel linkage. |
| Shader I/O arrays | Lower indirect shader I/O dereferences before mapping inputs to MSL. | Makes arrayed/indirect vertex input follow the Vulkan interface contract. |
| Descriptor lifetime | Preserve custom Vulkan allocator callbacks across ref-counted descriptor and pipeline-layout lifetimes. | Fixes ownership and teardown behavior under application allocators. |
| Custom borders | Carry custom border-color state through descriptor lowering and sampler emission. | Preserves Vulkan sampler semantics on Metal's sampler model. |

## Intentionally Not Claimed

- A nonzero `VkConformanceVersion`.
- Vulkan Memory Model or device-scope semantics that public Metal cannot prove.
- `shaderFloat64` on hardware where it is not exposed.
- Early-fragment sample-mask ordering stricter than the reported physical-device
  properties.
- Hardware ray tracing.

The source changes live in the pinned Mesa/KosmicKrisp checkout and are paired
with the CTS artifacts released for this build. No standalone AVK143 Vulkan
semantic engine is introduced.
