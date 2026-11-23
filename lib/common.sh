#!/usr/bin/env bash
# =============================================================================
# VulnServer - Ubuntu Hardening & Privilege Escalation Lab v1.0
# lib/common.sh - Shared helpers: config loading, logging, state, safety.
#
# This file is sourced by every other VulnServer script. It must stay free of
# side effects (no writes, no service changes) so that read-only tools such as
# audit.sh can source it safely.
# =============================================================================

# Do not inherit the caller's `set -e`: each script decides its own strictness.
set -o pipefail

# -----------------------------------------------------------------------------
# Repository / state locations
# -----------------------------------------------------------------------------
_common_src="${BASH_SOURCE[0]}"
VULNSERVER_REPO_DIR="$(cd "$(dirname "${_common_src}")/.." && pwd)"
readonly VULNSERVER_REPO_DIR

# Safe defaults; all of these can be overridden by config/lab.conf or the
# environment (env vars win so that automated tests can point at a sandbox).
LAB_NAME="${LAB_NAME:-VulnServer}"
LAB_VERSION="${LAB_VERSION:-1.0}"
LAB_STATE_DIR="${LAB_STATE_DIR:-/opt/vulnserver}"

LAB_CONFIG_FILE="${LAB_CONFIG_FILE:-$VULNSERVER_REPO_DIR/config/lab.conf}"
if [[ -r "$LAB_CONFIG_FILE" ]]; then
    # shellcheck source=/dev/null
    source "$LAB_CONFIG_FILE"
fi

# Derived paths (defined after config load so a custom LAB_STATE_DIR is honoured)
LAB_BIN_DIR="${LAB_STATE_DIR}/bin"
LAB_FLAG_DIR="${LAB_FLAG_DIR:-${LAB_STATE_DIR}/flags}"
LAB_LOG_DIR="${LAB_LOG_DIR:-${LAB_STATE_DIR}/logs}"
LAB_BACKUP_DIR="${LAB_BACKUP_DIR:-${LAB_STATE_DIR}/backups}"
LAB_REPORT_DIR="${LAB_REPORT_DIR:-${LAB_STATE_DIR}/reports}"
LAB_DATA_DIR="${LAB_DATA_DIR:-${LAB_STATE_DIR}/lab}"
LAB_STATE_STATE_DIR="${LAB_STATE_DIR}/state"
LAB_EVENT_LOG="${LAB_LOG_DIR}/events.log"
LAB_MAIN_LOG="${LAB_LOG_DIR}/vulnserver.log"
LAB_SCENARIO_REGISTRY="${LAB_SCENARIO_REGISTRY:-${VULNSERVER_REPO_DIR}/config/scenarios/scenarios.conf}"

# Runtime knobs
ASSUME_YES="${ASSUME_YES:-0}"        # -y / --yes : skip interactive prompts
DRY_RUN="${DRY_RUN:-0}"              # -n / --dry-run : print instead of acting
LAB_PROFILE="${LAB_PROFILE:-vm}"     # vm | container (container skips host-only bits)
LAB_TS_FORMAT="${LAB_TS_FORMAT:-%Y-%m-%d %H:%M:%S}"

# -----------------------------------------------------------------------------
# Output helpers
# -----------------------------------------------------------------------------
if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
    C_RESET=$'\033[0m'; C_RED=$'\033[0;31m'; C_GREEN=$'\033[0;32m'
    C_YELLOW=$'\033[1;33m'; C_BLUE=$'\033[0;36m'; C_BOLD=$'\033[1m'; C_DIM=$'\033[2m'
else
    C_RESET=''; C_RED=''; C_GREEN=''; C_YELLOW=''; C_BLUE=''; C_BOLD=''; C_DIM=''
fi

