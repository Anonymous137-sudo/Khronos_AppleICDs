#!/bin/sh
# Run the Vulkan CTS 1.4.6.2 default mustpass list as four deterministic,
# resumable, asynchronous FBO phases.  No worker creates an onscreen window.
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
script_path="$script_dir/$(basename -- "$0")"
icd_root=$(CDPATH= cd -- "$script_dir/.." && pwd)
stage_dir=${AVK143_STAGE_DIR:-"$icd_root/../build/AVK143"}
cts_version=1.4.6.2
cts_root=${AVK143_CTS_ROOT:-"${HOME}/Downloads/VK-GL-CTS-vulkan-cts-${cts_version}"}
cts_work_root=${AVK143_CTS_WORK_ROOT:-"$icd_root/../build/cts-${cts_version}"}
cts_binary=${AVK143_CTS_BINARY:-"$cts_work_root/build-cts/external/vulkancts/modules/vulkan/deqp-vk"}
loader_dir=${AVK143_VULKAN_LOADER_DIR:-"$cts_work_root/prefix/lib"}
manifest=${AVK143_KOSMICKRISP_MANIFEST:-"$stage_dir/prefix/share/vulkan/icd.d/kosmickrisp_mesa_icd.aarch64.json"}
results_root=${AVK143_CTS_MEGA_RESULTS_DIR:-"$stage_dir/cts/vulkan-${cts_version}/mega-mustpass"}
mustpass_root="$cts_root/external/vulkancts/mustpass/main"
mustpass_index="$mustpass_root/vk-default.txt"
phase_count=4
chunk_size=${AVK143_CTS_MEGA_CHUNK_SIZE:-1000}

usage()
{
   printf '%s\n' "usage: $0 prepare|launch|status|worker PHASE" >&2
   exit 2
}

verify_inputs()
{
   [ -x "$cts_binary" ] || { printf '%s\n' "Missing CTS binary: $cts_binary" >&2; exit 2; }
   [ -d "$loader_dir" ] || { printf '%s\n' "Missing Khronos Loader directory: $loader_dir" >&2; exit 2; }
   [ -f "$manifest" ] || { printf '%s\n' "Missing AVK143 ICD manifest: $manifest" >&2; exit 2; }
   [ -f "$mustpass_index" ] || { printf '%s\n' "Missing CTS ${cts_version} mustpass index: $mustpass_index" >&2; exit 2; }
}

prepare()
{
   verify_inputs
   mkdir -p "$results_root/cases" "$results_root/phases"
   flattened="$results_root/cases/vk-default-${cts_version}.txt"
   flattened_tmp="$flattened.tmp"
   : > "$flattened_tmp"

   while IFS= read -r relative; do
      case "$relative" in
         ''|'#'*) continue ;;
         # These admission gates run alone before the four GPU-heavy workers.
         vk-default/info.txt|vk-default/memory-model.txt) continue ;;
      esac
      source_file="$mustpass_root/$relative"
      [ -f "$source_file" ] || {
         printf '%s\n' "Missing mustpass component: $source_file" >&2
         exit 2
      }
      awk 'NF && $0 !~ /^#/' "$source_file" >> "$flattened_tmp"
   done < "$mustpass_index"
   mv "$flattened_tmp" "$flattened"

   total=$(wc -l < "$flattened" | tr -d ' ')
   [ "$total" -gt 0 ] || { printf '%s\n' 'CTS mustpass inventory is empty.' >&2; exit 2; }
   phase_dir="$results_root/cases"
   for phase in 1 2 3 4; do
      rm -f "$phase_dir/phase-$phase.cases"
   done
   awk -v total="$total" -v phases="$phase_count" -v out="$phase_dir" '
      {
         phase = int(((NR - 1) * phases) / total) + 1
         print $0 > (out "/phase-" phase ".cases")
      }
   ' "$flattened"

   {
      printf 'CTS version: %s\n' "$cts_version"
      printf 'CTS source: %s\n' "$cts_root"
      printf 'CTS binary: %s\n' "$cts_binary"
      printf 'ICD manifest: %s\n' "$manifest"
      printf 'Surface: fbo (hidden; no onscreen WindowServer windows)\n'
      printf 'Mustpass inventory: %s\n' "$total"
      printf 'Focused gates excluded from shards: info, memory_model\n'
   for phase in 1 2 3 4; do
      count=$(wc -l < "$phase_dir/phase-$phase.cases" | tr -d ' ')
      chunk_dir="$phase_dir/phase-$phase-chunks-$chunk_size"
      mkdir -p "$chunk_dir"
      split -l "$chunk_size" -a 3 \
         "$phase_dir/phase-$phase.cases" "$chunk_dir/chunk-"
      printf 'Phase %s: %s cases\n' "$phase" "$count"
   done
      printf 'Worker process batch size: %s cases\n' "$chunk_size"
      printf 'Inventory SHA-256: '
      shasum -a 256 "$flattened" | awk '{print $1}'
   } > "$results_root/run-configuration.txt"
   printf '%s\n' "Prepared $total CTS ${cts_version} mustpass cases in four phases."
}

