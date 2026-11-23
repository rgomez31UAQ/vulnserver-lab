#!/usr/bin/env bash
# =============================================================================
# VulnServer - scripts/cloud/provision.sh
#
# One command: create a Hetzner or Vultr VM, open only UDP 51820 (plus SSH from
# your address), copy the project over SSH and bootstrap the lab + WireGuard.
#
#   export HCLOUD_TOKEN=...          # https://console.hetzner.cloud -> Project -> Security -> API tokens
#   ./scripts/cloud/provision.sh --provider hetzner --name vulnserver-1
#
#   export VULTR_API_KEY=...
#   ./scripts/cloud/provision.sh --provider vultr --name vulnserver-1
#
#   ./scripts/cloud/provision.sh --provider hetzner --name vulnserver-1 --destroy
#
# Repo stays private: the project is uploaded over SSH, no GitHub token needed.
# For a public repo you can pass --user-data <cloud-init file> instead and skip
# the upload/bootstrap phase (--no-bootstrap).
#
# WireGuard client configs are copied to ./clients/ (gitignored, mode 0700).
# Nothing is destroyed automatically on failure: the VM is kept so you can
# inspect it, and the state file lets --destroy clean it up.
# =============================================================================
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# Overridable so the test suite never touches the real state or client keys.
STATE_DIR="${VULNSERVER_PROVISION_DIR:-${REPO_DIR}/provision}"
CLIENT_DIR="${VULNSERVER_CLIENT_DIR:-${REPO_DIR}/clients}"

PROVIDER="" NAME="" REGION="" PLAN=""
SSH_KEY="${HOME}/.ssh/id_ed25519.pub" SSH_USER="root"
PEER="owner" WG_PORT="51820" ADMIN_CIDR="" LAB_ARGS="--install-deps --activate a,b,c --yes"
TOKEN="" TOKEN_FILE="" API_BASE="" USER_DATA=""
DESTROY=0 NO_BOOTSTRAP=0 ASSUME_YES=0 DRY_RUN=0 KEEP=0

# -----------------------------------------------------------------------------
# Output
# -----------------------------------------------------------------------------
if [[ -t 1 ]]; then
    C_RED=$'\033[31m'; C_GRN=$'\033[32m'; C_YEL=$'\033[33m'; C_BLU=$'\033[36m'; C_OFF=$'\033[0m'
else
    C_RED=""; C_GRN=""; C_YEL=""; C_BLU=""; C_OFF=""
fi
info() { printf '%s[*]%s %s\n' "$C_BLU" "$C_OFF" "$*"; }
ok()   { printf '%s[+]%s %s\n' "$C_GRN" "$C_OFF" "$*"; }
warn() { printf '%s[!]%s %s\n' "$C_YEL" "$C_OFF" "$*" >&2; }
die()  { printf '%s[x]%s %s\n' "$C_RED" "$C_OFF" "$*" >&2; exit 1; }

usage() {
    cat <<'EOF'
Usage: provision.sh --provider hetzner|vultr [options]

Required:
  --provider NAME        hetzner | vultr
  --name NAME            VM name, lowercase (default: vulnserver-<MMDD-HHMM>)

Provider:
  --region NAME          hetzner: fsn1 (default) | vultr: fra (default)
  --plan NAME            hetzner server type (default cx23)
                         vultr plan id (default vc2-2c-4gb)
  --api-base URL         override API endpoint (tests / mock server)

Access:
  --token-file PATH      read the API token from a file instead of the env var
  --ssh-key PATH         public key to install (default ~/.ssh/id_ed25519.pub)
  --ssh-user NAME        VM user for the upload (default root)
  --peer NAME            WireGuard peer for you (default owner)
  --wg-port PORT         UDP port (default 51820)
  --admin-cidr CIDR      who may reach SSH (default: your current public IP /32)
  --lab-args ARGS        install.sh arguments
                         (default "--install-deps --activate a,b,c --yes")

Behaviour:
  --user-data FILE       pass cloud-init user data at create time and skip the
                         SSH upload/bootstrap (requires a public repo URL)
  --no-bootstrap         create the VM and stop (no SSH wait, no upload)
  --dry-run              print the plan without calling the provider
  --destroy              delete the VM and firewall recorded in the state file
  --keep                 with --destroy: keep the firewall and SSH key
  -y, --yes              do not ask for confirmation
  -h, --help             this help

Environment: HCLOUD_TOKEN (hetzner), VULTR_API_KEY (vultr)
State:       provision/<provider>-<name>.env
EOF
}

