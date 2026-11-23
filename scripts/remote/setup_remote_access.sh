#!/usr/bin/env bash
# =============================================================================
# VulnServer - scripts/remote/setup_remote_access.sh
#
# Builds the only network path into a cloud-hosted lab: a WireGuard tunnel.
# Nothing else is exposed. Juice Shop is published on the tunnel address only.
#
#   ./setup_remote_access.sh                          # dry-run: show the plan
#   sudo ./setup_remote_access.sh --apply --endpoint 203.0.113.10 --peer owner
#   sudo ./setup_remote_access.sh --apply --endpoint lab.example.net --peer alice --qr
#   sudo ./setup_remote_access.sh --publish-web --apply --endpoint 203.0.113.10
#   sudo ./setup_remote_access.sh --status
#   sudo ./setup_remote_access.sh --remove-peer alice
#
# Ownership: this script owns /etc/wireguard/wg0.conf. Add and remove peers
# with --peer / --remove-peer instead of editing the file by hand.
#
# The script is idempotent: existing server and peer keys are reused, so
# re-running it after a reboot or a peer addition never invalidates the
# configuration already installed on a client device.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../../lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

WG_IFACE="${WG_IFACE:-wg0}"
WG_DIR="${WG_DIR:-/etc/wireguard}"
WG_NET="${WG_NET:-10.8.0.0/24}"
WG_PORT="${WG_PORT:-51820}"
WG_DNS="${WG_DNS:-1.1.1.1}"
WG_ENDPOINT="${WG_ENDPOINT:-}"
WG_PEERS=()
WG_REMOVE=()
WG_QR=0
WG_UFW=1
WG_PUBLISH_WEB=0
WG_FORCE=0
APPLY=0
MODE="plan"

PEER_DIR="${WG_DIR}/peers"
CLIENT_DIR="${WG_DIR}/clients"
CONF="${WG_DIR}/${WG_IFACE}.conf"
MANAGED_TAG="# Managed by vulnserver setup_remote_access.sh"

usage() {
    sed -n '2,26p' "$0" | sed 's/^# \{0,1\}//'
    cat <<'EOF'

Options:
  --endpoint HOST     Public IP or DNS name clients connect to (required with --apply)
  --port N            WireGuard UDP port (default 51820)
  --network CIDR      Tunnel network; a /24 is required (default 10.8.0.0/24)
  --peer NAME         Add a peer (repeatable). Creates a client config for it.
  --remove-peer NAME  Remove a peer and delete its client config
  --qr                Print a terminal QR code for each new client config
  --no-ufw            Do not touch UFW (you manage the firewall yourself)
  --publish-web       Recreate the Juice Shop stack bound to the tunnel address
  --force             Overwrite a wg0.conf that was not created by this script
  --apply             Make the changes (default is a dry-run plan)
  --dry-run           Explicitly request the dry-run plan
  --status            Show interface, peer, firewall and web-app state
  -h, --help          This help
EOF
}

# -----------------------------------------------------------------------------
# Argument parsing
# -----------------------------------------------------------------------------
while (( $# > 0 )); do
    case "$1" in
        --endpoint)    WG_ENDPOINT="${2:?--endpoint needs a host}"; shift 2 ;;
        --port)        WG_PORT="${2:?--port needs a number}"; shift 2 ;;
        --network)     WG_NET="${2:?--network needs a CIDR}"; shift 2 ;;
        --peer)        WG_PEERS+=("${2:?--peer needs a name}"); shift 2 ;;
        --remove-peer) WG_REMOVE+=("${2:?--remove-peer needs a name}"); shift 2 ;;
        --qr)          WG_QR=1; shift ;;
        --no-ufw)      WG_UFW=0; shift ;;
        --publish-web) WG_PUBLISH_WEB=1; shift ;;
        --force)       WG_FORCE=1; shift ;;
        --apply)       APPLY=1; shift ;;
        --dry-run)     APPLY=0; shift ;;
        --status)      MODE="status"; shift ;;
        -y|--yes)      ASSUME_YES=1; shift ;;
        -h|--help)     usage; exit 0 ;;
        *)             die "unknown option: $1 (try --help)" ;;
    esac
done
export ASSUME_YES

