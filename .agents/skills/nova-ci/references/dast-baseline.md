# DAST baseline (ZAP, `dast-scan`) — depth

Referenced from `SKILL.md`'s "SAST and DAST Semantics" section. Read that section first.
This file covers the unauthenticated ZAP baseline/full scan run by the `dast` composite
action from the build workflow (`dast-scan` job). See `references/dast-api-scan.md` for the
authenticated `api-scan`, and `references/dast-live-and-pentest.md` for the two
`workflow_dispatch`-only callers.

## The four outcomes

**A scanner that could not run is not a clean scan.** This is the spine of both the SAST and
DAST actions. Semgrep exits 0 with an empty result set when no rules load, and a ZAP baseline
against an app that crashed on boot produces the same empty report as a healthy one — so each
scanner has to *prove* it ran.

**DAST has four outcomes and they must stay distinct**: `clean`, `findings`, `not-run`,
`error`. `not-run` means the application never booted — `.env.example` drift, a missing
migration, a changed port; none of them security events, and the image is already in GHCR. It
is a **loud skip**: green build, `=== DAST: not run ===` in the report, a `WARNING` summary
banner, and `⚠️ not run — <reason>` in the notification. Never silence it and never red it.
ZAP itself failing (a non-zero exit that is not "warnings present", or no report file) is
`error` and reds the job.

## Gates

**DAST gate:** `always() && github.event_name != 'pull_request' &&
needs.build-image.result == 'success'`, **plus**
`(needs.build-image.outputs.IS_TRUNK == 'true' || startsWith(github.ref_name, 'scan'))` and
the three-repository list — it boots the built image next to its database, which is the cost
that keeps it narrow. `build-image` resolves `IS_TRUNK` once as a job output because a
job-level `if` cannot reach a step in another job. `trivy-scan` deliberately keeps its own
`Resolve scan policy` step — two sources of truth for one predicate, accepted, and not to be
"simplified" without reading spec D6.

**The four scanners fan out from `build-image` in parallel** (`trivy-scan`, `sast-scan`,
`dast-scan`, `api-scan` → `notify`), each on `needs: [build-image]` and nothing else: they all
need `RELEASE`/`SHORT_REF_NAME`/`SHORT_SHA` from it and none needs another. They were chained
until the numbers were taken: run 33614788933 did 1083s of work in 2103s, 1017s of it gaps
between jobs, 397s waiting on `dast-scan` alone. A chain does not avoid the queue, it
guarantees one. The `medium` pool went to 4 in the same change. Concurrent release publishing
is safe — `action-gh-release` retries a `422 already_exists` and updates the winner's
release. Each job carries `if: always() && …` so one failure swallows neither another scan
nor the notifier.

**Three reports, one release.** Each job upserts its own `.report` onto the existing
`TRIVY.SCAN_<release>_<ref><suffix>_<sha>` prerelease (`softprops/action-gh-release@v2`
appends by tag; job needs `contents: write`), plus a run-scoped artifact and a job summary.
The `TRIVY.SCAN_` prefix is **historical** and stays — renaming breaks the stable URLs
documented in `docs/container-scanning.md`, and one release per scanner triples the walk for
the quarterly evidence aggregation.

**Pin both images by tag and digest**, never `latest`, for the reason the Gitleaks pin
exists. Upgrade with `docker buildx imagetools inspect`.

## Where the ZAP counts come from

**Take the ZAP counts from the single tally line**, never from the `-w` report or from a
per-rule `WARN-NEW:`/`FAIL-NEW:` line. `-w` writes the markdown "ZAP Scanning Report" and
carries no count at all. One line, printed unconditionally at the end of any completed scan,
carries all six: `FAIL-NEW: 0	FAIL-INPROG: 0	WARN-NEW: 11 WARN-INPROG: 0	INFO: 4	IGNORE: 7
PASS: 30`. Anchor on `^FAIL-NEW: <digits>` + a **literal tab byte** + `FAIL-INPROG: ` — the
tally's *shape*, not the bare `FAIL-NEW: ` prefix, which a per-rule FAIL-level line also
starts with and would be matched instead, misreporting a real finding as a broken scanner.
**Keep the pattern ANSI-C quoted (`$'…\t…'`), never a plain `'…\t…'` string:** BSD grep
expands `\t` inside a pattern, GNU grep does not — it warns `stray \ before t` and matches a
literal `t`. Every runner is GNU, so the plainly quoted form matches nothing in production,
every completed scan reports a missing tally and reds the build, and a macOS harness run is
the one place it passes. A missing or non-numeric tally is a scanner error, never a clean
scan — the format moving under the pinned digest is not a zero. Keep the `tee` capture and
`${PIPESTATUS[0]}` — ZAP's own exit status, unambiguously; plain `$?` only agrees because
`pipefail` is set and would become `tee`'s status the moment that changed, or whenever `tee`
itself fails — and the console log deleted on exit and never uploaded.

