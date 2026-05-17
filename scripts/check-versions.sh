#!/usr/bin/env bash
# =====================================================================
#  check-versions.sh — Compare upstream versions vs current image
#  Returns exit 0 if rebuild needed, exit 1 if up-to-date.
#  Outputs VERSION_FILE with resolved versions for CI consumption.
# =====================================================================
set -euo pipefail

VERSION_FILE="${1:-/tmp/versions.env}"

echo "==> Checking upstream versions..."

# --- Fetch latest stable Nginx ---
NGINX_LATEST=$(curl -fsSL https://nginx.org/en/download.html \
  | grep -oP 'nginx-\K[0-9]+\.[0-9]+\.[0-9]+' | head -1)
echo "Nginx latest: ${NGINX_LATEST}"

# --- Fetch latest ModSecurity ---
MODSEC_LATEST=$(curl -fsSL https://api.github.com/repos/owasp-modsecurity/ModSecurity/releases/latest \
  | grep -o '"tag_name": *"[^"]*"' | sed 's/.*"v\?\([^"]*\)"/\1/')
echo "ModSecurity latest: ${MODSEC_LATEST}"

# --- Fetch latest OWASP CRS ---
CRS_LATEST=$(curl -fsSL https://api.github.com/repos/coreruleset/coreruleset/releases/latest \
  | grep -o '"tag_name": *"[^"]*"' | sed 's/.*"v\?\([^"]*\)"/\1/')
echo "OWASP CRS latest: ${CRS_LATEST}"

# --- Read current versions from image labels (if image exists) ---
REGISTRY="${REGISTRY:-ghcr.io}"
IMAGE="${IMAGE:-jbsky/nginx-waf-hardened}"
CURRENT_TAG="${CURRENT_TAG:-latest}"

REBUILD_NEEDED=false

# Try to get current image labels
if LABELS=$(docker inspect --format='{{index .Config.Labels "versions"}}' "${REGISTRY}/${IMAGE}:${CURRENT_TAG}" 2>/dev/null) \
   || LABELS=$(curl -fsSL "https://${REGISTRY}/v2/${IMAGE}/manifests/${CURRENT_TAG}" 2>/dev/null | grep -o '"versions":"[^"]*"' | cut -d'"' -f4); then
  CURRENT_NGINX=$(echo "$LABELS" | grep -oP 'nginx=\K[0-9.]+' || echo "unknown")
  CURRENT_MODSEC=$(echo "$LABELS" | grep -oP 'modsec=\K[0-9.]+' || echo "unknown")
  CURRENT_CRS=$(echo "$LABELS" | grep -oP 'crs=\K[0-9.]+' || echo "unknown")

  echo "Current image: nginx=${CURRENT_NGINX} modsec=${CURRENT_MODSEC} crs=${CURRENT_CRS}"

  if [ "$NGINX_LATEST" != "$CURRENT_NGINX" ]; then
    echo "  => Nginx update: ${CURRENT_NGINX} -> ${NGINX_LATEST}"
    REBUILD_NEEDED=true
  fi
  if [ "$MODSEC_LATEST" != "$CURRENT_MODSEC" ]; then
    echo "  => ModSecurity update: ${CURRENT_MODSEC} -> ${MODSEC_LATEST}"
    REBUILD_NEEDED=true
  fi
  if [ "$CRS_LATEST" != "$CURRENT_CRS" ]; then
    echo "  => OWASP CRS update: ${CURRENT_CRS} -> ${CRS_LATEST}"
    REBUILD_NEEDED=true
  fi
else
  echo "  => No current image found, rebuild needed"
  REBUILD_NEEDED=true
fi

# Write version file for downstream consumption
cat > "$VERSION_FILE" <<EOF
NGINX_VER=${NGINX_LATEST}
MODSEC_VER=${MODSEC_LATEST}
OWASP_CRS_VER=${CRS_LATEST}
REBUILD_NEEDED=${REBUILD_NEEDED}
EOF

echo ""
echo "==> Versions written to ${VERSION_FILE}"
echo "==> Rebuild needed: ${REBUILD_NEEDED}"

if [ "$REBUILD_NEEDED" = "true" ]; then
  exit 0
else
  exit 1
fi
