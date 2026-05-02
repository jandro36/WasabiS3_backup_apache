#!/bin/bash
# ==============================================================================
# backup_wasabi.sh — Backup automatico Web + MySQL -> Wasabi S3
# ==============================================================================
# Requisitos:
#   - AWS CLI v2 configurado con perfil Wasabi (~/.aws/credentials)
#   - mysqldump instalado
#
# Uso:
#   chmod +x backup_wasabi.sh && ./backup_wasabi.sh
#
# Cron diario a las 2:00 AM:
#   0 2 * * * /opt/scripts/backup_wasabi.sh >> /var/log/backup_wasabi.log 2>&1
#
# Credenciales MySQL sin hardcodear:
#
#   Opcion A — variables de entorno:
#     export DB_USER="backup_user"
#     export DB_PASS="mipassword"
#     ./backup_wasabi.sh
#
#   Opcion B — ~/.my.cnf (recomendada):
#     Crea el fichero con chmod 600:
#       [client]
#       user=backup_user
#       password=TU_PASSWORD
#     Y elimina -u "$DB_USER" -p"$DB_PASS" de la linea de mysqldump.
# ==============================================================================

set -euo pipefail

# ==============================================================================
# CONFIGURACION
# ==============================================================================

FECHA=$(date +%Y-%m-%d)
TIMESTAMP=$(date +%Y-%m-%d_%H-%M-%S)

DIR_ORIGEN="/var/www"
DIR_DESTINO="/tmp/backups"
DIR_SNAPSHOT="/tmp/snapshot_www"

ARCHIVO_WEB="backup_www_${FECHA}.tar.gz"
ARCHIVO_SQL="backup_db_${FECHA}.sql.gz"

# Credenciales — lee de variable de entorno si existe; si no, usa el valor por defecto
# ADVERTENCIA: el valor por defecto queda en texto plano. Usa Opcion A o B (ver cabecera).
DB_USER="${DB_USER:-backup_user}"
DB_PASS="${DB_PASS:-TU_PASSWORD}"

# Wasabi S3
BUCKET_WASABI="${BUCKET_WASABI:-bckvps}"
WASABI_ENDPOINT="https://s3.eu-south-1.wasabisys.com"
PERFIL_AWS="${PERFIL_AWS:-wasabi}"

# Retencion en Wasabi (dias). 0 = no borrar nunca.
RETENTION_DAYS=30

# ==============================================================================
# FUNCIONES
# ==============================================================================

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

error_exit() {
    log "ERROR: $*" >&2
    exit 1
}

cleanup() {
    log "Limpieza automatica: borrando archivos temporales..."
    rm -rf "${DIR_SNAPSHOT:?}/www" 2>/dev/null || true
    rm -f "${DIR_DESTINO}/${ARCHIVO_WEB}" "${DIR_DESTINO}/${ARCHIVO_SQL}" 2>/dev/null || true
}

# Ejecutar cleanup SIEMPRE al salir: en exito y en cualquier error
trap cleanup EXIT

# ==============================================================================
# VALIDACIONES PREVIAS
# ==============================================================================

log "Verificando dependencias y accesos..."

for cmd in aws mysqldump gzip tar; do
    command -v "$cmd" &>/dev/null || error_exit "Comando '$cmd' no encontrado."
done

[ -d "$DIR_ORIGEN" ] || error_exit "El directorio '$DIR_ORIGEN' no existe."

aws s3 ls "s3://${BUCKET_WASABI}/" \
    --endpoint-url="$WASABI_ENDPOINT" \
    --profile "$PERFIL_AWS" &>/dev/null \
    || error_exit "No se puede acceder al bucket '${BUCKET_WASABI}'. Verifica ~/.aws/credentials."

# ==============================================================================
# EJECUCION
# ==============================================================================

log "======================================================"
log "Iniciando proceso de backup — ${TIMESTAMP}"
log "======================================================"

mkdir -p "$DIR_DESTINO"
mkdir -p "$DIR_SNAPSHOT"

log "1/4: Creando snapshot seguro de los archivos web..."
# cp -a mantiene intactos todos los permisos originales. Tu /var/www real NO se modifica.
cp -a "$DIR_ORIGEN" "$DIR_SNAPSHOT/"

log "2/4: Comprimiendo archivos web excluyendo logs y cache..."
cd "$DIR_SNAPSHOT"
tar --exclude="*.log" \
    --exclude="*.log.*" \
    --exclude="wp-content/cache" \
    --exclude="wp-content/uploads/cache" \
    --exclude=".git" \
    --exclude="node_modules" \
    -czf "${DIR_DESTINO}/${ARCHIVO_WEB}" www/ \
    || error_exit "Fallo al comprimir los archivos web."

