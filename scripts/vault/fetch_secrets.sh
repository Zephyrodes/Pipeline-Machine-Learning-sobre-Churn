#!/usr/bin/env bash
# =============================================================================
# Obtiene los secretos de un servicio desde Vault usando AppRole y los
# escribe en un directorio tmpfs (/run/mlops-secrets/<servicio>/).
#
# systemd lo invoca como ExecStartPre= antes de arrancar cada servicio.
# El directorio /run/mlops-secrets/ existe solo en memoria — se limpia en
# cada reinicio del sistema (recreado por systemd-tmpfiles vía
# /etc/tmpfiles.d/mlops-secrets.conf, generado por provision_vm.sh).
#
# Uso (llamado por systemd, no manualmente):
#   /usr/local/bin/fetch_secrets.sh <servicio>
#   Servicios válidos: airflow, mlflow, minio, fastapi
# =============================================================================

set -euo pipefail

SERVICE="${1:-}"
VAULT_ADDR="${VAULT_ADDR:-http://127.0.0.1:8200}"
VAULT_KV_PATH="mlops"
SECRETS_BASE_DIR="/run/mlops-secrets"
APPROLE_DIR="/etc/mlops/vault-init"

export VAULT_ADDR

# ──────────────────────────────────────────────
# Validaciones
# ──────────────────────────────────────────────
if [[ -z "$SERVICE" ]]; then
    echo "[fetch_secrets] ERROR: Especifica el servicio. Uso: $0 <servicio>"
    exit 1
fi

VALID_SERVICES=("airflow" "mlflow" "minio" "fastapi")
if [[ ! " ${VALID_SERVICES[*]} " =~ " ${SERVICE} " ]]; then
    echo "[fetch_secrets] ERROR: Servicio desconocido: $SERVICE"
    exit 1
fi

# Mapeo servicio → nombre del AppRole
declare -A ROLE_NAMES=(
    ["airflow"]="mlops-airflow"
    ["mlflow"]="mlops-mlflow"
    ["minio"]="mlops-minio"
    ["fastapi"]="mlops-fastapi"
)
ROLE_NAME="${ROLE_NAMES[$SERVICE]}"
ROLE_ID_FILE="$APPROLE_DIR/$SERVICE/role_id"
SECRET_ID_FILE="$APPROLE_DIR/$SERVICE/secret_id"

if [[ ! -f "$ROLE_ID_FILE" || ! -f "$SECRET_ID_FILE" ]]; then
    echo "[fetch_secrets] ERROR: No se encontraron credenciales AppRole para '$SERVICE'"
    echo "  Esperado: $ROLE_ID_FILE y $SECRET_ID_FILE"
    echo "  Ejecuta setup_vault.sh para generarlos."
    exit 1
fi

# ──────────────────────────────────────────────
# Autenticación AppRole → obtener token de Vault
# ──────────────────────────────────────────────
ROLE_ID=$(cat "$ROLE_ID_FILE")
SECRET_ID=$(cat "$SECRET_ID_FILE")

VAULT_TOKEN=$(vault write -field=token auth/approle/login \
    role_id="$ROLE_ID" \
    secret_id="$SECRET_ID")

export VAULT_TOKEN

# ──────────────────────────────────────────────
# Directorio de secretos en tmpfs (solo memoria)
# El directorio padre /run/mlops-secrets existe gracias a tmpfiles.d
# ──────────────────────────────────────────────
SERVICE_SECRETS_DIR="$SECRETS_BASE_DIR/$SERVICE"
mkdir -p "$SERVICE_SECRETS_DIR"
chmod 700 "$SERVICE_SECRETS_DIR"

# ──────────────────────────────────────────────
# Helpers
# ──────────────────────────────────────────────

