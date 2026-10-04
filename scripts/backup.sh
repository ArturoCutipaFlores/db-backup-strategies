#!/usr/bin/env bash
# ==================================================================
# backup.sh — Backup lógico COMPLETO de PostgreSQL con pg_dump
# ------------------------------------------------------------------
# Genera:  <BACKUP_DIR>/backup_YYYYMMDD_HHMMSS.sql.gz   (+ .sha256)
#          (o .sql.gz.gpg si se define BACKUP_ENCRYPTION_KEY)
#
# Variables de entorno:
#   DATABASE_URL           (obligatoria) cadena de conexión de PostgreSQL.
#                          En Neon usa la conexión DIRECTA (sin "-pooler").
#   BACKUP_DIR             carpeta destino (por defecto ./backups)
#   PG_BIN_DIR             carpeta con los binarios de PostgreSQL a usar
#                          (ej. /usr/lib/postgresql/17/bin). Opcional.
#   BACKUP_ENCRYPTION_KEY  si se define, cifra el backup con GPG (AES-256).
#   BACKUP_KEEP_LAST       si es > 0, conserva solo los N backups locales
#                          más recientes y borra los antiguos (retención local).
#
# Uso:
#   DATABASE_URL="postgresql://..." ./scripts/backup.sh
#
# Funciona en Ubuntu (runner de GitHub Actions) y en Alpine (Dockerfile).
# ==================================================================
set -Eeuo pipefail

# ---------- utilidades ----------
log()  { echo "[$(date -u '+%Y-%m-%d %H:%M:%S UTC')] $*"; }
fail() { log "ERROR: $*" >&2; exit 1; }

# Muestra solo el host de la conexión (NUNCA imprimir usuario/contraseña).
db_host() { echo "$1" | sed -E 's#^[a-zA-Z]+://([^@]*@)?([^/:?]+).*#\2#'; }

# ---------- configuración ----------
DATABASE_URL="${DATABASE_URL:-}"
BACKUP_DIR="${BACKUP_DIR:-./backups}"
PG_BIN_DIR="${PG_BIN_DIR:-}"
BACKUP_ENCRYPTION_KEY="${BACKUP_ENCRYPTION_KEY:-}"
BACKUP_KEEP_LAST="${BACKUP_KEEP_LAST:-0}"

PG_DUMP="pg_dump"
[[ -n "$PG_BIN_DIR" ]] && PG_DUMP="${PG_BIN_DIR%/}/pg_dump"

# ---------- validaciones previas ----------
[[ -n "$DATABASE_URL" ]] || fail "DATABASE_URL no está definida."
command -v "$PG_DUMP" >/dev/null 2>&1 || fail "No se encontró pg_dump ($PG_DUMP). Instala postgresql-client."
command -v gzip >/dev/null 2>&1      || fail "No se encontró gzip."
if [[ -n "$BACKUP_ENCRYPTION_KEY" ]]; then
  command -v gpg >/dev/null 2>&1 || fail "BACKUP_ENCRYPTION_KEY está definida pero gpg no está instalado."
fi
[[ "$BACKUP_KEEP_LAST" =~ ^[0-9]+$ ]] || fail "BACKUP_KEEP_LAST debe ser un número entero."

mkdir -p "$BACKUP_DIR" || fail "No se pudo crear la carpeta $BACKUP_DIR."

TIMESTAMP="$(date -u +%Y%m%d_%H%M%S)"
BACKUP_FILE="${BACKUP_DIR%/}/backup_${TIMESTAMP}.sql.gz"
TMP_FILE="${BACKUP_FILE}.partial"

# Si algo falla (error de comando o llamada a fail), borra los archivos
# incompletos para no dejar backups corruptos que parezcan válidos.
cleanup_on_exit() {
  local code=$?
  if (( code != 0 )); then
    rm -f "$TMP_FILE" "${BACKUP_FILE}.gpg.partial"
    log "Backup FALLIDO (código $code). Se eliminaron archivos parciales." >&2
  fi
}
trap cleanup_on_exit EXIT

log "Iniciando backup completo"
log "  Servidor : $(db_host "$DATABASE_URL")"
log "  pg_dump  : $("$PG_DUMP" --version)"
log "  Destino  : $BACKUP_FILE"

