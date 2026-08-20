#!/usr/bin/env bash
#
# Rewrite the CI-managed tag block in README.md.
#
# Usage: update-readme-tags.sh <image>=<version>=<revision-tag> [...]
#
# The block between the markers is the single source of truth for published tag
# values; the prose around it is static and never names a version. Publish
# workflows call this after pushing, so the README cannot drift from what the
# registries actually carry.
set -euo pipefail

README="${README:-README.md}"
BEGIN='<!-- BEGIN:tags (genere par la CI -- ne pas editer a la main) -->'
END='<!-- END:tags -->'

if [ "$#" -eq 0 ]; then
  echo "usage: $0 <image>=<version>=<revision-tag> ..." >&2
  exit 2
fi
for marker in "$BEGIN" "$END"; do
  grep -qF -- "$marker" "$README" || {
    echo "$README: marker not found: $marker" >&2
    exit 1
  }
done

block=$(mktemp)
out=$(mktemp)
trap 'rm -f "$block" "$out"' EXIT
{
  printf '%s\n' "$BEGIN"
  printf '| Image | Version amont | Tag immuable a epingler |\n'
  printf '|-------|---------------|-------------------------|\n'
  for spec in "$@"; do
    IFS='=' read -r img ver rev <<<"$spec"
    if [ -z "$img" ] || [ -z "$ver" ] || [ -z "$rev" ]; then
      echo "malformed spec (want image=version=revision): $spec" >&2
      exit 1
    fi
    # SC2016: the backticks are literal Markdown, not command substitution.
    # shellcheck disable=SC2016
    printf '| `%s` | `%s` | `%s` |\n' "$img" "$ver" "$rev"
  done
  printf '%s\n' "$END"
} > "$block"

awk -v b="$BEGIN" -v e="$END" -v blk="$block" '
  BEGIN { while ((getline l < blk) > 0) buf = buf l "\n"; close(blk) }
  $0 == b { printf "%s", buf; skip = 1; next }
  skip && $0 == e { skip = 0; next }
  skip { next }
  { print }
' "$README" > "$out"

mv "$out" "$README"
echo "README tag block updated: $*"
