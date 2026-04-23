REPO="${GITHUB_REPOSITORY##*/}"

TAG="${GITHUB_REF#refs/tags/}"

if [[ "$TAG" == *build* ]]; then
    REQUIRED_SIZE="small"
elif [[ "$TAG" == *test* ]]; then
    REQUIRED_SIZE="large"
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


RESPONSE=$(curl -s \
    -H "Authorization: Bearer $GH_TOKEN" \
    -H "Accept: application/vnd.github+json" \
    "https://api.github.com/orgs/$ORG/actions/runners")


RUNNERS=$(echo "$RESPONSE" | jq -r '
    [.runners[]
    | select(.name | startswith("gh-runner-"))
    ]')


COUNT=$(echo "$RUNNERS" | jq 'length')


echo "Total runners: $COUNT"


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


COUNT_SIZE=$(echo "$PARSED" | jq -r --arg size "$REQUIRED_SIZE" '
    map(select(.size == $size)) | length
')

echo "Current $REQUIRED_SIZE runners: $COUNT_SIZE"

if [ "$COUNT_SIZE" -lt 2 ]; then
    echo "Create new runner ($REQUIRED_SIZE)"
    echo "runner_size=$REQUIRED_TYPE" >> $GITHUB_OUTPUT
    echo "runner_name=gh-runner-$(date +%Y%m%d-%H%M%S-%3N)" >> $GITHUB_OUTPUT
    echo "runner_labels=$REQUIRED_SIZE" >> $GITHUB_OUTPUT
    echo "runner_need=true" >> $GITHUB_OUTPUT
else
    echo "Limit reached → do nothing (wait queue)"

    echo "runner_need=false" >> $GITHUB_OUTPUT
    echo "runner_labels=$REQUIRED_SIZE" >> $GITHUB_OUTPUT
fi