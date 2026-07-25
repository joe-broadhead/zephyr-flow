# Insertion reliability matrix

Manual results for Automatic insertion mode (`InsertionStrategyResolver`).  
Update this table when validating on a new macOS / app version.

| App | Bundle ID | Result | Winning strategy | Notes |
|-----|-----------|--------|------------------|-------|
| Notes | `com.apple.Notes` | pass | clipboardPaste | Focus restore + Cmd+V |
| TextEdit | `com.apple.TextEdit` | pass | clipboardPaste | |
| Terminal | `com.apple.Terminal` | pass | terminalPaste → clipboardPaste | Paste semantics |
| Safari (text field) | `com.apple.Safari` | pass | clipboardPaste | |
| VS Code | `com.microsoft.VSCode` | pass | clipboardPaste | Electron; AX secondary |
| Slack | `com.tinyspeck.slackmacgap` | pass | clipboardPaste | Electron |
| iTerm2 | `com.googlecode.iterm2` | manual | terminalPaste | Validate on device |
| Xcode | `com.apple.dt.Xcode` | manual | clipboardPaste | Validate on device |
| Chrome contenteditable | `com.google.Chrome` | manual | clipboardPaste | Site-dependent |
| Notion | `notion.id` | manual | clipboardPaste | Validate on device |
| Messages | `com.apple.MobileSMS` | manual | clipboardPaste | |
| Secure password field | (any) | pass | copyOnly | Never AX-inject |

**Policy**

- Secure roles → copy only  
- Terminals → terminal paste then clipboard  
- Editors / Electron / browsers → paste then AX selectedText then AX value  
- Default → paste, AX selectedText, AX value, copy only  

**User override:** Settings → General → Insertion mode (`Automatic` / `Always paste` / `Always copy only`).
