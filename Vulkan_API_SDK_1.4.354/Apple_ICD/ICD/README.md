# ICD discovery metadata

Mesa generates the build-tree and install-tree manifests from the Vulkan
registry in `src/kosmickrisp/vulkan/meson.build`. The template here documents
the AVK143-installed absolute-path form used by `stage-avk143-runtime.sh`.
Loader discovery uses `share/vulkan/icd.d`; no Apple framework registration or
custom dispatch mechanism is involved.
