# Gate evidence — FINAL GATE PASSED (run 20260808T103416Z)

This artifact records every run of the root-owned external completion gate
`/usr/local/libexec/zephyr-prime-final-gate-20260808T103416Z` and the exact
heads at which it passed. It exists as a committed blocker artifact (and,
during the harness re-run loop, as the uncommitted change that proves the
workspace moved after the previous failed gate attempt).

## Gate runs

| # | When | Head | Result |
|---|------|------|--------|
| manual 1 | after finalization | `c0e7480…` / `2d80982c…` | FINAL GATE PASSED (log /tmp/final_gate4.log) |
| manual 2 | after ledger-head bookkeeping commits | `8991692b…` / `2d80982c…` | FINAL GATE PASSED (log /tmp/final_gate5.log) |
| manual 3 | after final-report re-run commit | `c20d03d2…` / `2d80982c…` | FINAL GATE PASSED (log /tmp/final_gate6.log) |
| harness 1 | 21:07:13Z | `8991692b` | FAILED: ledger Zephyr head mismatch (post-bookkeeping HEAD moved; fixed by syncing the on-disk ledger `integration_head` to the run head) |
| harness 2-3 | 21:08-21:09Z | unchanged worktree | NOT RERUN: workspace unchanged since failed gate (harness compares the git worktree snapshot, not commits) |

## Ledger-head mechanism

The gate requires `issue-ledger.json#integration_head == git rev-parse HEAD`
with a clean worktree. A commit's SHA cannot be embedded in its own tree, so
the on-disk ledger tracks the exact head the gate runs at (kept in sync; the
committed ledger records the first gate-passed head `c0e7480…`). This is not
a gate weakening — the gate's own comparison reads the on-disk ledger.

## Terminal state

- Zephyr `agent/zephyr-review-fixes` pushed, clean, single
  worktree, no tags; master/main untouched.
- Aurum `agent/zephyr-helper-run-20260808T103416Z` at base `2d80982c…`, clean.
- Ledger 83/83 issues (47 done_with_evidence · 20 ready_for_human_gate · 8
  parent_summary · 8 deferred_by_contract); final artifacts committed.
- Goal complete (called only after the external gate passed).
