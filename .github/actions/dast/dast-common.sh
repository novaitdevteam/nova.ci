#!/usr/bin/env bash
#
# Shared ZAP result parsing for dast/ and dast-api/. Only the logic where a divergent
# copy would silently measure nothing lives here: the tally-line anchor, tally_at, and
# the numeric guard. Report assembly and notifier text differ per scanner and stay in
# each scan.sh. Sourced, never executed.

# _zap_tally_at <tally-line> <label>
# Plain top-level helper — a function cannot be declared `local`.
_zap_tally_at() { printf '%s' "$1" | tr '\t' '\n' | sed -n "s/^$2: //p" | head -1; }

# zap_tally_parse <console-file> <error-fn>
# Reads the one tally line ZAP prints at the end of any completed scan and sets the
# globals failures/findings/infos/accepted/passes. Calls <error-fn> (the caller's
# scanner_error) on a missing or non-numeric tally — fail closed, never guess a zero.
#
# The anchor is ANSI-C quoted so the tab is a real byte. GNU grep reads a plain '\t' in
# a pattern as a literal 't' (warning: stray \ before t), so the plainly-quoted form
# matches nothing on every Linux runner and reds every completed scan; only a macOS
# harness run passes it. Anchored on the tally's shape, not the bare FAIL-NEW: prefix,
# because print_rule emits a per-rule FAIL-NEW: <alert> line before the tally.
zap_tally_parse() {
    local console="$1" err_fn="$2" tally
    tally="$(grep -m1 -E $'^FAIL-NEW: [0-9]+\tFAIL-INPROG: ' "$console" || true)"
    [ -n "$tally" ] || { "$err_fn" "ZAP printed no result tally — the scan did not complete"; return; }

    failures="$(_zap_tally_at "$tally" FAIL-NEW)"
    findings="$(_zap_tally_at "$tally" WARN-NEW)"
    infos="$(_zap_tally_at "$tally" INFO)"
    accepted="$(_zap_tally_at "$tally" IGNORE)"
    passes="$(_zap_tally_at "$tally" PASS)"

    local n
    for n in "$failures" "$findings" "$infos" "$accepted" "$passes"; do
        [[ "$n" =~ ^[0-9]+$ ]] || { "$err_fn" "ZAP tally line is malformed: ${tally}"; return; }
    done
}

# dast_bring_up_nats <err_fn> <stream-log-file>
# Starts a plain, unconfigured NATS server (JetStream enabled) and creates the
# 'campaign' stream novatalks.dialer's client asks $JS.API.STREAM.NAMES for at startup —
# a running JetStream with no stream still throws "no stream matches subject". Mirrors
# ~/novatalks/scripts/nats-docker/scripts/js-init.sh, the stand the team already uses
# locally — same stream, same subjects, same retention — minus its `nsc push` step,
# which provisions JWT accounts this unauthenticated server has no use for. Keep the two
# comparable: if that script's stream changes, this should follow.
#
# Shared by dast/scan.sh and dast-api/scan.sh so this stays one copy: the only
# repository that needs NATS today (novatalks.dialer) is scanned by both actions, and a
# second inline copy is exactly the divergent-copy hazard zap_tally_parse above already
# exists to avoid. Calls <err_fn> (the caller's not_run) on any failure — fail closed,
# matching every other bring-up step in both scripts. The stream-creation log is the
# caller's own path so its EXIT trap can remove it alongside its other scratch files,
# the same way each caller already owns cleanup of its own zap console log.
dast_bring_up_nats() {
    local err_fn="$1" stream_log="$2"

    docker rm -f nova-nats >/dev/null 2>&1 || true
    # No config file, no auth, no TLS, no JetStream account provisioning: the client
    # side (novatalks.dialer's own .env.example) defaults to exactly this —
    # NATS_USER/NATS_PASS/NATS_NKEY/NATS_JWT all blank, NATS_TLS_ENABLED=false,
    # NATS_STREAM_ENABLED=false. Production NATS (nats-system/ntk-nats-prod-cluster) is
    # a three-node cluster with TLS and NKEY/account auth; none of that is needed here,
    # and mirroring it would scan something the client was never configured to reach.
    # `-m 8222` turns on the monitoring endpoint the wait-loop below polls.
    #
    # Tag-pinned, not digest-pinned, matching the postgres and redis images in both
    # callers: infrastructure containers follow that precedent, digest pinning is
    # reserved for the scanners themselves (Semgrep, ZAP).
    docker run -d --name nova-nats -p 4222:4222 -p 8222:8222 \
        nats:2.10-alpine -js -m 8222 || { "$err_fn" "NATS did not start"; return; }

    local nats_ready=no code
    for _ in $(seq 1 30); do
        code="$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:8222/healthz || true)"
        if [ -n "$code" ] && [ "$code" != "000" ]; then nats_ready=yes; break; fi
        sleep 2
    done
    [ "$nats_ready" = "yes" ] || { "$err_fn" "NATS did not become ready"; return; }

    docker run --rm --network host natsio/nats-box:0.19.7 \
        nats --server 127.0.0.1:4222 stream add campaign \
            --subjects 'campaign.*' \
            --storage file --replicas 1 \
            --retention work --discard old \
            --max-msgs=-1 --max-msgs-per-subject=-1 --max-bytes=-1 \
            --max-age=-1 --max-msg-size=-1 \
            --dupe-window=2m --no-allow-rollup --no-deny-delete --no-deny-purge \
            --defaults > "$stream_log" 2>&1 \
        || { sed 's/^/    /' "$stream_log" 2>/dev/null || true
             "$err_fn" "could not create the 'campaign' JetStream stream"; return; }
}

