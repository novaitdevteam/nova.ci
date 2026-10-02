#!/usr/bin/env bash
# zap_fixture <LEVEL> <ID> <RISK> [<LEVEL> <ID> <RISK>]...
# Builds a console and a traditional-json report shaped like real ZAP output: one
# per-rule line per entry ("WARN-NEW: Rule <id> [<id>] x 2"), the tally counting
# rules, and site[].alerts[] with pluginid/riskcode. Sets ZF_CONSOLE and ZF_JSON.
# LEVEL is WARN, FAIL or IGNORE; RISK is ZAP's riskcode, 0 (informational) to 3 (high).
# Sourced by test-dast-scan.sh and test-dast-api-scan.sh, never executed.
zap_fixture() {
    local lines="" alerts="[]" w=0 f=0 ig=0 level id risk
    while [ "$#" -ge 3 ]; do
        level="$1" id="$2" risk="$3"; shift 3
        case "$level" in
            # Shaped like print_rule: "<LEVEL>-NEW: <name> [<id>] x <n> <user_msg>" — the
            # trailing space is always there, the register's message after it when set.
            # A fixture without them lets a regex anchored on "x <n>$" pass here and red
            # every real scan.
            WARN)   lines+="WARN-NEW: Rule ${id} [${id}] x 2 "$'\n'; w=$((w + 1)) ;;
            FAIL)   lines+="FAIL-NEW: Rule ${id} [${id}] x 2 blocking per the register"$'\n'; f=$((f + 1)) ;;
            IGNORE) lines+="IGNORE-NEW: Rule ${id} [${id}] x 2 accepted risk"$'\n'; ig=$((ig + 1)) ;;
        esac
        alerts=$(jq -c --arg id "$id" --arg r "$risk" '. + [{pluginid: $id, riskcode: $r, alert: ("Rule " + $id)}]' <<<"$alerts")
    done
    ZF_CONSOLE="${lines}FAIL-NEW: ${f}"$'\t'"FAIL-INPROG: 0"$'\t'"WARN-NEW: ${w}"$'\t'"WARN-INPROG: 0"$'\t'"INFO: 0"$'\t'"IGNORE: ${ig}"$'\t'"PASS: 30"
    ZF_JSON=$(jq -cn --argjson a "$alerts" '{site: [{"@name": "http://127.0.0.1", alerts: $a}]}')
}
