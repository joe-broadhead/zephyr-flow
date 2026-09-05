#!/usr/bin/env bash
# JOE-2299: explicit notarization operation; never invoked by CI/release preflight.
# Tests use private synthetic bundles and PATH tool doubles, not Apple services.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
usage() {
  printf '%s\n' 'Usage: notarize.sh --dry-run | --help'
  printf '%s\n' '       notarize.sh --run --app APP --identity CERT_SHA1 --team TEAM --profile KEYCHAIN_PROFILE --output NEW_DIR'
  printf '%s\n' 'Real execution requires separate human authorization and a preconfigured keychain profile.'
}
fail() { printf 'NOTARIZATION FAILED: %s\n' "$1" >&2; exit 1; }
if [[ $# -eq 0 || ( $# -eq 1 && "$1" == --dry-run ) ]]; then
  usage
  printf '%s\n' 'NOT RUN: copy -> sign -> verify identity/runtime -> submit -> Accepted -> staple/validate -> Gatekeeper -> final zip/checksum.'
  printf '%s\n' 'No credential access, signing, network submission or production acceptance performed.'
  exit 2
fi
if [[ $# -eq 1 && "$1" == --help ]]; then usage; exit 0; fi
[[ "$1" == --run ]] || fail 'unknown mode'
shift
APP='' IDENTITY='' TEAM='' PROFILE='' OUTPUT=''
while [[ $# -gt 0 ]]; do
  [[ $# -ge 2 && -n "$2" && "$2" != --* ]] || fail 'missing argument value'
  case "$1" in
    --app) [[ -z "$APP" ]] || fail 'duplicate app'; APP="$2" ;;
    --identity) [[ -z "$IDENTITY" ]] || fail 'duplicate identity'; IDENTITY="$2" ;;
    --team) [[ -z "$TEAM" ]] || fail 'duplicate team'; TEAM="$2" ;;
    --profile) [[ -z "$PROFILE" ]] || fail 'duplicate profile'; PROFILE="$2" ;;
    --output) [[ -z "$OUTPUT" ]] || fail 'duplicate output'; OUTPUT="$2" ;;
    *) fail 'unknown argument' ;;
  esac
  shift 2
done
[[ "$APP" == /* && "$OUTPUT" == /* && -n "$PROFILE" ]] || fail 'absolute app/output and keychain profile required'
[[ "$IDENTITY" =~ ^[a-fA-F0-9]{40}$ && "$TEAM" =~ ^[A-Z0-9]{10}$ ]] || fail 'explicit certificate fingerprint and team required'
[[ -d "$APP" && ! -L "$APP" && ! -e "$OUTPUT" && ! -L "$OUTPUT" ]] || fail 'app must exist and output must be new'
for tool in codesign ditto xcrun spctl python3; do command -v "$tool" >/dev/null || fail "missing tool: $tool"; done
python3 - "$APP" "$OUTPUT" <<'PY'
import os,pathlib,sys
app,output=(pathlib.Path(p).resolve() for p in sys.argv[1:])
if app == output or any(p.exists() and os.path.samefile(app,p) for p in output.parents):
    raise ValueError('output cannot be inside the input app')
PY

# Deliberately narrow support: the current SPM bundle has one main executable.
# Unknown nested executable code fails until its signing order is reviewed.
python3 "$ROOT/Scripts/release/validate_bundle.py" "$APP" "$ROOT/VERSION"
umask 077
mkdir "$OUTPUT"
printf 'NOTARIZATION INCOMPLETE\n' > "$OUTPUT/result.txt"
WORK_APP="$OUTPUT/ZephyrFlow.app"
ditto "$APP" "$WORK_APP"
python3 "$ROOT/Scripts/release/validate_bundle.py" "$WORK_APP" "$ROOT/VERSION"
codesign --force --options runtime --timestamp --sign "$IDENTITY" \
  --entitlements "$ROOT/Resources/ZephyrFlow.entitlements" "$WORK_APP"
codesign --verify --deep --strict "$WORK_APP"
codesign --display --verbose=4 "$WORK_APP" > "$OUTPUT/signature.txt" 2>&1
python3 - "$OUTPUT/signature.txt" "$TEAM" <<'PY'
import pathlib,re,sys
text=pathlib.Path(sys.argv[1]).read_text()
for pattern,message in [
    (r'^Identifier=dev\.zephyrflow\.app$', 'bundle signature mismatch'),
    (r'^TeamIdentifier='+re.escape(sys.argv[2])+r'$', 'team signature mismatch'),
    (r'^Authority=Developer ID Application:', 'Developer ID required'),
    (r'^CodeDirectory .*flags=.*\bruntime\b', 'hardened runtime required')]:
    if not re.search(pattern,text,re.M): raise ValueError(message)
PY
ditto -c -k --sequesterRsrc --keepParent "$WORK_APP" "$OUTPUT/submission.zip"
# A profile is a reference to existing credentials. Never echo or import keys.
xcrun notarytool submit "$OUTPUT/submission.zip" --keychain-profile "$PROFILE" --wait --timeout 30m \
  --output-format json > "$OUTPUT/notary-submit.json"
python3 - "$OUTPUT/notary-submit.json" <<'PY'
import json,pathlib,sys,uuid
result=json.loads(pathlib.Path(sys.argv[1]).read_text())
if result.get('status')!='Accepted': raise ValueError('notary status is not Accepted')
uuid.UUID(result['id'])
PY
xcrun stapler staple "$WORK_APP"
xcrun stapler validate "$WORK_APP"
codesign --verify --deep --strict "$WORK_APP"
spctl --assess --type execute --verbose=2 "$WORK_APP" > "$OUTPUT/gatekeeper.txt" 2>&1
ditto -c -k --sequesterRsrc --keepParent "$WORK_APP" "$OUTPUT/ZephyrFlow-macos-arm64.app.zip"
python3 - "$OUTPUT" <<'PY'
import hashlib,json,pathlib,sys
p=pathlib.Path(sys.argv[1]); archive=p/'ZephyrFlow-macos-arm64.app.zip'
if not archive.is_file() or archive.is_symlink() or archive.stat().st_size <= 0:
    raise ValueError('final archive missing or empty')
h=hashlib.sha256()
with archive.open('rb') as f:
    for block in iter(lambda:f.read(1024*1024),b''): h.update(block)
(p/'SHA256SUMS').write_text(f'{h.hexdigest()}  {archive.name}\n')
(p/'result.txt').write_text('NOTARIZATION COMMANDS VERIFIED\nPRODUCTION ACCEPTANCE NOT ESTABLISHED\n')
PY
printf '%s\n' 'Notarization commands verified. Clean-Mac qualification, independent review and human GO remain separate.'
