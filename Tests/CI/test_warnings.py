"""Primary-diagnostic normalization and occurrence-budget regressions."""

from collections import Counter
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("check_warnings", ROOT / "Scripts/ci/check_warnings.py")
warnings = importlib.util.module_from_spec(spec)
spec.loader.exec_module(warnings)


class WarningTests(unittest.TestCase):
    def test_checkout_directory_does_not_change_identity(self):
        for root in [Path("/runner/work/zephyr-flow"), Path("/worktrees/validation with spaces")]:
            with self.subTest(root=root):
                log = f"{root}/Sources/A.swift:3:4: warning: sample message [#Isolation]\n"
                self.assertEqual(
                    warnings.warnings_from_log(log, root),
                    Counter({"Sources/A.swift | [#Isolation] | sample message": 1}),
                )

    def test_child_rendering_is_not_an_additional_occurrence(self):
        log = """Sources/A.swift:1:2: warning: sample
  | `- warning: sample
 4 | // warning: sample
Sources/A.swift:8:2: warning: sample
"""
        self.assertEqual(warnings.warnings_from_log(log, ROOT), Counter({"Sources/A.swift | sample": 2}))

    def test_external_file_retains_identity(self):
        self.assertEqual(warnings.normalized_key("/external/A.swift", "sample", ROOT), "/external/A.swift | sample")

    def test_symlinked_checkout_root_has_the_same_identity(self):
        with tempfile.TemporaryDirectory(prefix="zephyr-warning-alias-") as directory:
            base = Path(directory).resolve()
            root = base / "checkout"
            root.mkdir()
            alias = base / "checkout alias"
            alias.symlink_to(root, target_is_directory=True)
            for reported, actual_root in [(alias, root), (root, alias)]:
                self.assertEqual(
                    warnings.normalized_key(str(reported / "Sources/A.swift"), "sample", actual_root),
                    "Sources/A.swift | sample",
                )
            external = base / "external/Sources/A.swift"
            self.assertEqual(warnings.normalized_key(str(external), "sample", root), f"{external} | sample")

    def test_unfamiliar_format_fails_as_new_diagnostic(self):
        actual = warnings.warnings_from_log("new format warning: sample", ROOT)
        self.assertEqual(actual, Counter({"unparsed | new format warning: sample": 1}))

    def test_package_warning_is_not_dropped(self):
        self.assertEqual(warnings.warnings_from_log("warning: sample", ROOT), Counter({"unknown | sample": 1}))

    def test_reductions_allowed_but_new_file_or_increase_fails(self):
        baseline = warnings.read_baseline("# reviewed\n 2 Sources/A.swift | sample   \n")
        self.assertFalse(Counter({"Sources/A.swift | sample": 1}) - baseline)
        self.assertTrue(Counter({"Sources/A.swift | sample": 3}) - baseline)
        self.assertTrue(Counter({"Sources/B.swift | sample": 1}) - baseline)

    def test_invalid_or_duplicate_baseline_is_rejected(self):
        for text in ["garbage", "0 Sources/A | sample", "-1 Sources/A | sample",
                     "1 missing separator", "1 Sources/A | sample\n2 Sources/A | sample"]:
            with self.subTest(text=text), self.assertRaises(ValueError):
                warnings.read_baseline(text)

    def test_checked_in_baseline_is_parseable(self):
        baseline = warnings.read_baseline(
            (ROOT / "docs/development/ci/strict-concurrency-warnings-baseline.txt").read_text()
        )
        self.assertTrue(baseline)

    def test_location_report_distinguishes_repeats_from_other_sites(self):
        root = Path("/checkout with spaces")
        log = f"""{root}/Sources/A.swift:3:4: warning: sample [#Isolation]
  | `- warning: sample [#Isolation]
{root}/Sources/A.swift:3:4: warning: sample [#Isolation]
{root}/Sources/A.swift:3:9: warning: sample [#Isolation]
{root}/Sources/A.swift:8:4: warning: sample [#Isolation]
{root}/Sources/B.swift:3:4: warning: sample [#Isolation]
"""
        report = warnings.location_report(log, root)
        self.assertEqual(report["primary_emissions"], 5)
        self.assertEqual(report["distinct_source_locations"], 4)
        self.assertEqual(report["unlocated_emissions"], 0)
        self.assertEqual(report["diagnostics"][0], {
            "key": "Sources/A.swift | [#Isolation] | sample", "emissions": 4,
            "locations": [{"line": 3, "column": 4, "emissions": 2},
                          {"line": 3, "column": 9, "emissions": 1},
                          {"line": 8, "column": 4, "emissions": 1}],
            "unlocated_emissions": 0,
        })
        self.assertEqual(report["diagnostics"][1]["key"], "Sources/B.swift | [#Isolation] | sample")
        # Repeated primary emissions are still charged to the existing budget.
        self.assertEqual(warnings.warnings_from_log(log, root)[report["diagnostics"][0]["key"]], 4)

    def test_location_report_does_not_drop_unlocated_warnings(self):
        report = warnings.location_report("warning: package warning\nnew format warning: unknown\n", ROOT)
        self.assertEqual(report["primary_emissions"], 2)
        self.assertEqual(report["distinct_source_locations"], 0)
        self.assertEqual(report["unlocated_emissions"], 2)
        self.assertTrue(all(item["locations"] == [] for item in report["diagnostics"]))
        self.assertEqual({item["key"] for item in report["diagnostics"]}, {
            "unknown | package warning", "unparsed | new format warning: unknown",
        })

    def test_location_report_does_not_merge_changed_diagnostic_ids_or_messages(self):
        log = """Sources/A.swift:3:4: warning: sample [#Isolation]
Sources/A.swift:3:4: warning: sample
Sources/A.swift:3:4: warning: different [#Isolation]
"""
        report = warnings.location_report(log, ROOT)
        self.assertEqual(report["primary_emissions"], 3)
        self.assertEqual(report["distinct_source_locations"], 1)
        self.assertEqual(len(report["diagnostics"]), 3)
        baseline = warnings.read_baseline("3 Sources/A.swift | [#Isolation] | sample\n")
        self.assertEqual(sum((warnings.warnings_from_log(log, ROOT) - baseline).values()), 2)

    def test_location_report_and_budget_failure_survive_cli(self):
        with tempfile.TemporaryDirectory(prefix="zephyr-warning-test-") as directory:
            root = Path(directory)
            log = root / "build.log"
            baseline = root / "baseline.txt"
            output = root / "warnings.txt"
            locations = root / "locations.json"
            baseline.write_text("1 Sources/A.swift | sample\n")
            log.write_text("Sources/A.swift:3:4: warning: sample\n" * 2)
            command = [sys.executable, str(ROOT / "Scripts/ci/check_warnings.py"),
                       "--root", str(root), "--build-log", str(log), "--baseline", str(baseline),
                       "--output", str(output), "--locations-output", str(locations)]
            result = subprocess.run(command, capture_output=True, text=True, timeout=10)
            self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
            self.assertIn("New warning occurrences", result.stdout)
            self.assertEqual(output.read_text(), "2 Sources/A.swift | sample\n")
            report = json.loads(locations.read_text())
            self.assertEqual(report["primary_emissions"], 2)
            self.assertEqual(report["distinct_source_locations"], 1)

            # A requested evidence write failure must also fail with zero warnings.
            log.write_text("")
            locations.unlink()
            locations.mkdir()
            result = subprocess.run(command, capture_output=True, text=True, timeout=10)
            self.assertEqual(result.returncode, 1)
            self.assertIn("warning comparison failed", result.stderr)
