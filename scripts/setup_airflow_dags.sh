#!/usr/bin/env bash
# =============================================================================
# Configura Airflow para que detecte los DAGs del proyecto y elimina
# los DAGs de ejemplo que vienen por defecto.
#
# Qué hace este script:
#   1. Deshabilita los DAGs de ejemplo (load_examples = False)
#   2. Crea el directorio /opt/airflow/dags/ si no existe
#   3. Crea un symlink del DAG del proyecto → /opt/airflow/dags/
#   4. Crea un symlink de src/ del proyecto → /opt/airflow/dags/src
#      (el DAG importa desde esa ruta fija)
#   5. Elimina los archivos de ejemplo que ya estuviesen en disco
#   6. Verifica / crea el directorio de datos raw
#   7. Instala dependencias Python (setuptools bootstrap + requirements.txt)
#   8. Reinicia airflow-webserver y airflow-scheduler para aplicar cambios
#
# Uso:
#   sudo bash scripts/setup_airflow_dags.sh
# =============================================================================

set -euo pipefail

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[DAG-SETUP]${NC} $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}      $*"; }
log_skip()  { echo -e "${YELLOW}[SKIP]${NC}      $*"; }
log_error() { echo -e "${RED}[ERROR]${NC}     $*"; }

# ──────────────────────────────────────────────
# Variables
# ──────────────────────────────────────────────

# Raíz del proyecto: directorio padre del directorio scripts/
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

AIRFLOW_HOME="${AIRFLOW_HOME:-/opt/airflow}"
AIRFLOW_CFG="$AIRFLOW_HOME/airflow.cfg"
AIRFLOW_DAGS_DIR="$AIRFLOW_HOME/dags"

PROJECT_DAGS_DIR="$PROJECT_ROOT/dags"
PROJECT_SRC_DIR="$PROJECT_ROOT/src"

# DAG principal del proyecto
DAG_FILE="dag_churn_pipeline.py"

# ──────────────────────────────────────────────
# Verificaciones previas
# ──────────────────────────────────────────────
check_preconditions() {
    if [[ ! -f "$PROJECT_DAGS_DIR/$DAG_FILE" ]]; then
        log_error "No se encontró el DAG del proyecto en:"
        log_error "  $PROJECT_DAGS_DIR/$DAG_FILE"
        log_error "Verifica que el repo está completo y que dags/$DAG_FILE existe."
        exit 1
    fi

    if [[ ! -d "$PROJECT_SRC_DIR" ]]; then
        log_error "No se encontró el directorio src/ del proyecto en:"
        log_error "  $PROJECT_SRC_DIR"
        log_error "El DAG importa desde /opt/airflow/dags/src — src/ debe existir."
        exit 1
    fi

    if [[ ! -d "$AIRFLOW_HOME" ]]; then
        log_error "AIRFLOW_HOME no existe: $AIRFLOW_HOME"
        log_error "Ejecuta primero: make provision"
        exit 1
    fi

    log_info "Precondiciones OK"
    log_info "  Proyecto   : $PROJECT_ROOT"
    log_info "  DAG        : $PROJECT_DAGS_DIR/$DAG_FILE"
    log_info "  src/       : $PROJECT_SRC_DIR"
    log_info "  Airflow    : $AIRFLOW_HOME"
}

