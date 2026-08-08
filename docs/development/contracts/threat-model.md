# Zephyr Flow threat model, sensitivity classification and data-flow inventory

**Owner:** Security/Privacy track.
**Source:** JOE-2241 · milestone M0.
**Status:** Accepted baseline; extended by named issues.

## 1. Sensitivity classification

| Class | Meaning | Automatic history | Clipboard fallback | Payload diagnostics |
|-------|---------|-------------------|--------------------|---------------------|
| `normal` | Ordinary target | allowed under user policy | allowed | allowed under policy |
| `secure` | Password-style / protected target | **forbidden** | **forbidden** | **forbidden** |
| `unknown` | No evidence available | **forbidden (fail closed)** | **forbidden (fail closed)** | **forbidden (fail closed)** |

Unknown always fails closed (I5/I8). Evidence sources: AX role, target
metadata, user policy, or none (`unknown`).

## 8. Data-flow inventory

| Surface | Content | Owner | Lifetime | Storage | Deletion |
|---------|---------|-------|----------|---------|----------|
| PCM buffers | audio | audio session | session | memory | after drain disposal |
| Partials | interim text | session | session | memory | terminal disposal |
| Final text | transcript | session/Flow | session | memory | per retention policy |
| Flow output | transformed text | Flow stage | session | memory | per retention policy |
| Clipboard | text snapshot | pasteboard transaction | transaction | system clipboard | restore on completion |
| History | stored transcripts | HistoryStore | opt-in, bounded (age/bytes) | app container | user delete / limits |
| Settings | prefs + migration provenance | SettingsStore | persistent | app container | versioned migration |
| Logs | lengths/ids only, never bodies | ZFLog | bounded | log file | size cap |
| Metrics | versioned controlled events | MetricsSink | bounded | app container | age/byte cap |
| Support bundles | operational evidence (no payloads) | SupportBundle | on request | temp | removed after export |
| Model caches | model files | ModelAcquisition | persistent | app caches | user delete |
| Update traffic | version endpoints | UpdateChecker | transient | memory | n/a |
| Crash/recovery | state markers | Recovery | transient | app container | recovery complete |

Every transcript- or audio-bearing surface records: owner, lifetime, storage
location, sensitivity and deletion policy (JOE-2265 verification target).

## 3. Adversaries and failure modes

| Threat | Description | Mitigation |
|--------|-------------|------------|
| A1 | Compromised dependency/update channel | Pinned SHA actions, verified downloads, signed update manifest (M5) |
| A2 | Malicious or hung target app | Bound AX calls, revalidation, no silent fallback (JOE-2268/2270) |
| A3 | Stale callback from old session | SessionID-bound callbacks, absorbing terminals (JOE-2249/2253) |
| A4 | Clipboard observer | Lossless bounded paste transaction, restore on failure (JOE-2260) |
| A5 | Local multi-user access | File permissions, Keychain-scoped keys (JOE-2262) |
| A6 | Crash during persistence | Transactional settings/history writes, recovery markers (JOE-2263/2266) |
| A7 | Accidental diagnostics export | Support bundles contain no payloads; privacy canary scans (JOE-2265) |
| A8 | Model-cache tampering | Verified acquisition, digests over heuristic scanning (JOE-2255) |
| A9 | Global preference damage (Fn path) | Exact snapshot/restore transactions (JOE-2286) |
| A10 | Secure/unknown content escape | Fail-closed policy; canary matrix across every surface (JOE-2297) |

## 4. Permission/entitlement map

| Permission | Need | Path |
|------------|------|------|
| Microphone | WhisperKit/Apple Speech capture | required for all audio paths |
| Speech Recognition | Apple Speech | required only for Apple Speech |
| Accessibility | hotkeys + AX insertion | required for Fn path & automatic insertion |
| Model downloads | WhisperKit | explicit user consent gated (JOE-2283) |
| Launch at Login | SMAppService | transactional toggle (JOE-2290) |

Network behaviour is enumerated per user setting:
- `localOnlyMode=true` → no uploads; Apple Speech disabled; WhisperKit model
  downloads remain optional only via `allowModelDownloads`.
- `allowModelDownloads=false` → no model download network traffic.
- Update checker → HTTPS to the approved release endpoint only.

## 5. Abuse cases and privacy canaries

Canary plan (JOE-2297) injects unique synthetic markers into normal, secure
and unknown sessions across success/failure/cancellation/crash/recovery, then
scans every surface listed above. Secure/unknown markers have a
zero-tolerance forbidden-surface policy; normal expected locations must be
declared explicitly.

## 6. Open risks

| Risk | Named issue |
|------|-------------|
| First-version update channel not yet production-hardened | JOE-2298, JOE-2302 |
| AX elements vary across apps | JOE-2273 insertion matrix |
| Real-device evidence unavailable to automated agents | JOE-2294/2296 |

This file is extended by `security.md` operations guidance and by
implementation issues as they land.
