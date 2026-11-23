#!/usr/bin/env bash
# =============================================================================
# VulnServer - scripts/users/create_users.sh
# Creates the three laboratory accounts.
#
#   ./create_users.sh create   # create/repair accounts (idempotent)
#   ./create_users.sh status   # show accounts and group membership
#   ./create_users.sh remove   # delete the accounts (asks for confirmation)
#
# Accounts:
#   adminlab -> member of "sudo", the owner's administrative account.
#   labuser  -> ordinary user, no administrative group. Entry point.
#   labpriv  -> intermediate level. Password locked: reachable only through
#               Scenario B's sudo rule, never by direct login.
# =============================================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../../lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

require_root "$@"

ensure_user() { # <name> <shell> <comment>
    local name="$1" shell="$2" comment="$3"
    if id "$name" >/dev/null 2>&1; then
        dim "user ${name} already exists"
    else
        run_cmd useradd --create-home --shell "$shell" --comment "$comment" "$name"
        ok "created user ${name}"
    fi
}

ensure_group() { # <name>
    getent group "$1" >/dev/null 2>&1 || run_cmd groupadd "$1"
}

set_password() { # <user> <password>
    if [[ "$DRY_RUN" == "1" ]]; then
        dim "[dry-run] would set password for $1"
        return 0
    fi
    printf '%s:%s\n' "$1" "$2" | chpasswd
}

create_users() {
    info "Creating laboratory accounts"

    ensure_user "$ADMIN_USER" /bin/bash "VulnServer lab owner (administrator)"
    usermod -aG sudo "$ADMIN_USER" 2>/dev/null || run_cmd usermod -aG sudo "$ADMIN_USER"

    ensure_user "$LAB_USER" /bin/bash "VulnServer lab participant (unprivileged)"
    # Explicitly make sure labuser is NOT in an administrative group.
    for grp in sudo adm docker; do
        if id -nG "$LAB_USER" 2>/dev/null | tr ' ' '\n' | grep -qx "$grp"; then
            warn "removing ${LAB_USER} from group ${grp}"
            run_cmd gpasswd -d "$LAB_USER" "$grp" || true
        fi
    done

    # The intermediate account uses a dedicated group of the same name, so the
    # group is created first and reused (useradd would otherwise try to create
    # it again and fail).
    ensure_group "$PRIV_USER"
    if ! id "$PRIV_USER" >/dev/null 2>&1; then
        run_cmd useradd --create-home --gid "$PRIV_USER" --shell "$PRIV_USER_SHELL" \
            --comment "VulnServer intermediate privilege level (scenario B)" "$PRIV_USER"
        ok "created user ${PRIV_USER} (gid ${PRIV_USER})"
    else
        dim "user ${PRIV_USER} already exists"
        usermod -g "$PRIV_USER" "$PRIV_USER" 2>/dev/null || true
    fi

    # The intermediate account must not be usable as a login account.
    if [[ "$DRY_RUN" != "1" ]]; then
        passwd -l "$PRIV_USER" >/dev/null 2>&1 || true
        usermod --password '!' "$PRIV_USER" 2>/dev/null || true
        chage -E -1 "$PRIV_USER" 2>/dev/null || true
    fi

    set_password "$ADMIN_USER" "$ADMIN_USER_PASSWORD"
    set_password "$LAB_USER"  "$LAB_USER_PASSWORD"

    if [[ "$DRY_RUN" != "1" ]]; then
        # labuser home stays 0750: readable by its owner only.
        chmod 750 "/home/${LAB_USER}" 2>/dev/null || true
        chown "${LAB_USER}:${LAB_USER}" "/home/${LAB_USER}" 2>/dev/null || true
    fi

    log_event "USERS_CREATE" "accounts" "-" "SUCCESS" \
        "created=${ADMIN_USER},${LAB_USER},${PRIV_USER}"
    ok "Accounts ready: ${ADMIN_USER} (admin), ${LAB_USER} (lab), ${PRIV_USER} (intermediate, locked)"
}

status_users() {
    printf '%-12s %-6s %-6s %-10s %s\n' USER UID GID GROUPS SHELL
    local name
    for name in "$ADMIN_USER" "$LAB_USER" "$PRIV_USER"; do
        if id "$name" >/dev/null 2>&1; then
            printf '%-12s %-6s %-6s %-10s %s\n' "$name" \
                "$(id -u "$name")" "$(id -g "$name")" \
                "$(id -nG "$name" | tr ' ' ',')" "$(getent passwd "$name" | cut -d: -f7)"
        else
            printf '%-12s %s\n' "$name" "MISSING"
        fi
    done
    hr
    printf 'Password status:\n'
    passwd -S "$ADMIN_USER" 2>/dev/null || true
    passwd -S "$LAB_USER" 2>/dev/null || true
    passwd -S "$PRIV_USER" 2>/dev/null || true
}

remove_users() {
    confirm "Delete accounts ${ADMIN_USER}, ${LAB_USER}, ${PRIV_USER} and their homes?" || exit 1
    local name
    for name in "$LAB_USER" "$PRIV_USER"; do
        id "$name" >/dev/null 2>&1 && run_cmd userdel -r "$name" 2>/dev/null || true
    done
    # adminlab is deliberately kept: it is the owner's recovery account.
    warn "keeping ${ADMIN_USER} (owner account). Remove manually if required."
    log_event "USERS_REMOVE" "accounts" "-" "SUCCESS" "removed lab accounts"
}

case "${1:-create}" in
    create) create_users ;;
    status) status_users ;;
    remove) remove_users ;;
    *) die "usage: $0 {create|status|remove}" ;;
esac
