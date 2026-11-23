#!/usr/bin/env bash
# =============================================================================
# VulnServer - audit.sh
# READ-ONLY security audit of the laboratory host.
#
#   sudo ./audit.sh                 # full audit, write a Markdown report
#   sudo ./audit.sh --stdout        # print the report, do not write a file
#   sudo ./audit.sh --only suid,sudo
#   sudo ./audit.sh --strict        # exit 1 when any FAIL is found
#
# This script never modifies the system. Use harden.sh to fix findings.
# =============================================================================
set -uo pipefail   # no -e: a failing check must not abort the audit
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

ONLY=""; STDOUT=0; STRICT=0
while (( $# > 0 )); do
    case "$1" in
        --stdout) STDOUT=1; shift ;;
        --strict) STRICT=1; shift ;;
        --only)   ONLY="${2:?--only needs a list}"; shift 2 ;;
        -h|--help) sed -n '2,15p' "$0"; exit 0 ;;
        *) die "unknown option: $1" ;;
    esac
done

# Root is only needed to read some of the audited files.
require_root "$@"

TMP_FINDINGS="$(mktemp)"; trap 'rm -f "$TMP_FINDINGS"' EXIT
COUNTS_PASS=0; COUNTS_WARN=0; COUNTS_FAIL=0

# record <PASS|WARN|FAIL> <section> <title> <detail> <recommendation>
record() {
    local status="$1" section="$2" title="$3" detail="$4" rec="$5"
    case "$status" in
        PASS) COUNTS_PASS=$((COUNTS_PASS+1)) ;;
        WARN) COUNTS_WARN=$((COUNTS_WARN+1)) ;;
        FAIL) COUNTS_FAIL=$((COUNTS_FAIL+1)) ;;
    esac
    # tab separated, newlines flattened
    printf '%s\t%s\t%s\t%s\t%s\n' "$status" "$section" "$title" \
        "${detail//$'\n'/ }" "${rec//$'\n'/ }" >> "$TMP_FINDINGS"
}

want_section() {
    [[ -z "$ONLY" ]] && return 0
    [[ ",${ONLY}," == *",${1},"* ]]
}

# ---------------------------------------------------------------------------
# 1. Operating system and updates
# ---------------------------------------------------------------------------
check_os() {
    want_section os || return 0
    # shellcheck disable=SC1091
    source /etc/os-release 2>/dev/null || true
    if [[ "${ID:-}" == "ubuntu" && "${VERSION_ID:-}" == "24.04" ]]; then
        record PASS os "Supported operating system" "${PRETTY_NAME:-unknown}" "-"
    else
        record WARN os "Unsupported operating system" "${PRETTY_NAME:-unknown}" "Use Ubuntu Server 24.04 LTS for the lab"
    fi

    if command -v apt-get >/dev/null 2>&1; then
        local upgradable=0
        upgradable="$(apt-get -s -o Debug::NoLocking=true upgrade 2>/dev/null | grep -c '^Inst ' || true)"
        if (( upgradable > 20 )); then
            record WARN os "Security updates pending" "${upgradable} packages upgradable" "apt-get upgrade; enable unattended-upgrades"
        else
            record PASS os "Security updates" "${upgradable} packages upgradable" "-"
        fi
        if systemctl is-enabled --quiet unattended-upgrades 2>/dev/null; then
            record PASS os "Unattended upgrades" "enabled" "-"
        else
            record WARN os "Unattended upgrades" "disabled or not installed" "apt-get install unattended-upgrades && dpkg-reconfigure -plow unattended-upgrades"
        fi
    fi
}

