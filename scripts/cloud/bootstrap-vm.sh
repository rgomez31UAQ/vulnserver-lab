#!/usr/bin/env bash
# =============================================================================
# VulnServer - scripts/cloud/bootstrap-vm.sh
#
# Runs ON a fresh Ubuntu 24.04 VM, as root, and turns it into the finished lab:
# WireGuard tunnel first, lab second, web app on the tunnel address only.
#
# It is called in three ways:
#   * by cloud-init (see cloud-init/user-data.yaml.tpl)
#   * by scripts/cloud/provision.sh over SSH
#   * by hand: sudo PEER=owner ./scripts/cloud/bootstrap-vm.sh
#
# Every step is idempotent, so a failed run can be repeated safely.
#
# Environment:
#   LAB_DIR            project location on the VM   (default /root/vulnserver)
#   PEER               WireGuard peer name          (default owner)
#   WG_PORT            WireGuard UDP port           (default 51820)
#   PUBLIC_IP          endpoint; auto-detected from the cloud metadata service
#   LAB_INSTALL_ARGS   arguments for install.sh
#                      (default: --install-deps --activate a,b,c --yes)
#   LAB_BIND_ADDR      web bind address             (default 10.8.0.1)
# =============================================================================
set -euo pipefail

LAB_DIR="${LAB_DIR:-/root/vulnserver}"
PEER="${PEER:-owner}"
WG_PORT="${WG_PORT:-51820}"
PUBLIC_IP="${PUBLIC_IP:-}"
LAB_BIND_ADDR="${LAB_BIND_ADDR:-10.8.0.1}"
LAB_INSTALL_ARGS="${LAB_INSTALL_ARGS:---install-deps --activate a,b,c --yes}"
LOG_FILE="${LOG_FILE:-/var/log/vulnserver-bootstrap.log}"
MARKER="${LAB_DIR}/.bootstrap-complete"

# Mirror everything to the console (cloud-init logs) and to a file.
exec > >(tee -a "$LOG_FILE") 2>&1

say() { printf '[bootstrap %s] %s\n' "$(date +%H:%M:%S)" "$*"; }
fail() { printf '[bootstrap] ERROR: %s\n' "$*" >&2; exit 1; }

[[ "${EUID}" -eq 0 ]] || fail "run as root (sudo $0)"
[[ -d "$LAB_DIR" ]] || fail "project not found at ${LAB_DIR}; copy it first"

cd "$LAB_DIR"
say "bootstrapping ${LAB_DIR} on $(hostname)"

# -----------------------------------------------------------------------------
# 1. Base packages
# -----------------------------------------------------------------------------
if ! command -v wg >/dev/null 2>&1 || ! command -v curl >/dev/null 2>&1; then
    say "installing wireguard-tools and curl"
    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
        wireguard-tools curl ca-certificates || fail "apt-get install failed"
fi

# -----------------------------------------------------------------------------
# 2. Public endpoint (needed for the client configs, never for the tunnel itself)
# -----------------------------------------------------------------------------
detect_public_ip() {
    local url candidate
    for url in \
        "http://169.254.169.254/hetzner/v1/metadata/public-ipv4" \
        "http://169.254.169.254/v1/interfaces/public/0/ipv4/address" \
        "https://api.ipify.org"; do
        candidate="$(curl -fsS --max-time 4 "$url" 2>/dev/null | tr -d '[:space:]')" || continue
        [[ "$candidate" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || continue
        printf '%s' "$candidate"
        return 0
    done
    return 1
}

if [[ -z "$PUBLIC_IP" ]]; then
    PUBLIC_IP="$(detect_public_ip)" || fail "cannot detect the public IP; re-run with PUBLIC_IP=<address>"
    say "public endpoint detected: ${PUBLIC_IP}"
fi

# -----------------------------------------------------------------------------
# 3. Tunnel first: Juice Shop binds 10.8.0.1, which must exist beforehand
# -----------------------------------------------------------------------------
say "configuring WireGuard (${WG_PORT}/udp, peer ${PEER})"
./scripts/remote/setup_remote_access.sh --apply \
    --endpoint "$PUBLIC_IP" --peer "$PEER" --port "$WG_PORT" --yes \
    || fail "WireGuard setup failed"

ip link show wg0 >/dev/null 2>&1 || fail "wg0 did not come up"
say "wg0 is up: $(ip -4 -o addr show wg0 | awk '{print $4}')"

# -----------------------------------------------------------------------------
# 4. Laboratory
# -----------------------------------------------------------------------------
say "installing the lab: ./install.sh ${LAB_INSTALL_ARGS}"
# Word splitting is intentional: LAB_INSTALL_ARGS is an argument list.
# shellcheck disable=SC2086
LAB_BIND_ADDR="$LAB_BIND_ADDR" \
SSH_ALLOWED_NETS="10.8.0.0/24" \
LAB_ALLOWED_NETS="10.8.0.0/24" \
    ./install.sh $LAB_INSTALL_ARGS || fail "install.sh failed; see ${LOG_FILE}"

# -----------------------------------------------------------------------------
# 5. Verification and completion marker
# -----------------------------------------------------------------------------
say "verification"
wg show wg0 >/dev/null 2>&1 && say "  tunnel: ok" || fail "tunnel check failed"

if [[ "$LAB_INSTALL_ARGS" == *"--profile container"* ]]; then
    say "  restricted profile: skipping docker/web checks"
else
    code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 \
        "http://${LAB_BIND_ADDR}:${JUICE_SHOP_PORT:-3000}/" || true)"
    [[ "$code" == "200" ]] && say "  web app: HTTP ${code}" \
        || fail "web app not answering on ${LAB_BIND_ADDR} (HTTP ${code:-none})"
fi

{
    printf 'completed=%s\n' "$(date -Is)"
    printf 'host=%s\n' "$(hostname)"
    printf 'endpoint=%s\n' "$PUBLIC_IP"
    printf 'peer=%s\n' "$PEER"
    printf 'wg_port=%s\n' "$WG_PORT"
    printf 'bind=%s\n' "$LAB_BIND_ADDR"
    printf 'install_args=%s\n' "$LAB_INSTALL_ARGS"
} > "$MARKER"
chmod 0600 "$MARKER"

say "client configs: /etc/wireguard/clients/"
say "done. Connect the tunnel first, then ssh into 10.8.0.1"
