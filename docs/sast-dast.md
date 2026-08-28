# SAST and DAST (Semgrep and OWASP ZAP)

<p align="center">
  <img src="../assets/readme/sast-dast.svg" width="100%" alt="Semgrep reads our own source and an OWASP ZAP baseline probes the running application, alongside Trivy on the container image; each reports clean, findings or error, with a fourth not-run outcome for DAST alone, and a scanner that could not run is never reported clean; all three reports land on the one release the build already creates and each adds a line to the notification" />
</p>

Two scanners join `trivy-scan` after a trunk build: **Semgrep** reads our own source
(SAST) and an **OWASP ZAP baseline** probes the application while it runs (DAST). Both
publish a `.report` onto the release the build already creates, and both add a line to
the build notification.

## Three scanners, three questions

They are not redundant, and none of them is a substitute for another:

| Tool | Reads | Answers |
| --- | --- | --- |
| **Semgrep** | our source, in the checkout | *did we write an insecure pattern?* |
| **Trivy** | the container image we just pushed | *are the OS packages and libraries we ship vulnerable?* |
| **ZAP baseline** | the application, over HTTP, while it runs | *does the thing we deploy expose itself badly?* |
| Gitleaks | the commits a change adds | *did a credential get committed?* — see [Secret detection](secret-detection.md) |
| ESLint | our source | *is the code well-formed?* — **not a security question at all** |

ESLint is why this page exists. The pipeline has always had a linter and a secret
scanner, and neither of them is static security analysis: a lint rule set is tuned for
style and correctness, and a working credential and an injectable query look nothing
alike to it.

## What these two are, and what they are not

**Semgrep OSS** runs pattern-based static analysis with the registry rule packs
`p/typescript`, `p/nodejs` and `p/owasp-top-ten`. It is not a whole-program analyzer:
it matches syntactic patterns, so it finds the shapes those packs describe and nothing
else. Only `ERROR` severity is counted on this rollout — the first pass at `WARNING`
over an established codebase produces a volume nobody triages, and an untriaged backlog
is the exact failure this work exists to fix. `WARNING` gets added once the real count
is known.

> [!IMPORTANT]
> **The ZAP baseline is not a penetration test.** It runs unauthenticated and passive:
> it spiders what it can reach without credentials and reports on what it observes —
> missing or weak security headers, cookie flags, information disclosure, obvious
> misconfiguration. It does not log in, does not attack, and cannot see a broken
> authorization check or any other logic flaw. A green DAST line means the app's
> hygiene at the edge looks right. It does not mean the app is secure.

## When they run

Both use the same gate as the image scan: the build's source branch is `main`, `master`
or `development` (**trunk** throughout this page), or the triggering tag ref starts with
`scan`. Neither ever runs on a `pull_request` event.

```bash
git checkout my-feature-branch
git tag scan-NC2-1234
git push origin scan-NC2-1234   # builds, then scans the image, the source and the app
```

The gate is not a cost decision — Semgrep is cheap. **A report is only useful where
there is a release to attach it to**, and pull request events never build one, so a PR
run would produce a finding count with no stable URL behind it. Tighter feedback on
pull requests is worth revisiting as a second, summary-only run once the release path
has proven itself.

The jobs run one after another:

```text
build-image → trivy-scan → sast-scan → dast-scan → notify
```

