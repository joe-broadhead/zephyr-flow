# Hotkeys

## New-install default: Control-Option-Space

The human-selected default is **Control-Option-Space**. Existing saved choices
are preserved; changing the default does not reset personal shortcuts.

1. Press and hold **Control-Option-Space** (or your saved shortcut)
2. Speak
3. Release to finalize, process and attempt validated insertion or show review

Check System Settings → Keyboard → Keyboard Shortcuts and other installed apps
for conflicts. Availability is not guaranteed by configuration or unit tests.
Global shortcuts require Accessibility; menu controls do not require a hotkey.

## Fn / Globe is experimental

Fn detection uses `CGEventFlags.maskSecondaryFn` and key code `0x3F` on a
dedicated event-tap thread. Choosing Fn alone does not authorize a global
preference mutation. The separate experimental override opt-in requires verified
tap preparation and an acknowledged exact-value recovery journal. Failed or
uncertain recovery blocks Fn capture until explicitly resolved. Reset/recovery
does not immediately reapply the override in the same launch. Real OS/keyboard,
Globe conflict and crash/power-loss qualification remain incomplete.

## Alternatives (Settings → Hotkey)

| Hotkey | Notes |
|--------|-------|
| Control + Option + Space | New-install default; check conflicts |
| Fn / Globe | Experimental, opt-in selection |
| Right Option | Good if Fn is awkward on your keyboard |
| Right Command | Modifier-only |
| Right Control | Modifier-only; existing configurations preserved |
| Control + Space | Standard combo |
| Option + Space | Standard combo |

## Modes

| Mode | Behavior |
|------|----------|
| Hold to Talk | Press = start, release = insert |
| Toggle | First press start, second press insert |

## Tips

- Grant **Accessibility** or the hotkey tap stays limited  
- Menu **Start Dictation** does not require a working global shortcut; engine/permission/readiness gates still apply
- Enable **Debug logging** in Privacy settings if Fn seems dead, then check `~/Library/Logs/ZephyrFlow/zephyrflow.log`

## Panel keys

While a dictation session is active **and ZephyrFlow can receive key events** (e.g. you clicked the panel, or the menu bar extra is focused):

| Key | Action |
|-----|--------|
| **Esc** | Cancel session |
| **⌘.** | Cancel session |
| **Return** | Stop & insert |

During normal hold-to-talk, keyboard focus stays in the target app (by design for caret insert), so these shortcuts apply when the panel itself is key — not while typing in Notes mid-hold. Release the hotkey to finalize without using Return.
