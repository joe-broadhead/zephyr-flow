# Insertion adapter registry (JOE-2271) — version 1

Insertion behavior is a versioned capability contract matched by EXACT bundle
identity (+ optional role, app-version range, macOS minimum). Unknown apps use
the conservative default. Broad guesses (`contains("chrome")`, "Electron
grouping") are removed.

## Registry (Sources/ZephyrFlowCore/InsertionAdapter.swift)

| Adapter | Exact bundles | Strategies (order) | Settle | Verification | Limits |
|---------|--------------|--------------------|--------|--------------|--------|
| terminal.v1 | com.apple.Terminal, com.googlecode.iterm2, dev.warp.Warp-Stable, dev.warp.Warp, co.zeit.hyper, com.github.wez.wezterm | terminalPaste, clipboardPaste, copyOnly | 40 ms | none (unverified) | paste unverified |
| editor.v1 | com.microsoft.VSCode, com.apple.dt.Xcode | clipboardPaste, axSelectedText, axValue, copyOnly | 16 ms | postWriteReRead | axValue needs qualification (JOE-2270) |
| browser.v1 | com.apple.Safari, com.google.Chrome, org.mozilla.firefox, com.microsoft.edgemac | clipboardPaste, axSelectedText, copyOnly | 16 ms | postWriteReRead | no axValue; paste unverified |
| electron-shell.v1 | com.tinyspeck.slackmacgap, notion.id, com.figma.Desktop, com.linear | clipboardPaste, axSelectedText, copyOnly | 16 ms | postWriteReRead | shell apps vary; paste unverified |
| default.v1 | (unknown apps) | clipboardPaste, axSelectedText, copyOnly | 16 ms | none | no whole-value mutation; paste unverified |

## Rules

- Exact bundle match only; no substring guessing (regression tests enforce).
- Unknown apps use the conservative default (no unsafe whole-value mutation,
  unverified paste distinguished).
- Strategy failure cascades ONLY when `allowsStrategyCascade` is true for the
  adapter (all current entries permit; strict entries stop after first failure).
- Local user override: copy-only per exact bundle ID in Settings → Insertion
  ("Copy-only apps"), stored in `AppSettings.copyOnlyOverrideBundleIDs`. No
  remote configuration or telemetry.
- Registry hygiene (no overlaps/duplicates) and matching are unit-tested.
- Adapter identity + verification are logged content-free at insert time
  (`adapter id=… version=…`), reportable to UI/support bundle.

## Drift

Version bumps require code + this doc + tests to move together; `version` is
asserted in tests.
