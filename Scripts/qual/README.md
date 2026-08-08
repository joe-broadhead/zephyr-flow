# Qualification scripts (JOE-2297/2257/2273/2274/2294/2295/2296/2303)

Every script is fail-closed: it emits a timestamped report with machine
identity (macOS + toolchain + repo head) and exits non-zero when an
expectation fails. Hardware-dependent steps print exact manual instructions
and leave a report skeleton; the deterministic portions run the retained
Core/CLT harnesses. No transcript bodies are ever written to reports/logs —
only metrics.

Usage: each script prints `--help` or a usage line when run without args.
Reports land in `dist/qual-reports/`.
