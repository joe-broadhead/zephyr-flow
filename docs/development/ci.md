# CI & Quality

## Workflows

| Workflow | Trigger | Purpose |
|----------|---------|---------|
| `ci.yml` | push / PR | macOS build + core tests; docs strict build |
| `docs.yml` | docs paths + main | MkDocs → GitHub Pages |
| `release-prepare.yml` | manual | Open `release/x.y.z` PR |
| `release-tag.yml` | merged release PR | Create `vX.Y.Z` tag |
| `release.yml` | tag `v*` | Build `.app`, checksums, GitHub Release |

## Local parity

```bash
swift run ZephyrFlowCoreTests
./Scripts/build_app.sh release
python -m pip install -r docs/requirements.txt
mkdocs build --strict
```

## Version source of truth

- `VERSION` file (semver without `v`)
- `Sources/ZephyrFlow/Utilities/Constants.swift`
- `Resources/Info.plist` (`CFBundleShortVersionString`)
- `CHANGELOG.md` section `## [x.y.z]`

## Branch protection (`master`)

Configured via GitHub branch protection (not optional for direct pushes):

| Rule | Setting |
|------|---------|
| Require pull request | Yes (0 approvals — solo maintainer; raise when needed) |
| Dismiss stale reviews | Yes |
| Require conversation resolution | Yes |
| Required checks | `Test & Build (macOS)`, `Docs`, `Version sync` |
| Require branch up to date | Yes (strict) |
| Require linear history | Yes |
| Restrict force pushes | Yes |
| Restrict deletions | Yes |
| Enforce for admins | Yes |
| Delete head branch on merge | Yes |

Direct `git push origin master` is blocked; open a PR instead.
