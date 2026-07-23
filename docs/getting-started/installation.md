# Installation

## Prebuilt release (when published)

Assets ship from GitHub Releases as a zip of `ZephyrFlow.app` plus checksums.

```bash
# Example — replace VERSION
curl -L -o ZephyrFlow.app.zip \
  https://github.com/joe-broadhead/zephyr-flow/releases/download/v0.0.0/ZephyrFlow-macos-arm64.app.zip

unzip ZephyrFlow.app.zip
xattr -cr ZephyrFlow.app
codesign -dv ZephyrFlow.app   # expect ad-hoc until Developer ID
open ZephyrFlow.app
```

!!! warning "Gatekeeper (ad-hoc preview builds)"
    Preview builds are **not notarized**. First launch often fails with *“macOS cannot verify the developer”*.

    **Fix:** Finder → right-click `ZephyrFlow.app` → **Open** → **Open** again. Or:
    ```bash
    xattr -cr /path/to/ZephyrFlow.app
    open /path/to/ZephyrFlow.app
    ```

## From source

### Requirements

- macOS 14+
- Swift 5.10+ / Xcode CLT or full Xcode
- Network once to resolve Swift packages, and once more on first run to download Whisper Tiny (~75 MB) if model downloads are enabled
- **Apple Silicon (arm64)** for release builds

### Build

```bash
./Scripts/build_app.sh release
```

Output:

- `Dist/ZephyrFlow.app`
- `.build/App/ZephyrFlow.app` (intermediate)

### Install

```bash
cp -R Dist/ZephyrFlow.app /Applications/
open /Applications/ZephyrFlow.app
```

## Uninstall

```bash
pkill -f ZephyrFlow || true
rm -rf /Applications/ZephyrFlow.app
rm -rf ~/Library/Application\ Support/ZephyrFlow
rm -rf ~/Library/Logs/ZephyrFlow
defaults delete dev.zephyrflow.app 2>/dev/null || true
```

If you used Fn as the hotkey, quitting normally restores the system Globe-key preference. After a crash, the next launch restores it automatically.
