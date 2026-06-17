#!/usr/bin/env bash
# =====================================================================
#  test.sh — Smoke tests pour nginx-waf-hardened
# =====================================================================
set -euo pipefail

HOST="${1:-127.0.0.1}"
PORT="${2:-80}"
BASE="http://${HOST}:${PORT}"
PASS=0
FAIL=0

check() {
  local desc="$1" url="$2" expected_code="$3"
  local code
  code=$(curl -so /dev/null -w '%{http_code}' --max-time 5 "$url" 2>/dev/null || echo "000")
  if [ "$code" = "$expected_code" ]; then
    echo "  [PASS] ${desc} → ${code}"
    PASS=$((PASS + 1))
  else
    echo "  [FAIL] ${desc} → ${code} (expected ${expected_code})"
    FAIL=$((FAIL + 1))
  fi
}

echo "=== Nginx WAF Hardened — Smoke Tests ==="
echo "Target: ${BASE}"
echo ""

# Healthcheck
check "Healthcheck /healthz" "${BASE}/healthz" "200"

# Normal page (should work or 404 if no content)
check "Root /" "${BASE}/" "200"

# Blocked files
check "Block .env" "${BASE}/.env" "403"
check "Block .git" "${BASE}/.git/config" "403"
check "Block .sql" "${BASE}/dump.sql" "403"

# Block bad methods
check "TRACE blocked" "-X TRACE ${BASE}/" "405"

# ModSec: SQL injection attempt
check "ModSec SQLi block" "${BASE}/?id=1%20OR%201=1--" "403"

# ModSec: XSS attempt
check "ModSec XSS block" "${BASE}/?q=<script>alert(1)</script>" "403"

# WordPress scan blocked
check "Block wp-login" "${BASE}/wp-login.php" "403"

echo ""
echo "=== Results: ${PASS} passed, ${FAIL} failed ==="
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
