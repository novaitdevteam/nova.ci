#!/usr/bin/env bash
# Fail loudly instead of silently mis-deciding: an unhandled API or parse error must
# fail the step, not fall through to a create/wait decision made on empty counts.
set -euo pipefail

REPO="${GITHUB_REPOSITORY##*/}"

TAG="${GITHUB_REF#refs/tags/}"

# Global cap on concurrently existing dev-00-gh-runner-* Hetzner servers, across all
# sizes. Defaults to 6 (the theoretical max of the per-size caps: 2 small + 2 medium +
# 2 large). Env-overridable by callers. Tune this down just under the actual Hetzner
# project server limit once that limit is known.
MAX_TOTAL_RUNNERS="${MAX_TOTAL_RUNNERS:-6}"

# Runner sizing matrix.
# novatalks.core differentiates test sizing: unit tests are light and DB-less (medium),
# while integration/both need postgres + redis + the app (large). build stays small.
# All other repositories always use small, regardless of tag: the switcher only routes
# test tags to the large test matrix for novatalks.core, so a large VM for any other
# repo's test tag would be pure waste.
if [[ "$REPO" == "novatalks.core" ]]; then
    if [[ "$TAG" == *build* ]]; then
        REQUIRED_SIZE="small"
    elif [[ "$TAG" == *unit-test* ]]; then
        REQUIRED_SIZE="medium"
    elif [[ "$TAG" == *test* ]]; then
        REQUIRED_SIZE="large"
    else
        REQUIRED_SIZE="small"
    fi
else
    REQUIRED_SIZE="small"
fi


size_priority() {
    case "$1" in
        small) echo 1 ;;
        medium) echo 2 ;;
        large) echo 3 ;;
        *) echo 0 ;;
    esac
}


size_type() {
    case "$1" in
        small) echo cx33 ;;
        medium) echo cx43 ;;
        large) echo cx53 ;;
        *) echo 0 ;;
    esac
}


REQUIRED_PRIORITY=$(size_priority "$REQUIRED_SIZE")


REQUIRED_TYPE=$(size_type "$REQUIRED_SIZE")

DELAY=$((RANDOM % 10))

echo "Sleep $DELAY sec (0-9) to avoid runner race..."
sleep $DELAY

# Fetch the full server list with pagination. The Hetzner API returns 25 servers per
# page by default; once the project holds more servers than one page, runner VMs fall
# off the truncated list, both caps undercount, and extra runners get created.
HETZNER_PAGES=""
HETZNER_PAGE=1
while true; do
    HETZNER_PAGE_RESPONSE=$(curl -sS --fail-with-body \
        "https://api.hetzner.cloud/v1/servers?per_page=50&page=$HETZNER_PAGE" \
        --header "Authorization: Bearer $HCLOUD_TOKEN") || {
        echo "::error::Hetzner API servers request failed (page $HETZNER_PAGE): ${HETZNER_PAGE_RESPONSE:0:300}"
        exit 1
    }
    if ! echo "$HETZNER_PAGE_RESPONSE" | jq -e '.servers | type == "array"' >/dev/null; then
        echo "::error::Unexpected Hetzner API response shape (page $HETZNER_PAGE, no .servers array): ${HETZNER_PAGE_RESPONSE:0:300}"
        exit 1
    fi
    HETZNER_PAGES="$HETZNER_PAGES$HETZNER_PAGE_RESPONSE"
    HETZNER_NEXT_PAGE=$(echo "$HETZNER_PAGE_RESPONSE" | jq -r '.meta.pagination.next_page // empty')
    if [ -z "$HETZNER_NEXT_PAGE" ] || [ "$HETZNER_PAGE" -ge 20 ]; then
        break
    fi
    HETZNER_PAGE=$HETZNER_NEXT_PAGE
done

# Merge all pages into a single {servers: [...]} document so the jq filters below
# keep working on one response object.
HETZNER_RESPONSE=$(echo "$HETZNER_PAGES" | jq -s '{servers: (map(.servers // []) | add)}')

