#!/usr/bin/env bash
# =============================================================================
# VulnServer - scripts/flags/generate_flags.sh
# Creates the three lab flags with random identifiers and correct ownership.
#
#   ./generate_flags.sh generate [--force]   # (re)generate all flags
#   ./generate_flags.sh verify               # check perms + content format
#   ./generate_flags.sh show                 # admin only: print flags
#
# Permission model (section 8):
#   user.txt       labuser:labuser 0600  -> proves initial access
#   privilege.txt  root:labpriv    0640  -> proves intermediate level
#   root.txt       root:root       0400  -> proves root
# =============================================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../../lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

require_root "$@"
action="${1:-generate}"
force="${2:-}"

new_flag() { # <label>
    printf '%s{%s-%s}\n' "$FLAG_PREFIX" "$1" "$(openssl rand -hex 16)"
}

generate_flags() {
    if [[ -s "$FLAG_USER_FILE" && "$force" != "--force" ]]; then
        warn "flags already exist (use --force to rotate). Nothing changed."
        return 0
    fi
    run_cmd mkdir -p "$LAB_FLAG_DIR"
    id "$LAB_USER" >/dev/null 2>&1 || die "user ${LAB_USER} does not exist; run install.sh first"
    getent group "$PRIV_USER" >/dev/null 2>&1 || die "group ${PRIV_USER} does not exist"

    if [[ "$DRY_RUN" == "1" ]]; then
        dim "[dry-run] would write three flags in ${LAB_FLAG_DIR}"
        return 0
    fi

    # Create with restrictive perms first, then write, then fix ownership.
    umask 077
    printf '%s\n' "$(new_flag USER)" > "$FLAG_USER_FILE"
    printf '%s\n' "$(new_flag PRIVILEGE)" > "$FLAG_PRIV_FILE"
    printf '%s\n' "$(new_flag ROOT)" > "$FLAG_ROOT_FILE"

    chown "${LAB_USER}:${LAB_USER}" "$FLAG_USER_FILE"
    chmod 0600 "$FLAG_USER_FILE"

    chown "root:${PRIV_USER}" "$FLAG_PRIV_FILE"
    chmod 0640 "$FLAG_PRIV_FILE"

    chown root:root "$FLAG_ROOT_FILE"
    chmod 0400 "$FLAG_ROOT_FILE"

    # Flags are world-searchable only through the directory (0755) so paths are
    # discoverable but contents are not.
    chown root:root "$LAB_FLAG_DIR"
    chmod 0755 "$LAB_FLAG_DIR"

    log_event "FLAGS_GENERATE" "flags" "-" "SUCCESS" "rotated=false force=${force:-no}"
    ok "Flags generated:"
    dim "  ${FLAG_USER_FILE}       (labuser)"
    dim "  ${FLAG_PRIV_FILE}    (root:${PRIV_USER})"
    dim "  ${FLAG_ROOT_FILE}      (root only)"
}

verify_flags() {
    # spec layout: path:owner:group:mode
    local rc=0 spec f want_owner want_group want_mode mode actual
    printf '%-46s %-22s %-6s %s\n' FILE OWNER MODE RESULT
    for spec in "${FLAG_USER_FILE}:${LAB_USER}:${LAB_USER}:600" \
                "${FLAG_PRIV_FILE}:root:${PRIV_USER}:640" \
                "${FLAG_ROOT_FILE}:root:root:400"; do
        f="${spec%%:*}"; spec="${spec#*:}"
        want_owner="${spec%%:*}"; spec="${spec#*:}"
        want_group="${spec%%:*}"; want_mode="${spec#*:}"
        if [[ ! -f "$f" ]]; then
            printf '%-46s %-22s %-6s %s\n' "$f" "-" "-" "MISSING"; rc=1; continue
        fi
        mode="$(stat -c '%a' "$f")"
        actual="$(stat -c '%U:%G' "$f")"
        if [[ "$actual" == "${want_owner}:${want_group}" && "$mode" == "$want_mode" && -s "$f" ]]; then
            printf '%-46s %-22s %-6s %s\n' "$f" "$actual" "$mode" "PASS"
        else
            printf '%-46s %-22s %-6s %s (want %s %s)\n' "$f" "$actual" "$mode" "FAIL" \
                "${want_owner}:${want_group}" "$want_mode"
            rc=1
        fi
    done
    [[ $rc -eq 0 ]] && ok "Flag permissions are correct" || warn "Flag permission drift detected"
    return $rc
}

case "$action" in
    generate) generate_flags ;;
    verify)   verify_flags ;;
    show)
        # Administrative convenience only; never exposed to students.
        for f in "$FLAG_USER_FILE" "$FLAG_PRIV_FILE" "$FLAG_ROOT_FILE"; do
            printf '%-16s %s\n' "$(basename "$f")" "$(cat "$f" 2>/dev/null || echo MISSING)"
        done
        ;;
    *) die "usage: $0 {generate [--force]|verify|show}" ;;
esac
