"""Regression coverage for CTS discovery bookkeeping, without GPU execution."""

import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import subprocess

import run_ao46_gl_cts as runner
import analyze_ao46_gl_cts as analyzer


class CTSBookkeepingTests(unittest.TestCase):
    def test_metal_validation_keeps_the_actual_contract_reason(self):
        header = "-[Encoder validate]:42: failed assertion `Draw Errors Validation\n"
        texture = header + "incorrect type of texture at binding 0\n'\n"
        layers = header + "renderTargetArrayLength is set to zero\n'\n"
        self.assertNotEqual(analyzer.signature_for(texture), analyzer.signature_for(layers))
        self.assertIn("incorrect type of texture", analyzer.signature_for(texture))
        self.assertIn("renderTargetArrayLength", analyzer.signature_for(layers))
        self.assertEqual(analyzer.signature_for("Assertion failed: ordinary\nextra\n"),
                         "Assertion failed: ordinary")

    def test_comparison_does_not_call_unsupported_or_crash_conversion_fixed(self):
        before = {case: {"status": status} for case, status in
                  [("A", "Fail"), ("B", "Pass"), ("C", "NotSupported"),
                   ("D", "CrashOrMissing")]}
        after = {case: {"status": status} for case, status in
                 [("A", "Pass"), ("B", "NotSupported"), ("C", "Pass"),
                  ("D", "Fail")]}
        comparison = analyzer.compare_results(before, after)
        self.assertEqual(comparison["fixed_to_pass"], ["A"])
        self.assertEqual(comparison["lost_passes"],
                         [{"case": "B", "before": "Pass", "after": "NotSupported"}])
        with self.assertRaises(ValueError):
            analyzer.compare_results(before, {"A": {"status": "Pass"}})

    def test_worker_uses_cts_asset_directory(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "qpa").mkdir()
            (root / "logs").mkdir()
            config = runner.Config(root / "runtime/glcts", root,
                                   root / "framework/Versions/A/OpenGL", 1, 10, 0, 64, 64, True)
            with patch.object(runner.subprocess, "run", return_value=
                              subprocess.CompletedProcess([], 1, stdout="")) as run:
                runner.run_shard(config, 0, ["GL.case"], 0)
            self.assertEqual(run.call_args.kwargs["cwd"], root / "runtime")

    def test_diagnostics_follow_case_and_latest_attempt(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "batch.log"
            path.write_text("Test case 'A'..\nAssertion failed: A\n"
                            "Test case 'B'..\nAssertion failed: B\n"
                            "Test case 'C'..\nPass\n")
            results = {case: {"status": status, "log": str(path)} for case, status in
                       [("A", "Pass"), ("B", "Fail"), ("C", "Pass")]}
            self.assertEqual(analyzer.log_signatures(results), {"Assertion failed: B": {"B"}})

    def test_selection_is_unfiltered_and_unique(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "cases.txt"
            path.write_text("# comment\nA.first\nB.second\nA.first\n")
            self.assertEqual(runner.read_cases(path, []), ["A.first", "B.second"])

    def test_resume_uses_latest_and_retries_incomplete(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "results.jsonl"
            records = [
                {"case": "A", "status": "Pass"},
                {"case": "A", "status": "Fail"},
                {"case": "B", "status": "CrashOrMissing"},
                {"case": "C", "status": "NotSupported"},
            ]
            path.write_text("\n".join(json.dumps(r) for r in records))
            self.assertEqual(runner.completed_cases(path, True), set())
            self.assertEqual(runner.completed_cases(path, False), {"A", "C"})

    def test_summary_separates_unsupported_and_warnings(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory)
            final = {f"GL.feature.{i}": {"status": status} for i, status in
                     enumerate(["Pass", "Fail", "NotSupported", "QualityWarning", "Timeout"])}
            runner.write_summary(path, final, 1)
            summary = json.loads((path / "summary.json").read_text())
            self.assertEqual(summary["actionable"], 2)
            self.assertEqual(summary["unsupported"], 1)
            self.assertEqual(summary["warnings"], 1)
            self.assertEqual((path / "failures.txt").read_text(), "GL.feature.1\n")
            self.assertEqual((path / "unsupported.txt").read_text(), "GL.feature.2\n")

    def test_partial_qpa_preserves_completed_cases(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "test.qpa"
            path.write_text('#beginTestCaseResult A\n<Result StatusCode="Pass">ok</Result>\n'
                            '#endTestCaseResult\n#beginTestCaseResult B\n')
            self.assertEqual(runner.parse_qpa(path), {"A": "Pass"})


if __name__ == "__main__":
    unittest.main()
