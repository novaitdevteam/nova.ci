#!/usr/bin/env bash
#
# Self-check for ci-build-create-runner.sh.
#
# The script decides whether CI provisions a Hetzner VM, so its branches must keep
# behaving after edits. This harness runs it offline: a curl shim on PATH answers the
# Hetzner and GitHub calls from canned JSON, and each scenario asserts the resulting
# $GITHUB_OUTPUT. No network, no credentials, no Hetzner project touched.
#
# Usage: ./scripts/test-create-runner.sh [path-to-script]
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${1:-$ROOT/.github/workflows/ci-build-create-runner.sh}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

mkdir -p "$WORK/bin"

# curl shim: dispatch on the URL, honour -o/-w the way hcloud_api uses them.
cat > "$WORK/bin/curl" <<'SHIM'
#!/usr/bin/env bash
url="" out="" method=GET
args=("$@")
for a in "${args[@]}"; do case "$a" in https://*) url="$a" ;; esac; done
while [ $# -gt 0 ]; do
    case "$1" in
        -o) out="$2"; shift ;;
        -X) method="$2"; shift ;;
    esac
    shift
done
emit() { if [ -n "$out" ]; then printf '%s' "$1" >"$out"; else printf '%s' "$1"; fi; }
case "$url" in
    *api.hetzner.cloud/v1/servers*)          emit "$SHIM_SERVERS" ;;
    *api.github.com/orgs/*)                  emit "$SHIM_RUNNERS" ;;
    *api.hetzner.cloud/v1/placement_groups*)
        case "$method" in
            GET)    emit "${SHIM_PG_GET:-{\"placement_groups\":[]\}}"; printf '%s' "${SHIM_PG_GET_CODE:-200}" ;;
            POST)   emit "${SHIM_PG_POST:-{\}}";                       printf '%s' "${SHIM_PG_POST_CODE:-201}" ;;
            *)      emit '{}';                                         printf '%s' 204 ;;
        esac
        ;;
    *) echo "curl shim: unexpected URL $url" >&2; exit 99 ;;
esac
SHIM
printf '#!/usr/bin/env bash\nexit 0\n' > "$WORK/bin/sleep"   # skip the anti-race jitter
chmod +x "$WORK/bin/curl" "$WORK/bin/sleep"

servers() { # servers <name:type:status>...
    local out="[]" entry name type status
    for entry in "$@"; do
        IFS=: read -r name type status <<<"$entry"
        out=$(jq -c --arg n "$name" --arg t "$type" --arg s "$status" \
            '. + [{name: $n, server_type: {name: $t}, status: $s}]' <<<"$out")
    done
    jq -c '{servers: ., meta: {pagination: {next_page: null}}}' <<<"$out"
}

runners() { # runners <name:status:busy:size>...
    local out="[]" entry name status busy size
    for entry in "$@"; do
        IFS=: read -r name status busy size <<<"$entry"
        out=$(jq -c --arg n "$name" --arg st "$status" --argjson b "$busy" --arg sz "$size" \
            '. + [{name: $n, status: $st, busy: $b, labels: [{name: "self-hosted"}, {name: $sz}]}]' <<<"$out")
    done
    jq -c '{runners: .}' <<<"$out"
}

pass=0 failed=0

check() { # check <name> <ref> <repo> <expected-output-lines> [base-ref] [event-path-override]
    local name="$1" ref="$2" repo="$3" expected="$4" base_ref="${5:-}" event_override="${6:-}"
    local out summary actual event
    out="$WORK/output" summary="$WORK/summary" event="$WORK/event.json"
    : >"$out"; : >"$summary"
    if [ -n "$event_override" ]; then
        # A scenario that needs a missing or malformed event file supplies its own
        # path instead of a base-ref for the helper to encode.
        event="$event_override"
    elif [ -n "$base_ref" ]; then
        jq -nc --arg b "$base_ref" '{base_ref: $b}' > "$event"
    else
        echo '{}' > "$event"
    fi

    if ! PATH="$WORK/bin:$PATH" \
        GITHUB_REPOSITORY="novaitdevteam/$repo" GITHUB_REF="$ref" \
        GITHUB_EVENT_PATH="$event" \
        ORG=novaitdevteam GH_TOKEN=t HCLOUD_TOKEN=t \
        GITHUB_OUTPUT="$out" GITHUB_STEP_SUMMARY="$summary" \
        bash "$SCRIPT" >"$WORK/log" 2>&1
    then
        echo "FAIL $name — script exited non-zero"; sed 's/^/     /' "$WORK/log"; failed=$((failed + 1)); return
    fi

    # runner_name carries a timestamp; assert its shape, not its value.
    actual=$(sed 's/^runner_name=dev-00-gh-runner-.*/runner_name=<generated>/' "$out" | sort)
    if [ "$actual" = "$(printf '%s\n' "$expected" | sort)" ]; then
        echo "ok   $name"; pass=$((pass + 1))
    else
        echo "FAIL $name"
        echo "     expected: $(printf '%s\n' "$expected" | sort | tr '\n' ' ')"
        echo "     actual:   $(echo "$actual" | tr '\n' ' ')"
        failed=$((failed + 1))
    fi
}

