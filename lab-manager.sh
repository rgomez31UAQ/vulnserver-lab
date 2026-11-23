#!/usr/bin/env bash
# =============================================================================
# VulnServer - lab-manager.sh
# Terminal administration interface (section 17 of the brief).
#
# Interactive:      sudo ./lab-manager.sh
# Non-interactive:  sudo ./lab-manager.sh status
#                   sudo ./lab-manager.sh activate a
#                   sudo ./lab-manager.sh deactivate all
#
# Commands: status start stop activate <a|b|c|all> deactivate <a|b|c|all>
#           audit harden report reset docs logs ports
# =============================================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

# ---------------------------------------------------------------------------
# Status
# ---------------------------------------------------------------------------
show_status() {
    banner
    printf '%-18s %s\n' "Host:" "$(hostname) ($(uname -m))"
    printf '%-18s %s\n' "State dir:" "$LAB_STATE_DIR"
    printf '%-18s %s\n' "Installed:" "$([[ -d $LAB_BIN_DIR ]] && echo yes || echo 'no (running from source tree)')"
    hr

    # Web application
    if command -v docker >/dev/null 2>&1 && docker_ready; then
        local cstate
        # `docker inspect` exits 1 when the container is absent; with
        # `set -e` + `pipefail` that would abort the whole status view.
        cstate="$(docker inspect -f '{{.State.Status}}' vulnserver-juice-shop 2>/dev/null | head -n1 || true)"
        [[ -n "$cstate" ]] || cstate="absent"
        printf 'Juice Shop       : %s\n' "$cstate"
        if [[ "$cstate" == "running" ]]; then
            printf '  URL            : http://%s:%s\n' "$(hostname -I 2>/dev/null | awk '{print $1}')" "$JUICE_SHOP_PORT"
            printf '  Local check    : %s\n' "$(curl -fsS -o /dev/null -w 'HTTP %{http_code}' --max-time 3 "http://127.0.0.1:${JUICE_SHOP_PORT}/" 2>/dev/null || echo 'no response')"
        fi
    else
        printf 'Juice Shop       : docker unavailable\n'
    fi

    # SSH
    printf 'SSH              : %s (port %s)\n' "$(service_active ssh && echo running || service_active sshd && echo running || echo 'not detected')" "$SSH_PORT"

    # Firewall
    if command -v ufw >/dev/null 2>&1; then
        printf 'Firewall (ufw)   : %s\n' "$(ufw status 2>/dev/null | head -n1 | sed 's/Status: //')"
    else
        printf 'Firewall (ufw)   : not installed\n'
    fi

    # Audit
    printf 'auditd           : %s\n' "$(service_active auditd && echo active || echo 'not active')"
    hr

    # Scenarios
    printf 'Scenarios\n'
    local id state name
    for id in a b c; do
        state="inactive"; scenario_is_active "$id" && state="ACTIVE"
        name="$(scenario_config_get "$id" NAME 2>/dev/null || echo 'unknown')"
        printf '  %-2s %-8s %s\n' "${id^^}" "$state" "$name"
    done
    hr

    # Ports
    printf 'Listening ports (top 15)\n'
    ss -ltnH 2>/dev/null | awk '{printf "  %-22s %s\n", $4, $1}' | sort -u | head -n 15
    hr
    printf 'Flags\n'
    local f
    for f in "$FLAG_USER_FILE" "$FLAG_PRIV_FILE" "$FLAG_ROOT_FILE"; do
        if [[ -f "$f" ]]; then
            printf '  %-46s %s\n' "$f" "$(stat -c '%A %U:%G' "$f")"
        else
            printf '  %-46s %s\n' "$f" "MISSING"
        fi
    done
}

# ---------------------------------------------------------------------------
# Services
# ---------------------------------------------------------------------------
start_services() {
    require_root "$@"
    info "Starting Docker and Juice Shop"
    if command -v systemctl >/dev/null 2>&1 && has_systemd; then
        systemctl start docker 2>/dev/null || warn "could not start docker"
        systemctl start cron 2>/dev/null || true
        systemctl start auditd 2>/dev/null || true
    fi
    if [[ -f "$LAB_WEB_DIR/docker-compose.yml" ]] && docker_ready; then
        ( cd "$LAB_WEB_DIR" && docker compose up -d ) || die "Juice Shop failed to start"
        log_event "SERVICE_START" "juice-shop" "-" "SUCCESS"
        ok "Juice Shop started on port ${JUICE_SHOP_PORT}"
    else
        warn "compose file not found in ${LAB_WEB_DIR}; run install.sh first"
    fi
}

stop_services() {
    require_root "$@"
    info "Stopping Juice Shop (containers are kept)"
    if [[ -f "$LAB_WEB_DIR/docker-compose.yml" ]] && docker_ready; then
        ( cd "$LAB_WEB_DIR" && docker compose stop ) || warn "docker compose stop failed"
        log_event "SERVICE_STOP" "juice-shop" "-" "SUCCESS"
        ok "Juice Shop stopped"
    else
        warn "nothing to stop"
    fi
}

