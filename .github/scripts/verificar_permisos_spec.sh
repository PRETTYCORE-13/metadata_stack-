#!/usr/bin/env bash
# Verifica que cada commit que toca docs/specs/SPEC-<ÁREA>-* lo haya
# escrito alguien con permiso en esa área (.github/spec-permisos.txt).
# Un renombrado cuenta para ambas áreas: la de origen y la de destino.
#
# Uso: verificar_permisos_spec.sh <owner/repo> <sha> [<sha> ...]
# Requiere `gh` autenticado (GH_TOKEN en CI).
set -euo pipefail

repo="$1"
shift
config="$(dirname "$0")/../spec-permisos.txt"
fallas=0

permitidos() {
  awk -v area="$1" '$1 == area { for (i = 2; i <= NF; i++) print $i }' "$config"
}

for sha in "$@"; do
  datos=$(gh api "repos/$repo/commits/$sha" --jq \
    '"\(.parents | length) \(.author.login // "")", (.files[] | .filename, (.previous_filename // empty))')

  read -r padres login <<<"$(head -n 1 <<<"$datos")"
  # Un merge solo junta commits que ya se verificaron uno por uno.
  [ "$padres" -gt 1 ] && continue

  while IFS= read -r archivo; do
    case "$archivo" in
      .github/spec-permisos.txt | .github/scripts/verificar_permisos_spec.sh | .github/workflows/spec-permisos.yml)
        area="ADMIN"
        ;;
      docs/specs/SPEC-*)
        area=$(sed -E 's#^docs/specs/SPEC-([A-Z]+)-.*#\1#' <<<"$archivo")
        ;;
      *)
        continue
        ;;
    esac

    lista=$(permitidos "$area")

    if [ -z "$lista" ]; then
      echo "::error file=$archivo::${sha:0:7}: el área '$area' no está en .github/spec-permisos.txt"
      fallas=1
    elif [ -z "$login" ]; then
      echo "::error file=$archivo::${sha:0:7}: el correo del autor no está ligado a ninguna cuenta de GitHub, no se puede verificar el permiso sobre '$area'"
      fallas=1
    elif ! grep -qxF -e "$login" <<<"$lista" && ! { [ "$area" != "ADMIN" ] && grep -qxF -e "*" <<<"$lista"; }; then
      echo "::error file=$archivo::${sha:0:7}: $login no tiene permiso para alterar el área '$area' (permitidos: $(tr '\n' ' ' <<<"$lista"))"
      fallas=1
    fi
  done < <(tail -n +2 <<<"$datos" | sort -u)
done

exit "$fallas"
