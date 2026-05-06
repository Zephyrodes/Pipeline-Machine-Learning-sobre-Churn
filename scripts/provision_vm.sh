#!/usr/bin/env bash
# =============================================================================
# Aprovisiona la VM e instala todos los servicios del pipeline MLOps.
#
# Cada paso verifica si ya está hecho antes de ejecutarse.
# Es seguro volver a correr este script en una VM ya aprovisionada.
#
# Gestión de secretos:
#   Los secretos residen en HashiCorp Vault. Cada servicio systemd ejecuta
#   fetch_secrets.sh como ExecStartPre=, que autentica con AppRole, obtiene
#   las credenciales de Vault y las escribe en /run/mlops-secrets/<servicio>/
#   (tmpfs — solo memoria, se limpia en cada reinicio).
#
# Paso 1 del despliegue — ejecutar antes que setup_vault.sh.
#
# Uso:
#   sudo ./scripts/provision_vm.sh
#   sudo ./scripts/provision_vm.sh --only-units   # solo regenera los unit files
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
log_skip()    { echo -e "${YELLOW}[SKIP]${NC}  $*"; }
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

SYSTEMD_AVAILABLE=false
if systemctl is-system-running &>/dev/null 2>&1; then
    SYSTEMD_AVAILABLE=true
fi

# Registra y habilita el servicio. Si el unit ya existía y cambió,
# fuerza daemon-reload. NO arranca el servicio.
register_service() {
    local unit="$1"
    systemctl daemon-reload
    systemctl enable "$unit"
    log_info "Servicio $unit registrado (pendiente de arranque)"
}

# ──────────────────────────────────────────────
# fetch_secrets.sh
# ──────────────────────────────────────────────
install_fetch_secrets() {
    local dest="/usr/local/bin/fetch_secrets.sh"
    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local src="$script_dir/vault/fetch_secrets.sh"

    # Solo instala si el origen es diferente al destino (o no existe el destino)
    if [[ -f "$dest" ]] && cmp -s "$src" "$dest"; then
        log_skip "fetch_secrets.sh ya está actualizado"
        return
    fi

    log_info "Instalando fetch_secrets.sh en /usr/local/bin..."
    cp "$src" "$dest"
    chmod 755 "$dest"
    log_info "fetch_secrets.sh instalado"
}

# ──────────────────────────────────────────────
# tmpfiles.d
# ──────────────────────────────────────────────
setup_tmpfiles() {
    log_section "Configurando tmpfiles.d para /run/mlops-secrets"

    local conf="/etc/tmpfiles.d/mlops-secrets.conf"
    local desired
    desired="$(cat << EOF
# /run/mlops-secrets — directorio en tmpfs para credenciales efímeras de los
# servicios MLOps. Se recrean en cada arranque; nunca tocan disco persistente.
# Propietario mlops:mlops para que ExecStartPre= (usuario mlops) pueda
# crear los subdirectorios sin necesitar root.
d ${SECRETS_BASE} 0700 ${MLOPS_USER} ${MLOPS_GROUP} -
EOF
)"

    if [[ -f "$conf" ]] && [[ "$(cat "$conf")" == "$desired" ]]; then
        log_skip "tmpfiles.d ya configurado"
    else
        echo "$desired" > "$conf"
        log_info "tmpfiles.d escrito"
    fi

    # Crear el directorio en el tmpfs actual si aún no existe
    if [[ ! -d "$SECRETS_BASE" ]]; then
        systemd-tmpfiles --create "$conf"
        log_info "tmpfiles.d aplicado → ${SECRETS_BASE} (propietario: ${MLOPS_USER})"
    else
        log_skip "${SECRETS_BASE} ya existe"
    fi
}

# ──────────────────────────────────────────────
# Paquetes base
# ──────────────────────────────────────────────
detect_os() {
    [[ -f /etc/os-release ]] && . /etc/os-release \
        && log_info "Sistema operativo: $ID $VERSION_ID"
}