# ──────────────────────────────────────────────
# 1b. Dar permisos de traversal al usuario mlops sobre el repo
#
# Los symlinks de /opt/airflow/dags/ apuntan a archivos dentro del repo,
# que normalmente vive en /home/<usuario>/. El directorio home de Ubuntu
# tiene permisos 700 por defecto, así que el proceso de Airflow (usuario
# mlops) falla con PermissionError en path.stat() antes de poder leer
# nada — el DAG no aparece en la UI sin ningún mensaje de error obvio.
#
# Solución mínima de privilegios:
#   - o+x en cada directorio padre hasta la raíz del repo (traversal sin listar)
#   - o+r en el DAG .py y en src/ (lectura solo de lo necesario)
#
# No se modifica el home completo del usuario operador.
# ──────────────────────────────────────────────
fix_repo_permissions() {
    local mlops_user="mlops"

    log_info "Verificando que '$mlops_user' puede acceder al repo..."

    # Verificar si mlops ya puede stat() el DAG file
    if sudo -u "$mlops_user" test -r "$PROJECT_DAGS_DIR/$DAG_FILE" 2>/dev/null; then
        log_skip "El usuario '$mlops_user' ya tiene acceso de lectura al repo"
        return
    fi

    log_info "Aplicando permisos de traversal mínimos para '$mlops_user'..."

    # Dar o+x (traversal) a cada directorio en la ruta desde / hasta PROJECT_ROOT
    # Sin o+x en un directorio intermedio, stat() falla aunque el archivo
    # final tenga permisos correctos.
    local path="$PROJECT_ROOT"
    local dirs_to_fix=()
    while [[ "$path" != "/" && "$path" != "" ]]; do
        dirs_to_fix=("$path" "${dirs_to_fix[@]}")
        path="$(dirname "$path")"
    done

    for dir in "${dirs_to_fix[@]}"; do
        local perms
        perms=$(stat -c '%a' "$dir" 2>/dev/null || echo "000")
        # Solo añadir o+x si otros no tienen traversal ya
        if [[ "${perms: -1}" != *[1357]* ]]; then
            chmod o+x "$dir"
            log_info "chmod o+x $dir  (era $perms)"
        fi
    done

    # Dar o+r+x al directorio dags/ del proyecto y o+r al DAG .py
    chmod o+rx "$PROJECT_DAGS_DIR"
    chmod o+r  "$PROJECT_DAGS_DIR/$DAG_FILE"
    log_info "Permisos de lectura aplicados: $PROJECT_DAGS_DIR/$DAG_FILE"

    # Dar o+r+x recursivo a src/ para que los módulos sean importables
    chmod -R o+rX "$PROJECT_SRC_DIR"
    log_info "Permisos de lectura aplicados: $PROJECT_SRC_DIR"

    # Verificación final
    if sudo -u "$mlops_user" test -r "$PROJECT_DAGS_DIR/$DAG_FILE" 2>/dev/null; then
        log_info "Verificación OK — '$mlops_user' puede leer el DAG"
    else
        log_error "El usuario '$mlops_user' sigue sin poder leer el DAG tras aplicar permisos."
        log_error "  Ruta: $PROJECT_DAGS_DIR/$DAG_FILE"
        log_error "  Revisa si hay ACLs o flags de seguridad (lsattr, getfacl) bloqueando el acceso."
        exit 1
    fi
}

# ──────────────────────────────────────────────
# 1. Deshabilitar DAGs de ejemplo en airflow.cfg
# ──────────────────────────────────────────────
disable_example_dags() {
    if [[ ! -f "$AIRFLOW_CFG" ]]; then
        log_warn "airflow.cfg no encontrado en $AIRFLOW_CFG"
        log_warn "Airflow puede no haber sido inicializado aún."
        log_warn "Intentando inicializar la BD de Airflow..."
        sudo -u mlops \
            AIRFLOW_HOME="$AIRFLOW_HOME" \
            PATH="/opt/mlops_venv/bin:$PATH" \
            /opt/mlops_venv/bin/airflow db init 2>/dev/null \
            || true
    fi

    if [[ ! -f "$AIRFLOW_CFG" ]]; then
        log_error "airflow.cfg sigue sin existir tras db init. Revisa la instalación."
        exit 1
    fi

    # Parchar load_examples usando Python para no romper el formato INI
    python3 - <<PYEOF
import configparser, shutil, os, sys

cfg_path = "$AIRFLOW_CFG"
shutil.copy(cfg_path, cfg_path + ".bak")  # backup antes de modificar

cfg = configparser.RawConfigParser()
cfg.read(cfg_path)

changed = False

# Sección [core] — load_examples
if not cfg.has_section("core"):
    cfg.add_section("core")

current = cfg.get("core", "load_examples", fallback=None)
if current != "False":
    cfg.set("core", "load_examples", "False")
    changed = True
    print("[DAG-SETUP] load_examples = False aplicado")
else:
    print("[SKIP]      load_examples ya era False")

if changed:
    with open(cfg_path, "w") as f:
        cfg.write(f)
    print("[DAG-SETUP] airflow.cfg actualizado")
else:
    # Restaurar el backup si no hubo cambios (no queremos reescribir el formato)
    os.replace(cfg_path + ".bak", cfg_path)
PYEOF

    # También lo fijamos vía variable de entorno en el unit de systemd como
    # capa de seguridad extra — evita que un 'airflow db migrate' lo revierta.
    _patch_systemd_unit "airflow-webserver" "AIRFLOW__CORE__LOAD_EXAMPLES=False"
    _patch_systemd_unit "airflow-scheduler"  "AIRFLOW__CORE__LOAD_EXAMPLES=False"
}

