#!/usr/bin/env bash
# =============================================================================
# Instala HashiCorp Vault como servicio systemd, lo inicializa, habilita
# el motor KV v2 y configura el método de autenticación AppRole para que
# cada servicio del pipeline pueda obtener sus credenciales de forma segura.
#
# Ejecución única — después del aprovisionamiento base (provision_vm.sh).
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
# Variables
# ──────────────────────────────────────────────
VAULT_VERSION="1.17.2"
VAULT_ADDR="http://127.0.0.1:8200"
VAULT_DATA_DIR="/opt/vault/data"
VAULT_CONFIG_DIR="/etc/vault.d"
VAULT_KEYS_DIR="/etc/mlops/vault-init"   # unseal keys + root token (chmod 600, fuera del repo)
VAULT_KV_PATH="mlops"                    # path del motor KV: secret/mlops/...
MLOPS_POLICY_NAME="mlops-services"
VAULT_USER="vault"

# Servicios del pipeline y sus roles en Vault
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

    apt-get install -y gpg
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
# 2. Configuración y servicio systemd
# ──────────────────────────────────────────────
configure_vault_service() {
    log_section "Configurando Vault como servicio systemd"

    # Usuario del sistema para Vault
    if ! id "$VAULT_USER" &>/dev/null; then
        useradd --system --home "$VAULT_DATA_DIR" \
                --shell /bin/false "$VAULT_USER"
    fi

    mkdir -p "$VAULT_DATA_DIR" "$VAULT_CONFIG_DIR"
    chown -R "$VAULT_USER:$VAULT_USER" "$VAULT_DATA_DIR"

    # Configuración de Vault: almacenamiento local en disco (Raft integrado)
    cat > "$VAULT_CONFIG_DIR/vault.hcl" << 'HCL'
ui            = false
disable_mlock = true

storage "raft" {
    path    = "/opt/vault/data"
    node_id = "vault-node-1"
}

listener "tcp" {
    address     = "127.0.0.1:8200"
    tls_disable = true          # solo loopback — en producción usar TLS
}

api_addr     = "http://127.0.0.1:8200"
cluster_addr = "http://127.0.0.1:8201"
HCL
    chmod 640 "$VAULT_CONFIG_DIR/vault.hcl"
    chown root:"$VAULT_USER" "$VAULT_CONFIG_DIR/vault.hcl"

    cat > /etc/systemd/system/vault.service << EOF
[Unit]
Description=HashiCorp Vault
Documentation=https://www.vaultproject.io/docs/
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

    systemctl daemon-reload
    systemctl enable vault
    systemctl start vault
    sleep 3
    log_info "Servicio Vault iniciado"
}

# ──────────────────────────────────────────────
# 3. Inicialización y unseal
# ──────────────────────────────────────────────
initialize_vault() {
    log_section "Inicializando Vault"

    mkdir -p "$VAULT_KEYS_DIR"
    chmod 700 "$VAULT_KEYS_DIR"

    local init_output
    init_output=$(vault operator init \
        -key-shares=3 \
        -key-threshold=2 \
        -format=json 2>/dev/null)

    # Guardar unseal keys y root token — chmod 600, solo root puede leer
    echo "$init_output" > "$VAULT_KEYS_DIR/init.json"
    chmod 600 "$VAULT_KEYS_DIR/init.json"

    log_warn "Unseal keys y root token guardados en $VAULT_KEYS_DIR/init.json"
    log_warn "Haz un backup seguro de este archivo y elimínalo del servidor en producción."

    # Extraer keys y token
    local unseal_key_1 unseal_key_2 root_token
    unseal_key_1=$(echo "$init_output" | python3 -c "import sys,json; print(json.load(sys.stdin)['unseal_keys_b64'][0])")
    unseal_key_2=$(echo "$init_output" | python3 -c "import sys,json; print(json.load(sys.stdin)['unseal_keys_b64'][1])")
    root_token=$(echo  "$init_output" | python3 -c "import sys,json; print(json.load(sys.stdin)['root_token'])")

    # Unseal con 2 de 3 keys (threshold=2)
    vault operator unseal "$unseal_key_1"
    vault operator unseal "$unseal_key_2"

    export VAULT_TOKEN="$root_token"
    log_info "Vault inicializado y unsealed"
}

unseal_vault() {
    # Para reinicios posteriores — se llama desde un servicio o manualmente
    local init_file="$VAULT_KEYS_DIR/init.json"
    if [[ ! -f "$init_file" ]]; then
        log_error "No se encontró $init_file — ejecuta setup_vault.sh completo primero"
        exit 1
    fi
    local unseal_key_1 unseal_key_2
    unseal_key_1=$(python3 -c "import json; d=json.load(open('$init_file')); print(d['unseal_keys_b64'][0])")
    unseal_key_2=$(python3 -c "import json; d=json.load(open('$init_file')); print(d['unseal_keys_b64'][1])")
    vault operator unseal "$unseal_key_1"
    vault operator unseal "$unseal_key_2"
    log_info "Vault unsealed"
}