**Keep `0|1|2` in the ZAP exit-code `case`.** Exit 1 is `FAIL`-level findings present and is
a *finding*, not a broken scanner — `-I` gates exit 2 alone and does not suppress 1. Moving 1
into the error arm reds a trunk build the first time the triage register gains a `FAIL`
entry.

## Triage registers and scan modes

**`.github/actions/dast/zap-baseline.conf` (baseline) and `zap-full-scan.conf` (full) are the
triage registers**, never interchangeable — the active scanner loads a rule set the passive
one never reaches, so an `IGNORE` in one is not a decision made for the other. Both:
TAB-separated, at least three fields, levels `PASS`/`IGNORE`/`INFO`/`WARN`/`FAIL`/
`OUTOFSCOPE`. The reason column is a **review-time obligation, not a parsed one** — an empty
third field is accepted, because ZAP accepts it and this validator must never reject a
register ZAP would load; do not add a check that enforces it. Both ship with zero entries;
adding one is a risk-acceptance decision, not a CI change. `scan.sh` validates line shape and
level before anything boots and treats a malformed or missing register as a scanner error,
but **cannot validate rule IDs** — a mistyped one is silently inert.

**`dast/action.yml`'s `scan-mode` input (`baseline` default, `full`)** reaches `scan.sh` as
`DAST_SCAN_MODE` and picks the script, spider flag and triage register together, never one
alone: `zap-baseline.py` / no spider flag / `zap-baseline.conf` under `baseline`;
`zap-full-scan.py` / `-j` / `zap-full-scan.conf` under `full`. `-j` swaps the traditional
spider for the modern one — the only way a single-page app is more than one page to ZAP,
since nginx serves `index.html` for every route and the traditional spider has no JavaScript
to follow. Exit ladder and tally line are identical between the two scripts
(`zap-full-scan.py:480` and `:511-522`), so `dast-common.sh` and the `0|1|2` exit case stay
shared, unchanged, between modes. An unrecognised `scan-mode` is a scanner error, never a
silent fallback to `baseline`.

**`dast/action.yml`'s `zap-context` input** (empty default) reaches `scan.sh` as
`DAST_ZAP_CONTEXT` and, only under `scan-mode: full`, appends `-n <file> -U nova-ci-dast` to
the `zap-full-scan.py` invocation. `-n` and `-U` travel together or neither does — a context
loaded with no user selected scans as nobody while looking configured, same shape as the `-z`
replacer rule in `references/dast-api-scan.md`. A context file
(`.github/actions/dast/contexts/<repo>.context`) must define **both**
`loggedInIndicatorRegex` and `loggedOutIndicatorRegex`; one alone lets ZAP silently crawl
anonymously while reporting a successful authenticated run.
`contexts/novatalks-ui.context` exists with a source/image-verified login request (URL, JSON
field names) but is **not** wired into `targets.sh` — that arm leaves `DT_ZAP_CONTEXT` empty
because `novatalks.ui`'s ephemeral scan boots no backend at all (`POST /auth/sign_in` returns
`405` live; every route returns the same static shell regardless of credentials, since the
SPA's auth state is client-side only, with no HTTP response ZAP can regex-match). A wrong
indicator is worse than none — do not fill one in to "finish" that arm.

## Which repositories, and why

