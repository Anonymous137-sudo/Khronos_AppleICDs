# Runtime assembly

The redistributable runtime contains the KosmicKrisp ICD dylib, its private
SPIR-V Tools dylib, and a standard loader manifest. `stage-avk143-runtime.sh`
rewrites Mach-O IDs/rpaths, emits the installed manifest, and verifies that no
build-machine source path escapes into the package. The Khronos Loader remains
a separate client component.
