#!/usr/bin/env bash
# =============================================================================
# Inicializa DVC y configura el remote apuntando a MinIO.
# Crea los buckets necesarios en MinIO usando el cliente mc.
#
# Cada paso verifica el estado actual antes de actuar.
#
# Las credenciales se obtienen de HashiCorp Vault via AppRole (mismo mecanismo
# que usan los servicios systemd). Vault debe estar inicializado y unsealed.
#
# Prerequisito: scripts/vault/setup_vault.sh y scripts/vault/write_secrets.sh
#               ejecutados previamente.
#
# Uso:
#   ./scripts/setup_dvc.sh          # corre como el usuario actual
#   sudo ./scripts/setup_dvc.sh     # si el usuario actual no es miembro de mlops
# =============================================================================

set -euo pipefail

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[DVC-SETUP]${NC} $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}      $*"; }
log_skip()  { echo -e "${YELLOW}[SKIP]${NC}      $*"; }
log_error() { echo -e "${RED}[ERROR]${NC}     $*"; }

# ──────────────────────────────────────────────
# Variables
# ──────────────────────────────────────────────
VAULT_ADDR="${VAULT_ADDR:-http://127.0.0.1:8200}"
VAULT_KV_PATH="mlops"
APPROLE_DIR="/etc/mlops/vault-init/minio"
MC_BIN="/usr/local/bin/mc"
VENV_PATH="${VENV_PATH:-/opt/mlops_venv}"
export VAULT_ADDR

# ──────────────────────────────────────────────
# Auto-escalación a root
#
# /etc/mlops/vault-init/ es 710 root:mlops. Si el usuario actual no
# pertenece al grupo mlops, los tests -e/-r fallan con "permission denied"
# — bash los trata como "no existe", produciendo mensajes confusos.
#
# En lugar de requerir que el operador recuerde añadir su usuario al grupo,
# el script detecta si necesita más privilegios y se relanza con sudo
# preservando las variables de entorno relevantes.
# ──────────────────────────────────────────────
_ensure_privileged() {
    # Si ya somos root no hay nada que hacer
    [[ "$EUID" -eq 0 ]] && return

    # Comprobamos acceso real usando sudo test (no expone el contenido)
    if ! sudo test -r "$APPROLE_DIR/role_id" 2>/dev/null; then
        log_error "No se puede acceder a $APPROLE_DIR/role_id ni con sudo."
        log_error "  → Ejecuta primero: sudo ./scripts/vault/setup_vault.sh"
        exit 1
    fi

    # Tenemos sudo pero no somos root — relanzar el script completo elevado,
    # preservando las variables que el usuario pudo haber sobreescrito.
    log_warn "Usuario \'$(id -un)\' no pertenece al grupo mlops — relanzando con sudo..."
    exec sudo \
        VAULT_ADDR="$VAULT_ADDR" \
        VENV_PATH="$VENV_PATH" \
        HOME="$HOME" \
        GIT_AUTHOR_NAME="${GIT_AUTHOR_NAME:-}" \
        GIT_AUTHOR_EMAIL="${GIT_AUTHOR_EMAIL:-}" \
        bash "$0" "$@"
}

