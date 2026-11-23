#!/usr/bin/env bash
# =============================================================================
# VulnServer - tests/container-runner.sh
# Executed INSIDE a disposable Ubuntu 24.04 container by tests/test-container.sh.
# It runs the laboratory end to end and prints machine-readable results:
#
#     RESULT|PASS|test-name|detail
#     RESULT|FAIL|test-name|detail
#
# This is a genuine functional test: users are created, permissions applied,
# scenarios exploited, flags read, audit/harden/reset executed. It does not
# simulate any of it.
# =============================================================================
set -uo pipefail
SRC="${SRC:-/src}"
export DEBIAN_FRONTEND=noninteractive
PASS=0; FAIL=0

pass() { PASS=$((PASS+1)); printf 'RESULT|PASS|%s|%s\n' "$1" "${2:-}"; }
fail() { FAIL=$((FAIL+1)); printf 'RESULT|FAIL|%s|%s\n' "$1" "${2:-}"; }

# check <name> <expected> <actual>
# An empty expectation is treated as a failure: it almost always means the
# command under test produced no output at all (e.g. a missing file), which
# must never be reported as a pass.
redact() { printf '%s' "$1" | sed -E 's/VS\{[^}]*\}/VS{REDACTED}/g'; }

check() {
    local exp act
    exp="$(redact "$2")"; act="$(redact "$3")"
    if [[ -z "$2" ]]; then
        fail "$1" "empty expectation - command produced no output (actual='${act}')"
    elif [[ "$2" == "$3" ]]; then
        pass "$1" "expected=${exp}"
    else
        fail "$1" "expected='${exp}' actual='${act}'"
    fi
}

say() { printf '\n=== %s ===\n' "$*"; }

# ---------------------------------------------------------------------------
# 0. Base image preparation
# ---------------------------------------------------------------------------
say "Installing test dependencies"
apt-get update -qq >/dev/null 2>&1
apt-get install -y -qq sudo cron jq curl openssl tar procps passwd gawk \
    findutils coreutils util-linux iproute2 >/dev/null 2>&1
if ! command -v sudo >/dev/null || ! command -v visudo >/dev/null; then
    fail "dependencies" "sudo/visudo not installed"
    exit 1
fi
pass "dependencies" "sudo cron jq curl openssl tar present"

# sudo needs a resolvable hostname in minimal containers
grep -q "$(hostname)" /etc/hosts || echo "127.0.0.1 $(hostname)" >> /etc/hosts

cd "$SRC" || { fail "repo mounted" "cannot cd $SRC"; exit 1; }
check "repo mounted" "yes" "$([[ -f install.sh ]] && echo yes || echo no)"

# ---------------------------------------------------------------------------
# 1. Installation (restricted profile: no docker/ufw/auditd/ssh on this host)
# ---------------------------------------------------------------------------
say "Running install.sh --profile container"
if ./install.sh --profile container --yes --skip-os-check >/tmp/install.log 2>&1; then
    pass "install.sh exit status" "0"
else
    fail "install.sh exit status" "non-zero (see /tmp/install.log)"
    tail -n 25 /tmp/install.log
fi

# ---------------------------------------------------------------------------
# 2. Accounts
# ---------------------------------------------------------------------------
say "Accounts"
check "adminlab exists" "yes" "$(id adminlab >/dev/null 2>&1 && echo yes || echo no)"
check "labuser exists" "yes" "$(id labuser >/dev/null 2>&1 && echo yes || echo no)"
check "labpriv exists" "yes" "$(id labpriv >/dev/null 2>&1 && echo yes || echo no)"
check "labuser not in sudo group" "no" "$(id -nG labuser 2>/dev/null | tr ' ' '\n' | grep -qx sudo && echo yes || echo no)"
check "labpriv password locked" "L" "$(passwd -S labpriv 2>/dev/null | awk '{print $2}')"
check "adminlab in sudo group" "yes" "$(id -nG adminlab 2>/dev/null | tr ' ' '\n' | grep -qx sudo && echo yes || echo no)"
check "root login shell untouched" "/bin/bash" "$(getent passwd root | cut -d: -f7)"

