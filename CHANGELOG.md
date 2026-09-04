# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.1.0] - 2026-09-04

### Added

- **Hardened session lifecycle** — bounded audio channel with real admission, mono/rate-faithful accounting, drain-barrier finalization,and an immediate control plane so Release/Cancel preempts model preload (no more slow-stop races(.
- **Legal session state machine** — `DictationSession` + authoritative terminal outcome (exactly-one terminal event(, identity-checked cleanup, crash-recovery markers,and rapid-control stress coverage. 
- **Trusted target insertion** — validate+insert as one transaction against the same resolved element identity, AX write timeouts bound,and expired write budget never executes, revalidation immediately before mutation,and no auto-copy on secure/unknown/changed targets. 
- **Verified model acquisition** — loads the exact verified artifact byte-for-byte((digest-verified(,, quarantines on mismatch,, readiness = "exact verified artifact loaded"(. Downloads now **default off** until explicit onboarding consent. 
- **Encrypted local history** — at-rest Keychain-backed encryption,, single actor repository,, async UI view model,, every persistence error surfaced. Missing `saveHistory` decodes safe (false(. 
- **Flow fidelity** — protected-span placeholders with per-line restore,, failed protected-span check rejects output and returns conservative fallback (never fail open(. Rejected Flow never auto-inserts. 
- **Engine completeness** — Apple Speech bounded finalization with error provenance; WhisperKit chunked complete-audio finalization (or visible hard recording limit((,, safe decode ownership,, snapshot+apply language at session start. 
- **Docs** — product/security contracts (threat model,, sensitivity policy,, target snapshot,, audio channel,…(,, per-session state machine ADR,, CI policy + coverage/sanitizer baselines,, evidence-registry claims index. 

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
