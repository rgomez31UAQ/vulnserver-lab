#!/usr/bin/env bash
# =============================================================================
# VulnServer - scripts/sudo/apply_sudo.sh
# Manages the *baseline* sudo policy shared by all scenarios.
#
#   ./apply_sudo.sh base      # write /etc/sudoers.d/vulnserver-base (idempotent)
#   ./apply_sudo.sh validate  # syntax-check every vulnserver sudoers file
#   ./apply_sudo.sh show      # print the policy files
#   ./apply_sudo.sh remove    # remove base policy (scenario files are separate)
#
# Baseline guarantees:
#   * adminlab administers the host through the standard "sudo" group.
#   * labuser has NO general sudo rights (scenario B adds a narrow, broken one).
#   * sudo logs to its own file so auditd/journalctl have a clean trail.
# =============================================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../../lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

require_root "$@"

BASE_SUDOERS="/etc/sudoers.d/vulnserver-base"
SUDO_LOG="/var/log/sudo-vulnserver.log"

write_base() {
    check_deps visudo || die "visudo not found (install the sudo package)"
    run_cmd install -d -m 0750 -o root -g root /etc/sudoers.d
    run_cmd install -m 0600 -o root -g root /dev/null "$SUDO_LOG" || true

    local tmp; tmp="$(mktemp)"
    cat > "$tmp" <<EOF
# VulnServer baseline sudo policy - managed by scripts/sudo/apply_sudo.sh
# Do not edit by hand: re-run the script instead.
Defaults        use_pty
Defaults        logfile="${SUDO_LOG}"
Defaults        log_input, log_output
Defaults        lecture=once
# labuser must never receive general administrative rights.
${LAB_USER}     ALL=(root) !ALL
EOF
    if ! visudo -cqf "$tmp"; then
        rm -f "$tmp"
        die "generated sudoers file failed validation - aborting (host sudo untouched)"
    fi
    run_cmd install -m 0440 -o root -g root "$tmp" "$BASE_SUDOERS"
    rm -f "$tmp"

    log_event "SUDO_BASE" "sudo" "-" "SUCCESS" "file=${BASE_SUDOERS}"
    ok "Baseline sudo policy installed (${BASE_SUDOERS})"
}

validate_all() {
    local rc=0 f
    check_deps visudo || die "visudo not found"
    for f in /etc/sudoers.d/vulnserver-*; do
        [[ -e "$f" ]] || continue
        if visudo -cqf "$f" >/dev/null 2>&1; then
            printf '%-52s %s\n' "$f" "PASS"
        else
            printf '%-52s %s\n' "$f" "FAIL"
            rc=1
        fi
    done
    (( rc == 0 )) && ok "All VulnServer sudoers files are syntactically valid"
    return $rc
}

remove_base() {
    confirm "Remove the VulnServer baseline sudo policy?" || exit 1
    run_cmd rm -f "$BASE_SUDOERS"
    log_event "SUDO_BASE_REMOVE" "sudo" "-" "SUCCESS" "file=${BASE_SUDOERS}"
}

case "${1:-base}" in
    base)     write_base ;;
    validate) validate_all ;;
    show)     for f in /etc/sudoers.d/vulnserver-*; do [[ -e "$f" ]] && { echo "== $f"; cat "$f"; }; done ;;
    remove)   remove_base ;;
    *) die "usage: $0 {base|validate|show|remove}" ;;
esac
