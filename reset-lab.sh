#!/usr/bin/env bash
# =============================================================================
# VulnServer - reset-lab.sh
# Returns the laboratory to a clean, known state between exercises.
#
#   sudo ./reset-lab.sh                 # interactive reset
#   sudo ./reset-lab.sh --yes           # non-interactive
#   sudo ./reset-lab.sh --keep-logs     # do not archive/truncate the event log
#   sudo ./reset-lab.sh --no-restart    # do not restart Juice Shop afterwards
#
# What it does
#   1. deactivates every scenario and removes their artifacts
#   2. re-applies the secure baseline (permissions, sudo, cron)
#   3. removes practice data (labuser home artefacts, Juice Shop volume)
#   4. archives the current logs into backups/, then rotates them
#   5. regenerates the three flags with new random values
#   6. restarts the web application
#
# Administrative backups (backups/) are never deleted by this script.
# =============================================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

KEEP_LOGS=0; RESTART=1
while (( $# > 0 )); do
    case "$1" in
        -y|--yes)     ASSUME_YES=1; shift ;;
        -n|--dry-run) DRY_RUN=1; shift ;;
        --keep-logs)  KEEP_LOGS=1; shift ;;
        --no-restart) RESTART=0; shift ;;
        -h|--help)    sed -n '2,20p' "$0"; exit 0 ;;
        *) die "unknown option: $1" ;;
    esac
done
export ASSUME_YES DRY_RUN

require_root "$@"
banner
warn "This destroys laboratory state: flags are rotated and practice data is removed."
confirm "Reset the laboratory now?" || { info "aborted"; exit 0; }
log_event "RESET_START" "core" "-" "STARTED" "keep_logs=${KEEP_LOGS}"

# ---------------------------------------------------------------------------
reset_deactivate() {
    local id script
    for id in a b c; do
        script="$SCRIPT_DIR/scripts/scenarios/scenario-${id}.sh"
        if [[ -x "$script" ]]; then
            info "Deactivating scenario ${id^^}"
            "$script" deactivate || warn "scenario ${id} deactivation incomplete"
        fi
    done
    # Remove artifacts that may have been left behind by student activity.
    rm -f "$SCENARIO_C_CRON" "$SCENARIO_C_SCRIPT" "$SCENARIO_B_HELPER" 2>/dev/null || true
    rm -f /etc/sudoers.d/vulnserver-lab-* 2>/dev/null || true
    run_cmd rm -f "$LAB_STATE_STATE_DIR"/scenario-*.state 2>/dev/null || true
}

reset_baseline() {
    info "Re-applying the secure baseline"
    "$SCRIPT_DIR/scripts/permissions/apply_permissions.sh" base
    "$SCRIPT_DIR/scripts/sudo/apply_sudo.sh" base
    "$SCRIPT_DIR/scripts/sudo/apply_sudo.sh" validate || warn "sudoers validation reported an issue"
    "$SCRIPT_DIR/scripts/cron/apply_cron.sh" base || warn "cron baseline incomplete"
}

reset_practice_data() {
    info "Removing practice data"
    if [[ -d "/home/${LAB_USER}" ]]; then
        # Keep the account skeleton (.bashrc, .profile); remove everything else
        # the student created or dropped during the exercise.
        find "/home/${LAB_USER}" -mindepth 1 -maxdepth 1 \
            ! -name '.bashrc' ! -name '.profile' ! -name '.bash_logout' \
            -exec rm -rf {} + 2>/dev/null || true
        chown -R "${LAB_USER}:${LAB_USER}" "/home/${LAB_USER}" 2>/dev/null || true
    fi
    # Restore the fictional notes that Scenario A may have referenced.
    rm -rf "${LAB_DATA_DIR:?}/notes" 2>/dev/null || true
    "$SCRIPT_DIR/scripts/permissions/apply_permissions.sh" base >/dev/null

    if docker_ready && [[ -f "$LAB_WEB_DIR/docker-compose.yml" ]]; then
        ( cd "$LAB_WEB_DIR" && run_cmd docker compose down -v >/dev/null 2>&1 ) || \
            warn "could not remove the Juice Shop volume"
    fi
}

reset_logs() {
    if (( KEEP_LOGS == 1 )); then
        dim "logs kept (--keep-logs)"; return 0
    fi
    info "Archiving and rotating logs"
    if [[ -s "$LAB_EVENT_LOG" ]]; then
        local archive="${LAB_BACKUP_DIR}/logs-$(timestamp_slug).tar.gz"
        run_cmd tar -czf "$archive" -C "$LAB_LOG_DIR" . 2>/dev/null || warn "log archive failed"
        chmod 0600 "$archive" 2>/dev/null || true
        dim "archived to ${archive}"
    fi
    : > "$LAB_EVENT_LOG"
    : > "$LAB_MAIN_LOG"
    chmod 0640 "$LAB_EVENT_LOG" "$LAB_MAIN_LOG"
    chown root:root "$LAB_EVENT_LOG" "$LAB_MAIN_LOG"
}

reset_flags() {
    info "Regenerating flags"
    "$SCRIPT_DIR/scripts/flags/generate_flags.sh" generate --force
}

reset_services() {
    (( RESTART == 1 )) || { dim "services not restarted (--no-restart)"; return 0; }
    if docker_ready && [[ -f "$LAB_WEB_DIR/docker-compose.yml" ]]; then
        info "Restarting Juice Shop"
        ( cd "$LAB_WEB_DIR" && run_cmd docker compose up -d ) || warn "Juice Shop did not start"
    fi
}

main() {
    reset_deactivate
    reset_baseline
    reset_practice_data
    reset_logs
    reset_flags
    reset_services
    log_event "RESET_COMPLETE" "core" "-" "SUCCESS" "flags_rotated=true"
    hr
    ok "Laboratory reset complete"
    dim "All scenarios are inactive. Flags were rotated; distribute the new values through the admin guide."
}
main
