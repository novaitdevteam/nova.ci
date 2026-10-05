# SAST and DAST lines by severity: implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Semgrep and both ZAP scans report High / Medium / Low (and ZAP's Informational) like
the Trivy line does. `outcome=findings` follows High, or a ZAP `FAIL`, and gates do not change.

**Architecture:**
- **Semgrep:** `semgrep/scan.sh` buckets results with Semgrep's own severity mapping in `jq`.
- **ZAP:** both ZAP `scan.sh` files add `-J` (the JSON report) and call one new function,
  `zap_risk_counts`, in `dast/dast-common.sh`. It joins the console's per-rule
  `WARN-NEW`/`FAIL-NEW` lines with each rule's `riskcode` from the JSON. `IGNORE`d rules never
  count.
- **Proof that a scan ran:** the canary, `.errors[]`, the tally and the exit ladder stay
  untouched and run first.

**Tech Stack:** bash, jq, the pinned Semgrep and ZAP images, and the offline harnesses
`scripts/test-*.sh` (docker shimmed on `PATH`).

**Spec:** `docs/superpowers/specs/2026-10-02-scanner-severity-lines-design.md`

## Global Constraints

- **Semgrep mapping:** `CRITICAL`/`HIGH`/`ERROR` → high, `MEDIUM`/`WARNING` → medium,
  `LOW`/`INFO` → low. Any other severity string → high, plus a `::warning::`. Never drop it.
- **ZAP risk:** `riskcode` 3 → high, 2 → medium, 1 → low, 0 → informational. Counted per rule
  (pluginid), at that rule's highest `riskcode` in the JSON.
- **`outcome=findings`:** only when high > 0, or a ZAP `FAIL` > 0. Otherwise `clean`. `error`
  and `not-run` are unchanged.
- **Proof first:** the canary, `.errors[]`, the tab-anchored tally and the exit-code ladder are
  not modified and run before any severity code.
- **Fail closed:** a missing or unparseable JSON, a counted rule absent from the JSON, or
  per-rule lines that disagree with the tally → `scanner_error`, never a zero.
- **No severity filter hides Medium:** Medium stays counted and listed in the `.report` and the
  job summary on every run, clean or not.
- **Line format:** `🟠 HIGH found · H high · M medium · L low` / `🟢 clean · M medium · L low`.
  ZAP adds `· I informational · A accepted` on clean runs, and api-scan adds
  `· N operations`. ZAP `FAIL` stays `🔴 F must-fix · …`.
- **Outputs:** keep `outcome`, `findings`, `failures`, `warnings` and `message`, and add
  `high`, `medium`, `low` (and `informational` for ZAP).
  - `findings` = high (Semgrep) or high + failures (ZAP).
  - Semgrep `warnings` = medium.
- **Every `scan.sh` change gets its harness scenario first** (CLAUDE.md). Run
  `./scripts/validate.sh` before every commit. It hangs locally in actionlint, so the
  `actionlint` result comes from CI.

## Review Focus

1. **A leftover `zap.json` on a reused runner.** `zap_work_dir` outlives the job, so a run whose
   ZAP writes no JSON must not read the previous run's. Delete it before ZAP runs. Pinned in
   Task 3, step 1.
2. **A rule raised at two risks**, e.g. the same pluginid on two sites, counts once at the
   highest. Pinned in Task 2, step 1.
3. **A Semgrep severity outside the known set**, from a newer Semgrep or a custom rule, counts
   as high with a warning, never silently zero. Pinned in Task 1, step 1.
4. **A `FAIL` rule is in a risk bucket too.** The line shows `🔴 1 must-fix · 0 high · …` and
   does not double-count it in `findings`. Pinned in Task 3, step 1.
5. **The caller template's `secrets-inherit` is a Semgrep `ERROR`, so it maps to high.** Every
   product repository will read `🟠 HIGH found` until callers carry `nosemgrep`. Not a code
   path: it goes in the PR description, Task 6.

---

### Task 1: Semgrep severity buckets

**Files:**
- Modify: `.github/actions/semgrep/scan.sh` (the counting block from `count_at()` to the end)
- Modify: `.github/actions/semgrep/action.yml` (`outputs:`)
- Test: `scripts/test-sast-scan.sh`

**Interfaces:**
- Produces outputs `high`, `medium`, `low`, with `findings` = high and `warnings` = medium.
- Produces `outcome` ∈ {clean, findings, error}.

- [ ] **Step 1: Write the failing scenarios.** Append to `scripts/test-sast-scan.sh`, before the
  final `echo "--- $pass passed…"`. `semgrep_json yes <SEV>...` already builds results with the
  given severities.