install_base_packages() {
    log_section "Instalando paquetes base"

    local packages=(
        python3.12 python3.12-venv python3.12-dev python3-pip
        build-essential libssl-dev libffi-dev libpq-dev
        git curl wget unzip jq htop net-tools ufw systemd
    )

    local missing=()
    for pkg in "${packages[@]}"; do
        dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q "install ok installed" \
            || missing+=("$pkg")
    done

    if [[ ${#missing[@]} -eq 0 ]]; then
        log_skip "Todos los paquetes base ya están instalados"
        return
    fi

    log_info "Paquetes faltantes: ${missing[*]}"
    apt-get update -y
    apt-get install -y "${missing[@]}"
}

# ──────────────────────────────────────────────
# Usuario del sistema
# ──────────────────────────────────────────────
create_mlops_user() {
    log_section "Creando usuario del sistema: $MLOPS_USER"

    if getent group "$MLOPS_GROUP" &>/dev/null; then
        log_skip "Grupo $MLOPS_GROUP ya existe"
    else
        groupadd --system "$MLOPS_GROUP"
        log_info "Grupo $MLOPS_GROUP creado"
    fi

    if id "$MLOPS_USER" &>/dev/null; then
        log_skip "Usuario $MLOPS_USER ya existe"
    else
        useradd --system --gid "$MLOPS_GROUP" \
                --home-dir /opt/mlops --create-home \
                --shell /bin/bash "$MLOPS_USER"
        log_info "Usuario $MLOPS_USER creado"
    fi
}

# ──────────────────────────────────────────────
# Entorno virtual Python
# ──────────────────────────────────────────────
setup_python_virtualenv() {
    log_section "Configurando entorno virtual Python"

    if [[ -f "$VENV_PATH/bin/activate" ]]; then
        log_skip "Entorno virtual ya existe en $VENV_PATH"
        # shellcheck source=/dev/null
        source "$VENV_PATH/bin/activate"
        return
    fi

    python3.12 -m venv "$VENV_PATH"
    # shellcheck source=/dev/null
    source "$VENV_PATH/bin/activate"
    pip install --upgrade pip setuptools wheel
    log_info "Entorno virtual creado en $VENV_PATH"
}

# ──────────────────────────────────────────────
# MinIO
# ──────────────────────────────────────────────

# Escribe el unit file solo si ha cambiado; devuelve 0 si se escribió,
# 1 si ya estaba igual (para que register_service sepa si debe
# reiniciar el daemon o no).
_write_unit_if_changed() {
    local path="$1"
    local content="$2"
    local name
    name="$(basename "$path")"

    if [[ -f "$path" ]] && [[ "$(cat "$path")" == "$content" ]]; then
        log_skip "Unit $name sin cambios"
        return 1
    fi

    echo "$content" > "$path"
    log_info "Unit $name escrito/actualizado"
    return 0
}

install_minio() {
    log_section "Instalando MinIO"

    mkdir -p "$MINIO_HOME/data"

    # Solo descarga el binario si no existe (o si está corrupto)
    if [[ ! -x /usr/local/bin/minio ]]; then
        log_info "Descargando binario de MinIO..."
        wget -q "https://dl.min.io/server/minio/release/linux-amd64/minio" \
            -O /usr/local/bin/minio
        chmod +x /usr/local/bin/minio
        log_info "Binario de MinIO instalado"
    else
        log_skip "Binario de MinIO ya existe"
    fi

    chown -R "$MLOPS_USER:$MLOPS_GROUP" "$MINIO_HOME"

    # El unit usa EnvironmentFile= en lugar de `source` dentro de ExecStart.
    #
    # Problema resuelto: systemd expande ${VAR} en ExecStart= desde su propio
    # entorno ANTES de invocar el shell. Como ROOT_USER/ROOT_PASSWORD no estaban
    # en el entorno del servicio, systemd los expandia a vacio y MinIO arrancaba
    # con las credenciales por defecto minioadmin:minioadmin.
    #
    # Solucion: EnvironmentFile= carga el archivo de credenciales que escribio
    # fetch_secrets.sh directamente en el entorno del proceso. MinIO recibe
    # MINIO_ROOT_USER y MINIO_ROOT_PASSWORD como variables de entorno reales.
    local unit_content
    unit_content="$(cat << EOF
[Unit]
Description=MinIO Object Storage
After=network-online.target vault.service
Wants=network-online.target
Requires=vault.service

[Service]
Environment=VAULT_ADDR=http://127.0.0.1:8200
Environment=SERVICE_SECRETS_FILE=/run/mlops-secrets/minio/credentials
ExecStartPre=/usr/local/bin/fetch_secrets.sh minio
EnvironmentFile=/run/mlops-secrets/minio/credentials
ExecStart=/usr/local/bin/minio server --console-address :${PORT_MINIO_CONSOLE} ${MINIO_HOME}/data
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
)"

    _write_unit_if_changed /etc/systemd/system/minio.service "$unit_content" || true
    register_service minio
    log_info "MinIO configurado"
}

# ──────────────────────────────────────────────
# MLflow
# ──────────────────────────────────────────────
install_mlflow() {
    log_section "Instalando MLflow Tracking Server"
    # shellcheck source=/dev/null
    source "$VENV_PATH/bin/activate"

    if pip show mlflow &>/dev/null; then
        local installed
        installed="$(pip show mlflow | awk '/^Version:/{print $2}')"
        if [[ "$installed" == "2.15.1" ]]; then
            log_skip "MLflow 2.15.1 ya instalado"
        else
            log_info "Actualizando MLflow $installed → 2.15.1"
            pip install --quiet mlflow[extras]==2.15.1
        fi
    else
        pip install --quiet mlflow[extras]==2.15.1
    fi

    mkdir -p "$MLFLOW_HOME/artifacts" "$MLFLOW_HOME/db"
    chown -R "$MLOPS_USER:$MLOPS_GROUP" "$MLFLOW_HOME"

    local unit_content
    unit_content="$(cat << EOF
[Unit]
Description=MLflow Tracking Server
After=network.target minio.service vault.service
Requires=vault.service

[Service]
Environment=VAULT_ADDR=http://127.0.0.1:8200
Environment=SERVICE_SECRETS_FILE=/run/mlops-secrets/mlflow/credentials
Environment=PATH=${VENV_PATH}/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin
ExecStartPre=/usr/local/bin/fetch_secrets.sh mlflow
ExecStart=/bin/bash -c '\
    source \${SERVICE_SECRETS_FILE} && \
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
)"

    _write_unit_if_changed /etc/systemd/system/mlflow-server.service "$unit_content" || true
    register_service mlflow-server
    log_info "MLflow configurado"
}

# ──────────────────────────────────────────────
# Airflow
# ──────────────────────────────────────────────
install_airflow() {
    log_section "Instalando Apache Airflow $AIRFLOW_VERSION"
    # shellcheck source=/dev/null
    source "$VENV_PATH/bin/activate"
    export AIRFLOW_HOME="$AIRFLOW_HOME"

    if pip show apache-airflow &>/dev/null; then
        local installed
        installed="$(pip show apache-airflow | awk '/^Version:/{print $2}')"
        if [[ "$installed" == "$AIRFLOW_VERSION" ]]; then
            log_skip "Airflow $AIRFLOW_VERSION ya instalado"
        else
            log_info "Actualizando Airflow $installed → $AIRFLOW_VERSION"
            local CONSTRAINT_URL="https://raw.githubusercontent.com/apache/airflow/constraints-${AIRFLOW_VERSION}/constraints-${PYTHON_VERSION}.txt"
            pip install --quiet "apache-airflow==${AIRFLOW_VERSION}" --constraint "$CONSTRAINT_URL"
        fi
    else
        local CONSTRAINT_URL="https://raw.githubusercontent.com/apache/airflow/constraints-${AIRFLOW_VERSION}/constraints-${PYTHON_VERSION}.txt"
        pip install --quiet "apache-airflow==${AIRFLOW_VERSION}" --constraint "$CONSTRAINT_URL"
    fi

    # db migrate es idempotente por diseño (Alembic)
    airflow db migrate

    mkdir -p "$AIRFLOW_HOME/dags"
    chown -R "$MLOPS_USER:$MLOPS_GROUP" "$AIRFLOW_HOME"
    log_info "Airflow instalado"
    create_airflow_systemd_services
}

create_airflow_systemd_services() {
    local webserver_content
    webserver_content="$(cat << EOF
[Unit]
Description=Apache Airflow Webserver
After=network.target vault.service
Requires=vault.service

[Service]
Environment=VAULT_ADDR=http://127.0.0.1:8200
Environment=SERVICE_SECRETS_FILE=/run/mlops-secrets/airflow/credentials
Environment=AIRFLOW_HOME=${AIRFLOW_HOME}
Environment=PATH=${VENV_PATH}/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin
ExecStartPre=/usr/local/bin/fetch_secrets.sh airflow
ExecStart=/bin/bash -c '\
    source \${SERVICE_SECRETS_FILE} && \
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
)"

    local scheduler_content
    scheduler_content="$(cat << EOF
[Unit]
Description=Apache Airflow Scheduler
After=network.target vault.service
Requires=vault.service

[Service]
Environment=VAULT_ADDR=http://127.0.0.1:8200
Environment=SERVICE_SECRETS_FILE=/run/mlops-secrets/airflow/credentials
Environment=AIRFLOW_HOME=${AIRFLOW_HOME}
Environment=PATH=${VENV_PATH}/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin
ExecStartPre=/usr/local/bin/fetch_secrets.sh airflow
ExecStart=/bin/bash -c '\
    source \${SERVICE_SECRETS_FILE} && \
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
)"

    _write_unit_if_changed /etc/systemd/system/airflow-webserver.service "$webserver_content" || true
    _write_unit_if_changed /etc/systemd/system/airflow-scheduler.service "$scheduler_content" || true
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

    local unit_content
    unit_content="$(cat << EOF