_check_approle_access() {
    local role_id_file="$APPROLE_DIR/role_id"
    local secret_id_file="$APPROLE_DIR/secret_id"

    # En este punto somos root (garantizado por _ensure_privileged),
    # por lo que -e y -r funcionan sin ambigüedad de permisos.

    if [[ ! -e "$APPROLE_DIR" ]]; then
        log_error "Directorio AppRole no encontrado: $APPROLE_DIR"
        log_error "  → Ejecuta primero: sudo ./scripts/vault/setup_vault.sh"
        return 1
    fi

    local missing=()
    [[ ! -e "$role_id_file"   ]] && missing+=("role_id")
    [[ ! -e "$secret_id_file" ]] && missing+=("secret_id")
    if [[ ${#missing[@]} -gt 0 ]]; then
        log_error "Archivos AppRole faltantes en $APPROLE_DIR: ${missing[*]}"
        log_error "  → Ejecuta primero: sudo ./scripts/vault/setup_vault.sh"
        return 1
    fi

    return 0
}

# ──────────────────────────────────────────────
# Obtener credenciales de MinIO desde Vault via AppRole
# ──────────────────────────────────────────────
fetch_minio_credentials() {
    log_info "Obteniendo credenciales de MinIO desde Vault..."

    _check_approle_access || exit 1

    # Vault debe estar accesible — distinguir "proceso caído" de "sealed"
    local http_code
    http_code=$(curl -s --max-time 5 -o /dev/null -w "%{http_code}" \
                    "${VAULT_ADDR}/v1/sys/health" 2>/dev/null || echo "000")

    case "$http_code" in
        000)
            log_error "Vault no responde en $VAULT_ADDR (¿está corriendo?)"
            log_error "  → sudo systemctl start vault   (VM con systemd)"
            log_error "  → o revisa /var/log/vault.log"
            exit 1
            ;;
        501)
            log_error "Vault está corriendo pero NO inicializado (HTTP 501)"
            log_error "  → Ejecuta: sudo ./scripts/vault/setup_vault.sh"
            exit 1
            ;;
        503)
            log_error "Vault está corriendo pero SEALED (HTTP 503)"
            log_error "  → Ejecuta el unseal manual o reinicia vault-unseal.service"
            exit 1
            ;;
        200|429|472)
            log_info "Vault accesible (HTTP $http_code)"
            ;;
        *)
            log_warn "Vault responde con HTTP $http_code — continuando de todas formas"
            ;;
    esac

    local role_id secret_id vault_token
    role_id=$(cat "$APPROLE_DIR/role_id")
    secret_id=$(cat "$APPROLE_DIR/secret_id")

    vault_token=$(vault write -field=token auth/approle/login \
        role_id="$role_id" \
        secret_id="$secret_id") || {
        log_error "Fallo al autenticar con AppRole en Vault."
        log_error "  → El secret_id puede haber expirado o sido revocado."
        log_error "  → Regenera con: sudo ./scripts/vault/setup_vault.sh"
        exit 1
    }

    export VAULT_TOKEN="$vault_token"

    MINIO_ROOT_USER=$(vault kv get     -field=root_user      "${VAULT_KV_PATH}/minio")
    MINIO_ROOT_PASSWORD=$(vault kv get -field=root_password  "${VAULT_KV_PATH}/minio")
    MINIO_ENDPOINT=$(vault kv get      -field=endpoint       "${VAULT_KV_PATH}/minio")
    DVC_BUCKET=$(vault kv get          -field=dvc_bucket     "${VAULT_KV_PATH}/minio")
    MLFLOW_BUCKET=$(vault kv get       -field=mlflow_bucket  "${VAULT_KV_PATH}/minio")

    log_info "Credenciales obtenidas desde Vault"
}

# ──────────────────────────────────────────────
# 1. Activar venv (dvc y git deben estar en PATH)
# ──────────────────────────────────────────────
activate_venv() {
    if [[ -f "$VENV_PATH/bin/activate" ]]; then
        # shellcheck source=/dev/null
        source "$VENV_PATH/bin/activate"
        log_info "Entorno virtual activado: $VENV_PATH"
    else
        log_warn "Entorno virtual no encontrado en $VENV_PATH — usando PATH del sistema"
    fi
}

# ──────────────────────────────────────────────
# 2. Cliente MinIO (mc)
# ──────────────────────────────────────────────
install_mc_client() {
    if [[ -x "$MC_BIN" ]]; then
        log_skip "Cliente mc ya instalado"
        return
    fi
    log_info "Descargando cliente MinIO (mc)..."
    wget -q "https://dl.min.io/client/mc/release/linux-amd64/mc" -O "$MC_BIN"
    chmod +x "$MC_BIN"
    log_info "Cliente mc instalado"
}