```bash
# --- severity buckets (Semgrep's own mapping) ---------------------------------------
assert_out() { # assert_out <name> <key> <expected>
    local got; got=$(sed -n "s/^$2=//p" "$WORK/output" | head -1)
    if [ "$got" = "$3" ]; then echo "ok   $1"; pass=$((pass + 1))
    else echo "FAIL $1 — expected $2=$3, got $2=$got"; fail=$((fail + 1)); fi
}

SHIM_JSON="$(semgrep_json yes ERROR WARNING WARNING INFO)" SHIM_RC=1 \
    expect "ERROR is high and makes it a finding" findings 1
assert_out "WARNING is medium" medium 2
assert_out "INFO is low" low 1
assert_out "warnings output stays the medium count" warnings 2
if grep -q '🟠 HIGH found · 1 high · 2 medium · 1 low' "$WORK/output"; then
    echo "ok   the line reads like Trivy's"; pass=$((pass + 1))
else echo "FAIL the line is not severity-shaped"; sed 's/^/     /' "$WORK/output"; fail=$((fail + 1)); fi

SHIM_JSON="$(semgrep_json yes WARNING WARNING)" SHIM_RC=1 \
    expect "medium only is clean, not a finding" clean 0
assert_out "medium is still counted on a clean run" medium 2
assert_summary "medium is still listed on a clean run" "src/a.ts:3"
assert_report "medium is still in the report on a clean run" "=== MEDIUM: 2 ==="
if grep -q '🟢 clean · 2 medium · 0 low' "$WORK/output"; then
    echo "ok   the clean line carries the breakdown"; pass=$((pass + 1))
else echo "FAIL the clean line hides the breakdown"; sed 's/^/     /' "$WORK/output"; fail=$((fail + 1)); fi

SHIM_JSON="$(semgrep_json yes HIGH CRITICAL MEDIUM LOW)" SHIM_RC=1 \
    expect "native HIGH and CRITICAL are high" findings 2
assert_out "native MEDIUM is medium" medium 1
assert_out "native LOW is low" low 1

# Review Focus 3: an unknown severity is never dropped.
SHIM_JSON="$(semgrep_json yes BLOCKER)" SHIM_RC=1 \
    expect "an unknown severity counts as high" findings 1
if grep -q '::warning::.*unknown severity' "$WORK/log"; then
    echo "ok   an unknown severity is called out"; pass=$((pass + 1))
else echo "FAIL an unknown severity passed silently"; fail=$((fail + 1)); fi
```

  These existing scenarios change meaning. Edit them in the same step:
  - `"a lone WARNING is a finding, not a clean scan" findings 0` becomes
    `"a lone WARNING is medium: clean, still counted" clean 0`. Keep its `assert_warnings … 1`.
    Change its `assert_report "=== WARNING: 1 ==="` to `"=== MEDIUM: 1 ==="`.
  - `assert_report "report lists the ERROR section" "=== ERROR: 2 ==="` becomes
    `"=== HIGH: 2 ==="`.
  - `"=== WARNING: 3 ==="` becomes `"=== MEDIUM: 3 ==="`.
  - `"a clean scan lists nothing"`: the `<details>` absence still holds, because
    `semgrep_json yes` has no Medium.

- [ ] **Step 2: Run, confirm the new scenarios fail.**
  Run `./scripts/test-sast-scan.sh 2>&1 | grep -E '^FAIL|^--- '`. Expected: the FAIL lines
  above (`medium` unset, old line text), and nothing else red.

- [ ] **Step 3: Implement.** In `.github/actions/semgrep/scan.sh`, replace `count_at()`,
  `list_at()`, the three `errors=/warnings=/infos=` lines, the report block, the outcome `if`,
  the summary block, `list_capped()` and the findings `<details>` block with:

```bash
# Semgrep's own mapping (ERROR/WARNING/INFO = high/medium/low); a rule that declares a
# native severity keeps it. Anything else is counted high and called out — a severity
# nobody recognises is never a silent zero. The canary is excluded by rule ID.
BUCKET='def bucket: ((.extra.severity // "") | ascii_upcase) as $s
    | if ($s == "CRITICAL" or $s == "HIGH" or $s == "ERROR") then "high"
      elif ($s == "MEDIUM" or $s == "WARNING") then "medium"
      elif ($s == "LOW" or $s == "INFO") then "low" else "unknown" end;
  def real: .results[] | select(.check_id | test("nova-ci-semgrep-canary") | not);'

count_in() { jq --arg b "$1" "$BUCKET"' [real | select(bucket == $b)] | length' "$json"; }
list_in() {
    jq -r --arg b "$1" "$BUCKET"' real | select(bucket == $b)
        | "\(.path):\(.start.line)  [\(.check_id)]\n    \(.extra.message)\n"' "$json"
}

unknown=$(count_in unknown)
[ "$unknown" -eq 0 ] || echo "::warning::Semgrep returned ${unknown} result(s) with an unknown severity — counted as high."
high=$(( $(count_in high) + unknown ))
medium=$(count_in medium)
low=$(count_in low)

{
    echo "=============================="
    echo " SAST: Semgrep"
    echo " Image:    ${SEMGREP_IMAGE}"
    echo " Configs:  ${SEMGREP_CONFIGS}"
    echo "=============================="
    echo ""
    echo "=== HIGH: ${high} ==="
    echo ""
    list_in high; list_in unknown
    echo "=== MEDIUM: ${medium} ==="
    echo ""
    list_in medium
    echo "=== LOW: ${low} (counted, not listed) ==="
} > "$SEMGREP_REPORT_FILE"

if [ "$high" -gt 0 ]; then
    outcome=findings
    echo "::warning::Semgrep found ${high} high and ${medium} medium finding(s). See ${SEMGREP_REPORT_FILE}."
    message="🔍 SAST (Semgrep): 🟠 HIGH found · ${high} high · ${medium} medium · ${low} low"$'\n'"   📄 Report: ${REPORT_URL:-n/a}"
    alert=WARNING
    headline="🟠 ${high} high-severity finding(s) — review the report."
else
    outcome=clean
    message="🔍 SAST (Semgrep): 🟢 clean · ${medium} medium · ${low} low"$'\n'"   📄 Report: ${REPORT_URL:-n/a}"
    alert=NOTE
    headline="✅ No high-severity findings. ${medium} medium and ${low} low are listed below for review."
fi

{
    echo "## 🔍 SAST (Semgrep)"
    echo ""
    echo "> [!${alert}]"
    echo "> ${headline}"
    echo ""
    echo "- Image: \`${SEMGREP_IMAGE}\`"
    echo "- Configs: \`${SEMGREP_CONFIGS}\`"
    echo "- Files scanned: ${scanned}"
    echo "- High: ${high} · Medium: ${medium} · Low: ${low}"
    echo "- Report: ${REPORT_URL:-not published}"
} >> "${GITHUB_STEP_SUMMARY:-/dev/null}"

# High and Medium inline in the summary, on every run — Medium is the level the old
# single-severity filter once hid from everyone. Capped; the artifact has all of them.
SUMMARY_LIST_CAP=25
listed=$(( high + medium ))
if [ "$listed" -gt 0 ]; then
    {
        echo ""
        echo "<details><summary>High and medium findings</summary>"
        echo ""
        echo '```'
        jq -r --argjson cap "$SUMMARY_LIST_CAP" "$BUCKET"'
            [real | {b: bucket, r: .} | select(.b != "low")]
            | sort_by(if .b == "medium" then 1 else 0 end) | .[:$cap][]
            | "\(.b | ascii_upcase)  \(.r.path):\(.r.start.line)  [\(.r.check_id)]\n    \((.r.extra.message // "") | gsub("\n"; " ") | .[0:160])"' "$json"
        echo '```'
        if [ "$listed" -gt "$SUMMARY_LIST_CAP" ]; then
            echo ""
            echo "Showing ${SUMMARY_LIST_CAP} of ${listed}. The full list is in the \`$(basename "$SEMGREP_REPORT_FILE")\` artifact."
        fi
        echo ""
        echo "</details>"
    } >> "${GITHUB_STEP_SUMMARY:-/dev/null}"
