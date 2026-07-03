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

DELAY=$((RANDOM % 60))

echo "Sleep $DELAY sec to avoid runner race..."
sleep $DELAY

HETZNER_RESPONSE=$(curl -s \
    "https://api.hetzner.cloud/v1/servers" \
    --header "Authorization: Bearer $HCLOUD_TOKEN")

TOTAL_ALL=$(echo "$HETZNER_RESPONSE" | jq -r '
    [
        .servers[]
        | select(.name | startswith("dev-00-gh-runner-"))
    ] | length
')

echo "Total dev-00-gh-runner-* Hetzner servers (any status/size): $TOTAL_ALL"

CREATING_RUNNERS=$(echo "$HETZNER_RESPONSE" | jq -r \
    --arg required_type "$REQUIRED_TYPE" '
    [
        .servers[]
        | select(.name | startswith("dev-00-gh-runner-"))
        | select(.status == "starting" or .status == "initializing")
        | select(.server_type.name == $required_type)
    ] | length
')

echo "Runners in creating process: $CREATING_RUNNERS"

RESPONSE=$(curl -s \
    -H "Authorization: Bearer $GH_TOKEN" \
    -H "Accept: application/vnd.github+json" \
    "https://api.github.com/orgs/$ORG/actions/runners")


RUNNERS=$(echo "$RESPONSE" | jq -r '
    [.runners[]
    | select(.name | startswith("dev-00-gh-runner-"))
    ]')


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
        | .[]
        | select(.priority >= '"$REQUIRED_PRIORITY"')
        | .size
    ' | head -n1)
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


COUNT_SIZE=$(echo "$PARSED" | jq -r --arg size "$REQUIRED_SIZE" '
    map(select(.size == $size)) | length
')

TOTAL_SIZE=$((COUNT_SIZE + CREATING_RUNNERS))

echo "Current $REQUIRED_SIZE runners: $TOTAL_SIZE"

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