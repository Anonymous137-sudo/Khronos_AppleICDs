# KosmicKrisp integration

The implementation lives at `../../../mesa/src/kosmickrisp` and is built by
Mesa's Meson graph. That graph pulls in the Vulkan runtime, NIR, shader
compiler, WSI, synchronization, format, and common utility sources required by
the ICD; hand-compiling a subset would be incorrect.

Use either `scripts/build-avk143-icd.sh` or the CMake target
`AVK143KosmicKrispICD`. `AVK143KosmicKrispSources` is an IDE/source-navigation
target containing the bridge, compiler, libkk, CLC, utility, and Vulkan files.