**DAST baseline scope is three browser-surface repositories** — `novatalks.ui` (Vue SPA, port
8000, `/livez`), `novatalks.core` (dashboard, 3000, `/livez`, `needs-db`) and `nova.botflow`
(Node-RED editor, 1880, `/`, `needs-db`) — gated on `github.event.repository.name` like the
`postgres:17.9-trixie` and R2 exceptions. The ZAP baseline is a browser tool: it spiders HTML
and checks header/cookie hygiene, so it only earns its keep where there is a browser surface
to spider. A `Resolve DAST target` step (the same house pattern as `Resolve scan policy` in
`trivy-scan`) resolves port, health path, `needs-db`, `needs-nats` and `extra-env` per
repository by calling `.github/actions/dast-target`, a composite action that sources
`.github/actions/dast/targets.sh`'s `dast_resolve_target` relative to its own
`github.action_path` rather than `GITHUB_WORKSPACE` — see "Things that live once" below for
why that indirection exists, and `.agents/skills/dast-target-wiring/SKILL.md` for how an arm
is built and verified.
`nova.botflow` has no dedicated HTTP health route (its chart probes over `tcpSocket`), so its
health path is `/` — the boot wait-loop accepts any HTTP response, 404 included, since it only
tests that the process is listening; do not "fix" it to `/livez`. It brings up both redis and
postgres since its storage backend is configurable. Adding a fourth needs an explicit
request, a real browser surface, **and a boot probe first**: port and health path verified
against the chart or Dockerfile, never guessed.

**Six headless repositories were removed from the baseline on 2026-09-01**, tracked for the
authenticated api-scan expansion: `nova.chatsconnector.{telegram,whatsapp,signal}-client-api`
(all 3000, `/`, `needs-db`), `novatalks.dialer` (3000, `/livez`, `needs-db`, `needs-nats`),
`novatalks.uspacy.connector` (3000, `/`, `needs-db`) and `novatalks.geoip-api` (3000, `/`, no
db — an inference, not a verified fact). They are JSON APIs with no browser surface, so the
baseline measured almost nothing on them. Their real coverage is the authenticated `api-scan`
(OpenAPI-driven) — see `references/dast-api-scan.md`. The `needs-nats` input exists on both
`dast/action.yml` and `dast-api/action.yml` now; `novatalks.dialer`'s `api` arm sets
`DT_NEEDS_NATS=true` (its `main.ts` awaits `microService.listen()`, a real NATS connection,
before `app.listen()`), and both `scan.sh`s bring one up through the shared
`dast_bring_up_nats` in `dast-common.sh` rather than two copies (see "Things that live once"
below). Connecting is not booting: `novatalks.dialer` then creates its own JetStream push
consumer, and `nats`' own client throws `push consumer requires deliver_subject` when
`NATS_DELIVER_TO` is unset (confirmed live on pentest run 33873579035, after the stream lookup
had already succeeded) — `targets.sh`'s `api` arm now sets it in `DT_EXTRA_ENV`.
`NATS_DELIVER_GROUP`/`NATS_DURABLE` stay unset: both feed no-op calls when absent, yielding a
plain ephemeral consumer rather than a crash. The browser-surface arm this repository used to
have never hit this — `dast/scan.sh` seeds the whole product-repo `.env.example`, which
already carries `NATS_DELIVER_TO`; `dast-api/scan.sh` has no such seeding step, only the
hand-curated `DT_EXTRA_ENV` list.

**`target: live` in `ci-dast-pentest.yaml` is browser-surface only.** The live path runs
`zap-full-scan.py` straight at the allowlisted host — no image to boot, so no seeded database
for a token and no spec for `zap-api-scan.py` — so `surface: api` was an anonymous browser
crawl while the banner, job summary and notification all said `api`. `Validate live target`
now rejects it before anything is scanned, `validate.sh` asserts the rejection, and the live
step's `-j` is unconditional as a result.

## Things that live once, and must not be re-inlined

**Every `DT_*` the table sets must be bridged to a consumer, not just declared.**
`DT_ZAP_CONTEXT` was set by `targets.sh`, declared on `dast/action.yml` and honoured by
`dast/scan.sh`, with no resolve step emitting it — setting it on an arm would have produced an
anonymous crawl with no signal anywhere. `ci-dast-pentest.yaml` now emits `zap_context` and
passes `zap-context:` to the browser scan step, and `scripts/test-dast-targets.sh` asserts
both directions: nothing the table sets goes unemitted, nothing emitted goes unread.

