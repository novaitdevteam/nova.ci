---
paths:
  - ".github/workflows/ci-build-ntk-on-push-tags-build.yaml"
  - ".github/workflows/ci-build-ntk-on-push-tags-run-test.yaml"
  - ".github/actions/{dast,dast-api,dast-target}/**"
  - "docs/testing/tests.md"
  - "docs/security/sast-dast.md"
---

# novatalks.core-only exceptions

Loaded when Claude Code reads a matching file; Codex and humans read it from the table in [`CLAUDE.md`](../../CLAUDE.md). Breaking one of these is a regression even when the workflow still parses.

**Repository-scoped exceptions** — all gated on `github.event.repository.name == 'novatalks.core'`, none of them apply to other repositories without an explicit request:

- `postgres:17.9-trixie` as the Postgres image — for the integration suite **and** for the DAST/api-scan stacks, which resolve it from the same `novatalks.core` split (everything else takes `postgres:16`). **The image must be one whose entrypoint actually starts Postgres.** It was `ghcr.io/cloudnative-pg/postgresql` for weeks: that is the CloudNativePG *operator* image, `Entrypoint: null`, `Cmd: ["bash"]`, so `docker run -d` started bash, bash exited, and `POSTGRES_PASSWORD`/`_USER`/`_DB` were read by nobody — while `docker run -d` still returned a container ID, so `|| not_run "postgres did not start"` never fired. Every database-backed DAST scan was a loud skip from then on. `scripts/test-dast-scan.sh` now asserts the `postgres:N` family.
- **The postgres readiness loop must fail loudly when it gives up.** Its silent fall-through is what hid the above: `pg_isready` failed for sixty seconds, the script carried on, and the application died with `ECONNREFUSED` — reported as *"the image did not come up"*, blaming the image for a database that was never there. On exhaustion it now prints `docker logs nova-pg` and loud-skips with `postgres never became ready`.
- The S3 (Cloudflare R2) file-storage step (`FILE_DRIVER=s3` + `AWS_S3_*`), with `R2_*` secrets routed through step `env:`, never inline `${{ secrets }}` in `run`.
