#!/usr/bin/env bash
# =============================================================================
# Escribe los secretos del pipeline en el motor KV v2 de Vault.
# Se ejecuta una sola vez tras setup_vault.sh, o al rotar credenciales.
#
# Lee las variables desde .env si existe; de lo contrario las solicita
# de forma interactiva (sin exponerlas en argumentos de línea de comandos).
#
# Uso:
#   sudo VAULT_TOKEN=<token> ./scripts/vault/write_secrets.sh
#
# Obtener el root token:
#   python3 -c "import json; print(json.load(open('/etc/mlops/vault-init/init.json'))['root_token'])"
# =============================================================================

set -euo pipefail

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'
log_info()  { echo -e "${GREEN}[VAULT-WRITE]${NC} $*"; }
log_warn()  { echo -e "${YELLOW}[VAULT-WRITE]${NC} $*"; }
log_error() { echo -e "${RED}[VAULT-WRITE]${NC} $*"; }

VAULT_ADDR="${VAULT_ADDR:-http://127.0.0.1:8200}"
VAULT_KV_PATH="mlops"
export VAULT_ADDR

# ──────────────────────────────────────────────
# Validaciones
# ──────────────────────────────────────────────
if [[ -z "${VAULT_TOKEN:-}" ]]; then
    log_error "VAULT_TOKEN no está definido."
    log_error "Ejemplo:"
    log_error "  sudo VAULT_TOKEN=\$(python3 -c \"import json; print(json.load(open('/etc/mlops/vault-init/init.json'))['root_token'])\") \\"
    log_error "  ./scripts/vault/write_secrets.sh"
    exit 1
fi

if ! vault status &>/dev/null; then
    log_error "Vault no está accesible en $VAULT_ADDR"
    exit 1
fi

# ──────────────────────────────────────────────
# Cargar variables desde .env si existe
# De lo contrario, solicitarlas de forma interactiva
# ──────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/../../.env"

if [[ -f "$ENV_FILE" ]]; then
    log_info "Cargando variables desde .env..."
    set -o allexport
    # shellcheck source=/dev/null
    source "$ENV_FILE"
    set +o allexport
else
    log_warn "No se encontró .env — se solicitarán las variables de forma interactiva."
fi

prompt_secret() {
    local var_name="$1"
    local prompt_text="$2"
    if [[ -z "${!var_name:-}" ]]; then
        read -rsp "$prompt_text: " value
        echo ""
        printf -v "$var_name" '%s' "$value"
    fi
}

prompt_secret MINIO_ROOT_USER        "MinIO usuario"
prompt_secret MINIO_ROOT_PASSWORD    "MinIO contraseña"
prompt_secret AIRFLOW_ADMIN_USER     "Airflow usuario"
prompt_secret AIRFLOW_ADMIN_PASSWORD "Airflow contraseña"
prompt_secret AIRFLOW_ADMIN_EMAIL    "Airflow email"
prompt_secret AIRFLOW_FERNET_KEY     "Airflow Fernet key"

# ──────────────────────────────────────────────
# Escritura en Vault KV v2
# ──────────────────────────────────────────────
log_info "Escribiendo secretos en Vault KV v2..."

vault kv put "${VAULT_KV_PATH}/minio" \
    root_user="${MINIO_ROOT_USER}" \
    root_password="${MINIO_ROOT_PASSWORD}" \
    endpoint="${MINIO_ENDPOINT:-http://127.0.0.1:9000}" \
    dvc_bucket="${MINIO_DVC_BUCKET:-dvc-data}" \
    mlflow_bucket="${MINIO_MLFLOW_BUCKET:-mlflow-artifacts}"
log_info "mlops/minio escrito"

vault kv put "${VAULT_KV_PATH}/airflow" \
    admin_user="${AIRFLOW_ADMIN_USER}" \
    admin_password="${AIRFLOW_ADMIN_PASSWORD}" \
    admin_email="${AIRFLOW_ADMIN_EMAIL}" \
    fernet_key="${AIRFLOW_FERNET_KEY}" \
    home="${AIRFLOW_HOME:-/opt/airflow}"
log_info "mlops/airflow escrito"

vault kv put "${VAULT_KV_PATH}/mlflow" \
    tracking_uri="${MLFLOW_TRACKING_URI:-http://127.0.0.1:5000}" \
    artifact_bucket="${MLFLOW_ARTIFACT_BUCKET:-mlflow-artifacts}" \
    s3_endpoint_url="${MINIO_ENDPOINT:-http://127.0.0.1:9000}"
log_info "mlops/mlflow escrito"

vault kv put "${VAULT_KV_PATH}/fastapi" \
    mlflow_tracking_uri="${MLFLOW_TRACKING_URI:-http://127.0.0.1:5000}" \
    mlflow_model_name="${MLFLOW_MODEL_NAME:-churn-predictor}" \
    mlflow_model_alias="${MLFLOW_MODEL_ALIAS:-Production}" \
    fastapi_port="${FASTAPI_PORT:-8000}"
log_info "mlops/fastapi escrito"

echo ""
log_info "Todos los secretos escritos correctamente en Vault."
log_info "Verificar con: vault kv get ${VAULT_KV_PATH}/minio"