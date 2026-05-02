#!/bin/bash

# --- CONFIGURACIÓN ---
FECHA=$(date +\%Y-\%m-\%d)
DIR_ORIGEN="/var/www"
DIR_DESTINO="/tmp/backups"         # Carpeta para guardar los archivos comprimidos finales
DIR_SNAPSHOT="/tmp/snapshot_www"   # Carpeta temporal segura para clonar antes de comprimir

ARCHIVO_WEB="backup_www_${FECHA}.tar.gz"
ARCHIVO_SQL="backup_db_${FECHA}.sql.gz"

# Configuración de base de datos
DB_USER="backup_user"
DB_PASS="TU_PASSWORD"

# Configuración de Wasabi
BUCKET_WASABI="bckvps" # ¡Recuerda cambiar esto por el nombre real de tu bucket!
WASABI_ENDPOINT="https://s3.eu-south-1.wasabisys.com" #Tu URL del endpoint de tu S3 en Wasabi 
PERFIL_AWS="wasabi"

# --- EJECUCIÓN ---
echo "Iniciando proceso de backup..."

# 1. Crear directorios temporales si no existen
mkdir -p "$DIR_DESTINO"
mkdir -p "$DIR_SNAPSHOT"

echo "1/4: Creando snapshot seguro de los archivos web..."
# 2. Clonar la ruta web a la carpeta temporal
# cp -a mantiene intactos todos los permisos originales. Tu /var/www real NO se modifica.
cp -a "$DIR_ORIGEN" "$DIR_SNAPSHOT/"

echo "2/4: Comprimiendo archivos web excluyendo logs y caché..."
# 3. Comprimir desde la copia temporal clonada
cd "$DIR_SNAPSHOT"
tar --exclude='*.log' \
    --exclude='wp-content/cache' \
    -czvf "${DIR_DESTINO}/${ARCHIVO_WEB}" www/

# Limpieza inmediata de la copia temporal clonada para liberar espacio
rm -rf "${DIR_SNAPSHOT}/www"

echo "3/4: Exportando bases de datos MySQL..."
# 4. Exportar todas las bases de datos y comprimirlas al vuelo
mysqldump -u "$DB_USER" -p"$DB_PASS" --all-databases | gzip > "${DIR_DESTINO}/${ARCHIVO_SQL}"

echo "4/4: Subiendo backups a Wasabi..."
# 5. Subir archivos a Wasabi usando AWS CLI (Líneas corregidas)
aws s3 cp "${DIR_DESTINO}/${ARCHIVO_WEB}" "s3://${BUCKET_WASABI}/" --endpoint-url="$WASABI_ENDPOINT" --profile "$PERFIL_AWS"
aws s3 cp "${DIR_DESTINO}/${ARCHIVO_SQL}" "s3://${BUCKET_WASABI}/" --endpoint-url="$WASABI_ENDPOINT" --profile "$PERFIL_AWS"

echo "Limpieza final: Borrando archivos empaquetados locales..."
# 6. Borrar los .tar.gz y .sql.gz del VPS, ya que ahora están a salvo en Wasabi
rm -f "${DIR_DESTINO}/${ARCHIVO_WEB}" "${DIR_DESTINO}/${ARCHIVO_SQL}"

echo "¡Backup completado y subido a Wasabi con éxito!