# ──────────────────────────────────────────────
# Auxiliar: añade una variable de entorno a un unit systemd si no existe
# ──────────────────────────────────────────────
_patch_systemd_unit() {
    local unit="$1"
    local env_var="$2"
    local drop_in_dir="/etc/systemd/system/${unit}.service.d"
    local drop_in_file="$drop_in_dir/load_examples.conf"

    mkdir -p "$drop_in_dir"

    if [[ -f "$drop_in_file" ]] && grep -qF "$env_var" "$drop_in_file" 2>/dev/null; then
        log_skip "Drop-in $drop_in_file ya contiene $env_var"
        return
    fi

    cat > "$drop_in_file" <<UNIT
[Service]
Environment="$env_var"
UNIT
    log_info "Drop-in systemd creado: $drop_in_file"
}

# ──────────────────────────────────────────────
# 2. Crear el directorio de DAGs de Airflow
# ──────────────────────────────────────────────
create_dags_dir() {
    if [[ ! -d "$AIRFLOW_DAGS_DIR" ]]; then
        mkdir -p "$AIRFLOW_DAGS_DIR"
        log_info "Directorio creado: $AIRFLOW_DAGS_DIR"
    else
        log_skip "Directorio ya existe: $AIRFLOW_DAGS_DIR"
    fi

    # Asegurar ownership correcto
    chown -R mlops:mlops "$AIRFLOW_DAGS_DIR" 2>/dev/null || true
}

# ──────────────────────────────────────────────
# 3. Eliminar DAGs de ejemplo que ya estén en disco
#    (cuando load_examples=True los escribe en el dags_folder)
# ──────────────────────────────────────────────
remove_example_dags() {
    local removed=0

    # Los DAGs de ejemplo de Airflow tienen patrones reconocibles
    while IFS= read -r -d '' dag_file; do
        local basename
        basename="$(basename "$dag_file")"

        # Conservar cualquier cosa del proyecto; eliminar solo ejemplos de Airflow
        if [[ "$basename" == "example_"* ]] || \
           [[ "$basename" == "tutorial"* ]] || \
           [[ "$basename" == "test_utils"* ]]; then
            rm -f "$dag_file"
            log_info "Eliminado DAG de ejemplo: $basename"
            (( removed++ )) || true
        fi
    done < <(find "$AIRFLOW_DAGS_DIR" -maxdepth 1 -name "*.py" -print0 2>/dev/null)

    if [[ $removed -eq 0 ]]; then
        log_skip "No se encontraron DAGs de ejemplo en disco para eliminar"
    else
        log_info "$removed DAG(s) de ejemplo eliminados"
    fi
}

# ──────────────────────────────────────────────
# 4. Symlink del DAG del proyecto
# ──────────────────────────────────────────────
link_project_dag() {
    local target="$PROJECT_DAGS_DIR/$DAG_FILE"
    local link="$AIRFLOW_DAGS_DIR/$DAG_FILE"

    # Si ya hay un symlink correcto, skip
    if [[ -L "$link" ]] && [[ "$(readlink -f "$link")" == "$(readlink -f "$target")" ]]; then
        log_skip "Symlink del DAG ya existe y apunta correctamente"
        return
    fi

    # Eliminar symlink roto o archivo viejo si existe
    [[ -e "$link" || -L "$link" ]] && rm -f "$link"

    ln -s "$target" "$link"
    log_info "Symlink creado: $link → $target"
}

# ──────────────────────────────────────────────
# 5. Symlink de src/ dentro del dags_folder
#
# El DAG hace: sys.path.insert(0, "/opt/airflow/dags/src")
# Por eso src/ del proyecto debe ser accesible exactamente en esa ruta.
# ──────────────────────────────────────────────
link_src_dir() {
    local target="$PROJECT_SRC_DIR"
    local link="$AIRFLOW_DAGS_DIR/src"

    if [[ -L "$link" ]] && [[ "$(readlink -f "$link")" == "$(readlink -f "$target")" ]]; then
        log_skip "Symlink src/ ya existe y apunta correctamente"
        return
    fi

    [[ -e "$link" || -L "$link" ]] && rm -rf "$link"

    ln -s "$target" "$link"
    log_info "Symlink creado: $link → $target"
}

