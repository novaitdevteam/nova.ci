# SAST and DAST (Semgrep and OWASP ZAP)

<p align="center">
  <img src="../assets/readme/sast-dast.svg" width="100%" alt="Semgrep reads our own source and an OWASP ZAP baseline probes the running application, alongside Trivy on the container image; each reports clean, findings or error, with a fourth not-run outcome for DAST alone, and a scanner that could not run is never reported clean; all three reports land on the one release the build already creates and each adds a line to the notification" />
</p>

Two scanners join `trivy-scan` after a build: **Semgrep** reads our own source (SAST)
on every build, on any branch, and an **OWASP ZAP baseline** probes the application
while it runs (DAST) on trunk and `scan*` builds. Both write a `.report` — onto the
release the build already creates, where there is one — and both add a line to the
build notification.

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

### Seeding the app container from `.env.example`

> [!NOTE]
> The seeding mechanics in this block — the `.env.example` strip, the empty-value drop,
> `extra-env`, the `DATABASE_URL` build, the port forcing — all live in `scan.sh` and are
> unchanged. Several examples below (`nova.chatsconnector.signal-client-api`,
> `nova.chatsconnector.telegram-client-api`, `novatalks.dialer`) are headless repositories
> that were **removed from the baseline on 2026-09-01** (see [Which repositories](#which-repositories)),
> so no `Resolve DAST target` arm exercises them today. They are kept here because the
> machinery is exactly what api-scan reuses — `nova.chatsconnector.telegram-client-api` already does, via its
> `extra-env` in the `Resolve api-scan target` arm, and `whatsapp`, `signal` and `dialer`
> are the tracked Phase 2. The examples are how the mechanic was established, not a claim
> that those repos are scanned by the baseline now. `novatalks.core`, which is kept, still exercises the `.env.example` seeding
> and the `DATABASE_URL` build.

Some engines need more than `DATABASE_*`/`REDIS_*` to boot (`novatalks.core`'s S3 file
storage, among others). Rather than hardcode product-specific env vars in `scan.sh` — or
worse, a credential — the action reads the product repository's own `.env.example`, the
same file `ci-build-ntk-on-push-tags-run-test.yaml` already trusts for integration
tests, strips it down, and hands the survivors to `docker run --env-file`.

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

### Recording a decision about a finding

A scanner that can only ever add to its count is one people stop reading. Both scanners
have a way to write down "this is accepted" or "this must be fixed", and both keep that
decision in version control next to a reason.

**ZAP — [`zap-baseline.conf`](../.github/actions/dast/zap-baseline.conf).** Every rule
defaults to `WARN`; an entry overrides that for one rule ID. The grammar is
TAB-separated with at least three fields:

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

The file ships with no entries, so it changes nothing until someone adds a line. Adding
one is a risk-acceptance decision, not a CI change.

The reason is a **review-time obligation, not a parsed one.** `10038<TAB>IGNORE<TAB>` with an
empty third field is accepted by `scan.sh`, because ZAP itself accepts it and this
validator must never reject a register ZAP would load. Nothing mechanical will stop an
unexplained `IGNORE`; the pull request is what stops it.

Rule IDs are not written from memory. Generate the list the pinned image actually loads:

```bash
docker run --rm -v "$PWD:/zap/wrk:rw" ghcr.io/zaproxy/zaproxy:stable \
    zap-baseline.py -t http://example.com -g zap-rules.conf
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

These per-repository values are resolved by a **`Resolve DAST target`** step in
`dast-scan`, following the same house pattern as `Resolve scan policy` in `trivy-scan`
and `Resolve test plan` in the test workflow: a `case "$REPO_NAME"` in bash, one arm per
repository, every value set explicitly (no arm inherits from another), writing `port`,
`health_path`, `needs_db`, `needs_nats` and `extra_env` to `$GITHUB_OUTPUT`. This
replaced a chain of inline ternaries that did not scale past two repositories. The
default arm is not a fallback: a repository that reaches `dast-scan` with no configured
arm is a wiring mistake, and guessing a port would scan nothing and report it clean — so
the default arm emits `::error::` and exits non-zero instead. `pg-image` stays a
two-branch ternary (`postgres:17.9-trixie` for `novatalks.core`, the action's
`postgres:16` default for everyone else) rather than a resolver arm, since it only ever
has two truthy branches.

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
`novatalks.core` (`login`) and `nova.chatsconnector.telegram-client-api` (`db-token`);
extending it to the remaining connectors that publish a spec (`whatsapp`, `signal`,
`dialer`) is the tracked **Phase 2**, each a per-repository integration — seed data, its
own token model, the spec endpoint — verified against that repository's own code, never
assumed from telegram's. `novatalks.uspacy.connector` and `novatalks.geoip-api` publish no
OpenAPI spec, so they have no api-scan path either.

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
which the chart gives `/livez`. `novatalks.geoip-api`'s `needs-db: false` was an inference
(no ORM dependency, a five-variable `.env.example`), not a verified fact like the others;
if the api-scan expansion reaches it and wants a database, flip it to `true`. Several of
these also needed `.env.example` filters and per-repository `extra-env` overrides to boot
at all — those are preserved in the
[`extra-env`](#per-repository-extra-env-overrides) section above and carry over to the
api-scan work unchanged.

### `needs-nats`, for `novatalks.dialer` only

`novatalks.dialer` no longer reaches the baseline, so no arm sets `needs-nats: true`
today — but the input still exists on
[`dast/action.yml`](../.github/actions/dast/action.yml) and the bring-up machinery is
still in `scan.sh`, kept for the api-scan expansion, which will need it: a `novatalks.dialer`
container reaches NestJS startup and then dies with `Error: connect ECONNREFUSED ::1:4222`
without a NATS server, because port 4222 is NATS and nothing else in the action listens
on it.

When `needs-nats` is `true`, `scan.sh` brings up `nats:2.10-alpine` before the
application the same way `needs-db` brings up postgres and redis: no config file,
published on `4222`, started with its monitoring port (`-m 8222`) so a wait-loop shaped
like the `pg_isready` one can poll `http://127.0.0.1:8222/healthz` before the application
ever starts. A NATS that never becomes ready takes the same `not-run` path a database
failure does, naming NATS in the reason. The container is named `nova-nats` and torn
down by `cleanup()` on every exit path, alongside `nova-pg` and `nova-redis`. It is
tag-pinned (`nats:2.10-alpine`), not digest-pinned, matching the existing
`postgres:16`/`redis:8` precedent in this script — digest pinning stays reserved for the
scanners themselves.

The scan runs this NATS completely unconfigured — no auth, no TLS, no JetStream —
because that is all the client side needs: `novatalks.dialer`'s own `.env.example`
already defaults to `NATS_SERVERS=localhost:4222` with `NATS_USER`, `NATS_PASS`,
`NATS_NKEY`, `NATS_JWT` all blank, `NATS_TLS_ENABLED=false` and
`NATS_STREAM_ENABLED=false`. Production NATS (`nats-system/ntk-nats-prod-cluster`) is a
three-node cluster with TLS certificates and NKEY/account authentication — none of that
belongs here, and nobody should "harden" this bring-up to look more like it; a scan needs
a server to connect to, not a faithful copy of the production topology. `scan.sh` also
forces `-e NATS_SERVERS=127.0.0.1:4222` onto the application container after
`--env-file`, for the same reason `PORT`/`APP_PORT` are forced: the observed failure was
`::1:4222`, i.e. the client resolved `localhost` to IPv6, and a server bound to `0.0.0.0`
still refuses that — naming the address explicitly removes the resolution question rather
than hoping it resolves to `127.0.0.1` on its own.

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

**Opt-in, two repositories today.** It runs when the triggering tag ref starts with
`apiscan` and the repository is `novatalks.core` **or**
`nova.chatsconnector.telegram-client-api` — never on any other repository and never
automatically on a trunk build. The authenticated run against a seeded stack is a
hundreds-of-operations scan, not something every build should pay for. Every per-repository
value (port, health path, spec path, auth mode, header, scheme prefix, token query, setup
command, swagger toggle) is resolved in the `Resolve api-scan target` step's `case` in
[`ci-build-ntk-on-push-tags-build.yaml`](../.github/workflows/ci-build-ntk-on-push-tags-build.yaml),
one arm per repository; the default arm fails loudly rather than guessing.

```bash
git tag apiscan-NC2-1234
git push origin apiscan-NC2-1234   # builds the image, then the authenticated API scan
```

### Two ways to acquire the token

The token that authenticates the scan is obtained by one of two `auth-mode`s, and the
header it is injected under is a per-repository input — a connector's is not the engine's:

- **`login` (`novatalks.core`).** `scan.sh` POSTs the generated admin's username/password
  to `/auth/sign_in`, reads the JWT out of the response, and injects it as
  `Authorization: Bearer <token>`.
- **`db-token` (`nova.chatsconnector.telegram-client-api`).** There is no login endpoint:
  `db:setup` migrates and seeds the database, and the seeded super-admin token is read
  straight out of it with a caller-supplied `SELECT` (`tokens.api_token` joined to the
  `SUPER_ADMIN` role). It is injected **raw — no scheme prefix** — under the connector's
  own `api_access_token` header.

The injected header, the scheme prefix and the token `SELECT` are all per-repository
**inputs**, not constants. Both modes end with a bare token that `scan.sh` masks with
`::add-mask::` before first use, and both treat an **empty token** — a login that returned
none, or a `SELECT` that matched no row — as a loud skip (`not-run`), never a scan without
auth.

> [!IMPORTANT]
> **Each connector's auth model is read from its own code before its arm is written (D7).**
> Telegram's shape — a `db-token` read from a `tokens` table and injected under
> `api_access_token` — is **not** assumed for the Sequelize connectors (`whatsapp`,
> `signal`) or `novatalks.dialer`, which are the tracked **Phase 2**. Each of those has its
> token storage, header name and seed path verified against its own code before an arm is
> added. Copying telegram's shape onto them is exactly the mistake this rule exists to
> prevent.

- **Authenticated, with no stored credential.** In `login` mode the admin password is
  `openssl rand`-generated in `scan.sh` for this run only and used once; in `db-token` mode
  the seeded token never leaves the ephemeral database until the `SELECT` reads it. Either
  way the token reaches ZAP only as a request-header replacer rule on the `docker run`
  command line — and ZAP echoes that rule, token included, back on its own stdout. Since
  this repository is public, that stdout is a GitHub-persisted, world-readable step log the
  instant it is written, which is why `scan.sh` masks the token with `::add-mask::` the
  moment it is acquired and deletes the local console file on exit — belt and suspenders,
  not the only guard.
- **Safe mode only (`-S`).** `zap-api-scan.py` runs passive — it observes requests and
  responses, it does not write. Without `-S` the same tool active-scans, sending real
  `POST`/`PUT`/`DELETE` against the seeded API using the very session this script just
  created. `-S` is mandatory and the harness asserts it is passed.
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

The drift-dangerous part — the tally-line parse — is sourced from
[`dast-common.sh`](../.github/actions/dast/dast-common.sh), never re-implemented inline,
so this out-of-band workflow cannot silently disagree with the two in-pipeline scanners
about what a completed scan looks like.

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
| ZAP API scan (`apiscan*`, `novatalks.core` + telegram connector) | `zap-api-<repo>-<ref>-<sha>.report` |

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
| `🕷 API Scan (ZAP): ⏭️ skipped (not an apiscan trigger or repository)` | not an `apiscan*` tag on a covered repo (`novatalks.core`, telegram connector) |

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