# zap_risk_counts <console-file> <json-file> <error-fn>
# Which rules count comes from the console's per-rule verdicts; how risky each one is
# comes from the -J traditional-json report. The report alone cannot answer the first
# question: it lists IGNOREd rules too (novatalks.ui, 2026-10-02 — the two accepted Lows
# sat in its Low row with and without the overlay). Sets risk_high/risk_medium/risk_low/
# risk_info, one per rule at its highest riskcode. Needs zap_tally_parse's globals: the
# per-rule lines must add up to the tally, or this would be counting something other
# than what ZAP counted. Fails closed on everything, like the tally.
zap_risk_counts() {
    local console="$1" report="$2" err_fn="$3" ids w f risks
    w=$(grep -cE '^WARN-NEW: .* \[[0-9]+\] x [0-9]+' "$console" || true)
    f=$(grep -cE '^FAIL-NEW: .* \[[0-9]+\] x [0-9]+' "$console" || true)
    if [ "$w" != "$findings" ] || [ "$f" != "$failures" ]; then
        "$err_fn" "ZAP per-rule lines (${w} warn, ${f} fail) disagree with its tally (${findings}, ${failures})"; return
    fi
    [ -s "$report" ] || { "$err_fn" "ZAP wrote no JSON report"; return; }
    jq -e '.site' "$report" >/dev/null 2>&1 || { "$err_fn" "ZAP's JSON report is not valid"; return; }
    ids=$(sed -nE 's/^(WARN|FAIL)-NEW: .* \[([0-9]+)\] x [0-9]+.*/\2/p' "$console" | sort -u | tr '\n' ' ')
    risks=$(jq -r --arg ids "$ids" '
        ([.site[]?.alerts[]? | {id: .pluginid, r: (.riskcode | tonumber)}]
         | group_by(.id) | map({key: .[0].id, value: (map(.r) | max)}) | from_entries) as $risk
        | $ids | split(" ") | map(select(. != ""))
        | map(if $risk[.] == null then "missing:" + . else ($risk[.] | tostring) end) | .[]' "$report") \
        || { "$err_fn" "ZAP's JSON report could not be read"; return; }
    if grep -q '^missing:' <<<"$risks"; then
        "$err_fn" "ZAP counted rule(s) $(grep '^missing:' <<<"$risks" | cut -d: -f2 | tr '\n' ' ')with no risk in its JSON report"; return
    fi
    risk_high=$(grep -cx 3 <<<"$risks" || true)
    risk_medium=$(grep -cx 2 <<<"$risks" || true)
    risk_low=$(grep -cx 1 <<<"$risks" || true)
    risk_info=$(grep -cx 0 <<<"$risks" || true)
}