TOTAL_ALL=$(echo "$HETZNER_RESPONSE" | jq -r '
    [
        .servers[]
        | select(.name | startswith("dev-00-gh-runner-"))
    ] | length
')

echo "Total dev-00-gh-runner-* Hetzner servers (any status/size): $TOTAL_ALL"

# Fetch every runners page. The GitHub API returns 30 runners per page by default;
# with more registered runners in the org, idle dev-00-gh-runner-* runners beyond the
# first page would be invisible to the reuse check and cause unnecessary VM creation.
RUNNERS='[]'
GH_PAGE=1
while true; do
    RESPONSE=$(curl -sS --fail-with-body \
        -H "Authorization: Bearer $GH_TOKEN" \
        -H "Accept: application/vnd.github+json" \
        "https://api.github.com/orgs/$ORG/actions/runners?per_page=100&page=$GH_PAGE") || {
        echo "::error::GitHub API runners request failed (page $GH_PAGE): ${RESPONSE:0:300}"
        exit 1
    }
    if ! echo "$RESPONSE" | jq -e '.runners | type == "array"' >/dev/null; then
        echo "::error::Unexpected GitHub API response shape (page $GH_PAGE, no .runners array): ${RESPONSE:0:300}"
        exit 1
    fi
    PAGE_RUNNERS=$(echo "$RESPONSE" | jq '
        [.runners[]?
        | select(.name | startswith("dev-00-gh-runner-"))
        ]')
    RUNNERS=$(jq -n --argjson acc "$RUNNERS" --argjson page "${PAGE_RUNNERS:-[]}" '$acc + $page')
    PAGE_COUNT=$(echo "$RESPONSE" | jq -r '.runners | length')
    if [ -z "$PAGE_COUNT" ] || [ "$PAGE_COUNT" -lt 100 ] || [ "$GH_PAGE" -ge 10 ]; then
        break
    fi
    GH_PAGE=$((GH_PAGE + 1))
done


COUNT=$(echo "$RUNNERS" | jq 'length')


echo "Total running runners: $COUNT"


PARSED=$(echo "$RUNNERS" | jq '
    map({
        name: .name,
        status: .status,
        busy: .busy,
        size: (
            [.labels[].name
            | select(. == "small" or . == "medium" or . == "large")
            ][0] // "unknown"
        )
    })
')


BEST=$(echo "$PARSED" | jq -r '
    map(select(.status=="online" and .busy==false))
')


BEST_MATCH=""


if [ "$(echo "$BEST" | jq 'length')" -gt 0 ]; then
    BEST_MATCH=$(echo "$BEST" | jq -r '
        map(. + {
            priority:
                (if .size=="small" then 1
                 elif .size=="medium" then 2
                 elif .size=="large" then 3
                 else 0 end)
        })
        | sort_by(.priority)
        | reverse
        | map(select(.priority >= '"$REQUIRED_PRIORITY"'))
        | .[0].size // empty
    ')
fi


if [ -n "$BEST_MATCH" ]; then
    echo "Using existing runner: $BEST_MATCH"
    echo "runner_need=false" >> $GITHUB_OUTPUT
    echo "runner_labels=$BEST_MATCH" >> $GITHUB_OUTPUT
    exit 0
fi


if [ "$TOTAL_ALL" -ge "$MAX_TOTAL_RUNNERS" ]; then
    echo "Global runner cap reached ($TOTAL_ALL/$MAX_TOTAL_RUNNERS) → wait queue"

    echo "runner_need=false" >> $GITHUB_OUTPUT
    echo "runner_labels=$REQUIRED_SIZE" >> $GITHUB_OUTPUT
    exit 0
fi


# Count per-size directly from Hetzner server state (starting/initializing/running of
# the required server_type), not from GitHub-registered runners. This covers VMs that
# were just created but haven't registered as a GitHub runner yet, and excludes offline
# "ghost" GitHub registrations left over from failed creates that have no backing VM.
TOTAL_SIZE=$(echo "$HETZNER_RESPONSE" | jq -r \
    --arg required_type "$REQUIRED_TYPE" '
    [
        .servers[]
        | select(.name | startswith("dev-00-gh-runner-"))
        | select(.server_type.name == $required_type)
        | select(.status == "starting" or .status == "initializing" or .status == "running")
    ] | length
')

echo "Current $REQUIRED_SIZE Hetzner servers (starting/initializing/running): $TOTAL_SIZE"

if [ "$TOTAL_SIZE" -lt 2 ]; then
    echo "Create new runner ($REQUIRED_SIZE)"
    echo "runner_size=$REQUIRED_TYPE" >> $GITHUB_OUTPUT
    echo "runner_name=dev-00-gh-runner-$(TZ=Europe/Kyiv date +%Y%m%d-%H%M%S-%3N)" >> $GITHUB_OUTPUT
    echo "runner_labels=$REQUIRED_SIZE" >> $GITHUB_OUTPUT
    echo "runner_need=true" >> $GITHUB_OUTPUT
else
    echo "Limit reached → do nothing (wait queue)"

    echo "runner_need=false" >> $GITHUB_OUTPUT
    echo "runner_labels=$REQUIRED_SIZE" >> $GITHUB_OUTPUT
fi