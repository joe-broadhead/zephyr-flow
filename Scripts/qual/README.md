# Qualification scripts (JOE-2297/2257/2273/2274/2294/2295/2296/2303)

These helpers prepare **INCOMPLETE runbooks**, not qualification passes. They
do not drive the app, collect real sessions, validate a running artifact, post
keyboard events or change system preferences. The former no-op soak/focus and
hardware loops are not device evidence. Core contract assertions are labeled
separately and do not satisfy the accompanying device checklist.

Each script supports `--help`. Optional counts/minutes are positional positive
integers; unsupported flags/extra arguments fail. Insertion, privacy and rapid
control helpers run the Core suite once, retain its full log and require exit
zero plus assertion/completion markers. A failure cannot be hidden by output
that also contains earlier passing assertions.

- Exit **2**: device work **NOT RUN / INCOMPLETE** (the expected runbook result).
- Exit **1**: metadata/tool/Core/argument failure; still not qualification.
- Exit **0**: help only. No current helper can emit an overall qualification PASS.

Reports default to a unique temporary directory outside the repository. Set
`QUAL_REPORT_DIR` to another external evidence directory if needed. Repo HEAD
and machine metadata are not a substitute for candidate artifact hash,
OS/target-app versions, executed case/terminal counts, measured outcomes and
independent review. Never commit generated reports, personal logs or transcript
bodies. Core logs contain synthetic fixtures only; real-device evaluation must
keep permitted reference/hypothesis content separate from content-free reports.
