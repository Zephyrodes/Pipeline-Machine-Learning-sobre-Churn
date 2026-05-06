#!/usr/bin/env bash
# =============================================================================
# Instala HashiCorp Vault, lo inicializa, habilita el motor KV v2 y configura
# AppRole por servicio.
#
# Cada paso verifica el estado actual antes de actuar.
# Es seguro volver a correr este script en un Vault ya configurado.
#
# Compatible con VMs (systemd) y contenedores (proceso directo).
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
log_skip()    { echo -e "${YELLOW}[SKIP]${NC}   $*"; }
log_section() { echo -e "\n${BLUE}════════════════════════════════════════${NC}"; \
                echo -e "${BLUE} $*${NC}"; \
                echo -e "${BLUE}════════════════════════════════════════${NC}"; }

check_root() {
    [[ "$EUID" -eq 0 ]] || { log_error "Ejecutar como root (sudo)"; exit 1; }
}

# ──────────────────────────────────────────────
# Detectar systemd
# ──────────────────────────────────────────────
SYSTEMD_AVAILABLE=false
if systemctl is-system-running &>/dev/null 2>&1; then
    SYSTEMD_AVAILABLE=true
fi

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
MLOPS_GROUP="mlops"

declare -A SERVICE_ROLES=(
    ["airflow"]="mlops-airflow"
    ["mlflow"]="mlops-mlflow"
    ["minio"]="mlops-minio"
    ["fastapi"]="mlops-fastapi"
)

export VAULT_ADDR

# ──────────────────────────────────────────────
# Helpers
# ──────────────────────────────────────────────

# Escribe un archivo solo si el contenido difiere.
# Devuelve 0 si se escribió, 1 si ya estaba igual.
_write_file_if_changed() {
    local path="$1"
    local content="$2"
    if [[ -f "$path" ]] && [[ "$(cat "$path")" == "$content" ]]; then
        log_skip "$(basename "$path") sin cambios"
        return 1
    fi
    echo "$content" > "$path"
    return 0
}

# Espera a que el listener TCP de Vault esté activo (máx. 60 s).
#
# Por qué NO usar `vault status`:
#   - exit 0  → unsealed (imposible en el primer arranque)
#   - exit 1  → error de red / proceso aún no levantó
#   - exit 2  → sealed o no inicializado  ← estado normal justo tras arrancar
#
# Usar `vault status` como condición de espera nunca termina en primera
# instalación porque el proceso arranca sealed. En su lugar comprobamos
# que el puerto TCP 8200 acepta conexiones, que es lo único que necesitamos
# saber antes de llamar a `vault operator init`.
_wait_for_vault() {
    local retries=30   # 30 × 2 s = 60 s máximo
    log_info "Esperando a que Vault levante en $VAULT_ADDR..."
    until curl -sf --max-time 2 "${VAULT_ADDR}/v1/sys/health" \
            -o /dev/null 2>/dev/null \
          || [[ $retries -eq 0 ]]; do
        sleep 2
        (( retries-- )) || true
    done

    # /v1/sys/health devuelve:
    #   200 → activo y unsealed          (instalación previa)
    #   429 → standby                    (HA, no aplica aquí)
    #   472 → recovery mode
    #   501 → no inicializado            ← estado normal en primer arranque
    #   503 → sealed                     ← estado normal tras reinicio
    # Cualquiera de estos códigos significa que el proceso responde.
    # Solo falla si curl no pudo conectar en absoluto (exit ≠ 0 por red).
    local http_code
    http_code=$(curl -s --max-time 2 -o /dev/null -w "%{http_code}" \
                    "${VAULT_ADDR}/v1/sys/health" 2>/dev/null || echo "000")

    if [[ "$http_code" == "000" ]]; then
        log_error "Vault no responde en $VAULT_ADDR después de 60 s"
        log_error "Revisa los logs: journalctl -u vault  o  cat /var/log/vault.log"
        exit 1
    fi

    log_info "Vault accesible en $VAULT_ADDR (HTTP $http_code)"
}