info()  { printf '%s[*]%s %s\n' "$C_BLUE"   "$C_RESET" "$*"; }
ok()    { printf '%s[+]%s %s\n' "$C_GREEN"  "$C_RESET" "$*"; }
warn()  { printf '%s[!]%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
err()   { printf '%s[x]%s %s\n' "$C_RED"    "$C_RESET" "$*" >&2; }
dim()   { printf '%s    %s%s\n' "$C_DIM" "$*" "$C_RESET"; }
hr()    { printf '%s\n' "------------------------------------------------------------------------"; }
banner() {
    printf '%s\n' "${C_BOLD}${C_BLUE}================================================================${C_RESET}"
    printf '%s%s%s\n' "${C_BOLD}${C_BLUE}" " VulnServer - Ubuntu Hardening & Privilege Escalation Lab" "${C_RESET}"
    printf '%s\n' "${C_DIM} v${LAB_VERSION} | authorized laboratory use only${C_RESET}"
    printf '%s\n' "${C_BOLD}${C_BLUE}================================================================${C_RESET}"
}

# -----------------------------------------------------------------------------
# Fatal error / dependency / privilege checks
# -----------------------------------------------------------------------------
die() {
    err "$*"
    log_event "ERROR" "core" "-" "FAILURE" "$*" 2>/dev/null || true
    exit 1
}

# require_root [message]
require_root() {
    if [[ "${EUID}" -ne 0 ]]; then
        die "This operation requires root. Re-run with: sudo $0 ${*:-}${*:+ }(current uid: ${EUID})"
    fi
}

# check_deps cmd1 cmd2 ... -> reports every missing command at once
check_deps() {
    local missing=() cmd
    for cmd in "$@"; do
        command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
    done
    if (( ${#missing[@]} > 0 )); then
        err "Missing required commands: ${missing[*]}"
        dim "Install them first (see docs/INSTALLATION.md) or run ./install.sh --install-deps"
        return 1
    fi
    return 0
}

# confirm "question" -> 0 when the operator agreed
confirm() {
    local prompt="${1:-Continue?}"
    if [[ "$ASSUME_YES" == "1" ]]; then
        dim "auto-confirmed (--yes): $prompt"
        return 0
    fi
    if [[ ! -t 0 ]]; then
        err "Non-interactive session and no --yes given, refusing destructive step: $prompt"
        return 1
    fi
    local reply
    read -r -p "${C_YELLOW}${prompt} [y/N] ${C_RESET}" reply
    [[ "$reply" =~ ^[Yy]([Ee][Ss])?$ ]]
}

# run_cmd: honour DRY_RUN for every state-changing command
run_cmd() {
    if [[ "$DRY_RUN" == "1" ]]; then
        printf '%s[dry-run]%s %s\n' "$C_DIM" "$C_RESET" "$*"
        return 0
    fi
    "$@"
}

# -----------------------------------------------------------------------------
# Logging
# -----------------------------------------------------------------------------
# _ensure_log_dir: create the log directory if we (root) can, otherwise fall
# back to stderr. Never fails the calling script.
_ensure_log_dir() {
    [[ -d "$LAB_LOG_DIR" ]] && return 0
    mkdir -p "$LAB_LOG_DIR" 2>/dev/null || return 1
}

# log_event <event> <service> <scenario> <result> [detail]
#   Appends one JSON object per line (machine readable) and one human line to
#   vulnserver.log. The operator identity is taken from $SUDO_USER when the
#   script runs through sudo, so the log records who actually asked for it.
log_event() {
    local event="$1" service="${2:--}" scenario="${3:--}" result="${4:--}" detail="${5:-}"
    local actor ts json human

    # Uninstall sets this after deleting the state directory so that logging
    # cannot recreate it; syslog still receives the event.
    if [[ "${VULNSERVER_LOGGING_DISABLED:-0}" == "1" ]]; then
        command -v logger >/dev/null 2>&1 && \
            logger -t vulnserver -p "auth.notice" -- "event=$event service=$service scenario=$scenario result=$result detail=$detail" 2>/dev/null || true
        return 0
    fi
    actor="${VULNSERVER_ACTOR:-${SUDO_USER:-${USER:-unknown}}}"
    ts="$(date +"$LAB_TS_FORMAT")"

    if ! _ensure_log_dir; then
        printf '%s\n' "$ts actor=$actor event=$event service=$service scenario=$scenario result=$result detail=$detail" >&2
        return 0
    fi

    # Escape for JSON using bash parameter expansion only (no jq dependency).
    _json_escape() {
        local s="$1"
        s="${s//\\/\\\\}"; s="${s//\"/\\\"}"
        s="${s//$'\n'/\\n}"; s="${s//$'\r'/\\r}"; s="${s//$'\t'/\\t}"
        printf '%s' "$s"
    }
    if command -v jq >/dev/null 2>&1; then
        json="$(jq -cn --arg ts "$ts" --arg actor "$actor" --arg event "$event" \
                    --arg service "$service" --arg scenario "$scenario" \
                    --arg result "$result" --arg detail "$detail" --arg host "$(hostname)" \
                '{timestamp:$ts, host:$host, actor:$actor, event:$event, service:$service,
                  scenario:$scenario, result:$result, detail:$detail}')"
    else
        json="{\"timestamp\":\"$(_json_escape "$ts")\",\"host\":\"$(_json_escape "$(hostname)")\",\"actor\":\"$(_json_escape "$actor")\",\"event\":\"$(_json_escape "$event")\",\"service\":\"$(_json_escape "$service")\",\"scenario\":\"$(_json_escape "$scenario")\",\"result\":\"$(_json_escape "$result")\",\"detail\":\"$(_json_escape "$detail")\"}"
    fi
    printf '%s\n' "$json" >>"$LAB_EVENT_LOG" 2>/dev/null || true

    human="$ts actor=$actor event=$event service=$service scenario=$scenario result=$result"
    [[ -n "$detail" ]] && human+=" detail=$detail"
    printf '%s\n' "$human" >>"$LAB_MAIN_LOG" 2>/dev/null || true

    # Mirror to syslog/journald when available so auditd/journalctl can see it.
    if command -v logger >/dev/null 2>&1; then
        logger -t vulnserver -p "auth.notice" -- "$human" 2>/dev/null || true
    fi
    return 0
}

# -----------------------------------------------------------------------------
# Scenario state helpers
# -----------------------------------------------------------------------------
scenario_state_file() { printf '%s/scenario-%s.state\n' "$LAB_STATE_STATE_DIR" "$1"; }

scenario_is_active() {
    local f; f="$(scenario_state_file "$1")"
    [[ -r "$f" ]] && [[ "$(head -n1 "$f" 2>/dev/null)" == "active" ]]
}

scenario_set_state() { # <id> <active|inactive>
    local f; f="$(scenario_state_file "$1")"
    run_cmd mkdir -p "$LAB_STATE_STATE_DIR"
    if [[ "$DRY_RUN" == "1" ]]; then
        printf '%s[dry-run]%s scenario %s -> %s\n' "$C_DIM" "$C_RESET" "$1" "$2"
        return 0
    fi
    printf '%s\n' "$2" > "$f"
    printf 'updated=%s by=%s\n' "$(date +"$LAB_TS_FORMAT")" \
        "${VULNSERVER_ACTOR:-${SUDO_USER:-${USER:-unknown}}}" >> "$f"
}

# scenario_label <id> -> "A" .. "C" (accepts a, A, scenario-a)
scenario_label() {
    local id="${1,,}"
    id="${id#scenario-}"
    printf '%s' "${id^^}"
}

# scenario_config_get <id> <key> : read KEY="value" from scenarios.conf block
scenario_config_get() {
    local id="${1,,}" key="$2" value=""
    id="${id#scenario-}"
    [[ -r "$LAB_SCENARIO_REGISTRY" ]] || return 1
    # Blocks look like: [a]\nNAME="..."\nSCRIPT="..."
    value="$(awk -v block="[$id]" -v key="$key" '
        $0 == block { inside = 1; next }
        /^\[/ { inside = 0 }
        inside && $0 ~ "^" key "=" {
            sub("^" key "=", ""); gsub(/^"|"$/, ""); print; exit
        }' "$LAB_SCENARIO_REGISTRY")"
    [[ -n "$value" ]] || return 1
    printf '%s' "$value"
}

# create_restore_point <scenario-id>
#   Writes a self-contained rollback directory containing a restore.sh that
#   deactivates the scenario and a manifest describing what was changed.
#   Sets RESTORE_POINT to the created directory.
create_restore_point() {
    local id; id="$(scenario_label "$1")"
    RESTORE_POINT="${LAB_BACKUP_DIR}/restore-$(printf '%s' "$id" | tr '[:upper:]' '[:lower:]')-$(timestamp_slug)"
    if [[ "$DRY_RUN" == "1" ]]; then
        dim "[dry-run] would create restore point ${RESTORE_POINT}"
        return 0
    fi
    mkdir -p "$RESTORE_POINT" || { warn "cannot create restore point"; return 1; }
    chmod 0700 "$RESTORE_POINT"
    local script_id; script_id="$(printf '%s' "$id" | tr '[:upper:]' '[:lower:]')"
    cat > "$RESTORE_POINT/restore.sh" <<EOF
#!/usr/bin/env bash
# Restore point generated when scenario ${id} was activated.
# Deactivates the scenario and leaves a log entry.
set -euo pipefail
exec "${VULNSERVER_REPO_DIR}/scripts/scenarios/scenario-${script_id}.sh" deactivate
EOF
    chmod 0700 "$RESTORE_POINT/restore.sh"
    {
        printf 'scenario=%s\n' "$id"
        printf 'created=%s\n' "$(date +"$LAB_TS_FORMAT")"
        printf 'actor=%s\n' "${VULNSERVER_ACTOR:-${SUDO_USER:-${USER:-unknown}}}"
        printf 'host=%s\n' "$(hostname)"
    } > "$RESTORE_POINT/manifest.txt"
    printf '%s\n' "$RESTORE_POINT"
}

# -----------------------------------------------------------------------------
# Misc helpers
# -----------------------------------------------------------------------------
timestamp_slug() { date +%Y%m%d-%H%M%S; }

human_bytes() { numfmt --to=iec --suffix=B "$1" 2>/dev/null || printf '%s bytes' "$1"; }

# service_active <unit> -> true/false (systemd or pgrep fallback)
service_active() {
    local unit="$1"
    if command -v systemctl >/dev/null 2>&1 && systemctl list-units --type=service >/dev/null 2>&1; then
        systemctl is-active --quiet "$unit"
    else
        pgrep -x "${unit%.service}" >/dev/null 2>&1
    fi
}

# port_open <port> [host]
port_open() {
    local port="$1" host="${2:-127.0.0.1}"
    if command -v ss >/dev/null 2>&1; then
        ss -ltnH 2>/dev/null | awk '{print $4}' | grep -Eq "[:.]${port}$"
    else
        (exec 3<>"/dev/tcp/${host}/${port}") >/dev/null 2>&1 && exec 3>&- && return 0 || return 1
    fi
}

# docker_ready: docker CLI present and daemon reachable
docker_ready() {
    command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1
}

# has_systemd: real PID 1 systemd (allows skipping systemd-only steps in containers)
has_systemd() {
    [[ -d /run/systemd/system ]] && [[ "$(ps -p 1 -o comm= 2>/dev/null)" == "systemd" ]]
}
