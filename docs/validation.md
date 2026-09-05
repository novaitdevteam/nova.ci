# Validation

<p align="center">
  <img src="../assets/readme/validation.svg" width="100%" alt="scripts/validate.sh runs a YAML parse, a whitespace check, the agents-to-claude skill mirror check, the create-runner self-check and advisory actionlint" />
</p>

One harness runs every check:

```bash
./scripts/validate.sh   # or: make validate
```

[`scripts/validate.sh`](../scripts/validate.sh) runs a YAML parser over all `.github/workflows/*.yaml` and `.github/actions/*/action.yml`, `git diff --check` for whitespace, an `.agents` ↔ `.claude` skill mirror sync check, three documentation-asset checks (every page under `docs/` opens with a diagram, every referenced asset resolves, no asset drops below `font-size` 18), eight offline scenario self-checks — [`ci-build-create-runner.sh`](../.github/workflows/ci-build-create-runner.sh), Gitleaks, the secret-echo guard, Semgrep, dependency scanning, the DAST target table, the ZAP baseline and the ZAP API scan — a guard that no workflow invokes Gitleaks, Semgrep, ZAP or OSV-Scanner directly (with a narrow, counted exception for `ci-dast-pentest.yaml`'s single live-target ZAP call), a guard that no workflow reaches the Telegram or Google Chat API directly, a guard that every `novaitdevteam/nova.ci` self-reference pins `@main`, and `actionlint` when available — **advisory** by default, because the repo carries a pre-existing backlog of shellcheck-info and expression findings. Set `STRICT_ACTIONLINT=1` to enforce once that backlog is cleared.

## Runner script self-check

[`scripts/test-create-runner.sh`](../scripts/test-create-runner.sh) runs `ci-build-create-runner.sh` offline against 26 checks: a `curl` shim on `PATH` answers the Hetzner and GitHub calls from canned JSON, `sleep` is stubbed out, and each scenario asserts the emitted `$GITHUB_OUTPUT`. It touches no network, no credentials and no Hetzner project, and covers reuse, ghost registrations, both caps, the sizing matrix (including the `base_ref`-scoped DAST branch and a missing or unreadable event payload), and all four create-lock outcomes (free, held, stale, API failure).

Run it alone against any copy of the script:

```bash
./scripts/test-create-runner.sh [path-to-script]
```

## Secret scan self-check

[`scripts/test-secret-scan.sh`](../scripts/test-secret-scan.sh) gives
[`scan.sh`](../.github/actions/gitleaks/scan.sh) the same treatment, for the same
reason: it decides whether a pull request may merge. It builds throwaway git repos and
runs the real, pinned Gitleaks binary over them — 63 checks covering clean and
dirty pull requests, follow-up deletion versus branch rewrite, both allowlist
mechanisms, merge-base scoping, push ranges, a legacy finding outside the range, new
branches and rewritten history, that findings stay redacted in both stdout and the
summary, four fail-closed cases, and a self-scan of nova.ci's own commits (a real check
in CI; a counted skip locally, where there is no `main` ref to diff shallow-checked-out
commits against).

The version and checksum come out of
[`action.yml`](../.github/actions/gitleaks/action.yml), so the harness can never test a
version CI does not run. Fixture credentials are assembled from halves at runtime, so
no line of the harness itself trips the scanner. It uses `gitleaks` from `PATH` when
present (`brew install gitleaks`), otherwise downloads the pinned linux_x64 build.

```bash
./scripts/test-secret-scan.sh
```

## Secret-echo guard self-check

