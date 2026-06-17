#!/usr/bin/env bash
# =====================================================================
#  deploy.sh — build / scan / sbom helper
# =====================================================================
set -euo pipefail

IMAGE="nginx-waf-hardened"

case "${1:-build}" in
  build)
    echo "==> Building ${IMAGE}"
    docker compose build --pull
    ;;
  scan)
    echo "==> Trivy scan ${IMAGE}"
    docker run --rm \
      -v /var/run/docker.sock:/var/run/docker.sock \
      aquasec/trivy:latest image \
      --severity HIGH,CRITICAL --ignore-unfixed \
      "docker.io/jbsky/${IMAGE}:latest"
    ;;
  sbom)
    echo "==> SBOM generation (syft)"
    mkdir -p sbom
    docker run --rm \
      -v /var/run/docker.sock:/var/run/docker.sock \
      anchore/syft:latest \
      "docker.io/jbsky/${IMAGE}:latest" -o spdx-json > sbom/${IMAGE}.spdx.json
    echo "SBOM saved to sbom/${IMAGE}.spdx.json"
    ;;
  *)
    echo "Usage: $0 {build|scan|sbom}"
    exit 1
    ;;
esac