# ──────────────────────────────────────────────
# 6. Crear todos los directorios de datos del pipeline y verificar
#    que el dataset esté disponible para el DAG.
#
# Directorios necesarios (escritura en runtime por el usuario mlops):
#   /opt/mlops/data/raw/       → ingesta_datos escribe telco_churn_latest.csv
#   /opt/mlops/data/processed/ → preprocesamiento escribe train.parquet / test.parquet
#   /opt/mlops/models/         → entrenamiento escribe feature_importance.csv
#
# Problema resuelto: provision_vm.sh crea /opt/mlops/ como root y solo
# da chown al subdirectorio data/raw/ al que necesita acceder en ese momento.
# Los directorios data/processed/ y models/ no existen, así que cuando el
# DAG corre como mlops e intenta mkdir() sobre /opt/mlops/data/processed,
# falla con PermissionError porque /opt/mlops/data/ es propiedad de root
# sin write permission para otros.
#
# Solución:
#   1. Crear la jerarquía completa de directorios con mkdir -p.
#   2. Asignar chown mlops:mlops a /opt/mlops/ y toda su descendencia,
#      de modo que el proceso mlops pueda crear subdirectorios libremente
#      en runtime sin necesidad de root.
#   3. Dar o+x a los directorios de traversal (/opt/mlops, /opt/mlops/data)
#      para que otros procesos del sistema puedan hacer stat() sobre ellos.
# ──────────────────────────────────────────────
ensure_data_dir() {
    local canonical_path="/opt/mlops/data/raw/telco_churn.csv"
    local mlops_root="/opt/mlops"

    # ── Directorios requeridos por cada tarea del DAG ─────────────────────
    # Todos deben existir antes del primer run; el DAG no tiene permisos
    # para crearlos si el directorio padre pertenece a root.
    local -a required_dirs=(
        "/opt/mlops/data/raw"           # ingesta_datos
        "/opt/mlops/data/processed"     # preprocesamiento
        "/opt/mlops/data/processed/preprocessing_artifacts"  # preprocess artefactos
        "/opt/mlops/models"             # entrenamiento (feature_importance.csv)
    )

    log_info "Creando estructura de directorios del pipeline MLOps..."

    for dir in "${required_dirs[@]}"; do
        if [[ ! -d "$dir" ]]; then
            mkdir -p "$dir"
            log_info "  Creado: $dir"
        else
            log_skip "  Ya existe: $dir"
        fi
    done

    # ── Ownership: todo el árbol /opt/mlops/ pertenece a mlops ───────────
    # Esto permite que el proceso mlops cree archivos y subdirectorios
    # libremente en runtime (train.parquet, preprocessing_artifacts/, etc.)
    # sin necesitar escalada de privilegios.
    chown -R mlops:mlops "$mlops_root"
    log_info "Ownership mlops:mlops aplicado recursivamente a $mlops_root"

    # ── Traversal: o+x en los directorios de la jerarquía ────────────────
    # Necesario para que otros usuarios del sistema (azureuser, root en
    # comandos de diagnóstico) puedan hacer stat() sobre los subdirectorios
    # sin necesitar ser mlops ni pertenecer al grupo mlops.
    chmod o+x "$mlops_root" "$mlops_root/data"
    log_info "Permisos de traversal (o+x) aplicados a $mlops_root y $mlops_root/data"

    # ── Verificar que el dataset fuente está disponible ───────────────────
    if [[ -f "$canonical_path" ]]; then
        log_info "Dataset disponible: $canonical_path"
    else
        local data_raw_dir
        data_raw_dir="$(dirname "$canonical_path")"

        # Buscar el CSV con nombres alternativos en la misma carpeta
        local alt_csv="$data_raw_dir/CustomerChurn.csv"
        if [[ -f "$alt_csv" ]]; then
            cp "$alt_csv" "$canonical_path"
            chown mlops:mlops "$canonical_path"
            log_info "Dataset copiado desde nombre alternativo: $alt_csv → $canonical_path"
        else
            log_warn "═══════════════════════════════════════════════════════════"
            log_warn " AVISO: El dataset NO está disponible todavía."
            log_warn " El DAG quedará registrado en Airflow pero fallará en"
            log_warn " la tarea 'ingesta_datos' hasta que ejecutes:"
            log_warn ""
            log_warn "   make data-add CSV=<ruta>/CustomerChurn.csv"
            log_warn ""
            log_warn " Ese comando copia el CSV a $canonical_path,"
            log_warn " lo versiona con DVC y lo sube al remote MinIO."
            log_warn "═══════════════════════════════════════════════════════════"
        fi
    fi
}

