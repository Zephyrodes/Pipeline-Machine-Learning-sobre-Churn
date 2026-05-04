#!/usr/bin/env bash
# =============================================================================
# Instala HashiCorp Vault, lo inicializa, habilita el motor KV v2 y configura
# AppRole por servicio.
#
# Compatible con VMs (systemd) y contenedores (proceso directo).
# El script detecta automáticamente el entorno y actúa en consecuencia.
#
# Prerequisito: provision_vm.sh debe haberse ejecutado primero.
#
# Uso:
#   sudo ./scripts/vault/setup_vault.sh
# =============================================================================

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info()    { echo -e "${GREEN}[VAULT]${NC}  $*"; }
log_warn()    { echo -e "${YELLOW}[VAULT]${NC}  $*"; }
log_error()   { echo -e "${RED}[VAULT]${NC}  $*"; }
log_section() { echo -e "\n${BLUE}════════════════════════════════════════${NC}"; \
                echo -e "${BLUE} $*${NC}"; \
                echo -e "${BLUE}════════════════════════════════════════${NC}"; }

check_root() {
    [[ "$EUID" -eq 0 ]] || { log_error "Ejecutar como root (sudo)"; exit 1; }
}

# ──────────────────────────────────────────────
# Detectar si systemd está disponible
# ──────────────────────────────────────────────
SYSTEMD_AVAILABLE=false
if systemctl is-system-running &>/dev/null 2>&1; then
    SYSTEMD_AVAILABLE=true
fi

start_service() {
    local service_name="$1"
    local exec_cmd="$2"
    local pidfile="/run/${service_name}.pid"

    if $SYSTEMD_AVAILABLE; then
        systemctl daemon-reload
        systemctl enable "$service_name"
        systemctl start  "$service_name"
    else
        log_warn "systemd no disponible — arrancando $service_name como proceso directo"
        # Arrancar en segundo plano y guardar PID
        nohup $exec_cmd >> "/var/log/${service_name}.log" 2>&1 &
        echo $! > "$pidfile"
        log_info "$service_name PID: $(cat $pidfile)"
    fi
}

# ──────────────────────────────────────────────
# Variables
# ──────────────────────────────────────────────
VAULT_VERSION="1.17.2"
VAULT_ADDR="http://127.0.0.1:8200"
VAULT_DATA_DIR="/opt/vault/data"
VAULT_CONFIG_DIR="/etc/vault.d"
VAULT_KEYS_DIR="/etc/mlops/vault-init"
VAULT_KV_PATH="mlops"
MLOPS_POLICY_NAME="mlops-services"
VAULT_USER="vault"

declare -A SERVICE_ROLES=(
    ["airflow"]="mlops-airflow"
    ["mlflow"]="mlops-mlflow"
    ["minio"]="mlops-minio"
    ["fastapi"]="mlops-fastapi"
)

export VAULT_ADDR

# ──────────────────────────────────────────────
# 1. Instalación de Vault
# ──────────────────────────────────────────────
install_vault() {
    log_section "Instalando HashiCorp Vault $VAULT_VERSION"

    if command -v vault &>/dev/null; then
        log_warn "Vault ya instalado: $(vault version)"
        return
    fi

    apt-get install -y gpg lsb-release
    wget -qO - https://apt.releases.hashicorp.com/gpg | \
        gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg

    echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] \
https://apt.releases.hashicorp.com $(lsb_release -cs) main" \
        > /etc/apt/sources.list.d/hashicorp.list

    apt-get update -y
    apt-get install -y "vault=${VAULT_VERSION}-1"
    log_info "Vault $VAULT_VERSION instalado"
}

