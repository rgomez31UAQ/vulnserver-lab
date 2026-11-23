#!/usr/bin/env bash
# =============================================================================
# VulnServer - scripts/permissions/apply_permissions.sh
# Builds the state-directory tree and applies the *baseline* permission model.
# Scenario A intentionally breaks a small part of this model later; this script
# always restores the secure baseline.
#
#   ./apply_permissions.sh base     # create tree + baseline permissions
#   ./apply_permissions.sh verify   # check baseline (used by audit.sh)
#   ./apply_permissions.sh show     # print the tree with modes/owners
# =============================================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../../lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

require_root "$@"

apply_base() {
    info "Creating state directory tree under ${LAB_STATE_DIR}"
    run_cmd mkdir -p "$LAB_STATE_DIR"/{bin,flags,logs,backups,reports,state} \
                     "$LAB_DATA_DIR"/{notes,perms,cron} \
                     "$LAB_WEB_DIR"

    if [[ "$DRY_RUN" == "1" ]]; then
        dim "[dry-run] baseline permissions not applied"
        return 0
    fi

    # --- Baseline permissions -------------------------------------------------
    # Everything is root-owned and non-world-writable. The only intentionally
    # writable locations for students are inside $LAB_DATA_DIR and are enabled
    # per scenario.
    chmod 0755 "$LAB_STATE_DIR"
    chown root:root "$LAB_STATE_DIR"

    chmod 0755 "$LAB_FLAG_DIR";  chown root:root "$LAB_FLAG_DIR"

    # Logs: readable/appendable by root only; students cannot tamper with them.
    chmod 0750 "$LAB_LOG_DIR";   chown root:root "$LAB_LOG_DIR"
    [[ -f "$LAB_EVENT_LOG" ]] || { : >>"$LAB_EVENT_LOG"; }
    [[ -f "$LAB_MAIN_LOG"  ]] || { : >>"$LAB_MAIN_LOG"; }
    chmod 0640 "$LAB_EVENT_LOG" "$LAB_MAIN_LOG"; chown root:root "$LAB_EVENT_LOG" "$LAB_MAIN_LOG"

    # Backups and reports are administrative-only.
    chmod 0700 "$LAB_BACKUP_DIR"; chown root:root "$LAB_BACKUP_DIR"
    chmod 0750 "$LAB_REPORT_DIR"; chown root:root "$LAB_REPORT_DIR"
    chmod 0755 "$LAB_STATE_STATE_DIR"; chown root:root "$LAB_STATE_STATE_DIR"

    chmod 0755 "$LAB_DATA_DIR"; chown root:root "$LAB_DATA_DIR"
    chmod 0755 "$LAB_DATA_DIR/notes"; chown root:root "$LAB_DATA_DIR/notes"
    chmod 0755 "$LAB_DATA_DIR/perms"; chown root:root "$LAB_DATA_DIR/perms"
    chmod 0755 "$LAB_DATA_DIR/cron";  chown root:root "$LAB_DATA_DIR/cron"

    # Lab notes: fictional information students may legitimately discover.
    if [[ ! -f "$LAB_DATA_DIR/notes/README-lab.txt" ]]; then
        cat > "$LAB_DATA_DIR/notes/README-lab.txt" <<'EOF'
VulnServer lab notes (fictional data, no real credentials)
-----------------------------------------------------------
Week 1: deployed the internal status page on port 3000.
Week 2: TODO - review backup permissions. The vendor asked us to give the
        ops account write access to the maintenance script "for convenience".
Week 3: rotation of the internal reporting key is pending.
EOF
        chmod 0644 "$LAB_DATA_DIR/notes/README-lab.txt"
    fi

    # SSH banner: marks the lab boundary on every connection.
    install -d -m 0755 /etc/ssh
    if [[ ! -f /etc/ssh/vulnserver-banner ]]; then
        cat > /etc/ssh/vulnserver-banner <<'EOF'
+-------------------------------------------------------------------+
|  VulnServer - Educational Security Laboratory                     |
|  Authorized use only. All activity is logged and audited.         |
|  Disconnect now if you are not an authorized participant.         |
+-------------------------------------------------------------------+
EOF
        chmod 0644 /etc/ssh/vulnserver-banner
    fi

    log_event "PERMISSIONS_BASE" "filesystem" "-" "SUCCESS" "tree=${LAB_STATE_DIR}"
    ok "Baseline permission model applied"
}

verify_base() {
    local rc=0 path mode owner
    local -a checks=(
        "${LAB_STATE_DIR}:755:root:root"
        "${LAB_FLAG_DIR}:755:root:root"
        "${LAB_LOG_DIR}:750:root:root"
        "${LAB_BACKUP_DIR}:700:root:root"
        "${LAB_REPORT_DIR}:750:root:root"
        "${LAB_DATA_DIR}:755:root:root"
    )
    printf '%-46s %-18s %-6s %s\n' PATH OWNER MODE RESULT
    for spec in "${checks[@]}"; do
        IFS=: read -r path mode owner rest <<<"$spec"
        owner="${owner}:${rest}"
        if [[ ! -e "$path" ]]; then
            printf '%-46s %-18s %-6s %s\n' "$path" "-" "-" "MISSING"; rc=1; continue
        fi
        local amode aowner
        amode="$(stat -c '%a' "$path")"; aowner="$(stat -c '%U:%G' "$path")"
        if [[ "$amode" == "$mode" && "$aowner" == "$owner" ]]; then
            printf '%-46s %-18s %-6s %s\n' "$path" "$aowner" "$amode" "PASS"
        else
            printf '%-46s %-18s %-6s %s (want %s/%s)\n' "$path" "$aowner" "$amode" "FAIL" "$owner" "$mode"
            rc=1
        fi
    done
    return $rc
}

case "${1:-base}" in
    base)   apply_base ;;
    verify) verify_base ;;
    show)   find "$LAB_STATE_DIR" -maxdepth 3 \( -type d -o -type f \) \
                 -printf '%M %u:%-8g %p\n' 2>/dev/null | sort -k3 ;;
    *) die "usage: $0 {base|verify|show}" ;;
esac