START_TS=$(date +%s)

# ---------- 1. Volcado ----------
#  --format=plain     SQL legible, se restaura con psql (portable entre versiones)
#  --clean --if-exists  incluye DROP ... IF EXISTS: la restauración reemplaza los objetos
#  --no-owner --no-privileges  evita depender de roles concretos (Neon usa roles propios)
#  pipefail hace que un fallo de pg_dump aborte aunque gzip termine bien.
"$PG_DUMP" \
  --dbname="$DATABASE_URL" \
  --format=plain \
  --clean --if-exists \
  --no-owner --no-privileges \
  --encoding=UTF8 \
  | gzip -9 > "$TMP_FILE"

# ---------- 2. Verificación de integridad ----------
gzip -t "$TMP_FILE" || fail "El archivo comprimido está corrupto."
[[ -s "$TMP_FILE" ]] || fail "El backup está vacío."
# pg_dump escribe esta marca al final solo si el volcado terminó completo.
# (se usa grep -c en vez de grep -q para no cortar la tubería con SIGPIPE)
gzip -dc "$TMP_FILE" | tail -n 20 | grep -c "PostgreSQL database dump complete" >/dev/null \
  || fail "El volcado parece incompleto (no se encontró la marca final de pg_dump)."

mv "$TMP_FILE" "$BACKUP_FILE"

# ---------- 3. Cifrado opcional (AES-256 simétrico con GPG) ----------
if [[ -n "$BACKUP_ENCRYPTION_KEY" ]]; then
  log "Cifrando backup con GPG (AES-256)..."
  # La clave se pasa por descriptor (fd 0) para que no aparezca en 'ps'.
  gpg --batch --yes --quiet \
      --pinentry-mode loopback --passphrase-fd 0 \
      --symmetric --cipher-algo AES256 \
      --output "${BACKUP_FILE}.gpg.partial" "$BACKUP_FILE" <<< "$BACKUP_ENCRYPTION_KEY"
  mv "${BACKUP_FILE}.gpg.partial" "${BACKUP_FILE}.gpg"
  rm -f "$BACKUP_FILE"            # no dejar la copia sin cifrar
  BACKUP_FILE="${BACKUP_FILE}.gpg"
fi

# ---------- 4. Checksum SHA-256 (para verificar antes de restaurar) ----------
(
  cd "$(dirname "$BACKUP_FILE")"
  sha256sum "$(basename "$BACKUP_FILE")" > "$(basename "$BACKUP_FILE").sha256"
)

# ---------- 5. Retención local opcional ----------
if (( BACKUP_KEEP_LAST > 0 )); then
  log "Retención local: se conservan los últimos $BACKUP_KEEP_LAST backups."
  # Los nombres llevan fecha, así que el orden alfabético inverso = más reciente primero.
  find "${BACKUP_DIR%/}" -maxdepth 1 -type f \( -name 'backup_*.sql.gz' -o -name 'backup_*.sql.gz.gpg' \) \
    | sort -r | tail -n +"$((BACKUP_KEEP_LAST + 1))" \
    | while read -r old; do
        log "  Eliminando backup antiguo: $(basename "$old")"
        rm -f "$old" "${old}.sha256"
      done
fi

# ---------- 6. Resumen ----------
SIZE_BYTES=$(stat -c%s "$BACKUP_FILE")
SIZE_HUMAN=$(du -h "$BACKUP_FILE" | cut -f1)
DURATION=$(( $(date +%s) - START_TS ))
CHECKSUM=$(cut -d' ' -f1 < "${BACKUP_FILE}.sha256")

log "Backup completado correctamente"
log "  Archivo  : $BACKUP_FILE"
log "  Tamaño   : $SIZE_HUMAN ($SIZE_BYTES bytes)"
log "  SHA-256  : $CHECKSUM"
log "  Duración : ${DURATION}s"

# Exporta datos a los siguientes pasos del workflow de GitHub Actions.
if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  {
    echo "backup_file=$BACKUP_FILE"
    echo "backup_name=$(basename "$BACKUP_FILE")"
    echo "backup_size=$SIZE_HUMAN"
    echo "backup_bytes=$SIZE_BYTES"
    echo "backup_sha256=$CHECKSUM"
  } >> "$GITHUB_OUTPUT"
fi
