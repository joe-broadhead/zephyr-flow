# Models

## Whisper Tiny (default)

Backed by [WhisperKit](https://github.com/argmaxinc/WhisperKit). Downloads once (~75 MB) into Application Support, then runs fully on-device.

## Apple Speech (built-in fallback)

- No download  
- Forced on-device when the locale supports it  
- Fail-closed under Local Only if on-device is unavailable  

## Other WhisperKit models

| Model | Approx size | Notes |
|-------|-------------|-------|
| Tiny | ~75 MB | Fast |
| Base | ~150 MB | Balanced |
| Small | ~500 MB | Higher quality |

### Downloads

Downloads are **on by default** for Whisper Tiny. Toggle under Settings → **Privacy** → Allow Whisper model downloads.

Files land once in Application Support and run on-device (Neural Engine on Apple Silicon).

!!! note
    Local Only still applies to **your audio and transcripts**. Model download is a separate one-time file fetch.

!!! note "Long dictations"
    The WhisperKit path keeps roughly the **most recent 60 seconds** of audio in memory for the final pass. Prefer Apple Speech or shorter segments for long-form.
