"""Static CI configuration checks, not a substitute for running GitHub CI."""

from pathlib import Path
import re
import subprocess
import unittest

import yaml

ROOT = Path(__file__).resolve().parents[2]


class WorkflowContractTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        # Preserve the YAML `on` key rather than interpreting it as a bool.
        cls.workflow = yaml.load((ROOT / ".github/workflows/ci.yml").read_text(), Loader=yaml.BaseLoader)
        cls.gates = cls.workflow["jobs"]["gates"]

    def test_gates_run_without_path_filters(self):
        self.assertIn("pull_request", self.workflow["on"])
        self.assertNotIn("if", self.gates)
        self.assertNotIn("paths", self.workflow["on"]["pull_request"] or {})
        self.assertNotIn("continue-on-error", self.gates)

    def test_setup_has_isolated_python_and_no_ignored_errors(self):
        setup = next(s for s in self.gates["steps"] if s["name"] == "Install isolated gate dependencies")
        body = setup["run"]
        self.assertIn('python -m venv "$RUNNER_TEMP/zephyr-gate-venv"', body)
        self.assertIn('"$gate_python" -m pip install -r Scripts/ci/requirements.txt', body)
        self.assertIn('"$gate_python" -m pip check', body)
        self.assertIn('"$gate_python" -m pip freeze', body)
        for step in self.gates["steps"]:
            self.assertNotIn("continue-on-error", step)
            if "run" in step:
                self.assertIn("set -euo pipefail", step["run"])
                self.assertNotIn("|| true", step["run"])
                self.assertNotIn("--break-system-packages", step["run"])

    def test_report_upload_is_unconditional_and_required(self):
        upload = next(s for s in self.gates["steps"] if "upload-artifact@" in s.get("uses", ""))
        self.assertEqual(upload["if"], "always()")
        self.assertEqual(upload["with"]["if-no-files-found"], "error")
        for suffix in ["*.log", "*.txt", "*.tsv", "coverage.*/"]:
            self.assertIn(suffix, upload["with"]["path"])
        self.assertIn("runner.temp", upload["with"]["path"])
        # runner context is valid in step inputs, but NOT job-level env.
        self.assertNotIn("runner.", str(self.gates.get("env", {})))
        prepare = next(s for s in self.gates["steps"] if s["name"] == "Prepare gate reports and verify Xcode")
        self.assertIn('export ZF_CI_REPORT_DIR="$RUNNER_TEMP/zephyr-gates"', prepare["run"])
        self.assertIn('echo "ZF_CI_REPORT_DIR=$ZF_CI_REPORT_DIR" >> "$GITHUB_ENV"', prepare["run"])
        install = next(s for s in self.gates["steps"] if s["name"] == "Install isolated gate dependencies")
        self.assertIn("for tool in shellcheck actionlint", install["run"])

    def test_gate_action_references_keep_commit_pins(self):
        for step in self.gates["steps"]:
            if "uses" in step:
                self.assertRegex(step["uses"], r"@[0-9a-f]{40}$")

    def test_actions_validator_rejects_original_context_error(self):
        fixture = """name: Context regression
on: push
jobs:
  gates:
    runs-on: macos-15
    env:
      ZF_CI_REPORT_DIR: ${{ runner.temp }}/zephyr-gates
    steps:
      - run: echo synthetic
"""
        result = subprocess.run(
            ["actionlint", "-shellcheck=", "-pyflakes=", "-"],
            input=fixture, text=True, capture_output=True, timeout=30,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('context "runner" is not allowed here', result.stdout + result.stderr)

    def test_direct_python_dependencies_have_exact_versions(self):
        requirements = (ROOT / "Scripts/ci/requirements.txt").read_text().splitlines()
        packages = {}
        for line in requirements:
            if not line or line.startswith(("#", "-r ")):
                continue
            self.assertTrue(re.fullmatch(r"[A-Za-z0-9_-]+==[0-9]+(?:\.[0-9]+)+", line), line)
            name, version = line.split("==")
            packages[name.lower()] = version
        self.assertTrue({"pyyaml", "mkdocs", "mkdocs-material", "mkdocs-minify-plugin",
                         "pymdown-extensions"}.issubset(packages))
