#!/usr/bin/env bash
# =============================================================================
# VulnServer - harden.sh
# Applies the hardening module (section 11 of the brief).
#
#   sudo ./harden.sh --audit              # read-only analysis (same as audit.sh)
#   sudo ./harden.sh                      # interactive: analyse, confirm, fix
#   sudo ./harden.sh --apply --yes        # non-interactive full hardening
#   sudo ./harden.sh --apply --only suid,sudo,cron
#   sudo ./harden.sh --list               # list hardenable sections
#   sudo ./harden.sh --restore <backup>   # restore a previous backup
#
# Every fix:
#   1. copies the affected file/directory into $LAB_BACKUP_DIR/file-<ts>/...
#   2. records what it will change
#   3. applies the change (after confirmation unless --yes)
#   4. verifies the result and logs it
#
# The script never touches anything outside the lab's own components.
# =============================================================================
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

MODE="interactive"; ONLY=""; RESTORE_FROM=""
while (( $# > 0 )); do
    case "$1" in
        --audit)   MODE="audit"; shift ;;
        --apply)   MODE="apply"; shift ;;
        -y|--yes)  ASSUME_YES=1; shift ;;
        -n|--dry-run) DRY_RUN=1; shift ;;
        --only)    ONLY="${2:?--only needs a list}"; shift 2 ;;
        --list)    MODE="list"; shift ;;
        --restore) MODE="restore"; RESTORE_FROM="${2:?--restore needs a directory}"; shift 2 ;;
        -h|--help) sed -n '2,22p' "$0"; exit 0 ;;
        *) die "unknown option: $1" ;;
    esac
done
export ASSUME_YES DRY_RUN

# --list only prints section names; every other mode changes or reads privileged state.
[[ "$MODE" == "list" ]] || require_root "$@"
check_deps tar find awk sed

SECTIONS="ssh accounts permissions sudo suid cron firewall services docker updates auditd"
BACKUP_TS="$(timestamp_slug)"
BACKUP_ROOT="${LAB_BACKUP_DIR}/files-${BACKUP_TS}"
CHANGED=0

want() { [[ -z "$ONLY" || ",${ONLY}," == *",$1,"* ]]; }

# ---------------------------------------------------------------------------
# Backup helpers
# ---------------------------------------------------------------------------
backup_path() { # <path>
    local p="$1"
    [[ -e "$p" ]] || return 0
    if [[ "$DRY_RUN" == "1" ]]; then
        dim "[dry-run] would back up $p"
        return 0
    fi
    mkdir -p "${BACKUP_ROOT}${p%/*}" 2>/dev/null || { warn "cannot create backup for $p"; return 1; }
    cp -a "$p" "${BACKUP_ROOT}${p}" 2>/dev/null || { warn "backup of $p failed"; return 1; }
    # Never keep privilege bits in a backup copy: a SUID binary stored inside
    # the lab tree would itself become an escalation path.
    chmod u-s,g-s "${BACKUP_ROOT}${p}" 2>/dev/null || true
    printf '%s\n' "$p" >> "${BACKUP_ROOT}/index.txt"
}

make_manifest() {
    [[ "$DRY_RUN" == "1" ]] && return 0
    mkdir -p "$BACKUP_ROOT"
    {
        printf 'vulnserver hardening backup\n'
        printf 'timestamp=%s\n' "$(date +"$LAB_TS_FORMAT")"
        printf 'host=%s\n' "$(hostname)"
        printf 'actor=%s\n' "${VULNSERVER_ACTOR:-${SUDO_USER:-${USER:-unknown}}}"
        printf 'sections=%s\n' "${ONLY:-all}"
    } > "${BACKUP_ROOT}/MANIFEST.txt"
    chmod -R go-rwx "$BACKUP_ROOT" 2>/dev/null || true
    ok "Backup directory: ${BACKUP_ROOT}"
}

# apply_change <description> <command...>
apply_change() {
    local desc="$1"; shift
    if ! confirm "${desc}?"; then
        dim "skipped: ${desc}"
        return 1
    fi
    if run_cmd "$@"; then
        CHANGED=$((CHANGED+1))
        log_event "HARDEN_FIX" "hardening" "-" "SUCCESS" "$desc"
        ok "${desc}"
        return 0
    fi
    warn "failed: ${desc}"
    log_event "HARDEN_FIX" "hardening" "-" "FAILURE" "$desc"
    return 1
}

