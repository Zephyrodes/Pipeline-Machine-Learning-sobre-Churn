#!/usr/bin/env bash
# =============================================================================
# Arranca MinIO garantizando que las credenciales en disco coinciden con
# las que Vault tiene escritas.
#
#   MinIO persiste las credenciales de root en
#   $MINIO_HOME/data/.minio.sys/ la primera vez que arranca.
#   Si en algún arranque previo Vault estaba sealed o los secretos aún
#   no estaban escritos, MinIO usó las credenciales por defecto
#   (minioadmin:minioadmin) y las grabó en disco. En arranques
#   posteriores las ignora aunque el servicio reciba otras por variable
#   de entorno — produciendo el error "Access Key Id does not exist".
#
# Pasos:
#   1. Leer las credenciales correctas desde Vault.
#   2. Arrancar MinIO (o dejarlo correr si ya está activo).
#   3. Probar las credenciales con mc alias set.
#   4. Si fallan → parar MinIO, borrar .minio.sys/, reiniciar.
#   5. Los datos de usuario (buckets y objetos) se preservan siempre.
#
# Uso:
#   sudo ./scripts/start_minio.sh
# =============================================================================

set -euo pipefail

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[MINIO]${NC}  $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}   $*"; }
log_error() { echo -e "${RED}[ERROR]${NC}  $*"; }

VAULT_ADDR="${VAULT_ADDR:-http://127.0.0.1:8200}"
VAULT_KV_PATH="mlops"
APPROLE_DIR="/etc/mlops/vault-init/minio"
MINIO_HOME="${MINIO_HOME:-/opt/minio}"
MC_BIN="/usr/local/bin/mc"
export VAULT_ADDR

# ──────────────────────────────────────────────
# 1. Leer credenciales desde Vault via AppRole
# ──────────────────────────────────────────────
_fetch_credentials() {
    local role_id secret_id vault_token
    role_id=$(cat "$APPROLE_DIR/role_id")
    secret_id=$(cat "$APPROLE_DIR/secret_id")

    vault_token=$(vault write -field=token auth/approle/login \
        role_id="$role_id" secret_id="$secret_id") || {
        log_error "No se pudo autenticar con Vault. ¿Está unsealed?"
        log_error "  → make vault-unseal"
        exit 1
    }
    export VAULT_TOKEN="$vault_token"

    MINIO_ROOT_USER=$(vault kv get     -field=root_user     "${VAULT_KV_PATH}/minio")
    MINIO_ROOT_PASSWORD=$(vault kv get -field=root_password "${VAULT_KV_PATH}/minio")
    MINIO_ENDPOINT=$(vault kv get      -field=endpoint      "${VAULT_KV_PATH}/minio")
}

# ──────────────────────────────────────────────
# 2. Preparar directorio tmpfs para las credenciales de minio
#
# fetch_secrets.sh (ExecStartPre= de minio.service) necesita escribir en
# /run/mlops-secrets/minio/ pero ese subdirectorio puede no existir:
#   - systemd-tmpfiles solo recreó el directorio padre al arranque.
#   - ExecStartPre= corre como usuario mlops, sin permisos para crear
#     subdirectorios si mlops no es dueño de /run/mlops-secrets/.
#
# Se crea aquí corriendo como root (start_minio.sh se invoca con sudo),
# antes de llamar a systemctl start — así fetch_secrets.sh solo necesita
# escribir el archivo credentials, no crear el directorio.
# ──────────────────────────────────────────────
_prepare_secrets_dir() {
    local secrets_base="/run/mlops-secrets"
    local minio_secrets_dir="$secrets_base/minio"

    if [[ ! -d "$secrets_base" ]]; then
        mkdir -p "$secrets_base"
        chmod 755 "$secrets_base"
        chown mlops:mlops "$secrets_base"
        log_info "Directorio tmpfs $secrets_base creado"
    fi

    if [[ ! -d "$minio_secrets_dir" ]]; then
        mkdir -p "$minio_secrets_dir"
        chmod 700 "$minio_secrets_dir"
        chown mlops:mlops "$minio_secrets_dir"
        log_info "Directorio de secretos $minio_secrets_dir creado"
    fi
}

