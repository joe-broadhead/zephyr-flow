# Security

See also the repository root [SECURITY.md](https://github.com/joe-broadhead/zephyr-flow/blob/master/SECURITY.md).

## Threat model (preview)

ZephyrFlow is a **local** dictation utility. Primary risks:

| Risk | Mitigation |
|------|------------|
| Accessibility abuse | Only used for caret insert + hotkey; no remote control surface |
| Clipboard transient secrets | Restore previous pasteboard when safe; secure fields never AX-injected |
| Transcript leakage via logs | Lengths/events only — never body text |
| Unwanted network | No analytics; Local Only keeps audio on-device; model download is a separate toggle (on by default for Tiny) |
| System Fn/Globe override | Restored on quit; crash recovery on next launch; Settings → Reset Fn preference |
| Stuck Globe-key pref | Crash-recovery marker restores on next launch |

## Reporting

Use GitHub Security Advisories. Do not file public issues with exploit detail.

## Signing

`v0.x` ships **ad-hoc signed**. Notarized Developer ID builds are planned before broad distribution.
