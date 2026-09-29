---
paths:
  - "docs/**"
  - "README.md"
---

# Documentation style

Loaded when Claude Code reads a docs page; indexed in [`CLAUDE.md`](../../CLAUDE.md).

- Keep file paths in documentation relative to the page (`../../` from a section under `docs/`); `validate.sh` fails on a diagram that does not resolve.
- Docs are grouped by section (`docs/getting-started/`, `pipeline/`, `testing/`, `security/`, `reference/`), and each section keeps its diagrams in its own `assets/` folder (`docs/assets/` holds the shared hero). **Every page under `docs/` opens with one** — a new page needs a new asset, and `validate.sh` fails without it. Use the `beautify-github-readme` skill.
- Static SVG is the default. A GIF only when motion explains something prose cannot; then keep the `.svg` source plus its `*-motion.json` spec next to the `.gif` and regenerate with that skill's `render_motion_gif.py` rather than hand-editing a GIF.
- Match the house style: `1200`-unit `viewBox`, the `ui-monospace,SFMono-Regular,Menlo,monospace` stack, the existing palette (it already carries GitHub's semantic `#3FB950` / `#F85149` / `#E3862B` — do not invent new ones), and a **minimum `font-size` of 18** SVG units.
- **Verify a new asset by rendering it, not by computing text widths.** `rsvg-convert -w 900` is GitHub's content width; also check `-w 360`. Text clipping against a panel edge does not show up in the arithmetic — it cost a rework on `secret-detection.svg`.
