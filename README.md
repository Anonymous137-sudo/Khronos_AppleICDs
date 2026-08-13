# Khronos_AppleICDs

`Khronos_AppleICDs` is a third-party work-in-progress OpenGL 4.6
system-framework and driver project for macOS.

Its goal is to provide a modern OpenGL 4.6 core-profile stack through a real system framework, system-space loader pieces, and user-space `libGL*.dylib` bridges, filling in the modern OpenGL path Apple stopped advancing when OpenGL was deprecated on macOS Mojave 10.14 in 2018.

The active direction reuses Mesa's OpenGL core, state tracker, GLSL, SPIR-V,
NIR, and NIR-to-MSL compiler machinery. AO46 focuses on the Metal execution
backend and the macOS-specific work Mesa does not provide: framework ABI,
CGL/NSOpenGL, drawable lifecycle, `libGLICD.dylib`, user-space `libGL*.dylib`
bridges, compatibility behavior, and staged CTS readiness.

AO46 does not hand-write a second OpenGL semantic engine or a separate
GLSL-to-Metal compiler. The historical direct AGX/UABI work is retained as
research, including its raw evidence, but is not the active runtime path or a
conformance claim. See [the active Mesa Metal backend
plan](docs/AO46MetalBackendPlan.md).

## Repository Layout

- `OpenGL_4.6(Core Profile)/Apple_ICD`
  Main source tree for `OpenGL_4.6.framework`, the Apple-path `OpenGL.framework` loader, the internal ICD/backend boundary, the user-space `libGL*.dylib` drivers, test coverage, and packaging scripts.
- `docs/INSTALLATION.md`
  Live-install notes for developer machines, installer behavior, target paths, and update flow.
- `docs/AO46MetalBackendPlan.md`
  Governing Mesa-to-Metal backend plan, ownership boundary, and CTS delivery
  order.
- `docs/WORKFLOW_PLAN.md`
  Active workflow, implementation rules, CTS milestones, and archived direct
  AGX research dashboard.
- `docs/research/evidence/`
  Checksummed direct-AGX research evidence, trace logs, Ghidra reports, and
  project-owned analysis metadata.
- `dist/`
  Built `OpenGLKHR_ICD_Installer.pkg` outputs.

## Build

Build the framework stack directly from source with:

```bash
cmake -S "OpenGL_4.6(Core Profile)/Apple_ICD" -B "OpenGL_4.6(Core Profile)/Apple_ICD/artifacts/build"
cmake --build "OpenGL_4.6(Core Profile)/Apple_ICD/artifacts/build"
ctest --test-dir "OpenGL_4.6(Core Profile)/Apple_ICD/artifacts/build" --output-on-failure
```

Repo-local browsable artifacts are written under:

```text
OpenGL_4.6(Core Profile)/Apple_ICD/artifacts/build
OpenGL_4.6(Core Profile)/Apple_ICD/artifacts/stage
```

Passing the current smoke suite validates framework and integration scaffolding
only. It does not establish Metal-backed OpenGL 4.6 support or CTS conformance.

## Installer

Build the GitHub-bootstrap installer package with:

```bash
./build_OpenGLKHR_ICD_Installer.sh
```

The generated package is written to:

```text
dist/OpenGLKHR_ICD_Installer.pkg
```

The installer clones or updates this repository into:

```text
/usr/local/src/Khronos_AppleICDs
```

The installer is a developer-only WIP mechanism. Do not treat a successful
install as proof of system-wide application compatibility or OpenGL 4.6
conformance; staged CTS is an explicit project milestone.

Then it builds from source and installs into the live macOS locations:

```text
/System/Library/Frameworks/OpenGL.framework
/System/Library/Frameworks/OpenGL_4.6.framework
/usr/local/lib
```

Live installation is guarded by a developer-machine check. The install only proceeds when `csrutil status` and `csrutil authenticated-root status` both report disabled on the target machine, or when Authenticated Root is not supported by that macOS release.

For rebuilds after install:

```bash
/usr/local/bin/openglkhr-icd-build
```

For pulling newer commits and reinstalling:

```bash
/usr/local/bin/openglkhr-icd-update
```