fi

emit outcome "$outcome"
emit findings "$high"
emit warnings "$medium"
emit high "$high"
emit medium "$medium"
emit low "$low"
emit_message "$message"
echo "Semgrep results — high: ${high}, medium: ${medium}, low: ${low} (outcome: ${outcome})"
```

  Also update `finish_error` to emit `high 0`, `medium 0` and `low 0` next to its existing
  zeros. In `action.yml`, add three outputs after `warnings`:

```yaml
  high:
    description: "High-severity results (ERROR, or a native CRITICAL/HIGH) — the only level that makes outcome=findings"
    value: ${{ steps.scan.outputs.high }}
  medium:
    description: "Medium-severity results (WARNING, or native MEDIUM) — counted and listed on every run"
    value: ${{ steps.scan.outputs.medium }}
  low:
    description: "Low-severity results (INFO, or native LOW) — counted, not listed"
    value: ${{ steps.scan.outputs.low }}
```

  Then change `findings`' description to `"Number of high-severity results"` and `warnings`'
  to `"Number of medium-severity results (kept for callers; same as medium)"`.

- [ ] **Step 4: Run, confirm green.** Run `./scripts/test-sast-scan.sh 2>&1 | tail -1`.
  Expected: `--- N passed, 0 failed`. The pre-existing canary, `.errors[]`, zero-files and
  cap scenarios must still pass unchanged. Those guards are not touched.

- [ ] **Step 5: Commit.**

```bash
git add .github/actions/semgrep/scan.sh .github/actions/semgrep/action.yml scripts/test-sast-scan.sh
git commit -m "Report Semgrep by severity: high makes a finding, medium stays listed"
```

### Task 2: `zap_risk_counts` in `dast-common.sh`

**Files:**
- Modify: `.github/actions/dast/dast-common.sh` (append after `zap_tally_parse`)
- Create: `scripts/zap-fixture.sh` (a fixture builder shared by both DAST harnesses)
- Test: `scripts/test-dast-scan.sh` (a direct-call block, no docker)

**Interfaces:**
- Consumes the globals `failures` and `findings` set by `zap_tally_parse`.
- Produces `zap_risk_counts <console-file> <json-file> <err-fn>`, which sets the globals
  `risk_high`, `risk_medium`, `risk_low` and `risk_info`, or calls `<err-fn> "<reason>"`.
- Produces `zap_fixture <LEVEL> <ID> <RISK> ...` (in `scripts/zap-fixture.sh`), which sets
  `ZF_CONSOLE` and `ZF_JSON`.
  - `LEVEL` ∈ WARN | FAIL | IGNORE; `RISK` ∈ 0..3.
  - The tally counts one rule per WARN/FAIL entry, plus `IGNORE: <n>` for the IGNORE entries.
  - Every entry also goes into the JSON.

- [ ] **Step 1: Write the fixture builder and the failing scenarios.** Create
  `scripts/zap-fixture.sh`:

```bash
#!/usr/bin/env bash
# zap_fixture <LEVEL> <ID> <RISK> [<LEVEL> <ID> <RISK>]...
# Builds a console and a traditional-json report shaped like real ZAP output: one
# per-rule line per entry ("WARN-NEW: Rule <id> [<id>] x 2"), the tally counting
# rules, and site[].alerts[] with pluginid/riskcode. Sets ZF_CONSOLE and ZF_JSON.
# Sourced by test-dast-scan.sh and test-dast-api-scan.sh, never executed.
zap_fixture() {
    local lines="" alerts="[]" w=0 f=0 ig=0 level id risk
    while [ "$#" -ge 3 ]; do
        level="$1" id="$2" risk="$3"; shift 3
        case "$level" in
            WARN)   lines+="WARN-NEW: Rule ${id} [${id}] x 2"$'\n'; w=$((w + 1)) ;;
            FAIL)   lines+="FAIL-NEW: Rule ${id} [${id}] x 2"$'\n'; f=$((f + 1)) ;;
            IGNORE) lines+="IGNORE: Rule ${id} [${id}] x 2"$'\n'; ig=$((ig + 1)) ;;
        esac
        alerts=$(jq -c --arg id "$id" --arg r "$risk" '. + [{pluginid: $id, riskcode: $r, alert: ("Rule " + $id)}]' <<<"$alerts")
    done
    ZF_CONSOLE="${lines}FAIL-NEW: ${f}"$'\t'"FAIL-INPROG: 0"$'\t'"WARN-NEW: ${w}"$'\t'"WARN-INPROG: 0"$'\t'"INFO: 0"$'\t'"IGNORE: ${ig}"$'\t'"PASS: 30"
    ZF_JSON=$(jq -cn --argjson a "$alerts" '{site: [{"@name": "http://127.0.0.1", alerts: $a}]}')
}
```

  Append to `scripts/test-dast-scan.sh`, before its final summary line:

```bash
# --- zap_risk_counts, called directly ------------------------------------------------
. "$ROOT/scripts/zap-fixture.sh"
. "$ROOT/.github/actions/dast/dast-common.sh"
risk_err=""; risk_fail() { risk_err="$1"; }
risk_case() { # risk_case <name> <want "h m l i" | ERR> <json-override|-> <fixture args...>
    local name="$1" want="$2" json_override="$3"; shift 3
    zap_fixture "$@"
    printf '%s\n' "$ZF_CONSOLE" > "$WORK/rc-console"
    if [ "$json_override" = "-" ]; then printf '%s' "$ZF_JSON" > "$WORK/rc.json"
    elif [ "$json_override" = "MISSING" ]; then rm -f "$WORK/rc.json"
    else printf '%s' "$json_override" > "$WORK/rc.json"; fi
    risk_err=""; risk_high=; risk_medium=; risk_low=; risk_info=
    zap_tally_parse "$WORK/rc-console" risk_fail
    zap_risk_counts "$WORK/rc-console" "$WORK/rc.json" risk_fail
    local got="${risk_high} ${risk_medium} ${risk_low} ${risk_info}"
    [ -n "$risk_err" ] && got=ERR
    if [ "$got" = "$want" ]; then echo "ok   $name"; pass=$((pass + 1))
    else echo "FAIL $name — want '$want', got '$got' ${risk_err}"; fail=$((fail + 1)); fi
}