# ──────────────────────────────────────────────
# 3. Preparar MinIO: limpiar estado persistido si las credenciales
#    no coinciden, luego esperar a que el servicio esté disponible.
#
# Por qué: MinIO persiste las credenciales de root en
# $MINIO_HOME/data/.minio.sys/ la primera vez que arranca.
# Si arrancó previamente con minioadmin:minioadmin (credenciales por
# defecto, cuando Vault aún no tenía los secretos escritos), esas
# quedan grabadas en disco y MinIO las ignora aunque el servicio
# reciba otras por variable de entorno en arranques posteriores.
#
# Solución: detectar el mismatch probando el alias mc con las
# credenciales de Vault. Si falla, parar MinIO, borrar el estado
# persistido y reiniciarlo para que arranque limpio con las
# credenciales correctas.
# ──────────────────────────────────────────────
MINIO_HOME="${MINIO_HOME:-/opt/minio}"

_wait_for_minio() {
    local endpoint="$1"
    local retries=30   # 30 × 2 s = 60 s máximo
    log_info "Esperando a que MinIO esté disponible en $endpoint..."

    until curl -sf --max-time 2 "${endpoint}/minio/health/live"             -o /dev/null 2>/dev/null || [[ $retries -eq 0 ]]; do
        sleep 2
        (( retries-- )) || true
    done

    if ! curl -sf --max-time 2 "${endpoint}/minio/health/live"             -o /dev/null 2>/dev/null; then
        log_error "MinIO no responde en $endpoint después de 60 s"
        log_error "  → Revisa los logs: sudo journalctl -u minio -n 50 --no-pager"
        exit 1
    fi

    log_info "MinIO disponible en $endpoint"
}

_reset_minio_if_credentials_mismatch() {
    # Prueba silenciosa con las credenciales de Vault.
    # mc alias set falla con exit != 0 si las credenciales son incorrectas.
    if mc alias set probe "$MINIO_ENDPOINT"             "$MINIO_ROOT_USER" "$MINIO_ROOT_PASSWORD"             --quiet 2>/dev/null; then
        mc alias rm probe &>/dev/null || true
        log_skip "Credenciales de MinIO correctas — sin reset necesario"
        return
    fi
    mc alias rm probe &>/dev/null || true

    log_warn "Credenciales de MinIO no coinciden con Vault — reseteando estado persistido"
    log_warn "  (MinIO arrancó previamente con credenciales distintas)"

    # Detener MinIO antes de tocar su estado
    if systemctl is-active --quiet minio 2>/dev/null; then
        systemctl stop minio
        log_info "MinIO detenido para reset"
    fi

    # Borrar solo el estado de configuración (credenciales, políticas).
    # Los datos de usuario (buckets y objetos) se preservan.
    local config_dir="$MINIO_HOME/data/.minio.sys"
    if [[ -d "$config_dir" ]]; then
        rm -rf "$config_dir"
        log_info "Estado persistido de MinIO eliminado ($config_dir)"
    fi

    # Reiniciar y esperar a que levante con las credenciales correctas
    systemctl start minio
    _wait_for_minio "$MINIO_ENDPOINT"
    log_info "MinIO reiniciado con credenciales de Vault"
}

# ──────────────────────────────────────────────
# 4. Crear buckets en MinIO
# ──────────────────────────────────────────────
create_minio_buckets() {
    _wait_for_minio "$MINIO_ENDPOINT"
    # Las credenciales ya fueron verificadas y el estado de MinIO
    # sincronizado con Vault por start_minio.sh (make start-minio).
    log_info "Configurando alias mc → $MINIO_ENDPOINT"
    mc alias set local "$MINIO_ENDPOINT" "$MINIO_ROOT_USER" "$MINIO_ROOT_PASSWORD" --quiet

    for bucket in "$DVC_BUCKET" "$MLFLOW_BUCKET"; do
        if mc ls "local/$bucket" &>/dev/null; then
            log_skip "Bucket '$bucket' ya existe"
        else
            mc mb "local/$bucket" --quiet
            log_info "Bucket s3://$bucket creado"
        fi
    done
}

