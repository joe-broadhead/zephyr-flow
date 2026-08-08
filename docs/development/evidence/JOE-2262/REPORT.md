# JOE-2262 — at-rest history encryption (defense-in-depth)

**Run:** 20260808T103416Z · branch `agent/zephyr-production-run-20260808T103416Z`

## Core (`Sources/ZephyrFlowCore/HistoryCipher.swift`, AppKit-free)

- `HistoryCryptoKey` (keyID + 32-byte material).
- `HistoryEncryptedPayload`: version, cipher name (AES-256-GCM), keyID,
  nonce, ciphertext, authTag.
- `HistoryCipherEngine`: authenticated AES-256-GCM via CryptoKit; `decrypt`
  returns nil on ANY auth failure (wrong/missing key, tamper) — never
  partial plaintext.
- `EncryptedHistoryDocument` (schema 1): sealed entries + documented visible
  metadata (schemaVersion, encryptionVersion, cipher, keyID; entry bodies
  sealed).
- `HistoryEncryptionMigration`: atomic encrypt/decrypt of the full document.
- `ActorHistoryRepository`: optional keyProvider; encrypted persistence when
  a key is available; missing/inaccessible key -> recoveryState, NO plaintext
  exposed, sealed content retained on disk; write failures never mix old/new
  (atomic replace).

## App wiring

- `HistoryKeychainStore`: per-installation random 256-bit key as a
  NON-synchronizing Keychain item, `kSecAttrAccessibleAfterFirstUnlock`
  (least permissive compatible with launch-at-login); key material never
  enters logs/metrics/backups/iCloud/support bundles.
- `DictationController.start()` configures the repository with the Keychain
  key.
- SettingsView History section documents encryption honestly (AES-256-GCM,
  visible metadata, not a FileVault substitute).

## Acceptance criteria

- Transcript content not recoverable from the history file alone — raw-file
  test asserts no transcript substring + encrypted-doc marker.
- Wrong/missing keys fail authentication, never partial plaintext — tamper/
  wrong-key/missing-key tests.
- Migration interruption leaves old or new consistent store, never mixed —
  write-failure fault injection keeps the old store readable.
- Secure/unknown sessions excluded regardless of encryption — policy tests.
- Key material never in logs/metrics/backups/support bundles — key-bytes-
  absent test + Keychain-only storage + SupportBundle canary (JOE-2265).

## Deterministic tests (18 JOE-2262 checks)

Round-trip; tamper fails auth; wrong key fails; cipher/version/keyID stored;
metadata documented; migration decrypt; raw file has no transcript; raw file
is encrypted doc; repo decrypt round-trip; missing key -> no entries +
recovery state; sealed content retained; migration failure keeps old store;
secure/unknown denied; key bytes absent from file. All pass.

## Remaining manual validation (human gate)

Keychain accessibility across reboot/login/launch-at-login on a real
machine; uninstall/reinstall key-rotation semantics — runbook retained.
