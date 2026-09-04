#!/usr/bin/env bash
# Shared qual-script bootstrap: machine identity + report dir.
set -euo pipefail
QUAL_REPORT_DIR="${QUAL_REPORT_DIR:-$(pwd)/dist/qual-reports}"
mkdir -p "$QUAL_REPORT_DIR"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
REPORT="$QUAL_REPORT_DIR/$STAMP-${QUAL_NAME:-qual}.md"
{
  echo "# $STAMP ${QUAL_NAME:-qual}"
  echo
  echo "- macOS: $(sw_vers -productVersion 2>/dev/null || echo unknown)"
  echo "- hardware: $(sysctl -n hw.model 2>/dev/null || echo unknown)"
  echo "- swift: $(swift --version 2>/dev/null | head -1)"
  echo "- repo head: $(git rev-parse --short HEAD 2>/dev/null || echo unknown)"
  echo "- date: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo
} > "$REPORT"
echo "report: $REPORT"
qual_ok() { echo "- [PASS] $*" >> "$REPORT"; }
qual_fail() { echo "- [FAIL] $*" >> "$REPORT"; FAILURES=$((FAILURES+1)); }
FAILURES=0
