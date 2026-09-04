#!/usr/bin/env python3
"""JOE-2289: string-catalog completeness scan.

Scans production UI paths for hard-coded user-facing strings and fails on any
UNREVIEWED literal. Reviewed/legacy sites must be listed in the allowlist
with a reason. The catalog (Sources/ZephyrFlowCore/AppStrings.swift) is the
single source of truth.
"""
import re, sys, pathlib

ROOT = pathlib.Path(__file__).resolve().parent.parent
UI = ROOT / "Sources" / "ZephyrFlow"
ALLOWLIST = {
    # Reviewed dynamic/technical strings (never translated):
    "SettingsView.swift": [
        # history row separator punctuation (technical, not translatable)
        '\u00b7',
    ],
}
# Patterns for user-facing string literals: Text("..."), Label("...", systemImage:),
# Button("..."), .navigationTitle("..."), .accessibilityLabel("..."), title: "..."
PATTERNS = [
    re.compile(r'(?:Text|Label|Button|Toggle|Picker|navigationTitle|accessibilityLabel|accessibilityHint|help|tooltip)\(\s*"'),
    re.compile(r'\btitle:\s*"'),
    re.compile(r'\bmessage:\s*"'),
]

def scan_file(path):
    hits = []
    for i, line in enumerate(path.read_text().splitlines(), 1):
        for pat in PATTERNS:
            if pat.search(line) and not any(a in line for a in ALLOWLIST.get(path.name, [])):
                hits.append((i, line.strip()[:100]))
                break
    return hits

def main():
    bad = 0
    for path in sorted((UI / "UI").rglob("*.swift")):
        for i, line in scan_file(path):
            print(f"{path.relative_to(ROOT)}:{i}: hard-coded UI string: {line}")
            bad += 1
    # AppStrings catalog completeness: every referenced key must exist.
    catalog = (ROOT / "Sources" / "ZephyrFlowCore" / "AppStrings.swift").read_text()
    keys = set(re.findall(r'"([a-z][a-z0-9.]+)":\s*\(', catalog))
    refs = set(re.findall(r'AppStrings\.(?:key|format)\("([a-z][a-z0-9.]+)"', catalog))
    # references in UI
    for path in sorted((UI / "UI").rglob("*.swift")):
        refs |= set(re.findall(r'AppStrings\.(?:key|format)\("([a-z][a-z0-9.]+)"', path.read_text()))
    for r in sorted(refs - keys):
        print(f"MISSING CATALOG KEY: {r}")
        bad += 1
    if bad:
        print(f"string scan: {bad} issue(s) — refusing merge.")
        sys.exit(1)
    print(f"string scan: OK ({len(keys)} catalog keys, all references resolve).")
    sys.exit(0)

if __name__ == "__main__":
    main()