# -----------------------------------------------------------------------------
# Arguments
# -----------------------------------------------------------------------------
while (( $# > 0 )); do
    case "$1" in
        --provider)   PROVIDER="${2:?}"; shift 2 ;;
        --name)       NAME="${2:?}"; shift 2 ;;
        --region|--location) REGION="${2:?}"; shift 2 ;;
        --plan|--type) PLAN="${2:?}"; shift 2 ;;
        --token-file) TOKEN_FILE="${2:?}"; shift 2 ;;
        --ssh-key)    SSH_KEY="${2:?}"; shift 2 ;;
        --ssh-user)   SSH_USER="${2:?}"; shift 2 ;;
        --peer)       PEER="${2:?}"; shift 2 ;;
        --wg-port)    WG_PORT="${2:?}"; shift 2 ;;
        --admin-cidr) ADMIN_CIDR="${2:?}"; shift 2 ;;
        --lab-args)   LAB_ARGS="${2:?}"; shift 2 ;;
        --user-data)  USER_DATA="${2:?}"; shift 2 ;;
        --api-base)   API_BASE="${2:?}"; shift 2 ;;
        --no-bootstrap) NO_BOOTSTRAP=1; shift ;;
        --dry-run)    DRY_RUN=1; shift ;;
        --destroy)    DESTROY=1; shift ;;
        --keep)       KEEP=1; shift ;;
        -y|--yes)     ASSUME_YES=1; shift ;;
        -h|--help)    usage; exit 0 ;;
        *)            die "unknown option: $1 (try --help)" ;;
    esac
done

[[ -n "$PROVIDER" ]] || { usage; die "--provider is required"; }
[[ "$PROVIDER" == hetzner || "$PROVIDER" == vultr ]] || die "--provider must be hetzner or vultr"
[[ -n "$NAME" ]] || NAME="vulnserver-$(date +%m%d-%H%M)"
[[ "$NAME" =~ ^[a-z][a-z0-9-]{1,40}$ ]] || die "--name must be lowercase letters, digits and dashes (max 41)"

case "$PROVIDER" in
    hetzner)
        API_BASE="${API_BASE:-https://api.hetzner.cloud/v1}"
        REGION="${REGION:-fsn1}"; PLAN="${PLAN:-cx23}"
        TOKEN="${HCLOUD_TOKEN:-}"
        ;;
    vultr)
        API_BASE="${API_BASE:-https://api.vultr.com/v2}"
        REGION="${REGION:-fra}"; PLAN="${PLAN:-vc2-2c-4gb}"
        TOKEN="${VULTR_API_KEY:-}"
        ;;
esac
if [[ -n "$TOKEN_FILE" ]]; then
    [[ -r "$TOKEN_FILE" ]] || die "cannot read token file: ${TOKEN_FILE}"
    TOKEN="$(tr -d '[:space:]' < "$TOKEN_FILE")"
fi

[[ "$PEER" =~ ^[a-z0-9][a-z0-9-]{0,20}$ ]] || die "invalid --peer"
[[ "$LAB_ARGS" =~ ^[-A-Za-z0-9,=_.\ ]+$ ]] || die "invalid --lab-args"
[[ "$WG_PORT" =~ ^[0-9]+$ ]] || die "invalid --wg-port"

