#!/usr/bin/env python3
"""Tool doubles used ONLY inside test_gate_runner's temporary repository.

No Xcode, application, microphone, network, model, or system preference calls.
The happy path tests gate orchestration, not real tool qualification.
"""

import os
from pathlib import Path
import subprocess
import sys

tool = Path(sys.argv[0]).name
args = sys.argv[1:]
mode = os.environ.get("ZF_TEST_FAILURE", "")
products = Path(os.environ["ZF_TEST_PRODUCTS"])
root = Path(os.environ["ZF_TEST_ROOT"])
SUITES = ["M0ContractTests", "ProductionBlockerTests", "FlowProcessorTests", "ModelsTests",
          "ProductionAudioTests", "ProductionBoundaryTests", "ProductionEngineTests", "ProductionOfflineTokenizerTests",
          "ProductionPreparationTests", "ProductionAcquisitionTests", "ProductionPasteboardTests", "ProductionHistoryTests", "FlowDeadlineTests", "ProductionSettingsTests", "ProductionFnPreferenceTests", "ProductionAdmissionTests", "AxBoundedRunnerTests"]


def fail_if(name):
    if mode == name:
        print(f"synthetic {name} failure, exit 17", flush=True)
        sys.exit(17)


if tool == "swift":
    if args == ["--version"]:
        print("Swift test double (not a compiler)")
    elif args == ["test", "list"]:
        for suite in SUITES:
            if not (mode == "missing-suite" and suite == SUITES[-1]):
                print(f"ZephyrFlowTests.{suite}/testExample")
        fail_if("discovery")  # Success-shaped output followed by failure.
    elif args == ["test"]:
        if mode != "zero-executed":
            for suite in SUITES:
                print(f"Test Suite '{suite}' passed at synthetic-time")
        fail_if("xctest")
    elif args == ["package", "clean"]:
        fail_if("clean")
    elif "--show-bin-path" in args:
        fail_if("bin-path")
        print(products)
    elif "--build-tests" in args:
        if mode == "new-warning":
            print(f"{root}/Sources/Example.swift:1:1: warning: new synthetic warning")
        fail_if("strict-build")
    elif args[0] == "format":
        fail_if("format")
    elif "--enable-code-coverage" in args:
        fail_if("coverage-tests")
        if mode != "missing-xctest-profile":
            folder = products / "codecov"
            folder.mkdir(exist_ok=True)
            (folder / "xctest.profraw").write_text("synthetic profile")
    elif "--sanitize=address" in args:
        fail_if("asan")
    elif args == ["run", "ZephyrFlowCoreTests"]:
        fail_if("core")
    else:
        raise AssertionError(f"unexpected fake swift invocation: {args}")
elif tool == "xcrun":
    if args == ["--find", "xctest"]:
        fail_if("no-xctest")
        print(products / "xctest")
    elif args[:2] == ["llvm-profdata", "merge"]:
        fail_if("coverage-merge")
        Path(args[args.index("-o") + 1]).write_text("synthetic merged profile")
    elif args[:2] == ["llvm-cov", "report"]:
        fail_if("coverage-report")
        value = {"coverage-low": "69.99", "coverage-invalid": "NaN",
                 "coverage-high": "101"}.get(mode, "80.00")
        if mode != "coverage-empty":
            print(f"TOTAL 100 20 {value}% 100 20 80.00% 100 20 {value}% 0 0 -")
    else:
        raise AssertionError(f"unexpected fake xcrun invocation: {args}")
elif tool == "ZephyrFlowCoreTests":
    profile = os.environ.get("LLVM_PROFILE_FILE")
    if profile:
        fail_if("coverage-core")
        if mode != "missing-clt-profile":
            Path(profile).write_text("synthetic CLT profile")
    else:
        print("✓ 2292 synthetic control check")
        if mode != "stress-missing-marker":
            print("✓ 2293 synthetic recovery check")
        fail_if("stress")  # Printed markers must not hide this exit code.
elif tool == "python3":
    if args == ["-c", "import yaml"]:
        fail_if("no-pyyaml")
    elif args[0] == "-c" and "safe_load_all" in args[1]:
        fail_if("yaml")
    elif args[0] == "Scripts/string_scan.py":
        fail_if("strings")
    else:
        if args[:2] == ["-m", "unittest"]:
            fail_if("regressions")
        os.execv(sys.executable, [sys.executable, *args])
elif tool == "mkdocs":
    fail_if("docs")
    if mode.startswith("drift-"):
        name = "new-generated.txt" if mode == "drift-untracked" else "README.md"
        (root / name).write_text("synthetic generated drift")
        if mode == "drift-staged":
            subprocess.run(["git", "add", name], cwd=root, check=True)
elif tool == "shellcheck":
    fail_if("shellcheck")
elif tool == "actionlint":
    fail_if("actionlint")
elif tool == "xcodebuild":
    print("Xcode test double (not Xcode)")
elif tool == "xctest":
    assert args == ["-XCTest", "ZephyrFlowTests.ProductionOfflineTokenizerTests",
                    str(products / "ZephyrFlowPackageTests.xctest")], args
    if mode != "offline-zero-executed":
        print("Test Suite 'ProductionOfflineTokenizerTests' passed at synthetic-time")
    fail_if("offline-tokenizer")
elif tool == "sandbox-exec":
    if args[2] == "python3":
        print("synthetic sandbox policy check (NOT an actual sandbox)")
        fail_if("sandbox-policy")
    else:
        os.execvp(args[2], args[2:])
else:
    raise AssertionError(f"unexpected fake tool: {tool}")
