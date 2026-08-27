# Validation

<p align="center">
  <img src="../assets/readme/validation.svg" width="100%" alt="scripts/validate.sh runs a YAML parse, a whitespace check, the agents-to-claude skill mirror check, the create-runner self-check and advisory actionlint" />
</p>

One harness runs every check:

```bash
./scripts/validate.sh   # or: make validate
```

[`scripts/validate.sh`](../scripts/validate.sh) runs a YAML parser over all `.github/workflows/*.yaml` and `.github/actions/*/action.yml`, `git diff --check` for whitespace, an `.agents` ↔ `.claude` skill mirror sync check, the [`ci-build-create-runner.sh`](../.github/workflows/ci-build-create-runner.sh) self-check, and `actionlint` when available — **advisory** by default, because the repo carries a pre-existing backlog of shellcheck-info and expression findings. Set `STRICT_ACTIONLINT=1` to enforce once that backlog is cleared.

## Runner script self-check

[`scripts/test-create-runner.sh`](../scripts/test-create-runner.sh) runs `ci-build-create-runner.sh` offline against 13 scenarios: a `curl` shim on `PATH` answers the Hetzner and GitHub calls from canned JSON, `sleep` is stubbed out, and each scenario asserts the emitted `$GITHUB_OUTPUT`. It touches no network, no credentials and no Hetzner project, and covers reuse, ghost registrations, both caps, the sizing matrix, and all four create-lock outcomes (free, held, stale, API failure).

Run it alone against any copy of the script:

```bash
./scripts/test-create-runner.sh [path-to-script]
```

[`ci-self-validate.yaml`](../.github/workflows/ci-self-validate.yaml) runs the same harness (with `actionlint` installed) on every pull request and push to `main`.

After changing CI behavior, still verify by hand that these docs, [`CLAUDE.md`](../CLAUDE.md), [`AGENTS.md`](../AGENTS.md) and [`.agents/skills/nova-ci/SKILL.md`](../.agents/skills/nova-ci/SKILL.md) (with its `.claude/` mirror) describe the same routing.

---

[← Notifications](notifications.md) · [Docs index](README.md) · [Reference →](reference.md)
