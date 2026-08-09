# Remediation Plan — post-review rework (run 20260808T103416Z)

Source of truth: `review-findings.md` (review verdict, source-confirmed).
Order: fix the P0 invariants first, then test wiring, then CI, then re-review.

## Phase 1 — Session lifecycle + audio (P0, highest risk)

- [x] **R1.1 BoundedAudioChannel**: make admission release on dequeue (real
      bounded producer-consumer queue) or use an explicitly bounded
      AsyncStream policy with yield as authoritative admission. Test: send
      many multiples of capacity through a slow consumer; occupancy returns
      to zero; no loss.
- [x] **R1.2 Audio format metadata**: capture a genuinely mono buffer and
      label it mono, or preserve every channel in correct planar/interleaved
      layout. Remove the fixed `16_000/16_000` reconcile; track actual source
      rate and reconcile `engineRate / sourceRate`; tested rounding policy.
- [x] **R1.3 Drain barrier**: establish final sequence + begin barrier before
      closing admission; single consumer acknowledges the EOS marker;
      actor-isolate accounting/barrier; real timeout on consumer completion;
      successful capture requires `.drained`.
- [x] **R1.4 Control plane**: immediately-addressable session/control token
      before model preparation; release/cancel go direct to control plane;
      durable command buffering before orchestration starts.
- [x] **R1.5 State machine**: legal `SessionControlModel` transitions are the
      only mechanism that advances orchestration; reject/stop on illegal
      transition; one terminal function atomically sets terminal state,
      emits one versioned terminal event, releases resources, makes duplicate
      completion observable.
- [x] **R1.6 Controller cleanup**: identity-checked `sessionDidFinish`
      clears session/task/stateTask exactly once, resets hotkey toggle, then
      applies terminal UI dismissal policy.

## Phase 2 — Target + sensitivity boundaries

- [x] **R2.1 Validate+insert as one transaction** against the same resolved
      element identity; disable automatic insertion where stable identity is
      unavailable; revalidate PID/process-start/window/element/role/
      sensitivity/settable immediately before mutation in the same isolated op.
- [x] **R2.2 AX timeout semantics**: never begin a write unless the remaining
      deadline suffices; AX messaging timeout / serial AX worker; timed-out
      side-effecting call never described as "nothing was inserted".
- [x] **R2.3 Remove automatic secure/fallback clipboard writes**: secure/
      unknown/changed/failed targets never auto-write clipboard; only the
      explicit review-panel action returns `.explicitlyCopiedByUser`;
      `permitsHistoryRetention == false` for every automatic copy/fallback.

## Phase 3 — Engine completeness

- [x] **R3.1 Apple Speech**: one actor-owned finalization state; explicit
      deadline task resolves exactly one continuation; error provenance
      preserved; errored partial is `.partial`/`.degraded`, never `.complete`.
- [x] **R3.2 WhisperKit**: chunked complete-audio finalization or visible hard
      recording limit; never reset `DecodeOwnership` until native work ends or
      engine quarantined; snapshot + apply language at session start.

## Phase 4 — History

- [x] **R4.1** Remove legacy `HistoryStore` writer; one actor repository;
      load() before UI/sessions mutate; Keychain provider configured in
      production; async UI view model; surface every persistence error.

## Phase 5 — Flow

- [x] **R5.1** Globally unique placeholders or per-line span restore before
      joining; failed protected-span check rejects output and returns the
      conservative fallback with a controlled reason.

## Phase 6 — Model acquisition binding

- [x] **R6.1** Downloads default disabled until explicit onboarding consent;
      load the exact verified artifact (or verified immutable manifest
      WhisperKit demonstrably consumes); readiness = "exact verified artifact
      loaded".

## Phase 7 — Integration tests (replace model-only evidence)

- [x] **R7.1** Deterministic integration tests instantiating the production
      coordinator with fakes proving: release-during-preload cancels; second
      session starts after first terminates; source-rate accounting
      reconciles; no AX write after target switch/deadline; automatic secure
      copy impossible; one terminal category emitted; history encryption
      genuinely configured.

## Phase 8 — CI + exact-candidate gate

- [x] **R8.1** Fix `ci_checks.sh` strict-concurrency (`|| true` swallow),
      stage numbering, YAML fallback, drift-vs-coverage ordering; shellcheck
      all `Scripts/**`; gate actually runs sanitizer/rapid-control/crash lanes.
- [x] **R8.2** Pin all third-party Actions to full SHAs; add missing qual
      scripts (focus_stress, secure_field_probe, accessibility_probe,
      hardware_profile, soak_1000) referenced by human-gates.md.
- [x] **R8.3** Open a PR from the corrected branch; run full macOS/Xcode CI
      (XCTest, release build, corrected lanes) at the exact candidate SHA;
      ensure no tracked file is generated by the gate; attach reports to the
      terminal commit; generate a new ledger/final-report from that SHA.
- [x] **R8.4** Re-run the root-owned final gate at the new terminal SHA and
      record the pass in gate-evidence.md (ledger `integration_head` == HEAD
      at the exact validated commit).

## Done-criteria for re-review

All 24 reopened issues green with production-wiring integration tests; CI gate
fail-closed at exact SHA; gate passes; ledger regenerated from the tested SHA;
fresh independent review requested.
