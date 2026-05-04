#!/usr/bin/env bash
# =============================================================================
# Obtiene los secretos de un servicio desde Vault usando AppRole y los
# escribe en un directorio tmpfs (/run/mlops-secrets/<servicio>/).
#
# systemd lo invoca como ExecStartPre= antes de arrancar cada servicio.
# El directorio /run/mlops-secrets/ existe solo en memoria — se limpia en
# cada reinicio del sistema.
#
# Uso (llamado por systemd, no manualmente):
#   /usr/local/bin/fetch_secrets.sh <servicio>
#   Servicios válidos: airflow, mlflow, minio, fastapi
# =============================================================================

set -euo pipefail

SERVICE="${1:-}"
VAULT_ADDR="http://127.0.0.1:8200"
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
# ──────────────────────────────────────────────
SERVICE_SECRETS_DIR="$SECRETS_BASE_DIR/$SERVICE"
mkdir -p "$SERVICE_SECRETS_DIR"
chmod 700 "$SERVICE_SECRETS_DIR"

# ──────────────────────────────────────────────
# Leer secretos de Vault y exportar como archivo
# El archivo es leído por el servicio via LoadCredential= de systemd
# ──────────────────────────────────────────────
write_env_file() {
    local path="$1"
    local output_file="$SERVICE_SECRETS_DIR/credentials"
    local secret_json

    secret_json=$(vault kv get -format=json "$path" | python3 -c "
import sys, json
data = json.load(sys.stdin)['data']['data']
for k, v in data.items():
    print(f'{k.upper()}={v}')
")

    echo "$secret_json" > "$output_file"
    chmod 600 "$output_file"
}

# Cada servicio lee su propio path + los de las dependencias que necesita
case "$SERVICE" in
    minio)
        write_env_file "${VAULT_KV_PATH}/minio"
        ;;
    mlflow)
        # MLflow necesita las credenciales de MinIO para acceder a los artefactos
        {
            vault kv get -format=json "${VAULT_KV_PATH}/mlflow" | python3 -c "
import sys, json
data = json.load(sys.stdin)['data']['data']
for k, v in data.items(): print(f'{k.upper()}={v}')
"
            vault kv get -format=json "${VAULT_KV_PATH}/minio" | python3 -c "
import sys, json
data = json.load(sys.stdin)['data']['data']
# Solo las claves de acceso, no todo el bloque de minio
d = data
print(f'AWS_ACCESS_KEY_ID={d[\"root_user\"]}')
print(f'AWS_SECRET_ACCESS_KEY={d[\"root_password\"]}')
print(f'MLFLOW_S3_ENDPOINT_URL={d[\"endpoint\"]}')
"
        } > "$SERVICE_SECRETS_DIR/credentials"
        chmod 600 "$SERVICE_SECRETS_DIR/credentials"
        ;;
    airflow)
        write_env_file "${VAULT_KV_PATH}/airflow"
        # Agregar AIRFLOW__CORE__FERNET_KEY desde el campo fernet_key
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
data = json.load(sys.stdin)['data']['data']
print(f'AWS_ACCESS_KEY_ID={data[\"root_user\"]}')
print(f'AWS_SECRET_ACCESS_KEY={data[\"root_password\"]}')
"
        } > "$SERVICE_SECRETS_DIR/credentials"
        chmod 600 "$SERVICE_SECRETS_DIR/credentials"
        ;;
esac

echo "[fetch_secrets] Secretos de '$SERVICE' disponibles en $SERVICE_SECRETS_DIR/credentials"