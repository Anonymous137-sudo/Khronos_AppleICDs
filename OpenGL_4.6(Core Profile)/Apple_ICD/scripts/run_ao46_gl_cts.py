#!/usr/bin/env python3
"""Run OpenGL CTS safely in bounded asynchronous shards."""

from __future__ import annotations

import argparse
import concurrent.futures
import fnmatch
import hashlib
import json
import os
import re
import subprocess
import tempfile
import time
from dataclasses import dataclass
from pathlib import Path


RESULT_RE = re.compile(r'<Result StatusCode="([^"]+)">')
BEGIN_RE = re.compile(r"#beginTestCaseResult\s+(\S+)")
END_RE = re.compile(r"#endTestCaseResult")
PASS_STATUSES = {"Pass", "QualityWarning", "CompatibilityWarning"}


@dataclass(frozen=True)
class Config:
    binary: Path
    output: Path
    framework: Path
    workers: int
    timeout: int
    retries: int
    surface_width: int
    surface_height: int
    debug_layer: bool


def read_cases(path: Path, patterns: list[str]) -> list[str]:
    cases = []
    for raw in path.read_text(encoding="utf-8").splitlines():
        case = raw.strip()
        if not case or case.startswith("#"):
            continue
        if not patterns or any(fnmatch.fnmatchcase(case, pattern) for pattern in patterns):
            cases.append(case)
    return list(dict.fromkeys(cases))


def parse_qpa(path: Path) -> dict[str, str]:
    results: dict[str, str] = {}
    current: str | None = None
    if not path.exists():
        return results
    for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        begin = BEGIN_RE.search(line)
        if begin:
            current = begin.group(1)
            continue
        if current:
            result = RESULT_RE.search(line)
            if result:
                results[current] = result.group(1)
            if END_RE.search(line):
                current = None
    return results


def safe_name(index: int) -> str:
    return f"shard-{index:06d}"


def decoded_output(value: str | bytes | None) -> str:
    if value is None:
        return ""
    if isinstance(value, bytes):
        return value.decode("utf-8", errors="replace")
    return value


def run_shard(config: Config, index: int, cases: list[str], attempt: int) -> dict:
    stem = f"{safe_name(index)}-try{attempt}"
    qpa = config.output / "qpa" / f"{stem}.qpa"
    stdout = config.output / "logs" / f"{stem}.log"
    started = time.monotonic()
    timed_out = False

    with tempfile.NamedTemporaryFile("w", encoding="utf-8", suffix=".txt", delete=False) as handle:
        handle.write("\n".join(cases) + "\n")
        case_file = Path(handle.name)

    env = os.environ.copy()
    env.update({
        "AO46_FRAMEWORK_PATH": str(config.framework),
        "DYLD_FRAMEWORK_PATH": str(config.framework.parents[3]),
        "DYLD_LIBRARY_PATH": str(config.framework.parents[3]),
        "MTL_DEBUG_LAYER": "1" if config.debug_layer else "0",
    })
    command = [
        str(config.binary),
        f"--deqp-caselist-file={case_file}",
        "--deqp-gl-context-type=cgl",
        "--deqp-surface-type=fbo",
        f"--deqp-surface-width={config.surface_width}",
        f"--deqp-surface-height={config.surface_height}",
        "--deqp-log-images=disable",
        f"--deqp-log-filename={qpa}",
    ]
    try:
        completed = subprocess.run(
            command, env=env, text=True, stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT, timeout=config.timeout, check=False,
            cwd=config.binary.parent,
        )
        returncode = completed.returncode
        output = completed.stdout
    except subprocess.TimeoutExpired as error:
        timed_out = True
        returncode = 124
        output = decoded_output(error.stdout) + "\nAO46 CTS shard timed out\n"
    finally:
        case_file.unlink(missing_ok=True)

    stdout.write_text(output, encoding="utf-8")
    observed = parse_qpa(qpa)
    results = []
    for case in cases:
        status = observed.get(case)
        if status is None:
            status = "Timeout" if timed_out else "CrashOrMissing"
        results.append({
            "case": case,
            "status": status,
            "returncode": returncode,
            "seconds": round(time.monotonic() - started, 3),
            "attempt": attempt,
            "qpa": str(qpa),
            "log": str(stdout),
        })
    return {
        "index": index,
        "attempt": attempt,
        "returncode": returncode,
        "seconds": round(time.monotonic() - started, 3),
        "qpa": str(qpa),
        "log": str(stdout),
        "results": results,
    }


