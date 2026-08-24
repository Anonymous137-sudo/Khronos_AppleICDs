#!/bin/sh
# Qualify the one permitted early-fragment sample-mask ordering outcome before
# a broad CTS wave.  The maintenance5 pair verifies the advertised properties.
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
icd_root=$(CDPATH= cd -- "$script_dir/.." && pwd)
stage_dir=${AVK143_STAGE_DIR:-"$icd_root/../build/AVK143"}
manifest=${AVK143_KOSMICKRISP_MANIFEST:-"$stage_dir/prefix/share/vulkan/icd.d/kosmickrisp_mesa_icd.aarch64.json"}
cts_version=1.4.6.2
cts_work_root=${AVK143_CTS_WORK_ROOT:-"$icd_root/../build/cts-${cts_version}"}
cts_binary=${AVK143_CTS_BINARY:-"$cts_work_root/build-cts/external/vulkancts/modules/vulkan/deqp-vk"}
loader_dir=${AVK143_VULKAN_LOADER_DIR:-"$cts_work_root/prefix/lib"}
results_dir=${AVK143_EARLY_FRAGMENT_QUALITY_RESULTS_DIR:-"$stage_dir/cts/vulkan-${cts_version}/early-fragment-quality"}

if [ ! -x "$cts_binary" ]; then
   printf '%s\n' "AVK143 CTS binary is missing or not executable: $cts_binary" >&2
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
cases="$results_dir/cases.txt"
qpa="$results_dir/early-fragment-quality.qpa"
stdout="$results_dir/early-fragment-quality.stdout"

printf '%s\n' \
   'dEQP-VK.fragment_operations.early_fragment.sample_count_early_fragment_tests_depth_samples_2' \
   'dEQP-VK.fragment_operations.early_fragment.sample_count_early_fragment_tests_depth_samples_2_maintenance5' \
   'dEQP-VK.fragment_operations.early_fragment.sample_count_early_fragment_tests_depth_samples_4' \
   'dEQP-VK.fragment_operations.early_fragment.sample_count_early_fragment_tests_depth_samples_4_maintenance5' \
   > "$cases"

cd "$(dirname -- "$cts_binary")"
if ! DYLD_LIBRARY_PATH="$loader_dir${DYLD_LIBRARY_PATH:+:$DYLD_LIBRARY_PATH}" \
   VK_DRIVER_FILES="$manifest" \
   "$cts_binary" \
      --deqp-caselist-file="$cases" \
      --deqp-surface-type=fbo \
      --deqp-visibility=hidden \
      --deqp-watchdog=enable \
      --deqp-log-images=disable \
      --deqp-log-shader-sources=disable \
      --deqp-log-decompiled-spirv=disable \
      --deqp-log-filename="$qpa" > "$stdout" 2>&1; then
   printf '%s\n' "Early-fragment quality qualification did not complete; see $stdout" >&2
   exit 1
fi

pass_count=$(awk '/^  Pass \(/ { count++ } END { print count + 0 }' "$stdout")
warning_count=$(awk '/^  QualityWarning \(/ { count++ } END { print count + 0 }' "$stdout")
failure_count=$(awk '/^  (Fail|InternalError|Crash) \(/ { count++ } END { print count + 0 }' "$stdout")

if [ "$pass_count" -ne 2 ] || [ "$warning_count" -ne 2 ] || [ "$failure_count" -ne 0 ]; then
   printf '%s\n' "Unexpected early-fragment sample-mask qualification result:" >&2
   printf '%s\n' "  Pass=$pass_count QualityWarning=$warning_count Failure=$failure_count" >&2
   printf '%s\n' "  Expected two maintenance5 passes and two permitted core quality warnings." >&2
   printf '%s\n' "  See $stdout and $qpa" >&2
   exit 1
fi

printf '%s\n' "qualified: two permitted core QualityWarning results; maintenance5 ordering matches advertised properties" \
   > "$results_dir/qualification.txt"
printf '%s\n' "AVK143 early-fragment quality qualification passed."
