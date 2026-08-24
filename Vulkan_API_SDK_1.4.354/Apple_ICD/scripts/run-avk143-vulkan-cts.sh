#!/bin/sh
set -u

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
icd_root=$(CDPATH= cd -- "$script_dir/.." && pwd)
stage_dir=${AVK143_STAGE_DIR:-"$icd_root/../build/AVK143"}
manifest=${AVK143_KOSMICKRISP_MANIFEST:-"$stage_dir/prefix/share/vulkan/icd.d/kosmickrisp_mesa_icd.aarch64.json"}
cts_version=1.4.6.2
# Keep disposable test tools with the local build, not in volatile /private/tmp.
cts_root=${AVK143_CTS_ROOT:-"${HOME}/Downloads/VK-GL-CTS-vulkan-cts-${cts_version}"}
cts_work_root=${AVK143_CTS_WORK_ROOT:-"$icd_root/../build/cts-${cts_version}"}
cts_binary=${AVK143_CTS_BINARY:-"$cts_work_root/build-cts/external/vulkancts/modules/vulkan/deqp-vk"}
loader_dir=${AVK143_VULKAN_LOADER_DIR:-"$cts_work_root/prefix/lib"}
results_dir=${AVK143_CTS_RESULTS_DIR:-"$stage_dir/cts/vulkan-${cts_version}"}
# FBO is the safe default for broad API coverage. Set this to "window" when
# qualifying the Metal WSI/swapchain path under a live WindowServer session.
surface_type=${AVK143_CTS_SURFACE_TYPE:-fbo}
qualify_early_fragment=${AVK143_CTS_QUALIFY_EARLY_FRAGMENT:-1}

groups=${AVK143_CTS_GROUPS:-'
info api memory pipeline binding_model spirv_assembly glsl renderpass renderpass2
dynamic_rendering ubo dynamic_state ssbo query_pool draw compute image wsi
synchronization synchronization2 sparse_resources tessellation rasterization clipping
fragment_operations texture geometry robustness multiview subgroups ycbcr
protected_memory device_group memory_model conditional_rendering graphicsfuzz
imageless_framebuffer transform_feedback descriptor_indexing fragment_shader_interlock
drm_format_modifiers ray_tracing_pipeline ray_query fragment_shading_rate reconvergence
mesh_shader fragment_shading_barycentric depth video shader_object dgc cooperative_vector
'}

if [ ! -f "$cts_root/external/vulkancts/mustpass/main/vk-default.txt" ]; then
   printf '%s\n' "Vulkan CTS ${cts_version} source is missing: $cts_root" >&2
   exit 2
fi

if [ ! -x "$cts_binary" ]; then
   printf '%s\n' "AVK143 CTS binary is missing or not executable: $cts_binary" >&2
   printf '%s\n' "Run $script_dir/prepare-avk143-vulkan-cts.sh first." >&2
   exit 2
fi

if [ ! -f "$manifest" ]; then
   printf '%s\n' "AVK143 ICD manifest is missing: $manifest" >&2
   exit 2
fi

if [ ! -d "$loader_dir" ]; then
   printf '%s\n' "Khronos Loader directory is missing: $loader_dir" >&2
   exit 2
fi

mkdir -p "$results_dir"
printf 'CTS version: %s\nCTS source: %s\nCTS binary: %s\nICD manifest: %s\nLoader directory: %s\n' \
   "$cts_version" "$cts_root" "$cts_binary" "$manifest" "$loader_dir" \
   > "$results_dir/run-configuration.txt"

if [ "$qualify_early_fragment" -eq 1 ]; then
   AVK143_STAGE_DIR="$stage_dir" \
   AVK143_KOSMICKRISP_MANIFEST="$manifest" \
   AVK143_CTS_BINARY="$cts_binary" \
   AVK143_VULKAN_LOADER_DIR="$loader_dir" \
   AVK143_EARLY_FRAGMENT_QUALITY_RESULTS_DIR="$results_dir/early-fragment-quality" \
      "$script_dir/qualify-avk143-early-fragment-quality.sh"
fi

overall=0
cd "$(dirname -- "$cts_binary")" || exit 2

for group in $groups; do
   completion="$results_dir/$group.complete"
   qpa="$results_dir/$group.qpa"
   stdout="$results_dir/$group.stdout"

   if [ -f "$completion" ]; then
      printf '%s\n' "Skipping completed CTS group: dEQP-VK.$group"
      continue
   fi

   printf '%s\n' "Running CTS group: dEQP-VK.$group"
   DYLD_LIBRARY_PATH="$loader_dir${DYLD_LIBRARY_PATH:+:$DYLD_LIBRARY_PATH}" \
      VK_DRIVER_FILES="$manifest" \
      "$cts_binary" \
         --deqp-case="dEQP-VK.$group.*" \
         --deqp-surface-type="$surface_type" \
         --deqp-visibility=hidden \
         --deqp-watchdog=enable \
         --deqp-log-images=disable \
         --deqp-log-shader-sources=disable \
         --deqp-log-decompiled-spirv=disable \
         --deqp-log-filename="$qpa" > "$stdout" 2>&1
   group_result=$?

   if [ "$group_result" -eq 0 ]; then
      : > "$completion"
      printf '%s\n' "Completed CTS group: dEQP-VK.$group"
   else
      printf '%s\n' "CTS group failed: dEQP-VK.$group (exit $group_result); see $stdout" >&2
      overall=1
   fi
done

exit "$overall"
