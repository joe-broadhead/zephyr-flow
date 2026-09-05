#!/usr/bin/env python3
"""Compare primary Swift diagnostics by file, diagnostic and occurrence count."""

import argparse
from collections import Counter
from pathlib import Path
import re
import sys


def normalized_key(path, message, root):
    source = Path(path)
    if source.is_absolute():
        try:
            source = source.relative_to(root)
        except ValueError:
            pass  # Keep external identity; never merge it into a source file.
    message = " ".join(message.split())
    diagnostic = re.search(r"\[#[A-Za-z0-9]+\]", message)
    if diagnostic:
        tag = diagnostic.group()
        message = " ".join(message.replace(tag, "", 1).split())
        return f"{source} | {tag} | {message}"
    return f"{source} | {message}"


def warnings_from_log(text, root):
    warnings = Counter()
    for line in text.splitlines():
        if "warning:" not in line:
            continue
        # Compiler-rendered source excerpts and child diagnostics duplicate
        # the primary diagnostic; retain each primary occurrence exactly once.
        if re.match(r"^\s*(?:[|`+\-]|\d+\s*\|)", line):
            continue
        primary = re.match(r"^(.+?):\d+:\d+: warning: (.*)$", line)
        if primary:
            key = normalized_key(primary[1], primary[2], root)
        elif line.startswith("warning: "):
            key = normalized_key("unknown", line[len("warning: "):], root)
        else:
            # New diagnostic formats cannot silently produce a zero-warning pass.
            key = "unparsed | " + " ".join(line.split())
        warnings[key] += 1
    return warnings


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
    args = parser.parse_args()
    try:
        actual = warnings_from_log(args.build_log.read_text(), args.root.resolve())
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