# Escribe las credenciales de un path KV en formato KEY=VALUE.
# Usa un archivo temporal + rename atómico para evitar que el servicio
# lea un archivo parcialmente escrito en caso de fallo.
write_env_file() {
    local path="$1"
    local output_file="$SERVICE_SECRETS_DIR/credentials"
    local tmp_file
    tmp_file=$(mktemp "$SERVICE_SECRETS_DIR/.creds.XXXXXX")

    vault kv get -format=json "$path" | python3 -c "
import sys, json
data = json.load(sys.stdin)['data']['data']
for k, v in data.items():
    print(f'{k.upper()}={v}')
" > "$tmp_file"

    chmod 600 "$tmp_file"
    mv "$tmp_file" "$output_file"
}

# Igual que write_env_file pero recibe el contenido ya generado desde stdin.
# FIX: en el original los bloques multi-servicio (mlflow, fastapi) escribían
# con redirección directa al archivo de destino y aplicaban chmod 600 después,
# dejando una ventana en la que otro proceso podía leer el archivo sin permisos.
# Ahora se escribe a un tmp con permisos restrictivos y se renombra atómicamente.
write_env_file_from_stdin() {
    local output_file="$SERVICE_SECRETS_DIR/credentials"
    local tmp_file
    tmp_file=$(mktemp "$SERVICE_SECRETS_DIR/.creds.XXXXXX")
    chmod 600 "$tmp_file"
    cat > "$tmp_file"
    mv "$tmp_file" "$output_file"
}

# ──────────────────────────────────────────────
# Leer secretos de Vault y exportar como archivo.
# El archivo es leído por el servicio via LoadCredential= de systemd
# o mediante source ${SERVICE_SECRETS_FILE} en ExecStart=.
# ──────────────────────────────────────────────
case "$SERVICE" in
    minio)
        write_env_file "${VAULT_KV_PATH}/minio"
        ;;

    mlflow)
        # MLflow necesita sus propias credenciales + las de MinIO para artefactos.
        # FIX: se construye todo el contenido en un subshell y se escribe de forma
        # atómica vía write_env_file_from_stdin (antes el chmod se aplicaba después
        # de la redirección, dejando el archivo legible con permisos incorrectos).
        {
            vault kv get -format=json "${VAULT_KV_PATH}/mlflow" | python3 -c "
import sys, json
data = json.load(sys.stdin)['data']['data']
for k, v in data.items(): print(f'{k.upper()}={v}')
"
            vault kv get -format=json "${VAULT_KV_PATH}/minio" | python3 -c "
import sys, json
d = json.load(sys.stdin)['data']['data']
print(f'AWS_ACCESS_KEY_ID={d[\"root_user\"]}')
print(f'AWS_SECRET_ACCESS_KEY={d[\"root_password\"]}')
print(f'MLFLOW_S3_ENDPOINT_URL={d[\"endpoint\"]}')
"
        } | write_env_file_from_stdin
        ;;

    airflow)
        write_env_file "${VAULT_KV_PATH}/airflow"
        # Renombrar FERNET_KEY → AIRFLOW__CORE__FERNET_KEY para que Airflow
        # lo reconozca directamente al hacer source del archivo de credenciales
        sed -i 's/^FERNET_KEY=/AIRFLOW__CORE__FERNET_KEY=/' \
            "$SERVICE_SECRETS_DIR/credentials"
        ;;

    fastapi)
        {
            vault kv get -format=json "${VAULT_KV_PATH}/fastapi" | python3 -c "
import sys, json
data = json.load(sys.stdin)['data']['data']
for k, v in data.items(): print(f'{k.upper()}={v}')
"
            vault kv get -format=json "${VAULT_KV_PATH}/minio" | python3 -c "
import sys, json
d = json.load(sys.stdin)['data']['data']
print(f'AWS_ACCESS_KEY_ID={d[\"root_user\"]}')
print(f'AWS_SECRET_ACCESS_KEY={d[\"root_password\"]}')
"
        } | write_env_file_from_stdin
        ;;
esac

echo "[fetch_secrets] Secretos de '$SERVICE' disponibles en $SERVICE_SECRETS_DIR/credentials"