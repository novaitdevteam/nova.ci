#!/usr/bin/env bash
# Fail loudly instead of silently mis-deciding: an unhandled API or parse error must
# fail the step, not fall through to a create/wait decision made on empty counts.
set -euo pipefail

REPO="${GITHUB_REPOSITORY##*/}"

# Only real tag pushes carry sizing intent. For branch and PR events GITHUB_REF is
# refs/heads/<branch> or refs/pull/<n>/merge, and a branch name that happens to contain
# "test" (e.g. NC2-123-fix-test-timeout) must not provision a large VM for a plain
# build. An empty TAG falls through the sizing matrix to "small".
if [[ "$GITHUB_REF" == refs/tags/* ]]; then
    TAG="${GITHUB_REF#refs/tags/}"
else
    TAG=""
fi

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
        *) echo "::error::Unknown runner size: $1" >&2; exit 1 ;;
    esac
}


size_type() {
    case "$1" in
        small) echo cx33 ;;
        medium) echo cx43 ;;
        large) echo cx53 ;;
        *) echo "::error::Unknown runner size: $1" >&2; exit 1 ;;
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

# Emit wait-queue diagnostics: without them a queued job just sits on a runner label
# with no hint in the step log or summary about why nothing was created and what will
# (or will not) eventually pick the job up.
report_wait_queue() {
    local reason="$1" tone="${2:-auto}"

    if [ "$TOTAL_SIZE" -gt 0 ]; then
        echo "::notice::Runner wait queue: $reason. $TOTAL_SIZE active $REQUIRED_SIZE runner VM(s) exist; the job starts once one frees up."
    elif [ "$tone" = "notice" ]; then
        echo "::notice::Runner wait queue: $reason. If that creation succeeds, its runner picks this job up; otherwise the next trigger after lock expiry (max ${RUNNER_LOCK_TTL_SECONDS:-60}s) creates one."
    else
        echo "::warning::Runner wait queue starvation risk: $reason, and no active $REQUIRED_SIZE runner VM exists. This job waits until another trigger creates one, or until the job timeout."
    fi

    {
        echo "### Runner wait queue"
        echo ""
        echo "- Reason: $reason"
        echo "- Required size: \`$REQUIRED_SIZE\` (\`$REQUIRED_TYPE\`)"
        echo "- Active \`$REQUIRED_SIZE\` runner VMs: $TOTAL_SIZE"
        echo "- Total \`dev-00-gh-runner-*\` servers (any status/size): $TOTAL_ALL (cap $MAX_TOTAL_RUNNERS)"
    } >> "${GITHUB_STEP_SUMMARY:-/dev/null}"
}

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


echo "GitHub-registered dev-00-gh-runner-* runners (any status): $COUNT"


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


# A GitHub registration can outlive (or misrepresent) its VM: a runner may still show
# online && idle while its Hetzner server is already deleting (idle auto-shutdown,
# watchdog cleanup) or gone entirely (ghost registration). Reusing one queues the job
# on a runner that will never pick it up, so only trust runners whose backing Hetzner
# VM is actually running.
ACTIVE_VM_NAMES=$(echo "$HETZNER_RESPONSE" | jq '
    [
        .servers[]
        | select(.name | startswith("dev-00-gh-runner-"))
        | select(.status == "running")
        | .name
    ]')

BEST=$(echo "$PARSED" | jq -r --argjson active_vms "$ACTIVE_VM_NAMES" '
    map(select(.status=="online" and .busy==false and (.name as $n | $active_vms | index($n))))
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
    echo "runner_need=false" >> "$GITHUB_OUTPUT"
    echo "runner_labels=$BEST_MATCH" >> "$GITHUB_OUTPUT"
    exit 0
fi


if [ "$TOTAL_ALL" -ge "$MAX_TOTAL_RUNNERS" ]; then
    echo "Global runner cap reached ($TOTAL_ALL/$MAX_TOTAL_RUNNERS) → wait queue"
    report_wait_queue "global cap reached ($TOTAL_ALL/$MAX_TOTAL_RUNNERS dev-00-gh-runner-* servers in any status)"

    echo "runner_need=false" >> "$GITHUB_OUTPUT"
    echo "runner_labels=$REQUIRED_SIZE" >> "$GITHUB_OUTPUT"
    exit 0
fi


# --- Create lock --------------------------------------------------------------------
# The create decision here and the actual VM creation in the caller are seconds apart,
# and a new VM only becomes visible to the per-size count once Hetzner lists it. Two
# concurrent triggers can therefore both see room in the pool and both create
# (check-then-act race). A short-TTL lock closes that window.
#
# The lock is a Hetzner placement group named runner-create-lock-<size>: placement
# group names are unique per project, so POST /placement_groups is atomic (a
# uniqueness_error means somebody else won). It lives in the same Hetzner project the
# runner VMs are created in, written with the same HCLOUD_TOKEN every caller already
# passes to create those VMs -- org-wide scope with no extra credentials. (The earlier
# GitHub-ref lock variants died exactly there: the org PAT has no contents:write on
# any lock repo, and the built-in GITHUB_TOKEN would need per-caller wiring.) A
# placement group is free, pure metadata, and -- unlike an SSH key -- creating one
# does not trigger account security notifications.
# The group's "epoch" label carries the acquisition timestamp. Nobody releases the
# lock explicitly; it expires via TTL, by which time the winner's VM is visible to the
# counts, and the next trigger for that size clears the stale group. Every failure of
# the lock machinery itself fails OPEN (proceed without the lock, with a ::warning::):
# an API problem must degrade to the small race window, never block all creation.
RUNNER_LOCK_TTL_SECONDS="${RUNNER_LOCK_TTL_SECONDS:-60}"
LOCK_NAME="runner-create-lock-$REQUIRED_SIZE"
HC_API_BODY=$(mktemp)

# hcloud_api METHOD PATH [JSON_PAYLOAD] -> sets HC_API_CODE; response body in $HC_API_BODY
hcloud_api() {
    local method="$1" path="$2" payload="${3:-}"
    local args=(-sS -X "$method"
        -H "Authorization: Bearer $HCLOUD_TOKEN"
        -H "Content-Type: application/json"
        -o "$HC_API_BODY" -w "%{http_code}")
    if [ -n "$payload" ]; then
        args+=(-d "$payload")
    fi
    args+=("https://api.hetzner.cloud/v1$path")
    HC_API_CODE=$(curl "${args[@]}") || HC_API_CODE=000
}

acquire_create_lock() {
    local lock_id="" lock_epoch="" now="" age="" epoch="" err_code=""

    hcloud_api GET "/placement_groups?name=$LOCK_NAME"
    if [ "$HC_API_CODE" != "200" ]; then
        echo "::warning::Create lock inspection failed (HTTP $HC_API_CODE); creating without lock"
        return 0
    fi
    lock_id=$(jq -r '.placement_groups[0].id // empty' "$HC_API_BODY") || lock_id=""
    if [ -n "$lock_id" ]; then
        lock_epoch=$(jq -r '.placement_groups[0].labels.epoch // empty' "$HC_API_BODY" | tr -cd '0-9') || lock_epoch=""
        now=$(date +%s)
        # Guard the arithmetic before using the label as an epoch. A malformed value
        # (milliseconds epoch, stray digits, leading zeros) must resolve to
        # "unreadable -> stale", not wedge the lock: a 13-digit ms epoch makes the
        # age permanently negative ("held" forever, fail-closed), and a leading-zero
        # string with 8/9 in it octal-aborts the arithmetic -- which would skip the
        # entire enclosing if/else and leave $GITHUB_OUTPUT empty on a green step.
        if [[ ! "$lock_epoch" =~ ^[1-9][0-9]{8,10}$ ]]; then
            lock_epoch=""
        fi
        if [ -n "$lock_epoch" ]; then
            age=$((now - lock_epoch))
            # Symmetric window: a slightly future-dated epoch (clock skew) still counts
            # as held, but anything far outside the TTL in either direction is stale.
            if [ "$age" -lt "$RUNNER_LOCK_TTL_SECONDS" ] && [ "$age" -gt "-$RUNNER_LOCK_TTL_SECONDS" ]; then
                echo "Create lock $LOCK_NAME held (age ${age}s < ${RUNNER_LOCK_TTL_SECONDS}s TTL)"
                return 1
            fi
        fi
        # Stale (the holder finished or died; its VM, if any, is visible to the counts
        # by now) or unreadable: clear it and fall through to acquisition. Two triggers
        # clearing the same stale group is fine: the second DELETE 404s harmlessly and
        # the create below still decides a single winner.
        echo "Clearing stale create lock $LOCK_NAME"
        hcloud_api DELETE "/placement_groups/$lock_id"
    fi

    epoch=$(date +%s)
    hcloud_api POST "/placement_groups" "$(jq -n \
        --arg name "$LOCK_NAME" --arg epoch "$epoch" \
        '{name: $name, type: "spread", labels: {"nova-ci": "create-lock", epoch: $epoch}}')"
    if [ "$HC_API_CODE" = "201" ]; then
        echo "Acquired create lock $LOCK_NAME"
        return 0
    fi
    # Decide by the API error code, not the HTTP status: name collision is the one
    # "somebody else won" signal; anything else is a machinery failure -> fail open.
    err_code=$(jq -r '.error.code // empty' "$HC_API_BODY") || err_code=""
    if [ "$err_code" = "uniqueness_error" ]; then
        echo "Lost create lock race on $LOCK_NAME"
        return 1
    fi
    echo "::warning::Create lock creation failed (HTTP $HC_API_CODE, ${err_code:-no error code}); creating without lock"
    return 0
}


if [ "$TOTAL_SIZE" -lt 2 ]; then
    if acquire_create_lock; then
        echo "Create new runner ($REQUIRED_SIZE)"
        echo "runner_size=$REQUIRED_TYPE" >> "$GITHUB_OUTPUT"
        # %3N (milliseconds) is GNU date only -- fine on the ubuntu runners this runs on.
        echo "runner_name=dev-00-gh-runner-$(TZ=Europe/Kyiv date +%Y%m%d-%H%M%S-%3N)" >> "$GITHUB_OUTPUT"
        echo "runner_labels=$REQUIRED_SIZE" >> "$GITHUB_OUTPUT"
        echo "runner_need=true" >> "$GITHUB_OUTPUT"
    else
        echo "Create lock held → wait queue"
        report_wait_queue "another run took the $REQUIRED_SIZE create lock moments ago" notice

        echo "runner_need=false" >> "$GITHUB_OUTPUT"
        echo "runner_labels=$REQUIRED_SIZE" >> "$GITHUB_OUTPUT"
    fi
else
    echo "Limit reached → do nothing (wait queue)"
    report_wait_queue "per-size cap reached ($TOTAL_SIZE/2 $REQUIRED_SIZE servers)"

    echo "runner_need=false" >> "$GITHUB_OUTPUT"
    echo "runner_labels=$REQUIRED_SIZE" >> "$GITHUB_OUTPUT"
fi