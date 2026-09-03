# Parameterised connector API scanning — pilot telegram — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `dast-api` scan a connector by turning the two things that differ from the engine — how the auth token is acquired and how it is injected — into inputs, and prove it on `nova.chatsconnector.telegram-client-api`.

**Architecture:** `dast-api/scan.sh` gains an `auth-mode` switch: `login` (today's engine path, unchanged) or `db-token` (migrate + seed, then read the seeded admin token out of the database with a caller-supplied `SELECT`). Both converge on one token string, masked with `::add-mask::` and injected via a ZAP replacer whose header name and scheme prefix are now inputs. Per-repo env (the engine's `DEFAULT_*`/`SWAGGER_ENABLE`, telegram's `TELEGRAM_API_*`/`DATABASE_URL`) travels as a multiline `extra-env` input, the same shape the baseline uses. The `api-scan` job gate widens from one repo to a two-repo allowlist, each repo's parameters resolved in a `Resolve api-scan target` step.

**Tech Stack:** Bash, GitHub Actions composite actions, OWASP ZAP (`zap-api-scan.py`), Docker, `psql`, `curl`, NestJS connector image (Prisma).

**Spec:** [`docs/superpowers/specs/2026-09-02-dast-api-connectors.md`](../specs/2026-09-02-dast-api-connectors.md)

## Global Constraints

- `-S` (safe mode) stays mandatory on `zap-api-scan.py`; the harness asserts it. Active scanning is out of scope.
- Every precondition is a **loud skip** (`not_run`: green build, explicit `⚠️ not run — <reason>`): postgres/redis down, migrate/seed non-zero, boot timeout, **empty token** (login returned none, or the `SELECT` matched no row), empty `/api-docs-json`. A precondition failure must never report `clean`.
- The acquired token is masked with `::add-mask::` before first use, whatever its source. Never `echo` it; the migrate/seed step's stdout is discarded so the seeder's own print of the token stays out of the log.
- **Behaviour-preserving for `novatalks.core`:** it stays on `auth-mode=login` and its existing scenarios must stay green. The parameterisation defaults to the engine's values so core's arm changes only by passing them explicitly.
- The ZAP tally parse stays sourced from `dast-common.sh`; never re-inline the anchor.
- Each connector's auth model is verified against its own code before its arm is written — telegram's shape is not assumed for the others (Phase 2).
- The image is built fresh per `apiscan-*` tag; no pulling a "latest" image.
- Changing `scan.sh` means changing `scripts/test-dast-api-scan.sh` in the same commit.
- Every commit ends with `Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>`.
- Run `./scripts/validate.sh` after each task; it must end `VALIDATION OK`. Baseline: DAST 112, DAST-API 21, SAST 31, create-runner 23, secret-echo 23.

---

### Task 1: Parameterise `dast-api` for both auth modes

**Files:**
- Modify: `.github/actions/dast-api/action.yml`
- Modify: `.github/actions/dast-api/scan.sh`
- Test: `scripts/test-dast-api-scan.sh`

**Interfaces:**
- Consumes: nothing new.
- Produces: `dast-api` action inputs `port` (default `3000`), `health-path` (default `/livez`), `spec-path` (default `/api-docs-json`), `auth-mode` (`login`|`db-token`, default `login`), `login-path` (default `/auth/sign_in`), `auth-header` (default `Authorization`), `auth-scheme-prefix` (default `Bearer ` — note trailing space), `token-sql` (default empty), `setup-command` (default `npm run db:setup:prod`), `extra-env` (multiline, default empty). Behaviour with all defaults is byte-identical to today's core scan.

- [ ] **Step 1: Add the inputs to `action.yml`**

In `.github/actions/dast-api/action.yml`, add the inputs above to the `inputs:` block, each with the default named in the Interfaces section, and pass each into the step's `env:` as a `DAST_*` variable (`DAST_PORT`, `DAST_HEALTH_PATH`, `DAST_SPEC_PATH`, `DAST_AUTH_MODE`, `DAST_LOGIN_PATH`, `DAST_AUTH_HEADER`, `DAST_AUTH_PREFIX`, `DAST_TOKEN_SQL`, `DAST_SETUP_CMD`, `DAST_EXTRA_ENV`). Match the existing style (the action already maps `image`→`DAST_IMAGE` etc.).

- [ ] **Step 2: Write the failing harness scenarios for the new surface**

In `scripts/test-dast-api-scan.sh`, before the final tally line, add scenarios. The docker/curl/psql stubs already exist for the `login` path; extend the stub to answer a `psql` token query and record the ZAP replacer header. Add:

```bash
# db-token mode: migrate+seed run, the SELECT returns a token, it is injected under the
# configured header (not Authorization), and the scan runs safe-mode.
expect "db-token mode: seed, read token, scan clean" clean 0
assert_zap_flag "the configured auth header is injected" 'replacer.full_list(0).matchstr=api_access_token'
assert_zap_flag "no Bearer prefix when the scheme prefix is empty" 'replacement=nova-ci-fake-token'
assert_mask_emitted "the db-token value is masked" 'nova-ci-fake-token'

# empty token from the SELECT is a loud skip, never a scan without auth
expect "db-token mode: empty SELECT is a loud skip" not-run 0

# login mode still works unchanged (core), with the default Authorization/Bearer header
expect "login mode still injects Authorization: Bearer" findings 0
assert_zap_flag "login mode keeps the Bearer prefix" 'replacement=Bearer '
```

`assert_mask_emitted` greps the script's stdout for `::add-mask::<value>`; add it next to the existing asserts. The `psql` stub returns `${SHIM_TOKEN_SQL_RESULT}` (a fake token, or empty for the loud-skip scenario).

- [ ] **Step 3: Run the harness to confirm it fails**

Run: `./scripts/test-dast-api-scan.sh`
Expected: FAIL — `scan.sh` does not branch on `auth-mode` yet and hardcodes `Authorization`/`Bearer` and the login flow.

- [ ] **Step 4: Parameterise the hardcoded paths and env in `scan.sh`**

In `.github/actions/dast-api/scan.sh`, replace the hardcoded literals with the env inputs (falling back to the same defaults so core is unchanged):
- `DAST_PORT=3000` → `DAST_PORT="${DAST_PORT:-3000}"`.
- `health_url="${target}/livez"` → `health_url="${target}${DAST_HEALTH_PATH:-/livez}"`.
- `spec_url="${target}/api-docs-json"` → `spec_url="${target}${DAST_SPEC_PATH:-/api-docs-json}"`.
- The `docker exec nova-app sh -c 'npm run db:setup:prod'` → `... "${DAST_SETUP_CMD:-npm run db:setup:prod}"`.
- After the existing engine `-e` env block, apply the caller's `extra-env`: for each non-empty line of `$DAST_EXTRA_ENV`, add `-e "$line"` to the app `docker run`. Follow the baseline `dast/scan.sh` extra-env handling exactly (skip blank lines; do not word-split values). The engine-specific `-e SWAGGER_ENABLE`/`DEFAULT_ADMIN_USER`/`DEFAULT_USER_PASSWORD` stay, but only take effect for core because telegram's arm does not depend on them; a later step makes SWAGGER conditional (Step 6).

- [ ] **Step 5: Branch the token acquisition on `auth-mode`**

Replace the unconditional login block with a branch:

```bash
case "${DAST_AUTH_MODE:-login}" in
  login)
    # unchanged: POST the login route, read the token from the response header
    login_headers="$(curl -s -D - -o /dev/null -X POST "${target}${DAST_LOGIN_PATH:-/auth/sign_in}" \
        -H 'Content-Type: application/json' -H 'User-Agent: nova-ci-apiscan' \
        -d "{\"username\":\"${ADMIN_USER}\",\"password\":\"${ADMIN_PASS}\"}" 2>/dev/null || true)"
    TOKEN="$(printf '%s' "$login_headers" | tr -d '\r' | sed -n 's/^[Aa]uthorization: //p' | head -1)"
    TOKEN="${TOKEN#Bearer }"   # store the bare token; the prefix is re-applied at injection
    ;;
  db-token)
    [ -n "${DAST_TOKEN_SQL:-}" ] || scanner_error "db-token mode needs a token-sql query"
    TOKEN="$(docker exec -e PGPASSWORD="${DATABASE_PASSWORD:-password}" nova-pg \
        psql -tAq -h 127.0.0.1 -U "${DATABASE_USERNAME:-postgres}" -d "${DATABASE_NAME:-db_name}" \
        -c "$DAST_TOKEN_SQL" 2>/dev/null | head -1 | tr -d '[:space:]' || true)"
    ;;
  *) scanner_error "unknown auth-mode: ${DAST_AUTH_MODE}" ;;
esac

[ -n "$TOKEN" ] || not_run "no auth token (login returned none, or the token query matched no row)"
echo "::add-mask::${TOKEN}"
```

Note `TOKEN` replaces the old `JWT` variable name throughout; both the login and db-token paths end with a bare token in `$TOKEN`, masked once here.

- [ ] **Step 6: Make `SWAGGER_ENABLE` conditional and parameterise the replacer injection**

The engine needs `SWAGGER_ENABLE=true`; telegram serves Swagger unconditionally and has no such var (harmless if set, but keep the env honest). Gate it: only add `-e SWAGGER_ENABLE=true -e NODE_ENV=production` when `auth-mode=login` (the engine path), or better, drive it from an input — simplest correct form: add `-e SWAGGER_ENABLE=true` only if `DAST_SWAGGER_ENABLE` is `true` (default `true` for backward-compatible core). Add a `swagger-enable` input (default `true`) mapped to `DAST_SWAGGER_ENABLE`; telegram's arm sets it `false`.

Then parameterise the ZAP replacer so the header and prefix are inputs:

```bash
-config replacer.full_list(0).matchstr=${DAST_AUTH_HEADER:-Authorization} \
-config replacer.full_list(0).replacement=${DAST_AUTH_PREFIX:-Bearer }${TOKEN} \
```

For core, `DAST_AUTH_HEADER=Authorization` and `DAST_AUTH_PREFIX=Bearer ` reproduce today's exact string. For telegram, `api_access_token` and an empty prefix inject the raw token.

- [ ] **Step 7: Run the harness to green**

Run: `./scripts/test-dast-api-scan.sh`
Expected: PASS. Report the count; the pre-existing 21 core scenarios must all still pass (behaviour-preserving), plus the new ones.

- [ ] **Step 8: Prove the new guards bite**

Three mutations, each restored after:
- Remove `echo "::add-mask::${TOKEN}"` → the `assert_mask_emitted` scenario fails.
- Hardcode the replacer header back to `Authorization` → the `api_access_token` scenario fails.
- Make the empty-`SELECT` path fall through instead of `not_run` → the empty-token loud-skip scenario fails.

- [ ] **Step 9: Validate and commit**

Run: `./scripts/validate.sh` → `VALIDATION OK`.

```bash
git add .github/actions/dast-api/action.yml .github/actions/dast-api/scan.sh scripts/test-dast-api-scan.sh
git commit -m "$(cat <<'EOF'
Parameterise dast-api: auth-mode, injected header, per-repo env

The engine's api-scan hardcoded its auth — POST /auth/sign_in, JWT under
Authorization: Bearer. A connector's is a DB-backed token in a header of
its own name. So the two things that differ are now inputs: auth-mode
(login | db-token), the injected header and scheme prefix, and the token
SELECT. Per-repo env (the engine's DEFAULT_*/SWAGGER_ENABLE, a connector's
own vars) travels as a multiline extra-env, the baseline's shape.

db-token seeds the DB and reads the seeded admin token straight out of it
with a caller-supplied SELECT — robust and generalising, unlike parsing
the seeder's console output. An empty result is a loud skip, never a scan
without auth. The token is masked whatever its source, and the seed step's
stdout is discarded so the seeder's own print of it stays out of the log.

Behaviour-preserving for novatalks.core: every default reproduces the
engine's exact values, so its scenarios stay green.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 2: Wire the two-repo gate and the `Resolve api-scan target` step

**Files:**
- Modify: `.github/workflows/ci-build-ntk-on-push-tags-build.yaml`

**Interfaces:**
- Consumes: the parameterised `dast-api` from Task 1.
- Produces: `api-scan` runs for `novatalks.core` (login) and `nova.chatsconnector.telegram-client-api` (db-token) on an `apiscan*` tag.

- [ ] **Step 1: Widen the job gate**

Change the `api-scan` `if:` repository clause from
`github.event.repository.name == 'novatalks.core'` to
`contains(fromJSON('["novatalks.core","nova.chatsconnector.telegram-client-api"]'), github.event.repository.name)`.
Leave the rest of the gate (`apiscan*` tag, non-PR, `build-image` success) unchanged.

- [ ] **Step 2: Add a `Resolve api-scan target` step**

Before the `dast-api` action call, add a `Resolve api-scan target` step (id `apiscan_target`), a `case "$REPO_NAME"` mirroring `Resolve DAST target`, emitting `port`, `health_path`, `spec_path`, `auth_mode`, `login_path`, `auth_header`, `auth_scheme_prefix`, `token_sql`, `setup_command`, `swagger_enable`, `extra_env` to `$GITHUB_OUTPUT`. Two arms plus a loud default:

```bash
case "$REPO_NAME" in
  novatalks.core)
    port=3000; health_path=/livez; spec_path=/api-docs-json
    auth_mode=login; login_path=/auth/sign_in
    auth_header=Authorization; auth_scheme_prefix='Bearer '
    token_sql=''; setup_command='npm run db:setup:prod'; swagger_enable=true
    extra_env=''
    ;;
  nova.chatsconnector.telegram-client-api)
    # Verified in the connector's code: api_access_token header (setup-swagger.ts),
    # DB-backed token in tokens.api_token joined to token_roles.role (schema.prisma),
    # seeded by `npm run db:seed`, Swagger served unconditionally, no health route so "/".
    port=3000; health_path=/; spec_path=/api-docs-json
    auth_mode=db-token; login_path=''
    auth_header=api_access_token; auth_scheme_prefix=''
    token_sql="SELECT t.api_token FROM tokens t JOIN token_roles r ON t.role_id = r.id WHERE r.role = 'SUPER_ADMIN' ORDER BY t.id LIMIT 1;"
    setup_command='npm run db:setup'; swagger_enable=false  # db:setup = migrate + prisma db seed (the repo's canonical combined script)
    # Boot dummies the connector's config validator rejects a blank for — the same
    # values the removed baseline arm used; DATABASE_URL for Prisma is built by scan.sh.
    extra_env='TELEGRAM_API_ID=12345