STATE_FILE="${STATE_DIR}/${PROVIDER}-${NAME}.env"
TARBALL="/tmp/vulnserver-${NAME}.tar.gz"

need() { command -v "$1" >/dev/null 2>&1 || die "missing dependency: $1"; }
for c in curl jq ssh scp tar; do need "$c"; done

# -----------------------------------------------------------------------------
# Provider API
# -----------------------------------------------------------------------------
api() { # METHOD PATH [JSON]
    local method="$1" path="$2" body="${3-}" raw code payload
    local -a args=(-sS -X "$method" -H "Authorization: Bearer ${TOKEN}" -H "Accept: application/json")
    [[ -n "$body" ]] && args+=(-H "Content-Type: application/json" --data-binary "$body")
    raw="$(curl "${args[@]}" -w $'\n%{http_code}' "${API_BASE}${path}")" \
        || die "network error: ${method} ${path}"
    code="${raw##*$'\n'}"
    payload="${raw%$'\n'*}"
    if [[ "$code" != 2* ]]; then
        warn "API ${method} ${path} -> HTTP ${code}"
        printf '%s\n' "$payload" | jq -r '(.error.message? // .error? // .message? // .)' 2>/dev/null \
            || printf '%s\n' "$payload"
        exit 1
    fi
    # 204 responses carry no body; the function must still succeed.
    if [[ -n "$payload" ]]; then
        printf '%s\n' "$payload"
    fi
    return 0
}

get()  { api GET "$1"; }
post() { api POST "$1" "$2"; }
del()  { api DELETE "$1" >/dev/null; }

# -----------------------------------------------------------------------------
# Image / plan / key / firewall
# -----------------------------------------------------------------------------
resolve_image() {
    case "$PROVIDER" in
        hetzner)
            get "/images?type=system&architecture=x86&name=ubuntu-24.04" \
                | jq -r '.images[0].id // empty'
            ;;
        vultr)
            get "/os?per_page=500" \
                | jq -r '[.os[] | select(.name | test("Ubuntu 24.04")) | select(.name | test("x64"))][0].id // empty'
            ;;
    esac
}

check_plan() {
    case "$PROVIDER" in
        hetzner)
            if [[ "$(get "/server_types?per_page=50" | jq -r --arg p "$PLAN" '[.server_types[]|select(.name==$p)]|length')" == 0 ]]; then
                warn "server type '${PLAN}' not found. 2 vCPU / >=4 GB candidates:"
                get "/server_types?per_page=50" | jq -r '.server_types[]|select(.cores>=2 and .memory>=4)|"  \(.name)  \(.cores) vCPU  \(.memory) GB  \(.disk) GB disk"'
                die "choose one with --plan"
            fi
            ;;
        vultr)
            if [[ "$(get "/plans?per_page=500" | jq -r --arg p "$PLAN" '[.plans[]|select(.id==$p)]|length')" == 0 ]]; then
                warn "plan '${PLAN}' not found. 2 vCPU / >=4 GB candidates:"
                get "/plans?per_page=500" | jq -r '.plans[]|select(.vcpu_count>=2 and .ram>=4096)|"  \(.id)  \(.vcpu_count) vCPU  \(.ram) MB  \(.disk) GB"' | head -10
                die "choose one with --plan"
            fi
            ;;
    esac
}

ensure_ssh_key() {
    local name="vulnserver-${NAME}" pub id
    pub="$(<"$SSH_KEY")"
    case "$PROVIDER" in
        hetzner)
            id="$(get "/ssh_keys?name=${name}" | jq -r '.ssh_keys[0].id // empty')"
            if [[ -z "$id" ]]; then
                id="$(post "/ssh_keys" "$(jq -n --arg n "$name" --arg k "$pub" '{name:$n, public_key:$k}')" | jq -r '.ssh_key.id')"
                [[ -n "$id" ]] || die "could not register the SSH key"
            fi
            ;;
        vultr)
            id="$(get "/ssh-keys?per_page=500" | jq -r --arg n "$name" '[.ssh_keys[]|select(.name==$n)][0].id // empty')"
            if [[ -z "$id" ]]; then
                id="$(post "/ssh-keys" "$(jq -n --arg n "$name" --arg k "$pub" '{name:$n, ssh_key:$k}')" | jq -r '.ssh_key.id')"
                [[ -n "$id" ]] || die "could not register the SSH key"
            fi
            ;;
    esac
    printf '%s' "$id"
}

