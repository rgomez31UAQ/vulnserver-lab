#!/usr/bin/env bash
# =============================================================================
# tests/test-cloud.sh
#
# Tests the cloud tooling without credentials and without creating anything:
#   * cloud-init rendering (size limit, placeholders, bad input)
#   * provision.sh create/destroy against a local Hetzner/Vultr mock
#   * dry-run performs no API call
#
# The real provider APIs are NOT exercised here (no tokens); see
# docs/TEST_REPORT.md for what that leaves unverified.
# =============================================================================
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
PORT=$(( 18200 + RANDOM % 300 ))
LOG="${TMP}/requests.log"
MOCK_PID=""
PASS=0
FAIL=0

cleanup() {
    [[ -n "$MOCK_PID" ]] && kill "$MOCK_PID" 2>/dev/null || true
    rm -rf "$TMP"
}
trap cleanup EXIT

check() { # description, command...
    local desc="$1"; shift
    if "$@" >/dev/null 2>&1; then
        printf '[+] %s\n' "$desc"; PASS=$((PASS + 1))
    else
        printf '[x] %s\n' "$desc"; FAIL=$((FAIL + 1))
    fi
}

grep_log() { grep -q -- "$1" "$LOG"; }

echo "== cloud-init =="
UD="${TMP}/user-data.yaml"
check "renders user-data" \
    "$ROOT/scripts/cloud/make-cloud-init.sh" \
    --repo-url "https://github.com/example/lab/archive/refs/heads/main.tar.gz" \
    --peer owner --out "$UD"
check "has cloud-config header" grep -qx '#cloud-config' "$UD"
check "repo URL substituted" grep -q 'github.com/example/lab' "$UD"
check "no placeholders left" bash -c "! grep -q '__[A-Z_]*__' '$UD'"
check "under 32 KiB" test "$(wc -c < "$UD")" -le 32768
check "rejects http://" bash -c "! '$ROOT/scripts/cloud/make-cloud-init.sh' --repo-url http://x/y.tar.gz --out '$TMP/no.yaml'"
check "rejects unsafe shell chars" bash -c "! '$ROOT/scripts/cloud/make-cloud-init.sh' --repo-url 'https://x/y\$(id).tar.gz' --out '$TMP/no2.yaml'"

echo "== provision (mock API) =="
command -v jq >/dev/null || { echo "jq required"; exit 1; }
ssh-keygen -q -t ed25519 -N '' -f "${TMP}/key"
export HCLOUD_TOKEN=test VULTR_API_KEY=test
export VULNSERVER_PROVISION_DIR="${TMP}/state" VULNSERVER_CLIENT_DIR="${TMP}/clients"

python3 "$ROOT/tests/mock-cloud-api.py" "$LOG" "$PORT" &
MOCK_PID=$!
for _ in $(seq 1 30); do
    curl -fsS "http://127.0.0.1:${PORT}/v1/images" >/dev/null 2>&1 && break
    sleep 0.2
done

base="http://127.0.0.1:${PORT}"

# Dry run must not touch the API.
before="$(wc -l < "$LOG")"
"$ROOT/scripts/cloud/provision.sh" --provider hetzner --name dry-run --dry-run \
    --api-base "${base}/v1" --ssh-key "${TMP}/key.pub" >/dev/null
check "dry-run sends no request" test "$(wc -l < "$LOG")" -eq "$before"

# Hetzner
check "hetzner create" \
    "$ROOT/scripts/cloud/provision.sh" --provider hetzner --name t-hetz \
    --api-base "${base}/v1" --no-bootstrap --yes \
    --ssh-key "${TMP}/key.pub" --admin-cidr 203.0.113.9/32
check "hetzner state written" grep -q '^SERVER_ID=31' "${TMP}/state/hetzner-t-hetz.env"
check "hetzner state has IP" grep -q '^PUBLIC_IP=203.0.113.50' "${TMP}/state/hetzner-t-hetz.env"
check "hetzner firewall: udp 51820 open" grep_log '"port": "51820"'
check "hetzner firewall: ssh only from operator" grep_log '"203.0.113.9/32"'
check "hetzner server: key + firewall attached" grep_log '"ssh_keys": \[11\], "firewalls": \[{"firewall": 21}\]'

# Vultr
check "vultr create" \
    "$ROOT/scripts/cloud/provision.sh" --provider vultr --name t-vultr \
    --api-base "${base}/v2" --no-bootstrap --yes \
    --ssh-key "${TMP}/key.pub" --admin-cidr 203.0.113.9/32
check "vultr instance body" grep_log '"sshkey_id": \["k1"\], "firewall_group_id": "g1"'
check "vultr image is 24.04" grep_log '"os_id": 2284'

# Destroy both
check "hetzner destroy" \
    "$ROOT/scripts/cloud/provision.sh" --provider hetzner --name t-hetz --destroy --yes \
    --api-base "${base}/v1"
check "hetzner state removed" test ! -e "${TMP}/state/hetzner-t-hetz.env"
check "hetzner server+firewall deleted" test "$(grep -c 'DELETE' "$LOG")" -ge 2

# The first two DELETEs belong to Hetzner; afterwards the counter only grows.
deletes_before="$(grep -c 'DELETE' "$LOG")"
check "vultr destroy" \
    "$ROOT/scripts/cloud/provision.sh" --provider vultr --name t-vultr --destroy --yes \
    --api-base "${base}/v2"
check "vultr state removed" test ! -e "${TMP}/state/vultr-t-vultr.env"
check "vultr deletes issued" test "$(( $(grep -c 'DELETE' "$LOG") - deletes_before ))" -eq 2

echo
printf '== %d passed, %d failed ==\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
