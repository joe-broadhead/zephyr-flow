# AGENTS.md

macOS menu-bar dictation app: hold Fn → on-device speech → insert at caret.  
Stack: **Swift 5.10+ / SwiftUI / AppKit**, SPM (`Package.swift`), macOS 14+.  
Version source of truth: `VERSION` (first public release target: **v0.0.0**).

## Commands

- Resolve packages: `swift package resolve`
- Core tests (fast, no UI): `swift run ZephyrFlowCoreTests`
- Debug app: `./Scripts/build_app.sh debug && open Dist/ZephyrFlow.app`
- Release app: `./Scripts/build_app.sh release`
- Docs serve: `.venv/bin/mkdocs serve` (after `python3 -m venv .venv && .venv/bin/pip install -r docs/requirements.txt`)
- Docs strict: `.venv/bin/mkdocs build --strict`
- Version gate (same as CI):  
  `v=$(tr -d '[:space:]' < VERSION); grep -q "static let version = \"$v\"" Sources/ZephyrFlow/Utilities/Constants.swift && grep -q "<string>$v</string>" Resources/Info.plist && grep -q "^## \\[$v\\]" CHANGELOG.md`

## Boundaries

**Always do**
- Read files, list dirs, run `swift run ZephyrFlowCoreTests`
- Keep Local Only defaults and privacy gates intact
- Log events/lengths only — never transcript bodies
- Prefer small, focused diffs

**Ask first**
- `git push`, force-push, tags, GitHub Releases
- Change repo visibility (public/private)
- Add SPM dependencies or edit CI/release workflows
- Full `./Scripts/build_app.sh release` on CI-like long runs when not requested
- Rewrite git history

**Never do**
- Make the repo public or cut a release unless the human **explicitly** asked in that turn
- Commit audit dumps (`AUDIT.md`, `*_AUDIT.md`, peer-review dumps under `docs/`)
- Commit secrets, `.env`, keychains, or personal logs
- Edit `.build/`, `Dist/`, `site/`, `.venv/`
- Set WhisperKit `download: true` except via `settings.mayDownloadModels`
- Fall back to network Apple Speech when Local Only is on

## Project Structure

- `Sources/ZephyrFlowCore/` — models, protocols, `FlowProcessor` (unit-tested, no AppKit)
- `Sources/ZephyrFlow/App/` — `@main`, `AppDelegate`, `WindowRouter`
- `Sources/ZephyrFlow/Services/` — hotkey, STT, insert, focus, settings, history
- `Sources/ZephyrFlow/UI/` — Panel, Settings, Onboarding, MenuBar
- `Scripts/build_app.sh` — assemble + ad-hoc sign `ZephyrFlow.app`
- `Resources/Info.plist`, `Resources/ZephyrFlow.entitlements`
- `Tests/ZephyrFlowCoreTests/` — CLT-friendly privacy/logic tests
- `docs/` + `mkdocs.yml` — Material docs site
- `.github/workflows/` — `ci.yml`, `docs.yml`, `release*.yml`

Entry points: `Sources/ZephyrFlow/App/ZephyrFlowApp.swift`, `Services/DictationController.swift`.

## Code Style

- Swift concurrency: long-running work in `actor` or dedicated threads; UI on `@MainActor`
- STT backends only via `WhisperEngineProtocol`
- Prefer `ZFLog.info/error/debug` over `print`
- Match naming in neighboring files; no new god objects

### Good

```swift
try await activeEngine.startStreaming(localOnly: settings.localOnlyMode) { partial in
  Task { @MainActor in self.interimText = partial.text }
}
ZFLog.info("partial len=\(partial.text.count)") // never log text body
```

### Bad

```swift
try await engine.startStreaming { print($0.text) } // leaks PII to console/logs
URLSession.shared.data(from: modelURL) // no ad-hoc networking
```

## Testing & Git

- Before commit: `swift run ZephyrFlowCoreTests`
- Docs changes: `mkdocs build --strict`
- Commits: `feat(scope): …` / `fix(scope): …` / `docs: …` / `ci: …`
- PR: small, focused; CI green
- **Release / public / tag**: only when human says so explicitly

## Security & Privacy

- Default: `localOnlyMode=true`, `allowModelDownloads=true`, model=Whisper Tiny
- `mayDownloadModels == allowModelDownloads` (model files only; never uploads audio)
- History may store plaintext transcripts only if `saveHistory` (user toggle)
- Logs: never transcript content
- Audits are throwaway — terminal/temp only, never committed

## When stuck

Ask a clarifying question or propose a short plan. Do not guess on visibility, releases, or privacy behavior.
