# Release

## Versioning

Semantic versioning. Public preview line is `0.x.y`. **First public tag is `v0.0.0`** (intentional).

## Checklist before prepare

1. `VERSION` matches intended release  
2. `Constants.version` and `Info.plist` match  
3. `CHANGELOG.md` has `## [x.y.z] - YYYY-MM-DD`  
4. `swift run ZephyrFlowCoreTests` passes  
5. `./Scripts/build_app.sh release` succeeds on Apple Silicon  

## Flow

```text
1. workflow_dispatch → Prepare Release (version=0.0.0)
2. Merge release/0.0.0 PR into main
3. release-tag creates v0.0.0
4. release.yml builds macOS arm64 app zip + checksums
```

## Manual tag (fallback)

```bash
git tag -a v0.0.0 -m "Release v0.0.0"
git push origin v0.0.0
```

## Assets

| Asset | Contents |
|-------|----------|
| `ZephyrFlow-macos-arm64.app.zip` | `ZephyrFlow.app` |
| `SHA256SUMS` | Checksums |

Builds are **ad-hoc signed** until Developer ID is configured.

## Developer ID + notarization (optional)

When Apple Developer secrets are configured in GitHub Actions, `release.yml` signs with
**Developer ID Application**, submits to notarytool, staples, then publishes the zip.

### Required secrets

| Secret | Purpose |
|--------|---------|
| `APPLE_DEVELOPER_ID_CERT_P12_BASE64` | Base64-encoded .p12 Developer ID Application cert |
| `APPLE_DEVELOPER_ID_CERT_PASSWORD` | Password for the p12 |
| `APPLE_API_KEY_ID` | App Store Connect API key id |
| `APPLE_API_ISSUER` | Issuer UUID |
| `APPLE_API_KEY_P8` | Contents of the .p8 key |
| `APPLE_TEAM_ID` | Team ID |

If any secret is missing, the job keeps **ad-hoc** signing (current preview path) and logs that mode.

### Local verify

```bash
codesign --verify --deep --strict --verbose=2 Dist/ZephyrFlow.app
spctl --assess --type execute --verbose Dist/ZephyrFlow.app
```
