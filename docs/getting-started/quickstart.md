# Quickstart

## Prerequisites

- Initial qualification target: macOS 15.x / Apple Silicon / US English
- Whisper Tiny or on-device Apple Speech; six-app matrix and device evidence pending
- Explicit Microphone consent; Accessibility for global hotkey/automatic insertion; Speech permission only for Apple Speech
- Source minimum is macOS 14, not a production support claim; other combinations are experimental

## Run from source

```bash
git clone https://github.com/joe-broadhead/zephyr-flow.git
cd zephyr-flow
chmod +x Scripts/build_app.sh
./Scripts/build_app.sh debug
open Dist/ZephyrFlow.app
```

This is an ad-hoc developer build, not a production-qualified installation.
No Gatekeeper bypass establishes release acceptance.

Or install into Applications:

```bash
cp -R Dist/ZephyrFlow.app /Applications/
open /Applications/ZephyrFlow.app
```

## First dictation

1. Click the mic icon in the menu bar  
2. If you see **Enable Accessibility…**, click it and toggle ZephyrFlow **on**  
3. Open a normal text field in Notes and place the caret
4. **Hold Control-Option-Space** (or your saved shortcut), speak, **release**
5. Validate insertion or review the reported outcome; no automatic side effect is permitted for secure/unknown targets

!!! note "Ad-hoc builds and Accessibility"
    Each rebuild can require re-enabling Accessibility (ad-hoc code signature identity). Toggle ZephyrFlow off/on in System Settings → Privacy & Security → Accessibility.

## Menu controls

| Action | How |
|--------|-----|
| Start / stop without a shortcut | Menu → **Start Dictation** / **Stop & Insert** |
| Discard | Panel **✕** |
| Finish capture | Panel **✓** or release the configured shortcut |
| Settings | Menu → **Settings…** or ++cmd+,++ |

## Verify privacy defaults

```bash
swift run ZephyrFlowCoreTests
```

Expect assertions that Local Only is on, model downloads and history storage are
opt-in (`allowModelDownloads=false`, `saveHistory=false`), and the default model
is Whisper Tiny. New-install shortcut is Control-Option-Space. Core tests do not
prove device privacy or release qualification.