# ---------------------------------------------------------------------------
# 2. SSH
# ---------------------------------------------------------------------------
check_ssh() {
    want_section ssh || return 0
    local cfg="/etc/ssh/sshd_config" dropin="/etc/ssh/sshd_config.d/99-vulnserver.conf"

    if ! command -v sshd >/dev/null 2>&1; then
        record WARN ssh "SSH server" "not installed" "Install openssh-server if remote access is required"
        return 0
    fi

    if sshd -t 2>/dev/null; then
        record PASS ssh "sshd configuration syntax" "valid" "-"
    else
        record FAIL ssh "sshd configuration syntax" "sshd -t failed" "Fix /etc/ssh configuration before reloading sshd"
    fi

    # Effective values (fall back to files when sshd -T is unavailable)
    local eff=""
    eff="$(sshd -T 2>/dev/null || true)"
    local root_login pass_auth allow_users maxauth
    root_login="$(printf '%s\n' "$eff" | awk '/^permitrootlogin /{print $2}')"
    pass_auth="$(printf '%s\n' "$eff" | awk '/^passwordauthentication /{print $2}')"
    allow_users="$(printf '%s\n' "$eff" | awk '/^allowusers /{print $2" "$3}')"
    maxauth="$(printf '%s\n' "$eff" | awk '/^maxauthtries /{print $2}')"

    [[ -z "$root_login" ]] && root_login="$(grep -Eis '^\s*PermitRootLogin' "$cfg" "$dropin" 2>/dev/null | tail -n1 | awk '{print tolower($2)}')"
    [[ -z "$root_login" ]] && root_login="$(grep -Eis '^\s*PermitRootLogin' /etc/ssh/sshd_config.d/*.conf 2>/dev/null | tail -n1 | awk '{print tolower($2)}')"
    [[ -z "$root_login" ]] && root_login="prohibit-password"

    if [[ "$root_login" == "no" ]]; then
        record PASS ssh "Root login over SSH" "PermitRootLogin no" "-"
    else
        record FAIL ssh "Root login over SSH" "PermitRootLogin ${root_login}" "Set PermitRootLogin no in /etc/ssh/sshd_config.d/99-vulnserver.conf"
    fi

    if [[ "$pass_auth" == "no" ]]; then
        record PASS ssh "Password authentication" "disabled (key-only)" "-"
    else
        record WARN ssh "Password authentication" "enabled" "After the exercise, set PasswordAuthentication no and use SSH keys (docs/HARDENING_GUIDE.md)"
    fi

    if [[ -n "$allow_users" ]]; then
        record PASS ssh "Login restricted to lab accounts" "AllowUsers ${allow_users}" "-"
    else
        record FAIL ssh "Login restricted to lab accounts" "AllowUsers not set" "Add 'AllowUsers ${ADMIN_USER} ${LAB_USER}'"
    fi

    if [[ "${maxauth:-6}" =~ ^[0-9]+$ ]] && (( maxauth <= 3 )); then
        record PASS ssh "MaxAuthTries" "${maxauth}" "-"
    else
        record WARN ssh "MaxAuthTries" "${maxauth:-unset}" "Set MaxAuthTries 3"
    fi
}