risk_case "risk comes from the JSON, one per rule" "1 1 1 1" - \
    WARN 40012 3  WARN 10038 2  WARN 10021 1  WARN 10109 0
# The novatalks.ui case of 2026-10-02: ZAP's report lists IGNOREd rules too.
risk_case "an IGNOREd rule in the JSON is not counted" "0 1 0 0" - \
    WARN 10038 2  IGNORE 10096 1  IGNORE 10110 1
risk_case "a FAIL rule is counted in its risk bucket" "1 0 0 0" - FAIL 90001 3
# Review Focus 2: the same pluginid on two sites counts once, at its highest risk.
risk_case "one rule on two sites counts once, highest risk" "0 1 0 0" \
    '{"site":[{"alerts":[{"pluginid":"10038","riskcode":"1"}]},{"alerts":[{"pluginid":"10038","riskcode":"2"}]}]}' \
    WARN 10038 2
risk_case "a missing JSON is a scanner error" ERR MISSING WARN 10038 2
risk_case "an unparseable JSON is a scanner error" ERR 'not json' WARN 10038 2
risk_case "a counted rule absent from the JSON is a scanner error" ERR '{"site":[]}' WARN 10038 2
risk_case "a clean run needs no alerts in the JSON" "0 0 0 0" '{"site":[]}'
# Per-rule lines and the tally must agree, or the join is not counting what ZAP counted.
zap_fixture WARN 10038 2
printf '%s\n' "${ZF_CONSOLE/WARN-NEW: 1/WARN-NEW: 3}" > "$WORK/rc-console"; printf '%s' "$ZF_JSON" > "$WORK/rc.json"
risk_err=""; zap_tally_parse "$WORK/rc-console" risk_fail; zap_risk_counts "$WORK/rc-console" "$WORK/rc.json" risk_fail
if [ -n "$risk_err" ]; then echo "ok   per-rule lines that disagree with the tally are a scanner error"; pass=$((pass + 1))
else echo "FAIL a tally of 3 with one per-rule line was accepted"; fail=$((fail + 1)); fi
```

- [ ] **Step 2: Run, confirm they fail.** Run
  `./scripts/test-dast-scan.sh 2>&1 | grep -E '^FAIL|^--- '`. Expected:
  `zap_risk_counts: command not found` on every `risk_case`.

- [ ] **Step 3: Implement.** Append to `.github/actions/dast/dast-common.sh`:

```bash
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
```

  Note: when `ids` is empty, `risks` is empty. `grep -c` on an empty here-string prints `0`,
  which gives the clean case `"0 0 0 0"`.

- [ ] **Step 4: Run, confirm green.** Run `./scripts/test-dast-scan.sh 2>&1 | tail -1`.
  Expected: `0 failed`. The existing scan scenarios don't call the function yet, so they are
  unchanged.

- [ ] **Step 5: Commit.**

```bash
git add .github/actions/dast/dast-common.sh scripts/zap-fixture.sh scripts/test-dast-scan.sh
git commit -m "Add zap_risk_counts: ZAP risk per counted rule, from -J joined with the console"
```

### Task 3: `dast/scan.sh` reports by risk

**Files:**
- Modify: `.github/actions/dast/scan.sh`: the `zap_out=` area (around line 82); the ZAP
  `docker run` (around line 507); everything from `zap_tally_parse "$zap_console" scanner_error`
  to the end
- Modify: `.github/actions/dast/action.yml` (`outputs:`)
- Test: `scripts/test-dast-scan.sh`

**Interfaces:**
- Consumes `zap_risk_counts` and `zap_fixture` from Task 2.
- Produces outputs `high`, `medium`, `low` and `informational`, plus `findings` = high + failures.

- [ ] **Step 1: Make the shim write the JSON, and write the failing scenarios.**
  - **The shim.** In the docker shim's `*zaproxy*)` arm in `scripts/test-dast-scan.sh`, before
    `exit`, add:

```bash
                jname=""; prev=""
                for a in "$@"; do [ "$prev" = "-J" ] && jname="$a"; prev="$a"; done
                if [ -n "$jname" ] && [ -z "${SHIM_ZAP_SKIP_JSON:-}" ]; then
                    printf '%s' "${SHIM_ZAP_JSON:-{\"site\":[]\}}" > "$(dirname "${SHIM_ZAP_OUT:?}")/$jname"
                fi
