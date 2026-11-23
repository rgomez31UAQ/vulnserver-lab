#!/usr/bin/env bash
# =============================================================================
# VulnServer - config/ufw/ufw-rules.sh
# Applies the isolation firewall. Called by install.sh (apply) and harden.sh.
#
#   ./ufw-rules.sh apply     # install rules and enable UFW
#   ./ufw-rules.sh status    # show current rules
#   ./ufw-rules.sh remove    # remove VulnServer rules (keeps UFW state)
#
# Rules (default deny inbound, allow outbound):
#   * SSH (22/tcp)  only from SSH_ALLOWED_NETS
#   * Juice Shop    only from LAB_ALLOWED_NETS
#   * everything else dropped; Docker publishes only the Juice Shop port and
#     only on the lab interface (see web/docker-compose.yml).
# =============================================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../../lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

require_root "$@"
check_deps ufw || die "ufw is not installed (apt-get install ufw)"

action="${1:-apply}"
comment="vulnserver"

apply_rules() {
    info "Resetting UFW to a known state (default deny incoming)"
    run_cmd ufw --force reset >/dev/null
    run_cmd ufw default deny incoming
    run_cmd ufw default allow outgoing

    local net
    for net in $SSH_ALLOWED_NETS; do
        info "SSH ${SSH_PORT}/tcp allowed from ${net}"
        run_cmd ufw allow from "$net" to any port "$SSH_PORT" proto tcp comment "${comment}-ssh"
    done

    for net in $LAB_ALLOWED_NETS; do
        info "Juice Shop ${JUICE_SHOP_PORT}/tcp allowed from ${net}"
        run_cmd ufw allow from "$net" to any port "$JUICE_SHOP_PORT" proto tcp comment "${comment}-web"
    done

    # The reset above also wipes any WireGuard rule. If a tunnel is configured,
    # restore it or every remote client loses access the moment this runs.
    if [[ -r /etc/wireguard/wg0.conf ]]; then
        local wg_port
        wg_port="$(sed -n 's/^ListenPort *= *//p' /etc/wireguard/wg0.conf | head -n1)"
        wg_port="${wg_port:-51820}"
        info "WireGuard tunnel detected: allowing ${wg_port}/udp and wg0"
        run_cmd ufw allow "${wg_port}/udp" comment "${comment}-wireguard"
        run_cmd ufw allow in on wg0 comment "${comment}-tunnel"
    fi

    # Docker's userland proxy publishes on the host; block the container
    # network from reaching the host's other services.
    run_cmd ufw deny in on docker0 comment "${comment}-docker-in"
    run_cmd ufw deny in on "${LAB_NET_NAME}" comment "${comment}-labnet-in" || true

    info "Enabling UFW"
    run_cmd ufw --force enable
    log_event "FIREWALL_APPLY" "ufw" "-" "SUCCESS" "ssh_nets=${SSH_ALLOWED_NETS} web_nets=${LAB_ALLOWED_NETS} port=${JUICE_SHOP_PORT}"
    ok "Firewall active"
}

case "$action" in
    apply)  apply_rules ;;
    status) ufw status verbose ;;
    remove)
        confirm "Remove VulnServer UFW rules?" || exit 1
        ufw status numbered | awk '/vulnserver/ {print $1}' | tr -d '[]' | sort -rn |
            while read -r n; do run_cmd ufw --force delete "$n" || true; done
        log_event "FIREWALL_REMOVE" "ufw" "-" "SUCCESS" "rules removed"
        ;;
    *) die "usage: $0 {apply|status|remove}" ;;
esac
