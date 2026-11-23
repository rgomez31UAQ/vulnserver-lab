#!/usr/bin/env bash
# =============================================================================
# VulnServer - scripts/monitoring/report.sh
# Builds a Markdown report of laboratory activity from the event log.
#
#   ./report.sh                 # last 7 days -> reports/lab-report-<ts>.md
#   ./report.sh --days 30       # different window
#   ./report.sh --stdout        # print instead of writing a file
#
# The report never prints flag values: evidence must be collected by the
# students themselves. It only records who did what, and when.
# =============================================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../../lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

days=7
to_stdout=0
while (( $# > 0 )); do
    case "$1" in
        --days)   days="${2:?--days needs a number}"; shift 2 ;;
        --stdout) to_stdout=1; shift ;;
        *) die "usage: $0 [--days N] [--stdout]" ;;
    esac
done
[[ "$days" =~ ^[0-9]+$ ]] || die "--days must be an integer"

since_epoch=$(( $(date +%s) - days*86400 ))

# Parse the JSONL log with jq when available, otherwise fall back to grep.
collect() { # <event-prefix-regex>
    local re="$1"
    if [[ ! -r "$LAB_EVENT_LOG" ]]; then return 0; fi
    if command -v jq >/dev/null 2>&1; then
        jq -r --arg re "$re" --argjson since "$since_epoch" '
            select(.event | test($re))
            | (try (.timestamp | strptime("%Y-%m-%d %H:%M:%S") | mktime) catch 0) as $t
            | select($t >= $since)
            | "\(.timestamp)\t\(.actor)\t\(.event)\t\(.scenario)\t\(.result)\t\(.detail)"' \
            "$LAB_EVENT_LOG" 2>/dev/null || true
    else
        grep -E "\"event\":\"${re}\"" "$LAB_EVENT_LOG" 2>/dev/null || true
    fi
}

generate() {
    local ts; ts="$(date +"$LAB_TS_FORMAT")"
    local scenarios_state=""
    local id
    for id in a b c; do
        if scenario_is_active "$id"; then scenarios_state+="$(scenario_label "$id")=active "; else scenarios_state+="$(scenario_label "$id")=inactive "; fi
    done

    {
        printf '# VulnServer - Laboratory activity report\n\n'
        printf -- '- Generated: %s\n' "$ts"
        printf -- '- Host: %s\n' "$(hostname)"
        printf -- '- Window: last %s day(s)\n' "$days"
        printf -- '- Scenarios: %s\n\n' "${scenarios_state:-unknown}"

        printf '## Summary of events\n\n'
        printf '| Event | Count |\n|---|---|\n'
        if [[ -r "$LAB_EVENT_LOG" ]] && command -v jq >/dev/null 2>&1; then
            jq -r '.event' "$LAB_EVENT_LOG" 2>/dev/null | sort | uniq -c |
                sort -rn | awk '{printf "| %s | %s |\n", $2, $1}'
        else
            printf '| (no event log) | 0 |\n'
        fi
        printf '\n'

        for section in "Laboratory lifecycle:^(INSTALL|UNINSTALL|RESET|HARDEN|AUDIT)" \
                       "Scenario changes:^SCENARIO" \
                       "Flag operations:^FLAGS" \
                       "Service and firewall:^(SERVICE|FIREWALL|DOCKER)" \
                       "Errors and failures:^(ERROR)"; do
            local title="${section%%:*}" re="${section#*:}"
            printf '## %s\n\n' "$title"
            local rows; rows="$(collect "$re")"
            if [[ -z "$rows" ]]; then
                printf '_No events in this window._\n\n'
            else
                printf '| Timestamp | Actor | Event | Scenario | Result | Detail |\n'
                printf '|---|---|---|---|---|---|\n'
                printf '%s\n' "$rows" | awk -F'\t' '{printf "| %s | %s | %s | %s | %s | %s |\n", $1,$2,$3,$4,$5,$6}'
                printf '\n'
            fi
        done

        printf '## Evidence handling\n\n'
        printf 'Flag values are intentionally omitted from this report. Students must\n'
        printf 'submit the flag identifiers they recovered together with a timestamped\n'
        printf 'screenshot or command transcript, as described in the attacker guide.\n'
    } > "${TMP_REPORT:-/dev/stdout}"
}

if (( to_stdout == 1 )); then
    TMP_REPORT="" generate
else
    mkdir -p "$LAB_REPORT_DIR" 2>/dev/null || die "cannot create ${LAB_REPORT_DIR}"
    out="${LAB_REPORT_DIR}/lab-report-$(timestamp_slug).md"
    # generate() writes to ${TMP_REPORT}
    TMP_REPORT="$out" generate
    chmod 0640 "$out" 2>/dev/null || true
    log_event "REPORT_GENERATE" "monitoring" "-" "SUCCESS" "file=${out} days=${days}"
    ok "Report written to ${out}"
fi
