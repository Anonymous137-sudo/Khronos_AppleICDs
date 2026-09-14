# AO46 OpenGL CTS Pipeline

`run_ao46_gl_cts.py` runs CTS in bounded asynchronous shards. Each worker has
an independent case list, QPA file, process timeout, and stdout log. A crashed
shard is retried one case at a time by the same bounded worker pool, preventing
one compiler or GPU fault from hiding or serializing the rest of the batch.
Every classified case is appended to `results.jsonl` after its batch ends, so an
interrupted run can continue with `--resume` without repeating passing cases.
Use `--resume-classified` to skip completed passing, failing, and unsupported
cases when finishing interrupted discovery; missing/timeout cases are retried.
Resume always uses the latest result and allocates new artifact names.
Use `--resume` after a driver fix so
previous failures run again while established passes are retained.

The default of two workers is deliberate for a single Apple GPU and
WindowServer. Increase it gradually only after a stable offscreen run; the
runner caps concurrency at eight processes and the shard size at 256 cases.

```sh
python3 scripts/run_ao46_gl_cts.py \
  --binary /path/to/glcts \
  --case-list /path/to/gl46-main.txt \
  --framework build-metal/OpenGL_4.6.framework/Versions/A/OpenGL_4.6 \
  --output artifacts/cts/gl46 \
  --workers 2 --batch-size 16 --resume
```

Use repeated `--pattern` arguments for focused waves. For example,
`--pattern 'KHR-GL46.transform_feedback.*'` selects the transform-feedback
group. `summary.json` is the authoritative count, `failures.txt` contains
ordinary CTS failures, and `crashes.txt` contains timeout or process-loss cases.
`feature-matrix.json` groups every status by CTS feature. Generate a concise
failure/signature report after a wave with:

```sh
python3 scripts/analyze_ao46_gl_cts.py artifacts/cts/gl46
```

This writes `report.md` and `issue-signatures.json`; reruns include the exact
QPA and stdout-log provenance in each `results.jsonl` record.
Do not publish a conformance claim from these engineering results without the
Khronos submission and ratification process.

## Complete discovery campaign

The active workflow is full discovery before driver edits, not alternating
individual feature batches and fixes. The 2026-09-07 campaign selects every
case in the 19,714-case OpenGL 4.6 mustpass list with no feature filters:
four concurrent worker processes, 32 cases per batch, Metal validation on,
180-second process deadlines, and isolated execution of cases left unfinished
by a crashed or timed-out batch. This is bounded process-level parallelism,
not SIMD vectorization or thousands of concurrent GPU clients.

The active discovery output is `ao46-cts/gl46-complete-discovery-20260907-r2` relative to
the workspace containing Khronos_AppleICDs. Keep driver binaries unchanged
through bulk execution and isolation. A batch timeout marks its unfinished
cases provisionally; only the isolated results identify individual hangs.
Do not call a live summary complete merely because it contains every selected
case while isolation is still running.

Each invocation records `selected-cases.txt` and a numbered manifest containing
SHA-256 fingerprints of the case list, CTS binary, framework, and build-root
dylibs, plus concurrency, deadline, batch-size, and validation settings.
`summary.json` and feature counts refresh during execution. `unsupported.txt`
and `warnings.txt` are separate from ordinary `failures.txt` and `crashes.txt`.
The legacy `failed` aggregate includes NotSupported; use `actionable` and
individual status counts to distinguish defects from unsupported cases.

The analyzer uses only each case's latest attempt and its own stdout section.
It also writes `issues.json` with per-case QPA diagnostic excerpts and artifact
links, including cases without a recognized stdout signature.

Exit sequence:

1. Finish every selected case and all missing-case isolation; retain one full
   inventory, including unsupported and warning statuses.
2. Group issues by root cause and fix shared compiler, binding, scheduling,
   and semantic problems against that inventory. Do not hide failures by
   removing tests or changing expected results.
3. Verify fixes and run the complete list again on the final candidate;
   historical passes from a different binary are not release qualification.
4. Only after confirmed results: commit and push the intended changes, test
   installer payload/discovery and both frontend products, then prepare the
   release with accurate limitations and retained evidence.

This campaign exercises the CGL/offscreen OpenGL frontend. EGL/window-system
and packaging qualification remain separate release checks. It neither runs
Vulkan CTS nor establishes Khronos certification.

The unsuffixed 20260907 discovery was stopped during isolation after finding
a harness error: the executable inherited the repository working directory,
so data-driven CTS cases could not open gl_cts assets. Do not use its counts
as the consolidated driver baseline. The r2 run restarts the entire unfiltered
list on the same driver, launches from the executable's runtime-data directory,
and requires an asset preflight check before running. The original artifacts
remain retained for diagnosis, not merged into the corrected run.

## Completed discovery baseline

The corrected r2 campaign completed all 617 bulk shards and 2,198 isolated
reruns in 501.436 seconds. All 19,714 selected cases have a final classification:

| Status | Cases |
| --- | ---: |
| Pass | 9,978 |
| CompatibilityWarning | 1 |
| NotSupported | 4,714 |
| Fail | 4,373 |
| CrashOrMissing | 637 |
| ResourceError | 7 |
| InternalError | 4 |
| Timeout | 0 |

The 5,021 actionable results are failing cases, not 5,021 independent bugs.
NotSupported is recorded separately and still needs applicability review; it
does not establish that all required GL 4.6 features are implemented.

The consolidated inventory identifies repeated compiler ABI/type failures
(position, sample mask, layer), rejected SSBO ranges, constant-expression and
bitfield semantics, texture format/view/transfer assertions, and incomplete
geometry/tessellation execution. Repair shared causes against this baseline,
then requalify all cases on a newly fingerprinted candidate. Do not change
the retained baseline when verifying a fix.
