# Trivy Image Scan

The depth behind the nova-ci skill's Trivy pointer. Rules: `.claude/rules/code-scanning.md`.

`ci-build-ntk-on-push-tags-build.yaml` has a `trivy-scan` job that `needs: [build-image]` and scans the exact GHCR image the build produced:

```text
ghcr.io/<owner>/<repo>:<release>_<short-ref-name><image-suffix>_<short-sha>
```

Preserve these behaviors:

- Keep the scan gated on `github.event_name != 'pull_request'` and `needs.build-image.result == 'success'`. PRs stay lint and unit tests only (no scan).
- The `Resolve scan policy` step auto-enables the scan when `SHORT_REF_NAME` is `main`, `master`, or `development`, and enables it on demand when the trigger tag ref starts with `scan` (`[[ "$REF_NAME" == scan* ]]`). Otherwise the image is built but not scanned. Branch/repo/commit come from push metadata, not the tag name.
- The switcher routes `push` tags containing `build` or starting with `scan` to the build workflow, so a `scan*` tag builds and scans a specific branch.
- On `novatalks.core` a `scan*` tag resolves to `build-engine` before the Dockerfile chain runs. A scan tag names a trigger, not a build target, and that repository has no `server.Dockerfile` to fall through to — the engine is its representative image, since the other components build from the same shared libraries. Other repositories and explicit `build_target` values are untouched.
- Scan with `aquasecurity/trivy-action@v0.36.0` (pinned). Run an OS pass (`TRIVY_PKG_TYPES=os`), a library pass (`TRIVY_PKG_TYPES=library`), and a JSON pass for counts; reuse the install with `skip-setup-trivy: true`. The action manages the vulnerability and Java DBs — do not reintroduce a manual `--download-db-only` / `--download-java-db-only` two-step.
- Cache the Trivy DB with `actions/cache` over `${{ github.workspace }}/.cache/trivy` (action cache disabled via `cache: false`); the key embeds a 5-hour bucket (`trivy-db-5h-<floor(epoch/18000)>`).
- Emit a single `.report` file (`trivy-<repo>-<ref><suffix>-<sha>.report`) with `=== OS Vulnerabilities ===` and `=== Node.js Vulnerabilities ===` sections. Upload it as a workflow artifact and attach it to a GitHub prerelease tagged `TRIVY.SCAN_<release>_<ref><suffix>_<sha>` (`softprops/action-gh-release@v2`, job needs `contents: write`). Every step that can create that release passes `target_commitish: ${{ github.sha }}` — whichever job publishes first creates the tag, and without it GitHub tags the default branch instead of the scanned commit (NC2-2932). Put CRITICAL/HIGH counts and the report link in the job summary.
- `trivy_mode` policy: `warn-only` (default) always succeeds and only warns; `fail-on-critical` fails the job when CRITICAL > 0; `fail-on-high` fails when CRITICAL or HIGH > 0. The image is already built/pushed before the scan, so a failing scan signals red but does not unpublish it.