echo "=== ci-build-create-runner.sh — $SCRIPT ==="

export SHIM_PG_GET='{"placement_groups":[]}' SHIM_PG_GET_CODE=200 SHIM_PG_POST_CODE=201

SHIM_SERVERS=$(servers dev-00-gh-runner-a:cx53:running) \
SHIM_RUNNERS=$(runners dev-00-gh-runner-a:online:false:large) \
check "reuses a bigger idle runner whose VM is running" \
    refs/tags/build-NC2-1 novatalks.ui \
    'runner_need=false
runner_labels=large'

SHIM_SERVERS=$(servers) SHIM_RUNNERS=$(runners) \
check "creates when nothing exists" \
    refs/tags/build-NC2-1 novatalks.ui \
    'runner_size=cx33
runner_name=<generated>
runner_labels=small
runner_need=true'

SHIM_SERVERS=$(servers) \
SHIM_RUNNERS=$(runners dev-00-gh-runner-ghost:online:false:small) \
check "skips a ghost registration whose VM is gone" \
    refs/tags/build-NC2-1 novatalks.ui \
    'runner_size=cx33
runner_name=<generated>
runner_labels=small
runner_need=true'

SHIM_SERVERS=$(servers dev-00-gh-runner-a:cx53:running) \
SHIM_RUNNERS=$(runners dev-00-gh-runner-a:online:false:large) \
check "reuses a large idle runner when medium is required" \
    refs/tags/unit-test-NC2-1 novatalks.core \
    'runner_need=false
runner_labels=large'

SHIM_SERVERS=$(servers dev-00-gh-runner-a:cx33:running) \
SHIM_RUNNERS=$(runners dev-00-gh-runner-a:online:false:small) \
check "will not reuse a small runner when medium is required" \
    refs/tags/unit-test-NC2-1 novatalks.core \
    'runner_size=cx43
runner_name=<generated>
runner_labels=medium
runner_need=true'

SHIM_SERVERS=$(servers dev-00-gh-runner-big:cx53:running dev-00-gh-runner-sml:cx33:running) \
SHIM_RUNNERS=$(runners dev-00-gh-runner-big:online:false:large dev-00-gh-runner-sml:online:false:small) \
check "picks the largest idle runner regardless of API order" \
    refs/tags/build-NC2-1 novatalks.ui \
    'runner_need=false
runner_labels=large'

SHIM_SERVERS=$(servers dev-00-gh-runner-a:cx33:deleting) \
SHIM_RUNNERS=$(runners dev-00-gh-runner-a:online:false:small) \
check "creates when the only idle runner's VM is deleting" \
    refs/tags/build-NC2-1 novatalks.ui \
    'runner_size=cx33
runner_name=<generated>
runner_labels=small
runner_need=true'

SHIM_SERVERS=$(servers dev-00-gh-runner-a:cx33:running dev-00-gh-runner-b:cx33:running \
    dev-00-gh-runner-c:cx43:running dev-00-gh-runner-d:cx43:running \
    dev-00-gh-runner-e:cx53:running dev-00-gh-runner-f:cx53:running) \
SHIM_RUNNERS=$(runners) \
check "waits at the global cap" \
    refs/tags/build-NC2-1 novatalks.ui \
    'runner_need=false
runner_labels=small'

SHIM_SERVERS=$(servers dev-00-gh-runner-a:cx33:running dev-00-gh-runner-b:cx33:starting) \
SHIM_RUNNERS=$(runners) \
check "waits at the per-size cap" \
    refs/tags/build-NC2-1 novatalks.ui \
    'runner_need=false
runner_labels=small'

SHIM_SERVERS=$(servers) SHIM_RUNNERS=$(runners) \
check "novatalks.core int-test tag takes a large VM" \
    refs/tags/int-test-NC2-1 novatalks.core \
    'runner_size=cx53
runner_name=<generated>
runner_labels=large
runner_need=true'

SHIM_SERVERS=$(servers) SHIM_RUNNERS=$(runners) \
check "novatalks.core unit-test tag takes a medium VM" \
    refs/tags/unit-test-NC2-1 novatalks.core \
    'runner_size=cx43
