#!/usr/bin/env bash
# =============================================================================
# Inicializa DVC y configura el remote apuntando a MinIO.
# Crea los buckets necesarios en MinIO usando el cliente mc.
#
# Las credenciales se obtienen de HashiCorp Vault via AppRole (mismo mecanismo
# que usan los servicios systemd). Vault debe estar inicializado y unsealed.
#
# Prerequisito: scripts/vault/setup_vault.sh y scripts/vault/write_secrets.sh
#               ejecutados previamente.
#
# Uso:
#   chmod +x scripts/setup_dvc.sh
#   ./scripts/setup_dvc.sh
# =============================================================================

set -euo pipefail

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[DVC-SETUP]${NC} $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }

# ──────────────────────────────────────────────
# Obtener credenciales de MinIO desde Vault via AppRole
# ──────────────────────────────────────────────
VAULT_ADDR="${VAULT_ADDR:-http://127.0.0.1:8200}"
VAULT_KV_PATH="mlops"
APPROLE_DIR="/etc/mlops/vault-init/minio"
export VAULT_ADDR

fetch_minio_credentials() {
    log_info "Obteniendo credenciales de MinIO desde Vault..."

    if [[ ! -f "$APPROLE_DIR/role_id" || ! -f "$APPROLE_DIR/secret_id" ]]; then
        log_error "No se encontraron credenciales AppRole para MinIO en $APPROLE_DIR"
        log_error "Ejecuta scripts/vault/setup_vault.sh primero."
        exit 1
    fi

    if ! vault status &>/dev/null; then
        log_error "Vault no está accesible en $VAULT_ADDR — ¿está unsealed?"
        exit 1
    fi

    local role_id secret_id vault_token
    role_id=$(cat "$APPROLE_DIR/role_id")
    secret_id=$(cat "$APPROLE_DIR/secret_id")

    vault_token=$(vault write -field=token auth/approle/login \
        role_id="$role_id" \
        secret_id="$secret_id")

    export VAULT_TOKEN="$vault_token"

    # Leer secretos del path mlops/minio
    MINIO_ROOT_USER=$(vault kv get -field=root_user     "${VAULT_KV_PATH}/minio")
    MINIO_ROOT_PASSWORD=$(vault kv get -field=root_password "${VAULT_KV_PATH}/minio")
    MINIO_ENDPOINT=$(vault kv get -field=endpoint       "${VAULT_KV_PATH}/minio")
    DVC_BUCKET=$(vault kv get     -field=dvc_bucket     "${VAULT_KV_PATH}/minio")
    MLFLOW_BUCKET=$(vault kv get  -field=mlflow_bucket  "${VAULT_KV_PATH}/minio")

    log_info "Credenciales obtenidas desde Vault"
}

MC_BIN="/usr/local/bin/mc"

# ──────────────────────────────────────────────
# 1. Cliente MinIO (mc)
# ──────────────────────────────────────────────
install_mc_client() {
    if command -v mc &>/dev/null; then
        log_info "Cliente mc ya instalado"
        return
    fi
    log_info "Descargando cliente MinIO (mc)..."
    wget -q "https://dl.min.io/client/mc/release/linux-amd64/mc" -O "$MC_BIN"
    chmod +x "$MC_BIN"
    log_info "Cliente mc instalado"
}

# ──────────────────────────────────────────────
# 2. Crear buckets en MinIO
# ──────────────────────────────────────────────
create_minio_buckets() {
    mc alias set local "$MINIO_ENDPOINT" "$MINIO_ROOT_USER" "$MINIO_ROOT_PASSWORD" --quiet

    for bucket in "$DVC_BUCKET" "$MLFLOW_BUCKET"; do
        if mc ls "local/$bucket" &>/dev/null; then
            log_warn "Bucket '$bucket' ya existe"
        else
            mc mb "local/$bucket" --quiet
            log_info "Bucket s3://$bucket creado"
        fi
    done
}

# ──────────────────────────────────────────────
# 3. Inicializar DVC
# ──────────────────────────────────────────────
init_dvc() {
    if ! git rev-parse --is-inside-work-tree &>/dev/null; then
        git init
        git config user.email "zephyrodes@github.com"
        git config user.name  "Zephyrodes"
    fi

    if [ -d ".dvc" ]; then
        log_warn "DVC ya inicializado"
    else
        dvc init
        git add .dvc/ .dvcignore
        git commit -m "chore: inicializar DVC"
    fi
}

# ──────────────────────────────────────────────
# 4. Configurar remote DVC
# .dvc/config  → URL y endpoint (versionado en git, sin credenciales)
# .dvc/config.local → credenciales (excluido de git por .dvc/.gitignore)
# ──────────────────────────────────────────────
configure_dvc_remote() {
    dvc remote add -d minio "s3://$DVC_BUCKET" --force
    dvc remote modify minio endpointurl "$MINIO_ENDPOINT"

    # Las credenciales van solo en config.local — nunca en el config versionado
    dvc remote modify --local minio access_key_id     "$MINIO_ROOT_USER"
    dvc remote modify --local minio secret_access_key "$MINIO_ROOT_PASSWORD"

    git add .dvc/config
    git commit -m "chore: configurar DVC remote MinIO"
    log_info "Remote DVC configurado"
    log_info "  .dvc/config       → versionado en git (sin credenciales)"
    log_info "  .dvc/config.local → excluido de git (credenciales)"
}

# ──────────────────────────────────────────────
# 5. Estructura de directorios de datos
# ──────────────────────────────────────────────
create_data_dirs() {
    mkdir -p data/raw data/processed models

    cat > data/.gitignore << 'GITIGNORE'
/raw/*.csv
/raw/*.parquet
/processed/*.parquet
/processed/*.csv
GITIGNORE

    git add data/ models/
    git commit -m "chore: estructura de directorios del proyecto" || true
    log_info "Directorios de datos creados"
}

# ──────────────────────────────────────────────
# Main
# ──────────────────────────────────────────────
main() {
    fetch_minio_credentials
    install_mc_client
    create_minio_buckets
    init_dvc
    configure_dvc_remote
    create_data_dirs

    echo ""
    log_info "DVC configurado correctamente"
    echo "  Próximos pasos:"
    echo "  1. Coloca tu CSV en data/raw/telco_churn.csv"
    echo "  2. dvc add data/raw/telco_churn.csv"
    echo "  3. dvc push"
}

main "$@"