# ──────────────────────────────────────────────
# 1. Instalación de Vault
# ──────────────────────────────────────────────
install_vault() {
    log_section "Instalando HashiCorp Vault $VAULT_VERSION"

    if command -v vault &>/dev/null; then
        local installed
        installed="$(vault version | grep -oP '\d+\.\d+\.\d+')"
        if [[ "$installed" == "$VAULT_VERSION" ]]; then
            log_skip "Vault $VAULT_VERSION ya instalado"
            return
        fi
        log_info "Actualizando Vault $installed → $VAULT_VERSION"
    fi

    apt-get install -y gpg lsb-release

    # GPG key — solo si no existe
    if [[ ! -f /usr/share/keyrings/hashicorp-archive-keyring.gpg ]]; then
        wget -qO - https://apt.releases.hashicorp.com/gpg | \
            gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg
        log_info "GPG key de HashiCorp instalada"
    else
        log_skip "GPG key de HashiCorp ya existe"
    fi

    # Repositorio — solo si cambió
    local repo_file="/etc/apt/sources.list.d/hashicorp.list"
    local repo_line="deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com $(lsb_release -cs) main"
    _write_file_if_changed "$repo_file" "$repo_line" \
        && { apt-get update -y; log_info "Repositorio HashiCorp añadido"; } \
        || true

    apt-get install -y "vault=${VAULT_VERSION}-1"
    log_info "Vault $VAULT_VERSION instalado"
}

# ──────────────────────────────────────────────
# 2. Configuración y arranque
# ──────────────────────────────────────────────
configure_and_start_vault() {
    log_section "Configurando y arrancando Vault"

    # Usuario de sistema
    if id "$VAULT_USER" &>/dev/null; then
        log_skip "Usuario $VAULT_USER ya existe"
    else
        useradd --system --home "$VAULT_DATA_DIR" --shell /bin/false "$VAULT_USER"
        log_info "Usuario $VAULT_USER creado"
    fi

    mkdir -p "$VAULT_DATA_DIR" "$VAULT_CONFIG_DIR"
    chown -R "$VAULT_USER:$VAULT_USER" "$VAULT_DATA_DIR"

    # vault.hcl — solo reescribir si cambió
    local hcl_content
    hcl_content='ui            = false
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
cluster_addr = "http://127.0.0.1:8201"'

    if _write_file_if_changed "$VAULT_CONFIG_DIR/vault.hcl" "$hcl_content"; then
        chmod 640 "$VAULT_CONFIG_DIR/vault.hcl"
        chown root:"$VAULT_USER" "$VAULT_CONFIG_DIR/vault.hcl"
        log_info "vault.hcl actualizado"
    fi

    if $SYSTEMD_AVAILABLE; then
        local unit_content
        unit_content="$(cat << EOF
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
)"
        _write_file_if_changed /etc/systemd/system/vault.service "$unit_content" \
            && systemctl daemon-reload \
            || true

        systemctl enable vault

        if systemctl is-active --quiet vault; then
            log_skip "Vault ya está corriendo"
        else
            systemctl start vault
            log_info "Vault arrancado"
        fi
    else
        # Fallback para contenedores sin systemd
        if [[ -f /run/vault.pid ]] && kill -0 "$(cat /run/vault.pid)" 2>/dev/null; then
            log_skip "Vault ya está corriendo (PID: $(cat /run/vault.pid))"
        else
            mkdir -p /var/log
            nohup su -s /bin/bash "$VAULT_USER" -c \
                "vault server -config=$VAULT_CONFIG_DIR/vault.hcl" \
                >> /var/log/vault.log 2>&1 &
            echo $! > /run/vault.pid
            log_info "Vault arrancado como proceso (PID: $(cat /run/vault.pid))"
        fi
    fi

    _wait_for_vault
}

