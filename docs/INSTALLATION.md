# Installation

`Khronos_AppleICDs` ships a bootstrap installer that pulls the repository, builds from source on the target machine, and installs the live framework and driver outputs into macOS.

## Target Paths

The live install writes to:

```text
/System/Library/Frameworks/OpenGL.framework
/System/Library/Frameworks/OpenGL_4.6.framework
/usr/local/lib
```

The cloned working repository is stored at:

```text
/usr/local/src/Khronos_AppleICDs
```

## Safety Gate

Before a live install to `/`, the installer checks:

- `csrutil status`
- `csrutil authenticated-root status`

The install proceeds only when those protections are disabled, or when Authenticated Root is not supported by that macOS release.

When the machine passes the gate, the installer prints:

```text
device identified as a developer mac
warning: the driver is currently Indev/WIP and may cause uncertain behaviour
install at your own responsibility to maintain system stability
```

## Build And Install Flow

Build the bootstrap package:

```bash
./build_OpenGLKHR_ICD_Installer.sh
```

Install or reinstall from the cloned repository:

```bash
/usr/local/bin/openglkhr-icd-build
```

Pull the latest commit, rebuild, and reinstall:

```bash
/usr/local/bin/openglkhr-icd-update
```

## Local Verification

For repo-local builds and tests:

```bash
cmake -S "OpenGL_4.6(Core Profile)/Apple_ICD" -B "OpenGL_4.6(Core Profile)/Apple_ICD/artifacts/build"
cmake --build "OpenGL_4.6(Core Profile)/Apple_ICD/artifacts/build"
ctest --test-dir "OpenGL_4.6(Core Profile)/Apple_ICD/artifacts/build" --output-on-failure
```