```

  - **Do not clear it per scenario.** Do **not** delete `zap.json` in `expect()`. A JSON left
    by the previous scenario is exactly the reused-runner case, and only `scan.sh`'s own
    `rm -f` may protect against it. A harness that cleans up for the scan would make the
    leftover scenario below pass vacuously.
  - **The new scenarios.** Append, after the Task 2 block:

```bash
# --- the scan reports by risk --------------------------------------------------------
zap_fixture WARN 10038 2  WARN 10021 1  WARN 10109 0  IGNORE 10096 1
SHIM_CURL_RC=0 SHIM_ZAP_RC=0 SHIM_ZAP_CONSOLE="$ZF_CONSOLE" SHIM_ZAP_JSON="$ZF_JSON" \
    expect "medium and low without high is clean" clean 0
if grep -q '🟢 clean · 1 medium · 1 low · 1 informational · 1 accepted' "$WORK/output"; then
    echo "ok   the clean line carries the risk breakdown"; pass=$((pass + 1))
else echo "FAIL the clean line"; sed 's/^/     /' "$WORK/output"; fail=$((fail + 1)); fi
if grep -qE '^-J zap\.json$|-J zap\.json( |$)' "$WORK/dockerlog"; then
    echo "ok   zap-baseline.py is asked for the JSON report"; pass=$((pass + 1))
else echo "FAIL no -J passed to ZAP"; fail=$((fail + 1)); fi

zap_fixture WARN 40012 3  WARN 10038 2
SHIM_CURL_RC=0 SHIM_ZAP_RC=0 SHIM_ZAP_CONSOLE="$ZF_CONSOLE" SHIM_ZAP_JSON="$ZF_JSON" \
    expect "a high-risk rule is a finding" findings 0
grep -q '🟠 HIGH found · 1 high · 1 medium · 0 low' "$WORK/output" \
    && { echo "ok   the high line"; pass=$((pass + 1)); } \
    || { echo "FAIL the high line"; sed 's/^/     /' "$WORK/output"; fail=$((fail + 1)); }

# Review Focus 4: a FAIL stays red and is not counted twice in findings.
zap_fixture FAIL 90001 3  WARN 10038 2
SHIM_CURL_RC=0 SHIM_ZAP_RC=1 SHIM_ZAP_CONSOLE="$ZF_CONSOLE" SHIM_ZAP_JSON="$ZF_JSON" \
    expect "a FAIL rule stays must-fix" findings 0
grep -q '🔴 1 must-fix · 1 high · 1 medium · 0 low' "$WORK/output" \
    && { echo "ok   the must-fix line"; pass=$((pass + 1)); } \
    || { echo "FAIL the must-fix line"; sed 's/^/     /' "$WORK/output"; fail=$((fail + 1)); }
assert_findings "findings is high plus failures, the FAIL rule counted once" 1

zap_fixture WARN 10038 2
SHIM_CURL_RC=0 SHIM_ZAP_RC=0 SHIM_ZAP_CONSOLE="$ZF_CONSOLE" SHIM_ZAP_SKIP_JSON=1 \
    expect "no JSON report is a scanner error" error 2

# Review Focus 1: a previous run's JSON on a reused runner is never read.
zap_fixture WARN 10038 2
printf '%s' "$ZF_JSON" > "$WORK/zap-wrk/zap.json"
SHIM_CURL_RC=0 SHIM_ZAP_RC=0 SHIM_ZAP_CONSOLE="$ZF_CONSOLE" SHIM_ZAP_SKIP_JSON=1 \
    expect "a leftover zap.json from an earlier run is not reused" error 2
