# CVK ABI Contract

`CVK` is the stable macOS-facing ABI boundary between the future framework/ICD
layer and Mesa-owned Vulkan objects. It is deliberately not a parallel Vulkan
API or a replacement for Mesa dispatch.

Its platform direction is now constrained by the public Apple CGL/NSOpenGL
contract map in `../Research/AppleCGLNSOpenGLContractMap.md`. In particular,
the current header records opaque handles, explicit lifecycle state, and a
plain-C AppKit drawable snapshot. It does not freeze the final surface-handle
representation or create a Vulkan object.

## Rules

- `CVKInstance`, physical-device, device, and queue handles are opaque.
- A surface and submission use fixed-width values so their records are stable
  across language and dynamic-library boundaries.
- Every public record begins with `structure_size` and `abi_version`; unknown
  revisions fail with `kCVKErrorIncompatibleABI`.
- `native_drawable` is borrowed for surface creation. The future
  `NSVulkan_KHR` bridge owns its AppKit/CAMetalLayer lifetime separately.
- `CVKSurfaceConfiguration` governs only public `CAMetalLayer` pixel-format
  and framebuffer-only state. Vulkan image selection and format negotiation
  remain Mesa runtime responsibilities.
- A submission stays retained until it reaches `COMPLETE` or `FAILED`. The
  future Metal adapter will translate its completion value to Mesa/KK fence and
  semaphore state.

No runtime functions or capability claims are part of ABI version 1. It exists
solely to lock the future framework and ICD boundary before Mesa runtime
objects are wired in.

The first compiled `NSVulkan_KHR` companion owns weak AppKit-view attachment
and backing-size invalidation, then copies that state into a versioned
`CVKSurfaceSnapshot`. It may retain and configure an application-owned
`CAMetalLayer` with a validated `CVKSurfaceConfiguration` without changing the
view's layer tree, but does not manufacture a CVK surface handle, Vulkan
instance, layer, or swapchain.
