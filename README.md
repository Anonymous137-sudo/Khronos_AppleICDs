# Khronos_AppleICDs

`Khronos_AppleICDs` is a third-party work-in-progress OpenGL 4.6 system-framework and driver project for macOS.

Its goal is to provide a modern OpenGL 4.6 core-profile stack through a real system framework, system-space loader pieces, and user-space `libGL*.dylib` bridges, filling in the modern OpenGL path Apple stopped advancing when OpenGL was deprecated on macOS Mojave 10.14 in 2018.

## Repository Layout

- `OpenGL_4.6(Core Profile)/Apple_ICD`
  Main source tree for `OpenGL_4.6.framework`, the Apple-path `OpenGL.framework` loader, the internal ICD/backend boundary, the user-space `libGL*.dylib` drivers, test coverage, and packaging scripts.
- `docs/INSTALLATION.md`
  Live-install notes for developer machines, installer behavior, target paths, and update flow.
- `docs/WORKFLOW_PLAN.md`
  Active engineering workflow plan for taking the current driver framework to full OpenGL 4.6 Core Profile coverage.
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
