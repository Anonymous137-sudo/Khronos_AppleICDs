# Apple CGL and NSOpenGL Contract Map

## Purpose

This is the evidence gate before AVK143 expands `CVK` or defines
`NSVulkan_KHR`. It records the public macOS platform conventions that matter
for a new framework ABI. It does not copy Apple implementation code, infer a
private object layout, or depend on private graphics interfaces.

## Evidence Inputs

The review used the locally installed Xcode macOS SDK and its public text-based
linker interface files:

- `OpenGL.framework/Headers/CGLTypes.h`
- `OpenGL.framework/Headers/OpenGL.h`
- `OpenGL.framework/Headers/CGLCurrent.h`
- `OpenGL.framework/Headers/CGLIOSurface.h`
- `AppKit.framework/Headers/NSOpenGL.h`
- `OpenGL.framework/OpenGL.tbd`

The framework binary is resident in the dyld shared cache on this host, so the
SDK `.tbd` is the reproducible exported-symbol inventory. It confirms the
public CGL entry points including `CGLChoosePixelFormat`, `CGLCreateContext`,
`CGLSetCurrentContext`, `CGLFlushDrawable`, and `CGLUpdateContext`.

The inventory also contains `CGLSetSurface` and `CGLGetSurface`, but they are
not declared by the public umbrella headers reviewed here. They are therefore
not an AVK143 dependency or an ABI model.

`CGLContext.h` also exists in the SDK, but labels its exposed data as private
context data. AVK143 must not use that non-umbrella header or mirror its object
layout. The stable CGL-facing convention remains the opaque types in
`CGLTypes.h` and the functions declared by `OpenGL.h`.

## CGL Pattern

| Contract area | Public CGL evidence | AVK143 design consequence |
| --- | --- | --- |
| Object identity | `CGLContextObj`, `CGLPixelFormatObj`, renderer info, and pbuffer are pointer-to-incomplete-struct handles. | CVK native objects remain opaque handles. AVK143 must not expose Mesa, Metal, or AppKit storage layouts. |
| Creation and failure | `CGLChoosePixelFormat` and `CGLCreateContext` return `CGLError` and fill explicit out-parameters. | CVK creation calls should use explicit status plus output handles, never constructor-side exceptions or borrowed opaque state. |
| Capability selection | A terminated `CGLPixelFormatAttribute` request resolves to an implementation-selected pixel format; renderer queries describe actual support. | A future CVK surface/device request is a capability request, not a promise to expose a native Metal format or queue configuration. |
| Context ownership | CGL has create/destroy plus retain/release and an optional share context. | Define CVK object ownership, sharing, and destruction before the Mesa runtime call surface is frozen. |
| Thread-local selection | `CGLSetCurrentContext` and `CGLGetCurrentContext` make current-context selection explicit. | CVK must not imitate a hidden global context. Vulkan command/device state stays explicit; any NSVulkan convenience current object is AppKit-only. |
| Drawable lifecycle | Public `CGLClearDrawable`, `CGLFlushDrawable`, and `CGLUpdateContext` are distinct operations; AppKit adds `clearDrawable`, `update`, and `flushBuffer`. | Surface detach, resize/reconfigure, render completion, and present must remain separate CVK/WSI transitions. |
| IOSurface synchronization | `CGLTexImageIOSurface2D` documents explicit producer flush and consumer rebind/lock synchronization. | AVK143 WSI must express acquire/release and visibility through Mesa Vulkan synchronization, not implicit CPU copies. |

## AppKit Pattern

`NSOpenGLPixelFormat` is an Objective-C owner for a CGL pixel format.
`NSOpenGLContext` is an Objective-C owner for a CGL context and exposes an
explicit `NSView` attachment. The public header defines these important
lifecycle rules:

- `NSOpenGLContext` is created with a pixel format and optional share context.
- Its `view` property is explicitly `nullable, weak`; attaching an AppKit view
  never transfers view ownership to the graphics context.
- `clearDrawable`, `update`, `flushBuffer`, and `makeCurrentContext` are
  separate methods with separate meanings.
- `currentContext` is a class-level convenience, not the ownership model.
- `NSOpenGLContextParameterHasDrawable` makes drawable loss observable.

## AVK143 Decisions Before Runtime Work

1. Keep `CVK` as the framework/ICD C boundary with opaque handles, fixed-width
   ABI versioning, explicit errors, and explicit output ownership.
2. Define `NSVulkan_KHR` as a thin Objective-C AppKit bridge. Its future
   `NSView`/`CAMetalLayer` association must be weak or otherwise explicitly
   non-owning, and it must support clear, resize/update, acquire, present, and
   loss as distinct transitions.
3. Keep `VkSurfaceKHR`/Mesa WSI semantics authoritative. CVK records must not
   become a second Vulkan object model or a current-context API.
4. Treat `IOSurface` as an opt-in interoperable surface type with explicit
   synchronization; it is not a generic CPU staging shortcut.
5. Do not select final CVK surface-handle representation or expose an
   `NSVulkan_KHR` header until the Mesa WSI ownership map is reviewed against
   these rules.

## Next Evidence Gate

Map Mesa's public WSI ownership and the supported `CAMetalLayer`/IOSurface
handoff into the five decisions above. Only then should AVK143 add framework
entry points, an Objective-C `NSVulkan_KHR` class, or a loader-facing ICD ABI.
