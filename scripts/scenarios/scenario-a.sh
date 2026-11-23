#!/usr/bin/env bash
# =============================================================================
# VulnServer - scripts/scenarios/scenario-a.sh
# SCENARIO A - Insecure file permissions
#
# What is intentionally broken
#   1. /usr/bin/find carries the SUID bit (root). Any local user can use a
#      standard utility to obtain a root shell (GTFOBins "find").
#   2. $SCENARIO_A_DIR is mode 0777: every local user can read, replace and
#      delete the maintenance material stored there.
#   3. Fictional "investigation" files describe a backup routine, giving the
#      attacker a believable trail without containing real secrets.
#
#   ./scenario-a.sh activate     # enable the vulnerability (creates restore point)
#   ./scenario-a.sh deactivate   # restore secure state
#   ./scenario-a.sh status       # human readable state
#   ./scenario-a.sh verify       # automated check: 0 = vulnerable, 1 = fixed
# =============================================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../../lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

require_root "$@"
SCENARIO_ID="A"
BIN="$SCENARIO_A_SUID_BINARY"

seed_decoys() {
    mkdir -p "$SCENARIO_A_DIR"
    cat > "$SCENARIO_A_DIR/backup-routine.txt" <<'EOF'
INTERNAL - backup routine (fictional)
-------------------------------------
Nightly rsync of /srv/app to the NAS runs as the service account.
TODO(ops): "temporarily" gave the reporting group write access to this
folder so they could drop exports here. Nobody removed it.
EOF
    cat > "$SCENARIO_A_DIR/exports" <<'EOF'
host,service,port,owner
status.internal,http,3000,ops
reporting.internal,http,8080,reporting
EOF
    chmod 0644 "$SCENARIO_A_DIR/backup-routine.txt" "$SCENARIO_A_DIR/exports"
    chown root:root "$SCENARIO_A_DIR/backup-routine.txt" "$SCENARIO_A_DIR/exports"
}

activate() {
    [[ -x "$BIN" ]] || die "SUID target ${BIN} not found"
    seed_decoys
    local rp; rp="$(create_restore_point "$SCENARIO_ID")" || warn "restore point not created"
    info "Original mode of ${BIN}: $(stat -c '%a' "$BIN")"
    run_cmd chmod 0777 "$SCENARIO_A_DIR"
    run_cmd chmod u+s "$BIN"
    scenario_set_state "a" active
    log_event "SCENARIO_ACTIVATE" "filesystem" "$SCENARIO_ID" "SUCCESS" \
        "suid=${BIN} world_writable=${SCENARIO_A_DIR} restore_point=${rp:-none}"
    ok "Scenario A active: SUID on ${BIN}, 0777 on ${SCENARIO_A_DIR}"
    dim "Automated check: $0 verify"
}

deactivate() {
    if [[ -x "$BIN" ]]; then
        run_cmd chmod u-s "$BIN"
    fi
    [[ -d "$SCENARIO_A_DIR" ]] && run_cmd chmod 0755 "$SCENARIO_A_DIR"
    scenario_set_state "a" inactive
    log_event "SCENARIO_DEACTIVATE" "filesystem" "$SCENARIO_ID" "SUCCESS" \
        "suid_removed=${BIN} dir_mode=0755"
    ok "Scenario A deactivated (SUID removed, directory 0755)"
}

status() {
    local mode suid dir_mode
    mode="$(stat -c '%a' "$BIN" 2>/dev/null || echo missing)"
    suid="$(stat -c '%A' "$BIN" 2>/dev/null || echo missing)"
    dir_mode="$(stat -c '%a' "$SCENARIO_A_DIR" 2>/dev/null || echo missing)"
    printf 'Scenario A - insecure file permissions\n'
    printf '  state file   : %s\n' "$(scenario_is_active a && echo active || echo inactive)"
    printf '  %-12s : %s (mode %s)\n' "$(basename "$BIN")" "$suid" "$mode"
    printf '  %-12s : mode %s\n' "$(basename "$SCENARIO_A_DIR")" "$dir_mode"
}

verify() {
    local fail=0
    if [[ "$(stat -c '%a' "$BIN" 2>/dev/null)" == "4755" ]]; then
        printf '  SUID bit on %s            PASS (vulnerable, as configured)\n' "$BIN"
    else
        printf '  SUID bit on %s            FAIL (not set)\n' "$BIN"; fail=1
    fi
    if [[ "$(stat -c '%a' "$SCENARIO_A_DIR" 2>/dev/null)" == "777" ]]; then
        printf '  World-writable %-12s PASS (vulnerable, as configured)\n' "$(basename "$SCENARIO_A_DIR")"
    else
        printf '  World-writable %-12s FAIL (not 0777)\n' "$(basename "$SCENARIO_A_DIR")"; fail=1
    fi
    (( fail == 0 )) && ok "Scenario A is active" || warn "Scenario A is not fully active"
    return $fail
}

case "${1:-status}" in
    activate)   activate ;;
    deactivate) deactivate ;;
    status)     status ;;
    verify)     verify ;;
    *) die "usage: $0 {activate|deactivate|status|verify}" ;;
esac
