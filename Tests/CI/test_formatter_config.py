"""Check the legacy config wire shape and the installed formatter separately."""

import json
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


class FormatterConfigurationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory(prefix="zephyr-formatter-test-")
        cls.addClassCleanup(cls.temp.cleanup)
        cls.directory = Path(cls.temp.name)
        cls.probe = cls.directory / "configuration-probe"
        subprocess.run(
            ["swiftc", str(ROOT / "Tests/CI/FormatterConfigurationProbe.swift"), "-o", str(cls.probe)],
            check=True, capture_output=True, text=True, timeout=60,
        )

    def test_configuration_decodes_with_legacy_enum_shape(self):
        result = subprocess.run(
            [str(self.probe), str(ROOT / ".swift-format")],
            capture_output=True, text=True, timeout=10,
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_modern_string_encoding_is_rejected_by_legacy_decoder(self):
        config = json.loads((ROOT / ".swift-format").read_text())
        config["reflowMultilineStringLiterals"] = "never"
        path = self.directory / "incompatible.json"
        path.write_text(json.dumps(config))
        result = subprocess.run([str(self.probe), str(path)], capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("Incompatible configuration encoding", result.stdout)

    def test_installed_formatter_accepts_compatible_configuration(self):
        source = self.directory / "Example.swift"
        source.write_text("let example = 1\n")
        result = subprocess.run(
            ["swift", "format", "lint", "--strict", "--configuration", str(ROOT / ".swift-format"), str(source)],
            capture_output=True, text=True, timeout=30,
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
