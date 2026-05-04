#!/usr/bin/env bash
# =============================================================================
# provision_vm.sh
# Aprovisiona la VM e instala todos los servicios del pipeline MLOps.
#
# Gestión de secretos:
#   Los secretos residen en HashiCorp Vault. Cada servicio systemd ejecuta
#   fetch_secrets.sh como ExecStartPre=, que autentica con AppRole, obtiene
#   las credenciales de Vault y las escribe en /run/mlops-secrets/<servicio>/
#   (tmpfs — solo memoria, se limpia en cada reinicio).
#   LoadCredential= los entrega al proceso sin exponerlos en el entorno.
#
# Paso 1 del despliegue — ejecutar antes que setup_vault.sh.
#
# Uso:
#   sudo ./scripts/provision_vm.sh
# =============================================================================

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info()    { echo -e "${GREEN}[INFO]${NC}  $*"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $*"; }
log_section() { echo -e "\n${BLUE}════════════════════════════════════════${NC}"; \
                echo -e "${BLUE} $*${NC}"; \
                echo -e "${BLUE}════════════════════════════════════════${NC}"; }

check_root() {
    [[ "$EUID" -eq 0 ]] || { log_error "Ejecutar como root (sudo)"; exit 1; }
}

# ──────────────────────────────────────────────
# Variables de configuración (no sensibles)
# ──────────────────────────────────────────────
PYTHON_VERSION="3.12"
AIRFLOW_VERSION="2.9.3"
AIRFLOW_HOME="${AIRFLOW_HOME:-/opt/airflow}"
MLFLOW_HOME="/opt/mlflow"
MINIO_HOME="/opt/minio"
FASTAPI_APP_DIR="/opt/mlops_api"
MLOPS_USER="${MLOPS_USER:-mlops}"
MLOPS_GROUP="${MLOPS_USER:-mlops}"
VENV_PATH="${VENV_PATH:-/opt/mlops_venv}"

PORT_AIRFLOW_WEBSERVER=8080
PORT_MLFLOW_UI=5000
PORT_MINIO_API=9000
PORT_MINIO_CONSOLE=9001
PORT_FASTAPI="${FASTAPI_PORT:-8000}"

SECRETS_BASE="/run/mlops-secrets"   # tmpfs — limpiado en cada reinicio

# ──────────────────────────────────────────────
# Detectar si systemd está disponible
# En contenedores systemd no corre — se usa
# arranque directo de procesos como fallback
# ──────────────────────────────────────────────
SYSTEMD_AVAILABLE=false
if systemctl is-system-running &>/dev/null 2>&1; then
    SYSTEMD_AVAILABLE=true
fi

register_service() {
    # Solo registra y habilita el servicio en systemd.
    # NO lo arranca — el arranque ocurre en el paso 5,
    # después de que Vault esté inicializado y los secretos escritos.
    local unit="$1"
    systemctl daemon-reload
    systemctl enable "$unit"
    log_info "Servicio $unit registrado (pendiente de arranque)"
}


# ──────────────────────────────────────────────
# fetch_secrets.sh — script que cada servicio
# invoca como ExecStartPre= para obtener sus
# credenciales de Vault antes de arrancar
# ──────────────────────────────────────────────
install_fetch_secrets() {
    log_info "Instalando fetch_secrets.sh en /usr/local/bin..."
    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    cp "$script_dir/vault/fetch_secrets.sh" /usr/local/bin/fetch_secrets.sh
    chmod 755 /usr/local/bin/fetch_secrets.sh
    log_info "fetch_secrets.sh instalado"
}

# ──────────────────────────────────────────────
# Paquetes base del sistema
# ──────────────────────────────────────────────
detect_os() {
    [ -f /etc/os-release ] && . /etc/os-release \
        && log_info "Sistema operativo: $ID $VERSION_ID"
}

install_base_packages() {
    log_section "Instalando paquetes base"
    apt-get update -y
    apt-get install -y \
        python3.12 python3.12-venv python3.12-dev python3-pip \
        build-essential libssl-dev libffi-dev libpq-dev \
        git curl wget unzip jq htop net-tools ufw systemd
}

create_mlops_user() {
    log_section "Creando usuario del sistema: $MLOPS_USER"
    getent group  "$MLOPS_GROUP" &>/dev/null || groupadd  --system "$MLOPS_GROUP"
    id "$MLOPS_USER" &>/dev/null || \
        useradd --system --gid "$MLOPS_GROUP" \
                --home-dir /opt/mlops --create-home \
                --shell /bin/bash "$MLOPS_USER"
}

setup_python_virtualenv() {
    log_section "Configurando entorno virtual Python"
    python3.12 -m venv "$VENV_PATH"
    # shellcheck source=/dev/null
    source "$VENV_PATH/bin/activate"
    pip install --upgrade pip setuptools wheel
}

# ──────────────────────────────────────────────
# MinIO
# ──────────────────────────────────────────────
install_minio() {
    log_section "Instalando MinIO"
    mkdir -p "$MINIO_HOME/data"
    wget -q "https://dl.min.io/server/minio/release/linux-amd64/minio" \
        -O /usr/local/bin/minio
    chmod +x /usr/local/bin/minio
    chown -R "$MLOPS_USER:$MLOPS_GROUP" "$MINIO_HOME"

    cat > /etc/systemd/system/minio.service << EOF
[Unit]
Description=MinIO Object Storage
After=network-online.target vault-unseal.service

[Service]
# fetch_secrets.sh autentica con Vault via AppRole y escribe las credenciales
# en ${SECRETS_BASE}/minio/credentials (tmpfs). LoadCredential= las entrega
# al proceso sin exponerlas en variables de entorno visibles.
ExecStartPre=/usr/local/bin/fetch_secrets.sh minio
LoadCredential=credentials:${SECRETS_BASE}/minio/credentials
ExecStart=/bin/bash -c '\
    source \${CREDENTIALS_DIR}/credentials && \
    MINIO_ROOT_USER=\${ROOT_USER} \
    MINIO_ROOT_PASSWORD=\${ROOT_PASSWORD} \
    /usr/local/bin/minio server \
        --console-address :${PORT_MINIO_CONSOLE} \
        ${MINIO_HOME}/data'
User=${MLOPS_USER}
Group=${MLOPS_GROUP}
Restart=always
RestartSec=5s
StandardOutput=journal
StandardError=journal
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF

    register_service minio
    log_info "MinIO configurado"
}

# ──────────────────────────────────────────────
# MLflow
# ──────────────────────────────────────────────
install_mlflow() {
    log_section "Instalando MLflow Tracking Server"
    source "$VENV_PATH/bin/activate"
    pip install mlflow[extras]==2.15.1

    mkdir -p "$MLFLOW_HOME/artifacts" "$MLFLOW_HOME/db"
    chown -R "$MLOPS_USER:$MLOPS_GROUP" "$MLFLOW_HOME"

    cat > /etc/systemd/system/mlflow-server.service << EOF
[Unit]
Description=MLflow Tracking Server
After=network.target minio.service vault-unseal.service

[Service]
ExecStartPre=/usr/local/bin/fetch_secrets.sh mlflow
LoadCredential=credentials:${SECRETS_BASE}/mlflow/credentials
Environment=PATH=${VENV_PATH}/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin
ExecStart=/bin/bash -c '\
    source \${CREDENTIALS_DIR}/credentials && \
    ${VENV_PATH}/bin/mlflow server \
        --backend-store-uri sqlite://${MLFLOW_HOME}/db/mlflow.db \
        --default-artifact-root s3://\${ARTIFACT_BUCKET:-mlflow-artifacts}/ \
        --host 0.0.0.0 --port ${PORT_MLFLOW_UI}'
User=${MLOPS_USER}
Group=${MLOPS_GROUP}
Restart=on-failure
RestartSec=5s
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

    register_service mlflow-server
    log_info "MLflow configurado"
}

# ──────────────────────────────────────────────
# Airflow
# ──────────────────────────────────────────────
install_airflow() {
    log_section "Instalando Apache Airflow $AIRFLOW_VERSION"
    source "$VENV_PATH/bin/activate"
    export AIRFLOW_HOME="$AIRFLOW_HOME"

    CONSTRAINT_URL="https://raw.githubusercontent.com/apache/airflow/constraints-${AIRFLOW_VERSION}/constraints-${PYTHON_VERSION}.txt"
    pip install "apache-airflow==${AIRFLOW_VERSION}" --constraint "$CONSTRAINT_URL"

    airflow db migrate
    mkdir -p "$AIRFLOW_HOME/dags"
    chown -R "$MLOPS_USER:$MLOPS_GROUP" "$AIRFLOW_HOME"
    log_info "Airflow instalado"
    create_airflow_systemd_services
}

create_airflow_systemd_services() {
    cat > /etc/systemd/system/airflow-webserver.service << EOF
[Unit]
Description=Apache Airflow Webserver
After=network.target vault-unseal.service

[Service]
ExecStartPre=/usr/local/bin/fetch_secrets.sh airflow
LoadCredential=credentials:${SECRETS_BASE}/airflow/credentials
Environment=AIRFLOW_HOME=${AIRFLOW_HOME}
Environment=PATH=${VENV_PATH}/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin
ExecStart=/bin/bash -c '\
    source \${CREDENTIALS_DIR}/credentials && \
    ${VENV_PATH}/bin/airflow webserver --port ${PORT_AIRFLOW_WEBSERVER}'
User=${MLOPS_USER}
Group=${MLOPS_GROUP}
Restart=on-failure
RestartSec=5s
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

    cat > /etc/systemd/system/airflow-scheduler.service << EOF
[Unit]
Description=Apache Airflow Scheduler
After=network.target vault-unseal.service

[Service]
ExecStartPre=/usr/local/bin/fetch_secrets.sh airflow
LoadCredential=credentials:${SECRETS_BASE}/airflow/credentials
Environment=AIRFLOW_HOME=${AIRFLOW_HOME}
Environment=PATH=${VENV_PATH}/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin
ExecStart=/bin/bash -c '\
    source \${CREDENTIALS_DIR}/credentials && \
    ${VENV_PATH}/bin/airflow scheduler'
User=${MLOPS_USER}
Group=${MLOPS_GROUP}
Restart=on-failure
RestartSec=5s
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

    register_service airflow-webserver
    register_service airflow-scheduler
}

# ──────────────────────────────────────────────
# FastAPI
# ──────────────────────────────────────────────
setup_fastapi_service() {
    log_section "Configurando servicio FastAPI"
    mkdir -p "$FASTAPI_APP_DIR"
    chown -R "$MLOPS_USER:$MLOPS_GROUP" "$FASTAPI_APP_DIR"

    cat > /etc/systemd/system/mlops-api.service << EOF
[Unit]
Description=MLOps Churn Prediction API (FastAPI)
After=network.target mlflow-server.service vault-unseal.service

[Service]
ExecStartPre=/usr/local/bin/fetch_secrets.sh fastapi
LoadCredential=credentials:${SECRETS_BASE}/fastapi/credentials
Environment=PATH=${VENV_PATH}/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin
ExecStart=/bin/bash -c '\
    source \${CREDENTIALS_DIR}/credentials && \
    ${VENV_PATH}/bin/uvicorn app:app --host 0.0.0.0 --port ${PORT_FASTAPI}'
User=${MLOPS_USER}
Group=${MLOPS_GROUP}
WorkingDirectory=${FASTAPI_APP_DIR}
Restart=on-failure
RestartSec=5s
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

    register_service mlops-api
    log_info "FastAPI configurado"
}

# ──────────────────────────────────────────────
# Dependencias ML
# ──────────────────────────────────────────────
install_ml_dependencies() {
    log_section "Instalando dependencias ML"
    source "$VENV_PATH/bin/activate"
    pip install \
        dvc[s3]==3.51.2 scikit-learn==1.5.1 pandas==2.2.2 numpy==1.26.4 \
        fastapi==0.112.0 uvicorn[standard]==0.30.5 pydantic==2.8.2 \
        boto3==1.35.0 pyarrow==17.0.0 joblib==1.4.2 matplotlib==3.9.2 \
        python-multipart==0.0.9
}

# ──────────────────────────────────────────────
# Firewall y arranque
# ──────────────────────────────────────────────
configure_firewall() {
    log_section "Configurando firewall UFW"
    ufw allow ssh
    ufw allow "$PORT_AIRFLOW_WEBSERVER/tcp" comment "Airflow"
    ufw allow "$PORT_MLFLOW_UI/tcp"         comment "MLflow"
    ufw allow "$PORT_MINIO_API/tcp"         comment "MinIO API"
    ufw allow "$PORT_MINIO_CONSOLE/tcp"     comment "MinIO Console"
    ufw allow "$PORT_FASTAPI/tcp"           comment "FastAPI"
    ufw allow 8200/tcp                      comment "Vault (solo loopback en producción)"
    ufw --force enable
}

start_all_services() {
    log_section "Iniciando servicios base"
    # Vault NO se arranca aquí — es responsabilidad de setup_vault.sh,
    # que lo instala, inicializa y hace el unseal por primera vez.
    # Los servicios del pipeline (minio, mlflow, airflow, fastapi) arrancan
    # después de setup_vault.sh, cuando Vault ya está listo para servir secretos.
    log_info "Servicios registrados en systemd."
    log_info "Siguiente paso: sudo ./scripts/vault/setup_vault.sh"
}

print_summary() {
    VM_IP=$(hostname -I | awk '{print $1}')
    log_section "Aprovisionamiento completo"
    echo ""
    echo -e "  Servicios registrados (arrancan después de Vault):"
    echo -e "  ${GREEN}Airflow:${NC}       http://$VM_IP:$PORT_AIRFLOW_WEBSERVER"
    echo -e "  ${GREEN}MLflow:${NC}        http://$VM_IP:$PORT_MLFLOW_UI"
    echo -e "  ${GREEN}MinIO:${NC}         http://$VM_IP:$PORT_MINIO_CONSOLE"
    echo -e "  ${GREEN}FastAPI:${NC}       http://$VM_IP:$PORT_FASTAPI/docs"
    echo -e "  ${GREEN}Vault:${NC}         http://127.0.0.1:8200 (solo loopback)"
    echo ""
    echo -e "  Orden de pasos siguientes:"
    echo -e "  1. sudo ./scripts/vault/setup_vault.sh"
    echo -e "  2. sudo VAULT_TOKEN=<token> ./scripts/vault/write_secrets.sh"
    echo -e "  3. systemctl start minio mlflow-server airflow-webserver airflow-scheduler mlops-api"
}

# ──────────────────────────────────────────────
# Main
# ──────────────────────────────────────────────
main() {
    check_root
    detect_os
    install_fetch_secrets
    install_base_packages
    create_mlops_user
    setup_python_virtualenv
    install_minio
    install_mlflow
    install_airflow
    install_ml_dependencies
    setup_fastapi_service
    configure_firewall
    start_all_services
    print_summary
}

main "$@"