# ---------------------------------------------------------------------------
# 3. Flags
# ---------------------------------------------------------------------------
say "Flags"
check "user flag exists" "yes" "$([[ -s /opt/vulnserver/flags/user.txt ]] && echo yes || echo no)"
check "privilege flag exists" "yes" "$([[ -s /opt/vulnserver/flags/privilege.txt ]] && echo yes || echo no)"
check "root flag exists" "yes" "$([[ -s /opt/vulnserver/flags/root.txt ]] && echo yes || echo no)"
check "user flag perms" "labuser:labuser 600" "$(stat -c '%U:%G %a' /opt/vulnserver/flags/user.txt)"
check "privilege flag perms" "root:labpriv 640" "$(stat -c '%U:%G %a' /opt/vulnserver/flags/privilege.txt)"
check "root flag perms" "root:root 400" "$(stat -c '%U:%G %a' /opt/vulnserver/flags/root.txt)"
check "flag format" "yes" "$(grep -Eq '^VS\{[A-Z]+-[0-9a-f]{32}\}$' /opt/vulnserver/flags/root.txt && echo yes || echo no)"

# ---------------------------------------------------------------------------
# 4. Negative controls (the lab must not be trivially wide open)
# ---------------------------------------------------------------------------
say "Negative controls"
check "labuser cannot read root.txt" "denied" \
    "$(runuser -u labuser -- cat /opt/vulnserver/flags/root.txt >/dev/null 2>&1 && echo allowed || echo denied)"
check "labuser cannot read privilege.txt" "denied" \
    "$(runuser -u labuser -- cat /opt/vulnserver/flags/privilege.txt >/dev/null 2>&1 && echo allowed || echo denied)"
check "labuser can read user.txt" "allowed" \
    "$(runuser -u labuser -- cat /opt/vulnserver/flags/user.txt >/dev/null 2>&1 && echo allowed || echo denied)"
check "labuser has no root sudo rights" "denied" \
    "$(runuser -u labuser -- sudo -n /bin/cat /opt/vulnserver/flags/root.txt >/dev/null 2>&1 && echo allowed || echo denied)"
check "labuser cannot write the log dir" "denied" \
    "$(runuser -u labuser -- touch /opt/vulnserver/logs/probe 2>/dev/null && echo allowed || echo denied)"
check "labuser cannot write flags dir" "denied" \
    "$(runuser -u labuser -- touch /opt/vulnserver/flags/probe 2>/dev/null && echo allowed || echo denied)"

# ---------------------------------------------------------------------------
# 5. Scenario A - insecure permissions
# ---------------------------------------------------------------------------
say "Scenario A"
./scripts/scenarios/scenario-a.sh activate >/tmp/sa.log 2>&1
check "scenario A activates" "0" "$?"
check "scenario A state" "active" "$(head -n1 /opt/vulnserver/state/scenario-a.state 2>/dev/null)"
check "find has SUID" "4755" "$(stat -c '%a' /usr/bin/find)"
check "restore point created" "yes" "$(ls -d /opt/vulnserver/backups/restore-a-* >/dev/null 2>&1 && echo yes || echo no)"

ROOT_FLAG_A="$(runuser -u labuser -- /usr/bin/find /tmp -maxdepth 0 \
    -exec /bin/sh -p -c 'cat /opt/vulnserver/flags/root.txt' \; 2>/dev/null | head -n1)"
check "scenario A: labuser -> root via SUID find" "$(cat /opt/vulnserver/flags/root.txt)" "$ROOT_FLAG_A"

./scripts/scenarios/scenario-a.sh deactivate >/tmp/sa.log 2>&1
check "scenario A SUID removed" "755" "$(stat -c '%a' /usr/bin/find)"
check "scenario A dir secured" "755" "$(stat -c '%a' /opt/vulnserver/lab/perms)"
check "scenario A state inactive" "inactive" "$(head -n1 /opt/vulnserver/state/scenario-a.state)"

