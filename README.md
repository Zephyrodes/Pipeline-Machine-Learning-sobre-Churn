# Pipeline Machine Learning sobre Churn

[![GitHub](https://img.shields.io/badge/GitHub-Zephyrodes-181717?logo=github)](https://github.com/Zephyrodes/Pipeline-Machine-Learning-sobre-Churn)
[![Python](https://img.shields.io/badge/Python-3.12-3776AB?logo=python)](https://www.python.org/)
[![Airflow](https://img.shields.io/badge/Apache%20Airflow-2.9.3-017CEE?logo=apacheairflow)](https://airflow.apache.org/)
[![MLflow](https://img.shields.io/badge/MLflow-2.15.1-0194E2?logo=mlflow)](https://mlflow.org/)
[![DVC](https://img.shields.io/badge/DVC-3.51-945DD6?logo=dvc)](https://dvc.org/)
[![FastAPI](https://img.shields.io/badge/FastAPI-0.112-009688?logo=fastapi)](https://fastapi.tiangolo.com/)
[![Vault](https://img.shields.io/badge/HashiCorp%20Vault-1.17-FFEC6E?logo=vault&logoColor=black)](https://www.vaultproject.io/)

Pipeline MLOps end-to-end para predicción de churn de clientes sobre una VM Linux bare-metal.
Orquestado con Airflow, versionado de datos con DVC, tracking y registro de modelos con MLflow,
artefactos en MinIO, secretos gestionados con HashiCorp Vault y servicio de inferencia con
FastAPI administrado por systemd.

---

## Índice

1. [Arquitectura](#arquitectura)
2. [Stack técnico](#stack-técnico)
3. [Estructura del repositorio](#estructura-del-repositorio)
4. [Prerequisitos](#prerequisitos)
5. [Instalación](#instalación)
6. [Configuración de DVC](#configuración-de-dvc)
7. [Ejecución del pipeline](#ejecución-del-pipeline)
8. [Interfaces web](#interfaces-web)
9. [API de inferencia](#api-de-inferencia)

---

## Arquitectura

```
┌─────────────────────────────────────────────────────────┐
│  HashiCorp Vault (systemd)                              │
│  Motor KV v2 — AppRole por servicio                     │
│                                                         │
│  mlops/minio · mlops/airflow · mlops/mlflow · mlops/fastapi │
└──────────┬──────────────────────────────────────────────┘
           │  fetch_secrets.sh (ExecStartPre=)
           │  AppRole auth → credenciales en tmpfs
           │  source credentials → proceso
           ▼
┌──────────────────────────────────────────────────────────┐
│  Pipeline MLOps                                          │
│                                                         │
│  Fuente CSV                                              │
│      │                                                   │
│      ▼                                                   │
│   DVC add/push  ──────────────────► MinIO (s3://dvc-data)│
│      │                                      │ artifacts  │
│      ▼                                      │            │
│  Apache Airflow DAG                         │            │
│    ├── ingesta_datos                        │            │
│    ├── preprocesamiento                     │            │
│    ├── entrenamiento ──────► MLflow ────────┘            │
│    ├── evaluacion    ──────► (tracking + registry)       │
│    └── registro_modelo               │                   │
│                                      ▼                   │
│                          FastAPI /predict  (systemd)     │
│                                      │                   │
│                                      ▼                   │
│                               Cliente / curl             │
└──────────────────────────────────────────────────────────┘
```

### Flujo de secretos

```
Vault KV v2
    │
    │  AppRole (role_id + secret_id por servicio)
    ▼
fetch_secrets.sh          ← ExecStartPre= de cada unit systemd
    │
    │  VAULT_ADDR fijado a http://127.0.0.1:8200 (siempre HTTP,
    │  independiente del entorno heredado por sudo)
    │  escribe en /run/mlops-secrets/<servicio>/  (tmpfs)
    │  recreado en cada arranque por systemd-tmpfiles
    ▼
source credentials        ← ExecStart= lee y exporta las variables
    │
    ▼
minio / mlflow / airflow / fastapi
```

### Árbol de permisos de Vault

```
/etc/mlops/vault-init/              root:mlops  710  ← traversal sin listar
/etc/mlops/vault-init/init.json     root:root   600  ← solo root (unseal keys + root token)
/etc/mlops/vault-init/<servicio>/   root:mlops  750  ← mlops puede leer
/etc/mlops/vault-init/<servicio>/role_id        640
/etc/mlops/vault-init/<servicio>/secret_id      640
```

---

## Stack técnico

| Herramienta | Rol | Puerto |
|---|---|---|
| **HashiCorp Vault 1.17** | Gestión de secretos (KV v2 + AppRole) | 8200 (loopback) |
| **Apache Airflow 2.9** | Orquestación del pipeline | 8080 |
| **MLflow 2.15** | Tracking de experimentos + Model Registry | 5000 |
| **MinIO** | Almacén de artefactos S3-compatible | 9000 / 9001 |
| **DVC 3.51** | Versionado de datasets | — |
| **FastAPI** | Servicio de inferencia REST | 8000 |
| **scikit-learn** | Modelo RandomForestClassifier | — |
| **systemd** | Gestión de procesos y entrega de credenciales | — |
| **Bash** | Aprovisionamiento de la VM | — |

---

## Estructura del repositorio

```
Pipeline-Machine-Learning-sobre-Churn/
├── dags/
│   └── dag_churn_pipeline.py
├── src/
│   ├── data/
│   │   ├── ingest.py
│   │   └── preprocess.py
│   ├── models/
│   │   ├── train.py
│   │   ├── evaluate.py
│   │   └── register.py
│   └── api/
│       └── app.py
├── scripts/
│   ├── provision_vm.sh
│   ├── setup_dvc.sh
│   └── vault/
│       ├── setup_vault.sh        # Instala Vault, configura KV y AppRole
│       ├── write_secrets.sh      # Escribe credenciales en Vault KV
│       └── fetch_secrets.sh      # Obtiene secretos (llamado por systemd)
├── dvc/
│   └── .dvcconfig
├── tests/
│   └── test_pipeline.py
├── data/
│   ├── raw/
│   │   └── CustomerChurn.csv     # Excluido de git — versionado con DVC
│   └── processed/                # Generado por el pipeline (Parquet)
├── Makefile                      # Punto de entrada único para despliegue y operación
├── .env                          # Rellenar y cargar en Vault (excluido de git)
├── .gitignore
├── requirements.txt
└── README.md
```

---

## Prerequisitos

- Ubuntu 22.04 LTS
- 4 GB RAM mínimo
- 20 GB de disco mínimo
- Acceso root

---

## Instalación

El proyecto usa `make` como punto de entrada único. Gestiona los permisos de los
scripts, el orden de ejecución y las llamadas a `sudo` automáticamente.

### Despliegue completo

```bash
git clone https://github.com/Zephyrodes/Pipeline-Machine-Learning-sobre-Churn.git
cd Pipeline-Machine-Learning-sobre-Churn
nano .env        # completar con los valores reales
make install
```

`make install` ejecuta en orden: permisos → aprovisionamiento → Vault → secretos → usuario admin de Airflow → MinIO → DVC → arranque de servicios.

### Pasos individuales

Si se necesita ejecutar una etapa por separado:

```bash
make permissions           # dar permisos de ejecución a todos los scripts
make provision             # instalar dependencias, registrar servicios systemd, configurar PATH y AIRFLOW_HOME
make vault-setup           # instalar y configurar HashiCorp Vault
make vault-secrets         # cargar el .env en Vault
make airflow-create-admin  # crear el usuario admin de Airflow leyendo credenciales desde Vault
make dvc-setup             # inicializar DVC, crear buckets en MinIO y corregir ownership
make start                 # arrancar todos los servicios (con auto-recovery del lock de Vault)
```

```bash
make status           # estado de los servicios
make logs             # logs en tiempo real
make restart          # reiniciar todos los servicios
make test             # ejecutar suite de tests (usa pytest del venv directamente)
make data-add         # versionar dataset con DVC y hacer push a MinIO
make help             # ver todos los comandos disponibles
```

### Detalle de cada paso

**`make provision`** — instala Python 3.12, dependencias del sistema y del proyecto,
registra los servicios en systemd (MinIO, MLflow, Airflow, FastAPI), configura
el firewall y añade el venv (`/opt/mlops_venv/bin`) al `PATH` del usuario operador
en `~/.bashrc`, junto con `AIRFLOW_HOME=/opt/airflow`. No arranca los servicios.

**`make vault-setup`** — instala Vault, lo inicializa, habilita el motor KV v2,
crea la política `mlops-services` y genera un AppRole por servicio. Las unseal keys
y el root token se guardan en `/etc/mlops/vault-init/init.json` (`chmod 600`,
propietario `root:root`). Los archivos `role_id` y `secret_id` de cada servicio
quedan con propietario `root:mlops` y permisos `640` para que `ExecStartPre=`
pueda leerlos.

**`make vault-secrets`** — lee el `.env` y escribe las credenciales en los paths
del KV: `mlops/minio`, `mlops/airflow`, `mlops/mlflow`, `mlops/fastapi`. Pasa
`VAULT_ADDR=http://127.0.0.1:8200` explícitamente al invocar `sudo` para evitar
que Vault use su default HTTPS contra el listener HTTP de la VM.

**`make airflow-create-admin`** — lee las credenciales de `mlops/airflow` en Vault
y crea el usuario admin de Airflow en la base de datos de `/opt/airflow`. Es
idempotente: si el usuario ya existe no falla. Debe ejecutarse después de
`vault-secrets` y antes o después de arrancar `airflow-webserver`. No forma parte
de `provision` porque en ese momento Vault aún no existe.

**`make start`** — arranca los cinco servicios. Antes de hacerlo, ejecuta
`vault-unseal` que detecta y recupera automáticamente el lock de BoltDB de Raft
si Vault falló al arrancar (error `failed to open bolt file: timeout`). Cada
servicio ejecuta `fetch_secrets.sh` como `ExecStartPre=`, autentica con Vault
via AppRole y deposita las credenciales en `/run/mlops-secrets/<servicio>/credentials`
(tmpfs). `VAULT_ADDR` se fija a HTTP dentro de cada script para que funcione
correctamente aunque `sudo` limpie el entorno.

> **Nota sobre `AIRFLOW_HOME`:** los comandos de administración de Airflow (`airflow users list`,
> `airflow dags list`, etc.) deben ejecutarse con `AIRFLOW_HOME=/opt/airflow` apuntando
> al mismo directorio que usa el servicio systemd. `make provision` escribe esta variable
> en `~/.bashrc` del usuario operador; para la sesión actual ejecuta `source ~/.bashrc`
> o bien `export AIRFLOW_HOME=/opt/airflow`.

---

## Configuración de DVC

```bash
make dvc-setup
```

Crea los buckets `dvc-data` y `mlflow-artifacts` en MinIO, inicializa DVC y
configura el remote. Las credenciales quedan en `.dvc/config.local`, excluido de git.
Activa `core.autostage` y corrige el ownership de `.git/`, `.dvc/`, `data/` y `models/`
para que el usuario operador pueda ejecutar comandos DVC sin `sudo`.

### Dataset

Coloca el archivo `CustomerChurn.csv` en `data/raw/` y versiona con un solo comando:

```bash
cp /ruta/a/tu/CustomerChurn.csv data/raw/CustomerChurn.csv
make data-add
```

`make data-add` ejecuta en orden: `dvc add` → `git commit` → `dvc push` a MinIO.
Para un CSV en ruta diferente: `make data-add CSV=data/raw/otro.csv`

---

## Ejecución del pipeline

1. Abrir Airflow en `http://IP_VM:8080`
2. Activar el DAG `churn_prediction_pipeline` → **Trigger DAG**

El seguimiento de experimentos y versiones del modelo está en MLflow (`http://IP_VM:5000`).
Los artefactos se almacenan en MinIO (`http://IP_VM:9001`).

### Disparar un nuevo experimento

```bash
vim dags/dag_churn_pipeline.py   # editar hiperparámetros

git add dags/dag_churn_pipeline.py
git commit -m "exp: n_estimators 200 → 300"
# Trigger DAG nuevamente desde Airflow UI
```

---

## Interfaces web

| Servicio | URL |
|---|---|
| Airflow UI | `http://IP_VM:8080` |
| MLflow UI | `http://IP_VM:5000` |
| MinIO Console | `http://IP_VM:9001` |
| FastAPI Docs | `http://IP_VM:8000/docs` |

---

## API de inferencia

| Método | Ruta | Descripción |
|---|---|---|
| GET | `/health` | Estado del servicio y modelo cargado |
| GET | `/model/info` | Versión y parámetros del modelo en producción |
| POST | `/predict` | Predicción individual de churn |
| POST | `/predict/batch` | Predicción en lote (hasta 500 clientes) |
| POST | `/model/reload` | Recarga el modelo sin reiniciar el proceso |

```bash
curl -X POST http://localhost:8000/predict \
  -H "Content-Type: application/json" \
  -d '{
    "SeniorCitizen": 0, "Partner": 1, "Dependents": 0,
    "tenure": 12.0, "PhoneService": 1, "MultipleLines": 0,
    "InternetService": 1, "OnlineSecurity": 0, "OnlineBackup": 0,
    "DeviceProtection": 0, "TechSupport": 0, "StreamingTV": 1,
    "StreamingMovies": 1, "Contract": 0, "PaperlessBilling": 1,
    "PaymentMethod": 2, "MonthlyCharges": 65.50, "TotalCharges": 786.0
  }'
```

```json
{
  "churn_prediction": 1,
  "churn_probability": 0.7823,
  "risk_level": "alto",
  "model_version": "3"
}
```

---

## Autor

**Zephyrodes** — [github.com/Zephyrodes](https://github.com/Zephyrodes)