# Accepts either 1.2.3.4/32 or 1.2.3.4 and echoes "address prefix" per provider.
ensure_firewall() {
    local name="vulnserver-${NAME}" id
    local ip prefix
    ip="${ADMIN_CIDR%%/*}"; prefix="${ADMIN_CIDR#*/}"
    [[ "$prefix" != "$ADMIN_CIDR" ]] || prefix=32
    case "$PROVIDER" in
        hetzner)
            id="$(get "/firewalls?name=${name}" | jq -r '.firewalls[0].id // empty')"
            if [[ -z "$id" ]]; then
                id="$(post "/firewalls" "$(jq -n --arg n "$name" --arg ssh "${ip}/${prefix}" --arg wg "$WG_PORT" '
                    {name:$n, rules:[
                      {direction:"in", protocol:"udp", port:$wg, source_ips:["0.0.0.0/0","::/0"], description:"wireguard"},
                      {direction:"in", protocol:"tcp", port:"22", source_ips:[$ssh], description:"ssh-admin"}
                    ]}')" | jq -r '.firewall.id')"
            fi
            ;;
        vultr)
            id="$(post "/firewalls/group" "$(jq -n --arg n "$name" '{description:$n}')" | jq -r '.firewall_group.id')"
            [[ -n "$id" ]] || die "could not create the firewall group"
            post "/firewalls/group/${id}/rules" \
                "$(jq -n --arg wg "$WG_PORT" '{ip_type:"v4", protocol:"udp", subnet:"0.0.0.0", subnet_size:0, port:$wg, description:"wireguard"}')" >/dev/null
            post "/firewalls/group/${id}/rules" \
                "$(jq -n --arg ip "$ip" --argjson p "$prefix" '{ip_type:"v4", protocol:"tcp", subnet:$ip, subnet_size:$p, port:"22", description:"ssh-admin"}')" >/dev/null
            ;;
    esac
    [[ -n "$id" ]] || die "could not create the firewall"
    printf '%s' "$id"
}

delete_firewall() {
    local id="$1"
    case "$PROVIDER" in
        hetzner) del "/firewalls/${id}" ;;
        vultr)   del "/firewalls/group/${id}" ;;
    esac
}

# -----------------------------------------------------------------------------
# Server
# -----------------------------------------------------------------------------
create_server() {
    local image="$1" key="$2" fw="$3" body
    case "$PROVIDER" in
        hetzner)
            body="$(jq -n --arg n "$NAME" --arg t "$PLAN" --arg i "$image" --arg loc "$REGION" \
                --arg k "$key" --arg f "$fw" '
                {name:$n, server_type:$t, image:($i|tonumber), location:$loc,
                 ssh_keys:[($k|tonumber)], firewalls:[{firewall:($f|tonumber)}],
                 labels:{project:"vulnserver"}}')" || die "could not build the server request"
            if [[ -n "$USER_DATA" ]]; then
                body="$(jq --arg u "$(cat "$USER_DATA")" '. + {user_data:$u}' <<<"$body")" \
                    || die "could not attach user-data"
            fi
            post "/servers" "$body"
            ;;
        vultr)
            body="$(jq -n --arg n "$NAME" --arg p "$PLAN" --arg i "$image" --arg r "$REGION" \
                --arg k "$key" --arg f "$fw" '
                {label:$n, hostname:$n, plan:$p, os_id:($i|tonumber), region:$r,
                 sshkey_id:[$k], firewall_group_id:$f, backups:"disabled"}')" \
                || die "could not build the server request"
            if [[ -n "$USER_DATA" ]]; then
                body="$(jq --arg u "$(base64 -w0 < "$USER_DATA")" '. + {user_data:$u}' <<<"$body")" \
                    || die "could not attach user-data"
            fi
            post "/instances" "$body"
            ;;
    esac
}

