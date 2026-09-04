#!/usr/bin/env bash
# JOE-2300/2301/2302 prepared supply-chain manifests (DRY-RUN; inert until
# JOE-2298 channel decision + credentials).
set -euo pipefail
echo "Prepared supply-chain steps (not executed — blocked by JOE-2298 P2):"
echo "  1. exact-tag checkout:  git fetch --tags && git checkout v<tag> &&"
echo "     git fsck --full && git rev-parse HEAD > DIST_SHA"
echo "  2. full-SHA acceptance: verify committed tree matches built app."
echo "  3. SBOM:                swift package dump-package > sbom-package.json;"
echo "     syft dir:. -o spdx-json > sbom.spdx.json (third-party inventory)."
echo "  4. checksums:           shasum -a 256 Dist/ZephyrFlow.app.zip > SHA256SUMS"
echo "  5. provenance:          cosign attest-blob --type spdx ... (when cosign)"
echo "  6. signed update manifest: Scripts/release/update-manifest.json template"
echo "     (schema: {version, channel, arch, sha256, url, minOS, signature})."
echo "Run only after JOE-2298 chooses the production channel and credentials exist."
exit 0