summarize_output()
{
   label=$1
   stdout=$2
   issues=$3
   summary=$4

   awk -F '\t' '
      /^Test case / {
         name = $0
         sub(/^Test case '\''/, "", name)
         sub(/'\''\.\.$/, "", name)
      }
      /^  (Fail|QualityWarning|InternalError|Crash|Timeout|ResourceError|CompatibilityWarning) \(/ {
         result = $0
         sub(/^  /, "", result)
         sub(/ \(.*/, "", result)
         print result "\t" name
      }
   ' "$stdout" > "$issues"

   pass=$(awk '/^  Pass \(/ {n++} END {print n + 0}' "$stdout")
   unsupported=$(awk '/^  NotSupported \(/ {n++} END {print n + 0}' "$stdout")
   waived=$(awk '/^  Waived \(/ {n++} END {print n + 0}' "$stdout")
   warnings=$(awk '/^  (QualityWarning|CompatibilityWarning) \(/ {n++} END {print n + 0}' "$stdout")
   failures=$(awk '/^  (Fail|InternalError|Crash|Timeout|ResourceError) \(/ {n++} END {print n + 0}' "$stdout")
   unexpected_warnings=$(awk -F '\t' '
      $1 == "QualityWarning" || $1 == "CompatibilityWarning" {
         if ($2 != "dEQP-VK.fragment_operations.early_fragment.sample_count_early_fragment_tests_depth_samples_2" &&
             $2 != "dEQP-VK.fragment_operations.early_fragment.sample_count_early_fragment_tests_depth_samples_4")
            n++
      }
      END {print n + 0}
   ' "$issues")
   executed=$((pass + unsupported + waived + warnings + failures))

   {
      printf 'Unit: %s\n' "$label"
      printf 'Executed: %s\n' "$executed"
      printf 'Pass: %s\n' "$pass"
      printf 'NotSupported: %s\n' "$unsupported"
      printf 'Waived: %s\n' "$waived"
      printf 'Quality/compatibility warnings: %s\n' "$warnings"
      printf 'Unexpected warnings: %s\n' "$unexpected_warnings"
      printf 'Failures/errors/crashes/timeouts: %s\n' "$failures"
   } > "$summary"

   UNIT_FAILURES=$failures
   UNIT_UNEXPECTED_WARNINGS=$unexpected_warnings
}

worker()
{
   phase=${1:-}
   case "$phase" in 1|2|3|4) ;; *) usage ;; esac
   verify_inputs
   cases="$results_root/cases/phase-$phase.cases"
   chunk_cases_root="$results_root/cases/phase-$phase-chunks-$chunk_size"
   [ -f "$cases" ] && [ -d "$chunk_cases_root" ] || {
      printf '%s\n' 'Run prepare before launching workers.' >&2
      exit 2
   }
   phase_root="$results_root/phases/phase-$phase"
   chunk_results_root="$phase_root/chunks"
   mkdir -p "$phase_root" "$chunk_results_root"
   complete="$phase_root/complete"
   [ ! -f "$complete" ] || { printf '%s\n' "Phase $phase is already complete."; exit 0; }
   rm -f "$phase_root/attention-required" "$phase_root/summary.txt" \
      "$phase_root/issues.tsv" "$phase_root/finished-at.txt"
   printf '%s\n' "$$" > "$phase_root/pid"
   date -u '+%Y-%m-%dT%H:%M:%SZ' > "$phase_root/started-at.txt"
   : > "$phase_root/running"
   launchd_label="com.avk143.cts${cts_version}.phase${phase}"
   cleanup_worker()
   {
      if [ -n "${deqp_pid:-}" ]; then
         kill -TERM "$deqp_pid" 2>/dev/null || true
      fi
      rm -f "$phase_root/running"
      # A submitted launchd job is persistent by default. Remove our own job
      # after evidence and completion/attention markers have been committed.
      launchctl remove "$launchd_label" 2>/dev/null || true
   }
   trap cleanup_worker EXIT INT TERM

   cd "$(dirname -- "$cts_binary")"
   for chunk_cases in "$chunk_cases_root"/chunk-*; do
      [ -f "$chunk_cases" ] || continue
      chunk=$(basename -- "$chunk_cases")
      chunk_root="$chunk_results_root/$chunk"
      mkdir -p "$chunk_root"
      [ ! -f "$chunk_root/complete" ] || continue

      set +e
      DYLD_LIBRARY_PATH="$loader_dir${DYLD_LIBRARY_PATH:+:$DYLD_LIBRARY_PATH}" \
         VK_DRIVER_FILES="$manifest" \
         "$cts_binary" \
            --deqp-caselist-file="$chunk_cases" \
            --deqp-surface-type=fbo \
            --deqp-visibility=hidden \
            --deqp-watchdog=enable \
            --deqp-shadercache=disable \
            --deqp-log-images=disable \
            --deqp-log-shader-sources=disable \
            --deqp-log-decompiled-spirv=disable \
            --deqp-log-filename="$chunk_root/results.qpa" \
            > "$chunk_root/stdout.txt" 2>&1 &
      deqp_pid=$!
      wait "$deqp_pid"
      deqp_status=$?
      deqp_pid=
      set -e
      printf '%s\n' "$deqp_status" > "$chunk_root/deqp-exit-status.txt"
      summarize_output "phase-$phase/$chunk" "$chunk_root/stdout.txt" \
         "$chunk_root/issues.tsv" "$chunk_root/summary.txt"

      if [ "$deqp_status" -ne 0 ] || [ "$UNIT_FAILURES" -ne 0 ] ||
         [ "$UNIT_UNEXPECTED_WARNINGS" -ne 0 ]; then
         cp "$chunk_root/summary.txt" "$phase_root/summary.txt"
         cp "$chunk_root/issues.tsv" "$phase_root/issues.tsv"
         : > "$phase_root/attention-required"
         date -u '+%Y-%m-%dT%H:%M:%SZ' > "$phase_root/finished-at.txt"
         printf '%s\n' "Phase $phase stopped at $chunk; see $phase_root/summary.txt and issues.tsv" >&2
         exit 1
      fi
      : > "$chunk_root/complete"
   done

   pass=0 unsupported=0 waived=0 warnings=0 failures=0 executed=0
   : > "$phase_root/issues.tsv"
   for chunk_summary in "$chunk_results_root"/chunk-*/summary.txt; do
      [ -f "$chunk_summary" ] || continue
      chunk_dir=$(dirname -- "$chunk_summary")
      cat "$chunk_dir/issues.tsv" >> "$phase_root/issues.tsv"
      value=$(awk -F ': ' '$1 == "Executed" {print $2}' "$chunk_summary")
      executed=$((executed + value))
      value=$(awk -F ': ' '$1 == "Pass" {print $2}' "$chunk_summary")
      pass=$((pass + value))
      value=$(awk -F ': ' '$1 == "NotSupported" {print $2}' "$chunk_summary")
      unsupported=$((unsupported + value))
      value=$(awk -F ': ' '$1 == "Waived" {print $2}' "$chunk_summary")
      waived=$((waived + value))
      value=$(awk -F ': ' '$1 == "Quality/compatibility warnings" {print $2}' "$chunk_summary")
      warnings=$((warnings + value))
      value=$(awk -F ': ' '$1 == "Failures/errors/crashes/timeouts" {print $2}' "$chunk_summary")
      failures=$((failures + value))
   done
   {
      printf 'Phase: %s\n' "$phase"
      printf 'Executed: %s\n' "$executed"
      printf 'Pass: %s\n' "$pass"
      printf 'NotSupported: %s\n' "$unsupported"
      printf 'Waived: %s\n' "$waived"
      printf 'Quality/compatibility warnings: %s\n' "$warnings"
      printf 'Failures/errors/crashes/timeouts: %s\n' "$failures"
   } > "$phase_root/summary.txt"
   date -u '+%Y-%m-%dT%H:%M:%SZ' > "$phase_root/finished-at.txt"
   : > "$complete"
   printf '%s\n' "Phase $phase completed cleanly."
}

launch()
{
   verify_inputs
   [ -f "$results_root/cases/phase-1.cases" ] || prepare
   for gate in info memory_model; do
      [ -f "$stage_dir/cts/vulkan-${cts_version}/$gate.complete" ] || {
         printf '%s\n' "Refusing mega launch: focused $gate gate is not complete." >&2
         exit 1
      }
   done
   mkdir -p "$results_root/phases"
   for phase in 1 2 3 4; do
      phase_root="$results_root/phases/phase-$phase"
      if [ -f "$phase_root/complete" ]; then
         printf '%s\n' "Phase $phase already complete; not relaunched."
         continue
      fi
      if [ -f "$phase_root/running" ] && [ -f "$phase_root/pid" ] &&
         kill -0 "$(cat "$phase_root/pid")" 2>/dev/null; then
         printf '%s\n' "Phase $phase already running as PID $(cat "$phase_root/pid")."
         continue
      fi
      mkdir -p "$phase_root"
      if command -v launchctl >/dev/null 2>&1; then
         label="com.avk143.cts${cts_version}.phase${phase}"
         launchctl remove "$label" 2>/dev/null || true
         launchctl submit -l "$label" -p /bin/sh \
            -o "$phase_root/worker.log" -e "$phase_root/worker.err" -- \
            /bin/sh "$script_path" worker "$phase"
         printf '%s\n' "$label" > "$phase_root/launchd-label"
         printf '%s\n' "Launched phase $phase asynchronously through launchd ($label)."
      else
         nohup "$script_path" worker "$phase" </dev/null > "$phase_root/worker.log" 2>&1 &
         printf '%s\n' "$!" > "$phase_root/launcher-pid"
         printf '%s\n' "Launched phase $phase asynchronously as PID $!."
      fi
   done
}

status()
{
   [ -d "$results_root/phases" ] || { printf '%s\n' 'Campaign has not been launched.'; exit 0; }
   for phase in 1 2 3 4; do
      phase_root="$results_root/phases/phase-$phase"
      if [ -f "$phase_root/complete" ]; then
         state=complete
      elif [ -f "$phase_root/attention-required" ]; then
         state=attention-required
      elif [ -f "$phase_root/running" ] && [ -f "$phase_root/pid" ] &&
           kill -0 "$(cat "$phase_root/pid")" 2>/dev/null; then
         state="running (PID $(cat "$phase_root/pid"))"
      else
         state=not-running
      fi
      planned=0
      [ ! -f "$results_root/cases/phase-$phase.cases" ] ||
         planned=$(wc -l < "$results_root/cases/phase-$phase.cases" | tr -d ' ')
      executed=0
      for chunk_stdout in "$phase_root"/chunks/chunk-*/stdout.txt; do
         [ -f "$chunk_stdout" ] || continue
         count=$(awk '/^Test case '\''/ {n++} END {print n + 0}' "$chunk_stdout")
         executed=$((executed + count))
      done
      printf 'Phase %s: %s; %s/%s cases started\n' "$phase" "$state" "$executed" "$planned"
      [ ! -f "$phase_root/summary.txt" ] || sed 's/^/  /' "$phase_root/summary.txt"
   done
}

command=${1:-}
case "$command" in
   prepare) prepare ;;
   launch) launch ;;
   status) status ;;
   worker) shift; worker "${1:-}" ;;
   *) usage ;;
esac