Both new jobs need `RELEASE`, `SHORT_REF_NAME` and `SHORT_SHA` from `build-image` to
address the release, so neither can start earlier. Running the three scans in parallel
would buy no wall-clock time either: they would only queue against the
[per-size cap of two runners](runners.md#sizing-novatalkscore-only). Each job carries
`if: always() && …` so one scanner failing never swallows the next one or the notifier.

`build-image` resolves the trunk test once, into an `IS_TRUNK` output, because a
job-level `if:` cannot reach a step inside another job.

> [!NOTE]
> `trivy-scan` keeps its own `Resolve scan policy` step and does **not** read
> `IS_TRUNK`. Two sources of truth for one predicate is a real wart, accepted
> deliberately: consolidating them would change the behaviour of the only scanner
> currently working, for cosmetics. Read the spec's D6 before "simplifying" it.

## A scanner that could not run is not a clean scan

This is the spine of both actions, and the single idea to take away from this page.

Every scanner here has a failure mode where **it produces exactly the output a clean
run produces**. Semgrep that loaded zero rules reports zero findings, same as Semgrep
that loaded three thousand and matched nothing. A ZAP baseline against an application
that crashed on boot yields the same empty report as a baseline against a healthy one.
Both would be reported green by a naive job, and a green check that cannot fail is
worse than no check: it is a control that has been quietly switched off while everyone
believes it is on.

It is the same trap as `gitleaks git --log-opts` exiting `0` on a range git cannot
resolve, which is why `scan.sh` counts commits itself — see
[Secret detection](secret-detection.md#changing-the-scan). Each of these three scanners
gets a positive proof that it did its job, not the absence of a complaint.

### The four outcomes

| Outcome | What it means | Build |
| --- | --- | --- |
| `clean` | the scan ran, proved it ran, and found nothing | 🟢 green |
| `findings` | the scan ran and found something at the counted severity | 🟢 green — `warn-only` governs findings |
| `not-run` (DAST only) | the application never came up, so nothing was scanned | 🟢 green, and **said loudly** |
| `error` | the scanner itself broke | 🔴 **red** |

`warn-only` — the agreed policy, shared with [Trivy](container-scanning.md) —
governs **findings**. A scanner that could not run is a different event, and collapsing
the two is how a broken gate hides behind a policy that was only ever about triage
capacity. Semgrep has no environmental reason to fail: it needs no database and no
running application, so a Semgrep failure means broken tooling and reds the job.

### Why `not-run` is green and `error` is red

They look similar and are opposites.

A DAST boot failure comes from `.env.example` drift, a missing migration against an
empty database, or a port that changed — **none of them security events**. The build
already succeeded and the image is already in GHCR. Reddening it would teach the team
that a red DAST job usually means "the boot config needs a nudge", which is precisely
the training that gets a real red ignored. So the outcome is a **loud skip**: the
report file says `=== DAST: not run ===` with the reason, the job summary carries a
`WARNING` banner reading *"This is not a clean result"*, and the notification carries
`⚠️ not run — <reason>` rather than a green tick. Nothing is silent, and nothing claims
to have been scanned.

ZAP itself failing — a non-zero exit that is not "warnings present", or no report file
at all — is the opposite case. Nothing about the application explains it, so it is
broken tooling and the job goes red, exactly like a Semgrep failure.

### Where the ZAP warning count comes from

`zap-baseline.py` has two output channels and they do not carry the same information.
`-w` writes the traditional **"ZAP Scanning Report" markdown** — `## Summary of Alerts`
and a section per risk level. That file is the human-readable artifact, and it is what
the `.report` is assembled from. But the **`WARN-NEW:` lines are printed to stdout
only** and never appear in it, so the count is taken from a `tee` of the console stream,
anchored on `^WARN-NEW: ` — the trailing tally line begins `FAIL-NEW:` and must not be
counted as a rule.

This is not a detail. `-I` makes the script exit `0` even with warnings present, so the
exit code carries no signal either; counting the wrong stream leaves **both** channels
dead and every run reports `🟢 clean` with `findings=0`, including one where ZAP found
twenty warnings. It is precisely the failure this page is built around, so the harness
carries a scenario whose markdown report is full of alert text and free of `WARN-NEW`.
`${PIPESTATUS[0]}` matters for the same reason: plain `$?` after the pipe is `tee`'s
status, which is `0` whatever ZAP did.

The console log lives under `RUNNER_TEMP`, is deleted by the same `EXIT` trap that
removes the temporary env file, and is never uploaded — it is raw output about a
container booted with the product repository's own environment.

### The Semgrep canary guard

Semgrep exits `0` and reports an empty result set when no rules load, so
[`scan.sh`](../.github/actions/semgrep/scan.sh) refuses to call an empty result clean
until five things hold:

1. the container wrote an output file at all;
2. Semgrep exited `0` or `1` (`1` is "findings present"), not higher;
3. that output parses as JSON;
4. at least one file appears in `.paths.scanned`;
5. `.errors[]` is empty;
6. **the canary rule fired.**

The canary is a one-rule config in the action directory
([`canary.yaml`](../.github/actions/semgrep/canary.yaml)) plus a generated file it is
guaranteed to match, mounted alongside the real source. If it is missing, no amount of
"zero findings" proves anything, and the outcome is `error` with exit `2`.

The last two are **one guard in two halves, and neither half is sufficient alone.** The
canary config is mounted from the action's own directory, so it resolves even in a run
where all three registry packs failed to fetch: files get scanned, the canary fires, and
zero real rules produce zero findings. Semgrep records a failed `--config` resolution in
`.errors[]`, which is what closes that gap. So: the canary proves the **rule engine
executed**, and the empty `.errors[]` proves the **configs it executed with actually
loaded**. Together they mean a clean result is a real one.

The canary hit is excluded from the finding count **by rule ID, not by severity**. Its
own severity is a fixed `INFO`, but the counted severity is a caller-configurable input
with no enum behind it, so a caller that ever set it to `INFO` would otherwise start
counting the canary as a finding in every repository.

Rules come from the registry rather than being vendored into `security/`, unlike the
Gitleaks config. Mirroring thousands of rule files to guard against the registry being
unavailable buys little: the registry going down surfaces as a red job, and the real
risk — running with zero rules and reporting clean — is what the canary closes, for far
less.

## Which repositories

**SAST covers every standard build repository**, `novatalks.core` included. There is
nothing per-repository about reading a checkout.

**DAST covers `novatalks.ui` and `novatalks.core` only**, gated on
`github.event.repository.name`, the same repository-scoped-exception pattern already
used for the [integration Postgres image](tests.md) and R2 file storage.

DAST is scoped that narrowly because, unlike the other two, it has to **boot the
thing**. Every repository needs its own answer to: which port does the image listen on,
what path proves it is up, how long does it need, and does it need postgres and redis
first. Those are per-repository inputs on
[`dast/action.yml`](../.github/actions/dast/action.yml), and each one has to be
established against the real runtime image — a wrong path scans an error page and
reports it clean, which is the failure this whole design is built to avoid.

The two chosen repositories are the two poles of the problem: `novatalks.ui` serves
static assets, `novatalks.core` is a backend that needs postgres, redis and a schema.
Once both are working, the remaining repositories roll out by copying whichever pole
they resemble, rather than by writing eight boot configs blind. **Adding one needs an
explicit request and a boot probe first** — not a copied block and a hope.

## The runner-size consequence

The DAST stack is postgres + redis + the application + ZAP on one VM: the same load
that already earns `large` for `int-test`. So on **`novatalks.core` only**,
[`ci-build-create-runner.sh`](../.github/workflows/ci-build-create-runner.sh) resolves
`medium` (cx43) whenever DAST will run:

| Tag on `novatalks.core` | `base_ref` | Size |
| --- | --- | --- |
| `scan*` | any branch | `medium` |
| `*build*` | `main` / `master` / `development` | `medium` |
| `*build*` | any other branch | `small` |

The condition mirrors the DAST gate exactly rather than approximating it — a `scan*` tag
runs DAST on any branch, and used to fall through the matrix to `small`. `base_ref` is
read from the event payload with `jq` inside the script, because a tag push carries no
branch in `GITHUB_REF` and a new input would mean editing every product-repository
caller.

> [!IMPORTANT]
> **This branch exists for the DAST stack, not for faster builds.** `medium` is sized
> for postgres, redis, the application and ZAP on one VM — the same load `int-test`
> already earns `large` for — so narrowing it back to feature-branch builds would leave
> trunk builds, the ones that actually run DAST, on `small`. Widening it to every
> `novatalks.core` build puts ordinary feature builds into the `medium` pool, where they
> start contending with unit-test runs. See
> [Runners](runners.md#sizing-novatalkscore-only).

`cx43` is the agreed starting point, measured on the first real run; the documented
fallback for the same stack is `large`.

## Where the reports are

All three scanners publish onto the **one release the build already creates**, because
`softprops/action-gh-release@v2` upserts by tag and each job can attach its own file
independently:

```text
https://github.com/<owner>/<repo>/releases/download/TRIVY.SCAN_<release>_<ref><suffix>_<sha>/<file>
```

| Scanner | File |
| --- | --- |
| Trivy | `trivy-<repo>-<ref><suffix>-<sha>.report` |
| Semgrep | `semgrep-<repo>-<ref><suffix>-<sha>.report` |
| ZAP baseline | `zap-<repo>-<ref><suffix>-<sha>.report` |

> [!NOTE]
> **The `TRIVY.SCAN_` release-tag prefix is historical.** It now carries three
> scanners' reports. Renaming it to something neutral would break the stable download
> URLs documented in [Container scanning](container-scanning.md),
> for cosmetic gain.

One release per build rather than one per scanner: three prereleases on every trunk
build is noise, and it would triple the walk for the quarterly evidence aggregation
this work exists to feed.

Each report is also uploaded as a run-scoped artifact, and each job writes a summary
banner — `NOTE` when clean, `WARNING` for findings or a not-run, `CAUTION` when the
scanner broke.

## In the notification

Each scanner contributes one line to the same Telegram and Google Chat message the
build already sends — see [Notifications](notifications.md).

| Line | When |
| --- | --- |
| `🔍 SAST (Semgrep): 🟢 clean` | scan ran, nothing at the counted severity |
| `🔍 SAST (Semgrep): 🟡 <n> ERROR` | findings |
| `🔍 SAST (Semgrep): ❌ scan failed — <reason>` | broken scanner |
| `🔍 SAST (Semgrep): ⏭️ skipped (no scan trigger)` | not a trunk build or `scan*` tag |
| `🕷 DAST (ZAP): 🟢 clean` | app booted, no baseline warnings |
| `🕷 DAST (ZAP): 🟡 <n> warnings` | baseline warnings |
| `🕷 DAST (ZAP): ⚠️ not run — <reason>` | the app never came up |
| `🕷 DAST (ZAP): ❌ scanner failed — <reason>` | broken scanner |
| `🕷 DAST (ZAP): ⏭️ skipped (not a DAST trigger or repository)` | not a trunk build or `scan*` tag, or not a DAST repository |

The text is composed inside each `scan.sh`, not in the workflow, so the harnesses cover
it — the same reason the [secret-scan alert](secret-detection.md#the-secret-scan-notify-job)
is composed there. The workflow keeps a fallback line for a job that died before
`scan.sh` ran at all: silence in a notification reads as a clean scan.

## Changing a scanner

Both actions are the only place a workflow may invoke their tool, and `validate.sh`
fails on a direct call — the same guard [Gitleaks](secret-detection.md) has, for the
same reason. An inline `docker run semgrep` or `zap-baseline.py` step bypasses the
digest pin, the canary guard and the harness at once.

| Piece | Path |
| --- | --- |
| Semgrep action | [`.github/actions/semgrep/action.yml`](../.github/actions/semgrep/action.yml) + [`scan.sh`](../.github/actions/semgrep/scan.sh), [`canary.yaml`](../.github/actions/semgrep/canary.yaml) |
| DAST action | [`.github/actions/dast/action.yml`](../.github/actions/dast/action.yml) + [`scan.sh`](../.github/actions/dast/scan.sh) |
| Jobs | `sast-scan` and `dast-scan` in [`ci-build-ntk-on-push-tags-build.yaml`](../.github/workflows/ci-build-ntk-on-push-tags-build.yaml) |
| Scenario tests | [`scripts/test-sast-scan.sh`](../scripts/test-sast-scan.sh), [`scripts/test-dast-scan.sh`](../scripts/test-dast-scan.sh) |

Both images are pinned by **tag and digest**, never `latest`, for the reason the
Gitleaks pin exists: a tag can be moved, and an upstream change must not be able to
silently alter what a security report says. To upgrade, bump the tag and re-read the
digest:

```bash
docker buildx imagetools inspect semgrep/semgrep:<tag>
docker buildx imagetools inspect ghcr.io/zaproxy/zaproxy:stable --format '{{.Manifest.Digest}}'
```

**Changing either `scan.sh` means adding a scenario to its harness in the same change.**
Both run offline under `./scripts/validate.sh` with `docker` (and, for DAST, `curl`)
stubbed, so they need no image and no network — see [Validation](validation.md).

---

**Background:** [spec](superpowers/specs/2026-08-28-sast-dast-scanning.md) — the
decisions, the alternatives ruled out (CodeQL, SonarQube Community) and the assumptions
settled during implementation ·
[plan](superpowers/plans/2026-08-28-sast-dast-scanning.md) — how it was built.

---

[← Container scanning (Trivy)](container-scanning.md) · [Docs index](README.md) · [Tests →](tests.md)
