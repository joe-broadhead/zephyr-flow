# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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

[0.0.0]: https://github.com/joe-broadhead/zephyr-flow/releases/tag/v0.0.0