TELEGRAM_API_HASH=00000000000000000000000000000000
NOVATALKS_ACCESS_TOKEN=dast-dummy-dummy-token
ENCRYPTION_SECRET=dast-dummy-dummy-dummy-dummy-dummy'
    ;;
  *)
    echo "::error::No api-scan configuration for '$REPO_NAME'."; exit 1 ;;
esac
```

Write each to `$GITHUB_OUTPUT` (multiline `extra_env` via a heredoc delimiter, like the other resolve steps). Confirm the telegram dummies' entropy does not trip `secret-scan` — reuse the all-zeros / repeated-token forms already proven safe in the baseline (`00000…`, `dast-dummy-dummy-…`), not realistic-looking values.

- [ ] **Step 3: Pass the resolved values into the `dast-api` call**

Add `with:` inputs to the `dast-api` step: `port`, `health-path`, `spec-path`, `auth-mode`, `login-path`, `auth-header`, `auth-scheme-prefix`, `token-sql`, `setup-command`, `swagger-enable`, `extra-env`, each from `steps.apiscan_target.outputs.*`. Keep `image`/`report-file`/`report-url` as they are.

- [ ] **Step 4: Confirm the connector needs a `medium`/DB-capable runner and the tag routes**

`nova.chatsconnector.telegram-client-api` is not `novatalks.core`, so `ci-build-create-runner.sh` sizes it `small`. The api-scan stack is postgres + redis + app + ZAP — the same load core gets `medium` for. Decide: does telegram's api-scan fit `small`? The connectors' baseline DAST ran on `small` with postgres+redis (per the removed arms), so `small` held redis+pg+app+ZAP for a connector before. Keep `small` unless the pilot run shows memory pressure; note this in the report rather than pre-emptively enlarging. Also confirm the switcher already routes `apiscan*` for any repo in the standard build list (it was widened in the core work — verify telegram reaches the build workflow on an `apiscan*` tag).

- [ ] **Step 5: Validate and commit**

Run: `./scripts/validate.sh` → `VALIDATION OK`; `actionlint` clean on the workflow.

```bash
git add .github/workflows/ci-build-ntk-on-push-tags-build.yaml
git commit -m "$(cat <<'EOF'
Add telegram to api-scan with the db-token auth mode