# ---------------------------------------------------------------------------
# 3. Accounts and groups
# ---------------------------------------------------------------------------
check_accounts() {
    want_section accounts || return 0
    local u

    for u in "$ADMIN_USER" "$LAB_USER" "$PRIV_USER"; do
        if id "$u" >/dev/null 2>&1; then
            record PASS accounts "Account ${u} exists" "uid=$(id -u "$u") groups=$(id -nG "$u" | tr ' ' ',')" "-"
        else
            record FAIL accounts "Account ${u} exists" "missing" "Run install.sh / scripts/users/create_users.sh create"
        fi
    done

    if id -nG "$LAB_USER" 2>/dev/null | tr ' ' '\n' | grep -qxE 'sudo|adm|docker'; then
        record FAIL accounts "labuser has administrative group membership" "$(id -nG "$LAB_USER" | tr ' ' ',')" \
            "gpasswd -d ${LAB_USER} sudo (and adm/docker)"
    else
        record PASS accounts "labuser is unprivileged" "groups=$(id -nG "$LAB_USER" 2>/dev/null | tr ' ' ',')" "-"
    fi

    # Empty password fields
    local empty
    empty="$(awk -F: '$2 == "" {print $1}' /etc/shadow 2>/dev/null | tr '\n' ' ')"
    if [[ -z "${empty// /}" ]]; then
        record PASS accounts "No accounts with empty passwords" "none" "-"
    else
        record FAIL accounts "Accounts with empty passwords" "$empty" "passwd -l <user>"
    fi

    if passwd -S "$PRIV_USER" 2>/dev/null | awk '{print $2}' | grep -qE '^(L|LK)$'; then
        record PASS accounts "Intermediate account ${PRIV_USER} cannot log in" "password locked" "-"
    else
        record WARN accounts "Intermediate account ${PRIV_USER} login state" "$(passwd -S "$PRIV_USER" 2>/dev/null)" \
            "Lock it: passwd -l ${PRIV_USER}"
    fi

    # UID 0 accounts other than root
    local extra_root
    extra_root="$(awk -F: '$3 == 0 && $1 != "root" {print $1}' /etc/passwd | tr '\n' ' ')"
    if [[ -z "${extra_root// /}" ]]; then
        record PASS accounts "Only root has UID 0" "none" "-"
    else
        record FAIL accounts "Additional UID 0 accounts" "$extra_root" "Remove or renumber unexpected root-equivalent accounts"
    fi
}

# ---------------------------------------------------------------------------
# 4. File permissions (flags, logs, lab data)
# ---------------------------------------------------------------------------
check_permissions() {
    want_section permissions || return 0

    # spec layout: path:owner:group:mode
    local spec path want_owner want_group want_mode actual_owner actual_mode
    for spec in "${FLAG_USER_FILE}:${LAB_USER}:${LAB_USER}:600" \
                "${FLAG_PRIV_FILE}:root:${PRIV_USER}:640" \
                "${FLAG_ROOT_FILE}:root:root:400"; do
        path="${spec%%:*}"; spec="${spec#*:}"
        want_owner="${spec%%:*}"; spec="${spec#*:}"
        want_group="${spec%%:*}"; want_mode="${spec#*:}"

        if [[ ! -f "$path" ]]; then
            record FAIL permissions "Flag $(basename "$path")" "missing" "Re-run scripts/flags/generate_flags.sh generate"
            continue
        fi
        actual_owner="$(stat -c '%U:%G' "$path")"; actual_mode="$(stat -c '%a' "$path")"
        if [[ "$actual_owner" == "${want_owner}:${want_group}" && "$actual_mode" == "$want_mode" ]]; then
            record PASS permissions "Flag $(basename "$path") permissions" "${actual_owner} ${actual_mode}" "-"
        else
            record FAIL permissions "Flag $(basename "$path") permissions" "${actual_owner} ${actual_mode}" \
                "chown ${want_owner}:${want_group} $path && chmod ${want_mode} $path"
        fi
    done

    for spec in "${LAB_LOG_DIR}:root:root:750" "${LAB_BACKUP_DIR}:root:root:700" \
                "${LAB_REPORT_DIR}:root:root:750" "${LAB_STATE_DIR}:root:root:755"; do
        path="${spec%%:*}"; spec="${spec#*:}"
        want_owner="${spec%%:*}"; spec="${spec#*:}"
        want_group="${spec%%:*}"; want_mode="${spec#*:}"
        if [[ ! -e "$path" ]]; then
            record FAIL permissions "Directory $(basename "$path")" "missing" "Run install.sh"
            continue
        fi
        actual_owner="$(stat -c '%U:%G' "$path")"; actual_mode="$(stat -c '%a' "$path")"
        if [[ "$actual_owner" == "${want_owner}:${want_group}" && "$actual_mode" == "$want_mode" ]]; then
            record PASS permissions "Directory $(basename "$path")" "${actual_owner} ${actual_mode}" "-"
        else
            record FAIL permissions "Directory $(basename "$path")" "${actual_owner} ${actual_mode}" \
                "chown ${want_owner}:${want_group} $path && chmod ${want_mode} $path"
        fi
    done

    if [[ -f "$LAB_EVENT_LOG" ]] && find "$LAB_EVENT_LOG" -perm -o+w -print -quit | grep -q .; then
        record FAIL permissions "Event log is world-writable" "$(stat -c '%A' "$LAB_EVENT_LOG")" "chmod o-w $LAB_EVENT_LOG"
    else
        record PASS permissions "Event log not writable by others" "$(stat -c '%A' "$LAB_EVENT_LOG" 2>/dev/null || echo missing)" "-"
    fi

    # World-writable directories inside the lab tree
    local ww
    ww="$(find "$LAB_STATE_DIR" -xdev -type d -perm -0002 2>/dev/null | grep -v '^/proc' | tr '\n' ' ')"
    if [[ -z "${ww// /}" ]]; then
        record PASS permissions "No world-writable directories in the lab tree" "none" "-"
    else
        record FAIL permissions "World-writable directories in the lab tree" "$ww" \
            "chmod o-w <dir> (see Scenario A in docs/HARDENING_GUIDE.md)"
    fi
}