# ──────────────────────────────────────────────
# 3. Arrancar MinIO si no está corriendo
# ──────────────────────────────────────────────
_ensure_minio_running() {
    if systemctl is-active --quiet minio; then
        log_info "MinIO ya está corriendo"
        return
    fi
    _prepare_secrets_dir
    log_info "Arrancando MinIO..."
    systemctl start minio
    _wait_for_minio
}

_wait_for_minio() {
    local retries=30
    until curl -sf --max-time 2 "${MINIO_ENDPOINT}/minio/health/live" \
            -o /dev/null 2>/dev/null || [[ $retries -eq 0 ]]; do
        sleep 2
        (( retries-- )) || true
    done
    if ! curl -sf --max-time 2 "${MINIO_ENDPOINT}/minio/health/live" \
            -o /dev/null 2>/dev/null; then
        log_error "MinIO no responde en $MINIO_ENDPOINT después de 60 s"
        log_error "  → sudo journalctl -u minio -n 50 --no-pager"
        exit 1
    fi
    log_info "MinIO disponible en $MINIO_ENDPOINT"
}

# ──────────────────────────────────────────────
# 4. Verificar credenciales y resetear si no coinciden
# ──────────────────────────────────────────────
_verify_or_reset_credentials() {
    # Prueba silenciosa: mc alias set falla si las credenciales son incorrectas
    if "$MC_BIN" alias set probe "$MINIO_ENDPOINT" \
            "$MINIO_ROOT_USER" "$MINIO_ROOT_PASSWORD" \
            --quiet 2>/dev/null; then
        "$MC_BIN" alias rm probe &>/dev/null || true
        log_info "Credenciales de MinIO verificadas correctamente"
        return
    fi
    "$MC_BIN" alias rm probe &>/dev/null || true

    log_warn "Las credenciales de Vault no coinciden con el estado persistido de MinIO"
    log_warn "MinIO arrancó previamente con credenciales distintas — reseteando"

    # Parar MinIO antes de modificar su estado
    systemctl stop minio
    log_info "MinIO detenido"

    # Borrar solo la configuración persistida.
    # Los buckets y objetos en $MINIO_HOME/data/ se preservan intactos.
    local config_dir="$MINIO_HOME/data/.minio.sys"
    if [[ -d "$config_dir" ]]; then
        rm -rf "$config_dir"
        log_info "Estado persistido eliminado: $config_dir"
    fi

    # Reiniciar con las credenciales correctas de Vault
    log_info "Reiniciando MinIO con credenciales de Vault..."
    _prepare_secrets_dir
    systemctl start minio
    _wait_for_minio

    # Verificación final
    if ! "$MC_BIN" alias set probe "$MINIO_ENDPOINT" \
            "$MINIO_ROOT_USER" "$MINIO_ROOT_PASSWORD" \
            --quiet 2>/dev/null; then
        "$MC_BIN" alias rm probe &>/dev/null || true
        log_error "MinIO sigue rechazando las credenciales de Vault tras el reset"
        log_error "Revisa que write_secrets.sh escribió las credenciales correctas:"
        log_error "  make vault-secrets"
        exit 1
    fi
    "$MC_BIN" alias rm probe &>/dev/null || true
    log_info "MinIO reiniciado y credenciales verificadas"
}

# ──────────────────────────────────────────────
# Main
# ──────────────────────────────────────────────
main() {
    [[ "$EUID" -eq 0 ]] || { log_error "Ejecutar como root (sudo)"; exit 1; }

    _fetch_credentials
    _ensure_minio_running
    _verify_or_reset_credentials
}

main "$@"