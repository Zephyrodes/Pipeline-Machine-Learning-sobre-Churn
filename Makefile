# =============================================================================
# Makefile — Pipeline Machine Learning sobre Churn
# Punto de entrada único para todo el despliegue y operación del pipeline.
#
# Uso:
#   make help          → ver todos los comandos disponibles
#   make install       → despliegue completo desde cero
# =============================================================================

SHELL := /bin/bash
SCRIPTS_DIR := scripts
VAULT_DIR   := scripts/vault

# Ruta del entorno virtual del proyecto
VENV_BIN := /opt/mlops_venv/bin

# Ruta canónica del dataset que espera el DAG (dag_churn_pipeline.py)
DATA_RAW_CANONICAL := /opt/mlops/data/raw/telco_churn.csv

# Silencia el warning de gosnowflake/dbus que aparece en cada invocación
# de `vault` cuando no hay sesión de escritorio activa (servidor headless).
export DBUS_SESSION_BUS_ADDRESS ?= /dev/null

# Colores
GREEN  := \033[0;32m
YELLOW := \033[1;33m
NC     := \033[0m

.PHONY: help install provision configure-env vault-setup vault-unseal vault-secrets \
        airflow-create-admin airflow-setup-dags dvc-setup start-minio start stop status restart logs test clean permissions data-add \
        fix-airflow-units

# ──────────────────────────────────────────────
# Ayuda
# ──────────────────────────────────────────────
help:
	@echo ""
	@echo "  Pipeline Machine Learning sobre Churn"
	@echo ""
	@echo "  Despliegue completo:"
	@echo "    make install          → ejecuta todo en orden"
	@echo ""
	@echo "  Pasos individuales:"
	@echo "    make permissions      → dar permisos de ejecución a todos los scripts"
	@echo "    make provision        → instalar dependencias y registrar servicios"
	@echo "    make configure-env    → añadir el venv al PATH del usuario operador"
	@echo "    make vault-setup      → instalar y configurar HashiCorp Vault"
	@echo "    make vault-unseal     → desellar Vault si está sealed (safe re-run)"
	@echo "    make vault-secrets         → cargar secretos del .env en Vault"
	@echo "    make airflow-create-admin  → crear usuario admin de Airflow (post-Vault)"
	@echo "    make airflow-setup-dags    → desactivar ejemplos y registrar el DAG del proyecto"
	@echo "    make dvc-setup             → inicializar DVC y crear buckets en MinIO"
	@echo ""
	@echo "  Operación:"
	@echo "    make start            → arrancar todos los servicios"
	@echo "    make stop             → detener todos los servicios"
	@echo "    make restart          → reiniciar todos los servicios"
	@echo "    make status           → estado de todos los servicios"
	@echo "    make logs             → ver logs en tiempo real"
	@echo ""
	@echo "  Datos:"
	@echo "    make data-add         → versionar el dataset con DVC y hacer push a MinIO"
	@echo ""
	@echo "  Desarrollo:"
	@echo "    make test             → ejecutar suite de tests"
	@echo "    make clean            → limpiar artefactos temporales"
	@echo ""

# ──────────────────────────────────────────────
# Permisos — se aplican antes de cualquier otra cosa
# ──────────────────────────────────────────────
permissions:
	@echo -e "$(GREEN)[MAKE]$(NC) Aplicando permisos de ejecución a todos los scripts..."
	@find $(SCRIPTS_DIR) -name "*.sh" -exec chmod +x {} \;
	@echo -e "$(GREEN)[MAKE]$(NC) Permisos aplicados"

# ──────────────────────────────────────────────
# Despliegue completo en orden
#
# Orden crítico:
#   1. provision          → instala binarios, registra units systemd
#                           y configura el PATH del venv en .bashrc
#   2. vault-setup        → instala Vault, lo inicializa y configura AppRoles
#   3. vault-secrets      → escribe los secretos del .env en Vault
#   4. vault-unseal       → garantiza que Vault está unsealed justo antes
#                           de que los servicios intenten leer secretos
#   5. start-minio        → arranca MinIO; dvc-setup necesita el API en :9000
#   6. airflow-create-admin → crea el usuario admin de Airflow
#   7. dvc-setup          → crea buckets e inicializa DVC
#   8. start              → arranca el resto de servicios (Airflow ya corriendo)
#   9. airflow-setup-dags → desactiva los DAGs de ejemplo y publica el DAG del
#                           proyecto; el restart al final del script es efectivo
#                           porque los servicios ya están activos
# ──────────────────────────────────────────────
install: permissions
	@echo -e "$(GREEN)[MAKE]$(NC) Iniciando despliegue completo..."
	@$(MAKE) provision
	@$(MAKE) vault-setup
	@$(MAKE) vault-secrets
	@$(MAKE) vault-unseal
	@$(MAKE) start-minio
	@$(MAKE) airflow-create-admin
	@$(MAKE) dvc-setup
	@$(MAKE) fix-airflow-units
	@$(MAKE) start
	@$(MAKE) airflow-setup-dags
	@echo ""
	@echo -e "$(GREEN)[MAKE]$(NC) Despliegue completo. Ejecuta 'make status' para verificar."
	@echo ""
	@echo -e "$(YELLOW)[NOTE]$(NC) Para activar el PATH del venv en esta sesión ejecuta:"
	@echo -e "         source ~/.bashrc"
	@echo -e "         Las próximas sesiones SSH lo tendrán activo automáticamente."
	@echo ""
	@# Usar sudo test para no fallar por permisos de traversal en /opt/mlops/
	@if sudo test -f "$(DATA_RAW_CANONICAL)"; then \
		echo -e "$(GREEN)[OK]$(NC)   Dataset listo en $(DATA_RAW_CANONICAL)"; \
	else \
		echo -e "$(YELLOW)[NOTE]$(NC) El dataset aún no está en la ruta del DAG."; \
		echo -e "         El pipeline fallará en 'ingesta_datos' hasta que ejecutes:"; \
		echo -e "           make data-add CSV=<ruta>/CustomerChurn.csv"; \
	fi

# ──────────────────────────────────────────────
# Pasos individuales
# ──────────────────────────────────────────────
provision: permissions
	@echo -e "$(GREEN)[MAKE]$(NC) Aprovisionando VM..."
	@sudo bash $(SCRIPTS_DIR)/provision_vm.sh
	@$(MAKE) configure-env

# Añade el venv al PATH del usuario operador (el que invocó sudo, no root).
# Idempotente: no duplica la línea si ya existe en .bashrc.
# También instala herramientas de desarrollo (pytest) si no están presentes.
# NOTA: make no puede recargar el entorno de la shell padre (limitación Unix).
#       El PATH estará disponible automáticamente en la próxima sesión SSH.
#       Para la sesión actual ejecuta: source ~/.bashrc
configure-env:
	@echo -e "$(GREEN)[MAKE]$(NC) Configurando PATH del entorno virtual..."
	@OPERATOR_USER="$${SUDO_USER:-$$(logname 2>/dev/null || echo azureuser)}"; \
	OPERATOR_HOME=$$(eval echo "~$$OPERATOR_USER"); \
	BASHRC="$$OPERATOR_HOME/.bashrc"; \
	VENV_LINE='export PATH="$(VENV_BIN):$$PATH"'; \
	if ! grep -qF '$(VENV_BIN)' "$$BASHRC" 2>/dev/null; then \
		echo "$$VENV_LINE" >> "$$BASHRC"; \
		echo -e "$(GREEN)[MAKE]$(NC) PATH del venv añadido a $$BASHRC para $$OPERATOR_USER"; \
	else \
		echo -e "$(GREEN)[SKIP]$(NC) PATH del venv ya presente en $$BASHRC"; \
	fi; \
	AIRFLOW_LINE='export AIRFLOW_HOME=/opt/airflow'; \
	if ! grep -qF 'AIRFLOW_HOME' "$$BASHRC" 2>/dev/null; then \
		echo "$$AIRFLOW_LINE" >> "$$BASHRC"; \
		echo -e "$(GREEN)[MAKE]$(NC) AIRFLOW_HOME=/opt/airflow añadido a $$BASHRC"; \
	else \
		echo -e "$(GREEN)[SKIP]$(NC) AIRFLOW_HOME ya presente en $$BASHRC"; \
	fi
	@echo -e "$(GREEN)[MAKE]$(NC) Verificando herramientas de desarrollo..."
	@if [ ! -f "$(VENV_BIN)/pytest" ]; then \
		echo -e "$(GREEN)[MAKE]$(NC) Instalando pytest en el venv..."; \
		sudo $(VENV_BIN)/pip install pytest --quiet; \
		echo -e "$(GREEN)[MAKE]$(NC) pytest instalado"; \
	else \
		echo -e "$(GREEN)[SKIP]$(NC) pytest ya instalado"; \
	fi

vault-setup: permissions
	@echo -e "$(GREEN)[MAKE]$(NC) Configurando Vault..."
	@sudo bash $(VAULT_DIR)/setup_vault.sh

# Ruta del almacenamiento Raft de Vault (BoltDB)
VAULT_RAFT_PATH := /opt/vault/data

# Desella Vault si está sealed. No-op si ya está abierto.
# Recupera automáticamente el lock de BoltDB si Vault falló al arrancar
# (síntoma: "failed to open bolt file: timeout" en journalctl).
# Invocar manualmente tras cualquier reinicio de la VM o del proceso vault.
vault-unseal: permissions
	@echo -e "$(GREEN)[MAKE]$(NC) Verificando estado de Vault..."
	@if sudo systemctl is-failed --quiet vault.service 2>/dev/null; then \
		echo -e "$(YELLOW)[WARN]$(NC) vault.service en estado failed — comprobando causa..."; \
		if sudo journalctl -u vault.service -n 20 --no-pager 2>/dev/null \
				| grep -q "bolt file: timeout"; then \
			echo -e "$(YELLOW)[WARN]$(NC) BoltDB lock detectado — liberando y reiniciando Vault..."; \
			sudo pkill -9 vault 2>/dev/null || true; \
			sudo rm -f $(VAULT_RAFT_PATH)/vault.db.lock 2>/dev/null || true; \
			sudo systemctl reset-failed vault.service; \
			sudo systemctl start vault.service; \
			sleep 3; \
			if ! sudo systemctl is-active --quiet vault.service; then \
				echo -e "$(YELLOW)[ERROR]$(NC) Vault no arrancó tras limpiar el lock."; \
				echo -e "         Revisa: sudo journalctl -u vault -n 30 --no-pager"; \
				exit 1; \
			fi; \
			echo -e "$(GREEN)[MAKE]$(NC) Vault reiniciado correctamente tras limpiar BoltDB lock"; \
		else \
			echo -e "$(YELLOW)[WARN]$(NC) vault.service falló por causa desconocida — intentando restart..."; \
			sudo systemctl reset-failed vault.service; \
			sudo systemctl start vault.service; \
			sleep 3; \
		fi; \
	fi
	@echo -e "$(GREEN)[MAKE]$(NC) Verificando/desellando Vault..."
	@sudo bash $(VAULT_DIR)/setup_vault.sh --unseal

vault-secrets: permissions
	@echo -e "$(GREEN)[MAKE]$(NC) Cargando secretos en Vault..."
	@if [ ! -f .env ]; then \
		echo -e "$(YELLOW)[WARN]$(NC) No se encontró .env — complétalo antes de continuar:"; \
		echo "  nano .env"; \
		exit 1; \
	fi
	@ROOT_TOKEN=$$(sudo python3 -c "import json; print(json.load(open('/etc/mlops/vault-init/init.json'))['root_token'])") && \
		sudo VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN=$$ROOT_TOKEN bash $(VAULT_DIR)/write_secrets.sh

# Crea el usuario admin de Airflow leyendo las credenciales desde Vault.
# Debe ejecutarse DESPUÉS de vault-secrets y ANTES (o después) de arrancar
# airflow-webserver — airflow users create es idempotente.
# No va en provision porque en ese momento Vault aún no existe.
airflow-create-admin: permissions
	@echo -e "$(GREEN)[MAKE]$(NC) Creando usuario admin de Airflow desde Vault..."
	@ROOT_TOKEN=$$(sudo python3 -c "import json; print(json.load(open('/etc/mlops/vault-init/init.json'))['root_token'])"); \
	CREDS=$$(sudo VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN=$$ROOT_TOKEN \
		vault kv get -format=json mlops/airflow \
		| python3 -c \
		"import sys,json; d=json.load(sys.stdin)['data']['data']; \
		[print(k.upper()+'='+v) for k,v in d.items()]"); \
	ADMIN_USER=$$(echo "$$CREDS" | grep ^ADMIN_USER= | cut -d= -f2); \
	ADMIN_PASSWORD=$$(echo "$$CREDS" | grep ^ADMIN_PASSWORD= | cut -d= -f2); \
	ADMIN_EMAIL=$$(echo "$$CREDS" | grep ^ADMIN_EMAIL= | cut -d= -f2); \
	sudo -u mlops \
		AIRFLOW_HOME=/opt/airflow \
		PATH=$(VENV_BIN):$$PATH \
		/opt/mlops_venv/bin/airflow users create \
			--username "$$ADMIN_USER" \
			--firstname Admin \
			--lastname MLOps \
			--role Admin \
			--email "$$ADMIN_EMAIL" \
			--password "$$ADMIN_PASSWORD" 2>/dev/null \
		&& echo -e "$(GREEN)[MAKE]$(NC) Usuario admin creado: $$ADMIN_USER" \
		|| echo -e "$(YELLOW)[SKIP]$(NC) El usuario admin ya existe (idempotente)"

# Desactiva los DAGs de ejemplo de Airflow y publica el DAG del proyecto.
# Crea los symlinks necesarios en /opt/airflow/dags/ y parchea airflow.cfg.
# Idempotente: seguro de re-ejecutar si se añaden nuevos DAGs al proyecto.
airflow-setup-dags: permissions
	@echo -e "$(GREEN)[MAKE]$(NC) Configurando DAGs de Airflow..."
	@sudo bash $(SCRIPTS_DIR)/setup_airflow_dags.sh
	@echo -e "$(GREEN)[MAKE]$(NC) DAGs configurados — el DAG 'churn_prediction_pipeline' ya está disponible"

# Regenera los unit files de Airflow con el fix de credenciales AWS/boto3 y
# hace daemon-reload + restart de los servicios afectados.
#
# Cuándo usarlo:
#   - En una VM ya desplegada donde make install o make provision se ejecutó
#     con la versión anterior de provision_vm.sh (sin fetch_secrets mlflow).
#   - Después de cualquier cambio en create_airflow_systemd_services().
#
# Qué hace:
#   1. Invoca provision_vm.sh --only-units para regenerar los .service files.
#      --only-units omite apt-get, pip, creación de usuario y firewall.
#   2. systemd daemon-reload (lo hace register_service dentro del script).
#   3. Reinicia webserver y scheduler para que arranquen con el nuevo
#      ExecStartPre=fetch_secrets.sh mlflow y los EnvironmentFile actualizados.
fix-airflow-units: permissions
	@echo -e "$(GREEN)[MAKE]$(NC) Regenerando units de Airflow con fix de credenciales AWS/boto3..."
	@sudo bash $(SCRIPTS_DIR)/provision_vm.sh --only-units
	@echo -e "$(GREEN)[MAKE]$(NC) Reiniciando airflow-webserver y airflow-scheduler..."
	@sudo systemctl restart airflow-webserver airflow-scheduler
	@echo -e "$(GREEN)[MAKE]$(NC) Units actualizados y servicios reiniciados"
	@echo -e "$(GREEN)[MAKE]$(NC) Verifica con: sudo journalctl -u airflow-scheduler -n 30 --no-pager"

dvc-setup: permissions
	@echo -e "$(GREEN)[MAKE]$(NC) Configurando DVC..."
	@sudo bash $(SCRIPTS_DIR)/setup_dvc.sh
	@OPERATOR_USER="$${SUDO_USER:-$$(logname 2>/dev/null || echo azureuser)}"; \
	for dir in .git .dvc data models; do \
		if [ -d "$$dir" ] && [ "$$(stat -c '%U' $$dir 2>/dev/null)" != "$$OPERATOR_USER" ]; then \
			echo -e "$(GREEN)[MAKE]$(NC) Corrigiendo ownership de $$dir/ → $$OPERATOR_USER"; \
			sudo chown -R "$$OPERATOR_USER":"$$OPERATOR_USER" "$$dir"/; \
		fi; \
	done

# ──────────────────────────────────────────────
# Operación de servicios
# ──────────────────────────────────────────────
SERVICES := minio mlflow-server airflow-webserver airflow-scheduler mlops-api

# Arranca MinIO asegurando que las credenciales en disco coincidan
# con las que Vault tiene escritas. Si MinIO arrancó previamente con
# credenciales distintas (p.ej. minioadmin:minioadmin por defecto),
# el script limpia el estado persistido y lo reinicia limpio.
# Si el servicio lleva varios ciclos fallidos (StartLimitBurst), se hace
# reset-failed antes para que systemd permita el siguiente intento.
start-minio:
	@echo -e "$(GREEN)[MAKE]$(NC) Arrancando MinIO..."
	@if sudo systemctl is-failed --quiet minio.service 2>/dev/null; then \
		echo -e "$(YELLOW)[WARN]$(NC) minio.service en estado failed — reseteando contadores..."; \
		sudo systemctl reset-failed minio.service; \
	fi
	@sudo bash $(SCRIPTS_DIR)/start_minio.sh
	@echo -e "$(GREEN)[MAKE]$(NC) MinIO listo"

start: vault-unseal
	@echo -e "$(GREEN)[MAKE]$(NC) Arrancando servicios..."
	@sudo systemctl start $(SERVICES)
	@echo -e "$(GREEN)[MAKE]$(NC) Servicios arrancados. Ejecuta 'make status' para verificar."

stop:
	@echo -e "$(GREEN)[MAKE]$(NC) Deteniendo servicios..."
	@sudo systemctl stop $(SERVICES)

restart: vault-unseal fix-airflow-units
	@echo -e "$(GREEN)[MAKE]$(NC) Reiniciando servicios..."
	@sudo systemctl restart $(SERVICES)

status:
	@sudo systemctl status $(SERVICES) --no-pager

logs:
	@sudo journalctl -u minio -u mlflow-server -u airflow-webserver \
		-u airflow-scheduler -u mlops-api -f

# ──────────────────────────────────────────────
# Desarrollo
# ──────────────────────────────────────────────

# Usa el pytest del venv directamente para garantizar que encuentra
# todas las dependencias del proyecto sin necesidad de activar el venv.
test:
	@echo -e "$(GREEN)[MAKE]$(NC) Ejecutando tests..."
	@$(VENV_BIN)/pytest tests/ -v

# Versiona el dataset con DVC y hace push a MinIO.
# Usa rutas absolutas del venv — no requiere activar el entorno ni source .bashrc.
# Uso: make data-add CSV=data/raw/CustomerChurn.csv
CSV ?= data/raw/CustomerChurn.csv

data-add:
	@if [ ! -f "$(CSV)" ]; then \
		echo -e "$(YELLOW)[WARN]$(NC) No se encontró el archivo: $(CSV)"; \
		echo -e "         Uso: make data-add CSV=<ruta>/CustomerChurn.csv"; \
		exit 1; \
	fi
	@# ── Crear directorio y fijar permisos de traversal ──────────────────
	@# /opt/mlops/ y subdirectorios necesitan o+x para que azureuser y los
	@# procesos del sistema puedan hacer stat() aunque el owner sea mlops.
	@sudo mkdir -p "$$(dirname $(DATA_RAW_CANONICAL))"
	@sudo chmod o+x /opt/mlops /opt/mlops/data /opt/mlops/data/raw
	@# ── Copiar el CSV a la ruta canónica del DAG ─────────────────────────
	@echo -e "$(GREEN)[MAKE]$(NC) Copiando dataset a la ruta del DAG..."
	@sudo cp "$(CSV)" "$(DATA_RAW_CANONICAL)"
	@sudo chown mlops:mlops "$(DATA_RAW_CANONICAL)"
	@echo -e "$(GREEN)[MAKE]$(NC) Dataset disponible en $(DATA_RAW_CANONICAL)"
	@# ── Versionar con DVC el archivo del repo ────────────────────────────
	@echo -e "$(GREEN)[MAKE]$(NC) Versionando $(CSV) con DVC..."
	@$(VENV_BIN)/dvc add $(CSV)
	@if git diff --cached --quiet; then \
		echo -e "$(YELLOW)[SKIP]$(NC) Sin cambios para commitear en git"; \
	else \
		git commit -m "data: añadir $$(basename $(CSV)) v$$(date +%Y%m%d)"; \
	fi
	@echo -e "$(GREEN)[MAKE]$(NC) Haciendo push a MinIO..."
	@$(VENV_BIN)/dvc push
	@echo -e "$(GREEN)[MAKE]$(NC) Dataset versionado y disponible en MinIO"

clean:
	@echo -e "$(GREEN)[MAKE]$(NC) Limpiando artefactos temporales..."
	@find . -type d -name "__pycache__" -exec rm -rf {} + 2>/dev/null || true
	@find . -name "*.pyc" -delete 2>/dev/null || true
	@rm -rf /tmp/mlops_plots/ 2>/dev/null || true
	@echo -e "$(GREEN)[MAKE]$(NC) Limpieza completada"