# ──────────────────────────────────────────────
# 2. Configuración y arranque
# ──────────────────────────────────────────────
configure_and_start_vault() {
    log_section "Configurando y arrancando Vault"

    # Usuario del sistema
    if ! id "$VAULT_USER" &>/dev/null; then
        useradd --system --home "$VAULT_DATA_DIR" \
                --shell /bin/false "$VAULT_USER"
    fi

    mkdir -p "$VAULT_DATA_DIR" "$VAULT_CONFIG_DIR"
    chown -R "$VAULT_USER:$VAULT_USER" "$VAULT_DATA_DIR"

    cat > "$VAULT_CONFIG_DIR/vault.hcl" << 'HCL'
ui            = false
disable_mlock = true

storage "raft" {
    path    = "/opt/vault/data"
    node_id = "vault-node-1"
}

listener "tcp" {
    address     = "127.0.0.1:8200"
    tls_disable = true
}

api_addr     = "http://127.0.0.1:8200"
cluster_addr = "http://127.0.0.1:8201"
HCL
    chmod 640 "$VAULT_CONFIG_DIR/vault.hcl"
    chown root:"$VAULT_USER" "$VAULT_CONFIG_DIR/vault.hcl"

    if $SYSTEMD_AVAILABLE; then
        cat > /etc/systemd/system/vault.service << EOF
[Unit]
Description=HashiCorp Vault
After=network-online.target
Wants=network-online.target

[Service]
User=${VAULT_USER}
Group=${VAULT_USER}
ExecStart=/usr/bin/vault server -config=${VAULT_CONFIG_DIR}/vault.hcl
ExecReload=/bin/kill --signal HUP \$MAINPID
KillMode=process
KillSignal=SIGINT
Restart=on-failure
RestartSec=5s
LimitNOFILE=65536
LimitMEMLOCK=infinity
NoNewPrivileges=yes
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF
        start_service "vault" ""
    else
        # Contenedor: arrancar Vault directamente como proceso
        mkdir -p /var/log
        nohup su -s /bin/bash "$VAULT_USER" -c \
            "vault server -config=$VAULT_CONFIG_DIR/vault.hcl" \
            >> /var/log/vault.log 2>&1 &
        echo $! > /run/vault.pid
        log_info "Vault arrancado como proceso (PID: $(cat /run/vault.pid))"
    fi

    # Esperar a que Vault esté listo
    local retries=10
    until vault status &>/dev/null || [[ $retries -eq 0 ]]; do
        sleep 2
        (( retries-- )) || true
    done
    log_info "Vault accesible en $VAULT_ADDR"
}

# ──────────────────────────────────────────────
# 3. Inicialización y unseal
# ──────────────────────────────────────────────
initialize_vault() {
    log_section "Inicializando Vault"

    # Si ya está inicializado, solo hacer unseal
    if vault status 2>/dev/null | grep -q "Initialized.*true"; then
        log_warn "Vault ya inicializado — procediendo al unseal"
        unseal_vault
        return
    fi

    mkdir -p "$VAULT_KEYS_DIR"
    chmod 700 "$VAULT_KEYS_DIR"

    local init_output
    init_output=$(vault operator init \
        -key-shares=3 \
        -key-threshold=2 \
        -format=json)

    echo "$init_output" > "$VAULT_KEYS_DIR/init.json"
    chmod 600 "$VAULT_KEYS_DIR/init.json"
    log_warn "Unseal keys y root token guardados en $VAULT_KEYS_DIR/init.json"
    log_warn "Haz backup de este archivo y elimínalo del servidor en producción."

    local key1 key2 root_token
    key1=$(echo "$init_output" | python3 -c "import sys,json; print(json.load(sys.stdin)['unseal_keys_b64'][0])")
    key2=$(echo "$init_output" | python3 -c "import sys,json; print(json.load(sys.stdin)['unseal_keys_b64'][1])")
    root_token=$(echo "$init_output" | python3 -c "import sys,json; print(json.load(sys.stdin)['root_token'])")

    vault operator unseal "$key1"
    vault operator unseal "$key2"

    export VAULT_TOKEN="$root_token"
    log_info "Vault inicializado y unsealed"
}

unseal_vault() {
    local init_file="$VAULT_KEYS_DIR/init.json"
    [[ -f "$init_file" ]] || { log_error "No se encontró $init_file"; exit 1; }

    local key1 key2
    key1=$(python3 -c "import json; print(json.load(open('$init_file'))['unseal_keys_b64'][0])")
    key2=$(python3 -c "import json; print(json.load(open('$init_file'))['unseal_keys_b64'][1])")
    vault operator unseal "$key1"
    vault operator unseal "$key2"
    log_info "Vault unsealed"
}

# ──────────────────────────────────────────────
# 4. Motor KV v2
# ──────────────────────────────────────────────
configure_kv_store() {
    log_section "Configurando motor KV v2"
    vault secrets enable -path="$VAULT_KV_PATH" kv-v2 2>/dev/null \
        || log_warn "Motor KV ya habilitado en $VAULT_KV_PATH"
}

