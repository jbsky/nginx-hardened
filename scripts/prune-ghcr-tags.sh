#!/usr/bin/env bash
# Prunes old immutable version tags + auto-* snapshot tags on GHCR, mirroring
# prune-registry-tags.sh for Docker Hub. Only ever deletes a package version
# by its OWN tag reference -- untagged versions (manifest-list children,
# sbom/provenance attestations, cosign signatures) are left alone, since
# deleting those independently of their parent risks breaking a still-live
# tagged manifest.
set -euo pipefail

OWNER="${1:?usage: prune-ghcr-tags.sh <owner> <package> [keep_count]}"
PACKAGE="${2:?usage: prune-ghcr-tags.sh <owner> <package> [keep_count]}"
KEEP_COUNT="${3:-3}"

# Packages that have accumulated many untagged versions (SBOM/provenance
# attestations, cosign signatures, old manifest-list children -- never
# pruned, since deleting them independently of their parent tag risks
# breaking a still-live manifest reference) make this paginated listing
# deep enough that GHCR intermittently 502s partway through. Confirmed on
# c-icap-hardened (196 versions, 193 untagged): retrying the whole listing
# a few times clears it, no different than a human re-running the workflow.
for attempt in 1 2 3 4 5; do
  if VERSIONS_JSON=$(gh api "/users/${OWNER}/packages/container/${PACKAGE}/versions" --paginate 2>&1); then
    break
  fi
  if [ "$attempt" -eq 5 ]; then
    echo "$VERSIONS_JSON" >&2
    exit 1
  fi
  echo "Listing versions failed (attempt ${attempt}/5), retrying in $((attempt * 5))s..." >&2
  sleep "$((attempt * 5))"
done

# id + first tag, newest first (API default order), tagged versions only.
mapfile -t TAGGED < <(echo "$VERSIONS_JSON" \
  | jq -r '.[] | select(.metadata.container.tags | length > 0) | "\(.id)\t\(.metadata.container.tags[0])"')

DELETE_IDS=()
SEMVER_SEEN=0
for entry in "${TAGGED[@]}"; do
  id="${entry%%$'\t'*}"
  tag="${entry##*$'\t'}"

  if [ "$tag" = "latest" ]; then
    continue
  fi

  # Matches both X.Y (e.g. squid's 7.6) and X.Y.Z (e.g. nginx's 1.30.4).
  if [[ "$tag" =~ ^[0-9]+(\.[0-9]+){1,2}$ ]]; then
    SEMVER_SEEN=$((SEMVER_SEEN + 1))
    if [ "$SEMVER_SEEN" -gt "$KEEP_COUNT" ]; then
      DELETE_IDS+=("$id")
    fi
  else
    # auto-* snapshots and legacy short-sha tags: already preserved via git
    # tags/GitHub Releases, never meant for pinning, always safe to prune.
    DELETE_IDS+=("$id")
  fi
done

if [ "${#DELETE_IDS[@]}" -eq 0 ]; then
  echo "Nothing to prune."
  exit 0
fi

for id in "${DELETE_IDS[@]}"; do
  echo "Deleting ghcr.io/${OWNER}/${PACKAGE} version id ${id}"
  # A concurrent run (e.g. several dependabot PRs merged close together, each
  # triggering its own build+cleanup) may have already deleted this exact
  # version -- a 404 here means the goal state is already reached, not a
  # real failure. Any other error still aborts the script.
  if ! output=$(gh api --method DELETE "/users/${OWNER}/packages/container/${PACKAGE}/versions/${id}" 2>&1); then
    if echo "$output" | grep -q '"status":"404"'; then
      echo "  (already deleted by a concurrent run, skipping)"
    else
      echo "$output" >&2
      exit 1
    fi
  fi
done
