# Distribution implementation status

**Not production-approved. Nothing here authorizes a release operation.**

The human approved implementation and isolated tests on 2026-09-05, excluding
real signing/notarization, credential access, environment/protection changes,
merges, tags, Releases and publication. Do not execute the real operation during
an implementation/test run.

## Fail-closed workflows

The three release workflows are manual, read-only preflights. Automatic
merge→tag→publish and ad-hoc production fallback are removed. An exact candidate
SHA must match its existing tag and version, but this alone is not acceptance.
All preflights deliberately fail until a separately reviewed acceptance verifier
binds the candidate, artifact hashes, device qualification, independent review
and explicit human GO. There is no override flag, secret-presence shortcut, or
boolean input that enables publication. No environments/protection rules were
created by this change. Existing original-stack workflows remain in history.

## Notarization operation (not executed against Apple)

`bash Scripts/release/notarize.sh --dry-run` exits **2 / NOT RUN**. `--help` exits
0. Invalid arguments or failed checks exit 1. Real `--run` is implemented but
requires separate human authorization. Use an existing Keychain profile
reference; never paste keys into configuration or command-line arguments.

The operation works on a newly created private copy of the app and leaves the
input untouched. It requires the source version and `dev.zephyrflow.app`
identity, an explicit certificate fingerprint/team, hardened runtime, a
Developer ID signature, an Accepted notary response, a stapled/validated ticket,
post-staple signature verification and a Gatekeeper assessment. It then packages
and hashes the **post-staple** app. Failed runs retain an INCOMPLETE marker and
diagnostics in the caller-selected new output directory. There is no silent
ad-hoc fallback and no publication step.

Supported signing layout is deliberately narrow: the current SPM app with one
thin arm64 Mach-O executable. Symlinks and nested executable code are rejected rather
than blindly signed with `--deep`. Additional frameworks/helpers need reviewed
inside-out signing support. Native code signing, Apple credentials/network,
clean-Mac launch and actual distribution have **not** been qualified by mocks.

## Supply chain remains incomplete

`supply-chain.sh --dry-run` exits 2, not success. `--run` refuses execution.
`Package.resolved` and `swift package dump-package` are metadata, not a complete
SBOM, signed provenance or signed update manifest. Generation, verification,
trust roots and update-channel policy still need implementation/review; no
dependencies/tools are added without approval. A notarized ZIP alone is not a
release-qualified artifact.

## Validation

`python3 -m unittest discover -s Tests/CI -p 'test_release_*.py'` uses private
synthetic app bundles and codesign/ditto/xcrun/spctl doubles. It verifies command
order, failure exits and output state only. It never imports a certificate,
touches a real Keychain, sends a notarization request, tags or uploads anything.
Full Core tests and strict MkDocs are also required before commits.
