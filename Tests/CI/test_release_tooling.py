"""Synthetic orchestration only: no Apple tools, credentials, network or release."""
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import struct
import subprocess
import sys
import tempfile
import unittest

import yaml

ROOT = Path(__file__).resolve().parents[2]
FAKE = r'''
import json,os,pathlib,shutil,sys
name=pathlib.Path(sys.argv[0]).name
args=sys.argv[1:]
log=pathlib.Path(os.environ['FAKE_LOG'])
calls=json.loads(log.read_text()) if log.exists() else []
calls.append([name,*args]); log.write_text(json.dumps(calls))
if len(calls)==int(os.environ.get('FAIL_AT','0')): sys.exit(17)
if name=='ditto':
    if args[0]=='-c':
        app=pathlib.Path(args[-2]); pathlib.Path(args[-1]).write_bytes(
            b'synthetic-stapled' if (app/'.synthetic-stapled').exists() else b'synthetic-submission')
    else: shutil.copytree(args[0],args[1])
elif name=='codesign' and '--display' in args:
    print('Identifier=dev.zephyrflow.app',file=sys.stderr)
    print('TeamIdentifier='+os.environ.get('SIGN_TEAM','ABCDEFGHIJ'),file=sys.stderr)
    print('Authority='+os.environ.get('SIGN_AUTHORITY','Developer ID Application: Synthetic'),file=sys.stderr)
    print('CodeDirectory v=20500 size=1 flags='+os.environ.get('SIGN_FLAGS','0x10000(runtime)'),file=sys.stderr)
elif name=='xcrun':
    if args[:2]==['notarytool','submit']:
        print(os.environ.get('NOTARY_JSON','{"status":"Accepted","id":"aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"}'))
    elif args[:2]==['stapler','staple']:
        (pathlib.Path(args[-1])/'.synthetic-stapled').write_text('synthetic')
    elif args[:2]==['stapler','validate']:
        assert (pathlib.Path(args[-1])/'.synthetic-stapled').exists()
'''


class ReleaseToolingTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="zephyr-release-test-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.repo = self.root / "repo"
        (self.repo / "Scripts/release").mkdir(parents=True)
        (self.repo / "Resources").mkdir()
        for name in ["notarize.sh", "validate_bundle.py", "supply-chain.sh", "acceptance_gate.sh"]:
            shutil.copyfile(ROOT / "Scripts/release" / name, self.repo / "Scripts/release" / name)
        (self.repo / "VERSION").write_text("0.1.0\n")
        (self.repo / "Resources/ZephyrFlow.entitlements").write_bytes(plistlib.dumps({}))
        self.app = self.root / "Input.app"
        (self.app / "Contents/MacOS").mkdir(parents=True)
        self.info = {"CFBundleIdentifier": "dev.zephyrflow.app", "CFBundleExecutable": "ZephyrFlow",
                     "CFBundleShortVersionString": "0.1.0", "CFBundleVersion": "0.1.0"}
        self.write_info()
        main = self.app / "Contents/MacOS/ZephyrFlow"
        main.write_bytes(struct.pack("<8I", 0xFEEDFACF, 0x0100000C, 0, 2, 0, 0, 0, 0) + b"SYNTHETIC_NOT_EXECUTABLE")
        main.chmod(0o700)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        for name in ["codesign", "ditto", "xcrun", "spctl"]:
            tool = self.bin / name
            tool.write_text("#!" + sys.executable + "\n" + FAKE)
            tool.chmod(0o700)
        self.log = self.root / "calls.json"
        self.env = dict(os.environ, PATH=str(self.bin) + os.pathsep + os.environ["PATH"], FAKE_LOG=str(self.log))
        self.output = self.root / "output"

    def write_info(self):
        (self.app / "Contents/Info.plist").write_bytes(plistlib.dumps(self.info))

    def run_script(self, script, args=(), env=None):
        return subprocess.run(["bash", str(self.repo / "Scripts/release" / script), *args],
                              env=env or self.env, text=True, capture_output=True, timeout=20)

    def run_notary(self, **environment):
        return self.run_script("notarize.sh", ["--run", "--app", str(self.app), "--identity", "a" * 40,
                              "--team", "ABCDEFGHIJ", "--profile", "synthetic-reference-only",
                              "--output", str(self.output)], dict(self.env, **environment))

    def calls(self):
        return json.loads(self.log.read_text()) if self.log.exists() else []

    def test_help_plan_and_invalid_modes_never_call_native_tools(self):
        for script in ["notarize.sh", "supply-chain.sh"]:
            self.assertEqual(self.run_script(script, ["--help"]).returncode, 0)
            for args in [[], ["--dry-run"]]:
                result = self.run_script(script, args)
                self.assertEqual(result.returncode, 2)
                self.assertIn("NOT RUN", result.stdout)
            for args in [["--unknown"], ["--dry-run", "ignored"], ["--run"]]:
                self.assertNotEqual(self.run_script(script, args).returncode, 0)
        self.assertEqual(self.calls(), [])

    def test_acceptance_gate_has_no_override_flag_or_environment_bypass(self):
        for args in [[], ["--run"], ["--approved"], ["--go", "true"]]:
            result = self.run_script("acceptance_gate.sh", args, dict(self.env, HUMAN_GO="true", RELEASE_APPROVED="true"))
            self.assertEqual(result.returncode, 1)
            self.assertIn("RELEASE BLOCKED", result.stderr)
        self.assertEqual(self.calls(), [])

    def test_synthetic_success_packages_post_staple_copy_and_never_changes_input(self):
        result = self.run_notary()
        self.assertEqual(result.returncode, 0, result.stderr)
        calls = self.calls()
        self.assertEqual([c[0] for c in calls], ["ditto", "codesign", "codesign", "codesign", "ditto",
                                              "xcrun", "xcrun", "xcrun", "codesign", "spctl", "ditto"])
        self.assertIn("--timestamp", calls[1])
        self.assertNotIn("--deep", calls[1], "do not recursively guess signing order")
        self.assertIn("--keychain-profile", calls[5])
        self.assertFalse((self.app / ".synthetic-stapled").exists())
        self.assertTrue((self.output / "ZephyrFlow.app/.synthetic-stapled").exists())
        artifact = self.output / "ZephyrFlow-macos-arm64.app.zip"
        self.assertEqual(artifact.read_bytes(), b"synthetic-stapled")
        self.assertIn(hashlib.sha256(artifact.read_bytes()).hexdigest(), (self.output / "SHA256SUMS").read_text())
        self.assertIn("PRODUCTION ACCEPTANCE NOT ESTABLISHED", (self.output / "result.txt").read_text())
        self.assertEqual(self.output.stat().st_mode & 0o777, 0o700)

    def test_every_native_failure_stops_pipeline_and_keeps_incomplete_marker(self):
        for index in range(1, 12):
            with self.subTest(index=index):
                self.output = self.root / f"failed-{index}"
                self.log = self.root / f"failed-{index}.json"
                result = self.run_notary(FAIL_AT=str(index), FAKE_LOG=str(self.log))
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(len(self.calls()), index)
                self.assertIn("INCOMPLETE", (self.output / "result.txt").read_text())
                self.assertFalse((self.output / "SHA256SUMS").exists())

    def test_rejected_malformed_and_in_progress_notary_results_never_staple(self):
        for index, response in enumerate(["not json", "{}", '{"status":"Invalid"}',
                                           '{"status":"In Progress"}', '{"status":"Accepted","id":"invalid"}']):
            with self.subTest(response=response):
                self.output = self.root / f"notary-{index}"
                self.log = self.root / f"notary-{index}.json"
                result = self.run_notary(NOTARY_JSON=response, FAKE_LOG=str(self.log))
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse(any(c[1:3] == ["stapler", "staple"] for c in self.calls()))

    def test_wrong_team_adhoc_or_missing_runtime_never_submits(self):
        for index, env in enumerate([{"SIGN_TEAM": "WRONGTEAM1"}, {"SIGN_AUTHORITY": "adhoc"}, {"SIGN_FLAGS": "0x0(none)"}]):
            self.output = self.root / f"signature-{index}"
            self.log = self.root / f"signature-{index}.json"
            result = self.run_notary(**env, FAKE_LOG=str(self.log), PYTHONOPTIMIZE="1")
            self.assertNotEqual(result.returncode, 0)
            self.assertFalse(any(c[0] == "xcrun" for c in self.calls()))

    def test_bundle_identity_version_symlink_and_nested_code_fail_before_copy(self):
        self.info["CFBundleIdentifier"] = "foreign.app"
        self.write_info()
        self.assertNotEqual(self.run_notary().returncode, 0)
        self.info["CFBundleIdentifier"] = "dev.zephyrflow.app"
        self.info["CFBundleVersion"] = "0.0.0"
        self.write_info()
        self.assertNotEqual(self.run_notary().returncode, 0)
        self.info["CFBundleVersion"] = "0.1.0"
        self.write_info()
        link = self.app / "Contents/link"
        link.symlink_to(self.root / "missing")
        self.assertNotEqual(self.run_notary().returncode, 0)
        link.unlink()
        (self.app / "Contents/nested.dylib").write_bytes(b"\xcf\xfa\xed\xfeSYNTHETIC")
        self.assertNotEqual(self.run_notary().returncode, 0)
        self.assertEqual(self.calls(), [])
        self.assertFalse(self.output.exists())

    def test_existing_output_is_not_overwritten(self):
        self.output.mkdir()
        (self.output / "user-work").write_text("preserve")
        self.assertNotEqual(self.run_notary().returncode, 0)
        self.assertEqual((self.output / "user-work").read_text(), "preserve")
        self.assertEqual(self.calls(), [])

    def test_output_inside_input_and_wrong_architecture_fail_before_copy(self):
        self.output = self.app / "nested-output"
        self.assertNotEqual(self.run_notary().returncode, 0)
        self.assertFalse(self.output.exists())
        self.output = self.root / "output"
        (self.app / "Contents/MacOS/ZephyrFlow").write_bytes(
            struct.pack("<8I", 0xFEEDFACF, 0x01000007, 0, 2, 0, 0, 0, 0))
        self.assertNotEqual(self.run_notary().returncode, 0)
        self.assertEqual(self.calls(), [])

    def test_release_workflows_are_read_only_manual_and_cannot_publish(self):
        for name in ["release.yml", "release-tag.yml", "release-prepare.yml"]:
            text = (ROOT / ".github/workflows" / name).read_text()
            data = yaml.load(text, Loader=yaml.BaseLoader)
            self.assertEqual(set(data["on"]), {"workflow_dispatch"})
            self.assertEqual(data["permissions"], {"contents": "read"})
            self.assertNotIn("secrets.", text)
            self.assertNotIn("contents: write", text)
            self.assertNotIn("environment:", text)
            for job in data["jobs"].values():
                self.assertNotIn("permissions", job)
                self.assertIn("exit 1", job["steps"][-1]["run"])
                for step in job["steps"]:
                    self.assertNotIn("gh release", step.get("run", ""))
                    self.assertNotIn("git push", step.get("run", ""))
                    self.assertNotIn("codesign", step.get("run", ""))
        text = (ROOT / ".github/workflows/release.yml").read_text()
        self.assertIn('refs/tags/$TAG^{commit}', text)
        self.assertIn("persist-credentials: false", text)
        self.assertNotIn("|| true", text)


if __name__ == "__main__":
    unittest.main()
