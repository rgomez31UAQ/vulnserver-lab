#!/usr/bin/env bash
# =============================================================================
# VulnServer - install.sh
# Installs the laboratory on an Ubuntu Server 24.04 host.
#
#   sudo ./install.sh                     # full installation
#   sudo ./install.sh --activate all      # also enable every scenario
#   sudo ./install.sh --profile container # restricted profile (tests/CI)
#
# Options
#   -y, --yes               non-interactive (assumes yes for prompts)
#   -n, --dry-run           print actions, change nothing
#       --install-deps      apt-get install missing dependencies
#       --no-docker         do not install/start Docker or Juice Shop
#       --no-firewall       do not touch UFW
#       --no-auditd         do not install auditd rules
#       --no-ssh            do not modify sshd configuration
#       --port N            Juice Shop port (default 3000)
#       --activate a,b,c    activate scenarios after installation
#       --skip-os-check     allow non-Ubuntu hosts (lab VMs only)
#       --profile container restricted profile: no apt, no systemd, no firewall
#
# Safety: the script never overwrites an existing host sshd_config; it adds a
# drop-in and validates it before reloading. Every step is logged.
# =============================================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
DO_DOCKER=1; DO_FIREWALL=1; DO_AUDITD=1; DO_SSH=1
INSTALL_DEPS=0; SKIP_OS_CHECK=0; ACTIVATE_LIST=""
while (( $# > 0 )); do
    case "$1" in
        -y|--yes)        ASSUME_YES=1; shift ;;
        -n|--dry-run)    DRY_RUN=1;    shift ;;
        --install-deps)  INSTALL_DEPS=1; shift ;;
        --no-docker)     DO_DOCKER=0; shift ;;
        --no-firewall)   DO_FIREWALL=0; shift ;;
        --no-auditd)     DO_AUDITD=0; shift ;;
        --no-ssh)        DO_SSH=0; shift ;;
        --port)          JUICE_SHOP_PORT="${2:?--port needs a value}"; shift 2 ;;
        --activate)      ACTIVATE_LIST="${2:?--activate needs a list, e.g. a,b,c}"; shift 2 ;;
        --skip-os-check) SKIP_OS_CHECK=1; shift ;;
        --profile)
            LAB_PROFILE="${2:?--profile needs vm|container}"
            [[ "$LAB_PROFILE" == "container" ]] && { DO_DOCKER=0; DO_FIREWALL=0; DO_AUDITD=0; DO_SSH=0; INSTALL_DEPS=0; SKIP_OS_CHECK=1; }
            shift 2 ;;
        -h|--help)       sed -n '2,30p' "$0"; exit 0 ;;
        *) die "unknown option: $1 (try --help)" ;;
    esac
done
export ASSUME_YES DRY_RUN LAB_PROFILE JUICE_SHOP_PORT

trap 'err "installation failed at line $LINENO"; log_event "INSTALL" "core" "-" "FAILURE" "line=$LINENO"' ERR

# ---------------------------------------------------------------------------
# Pre-flight
# ---------------------------------------------------------------------------
preflight() {
    banner
    require_root "$@"
    [[ "$LAB_PROFILE" == "vm" ]] || warn "restricted profile: ${LAB_PROFILE} (no apt/systemd/firewall changes)"

    if [[ "$SKIP_OS_CHECK" != "1" && "$REQUIRE_UBUNTU" == "1" ]]; then
        if [[ -r /etc/os-release ]]; then
            # shellcheck disable=SC1091
            source /etc/os-release
            if [[ "${ID:-}" != "ubuntu" ]]; then
                die "this installer targets Ubuntu Server 24.04 (found: ${PRETTY_NAME:-unknown}). Use --skip-os-check only for disposable lab VMs."
            fi
            if [[ "${VERSION_ID:-}" != "24.04" ]]; then
                warn "expected Ubuntu 24.04, found ${VERSION_ID:-unknown}; continuing"
            fi
        fi
    fi

    local -a required=(bash openssl)
    check_deps "${required[@]}" || die "install the missing base packages first"

    # Port sanity
    if ! [[ "$JUICE_SHOP_PORT" =~ ^[0-9]+$ ]] || (( JUICE_SHOP_PORT < 1 || JUICE_SHOP_PORT > 65535 )); then
        die "invalid port: ${JUICE_SHOP_PORT}"
    fi

    if [[ "$LAB_PROFILE" == "vm" ]] && port_open "$JUICE_SHOP_PORT" && ! docker_ready; then
        warn "port ${JUICE_SHOP_PORT} is already in use by another service"
    fi
    log_event "INSTALL_START" "core" "-" "STARTED" "profile=${LAB_PROFILE} port=${JUICE_SHOP_PORT}"
}

