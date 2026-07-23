# Contributing to ZephyrFlow

Thanks for helping build private, on-device dictation.

## Ground rules

1. **Privacy first** — no analytics/telemetry; Local Only keeps user audio on-device. Model downloads are explicit file fetches only.
2. **Actor + protocol architecture** — STT backends stay behind `WhisperEngineProtocol`.
3. **Insertion is sacred** — AX/paste changes need multi-app manual checks.
4. **UI must feel premium** — the floating panel is a product feature.

## Setup

```bash
git clone https://github.com/joe-broadhead/zephyr-flow.git
cd zephyr-flow
swift run ZephyrFlowCoreTests
./Scripts/build_app.sh debug
open Dist/ZephyrFlow.app
```

Grant Microphone + Accessibility + Speech Recognition to the debug build.

## Docs

```bash
python -m pip install -r docs/requirements.txt
mkdocs serve
mkdocs build --strict
```

## Pull requests

- Keep PRs focused  
- Update `CHANGELOG.md` under `[Unreleased]` when user-visible  
- Note apps you manually verified for insertion changes  
- Do not add dependencies that phone home by default  

## Code of conduct

Be respectful. See [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md).
