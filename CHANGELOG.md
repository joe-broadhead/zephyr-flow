# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.1.0] — proposed, unreleased

This version is proposed stack metadata, not a published release or production
approval. The entries below describe implementation work; supported-device and
app qualification, independent review, Developer ID/notarized distribution and
explicit human approval remain outstanding. Historical entries do not establish
acceptance of the current candidate.

### Added

- **Session and audio controls** — per-session actors, bounded audio delivery, frame accounting, converter-tail retention, terminal outcomes and cancellation-aware engine preparation. Automated tests do not qualify every native callback, rapid-control or cleanup path.
- **Target and clipboard checks** — process-start identity, target revalidation, lossless bounded clipboard snapshots and marker-plus-generation restoration ownership. Secure subroles and failed sensitivity reads are confined. AX IPC deadlines, live focus races, crash recovery and the six-app insertion matrix remain qualification work.
- **Engine preparation** — separate verified files, acquisition consent, loaded engines and capability preflight; Retry/Cancel and explicit Apple continuation. Local Only remains on, model downloads remain off until consent, and history remains off by default. Local tokenizer loading is checked without a remote fallback; digest integrity is not pinned artifact authenticity or real-model inference qualification.
- **History and settings** — a single opt-in actor history repository with Keychain-backed encryption preparation; settings publish after persistence acknowledgment. Login registration is verified before saving its desired value. Reboot/power-loss, Keychain, storage recovery and login-item behavior require device evidence.
- **Flow outcomes** — protected-span checks, typed fallback and bounded callers that do not join a noncooperative backend. The inherited fidelity corpus is incomplete: Raw statistics are missing from the release gate. Passing implementation tests is not Flow qualification.
- **Engine completeness reporting** — The human-selected target is bounded chunking up to ten minutes. WhisperKit now retains the recording prefix in bounded PCM blocks and finalizes sequential 30-second windows with two-second overlap. Unique-range accounting excludes repeated overlap work; missing/conflicting/ambiguous word alignment preserves all hypotheses as incomplete review output. Excess beyond ten minutes is counted, not substituted for the prefix. Cancellation/deadline releases the waiter, not native ownership. Synthetic engine tests are authored; real inference/alignment, memory/latency, all-language boundary behavior and recording-limit UI/control are not yet qualified. Apple finalization/preflight is implemented; real-device Speech lifecycle and language-pack behavior remain unqualified.
- **Validation tooling** — required XCTest execution, strict-concurrency warning checks, preserved command exits/artifacts and unchanged coverage thresholds. Device runbook helpers now report NOT RUN/INCOMPLETE instead of treating prepared checklists or no-op loops as qualification passes. Signed distribution tooling remains incomplete.

### Removed

- Unreferenced legacy plaintext `HistoryStore` and duplicate `NeuralFlowProcessor` implementations. Active paths use `ActorHistoryRepository` and the deterministic `EnhancedFlowProcessor`; Enhanced rules is not an LLM.

## [0.0.1] - 2026-07-25

### Added

- **Live Whisper partials** — single-flight progressive decode while holding Fn so the panel shows interim text before release (safe against WhisperKit concurrent-transcribe crashes)
- **Model readiness UI** — Settings → Model shows Ready / Not downloaded / Failed; load path surfaces download/fail banners
- **Per-app insertion strategies** — Automatic / Always paste / Always copy; terminal & Electron-aware order; secure fields stay copy-only
- **Enhanced Flow (opt-in)** — Settings → Flow: Classic (default) or Enhanced on-device **rules** for Professional / Bullets / Summary (Clean & Raw always Classic). Not a cloud or LLM path
- **Check for Updates** — Settings → About and menu bar; on-demand GitHub Releases check only (no background pings)
- Optional **Developer ID + notarization** path in release CI when Apple secrets are configured (otherwise ad-hoc)
- Docs: live partials, insertion matrix, hotkeys panel keys, update privacy note, Aurum bake-off memo (engine no-go)

### Fixed

- Listening **orb waveform animation** — TimelineView pulse + mic-reactive bars (SwiftUI `repeatForever` froze under frequent redraws)
- Insertion `preferPaste=false` path no longer skips paste by placing copy-only first
- Flow backend user-facing naming honesty (Enhanced rules, not “neural LLM”)

### Changed

- Whisper finalize waits for any in-flight partial before the final decode (single-flight guarantee)
- Panel: movable by background, optional position memory, Esc/Return when ZephyrFlow can receive keys

## [0.0.0] - 2026-07-23

### Added

- Initial public preview of ZephyrFlow for **macOS 14+ / Apple Silicon (arm64)**
- Hold-to-talk **Fn** hotkey (Wispr-style) with Right Option and combo alternatives
- Default engine **Whisper Tiny** (WhisperKit) — one-time model download, then on-device inference
- **Apple Speech** built-in fallback with Local Only fail-closed behavior when on-device speech is unavailable
- Floating dark-glass panel with clipped waveform, interim text, Stop (✓) / Cancel (✕)
- Focus restore + clipboard paste / Accessibility insert
- FlowProcessor styles: clean, bullets, professional, summary, raw
- Menu bar app, Settings, stepped onboarding, optional local history
- MkDocs Material documentation site
- CI (macOS build + tests), docs deploy, release workflows

### Privacy

- Local Only default (audio/transcripts stay on-device; no analytics)
- Model downloads are a separate toggle (on by default for Whisper Tiny file fetch only)
- Logs record events and lengths only (never transcript bodies)
- Globe-key preference crash recovery + in-app reset

[0.0.1]: https://github.com/joe-broadhead/zephyr-flow/releases/tag/v0.0.1
[0.0.0]: https://github.com/joe-broadhead/zephyr-flow/releases/tag/v0.0.0
