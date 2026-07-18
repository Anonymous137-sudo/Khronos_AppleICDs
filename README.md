# Khronos_AppleICDs

This repository carries the `OpenGL_4.6(Core Profile)` source used to build the OpenGLKHR ICD stack for macOS.

## Layout

- `OpenGL_4.6(Core Profile)/Apple_ICD`
  Main source tree for the system-space framework, the Apple `OpenGL.framework` shim, the internal ICD/backend layer, and the user-space `libGL*.dylib` bridge libraries.

## Installer

Build the repo-bootstrap installer package with:

```bash
./build_OpenGLKHR_ICD_Installer.sh
```

The resulting package is written to:

```text
dist/OpenGLKHR_ICD_Installer.pkg
```

On install, the package does not embed the source tree. Instead it installs bootstrap scripts that clone or update this repository into:

```text
/usr/local/src/Khronos_AppleICDs
```

Then it builds from source and installs live outputs into:

```text
/System/Library/Frameworks/OpenGL.framework
/System/Library/Frameworks/OpenGL_4.6.framework
/usr/local/lib
```

For rebuilds after install:

```bash
/usr/local/bin/openglkhr-icd-build
```

For pulling newer commits and reinstalling:

```bash
/usr/local/bin/openglkhr-icd-update
```