# ---------------------------------------------------------------------------
# 5. sudo policy
# ---------------------------------------------------------------------------
check_sudo() {
    want_section sudo || return 0
    if ! command -v sudo >/dev/null 2>&1; then
        record WARN sudo "sudo" "not installed" "-"; return 0
    fi

    local f
    for f in /etc/sudoers.d/vulnserver-*; do
        [[ -e "$f" ]] || continue
        if visudo -cqf "$f" >/dev/null 2>&1; then
            record PASS sudo "Sudoers file valid: $(basename "$f")" "$(stat -c '%a %U:%G' "$f")" "-"
        else
            record FAIL sudo "Sudoers file invalid: $(basename "$f")" "visudo -c failed" \
                "Fix syntax immediately: this can break sudo"
        fi
    done

    local nopasswd
    nopasswd="$(grep -rh --include='*' -E '^[^#]*NOPASSWD' /etc/sudoers.d/ 2>/dev/null | grep -v '^#' | tr '\n' ';')"
    if [[ -z "$nopasswd" ]]; then
        record PASS sudo "No NOPASSWD rules in sudoers.d" "none" "-"
    else
        record WARN sudo "NOPASSWD rules present" "$nopasswd" \
            "Remove lab rules: scripts/scenarios/scenario-b.sh deactivate"
    fi

    # Delegation to the intermediate account
    if [[ -f "$SCENARIO_B_SUDOERS" ]]; then
        record WARN sudo "Scenario B sudo delegation is active" "$SCENARIO_B_SUDOERS" \
            "Deactivate scenario B or delete the file"
    else
        record PASS sudo "No scenario sudo delegation" "absent" "-"
    fi

    if [[ -e "$SCENARIO_B_HELPER" ]]; then
        local hmode hgroup
        hmode="$(stat -c '%a' "$SCENARIO_B_HELPER")"; hgroup="$(stat -c '%G' "$SCENARIO_B_HELPER")"
        if [[ "$hmode" =~ ^7[0-9][0-9]$ || "$hgroup" == "$PRIV_USER" ]]; then
            record FAIL sudo "Root helper writable by delegated account" "$SCENARIO_B_HELPER ${hmode} ${hgroup}" \
                "chown root:root $SCENARIO_B_HELPER && chmod 0755 $SCENARIO_B_HELPER"
        else
            record PASS sudo "Root helper permissions" "${hmode} $(stat -c '%U:%G' "$SCENARIO_B_HELPER")" "-"
        fi
    fi

    # labuser must not have general root rights
    local lab_rules
    lab_rules="$(sudo -l -U "$LAB_USER" 2>/dev/null | grep -E 'ALL' | grep -v '!ALL' || true)"
    if [[ -n "$lab_rules" ]]; then
        record WARN sudo "${LAB_USER} has broad sudo rights" "$(printf '%s' "$lab_rules" | tr '\n' ';')" "Review /etc/sudoers.d"
    else
        record PASS sudo "${LAB_USER} has no broad sudo rights" "none" "-"
    fi
}

