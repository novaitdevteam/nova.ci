# SAST (Semgrep) and dependency scanning — depth

Referenced from `SKILL.md`'s "SAST and DAST Semantics" section. Read that section first —
this file is the reasoning and evidence behind its terse invariant list, not a second copy
of the invariants themselves.

## Job architecture

The switcher carries an **inline `sast-scan` job on `pull_request`** for the same eleven
repositories `secret-scan` covers. Builds are the evidence path, not the feedback path — an
ordinary pull request builds no image and so reaches no `sast-scan` in the build workflow,
which would leave a developer learning about a finding only after it is on trunk. It checks
out the merge commit, runs the same pinned `semgrep` action, and leaves a job summary
(counts **plus** the findings: severity, `path:line`, rule ID, message, capped at 25 with a
`Showing 25 of N` note) and the complete `.report` artifact. It is advisory (only a broken
scanner reds it) and has no notifier line. It is inline for the same reason `secret-scan` is:
`novatalks.core`'s PR route is a two-entry `build_target` matrix, so a job in the build
workflow would scan identical source twice per event.

The switcher also carries an **inline `deps-scan` job on `pull_request`**, same eleven
repositories, same reason: `trivy-scan`'s image scan reads dependencies that ship inside a
built image, and cannot see a manifest-less frontend bundle (`novatalks.ui`'s runtime image
has no `node_modules`), a pruned devDependency (`novatalks.core`'s `npm prune --omit=dev`),
or a repository that builds no image at all (`novatalks.chatwidget`, `novatalks.ui-lite`,
`nova.docs`). Two independent, never de-duplicated databases: `trivy fs --scanners vuln`
(Trivy called directly in the job, same as every other Trivy job here — no wrapper-action
rule for Trivy) and OSV-Scanner (tag- and digest-pinned `ghcr.io/google/osv-scanner`, invoked
only from `.github/actions/deps-scan/scan.sh`). Four outcomes: `clean` / `findings` /
`no-manifests` (neither tool found a lockfile — a legitimate state, reported loudly, never
`clean`) / `error`. **OSV-Scanner's exit code, not its JSON body, proves it ran**: a real
`api.osv.dev` network failure still writes a well-formed JSON document with the package list
populated and zero vulnerabilities, indistinguishable from clean in the JSON alone —
reproduced live with `docker run --network none`. Only exit `0`/`1`/`128` are acceptable;
anything else (`127`, `129` `ErrAPIFailed`, `130`) is `error` even with parseable JSON, the
same shape as the ZAP `0|1|2` ladder. Advisory, notifier-free, same as `sast-scan`. See
`docs/sast-dast.md#dependency-scanning-source-manifests`.

`ci-build-ntk-on-push-tags-build.yaml` runs `sast-scan` (Semgrep, all standard build
repositories, **every build on any branch**) after `trivy-scan`, delegating to the same
composite action. Three scanners, three questions: Semgrep reads our source, Trivy reads the
image, ZAP probes the running app. Gitleaks covers secrets; ESLint answers none of them. See
`docs/sast-dast.md`.

`ci-build-ntk-on-push-tags-widget-build.yaml` (`novatalks.chatwidget`'s workflow, not the
standard one) has its own `sast-scan` job mirroring the pattern above: same
every-non-`pull_request`-build gate, SHA-pinned checkout, `install-docker`, the same
`semgrep` composite action, and it upserts its report onto the release `build-widget` already
creates (`NTK.CHATWIDGET_<release>_<ref>_<sha>`) rather than a second one. It needs no
`PUBLISH_RELEASE` equivalent — `build-widget`'s `Create a Release` step is itself ungated, so
every build it follows already has a release to attach to. It has **no Trivy and no DAST
job** — that workflow zips `dist` and publishes it as a release asset, so there is no
container image for either to point at. Do not add one without inventing a target. The
notifier's `Compose SAST line` step is the same three-state shape as the main workflow's
(skipped / worded verdict / job died before `scan.sh` ran).

## Why the canary guard exists

**Do not remove the Semgrep canary guard.** `.github/actions/semgrep/canary.yaml` is a
one-rule config plus a generated file it must match, mounted next to the source. If that hit
is absent the outcome is `error` (exit 2), never `clean`. `scan.sh` also fails closed on: no
output file, exit > 1, unparseable JSON, and an empty `.paths.scanned`. Same class of trap as
`gitleaks git --log-opts` exiting 0 on an unresolvable range.

The canary hit is excluded from every bucket — `ERROR`, `WARNING`, `INFO` — **by rule ID, not
by severity**. Severity used to be a caller input; excluding by check_id instead means the
exclusion keeps working regardless of it.

**The Semgrep canary and the `.errors[]` check are one guard in two halves.** The canary
config is mounted from the action's own directory, so it fires even when every registry pack
failed to fetch — canary proves the engine ran, empty `.errors[]` proves the configs
resolved. Removing either re-opens "zero rules, reported clean".

## Findings vs. broken tooling

**`warn-only` governs findings only.** Findings warn and the build stays green; a broken
scanner reds the job. Never collapse the two — Semgrep has no environmental reason to fail
(no database, no running app), so its failure means broken tooling.

## SAST gate mechanics

**SAST gate:** `always() && github.event_name != 'pull_request' &&
needs.build-image.result == 'success'` — **every build on any branch**. Semgrep reads the
checkout, so it needs no running app, no database and no seeded stack, and a finding is
cheapest before the branch merges. No Semgrep on `pull_request`: `build-image` is gated off
there, so there is no build to read. The trunk/`scan*` narrowing was never about cost — it
was about having a release to attach a report to — so it lives on as the job-level
`PUBLISH_RELEASE` env (`IS_TRUNK == 'true' || startsWith(github.ref_name, 'scan')`), which
gates the `Publish report release` step and picks the notifier's report URL (release asset
when publishing, otherwise the run, where the artifact is). Do not let `sast-scan` create the
release: `TRIVY.SCAN_*` only exists where `trivy-scan` made it, and `action-gh-release` would
mint a `TRIVY.SCAN_*` git tag per feature build.

## Rules and reporting

**Rules come from the registry** (`p/typescript p/nodejs p/owasp-top-ten`), not vendored
into `security/`. `ERROR` and `WARNING` are both counted and both listed in the report body —
there is no `severity` input to narrow that. `INFO` is counted for the job summary only, kept
out of the report body.

## Test coverage

Changing `scan.sh` means adding a scenario to `scripts/test-sast-scan.sh` or
`scripts/test-deps-scan.sh` in the same change. `validate.sh` also fails if any workflow runs
`semgrep scan`/`semgrep ci`, a `docker run` of a Semgrep image, or a third-party action for
either.
