# Troubleshooting

## Fn does nothing

1. Menu bar should show `Hotkey: Fn ✓`  
2. If you see **Enable Accessibility…**, grant it and wait 1–2 seconds  
3. After a rebuild, toggle Accessibility off/on  
4. Enable **Debug logging** (Settings → Privacy) and watch:
   ```bash
   tail -f ~/Library/Logs/ZephyrFlow/zephyrflow.log
   ```
   Look for `Hotkey PRESS (Fn)` / `Hotkey RELEASE (Fn)`

## Dictation works but text does not insert

- Click into a real text field first  
- Accessibility must be on for paste/AX  
- Secure fields never receive insert (clipboard only)  
- Logs should show `Pre-insert focus restored` and `Insertion result`

## “No speech detected”

- Speak longer / closer to the mic  
- Check Microphone permission  
- Confirm Speech Recognition is granted  

## “macOS Dictation is turned off” / Siri and Dictation are disabled

Apple Speech requires the **system Dictation** switch:

1. **System Settings → Keyboard → Dictation → On**  
2. Retry hold-Fn dictation  

This is separate from granting ZephyrFlow “Speech Recognition” permission.

## Local Only error about on-device speech

Your locale lacks an on-device Apple Speech model. Either:

- Install the language pack in System Settings, or  
- Knowingly turn off Local Only  

## Globe / emoji key feels wrong after a crash

1. Launch ZephyrFlow once — it restores the previous preference automatically.  
2. Or Settings → Privacy → **Reset system Fn / Globe key preference**.  
3. Or:
```bash
defaults delete com.apple.HIToolbox AppleFnUsageType 2>/dev/null || true
```

While Fn is the hotkey, ZephyrFlow sets Globe to “Do Nothing” so the emoji picker does not steal the key. Quitting normally restores your previous setting.

## Build fails (WhisperKit / packages)

```bash
rm -rf .build
swift package resolve
./Scripts/build_app.sh release
```


## Model won’t download / stays “Not downloaded”

1. Settings → **Privacy** → ensure **Allow Whisper model downloads** is on  
2. Settings → **Model** → select Whisper Tiny → watch status  
3. Check network access to Hugging Face (model host)  
4. Or switch to **Apple Speech** (needs Speech Recognition + system Dictation On)

## Check for Updates fails

- Requires network to `api.github.com`  
- Only runs when you click the button (Settings → About or menu bar)  
- If you’re already on the latest tag, you’ll see “latest version”
