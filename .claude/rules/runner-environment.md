---
paths:
  - ".github/workflows/*.yaml"
  - ".github/actions/{install-docker,notify}/**"
---

# Runner environment rules

Loaded when Claude Code reads a matching file; Codex and humans read it from the table in [`CLAUDE.md`](../../CLAUDE.md). Breaking one of these is a regression even when the workflow still parses.

**Runner environment**

- Keep Docker setup limited to jobs that need Docker, via [`install-docker/action.yml`](../../.github/actions/install-docker/action.yml).
- Keep notification jobs Docker-free and routed through [`notify/action.yml`](../../.github/actions/notify/action.yml): `actions/github-script@v8` with Node.js `fetch`. A workflow must not call the Telegram or Google Chat API directly — `validate.sh` fails on it.
- Keep mobile APK setup explicit — self-hosted images ship neither `zip`/`unzip` nor the Android build tools.
