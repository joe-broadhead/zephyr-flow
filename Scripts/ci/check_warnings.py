#!/usr/bin/env python3
"""Compare primary Swift diagnostics by file, diagnostic and occurrence count."""

import argparse
from collections import Counter
import json
from pathlib import Path
import re
import sys


def normalized_key(path, message, root):
    source = Path(path)
    if source.is_absolute():
        try:
            source = source.relative_to(root)
        except ValueError:
            # macOS can spell the same checkout /var/... or /private/var/....
            # Resolve aliases only to test containment; external paths retain
            # their original identity rather than collapsing to a basename.
            try:
                source = source.resolve().relative_to(root.resolve())
            except ValueError:
                pass
    message = " ".join(message.split())
    diagnostic = re.search(r"\[#[A-Za-z0-9]+\]", message)
    if diagnostic:
        tag = diagnostic.group()
        message = " ".join(message.replace(tag, "", 1).split())
        return f"{source} | {tag} | {message}"
    return f"{source} | {message}"


def warning_records(text, root):
    """Retain primary emissions and their coordinates; never deduplicate the gate."""
    for line in text.splitlines():
        if "warning:" not in line:
            continue
        # Compiler-rendered source excerpts and child diagnostics duplicate
        # the primary diagnostic; retain each primary occurrence exactly once.
        if re.match(r"^\s*(?:[|`+\-]|\d+\s*\|)", line):
            continue
        primary = re.match(r"^(.+?):(\d+):(\d+): warning: (.*)$", line)
        if primary:
            yield normalized_key(primary[1], primary[4], root), int(primary[2]), int(primary[3])
        elif line.startswith("warning: "):
            yield normalized_key("unknown", line[len("warning: "):], root), None, None
        else:
            # New diagnostic formats cannot silently produce a zero-warning pass.
            yield "unparsed | " + " ".join(line.split()), None, None


def warnings_from_log(text, root):
    return Counter(key for key, _, _ in warning_records(text, root))


def location_report(text, root):
    """Explain repeated emissions in ONE build; not a replacement warning budget.

    Line/column coordinates are evidence, not stable identities across edits or
    compiler versions. Keep diagnostic IDs/messages intact and unlocated warnings
    visible. The existing emission-count comparison remains authoritative.
    """
    records = Counter(warning_records(text, root))
    diagnostics = {}
    sites = set()
    for (key, line, column), count in records.items():
        item = diagnostics.setdefault(key, {"key": key, "emissions": 0, "locations": [], "unlocated_emissions": 0})
        item["emissions"] += count
        if line is None:
            item["unlocated_emissions"] += count
        else:
            item["locations"].append({"line": line, "column": column, "emissions": count})
            sites.add((key.split(" | ", 1)[0], line, column))
    for item in diagnostics.values():
        item["locations"].sort(key=lambda location: (location["line"], location["column"]))
    return {
        "schema_version": 1,
        "primary_emissions": sum(records.values()),
        "distinct_source_locations": len(sites),
        "unlocated_emissions": sum(item["unlocated_emissions"] for item in diagnostics.values()),
        "diagnostics": [diagnostics[key] for key in sorted(diagnostics)],
    }


def read_baseline(text):
    baseline = Counter()
    for line in text.splitlines():
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        entry = re.fullmatch(r"\s*([1-9][0-9]*)\s+(.+)", line)
        if not entry or " | " not in entry[2]:
            raise ValueError("invalid warning baseline entry")
        key = " ".join(entry[2].split())
        if key in baseline:
            raise ValueError("duplicate warning baseline entry")
        baseline[key] = int(entry[1])
    return baseline


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, required=True)
    parser.add_argument("--build-log", type=Path, required=True)
    parser.add_argument("--baseline", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--locations-output", type=Path, help="Diagnostic-only location report; never changes the budget")
    args = parser.parse_args()
    try:
        text = args.build_log.read_text()
        root = args.root.resolve()
        actual = warnings_from_log(text, root)
        if args.locations_output:
            report = location_report(text, root)
            args.locations_output.write_text(json.dumps(report, indent=2) + "\n")
            print(f"Warning evidence: {report['primary_emissions']} primary emissions at "
                  f"{report['distinct_source_locations']} source locations; "
                  f"{report['unlocated_emissions']} unlocated emissions. Budget unchanged.")
        baseline = read_baseline(args.baseline.read_text())
        args.output.write_text("".join(f"{count} {key}\n" for key, count in sorted(actual.items())))
    except (OSError, ValueError) as error:
        print(f"warning comparison failed: {error}", file=sys.stderr)
        return 1
    new = actual - baseline
    if new:
        print("New warning occurrences beyond the reviewed baseline:")
        for key, count in sorted(new.items()):
            print(f"{count} {key}")
        return 1
    print(f"Strict warnings: {sum(actual.values())} occurrences; no increases against baseline.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
