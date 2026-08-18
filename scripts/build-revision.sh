#!/usr/bin/env bash
# =====================================================================
#  build-revision.sh -- how many commits have touched this image's build
#  inputs since its upstream version last changed.
#
#  The upstream version alone is not a unique tag: rebuilding on a new Alpine,
#  or after a Dockerfile change, overwrites :<version> in place and the build
#  it replaced becomes unreachable -- there is no way to name "the 7.6 that
#  ran on alpine 3.21" or to roll back to it. Appending this counter gives
#  every distinct build an immutable tag (7.6.13) while :<version> and :latest
#  keep floating to the newest one.
#
#  The counter resets to 0 on every upstream version bump, so it stays small
#  and readable, and it is derived purely from git: re-running the same
#  workflow on the same commit produces the same tag rather than burning a
#  new number for identical content.
#
#  Usage:
#    build-revision.sh <jq_key> <path>...
#        version read from versions.json[<jq_key>]
#    build-revision.sh --source <file> --jq-key <key> -- <path>...
#        version read from a JSON file that is not versions.json
#    build-revision.sh --source <file> --grep <perl_regex> -- <path>...
#        version scraped from a tracked file (php reads its own FROM line)
#    build-revision.sh --unanchored -- <path>...
#        no version recorded in git (nginx resolves it from upstream at build
#        time), so the counter runs from the root commit instead of resetting.
#        Tags stay unique because the version prefix changes on its own.
#
#  <path>... are that image's build inputs. Keep them in step with the
#  workflow's push `paths:` filter, minus the workflow file itself: editing
#  the pipeline does not change what lands in the image.
# =====================================================================
set -euo pipefail

SOURCE="versions.json"
JQ_KEY=""
GREP_RE=""
ANCHORED=true

if [ "${1:-}" = "--unanchored" ]; then
  ANCHORED=false
  shift
  [ "${1:-}" = "--" ] && shift
elif [ "${1:-}" = "--source" ]; then
  while [ "${1:-}" != "--" ] && [ "$#" -gt 0 ]; do
    case "$1" in
      --source)  SOURCE="$2"; shift 2 ;;
      --jq-key)  JQ_KEY="$2"; shift 2 ;;
      --grep)    GREP_RE="$2"; shift 2 ;;
      *) echo "build-revision: unknown option $1" >&2; exit 1 ;;
    esac
  done
  shift  # the --
else
  JQ_KEY="${1:?usage: build-revision.sh <jq_key> <path>...}"
  shift
fi

[ "$#" -gt 0 ] || { echo "build-revision: no input paths given" >&2; exit 1; }

# A shallow checkout silently yields 0 for every image -- actions/checkout
# defaults to fetch-depth 1, so fail loudly rather than tag everything .0.
if [ "$(git rev-parse --is-shallow-repository)" = "true" ]; then
  echo "build-revision: shallow clone; checkout needs fetch-depth: 0" >&2
  exit 1
fi

# Read the version out of an arbitrary revision of the source file. Called
# with an empty rev for the working tree.
read_version() {
  local rev="$1" content
  if [ -n "$rev" ]; then
    content=$(git show "${rev}:${SOURCE}" 2>/dev/null) || return 0
  else
    content=$(cat "$SOURCE" 2>/dev/null) || return 0
  fi
  if [ -n "$JQ_KEY" ]; then
    printf '%s' "$content" | jq -r --arg k "$JQ_KEY" '.[$k] // empty' 2>/dev/null || true
  else
    printf '%s' "$content" | grep -oP "$GREP_RE" 2>/dev/null | head -1 || true
  fi
}

BASE=""
if [ "$ANCHORED" = true ]; then
  CURRENT=$(read_version "")
  [ -n "$CURRENT" ] || { echo "build-revision: no version found in ${SOURCE}" >&2; exit 1; }

  # Walk the source file backwards to the oldest commit that already carries
  # the current value: that commit is where this upstream version was introduced.
  while read -r sha; do
    [ "$(read_version "$sha")" = "$CURRENT" ] || break
    BASE="$sha"
  done < <(git log --format=%H -- "$SOURCE")
fi

# No anchor (unanchored, or the version never changed in history): count from
# the root commit.
if [ -n "$BASE" ]; then
  git rev-list --count "${BASE}..HEAD" -- "$@"
else
  git rev-list --count HEAD -- "$@"
fi
