# Scanner triage and real-picture reporting

**Date:** 2026-08-31
**Branch:** `feat/scanner-triage` (stacked on `feat/dast-more-repos`)
**Status:** approved for planning

## Problem

Both scanners shipped in [`2026-08-28-sast-dast-scanning.md`](2026-08-28-sast-dast-scanning.md)
report a single number, and neither has a way to record a decision about a finding.
Three concrete consequences:

1. **Semgrep hides most of what it found.** `scan.sh` filters on
   `.extra.severity == $sev` with `SEMGREP_SEVERITY=ERROR`. That is an exact equality,
   and the same filter builds the report body — so `WARNING` and `INFO` findings are
   absent from the count *and* from the `.report` published as a release asset.
   `novatalks.core` produced 12 `WARNING` findings that nobody has ever seen.
   The quarterly evidence pack therefore understates the picture it exists to describe.

2. **ZAP has no triage mechanism at all.** Every alert is a `WARN`. There is no way to
   say "this one is accepted", "this one is informational", or "this one must be fixed".
   The count only goes up, so the first thirty-item run is also the run where people
   stop reading it.

3. **The DAST exit-code handling is wrong**, and becomes actively harmful the moment
   triage is introduced. Verified against `zaproxy/zaproxy@main:docker/zap-baseline.py`
   lines 697–708:

   | Exit | Meaning | Current `scan.sh:355` handling |
   | --- | --- | --- |
   | 0 | `pass_count > 0`, nothing else | ✅ accepted |
   | 1 | `fail_count > 0` — `FAIL`-level findings | ❌ `scanner_error`, job goes red |
   | 2 | warnings **and** `-I` absent | ✅ accepted, but unreachable — we always pass `-I` |
   | 3 | exception, **or** nothing ran at all | ✅ `scanner_error` |

   Exit 1 is a *finding*, not a broken scanner. Reddening the build for it breaks the
   standing invariant that `warn-only` governs findings and only a scanner that could
   not run may red the job. The in-code comment asserting "with `-I` it never returns 1"
   is false; `-I` gates exit 2 only (`elif (not ignore_warn) and warn_count > 0`).

## Scope

In: `.github/actions/semgrep/scan.sh`, `.github/actions/dast/scan.sh`,
`.github/actions/dast/action.yml`, `.github/actions/semgrep/action.yml`, a new
`.github/actions/dast/zap-baseline.conf`, both self-check harnesses, `docs/sast-dast.md`,
`CLAUDE.md` and both `SKILL.md` mirrors.

Out: no change to which repositories are scanned, to the runner sizing, to the release
layout, or to any product repository.

## Decisions

**D1 — Semgrep counts and reports `ERROR` and `WARNING` separately.**
Two outputs (`findings` for `ERROR`, `warnings` for `WARNING`), two report sections,
both severities listed in full. `INFO` is counted for the job summary only and stays out
of the report body: the OSS packs emit it liberally and it would bury the two levels that
carry a decision.