# -----------------------------------------------------------------------------
# Validation helpers
# -----------------------------------------------------------------------------
validate_inputs() {
    [[ "$WG_PORT" =~ ^[0-9]+$ ]] && (( WG_PORT >= 1 && WG_PORT <= 65535 )) \
        || die "invalid --port: ${WG_PORT}"

    [[ "$WG_NET" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/([0-9]{1,2})$ ]] \
        || die "invalid --network: ${WG_NET} (expected e.g. 10.8.0.0/24)"
    local prefix="${WG_NET##*/}"
    [[ "$prefix" == "24" ]] \
        || die "this helper supports /24 tunnel networks only (got /${prefix})"

    local name
    for name in "${WG_PEERS[@]}" "${WG_REMOVE[@]}"; do
        [[ "$name" =~ ^[a-z0-9][a-z0-9-]{0,20}$ ]] \
            || die "invalid peer name '${name}' (lowercase letters, digits, dash; max 21 chars)"
    done

    # The endpoint is remembered from the previous run, so day-to-day peer
    # management (--remove-peer) does not require repeating it.
    if (( APPLY == 1 )) && [[ -z "$WG_ENDPOINT" && -r "${WG_DIR}/server.info" ]]; then
        WG_ENDPOINT="$(sed -n 's/^endpoint=//p' "${WG_DIR}/server.info" | head -n1)"
    fi
    if (( APPLY == 1 )) && [[ -z "$WG_ENDPOINT" ]] && (( ${#WG_PEERS[@]} > 0 )); then
        die "--endpoint is required the first time you add peers (public IP or DNS name of this VM)"
    fi
}

net_base() { printf '%s' "${WG_NET%/*}" | awk -F. '{printf "%s.%s.%s", $1, $2, $3}'; }
server_ip() { printf '%s.1' "$(net_base)"; }

# -----------------------------------------------------------------------------
# Peer bookkeeping: /etc/wireguard/peers/<name>.info
#   name=alice
#   address=10.8.0.2
#   public_key=...
# -----------------------------------------------------------------------------
peer_info() { printf '%s/%s.info' "$PEER_DIR" "$1"; }

peer_field() { # <name> <field>
    local f value; f="$(peer_info "$1")"
    [[ -r "$f" ]] || return 1
    value="$(sed -n "s/^$2=//p" "$f" | head -n1)"
    [[ -n "$value" ]] || return 1
    printf '%s' "$value"
}

peer_exists() { [[ -r "$(peer_info "$1")" ]] && [[ -r "${PEER_DIR}/${1}.pub" ]]; }

used_addresses() {
    local f
    {
        [[ -r "$CONF" ]] && sed -n 's/^AllowedIPs *= *\([0-9.]*\)\/32.*/\1/p' "$CONF"
        for f in "$PEER_DIR"/*.info; do
            [[ -e "$f" ]] || continue
            sed -n 's/^address=//p' "$f"
        done
    } | sort -u
}

# next_free <space-separated used addresses> -> first free .2-.254
next_free() {
    local used=" $1 " n
    for n in $(seq 2 254); do
        [[ "$used" == *" $(net_base).${n} "* ]] && continue
        printf '%s.%s' "$(net_base)" "$n"
        return 0
    done
    return 1
}

next_address() { next_free "$(used_addresses | tr '\n' ' ')"; }

# -----------------------------------------------------------------------------
# Plan output (also used as the dry-run body)
# -----------------------------------------------------------------------------
print_plan() {
    local name ip taken
    taken="$(used_addresses | tr '\n' ' ')"
    info "WireGuard server"
    dim "interface : ${WG_IFACE}"
    dim "address   : $(server_ip)/24"
    dim "port      : ${WG_PORT}/udp"
    dim "endpoint  : ${WG_ENDPOINT:-<set with --endpoint>}"
    dim "config    : ${CONF} (mode 0600)"
    dim "clients   : ${CLIENT_DIR}/<peer>.conf"

    hr
    info "Peers"
    if (( ${#WG_PEERS[@]} == 0 )) && (( ${#WG_REMOVE[@]} == 0 )); then
        dim "none requested; add one with: --peer owner"
    fi
    for name in "${WG_PEERS[@]}"; do
        if peer_exists "$name"; then
            dim "${name}: exists at $(peer_field "$name" address) (keys reused)"
        else
            ip="$(next_free "$taken")" || die "tunnel network is full"
            taken+=" ${ip}"
            dim "${name}: new peer at ${ip}"
        fi
    done
    for name in "${WG_REMOVE[@]}"; do
        dim "${name}: removal requested"
    done

    hr
    info "Firewall"
    if (( WG_UFW == 1 )); then
        dim "allow ${WG_PORT}/udp from anywhere (WireGuard only)"
        dim "allow all traffic on ${WG_IFACE}"
        dim "no other inbound port is opened by this script"
    else
        dim "skipped (--no-ufw): you must allow ${WG_PORT}/udp yourself"
    fi
    if (( WG_PUBLISH_WEB == 1 )); then
        dim "rebind Juice Shop to $(server_ip):${JUICE_SHOP_PORT}"
    fi

    hr
    info "Client configuration that will be written (values filled on --apply)"
    cat <<EOF
[Interface]
PrivateKey = <peer private key>
Address = <peer ip>/32
DNS = ${WG_DNS}

[Peer]
PublicKey = <server public key>
Endpoint = ${WG_ENDPOINT:-<endpoint>}:${WG_PORT}
AllowedIPs = ${WG_NET}
PersistentKeepalive = 25
EOF
}

# -----------------------------------------------------------------------------
# Apply
# -----------------------------------------------------------------------------
write_server_config() {
    local tmpdir tmp name pub ip
    # wg-quick derives the interface name from the file name, so the temporary
    # file must be called <iface>.conf or validation fails for the wrong reason.
    tmpdir="$(mktemp -d)"
    tmp="${tmpdir}/${WG_IFACE}.conf"

    {
        printf '%s\n' "$MANAGED_TAG"
        printf '# Regenerate with scripts/remote/setup_remote_access.sh; manual edits are lost.\n'
        printf '[Interface]\n'
        printf 'Address = %s/24\n' "$(server_ip)"
        printf 'ListenPort = %s\n' "$WG_PORT"
        printf 'PrivateKey = %s\n' "$(cat "${WG_DIR}/server.key")"
        for name in $(used_peer_names); do
            pub="$(cat "${PEER_DIR}/${name}.pub")"
            ip="$(peer_field "$name" address)"
            printf '\n# peer: %s\n[Peer]\nPublicKey = %s\nAllowedIPs = %s/32\n' \
                "$name" "$pub" "$ip"
        done
    } > "$tmp"

    # Validate the generated file before it can affect networking.
    if ! wg-quick strip "$tmp" >/dev/null 2>&1; then
        rm -rf "$tmpdir"
        die "generated WireGuard config failed validation; ${CONF} was not modified"
    fi
    chmod 0600 "$tmp"
    [[ -f "$CONF" ]] && cp -a "$CONF" "${CONF}.bak.$(timestamp_slug)"
    mv "$tmp" "$CONF"
    rm -rf "$tmpdir"
}

used_peer_names() {
    local f
    for f in "$PEER_DIR"/*.info; do
        [[ -e "$f" ]] || continue
        basename "$f" .info
    done | sort
}

ensure_server_keys() {
    mkdir -p "$WG_DIR"
    chmod 0700 "$WG_DIR"
    if [[ ! -s "${WG_DIR}/server.key" ]]; then
        umask 077
        wg genkey | tee "${WG_DIR}/server.key" | wg pubkey > "${WG_DIR}/server.pub"
        ok "generated server key pair"
    else
        dim "reusing existing server key"
    fi
    chmod 0600 "${WG_DIR}/server.key"
    chmod 0644 "${WG_DIR}/server.pub"
}

add_peer() {
    local name="$1" ip
    mkdir -p "$PEER_DIR" "$CLIENT_DIR"
    chmod 0700 "$PEER_DIR" "$CLIENT_DIR"

    if peer_exists "$name"; then
        dim "peer ${name} already exists; keeping its keys and address"
    else
        ip="$(next_address)" || die "tunnel network is full"
        umask 077
        wg genkey | tee "${PEER_DIR}/${name}.key" | wg pubkey > "${PEER_DIR}/${name}.pub"
        {
            printf 'name=%s\n' "$name"
            printf 'address=%s\n' "$ip"
            printf 'created=%s\n' "$(date +"$LAB_TS_FORMAT")"
        } > "$(peer_info "$name")"
        chmod 0600 "${PEER_DIR}/${name}.key" "$(peer_info "$name")"
        chmod 0644 "${PEER_DIR}/${name}.pub"
        ok "created peer ${name} (${ip})"
    fi
}

write_client_config() {
    local name="$1" ip out
    ip="$(peer_field "$name" address)"
    out="${CLIENT_DIR}/${name}.conf"
    {
        printf '# VulnServer WireGuard client - %s\n' "$name"
        printf '[Interface]\n'
        printf 'PrivateKey = %s\n' "$(cat "${PEER_DIR}/${name}.key")"
        printf 'Address = %s/32\n' "$ip"
        printf 'DNS = %s\n\n' "$WG_DNS"
        printf '[Peer]\n'
        printf 'PublicKey = %s\n' "$(cat "${WG_DIR}/server.pub")"
        printf 'Endpoint = %s:%s\n' "$WG_ENDPOINT" "$WG_PORT"
        printf 'AllowedIPs = %s\n' "$WG_NET"
        printf 'PersistentKeepalive = 25\n'
    } > "$out"
    chmod 0600 "$out"
    ok "client config: ${out}"
    if (( WG_QR == 1 )); then
        if command -v qrencode >/dev/null 2>&1; then
            qrencode -t ansiutf8 < "$out"
        else
            warn "qrencode not installed; copy the file to the WireGuard app instead"
        fi
    fi
}

remove_peer() {
    local name="$1" pub
    if [[ ! -r "$(peer_info "$name")" ]]; then
        warn "peer ${name} does not exist"
        return 0
    fi
    pub="$(cat "${PEER_DIR}/${name}.pub")"
    if command -v wg >/dev/null 2>&1 && ip link show "$WG_IFACE" >/dev/null 2>&1; then
        wg set "$WG_IFACE" peer "$pub" remove || warn "could not remove peer from the running interface"
    fi
    rm -f "${PEER_DIR}/${name}.key" "${PEER_DIR}/${name}.pub" "$(peer_info "$name")" \
          "${CLIENT_DIR}/${name}.conf"
    ok "removed peer ${name}"
}

reload_interface() {
    if has_systemd; then
        systemctl enable "wg-quick@${WG_IFACE}" >/dev/null 2>&1 || warn "could not enable wg-quick@${WG_IFACE}"
    fi
    if ip link show "$WG_IFACE" >/dev/null 2>&1; then
        # syncconf applies peer changes without tearing the tunnel down.
        wg syncconf "$WG_IFACE" <(wg-quick strip "$CONF")
        ok "reloaded ${WG_IFACE} without dropping connected clients"
    else
        wg-quick up "$CONF"
        ok "brought ${WG_IFACE} up"
    fi
}

apply_firewall() {
    (( WG_UFW == 1 )) || { dim "UFW skipped (--no-ufw)"; return 0; }
    if ! command -v ufw >/dev/null 2>&1; then
        warn "ufw is not installed; open ${WG_PORT}/udp in the provider firewall instead"
        return 0
    fi
    ufw allow "${WG_PORT}/udp" comment "vulnserver-wireguard" >/dev/null
    ufw allow in on "$WG_IFACE" comment "vulnserver-tunnel" >/dev/null
    ufw status | grep -q "Status: active" || ufw --force enable >/dev/null
    ok "UFW allows ${WG_PORT}/udp and all traffic on ${WG_IFACE}"
}

publish_web() {
    local web_dir="${LAB_WEB_DIR:-${LAB_STATE_DIR}/web}"
    [[ -f "${web_dir}/docker-compose.yml" ]] \
        || die "no compose file at ${web_dir}; run install.sh first"
    command -v docker >/dev/null 2>&1 || die "docker is not installed"
    info "Rebinding Juice Shop to $(server_ip):${JUICE_SHOP_PORT} (tunnel only)"
    ( cd "$web_dir" && LAB_BIND_ADDR="$(server_ip)" JUICE_SHOP_PORT="$JUICE_SHOP_PORT" \
        docker compose up -d --force-recreate )
    ok "Juice Shop now listens only on the tunnel address"
    dim "verify from a client: curl -s -o /dev/null -w '%{http_code}\\n' http://$(server_ip):${JUICE_SHOP_PORT}/"
}

do_apply() {
    require_root "$@"
    check_deps wg wg-quick ip || die "install WireGuard first: apt install -y wireguard"

    if [[ -f "$CONF" ]] && ! grep -qF "$MANAGED_TAG" "$CONF" && (( WG_FORCE == 0 )); then
        die "${CONF} exists and was not created by this script; re-run with --force to take it over"
    fi

    # Refuse to end up with zero peers before touching the live interface:
    # an empty tunnel is unreachable and removing the last peer would lock
    # every client out.
    local name remaining old_endpoint
    old_endpoint=""
    [[ -r "${WG_DIR}/server.info" ]] && \
        old_endpoint="$(sed -n 's/^endpoint=//p' "${WG_DIR}/server.info" | head -n1)"

    remaining="$(used_peer_names)"
    for name in "${WG_REMOVE[@]}"; do
        remaining="$(printf '%s\n' "$remaining" | grep -vx "$name" || true)"
    done
    for name in "${WG_PEERS[@]}"; do
        remaining="$(printf '%s\n%s\n' "$remaining" "$name" | sed '/^$/d' | sort -u)"
    done
    [[ -n "$remaining" ]] \
        || die "this would leave zero peers; add one with --peer <name>"

    ensure_server_keys
    for name in "${WG_PEERS[@]}"; do add_peer "$name"; done
    for name in "${WG_REMOVE[@]}"; do remove_peer "$name"; done
    write_server_config
    reload_interface
    apply_firewall

    {
        printf 'endpoint=%s\n' "$WG_ENDPOINT"
        printf 'port=%s\n' "$WG_PORT"
        printf 'network=%s\n' "$WG_NET"
        printf 'updated=%s\n' "$(date +"$LAB_TS_FORMAT")"
    } > "${WG_DIR}/server.info"
    chmod 0600 "${WG_DIR}/server.info"

    if [[ "$old_endpoint" != "$WG_ENDPOINT" ]]; then
        warn "endpoint changed from '${old_endpoint:-none}' to '${WG_ENDPOINT}': regenerating every client config"
        while read -r name; do
            [[ -n "$name" ]] && write_client_config "$name"
        done < <(used_peer_names)
    else
        for name in "${WG_PEERS[@]}"; do write_client_config "$name"; done
    fi

    (( WG_PUBLISH_WEB == 1 )) && publish_web

    log_event "REMOTE_ACCESS_APPLY" "wireguard" "-" "SUCCESS" \
        "iface=${WG_IFACE} port=${WG_PORT} net=${WG_NET} peers=$(used_peer_names | tr '\n' ',' | sed 's/,$//')"

    hr
    ok "Remote access is configured"
    dim "1. Copy ${CLIENT_DIR}/<peer>.conf to the WireGuard app on that device."
    dim "2. Connect, then: ssh ${LAB_USER}@$(server_ip)"
    dim "3. Open the lab web app at http://$(server_ip):${JUICE_SHOP_PORT}/"
    dim "Provider firewall must allow ${WG_PORT}/udp; nothing else."
}

show_status() {
    hr
    info "WireGuard"
    if ! command -v wg >/dev/null 2>&1; then
        warn "wireguard-tools not installed on this host"
    elif ! ip link show "$WG_IFACE" >/dev/null 2>&1; then
        warn "interface ${WG_IFACE} is not up"
    else
        wg show "$WG_IFACE"
    fi

    hr
    info "Configured peers"
    if [[ -d "$PEER_DIR" ]]; then
        used_peer_names | while read -r n; do
            printf '  %-12s %-15s %s\n' "$n" "$(peer_field "$n" address)" \
                "$(cat "${PEER_DIR}/${n}.pub")"
        done
    else
        dim "none"
    fi

    hr
    info "Firewall"
    if command -v ufw >/dev/null 2>&1; then
        ufw status | sed -n '1p;/51820\|vulnserver/p'
    else
        dim "ufw not installed"
    fi

    hr
    info "Web application"
    local running
    if docker_ready; then
        running="$(docker ps --filter name=vulnserver-juice-shop --format \
            '  {{.Names}}  {{.Status}}  {{.Ports}}' 2>/dev/null || true)"
        if [[ -n "$running" ]]; then printf '%s\n' "$running"; else dim "not running"; fi
    else
        dim "docker not available"
    fi

    hr
    info "Tunnel address"
    ip -4 addr show "$WG_IFACE" 2>/dev/null | awk '/inet / {print "  " $2}' || dim "not configured"
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------
validate_inputs

case "$MODE" in
    status)
        show_status
        ;;
    *)
        if (( APPLY == 0 )); then
            print_plan
            hr
            warn "dry-run only: nothing was changed. Re-run with --apply to install."
            dim "Prerequisites: Ubuntu 24.04 VM with a public IP, wireguard installed,"
            dim "and ${WG_PORT}/udp allowed in the provider firewall."
        else
            print_plan
            hr
            do_apply "$@"
        fi
        ;;
esac