**Neither DAST `scan.sh` infers the scanned repository from the runner's repository.** Both
take a `target-repository` input reaching the script as `DAST_TARGET_REPO`, defaulting to
empty and falling back to `${GITHUB_REPOSITORY##*/}` — identical for the reusable build
workflow, which runs in the product repository's own context, and wrong for
`ci-dast-pentest.yaml`, which runs in `nova.ci`. It decides the Postgres major version (now
logged with the repository it was chosen for and the source of that name, because a silently
wrong `postgres:16` for `novatalks.core` was invisible) and whether `GITHUB_WORKSPACE`'s
`.env.example` belongs to the application being scanned. When it does not, nothing is seeded
from it, a `::warning::` names the checkout that was found, and any subsequent boot-failure
loud skip carries that reason — a warning rather than a hard stop, because `novatalks.ui`
needs no seeding and must still be scannable.

**The tally parse lives once, in `dast/dast-common.sh`.** `zap_tally_parse` (anchor +
numeric guard) is sourced by `dast`, `dast-api` and the live-baseline workflow. Never
re-inline or copy it — the ANSI-C `\t` and the shape-not-prefix anchor are the exact
divergent-copy hazard it exists to remove; a copy that rots reds only on GNU runners.

**The NATS bring-up lives once too, in the same `dast-common.sh`.**
`dast_bring_up_nats <err_fn> <stream-log-file>` starts `nats:2.10-alpine -js -m 8222`, polls
`http://127.0.0.1:8222/healthz`, and creates the `campaign` JetStream stream — mirrors
`~/novatalks/scripts/nats-docker/scripts/js-init.sh` minus its `nsc push` step, which
provisions JWT accounts this unauthenticated server has no use for. Both `dast/scan.sh` and
`dast-api/scan.sh` call it under `needs-nats`/`DAST_NEEDS_NATS` rather than each carrying an
inline copy, following the same house rule as the tally parse above. `<err_fn>` is the
caller's own `not_run`, passed by name exactly like `zap_tally_parse`'s `<error-fn>` — the
shared function calls back into the caller's scope rather than assuming one.

**The per-repository DAST table lives once, in `dast/targets.sh`.** `dast_resolve_target
<repo> <api|browser>` sets `DT_*` in the caller's scope. Never re-inline or copy an arm into a
workflow's own `case` — same divergent-copy hazard as the tally parse above. Every arm sets
every `DT_*` variable, even ones with no consumer yet, so a stale value can never leak from
the previous caller.

**`targets.sh` itself is reached exactly one way: `.github/actions/dast-target`, never a
workflow's own `run:` step.** That composite action sources `targets.sh` relative to its own
`github.action_path` and emits every `DT_*` as a step output; `ci-build-ntk-on-push-tags-build.yaml`'s
`Resolve DAST target` and `Resolve api-scan target` steps and `ci-dast-pentest.yaml`'s
`Resolve target` step all call it with `uses:`. A `run:` step doing
`. "${GITHUB_WORKSPACE}/.github/actions/dast/targets.sh"` looks identical in review — a
`Checkout` step precedes it every time — but `GITHUB_WORKSPACE` in a `workflow_call` reusable
workflow is the *calling* repository's checkout, not nova.ci's, and `targets.sh` has never
lived in `nova.botflow` or `novatalks.core`. That exact step broke `dast-scan` and `api-scan`
outright, for every repository, the moment the table was extracted into its own file
(`nova.botflow` run 33955935398) — two reviews missed it because both asked whether a
`Checkout` step preceded the resolve step, never which repository it checked out.
`ci-dast-pentest.yaml` worked the whole time only because it runs directly in nova.ci
(`workflow_dispatch`, not `workflow_call`), which made `targets.sh` look proven when only that
one caller's `GITHUB_WORKSPACE` ever agreed with it. `uses:` does not have this ambiguity:
GitHub checks out the *whole* calling repository next to the action, so `github.action_path`
always resolves to nova.ci regardless of whose checkout `GITHUB_WORKSPACE` holds — the same
mechanism `gitleaks/action.yml`'s own comment documents for its central config.
`scripts/validate.sh`'s "GITHUB_WORKSPACE self-reference" guard now fails any
`workflow_call`-triggered workflow that sources a nova.ci-only path via `GITHUB_WORKSPACE`, so
this exact regression reds the harness instead of shipping silently.