[`scripts/guard-secret-echo.sh`](../scripts/guard-secret-echo.sh) is a `PreToolUse`
hook, not a `scan.sh` — it runs in the agent's own tool loop, before a Bash command
executes, and refuses one it judges would dump a `.env` file's contents into the
transcript. `validate.sh` runs its own self-test (23 checks) covering both the block
and the allow cases; it over-blocked twice during development (`open(` in a Python
snippet, `tail -1` inside an unrelated command), and a check that cries wolf teaches
people to route around it, so the allow-list is exercised as deliberately as the
block-list. It cannot see an editor `@file` reference or a pasted log line — see
[Secret detection](secret-detection.md#credentials-in-the-transcript) for what that
means when a credential reaches the transcript anyway.

```bash
./scripts/guard-secret-echo.sh --self-test
```

## SAST and DAST scan self-checks

The two [SAST and DAST](sast-dast.md) actions get the same treatment, for the reason
that page is built around: the difference between "found nothing" and "never ran" is
invisible in the tools' own output, so it has to be asserted.

[`scripts/test-sast-scan.sh`](../scripts/test-sast-scan.sh) runs the Semgrep
[`scan.sh`](../.github/actions/semgrep/scan.sh) against 43 checks with `docker`
stubbed by a shim on `PATH`, so it needs no image and no network. It covers a clean run,
`ERROR` and `WARNING` counted and listed separately (a lone `WARNING` is a finding, not
a clean scan), `INFO` counted in the job summary but kept out of the report body, and
every fail-closed case the rule-load guard exists for: no output file, a non-zero exit,
unparseable JSON, zero files scanned, a result set in which the canary rule did not
fire, and a non-empty `.errors[]` *with* a firing canary — the shape of a run whose
registry packs never loaded, as against per-file `.errors[]` entries, which all carry a
`path` and must not fail the job. Two guards are isolated by giving their scenario a
firing canary, so the canary guard cannot catch the case first: the zero-files guard,
and the `INFO`-is-not-listed rule, which uses an `INFO`-only rule ID so the report
assertion is about `INFO` and nothing else. The canary itself is excluded from every
bucket unconditionally, by `check_id`, and the `canary alone is a clean scan` scenario
holds it to that — there is no severity input to coincide with any more.

[`scripts/test-dast-scan.sh`](../scripts/test-dast-scan.sh) does the same for the ZAP
[`scan.sh`](../.github/actions/dast/scan.sh) across 147 checks, with `docker` and
`curl` stubbed. It asserts the four outcomes stay distinct — `clean`, `findings`,
`not-run` and `error` — plus the boot wait loop, teardown on every path, that a
no-database run never starts postgres or redis, the `.env.example` seeding filters, the
triage register's shape validation, and the `scan-mode` fork: `full` runs
`zap-full-scan.py` with `-j` and loads `zap-full-scan.conf`, an unset mode still runs
`zap-baseline.py`, and an unrecognised mode is a scanner error. It also asserts the
`zap-context` mechanism on its own terms: a set context appends both `-n <file>` and
`-U nova-ci-dast` together, and an unset one appends neither — never `-n` without `-U`
or the reverse. Its ZAP shim writes the
`-w` markdown report and
the console stream **separately**, because the real `zap-baseline.py` does: `WARN-NEW`
lines exist only on stdout, so a scenario whose markdown report is full of alert text but
carries no `WARN-NEW` proves the count comes from the stream ZAP actually prints it on.
All six counts come off one tally line, and the scenarios around it assert the reason as
well as the outcome — a missing tally and an unparseable one are both scanner errors, so
outcome alone cannot tell the two guards apart, and matching the reason keeps each one
independently falsifiable. A `FAIL`-level finding is asserted to report as a finding with
the build green, never as a broken scanner.

[`scripts/test-deps-scan.sh`](../scripts/test-deps-scan.sh) does the same for the
dependency [`scan.sh`](../.github/actions/deps-scan/scan.sh) across 42 checks, with
`docker` stubbed for OSV-Scanner and Trivy's JSON read from a fixture file. It covers
all four outcomes — `clean`, `findings`, `no-manifests` (neither tool found a lockfile;
a legitimate, loudly-reported state, never `clean`) and `error` — and both silent-zero
traps: OSV-Scanner exiting `127`/`129` while still leaving a well-formed, clean-looking
JSON body behind (only exit `0`/`1`/`128` are acceptable), and Trivy's own JSON missing
or emptying its `.Results` key.

[`scripts/test-dast-targets.sh`](../scripts/test-dast-targets.sh) checks the shared
per-repository table, [`dast/targets.sh`](../.github/actions/dast/targets.sh), across 69
checks: every arm sets every `DT_*` variable (so a stale value can never leak from the
previous caller), an unknown repository/surface pair fails loudly instead of guessing,
and — in both directions — every `DT_*` field the table can emit is bridged to a
consumer somewhere, and nothing a caller reads is left unset by the table.

[`scripts/test-dast-api-scan.sh`](../scripts/test-dast-api-scan.sh) does the ZAP-baseline
treatment for the authenticated API scan's
[`scan.sh`](../.github/actions/dast-api/scan.sh) across 87 checks. It covers all four
`auth-mode`s (`login`, `db-token`, `db-insert`, `env-token`) and their distinct
loud-skip/error paths, the `-S` safe-mode default versus its absence under
`scan-mode: active`, the `::add-mask::` on the token regardless of source, and — the one
mutation check in the suite — that a mismatched `env-token` value (the token handed to
the application container differing from the one ZAP holds) fails the harness, because
that scan would look authenticated while checking nothing. It also reproduces
`zap-api-scan.py`'s own `shlex.split()` behavior on the `-z` replacer string rather than
grepping the raw string, since an unquoted token there splits into two arguments and
authenticates as nobody while reporting a plausible result.

```bash
./scripts/test-sast-scan.sh
./scripts/test-deps-scan.sh
./scripts/test-dast-targets.sh
./scripts/test-dast-scan.sh
./scripts/test-dast-api-scan.sh
```

## Scanner invocation guard

`validate.sh` fails when a workflow invokes **Gitleaks, Semgrep, ZAP or OSV-Scanner
directly** — a `gitleaks git` line, a `semgrep scan`/`semgrep ci` line, a `docker run`
of a Semgrep image, `zap-baseline.py` or `zap-full-scan.py`, a `docker run` of the
OSV-Scanner image, or a third-party action for any of the four. Each tool's pin, its
guard logic and its harness live in its composite action, and one inline step bypasses
all of them at once. Commented-out lines and references to a step's own `id`/outputs
are not invocations and do not trip it.

> [!NOTE]
> **The ZAP half is narrower than the others**: it matches the two ZAP scripts and a
> third-party `zaproxy` action, but **not** a bare `docker run ghcr.io/zaproxy/zaproxy`,
> which the Semgrep pattern does catch for its own images. All the patterns are
> per-line greps, so none of them catches an invocation split across a line-broken YAML
> block scalar. They stop careless copy-paste, not a determined bypass.

[`ci-dast-pentest.yaml`](../.github/workflows/ci-dast-pentest.yaml) and
[`ci-dast-live-baseline.yaml`](../.github/workflows/ci-dast-live-baseline.yaml) are the
two deliberate exceptions to the ZAP-direct-invocation guard, because both attack a real
host with no image to boot and no token to seed, so neither `dast` nor `dast-api`
applies. `ci-dast-live-baseline.yaml` is excluded by file path — it has no other path to
protect. `ci-dast-pentest.yaml` also carries an ephemeral path that the guard must keep
covering, so it is not file-path-excluded; instead `validate.sh` asserts, by line count,
that the file contains **exactly one** direct ZAP invocation — the `target: live` path
— and separately asserts that the same live path rejects `surface: api` (there is no
image to seed a token from, so an "api" surface against a live host would be an
anonymous browser crawl reporting itself as authenticated).

## Self-reference pins

`validate.sh` fails when any `uses: novaitdevteam/nova.ci/...@<ref>` line in
`.github/workflows/*.yaml` pins anything other than `@main` (commented-out lines, like
the legacy branch-push route, are skipped). A non-`@main` self-reference is a
**temporary testing state** — it lets a product repository's test branch exercise this
repository's own unmerged CI — and it must never reach `main`, where it would pin the
pipeline to a branch that no longer exists or, worse, one that still does and has since
moved. The failure is deliberate: while a test ref is in place, `validate.sh` staying
red is what makes merging that state by accident impossible. This guard is about this
repository referencing itself, not about the tag-and-digest pins on Semgrep, Gitleaks,
Trivy, ZAP or OSV-Scanner images, which are pinned on purpose for the opposite reason.

[`ci-self-validate.yaml`](../.github/workflows/ci-self-validate.yaml) runs the same harness (with `actionlint` installed) on every pull request and push to `main`.

After changing CI behavior, still verify by hand that these docs, [`CLAUDE.md`](../CLAUDE.md), [`AGENTS.md`](../AGENTS.md) and [`.agents/skills/nova-ci/SKILL.md`](../.agents/skills/nova-ci/SKILL.md) (with its `.claude/` mirror) describe the same routing.

---

[← Notifications](notifications.md) · [Docs index](README.md) · [Reference →](reference.md)