# Limpieza inmediata del snapshot para liberar espacio
rm -rf "${DIR_SNAPSHOT:?}/www"

WEB_SIZE=$(du -sh "${DIR_DESTINO}/${ARCHIVO_WEB}" | cut -f1)
log "   Tamano: ${WEB_SIZE}"

log "3/4: Exportando bases de datos MySQL..."
mysqldump -u "$DB_USER" -p"$DB_PASS" \
    --all-databases \
    --single-transaction \
    --routines \
    --triggers \
    --events \
    2>/tmp/mysqldump_err.log \
    | gzip > "${DIR_DESTINO}/${ARCHIVO_SQL}"

# Filtrar stderr: warning de password es esperado; cualquier otra linea = error real
if [ -s /tmp/mysqldump_err.log ]; then
    MYSQL_ERR=$(cat /tmp/mysqldump_err.log)
    rm -f /tmp/mysqldump_err.log
    echo "$MYSQL_ERR" | grep -vi "^\[Warning\]" | grep -vi "^mysqldump: \[Warning\]" \
        && error_exit "Fallo al exportar las bases de datos." || true
fi
rm -f /tmp/mysqldump_err.log

SQL_SIZE=$(du -sh "${DIR_DESTINO}/${ARCHIVO_SQL}" | cut -f1)
log "   Tamano: ${SQL_SIZE}"

log "4/4: Subiendo backups a Wasabi..."
aws s3 cp "${DIR_DESTINO}/${ARCHIVO_WEB}" \
    "s3://${BUCKET_WASABI}/" \
    --endpoint-url="$WASABI_ENDPOINT" \
    --profile "$PERFIL_AWS" \
    || error_exit "Fallo al subir el backup web."

aws s3 cp "${DIR_DESTINO}/${ARCHIVO_SQL}" \
    "s3://${BUCKET_WASABI}/" \
    --endpoint-url="$WASABI_ENDPOINT" \
    --profile "$PERFIL_AWS" \
    || error_exit "Fallo al subir el backup SQL."

# --- Retencion: eliminar backups con mas de RETENTION_DAYS dias en Wasabi ---
if [ "$RETENTION_DAYS" -gt 0 ]; then
    log "Retencion: eliminando backups de mas de ${RETENTION_DAYS} dias en Wasabi..."

    FECHA_LIMITE=$(date -d "-${RETENTION_DAYS} days" +%Y-%m-%d 2>/dev/null \
        || date -v "-${RETENTION_DAYS}d" +%Y-%m-%d) \
        || error_exit "No se pudo calcular la fecha limite de retencion."

    # || true: evita que grep aborte el script si no hay resultados
    ARCHIVOS_BUCKET=$(aws s3 ls "s3://${BUCKET_WASABI}/" \
        --endpoint-url="$WASABI_ENDPOINT" \
        --profile "$PERFIL_AWS" \
        | awk '{print $4}' \
        | grep -E "^backup_(www|db)_[0-9]{4}-[0-9]{2}-[0-9]{2}" || true)

    if [ -n "$ARCHIVOS_BUCKET" ]; then
        while IFS= read -r FILE; do
            FILE_DATE=$(echo "$FILE" | grep -oE "[0-9]{4}-[0-9]{2}-[0-9]{2}" | head -1)
            if [ -n "$FILE_DATE" ] && [[ "$FILE_DATE" < "$FECHA_LIMITE" ]]; then
                log "   Eliminando: ${FILE} (${FILE_DATE} < ${FECHA_LIMITE})"
                aws s3 rm "s3://${BUCKET_WASABI}/${FILE}" \
                    --endpoint-url="$WASABI_ENDPOINT" \
                    --profile "$PERFIL_AWS" || log "   AVISO: no se pudo eliminar ${FILE}"
            fi
        done <<< "$ARCHIVOS_BUCKET"
    else
        log "   Sin backups antiguos que eliminar."
    fi
fi

# El trap EXIT borra automaticamente los .tar.gz y .sql.gz locales al terminar
log "======================================================"
log "Backup completado y subido a Wasabi con exito!"
log "   Web -> s3://${BUCKET_WASABI}/${ARCHIVO_WEB} (${WEB_SIZE})"
log "   SQL -> s3://${BUCKET_WASABI}/${ARCHIVO_SQL} (${SQL_SIZE})"
log "======================================================"
