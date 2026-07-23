# Security Policy

## Reporting a Vulnerability

Please report security issues privately through GitHub Security Advisories for
this repository. If advisories are unavailable, contact the maintainer through
the repository owner's GitHub profile before opening a public issue.

Do **not** include vulnerability details, exploit steps, or private logs in
public issues or pull requests.

## Scope notes

ZephyrFlow is a local macOS dictation utility. Reports are especially welcome for:

- Unexpected network access on default (Local Only) settings
- Transcript leakage outside Application Support / intended UI
- Accessibility or event-tap abuse beyond stated product behavior
- Supply-chain issues in release artifacts

## Supported versions

Until the first stable (`1.x`) release, security fixes target the latest
published release and the default branch.

## Preview signing

`v0.x` builds are ad-hoc signed and not notarized. Treat them as developer
preview binaries. Notarized Developer ID builds are planned before broad
distribution.