# ──────────────────────────────────────────────
# Helpers de estado — consultan /v1/sys/health via HTTP para evitar
# depender del exit code de `vault status`, que varía según el estado
# de Vault y rompe `set -euo pipefail`:
#
#   exit 0 → unsealed y activo   (nunca ocurre justo tras arrancar)
#   exit 1 → error de red
#   exit 2 → sealed o no inicializado  ← esto mataba el script
#
# /v1/sys/health en cambio siempre responde con HTTP si el proceso vive:
#   200 → activo y unsealed
#   501 → no inicializado
#   503 → sealed
# ──────────────────────────────────────────────
_vault_http_code() {
    curl -s --max-time 3 -o /dev/null -w "%{http_code}" \
        "${VAULT_ADDR}/v1/sys/health" 2>/dev/null || echo "000"
}

_vault_is_initialized() {
    # 501 = no inicializado; cualquier otra respuesta = ya inicializado
    local code
    code=$(_vault_http_code)
    [[ "$code" != "501" && "$code" != "000" ]]
}

_vault_is_sealed() {
    # 503 = sealed; 200 = activo (unsealed)
    local code
    code=$(_vault_http_code)
    [[ "$code" == "503" ]]
}

# ──────────────────────────────────────────────
# 3. Inicialización y unseal
# ──────────────────────────────────────────────
initialize_vault() {
    log_section "Inicializando Vault"

    if _vault_is_initialized; then
        log_skip "Vault ya inicializado"
        _unseal_if_needed
        return
    fi

    mkdir -p "$VAULT_KEYS_DIR"
    chmod 710 "$VAULT_KEYS_DIR"
    chown root:"$MLOPS_GROUP" "$VAULT_KEYS_DIR"

    local init_output
    init_output=$(vault operator init \
        -key-shares=3 \
        -key-threshold=2 \
        -format=json)

    local init_file="$VAULT_KEYS_DIR/init.json"
    echo "$init_output" > "$init_file"
    chmod 600 "$init_file"
    chown root:root "$init_file"
    log_warn "Unseal keys y root token guardados en $init_file"
    log_warn "Haz backup de este archivo y elimínalo del servidor en producción."

    local key1 key2 root_token
    key1=$(echo "$init_output"       | python3 -c "import sys,json; print(json.load(sys.stdin)['unseal_keys_b64'][0])")
    key2=$(echo "$init_output"       | python3 -c "import sys,json; print(json.load(sys.stdin)['unseal_keys_b64'][1])")
    root_token=$(echo "$init_output" | python3 -c "import sys,json; print(json.load(sys.stdin)['root_token'])")

    vault operator unseal "$key1"
    vault operator unseal "$key2"

    export VAULT_TOKEN="$root_token"
    log_info "Vault inicializado y unsealed"
}

# Hace unseal solo si Vault está sealed; no-op si ya está abierto.
_unseal_if_needed() {
    if ! _vault_is_sealed; then
        log_skip "Vault ya está unsealed"
        return
    fi

    local init_file="$VAULT_KEYS_DIR/init.json"
    [[ -f "$init_file" ]] || { log_error "No se encontró $init_file para hacer unseal"; exit 1; }

    local key1 key2
    key1=$(python3 -c "import json; print(json.load(open('$init_file'))['unseal_keys_b64'][0])")
    key2=$(python3 -c "import json; print(json.load(open('$init_file'))['unseal_keys_b64'][1])")
    vault operator unseal "$key1"
    vault operator unseal "$key2"
    log_info "Vault unsealed"
}

# Exporta VAULT_TOKEN desde init.json para los pasos de configuración.
_load_root_token() {
    local init_file="$VAULT_KEYS_DIR/init.json"
    [[ -f "$init_file" ]] || { log_error "No se encontró $init_file"; exit 1; }
    export VAULT_TOKEN
    VAULT_TOKEN=$(python3 -c "import json; print(json.load(open('$init_file'))['root_token'])")
}