# ---------------------------------------------------------------------------
# 6. SUID / SGID
# ---------------------------------------------------------------------------
check_suid() {
    want_section suid || return 0
    local known_safe="/usr/bin/su /usr/bin/sudo /usr/bin/passwd /usr/bin/chsh /usr/bin/chfn /usr/bin/newgrp /usr/bin/gpasswd /usr/bin/mount /usr/bin/umount /usr/lib/openssh/ssh-keysign /usr/lib/dbus-1.0/dbus-daemon-launch-helper /usr/bin/fusermount3 /usr/libexec/polkit-agent-helper-1"

    local found f
    # Administrative backups are root-only (0700) and may legitimately contain
    # a copy of a SUID file; they are not an escalation path and are excluded.
    found="$(find /usr /bin /sbin /opt -xdev -type f -perm -4000 \
                -not -path "${LAB_BACKUP_DIR}/*" 2>/dev/null)"
    local suspicious=""
    while IFS= read -r f; do
        [[ -z "$f" ]] && continue
        if [[ " $known_safe " != *" $f "* ]]; then
            suspicious+="$f "
        fi
    done <<< "$found"

    if [[ -z "${suspicious// /}" ]]; then
        record PASS suid "No unexpected SUID binaries" "only standard utilities" "-"
    else
        record FAIL suid "Unexpected SUID binaries" "$suspicious" \
            "Investigate and remove: chmod u-s <file> (see Scenario A)"
    fi

    if [[ -e "$SCENARIO_A_SUID_BINARY" ]]; then
        local m; m="$(stat -c '%a' "$SCENARIO_A_SUID_BINARY")"
        if [[ "$m" == "4755" ]]; then
            record WARN suid "Scenario A active: SUID on $(basename "$SCENARIO_A_SUID_BINARY")" "$m" \
                "chmod u-s $SCENARIO_A_SUID_BINARY"
        fi
    fi
}

# ---------------------------------------------------------------------------
# 7. Cron
# ---------------------------------------------------------------------------
check_cron() {
    want_section cron || return 0
    if command -v systemctl >/dev/null 2>&1 && has_systemd; then
        if service_active cron; then
            record PASS cron "cron service" "active" "-"
        else
            record WARN cron "cron service" "inactive" "systemctl enable --now cron (needed for Scenario C)"
        fi
    fi

    local d
    for d in /etc/cron.d /etc/cron.hourly /etc/cron.daily /etc/cron.weekly /etc/cron.monthly; do
        [[ -d "$d" ]] || continue
        if find "$d" -maxdepth 0 -perm -0002 | grep -q .; then
            record FAIL cron "World-writable cron directory" "$d" "chmod o-w $d"
        fi
    done

    if [[ -e "$SCENARIO_C_CRON" ]]; then
        record WARN cron "Scenario C root cron job is installed" "$SCENARIO_C_CRON" \
            "Deactivate scenario C or chmod 0755 $SCENARIO_C_DIR"
    fi

    if [[ -f "$SCENARIO_C_SCRIPT" ]]; then
        local m; m="$(stat -c '%a' "$SCENARIO_C_SCRIPT")"
        if [[ "$m" != "755" ]]; then
            record FAIL cron "Lab cron script mode" "$SCENARIO_C_SCRIPT $m" "chmod 0755 and chown root:root"
        fi
    fi

    local ww
    ww="$(find "$LAB_DATA_DIR" -xdev -type d -perm -0002 2>/dev/null | tr '\n' ' ')"
    [[ -z "${ww// /}" ]] && record PASS cron "No world-writable lab directories" "none" "-" \
                        || record FAIL cron "World-writable lab directories" "$ww" "chmod o-w <dir>"
}

# ---------------------------------------------------------------------------
# 8. Firewall
# ---------------------------------------------------------------------------
check_firewall() {
    want_section firewall || return 0
    if ! command -v ufw >/dev/null 2>&1; then
        record FAIL firewall "UFW installed" "not installed" "apt-get install ufw && config/ufw/ufw-rules.sh apply"
        return 0
    fi
    local status_line
    status_line="$(ufw status 2>/dev/null | head -n1)"
    if [[ "$status_line" == *"active"* ]]; then
        record PASS firewall "UFW active" "$status_line" "-"
    else
        record FAIL firewall "UFW inactive" "$status_line" "ufw --force enable (after reviewing rules)"
    fi

    if ufw status 2>/dev/null | grep -q "${JUICE_SHOP_PORT}"; then
        record PASS firewall "Juice Shop port has an explicit rule" "$(ufw status | grep "${JUICE_SHOP_PORT}" | tr '\n' ';')" "-"
    else
        record WARN firewall "Juice Shop port has no explicit rule" "port ${JUICE_SHOP_PORT}" "Add an allow rule limited to ${LAB_ALLOWED_NETS}"
    fi

    if ufw status 2>/dev/null | grep -qE '^[0-9]+/tcp +ALLOW +Anywhere' ; then
        record WARN firewall "Ports open to anywhere" "$(ufw status | grep -E '^[0-9]+/tcp +ALLOW +Anywhere' | tr '\n' ';')" \
            "Restrict to lab networks"
    else
        record PASS firewall "No port open to any source" "none" "-"
    fi
}

# ---------------------------------------------------------------------------
# 9. Services and listening sockets
# ---------------------------------------------------------------------------
check_services() {
    want_section services || return 0
    local bad=""
    # Docker API must never listen on TCP.
    if ss -ltnH 2>/dev/null | awk '{print $4}' | grep -qE ':2375$|:2376$'; then
        bad+="docker-api "
        record FAIL services "Docker API exposed on TCP" "$(ss -ltn | grep -E ':2375|:2376' | tr '\n' ';')" \
            "Remove -H tcp:// from the docker unit / daemon.json"
    else
        record PASS services "Docker API not exposed on TCP" "unix socket only" "-"
    fi

    if [[ -e /var/run/docker.sock ]]; then
        local perms; perms="$(stat -c '%a %U:%G' /var/run/docker.sock)"
        if [[ "$(stat -c '%G' /var/run/docker.sock)" == "docker" ]]; then
            record WARN services "Docker socket group access" "$perms" "Only trusted administrators should be in the docker group"
        fi
    fi

    # Database ports must not be published.
    local dbports="3306 5432 6379 27017 9200"
    local p exposed=""
    for p in $dbports; do
        ss -ltnH 2>/dev/null | awk '{print $4}' | grep -Eq "[:.]${p}$" && exposed+="${p} "
    done
    [[ -z "${exposed// /}" ]] && record PASS services "No database ports listening on the host" "none" "-" \
                               || record FAIL services "Database ports exposed" "$exposed" "Bind to 127.0.0.1 or remove the publish rule"

    # Administrative web panels
    for p in 8080 8443 9090 10000; do
        if ss -ltnH 2>/dev/null | awk '{print $4}' | grep -Eq "[:.]${p}$"; then
            record WARN services "Administrative-looking port listening" "$p" "Confirm it is required and firewalled"
        fi
    done

    # Unattended services worth reviewing
    local svc
    for svc in telnet vsftpd rsh-server; do
        if systemctl list-unit-files 2>/dev/null | grep -q "^${svc}\.service"; then
            record FAIL services "Legacy/insecure service installed" "$svc" "apt-get purge $svc"
        fi
    done
}

# ---------------------------------------------------------------------------
# 10. Docker / Juice Shop
# ---------------------------------------------------------------------------
check_docker() {
    want_section docker || return 0
    if ! docker_ready; then
        record WARN docker "Docker available" "daemon not reachable" "Start docker or install it (install.sh --install-deps)"
        return 0
    fi
    record PASS docker "Docker daemon reachable" "$(docker version --format '{{.Server.Version}}' 2>/dev/null)" "-"

    local cid
    cid="$(docker ps -q --filter 'name=vulnserver-juice-shop' 2>/dev/null)"
    if [[ -z "$cid" ]]; then
        record WARN docker "Juice Shop container" "not running" "cd ${LAB_WEB_DIR} && docker compose up -d"
        return 0
    fi
    local ports image priv
    ports="$(docker port "$cid" 2>/dev/null | tr '\n' ';')"
    image="$(docker inspect -f '{{.Config.Image}}' "$cid" 2>/dev/null)"
    priv="$(docker inspect -f '{{.HostConfig.Privileged}}' "$cid" 2>/dev/null)"

    record PASS docker "Juice Shop running" "$image" "-"
    if [[ "$priv" == "true" ]]; then
        record FAIL docker "Container runs privileged" "$cid" "Set privileged: false (compose default)"
    else
        record PASS docker "Container not privileged" "false" "-"
    fi

    if [[ "$ports" == *"0.0.0.0:${JUICE_SHOP_PORT}"* ]]; then
        record WARN docker "Juice Shop published on all interfaces" "$ports" "Rely on UFW/WireGuard, or set LAB_BIND_ADDR to the lab interface"
    else
        record PASS docker "Juice Shop publish scope" "$ports" "-"
    fi

    if docker ps -q 2>/dev/null | wc -l | awk '{exit !($1 > 1)}'; then
        record WARN docker "Other containers running" "$(docker ps --format '{{.Names}}' | tr '\n' ',')" "Keep the lab host dedicated"
    fi
}

# ---------------------------------------------------------------------------
# 11. auditd
# ---------------------------------------------------------------------------
check_auditd() {
    want_section auditd || return 0
    if ! command -v auditctl >/dev/null 2>&1; then
        record FAIL auditd "auditd installed" "not installed" "apt-get install auditd audispd-plugins"
        return 0
    fi
    service_active auditd && record PASS auditd "auditd service" "active" "-" \
                         || record FAIL auditd "auditd service" "inactive" "systemctl enable --now auditd"

    if [[ -f "$AUDIT_RULES_FILE" ]]; then
        record PASS auditd "VulnServer audit rules installed" "$AUDIT_RULES_FILE" "-"
    else
        record FAIL auditd "VulnServer audit rules installed" "missing" "scripts/monitoring/setup_audit.sh apply"
    fi

    local loaded
    loaded="$(auditctl -l 2>/dev/null | grep -c vulnserver || true)"
    if (( loaded > 0 )); then
        record PASS auditd "Audit rules loaded in kernel" "${loaded} rules" "-"
    else
        record WARN auditd "Audit rules loaded in kernel" "0" "augenrules --load"
    fi
}

# ---------------------------------------------------------------------------
# 12. Lab-specific leak checks
# ---------------------------------------------------------------------------
check_lab() {
    want_section lab || return 0
    if [[ -d "$LAB_DATA_DIR" ]]; then
        local leaks
        leaks="$(grep -rIl --exclude-dir=logs -E 'VS\{(USER|PRIVILEGE|ROOT)-' "$LAB_DATA_DIR" 2>/dev/null | tr '\n' ' ')"
        if [[ -z "${leaks// /}" ]]; then
            record PASS lab "No flag values copied into lab data" "none" "-"
        else
            record FAIL lab "Flag values present in lab data" "$leaks" "Flags must stay in ${LAB_FLAG_DIR} only"
        fi
    fi

    if [[ -f "$LAB_WEB_DIR/.env" ]]; then
        local mode; mode="$(stat -c '%a' "$LAB_WEB_DIR/.env")"
        (( 8#$mode & 8#004 )) && record FAIL lab "web/.env is world-readable" "$mode" "chmod 640 $LAB_WEB_DIR/.env" \
                             || record PASS lab "web/.env permissions" "$mode" "-"
    fi

    # Real secrets accidentally committed would be a project error, not a lab one.
    if [[ -d "$VULNSERVER_REPO_DIR/.git" ]]; then
        if git -C "$VULNSERVER_REPO_DIR" ls-files --error-unmatch flags/user.txt >/dev/null 2>&1; then
            record FAIL lab "Flags are tracked by git" "flags/user.txt" "Remove from the index: git rm --cached flags/*"
        else
            record PASS lab "Flags are not tracked by git" "ok" "-"
        fi
    fi
}

# ---------------------------------------------------------------------------
main() {
    banner
    info "Running read-only audit (no changes will be made)"
    check_os
    check_ssh
    check_accounts
    check_permissions
    check_sudo
    check_suid
    check_cron
    check_firewall
    check_services
    check_docker
    check_auditd
    check_lab

    local total; total=$((COUNTS_PASS + COUNTS_WARN + COUNTS_FAIL))
    local report_file=""
    local ts; ts="$(date +"$LAB_TS_FORMAT")"

    render() {
        printf '# VulnServer audit report\n\n'
        printf -- '- Generated: %s\n- Host: %s\n- Result: %s PASS, %s WARN, %s FAIL (of %s checks)\n\n' \
            "$ts" "$(hostname)" "$COUNTS_PASS" "$COUNTS_WARN" "$COUNTS_FAIL" "$total"
        printf '| Status | Section | Check | Current state | Recommendation |\n'
        printf '|---|---|---|---|---|\n'
        sort -t$'\t' -k2,2 -k1,1 "$TMP_FINDINGS" |
            awk -F'\t' '{printf "| **%s** | %s | %s | %s | %s |\n", $1,$2,$3,$4,$5}'
        printf '\n## Summary by section\n\n| Section | PASS | WARN | FAIL |\n|---|---|---|---|\n'
        cut -f2 "$TMP_FINDINGS" | sort -u | while read -r s; do
            awk -F'\t' -v s="$s" '$2==s {c[$1]++} END {printf "| %s | %d | %d | %d |\n", s, c["PASS"], c["WARN"], c["FAIL"]}' "$TMP_FINDINGS"
        done
        printf '\n_Generated by audit.sh (read-only). Fix findings with harden.sh._\n'
    }

    if (( STDOUT == 1 )); then
        render
    else
        mkdir -p "$LAB_REPORT_DIR"
        report_file="${LAB_REPORT_DIR}/audit-$(timestamp_slug).md"
        render > "$report_file"
        chmod 0640 "$report_file" 2>/dev/null || true
        printf '\n'
        column -t -s$'\t' "$TMP_FINDINGS" 2>/dev/null | head -n 60 || cat "$TMP_FINDINGS"
        hr
        printf 'PASS: %d   WARN: %d   FAIL: %d   (total %d)\n' "$COUNTS_PASS" "$COUNTS_WARN" "$COUNTS_FAIL" "$total"
        ok "Report: ${report_file}"
        log_event "AUDIT_RUN" "audit" "-" "$( ((COUNTS_FAIL>0)) && echo WARNING || echo SUCCESS )" \
            "pass=${COUNTS_PASS} warn=${COUNTS_WARN} fail=${COUNTS_FAIL} report=${report_file}"
    fi

    if (( STRICT == 1 && COUNTS_FAIL > 0 )); then
        return 1
    fi
    return 0
}
main