[Unit]
Description=MLOps Churn Prediction API (FastAPI)
After=network.target mlflow-server.service vault.service
Requires=vault.service

[Service]
Environment=VAULT_ADDR=http://127.0.0.1:8200
Environment=SERVICE_SECRETS_FILE=/run/mlops-secrets/fastapi/credentials
Environment=PATH=${VENV_PATH}/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin
ExecStartPre=/usr/local/bin/fetch_secrets.sh fastapi
ExecStart=/bin/bash -c '\
    source \${SERVICE_SECRETS_FILE} && \
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
)"

    _write_unit_if_changed /etc/systemd/system/mlops-api.service "$unit_content" || true
    register_service mlops-api
    log_info "FastAPI configurado"
}

# ──────────────────────────────────────────────
# Dependencias ML
# ──────────────────────────────────────────────

# Tabla de paquete → versión esperada
declare -A ML_PACKAGES=(
    [dvc]=3.51.2
    [scikit-learn]=1.5.1
    [pandas]=2.2.2
    [numpy]=1.26.4
    [fastapi]=0.112.0
    [uvicorn]=0.30.5
    [pydantic]=2.8.2
    [boto3]=1.35.0
    [pyarrow]=15.0.2
    [joblib]=1.4.2
    [matplotlib]=3.9.2
    [python-multipart]=0.0.9
)