# ──────────────────────────────────────────────
# 4. Motor KV v2
# ──────────────────────────────────────────────
configure_kv_store() {
    log_section "Configurando motor KV v2"

    if vault secrets list -format=json 2>/dev/null \
        | python3 -c "import sys,json; sys.exit(0 if '${VAULT_KV_PATH}/' in json.load(sys.stdin) else 1)" \
        2>/dev/null; then
        log_skip "Motor KV ya habilitado en $VAULT_KV_PATH"
    else
        vault secrets enable -path="$VAULT_KV_PATH" kv-v2
        log_info "Motor KV v2 habilitado en $VAULT_KV_PATH"
    fi
}

# ──────────────────────────────────────────────
# 5. Policy
# ──────────────────────────────────────────────
create_vault_policy() {
    log_section "Creando política $MLOPS_POLICY_NAME"

    local desired_policy
    desired_policy="$(cat << POLICY
path "${VAULT_KV_PATH}/data/minio"   { capabilities = ["read"] }
path "${VAULT_KV_PATH}/data/airflow" { capabilities = ["read"] }
path "${VAULT_KV_PATH}/data/mlflow"  { capabilities = ["read"] }
path "${VAULT_KV_PATH}/data/fastapi" { capabilities = ["read"] }
POLICY
)"

    local existing_policy
    existing_policy="$(vault policy read "$MLOPS_POLICY_NAME" 2>/dev/null || true)"

    if [[ "$existing_policy" == "$desired_policy" ]]; then
        log_skip "Política $MLOPS_POLICY_NAME sin cambios"
        return
    fi

    vault policy write "$MLOPS_POLICY_NAME" - <<< "$desired_policy"
    log_info "Política $MLOPS_POLICY_NAME escrita"
}

# ──────────────────────────────────────────────
# 6. AppRole por servicio
# ──────────────────────────────────────────────
configure_approle() {
    log_section "Configurando AppRole"

    if vault auth list -format=json 2>/dev/null \
        | python3 -c "import sys,json; sys.exit(0 if 'approle/' in json.load(sys.stdin) else 1)" \
        2>/dev/null; then
        log_skip "AppRole ya habilitado"
    else
        vault auth enable approle
        log_info "AppRole habilitado"
    fi

    for service in "${!SERVICE_ROLES[@]}"; do
        local role_name="${SERVICE_ROLES[$service]}"
        local role_dir="$VAULT_KEYS_DIR/$service"

        # vault write en un rol existente es idempotente (actualiza sin error)
        vault write "auth/approle/role/$role_name" \
            token_policies="$MLOPS_POLICY_NAME" \
            token_ttl=1h \
            token_max_ttl=4h \
            secret_id_ttl=0

        mkdir -p "$role_dir"

        # role_id: estable dentro de una instancia de Vault.
        # Se regenera si el archivo no existe O si el role_id en disco
        # no coincide con el que Vault reporta ahora (indica reinicialización).
        local current_role_id
        current_role_id=$(vault read -field=role_id "auth/approle/role/$role_name/role-id")
        if [[ ! -f "$role_dir/role_id" ]] ||            [[ "$(cat "$role_dir/role_id")" != "$current_role_id" ]]; then
            echo "$current_role_id" > "$role_dir/role_id"
            log_info "role_id actualizado para $service"
        else
            log_skip "role_id de $service sin cambios"
        fi

        # secret_id: verificar que el que está en disco sigue siendo válido
        # intentando un login de prueba. Si falla (Vault reinicializado, secret_id
        # revocado, o archivo corrupto), generar uno nuevo.
        #
        # lookup-secret-id requiere el secret_id en texto plano, no el accessor,
        # así que hacemos un login real con token_ttl mínimo como prueba de validez.
        local needs_new_secret_id=true
        if [[ -f "$role_dir/secret_id" ]]; then
            local test_token
            test_token=$(vault write -field=token auth/approle/login \
                role_id="$current_role_id" \
                secret_id="$(cat "$role_dir/secret_id")" 2>/dev/null || true)
            if [[ -n "$test_token" ]]; then
                # Token válido obtenido → secret_id sigue activo; revocar el token de prueba
                vault token revoke "$test_token" &>/dev/null || true
                needs_new_secret_id=false
                log_skip "secret_id de $service sigue siendo válido"
            else
                log_warn "secret_id de $service inválido o expirado — regenerando"
            fi
        fi

        if $needs_new_secret_id; then
            vault write -field=secret_id -f \
                "auth/approle/role/$role_name/secret-id" \
                > "$role_dir/secret_id"
            log_info "secret_id regenerado para $service"
        fi

        # Árbol de permisos:
        #   /etc/mlops/vault-init/           root:mlops  710  (traversal sin lectura)
        #   /etc/mlops/vault-init/init.json  root:root   600  (solo root)
        #   /etc/mlops/vault-init/<svc>/     root:mlops  750  (mlops puede listar/leer)
        #   /etc/mlops/vault-init/<svc>/role_id    root:mlops  640
        #   /etc/mlops/vault-init/<svc>/secret_id  root:mlops  640
        chown root:"$MLOPS_GROUP" "$role_dir"        && chmod 750 "$role_dir"
        chown root:"$MLOPS_GROUP" "$role_dir/role_id"   && chmod 640 "$role_dir/role_id"
        chown root:"$MLOPS_GROUP" "$role_dir/secret_id" && chmod 640 "$role_dir/secret_id"

        log_info "AppRole '$role_name' → $role_dir/"
    done
}