# ---------------------------------------------------------------------------
# 6. Scenario B - insecure sudo (full two-stage chain)
# ---------------------------------------------------------------------------
say "Scenario B"
./scripts/scenarios/scenario-b.sh activate >/tmp/sb.log 2>&1
check "scenario B activates" "0" "$?"
check "scenario B sudoers file" "440" "$(stat -c '%a' /etc/sudoers.d/vulnserver-lab-b)"
check "scenario B helper mode" "774" "$(stat -c '%a' /usr/local/bin/lab-healthcheck)"

PRIV_FLAG="$(runuser -u labuser -- sudo -n -u labpriv /usr/bin/cat /opt/vulnserver/flags/privilege.txt 2>/dev/null)"
check "scenario B: labuser -> labpriv reads privilege flag" "$(cat /opt/vulnserver/flags/privilege.txt)" "$PRIV_FLAG"

# Stage 2: labpriv replaces the root-executed helper and gets root.txt copied
runuser -u labpriv -- bash -c \
    'printf "#!/bin/bash\ncat /opt/vulnserver/flags/root.txt > /tmp/vs_root_proof\nchmod 644 /tmp/vs_root_proof\n" > /usr/local/bin/lab-healthcheck' 2>/dev/null
runuser -u labpriv -- sudo -n /usr/local/bin/lab-healthcheck >/dev/null 2>&1
check "scenario B: labpriv -> root via writable helper" "$(cat /opt/vulnserver/flags/root.txt)" "$(cat /tmp/vs_root_proof 2>/dev/null)"
check "scenario B proof owned by root" "root" "$(stat -c '%U' /tmp/vs_root_proof 2>/dev/null)"

./scripts/scenarios/scenario-b.sh deactivate >/tmp/sb.log 2>&1
check "scenario B sudoers removed" "no" "$([[ -e /etc/sudoers.d/vulnserver-lab-b ]] && echo yes || echo no)"
check "scenario B helper secured" "root:root 755" "$(stat -c '%U:%G %a' /usr/local/bin/lab-healthcheck)"
check "scenario B no longer escalates" "denied" \
    "$(runuser -u labuser -- sudo -n -u labpriv /usr/bin/cat /etc/shadow >/dev/null 2>&1 && echo allowed || echo denied)"

# ---------------------------------------------------------------------------
# 7. Scenario C - insecure cron
# ---------------------------------------------------------------------------
say "Scenario C"
./scripts/scenarios/scenario-c.sh activate >/tmp/sc.log 2>&1
check "scenario C activates" "0" "$?"
check "scenario C cron drop-in" "yes" "$([[ -f /etc/cron.d/vulnserver-lab-c ]] && echo yes || echo no)"
check "scenario C dir world-writable" "777" "$(stat -c '%a' /opt/vulnserver/lab/cron)"

# Exploit: replace the script that root runs (rename attack)
runuser -u labuser -- bash -c \
    'mv /opt/vulnserver/lab/cron/lab-cleanup.sh /opt/vulnserver/lab/cron/lab-cleanup.sh.orig 2>/dev/null; printf "#!/bin/bash\nid -u > /tmp/vs_cron_uid\ncat /opt/vulnserver/flags/root.txt > /tmp/vs_cron_root\n" > /opt/vulnserver/lab/cron/lab-cleanup.sh; chmod 755 /opt/vulnserver/lab/cron/lab-cleanup.sh' 2>/dev/null
check "scenario C: labuser replaced root script" "yes" "$([[ -f /opt/vulnserver/lab/cron/lab-cleanup.sh ]] && echo yes || echo no)"

