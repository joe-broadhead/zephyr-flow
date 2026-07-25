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

## Panel keys

While a dictation session is active **and ZephyrFlow can receive key events** (e.g. you clicked the panel, or the menu bar extra is focused):

| Key | Action |
|-----|--------|
| **Esc** | Cancel session |
| **⌘.** | Cancel session |
| **Return** | Stop & insert |

During normal hold-to-talk, keyboard focus stays in the target app (by design for caret insert), so these shortcuts apply when the panel itself is key — not while typing in Notes mid-hold. Release the hotkey to finalize without using Return.