# ──────────────────────────────────────────────
# 7. Instalar dependencias Python en /opt/mlops_venv
#
# Problema conocido en Python 3.12: setuptools (que provee pkg_resources)
# ya no se incluye en los venvs automáticamente. MLflow y otras librerías
# lo importan durante su propia instalación, por lo que si setuptools no
# está presente ANTES de que pip procese el resto del requirements.txt,
# la instalación falla con "No module named 'pkg_resources'".
#
# Solución: bootstrap en dos fases —
#   Fase 1: instalar setuptools y wheel primero, de forma aislada.
#   Fase 2: instalar el requirements.txt completo con setuptools ya disponible.
# ──────────────────────────────────────────────
install_python_deps() {
    local venv_pip="/opt/mlops_venv/bin/pip"
    local req_file="$PROJECT_ROOT/requirements.txt"

    if [[ ! -f "$venv_pip" ]]; then
        log_warn "No se encontró $venv_pip — omitiendo instalación de dependencias."
        return
    fi

    if [[ ! -f "$req_file" ]]; then
        log_warn "No se encontró requirements.txt en $PROJECT_ROOT — omitiendo instalación."
        return
    fi

    log_info "─── Fase 1: bootstrap de setuptools y wheel ───────────────"
    # setuptools provee pkg_resources; wheel acelera la instalación de
    # paquetes binarios. Ambos deben estar presentes antes de instalar
    # mlflow, airflow y cualquier librería que los importe en tiempo de build.
    if ! "$venv_pip" install \
            --quiet \
            --disable-pip-version-check \
            "setuptools>=70" "wheel"; then
        log_error "Falló el bootstrap de setuptools/wheel. Revisa la conectividad a PyPI."
        exit 1
    fi
    log_info "setuptools y wheel instalados"

    log_info "─── Fase 2: instalando requirements.txt completo ──────────"
    log_info "  Archivo: $req_file"
    if ! "$venv_pip" install \
            --quiet \
            --disable-pip-version-check \
            -r "$req_file"; then
        log_error "pip install -r requirements.txt falló."
        log_error "Ejecuta manualmente para ver el error completo:"
        log_error "  $venv_pip install -r $req_file"
        exit 1
    fi
    log_info "Dependencias instaladas correctamente"

    # Verificaciones rápidas de las dependencias críticas
    local checks=("openpyxl" "mlflow" "pkg_resources")
    for pkg in "${checks[@]}"; do
        if /opt/mlops_venv/bin/python -c "import $pkg" 2>/dev/null; then
            log_info "  ✓ $pkg disponible"
        else
            log_warn "  ✗ $pkg NO encontrado tras la instalación — revisa requirements.txt"
        fi
    done
}

# ──────────────────────────────────────────────
# 8. Reiniciar servicios de Airflow para aplicar cambios
# ──────────────────────────────────────────────
restart_airflow() {
    local services=("airflow-webserver" "airflow-scheduler")

    systemctl daemon-reload

    for svc in "${services[@]}"; do
        if systemctl is-active --quiet "$svc" 2>/dev/null; then
            log_info "Reiniciando $svc..."
            systemctl restart "$svc"
            log_info "$svc reiniciado"
        else
            log_warn "$svc no está activo — omitiendo restart (se aplicará en el próximo 'make start')"
        fi
    done
}

# ──────────────────────────────────────────────
# Main
# ──────────────────────────────────────────────
main() {
    if [[ "$EUID" -ne 0 ]]; then
        log_error "Este script debe ejecutarse como root (usa sudo)."
        exit 1
    fi

    log_info "============================================"
    log_info " Configurando DAGs de Airflow"
    log_info "============================================"

    check_preconditions
    fix_repo_permissions
    create_dags_dir
    disable_example_dags
    remove_example_dags
    link_project_dag
    link_src_dir
    ensure_data_dir
    install_python_deps
    restart_airflow

    echo ""
    log_info "============================================"
    log_info " Configuración completada"
    log_info "============================================"
    echo ""
    echo "  DAG disponible : churn_prediction_pipeline"
    echo "  Airflow UI     : http://IP_VM:8080"
    echo ""
    echo "  Si los DAGs de ejemplo siguen apareciendo en la UI,"
    echo "  espera ~30 s a que el scheduler refresque el DagBag, o:"
    echo "    make restart"
    echo ""
}

main "$@"