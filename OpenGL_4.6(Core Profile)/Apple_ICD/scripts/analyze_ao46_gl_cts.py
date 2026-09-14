#!/usr/bin/env python3
"""Cluster an AO46 CTS run by feature, status, and diagnostic signature."""

from __future__ import annotations

import argparse
import html
import json
import re
from collections import Counter, defaultdict
from pathlib import Path


CASE_RE = re.compile(r"Test case '([^']+)'\.\.")
SIGNATURES = (
    re.compile(r"Assertion failed:.*"),
    re.compile(r"NIR validation failed.*"),
    re.compile(r"Failed to create MTLLibrary:.*"),
    re.compile(r"Unknown intrinsic \S+"),
    re.compile(r"Bad texture dim \d+"),
    re.compile(r".*(?:Pipeline creation error|failed assertion|incorrect type of texture|must be a multiple of).*"),
    re.compile(r"AO46[^\n]*(?:failed|rejected|unsupported)[^\n]*", re.I),
)


def log_signatures(results: dict[str, dict]) -> dict[str, set[str]]:
    signatures: dict[str, set[str]] = defaultdict(set)
    by_log: dict[Path, set[str]] = defaultdict(set)
    for case, record in results.items():
        if record["status"] not in {"Pass", "NotSupported"}:
            by_log[Path(record["log"])].add(case)
    for log, wanted in by_log.items():
        if not log.exists():
            continue
        text = log.read_text(encoding="utf-8", errors="replace")
        matches = list(CASE_RE.finditer(text))
        for index, match in enumerate(matches):
            case = match.group(1)
            if case not in wanted:
                continue
            end = matches[index + 1].start() if index + 1 < len(matches) else len(text)
            signature = signature_for(text[match.end():end])
            if signature:
                signatures[signature].add(case)
    return signatures


def qpa_failure_details(results: dict[str, dict]) -> dict[str, str]:
    """Keep a per-case semantic diagnostic even when stdout only says Fail."""
    details: dict[str, str] = {}
    by_qpa: dict[Path, set[str]] = defaultdict(set)
    for case, record in results.items():
        if record["status"] not in {"Pass", "NotSupported"}:
            by_qpa[Path(record["qpa"])].add(case)
    for path, wanted in by_qpa.items():
        if not path.exists():
            continue
        current = None
        with path.open(encoding="utf-8", errors="replace") as stream:
            for line in stream:
                if line.startswith("#beginTestCaseResult "):
                    current = line.split(maxsplit=1)[1].strip()
                elif line.startswith("#endTestCaseResult"):
                    current = None
                elif current in wanted and current not in details:
                    match = re.search(r"<Text>(.*?)</Text>", line)
                    if match:
                        message = html.unescape(match.group(1)).strip()
                        if len(message) < 600 and re.search(
                            r"\b(failed|failure|mismatch|incorrect|unexpected|invalid|expected)\b",
                            message, re.I,
                        ) and not message.startswith("gl"):
                            details[current] = message
    return details


def latest_results(path: Path) -> dict[str, dict]:
    latest: dict[str, dict] = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        try:
            record = json.loads(line)
        except json.JSONDecodeError:
            continue
        case = record.get("case")
        if case:
            latest[case] = record
    return latest


def signature_for(text: str) -> str | None:
    lines = text.splitlines()
    for index, line in enumerate(lines):
        for pattern in SIGNATURES:
            match = pattern.search(line)
            if match:
                signature = match.group(0).strip()
                # Metal prints the useful validation reason after a generic
                # assertion header. Do not collapse different contracts into
                # one "Draw Errors Validation" bucket.
                if re.search(r"failed assertion `[^`']*Validation$", signature):
                    reasons = []
                    for detail in lines[index + 1:index + 5]:
                        detail = detail.strip()
                        if not detail or detail == "'":
                            break
                        reasons.append(detail)
                    if reasons:
                        signature += ": " + " | ".join(reasons)
                return signature
    return None


