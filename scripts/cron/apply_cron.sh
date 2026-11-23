#!/usr/bin/env bash
# =============================================================================
# VulnServer - scripts/cron/apply_cron.sh
# Ensures the cron subsystem is present and in its *secure baseline* state.
# Scenario C adds the deliberately broken job; this script never does.
#
#   ./apply_cron.sh base    # ensure cron installed/enabled + baseline perms
#   ./apply_cron.sh status  # show service state and VulnServer cron files
#   ./apply_cron.sh logs    # recent cron activity from journal/syslog
# =============================================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../../lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

require_root "$@"

apply_base() {
    check_deps cron || die "cron is not installed (apt-get install cron)"
    if has_systemd; then
        run_cmd systemctl enable --now cron >/dev/null 2>&1 || warn "could not enable cron via systemd"
    else
        pgrep -x cron >/dev/null 2>&1 || run_cmd cron || warn "could not start cron"
    fi

    # Baseline: only root may write to the cron spool directories.
    local d
    for d in /etc/cron.d /etc/cron.hourly /etc/cron.daily /etc/cron.weekly /etc/cron.monthly; do
        [[ -d "$d" ]] && { chmod 0755 "$d"; chown root:root "$d"; }
    done
    [[ -f /etc/crontab ]] && { chmod 0644 /etc/crontab; chown root:root /etc/crontab; }

    # Log cron executions to syslog (Ubuntu default) - explicit for clarity.
    log_event "CRON_BASE" "cron" "-" "SUCCESS" "service=enabled baseline_perms=applied"
    ok "cron service enabled, baseline permissions applied"
}

status_cron() {
    if service_active cron; then ok "cron: active"; else warn "cron: not running"; fi
    hr
    printf 'VulnServer cron files:\n'
    local f found=0
    for f in /etc/cron.d/vulnserver-*; do
        [[ -e "$f" ]] || continue
        found=1
        stat -c '%A %U:%G %n' "$f"
        sed 's/^/    /' "$f"
    done
    (( found == 0 )) && dim "  none installed (scenario C inactive)"
}

cron_logs() {
    if command -v journalctl >/dev/null 2>&1 && has_systemd; then
        journalctl -u cron --since '-1 day' --no-pager 2>/dev/null | tail -n 40
    elif [[ -r /var/log/syslog ]]; then
        grep -i cron /var/log/syslog | tail -n 40
    else
        warn "no journalctl or /var/log/syslog available"
    fi
}

case "${1:-base}" in
    base)   apply_base ;;
    status) status_cron ;;
    logs)   cron_logs ;;
    *) die "usage: $0 {base|status|logs}" ;;
esac