# ---------------------------------------------------------------------------
# Section: SSH
# ---------------------------------------------------------------------------
harden_ssh() {
    want ssh || return 0
    local dropin="/etc/ssh/sshd_config.d/99-vulnserver.conf"
    local eff; eff="$(sshd -T 2>/dev/null || true)"
    local pass_auth; pass_auth="$(printf '%s\n' "$eff" | awk '/^passwordauthentication /{print $2}')"

    if [[ "$pass_auth" != "no" ]]; then
        warn "Disabling password authentication will block users without SSH keys."
        if [[ -n "$(find /home -name authorized_keys 2>/dev/null)" ]]; then
            dim "authorized_keys found for at least one account"
        else
            warn "no authorized_keys found under /home - do this only after distributing keys"
        fi
        backup_path "$dropin"
        if confirm "Disable SSH password authentication (key-only)?"; then
            if [[ "$DRY_RUN" != "1" ]]; then
                if [[ -f "$dropin" ]]; then
                    sed -i 's/^PasswordAuthentication.*/PasswordAuthentication no/' "$dropin"
                    grep -q '^PasswordAuthentication' "$dropin" || echo 'PasswordAuthentication no' >> "$dropin"
                    sed -i 's/^KbdInteractiveAuthentication.*/KbdInteractiveAuthentication no/' "$dropin"
                else
                    printf 'PasswordAuthentication no\nKbdInteractiveAuthentication no\n' > "$dropin"
                fi
                if sshd -t; then
                    systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null || true
                    CHANGED=$((CHANGED+1)); ok "SSH password authentication disabled"
                    log_event "HARDEN_FIX" "sshd" "-" "SUCCESS" "PasswordAuthentication=no"
                else
                    warn "sshd -t failed, restoring drop-in"
                    [[ -f "${BACKUP_ROOT}${dropin}" ]] && cp -a "${BACKUP_ROOT}${dropin}" "$dropin"
                fi
            fi
        fi
    else
        ok "SSH: password authentication already disabled"
    fi

    # MaxAuthTries
    if [[ -f "$dropin" ]] && ! grep -q '^MaxAuthTries 3' "$dropin"; then
        backup_path "$dropin"
        apply_change "Set MaxAuthTries 3" sed -i 's/^MaxAuthTries.*/MaxAuthTries 3/' "$dropin" || true
    fi
}

# ---------------------------------------------------------------------------
# Section: accounts
# ---------------------------------------------------------------------------
harden_accounts() {
    want accounts || return 0
    local g
    for g in sudo adm docker; do
        if id -nG "$LAB_USER" 2>/dev/null | tr ' ' '\n' | grep -qx "$g"; then
            apply_change "Remove ${LAB_USER} from group ${g}" gpasswd -d "$LAB_USER" "$g"
        fi
    done

    if ! passwd -S "$PRIV_USER" 2>/dev/null | awk '{print $2}' | grep -qE '^(L|LK)$'; then
        apply_change "Lock the intermediate account ${PRIV_USER}" passwd -l "$PRIV_USER"
    else
        ok "accounts: ${PRIV_USER} is locked"
    fi

    local empty
    empty="$(awk -F: '$2 == "" {print $1}' /etc/shadow 2>/dev/null)"
    if [[ -n "$empty" ]]; then
        local u
        for u in $empty; do
            apply_change "Lock account with empty password: ${u}" passwd -l "$u"
        done
    else
        ok "accounts: no empty password fields"
    fi
}

