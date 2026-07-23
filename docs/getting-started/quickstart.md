# Quickstart

## Prerequisites

- macOS 14+
- Apple Silicon recommended
- Microphone, Accessibility, Speech Recognition permissions

## Run from source

```bash
git clone https://github.com/joe-broadhead/zephyr-flow.git
cd zephyr-flow
chmod +x Scripts/build_app.sh
./Scripts/build_app.sh release
xattr -cr Dist/ZephyrFlow.app
open Dist/ZephyrFlow.app
```

If macOS blocks the app, right-click → **Open** (ad-hoc preview signing — see [Installation](installation.md)).

Or install into Applications:

```bash
cp -R Dist/ZephyrFlow.app /Applications/
open /Applications/ZephyrFlow.app
```

## First dictation

1. Click the mic icon in the menu bar  
2. If you see **Enable Accessibility…**, click it and toggle ZephyrFlow **on**  
3. Open Notes (or any text field) and place the caret  
4. **Hold Fn**, speak a sentence, **release**  
5. Text should insert at the caret  

!!! note "Ad-hoc builds and Accessibility"
    Each rebuild can require re-enabling Accessibility (ad-hoc code signature identity). Toggle ZephyrFlow off/on in System Settings → Privacy & Security → Accessibility.

## Menu controls

| Action | How |
|--------|-----|
| Start / stop without Fn | Menu → **Start Dictation** / **Stop & Insert** |
| Discard | Panel **✕** |
| Confirm insert | Panel **✓** or release Fn |
| Settings | Menu → **Settings…** or ++cmd+,++ |

## Verify privacy defaults

```bash
swift run ZephyrFlowCoreTests
```

Expect assertions that Local Only is on, default model is Whisper Tiny, and model downloads are allowed (file fetch only).