if [[ "${RUN_CRON_TEST:-0}" == "1" ]]; then
    say "Scenario C: waiting for cron (up to 90s)"
    for _ in $(seq 1 45); do [[ -f /tmp/vs_cron_root ]] && break; sleep 2; done
    check "scenario C: cron executed attacker script as root" "0" "$(cat /tmp/vs_cron_uid 2>/dev/null)"
    check "scenario C: root flag copied by cron" "$(cat /opt/vulnserver/flags/root.txt)" "$(cat /tmp/vs_cron_root 2>/dev/null)"
else
    pass "scenario C: cron execution" "skipped (RUN_CRON_TEST=0)"
fi

./scripts/scenarios/scenario-c.sh deactivate >/tmp/sc.log 2>&1
check "scenario C cron removed" "no" "$([[ -e /etc/cron.d/vulnserver-lab-c ]] && echo yes || echo no)"
check "scenario C dir secured" "755" "$(stat -c '%a' /opt/vulnserver/lab/cron)"

# ---------------------------------------------------------------------------
# 8. Audit (read-only) and report
# ---------------------------------------------------------------------------
say "Audit and report"
BEFORE_AUDIT="$(find /etc/sudoers.d /opt/vulnserver/flags -type f -exec md5sum {} + 2>/dev/null | sort)"
if ./audit.sh --stdout >/tmp/audit-before.md 2>/dev/null; then
    pass "audit.sh runs" "exit 0"
else
    fail "audit.sh runs" "non-zero exit"
fi
AFTER_AUDIT="$(find /etc/sudoers.d /opt/vulnserver/flags -type f -exec md5sum {} + 2>/dev/null | sort)"
check "audit.sh is read-only" "unchanged" "$([[ "$BEFORE_AUDIT" == "$AFTER_AUDIT" ]] && echo unchanged || echo modified)"
check "audit report contains a result summary" "yes" "$(grep -q 'Result:' /tmp/audit-before.md && echo yes || echo no)"
check "audit detects missing ufw" "yes" "$(grep -qi 'UFW' /tmp/audit-before.md && echo yes || echo no)"
check "audit validates flag permissions" "yes" "$(grep -q 'Flag root.txt permissions' /tmp/audit-before.md && echo yes || echo no)"

if ./scripts/monitoring/report.sh --stdout >/tmp/report.md 2>/dev/null; then
    pass "report.sh runs" "stdout mode"
else
    fail "report.sh runs" "non-zero exit"
fi
check "report lists scenario events" "yes" "$(grep -q 'SCENARIO_ACTIVATE' /tmp/report.md && echo yes || echo no)"
check "event log is JSON lines" "yes" "$(head -n1 /opt/vulnserver/logs/events.log | jq -e . >/dev/null 2>&1 && echo yes || echo no)"
check "event log records the actor" "yes" "$(jq -r .actor /opt/vulnserver/logs/events.log 2>/dev/null | grep -q . && echo yes || echo no)"

# ---------------------------------------------------------------------------
# 9. Hardening
# ---------------------------------------------------------------------------
say "Hardening (re-activate scenarios first, then harden)"
./scripts/scenarios/scenario-a.sh activate >/dev/null 2>&1
./scripts/scenarios/scenario-b.sh activate >/dev/null 2>&1
./scripts/scenarios/scenario-c.sh activate >/dev/null 2>&1
./harden.sh --apply --yes --only permissions,sudo,suid,cron >/tmp/harden.log 2>&1
check "harden.sh exit status" "0" "$?"
check "harden removed SUID" "755" "$(stat -c '%a' /usr/bin/find)"
check "harden removed scenario sudoers" "no" "$([[ -e /etc/sudoers.d/vulnserver-lab-b ]] && echo yes || echo no)"
check "harden removed scenario cron" "no" "$([[ -e /etc/cron.d/vulnserver-lab-c ]] && echo yes || echo no)"
check "harden secured cron dir" "755" "$(stat -c '%a' /opt/vulnserver/lab/cron)"
check "harden secured helper" "root:root 755" "$(stat -c '%U:%G %a' /usr/local/bin/lab-healthcheck)"
check "harden created a backup" "yes" "$(ls -d /opt/vulnserver/backups/files-* >/dev/null 2>&1 && echo yes || echo no)"
check "hardening closes the SUID path" "denied" \
    "$(runuser -u labuser -- /usr/bin/find /tmp -maxdepth 0 -exec /bin/sh -p -c 'id -u' \; 2>/dev/null | grep -qx 0 && echo allowed || echo denied)"

