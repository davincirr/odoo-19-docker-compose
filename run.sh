#!/bin/bash
DESTINATION=$1
PORT=$2
CHAT=$3

# --- VALIDACIÓN DE ARGUMENTOS ---
if [ -z "$DESTINATION" ] || [ -z "$PORT" ] || [ -z "$CHAT" ]; then
    echo "Uso: ./script.sh [nombre_carpeta] [puerto_web] [puerto_chat]"
    echo "Ejemplo: ./script.sh odoo-produccion 10019 20019"
    exit 1
fi

# --- 1. CLONADO Y PREPARACIÓN (Código Original) ---
echo "--- Clonando repositorio en $DESTINATION ---"
git clone --depth=1 https://github.com/minhng92/odoo-19-docker-compose $DESTINATION
rm -rf $DESTINATION/.git

mkdir -p $DESTINATION/postgresql

# Permisos de seguridad
sudo chown -R $USER:$USER $DESTINATION
sudo chmod -R 700 $DESTINATION 

# Configuración de sistema (inotify)
if [[ "$OSTYPE" == "darwin"* ]]; then
  echo "Running on macOS. Skipping inotify configuration."
else
  if grep -qF "fs.inotify.max_user_watches" /etc/sysctl.conf; then
    echo "Configuración inotify detectada."
  else
    echo "fs.inotify.max_user_watches = 524288" | sudo tee -a /etc/sysctl.conf
  fi
  sudo sysctl -p
fi

# Configuración de puertos con sed
if [[ "$OSTYPE" == "darwin"* ]]; then
  sed -i '' 's/10019/'$PORT'/g' $DESTINATION/docker-compose.yml
  sed -i '' 's/20019/'$CHAT'/g' $DESTINATION/docker-compose.yml
else
  sed -i 's/10019/'$PORT'/g' $DESTINATION/docker-compose.yml
  sed -i 's/20019/'$CHAT'/g' $DESTINATION/docker-compose.yml
fi

# Permisos finales de archivos
find $DESTINATION -type f -exec chmod 644 {} \;
find $DESTINATION -type d -exec chmod 755 {} \;
chmod +x $DESTINATION/entrypoint.sh

# --- 2. INICIO DE CONTENEDORES ---
echo "--- Iniciando Contenedores Docker ---"
if ! is_present="$(type -p "docker-compose")" || [[ -z $is_present ]]; then
  docker compose -f $DESTINATION/docker-compose.yml up -d
else
  docker-compose -f $DESTINATION/docker-compose.yml up -d
fi

echo "Esperando 10 segundos para que los servicios arranquen..."
sleep 10

# --- 3. DETECCIÓN INTELIGENTE DE NOMBRES ---
# Esto es vital: detecta cómo llamó Docker a tus contenedores basándose en la carpeta
COMPOSE_FILE="$DESTINATION/docker-compose.yml"
# Detectamos el nombre real del contenedor Odoo y DB
CONTAINER_ODOO=$(docker compose -f $COMPOSE_FILE ps -q odoo)
CONTAINER_DB_NAME=$(docker compose -f $COMPOSE_FILE ps --format '{{.Names}}' db)

# Si falla la detección por comando moderno, intentamos fallback
if [ -z "$CONTAINER_DB_NAME" ]; then
    # Fallback asumiendo nombre estandar si el comando anterior falla
    CONTAINER_DB_NAME="${DESTINATION}-db-1"
fi

echo "Detectado contenedor Odoo ID: $CONTAINER_ODOO"
echo "Detectado host DB: $CONTAINER_DB_NAME"

# --- 4. SOLICITUD DE DATOS AL USUARIO ---
echo " "
echo "=========================================="
echo "   CONFIGURACIÓN DE BASE DE DATOS ODOO"
echo "=========================================="
echo " "

read -p "Ingresa el nombre para la nueva Base de Datos [produccion]: " DB_NAME
DB_NAME=${DB_NAME:-produccion}

read -p "Ingresa la contraseña MAESTRA de la DB (POSTGRES_PASSWORD) definida en el docker-compose: " DB_PASSWORD

if [ -z "$DB_PASSWORD" ]; then
    echo "Error: La contraseña no puede estar vacía."
    exit 1
fi

# --- 5. EJECUCIÓN DEL COMANDO MÁGICO ---
echo " "
echo "--- Ejecutando instalación de módulos (Esto tomará unos minutos) ---"

# Ejecutamos el comando usando las variables detectadas e ingresadas
docker exec -u odoo -it $CONTAINER_ODOO odoo \
    --db_host=$CONTAINER_DB_NAME \
    --db_user=odoo \
    --db_password=$DB_PASSWORD \
    --data-dir=/var/lib/odoo \
    -d $DB_NAME \
    -i sale_management,account,point_of_sale,stock,hr_expense,purchase,l10n_co \
    --stop-after-init

# --- 6. FINALIZACIÓN Y REINICIO ---
if [ $? -eq 0 ]; then
    echo "--- Instalación exitosa. Reiniciando servicio... ---"
    docker restart $CONTAINER_ODOO
    echo " "
    echo "======================================================="
    echo " Odoo Desplegado Exitosamente"
    echo " URL: http://localhost:$PORT"
    echo " Base de Datos: $DB_NAME"
    echo " Usuario Web por defecto: admin / admin"
    echo "======================================================="
else
    echo "!!! Ocurrió un error durante la creación de la base de datos !!!"
    echo "Revisa los logs anteriores."
fi
