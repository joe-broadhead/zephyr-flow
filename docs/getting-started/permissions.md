# Permissions

ZephyrFlow needs three permissions. None of them imply network access.

| Permission | Why |
|------------|-----|
| **Microphone** | Capture audio for on-device speech recognition |
| **Speech Recognition** | Apple Speech framework (default engine) |
| **Accessibility** | Global Fn hotkey + insert text at the caret |

## How to grant

**System Settings → Privacy & Security**

- Microphone → ZephyrFlow  
- Speech Recognition → ZephyrFlow  
- Accessibility → ZephyrFlow (toggle off/on after rebuilds)

**System Settings → Keyboard → Dictation**

- Turn **Dictation** **On**  
  Apple’s Speech framework will not produce text while system Dictation is off (`Siri and Dictation are disabled`).

Or use the in-app prompts / menu item **Enable Accessibility…**.

## What we never request by default

- Full Disk Access  
- Input Monitoring (optional future)  
- Analytics / telemetry network

## System Fn / Globe key

New installations use Control-Option-Space. Fn is experimental. Selecting Fn
does not authorize a system Globe-key change: a separate explicit override
opt-in and verified tap preparation are required. An acknowledged recovery
journal preserves the exact supported prior value/type. Failed/uncertain
recovery blocks Fn; use the explicit retry/reset control and check its result.
Never guess/remove the original global preference. Real crash/power-loss and
keyboard/OS support remain unqualified.

## Ad-hoc signing note

Preview builds use ad-hoc codesign (`codesign -s -`). macOS may treat each rebuild as a new identity for TCC. Re-toggle Accessibility after updating the app until Developer ID signing ships.
