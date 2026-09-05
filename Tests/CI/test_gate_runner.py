"""Run the real shell runner with fake tools in an isolated throwaway repo."""

import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


class GateRunnerTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="zephyr-gate-test-")
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        self.repo = self.base / "checkout with spaces"
        self.repo.mkdir()
        self.report = self.base / "reports"
        self.products = self.base / "products"
        self.products.mkdir()
        self.bin = self.base / "tools"
        self.bin.mkdir()
        for name in ["Scripts/ci_checks.sh", "Scripts/ci/check_warnings.py"]:
            target = self.repo / name
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(ROOT / name, target)
        files = {
            "README.md": "fixture only",
            "VERSION": "0.1.0\n",
            "Sources/ZephyrFlow/Utilities/Constants.swift": 'static let version = "0.1.0"',
            "Sources/ZephyrFlowCore/Fixture.swift": "// synthetic fixture",
            "Resources/Info.plist": "<string>0.1.0</string>",
            "CHANGELOG.md": "## [0.1.0]\n",
            "docs/development/ci/strict-concurrency-warnings-baseline.txt": "# empty fixture baseline\n",
            ".github/workflows/ci.yml": "name: fixture\n",
            "Tests/CI/test_fixture.py": (
                "import unittest\nclass FixtureTests(unittest.TestCase):\n"
                "    def test_fixture(self): self.assertTrue(True)\n"
            ),
            ".gitignore": "__pycache__/\n",
        }
        for name, text in files.items():
            target = self.repo / name
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text(text)
        helper = (ROOT / "Tests/CI/fake_gate_tool.py").read_text().split("\n", 1)[1]
        for tool in ["swift", "xcrun", "xcodebuild", "python3", "shellcheck", "mkdocs"]:
            target = self.bin / tool
            target.write_text(f"#!{sys.executable}\n{helper}")
            target.chmod(0o755)
        clt = self.products / "ZephyrFlowCoreTests"
        clt.write_text(f"#!{sys.executable}\n{helper}")
        clt.chmod(0o755)
        self.env = {**os.environ, "PATH": f"{self.bin}:/usr/bin:/bin", "CI": "true",
                    "ZF_CI_REPORT_DIR": str(self.report), "ZF_TEST_ROOT": str(self.repo),
                    "ZF_TEST_PRODUCTS": str(self.products), "PYTHONDONTWRITEBYTECODE": "1"}
        # Never inherit a caller's alternate git index/worktree or hooks.
        for key in list(self.env):
            if key.startswith("GIT_") or key == "LLVM_PROFILE_FILE":
                del self.env[key]
        self.git("init", "-q")
        self.git("add", ".")
        self.git("-c", "user.name=CI Fixture", "-c", "user.email=fixture@example.invalid",
                 "-c", "commit.gpgsign=false", "-c", "core.hooksPath=/dev/null", "commit", "-qm", "fixture")

    def git(self, *args):
        return subprocess.run(["/usr/bin/git", *args], cwd=self.repo, env=self.env, check=True, capture_output=True)

    def run_gate(self, mode=""):
        return subprocess.run(["/bin/bash", "Scripts/ci_checks.sh"], cwd=self.repo,
                              env={**self.env, "ZF_TEST_FAILURE": mode},
                              text=True, capture_output=True, timeout=40)

    def test_happy_path_keeps_complete_reports(self):
        result = self.run_gate()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("ALL GATES PASSED", result.stdout)
        for name in ["xctest", "xctest-discovery", "core", "strict-build", "strict-warnings",
                     "format", "docs", "coverage-tests", "coverage-core", "coverage-report", "asan", "stress"]:
            self.assertTrue((self.report / f"{name}.log").exists(), name)
        self.assertIn("exit_code=0", (self.report / "result.txt").read_text())

    def test_missing_required_tool_fails_preflight(self):
        (self.bin / "mkdocs").unlink()
        result = self.run_gate()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("missing required tool: mkdocs", result.stdout)

    def test_failures_cannot_be_hidden_by_success_shaped_output(self):
        modes = ["no-xctest", "no-pyyaml", "xctest", "discovery", "missing-suite", "zero-executed",
                 "core", "clean", "strict-build", "new-warning", "format", "strings", "shellcheck", "yaml",
                 "regressions", "docs", "bin-path", "coverage-tests", "coverage-core", "missing-clt-profile",
                 "missing-xctest-profile", "coverage-merge", "coverage-report", "coverage-low",
                 "coverage-invalid", "coverage-high", "coverage-empty", "asan", "stress", "stress-missing-marker"]
        for mode in modes:
            with self.subTest(mode=mode):
                # No stale synthetic measurements may influence the next case.
                for directory in [self.report, self.products / "codecov"]:
                    if directory.exists():
                        shutil.rmtree(directory)
                result = self.run_gate(mode)
                self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertNotIn("ALL GATES PASSED", result.stdout)
                self.assertIn("exit_code=1", (self.report / "result.txt").read_text())

    def assert_drift_rejected(self, mode):
        result = self.run_gate(mode)
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("drift after gates", result.stdout)

    def test_final_check_includes_untracked_drift(self):
        self.assert_drift_rejected("drift-untracked")

    def test_final_check_includes_tracked_drift(self):
        self.assert_drift_rejected("drift-tracked")

    def test_final_check_includes_staged_drift(self):
        self.assert_drift_rejected("drift-staged")