# ---------------------------------------------------------------------------
# Dependencies
# ---------------------------------------------------------------------------
install_dependencies() {
    info "Checking dependencies"
    local -a packages=() missing=()
    local cmd pkg
    for pair in "jq:jq" "curl:curl" "sed:sed" "grep:grep" "tar:tar" \
                "useradd:passwd" "visudo:sudo" "cron:cron" "chpasswd:passwd"; do
        cmd="${pair%%:*}"; pkg="${pair##*:}"
        command -v "$cmd" >/dev/null 2>&1 || missing+=("$pkg")
    done
    (( DO_FIREWALL == 1 )) && { command -v ufw >/dev/null 2>&1 || missing+=("ufw"); }
    (( DO_AUDITD == 1 ))  && { command -v auditctl >/dev/null 2>&1 || missing+=("auditd" "audispd-plugins"); }

    if (( ${#missing[@]} == 0 )); then
        ok "dependencies present"; return 0
    fi
    warn "missing packages: ${missing[*]}"
    if (( INSTALL_DEPS == 0 )); then
        warn "re-run with --install-deps to install them automatically"; return 0
    fi
    (( DRY_RUN == 1 )) && { dim "[dry-run] apt-get install ${missing[*]}"; return 0; }
    info "Installing packages (non-interactive)"
    DEBIAN_FRONTEND=noninteractive apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${missing[@]}"
    ok "packages installed"
}

# ---------------------------------------------------------------------------
# State tree and modules
# ---------------------------------------------------------------------------
setup_tree() {
    info "Preparing state tree and baseline permissions"
    "$SCRIPT_DIR/scripts/permissions/apply_permissions.sh" base
    # Installed copy of the toolkit: the lab keeps working if the git checkout
    # is moved or removed.
    install -d -m 0755 -o root -g root "$LAB_BIN_DIR" "$LAB_BIN_DIR"/{scripts,lib,config}
    cp -a "$SCRIPT_DIR/lib/." "$LAB_BIN_DIR/lib/"
    cp -a "$SCRIPT_DIR/scripts/." "$LAB_BIN_DIR/scripts/"
    cp -a "$SCRIPT_DIR/config/." "$LAB_BIN_DIR/config/"
    find "$LAB_BIN_DIR" -type f -name '*.sh' -exec chmod 0755 {} +
    ok "toolkit installed in ${LAB_BIN_DIR}"
}

setup_accounts() {
    info "Creating laboratory accounts"
    "$SCRIPT_DIR/scripts/users/create_users.sh" create
    "$SCRIPT_DIR/scripts/sudo/apply_sudo.sh" base
    "$SCRIPT_DIR/scripts/sudo/apply_sudo.sh" validate
    "$SCRIPT_DIR/scripts/cron/apply_cron.sh" base || warn "cron baseline incomplete (scenario C will need it)"
}

setup_flags() {
    info "Generating flags"
    "$SCRIPT_DIR/scripts/flags/generate_flags.sh" generate
    "$SCRIPT_DIR/scripts/flags/generate_flags.sh" verify
}

# ---------------------------------------------------------------------------
# SSH
# ---------------------------------------------------------------------------
setup_ssh() {
    (( DO_SSH == 1 )) || { dim "ssh configuration skipped (--no-ssh)"; return 0; }
    info "Configuring SSH (drop-in, root login disabled)"
    check_deps sshd || { warn "sshd not installed, skipping SSH configuration"; return 0; }

    install -d -m 0755 /etc/ssh/sshd_config.d
    install -m 0644 -o root -g root "$SCRIPT_DIR/config/ssh/99-vulnserver.conf" \
        /etc/ssh/sshd_config.d/99-vulnserver.conf

    # Ubuntu's default sshd_config includes sshd_config.d/*.conf; confirm it.
    if ! grep -Eq '^\s*Include\s+/etc/ssh/sshd_config\.d/\*\.conf' /etc/ssh/sshd_config; then
        warn "/etc/ssh/sshd_config does not include sshd_config.d - review manually"
    fi

    if ! sshd -t; then
        rm -f /etc/ssh/sshd_config.d/99-vulnserver.conf
        die "sshd configuration test failed; drop-in removed so SSH stays reachable"
    fi
    run_cmd systemctl reload ssh 2>/dev/null || run_cmd systemctl reload sshd 2>/dev/null || \
        warn "could not reload sshd; restart it manually"
    log_event "SSH_CONFIGURE" "sshd" "-" "SUCCESS" "allowusers=adminlab,labuser root_login=no"
    ok "SSH configured (root login disabled, labuser password login enabled)"
}

# ---------------------------------------------------------------------------
# Docker + Juice Shop
# ---------------------------------------------------------------------------
setup_docker() {
    (( DO_DOCKER == 1 )) || { dim "docker/Juice Shop skipped (--no-docker)"; return 0; }
    info "Checking Docker"
    if ! command -v docker >/dev/null 2>&1; then
        if (( INSTALL_DEPS == 1 )); then
            info "Installing Docker from the distribution repository"
            run_cmd env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq docker.io docker-compose-v2 \
                || die "Docker installation failed; see docs/TROUBLESHOOTING.md"
        else
            die "Docker is missing. Re-run with --install-deps or install docker.io + docker-compose-v2"
        fi
    fi
    has_systemd && run_cmd systemctl enable --now docker >/dev/null 2>&1 || true
    docker_ready || die "Docker daemon is not reachable (systemctl status docker)"

    # Never expose the Docker API over TCP.
    if [[ -e /etc/docker/daemon.json ]] && grep -q '"hosts"' /etc/docker/daemon.json; then
        warn "/etc/docker/daemon.json configures a TCP API endpoint - remove it in a lab host"
    fi
}

setup_web() {
    (( DO_DOCKER == 1 )) || return 0
    info "Deploying OWASP Juice Shop on port ${JUICE_SHOP_PORT}"
    install -d -m 0755 -o root -g root "$LAB_WEB_DIR"
    install -m 0644 "$SCRIPT_DIR/web/docker-compose.yml" "$LAB_WEB_DIR/docker-compose.yml"

    if [[ ! -f "$LAB_WEB_DIR/.env" ]]; then
        cat > "$LAB_WEB_DIR/.env" <<EOF
# Generated by install.sh on $(date +"$LAB_TS_FORMAT") - see web/.env.example
JUICE_SHOP_IMAGE=${JUICE_SHOP_IMAGE}
JUICE_SHOP_PORT=${JUICE_SHOP_PORT}
LAB_BIND_ADDR=${LAB_BIND_ADDR}
JUICE_SHOP_MEMORY_LIMIT=${JUICE_SHOP_MEMORY_LIMIT}
JUICE_SHOP_VOLUME=${JUICE_SHOP_VOLUME}
LAB_NET_NAME=${LAB_NET_NAME}
LAB_NET_SUBNET=${LAB_NET_SUBNET}
EOF
        chmod 0640 "$LAB_WEB_DIR/.env"
    else
        sed -i "s/^JUICE_SHOP_PORT=.*/JUICE_SHOP_PORT=${JUICE_SHOP_PORT}/" "$LAB_WEB_DIR/.env"
    fi

    ( cd "$LAB_WEB_DIR" && run_cmd docker compose pull -q && run_cmd docker compose up -d ) \
        || die "Juice Shop failed to start (docker compose logs in ${LAB_WEB_DIR})"
    log_event "DOCKER_DEPLOY" "juice-shop" "-" "SUCCESS" "port=${JUICE_SHOP_PORT} image=${JUICE_SHOP_IMAGE}"

    info "Waiting for Juice Shop to answer on http://127.0.0.1:${JUICE_SHOP_PORT}/"
    local i
    for i in $(seq 1 30); do
        if curl -fsS --max-time 3 "http://127.0.0.1:${JUICE_SHOP_PORT}/" >/dev/null 2>&1; then
            ok "Juice Shop is responding"; return 0
        fi
        sleep 2
    done
    warn "Juice Shop did not respond within 60s; check: docker compose -f ${LAB_WEB_DIR}/docker-compose.yml logs"
    log_event "DOCKER_DEPLOY" "juice-shop" "-" "WARNING" "no HTTP response within 60s"
}

# ---------------------------------------------------------------------------
# Firewall / audit
# ---------------------------------------------------------------------------
setup_firewall() {
    (( DO_FIREWALL == 1 )) || { dim "firewall skipped (--no-firewall)"; return 0; }
    info "Applying firewall rules"
    "$SCRIPT_DIR/config/ufw/ufw-rules.sh" apply || warn "firewall step incomplete"
}

setup_audit() {
    (( DO_AUDITD == 1 )) || { dim "auditd skipped (--no-auditd)"; return 0; }
    info "Configuring auditd"
    "$SCRIPT_DIR/scripts/monitoring/setup_audit.sh" apply || warn "auditd step incomplete"
}

activate_scenarios() {
    [[ -n "$ACTIVATE_LIST" ]] || { dim "scenarios left inactive (use --activate a,b,c or lab-manager.sh)"; return 0; }
    local id
    IFS=',' read -ra ids <<< "$ACTIVATE_LIST"
    for id in "${ids[@]}"; do
        info "Activating scenario ${id}"
        "$SCRIPT_DIR/scripts/scenarios/scenario-$(printf '%s' "$id" | tr '[:upper:]' '[:lower:]').sh" activate \
            || warn "scenario ${id} did not activate cleanly"
    done
}

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
summary() {
    hr
    ok "VulnServer ${LAB_VERSION} installed"
    printf '\n  State directory : %s\n' "$LAB_STATE_DIR"
    printf '  Toolchain       : %s\n' "$LAB_BIN_DIR"
    printf '  Flags           : %s\n' "$LAB_FLAG_DIR"
    printf '  Logs            : %s\n' "$LAB_LOG_DIR"
    if (( DO_DOCKER == 1 )); then
        printf '  Juice Shop      : http://<lab-ip>:%s\n' "$JUICE_SHOP_PORT"
    fi
    printf '  SSH             : port %s, users %s,%s (root login disabled)\n' "$SSH_PORT" "$ADMIN_USER" "$LAB_USER"
    printf '  Allowed networks: %s\n' "$SSH_ALLOWED_NETS"
    hr
    printf 'Next steps:\n'
    printf '  1. %s/lab-manager.sh            (status / scenario control)\n' "$LAB_BIN_DIR"
    printf '  2. %s/audit.sh                  (read-only audit)\n' "$LAB_BIN_DIR"
    printf '  3. docs/ATTACKER_GUIDE.md       (hand this to the participant)\n'
    hr
    warn "This host is intentionally vulnerable. Keep it on an isolated network."
    log_event "INSTALL_COMPLETE" "core" "-" "SUCCESS" "port=${JUICE_SHOP_PORT} profile=${LAB_PROFILE}"
}

# ---------------------------------------------------------------------------
main() {
    preflight
    install_dependencies
    setup_tree
    setup_accounts
    setup_flags
    setup_ssh
    setup_docker
    setup_web
    setup_firewall
    setup_audit
    activate_scenarios
    summary
}
main "$@"
