"""Qualification-helper orchestration only; never run apps or device probes."""

import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
FAKE = r'''#!/usr/bin/env python3
import json, os, pathlib, sys
name = pathlib.Path(sys.argv[0]).name
with open(os.environ["QUAL_TEST_CALLS"], "a") as out:
    out.write(json.dumps([name, *sys.argv[1:]]) + "\n")
if name == "swift" and sys.argv[1:] == ["--version"]:
    print("Synthetic Swift tool version")
elif name == "swift":
    if not os.environ.get("QUAL_TEST_MISSING_MARKER"):
        print("\n".join("✓ " + p + " synthetic assertion" for p in ["2268", "2269", "2270", "2260", "2261", "2262", "2259", "2264", "2293", "2292"]))
        print("All tests passed")
    sys.exit(int(os.environ.get("QUAL_TEST_CORE_EXIT", "0")))
elif name == "git":
    if "rev-parse" in sys.argv: print("a" * 40)
elif name in ("sw_vers", "sysctl"):
    if os.environ.get("QUAL_TEST_METADATA_FAIL"): sys.exit(5)
    print("Synthetic machine metadata")
else:
    print("unexpected device-driving tool", file=sys.stderr)
    sys.exit(99)
'''


class QualificationScriptsTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="zephyr-qual-regression-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.scripts = self.root / "qual"
        shutil.copytree(ROOT / "Scripts/qual", self.scripts)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        fake = self.bin / "fake"
        fake.write_text(FAKE)
        fake.chmod(0o755)
        for name in ["swift", "git", "sw_vers", "sysctl", "osascript", "ps", "sleep", "open"]:
            (self.bin / name).symlink_to(fake)
        self.env = dict(os.environ, PATH=f"{self.bin}:{os.environ['PATH']}",
                        QUAL_REPORT_DIR=str(self.root / "reports"), QUAL_TEST_CALLS=str(self.root / "calls"))

    def run_script(self, name, *args, **env):
        result = subprocess.run(["bash", str(self.scripts / name), *args], cwd=self.root,
                                env=dict(self.env, **env), capture_output=True, text=True, timeout=15)
        reports = sorted((self.root / "reports").glob("*"))
        body = "\n".join(p.read_text() for p in reports if not p.name.endswith(".log"))
        calls_file = self.root / "calls"
        calls = [json.loads(line) for line in calls_file.read_text().splitlines()] if calls_file.exists() else []
        return result, body, calls

    def test_every_runbook_is_incomplete_and_never_drives_a_device(self):
        for script in sorted(self.scripts.glob("*.sh")):
            if script.name == "_common.sh":
                continue
            with self.subTest(script=script.name):
                result, body, calls = self.run_script(script.name)
                self.assertEqual(result.returncode, 2, result.stderr)
                self.assertIn("RESULT: INCOMPLETE", body)
                self.assertIn("[NOT RUN]", body)
                self.assertNotIn("[PASS]", body)
                self.assertNotIn("RESULT: PASS", body)
                self.assertFalse(any(c[0] in ("osascript", "ps", "sleep", "open") for c in calls))

    def test_core_failure_is_not_hidden_by_passing_output(self):
        result, body, _ = self.run_script("insertion_matrix.sh", QUAL_TEST_CORE_EXIT="7")
        self.assertEqual(result.returncode, 1)
        self.assertIn("Core command exit 7", body)
        self.assertIn("RESULT: FAIL", body)

    def test_missing_assertion_and_completion_markers_fail(self):
        result, body, _ = self.run_script("privacy_canary.sh", QUAL_TEST_MISSING_MARKER="1")
        self.assertEqual(result.returncode, 1)
        self.assertIn("completion marker missing", body)

    def test_metadata_failure_cannot_be_labeled_complete(self):
        result, body, _ = self.run_script("soak_1000.sh", QUAL_TEST_METADATA_FAIL="1")
        self.assertEqual(result.returncode, 1)
        self.assertIn("metadata command failed", body)

    def test_help_has_no_side_effects_and_documents_supported_arguments(self):
        for script in self.scripts.glob("*.sh"):
            if script.name == "_common.sh":
                continue
            result, body, calls = self.run_script(script.name, "--help")
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("Usage:", result.stdout)
            self.assertEqual(body, "")
            self.assertEqual(calls, [])

    def test_invalid_counts_and_unimplemented_flags_fail(self):
        for script, args in [("rapid_control_soak.sh", ["--minutes", "1"]), ("soak_1000.sh", ["0"]),
                             ("hardware_profile.sh", ["-1"]), ("focus_stress.sh", ["1", "extra"])]:
            result, body, _ = self.run_script(script, *args)
            self.assertEqual(result.returncode, 1)
            self.assertIn("RESULT: FAIL", body)

    def test_real_app_matrix_names_vs_code_not_mail(self):
        _, body, _ = self.run_script("insertion_matrix.sh")
        self.assertIn("Notes, TextEdit, Terminal, Safari, VS Code, Slack", body)
        self.assertNotIn("TextEdit, Mail", body)


if __name__ == "__main__":
    unittest.main()
