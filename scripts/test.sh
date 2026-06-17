#!/usr/bin/env bash
# =====================================================================
#  test.sh — Smoke tests pour nginx-waf-hardened
# =====================================================================
set -euo pipefail

HOST="${1:-127.0.0.1}"
PORT="${2:-80}"
BASE="http://${HOST}:${PORT}"
CURL_OPTS=(-so /dev/null -w '%{http_code}' --max-time 5 -H "Host: localhost")
PASS=0
FAIL=0

check() {
  local desc="$1" expected_code="$2"
  shift 2
  local code
  code=$(curl "${CURL_OPTS[@]}" "$@" 2>/dev/null || echo "000")
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
check "Healthcheck /healthz" "200" "${BASE}/healthz"

# Normal page (403 expected: no content mounted in /var/www/html)
check "Root / (no content = 403)" "403" "${BASE}/"

# Blocked files
check "Block .env" "403" "${BASE}/.env"
check "Block .git" "403" "${BASE}/.git/config"
check "Block .sql" "403" "${BASE}/dump.sql"

# Block bad methods
check "TRACE blocked" "405" -X TRACE "${BASE}/"

# ModSec: SQL injection attempt
check "ModSec SQLi block" "403" "${BASE}/?id=1%20OR%201=1--"

# ModSec: XSS attempt
check "ModSec XSS block" "403" "${BASE}/?q=<script>alert(1)</script>"

# WordPress scan blocked
check "Block wp-login" "403" "${BASE}/wp-login.php"

echo ""
echo "=== Results: ${PASS} passed, ${FAIL} failed ==="
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
