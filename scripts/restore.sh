#!/usr/bin/env bash
# ==================================================================
# restore.sh — Restaura un backup de PostgreSQL
# ------------------------------------------------------------------
# Formatos soportados (se detecta por la extensión):
#   *.sql.gz      -> gunzip | psql           (generado por backup.sh)
#   *.sql.gz.gpg  -> gpg -d | gunzip | psql  (backup cifrado)
#   *.sql         -> psql
#   *.dump        -> pg_restore              (formato custom de pg_dump -Fc)
#
# Variables de entorno:
#   TARGET_DATABASE_URL    BD destino. Si no se define se usa DATABASE_URL.
#   DATABASE_URL           BD destino por defecto.
#   PG_BIN_DIR             carpeta con psql/pg_restore a usar (opcional).
#   BACKUP_ENCRYPTION_KEY  clave para descifrar backups .gpg.
#
# Uso:
#   ./scripts/restore.sh backups/backup_20260101_020000.sql.gz
#   ./scripts/restore.sh --yes backups/backup_...sql.gz     # sin confirmación (CI)
#
# ¡ATENCIÓN! El backup incluye DROP ... IF EXISTS: los objetos existentes
# en la BD destino (p. ej. la tabla "tasks") se REEMPLAZAN por los del backup.
# ==================================================================
set -Eeuo pipefail

log()  { echo "[$(date -u '+%Y-%m-%d %H:%M:%S UTC')] $*"; }
fail() { log "ERROR: $*" >&2; exit 1; }
db_host() { echo "$1" | sed -E 's#^[a-zA-Z]+://([^@]*@)?([^/:?]+).*#\2#'; }

usage() {
  cat <<EOF
Uso: $(basename "$0") [--yes] <archivo_backup>

  <archivo_backup>  .sql.gz | .sql.gz.gpg | .sql | .dump
  --yes, -y         no pedir confirmación (para CI / scripts)

La BD destino se toma de TARGET_DATABASE_URL o, si no existe, de DATABASE_URL.
EOF
}

# ---------- argumentos ----------
ASSUME_YES="${FORCE:-0}"
BACKUP_FILE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -y|--yes) ASSUME_YES=1; shift ;;
    -h|--help) usage; exit 0 ;;
    -*) usage; fail "Opción desconocida: $1" ;;
    *) BACKUP_FILE="$1"; shift ;;
  esac
done

[[ -n "$BACKUP_FILE" ]] || { usage; fail "Debes indicar el archivo de backup."; }
[[ -f "$BACKUP_FILE" ]] || fail "No existe el archivo: $BACKUP_FILE"

TARGET_URL="${TARGET_DATABASE_URL:-${DATABASE_URL:-}}"
[[ -n "$TARGET_URL" ]] || fail "Define TARGET_DATABASE_URL o DATABASE_URL con la BD destino."

PG_BIN_DIR="${PG_BIN_DIR:-}"
PSQL="psql"; PG_RESTORE="pg_restore"
if [[ -n "$PG_BIN_DIR" ]]; then
  PSQL="${PG_BIN_DIR%/}/psql"; PG_RESTORE="${PG_BIN_DIR%/}/pg_restore"
fi
command -v "$PSQL" >/dev/null 2>&1 || fail "No se encontró psql. Instala postgresql-client."

# ---------- verificación de checksum (si existe el .sha256) ----------
if [[ -f "${BACKUP_FILE}.sha256" ]]; then
  log "Verificando checksum SHA-256..."
  ( cd "$(dirname "$BACKUP_FILE")" && sha256sum -c "$(basename "$BACKUP_FILE").sha256" ) \
    || fail "El checksum NO coincide: el archivo está dañado o fue modificado."
else
  log "Aviso: no se encontró ${BACKUP_FILE}.sha256; se omite la verificación de checksum."
fi

# ---------- confirmación ----------
log "Archivo   : $BACKUP_FILE ($(du -h "$BACKUP_FILE" | cut -f1))"
log "Destino   : $(db_host "$TARGET_URL")"
if [[ "$ASSUME_YES" != "1" ]]; then
  [[ -t 0 ]] || fail "Entrada no interactiva: usa --yes para confirmar la restauración."
  echo
  echo "  Se van a REEMPLAZAR los objetos de la base de datos destino con el contenido del backup."
  read -r -p "  Escribe RESTAURAR para continuar: " answer
  [[ "$answer" == "RESTAURAR" ]] || fail "Restauración cancelada por el usuario."
fi

# Elimina líneas incompatibles con servidores más antiguos:
# pg_dump 17 emite "SET transaction_timeout = 0;", que PostgreSQL <=16 no reconoce
# (pasa al restaurar un backup de Neon (v17) en el postgres:15 local).
sanitize_sql() { sed -e '/^SET transaction_timeout = /d'; }

# psql con:
#   ON_ERROR_STOP=1        aborta al primer error
#   --single-transaction   todo o nada: si falla, la BD queda como estaba
run_psql() {
  "$PSQL" --dbname="$TARGET_URL" \
          --set ON_ERROR_STOP=1 \
          --single-transaction \
          --quiet --no-psqlrc \
          --output=/dev/null
}

decrypt() {
  [[ -n "${BACKUP_ENCRYPTION_KEY:-}" ]] || fail "El backup está cifrado: define BACKUP_ENCRYPTION_KEY."
  command -v gpg >/dev/null 2>&1 || fail "gpg no está instalado."
  # La clave entra por el descriptor 3 para no exponerla en la línea de comandos.
  gpg --batch --quiet --pinentry-mode loopback --passphrase-fd 3 \
      --decrypt "$BACKUP_FILE" 3<<< "$BACKUP_ENCRYPTION_KEY"
}

START_TS=$(date +%s)
log "Iniciando restauración..."

case "$BACKUP_FILE" in
  *.sql.gz.gpg)
    decrypt | gzip -dc | sanitize_sql | run_psql ;;
  *.sql.gz)
    gzip -t "$BACKUP_FILE" || fail "El archivo .gz está corrupto."
    gzip -dc "$BACKUP_FILE" | sanitize_sql | run_psql ;;
  *.sql)
    sanitize_sql < "$BACKUP_FILE" | run_psql ;;
  *.dump)
    command -v "$PG_RESTORE" >/dev/null 2>&1 || fail "No se encontró pg_restore."
    "$PG_RESTORE" --dbname="$TARGET_URL" --clean --if-exists \
                  --no-owner --no-privileges --single-transaction --exit-on-error \
                  "$BACKUP_FILE" ;;
  *)
    fail "Extensión no soportada: $BACKUP_FILE (usa .sql.gz, .sql.gz.gpg, .sql o .dump)" ;;
esac

log "Restauración completada en $(( $(date +%s) - START_TS ))s"

# ---------- verificación post-restauración ----------
HAS_TASKS=$("$PSQL" --dbname="$TARGET_URL" --no-psqlrc -tA \
             -c "SELECT to_regclass('public.tasks') IS NOT NULL" 2>/dev/null || echo "f")
if [[ "$HAS_TASKS" == "t" ]]; then
  TOTAL=$("$PSQL" --dbname="$TARGET_URL" --no-psqlrc -tA -c "SELECT COUNT(*) FROM tasks")
  log "Verificación: la tabla 'tasks' tiene $TOTAL filas."
else
  log "Aviso: no se encontró la tabla 'tasks' tras la restauración."
fi