def compare_results(baseline: dict[str, dict], candidate: dict[str, dict]) -> dict:
    if baseline.keys() != candidate.keys():
        raise ValueError("Comparison requires identical complete case inventories")
    actionable = {"Fail", "CrashOrMissing", "Timeout", "ResourceError", "InternalError"}
    transitions = Counter()
    changes = []
    fixed = []
    lost_passes = []
    for case in sorted(baseline):
        before = baseline[case]["status"]
        after = candidate[case]["status"]
        transitions[f"{before} -> {after}"] += 1
        if before != after:
            change = {"case": case, "before": before, "after": after}
            changes.append(change)
            if before in actionable and after == "Pass":
                fixed.append(case)
            if before == "Pass" and after != "Pass":
                lost_passes.append(change)
    return {"total": len(candidate), "transitions": dict(sorted(transitions.items())),
            "fixed_to_pass": fixed, "lost_passes": lost_passes, "changes": changes}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("run", type=Path)
    parser.add_argument("--baseline", type=Path,
                        help="Compare latest per-case results from an identical full inventory")
    args = parser.parse_args()
    run = args.run.resolve()
    results = latest_results(run / "results.jsonl")
    statuses = Counter(record["status"] for record in results.values())
    features: dict[str, Counter] = defaultdict(Counter)
    for case, record in results.items():
        parts = case.split(".")
        feature = parts[1] if len(parts) > 1 else parts[0]
        features[feature][record["status"]] += 1

    # Only associate a diagnostic with that case's latest attempt, not the
    # last case in a batch or a stale crash log from a successful rerun.
    signatures = log_signatures(results)
    details = qpa_failure_details(results)
    issues = [{"case": case, "status": record["status"],
               "detail": details.get(case), "log": record["log"], "qpa": record["qpa"]}
              for case, record in sorted(results.items())
              if record["status"] not in {"Pass", "NotSupported"}]
    (run / "issues.json").write_text(json.dumps(issues, indent=2) + "\n", encoding="utf-8")

    issue_records = [
        {"signature": signature, "count": len(cases), "cases": sorted(cases)}
        for signature, cases in sorted(
            signatures.items(), key=lambda item: (-len(item[1]), item[0])
        )
    ]
    (run / "issue-signatures.json").write_text(
        json.dumps(issue_records, indent=2) + "\n", encoding="utf-8"
    )

    lines = ["# AO46 GL CTS Report", "", f"Cases classified: {len(results)}", "", "## Status", ""]
    lines.extend(f"- {status}: {count}" for status, count in statuses.most_common())
    lines.extend(["", "## Largest Non-Passing Features", ""])
    ranked = []
    for feature, counts in features.items():
        nonpassing = sum(count for status, count in counts.items() if status not in {"Pass", "QualityWarning", "CompatibilityWarning", "NotSupported"})
        if nonpassing:
            ranked.append((nonpassing, feature, counts))
    for nonpassing, feature, counts in sorted(ranked, reverse=True)[:40]:
        detail = ", ".join(f"{key}={value}" for key, value in counts.most_common())
        lines.append(f"- {feature}: {nonpassing} non-passing ({detail})")
    lines.extend(["", "## Diagnostic Signatures", ""])
    lines.extend(
        f"- {item['count']} cases: `{item['signature']}`"
        for item in issue_records[:40]
    )
    if args.baseline:
        comparison = compare_results(latest_results(args.baseline / "results.jsonl"), results)
        (run / "comparison.json").write_text(
            json.dumps(comparison, indent=2) + "\n", encoding="utf-8")
        lines.extend(["", "## Baseline Comparison", "",
                      f"- Actionable cases now Pass: {len(comparison['fixed_to_pass'])}",
                      f"- Previous Pass results now non-Pass: {len(comparison['lost_passes'])}",
                      "- Case-level transitions are retained in `comparison.json`.", ""])
        lines.extend(f"- {transition}: {count}" for transition, count in
                     comparison["transitions"].items())
    (run / "report.md").write_text("\n".join(lines) + "\n", encoding="utf-8")
    print(run / "report.md")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