install_ml_dependencies() {
    log_section "Instalando dependencias ML"
    # shellcheck source=/dev/null
    source "$VENV_PATH/bin/activate"

    local to_install=()

    for pkg in "${!ML_PACKAGES[@]}"; do
        local want="${ML_PACKAGES[$pkg]}"
        local got
        got="$(pip show "$pkg" 2>/dev/null | awk '/^Version:/{print $2}')"
        if [[ "$got" == "$want" ]]; then
            log_skip "$pkg==$want ya instalado"
        else
            [[ -n "$got" ]] \
                && log_info "$pkg: $got → $want" \
                || log_info "$pkg==$want faltante"
            to_install+=("${pkg}==${want}")
        fi
    done

    if [[ ${#to_install[@]} -eq 0 ]]; then
        log_skip "Todas las dependencias ML ya están al día"
        return
    fi

    # dvc[s3] y uvicorn[standard] necesitan el extra explícito
    local install_args=()
    for item in "${to_install[@]}"; do
        case "$item" in
            dvc==*)        install_args+=("dvc[s3]==${item#dvc==}") ;;
            uvicorn==*)    install_args+=("uvicorn[standard]==${item#uvicorn==}") ;;
            *)             install_args+=("$item") ;;
        esac
    done

    pip install --quiet "${install_args[@]}"
    log_info "Dependencias ML instaladas: ${install_args[*]}"
}

# ──────────────────────────────────────────────
# Firewall
# ──────────────────────────────────────────────
configure_firewall() {
    log_section "Configurando firewall UFW"

    # ufw status numbered | grep permite saber si una regla ya existe.
    # Es más simple dejar que ufw gestione duplicados (es idempotente
    # si se usa `ufw allow` con los mismos argumentos).
    ufw allow ssh
    ufw allow "$PORT_AIRFLOW_WEBSERVER/tcp" comment "Airflow"
    ufw allow "$PORT_MLFLOW_UI/tcp"         comment "MLflow"
    ufw allow "$PORT_MINIO_API/tcp"         comment "MinIO API"
    ufw allow "$PORT_MINIO_CONSOLE/tcp"     comment "MinIO Console"
    ufw allow "$PORT_FASTAPI/tcp"           comment "FastAPI"
    ufw allow 8200/tcp                      comment "Vault (solo loopback en producción)"

    # --force evita el prompt interactivo; ufw no duplica reglas existentes
    ufw --force enable
    log_info "UFW configurado"
}

# ──────────────────────────────────────────────
# Arranque / resumen
# ──────────────────────────────────────────────
start_all_services() {
    log_section "Iniciando servicios base"
    log_info "Servicios registrados en systemd."
    log_info "Siguiente paso: sudo ./scripts/vault/setup_vault.sh"
}

print_summary() {
    local VM_IP
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
    echo -e "  3. sudo systemctl start minio mlflow-server airflow-webserver airflow-scheduler mlops-api"
}

# ──────────────────────────────────────────────
# Main
# ──────────────────────────────────────────────
main() {
    local only_units=false
    [[ "${1:-}" == "--only-units" ]] && only_units=true

    check_root
    detect_os
    install_fetch_secrets

    if ! $only_units; then
        install_base_packages
        create_mlops_user
        setup_python_virtualenv
    fi

    # tmpfiles.d debe ejecutarse DESPUÉS de crear el usuario mlops
    # y ANTES de registrar los units.
    setup_tmpfiles

    install_minio
    install_mlflow
    install_airflow
    install_ml_dependencies
    setup_fastapi_service

    if ! $only_units; then
        configure_firewall
    fi

    start_all_services
    print_summary
}

main "$@"