```

  The stale file is written before `expect` and nothing in the harness removes it, so this
  scenario fails until `scan.sh` deletes the JSON before ZAP runs (step 3).

  - **Rewrite the existing fixtures** so the per-rule lines add up to the tally. Each one
    becomes a `zap_fixture` call:
    - `"ZAP warnings are findings, not failure" findings 0` (tally `WARN-NEW: 4`) becomes
      `zap_fixture WARN 10038 3 WARN 10020 2 WARN 10021 1 WARN 10063 1`, keeping
      `findings 0`. 10038 is high here, so it is a finding. Rename it
      `"a high ZAP warning is a finding, not a failure"`.
    - `"warnings are counted from the console stream, not the -w markdown report"`: keep
      its `SHIM_ZAP_MD`, replace the console with
      `zap_fixture WARN 10038 2 WARN 10020 2 WARN 10021 1`, and change the expectation to
      `clean 0`. Keep its assertion that the counts come from the console, now on
      `medium=2`/`low=1`.
    - `"a FAIL-level finding is a finding, not a broken scanner"`: replace with
      `zap_fixture FAIL 90001 3 FAIL 90002 3 WARN 10038 2 WARN 10020 2 WARN 10021 1 WARN 10063 1 WARN 10109 0`,
      then append `IGNORE 10096 1 IGNORE 10110 1 IGNORE 10027 0` so the summary's accepted
      count stays non-zero. Keep `findings 0`, `assert_failures … 2` and the `must-fix` grep.
      Change `assert_findings … 5` to `assert_findings … 4`, which is high 2 + failures 2.

- [ ] **Step 2: Run, confirm the new and rewritten scenarios fail.** Run
  `./scripts/test-dast-scan.sh 2>&1 | grep -E '^FAIL|^--- '`. Expected: the risk-line
  scenarios, the `-J` check, and both error cases (no JSON, leftover JSON) fail.

- [ ] **Step 3: Implement.**
  - **The JSON path.** Below `zap_out="${zap_work_dir}/zap.md"`, add
    `zap_json="${zap_work_dir}/zap.json"`.
  - **No stale reports.** Immediately before `set +e` / `docker run … "$zap_script"`, add:

```bash
# Both report files live in zap_work_dir, which outlives the job on a reused runner; a
# previous run's file must never stand in for one this ZAP did not write.
rm -f "$zap_out" "$zap_json"
```

  - **The `-J` flag.** In that `docker run`, change
    `-I -c "$(basename "$zap_conf")" -w "$(basename "$zap_out")"` to
    `-I -c "$(basename "$zap_conf")" -w "$(basename "$zap_out")" -J "$(basename "$zap_json")"`.
  - **The tail.** Replace everything from the existing `{ echo "===…" … } > "$DAST_REPORT_FILE"`
    block to the end of the file with:

```bash
zap_risk_counts "$zap_console" "$zap_json" scanner_error

{
    echo "=============================="
    echo " DAST: OWASP ZAP baseline"
    echo " Image:  ${DAST_IMAGE}"
    echo " Target: ${target}"
    echo "=============================="
    echo ""
    echo "must fix (FAIL):   ${failures}"
    echo "warnings (WARN):   ${findings}"
    echo "  by risk:         high ${risk_high} · medium ${risk_medium} · low ${risk_low} · informational ${risk_info}"
    echo "informational:     ${infos}"
    echo "accepted (IGNORE): ${accepted}"
    echo "passed:            ${passes}"
    echo ""
    cat "$zap_out"
} > "$DAST_REPORT_FILE"

emit failures "$failures"
emit high "$risk_high"
emit medium "$risk_medium"
emit low "$risk_low"
emit informational "$risk_info"
emit findings "$(( risk_high + failures ))"
breakdown="${risk_high} high · ${risk_medium} medium · ${risk_low} low"

if [ "$failures" -gt 0 ]; then
    echo "::warning::ZAP baseline reported ${failures} must-fix; by risk ${breakdown}. See ${DAST_REPORT_FILE}."
    emit outcome findings
    emit_message "🕷 DAST (ZAP): 🔴 ${failures} must-fix · ${breakdown}"$'\n'"   📄 Report: ${REPORT_URL:-n/a}"
    summary WARNING "🔴 ${failures} must-fix — the register marks these as blocking. By risk: ${breakdown}, ${risk_info} informational."
elif [ "$risk_high" -gt 0 ]; then
    echo "::warning::ZAP baseline reported ${risk_high} high-risk rule(s). See ${DAST_REPORT_FILE}."
    emit outcome findings
    emit_message "🕷 DAST (ZAP): 🟠 HIGH found · ${breakdown}"$'\n'"   📄 Report: ${REPORT_URL:-n/a}"
    summary WARNING "🟠 ${risk_high} high-risk rule(s) — review the report. Also ${risk_medium} medium, ${risk_low} low, ${risk_info} informational."
else
    emit outcome clean
    emit_message "🕷 DAST (ZAP): 🟢 clean · ${risk_medium} medium · ${risk_low} low · ${risk_info} informational · ${accepted} accepted"$'\n'"   📄 Report: ${REPORT_URL:-n/a}"
    summary NOTE "✅ No high-risk or must-fix findings. ${risk_medium} medium, ${risk_low} low and ${risk_info} informational are in the report; ${accepted} accepted by the triage register."
fi

