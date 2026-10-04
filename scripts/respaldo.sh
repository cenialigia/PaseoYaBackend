#!/usr/bin/env bash
# DEC-24 · Respaldo semanal manual de la base (esquema, datos y roles).
# Uso: npm run respaldo            → proyecto vinculado (nube)
#      npm run respaldo -- --local → base local de Docker
# Los archivos se guardan FUERA del repositorio (RESPALDO_DIR, por defecto ~/paseoya-respaldos):
# contienen datos personales y no deben subirse a Git. No incluye los archivos de Storage (fotos), sólo sus metadatos.
set -euo pipefail

OBJETIVO="${1:---linked}"
DESTINO="${RESPALDO_DIR:-$HOME/paseoya-respaldos}"
SELLO="$(date +%Y%m%d-%H%M)"
mkdir -p "$DESTINO"
BASE="$DESTINO/paseoya-$SELLO"

npx supabase db dump "$OBJETIVO" -f "$BASE-esquema.sql"
npx supabase db dump "$OBJETIVO" --data-only --use-copy --schema public,auth,storage,cron -f "$BASE-datos.sql"
npx supabase db dump "$OBJETIVO" --role-only -f "$BASE-roles.sql"

echo "Respaldo listo en $DESTINO:"
ls -1 "$BASE"-*.sql
