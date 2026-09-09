#!/bin/sh
# =====================================================================
#  check-image-closure.sh — verifie qu'une image FROM scratch embarque
#  bien TOUTES les bibliotheques dont ses binaires ont besoin.
#
#  Pourquoi : `lddtree` signale une dependance introuvable sur stderr et
#  sort quand meme en 0. Un build qui derive sa cloture de lddtree peut
#  donc publier une image trouee sans que rien n'echoue -- l'erreur ne
#  sort qu'au demarrage du conteneur, en production.
#  Constate le 2026-08-28 sur clamav-hardened : `apk add bzip2` n'installe
#  pas libbz2.so.1 (paquet separe), lddtree a ecrit "libbz2.so.1: Not
#  found." et le build a reussi.
#
#  Methode : exporter le filesystem de l'image, puis demander au vrai
#  chargeur musl -- dans un chroot sur ce filesystem, donc avec exactement
#  les chemins de l'image -- de resoudre chaque ELF embarque.
#
#  Usage : check-image-closure.sh <image> [<image>...]
#  Sortie : 0 si toutes les images sont completes, 1 sinon.
# =====================================================================
set -eu

ALPINE="alpine:3.24@sha256:28bd5fe8b56d1bd048e5babf5b10710ebe0bae67db86916198a6eec434943f8b"
RC=0
SANS_LOADER=0

[ "$#" -gt 0 ] || { echo "usage: $0 <image> [<image>...]" >&2; exit 2; }

for img in "$@"; do
  printf '\n== %s\n' "$img"

  # Une image nommee qu'on ne trouve pas est un ECHEC, pas un saut. Sauter
  # rendrait ce script vert sur une faute de frappe dans le tag -- exactement
  # le faux vert qu'il est cense empecher ailleurs.
  if ! docker image inspect "$img" >/dev/null 2>&1; then
    if ! docker pull -q "$img" >/dev/null 2>&1; then
      echo "  ECHEC -- image introuvable localement et pull impossible"
      RC=1
      continue
    fi
  fi

  dir=$(mktemp -d)
  cid=$(docker create "$img" 2>/dev/null) || { echo "  ECHEC -- docker create a echoue"; RC=1; rm -rf "$dir"; continue; }
  docker export "$cid" | tar -x -C "$dir" 2>/dev/null || true
  docker rm -f "$cid" >/dev/null 2>&1 || true

  # Le chroot tourne dans un conteneur : pas besoin d'etre root sur l'hote,
  # et le filesystem teste est bien celui de l'image, pas celui de l'hote.
  out=$(docker run --rm -v "$dir:/x" "$ALPINE" sh -c '
    ldso=""
    for c in /x/lib/ld-musl-*.so.1 /x/usr/lib/ld-musl-*.so.1; do
      [ -f "$c" ] && { ldso="${c#/x}"; break; }
    done
    if [ -z "$ldso" ]; then
      echo "PAS-DE-LOADER"
      exit 0
    fi
    # Tout ELF embarque : executables et objets partages.
    find /x -type f \( -perm -111 -o -name "*.so*" \) 2>/dev/null | while IFS= read -r f; do
      # Signature ELF (0x7f E L F) -- evite de lancer le loader sur des
      # scripts, des configs ou des certificats marques executables.
      case "$(dd if="$f" bs=4 count=1 2>/dev/null | tr -d "\0")" in
        *ELF*) ;;
        *) continue ;;
      esac
      rel="${f#/x}"
      # On ne retient QUE "Error loading shared library" : une bibliotheque
      # absente est un vrai trou de cloture. Les "symbol not found" sont
      # attendus sur un plugin dlopen (squidclamav.so, dnsbl_tables.so, ...)
      # dont les symboles viennent du processus hote, pas d une lib liee --
      # les compter ferait echouer toute image a modules.
      miss=$(chroot /x "$ldso" --list "$rel" 2>&1 | grep "Error loading shared library" || true)
      [ -n "$miss" ] && printf "%s\n%s\n" "  MANQUE dans $rel :" "$miss"
    done
  ' 2>/dev/null) || true

  rm -rf "$dir"

  case "$out" in
    *PAS-DE-LOADER*)
      echo "  [saute] pas de chargeur musl (image statique ou non-Alpine)"
      SANS_LOADER=$((SANS_LOADER + 1)) ;;
    "")
      echo "  OK -- toutes les dependances sont resolues" ;;
    *)
      echo "$out"
      echo "  ECHEC -- cloture incomplete"
      RC=1 ;;
  esac
done

echo
if [ "$RC" -ne 0 ]; then
  echo "=== Au moins une image a une cloture trouee, ou n'a pas pu etre lue ==="
elif [ "$SANS_LOADER" -gt 0 ]; then
  # Ne jamais annoncer "toutes completes" quand une image n'a pas ete examinee :
  # c'est la difference entre « rien a signaler » et « rien n'a tourne ».
  echo "=== Clotures completes, mais $SANS_LOADER image(s) NON EXAMINEE(S) (pas de chargeur) ==="
else
  echo "=== Toutes les clotures sont completes ==="
fi
exit "$RC"