server_id_of() {
    case "$PROVIDER" in
        hetzner) jq -r '.server.id' ;;
        vultr)   jq -r '.instance.id' ;;
    esac
}

server_ip_of() {
    case "$PROVIDER" in
        hetzner) jq -r '.server.public_net.ipv4.ip // empty' ;;
        vultr)   jq -r '.instance.main_ip // empty' ;;
    esac
}

server_running() {
    case "$PROVIDER" in
        hetzner) jq -r '.server.status == "running"' ;;
        vultr)   jq -r '(.instance.status == "active") and (.instance.main_ip != "0.0.0.0")' ;;
    esac
}

wait_server() { # SERVER_ID -> prints JSON
    local id="$1" json i
    for i in $(seq 1 60); do
        json="$(get "$( [[ "$PROVIDER" == hetzner ]] && echo "/servers/${id}" || echo "/instances/${id}" )")"
        if [[ "$(server_running <<<"$json")" == "true" ]]; then
            printf '%s\n' "$json"
            return 0
        fi
        sleep 5
    done
    die "server ${id} did not become running within 5 minutes"
}

# -----------------------------------------------------------------------------
# Bootstrap over SSH
# -----------------------------------------------------------------------------
SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR
          -o ConnectTimeout=10 -o ServerAliveInterval=15)

wait_ssh() { # HOST
    local host="$1" i
    for i in $(seq 1 60); do
        if ssh "${SSH_OPTS[@]}" -i "${SSH_KEY%.pub}" "${SSH_USER}@${host}" true 2>/dev/null; then
            return 0
        fi
        sleep 5
    done
    die "SSH did not answer on ${host} within 5 minutes"
}

upload_project() { # HOST
    local host="$1"
    info "packing the project (ISO, git objects, runtime state excluded)"
    tar -czf "$TARBALL" -C "$REPO_DIR" \
        --exclude='./.git' --exclude='./*.iso' --exclude='./provision' \
        --exclude='./clients' --exclude='./reports' --exclude='./logs' \
        --exclude='./backups' --exclude='./flags' --exclude='./state' \
        --exclude='*.tar.gz' --exclude='*.tgz' . || die "tar failed"
    info "uploading $(du -h "$TARBALL" | cut -f1)"
    ssh "${SSH_OPTS[@]}" -i "${SSH_KEY%.pub}" "${SSH_USER}@${host}" \
        "rm -rf /root/vulnserver && mkdir -p /root/vulnserver" \
        || die "cannot prepare /root/vulnserver"
    ssh "${SSH_OPTS[@]}" -i "${SSH_KEY%.pub}" "${SSH_USER}@${host}" "tar -xzf - -C /root/vulnserver" \
        < "$TARBALL" || die "upload failed"
    rm -f "$TARBALL"
}

run_bootstrap() { # HOST
    local host="$1"
    info "bootstrapping the lab (WireGuard first, then install.sh)"
    ssh "${SSH_OPTS[@]}" -i "${SSH_KEY%.pub}" "${SSH_USER}@${host}" \
        "PEER='${PEER}' WG_PORT='${WG_PORT}' LAB_INSTALL_ARGS='${LAB_ARGS}' bash -s" \
        < "${REPO_DIR}/scripts/cloud/bootstrap-vm.sh" \
        || die "bootstrap failed on the VM. Inspect: ssh -i ${SSH_KEY%.pub} ${SSH_USER}@${host} 'tail -60 /var/log/vulnserver-bootstrap.log'"
}

