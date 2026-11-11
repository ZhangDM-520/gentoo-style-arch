# Scratchpad

**Active:** blind review exercise — round 2 running (5 personae), round 1 fixed
and shipped as 14 commits.

## State
- Round 1: DONE (3 personae). 14 fixes committed, battery 56/56 green,
  summary at `~/Workspace/gsa-lab/runs/r1/SUMMARY.md`.
- Round 2: IN FLIGHT — containers `gsa-lab-r2-{newcomer,path-space,
  recovery-user,perf-tuner,kernel-tinkerer}` on image `gsa-lab:2`
  (binary from `target/release/gsa` @ 4706d2a + refreshed `/src`).
  Reports land in `~/Workspace/gsa-lab/runs/r2/<persona>/report.md`.
- Rounds 3 and 4 pending (5 personae each, roster in plan.md).
- Enhancement backlog (final discussion): `-Mh` addressable run id,
  `--skip` waiver reason, `-U <path>` unindexed hash gate (contract open
  decision I2), non-ELF token `sha256("")`, `-B` missing-house-dep preflight.

## Next action
When the five round-2 agents report: triage each finding (bug/enhancement/
unproven), fix every reproducible bug one commit each with a red-first
fixture, run the battery, write the round-2 summary, then build `gsa-lab:3`.