./audit.sh --stdout >/tmp/audit-after.md 2>/dev/null
check "post-hardening audit runs" "0" "$?"
grep -i 'Unexpected SUID' /tmp/audit-after.md | head -n3
check "post-hardening: no unexpected SUID binary" "yes" \
    "$(grep -q 'No unexpected SUID binaries' /tmp/audit-after.md && echo yes || echo no)"

# ---------------------------------------------------------------------------
# 10. Reset
# ---------------------------------------------------------------------------
say "Reset"
OLD_USER_FLAG="$(cat /opt/vulnserver/flags/user.txt)"
OLD_ROOT_FLAG="$(cat /opt/vulnserver/flags/root.txt)"
if ./reset-lab.sh --yes --no-restart >/tmp/reset.log 2>&1; then
    pass "reset-lab.sh exit status" "0"
else
    fail "reset-lab.sh exit status" "non-zero"
    tail -n 20 /tmp/reset.log
fi
check "reset rotated the user flag" "changed" "$([[ "$OLD_USER_FLAG" != "$(cat /opt/vulnserver/flags/user.txt)" ]] && echo changed || echo same)"
check "reset rotated the root flag" "changed" "$([[ "$OLD_ROOT_FLAG" != "$(cat /opt/vulnserver/flags/root.txt)" ]] && echo changed || echo same)"
check "reset deactivated all scenarios" "inactive inactive inactive" \
    "$(for i in a b c; do head -n1 /opt/vulnserver/state/scenario-$i.state 2>/dev/null || echo inactive; done | tr '\n' ' ' | sed 's/ $//')"
check "reset preserved administrative backups" "yes" "$(ls /opt/vulnserver/backups >/dev/null 2>&1 && echo yes || echo no)"
PRACTICE_LEFTOVER="$(ls -A /home/labuser 2>/dev/null | grep -vE '^\.(bashrc|profile|bash_logout)$' | tr '\n' ' ' | sed 's/ $//')"
check "reset removed practice data" "none" "${PRACTICE_LEFTOVER:-none}"

# ---------------------------------------------------------------------------
# 11. Manager interface
# ---------------------------------------------------------------------------
say "lab-manager"
if ./lab-manager.sh status >/tmp/status.log 2>&1; then
    pass "lab-manager.sh status" "exit 0"
else
    fail "lab-manager.sh status" "non-zero exit"
fi
check "status shows the three scenarios" "yes" \
    "$([[ $(grep -cE '^  [ABC] +(ACTIVE|inactive)' /tmp/status.log) -eq 3 ]] && echo yes || echo no)"

# ---------------------------------------------------------------------------
# 12. Uninstall
# ---------------------------------------------------------------------------
say "Uninstall (purge)"
if ./uninstall.sh --yes --purge >/tmp/uninstall.log 2>&1; then
    pass "uninstall.sh exit status" "0"
else
    fail "uninstall.sh exit status" "non-zero"
    tail -n 20 /tmp/uninstall.log
fi
check "uninstall removed state dir" "no" "$([[ -d /opt/vulnserver ]] && echo yes || echo no)"
check "uninstall removed sudoers files" "0" "$(ls /etc/sudoers.d/vulnserver-* 2>/dev/null | wc -l)"
check "uninstall removed cron drop-in" "no" "$([[ -e /etc/cron.d/vulnserver-lab-c ]] && echo yes || echo no)"
check "uninstall kept adminlab" "yes" "$(id adminlab >/dev/null 2>&1 && echo yes || echo no)"

printf '\nSUMMARY|PASS=%d|FAIL=%d\n' "$PASS" "$FAIL"
(( FAIL == 0 )) && exit 0 || exit 1
