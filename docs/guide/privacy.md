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
- Transcription (Apple Speech on-device when available; WhisperKit only if you opt in)  
- History → `~/Library/Application Support/ZephyrFlow/`  
- Logs → `~/Library/Logs/ZephyrFlow/` (events + lengths, **never transcript text**)

## Fail-closed Local Only

If Local Only is on and Apple Speech cannot run on-device for your locale, ZephyrFlow **errors** instead of sending audio to Apple servers. Install the language pack under System Settings, or turn Local Only off knowingly.

## How to audit in 60 seconds

```bash
rg -n "URLSession|analytics|telemetry|Sentry|Firebase" Sources
rg -n "preferredModel|allowModelDownloads|localOnlyMode|mayDownloadModels" Sources/ZephyrFlowCore/Models.swift
swift run ZephyrFlowCoreTests
# Expect: localOnly=true, preferredModel=whisperTiny, allowModelDownloads=true
```

See also [Security](../operations/security.md). Full audit dumps are not kept in-repo (see [Audits policy](../development/audits.md)).