echo "ZAP baseline — must-fix: ${failures}, warn rules: ${findings} (high ${risk_high}, medium ${risk_medium}, low ${risk_low}, informational ${risk_info}), accepted: ${accepted}, passed: ${passes}"
```

  - **The other emit paths.** In `not_run` and `scanner_error`, add `emit high 0`,
    `emit medium 0`, `emit low 0` and `emit informational 0` next to their existing zero emits.
  - **`action.yml`.** Add the `high`, `medium`, `low` and `informational` outputs, in the same
    shape as Task 1, with ZAP wording: "rules at ZAP risk High / Medium / Low / Informational,
    counted once each, IGNOREd rules excluded". Set `findings` to
    `"High-risk rules plus FAIL-level rules"`.

- [ ] **Step 4: Run, confirm green.** Run `./scripts/test-dast-scan.sh 2>&1 | tail -1`.
  Expected: `0 failed`. The tally anchor, exit ladder, not-run, NATS, env-file, overlay and
  register scenarios pass unchanged.

- [ ] **Step 5: Commit.**

```bash
git add .github/actions/dast/scan.sh .github/actions/dast/action.yml scripts/test-dast-scan.sh
git commit -m "Report the ZAP baseline by risk; findings only on High or a FAIL"
```

### Task 4: `dast-api/scan.sh` reports by risk

**Files:**
- Modify: `.github/actions/dast-api/scan.sh`: below `zap_out=` (around line 90); the ZAP
  `docker run` (around line 530); from `zap_tally_parse "$zap_console" scanner_error` to the end
- Modify: `.github/actions/dast-api/action.yml` (`outputs:`)
- Test: `scripts/test-dast-api-scan.sh`

**Interfaces:**
- Consumes `zap_risk_counts` (`dast-api/scan.sh` already sources `../dast/dast-common.sh`;
  confirm with `grep -n dast-common .github/actions/dast-api/scan.sh`) and `zap_fixture`.
- Produces the same four outputs as Task 3.

- [ ] **Step 1: The shim and the failing scenarios.**
  - **The shim.** In `scripts/test-dast-api-scan.sh`'s `*zaproxy*)` arm, add the same `-J`
    loop as in Task 3, writing to `$(dirname "${SHIM_ZAP_OUT:?}")/$jname`. As in Task
    3, do **not** clear `zap-api.json` in its `expect()`.
  - **The new scenarios.** Source the fixture builder (`. "$ROOT/scripts/zap-fixture.sh"`)
    and append:

```bash
zap_fixture WARN 10038 2  WARN 10021 1
SHIM_ZAP_RC=0 SHIM_ZAP_CONSOLE="$ZF_CONSOLE" SHIM_ZAP_JSON="$ZF_JSON" \
    expect "api-scan medium and low without high is clean" clean 0
grep -qE '🟢 clean · [0-9]+ operations · 1 medium · 1 low · 0 informational · 0 accepted' "$WORK/output" \
    && { echo "ok   the api clean line carries operations and the breakdown"; pass=$((pass + 1)); } \
    || { echo "FAIL the api clean line"; sed 's/^/     /' "$WORK/output"; fail=$((fail + 1)); }
grep -qx -- '-J' "$WORK/zap-argv" && grep -qx 'zap-api.json' "$WORK/zap-argv" \
    && { echo "ok   zap-api-scan.py is asked for the JSON report"; pass=$((pass + 1)); } \
    || { echo "FAIL no -J zap-api.json passed"; fail=$((fail + 1)); }

zap_fixture WARN 40012 3
SHIM_ZAP_RC=0 SHIM_ZAP_CONSOLE="$ZF_CONSOLE" SHIM_ZAP_JSON="$ZF_JSON" \
    expect "api-scan high is a finding" findings 0

zap_fixture WARN 10038 2
SHIM_ZAP_RC=0 SHIM_ZAP_CONSOLE="$ZF_CONSOLE" SHIM_ZAP_SKIP_JSON=1 \
    expect "api-scan without a JSON report is a scanner error" error 2