# ──────────────────────────────────────────────
# 5. Policy
# ──────────────────────────────────────────────
create_vault_policy() {
    log_section "Creando política $MLOPS_POLICY_NAME"
    vault policy write "$MLOPS_POLICY_NAME" - << POLICY
path "${VAULT_KV_PATH}/data/minio"   { capabilities = ["read"] }
path "${VAULT_KV_PATH}/data/airflow" { capabilities = ["read"] }
path "${VAULT_KV_PATH}/data/mlflow"  { capabilities = ["read"] }
path "${VAULT_KV_PATH}/data/fastapi" { capabilities = ["read"] }
POLICY
    log_info "Política $MLOPS_POLICY_NAME creada"
}

# ──────────────────────────────────────────────
# 6. AppRole por servicio
# ──────────────────────────────────────────────
configure_approle() {
    log_section "Configurando AppRole"
    vault auth enable approle 2>/dev/null || log_warn "AppRole ya habilitado"

    for service in "${!SERVICE_ROLES[@]}"; do
        local role_name="${SERVICE_ROLES[$service]}"
        local role_dir="$VAULT_KEYS_DIR/$service"
        mkdir -p "$role_dir"

        vault write "auth/approle/role/$role_name" \
            token_policies="$MLOPS_POLICY_NAME" \
            token_ttl=1h \
            token_max_ttl=4h \
            secret_id_ttl=0

        local role_id secret_id
        role_id=$(vault read -field=role_id "auth/approle/role/$role_name/role-id")
        secret_id=$(vault write -field=secret_id -f "auth/approle/role/$role_name/secret-id")

        echo "$role_id"   > "$role_dir/role_id"
        echo "$secret_id" > "$role_dir/secret_id"
        chmod 644 "$role_dir/role_id"
        chmod 600 "$role_dir/secret_id"

        log_info "AppRole '$role_name' → $role_dir/"
    done
}

# ──────────────────────────────────────────────
# 7. Servicio de unseal automático (solo systemd)
# ──────────────────────────────────────────────
create_unseal_service() {
    $SYSTEMD_AVAILABLE || { log_warn "systemd no disponible — unseal automático omitido"; return; }

    log_section "Creando servicio de unseal automático"

    cat > /usr/local/bin/vault-unseal.sh << 'UNSEAL'
#!/usr/bin/env bash
set -euo pipefail
VAULT_ADDR="http://127.0.0.1:8200"
INIT_FILE="/etc/mlops/vault-init/init.json"
export VAULT_ADDR
sleep 5
if vault status 2>/dev/null | grep -q "Sealed.*true"; then
    KEY1=$(python3 -c "import json; print(json.load(open('$INIT_FILE'))['unseal_keys_b64'][0])")
    KEY2=$(python3 -c "import json; print(json.load(open('$INIT_FILE'))['unseal_keys_b64'][1])")
    vault operator unseal "$KEY1"
    vault operator unseal "$KEY2"
fi
UNSEAL
    chmod 700 /usr/local/bin/vault-unseal.sh

    cat > /etc/systemd/system/vault-unseal.service << EOF
[Unit]
Description=HashiCorp Vault Auto-Unseal
After=vault.service
Requires=vault.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/vault-unseal.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable vault-unseal
    log_info "Servicio vault-unseal habilitado"
}

# ──────────────────────────────────────────────
# Main
# ──────────────────────────────────────────────
print_next_steps() {
    log_section "Vault configurado"
    echo ""
    echo "  Próximos pasos:"
    echo "  1. Escribir los secretos del pipeline:"
    echo "     sudo VAULT_TOKEN=\$(python3 -c \"import json; print(json.load(open('/etc/mlops/vault-init/init.json'))['root_token'])\") \\"
    echo "       ./scripts/vault/write_secrets.sh"
    echo ""
    echo "  IMPORTANTE: Haz backup de /etc/mlops/vault-init/init.json"
}

main() {
    check_root
    install_vault
    configure_and_start_vault
    initialize_vault
    configure_kv_store
    create_vault_policy
    configure_approle
    create_unseal_service
    print_next_steps
}

main "$@"