**D2 — the `severity` input is removed, not repurposed.**
No caller sets it, and with both levels now reported there is nothing left for it to
select. Removing it also retires the hazard behind the existing invariant ("the counted
severity is a caller input with no enum behind it"). The canary keeps being excluded by
`check_id`, which is now the only mechanism rather than a belt-and-braces one.

**D3 — Semgrep's acceptance marker is the native inline `nosemgrep`, in the product repo.**
`// nosemgrep: <rule-id> — <reason>` on the line above the finding. Per-finding, next to
the code it describes, reviewed in the pull request that introduces it. This is the exact
analogue of the `.gitleaksignore` fingerprint already in use, and it needs no registry, no
matching key and no new file. A path-scoped `.semgrepignore` is explicitly *not* adopted:
it is the blanket `ignore tests/**` this repository already rejected for Gitleaks.

**D4 — ZAP gets `-c`, pointed at a config file shipped with the action.**
`.github/actions/dast/zap-baseline.conf`, copied into `RUNNER_TEMP` at scan time because
`zap-baseline.py` resolves `-c` relative to `/zap/wrk/` (`zap-baseline.py:403-406`), which
is already a bind mount of that directory. Format verified at `zap_common.py:148-176`:

```
<rule_id>	<LEVEL>	<free-text reason>
<id,id,id>	OUTOFSCOPE	<url regex>
```

Tab-separated, at least two tabs per line, `#` and blank lines ignored. Levels are exactly
`PASS`, `IGNORE`, `INFO`, `WARN`, `FAIL` (`zap_common.py:57`). This file **is** the
register of "must fix / acceptable": `FAIL` for a finding that must block, `IGNORE` for an
accepted risk, and the third column is where the reason is written down.

**D5 — the config ships with no rule entries.**
Comments and a worked format example only. Which ZAP rules are acceptable is a
risk-acceptance decision belonging to whoever signs the quarterly report, not to this
change. An entry-free config parses to an empty `config_dict`, every rule keeps defaulting
to `WARN` (`zap_common.py:240-241`, `inc_extra` is true), and behaviour on day one is
therefore byte-identical to today's. That is the safest possible landing: the mechanism
arrives inert, the policy is filled in deliberately.

**D6 — `scan.sh` validates the config's shape before handing it to ZAP.**
Every non-comment, non-blank line must have at least two tabs and a level from the
enumerated set. Malformed input is a `scanner_error`, not a warning. ZAP's own handling is
already loud (`sys.exit(3)` on a `ValueError`, an uncaught `FileNotFoundError` on a missing
file), but its message lands in a log nobody reads, and the check being ours is what lets
the harness cover it.

**Honest limit, stated because the alternative is pretending otherwise:** a well-formed
line naming a rule ID that does not exist is silently inert. ZAP reports alert counts per
bucket, never which configured IDs matched, so nothing in the exit status or the tally
distinguishes "IGNORE applied" from "IGNORE typo'd". The mitigation is procedural — rule
IDs come from a generated file, see D9 — not mechanical.

**D7 — the finding counts come from the tally line, not from per-rule lines.**
`zap-baseline.py:666-668` prints exactly one, unconditionally, at the end of any completed
scan:

```
FAIL-NEW: n	FAIL-INPROG: n	WARN-NEW: n	WARN-INPROG: n	INFO: n	IGNORE: n	PASS: n
```

Anchored on `^FAIL-NEW: [0-9]+\tFAIL-INPROG: `, not on the bare `^FAIL-NEW: ` prefix:
`print_rule` (`zap_common.py:205`) emits one per-rule line per FAIL-level finding shaped
`FAIL-NEW: <alert name> [<id>] x <n>`, which starts with that same prefix and precedes the
tally whenever a FAIL entry exists — a bare-prefix `grep -m1` would take the per-rule line
instead and misreport a real finding as a broken scanner. Its absence means the scan did
not complete and is a `scanner_error` — the same fail-closed shape as the Semgrep canary
and the `git rev-list --count` guard. This replaces `grep -cE '^WARN-NEW: '`, which is
correct today but only counts one of the six numbers.

The `tee` capture and `${PIPESTATUS[0]}` stay exactly as they are. The reasons in the
existing comment are unchanged and still load-bearing: the `-w` report contains no
`WARN-NEW` at all, and `$?` is ZAP's status only incidentally.

**D8 — the exit-code `case` is corrected to the verified table.**
`0` and `2` pass through as today; `1` becomes a *findings* outcome, not an error; `3` and
anything else stay `scanner_error`. Exit 1 is unreachable until a `FAIL` entry exists, which
is precisely why it must be handled before one does.

**D9 — bootstrapping real rule IDs is documented, not guessed.**
`zap-baseline.py -g <file>` writes every loaded passive rule as `id\tWARN\t(name)`
(`zap-baseline.py:608-615`). `docs/sast-dast.md` gets the one-liner that produces it. No
rule ID is hand-written into this repository from memory.

**D10 — DAST outputs and message carry both severities.**
`findings` keeps meaning `WARN-NEW` so the notifier and the release layout are unchanged;
`failures` is added for `FAIL-NEW`. The composed line reports what was found and what was
suppressed, because a triage register nobody can see is a register nobody audits:

- `🕷 DAST (ZAP): 🔴 2 must-fix · 11 warnings` when `FAIL-NEW > 0`
- `🕷 DAST (ZAP): 🟡 11 warnings` when only `WARN-NEW > 0`
- `🕷 DAST (ZAP): 🟢 clean · 3 info · 5 accepted` when neither

`outcome` is `findings` when either count is non-zero. The build stays green in every
case — `warn-only` is unchanged by this work.

**D11 — no `-J`, no `-j`, no `-p`, no extra Semgrep packs in this change.**
The JSON report is redundant once the tally is parsed. The modern spider (`-j`) is a real
gap for `novatalks.ui`, whose SPA the traditional spider sees as an empty `<div id="root">`,
but it carries its own runtime cost and belongs in its own change with its own scenarios.
`-p progress_file` needs an issue-tracker feed; the config's reason column covers the same
ground for now. Widening the Semgrep packs before the triage mechanism exists would deliver
the noise first and the means to sort it second.

## Verified behaviours

Established by reading upstream source at `zaproxy/zaproxy@main`, not from memory:

- `-c` is resolved against `/zap/wrk/` — `zap-baseline.py:384,403-406`
- config grammar and the five levels — `zap_common.py:57,148-176`
- a malformed config exits 3 — `zap-baseline.py:409-410`
- unconfigured rules default to `WARN` — `zap_common.py:240-241`
- the tally line and its unconditional print — `zap-baseline.py:666-668`
- the exit-code ladder — `zap-baseline.py:697-708`
- `-g` template shape — `zap-baseline.py:608-615`

## Assumptions

**A1** — the pinned ZAP digest (`ghcr.io/zaproxy/zaproxy:stable@sha256:781a2bd…`) carries a
`zap-baseline.py` matching `main` for every behaviour above. The exit ladder, the config
grammar and the tally line are long-stable, but the digest is not `main`. First live run
verifies; the tally-line guard fails closed if it does not.

**A2** — no product repository currently has an inline `nosemgrep` comment, so D3 changes
nothing retroactively.

**A3** — surfacing `WARNING` will raise reported Semgrep counts substantially on first run
(12 known on `novatalks.core`, unknown elsewhere). This is the point of the change, not a
regression, and no build goes red for it.

**A4** — `RUNNER_TEMP` is writable by the runner user; already relied on by the existing
`-w` mount and the `--user $(id -u):$(id -g)` fix.

## Impact surface

| File | Change |
| --- | --- |
| `.github/actions/semgrep/action.yml` | remove the `severity` input, add the `warnings` output |
| `.github/actions/semgrep/scan.sh` | two-level counting, two-section report, summary counts |
| `.github/actions/dast/action.yml` | add the `failures` output |
| `.github/actions/dast/zap-baseline.conf` | new — the triage register, no entries |
| `.github/actions/dast/scan.sh` | config copy + validation, `-c`, tally parsing, exit ladder |
| `scripts/test-sast-scan.sh` | scenarios for two-level counting |
| `scripts/test-dast-scan.sh` | scenarios for the config, the tally and each exit code |
| `docs/sast-dast.md` | the triage section and the `-g` bootstrap one-liner |
| `CLAUDE.md`, both `SKILL.md` | invariants for the tally guard and the exit ladder |

No workflow file changes: the notifier passes `MESSAGE` through verbatim, and `scan.sh`
words it.
