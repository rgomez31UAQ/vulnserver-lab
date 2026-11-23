#!/usr/bin/env bash
# =============================================================================
# VulnServer - scripts/scenarios/scenario-b.sh
# SCENARIO B - Insecure sudo configuration
#
# What is intentionally broken
#   1. labuser may run /usr/bin/tar (and cat) as the intermediate account
#      labpriv, without a password. tar's --checkpoint-action can execute a
#      command, so labuser obtains a shell as labpriv.
#   2. labpriv may run /usr/local/bin/lab-healthcheck as root, without a
#      password - and that helper is group-writable by labpriv. labpriv
#      therefore controls a script that root executes.
#
# Result: labuser -> labpriv (PRIVILEGE flag) -> root (ROOT flag).
#
#   ./scenario-b.sh activate | deactivate | status | verify
# =============================================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../../lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

require_root "$@"
SCENARIO_ID="B"

write_helper() {
    # Benign maintenance helper, root-owned but writable by labpriv (0774).
    install -m 0755 -o root -g root /dev/null "$SCENARIO_B_HELPER"
    cat > "$SCENARIO_B_HELPER" <<'EOF'
#!/usr/bin/env bash
# lab-healthcheck - executed by root through sudo (scenario B).
# Legitimate purpose: report disk and memory pressure to the monitoring log.
set -euo pipefail
{
    printf 'healthcheck %s\n' "$(date -Is)"
    df -h / | tail -n1
    free -m | awk 'NR==2 {print "mem_used_mb=" $3 " mem_free_mb=" $4}'
} >> /var/log/lab-healthcheck.log
EOF
    chown "root:${PRIV_USER}" "$SCENARIO_B_HELPER"
    chmod 0774 "$SCENARIO_B_HELPER"
}

write_sudoers() {
    local tmp; tmp="$(mktemp)"
    cat > "$tmp" <<EOF
# VulnServer scenario B - DELIBERATELY INSECURE sudo policy.
# Two separate mistakes:
#   * over-broad delegation to an intermediate account (tar can execute code)
#   * a root-executed helper that the delegated account can modify
${LAB_USER}   ALL=(${PRIV_USER}) NOPASSWD: /usr/bin/tar, /usr/bin/cat
${PRIV_USER}  ALL=(root) NOPASSWD: ${SCENARIO_B_HELPER}
EOF
    if ! visudo -cqf "$tmp" >/dev/null 2>&1; then
        rm -f "$tmp"
        die "scenario B sudoers file failed validation - host policy untouched"
    fi
    install -m 0440 -o root -g root "$tmp" "$SCENARIO_B_SUDOERS"
    rm -f "$tmp"
}

activate() {
    id "$PRIV_USER" >/dev/null 2>&1 || die "intermediate user ${PRIV_USER} missing; run install.sh"
    getent group "$PRIV_USER" >/dev/null 2>&1 || die "group ${PRIV_USER} missing; run install.sh"
    check_deps visudo || die "visudo not found"

    local rp; rp="$(create_restore_point "$SCENARIO_ID")" || warn "restore point not created"
    write_helper
    write_sudoers
    scenario_set_state "b" active
    log_event "SCENARIO_ACTIVATE" "sudo" "$SCENARIO_ID" "SUCCESS" \
        "sudoers=${SCENARIO_B_SUDOERS} helper=${SCENARIO_B_HELPER} restore_point=${rp:-none}"
    ok "Scenario B active: ${LAB_USER} -> ${PRIV_USER} -> root"
    dim "Automated check: $0 verify"
}

deactivate() {
    run_cmd rm -f "$SCENARIO_B_SUDOERS"
    if [[ -e "$SCENARIO_B_HELPER" ]]; then
        run_cmd chown root:root "$SCENARIO_B_HELPER"
        run_cmd chmod 0755 "$SCENARIO_B_HELPER"
    fi
    scenario_set_state "b" inactive
    log_event "SCENARIO_DEACTIVATE" "sudo" "$SCENARIO_ID" "SUCCESS" "sudoers removed, helper secured"
    ok "Scenario B deactivated (sudoers rule removed, helper 0755 root:root)"
}

status() {
    printf 'Scenario B - insecure sudo configuration\n'
    printf '  state file   : %s\n' "$(scenario_is_active b && echo active || echo inactive)"
    printf '  sudoers file : %s\n' "$([[ -e "$SCENARIO_B_SUDOERS" ]] && echo present || echo absent)"
    printf '  helper       : %s\n' "$(stat -c '%A %U:%G %n' "$SCENARIO_B_HELPER" 2>/dev/null || echo absent)"
    hr
    printf 'Effective sudo rights of %s:\n' "$LAB_USER"
    sudo -l -U "$LAB_USER" 2>/dev/null | sed -n '/may run/,$p' || true
}

verify() {
    local fail=0
    if [[ -f "$SCENARIO_B_SUDOERS" ]] && grep -q "NOPASSWD" "$SCENARIO_B_SUDOERS"; then
        printf '  sudoers rule present        PASS (vulnerable, as configured)\n'
    else
        printf '  sudoers rule present        FAIL\n'; fail=1
    fi
    if [[ "$(stat -c '%a' "$SCENARIO_B_HELPER" 2>/dev/null)" == "774" ]] &&
       [[ "$(stat -c '%G' "$SCENARIO_B_HELPER" 2>/dev/null)" == "$PRIV_USER" ]]; then
        printf '  root helper group-writable  PASS (vulnerable, as configured)\n'
    else
        printf '  root helper group-writable  FAIL\n'; fail=1
    fi
    (( fail == 0 )) && ok "Scenario B is active" || warn "Scenario B is not fully active"
    return $fail
}

case "${1:-status}" in
    activate)   activate ;;
    deactivate) deactivate ;;
    status)     status ;;
    verify)     verify ;;
    *) die "usage: $0 {activate|deactivate|status|verify}" ;;
esac