# ---------------------------------------------------------------------------
# Section: permissions
# ---------------------------------------------------------------------------
harden_permissions() {
    want permissions || return 0
    local spec path owner group mode
    for spec in "${FLAG_USER_FILE}:${LAB_USER}:${LAB_USER}:600" \
                "${FLAG_PRIV_FILE}:root:${PRIV_USER}:640" \
                "${FLAG_ROOT_FILE}:root:root:400"; do
        path="${spec%%:*}"; spec="${spec#*:}"
        owner="${spec%%:*}"; spec="${spec#*:}"
        group="${spec%%:*}"; mode="${spec#*:}"
        [[ -f "$path" ]] || continue
        if [[ "$(stat -c '%U:%G' "$path")" != "${owner}:${group}" || "$(stat -c '%a' "$path")" != "$mode" ]]; then
            backup_path "$path"
            apply_change "Fix permissions of $(basename "$path") (${owner}:${group} ${mode})" \
                sh -c "chown '${owner}:${group}' '$path' && chmod '${mode}' '$path'"
        fi
    done

    for spec in "${LAB_LOG_DIR}:root:root:750" "${LAB_BACKUP_DIR}:root:root:700" \
                "${LAB_REPORT_DIR}:root:root:750" "${LAB_STATE_DIR}:root:root:755"; do
        path="${spec%%:*}"; spec="${spec#*:}"
        owner="${spec%%:*}"; spec="${spec#*:}"
        group="${spec%%:*}"; mode="${spec#*:}"
        [[ -d "$path" ]] || continue
        if [[ "$(stat -c '%U:%G' "$path")" != "${owner}:${group}" || "$(stat -c '%a' "$path")" != "$mode" ]]; then
            apply_change "Fix permissions of directory $(basename "$path")" \
                sh -c "chown '${owner}:${group}' '$path' && chmod '${mode}' '$path'"
        fi
    done

    local ww
    ww="$(find "$LAB_STATE_DIR" -xdev -type d -perm -0002 2>/dev/null)"
    if [[ -n "$ww" ]]; then
        local d
        while IFS= read -r d; do
            [[ -z "$d" ]] && continue
            backup_path "$d"
            apply_change "Restore baseline mode 0755 on ${d}" chmod 0755 "$d"
        done <<< "$ww"
    else
        ok "permissions: no world-writable directories"
    fi
}

# ---------------------------------------------------------------------------
# Section: sudo
# ---------------------------------------------------------------------------
harden_sudo() {
    want sudo || return 0
    local f
    for f in /etc/sudoers.d/vulnserver-lab-*; do
        [[ -e "$f" ]] || continue
        backup_path "$f"
        apply_change "Remove lab sudoers file $(basename "$f")" rm -f "$f"
    done

    if [[ -e "$SCENARIO_B_HELPER" ]]; then
        local m g
        m="$(stat -c '%a' "$SCENARIO_B_HELPER")"; g="$(stat -c '%G' "$SCENARIO_B_HELPER")"
        if [[ "$m" =~ ^7 || "$g" == "$PRIV_USER" ]]; then
            backup_path "$SCENARIO_B_HELPER"
            apply_change "Secure root helper (root:root 0755)" \
                sh -c "chown root:root '$SCENARIO_B_HELPER' && chmod 0755 '$SCENARIO_B_HELPER'"
        fi
    fi

    if visudo -c >/dev/null 2>&1; then
        ok "sudo: policy syntax valid"
    else
        warn "sudo: 'visudo -c' reports an error - inspect /etc/sudoers.d immediately"
    fi
}

