"""Primary-diagnostic normalization and occurrence-budget regressions."""

from collections import Counter
import importlib.util
from pathlib import Path
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
