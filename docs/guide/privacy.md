# Privacy

## Defaults (ship posture)

| Setting | Default |
|---------|---------|
| Local Only | **On** (audio/transcripts stay on-device) |
| Allow Whisper model downloads | **On** (model files only — not your audio) |
| Preferred model | **Whisper Tiny** |
| Analytics / telemetry | **None** |

`mayDownloadModels` follows the download toggle. Local Only still fail-closes Apple Speech if on-device speech is unavailable.

## What stays on your Mac

- Audio capture (`AVAudioEngine`)  
- Transcription (**Whisper Tiny** by default after optional model download; **Apple Speech** built-in fallback, fail-closed under Local Only when on-device speech is unavailable)  
- History → `~/Library/Application Support/ZephyrFlow/`  
- Logs → `~/Library/Logs/ZephyrFlow/` (events + lengths, **never transcript text**)  
- Whisper model files → Hugging Face / WhisperKit cache (not the history folder); see Settings → Model

## Fail-closed Local Only

If Local Only is on and Apple Speech cannot run on-device for your locale, ZephyrFlow **errors** instead of sending audio to Apple servers. Install the language pack under System Settings, or turn Local Only off knowingly.

## How to audit in 60 seconds

```bash
rg -n "analytics|telemetry|Sentry|Firebase" Sources
rg -n "URLSession" Sources   # expect only UpdateChecker (manual GitHub Releases check)
rg -n "preferredModel|allowModelDownloads|localOnlyMode|mayDownloadModels" Sources/ZephyrFlowCore/Models.swift
swift run ZephyrFlowCoreTests
# Expect: localOnly=true, preferredModel=whisperTiny, allowModelDownloads=true
```

`UpdateChecker` is the only first-party `URLSession` use — HTTPS to GitHub Releases **on button click only**.

See also [Security](../operations/security.md). Full audit dumps are not kept in-repo (see [Audits policy](../development/audits.md)).


## Check for Updates

Settings → **About** → **Check for Updates** (also in the menu bar) contacts **GitHub Releases only when you click the button**. There is no background update polling or telemetry. The request uses HTTPS to `api.github.com` for this repository’s latest release tag and asset list.


## Settings that affect privacy

| Control | Default | Network? |
|---------|---------|----------|
| Local Only | On | Blocks off-device Apple Speech fallback |
| Allow Whisper model downloads | On | One-time model **file** fetch only |
| Flow backend | Classic | Enhanced is on-device rules only (no network) |
| Check for Updates | Manual | GitHub Releases API **on button click only** |
