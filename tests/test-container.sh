#!/usr/bin/env bash
# =============================================================================
# VulnServer - tests/test-container.sh
# Runs the full functional test suite inside a disposable Ubuntu 24.04
# container and writes a Markdown matrix to reports/.
#
#   ./tests/test-container.sh                 # standard run
#   RUN_CRON_TEST=1 ./tests/test-container.sh # also wait for a real cron run
#
# Requirements on the machine running this: docker (daemon reachable) and
# network access to Docker Hub / Ubuntu archives.
# =============================================================================
set -euo pipefail
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IMAGE="${TEST_IMAGE:-ubuntu:24.04}"
CONTAINER_NAME="vulnserver-test-$$"
OUT_DIR="${REPO_DIR}/reports"
STAMP="$(date +%Y%m%d-%H%M%S)"

command -v docker >/dev/null 2>&1 || { echo "docker is required" >&2; exit 1; }
docker info >/dev/null 2>&1 || { echo "docker daemon unreachable" >&2; exit 1; }

mkdir -p "$OUT_DIR" "$REPO_DIR/logs"

echo "[*] Starting test container from ${IMAGE}"
docker run --rm --name "$CONTAINER_NAME" \
    -e RUN_CRON_TEST="${RUN_CRON_TEST:-0}" \
    -e SRC=/src \
    -v "${REPO_DIR}:/src:rw" \
    -w /src \
    "$IMAGE" bash /src/tests/container-runner.sh 2>&1 | tee "${OUT_DIR}/test-run-${STAMP}.log"

STATUS=${PIPESTATUS[0]}

# ---------------------------------------------------------------------------
# Build the Markdown matrix
# ---------------------------------------------------------------------------
LOG_FILE="${OUT_DIR}/test-run-${STAMP}.log"
PASS_COUNT="$(grep -c '^RESULT|PASS|' "$LOG_FILE" || true)"
FAIL_COUNT="$(grep -c '^RESULT|FAIL|' "$LOG_FILE" || true)"
TOTAL=$((PASS_COUNT + FAIL_COUNT))

{
    printf '# VulnServer - functional test matrix\n\n'
    printf -- '- Date: %s\n' "$(date +'%Y-%m-%d %H:%M:%S')"
    printf -- '- Environment: Docker `%s` (Ubuntu Server 24.04 LTS userland)\n' "$IMAGE"
    printf -- '- Profile: `install.sh --profile container --yes`\n'
    if [[ "${RUN_CRON_TEST:-0}" == "1" ]]; then
        printf -- '- Real cron execution test: **enabled**\n'
    else
        printf -- '- Real cron execution test: disabled (set `RUN_CRON_TEST=1`)\n'
    fi
    printf -- '- Result: **%s/%s PASS**, **%s FAIL**\n\n' "$PASS_COUNT" "$TOTAL" "$FAIL_COUNT"
    printf '| # | Test | Result | Detail |\n|---|---|---|---|\n'
    # Log lines look like: RESULT|PASS|<name>|<detail>
    grep -E '^RESULT\|' "$LOG_FILE" |
        awk -F'|' '{printf "| %d | %s | %s | %s |\n", NR, $3, $2, $4}'
    printf '\n'
    if (( FAIL_COUNT > 0 )); then
        printf '## Failures\n\n'
        grep '^RESULT|FAIL|' "$LOG_FILE" | awk -F'|' '{printf "- **%s**: %s\n", $3, $4}'
        printf '\n'
    fi
    printf '## Raw output\n\nSee `reports/test-run-%s.log`.\n' "$STAMP"
} > "${OUT_DIR}/test-matrix-${STAMP}.md"

echo
echo "[*] Matrix written to reports/test-matrix-${STAMP}.md"
echo "[*] PASS=${PASS_COUNT} FAIL=${FAIL_COUNT} (exit status of the run: ${STATUS})"
exit "$STATUS"
