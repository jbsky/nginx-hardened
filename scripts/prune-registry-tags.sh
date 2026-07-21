#!/usr/bin/env bash
# Prunes old immutable version tags + auto-* snapshot tags on Docker Hub,
# keeping only the last KEEP_COUNT semver tags plus :latest. Old semver tags
# point at genuinely outdated (and eventually vulnerable) nginx builds that
# never get deleted otherwise, since every build pushes a brand new
# immutable version tag without ever retiring the previous one.
#
# GHCR pruning is handled separately by actions/delete-package-versions in
# the workflow, since GHCR's package API doesn't fit a portable curl+jq
# script as cleanly as Docker Hub's REST API does.
set -euo pipefail

DOCKERHUB_USERNAME="${1:?usage: prune-registry-tags.sh <dockerhub_username> <repo> [keep_count]}"
REPO="${2:?usage: prune-registry-tags.sh <dockerhub_username> <repo> [keep_count]}"
KEEP_COUNT="${3:-3}"
DOCKERHUB_PASSWORD="${DOCKERHUB_TOKEN:?DOCKERHUB_TOKEN env var required}"

TOKEN=$(curl -fsSL -X POST "https://hub.docker.com/v2/users/login/" \
  -H "Content-Type: application/json" \
  -d "{\"username\":\"${DOCKERHUB_USERNAME}\",\"password\":\"${DOCKERHUB_PASSWORD}\"}" \
  | jq -r '.token')

TAGS_JSON=$(curl -fsSL -H "Authorization: Bearer ${TOKEN}" \
  "https://hub.docker.com/v2/repositories/${DOCKERHUB_USERNAME}/${REPO}/tags?page_size=100")

mapfile -t SEMVER_TAGS < <(echo "$TAGS_JSON" | jq -r '.results[].name' \
  | grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' \
  | sort -t. -k1,1n -k2,2n -k3,3n -r)

DELETE_SEMVER=("${SEMVER_TAGS[@]:${KEEP_COUNT}}")

# auto-* (and any other non-semver, non-latest) tags are point-in-time
# snapshots already preserved via git tags + GitHub Releases -- never meant
# for pinning, always safe to prune.
mapfile -t AUTO_TAGS < <(echo "$TAGS_JSON" | jq -r '.results[].name' \
  | grep -vE '^[0-9]+\.[0-9]+\.[0-9]+$' | grep -v '^latest$' || true)

DELETE_TAGS=("${DELETE_SEMVER[@]}" "${AUTO_TAGS[@]}")

if [ "${#DELETE_TAGS[@]}" -eq 0 ]; then
  echo "Nothing to prune."
  exit 0
fi

for tag in "${DELETE_TAGS[@]}"; do
  echo "Deleting docker.io/${DOCKERHUB_USERNAME}/${REPO}:${tag}"
  curl -fsSL -X DELETE -H "Authorization: Bearer ${TOKEN}" \
    "https://hub.docker.com/v2/repositories/${DOCKERHUB_USERNAME}/${REPO}/tags/${tag}/"
done

echo "Kept: ${SEMVER_TAGS[*]:0:${KEEP_COUNT}} latest"