runner_name=<generated>
runner_labels=medium
runner_need=true'

SHIM_SERVERS=$(servers) SHIM_RUNNERS=$(runners) \
check "a branch named …-test stays small" \
    refs/heads/NC2-123-fix-test-timeout novatalks.core \
    'runner_size=cx33
runner_name=<generated>
runner_labels=small
runner_need=true'

SHIM_SERVERS=$(servers) SHIM_RUNNERS=$(runners) \
check "a test tag in another repo stays small" \
    refs/tags/int-test-NC2-1 novatalks.ui \
    'runner_size=cx33
runner_name=<generated>
runner_labels=small
runner_need=true'

SHIM_SERVERS=$(servers) SHIM_RUNNERS=$(runners) \
SHIM_PG_GET="{\"placement_groups\":[{\"id\":7,\"labels\":{\"epoch\":\"$(date +%s)\"}}]}" \
check "waits while another run holds the create lock" \
    refs/tags/build-NC2-1 novatalks.ui \
    'runner_need=false
runner_labels=small'

SHIM_SERVERS=$(servers) SHIM_RUNNERS=$(runners) \
SHIM_PG_GET='{"placement_groups":[{"id":7,"labels":{"epoch":"1000000000"}}]}' \
check "clears a stale create lock and creates" \
    refs/tags/build-NC2-1 novatalks.ui \
    'runner_size=cx33
runner_name=<generated>
runner_labels=small
runner_need=true'

SHIM_SERVERS=$(servers) SHIM_RUNNERS=$(runners) SHIM_PG_GET_CODE=500 \
check "fails open when the lock API breaks" \
    refs/tags/build-NC2-1 novatalks.ui \
    'runner_size=cx33
runner_name=<generated>
runner_labels=small
runner_need=true'

SHIM_SERVERS=$(servers) SHIM_RUNNERS=$(runners) \
check "core trunk build gets medium: DAST brings up pg, redis and the app" \
    refs/tags/build-NC2-1 novatalks.core \
    'runner_size=cx43
runner_name=<generated>
runner_labels=medium
runner_need=true' \
    refs/heads/development

SHIM_SERVERS=$(servers) SHIM_RUNNERS=$(runners) \
check "core feature-branch build stays small: no DAST, no medium-pool contention" \
    refs/tags/build-NC2-1 novatalks.core \
    'runner_size=cx33
runner_name=<generated>
runner_labels=small
runner_need=true' \
    refs/heads/NC2-123-some-feature

SHIM_SERVERS=$(servers) SHIM_RUNNERS=$(runners) \
check "core scan tag gets medium on any branch: a scan tag always runs DAST" \
    refs/tags/scan-NC2-1 novatalks.core \
    'runner_size=cx43
runner_name=<generated>
runner_labels=medium
runner_need=true' \
    refs/heads/NC2-123-some-feature

SHIM_SERVERS=$(servers) SHIM_RUNNERS=$(runners) \
check "core apiscan tag gets medium on any branch: apiscan always runs the API scan" \
    refs/tags/apiscan-NC2-1 novatalks.core \
    'runner_size=cx43
runner_name=<generated>
runner_labels=medium
runner_need=true' \
    refs/heads/NC2-123-some-feature

SHIM_SERVERS=$(servers) SHIM_RUNNERS=$(runners) \
check "ui trunk build stays small: static assets need no database" \
    refs/tags/build-NC2-1 novatalks.ui \
    'runner_size=cx33
runner_name=<generated>
runner_labels=small
runner_need=true' \
    refs/heads/development

SHIM_SERVERS=$(servers) SHIM_RUNNERS=$(runners) \
check "core build tag degrades to small when GITHUB_EVENT_PATH is missing" \
    refs/tags/build-NC2-1 novatalks.core \
    'runner_size=cx33
runner_name=<generated>
runner_labels=small
runner_need=true' \
    "" "$WORK/nonexistent-event.json"

echo '{ this is not json' > "$WORK/malformed-event.json"
SHIM_SERVERS=$(servers) SHIM_RUNNERS=$(runners) \
check "core build tag degrades to small when GITHUB_EVENT_PATH is malformed JSON" \
    refs/tags/build-NC2-1 novatalks.core \
    'runner_size=cx33
runner_name=<generated>
runner_labels=small
runner_need=true' \
    "" "$WORK/malformed-event.json"

echo
if [ "$failed" -ne 0 ]; then
    echo "$failed of $((pass + failed)) scenarios FAILED"
    exit 1
fi
echo "all $pass scenarios passed"
