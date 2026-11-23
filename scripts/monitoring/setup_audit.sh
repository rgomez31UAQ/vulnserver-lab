#!/usr/bin/env bash
# =============================================================================
# VulnServer - scripts/monitoring/setup_audit.sh
# Installs the auditd rules that record activity inside the lab.
#
#   ./setup_audit.sh apply    # write rules and load them
#   ./setup_audit.sh status   # show auditd state and loaded rules
#   ./setup_audit.sh remove   # remove the rules (keeps auditd installed)
#
# What is audited
#   * identity files: /etc/passwd, /etc/shadow, /etc/group, sudoers
#   * lab flags: reads/writes/attribute changes
#   * lab data, cron drop-ins, helper scripts
#   * process execution by labuser and labpriv
#   * privilege escalation syscalls (setuid/setgid family)
# =============================================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../../lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

require_root "$@"
action="${1:-apply}"

apply_rules() {
    check_deps auditctl || die "auditd is not installed (apt-get install auditd audispd-plugins)"

    local tmp; tmp="$(mktemp)"
    cat > "$tmp" <<EOF
## VulnServer audit rules - managed by scripts/monitoring/setup_audit.sh
## Identity and authorisation changes
-w /etc/passwd -p wa -k vulnserver_identity
-w /etc/shadow -p wa -k vulnserver_identity
-w /etc/group  -p wa -k vulnserver_identity
-w /etc/sudoers -p wa -k vulnserver_sudo
-w /etc/sudoers.d -p wa -k vulnserver_sudo

## Flags and lab material
-w ${LAB_FLAG_DIR} -p rwa -k vulnserver_flags
-w ${LAB_DATA_DIR} -p rwa -k vulnserver_labdata
-w ${LAB_STATE_DIR}/state -p wa -k vulnserver_state

## Scheduled tasks and privileged helpers
-w /etc/cron.d -p wa -k vulnserver_cron
-w /etc/crontab -p wa -k vulnserver_cron
-w ${SCENARIO_B_HELPER} -p wa -k vulnserver_sudo

## Interactive activity of the lab accounts
-a always,exit -F arch=b64 -S execve -F auid>=1000 -F auid!=4294967295 -k vulnserver_exec
-a always,exit -F arch=b32 -S execve -F auid>=1000 -F auid!=4294967295 -k vulnserver_exec

## Privilege transitions
-a always,exit -F arch=b64 -S setuid,setgid,setreuid,setregid,setresuid,setresgid -k vulnserver_privchange
## SUID/SGID execution
-a always,exit -F arch=b64 -S execve -C uid!=euid -F euid=0 -k vulnserver_suid_exec
EOF

    install -d -m 0750 -o root -g root /etc/audit/rules.d
    install -m 0640 -o root -g root "$tmp" "$AUDIT_RULES_FILE"
    rm -f "$tmp"

    if has_systemd; then
        run_cmd systemctl enable --now auditd >/dev/null 2>&1 || warn "could not enable auditd"
    fi
    if command -v augenrules >/dev/null 2>&1; then
        run_cmd augenrules --load >/dev/null 2>&1 || warn "augenrules --load reported an error"
    else
        run_cmd auditctl -R "$AUDIT_RULES_FILE" || warn "auditctl -R reported an error"
    fi
    log_event "AUDIT_RULES_APPLY" "auditd" "-" "SUCCESS" "rules=${AUDIT_RULES_FILE}"
    ok "auditd rules installed (${AUDIT_RULES_FILE})"
}

status_rules() {
    if service_active auditd; then ok "auditd: active"; else warn "auditd: not running"; fi
    hr
    if command -v auditctl >/dev/null 2>&1; then
        auditctl -l 2>/dev/null | grep -c . | xargs -r printf 'loaded rules: %s\n'
        auditctl -l 2>/dev/null | grep vulnserver | head -n 20 || dim "no vulnserver rules loaded"
    else
        warn "auditctl not installed"
    fi
    hr
    printf 'Recent audited events (last 20):\n'
    if command -v ausearch >/dev/null 2>&1; then
        ausearch -ts recent -k vulnserver_flags 2>/dev/null | tail -n 20 || dim "  none"
    else
        dim "  ausearch not available"
    fi
}

case "$action" in
    apply)  apply_rules ;;
    status) status_rules ;;
    remove)
        confirm "Remove VulnServer audit rules?" || exit 1
        run_cmd rm -f "$AUDIT_RULES_FILE"
        command -v augenrules >/dev/null 2>&1 && run_cmd augenrules --load >/dev/null 2>&1 || true
        log_event "AUDIT_RULES_REMOVE" "auditd" "-" "SUCCESS" "rules removed"
        ;;
    *) die "usage: $0 {apply|status|remove}" ;;
esac
