# SAST and DAST (Semgrep and OWASP ZAP)

<p align="center">
  <img src="../assets/readme/sast-dast.svg" width="100%" alt="Semgrep reads our own source and an OWASP ZAP baseline probes the running application, alongside Trivy on the container image; each reports clean, findings or error, with a fourth not-run outcome for DAST alone, and a scanner that could not run is never reported clean; all three reports land on the one release the build already creates and each adds a line to the notification" />
</p>

Two scanners join `trivy-scan` after a build: **Semgrep** reads our own source (SAST)
on every build, on any branch, and an **OWASP ZAP baseline** probes the application
while it runs (DAST) on trunk and `scan*` builds. Both write a `.report` — onto the
release the build already creates, where there is one — and both add a line to the
build notification.

A fourth job, `deps-scan`, joins `secret-scan` and `sast-scan` inline in the switcher on
every pull request: **Trivy fs** and **OSV-Scanner** read the checkout's own lockfiles —
declared dependencies at declared versions, not the container image and not our own
code — and neither is a substitute for `trivy-scan`'s image scan, which reads what
actually ships. See [Dependency scanning](#dependency-scanning-source-manifests) below.

## Three scanners, three questions

They are not redundant, and none of them is a substitute for another:

| Tool | Reads | Answers |
| --- | --- | --- |
| **Semgrep** | our source, in the checkout | *did we write an insecure pattern?* |
| **Trivy** | the container image we just pushed | *are the OS packages and libraries we ship vulnerable?* |
| **ZAP baseline** | the application, over HTTP, while it runs | *does the thing we deploy expose itself badly?* |
| **Trivy fs + OSV-Scanner** | the checkout's own lockfiles, on every pull request | *did we declare a dependency version with a known vulnerability?* — see [Dependency scanning](#dependency-scanning-source-manifests) |
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
else. `ERROR` and `WARNING` are both counted and both listed in the report body, as two
separate numbers — there is no `severity` input to narrow that. `INFO` is counted for
the job summary only and kept out of the report body: the registry packs emit it
liberally, and burying the two levels that carry a decision under it is how a report
stops being read.

> [!IMPORTANT]
> **The ZAP baseline is not a penetration test.** It runs unauthenticated and passive:
> it spiders what it can reach without credentials and reports on what it observes —
> missing or weak security headers, cookie flags, information disclosure, obvious
> misconfiguration. It does not log in, does not attack, and cannot see a broken
> authorization check or any other logic flaw. A green DAST line means the app's
> hygiene at the edge looks right. It does not mean the app is secure.

## When they run

**Semgrep runs on every build**, on any branch, as soon as `build-image` succeeds. It
reads the source that was just built — no running application, no database, no seeded
stack — so nothing about a feature branch makes its answer less true, and a finding is
cheapest to fix before the branch merges.

**The ZAP baseline keeps the image scan's gate**: the build's source branch is `main`,
`master` or `development` (**trunk** throughout this page), or the triggering tag ref
starts with `scan`. It boots the built image on the runner alongside its database, and
that cost is what keeps it narrowed — that, and the three-repository list below.

Neither ever runs on a `pull_request` event. `build-image` does not run there, so there
is no build to read the source of and no image to boot.

```bash
git checkout my-feature-branch
git tag scan-NC2-1234
git push origin scan-NC2-1234   # builds, then scans the image, the source and the app
```

### Semgrep on the pull request

Builds are the evidence path, not the feedback path. An ordinary pull request builds no
image, so it reaches no `sast-scan` in the build workflow, and without more than that a
developer first learns about a Semgrep finding after the change is already on trunk —
the wrong end of the review.

So the switcher carries its **own inline `sast-scan` job**, on `pull_request` for the
same eleven repositories `secret-scan` covers. It checks out the merge of head into
base — the code actually being proposed — runs the same pinned `semgrep` action, and
leaves two things behind:

- the **job summary**, with counts *and the findings themselves*: severity, `path:line`,
  rule ID and message, capped at 25 with a note naming the artifact when there are more
- the **`.report` artifact**, always complete

It is **advisory**. `scan.sh` exits non-zero only when the scanner itself broke; findings
leave the job green. And there is no notifier line: a SAST finding is not the
pager-worthy event a leaked credential is, and the pull request's checks tab is where it
will actually be read.

> [!NOTE]
> **Why inline in the switcher rather than in the build workflow's PR route.** Same
> reason as `secret-scan`: `novatalks.core`'s pull request route is a two-entry
> `build_target` matrix (`build-engine`, `build-reporting`), so a job there would scan
> identical source twice for one event. Source is source — one run per event.

This costs one more job on every pull request in those repositories, queueing against
the [per-size runner cap](runners.md#sizing-novatalkscore-only) alongside the linter, the
unit gate and `secret-scan`. That is the price of the feedback being timely.

### Where a feature build's SAST report goes

The `.report` is uploaded as a run artifact on every build. It is added to the
`TRIVY.SCAN_*` release only on trunk and `scan*` builds, because that release exists
only where `trivy-scan` created it — and letting `sast-scan` create one instead would
mint a `TRIVY.SCAN_*` git tag per feature build, noise the
[quarterly evidence walk](#where-the-reports-are) would have to step over. So on a feature build the
notifier's `📄 Report:` link points at the run, where the artifact lives, rather than at
a release-download URL that would 404.

All four scanners fan out from `build-image` in parallel:

```text
                ┌── trivy-scan ──┐
build-image ────┼── sast-scan ───┼──→ notify
                ├── dast-scan ───┤
                └── api-scan ────┘
```

None of them can start earlier: each needs `RELEASE`, `SHORT_REF_NAME` and `SHORT_SHA`
from `build-image` to address the release. None of them needs any of the others.

> [!NOTE]
> **They used to run in a chain**, on the reasoning that parallel scans "would only queue
> against the per-size cap of two runners". That was wrong in a way the numbers make
> plain: a chain does not avoid the queue, it *guarantees* one even when a runner is
> free, and every hop between jobs costs a fresh dispatch. On `novatalks.core` run
> [33614788933](https://github.com/novaitdevteam/novatalks.core/actions/runs/33614788933)
> — 35 minutes wall clock — the jobs did **1083s of work and spent 1017s in gaps between
> each other**, 397s of it waiting to start `dast-scan` alone. The `medium` pool went to
> [four runners](runners.md#sizing-novatalkscore-only) in the same change, so the fan-out
> has somewhere to land.
>
> Publishing is race-safe by construction: three jobs may now try to create the same
> release at once, and `softprops/action-gh-release` retries a `422 already_exists` and
> updates whichever release won — verified in its source, not assumed.

Each job carries `if: always() && …` so one scanner failing never swallows another or the
notifier.

`build-image` resolves the trunk test once, into an `IS_TRUNK` output, because a
job-level `if:` cannot reach a step inside another job.

> [!NOTE]
> `trivy-scan` keeps its own `Resolve scan policy` step and does **not** read
> `IS_TRUNK`. Two sources of truth for one predicate is a real wart, accepted
> deliberately: consolidating them would change the behaviour of the only scanner
> currently working, for cosmetics. Read the spec's D6 before "simplifying" it.

## Dependency scanning (source manifests)

`trivy-scan` already reads dependencies that ship **inside a built image**
(`TRIVY_PKG_TYPES: library`) — real coverage, exercised on `novatalks.core`'s production
`node_modules` today. What it structurally cannot see:

- **a frontend bundle with no manifest.** `novatalks.ui`'s runtime image is
  `FROM cgr.dev/chainguard/nginx` plus `COPY --from=builder /app/dist` — no
  `node_modules`, no `package.json`, no lockfile in the image at all. A vulnerable
  library minified into a `.js` file has no manifest entry for any scanner to read.
- **devDependencies.** `novatalks.core` runs `npm prune --omit=dev` before the image is
  built; a vulnerable build-time dependency never reaches it.
- **a repository that builds no image**, or builds one only after merge.
  `novatalks.chatwidget` zips `dist` and publishes it as a release asset;
  `novatalks.ui-lite` and `nova.docs` build no container at all. And on an ordinary pull
  request `build-image` never runs regardless of repository, so there is no dependency
  signal until after merge for anyone.

So this is a **source** scan, not an image scan: it reads whatever lockfiles are in the
checkout, on the same inline pull-request gate as [`sast-scan`](#semgrep-on-the-pull-request)
above and for the same reason — a developer should hear about a known-vulnerable
dependency before the change merges, not at the next quarterly audit.

**Be honest about what this reads.** A lockfile entry is a *declared* dependency at a
*declared* version. This finds a known-vulnerable version of something `package.json`
and its lockfile say is there. It does not find vulnerable code we wrote ourselves (that
is Semgrep's job), and it cannot find a vulnerable library that was vendored into the
tree with no manifest entry at all — there is nothing here for either tool to read in
that case, and no `not-run`-style loud skip either, because nothing about that shape
looks like a failure to either scanner: both tools simply see fewer packages than the
tree actually contains.

### Two databases, deliberately not de-duplicated

**`trivy fs --scanners vuln`** and **OSV-Scanner** both read the same checkout, and
neither's result is merged into the other's:

| Tool | Database | Invocation |
| --- | --- | --- |
| **Trivy** (`fs` mode) | aquasecurity's own feed | `uses: aquasecurity/trivy-action@v0.36.0`, `scan-type: fs` — called directly in the `deps-scan` job, the same place every other Trivy job in this repository calls it. There is no `validate.sh` wrapper guard for Trivy the way there is for Gitleaks, Semgrep and ZAP. |
| **OSV-Scanner** | osv.dev, which aggregates GitHub Security Advisories and the npm advisory feed among others | invoked inside [`deps-scan/scan.sh`](../.github/actions/deps-scan/scan.sh) via a pinned digest, the same shape Semgrep's `scan.sh` uses for its own `docker run` |

They are a genuine cross-check, not a duplicate: two independent vulnerability
databases can (and in practice do) know about different advisories for the same
package, or fix-version data that disagrees by a patch release. The report and the job
summary list both tools' findings **separately**, never merged into one row, so a
disagreement between them stays visible instead of being silently averaged away.

**OSV-Scanner is pinned by tag and digest**, the same policy as every other scanner
image in this repository:

```
ghcr.io/google/osv-scanner:v2.5.1@sha256:8108ae94eadea5a02c9bec6e646909d5b790b44bd62d7f5b7f0b1d6d0ffc7734
```

Obtained the same way the Semgrep pin's own comment documents:

```bash
docker buildx imagetools inspect ghcr.io/google/osv-scanner:v2.5.1
# take the manifest-list digest, not a per-architecture one
```

To upgrade: bump the tag, re-run that command, and re-verify the JSON shape `scan.sh`
reads (`.results[].source.path`, `.results[].packages[].package.*`,
`.results[].packages[].vulnerabilities[].*`) against a fixture that actually produces
findings — the same three-part discipline the Semgrep pin's comment describes, since the
harness stubs `docker` and proves nothing about the real image.

### A scanner that could not run must never look like a clean scan — and here, `.report` JSON alone is not enough

Both tools were checked live, not assumed, for the exact trap this page is built around:
does a broken scanner produce the same output as a genuinely clean one?

**Trivy** fails the way you would hope: a DB-fetch failure with no cache exits non-zero
and writes no JSON file at all — reproduced with `--skip-db-update` against an empty
cache directory (`FATAL … --skip-db-update cannot be specified on the first run`, exit 1,
empty stdout). So "no output file, or a file that is not valid JSON" is real, reachable
signal for Trivy, not a corner nobody hits. `deps-scan/scan.sh` treats Trivy's own
`.Results` key being entirely absent as its version of Semgrep's zero-files guard: it is
the actual shape Trivy's JSON takes when it found no lockfile at all, and a `.Results[]`
entry whose `.Packages` is empty is treated the same way defensively, in case that shape
is ever produced live.

**OSV-Scanner does not fail the way you would hope.** A real network failure reaching
`api.osv.dev` — reproduced with `docker run --network none` — still exits with a
perfectly well-formed JSON document: the lockfile was found, the package list is
populated, and the vulnerability query simply came back empty because it never left the
container. **The JSON body alone is indistinguishable from a genuinely clean scan.**
Only the exit code carries the signal, and it has to be checked against the exact set
OSV-Scanner's own source documents
(`cmd/osv-scanner/internal/cmd/run.go`, `v2.5.1`):

| Exit | Meaning |
| --- | --- |
| 0 | clean — ran to completion, nothing found |
| 1 | `ErrVulnerabilitiesFound` — findings present |
| 128 | `ErrNoPackagesFound` — no manifest found; stdout is empty, not `{}` |
| anything else (127 generic, 129 `ErrAPIFailed`, 130 `SIGINT`, …) | scanner error, **even when stdout parses as valid JSON** |

This is the same shape as the ZAP `0|1|2` exit ladder elsewhere in this repository, and
for the same reason: the exit code is load-bearing and the response body is not enough
on its own. `scripts/test-deps-scan.sh` has a scenario for exactly this — a canned exit
127 and exit 129 alongside a JSON body that looks completely clean, both asserted as
`error`, never `clean`. No synthetic canary file is needed here the way Semgrep needs
one: a repository's own real lockfile and its own real package list, once the exit-code
and `.Results`/`.Packages` guards above rule out the "ran but silently learned nothing"
shapes, are themselves the proof of parsing.

### The fourth outcome: `no-manifests`

A repository with no lockfile at all is a legitimate state, not a failure — but it must
never be reported as `clean`, which would claim a check that never actually happened.
`deps-scan` gets its own fourth outcome for exactly this, parallel to DAST's `not-run`:

| Outcome | What it means | Build |
| --- | --- | --- |
| `clean` | both tools found at least one lockfile, and neither found a vulnerability | 🟢 green |
| `findings` | at least one tool found a vulnerability | 🟢 green — advisory, findings never fail the job |
| `no-manifests` | **neither** tool found a manifest to read | 🟢 green, and **said loudly** — not a clean result |
| `error` | either tool could not prove it ran (see above) | 🔴 **red** |

`no-manifests` requires **both** tools to agree there is nothing to scan. If one tool's
lockfile-format support does not cover this repository's ecosystem but the other tool
still found and parsed a real manifest, that is not evidence of a missing dependency
signal — it is reported as `clean` or `findings` from whichever tool actually parsed
something, with the other tool's `no-manifest` state logged for visibility only.

Advisory, matching every other scanner on this page: `warn-only` governs findings, never
the difference between a real scan and a broken or absent one. `scan.sh` exits non-zero
(`2`) only on `error`; `clean`, `findings` and `no-manifests` all leave the job green. No
notifier line — a vulnerable transitive dependency is not the pager-worthy event a leaked
credential is, and this job's own checks-tab entry is where it will be read.

### Report and job summary

Same discipline as `sast-scan`: the `.report` artifact is always complete, and the job
summary lists the findings themselves — package, installed version, fixed version,
severity, advisory ID — not only a count, capped at 25 combined across both tools with
an explicit `Showing 25 of N` note naming the artifact when there are more. The two
tools' findings are listed in **separate sections**, `[trivy]` and `[osv]`, never merged
into one row — see [Two databases](#two-databases-deliberately-not-de-duplicated) above
for why.

### Which repositories

The same eleven-repository list `secret-scan` and `sast-scan` already cover — dependency
scanning asks a different question of the same set of live repositories, and there is
nothing per-repository about reading a lockfile the way there is about booting an image
for DAST.

### Where the logic lives

[`deps-scan/action.yml`](../.github/actions/deps-scan/action.yml) +
[`scan.sh`](../.github/actions/deps-scan/scan.sh) hold the OSV-Scanner invocation and the
decision logic for both tools; Trivy itself is called directly in the `deps-scan` job in
`ci-build-trigger-switcher.yaml`, with its JSON output path and step outcome handed to
the action as inputs. `continue-on-error: true` on that Trivy step matters structurally:
without it, a failed Trivy step would stop the job before `deps-scan/scan.sh` ever ran,
leaving a bare GitHub Actions step failure with no report behind it — the same reason
Semgrep's `scan.sh` wraps its own `docker run` in `set +e` rather than letting a failure
abort the script outright.

`validate.sh`'s scanner-invocation guard now also covers OSV-Scanner: no workflow may
run `osv-scanner scan` or `docker run … google/osv-scanner` itself, only through
`.github/actions/deps-scan`. Trivy has no equivalent guard, on purpose — it never had a
"wrap it in an action" rule anywhere in this repository, `deps-scan` included.

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
| `findings` | the scan ran and found something at a counted level | 🟢 green — `warn-only` governs findings |
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

### Which repository is being scanned

Both DAST actions take a `target-repository` input: the bare name of the repository
whose image is under the scanner, e.g. `novatalks.core`. It defaults to empty, which
falls back to the repository the job is running in (`GITHUB_REPOSITORY`).

That fallback is exactly right for the reusable build workflow — it runs in the product
repository's own context, so the two names are the same — and it is exactly wrong for
[`ci-dast-pentest.yaml`](../.github/workflows/ci-dast-pentest.yaml), which runs in
`nova.ci` and scans somebody else's published image. Two things key off the name:

- **the Postgres major version.** `novatalks.core` gets `postgres:17.9-trixie`, every
  other repository `postgres:16`. Resolved from the *runner's* name, a pentest of
  `novatalks.core` would silently have taken `postgres:16`. The chosen image, the
  repository it was chosen for, and where that name came from are now all printed:
  `DAST postgres: postgres:17.9-trixie — chosen for 'novatalks.core' (from the
  target-repository input)`.
- **whether `GITHUB_WORKSPACE`'s `.env.example` is this application's configuration.**
  See below. When the workspace is a checkout of a different repository, nothing is
  seeded from it and the log says so.

Both `dast-scan` and `api-scan` in the build workflow pass the input explicitly even
though it equals their fallback, so the value never depends on who is calling.

### Seeding the app container from `.env.example`

> [!NOTE]
> The seeding mechanics in this block — the `.env.example` strip, the empty-value drop,
> `extra-env`, the `DATABASE_URL` build, the port forcing — all live in `scan.sh` and are
> unchanged. Several examples below (`nova.chatsconnector.signal-client-api`,
> `nova.chatsconnector.telegram-client-api`, `novatalks.dialer`) are headless repositories
> that were **removed from the baseline on 2026-09-01** (see [Which repositories](#which-repositories)),
> so no `Resolve DAST target` arm exercises them today. They are kept here because the
> machinery is exactly what api-scan reuses — `nova.chatsconnector.telegram-client-api`,
> `whatsapp`, `signal` and `dialer` all now have their own `extra-env` in the `Resolve
> api-scan target` arm too (see [Four ways to acquire the token](#four-ways-to-acquire-the-token)).
> The examples are how the mechanic was established, not a claim
> that those repos are scanned by the baseline now. `novatalks.core`, which is kept, still exercises the `.env.example` seeding
> and the `DATABASE_URL` build.

Some engines need more than `DATABASE_*`/`REDIS_*` to boot (`novatalks.core`'s S3 file
storage, among others). Rather than hardcode product-specific env vars in `scan.sh` — or
worse, a credential — the action reads the product repository's own `.env.example`, the
same file `ci-build-ntk-on-push-tags-run-test.yaml` already trusts for integration
tests, strips it down, and hands the survivors to `docker run --env-file`.

**"The product repository's own" is a precondition, not a description.** The file is
read out of `GITHUB_WORKSPACE`, and under the pentest workflow that workspace holds
`nova.ci`, which has an `.env.example` of its own. Seeding it would hand the scanned
container four unrelated variables, log a perfectly plausible `seeded 4 variable(s)`,
and then blame the image for the boot failure it caused. So when
[`target-repository`](#which-repository-is-being-scanned) names a repository other than
the one checked out, `scan.sh` seeds nothing from that file and emits a `::warning::`
saying which checkout it found. It is a warning rather than a loud skip on purpose: a
static-nginx target like `novatalks.ui` needs no seeding at all and must still be
scannable. If the application then does not come up, the loud skip carries the reason
with it — *"the image did not come up within 300s — and no .env.example was seeded,
because GITHUB_WORKSPACE holds a checkout of 'nova.ci', not of 'novatalks.core'"* — so
the failure names our own missing input instead of the image.

That is exactly what live pentest run 33882314584 reported for `novatalks.core`/browser/
ephemeral, and the message was doing its job — but the gap it named was closable. The
`api` arm boots the identical image successfully with no `.env.example` at all, using
five `AWS_S3_*` boot dummies (see [Per-repository `extra-env`
overrides](#per-repository-extra-env-overrides) below) plus
`DEFAULT_ADMIN_USER`/`DEFAULT_USER_PASSWORD` — so the same values close the gap for
`browser` too, for reasons that are not endpoint-specific: the
entrypoint's own seeder (create-database/migrate/seed-database) runs before either
surface serves anything, and `MulterConfigService.createMulterOptions()` `getOrThrow()`s
the five S3 keys at module registration regardless of which surface is ever scanned.
They cannot simply join `DT_EXTRA_ENV`, though: `dast/scan.sh` applies `extra-env` with
`-e` *after* `--env-file`, so on the build workflow's own path — where the real
`.env.example` (including the real S3 config the [`novatalks.core`-scoped R2/S3
exception](../CLAUDE.md) documents) *is* seeded — it would override a value that is
already correct there, and change a scan that already works
(`WARN-NEW: 2, PASS: 65`). A second field, `unseeded-env` (`DT_UNSEEDED_ENV` in
`targets.sh`, `DAST_UNSEEDED_ENV` in `scan.sh`), is folded into `DAST_EXTRA_ENV` only
inside the branch above where `scan.sh` has already determined nothing was seeded — a
no-op on every existing caller, live only for `ci-dast-pentest.yaml`. Both `Resolve DAST
target` steps and `ci-dast-pentest.yaml`'s `Resolve target` step bridge it from
`targets.sh` regardless, per the "every `DT_*` is bridged" rule the target table itself
follows.

`.env.example` is a human-facing file, not a strict `KEY=value` format: on
`novatalks.core` it carries `NODE_ENV=production // production, development, test`.
Docker's `--env-file` strips whole-line comments only, never a trailing one, so the
literal comment text became part of `NODE_ENV`, Sequelize CLI found no config section by
that name, and the engine never booted — reported correctly as `not-run`, but for the
wrong reason. Two rules fix it, applied before the file ever reaches `docker run`:

- any line whose value carries a trailing ` //` or ` #` comment is **dropped outright**,
  not trimmed — guessing where the value ends is how a password containing ` #` gets
  corrupted instead of dropped. The drop is anchored on the whitespace before the marker,
  so a URL value (`https://…`, no space before its own `//`) survives.
- `NODE_ENV` is **never seeded**, comment or not: it selects the application's own code
  paths and config sections, and the image already sets it correctly
  (`ENV NODE_ENV=production`) — seeding it from documentation can only make it wrong.

`scan.sh` logs how many variables were seeded and how many lines were dropped, by which
rule — names and counts only, never values, since the file may carry credentials.

`.env.example` is written for `dotenv`, which strips a **matching pair** of surrounding
quotes from a value — first and last character both `"` or both `'` — before handing it
to the process. Docker's `--env-file` does not: `nova.chatsconnector.telegram-client-api`
carries `DATABASE_URL="postgresql://user:!1q2w3e@localhost:5432/novatalks..."`, and the
container received a value whose first character is `"`, which Prisma rejected outright
(`the URL must start with the protocol 'postgresql://'...`) — the engine never booted.
`novatalks.core`'s `.env.example` has six quoted values that were reaching its container
the same way; it happened to boot anyway because none of the six was load-bearing.
`scan.sh` now strips exactly that matching pair before the file reaches `docker run` —
never an inner quote, never an unmatched leading quote with no trailing one, no
whitespace trimmed. That is dotenv's own rule, nothing more.

### The action owns the listen port

`scan.sh` decides which port to poll (the wait-loop) and which port to hand ZAP (the
scan target), but until this fix it left which port the application actually **listens
on** to whatever `.env.example` said — and the two can disagree.
`nova.chatsconnector.signal-client-api`'s `.env.example` carried `APP_PORT=5555` while
its chart `containerPort`, its Dockerfile `EXPOSE` and its `Resolve DAST target` arm all
agreed on `3000`. The seeding passed `APP_PORT=5555` through, the application booted on
it (`Nest application is running on PORT: 5555`), and the wait-loop polled `3000` until
it timed out — a perfectly healthy boot reported as `not run`.

This is the third defect of one shape: `NODE_ENV` was the first, a template value with a
trailing comment overriding a correct image default; quoted values were the second.
`.env.example` is documentation, and it must not decide anything the scan itself depends
on. `scan.sh` now forces the resolved port onto the container after `--env-file`, under
both names in use across these repositories:

### An empty value is dropped, not passed through

The fourth defect of the same shape: `.env.example` leaves plenty of values blank as
template placeholders (`KEY=`), and until now every one of those blank lines was seeded
as a literal empty string. `novatalks.dialer` declares
`MEMORY_RSS_THRESHOLD: Joi.number().integer().default(0)` — a perfectly good default —
but its `.env.example` carries `MEMORY_RSS_THRESHOLD=`. Joi only applies `.default()`
when a value is `undefined`; an empty string is a value, and `.number()` rejects it, so
the engine never booted (`"MEMORY_RSS_THRESHOLD" must be a number`) even though it never
needed the line at all.

An empty value in a template means "fill this in", not "set this to the empty string",
and passing it through is strictly worse than dropping the line: dropping it lets an
application's own default apply, exactly as it would if the line were never written,
and a variable that is genuinely required still fails loudly by its own name — a far
better diagnostic than a type error two layers down. `scan.sh` now drops any line whose
value is empty or entirely whitespace, in the same pass that strips quotes, and folds
the count into the same log line as the comment, `NODE_ENV` and (once resolved) seeded
totals.

```
-e PORT="$DAST_PORT" -e APP_PORT="$DAST_PORT"
```

Both, because the repositories disagree on the name: `nova.chatsconnector.whatsapp-client-api`
reads `PORT`, while `novatalks.core`, the telegram connector and the signal connector all
read `APP_PORT`. Coming after `--env-file` means either name wins over whatever the
template said, exactly like the `NODE_ENV` filter and the quote-stripping above. An
application that reads neither — `novatalks.ui`, served through nginx — is unaffected.
This is also what keeps the three uses of the port — what the container listens on, what
the wait-loop polls, and what ZAP scans — from ever disagreeing again.

### Per-repository `extra-env` overrides

`.env.example` is a template, and some of its values are placeholders on purpose.
`nova.chatsconnector.signal-client-api` ships `S3_ENDPOINT=https://<account-id>.r2.cloudflarestorage.com`
— the angle brackets are documentation, not a value, and NestJS's config validator
rejects it as an invalid URL outright. Postgres came up and migrations ran clean; only
the boot itself failed, and none of the filters above can fix it, because the file
isn't malformed — it's a template doing exactly what a template does. The other `S3_*`
variables in the same file are blank and pass unchallenged; only the URL-shaped one
needs a value at all.

`dast/action.yml`'s `extra-env` input is the escape hatch: newline-separated
`KEY=VALUE` lines, applied to the application container as `-e` flags **after**
`--env-file`, so each overrides the seeded value of the same name. Blank lines are
skipped and surrounding whitespace on a line is trimmed; nothing else is parsed, so a
value containing `=` survives. `scan.sh` logs how many overrides were applied, never
their content — the mechanism is generic, and a future repository could put something
sensitive there even though today's only use is a dummy URL.

`nova.chatsconnector.signal-client-api`'s `Resolve DAST target` arm sets
`S3_ENDPOINT=https://s3.example.com` — `example.com` rather than an invented TLD
because it is IANA-reserved for exactly this purpose and satisfies URL validators. It
is never contacted during a baseline scan and carries no credential.

Past the URL, the same config validator rejects the next blank `S3_*` variable, one at
a time (`"S3_ACCESS_KEY_ID" is not allowed to be empty`, then the next), so the arm
seeds the whole plausible set together — `S3_ACCESS_KEY_ID`, `S3_SECRET_ACCESS_KEY`,
`S3_BUCKET` and `WEBHOOK_SECRET` — rather than iterating one blank per five-minute CI
run. `nova.chatsconnector.telegram-client-api`'s arm does the same for
`TELEGRAM_API_ID`, `TELEGRAM_API_HASH`, `NOVATALKS_ACCESS_TOKEN` and
`ENCRYPTION_SECRET` (`"TELEGRAM_API_ID" is not allowed to be empty` was the first
error); `TELEGRAM_API_ID` is numeric and `TELEGRAM_API_HASH` is 32 hex characters so a
validator checking shape, not just presence, accepts them. `TELEGRAM_API_HASH` is
thirty-two *identical* hex characters rather than a realistic-looking one on purpose:
`generic-api-key` is Gitleaks' heuristic entropy rule, and a plausible 32-character hash
written into this workflow would trip it and red the required
[secret-scan](secret-detection.md) check. Do not "improve" the placeholder's realism.
All of these are dummy values, not credentials — they exist only so a scanned container
reaches its HTTP listener; if one ever needs to be real, it belongs in a secret, not in
this step.

`novatalks.dialer`'s arm seeds five `AWS_S3_*` values for a different reason again —
not a validator rejecting a blank, but object storage wired at boot: `multer-s3` throws
`bucket is required` without one, and `FILE_DRIVER=s3` is the only driver that
repository supports, so storage cannot simply be switched off for the scan.
`AWS_S3_ENDPOINT` uses the same IANA-reserved `example.com` as the signal arm and is
never contacted by a baseline scan.

`novatalks.core`'s **api** arm hits the same shape from a different angle. The baseline
never saw it, because `dast/scan.sh` seeds the engine from its own `.env.example`, which
defines `AWS_S3_*`; `dast-api/scan.sh` seeds nothing from that file at all. Run
33863826945 loud-skipped with the container log reading `[Nest] ERROR
[ExceptionHandler] TypeError: Configuration key "file.awsS3AccessKeyId" does not
exist`: `MulterConfigService.createMulterOptions()` runs at module registration, before
any request lands, and `getOrThrow()`s `awsS3AccessKeyId`/`awsS3SecretAccessKey`/
`awsS3Endpoint`/`awsS3Region`/`awsS3Bucket` unconditionally, because `FILE_DRIVER`
defaults to `s3` and none of the five has a default. The `novatalks.core/api` arm now
sets `AWS_S3_ACCESS_KEY_ID`, `AWS_S3_SECRET_ACCESS_KEY`, `AWS_S3_BUCKET`,
`AWS_S3_REGION` and `AWS_S3_ENDPOINT` as boot dummies — the scan never uploads a file,
so the values only need to exist and parse. `AWS_S3_ENDPOINT` uses
`http://s3.example.invalid`, an RFC 2606-reserved domain, rather than the `example.com`
convention above, and the other four are self-describing strings like
`dast-dummy-not-a-real-key` — obviously fake, not a plausible-looking credential, since
this repository is public and a plausible fake reads as a leak to anyone (or any secret
scanner) reading it later.

`novatalks.core`'s **browser** arm needs the identical five `AWS_S3_*` dummies plus
`DEFAULT_ADMIN_USER`/`DEFAULT_USER_PASSWORD` for the same module-registration and seeder
reasons, but only from `ci-dast-pentest.yaml` — the build workflow's own browser scan
already gets real values from the product repository's real `.env.example`. They cannot
live in this arm's `extra-env`: `dast/scan.sh` applies `extra-env` with `-e` *after*
`--env-file`, so on the build workflow's path it would override a value the real
`.env.example` already got right, including the real S3 config the `novatalks.core`-
scoped R2/S3 exception in `CLAUDE.md` documents. They live instead in a second field,
`unseeded-env` (`DT_UNSEEDED_ENV` in `targets.sh`), that `dast/scan.sh` folds into
`DAST_EXTRA_ENV` only inside the branch where it has already determined nothing was
seeded (`target-repository` disagrees with `GITHUB_WORKSPACE` — see [Which repository is
being scanned](#which-repository-is-being-scanned) above) — a no-op on every existing
caller, live only for the pentest workflow. Confirmed live on pentest run 33882314584:
the browser scan of `novatalks.core`/ephemeral loud-skipped for lack of exactly these
values.

Two entries that once lived in these same lists are gone now that `scan.sh` drops empty
values instead of passing them through. `S3_PUBLIC_URL` is declared
`Joi.string().uri(...).empty('')` — optional, no default needed, and
`storage.config.ts` already falls back to path-style `<S3_ENDPOINT>/<S3_BUCKET>` when
it's unset — so seeding a dummy only ever overrode a fallback that already worked.
`SIGNAL_MAX_FILE_SIZE`, by contrast, stays: its schema
(`Joi.number().integer().positive().empty('').default(104857600)`) would make it just
as removable, but its `.env.example` line reads
`SIGNAL_MAX_FILE_SIZE=104857600# inbound file size...` with no space before the `#`, so
the trailing-comment filter above — anchored on a preceding space — never strips it,
and the literal comment text would still reach the container glued to the number. That
is a comment-filter gap, not an empty-value one; dropping empty values does not touch
it, so the override still earns its keep. Not every workaround in this file traces back
to the empty-value fix — `TELEGRAM_API_ID`, `TELEGRAM_API_HASH`, `S3_ENDPOINT`,
`S3_ACCESS_KEY_ID`, `S3_SECRET_ACCESS_KEY` and `S3_BUCKET` are all `.required()` with no
default, so dropping their blank line only makes the failure clearer, not avoidable;
`NOVATALKS_ACCESS_TOKEN`, `ENCRYPTION_SECRET` and `WEBHOOK_SECRET` sit outside every
Joi schema in their repositories entirely, so there is no schema line to justify
dropping them either.

Both templates also leave `REDIS_PASSWORD` blank, and the signal one leaves
`DATABASE_SSL_CA_CERT` blank too — both stay blank here on purpose. The redis this
action starts has no password, so supplying one would break the connection that
currently works, and a bogus CA certificate would break TLS negotiation rather than
satisfy it. The telegram template also leaves `PROXY_IP`, `PROXY_PORT`,
`PROXY_USERNAME`, `PROXY_PASSWORD` and `PROXY_SECRET` blank: an outbound proxy that
does not exist is worse than none, and the validator has not complained about them.
Every other arm sets `extra_env=""` explicitly, following the same
no-arm-inherits-from-another discipline as `port`, `health_path`, `needs_db` and
`needs_nats`.

### `DATABASE_URL` for Prisma-based repositories

The discrete `DATABASE_HOST`/`PORT`/`USERNAME`/`PASSWORD`/`NAME` variables are the
NovaTalks convention and serve the Sequelize-based repositories. Prisma, which
`nova.chatsconnector.telegram-client-api` uses, has no notion of those — it wants a
single `DATABASE_URL`. Even with the quoting fixed, the value written in that repo's
`.env.example` names a different user, password and database than the postgres this
script actually starts, so the connection would still fail.

When `DAST_NEEDS_DB` is `true`, `scan.sh` builds
`DATABASE_URL=postgresql://<user>:<password>@127.0.0.1:5432/<dbname>` from the very same
values it already uses for the discrete variables and for the postgres container it
starts, and passes it as an explicit `-e` flag after `--env-file`, so it overrides
whatever the example file said. It is never set when no database is started. The two
conventions coexist deliberately and cannot disagree, since both come from one source;
the URL is simply ignored by the Sequelize repositories that don't look for it.

### Where the ZAP counts come from

`zap-baseline.py` has two output channels and they do not carry the same information.
`-w` writes the traditional **"ZAP Scanning Report" markdown** — `## Summary of Alerts`
and a section per risk level. That file is the human-readable artifact, and it is what
the `.report` is assembled from. But **no count appears in it at all**, so every number
is taken from a `tee` of the console stream.

One line carries all of them, printed unconditionally at the end of any completed scan:

```
FAIL-NEW: 0	FAIL-INPROG: 0	WARN-NEW: 11	WARN-INPROG: 0	INFO: 4	IGNORE: 7	PASS: 30
```

`scan.sh` anchors on `^FAIL-NEW: <digits>` followed by a **literal tab byte** and
`FAIL-INPROG: `, and reads all six. The tab has to reach `grep` as a real tab, which is
why the pattern is written with ANSI-C quoting (`$'…\t…'`) and not as a plain
single-quoted string: BSD `grep` expands `\t` inside a pattern, GNU `grep` does not — it
warns `stray \ before t` and matches a literal `t`. Every runner is GNU, so the plainly
quoted form matches nothing there, and every completed scan reports a missing tally and
reds the build. A macOS harness run is the one place it passes. The anchor
matches the tally's shape rather than its prefix on purpose: every `FAIL`-level finding
also prints a per-rule line beginning `FAIL-NEW: `, before the tally, so a bare-prefix
match would read an alert name where a number belongs and misreport a real finding as a
broken scanner. `FAIL-NEW` is the must-fix count,
`WARN-NEW` the warning count, and `INFO` / `IGNORE` are what the
[triage register](#recording-a-decision-about-a-finding) suppressed — reported even on a
clean run, because suppressions nobody can see are suppressions nobody audits.

**A missing tally line is a scanner error, never a clean scan.** A completed scan always
prints one, so its absence means the scan did not finish — and an unfinished scan
reporting zero findings is the exact failure this page is built around. The same applies
to a tally whose numbers do not parse: the format would have moved under the pinned
digest, and guessing zero there reports a clean scan that never happened.

This is not a detail. `-I` makes the script exit `0` even with warnings present, so the
exit code carries no signal either; counting the wrong stream leaves **both** channels
dead and every run reports `🟢 clean` with `findings=0`, including one where ZAP found
twenty warnings. The harness carries a scenario whose markdown report is full of alert
text and free of any count, so a `scan.sh` that ever reads the `-w` file again fails.

`${PIPESTATUS[0]}` matters for the same reason: it is ZAP's own exit status,
unambiguously. Plain `$?` after the pipe happens to give the same answer today only
because `pipefail` is set — it would silently become `tee`'s status the moment that
changed, and it reports `tee`'s status whenever `tee` itself fails.

The exit ladder is read from the same source rather than assumed
(`zap-baseline.py:697-708`):

| Exit | Meaning | Treated as |
| --- | --- | --- |
| 0 | passes only | clean |
| 1 | `FAIL`-level findings present | **findings** — `-I` does *not* suppress this |
| 2 | warnings with `-I` absent | findings — unreachable while `-I` is passed |
| 3 | an exception, or no rule ran at all | scanner error |

Exit `1` is the one to be careful with. `-I` gates exit `2` alone, so the moment the
triage register gains its first `FAIL` entry, an exit-`1` run is a *finding* — and
treating it as a broken scanner would red a trunk build for one.

The console log lives under `RUNNER_TEMP`, is deleted by the same `EXIT` trap that
removes the temporary env file, and is never uploaded — it is raw output about a
container booted with the product repository's own environment.

### `scan-mode`: baseline or full

`dast/action.yml`'s `scan-mode` input (`baseline`, the default, or `full`) reaches
`scan.sh` as `DAST_SCAN_MODE` and selects the whole ZAP invocation, not a single flag:

| `scan-mode` | Script | Spider | Triage register |
| --- | --- | --- | --- |
| `baseline` (default) | `zap-baseline.py` | traditional | [`zap-baseline.conf`](../.github/actions/dast/zap-baseline.conf) |
| `full` | `zap-full-scan.py` | modern (`-j`) | [`zap-full-scan.conf`](../.github/actions/dast/zap-full-scan.conf) |

`zap-baseline.py` carries no active scanner at all — it only observes. `zap-full-scan.py`
adds the whole active rule set on top of the passive one: injection, path traversal,
command execution, the classes `baseline` never reaches. `-j` matters independently of
that: it swaps ZAP's traditional spider for the modern, browser-driven one, which is the
only way a single-page application is more than one page to ZAP. nginx serves
`index.html` for every route and the traditional spider has no JavaScript engine to
follow it with, so a SPA scanned without `-j` is one page regardless of which script ran.

The exit ladder and the tally line are identical between the two scripts — verified
against `zap-full-scan.py:480` (the tally) and `:511-522` (the exit codes) rather than
assumed — which is why
[`dast-common.sh`](../.github/actions/dast/dast-common.sh) and the `0|1|2` exit `case`
are shared unchanged between both modes; see
[Where the ZAP counts come from](#where-the-zap-counts-come-from) above. An unrecognised
`scan-mode` is a scanner error, never a silent fallback to `baseline`.

> [!IMPORTANT]
> **`full` is not a penetration test either.** It sends real attack payloads — but only
> ever against the ephemeral container this action starts and kills for the job, never a
> deployed environment — and it is still unauthenticated: it attacks the same anonymous
> surface the baseline observes, so it still cannot see a broken authorization check or
> any logic flaw behind a login. It finds more than the baseline on the same surface, not
> a different surface.

### `zap-context`: teaching the crawl to log in

> [!NOTE]
> The table's `DT_ZAP_CONTEXT` is bridged to this input by
> [`ci-dast-pentest.yaml`](../.github/workflows/ci-dast-pentest.yaml)'s `Resolve target`
> step (`zap_context` output → `zap-context:` on the browser scan step). It was not, for
> a while: the table could set a value, the harness could assert it, and the scan would
> still have crawled anonymously with no signal anywhere. `scripts/test-dast-targets.sh`
> now asserts both directions — every `DT_*` the table sets is emitted by that step, and
> every key that step emits is passed on to a scan step. The build workflow's
> `dast-scan` runs in `baseline` mode, where `zap-context` is not consulted at all, so it
> has nothing to bridge.

`dast/action.yml`'s `zap-context` input (empty by default) names a file under
[`.github/actions/dast/contexts/`](../.github/actions/dast/contexts/). When `scan-mode` is
`full` and this is set, `scan.sh` copies that file into `RUNNER_TEMP` and appends
`-n <file> -U nova-ci-dast` to the `zap-full-scan.py` invocation — `nova-ci-dast` is the
one user name every context in this repository defines, never a per-repository value. A
context tells ZAP a login URL, the field names to POST, and a regex pair — one that
matches only while logged in, one that matches only while logged out — so the crawl can
tell the two states apart.

> [!WARNING]
> **A context needs both regexes or it is worse than no context.** With only one, ZAP can
> silently crawl as an anonymous user while the run still looks configured for
> authentication — the same "authenticated-looking, completely blind" shape as an
> unquoted `-z` replacer in `dast-api` (further down this page, the `-z` replacer values
> are single-quoted in `scan.sh` for exactly this reason). `-n` and `-U` travel together
> in `scan.sh` for the same reason: a context loaded with no user selected scans as
> nobody while looking configured.

[`contexts/novatalks-ui.context`](../.github/actions/dast/contexts/novatalks-ui.context)
exists and documents the one login request this repository has verified — both against
`novatalks.ui`'s own source and against its published image — but it is **not** wired
into [`targets.sh`](../.github/actions/dast/targets.sh): that arm leaves `DT_ZAP_CONTEXT`
empty, and the context file's own header comment explains why in full. In short,
`novatalks.ui` is a static SPA with no backend of its own; the ephemeral DAST scan boots
it alone (no database, no proxy), so `/auth/sign_in` has nothing behind it — confirmed
live (`POST /auth/sign_in` → `405 Not Allowed`) as well as in source (no API base URL is
configured anywhere in the client). Every route nginx serves is a byte-identical static
shell, logged in or not, because the SPA renders the difference client-side where no HTTP
response ZAP can regex-match ever reflects it. There is consequently no reliable
`loggedInIndicatorRegex`/`loggedOutIndicatorRegex` pair for this deployment shape, and per
the warning above, guessing one would be worse than leaving the context unwired. Revisit
once `novatalks.ui` is scanned alongside a real backend (or through something proxying to
one). Separately from the login-request fields above, the context file's surrounding XML
*structure* is written from documented ZAP conventions with no ZAP instance available to
verify it against — the file's own header names the specific elements to check first.

### Recording a decision about a finding

A scanner that can only ever add to its count is one people stop reading. Both scanners
have a way to write down "this is accepted" or "this must be fixed", and both keep that
decision in version control next to a reason.

**ZAP — [`zap-baseline.conf`](../.github/actions/dast/zap-baseline.conf) for `baseline`
mode, [`zap-full-scan.conf`](../.github/actions/dast/zap-full-scan.conf) for `full`
mode.** The two are never interchangeable: the active scanner loads a rule set the
passive one never reaches, so an `IGNORE` written for one is not a decision made for the
other. Every rule defaults to `WARN`; an entry overrides that for one rule ID. The
grammar is TAB-separated with at least three fields, identical in both files:

```
<rule_id>	<LEVEL>	<why this decision was made, and who accepted it>
<id>,<id>	OUTOFSCOPE	<regex matched against the alert URL>
```

| Level | Means |
| --- | --- |
| `FAIL` | must be fixed — counted and reported separately from warnings |
| `WARN` | the default; no entry needed |
| `INFO` | noted, out of the warning count, still in the report |
| `IGNORE` | accepted risk — write the reason; see below |
| `PASS` | treated as passing |

Both files ship with no entries, so neither changes anything until someone adds a line.
Adding one is a risk-acceptance decision, not a CI change.

The reason is a **review-time obligation, not a parsed one.** `10038<TAB>IGNORE<TAB>` with an
empty third field is accepted by `scan.sh`, because ZAP itself accepts it and this
validator must never reject a register ZAP would load. Nothing mechanical will stop an
unexplained `IGNORE`; the pull request is what stops it.

Rule IDs are not written from memory. Generate the list the pinned image actually loads,
against the script for the mode the register belongs to:

```bash
docker run --rm -v "$PWD:/zap/wrk:rw" ghcr.io/zaproxy/zaproxy:stable \
    zap-baseline.py -t http://example.com -g zap-rules.conf
# or, for zap-full-scan.conf:
docker run --rm -v "$PWD:/zap/wrk:rw" ghcr.io/zaproxy/zaproxy:stable \
    zap-full-scan.py -t http://example.com -g zap-rules.conf
```

`scan.sh` validates the shape of every line before anything is booted — at least two
tabs, and a level from the set above — and treats a malformed or missing register as a
broken gate. **It cannot validate the IDs.** ZAP reports alert counts per bucket, never
which configured IDs matched, so a well-formed line naming a rule that does not exist is
silently inert and nothing detects it. That limit is procedural, not mechanical: use the
generated list.

**Semgrep — inline `nosemgrep`, in the product repository.**

```ts
// nosemgrep: javascript.express.security.audit.xss.direct-response-write — value is a
// UUID from the router, validated by the Joi schema above. NC2-XXXX.
res.write(req.params.id)
```

Per-finding, next to the code it describes, reviewed in the pull request that introduces
it. This is the analogue of a `.gitleaksignore` fingerprint. A path-scoped
`.semgrepignore` is deliberately **not** used: it is the blanket `ignore tests/**` that
[secret detection](secret-detection.md) already rejected, and it hides whole directories
rather than one decision.

### The Semgrep canary guard

Semgrep exits `0` and reports an empty result set when no rules load, so
[`scan.sh`](../.github/actions/semgrep/scan.sh) refuses to call an empty result clean
until six things hold:

1. the container wrote an output file at all;
2. Semgrep exited `0` or `1` (`1` is "findings present"), not higher;
3. that output parses as JSON;
4. at least one file appears in `.paths.scanned`;
5. `.errors[]` carries no error without a `path`;
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
executed**, and `.errors[]` proves the **configs it executed with actually loaded**.
Together they mean a clean result is a real one.

`.errors[]` is not one kind of problem, though. Semgrep files a config/rule-resolution
failure there with no `path` — the error is about the run itself — and a per-file
problem such as a parse error or a scan timeout there too, with the offending file's
`path` attached. The second kind is routine on a large TypeScript monorepo and proves
nothing about whether the configs loaded: `novatalks.core`'s first real run hit twelve
of them, all per-file, on the same pinned image and configs `novatalks.ui` had scanned
clean forty minutes earlier. So `scan.sh` prints every error — level, type, path,
message — and only fails closed on the ones with no `path`; per-file errors are logged
as a warning with their count and the scan proceeds, findings and all.

The canary hit is excluded from every bucket — `ERROR`, `WARNING` and `INFO` — **by rule
ID, not by severity**. Its own severity is a fixed `INFO`; severity used to be a caller
input, and excluding by check_id instead means the exclusion does not depend on it —
severity used to be exactly the kind of caller-configurable value that could silently
coincide with the canary's own and stop excluding it.

Rules come from the registry rather than being vendored into `security/`, unlike the
Gitleaks config. Mirroring thousands of rule files to guard against the registry being
unavailable buys little: the registry going down surfaces as a red job, and the real
risk — running with zero rules and reporting clean — is what the canary closes, for far
less.

## Which repositories

**SAST covers every standard build repository**, `novatalks.core` included. There is
nothing per-repository about reading a checkout.

**`novatalks.chatwidget` also gets SAST**, from a `sast-scan` job in its own
`ci-build-ntk-on-push-tags-widget-build.yaml` rather than the main build workflow — that
repository routes to the widget workflow, not the standard one. It gets **no Trivy and
no DAST**, and that is a decision, not a gap: that workflow zips `dist` and publishes it
as a release asset, it produces no container image, so neither scanner has a target —
Trivy scans images, DAST boots them. Semgrep reads source, so it applies exactly as it
does everywhere else. The widget's `sast-scan` mirrors the main workflow's: every
non-`pull_request` build on any branch, same SHA-pinned checkout, same report-file
convention, and it upserts its report onto the release `build-widget` already creates
(`NTK.CHATWIDGET_<release>_<ref>_<sha>`) instead of a second one. It needs no
`PUBLISH_RELEASE` equivalent: `build-widget`'s own `Create a Release` step is ungated,
so every build it follows already has a release, feature branches included.

**DAST covers three browser-surface repositories**, gated on
`github.event.repository.name`, the same repository-scoped-exception pattern already
used for the [integration Postgres image](tests.md) and R2 file storage:

| repository | port | health path | needs-db | needs-nats | extra-env |
| --- | --- | --- | --- | --- | --- |
| `novatalks.ui` | 8000 | `/livez` | false | false | — |
| `novatalks.core` | 3000 | `/livez` | true | false | — |
| `nova.botflow` | 1880 | `/` | true | false | — |

The scope is three because the ZAP baseline is a **browser tool**: it spiders HTML and
checks response-header and cookie hygiene, and these three have a real browser surface
to spider. `novatalks.ui` is a Vue SPA, `novatalks.core` serves a dashboard, and
`nova.botflow` is the Node-RED editor — its baseline produced 14 alerts, one of them a
vulnerable JS library. On a headless JSON API the same scan finds a few response headers
and nothing a browser would, which is why the other six were removed (below). Read the
[non-penetration-test caveat](#what-these-two-are-and-what-they-are-not) above: even on
these three, a green DAST line means edge hygiene looks right, not that the app is secure.

`novatalks.ui` serves static assets through nginx; the other two are backends that need
postgres and redis before they boot. `nova.botflow` has no dedicated HTTP health route —
its chart probes over `tcpSocket`, so `/` is the correct health path: the boot wait-loop
accepts any HTTP response, a 404 included, because it is only testing whether the process
is listening, not whether a route exists. Do not "fix" that to `/livez` — there is
nothing there to hit. It needs redis or postgres depending on its storage configuration;
bringing up both is simpler than modelling the choice, and an unused container costs a
few seconds.

DAST is scoped that narrowly because, unlike the other two scanners, it has to **boot the
thing**. Every repository needs its own answer to: which port does the image listen on,
what path proves it is up, how long does it need, and does it need postgres and redis
first. Those are per-repository inputs on
[`dast/action.yml`](../.github/actions/dast/action.yml), and each one has to be
established against the real runtime image — a wrong path scans an error page and
reports it clean, which is the failure this whole design is built to avoid.

These per-repository values are resolved by
[`dast/targets.sh`](../.github/actions/dast/targets.sh)'s `dast_resolve_target <repo>
<api|browser>`: a `case "${repo}/${surface}"` in bash, one arm per repository/surface
pair, every value set explicitly (no arm inherits from another), setting `DT_PORT`,
`DT_HEALTH_PATH`, `DT_NEEDS_DB`, `DT_NEEDS_NATS` and `DT_EXTRA_ENV` (among others) in the
caller's scope. The **`Resolve DAST target`** step in `dast-scan` sources it and writes
those to `$GITHUB_OUTPUT`, following the same house pattern as `Resolve scan policy` in
`trivy-scan` and `Resolve test plan` in the test workflow. The table is a single sourced
file rather than a `case` inline in each step because it now has three consumers —
`dast-scan`'s browser surface, `api-scan`'s api surface, and the live-baseline dispatch —
and a copy in each step is a copy that drifts: a port fixed in one and not the others
silently reverts to guessing. This replaced a chain of inline ternaries that did not
scale past two repositories. The default arm is not a fallback: a repository/surface
pair that reaches a scan with no configured arm is a wiring mistake, and guessing a port
would scan nothing and report it clean — so the default arm emits `::error::` and returns
non-zero instead. `pg-image` stays a two-branch ternary (`postgres:17.9-trixie` for
`novatalks.core`, the action's `postgres:16` default for everyone else) rather than a
resolver arm, since it only ever has two truthy branches.

Adding a fourth repository to the baseline needs an explicit request, a real browser
surface worth spidering, **and a boot probe first** — port and health path verified
against the deployment chart or the Dockerfile, never guessed.

### The six removed on 2026-09-01

DAST once covered nine repositories. Six were removed on 2026-09-01 because they are
**headless JSON APIs** with no browser surface: `nova.chatsconnector.telegram-client-api`,
`nova.chatsconnector.whatsapp-client-api`, `nova.chatsconnector.signal-client-api`,
`novatalks.dialer`, `novatalks.uspacy.connector` and `novatalks.geoip-api`. The
unauthenticated baseline spiders HTML and checks header and cookie hygiene; against a
service that serves no HTML it reaches a handful of response headers and stops, so the
green line was measuring almost nothing while reading as coverage.

Their real coverage is the authenticated **[api-scan](#api-scanning-authenticated-zap)**,
which walks an OpenAPI spec rather than spidering pages. It ships today for
`novatalks.core` (`login`), `nova.chatsconnector.telegram-client-api` (`db-token`),
`nova.chatsconnector.whatsapp-client-api` and `…signal-client-api` (`db-insert`), and
`novatalks.dialer` (`env-token`) — each wired into `targets.sh` as its own per-repository
integration: seed data, its own token model, the spec endpoint, all verified against that
repository's own code, never assumed from telegram's or from each other's (`whatsapp` and
`signal` share a token schema, but `signal` diverges on health path and boot env — see
[Four ways to acquire the token](#four-ways-to-acquire-the-token)). `novatalks.uspacy.connector`
and `novatalks.geoip-api` publish no OpenAPI spec — no `@fastify/swagger`-equivalent
dependency anywhere in `novatalks.geoip-api`'s single-file `index.js`/`package.json`, verified
directly — so `zap-api-scan.py -f openapi`, which has no spider fallback, has nothing to
discover routes from. Neither has an api-scan path; adding one without a spec would only
ever produce a guaranteed, permanent loud skip.

Their boot inputs are kept here rather than deleted: each was established against the
deployment chart or the Dockerfile, and the api-scan expansion will reuse them.

| repository | port | health path | needs-db | needs-nats |
| --- | --- | --- | --- | --- |
| `nova.chatsconnector.telegram-client-api` | 3000 | `/` | true | false |
| `nova.chatsconnector.whatsapp-client-api` | 3000 | `/` | true | false |
| `nova.chatsconnector.signal-client-api` | 3000 | `/` | true | false |
| `novatalks.dialer` | 3000 | `/livez` | true | true |
| `novatalks.uspacy.connector` | 3000 | `/` | true | false |
| `novatalks.geoip-api` | 3000 | `/` | false | false |

`novatalks.dialer`'s port and health path came from the deployment chart
(`novatalks.charts`, `novatalks_v5/values.yaml`, `dialer.containerPort: 3000`, probing
`/livez` and `/readyz`); the other five ports from `docker/server.Dockerfile`'s
`EXPOSE 3000`. None of the six exposes a dedicated HTTP health route, so `/` is correct
for the same tcpSocket-style reason `nova.botflow` uses it — except `novatalks.dialer`,
which the chart gives `/livez`. `novatalks.geoip-api`'s `needs-db: false` was an
inference (no ORM dependency, a five-variable `.env.example`), never verified like the
others, and it stays unverified — see below, it will not get an api-scan arm either.
Every other boot input here (telegram, whatsapp, signal, dialer) was carried forward
and now has its own `api-scan` arm in `targets.sh`; several also needed `.env.example`
filters and per-repository `extra-env` overrides to boot at all, preserved in the
[`extra-env`](#per-repository-extra-env-overrides) section above.

### `novatalks.geoip-api` gets no DAST at all

This is a decision, not a gap. `novatalks.geoip-api` keeps Trivy, Semgrep and secret
detection; it gets **no DAST** — no baseline (it was never a browser surface, see
above), no `api-scan`, and it is not offered in `ci-dast-pentest.yaml`'s `repository`
dropdown either. Two reasons, verified against the repository's own code, not
inferred:

- **No authentication.** Grepped the whole ~220-line single-file Fastify service — no
  guard, no middleware, no header check. Anyone who can reach it can call it.
- **No OpenAPI spec.** No `@fastify/swagger` dependency anywhere in `package.json`.
  `api-scan` drives `zap-api-scan.py -f openapi` from the application's own spec and has
  no spider fallback, so there is no way for it to discover routes here at all.

Adding a `targets.sh` arm for either surface would only ever produce a guaranteed,
permanent `not-run` — a choice that always fails loudly is worse than not offering it,
which is why the pentest dropdown omits it too. This exclusion is also recorded as an
invariant in `CLAUDE.md`; revisiting it needs an explicit request, not a rediscovery of
the same absence.

### `needs-nats`, for `novatalks.dialer`'s api-scan

`novatalks.dialer` no longer reaches the baseline, so `needs-nats` has no browser-surface
consumer today — but the input still exists on
[`dast/action.yml`](../.github/actions/dast/action.yml), because the api-scan arm needs
it: a `novatalks.dialer` container reaches NestJS startup and then dies with
`Error: connect ECONNREFUSED ::1:4222` without a NATS server, because
`nats.config.ts`'s `registerAs` factory calls `NATS_SUBJECTS.split(',')` unconditionally
at config-load time and `main.ts` awaits `microService.listen()` — a real NATS
connection — before `app.listen()`.

`needs-nats` is now also an input on
[`dast-api/action.yml`](../.github/actions/dast-api/action.yml), and
`novatalks.dialer`'s `api` arm in `targets.sh` sets `DT_NEEDS_NATS=true`. The bring-up
itself — `docker run nats:2.10-alpine -js -m 8222`, the readiness poll against
`http://127.0.0.1:8222/healthz`, and creating the `campaign` JetStream stream the
dialer's client asks `$JS.API.STREAM.NAMES` for at startup — lives in exactly one place,
`dast_bring_up_nats` in
[`dast-common.sh`](../.github/actions/dast/dast-common.sh), and both `dast/scan.sh` and
`dast-api/scan.sh` call it rather than each carrying its own copy. It mirrors
`~/novatalks/scripts/nats-docker/scripts/js-init.sh`, the stand the team already uses
locally — same stream, same subjects, same retention — minus its `nsc push` step, which
provisions JWT accounts this unauthenticated server has no use for.

A NATS that never becomes ready, or a stream that fails to create, takes the same
`not-run` path a database failure does, naming NATS in the reason — never `clean`, never
`error`. The container is named `nova-nats` and torn down by each caller's own
`cleanup()` on every exit path, alongside `nova-pg` and `nova-redis`. It is tag-pinned
(`nats:2.10-alpine`), not digest-pinned, matching the existing `postgres:16`/`redis:8`
precedent — digest pinning stays reserved for the scanners themselves.

Bringing the stream up is not the whole story: once connected, `novatalks.dialer` creates
its own JetStream push consumer (`nats-config.service.ts`'s `consumerOptions`, built from
`nats.config.ts`), and the underlying `nats` client (`jsclient.js`) throws `Error: push
consumer requires deliver_subject` when `NATS_DELIVER_TO` is unset — confirmed live on
pentest run 33873579035, after the stream lookup had already succeeded. `targets.sh`'s
`novatalks.dialer/api` arm now sets `NATS_DELIVER_TO=dast-dialer-messages` in
`DT_EXTRA_ENV` for exactly this reason; `NATS_DELIVER_GROUP`/`NATS_DURABLE` are left unset
because both feed no-op calls when absent, producing a plain ephemeral consumer rather
than a crash. The browser-surface arm this repository used to have never hit this: `dast/
scan.sh` seeds the whole product-repo `.env.example`, which already carries
`NATS_DELIVER_TO`, while `dast-api/scan.sh` only ever passes the explicit
`DT_EXTRA_ENV` list.

The scan runs this NATS completely unconfigured — no auth, no TLS, no JetStream account
provisioning — because that is all the client side needs: `novatalks.dialer`'s own
`.env.example` already defaults to `NATS_SERVERS=localhost:4222` with `NATS_USER`,
`NATS_PASS`, `NATS_NKEY`, `NATS_JWT` all blank, `NATS_TLS_ENABLED=false` and
`NATS_STREAM_ENABLED=false`. Production NATS (`nats-system/ntk-nats-prod-cluster`) is a
three-node cluster with TLS certificates and NKEY/account authentication — none of that
belongs here, and nobody should "harden" this bring-up to look more like it; a scan needs
a server to connect to, not a faithful copy of the production topology. Both `scan.sh`
files also force `-e NATS_SERVERS=127.0.0.1:4222` onto the application container, for the
same reason `PORT`/`APP_PORT` are forced: the observed failure was `::1:4222`, i.e. the
client resolved `localhost` to IPv6, and a server bound to `0.0.0.0` still refuses that —
naming the address explicitly removes the resolution question rather than hoping it
resolves to `127.0.0.1` on its own.

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

**A `scan*` tag on `novatalks.core` builds the engine.** A scan tag names a trigger, not a
build target, so it would otherwise resolve to `server.Dockerfile` — which that repository
does not have, since it ships `engine`, `reporting`, `restore-historical` and
`message-source-id`. The engine is the representative image there: the other components
build from the same shared libraries, so scanning it covers them. Every other repository
has a single `server.Dockerfile` and is unaffected, as is any explicit `build_target`.

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

## API scanning (authenticated ZAP)

The baseline above is unauthenticated on purpose. **API scanning** is the authenticated
counterpart: it boots the built image against an ephemeral postgres and redis, runs the
repository's own migrate-and-seed, acquires an auth token, and runs `zap-api-scan.py`
against the application's **own OpenAPI spec** — the same four outcomes and the same tally
parse as the baseline, driven a different way. It is
[`dast-api/action.yml`](../.github/actions/dast-api/action.yml) +
[`scan.sh`](../.github/actions/dast-api/scan.sh), run by the `api-scan` job.

**Opt-in, five repositories today.** It runs when the triggering tag ref starts with
`apiscan` and the repository is `novatalks.core`, `nova.chatsconnector.telegram-client-api`,
`…whatsapp-client-api`, `…signal-client-api` or `novatalks.dialer` — never on any other
repository and never automatically on a trunk build. The authenticated run against a seeded stack is a
hundreds-of-operations scan, not something every build should pay for. Every per-repository
value (port, health path, spec path, auth mode, header, scheme prefix, token query, setup
command, swagger toggle) is resolved by the same
[`dast/targets.sh`](../.github/actions/dast/targets.sh) table the baseline above uses —
`dast_resolve_target <repo> api` — one arm per repository, read by the `Resolve api-scan
target` step in
[`ci-build-ntk-on-push-tags-build.yaml`](../.github/workflows/ci-build-ntk-on-push-tags-build.yaml);
the default arm fails loudly rather than guessing.

```bash
git tag apiscan-NC2-1234
git push origin apiscan-NC2-1234   # builds the image, then the authenticated API scan
```

### Four ways to acquire the token

The token that authenticates the scan is obtained by one of four `auth-mode`s, and the
header it is injected under is a per-repository input — a connector's is not the engine's:

- **`login` (`novatalks.core`).** `scan.sh` POSTs the generated admin's username/password
  to `/auth/sign_in`, reads the JWT out of the response, and injects it as
  `Authorization: Bearer <token>`.
- **`db-token` (`nova.chatsconnector.telegram-client-api`).** There is no login endpoint:
  `db:setup` migrates and seeds the database, and the seeded super-admin token is read
  straight out of it with a caller-supplied `SELECT` (`tokens.api_token` joined to the
  `SUPER_ADMIN` role). It is injected **raw — no scheme prefix** — under the connector's
  own `api_access_token` header. The `targets.sh` arm's boot dummies also carry
  `WEBHOOK_URL`: a run against tag `2025_R4_master_9a879f10` loud-skipped with
  `Config validation error: "WEBHOOK_URL" is required`, from a `Joi` schema in
  `src/app.module.ts`'s `ConfigModule.forRoot` at that exact commit — three commits
  behind current `master`, which dropped the requirement in "feat(remove unused env
  webhook_url)". Kept as a dummy anyway, since an unused var costs nothing and an older
  GHCR tag could still be the one a future scan is pointed at.
- **`db-insert` (`nova.chatsconnector.whatsapp-client-api` and `…signal-client-api`).**
  Both connectors share the same `tokens`/`token_roles` schema (`token.model.ts`,
  `token-role.model.ts`, `tableName: 'tokens'`/`'token_roles'`, `schema: 'public'`) and the
  same `api_access_token` header (`roles.guard.ts`), verified independently in each
  repository rather than assumed from the other. Both Dockerfiles run
  `npm prune --omit=dev` in the runtime stage, which removes `ts-node`, but their
  entrypoints still migrate and seed themselves — `node dist/scripts/run-seed.js up`, a
  compiled seeder, not one driven by `ts-node` — so a `super_admin`-role token does exist
  in the database by the time the health probe passes. `db-insert` is used anyway: `scan.sh`
  generates its own token (`nova-ci-apiscan-$(openssl rand -hex 24)`) and writes it in with
  a caller-supplied `INSERT` (the `token-insert-sql` input, `%TOKEN%` substituted in before
  it runs, `role_id` filled from a `SELECT id FROM token_roles WHERE role = 'super_admin'`
  subquery — lowercase, per `token-role.enum.ts`, unlike the telegram connector's
  uppercase `SUPER_ADMIN`), rather than depending on the seeder's own `findOrCreate` key
  staying exactly as it is today. A failed `INSERT` is a loud skip, not a scanner error —
  it means the migration never created the table, a broken setup rather than a finding.
  The value is generated for this run only and lives in a database that dies with the
  container: nothing is stored, nothing to rotate.
- **`env-token` (`novatalks.dialer`).** No seed at all, but not "no database" either:
  `novatalks.dialer`'s `src/auth/auth.middleware.ts` always queries
  `prismaService.accessTokens.findFirst` first, for every request carrying the header —
  that query just finds nothing, because nothing was ever seeded into it. The request is
  still authenticated because the header value is also checked against
  `app.apiAccessTokens`, which `src/config/app.config.ts` builds by splitting the
  `API_ACCESS_TOKENS` environment variable; either the DB row or the env-list match is
  enough, and only the *outbound call to the engine* (`fetchTokenInfo`) is skipped when
  one of them hits — the DB lookup itself is never skipped. That is why this arm still
  needs `needs-db: true` despite seeding no token anywhere. Every other mode acquires its
  token *after* the application container boots;
  this is the one mode that cannot, because the application only ever reads the variable
  once, at its own startup. So `scan.sh` generates the token and masks it before the
  container exists at all — right beside `ADMIN_PASS` — and the container-start step
  appends it with `-e <token-env-var>=<token>`. The same value is then injected into ZAP
  exactly as every other mode's token is. A missing `token-env-var` is a scanner error, not
  a scan without auth: there is no variable name to generate a value for.

  This arm's boot dummies carry two fixes found by reading the code rather than by a live
  failure. `HEALTH_ENABLED=true`: `src/app.module.ts` only pushes `HealthModule` onto its
  `imports` array inside `if (process.env.HEALTH_ENABLED === 'true')` — a raw
  `process.env` check made before Nest ever builds a `ConfigService` — so without it
  `/readyz` (this arm's health path) 404s for the container's whole life, reported as "the
  image did not come up" rather than the missing route it is. `AWS_S3_ACCESS_KEY_ID`,
  `AWS_S3_SECRET_ACCESS_KEY`, `AWS_S3_BUCKET`, `AWS_S3_REGION` and `AWS_S3_ENDPOINT`: the
  same `multer-s3` "`bucket is required`" failure documented above for the old, removed
  baseline arm also applies here, undocumented until now — `ContactModule` and
  `DncListModule`, both unconditional imports, each register
  `MulterModule.registerAsync({ useClass: MulterConfigService })`, and
  `MulterConfigService.createMulterOptions()` builds the S3 storage at module-init time,
  unconditionally, because `FILE_DRIVER` defaults to `s3` and none of the five
  `file.awsS3*` keys has a fallback.

> [!CAUTION]
> **The Postgres image must be one whose entrypoint actually starts Postgres.** It was
> `ghcr.io/cloudnative-pg/postgresql` for weeks. That is the CloudNativePG *operator*
> image: `Entrypoint: null`, `Cmd: ["bash"]`. Under `docker run -d` it started bash, bash
> exited immediately, and `POSTGRES_PASSWORD` / `_USER` / `_DB` were read by nobody
> because there is no `docker-entrypoint.sh` in it. A container ID still came back, so
> `|| not_run "postgres did not start"` never fired; `pg_isready` then failed for sixty
> seconds while the wait loop fell through **in silence**; and the application finally
> died with `ECONNREFUSED`, reported as *"the image did not come up"* — blaming the image
> for a database that was never there.
>
> Every database-backed DAST scan was a loud skip from then until 2026-09-03:
> `novatalks.core` and `nova.botflow` for the baseline, every repository for the API
> scan. Only `novatalks.ui`, which sets `needs-db: false`, was ever really scanned.
>
> Two guards now hold it shut, and both are mutation-tested: the harness asserts the
> `postgres:N` Docker Official family, and the readiness loop prints
> `docker logs nova-pg` and loud-skips with `postgres never became ready` instead of
> carrying on.

> [!IMPORTANT]
> **The image sets itself up; `scan.sh` does not.** `setup-command` defaults to empty
> because both images wired up so far run their migrate-and-seed from their own
> `ENTRYPOINT` before they serve anything — so the health poll *is* the completion
> signal, and a second run over `docker exec` is redundant. For `novatalks.core` it is
> impossible: the runtime stage of `docker/engine.Dockerfile` installs `nodejs-24` and
> **not** npm, and its `entrypoint.sh` does the same three steps with plain `node`,
> saying so in a comment. `npm run db:setup:prod` there could only ever answer
> `sh: npm: not found` — and did.
>
> The container also gets **`DATABASE_URL`**, not just the discrete `DATABASE_*`
> variables. Prisma reads that and nothing else; without it the telegram connector's
> entrypoint died on `P1012 Environment variable not found: DATABASE_URL`. Both
> conventions are built from the values handed to the postgres container moments
> earlier, so they cannot point at a different database — the same rule
> [`dast/scan.sh`](../.github/actions/dast/scan.sh) follows.

> [!NOTE]
> **A loud skip has to say which thing broke, and show it.** `docker exec` against a
> container that never started fails on its own, so an image that did not boot used to
> report `database setup failed` — one message for two very different causes. A
> `docker inspect -f '{{.State.Running}}'` check ahead of the setup step separates them,
> and the setup command's output is captured and printed on failure rather than sent to
> `/dev/null`. The generated admin password is masked at generation for this reason: the
> failure paths print container logs, and this repository is public.

> [!WARNING]
> **The `-z` replacer values are single-quoted in `scan.sh`, and that is load-bearing.**
> `zap-api-scan.py` puts the whole `-z` string through Python's `shlex.split()` before
> passing it to ZAP. Unquoted, `replacement=Bearer <token>` splits in two: ZAP sets the
> header to a bare `Bearer` and drops the token as a stray positional, so the scan runs
> **unauthenticated and reports a normal-looking result** — the exact failure mode this
> page opens with. `db-token` connectors never saw it because their prefix is empty. The
> harness reproduces ZAP's own `shlex.split`; grepping the raw string passes either way,
> which is how it survived review.

The injected header, the scheme prefix and the token `SELECT`/`INSERT` are all
per-repository **inputs**, not constants. All four modes end with a bare token that
`scan.sh` masks with `::add-mask::` before first use, and `login`/`db-token` both treat an
**empty token** — a login that returned none, or a `SELECT` that matched no row — as a
loud skip (`not-run`), never a scan without auth. `db-insert` and `env-token` cannot
produce an empty token (both are generated locally, never read back), so their own failure
modes are a missing prerequisite instead: `db-insert`'s is a failed `INSERT` (`not-run` —
the migration never created the table to insert into, or the `role_id` subquery matched no
row; **psql's own output is captured and printed** rather than discarded, because a loud
skip that guesses at one cause out of several is a dead end, and the generated token is
`::add-mask::`ed **before** it is interpolated into the statement, since that failure path
prints text psql quotes the statement back into), `env-token`'s is a missing
`token-env-var` name (a **scanner error**, since there is nothing to generate a token
for — a broken configuration, not a scan that ran without one).

> [!IMPORTANT]
> **Each connector's auth model is read from its own code before its arm is written (D7).**
> Telegram's shape — a `db-token` read from a `tokens` table and injected under
> `api_access_token` — was **not** assumed for the Sequelize connectors (`whatsapp`,
> `signal`) or `novatalks.dialer`. Each had its token storage, header name and seed path
> verified against its own code before its arm was added — including `signal`, which was
> expected to match `whatsapp` and was checked anyway: same `roles.guard.ts`, same
> `token.model.ts`/`token-role.model.ts` shape, but no health controller at all (`/` is
> its health path, not `/health`) and a `Joi` env-validation schema `whatsapp` has no
> equivalent of. Copying telegram's shape, or one connector's shape onto the other, is
> exactly the mistake this rule exists to prevent.

- **Authenticated, with no stored credential.** In `login` mode the admin password is
  `openssl rand`-generated in `scan.sh` for this run only and used once; in `db-token` mode
  the seeded token never leaves the ephemeral database until the `SELECT` reads it; in
  `db-insert` mode the token is generated the same way the admin password is and written
  into a database that dies with the container; in `env-token` mode the token is generated
  the same way and handed to the application container as an environment variable, never
  written anywhere else — in every mode, nothing is ever stored, nothing to rotate.
  Either way the token reaches ZAP only as a request-header replacer rule on the
  `docker run` command line — and ZAP echoes that rule, token included, back on its own
  stdout. Since
  this repository is public, that stdout is a GitHub-persisted, world-readable step log the
  instant it is written, which is why `scan.sh` masks the token with `::add-mask::` the
  moment it is acquired and deletes the local console file on exit — belt and suspenders,
  not the only guard.
- **Safe mode by default (`-S`), active as a deliberate exception.** `zap-api-scan.py`
  runs passive by default — it observes requests and responses, it does not write. The
  `scan-mode` input (`passive`, the default, or `active`) reaches `scan.sh` as
  `DAST_API_SCAN_MODE`; `active` drops `-S`, and the same tool then sends real
  `POST`/`PUT`/`DELETE` and injection payloads against the seeded API using the very
  session this script just created. That is safe only because the stack is ephemeral —
  this action starts and kills it — so `active` is never the default and an unrecognised
  mode is a scanner error, not a silent fallback to either one. The harness asserts both
  directions: `-S` present when unset, absent under `active`.
- **Spec-driven (`-f openapi`).** The scan walks the real routes the application publishes
  at its spec path (`/api-docs-json`), not a spider — a backend API has no pages to spider.
  Serving that spec can be conditional: the engine needs `SWAGGER_ENABLE=true` (its
  `swagger-enable` input), while the telegram connector serves it unconditionally and sets
  the input `false`. Either way, if the spec comes back empty the scan is a **loud skip**
  (`not-run`), never a green tick over zero operations.

> [!IMPORTANT]
> **Authenticated is not the same as thorough.** This is a passive scan across real,
> logged-in endpoints: it checks transport and header hygiene on routes the baseline can
> never reach without a session. It does **not** try `{accountId}` values it was not
> given, so it does not find IDOR; it does not test whether a low-privilege token can
> reach an admin route, so it does not find privilege escalation; and it does not model
> what any endpoint is *for*, so it does not find business-logic flaws. It is not a
> penetration test. A green line means the authenticated surface's hygiene looks right,
> nothing more.

The report is the same shape as the baseline's and lands on the same release, and it uses
its own triage register — [`zap-api-scan.conf`](../.github/actions/dast-api/zap-api-scan.conf),
not the baseline's `zap-baseline.conf`, because the two load different rule sets and are
never interchangeable.

## Live baseline (the real deployment)

The container DAST above boots the built image in isolation, so it sees the application's
own responses but nothing in front of them. **The live baseline** scans the deployed host
through Cloudflare — the surface the container scan structurally cannot see. It is the
[`ci-dast-live-baseline.yaml`](../.github/workflows/ci-dast-live-baseline.yaml) workflow,
run by hand:

```text
Actions → DAST Live Baseline → Run workflow → target: <allowlisted URL>
```

What it catches that the container scan cannot is **edge configuration**: on the live
host, nginx serves the SPA with none of the security headers the app sets on its own
routes, so `/` comes back with no CSP and no HSTS while the engine's own routes carry
them. That gap only exists once nginx/ingress is in front of the app, which is exactly
what the container scan lacks.

- **The target is allowlisted.** The `target` input is validated against a one-host
  allowlist before anything is scanned; anything else fails loudly. A free-text URL field
  with no allowlist is how a scanner eventually points somewhere it must not, so adding a
  host is a deliberate edit to that `case`, not a runtime choice.
- **SPA-200 caveat.** The host returns HTTP 200 for **every** path — it is an SPA with
  client-side routing, so nginx never 404s and the ZAP spider walks invented routes as
  though they were real pages. The same header finding then repeats once per invented
  path. A larger finding count is duplication, **not broader coverage**: read the report
  for *which* headers or cookies are missing, not for how many times each was flagged.

- **The notification carries the report's own download URL.** There is no release to
  attach to — there is no build — so the report exists only as a run artifact. The
  notification therefore links the artifact directly (`📥 Report:`) as well as the run
  (`📄 Run:`), so reading the alert and reading the report are one click apart rather
  than three. The scan step emits a verdict line and nothing else: `artifact-url` is an
  output of the upload step, so it cannot exist before the upload, and a separate
  `Compose notification` step assembles the links afterwards. If the scan died before
  writing a report there is no artifact and no `📥` line — offering a download for a file
  that does not exist is worse than offering none.

The drift-dangerous part — the tally-line parse — is sourced from
[`dast-common.sh`](../.github/actions/dast/dast-common.sh), never re-implemented inline,
so this out-of-band workflow cannot silently disagree with the two in-pipeline scanners
about what a completed scan looks like.

## Pentest (active scan)

Every scan on this page so far — the baseline, the authenticated `api-scan`, the live
baseline — is passive: it observes and comments on responses, never sends a payload
meant to break something. **The pentest workflow** is the one exception, and it exists
as its own file for that reason: [`ci-dast-pentest.yaml`](../.github/workflows/ci-dast-pentest.yaml)
drives the same two composite actions (`dast`, `dast-api`) with `scan-mode: full` /
`scan-mode: active`, which drops the safe-mode guard and sends real injection,
traversal, command-execution and `POST`/`PUT`/`DELETE` payloads against whatever it is
pointed at.

```text
Actions → DAST Pentest (active scan) → Run workflow → repository, surface, image_tag
```

- **Manual only.** `workflow_dispatch`, no `schedule:`. An attacking scan is a decision
  somebody makes, with an actor and a timestamp against the run — never something a
  branch push or a cron tick triggers on its own.
- **No free-text URL input, anywhere.** `repository` is a `type: choice` dropdown and
  the port, health path, spec path and auth wiring are all derived from it through the
  same [`dast_resolve_target`](../.github/actions/dast/targets.sh) table the trunk
  build uses — an attacking scanner that cannot be pointed anywhere cannot be pointed
  somewhere it must not go, which is a stronger guarantee than any regex on a string
  input would be. `target: live` does add a real host to the picture, but it is picked
  from a one-host allowlist inside the workflow file, never typed — see
  [Live target](#live-target-real-writes-against-a-real-host) below. `image_tag` is
  **required for `target: ephemeral`** and names the exact published tag to scan, never
  a host — there is no "leave blank for the most recent" lookup, and it is unused (and
  may be left blank) for `target: live`, which has no image at all. That was tried and
  reverted: this
  repository's own `GITHUB_TOKEN` cannot read a package published by a *different*
  repository, and the registry's own tag list is not date-ordered, so a "most recent"
  heuristic built on it could silently pick an arbitrary old image and report the scan
  as current — the exact "a scan that could not run looks exactly like a clean one"
  failure this page's [scanner-that-could-not-run](#a-scanner-that-could-not-run-is-not-a-clean-scan)
  rule exists to refuse. Naming the tag by hand is the fix.
- **Two repositories are absent from the `repository` dropdown, deliberately.**
  `novatalks.ui`'s ephemeral image is a static SPA with no backend of its own: every
  route returns the byte-identical nginx shell regardless of surface or payload
  (confirmed live against the published image — POST to its login path returns 405,
  and every route shares one ETag), so an active scan of it finds nothing a scan of one
  page would not. Its passive baseline (`dast-scan`) still covers it; only the pentest
  excludes it. `novatalks.geoip-api` has no authentication and publishes no OpenAPI
  spec, and `api-scan` is spec-driven with no spider fallback, so it has no
  `targets.sh` arm at all — see [the exclusion below](#novatalksgeoip-api-gets-no-dast-at-all)
  and `CLAUDE.md`. Offering a choice that always fails loudly at `Resolve target` is
  worse than not offering it; both repositories' `targets.sh` arms (where they exist)
  are untouched, so nothing here changes what the trunk build itself scans.
- **Ephemeral by default, live behind a typed confirmation.** The `target` input
  defaults to `ephemeral`: a GHCR image this workflow boots on the runner and tears
  down — the same isolated stack the trunk `dast-scan` / `api-scan` jobs use, just with
  the safe-mode guard removed. Setting `target: live` instead points the same active
  scan at a real, running host. See [Live target](#live-target-real-writes-against-a-real-host)
  below — it is not a smaller version of the same decision, it is a different one.
- **What "active" means.** For `target: ephemeral`, `surface: browser` runs
  `zap-full-scan.py` with the modern spider and the active rule set (`dast/action.yml`'s
  `scan-mode: full`), and `surface: api` runs `zap-api-scan.py` with `-S` dropped
  (`dast-api/action.yml`'s `scan-mode: active`). Both run only against the ephemeral
  container this workflow itself starts and kills — see
  [`scan-mode`: baseline or full](#scan-mode-baseline-or-full) and
  [Four ways to acquire the token](#four-ways-to-acquire-the-token) for what each mode
  changes. **`target: live` is browser-surface only** and rejects `surface: api`
  outright; see [Live target](#live-target-real-writes-against-a-real-host).
- **What it still cannot find.** An active ZAP scan has no model of what an endpoint is
  *for*. It finds routes that mishandle a malformed or hostile input — the same class of
  bug the passive scan's header/cookie checks miss — but it does not find **IDOR**, does
  not find **privilege escalation**, and does not find any other **business-logic
  flaw**, because none of those are visible from the outside without knowing what the
  correct behaviour was supposed to be. This is not a penetration test; it is a passive
  scanner's active sibling, still bounded by the same "no model of intent" limit called
  out for `api-scan` above.
- **The report and notification follow the live-baseline pattern**, not the trunk
  build's: there is no release to attach to (no build ran), so the `.report` is a run
  artifact only (`if-no-files-found: warn`), and the notification is composed after the
  upload so it can carry the artifact's own download link, not just the run's.

### Live target: real writes against a real host

Setting `target: live` points the same active scan at a real, running host instead of
an ephemeral container. **Say this plainly: an active scan performs real writes and
deletions** — entities get created, settings get changed, data can be broken. It is
not a hypothetical side effect; it is what an active ZAP scan does by design. The whole
reason this mode is acceptable at all is that the allowlisted host is a dedicated
security-testing instance, never production. Adding a second host to that allowlist is
a separate decision made by editing the `case` in `ci-dast-pentest.yaml`, never a
runtime choice.

- **The allowlist is the whole safety mechanism.** One host —
  `novatalks-security.cloud.novatalks.com.ua` — named in a `case` inside
  `ci-dast-pentest.yaml` and nowhere else, keyed off `repository` (`novatalks.core`
  today). The same shape as `ci-dast-live-baseline.yaml`'s allowlist, and the same
  reason: a scanner that can be pointed anywhere eventually is.
- **Typing the host name back is the confirmation.** The `confirm` input must equal the
  allowlisted host exactly, checked before anything is scanned. This cannot be done by
  accident, and it cannot be done without reading which host is about to be attacked —
  a checkbox or a `type: boolean` would fail both tests.
- **`surface: api` is rejected, not relabelled.** The live path runs `zap-full-scan.py`
  straight at the host: there is no image to boot, so no seeded database to read a token
  out of and no `spec-path` to drive `zap-api-scan.py` from. Before this was refused,
  `surface: api` ran the same anonymous browser crawl against the host root while the
  report banner, the job summary (`- Surface: \`api\``) and the notification all said
  `api` — the operator asked for the authenticated OpenAPI attack, got a crawl, and a
  clean crawl reported `🟢 clean`. A mislabelled artifact is worse than a missing one, so
  the `Validate live target` step fails the dispatch with a message naming the reason.
  Use `target: ephemeral` for the authenticated API attack. `scripts/validate.sh` asserts
  the rejection is still there.
- **`image_tag` is unused.** There is no image to boot for a live scan; the host is
  already running. Leaving `image_tag` blank is correct for `target: live` — it stays
  optional at the input level, and the `Resolve target` step (which only runs for
  `target: ephemeral`) is what enforces it there instead.
- **The scan runs `zap-full-scan.py` directly**, the one place in this workflow — or in
  any workflow in this repository other than `ci-dast-live-baseline.yaml` — that
  invokes ZAP without going through `.github/actions/dast` or `.github/actions/dast-api`.
  Neither composite action applies: there is no image to boot, no database to bring up,
  no token to seed. `scripts/validate.sh`'s guard against invoking ZAP directly carries
  a second named exemption for exactly this file's live path, next to the existing one
  for `ci-dast-live-baseline.yaml`. The tally-line parse still comes from
  [`dast-common.sh`](../.github/actions/dast/dast-common.sh)'s `zap_tally_parse`, never
  re-implemented, and the exit ladder is the same `0|1|2` accepted / anything else an
  error.
- **Unmistakable three months later.** The report's first line, the job summary
  banner, and the notification all open with
  `⚠️ LIVE TARGET <host> — this scan performed real writes. Dispatched by <actor>.` A
  report that could be mistaken for an ephemeral run is the exact failure this
  requirement exists to prevent — nothing about a clean-looking ZAP report otherwise
  says whether it came from a throwaway container or a scan that just mutated real
  data.

## Live proof (2026-09-04)

The exit criterion for this workflow was never "the code exists" — it was every wired
repository producing a real verdict with a non-zero count, dispatched through
`ci-dast-pentest.yaml` itself with `target: ephemeral`
(`docs/superpowers/plans/2026-09-03-dast-completion.md`, Task 10). All six repository/
surface pairs that have a `targets.sh` arm now have one:

| Repository | Surface | Auth mode | Verdict | Run |
| --- | --- | --- | --- | --- |
| `novatalks.core` | api | `login` | `operations: 359, must-fix: 0, warnings: 6, info: 0, accepted: 0, passed: 113` | [33869023913](https://github.com/novaitdevteam/nova.ci/actions/runs/33869023913) |
| `nova.chatsconnector.telegram-client-api` | api | `db-token` | `operations: 35, must-fix: 0, warnings: 5, info: 0, accepted: 0, passed: 113` | [33873549140](https://github.com/novaitdevteam/nova.ci/actions/runs/33873549140) |
| `nova.chatsconnector.whatsapp-client-api` | api | `db-insert` | `operations: 44, must-fix: 0, warnings: 7, info: 0, accepted: 0, passed: 112` | [33873563894](https://github.com/novaitdevteam/nova.ci/actions/runs/33873563894) |
| `nova.chatsconnector.signal-client-api` | api | `db-insert` | `operations: 26, must-fix: 0, warnings: 5, info: 0, accepted: 0, passed: 114` | [33875964532](https://github.com/novaitdevteam/nova.ci/actions/runs/33875964532) |
| `novatalks.dialer` | api | `env-token` | `operations: 19, must-fix: 0, warnings: 5, info: 0, accepted: 0, passed: 114` | [33876797012](https://github.com/novaitdevteam/nova.ci/actions/runs/33876797012) |
| `nova.botflow` | browser | none | `must-fix: 0, warnings: 12, info: 0, accepted: 0, passed: 129` | [33876812531](https://github.com/novaitdevteam/nova.ci/actions/runs/33876812531) |

All six runs are dated 2026-09-04. This table is what the quarterly evidence report is
assembled from, and it is also what makes a future regression visible: a repository
that once reported 359 operations reporting `⚠️ not run` next quarter is a break, not a
fluctuation, and this table is what shows it.

> [!IMPORTANT]
> **`must-fix: 0` does not mean nothing was found.** Every repository above carries
> warnings — 5 to 12 of them. It means no finding is marked as blocking, because
> [both triage registers](#recording-a-decision-about-a-finding) — `zap-baseline.conf`,
> `zap-api-scan.conf` and `zap-full-scan.conf` — are still empty of entries, so every
> rule sits at its own default `WARN`. Nobody has yet decided which of these findings
> must be fixed. A reader three months from now must not read a row of zeros as a clean
> bill of health; read it as "found, and not yet triaged."

**What this coverage still does not include:**

- **This is not a penetration test.** An active scanner sends injection, traversal and
  command-execution payloads and observes the responses. It has no model of intent, so
  none of the six runs above find an IDOR, a privilege escalation, a business-logic
  flaw or a chained exploit — the same limit stated for every scan on this page,
  restated once more here because a table of real numbers is exactly the place someone
  is tempted to read more into it than it says.
- **`novatalks.ui` has no pentest coverage.** Its ephemeral image is a static SPA with
  no backend of its own: `POST /auth/sign_in` returns `405` and every route returns a
  byte-identical shell, so there is nothing an active scan can reach that a scan of one
  page would not — see [above](#pentest-active-scan). Its passive baseline still runs
  in the build workflow and still finds real header and cookie issues.
- **`novatalks.geoip-api` has no DAST at all**, by decision — see
  [above](#novatalksgeoip-api-gets-no-dast-at-all). It keeps Trivy, Semgrep and secret
  detection.
- **The operation counts are what the OpenAPI spec declares.** A route absent from the
  spec was not scanned. That cuts both ways: a spec that over-declares would have the
  scanner probe a route that does not exist, and one that under-declares hides a real
  one from every count in this table.

**Reproducing a row:** `Actions → DAST Pentest (active scan) → Run workflow`, with
`repository` and `surface` set and `target` left at its `ephemeral` default. Find a
current `image_tag` on the repository's own GHCR package page
(`ghcr.io/novaitdevteam/<repository>`) or from a recent build notification — there is no
"most recent" lookup built into the workflow, [by design](#pentest-active-scan).

Getting to six clean dispatches took three loud skips first, and each one named its own
cause rather than reporting a plausible result over zero operations — the exact failure
[this page is built to refuse](#a-scanner-that-could-not-run-is-not-a-clean-scan):
`novatalks.core`'s api arm was missing five `AWS_S3_*` boot dummies (fixed, and told in
full, [above](#per-repository-extra-env-overrides)); ZAP itself then failed outright
with `Failed to start ZAP :(` under a uid that had no write access to `/home/zap`
(run 33867417238, fixed in `dast/scan.sh`); and `novatalks.dialer`'s NATS consumer
needed a `deliver_subject` that only surfaced once the JetStream stream lookup had
already succeeded (fixed, and told in full, under [`needs-nats`](#needs-nats-for-novatalksdialers-api-scan)
above). A scanner that had reported any of those three as clean would have produced six
green rows with zero operations behind them — which is the failure this whole page
exists to refuse, not an aspiration.

## Where the reports are

All three scanners publish onto the **one release the build already creates**, because
`softprops/action-gh-release@v2` upserts by tag and each job can attach its own file
independently. Trivy and the two ZAP scans only run where that release exists; Semgrep
runs on every build and attaches its report only there, keeping the run artifact as the
copy elsewhere (see [above](#where-a-feature-builds-sast-report-goes)):

```text
https://github.com/<owner>/<repo>/releases/download/TRIVY.SCAN_<release>_<ref><suffix>_<sha>/<file>
```

| Scanner | File |
| --- | --- |
| Trivy | `trivy-<repo>-<ref><suffix>-<sha>.report` |
| Semgrep | `semgrep-<repo>-<ref><suffix>-<sha>.report` |
| ZAP baseline | `zap-<repo>-<ref><suffix>-<sha>.report` |
| ZAP API scan (`apiscan*`, `novatalks.core`, telegram, whatsapp, signal or dialer) | `zap-api-<repo>-<ref>-<sha>.report` |

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
| `🔍 SAST (Semgrep): 🟢 clean` | scan ran, no `ERROR` or `WARNING` findings |
| `🔍 SAST (Semgrep): 🟡 3 error · 12 warning` | findings — `ERROR` and `WARNING`, always both counts |
| `🔍 SAST (Semgrep): ❌ scan failed — <reason>` | broken scanner |
| `🔍 SAST (Semgrep): ⏭️ skipped (no build to scan)` | the job never ran — a `pull_request` event, or `build-image` failed |
| `🕷 DAST (ZAP): 🟢 clean · <n> info · <n> accepted` | app booted, no must-fix or warning findings |
| `🕷 DAST (ZAP): 🟡 <n> warnings` | `WARN`-level findings, no `FAIL`-level ones |
| `🕷 DAST (ZAP): 🔴 <n> must-fix · <n> warnings` | at least one `FAIL`-level finding — the register marks it blocking |
| `🕷 DAST (ZAP): ⚠️ not run — <reason>` | the app never came up |
| `🕷 DAST (ZAP): ❌ scanner failed — <reason>` | broken scanner |
| `🕷 DAST (ZAP): ⏭️ skipped (not a DAST trigger or repository)` | not a trunk build or `scan*` tag, or not a DAST repository |
| `🕷 DAST (ZAP API): 🟢 clean · <n> operations · <n> info · <n> accepted` | authenticated API scan ran, no must-fix or warning findings |
| `🕷 DAST (ZAP API): 🟡 <n> warnings` / `🔴 <n> must-fix · <n> warnings` / `⚠️ not run — <reason>` / `❌ scanner failed — <reason>` | the same four states as the baseline, worded by `dast-api/scan.sh` |
| `🕷 API Scan (ZAP): ⏭️ skipped (not an apiscan trigger or repository)` | not an `apiscan*` tag on a covered repo (`novatalks.core`, telegram, whatsapp, signal, dialer) |

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
| DAST-API action | [`.github/actions/dast-api/action.yml`](../.github/actions/dast-api/action.yml) + [`scan.sh`](../.github/actions/dast-api/scan.sh) |
| Shared tally parse | [`.github/actions/dast/dast-common.sh`](../.github/actions/dast/dast-common.sh) — sourced by all three ZAP callers |
| Jobs | `sast-scan`, `dast-scan` and `api-scan` in [`ci-build-ntk-on-push-tags-build.yaml`](../.github/workflows/ci-build-ntk-on-push-tags-build.yaml); the live baseline is its own [`ci-dast-live-baseline.yaml`](../.github/workflows/ci-dast-live-baseline.yaml) |
| Scenario tests | [`scripts/test-sast-scan.sh`](../scripts/test-sast-scan.sh), [`scripts/test-dast-scan.sh`](../scripts/test-dast-scan.sh), [`scripts/test-dast-api-scan.sh`](../scripts/test-dast-api-scan.sh) |

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