The api-scan gate widens to novatalks.core (login) and the telegram
connector (db-token). A Resolve api-scan target step carries each repo's
parameters — port, health/spec path, auth mode, injected header, the token
SELECT, setup command, swagger flag, boot env — one arm per repo, a loud
default. Telegram's values are transcribed from its own code: the
api_access_token header, the tokens/token_roles SELECT, db:migrate+db:seed,
Swagger unconditional, "/" health, and the boot dummies the removed
baseline arm used.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 3: Documentation, invariants and mirrors

**Files:**
- Modify: `docs/sast-dast.md`, `CLAUDE.md`, `.agents/skills/nova-ci/SKILL.md`, `.claude/skills/nova-ci/SKILL.md`

- [ ] **Step 1: Document the two auth modes in `docs/sast-dast.md`**

In the API-scanning section, add: api-scan now covers `novatalks.core` (login) and the telegram connector (db-token), on the `apiscan*` tag. Explain the two modes — login POST vs seed-then-read-from-DB — and that the injected header/prefix are per-repo (engine `Authorization: Bearer`, telegram `api_access_token`). State the per-connector-verification rule (D7): each connector's auth is read from its own code, telegram's shape is not assumed. Note Phase 2 (whatsapp, signal, dialer) is tracked.

- [ ] **Step 2: Add/adjust invariants in `CLAUDE.md`**

