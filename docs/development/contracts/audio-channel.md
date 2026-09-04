

## Drain barrier + frame accounting (JOE-2248)

Finalization begins only after every accepted frame reached the engine or was
explicitly classified as dropped. `AudioDrainBarrier` drains through the
final accepted producer sequence (deadline-aware, cancellable, late appends
counted). `AudioFrameAccounting` reconciles captured/converted/delivered/
dropped counts; successful sessions must satisfy the exact invariant within
the explicitly defined converter rounding tolerance; any gap/overflow/timeout
⇒ degraded, never complete. Counts only — never audio payloads.
