# Provisional decisions

Conservative, reversible assumptions used only to keep review-branch implementation moving. These are not human approvals.

## 2026-08-08 — 2259 fail-closed runtime default

Until JOE-2268/2290 wire AX target evidence, `DictationController.sessionSensitivity`
defaults to `.unknown` (fail-closed): sessions run conservative review-only,
no automatic insertion/clipboard/history. This is the conservative, reversible
reading of JOE-2259's "disabling Accessibility causes unknown/fail-closed
behavior"; it will be relaxed ONLY by real target evidence, never by default.