- api-scan is parameterised: `auth-mode` `login`|`db-token`, injected header/prefix and the token `SELECT` are inputs; the token is masked whatever its source; an empty token is a loud skip. `-S` stays mandatory.
- Each connector's auth model is verified against its own code before its arm is written; telegram's `db-token`/`api_access_token`/`tokens` shape is not assumed for the Sequelize connectors or dialer.
- Update the harness count for `test-dast-api-scan.sh` to the number Task 1 produced.

- [ ] **Step 3: Mirror both SKILL.md**

Apply the same to `.agents/skills/nova-ci/SKILL.md` and `cp` to `.claude/skills/nova-ci/SKILL.md`.

- [ ] **Step 4: Validate and commit**

Run: `./scripts/validate.sh` → `VALIDATION OK`, mirror check included.

```bash
git add docs/sast-dast.md CLAUDE.md .agents/skills/nova-ci/SKILL.md .claude/skills/nova-ci/SKILL.md
git commit -m "$(cat <<'EOF'
Document the two api-scan auth modes and the telegram pilot

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Verification before the pull request

- [ ] `./scripts/validate.sh` ends `VALIDATION OK`
- [ ] The core (`login`) scenarios are all still green — the parameterisation did not regress the engine path
- [ ] The new `db-token` scenarios bite under mutation (mask, header, empty-token loud skip)
- [ ] No credential or token value appears in any committed file; the telegram boot dummies use the low-entropy forms proven not to trip `secret-scan`
- [ ] Every commit carries the `Co-Authored-By` trailer
- [ ] **Live pilot:** an `apiscan-<date>` tag on `nova.chatsconnector.telegram-client-api`'s development HEAD builds its image, brings up postgres+redis, migrates+seeds, the `SELECT` returns a token, `/api-docs-json` loads, and `zap-api-scan.py -S` reports a tally. This confirms A1 (spec JSON path) and A2 (seed→token). **A concrete A2 risk to expect:** `prisma db seed` runs `ts-node prisma/seed.ts`, and a production image may ship neither `ts-node` nor devDependencies — if so the seed step exits non-zero and the scan is a loud skip naming "database setup failed", which is the fail-closed design telling us the image cannot self-seed. If that happens, the pilot's finding is that connectors need a seed path that works in the runtime image (e.g. a compiled seeder, or seeding via `psql` directly) — resolve it before Phase 2, do not force it. The guards fail closed either way, but the first real run is where the pilot is proven — do not claim it works without it.
- [ ] Phase 2 (whatsapp, signal, dialer) opened as a follow-up plan only after the telegram run is green
