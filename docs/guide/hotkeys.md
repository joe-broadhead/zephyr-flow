# Hotkeys

## Default: hold Fn

ZephyrFlow uses a Wispr-style **hold-to-talk** Fn / Globe key:

1. Press and hold **Fn**
2. Speak
3. Release to finalize, clean text, restore focus, and insert

Detection uses `CGEventFlags.maskSecondaryFn` and key code `0x3F` on a dedicated event-tap thread.

While Fn is the hotkey, ZephyrFlow temporarily sets the system **Globe key** action to “Do Nothing” so the emoji picker does not steal the key. The previous preference is restored on quit, and recovered automatically after a crash.

## Alternatives (Settings → Hotkey)

| Hotkey | Notes |
|--------|-------|
| Fn | Default |
| Right Option | Good if Fn is awkward on your keyboard |
| Right Command | Modifier-only |
| Control + Space | Standard combo |
| Option + Space | Standard combo |

## Modes

| Mode | Behavior |
|------|----------|
| Hold to Talk | Press = start, release = insert |
| Toggle | First press start, second press insert |

## Tips

- Grant **Accessibility** or the hotkey tap stays limited  
- Menu **Start Dictation** always works as a fallback  
- Enable **Debug logging** in Privacy settings if Fn seems dead, then check `~/Library/Logs/ZephyrFlow/zephyrflow.log`

## Panel keys (while listening / processing)

| Key | Action |
|-----|--------|
| **Esc** | Cancel session |
| **⌘.** | Cancel session |
| **Return** | Stop & insert |

These are handled only while the floating panel is in an active session state so they do not leak into the target app after insert.
