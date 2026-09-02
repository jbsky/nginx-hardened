#!/usr/bin/env bash
#
# Render every version-bearing part of README.md from the values the publish
# workflow just used.
#
# Usage: update-readme-tags.sh [--check] <image>=<version>=<revision-tag> [...]
#
# `<image>` is the full repository name (`jbsky/bind9-hardened`); the part after
# the slash is the *key* used by the inline markers below.
#
# Three things are generated, and they are the ONLY places a version may appear
# in the README:
#
#   1. the table between BEGIN:tags / END:tags -- one row per image;
#   2. inline spans in prose, hidden by HTML comments so nothing shows on
#      GitHub:  `<!--v:bind9-hardened-->9.20.27<!--/v-->` (upstream version) and
#      `<!--t:bind9-hardened-->9.20.27.9<!--/t-->` (immutable tag);
#   3. any tagged reference to one of these images -- `jbsky/x:9.20.27.9`,
#      with or without a `docker.io/` / `ghcr.io/` prefix -- which is rewritten
#      to the current immutable tag. `:latest` is deliberately left alone.
#
# Anything else that names a version drifts, because nothing updates it: the
# README used to announce BIND 9.20.26 and hand out `:9.20.26.3` in four code
# blocks while the table already said 9.20.27. So a guard runs after the
# rewrite: a dotted-number token that belongs to an image's version family
# (same components but the last) without being that image's current version or
# a tag derived from it fails the run. Prose that legitimately names an *old*
# version -- "embarque depuis la 8.0.5" -- exempts its line with a trailing
# `<!-- version-fixe -->` comment.
#
# --check renders into a temp file and fails on any difference instead of
# writing. It is a local/manual audit, NOT a PR gate: between a publish and the
# commit that follows it the revision counter legitimately leads the README by
# one, and a gate would go red on every pull request.
set -euo pipefail

README="${README:-README.md}"
BEGIN='<!-- BEGIN:tags (genere par la CI -- ne pas editer a la main) -->'
END='<!-- END:tags -->'

CHECK=false
if [ "${1:-}" = "--check" ]; then
  CHECK=true
  shift
fi

if [ "$#" -eq 0 ]; then
  echo "usage: $0 [--check] <image>=<version>=<revision-tag> ..." >&2
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

specs=""
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
    specs="${specs}${img#*/}|${ver}|${rev};"
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

# Prose spans and tagged image references. The tag regex starts on a digit so
# `:latest` -- which is meant to float -- is never touched.
for spec in "$@"; do
  IFS='=' read -r img ver rev <<<"$spec"
  key="${img#*/}"
  sed -E -i \
    -e "s#(<!--v:${key}-->)[^<]*(<!--/v-->)#\1${ver}\2#g" \
    -e "s#(<!--t:${key}-->)[^<]*(<!--/t-->)#\1${rev}\2#g" \
    -e "s#(jbsky/${key}):[0-9][0-9A-Za-z._-]*#\1:${rev}#g" \
    "$out"
done

awk -v specs="$specs" -v file="$README" '
  BEGIN {
    n = split(specs, a, ";")
    for (i = 1; i <= n; i++) {
      if (a[i] == "") continue
      split(a[i], f, "|")
      key[i] = f[1]; ver[i] = f[2]
      fam[i] = ver[i]
      sub(/\.[0-9]+$/, ".", fam[i])   # 9.20.27 -> 9.20.  /  7.7 -> 7.
      count = i
    }
  }
  index($0, "BEGIN:tags") { inblk = 1 }
  index($0, "END:tags")   { inblk = 0; next }
  inblk { next }
  index($0, "version-fixe") { next }
  {
    rest = $0
    while (match(rest, /[0-9]+(\.[0-9]+)+/)) {
      tok  = substr(rest, RSTART, RLENGTH)
      rest = substr(rest, RSTART + RLENGTH)
      ok = 0; hit = 0
      for (i = 1; i <= count; i++) {
        if (tok == ver[i] || index(tok, ver[i] ".") == 1) { ok = 1; break }
        if (index(tok, fam[i]) == 1) hit = i
      }
      if (!ok && hit) {
        printf "%s:%d: %s nomme %s alors que la version courante est %s\n",
               file, NR, key[hit], tok, ver[hit] > "/dev/stderr"
        bad++
      }
    }
  }
  END { if (bad) exit 1 }
' "$out" || {
  echo "version perimee hors des zones generees; corriger la ligne ou l'exempter avec <!-- version-fixe -->" >&2
  exit 1
}

if [ "$CHECK" = true ]; then
  if diff -u "$README" "$out"; then
    echo "README a jour: $*"
    exit 0
  fi
  echo "README perime (voir le diff ci-dessus): $*" >&2
  exit 1
fi

mv "$out" "$README"
echo "README rendered: $*"
