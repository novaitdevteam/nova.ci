./CLAUDE.md

## nova.ci

This repository is `nova.ci`, the shared GitHub Actions workflow repository for NovaTalks projects. Product repositories keep a thin local caller workflow and call reusable workflows from this repo with `uses: novaitdevteam/nova.ci/.github/workflows/...@main`.

Canonical guidance for both Codex-compatible agents and Claude Code lives in [`CLAUDE.md`](CLAUDE.md) — read it first; it links every documentation page. The invariants live in [`.claude/rules/`](.claude/rules/), one file per area: Claude Code loads them by path, so any other agent must open the one for the area it touches (the table in `CLAUDE.md` names it).

- Human-facing documentation: [`docs/`](docs/README.md)
- Maintenance skill: [`.agents/skills/nova-ci/SKILL.md`](.agents/skills/nova-ci/SKILL.md), mirrored for Claude Code under [`.claude/skills/nova-ci/SKILL.md`](.claude/skills/nova-ci/SKILL.md)
- Validation: `./scripts/validate.sh` after every change