## `.env.example` and boot environment

**`.env.example` is documentation and must not decide anything the scan depends on.** Four
boot failures traced back to trusting it literally: a trailing `//` comment glued onto
`NODE_ENV`, dotenv-style surrounding quotes that `docker --env-file` does not strip, an
`APP_PORT` disagreeing with the Dockerfile, and a blank `KEY=` seeded as an empty string
where the app had a perfectly good default. `scan.sh` therefore drops comment-bearing and
empty-valued lines, strips one matching quote pair, never seeds `NODE_ENV`, and forces
`PORT`/`APP_PORT` (and `NATS_SERVERS`, and `DATABASE_URL` when `needs-db`) after
`--env-file`. It logs counts and names, never values.

**`dast/action.yml`'s `extra-env` is the per-repository escape hatch** for template values no
filter can fix — newline-separated `KEY=VALUE`, applied as `-e` flags after `--env-file` so
each overrides the seeded value. The input still exists on the action, but no baseline
resolver arm uses it today — the three repos that once did are removed headless repos, kept
here as history of how the mechanism was established (via `.env.example`-shaped boot
failures), not a current baseline arm: `nova.chatsconnector.telegram-client-api` (four blanks
its Joi schema rejects one per CI run), `nova.chatsconnector.signal-client-api` (an
`S3_ENDPOINT` written as `https://<account-id>.…`, plus the blanks behind it), and
`novatalks.dialer` (five `AWS_S3_*` — `multer-s3` throws `bucket is required` at boot and
`FILE_DRIVER=s3` is the only driver it supports). `dast-api/action.yml`'s own `extra-env`
input (separate from this one) has its own arms — see `references/dast-api-scan.md`.

**`novatalks.core`'s `browser` arm needs the same boot dummies as its `api` arm, but only
through a second field, `unseeded-env` (`DT_UNSEEDED_ENV` in `targets.sh`,
`DAST_UNSEEDED_ENV` in `dast/scan.sh`), never through `extra-env`.** Live pentest run
33882314584 loud-skipped the browser scan of `novatalks.core`/ephemeral with "the image did
not come up within 180s — and no .env.example was seeded, because GITHUB_WORKSPACE holds a
checkout of 'nova.ci', not of 'novatalks.core'": `dast/scan.sh` (unlike `dast-api/scan.sh`)
normally seeds the engine from the product repository's own `.env.example`, which already
carries `DEFAULT_ADMIN_USER`/`DEFAULT_USER_PASSWORD` and the real S3 config;
`ci-dast-pentest.yaml` runs in `nova.ci`, so that seeding is correctly skipped, and nothing
filled the gap. `extra-env` was not the fix: `dast/scan.sh` applies it with `-e` *after*
`--env-file`, so on the build workflow's own path — where the real `.env.example` is seeded —
it would override novatalks.core's real S3 config with dummies, contradicting the R2/S3
exception in `CLAUDE.md` and changing a scan that already works (`WARN-NEW: 2, PASS: 65`).
`unseeded-env` is folded into `DAST_EXTRA_ENV` only inside the branch where `scan.sh` has
already determined nothing was seeded (`scanned_repo != workspace_repo`) — a no-op on every
existing caller, live only for the pentest workflow. Both
`ci-build-ntk-on-push-tags-build.yaml`'s `Resolve DAST target` step and
`ci-dast-pentest.yaml`'s `Resolve target` step bridge it from `targets.sh` regardless, per
the "every `DT_*` is bridged" rule above. `scripts/test-dast-scan.sh` mutation-tests the
guard: hoisting the merge out from behind the `scanned_repo != workspace_repo` check makes
the "must not apply when seeded" scenario fail.

## Reach and honesty

Be honest about reach in any documentation: the unauthenticated ZAP baseline finds header and
cookie hygiene, not logic flaws. It is not a penetration test.

## Test coverage

Changing `scan.sh` means adding a scenario to `scripts/test-dast-scan.sh` in the same change.
`validate.sh` also fails if any workflow runs `zap-baseline.py`/`zap-full-scan.py`, or a
third-party action for either. The ZAP half of that guard is narrower than the Semgrep half
on purpose-not-yet-done: it does **not** match a bare `docker run ghcr.io/zaproxy/zaproxy`. Do
not describe it as if it does.