# ──────────────────────────────────────────────
# 4. Motor KV v2 y secretos del pipeline
# ──────────────────────────────────────────────
configure_kv_store() {
    log_section "Configurando motor KV v2"

    vault secrets enable -path="$VAULT_KV_PATH" kv-v2 2>/dev/null \
        || log_warn "Motor KV ya habilitado en $VAULT_KV_PATH"

    log_info "Los secretos se escriben con: vault/setup_vault_secrets.sh"
    log_info "Motor KV disponible en: $VAULT_KV_PATH/"
}

# ──────────────────────────────────────────────
# 5. Policy — define qué puede leer cada servicio
# ──────────────────────────────────────────────
create_vault_policy() {
    log_section "Creando política $MLOPS_POLICY_NAME"

    vault policy write "$MLOPS_POLICY_NAME" - << POLICY
# Política para los servicios del pipeline MLOps
# Acceso de solo lectura a los secretos del path mlops/

path "${VAULT_KV_PATH}/data/minio" {
    capabilities = ["read"]
}

path "${VAULT_KV_PATH}/data/airflow" {
    capabilities = ["read"]
}

path "${VAULT_KV_PATH}/data/mlflow" {
    capabilities = ["read"]
}

path "${VAULT_KV_PATH}/data/fastapi" {
    capabilities = ["read"]
}
POLICY

    log_info "Política $MLOPS_POLICY_NAME creada"
}

# ──────────────────────────────────────────────
# 6. AppRole — un role por servicio
# ──────────────────────────────────────────────
configure_approle() {
    log_section "Configurando método de autenticación AppRole"

    vault auth enable approle 2>/dev/null \
        || log_warn "AppRole ya habilitado"

    for service in "${!SERVICE_ROLES[@]}"; do
        local role_name="${SERVICE_ROLES[$service]}"
        local role_dir="$VAULT_KEYS_DIR/$service"
        mkdir -p "$role_dir"

        # Crear el role — token válido 1h, renovable, limitado a la policy del pipeline
        vault write "auth/approle/role/$role_name" \
            token_policies="$MLOPS_POLICY_NAME" \
            token_ttl=1h \
            token_max_ttl=4h \
            secret_id_ttl=0          # secret_id no expira (rotar manualmente)

        # Obtener role_id (no secreto — puede estar en el repo o en la VM)
        local role_id
        role_id=$(vault read -field=role_id "auth/approle/role/$role_name/role-id")
        echo "$role_id" > "$role_dir/role_id"
        chmod 644 "$role_dir/role_id"   # no es secreto

        # Generar secret_id (secreto — solo root puede leer)
        local secret_id
        secret_id=$(vault write -field=secret_id -f "auth/approle/role/$role_name/secret-id")
        echo "$secret_id" > "$role_dir/secret_id"
        chmod 600 "$role_dir/secret_id"
        chown root:root "$role_dir/secret_id"

        log_info "AppRole '$role_name' configurado → $role_dir/"
    done
}

# ──────────────────────────────────────────────
# 7. Script de unseal automático post-reinicio
# ──────────────────────────────────────────────
create_unseal_service() {
    log_section "Creando servicio de unseal automático"

    cat > /usr/local/bin/vault-unseal.sh << 'UNSEAL'
#!/usr/bin/env bash
# Unseal automático de Vault tras un reinicio del sistema.
# En producción considerar Vault Auto Unseal con KMS (AWS/Azure/GCP).
set -euo pipefail
VAULT_ADDR="http://127.0.0.1:8200"
INIT_FILE="/etc/mlops/vault-init/init.json"
export VAULT_ADDR

sleep 5  # Esperar a que el proceso de Vault esté listo

if vault status 2>/dev/null | grep -q "Sealed.*true"; then
    KEY1=$(python3 -c "import json; d=json.load(open('$INIT_FILE')); print(d['unseal_keys_b64'][0])")
    KEY2=$(python3 -c "import json; d=json.load(open('$INIT_FILE')); print(d['unseal_keys_b64'][1])")
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
    echo "     sudo ./scripts/vault/write_secrets.sh"
    echo ""
    echo "  2. Verificar que los servicios pueden leer sus secretos:"
    echo "     sudo ./scripts/vault/fetch_secrets.sh airflow"
    echo ""
    echo "  IMPORTANTE: Haz backup de $VAULT_KEYS_DIR/init.json"
    echo "  y elimínalo del servidor en producción."
}

main() {
    check_root
    install_vault
    configure_vault_service
    initialize_vault
    configure_kv_store
    create_vault_policy
    configure_approle
    create_unseal_service
    print_next_steps
}

main "$@"