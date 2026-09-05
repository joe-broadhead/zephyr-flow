# ZephyrFlow

<div align="center">

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Qualification target: macOS 15](https://img.shields.io/badge/qualification%20target-macOS%2015-black.svg?logo=apple&logoColor=white)](docs/development/contracts/supported-platform-matrix.md)
[![Swift 5.10+](https://img.shields.io/badge/Swift-5.10%2B-F05138.svg?logo=swift&logoColor=white)](https://swift.org/)
[![Docs](https://img.shields.io/badge/docs-mkdocs%20material-blue.svg?logo=materialformkdocs&logoColor=white)](https://joe-broadhead.github.io/zephyr-flow/)
[![CI](https://github.com/joe-broadhead/zephyr-flow/actions/workflows/ci.yml/badge.svg?branch=master)](https://github.com/joe-broadhead/zephyr-flow/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/joe-broadhead/zephyr-flow?include_prereleases&logo=github)](https://github.com/joe-broadhead/zephyr-flow/releases)

</div>

```
 _____          _                _____ _
|__  /___ _ __ | |__  _   _ _ __|  ___| | _____      __
  / // _ \ '_ \| '_ \| | | | '__| |_  | |/ _ \ \ /\ / /
 / /|  __/ |_) | | | | |_| | |  |  _| | | (_) \ V  V /
/____\___| .__/|_| |_|\__, |_|  |_|   |_|\___/ \_/\_/
         |_|          |___/

  Private voice-to-text direct to your cursor
```

<div align="center">

Hold **Control-Option-Space** · speak · release for validated insertion or review.
**Local Only by default** (your audio stays on-device). No analytics. No telemetry.  
Default engine: **Whisper Tiny** (model download requires explicit consent).

[Docs](https://joe-broadhead.github.io/zephyr-flow/) · [Quickstart](docs/getting-started/quickstart.md) · [Privacy](docs/guide/privacy.md) · [Releases](https://github.com/joe-broadhead/zephyr-flow/releases)

<br/>

<img src="docs/images/app-icon-1024.png" width="160" alt="ZephyrFlow app icon" />

</div>

---

## Screenshots

<p align="center">
  <img src="docs/images/01-setup.png" width="320" alt="Setup — stepped permissions" />
  &nbsp;
  <img src="docs/images/02-settings.png" width="420" alt="Settings — dark tech UI" />
</p>

<p align="center">
  <img src="docs/images/03-panel.png" width="360" alt="Listening panel with live waveform" />
</p>

---

## What it does

**Current forward candidate: proposed/unreleased, not approved for production.**
The human-selected qualification target is macOS 15.x / Apple Silicon / US
English / Whisper Tiny or on-device Apple Speech / Notes, TextEdit, Terminal,
Safari, VS Code and Slack. Exact-device/app evidence and independent review are
still required. Other combinations are experimental/unqualified; the source
deployment minimum of macOS 14 is not a production support claim. See the
[qualification boundary](docs/development/contracts/supported-platform-matrix.md).

ZephyrFlow is a macOS menu-bar dictation app:

1. Hold **Control-Option-Space** (new-install default; saved shortcuts are preserved)
2. A glass panel appears near the cursor with live waveform + interim text
3. Release → text is processed and either validated for insertion or held for review

> Historical GitHub release assets are not acceptance evidence for this candidate.
> Production requires Developer ID + notarization, exact-candidate qualification,
> independent review and explicit human GO. Release preflights are blocked;
> credentials alone do not complete release implementation or approval.

## Highlights

- **Hold-to-talk shortcut** — Control-Option-Space by default; Fn / Globe remains experimental
- **Whisper Tiny by default** — downloads once, then runs fully on-device (Neural Engine), with **live interim text** while you hold  
- **Local Only** — your voice/transcripts stay on this Mac; Apple Speech remains a built-in fallback  
- **Target-aware insertion** — per-app paste/AX strategies; secure/unknown fields prohibit automatic clipboard/AX/history side effects
- **Flow styles** — clean, bullets, professional, summary, raw (optional Enhanced on-device rules)  
- **Check for Updates** — on-demand GitHub Releases (no background pings)  
- **Auditable** — greppable privacy posture + core tests  

## Developer build (not production installation)

```bash
git clone https://github.com/joe-broadhead/zephyr-flow.git
cd zephyr-flow
./Scripts/build_app.sh debug
open Dist/ZephyrFlow.app
```

This developer bundle is ad-hoc signed, not a qualified production artifact.
Do not use a Gatekeeper bypass as distribution acceptance.

Use explicit Setup actions for **Microphone**, **Accessibility** (global shortcut
and automatic insertion) and model-download consent. Apple Speech also needs
Speech authorization and the selected on-device locale; no network fallback is
allowed with Local Only on. The menu controls remain available without a global
shortcut. New installations use **Control-Option-Space**; check keyboard conflicts.

**Planned platform:** macOS 15.x / arm64; exact hardware/app qualification pending.

## Architecture

```mermaid
flowchart TB
  subgraph Input
    HK[HotkeyService<br/>Fn / modifiers]
  end

  subgraph Orchestration
    DC[DictationController]
    FS[FocusStore]
    FP[FloatingPanel]
  end

  subgraph Speech
    AS[AppleSpeechEngine<br/>fallback · on-device]
    WK[WhisperKitEngine<br/>default · Tiny]
  end

  subgraph Output
    FL[FlowProcessor]
    IN[InsertionService<br/>paste / AX]
    HS[ActorHistoryRepository<br/>opted-in encrypted history]
  end

  HK -->|press / release| DC
  DC --> FP
  DC --> AS
  DC --> WK
  DC --> FS
  AS --> FL
  WK --> FL
  FL --> FS
  FS -->|restore frontmost app| IN
  DC --> HS
```

| Module | Role |
|--------|------|
| `ZephyrFlowCore` | Models, protocols, `FlowProcessor` (no AppKit) |
| `ZephyrFlow` | App, services, SwiftUI, optional WhisperKit link |

Session path: **Fn hold → panel + STT → release → flow → focus restore → paste/AX insert**.

## Privacy — how to audit

| Claim | Check |
|-------|--------|
| No analytics | `rg -i 'telemetry\|analytics\|sentry\|firebase' Sources` |
| Local Only default | `AppSettings.default.localOnlyMode == true` |
| Default model Whisper Tiny | `AppSettings.default.preferredModel == .whisperTiny` |
| Model downloads allowed (files only) | `allowModelDownloads == true` |
| No transcript log bodies | logs are lengths/events only |
| Tests | `swift run ZephyrFlowCoreTests` |

Details: [Privacy guide](docs/guide/privacy.md).

## Development

```bash
swift run ZephyrFlowCoreTests
./Scripts/build_app.sh debug
./Scripts/generate_app_icon.py    # Resources/AppIcon.icns + docs/images
./Scripts/capture_screenshots.sh  # docs/images product shots
# docs
python3 -m venv .venv && .venv/bin/pip install -r docs/requirements.txt
.venv/bin/mkdocs serve
```

See [Contributing](CONTRIBUTING.md), [AGENTS.md](AGENTS.md), and [Release](docs/development/release.md).

## License

[MIT](LICENSE)
