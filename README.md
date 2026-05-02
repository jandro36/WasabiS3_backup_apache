# WasabiS3_backup_apache
Script de Bash para realizar backups automáticos de archivos web (/var/www) y bases de datos MySQL, subiéndolos directamente a un bucket de Wasabi S3. Los archivos locales se eliminan tras la subida para no consumir espacio en el VPS.


✨ Características
Snapshot seguro: Clona /var/www antes de comprimir para no bloquear el servidor web.

Excluye basura: Ignora logs, cachés de WordPress, .git y node_modules.

Exportación MySQL completa: Usa --single-transaction para consistencia sin bloquear tablas.

Retención automática: Elimina backups de Wasabi con más de N días (configurable).

Robusto ante errores: set -euo pipefail + trap garantizan limpieza aunque el script falle.

Logs con timestamp: Cada paso queda registrado con hora exacta.

Sin rastro local: Los .tar.gz y .sql.gz se borran del VPS tras subirse.

📋 Requisitos
Herramienta	Versión mínima	Instalación
bash	4.0+	Pre-instalado en Linux
aws CLI	v2	Guía oficial
mysqldump	cualquiera	apt install mysql-client
tar, gzip	cualquiera	Pre-instalado en Linux
⚙️ Configuración paso a paso
1. Clonar el repositorio
bash
git clone https://github.com/TU_USUARIO/backup-wasabi.git /opt/scripts/backup-wasabi
cd /opt/scripts/backup-wasabi
chmod +x backup_wasabi.sh
2. Configurar AWS CLI para Wasabi
Crea el fichero ~/.aws/credentials con un perfil específico para Wasabi:

text
[wasabi]
aws_access_key_id     = TU_ACCESS_KEY_ID
aws_secret_access_key = TU_SECRET_ACCESS_KEY
Y ~/.aws/config:

text
[profile wasabi]
region = eu-south-1
💡 Genera tus claves en la consola de Wasabi → Access Keys.

Verifica el acceso:

bash
aws s3 ls s3://TU-BUCKET/ --endpoint-url=https://s3.eu-south-1.wasabisys.com --profile wasabi
3. Configurar credenciales de MySQL (seguro)
Opción A — Recomendada: fichero .my.cnf

bash
cat > ~/.my.cnf << 'EOF'
[client]
user=backup_user
password=TU_PASSWORD_AQUI
EOF
chmod 600 ~/.my.cnf
Luego en el script, cambia la línea de mysqldump a:

bash
mysqldump --all-databases --single-transaction ...
(sin -u ni -p, los toma de .my.cnf automáticamente).

Opción B — Variables de entorno

bash
export DB_USER="backup_user"
export DB_PASS="TU_PASSWORD"
./backup_wasabi.sh
4. Ajustar variables en el script
Edita la sección CONFIGURACIÓN al inicio del script:

bash
DIR_ORIGEN="/var/www"           # Directorio web a respaldar
BUCKET_WASABI="mi-bucket"       # Nombre de tu bucket en Wasabi
WASABI_ENDPOINT="https://s3.eu-south-1.wasabisys.com"  # Endpoint de tu región
PERFIL_AWS="wasabi"             # Nombre del perfil en ~/.aws/credentials
RETENTION_DAYS=30               # Días de retención (0 = nunca borrar)
🌍 Regiones disponibles de Wasabi: us-east-1, us-east-2, us-west-1, eu-central-1, eu-west-1, eu-west-2, eu-south-1, ap-northeast-1, ap-northeast-2, ap-southeast-1

5. Probar manualmente
bash
./backup_wasabi.sh
La salida esperada:

text
[2025-06-15 02:00:01] ======================================================
[2025-06-15 02:00:01] Iniciando proceso de backup — 2025-06-15_02-00-01
[2025-06-15 02:00:01] ======================================================
[2025-06-15 02:00:01] 1/4: Creando snapshot seguro de los archivos web...
[2025-06-15 02:00:05] 2/4: Comprimiendo archivos web (excluyendo logs y caché)...
[2025-06-15 02:00:12]    Tamaño del backup web: 245M
[2025-06-15 02:00:12] 3/4: Exportando todas las bases de datos MySQL...
[2025-06-15 02:00:18]    Tamaño del backup SQL: 38M
[2025-06-15 02:00:18] 4/4: Subiendo backups a Wasabi S3...
[2025-06-15 02:00:45] ✅ Backup completado con éxito.
[2025-06-15 02:00:45]    Web  → s3://mi-bucket/backup_www_2025-06-15.tar.gz (245M)
[2025-06-15 02:00:45]    SQL  → s3://mi-bucket/backup_db_2025-06-15.sql.gz (38M)
6. Automatizar con cron
bash
crontab -e
Añade una línea para ejecutar el backup todos los días a las 2:00 AM:

text
0 2 * * * /opt/scripts/backup-wasabi/backup_wasabi.sh >> /var/log/backup_wasabi.log 2>&1
📁 Estructura del repositorio
text
backup-wasabi/
├── backup_wasabi.sh    # Script principal
└── README.md           # Esta guía
🔒 Consideraciones de seguridad
Nunca hardcodees contraseñas directamente en el script. Usa .my.cnf o variables de entorno.

Asigna permisos restrictivos al script: chmod 700 backup_wasabi.sh

Crea un usuario MySQL dedicado solo para backups con permisos mínimos:

sql
CREATE USER 'backup'@'localhost' IDENTIFIED BY 'password';
GRANT SELECT, LOCK TABLES, SHOW VIEW, EVENT, TRIGGER ON *.* TO 'backup'@'localhost';
FLUSH PRIVILEGES;
Considera cifrar los backups antes de subir a Wasabi: gpg --symmetric archivo.tar.gz

🐛 Solución de problemas
Error	Causa probable	Solución
No se puede acceder al bucket	Credenciales o endpoint incorrecto	Verifica ~/.aws/credentials y la región
Fallo al exportar las bases de datos	Contraseña MySQL incorrecta	Usa .my.cnf o comprueba DB_PASS
Comando 'aws' no encontrado	AWS CLI no instalado	Sigue la guía oficial
Script no termina	Disco /tmp lleno	Libera espacio o cambia DIR_DESTINO a otro disco
