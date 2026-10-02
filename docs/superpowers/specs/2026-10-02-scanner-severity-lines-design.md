# SAST and DAST lines by severity, like Trivy

- **Date:** 2026-10-02
- **Status:** approved design, not implemented
- **Scope:** `semgrep/scan.sh`, `dast/scan.sh`, `dast-api/scan.sh`, `dast/dast-common.sh`, their harnesses and docs

## Problem

The Trivy line reports by severity: `🔴 CRITICAL found!` / `🟠 HIGH found` / `🟢 clean`, with
counts. SAST and DAST report a level instead, and the level is not a risk:

- Semgrep counts every `ERROR` and `WARNING` as a finding (`🟡 3 error · 2 warning`).
- ZAP counts every `WARN`-level rule, whatever its risk. `novatalks.ui`'s "11 warnings" are
  0 High, 2 Medium and 8 Low, plus one more.

Every trunk build therefore reads `🟡`, and a High can no longer be told apart from a missing
`Permissions-Policy` header.

## What the reader gets

| | Now | After |
| --- | --- | --- |
| SAST line | `🟡 3 error · 2 warning` | `🟠 HIGH found · 3 high · 2 medium` or `🟢 clean · 2 medium · 1 low` |
| DAST line | `🟡 11 warnings` | `🟢 clean · 2 medium · 8 low` |
| `outcome=findings` | any ERROR/WARNING, any WARN | **high > 0**, or a ZAP `FAIL` from the triage register |
| ZAP `FAIL` | `🔴 N must-fix` | unchanged. A `FAIL` entry is an explicit decision, independent of risk. |
| `⚠️ not run`, `❌ failed` | | unchanged |
| Job summary, `.report` | | full breakdown. High and Medium are listed, Low is counted only. |

Neither scanner has a Critical, so `🔴 CRITICAL` stays Trivy's alone. Gates do not change:
both scanners stay advisory, and only a scanner that could not run reds the job.

## Severity sources

**Semgrep:** Semgrep's own mapping, the same for every pack.

| `extra.severity` | bucket |
| --- | --- |
| `CRITICAL`, `HIGH`, `ERROR` | high |
| `MEDIUM`, `WARNING` | medium |
| `LOW`, `INFO` | low |

A rule that declares a native severity keeps it. `metadata.impact`/`likelihood` were
considered and rejected: packs fill them inconsistently, so a bucket would depend on the
rule's author. Counted per result. The canary stays excluded by rule ID.

**ZAP:** risk per rule, from the JSON report, joined with the console's verdict.

- The ZAP call gains `-J zap.json` (`zap-api.json` for api-scan), next to the existing `-w`.
  The JSON is `site[].alerts[]`, with `pluginid` and `riskcode` (3 High, 2 Medium, 1 Low,
  0 Informational).
- Which rules count comes from the console's per-rule `WARN-NEW: … [id]` and `FAIL-NEW: … [id]`
  lines. The report alone cannot be used: on 2026-10-02 it listed the two `IGNORE`d
  `novatalks.ui` rules (10096, 10110) under Low both with and without the overlay. Counting
  from it would count accepted risk.
- Counted per rule (alert type), as ZAP's own "Summary of Alerts" does, not per instance
  (`x 11`). A rule raised on several sites counts once, at its highest risk.
- This join lives once, as `zap_risk_counts` in `dast-common.sh`, next to `zap_tally_parse`,
  sourced by both ZAP actions.

## What does not move

- **The proof that a scan ran.** The Semgrep canary and its `.errors[]` check, and the
  tab-anchored ZAP tally line with its exit ladder, still decide `clean` vs `error`.
  Severity is computed only after them.
- **A JSON that is missing, unparseable, or names no risk for a counted rule is a
  `scanner_error`, never a zero.** That is the same rule the tally follows.
- Both ZAP triage registers, the overlay, `IGNORE`/`OUTOFSCOPE` semantics.
- Medium findings stay visible. `.claude/rules/code-scanning.md`'s "ERROR and WARNING are two
  counts, both listed" becomes "High and Medium are counted and listed, Low is counted, and
  `outcome` follows High". The scar it records, 12 core WARNINGs hidden from the count and the
  report, stays closed, because Medium is still in both.

## Outputs

Each of the three actions gains `high`, `medium` and `low`. `findings`, `warnings`, `failures`
and `outcome` keep their names. `findings` becomes the high count (Semgrep) or the high count
plus `FAIL`s (ZAP); `warnings` stays the Semgrep `WARNING` count until no caller reads it.
`message` is composed in `scan.sh` as now, so the harnesses cover its wording.

## Testing

TDD, scenario first, in the existing offline harnesses:

- `test-sast-scan.sh`:
  - the mapping, including a native `HIGH` and `CRITICAL`;
  - `outcome=clean` with Medium only;
  - Medium is still listed in the summary and the report;
  - the line format.
- `test-dast-scan.sh`, `test-dast-api-scan.sh`, with a shimmed `zap.json`:
  - risk is taken from the JSON;
  - an `IGNORE`d rule present in the JSON is not counted;
  - a `FAIL` stays 🔴;
  - a missing, unparseable or riskless JSON is `error`;
  - one rule with `x 11` instances counts once.
- One real run of the pinned ZAP image against `novatalks.ui:2026_R4_development_a0ce796d`
  with the overlay. Expected, from the 2026-10-02 report minus the two ignored Lows:
  high 0, medium 2, low 6. To be confirmed by the run, not assumed.

## Out of scope

- Thresholds like `trivy_mode` (`fail-on-high`). This design changes what is reported, not
  what fails.
- Gitleaks (no severity) and `deps-scan` (a separate surface).