# ---------------------------------------------------------------------------
# Section: SUID / SGID
# ---------------------------------------------------------------------------
harden_suid() {
    want suid || return 0
    local known_safe="/usr/bin/su /usr/bin/sudo /usr/bin/passwd /usr/bin/chsh /usr/bin/chfn /usr/bin/newgrp /usr/bin/gpasswd /usr/bin/mount /usr/bin/umount /usr/lib/openssh/ssh-keysign /usr/lib/dbus-1.0/dbus-daemon-launch-helper /usr/bin/fusermount3 /usr/libexec/polkit-agent-helper-1"
    local f suspicious=()
    while IFS= read -r f; do
        [[ -z "$f" ]] && continue
        [[ " $known_safe " == *" $f "* ]] && continue
        suspicious+=("$f")
    done < <(find /usr /bin /sbin /opt -xdev -type f -perm -4000 \
                -not -path "${LAB_BACKUP_DIR}/*" 2>/dev/null)

    if (( ${#suspicious[@]} == 0 )); then
        ok "suid: no unexpected SUID binaries"
        return 0
    fi
    for f in "${suspicious[@]}"; do
        warn "unexpected SUID binary: ${f} ($(stat -c '%A %U:%G' "$f"))"
        backup_path "$f"
        apply_change "Remove SUID bit from ${f}" chmod u-s "$f"
    done
}

# ---------------------------------------------------------------------------
# Section: cron
# ---------------------------------------------------------------------------
harden_cron() {
    want cron || return 0
    local f
    for f in /etc/cron.d/vulnserver-lab-*; do
        [[ -e "$f" ]] || continue
        backup_path "$f"
        apply_change "Remove lab cron drop-in $(basename "$f")" rm -f "$f"
    done

    local d
    for d in /etc/cron.d /etc/cron.hourly /etc/cron.daily /etc/cron.weekly /etc/cron.monthly "$LAB_DATA_DIR"; do
        [[ -d "$d" ]] || continue
        if find "$d" -maxdepth 0 -perm -0002 | grep -q .; then
            apply_change "Restore standard mode 0755 on cron directory ${d}" chmod 0755 "$d"
        fi
    done

    if [[ -f "$SCENARIO_C_SCRIPT" ]]; then
        if [[ "$(stat -c '%a' "$SCENARIO_C_SCRIPT")" != "755" || "$(stat -c '%U:%G' "$SCENARIO_C_SCRIPT")" != "root:root" ]]; then
            backup_path "$SCENARIO_C_SCRIPT"
            apply_change "Secure lab cron script (root:root 0755)" \
                sh -c "chown root:root '$SCENARIO_C_SCRIPT' && chmod 0755 '$SCENARIO_C_SCRIPT'"
        fi
    fi
}

# ---------------------------------------------------------------------------
# Section: firewall
# ---------------------------------------------------------------------------
harden_firewall() {
    want firewall || return 0
    if ! command -v ufw >/dev/null 2>&1; then
        warn "firewall: ufw not installed (skipping)"; return 0
    fi
    if ufw status 2>/dev/null | head -n1 | grep -q inactive; then
        apply_change "Enable UFW with the lab rule set" \
            "$SCRIPT_DIR/config/ufw/ufw-rules.sh" apply
    else
        ok "firewall: UFW already active"
    fi
}

# ---------------------------------------------------------------------------
# Section: services
# ---------------------------------------------------------------------------
harden_services() {
    want services || return 0
    # Docker API over TCP
    local unitdrop="/etc/systemd/system/docker.service.d/10-vulnserver-tcp.conf"
    if ss -ltnH 2>/dev/null | awk '{print $4}' | grep -qE ':2375$|:2376$'; then
        warn "Docker API is listening on TCP; removing the override"
        backup_path "$unitdrop"
        apply_change "Remove the Docker TCP API override" rm -f "$unitdrop"
    else
        ok "services: Docker API not exposed on TCP"
    fi

    # Legacy services
    local svc
    for svc in telnet vsftpd rsh-server; do
        if systemctl list-unit-files 2>/dev/null | grep -q "^${svc}\.service"; then
            apply_change "Disable legacy service ${svc}" systemctl disable --now "$svc"
        fi
    done
}

# ---------------------------------------------------------------------------
# Section: docker
# ---------------------------------------------------------------------------
harden_docker() {
    want docker || return 0
    if ! docker_ready; then
        warn "docker: daemon not reachable (skipping)"; return 0
    fi
    local cid
    cid="$(docker ps -q --filter 'name=vulnserver-juice-shop' 2>/dev/null)"
    if [[ -z "$cid" ]]; then
        ok "docker: Juice Shop not running"
        return 0
    fi

    # Bind the container to the lab interface instead of 0.0.0.0
    if docker port "$cid" 2>/dev/null | grep -q '0.0.0.0'; then
        local iface_ip
        iface_ip="$(ip -4 -o addr show scope global 2>/dev/null | awk 'NR==1 {split($4,a,"/"); print a[1]}')"
        if [[ -n "$iface_ip" ]]; then
            backup_path "$LAB_WEB_DIR/docker-compose.yml"
            backup_path "$LAB_WEB_DIR/.env"
            if confirm "Bind Juice Shop to ${iface_ip}:${JUICE_SHOP_PORT} instead of 0.0.0.0?"; then
                if [[ "$DRY_RUN" != "1" ]]; then
                    sed -i "s/^LAB_BIND_ADDR=.*/LAB_BIND_ADDR=${iface_ip}/" "$LAB_WEB_DIR/.env" 2>/dev/null || \
                        printf 'LAB_BIND_ADDR=%s\n' "$iface_ip" >> "$LAB_WEB_DIR/.env"
                    ( cd "$LAB_WEB_DIR" && docker compose up -d --force-recreate >/dev/null 2>&1 ) && {
                        CHANGED=$((CHANGED+1)); ok "Juice Shop bound to ${iface_ip}"
                        log_event "HARDEN_FIX" "docker" "-" "SUCCESS" "bind=${iface_ip}"; }
                fi
            fi
        fi
    fi

    # Ensure no-new-privileges and a memory limit
    if [[ "$(docker inspect -f '{{.HostConfig.Privileged}}' "$cid" 2>/dev/null)" == "true" ]]; then
        backup_path "$LAB_WEB_DIR/docker-compose.yml"
        apply_change "Recreate the container without privileged mode" \
            sh -c "cd '$LAB_WEB_DIR' && docker compose up -d --force-recreate"
    else
        ok "docker: container is not privileged"
    fi
}

# ---------------------------------------------------------------------------
# Section: updates
# ---------------------------------------------------------------------------
harden_updates() {
    want updates || return 0
    if ! systemctl is-enabled --quiet unattended-upgrades 2>/dev/null; then
        if dpkg -l unattended-upgrades >/dev/null 2>&1; then
            apply_change "Enable unattended-upgrades" systemctl enable --now unattended-upgrades
        else
            warn "updates: unattended-upgrades not installed (apt-get install unattended-upgrades)"
        fi
    else
        ok "updates: unattended-upgrades enabled"
    fi

    local pending
    pending="$(apt-get -s -o Debug::NoLocking=true upgrade 2>/dev/null | grep -c '^Inst ' || true)"
    if (( pending > 0 )); then
        warn "${pending} packages can be upgraded. Apply them during a maintenance window: apt-get upgrade"
        dim "not applied automatically: an unattended upgrade could reboot the lab mid-exercise"
    fi
}

# ---------------------------------------------------------------------------
# Section: auditd
# ---------------------------------------------------------------------------
harden_auditd() {
    want auditd || return 0
    if command -v auditctl >/dev/null 2>&1; then
        if [[ ! -f "$AUDIT_RULES_FILE" ]]; then
            apply_change "Install VulnServer audit rules" \
                "$SCRIPT_DIR/scripts/monitoring/setup_audit.sh" apply
        else
            ok "auditd: rules already installed"
        fi
    else
        warn "auditd: not installed (apt-get install auditd audispd-plugins)"
    fi
}

# ---------------------------------------------------------------------------
# Restore
# ---------------------------------------------------------------------------
restore_backup() {
    local dir="$RESTORE_FROM"
    [[ -d "$dir" ]] || die "backup directory not found: $dir"
    [[ -f "$dir/index.txt" ]] || die "not a harden.sh backup (index.txt missing): $dir"
    warn "About to restore files from ${dir}"
    sed 's/^/    /' "$dir/index.txt"
    confirm "Restore these ${#} files?" || exit 0
    local p
    while IFS= read -r p; do
        [[ -z "$p" ]] && continue
        if [[ -e "${dir}${p}" ]]; then
            run_cmd cp -a "${dir}${p}" "$p"
            ok "restored ${p}"
            log_event "HARDEN_RESTORE" "hardening" "-" "SUCCESS" "restored=${p} from=${dir}"
        else
            warn "missing in backup: ${p}"
        fi
    done < "$dir/index.txt"
    command -v sshd >/dev/null 2>&1 && sshd -t && { systemctl reload ssh 2>/dev/null || true; }
    command -v augenrules >/dev/null 2>&1 && augenrules --load >/dev/null 2>&1 || true
    ok "Restore complete - verify with ./audit.sh"
}

# ---------------------------------------------------------------------------
main() {
    case "$MODE" in
        list)  printf 'Hardenable sections:\n'; for s in $SECTIONS; do printf '  %s\n' "$s"; done; exit 0 ;;
        restore) restore_backup ;;
        audit) require_root "$@"; exec "$SCRIPT_DIR/audit.sh" --stdout ;;
    esac

    banner
    warn "Hardening modifies system configuration. A backup is created first."
    make_manifest
    log_event "HARDEN_START" "hardening" "-" "STARTED" "sections=${ONLY:-all} backup=${BACKUP_ROOT}"

    harden_ssh
    harden_accounts
    harden_permissions
    harden_sudo
    harden_suid
    harden_cron
    harden_firewall
    harden_services
    harden_docker
    harden_updates
    harden_auditd

    hr
    if (( CHANGED == 0 )); then
        ok "No changes were required"
    else
        ok "${CHANGED} change(s) applied"
        ok "Backup: ${BACKUP_ROOT}"
        dim "Rollback: sudo $0 --restore ${BACKUP_ROOT}"
    fi
    log_event "HARDEN_COMPLETE" "hardening" "-" "SUCCESS" "changes=${CHANGED} backup=${BACKUP_ROOT}"
    printf '\nRe-run the audit to confirm: %s/audit.sh\n' "$SCRIPT_DIR"
}
main
