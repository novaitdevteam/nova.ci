# NC2-3092 follow-up plan: rag in `api-scan` and in the integration route

Spec: [`../specs/2026-11-03-nc2-3092-rag-dast-and-integration-design.md`](../specs/2026-11-03-nc2-3092-rag-dast-and-integration-design.md). Branch `NC2-3092-rag-dast-int`. One PR.

Each task ends with `./scripts/validate.sh` green unless it says otherwise.

## Task 1: harness scenarios first (red)

In `scripts/test-dast-api-scan.sh`, add scenarios before any change to `scan.sh`. Run the harness and watch the new ones fail.

1. **`jwt-es256` happy path → `clean`.**
   - The token ZAP receives (from the `-z` argv) is three base64url parts.
   - Its header has `alg ES256` and `kid nova-ci-dast`.
   - Its payload carries the `jwt-claims` keys plus the `tid` from `token-sql`, with `exp - iat = 300`.
   - The signature verifies with `openssl` against the public key that went into the app's `-e <token-env-var>=…`.
   - The private key and the token are masked.
2. **`%JWT_PRIVATE_KEY%` in `extra-env`.** The app's `-e` carries a PEM, not the placeholder.
3. **`token-sql` returns nothing → `not-run`.**
4. **`jwt-claims` missing or not JSON → `error`.**
5. **The scan outlives the token → `not-run`, never `clean`.** The shim fakes the clock: a `date` shim returns `iat` first and `iat+301` after ZAP.
6. **`pre-boot-command` fails → `not-run`**, with its output in the log and the app never started.
7. **`pre-boot-command` succeeds** and runs before `docker run --name nova-app`. It sees `DAST_IMAGE` and `DATABASE_NAME`.
8. **`extra-env` `DATABASE_URL=…` wins** over the default (its `-e` comes after the default one).
9. **`PG_IMAGE` override** reaches `docker run --name nova-pg`.

In `scripts/test-dast-targets.sh`, add a rag `api` arm shape check.

## Task 2: `dast-api/scan.sh` (green)

- `PG_IMAGE` stays as it is: already an override.
- Export the resolved `DATABASE_USERNAME`/`PASSWORD`/`NAME`.
- Add `DAST_PRE_BOOT_CMD` after postgres, redis and NATS, before the app.
- Move `extra-env` below the database block.
- Add `jwt-es256`:
  - keys and env before the app;
  - placeholder substitution;
  - `tid` from `token-sql` after boot;
  - sign;
  - TTL guard after ZAP.
- Update the header comment from four modes to five.

## Task 3: plumbing

- **`dast-api/action.yml`:** add the inputs `pg-image`, `pre-boot-command` and `jwt-claims`.
- **`targets.sh`:**
  - every arm sets `DT_PG_IMAGE`, `DT_PRE_BOOT_COMMAND` and `DT_JWT_CLAIMS`;
  - add rag's `api` arm.
- **`dast-target/action.yml`:** emit the three keys.
- **Build workflow:**
  - add rag to the `api-scan` list;
  - pass the three inputs;
  - make rag's `apiscan*` build the API.
- **`ci-dast-pentest.yaml`:** read the three keys.

## Task 4: integration route

- **Switcher:** add rag to the test route.
- **Run-test workflow:**
  - the unit command is repository-aware;
  - rag's stack step (pgvector with shm and db `rag`, `init-db.sql`, MinIO plus bucket, port presets);
  - skip `.env.example` for rag.

## Task 5: docs and rules

- **Docs pages:**
  - `docs/security/sast-dast.md`: api-scan repositories, five auth modes;
  - `docs/testing/tests.md`, `docs/pipeline/routing.md`, quick-start: test tags now route for core and rag;
  - `docs/pipeline/build-pipeline.md`: rag's `apiscan*`.
- **Rules:** `.claude/rules/code-scanning.md`, which lists the api-scan repositories and auth modes, and gains `jwt-es256` plus the TTL guard.
- **Skills:**
  - `nova-ci` `SKILL.md` and its mirror;
  - `references/dast-api-scan.md` and its mirror;
  - `dast-target-wiring` skill: five modes.

## Task 6: review and live

1. Run `/code-review` and `ponytail-review`, and `/security-review` since this touches a scanner and token path.
2. PR, wait for green, merge (nova.ci).
3. Live, in this order:
   - `apiscan-NC2-3092` on rag's `NC2-3092-ci-wiring` branch;
   - then `int-test-NC2-3092`.
4. Read each loud skip and fix forward.
