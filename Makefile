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

# Silencia el warning de gosnowflake/dbus que aparece en cada invocación
# de `vault` cuando no hay sesión de escritorio activa (servidor headless).
export DBUS_SESSION_BUS_ADDRESS ?= /dev/null

# Colores
GREEN  := \033[0;32m
YELLOW := \033[1;33m
NC     := \033[0m

.PHONY: help install provision vault-setup vault-unseal vault-secrets dvc-setup \
        start-minio start stop status restart logs test clean permissions

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
	@echo "    make vault-setup      → instalar y configurar HashiCorp Vault"
	@echo "    make vault-unseal     → desellar Vault si está sealed (safe re-run)"
	@echo "    make vault-secrets    → cargar secretos del .env en Vault"
	@echo "    make dvc-setup        → inicializar DVC y crear buckets en MinIO"
	@echo ""
	@echo "  Operación:"
	@echo "    make start            → arrancar todos los servicios"
	@echo "    make stop             → detener todos los servicios"
	@echo "    make restart          → reiniciar todos los servicios"
	@echo "    make status           → estado de todos los servicios"
	@echo "    make logs             → ver logs en tiempo real"
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
#   1. provision      → instala binarios y registra units systemd
#   2. vault-setup    → instala Vault, lo inicializa y configura AppRoles
#   3. vault-secrets  → escribe los secretos del .env en Vault
#   4. vault-unseal   → garantiza que Vault está unsealed justo antes
#                       de que los servicios intenten leer secretos
#   5. start-minio    → arranca MinIO; dvc-setup necesita el API en :9000
#   6. dvc-setup      → crea buckets e inicializa DVC
#   7. start          → arranca el resto de servicios
# ──────────────────────────────────────────────
install: permissions
	@echo -e "$(GREEN)[MAKE]$(NC) Iniciando despliegue completo..."
	@$(MAKE) provision
	@$(MAKE) vault-setup
	@$(MAKE) vault-secrets
	@$(MAKE) vault-unseal
	@$(MAKE) start-minio
	@$(MAKE) dvc-setup
	@$(MAKE) start
	@echo ""
	@echo -e "$(GREEN)[MAKE]$(NC) Despliegue completo. Ejecuta 'make status' para verificar."

# ──────────────────────────────────────────────
# Pasos individuales
# ──────────────────────────────────────────────
provision: permissions
	@echo -e "$(GREEN)[MAKE]$(NC) Aprovisionando VM..."
	@sudo bash $(SCRIPTS_DIR)/provision_vm.sh

vault-setup: permissions
	@echo -e "$(GREEN)[MAKE]$(NC) Configurando Vault..."
	@sudo bash $(VAULT_DIR)/setup_vault.sh

# Desella Vault si está sealed. No-op si ya está abierto.
# Invocar manualmente tras cualquier reinicio de la VM o del proceso vault.
vault-unseal: permissions
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
		sudo VAULT_TOKEN=$$ROOT_TOKEN bash $(VAULT_DIR)/write_secrets.sh

dvc-setup: permissions
	@echo -e "$(GREEN)[MAKE]$(NC) Configurando DVC..."
	@sudo bash $(SCRIPTS_DIR)/setup_dvc.sh

# ──────────────────────────────────────────────
# Operación de servicios
# ──────────────────────────────────────────────
SERVICES := minio mlflow-server airflow-webserver airflow-scheduler mlops-api

# Arranca solo MinIO. Usado en install para que dvc-setup pueda
# crear los buckets antes de que se lancen el resto de servicios.
start-minio:
	@echo -e "$(GREEN)[MAKE]$(NC) Arrancando MinIO..."
	@sudo systemctl start minio
	@echo -e "$(GREEN)[MAKE]$(NC) MinIO arrancado"

start:
	@echo -e "$(GREEN)[MAKE]$(NC) Arrancando servicios..."
	@sudo systemctl start $(SERVICES)
	@echo -e "$(GREEN)[MAKE]$(NC) Servicios arrancados. Ejecuta 'make status' para verificar."

stop:
	@echo -e "$(GREEN)[MAKE]$(NC) Deteniendo servicios..."
	@sudo systemctl stop $(SERVICES)

restart:
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
test:
	@echo -e "$(GREEN)[MAKE]$(NC) Ejecutando tests..."
	@python3 -m pytest tests/ -v

clean:
	@echo -e "$(GREEN)[MAKE]$(NC) Limpiando artefactos temporales..."
	@find . -type d -name "__pycache__" -exec rm -rf {} + 2>/dev/null || true
	@find . -name "*.pyc" -delete 2>/dev/null || true
	@rm -rf /tmp/mlops_plots/ 2>/dev/null || true
	@echo -e "$(GREEN)[MAKE]$(NC) Limpieza completada"