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
validator checking shape, not just presence, accepts them. All of these are dummy
values, not credentials — they exist only so a scanned container reaches its HTTP
listener; if one ever needs to be real, it belongs in a secret, not in this step.

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

`scan.sh` anchors on `^FAIL-NEW: [0-9]+\tFAIL-INPROG: ` and reads all six. The anchor
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
| `IGNORE` | accepted risk — the reason column is not optional |
| `PASS` | treated as passing |

The file ships with no entries, so it changes nothing until someone adds a line. Adding
one is a risk-acceptance decision, not a CI change.

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
does everywhere else. The widget's `sast-scan` mirrors the main workflow's: same trunk
gate (an `IS_TRUNK` output added to `build-widget`'s `prep` step), same SHA-pinned
checkout, same report-file convention, and it upserts its report onto the release
`build-widget` already creates (`NTK.CHATWIDGET_<release>_<ref>_<sha>`) instead of a
second one.

**DAST covers nine repositories**, gated on `github.event.repository.name`, the same
repository-scoped-exception pattern already used for the
[integration Postgres image](tests.md) and R2 file storage:

| repository | port | health path | needs-db | needs-nats | extra-env |
| --- | --- | --- | --- | --- | --- |
| `novatalks.ui` | 8000 | `/livez` | false | false | — |
| `novatalks.core` | 3000 | `/livez` | true | false | — |
| `nova.botflow` | 1880 | `/` | true | false | — |
| `nova.chatsconnector.telegram-client-api` | 3000 | `/` | true | false | `TELEGRAM_API_ID`, `TELEGRAM_API_HASH`, `NOVATALKS_ACCESS_TOKEN`, `ENCRYPTION_SECRET` |
| `nova.chatsconnector.whatsapp-client-api` | 3000 | `/` | true | false | — |
| `nova.chatsconnector.signal-client-api` | 3000 | `/` | true | false | `S3_ENDPOINT`, `S3_ACCESS_KEY_ID`, `S3_SECRET_ACCESS_KEY`, `S3_BUCKET`, `WEBHOOK_SECRET`, `SIGNAL_MAX_FILE_SIZE` |
| `novatalks.dialer` | 3000 | `/livez` | true | true | — |
| `novatalks.uspacy.connector` | 3000 | `/` | true | false | — |
| `novatalks.geoip-api` | 3000 | `/` | false | false | — |

DAST is scoped that narrowly because, unlike the other two, it has to **boot the
thing**. Every repository needs its own answer to: which port does the image listen on,
what path proves it is up, how long does it need, and does it need postgres and redis
first. Those are per-repository inputs on
[`dast/action.yml`](../.github/actions/dast/action.yml), and each one has to be
established against the real runtime image — a wrong path scans an error page and
reports it clean, which is the failure this whole design is built to avoid.

The original two repositories were the two poles of the problem: `novatalks.ui` serves
static assets, `novatalks.core` is a backend that needs postgres, redis and a schema.
The four repositories added after them (`nova.botflow` and the telegram, whatsapp and
signal chatsconnectors) all resemble the `novatalks.core` pole — a backend service —
but none of them exposes a dedicated HTTP health route the way `novatalks.core` does.
Their charts probe them over `tcpSocket` instead, so `/` is the correct health path for
all four: the boot wait-loop accepts any HTTP response, a 404 included, because it is
only testing whether the process is listening, not whether a particular route exists.
Do not "fix" that to `/livez` — there is nothing there to hit. `nova.botflow` needs
redis or postgres depending on its storage configuration; bringing up both is simpler
than modelling the choice, and an unused container costs a few seconds. The signal
connector's own default branch is a feature branch, not `main`/`master`/`development`,
so in practice it only reaches `dast-scan` via an explicit `scan*` tag — it has no trunk
to be auto-scanned from.

The three repositories added after those (`novatalks.dialer`, `novatalks.uspacy.connector`,
`novatalks.geoip-api`) split differently. `novatalks.dialer` is in the deployment chart
(`novatalks.charts`, `novatalks_v5/values.yaml`, `dialer.containerPort: 3000`), whose
deployment probes `/livez` and `/readyz` — the same authoritative source as `novatalks.ui`
and `novatalks.core`. It uses Prisma and redis, so `needs-db` is `true`. The other two are
not in that chart; their port comes from `docker/server.Dockerfile`'s `EXPOSE 3000`
instead, and neither exposes a dedicated health route, so `/` is correct for the same
reason it is for `nova.botflow` and the chatsconnectors. `novatalks.uspacy.connector` uses
Prisma, so it needs the database. `novatalks.geoip-api` has no ORM dependency and only
five variables in its `.env.example`, so it is treated as needing no database, like
`novatalks.ui` — this is the one inference in the set, not a verified fact like the
others; if its first real run wants a database, flip `needs-db` to `true`. Both
`novatalks.dialer` and `novatalks.uspacy.connector` set an `APP_PORT` in their templates
that disagrees with their Dockerfile (3006 and 3001 against `EXPOSE 3000`), but the
action already forces `PORT` and `APP_PORT` to the resolved port for exactly this reason,
so it needs no special-casing in their arms.

### `needs-nats`, for `novatalks.dialer` only

`novatalks.dialer` reaches NestJS startup and then dies with
`Error: connect ECONNREFUSED ::1:4222` — port 4222 is NATS, and nothing in this action
listened on it. `dast/action.yml`'s `needs-nats` input (default `false`) tells `scan.sh`
to bring up `nats:2.10-alpine` before the application the same way `needs-db` brings up
postgres and redis: no config file, published on `4222`, started with its monitoring
port (`-m 8222`) so a wait-loop shaped like the `pg_isready` one can poll
`http://127.0.0.1:8222/healthz` before the application ever starts. A NATS that never
becomes ready takes the same `not-run` path a database failure does, naming NATS in the
reason. The container is named `nova-nats` and torn down by `cleanup()` on every exit
path, alongside `nova-pg` and `nova-redis`. It is tag-pinned (`nats:2.10-alpine`), not
digest-pinned, matching the existing `postgres:16`/`redis:8` precedent in this
script — digest pinning stays reserved for the scanners themselves.

The scan runs this NATS completely unconfigured — no auth, no TLS, no JetStream —
because that is all the client side needs: `novatalks.dialer`'s own `.env.example`
already defaults to `NATS_SERVERS=localhost:4222` with `NATS_USER`, `NATS_PASS`,
`NATS_NKEY`, `NATS_JWT` all blank, `NATS_TLS_ENABLED=false` and
`NATS_STREAM_ENABLED=false`. Production NATS (`nats-system/ntk-nats-prod-cluster`) is a
three-node cluster with TLS certificates and NKEY/account authentication — none of that
belongs here, and nobody should "harden" this bring-up to look more like it; a baseline
scan needs a server to connect to, not a faithful copy of the production topology.
`scan.sh` also forces `-e NATS_SERVERS=127.0.0.1:4222` onto the application container
after `--env-file`, for the same reason `PORT`/`APP_PORT` are forced: the observed
failure was `::1:4222`, i.e. the client resolved `localhost` to IPv6, and a server bound
to `0.0.0.0` still refuses that — naming the address explicitly removes the resolution
question rather than hoping it resolves to `127.0.0.1` on its own.

These per-repository values are resolved by a **`Resolve DAST target`** step in
`dast-scan`, following the same house pattern as `Resolve scan policy` in `trivy-scan`
and `Resolve test plan` in the test workflow: a `case "$REPO_NAME"` in bash, one arm per
repository, every value set explicitly (no arm inherits from another), writing `port`,
`health_path`, `needs_db`, `needs_nats` and `extra_env` to `$GITHUB_OUTPUT`. This replaced a chain of inline
ternaries that did not scale past two repositories. The default arm is not a fallback:
a repository that reaches `dast-scan` with no configured arm is a wiring mistake, and
guessing a port would scan nothing and report it clean — so the default arm emits
`::error::` and exits non-zero instead. `pg-image` stays a two-branch ternary
(`postgres:17.9-trixie` for `novatalks.core`, the action's `postgres:16` default for
everyone else) rather than a resolver arm, since it only ever has two truthy branches.

Once all nine are working, a tenth repository rolls out by copying whichever existing
arm it resembles most, rather than by writing a boot config blind. **Adding one needs an
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
| `🔍 SAST (Semgrep): 🟢 clean` | scan ran, no `ERROR` or `WARNING` findings |
| `🔍 SAST (Semgrep): 🟡 3 error · 12 warning` | findings — `ERROR` and `WARNING`, always both counts |
| `🔍 SAST (Semgrep): ❌ scan failed — <reason>` | broken scanner |
| `🔍 SAST (Semgrep): ⏭️ skipped (no scan trigger)` | not a trunk build or `scan*` tag |
| `🕷 DAST (ZAP): 🟢 clean · <n> info · <n> accepted` | app booted, no must-fix or warning findings |
| `🕷 DAST (ZAP): 🟡 <n> warnings` | `WARN`-level findings, no `FAIL`-level ones |
| `🕷 DAST (ZAP): 🔴 <n> must-fix · <n> warnings` | at least one `FAIL`-level finding — the register marks it blocking |
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
