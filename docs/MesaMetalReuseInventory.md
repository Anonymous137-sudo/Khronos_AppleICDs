# Mesa Metal Gallium Reuse Inventory

AO46 uses this inventory before implementing a Metal Gallium feature. It
separates upstream code that can be linked directly from code whose algorithms
must be adapted behind `pipe_screen`/`pipe_context`, and from AGX/DRM execution
code that is intentionally excluded from the active Metal backend.

Refresh the report from the pinned Mesa checkout:

```sh
python3 'OpenGL_4.6(Core Profile)/Apple_ICD/scripts/inventory_mesa_reuse.py' \
  --mesa-root 'OpenGL_4.6(Core Profile)/mesa'
```

Use `--format json` for tooling and `--check --check-artifacts` in automation.
The check fails if a pinned upstream update removes an inventoried source path
or if the full KK/Asahi porting archives are not materialized.

## Reuse Policy

| Mode | Meaning | AO46 rule |
| --- | --- | --- |
| `direct` | Existing upstream Metal/NIR machinery | Link or call it through its public interface; do not fork it locally. |
| `port` | Useful upstream algorithm, but a Vulkan or AGX object ABI | Port the behavior into AO46 Gallium or the Metal adapter with upstream attribution and a focused regression test. |
| `reference` | Gallium feature behavior coupled to AGX state | Use it to define capability/state coverage and tests; extract only decoupled algorithms. |
| `exclude` | Native AGX binary, BO/VM, batch, or DRM synchronization path | Never link it into the active Metal backend. |

`libkk.a` and `libasahi.a` are explicit AO46 build dependencies used for
upstream feature-port validation. They are intentionally not linked into
`OpenGL_4.6.framework`: `libkk.a` is a Vulkan frontend and `libasahi.a` emits
AGX/DRM work rather than public Metal command buffers.

## Initial Priority Order

1. `kk-image-and-format`: generalize texture, image-view, texel-buffer, and
   format validation without creating a second resource model.
2. `kk-descriptors-and-nir`: replace the current static sampler/UBO contracts
   with reflected Gallium state and KosmicKrisp argument-table bindings.
3. `kk-commands-and-sync`: adopt KK's batching and event-ordering behavior in
   `AO46MetalSubmission` while preserving AO46 fence ownership.
4. `asahi-blit-streamout-query`: use Asahi's feature behavior to plan Metal
   implementations for blits, transform feedback, and queries. This is a port,
   never an AGX runtime dependency.
5. `kk-libkk-and-poly`: continue the existing tessellation and geometry work
   through the upstream Mesa lowering and kernel artifacts.

The scanner emits exact source paths, source-file counts, and native AGX/DRM
markers so each pass has a reproducible upstream starting point.