fetch_clients() { # HOST
    local host="$1"
    install -d -m 0700 "$CLIENT_DIR"
    scp "${SSH_OPTS[@]}" -i "${SSH_KEY%.pub}" -q \
        "${SSH_USER}@${host}:/etc/wireguard/clients/*.conf" "$CLIENT_DIR/" \
        || die "could not download the WireGuard client configs"
    chmod 0600 "$CLIENT_DIR"/*.conf
    ok "client configs in ${CLIENT_DIR}:"
    for f in "$CLIENT_DIR"/*.conf; do printf '    %s\n' "$(basename "$f")"; done
}

# -----------------------------------------------------------------------------
# State
# -----------------------------------------------------------------------------
write_state() { # SERVER_ID FIREWALL_ID IP
    install -d -m 0700 "$STATE_DIR"
    umask 077
    cat > "$STATE_FILE" <<EOF
# VulnServer provisioning state - created $(date -Is)
PROVIDER=${PROVIDER}
NAME=${NAME}
REGION=${REGION}
PLAN=${PLAN}
SERVER_ID=$1
FIREWALL_ID=$2
PUBLIC_IP=$3
SSH_USER=${SSH_USER}
SSH_KEY=${SSH_KEY}
WG_PORT=${WG_PORT}
PEER=${PEER}
EOF
    chmod 0600 "$STATE_FILE"
}

load_state() {
    [[ -r "$STATE_FILE" ]] || die "no state file ${STATE_FILE}; pass the same --provider and --name used at creation"
    # shellcheck disable=SC1090
    source "$STATE_FILE"
}

destroy_server() {
    [[ -n "$TOKEN" ]] || die "no API token: export HCLOUD_TOKEN / VULTR_API_KEY, or use --token-file"
    load_state
    info "destroying ${NAME} (server ${SERVER_ID}, firewall ${FIREWALL_ID})"
    if (( ASSUME_YES == 0 )); then
        read -r -p "Delete this VM permanently? [y/N] " reply || reply=""
        [[ "$reply" =~ ^[Yy]$ ]] || die "cancelled"
    fi
    del "$( [[ "$PROVIDER" == hetzner ]] && echo "/servers/${SERVER_ID}" || echo "/instances/${SERVER_ID}" )" \
        || warn "server deletion failed; check the console"
    if (( KEEP == 0 )); then
        delete_firewall "$FIREWALL_ID" || warn "firewall deletion failed"
    fi
    rm -f "$STATE_FILE"
    ok "${NAME} deleted"
    cat <<EOF

The SSH key registered at the provider was kept (reusable by name
vulnserver-${NAME}). Remove it in the console if you no longer need it.
EOF
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------
if (( DESTROY == 1 )); then
    destroy_server
    exit 0
fi

[[ -z "$ADMIN_CIDR" ]] || [[ "$ADMIN_CIDR" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}(/[0-9]{1,2})?$ ]] \
    || die "--admin-cidr must be an IPv4 address or CIDR"

if [[ -n "$USER_DATA" ]]; then
    [[ -r "$USER_DATA" ]] || die "cannot read --user-data ${USER_DATA}"
    local_size="$(wc -c < "$USER_DATA" | tr -d ' ')"
    (( local_size <= 32768 )) || die "user-data is ${local_size} bytes; Hetzner rejects more than 32768"
    NO_BOOTSTRAP=1
fi

if (( DRY_RUN == 1 )); then
    cat <<EOF
DRY RUN - no API calls, nothing created.

  provider    : ${PROVIDER}
  name        : ${NAME}
  region      : ${REGION}
  plan        : ${PLAN}
  image       : (resolved via API: Ubuntu 24.04 x86_64)
  ssh key     : ${SSH_KEY} -> ${SSH_USER}@<vm>
  firewall    : udp/${WG_PORT} from 0.0.0.0/0, tcp/22 from ${ADMIN_CIDR:-<your public IP>/32}
  wireguard   : peer '${PEER}'
  bootstrap   : $( (( NO_BOOTSTRAP == 1 )) && echo "skipped" || echo "upload + scripts/cloud/bootstrap-vm.sh" )
  user-data   : ${USER_DATA:-none}
  state file  : ${STATE_FILE}
  client confs: ${CLIENT_DIR}/
EOF
    exit 0
fi

[[ -n "$TOKEN" ]] || die "no API token: export HCLOUD_TOKEN / VULTR_API_KEY, or use --token-file"
[[ -r "$SSH_KEY" ]] || die "public key not found: ${SSH_KEY} (create one with: ssh-keygen -t ed25519)"

if (( ASSUME_YES == 0 )); then
    info "creating a billable ${PROVIDER} VM '${NAME}' (${PLAN} in ${REGION})"
    read -r -p "Continue? [y/N] " reply || reply=""
    [[ "$reply" =~ ^[Yy]$ ]] || die "cancelled"
fi

# Who may reach SSH: the operator's current address, never the world.
if [[ -z "$ADMIN_CIDR" ]]; then
    me="$(curl -fsS --max-time 8 https://api.ipify.org || true)"
    [[ "$me" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] \
        || die "could not detect your public IP; pass --admin-cidr <your-ip>/32"
    ADMIN_CIDR="${me}/32"
    info "SSH will only be reachable from ${ADMIN_CIDR}"
fi

info "resolving Ubuntu 24.04 image"
IMAGE_ID="$(resolve_image)"
[[ -n "$IMAGE_ID" ]] || die "Ubuntu 24.04 image not found for ${PROVIDER} in ${API_BASE}"
ok "image id: ${IMAGE_ID}"

info "checking plan ${PLAN}"
check_plan

info "registering SSH key"
KEY_ID="$(ensure_ssh_key)"
ok "ssh key id: ${KEY_ID}"

info "creating firewall"
FW_ID="$(ensure_firewall)"
ok "firewall id: ${FW_ID}"

info "creating server"
CREATED="$(create_server "$IMAGE_ID" "$KEY_ID" "$FW_ID")" || {
    warn "server creation failed; removing the firewall"
    delete_firewall "$FW_ID" || true
    exit 1
}
SERVER_ID="$(server_id_of <<<"$CREATED")"
[[ -n "$SERVER_ID" && "$SERVER_ID" != "null" ]] || die "provider did not return a server id"

# State is written before waiting so a failed deploy can always be destroyed.
write_state "$SERVER_ID" "$FW_ID" ""
info "server id ${SERVER_ID}; waiting for it to become running"
RUNNING="$(wait_server "$SERVER_ID")"
IP="$(server_ip_of <<<"$RUNNING")"
[[ -n "$IP" ]] || die "provider did not return a public IP"
write_state "$SERVER_ID" "$FW_ID" "$IP"
ok "server running at ${IP}"

if (( NO_BOOTSTRAP == 1 )); then
    cat <<EOF

VM created without bootstrap.
  ssh -i ${SSH_KEY%.pub} ${SSH_USER}@${IP}
  destroy: ./scripts/cloud/provision.sh --provider ${PROVIDER} --name ${NAME} --destroy
EOF
    [[ -n "$USER_DATA" ]] && printf 'cloud-init runs on first boot; log: /var/log/vulnserver-bootstrap.log\n'
    exit 0
fi

wait_ssh "$IP"
upload_project "$IP"
run_bootstrap "$IP"
fetch_clients "$IP"
write_state "$SERVER_ID" "$FW_ID" "$IP"

cat <<EOF

$(ok "VulnServer is up")

  1. Import ${CLIENT_DIR}/${PEER}.conf into the WireGuard app and connect.
  2. Juice Shop : http://10.8.0.1:3000/
     SSH        : ssh labuser@10.8.0.1   (after connecting the tunnel)
  3. Never open the tunnel to people you do not trust; every peer can reach
     the lab and the lab is intentionally vulnerable.

  destroy: ./scripts/cloud/provision.sh --provider ${PROVIDER} --name ${NAME} --destroy
EOF
