#!/usr/bin/env bash
# =============================================================================
# VulnServer - uninstall.sh
# Reverses install.sh as far as possible.
#
#   sudo ./uninstall.sh              # interactive, step by step
#   sudo ./uninstall.sh --yes        # accept every prompt (keeps backups)
#   sudo ./uninstall.sh --purge      # also delete logs, flags, backups, reports
#   sudo ./uninstall.sh --purge --remove-users
#
# By default it keeps: backups, flags, reports and the adminlab account, so an
# accidental run cannot destroy the owner's recovery path or evidence.
# =============================================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

PURGE=0; REMOVE_USERS=0; REMOVE_IMAGE=0
while (( $# > 0 )); do
    case "$1" in
        -y|--yes)        ASSUME_YES=1; shift ;;
        -n|--dry-run)    DRY_RUN=1; shift ;;
        --purge)         PURGE=1; shift ;;
        --remove-users)  REMOVE_USERS=1; shift ;;
        --remove-image)  REMOVE_IMAGE=1; shift ;;
        -h|--help)       sed -n '2,20p' "$0"; exit 0 ;;
        *) die "unknown option: $1" ;;
    esac
done
export ASSUME_YES DRY_RUN

require_root "$@"
banner
warn "This will stop and remove the VulnServer laboratory components."
confirm "Continue with uninstallation?" || { info "aborted"; exit 0; }
log_event "UNINSTALL_START" "core" "-" "STARTED" "purge=${PURGE} remove_users=${REMOVE_USERS}"

# ---------------------------------------------------------------------------
# 1. Stop the web application
# ---------------------------------------------------------------------------
stop_web() {
    if [[ -f "$LAB_WEB_DIR/docker-compose.yml" ]] && docker_ready; then
        info "Stopping Juice Shop"
        ( cd "$LAB_WEB_DIR" && run_cmd docker compose down --remove-orphans ) \
            || warn "docker compose down reported an error"
        if (( REMOVE_IMAGE == 1 )); then
            run_cmd docker rmi "$JUICE_SHOP_IMAGE" >/dev/null 2>&1 || true
        fi
        if (( PURGE == 1 )); then
            confirm "Delete the Juice Shop data volume ${JUICE_SHOP_VOLUME}?" && \
                run_cmd docker volume rm "$JUICE_SHOP_VOLUME" >/dev/null 2>&1 || true
        fi
    else
        dim "no compose file or Docker unavailable - nothing to stop"
    fi
}

# ---------------------------------------------------------------------------
# 2. Deactivate scenarios
# ---------------------------------------------------------------------------
deactivate_scenarios() {
    local id script
    for id in a b c; do
        script="$SCRIPT_DIR/scripts/scenarios/scenario-${id}.sh"
        [[ -x "$script" ]] || continue
        info "Deactivating scenario ${id^^}"
        "$script" deactivate || warn "scenario ${id} deactivation incomplete"
    done
}

remove_scenario_artifacts() {
    info "Removing scenario artifacts"
    # Scenario B helper
    [[ -e "$SCENARIO_B_HELPER" ]] && run_cmd rm -f "$SCENARIO_B_HELPER"
    # Scenario C script and drop-in
    [[ -e "$SCENARIO_C_CRON" ]] && run_cmd rm -f "$SCENARIO_C_CRON"
    [[ -e "$SCENARIO_C_SCRIPT" ]] && run_cmd rm -f "$SCENARIO_C_SCRIPT"
    # Scenario A directory content
    [[ -d "$LAB_DATA_DIR/perms" ]] && run_cmd rm -rf "${LAB_DATA_DIR:?}/perms"/* 2>/dev/null || true
    rm -f "$LAB_STATE_STATE_DIR"/scenario-*.state 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# 3. Sudoers / cron / ssh / auditd
# ---------------------------------------------------------------------------
remove_system_config() {
    info "Restoring system configuration"
    run_cmd rm -f /etc/sudoers.d/vulnserver-base /etc/sudoers.d/vulnserver-lab-*
    command -v visudo >/dev/null 2>&1 && visudo -c >/dev/null 2>&1 || warn "sudoers validation reported an issue"

    run_cmd rm -f /etc/cron.d/vulnserver-lab-*

    if [[ -f /etc/ssh/sshd_config.d/99-vulnserver.conf ]]; then
        run_cmd rm -f /etc/ssh/sshd_config.d/99-vulnserver.conf
        if command -v sshd >/dev/null 2>&1 && sshd -t; then
            systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null || true
        fi
    fi

    if [[ -f "$AUDIT_RULES_FILE" ]]; then
        run_cmd rm -f "$AUDIT_RULES_FILE"
        command -v augenrules >/dev/null 2>&1 && run_cmd augenrules --load >/dev/null 2>&1 || true
    fi

    # Remove our UFW rules but leave the firewall in whatever state it was.
    if command -v ufw >/dev/null 2>&1; then
        ufw status numbered 2>/dev/null | awk '/vulnserver/ {print $1}' | tr -d '[]' | sort -rn |
            while read -r n; do run_cmd ufw --force delete "$n" >/dev/null 2>&1 || true; done
    fi
}

# ---------------------------------------------------------------------------
# 4. Accounts
# ---------------------------------------------------------------------------
remove_accounts() {
    (( REMOVE_USERS == 1 )) || { dim "keeping lab accounts (use --remove-users)"; return 0; }
    confirm "Delete ${LAB_USER} and ${PRIV_USER} including home directories?" || return 0
    local name
    for name in "$LAB_USER" "$PRIV_USER"; do
        id "$name" >/dev/null 2>&1 && run_cmd userdel -r "$name" 2>/dev/null || true
    done
    warn "${ADMIN_USER} kept (recovery account)"
}

# ---------------------------------------------------------------------------
# 5. State directory
# ---------------------------------------------------------------------------
remove_state() {
    if (( PURGE == 1 )); then
        confirm "Delete ${LAB_STATE_DIR} entirely (logs, flags, reports, backups)?" || {
            warn "state directory kept"; return 0; }
        # Logging must stop before deletion: otherwise log_event would recreate
        # the log directory it just removed.
        export VULNSERVER_LOGGING_DISABLED=1
        run_cmd rm -rf "$LAB_STATE_DIR"
    else
        info "Removing toolchain, keeping logs/flags/reports/backups"
        run_cmd rm -rf "$LAB_BIN_DIR" "$LAB_WEB_DIR"
        chmod 0700 "$LAB_BACKUP_DIR" 2>/dev/null || true
    fi
}

main() {
    stop_web
    deactivate_scenarios
    remove_scenario_artifacts
    remove_system_config
    remove_accounts
    remove_state
    log_event "UNINSTALL_COMPLETE" "core" "-" "SUCCESS" "purge=${PURGE}"
    ok "Uninstallation finished"
    (( PURGE == 1 )) || dim "Backups in ${LAB_BACKUP_DIR} and reports in ${LAB_REPORT_DIR} were preserved"
}
main