# ──────────────────────────────────────────────
# 7. Servicio de unseal automático (solo systemd)
# ──────────────────────────────────────────────
create_unseal_service() {
    $SYSTEMD_AVAILABLE || { log_warn "systemd no disponible — unseal automático omitido"; return; }

    log_section "Creando servicio de unseal automático"

    local unseal_script="/usr/local/bin/vault-unseal.sh"
    # Nota: las variables $INIT_FILE, $KEY1, $KEY2 deben expandirse en
    # tiempo de ejecución del script generado, no ahora — de ahí las comillas simples.
    local unseal_content
    unseal_content='#!/usr/bin/env bash
set -euo pipefail
VAULT_ADDR="http://127.0.0.1:8200"
INIT_FILE="/etc/mlops/vault-init/init.json"
export VAULT_ADDR
sleep 5
if vault status 2>/dev/null | grep -q "Sealed.*true"; then
    KEY1=$(python3 -c "import json; print(json.load(open(\"$INIT_FILE\"))[\"unseal_keys_b64\"][0])")
    KEY2=$(python3 -c "import json; print(json.load(open(\"$INIT_FILE\"))[\"unseal_keys_b64\"][1])")
    vault operator unseal "$KEY1"
    vault operator unseal "$KEY2"
fi'

    if _write_file_if_changed "$unseal_script" "$unseal_content"; then
        chmod 700 "$unseal_script"
        log_info "vault-unseal.sh actualizado"
    fi

    local unit_content
    unit_content="$(cat << EOF
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
)"

    if _write_file_if_changed /etc/systemd/system/vault-unseal.service "$unit_content"; then
        systemctl daemon-reload
        log_info "Unit vault-unseal actualizado"
    fi

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

    # Subcomando: setup_vault.sh --unseal
    # Usado por `make vault-unseal` para desellar Vault sin re-ejecutar
    # todo el flujo de configuración. Seguro de invocar en cualquier momento.
    if [[ "${1:-}" == "--unseal" ]]; then
        log_section "Unseal manual de Vault"
        _wait_for_vault
        _unseal_if_needed
        log_info "Vault listo"
        return
    fi

    install_vault
    configure_and_start_vault
    initialize_vault    # inicializa si es primera vez; unseal si ya está inicializado
    _load_root_token    # exporta VAULT_TOKEN para los pasos siguientes
    configure_kv_store
    create_vault_policy
    configure_approle
    create_unseal_service
    print_next_steps
}

main "$@"