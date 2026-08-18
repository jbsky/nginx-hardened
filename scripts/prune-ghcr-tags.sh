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

# GHCR groups every tag pointing at the same digest into ONE version object.
# A single build push (latest + <version> + auto-YYYYMMDD.N, all one digest)
# lands as one version carrying all three tags; a cosign signature or SLSA
# attestation lands as its own version carrying just its own "sha256-..."
# tag. Any classification that looks at only one tag per version (e.g.
# tags[0]) can misclassify the whole version -- confirmed live: nginx-waf-
# hardened's GHCR "latest" was wiped entirely because the version's first
# listed tag happened to be that run's auto-* tag, and every repo's cosign
# signature was deleted every single build because "sha256-...sig"/".att"
# tags matched no protected pattern. Fix: inspect the FULL tag set of a
# version and protect it if ANY tag on it deserves protection.
# {1,3} also matches the revisioned tags (7.6.13, 1.30.4.2); anything not
# matched here is treated as a disposable snapshot and deleted.
mapfile -t ALL_SEMVER < <(echo "$VERSIONS_JSON" \
  | jq -r '.[].metadata.container.tags[]?' \
  | grep -E '^[0-9]+(\.[0-9]+){1,3}$' \
  | sort -t. -k1,1nr -k2,2nr -k3,3nr -k4,4nr)

declare -A KEEP_SEMVER=()
for tag in "${ALL_SEMVER[@]:0:${KEEP_COUNT}}"; do
  KEEP_SEMVER["$tag"]=1
done

# The short tag (7.6) floats to the newest revision (7.6.13) but sorts below
# every one of them, so keeping only the newest KEEP_COUNT would delete the
# tag deployments actually pin. Keep any tag that is a dot-prefix of a kept one.
for tag in "${ALL_SEMVER[@]:${KEEP_COUNT}}"; do
  for kept in "${!KEEP_SEMVER[@]}"; do
    case "$kept" in "${tag}."*) KEEP_SEMVER["$tag"]=1; break ;; esac
  done
done

mapfile -t TAGGED < <(echo "$VERSIONS_JSON" \
  | jq -r '.[] | select(.metadata.container.tags | length > 0) | "\(.id)\t" + (.metadata.container.tags | join(","))')

DELETE_IDS=()
for entry in "${TAGGED[@]}"; do
  id="${entry%%$'\t'*}"
  tags_csv="${entry#*$'\t'}"
  IFS=',' read -ra tags <<< "$tags_csv"

  protect=false
  for tag in "${tags[@]}"; do
    if [ "$tag" = "latest" ]; then
      protect=true
      break
    fi
    # Cosign signatures/attestations/SBOMs, tagged "sha256-<digest>.<suffix>"
    # -- a digest-derived reference, never meant to be human-pinned, and
    # load-bearing for whatever manifest it signs. Match on prefix alone
    # rather than an enumerated suffix list (.sig/.att/.sbom today, but the
    # convention isn't a contract).
    if [[ "$tag" == sha256-* ]]; then
      protect=true
      break
    fi
    if [ -n "${KEEP_SEMVER[$tag]+x}" ]; then
      protect=true
      break
    fi
  done

  if [ "$protect" = false ]; then
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