def completed_cases(results_file: Path, passing_only: bool) -> set[str]:
    latest: dict[str, str] = {}
    if not results_file.exists():
        return set()
    for line in results_file.read_text(encoding="utf-8").splitlines():
        try:
            record = json.loads(line)
        except json.JSONDecodeError:
            continue
        latest[record.get("case", "")] = record.get("status", "")
    return {case for case, status in latest.items() if case and
            (status in PASS_STATUSES if passing_only else
             status not in {"CrashOrMissing", "Timeout"})}


def latest_results(results_file: Path, selected: set[str]) -> dict[str, dict]:
    latest: dict[str, dict] = {}
    if not results_file.exists():
        return latest
    for line in results_file.read_text(encoding="utf-8").splitlines():
        try:
            record = json.loads(line)
        except json.JSONDecodeError:
            continue
        case = record.get("case")
        if case in selected:
            latest[case] = record
    return latest


def run_isolated_case(config: Config, index: int, case: str) -> dict:
    result = None
    for attempt in range(1, config.retries + 2):
        result = run_shard(config, index, [case], attempt)
        if result["results"][0]["status"] not in {"CrashOrMissing", "Timeout"}:
            break
    return result


def write_summary(output: Path, final: dict[str, dict], elapsed: float) -> None:
    counts: dict[str, int] = {}
    for result in final.values():
        counts[result["status"]] = counts.get(result["status"], 0) + 1
    summary = {
        "total": len(final),
        "passed": sum(counts.get(status, 0) for status in PASS_STATUSES),
        "failed": len(final) - sum(counts.get(status, 0) for status in PASS_STATUSES),
        "statuses": dict(sorted(counts.items())),
        "unsupported": counts.get("NotSupported", 0),
        "warnings": sum(counts.get(status, 0) for status in
                        {"QualityWarning", "CompatibilityWarning"}),
        "actionable": sum(count for status, count in counts.items()
                          if status not in PASS_STATUSES | {"NotSupported"}),
        "elapsed_seconds": round(elapsed, 3),
    }
    (output / "summary.json").write_text(json.dumps(summary, indent=2) + "\n", encoding="utf-8")
    feature_matrix: dict[str, dict[str, int]] = {}
    for case, result in final.items():
        parts = case.split(".")
        feature = parts[1] if len(parts) > 1 else parts[0]
        statuses = feature_matrix.setdefault(feature, {})
        status = result["status"]
        statuses[status] = statuses.get(status, 0) + 1
    (output / "feature-matrix.json").write_text(
        json.dumps(dict(sorted(feature_matrix.items())), indent=2) + "\n",
        encoding="utf-8",
    )
    for filename, predicate in (
        ("failures.txt", lambda status: status not in PASS_STATUSES | {"NotSupported", "CrashOrMissing", "Timeout"}),
        ("crashes.txt", lambda status: status in {"CrashOrMissing", "Timeout"}),
        ("unsupported.txt", lambda status: status == "NotSupported"),
        ("warnings.txt", lambda status: status in {"QualityWarning", "CompatibilityWarning"}),
    ):
        selected = sorted(case for case, result in final.items() if predicate(result["status"]))
        (output / filename).write_text("\n".join(selected) + ("\n" if selected else ""), encoding="utf-8")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, required=True)
    parser.add_argument("--case-list", type=Path, required=True)
    parser.add_argument("--framework", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--pattern", action="append", default=[])
    parser.add_argument("--workers", type=int, default=2)
    parser.add_argument("--batch-size", type=int, default=16)
    parser.add_argument("--timeout", type=int, default=300)
    parser.add_argument("--retries", type=int, default=1)
    parser.add_argument("--surface-width", type=int, default=64)
    parser.add_argument("--surface-height", type=int, default=64)
    parser.add_argument("--debug-layer", action="store_true")
    parser.add_argument("--resume", action="store_true")
    parser.add_argument("--resume-classified", action="store_true")
    args = parser.parse_args()

    if not 1 <= args.workers <= 8:
        parser.error("--workers must be between 1 and 8")
    if not 1 <= args.batch_size <= 256:
        parser.error("--batch-size must be between 1 and 256")
    if args.timeout < 10 or args.retries < 0:
        parser.error("timeout/retry values are invalid")
    if args.resume and args.resume_classified:
        parser.error("choose either --resume or --resume-classified")

    config = Config(
        binary=args.binary.resolve(), output=args.output.resolve(),
        framework=args.framework.resolve(), workers=args.workers,
        timeout=args.timeout, retries=args.retries,
        surface_width=args.surface_width, surface_height=args.surface_height,
        debug_layer=args.debug_layer,
    )
    if not config.binary.is_file() or not config.framework.is_file():
        parser.error("CTS binary or AO46 framework does not exist")
    if not (config.binary.parent / "gl_cts/data/gl33/preprocessor.test").is_file():
        parser.error("CTS runtime data is missing beside glcts; build/install the CTS data target")
    config.output.mkdir(parents=True, exist_ok=True)
    (config.output / "qpa").mkdir(exist_ok=True)
    (config.output / "logs").mkdir(exist_ok=True)
    results_file = config.output / "results.jsonl"
    if results_file.exists() and not (args.resume or args.resume_classified):
        parser.error("output already contains results; use a fresh directory or explicit resume")
    selected_cases = read_cases(args.case_list.resolve(), args.pattern)
    # Each invocation has unique artifact names, including an interrupted resume.
    shard_offset = max((int(p.stem.split('-')[1]) + 1
                        for p in (config.output / "logs").glob("shard-*-try*.log")),
                       default=0)
    def fingerprint(path: Path) -> str:
        digest = hashlib.sha256()
        with path.open("rb") as stream:
            for block in iter(lambda: stream.read(1024 * 1024), b""):
                digest.update(block)
        return digest.hexdigest()
    manifest = {
        "selected": len(selected_cases), "workers": config.workers,
        "batch_size": args.batch_size, "timeout": config.timeout,
        "debug_layer": config.debug_layer, "patterns": args.pattern,
        "binary_sha256": fingerprint(config.binary),
        "asset_preflight": "gl_cts/data/gl33/preprocessor.test",
        "asset_sha256": fingerprint(config.binary.parent / "gl_cts/data/gl33/preprocessor.test"),
        "framework_sha256": fingerprint(config.framework),
        "case_list_sha256": fingerprint(args.case_list.resolve()),
        "runtime_dylibs": {p.name: fingerprint(p) for p in
                           sorted(config.framework.parents[3].glob("*.dylib"))
                           if p.is_file() and not p.is_symlink()},
    }
    (config.output / f"manifest-{shard_offset:06d}.json").write_text(
        json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    (config.output / "selected-cases.txt").write_text(
        "\n".join(selected_cases) + "\n", encoding="utf-8")
    cases = selected_cases
    if args.resume or args.resume_classified:
        done = completed_cases(results_file, passing_only=args.resume)
        cases = [case for case in cases if case not in done]
    if not cases:
        print("No CTS cases selected.")
        return 0

    shards = [cases[i:i + args.batch_size] for i in range(0, len(cases), args.batch_size)]
    final = latest_results(results_file, set(selected_cases))
    crashed: list[str] = []
    started = time.monotonic()
    print(f"AO46 CTS: {len(cases)} cases, {len(shards)} shards, {config.workers} workers")

    with results_file.open("a", encoding="utf-8") as handle:
        def checkpoint(item: dict) -> None:
            final[item["case"]] = item
            handle.write(json.dumps(item, sort_keys=True) + "\n")
            handle.flush()

        with concurrent.futures.ThreadPoolExecutor(max_workers=config.workers) as pool:
            futures = {
                pool.submit(run_shard, config, shard_offset + i, shard, 0): (i, shard)
                for i, shard in enumerate(shards)
            }
            for future in concurrent.futures.as_completed(futures):
                shard = future.result()
                for item in shard["results"]:
                    checkpoint(item)
                    if item["status"] in {"CrashOrMissing", "Timeout"}:
                        crashed.append(item["case"])
                classified = len(final)
                write_summary(config.output, final, time.monotonic() - started)
                print(
                    f"[{classified:>6}/{len(cases)}] shard {shard['index']:>5} "
                    f"rc={shard['returncode']} {shard['seconds']:.1f}s",
                    flush=True,
                )

        if crashed:
            print(f"Isolating {len(crashed)} crash/missing cases across {config.workers} workers")
            with concurrent.futures.ThreadPoolExecutor(max_workers=config.workers) as pool:
                futures = {
                    pool.submit(
                        run_isolated_case, config, shard_offset + len(shards) + index,
                        case,
                    ): case
                    for index, case in enumerate(crashed)
                }
                for completed, future in enumerate(
                    concurrent.futures.as_completed(futures), 1
                ):
                    result = future.result()
                    checkpoint(result["results"][0])
                    if completed % 32 == 0 or completed == len(crashed):
                        write_summary(config.output, final, time.monotonic() - started)
                        print(
                            f"[isolation {completed:>6}/{len(crashed)}]",
                            flush=True,
                        )

    complete = latest_results(results_file, set(selected_cases))
    write_summary(config.output, complete, time.monotonic() - started)
    print((config.output / "summary.json").read_text(encoding="utf-8"), end="")
    return 0 if (len(complete) == len(selected_cases) and
                 all(result["status"] in PASS_STATUSES
                     for result in complete.values())) else 1


if __name__ == "__main__":
    raise SystemExit(main())