# ---------------------------------------------------------------------------
# Scenarios
# ---------------------------------------------------------------------------
manage_scenario() { # <activate|deactivate> <id|all>
    local action="$1" target="${2,,}" id script
    require_root "$@"
    [[ "$target" == "all" ]] && target="a b c"
    for id in $target; do
        case "$id" in
            a|b|c) ;;
            scenario-a) id=a ;; scenario-b) id=b ;; scenario-c) id=c ;;
            *) die "unknown scenario: $id (use a, b, c or all)" ;;
        esac
        script="$SCRIPT_DIR/scripts/scenarios/scenario-${id}.sh"
        [[ -x "$script" ]] || die "missing scenario script: ${script}"
        "$script" "$action"
    done
}

# ---------------------------------------------------------------------------
# Reports / docs
# ---------------------------------------------------------------------------
generate_report() {
    require_root "$@"
    "$SCRIPT_DIR/scripts/monitoring/report.sh" "$@"
}

show_docs() {
    local docs="$SCRIPT_DIR/docs"
    printf 'Available documentation in %s:\n\n' "$docs"
    local f
    for f in INSTALLATION ATTACKER_GUIDE ADMIN_GUIDE HARDENING_GUIDE CLOUD_DEPLOYMENT TROUBLESHOOTING INSTRUCTOR_SOLUTIONS; do
        [[ -f "$docs/$f.md" ]] && printf '  %-24s %s\n' "$f.md" "$(head -n 1 "$docs/$f.md" | sed 's/^# //')"
    done
    hr
    printf 'Quick views:\n'
    printf '  less %s/ATTACKER_GUIDE.md\n' "$docs"
    printf '  less %s/HARDENING_GUIDE.md\n' "$docs"
}

show_logs() {
    printf 'Event log : %s\n' "$LAB_EVENT_LOG"
    printf 'Main log  : %s\n' "$LAB_MAIN_LOG"
    hr
    if [[ -r "$LAB_EVENT_LOG" ]]; then tail -n 20 "$LAB_EVENT_LOG"; else warn "no event log yet"; fi
    hr
    printf 'SSH/auth (last 10):\n'
    journalctl -u ssh --no-pager -n 10 2>/dev/null || tail -n 10 /var/log/auth.log 2>/dev/null || dim "unavailable"
}

show_ports() {
    printf '%-22s %-10s %s\n' LOCAL STATE PROCESS
    ss -ltnpH 2>/dev/null | awk '{printf "%-22s %-10s %s\n", $4, $1, $6}' | sort -u
    hr
    printf 'Expected: SSH %s/tcp, Juice Shop %s/tcp\n' "$SSH_PORT" "$JUICE_SHOP_PORT"
    printf 'Allowed source networks - SSH: %s | web: %s\n' "$SSH_ALLOWED_NETS" "$LAB_ALLOWED_NETS"
}

# ---------------------------------------------------------------------------
# Menu
# ---------------------------------------------------------------------------
menu() {
    local choice
    while true; do
        banner
        cat <<EOF

 1) Laboratory status
 2) Install dependencies / re-run installer
 3) Start services
 4) Stop services
 5) Activate a scenario
 6) Deactivate a scenario
 7) Run audit (read-only)
 8) Apply hardening
 9) Generate activity report
10) Reset laboratory
11) View documentation
12) Exit
EOF
        read -r -p "Select an option [1-12]: " choice
        case "$choice" in
            1) show_status ;;
            2) sudo "$SCRIPT_DIR/install.sh" --install-deps ;;
            3) start_services ;;
            4) stop_services ;;
            5) read -r -p "Scenario (a/b/c/all): " s; manage_scenario activate "$s" ;;
            6) read -r -p "Scenario (a/b/c/all): " s; manage_scenario deactivate "$s" ;;
            7) sudo "$SCRIPT_DIR/audit.sh" ;;
            8) sudo "$SCRIPT_DIR/harden.sh" ;;
            9) sudo "$SCRIPT_DIR/scripts/monitoring/report.sh" ;;
           10) sudo "$SCRIPT_DIR/reset-lab.sh" ;;
           11) show_docs; read -r -p "Press Enter to continue..." _ ;;
           12) info "bye"; exit 0 ;;
            *) warn "invalid option" ;;
        esac
        printf '\n'; read -r -p "Press Enter to return to the menu..." _ || true
    done
}

# ---------------------------------------------------------------------------
# Dispatch
# ---------------------------------------------------------------------------
cmd="${1:-menu}"; shift || true
case "$cmd" in
    menu)        menu ;;
    status)      show_status ;;
    start)       start_services ;;
    stop)        stop_services ;;
    activate)    manage_scenario activate "${1:?scenario id required (a|b|c|all)}" ;;
    deactivate)  manage_scenario deactivate "${1:?scenario id required (a|b|c|all)}" ;;
    audit)       require_root "$@"; "$SCRIPT_DIR/audit.sh" ;;
    harden)      require_root "$@"; "$SCRIPT_DIR/harden.sh" ;;
    report)      generate_report ;;
    reset)       require_root "$@"; "$SCRIPT_DIR/reset-lab.sh" ;;
    docs)        show_docs ;;
    logs)        show_logs ;;
    ports)       show_ports ;;
    -h|--help)   sed -n '2,18p' "$0" ;;
    *) die "unknown command: $cmd (try --help)" ;;
esac