```

  - **Rewrite the existing fixtures.** The two existing fixtures with tally
    `FAIL-NEW: 2 … WARN-NEW: 5` ("api-scan warnings are findings, build green" and "login
    mode still injects Authorization: Bearer") become
    `zap_fixture FAIL 90001 3 FAIL 90002 3 WARN 10038 2 WARN 10020 2 WARN 10021 1 WARN 10063 1 WARN 10109 0`,
    keeping `findings 0` and their header assertions.

- [ ] **Step 2: Run, confirm they fail.** Run
  `./scripts/test-dast-api-scan.sh 2>&1 | grep -E '^FAIL|^--- '`.

- [ ] **Step 3: Implement.**
  - **The JSON path.** Add `zap_json="${zap_work_dir}/zap-api.json"` below `zap_out=`.
  - **No stale reports.** Add `rm -f "$zap_out" "$zap_json"` before `set +e`, with the
    Task 3 comment.
  - **The `-J` flag.** After `-w "$(basename "$zap_out")"`, add `-J "$(basename "$zap_json")"`.
  - **The tail.** Replace the tail with the Task 3 block, with these substitutions: header
    `DAST: OWASP ZAP API scan` with its existing `Image`/`Spec`/`Operations` lines; message
    prefix `🕷 DAST (ZAP API):`; the clean message
    `🟢 clean · ${op_count} operations · ${risk_medium} medium · ${risk_low} low · ${risk_info} informational · ${accepted} accepted`;
    log line prefix `ZAP API scan — operations: ${op_count}, …`; summary wording `api-scan`
    where Task 3 says `baseline`.
  - **The other emit paths.** Add the zero emits to `not_run` and `scanner_error`.
  - **`action.yml`.** Add the four outputs as in Task 3.

- [ ] **Step 4: Run, confirm green.** Run `./scripts/test-dast-api-scan.sh 2>&1 | tail -1`.
  Expected: `0 failed`. All auth-mode, `-z` quoting and spec scenarios pass unchanged.

- [ ] **Step 5: Commit.**

```bash
git add .github/actions/dast-api/scan.sh .github/actions/dast-api/action.yml scripts/test-dast-api-scan.sh
git commit -m "Report the ZAP API scan by risk, same join as the baseline"
```

### Task 5: Prove it on the real tools

**Files:** none changed. The numbers go into the PR description.

- [ ] **Step 1: Real ZAP output through `zap_risk_counts`.** Boot
  `ghcr.io/novaitdevteam/novatalks.ui:2026_R4_development_a0ce796d` and run the pinned ZAP
  image inside the Docker VM, with the overlay register. This is the same method as for
  nova.ci#84: on macOS, `scan.sh`'s own health check cannot reach `--network host`.

```bash
D=.github/actions/dast; Z=$(grep -oE 'ghcr.io/zaproxy/zaproxy:stable@sha256:[0-9a-f]+' $D/action.yml)
docker run -d --name nova-app --network host --platform linux/amd64 ghcr.io/novaitdevteam/novatalks.ui:2026_R4_development_a0ce796d
until [ "$(docker run --rm --network host curlimages/curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:8000/livez)" = 200 ]; do sleep 3; done
W=$(mktemp -d); chmod 777 "$W"; awk 1 $D/zap-baseline.conf $D/zap-baseline.novatalks.ui.conf > "$W/zap-baseline.conf"
docker run --rm --network host -v "$W:/zap/wrk:rw" "$Z" zap-baseline.py -t http://127.0.0.1:8000 -I -c zap-baseline.conf -w zap.md -J zap.json > "$W/console" 2>&1
docker rm -f nova-app
bash -c ". $D/dast-common.sh; e(){ echo ERR: \$1; }; zap_tally_parse $W/console e; zap_risk_counts $W/console $W/zap.json e; echo high=\$risk_high medium=\$risk_medium low=\$risk_low info=\$risk_info"
```

  Expected:
  - No `ERR:` line.
  - `high=0`.
  - medium + low + info = 9, the tally's `WARN-NEW: 9` from the 2026-10-02 overlay run. Record
    the exact split.
  - 10096 and 10110 absent from the counted IDs.

- [ ] **Step 2: Real Semgrep through the new `scan.sh`.** On a shallow clone of
  `novatalks.ui` `development`:

```bash
C=$(mktemp -d); gh repo clone novaitdevteam/novatalks.ui "$C/src" -- --depth 1 -b development
SEMGREP_IMAGE=$(grep -oE 'semgrep/semgrep:[0-9.]+@sha256:[0-9a-f]+' .github/actions/semgrep/action.yml) \
SEMGREP_CONFIGS="p/typescript p/nodejs p/owasp-top-ten" SEMGREP_SRC="$C/src" SEMGREP_REPORT_FILE="$C/report" \
SEMGREP_ACTION_ROOT="$PWD/.github/actions/semgrep" RUNNER_TEMP="$C" GITHUB_OUTPUT="$C/out" \
bash .github/actions/semgrep/scan.sh | tail -1; grep -E '^(high|medium|low|outcome)=' "$C/out"
```

  Expected: the canary fires, nothing from `.claude/`, and `high` ≥ 1 from `secrets-inherit`
  (Review Focus 5). Record the counts.

### Task 6: Docs, validation, PR

**Files:**
- Modify: `docs/security/sast-dast.md`: the Semgrep counting section and "Recording a decision
  about a finding"; the DAST outcomes section; the notifier-line paragraphs. Find them with
  `grep -nE 'ERROR and WARNING|warnings|🟡' docs/security/sast-dast.md`.
- Modify: `.claude/rules/code-scanning.md`, the line starting "Semgrep reports `ERROR` and
  `WARNING` as two counts".
- Modify: `.agents/skills/nova-ci/SKILL.md` and its mirror `.claude/skills/nova-ci/SKILL.md`,
  the notification semantics paragraph ("Compose SAST line and Compose DAST line").
- Modify: `.agents/skills/nova-ci/references/sast-and-deps-scan.md` and
  `references/dast-baseline.md`, plus their `.claude/skills/nova-ci/references/` copies.
- Modify: the spec's "What the reader gets" table: the DAST line gains
  `· N informational · A accepted`.

- [ ] **Step 1: The rule.** Replace the `code-scanning.md` line with:

```markdown
- Semgrep reports by Semgrep's own severity mapping: `ERROR`/native `CRITICAL`/`HIGH` → high, `WARNING`/`MEDIUM` → medium, `INFO`/`LOW` → low, anything else → high with a warning. `outcome=findings` follows high only. **High and Medium are counted and listed on every run, clean or not**: the old exact-equality filter hid 12 `WARNING` findings on `novatalks.core` from the count *and* the report, and a severity filter that drops Medium from either is that defect again. ZAP reports risk per counted rule through `zap_risk_counts` (`dast-common.sh`): which rules count comes from the console's `WARN-NEW`/`FAIL-NEW` lines, their risk from the `-J` JSON. Never count risk from the report alone, because it lists `IGNORE`d rules too. A missing JSON, a counted rule without a risk, or per-rule lines that disagree with the tally are scanner errors.
```

- [ ] **Step 2: The docs pages.** Update the sections listed above to the new line format and
  outcomes, quoting the Task 5 numbers as the worked example. Keep the mirrors identical:
  `git diff --no-index --quiet .agents/skills/nova-ci .claude/skills/nova-ci`.

- [ ] **Step 3: Validate.** Run `./scripts/validate.sh`. Every section must be green up to
  actionlint. If actionlint hangs locally (known), stop it and rely on CI's.

- [ ] **Step 4: Commit and open the PR.**

```bash
git add docs .claude/rules .agents/skills .claude/skills
git commit -m "Document severity lines for SAST and DAST"
git push -u origin feat/scanner-severity-lines
gh pr create --base main --title "SAST and DAST lines by severity, like Trivy" --body-file <pr-body.md>
```

  The PR body must state:
  - the Task 5 real numbers;
  - that `secrets-inherit` now reads as High in every product repository until callers carry
    `nosemgrep` (Review Focus 5);
  - that `ci-dast-live-baseline.yaml` calls ZAP itself and keeps its old line.

  **Do not merge** without the user's explicit go-ahead.