# ──────────────────────────────────────────────
# 5. Inicializar DVC
# ──────────────────────────────────────────────
init_dvc() {
    if ! git rev-parse --is-inside-work-tree &>/dev/null; then
        log_info "Inicializando repositorio git..."
        git init
        git config user.email "mlops@pipeline.local"
        git config user.name  "MLOps Pipeline"
    else
        log_skip "Repositorio git ya existe"
    fi

    if [[ -d ".dvc" ]]; then
        log_skip "DVC ya inicializado"
    else
        log_info "Inicializando DVC..."
        dvc init
        git add .dvc/ .dvcignore
        git commit -m "chore: inicializar DVC"
    fi
}

# ──────────────────────────────────────────────
# 6. Configurar remote DVC
# .dvc/config       → URL y endpoint (versionado en git, sin credenciales)
# .dvc/config.local → credenciales   (excluido de git por .dvc/.gitignore)
# ──────────────────────────────────────────────
configure_dvc_remote() {
    # Comprueba si el remote ya apunta al bucket correcto
    local current_url
    current_url=$(dvc remote list 2>/dev/null | awk '/^minio/{print $2}' || true)

    if [[ "$current_url" == "s3://$DVC_BUCKET" ]]; then
        log_skip "Remote DVC 'minio' ya configurado → $current_url"
        # Las credenciales locales pueden estar desactualizadas — siempre actualizarlas
        dvc remote modify --local minio access_key_id     "$MINIO_ROOT_USER"
        dvc remote modify --local minio secret_access_key "$MINIO_ROOT_PASSWORD"
        log_info "Credenciales locales de DVC actualizadas"
        return
    fi

    log_info "Configurando remote DVC → s3://$DVC_BUCKET"
    dvc remote add -d minio "s3://$DVC_BUCKET" --force
    dvc remote modify minio endpointurl "$MINIO_ENDPOINT"
    dvc remote modify --local minio access_key_id     "$MINIO_ROOT_USER"
    dvc remote modify --local minio secret_access_key "$MINIO_ROOT_PASSWORD"

    # Solo hace commit si .dvc/config cambió
    if ! git diff --quiet .dvc/config 2>/dev/null; then
        git add .dvc/config
        git commit -m "chore: configurar DVC remote MinIO"
    else
        log_skip ".dvc/config sin cambios — commit omitido"
    fi

    log_info "Remote DVC configurado"
    log_info "  .dvc/config       → versionado en git (sin credenciales)"
    log_info "  .dvc/config.local → excluido de git (credenciales)"
}

# ──────────────────────────────────────────────
# 7. Estructura de directorios de datos
# ──────────────────────────────────────────────
create_data_dirs() {
    local created=false

    for dir in data/raw data/processed models; do
        if [[ ! -d "$dir" ]]; then
            mkdir -p "$dir"
            log_info "Directorio creado: $dir"
            created=true
        else
            log_skip "Directorio ya existe: $dir"
        fi
    done

    local gitignore="data/.gitignore"
    local desired_gitignore
    desired_gitignore="$(cat << 'GITIGNORE'
/raw/*.csv
/raw/*.parquet
/processed/*.parquet
/processed/*.csv
GITIGNORE
)"

    if [[ ! -f "$gitignore" ]] || [[ "$(cat "$gitignore")" != "$desired_gitignore" ]]; then
        echo "$desired_gitignore" > "$gitignore"
        created=true
        log_info "$gitignore actualizado"
    else
        log_skip "$gitignore sin cambios"
    fi

    if $created; then
        git add data/ models/ 2>/dev/null || true
        git diff --cached --quiet \
            || git commit -m "chore: estructura de directorios del proyecto"
    fi
}

# ──────────────────────────────────────────────
# Main
# ──────────────────────────────────────────────
main() {
    _ensure_privileged "$@"   # relanza como root si el usuario no es del grupo mlops
    activate_venv
    fetch_minio_credentials
    install_mc_client
    create_minio_buckets
    init_dvc
    configure_dvc_remote
    create_data_dirs

    echo ""
    log_info "DVC configurado correctamente"
    echo ""
    echo "  Próximos pasos:"
    echo "  1. Coloca tu CSV en data/raw/telco_churn.csv"
    echo "  2. dvc add data/raw/telco_churn.csv"
    echo "  3. dvc push"
}

main "$@"