#!/usr/bin/env bash
# =============================================================================
# VulnServer - scripts/scenarios/scenario-c.sh
# SCENARIO C - Insecure cron job
#
# What is intentionally broken
#   * A root cron job runs $SCENARIO_C_SCRIPT every minute.
#   * The directory that contains the script is mode 0777, so any local user can
#     replace the script (rename attack) and have root execute their code.
#
# Result: any local user (labuser) -> root.
#
#   ./scenario-c.sh activate | deactivate | status | verify
# =============================================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../../lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

require_root "$@"
SCENARIO_ID="C"

write_script() {
    install -d -m 0755 -o root -g root "$SCENARIO_C_DIR"
    install -m 0755 -o root -g root /dev/null "$SCENARIO_C_SCRIPT"
    cat > "$SCENARIO_C_SCRIPT" <<'EOF'
#!/usr/bin/env bash
# lab-cleanup.sh - executed as root by /etc/cron.d/vulnserver-lab-c.
# Legitimate purpose: rotate the lab's temporary exports directory.
set -euo pipefail
echo "[$(date -Is)] lab-cleanup run by uid=$(id -u)" >> /var/log/lab-cleanup.log
EOF
}

write_cron() {
    local tmp; tmp="$(mktemp)"
    cat > "$tmp" <<EOF
# VulnServer scenario C - DELIBERATELY INSECURE cron job.
# Runs as root, from a directory that any local user can write to.
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
${SCENARIO_C_SCHEDULE} root ${SCENARIO_C_SCRIPT} >/dev/null 2>&1
EOF
    install -m 0644 -o root -g root "$tmp" "$SCENARIO_C_CRON"
    rm -f "$tmp"
}

activate() {
    check_deps cron || die "cron is not installed"
    local rp; rp="$(create_restore_point "$SCENARIO_ID")" || warn "restore point not created"
    write_script
    write_cron
    chmod 0777 "$SCENARIO_C_DIR"
    if has_systemd; then systemctl is-active --quiet cron || systemctl start cron || warn "cron not started"; fi
    scenario_set_state "c" active
    log_event "SCENARIO_ACTIVATE" "cron" "$SCENARIO_ID" "SUCCESS" \
        "cron_file=${SCENARIO_C_CRON} script=${SCENARIO_C_SCRIPT} dir_mode=0777 restore_point=${rp:-none}"
    ok "Scenario C active: root cron executes ${SCENARIO_C_SCRIPT} every minute"
    warn "The directory ${SCENARIO_C_DIR} is world-writable (intentional)"
    dim "Automated check: $0 verify"
}

deactivate() {
    run_cmd rm -f "$SCENARIO_C_CRON"
    [[ -d "$SCENARIO_C_DIR" ]] && run_cmd chmod 0755 "$SCENARIO_C_DIR"
    scenario_set_state "c" inactive
    log_event "SCENARIO_DEACTIVATE" "cron" "$SCENARIO_ID" "SUCCESS" "cron file removed, dir 0755"
    ok "Scenario C deactivated (cron drop-in removed, directory 0755)"
}

status() {
    printf 'Scenario C - insecure cron job\n'
    printf '  state file   : %s\n' "$(scenario_is_active c && echo active || echo inactive)"
    printf '  cron drop-in : %s\n' "$([[ -e "$SCENARIO_C_CRON" ]] && echo present || echo absent)"
    printf '  script       : %s\n' "$(stat -c '%A %U:%G %n' "$SCENARIO_C_SCRIPT" 2>/dev/null || echo absent)"
    printf '  script dir   : %s\n' "$(stat -c '%A %U:%G %n' "$SCENARIO_C_DIR" 2>/dev/null || echo absent)"
    [[ -r /var/log/lab-cleanup.log ]] && { hr; tail -n 3 /var/log/lab-cleanup.log; }
}

verify() {
    local fail=0
    if [[ -e "$SCENARIO_C_CRON" ]] && grep -q "root ${SCENARIO_C_SCRIPT}" "$SCENARIO_C_CRON"; then
        printf '  root cron job present       PASS (vulnerable, as configured)\n'
    else
        printf '  root cron job present       FAIL\n'; fail=1
    fi
    if [[ "$(stat -c '%a' "$SCENARIO_C_DIR" 2>/dev/null)" == "777" ]]; then
        printf '  world-writable script dir   PASS (vulnerable, as configured)\n'
    else
        printf '  world-writable script dir   FAIL\n'; fail=1
    fi
    (( fail == 0 )) && ok "Scenario C is active" || warn "Scenario C is not fully active"
    return $fail
}

case "${1:-status}" in
    activate)   activate ;;
    deactivate) deactivate ;;
    status)     status ;;
    verify)     verify ;;
    *) die "usage: $0 {activate|deactivate|status|verify}" ;;
esac
