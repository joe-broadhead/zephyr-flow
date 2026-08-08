# JOE-2271 — evidence-backed insertion adapter registry

**Run:** 20260808T103416Z · branch `agent/zephyr-production-run-20260808T103416Z`

## Delivered

- `Sources/ZephyrFlowCore/InsertionAdapter.swift`: `InsertionAdapter` capability
  record (exact bundle IDs, optional role filter, app-version range, macOS
  minimum, permitted strategies + ordering, settle condition, verification
  method, known limitations, evidence reference, cascade flag);
  `InsertionAdapterRegistry` (versioned, hygiene-checked, exact-match or
  conservative default); `AdapterIdentity` (content-free reporting).
- Replaced guess-based routing: `InsertionStrategyResolver` now consults the
  registry. `contains("chrome")` / broad Electron-browser grouping removed —
  explicit exact entries (browser.v1, electron-shell.v1) or safe default.
- Conservative default: clipboardPaste + axSelectedText + copyOnly; NO axValue
  (no unsafe whole-value mutation); paste verification `.none` (distinguished
  unverified).
- Local user override: `AppSettings.copyOnlyOverrideBundleIDs` +
  Settings → Insertion TextField (comma-separated exact bundle IDs) →
  controller passes overrides into `InsertionService.insert`. No remote config,
  no telemetry.
- Strategy failure cascade gated by `allowsStrategyCascade` per adapter;
  `nextStrategy(after:)` is deterministic and unit-tested.
- Insert logs adapter id + registry version + strategy list (content-free);
  UI/support bundle can report adapter identity/confidence.

## Acceptance criteria

- Every special-case strategy has a named qualification record — 4 named
  adapters + default, all versioned with evidence references.
- Unknown apps use the conservative default — tests.
- Exact app/version changes can invalidate/downgrade an adapter without code
  ambiguity — version-range + macOS-min matching tests.
- Registry unit-testable without AppKit, no duplicate/overlapping entries —
  hygiene test.
- UI/support bundle can report adapter identity and confidence without field
  text — AdapterIdentity + content-free logs.

## Tests (JOE-2271 block)

Registry hygiene/version, exact bundle matching (chrome/safari/terminal/vscode/
slack), unknown→default, chrome-like-guess regression (com.evil.chromeish.app
→ default), default no-axValue + unverified-paste, strategy ordering + cascade
(strict adapter stops), role filter, version + macOS ranges, resolver strategies
per adapter, copy-only override, alwaysCopy mode. All pass.

## Evidence references

- docs/development/contracts/insertion-adapter-registry.md (generated compat
  doc, version 1)
- Real-app evidence IDs: terminal.v1 / editor.v1 / browser.v1 /
  electron-shell.v1 (qualification records above; manual real-app matrix
  retained for human gate).
