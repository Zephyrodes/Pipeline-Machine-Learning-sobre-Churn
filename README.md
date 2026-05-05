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
           │  LoadCredential= → proceso (nunca en /proc)
           ▼
┌──────────────────────────────────────────────────────────┐
│  Pipeline MLOps                                          │
│                                                          │
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
    │  escribe en /run/mlops-secrets/<servicio>/  (tmpfs)
    ▼
LoadCredential=           ← systemd entrega al proceso via CREDENTIALS_DIR
    │
    ▼
minio / mlflow / airflow / fastapi
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
│   │   └── CustomerChurn.csv       # Excluido de git — versionado con DVC
│   └── processed/                  # Generado por el pipeline (Parquet)
├── .env                            # Rellenar y cargar en Vault (excluido de git)
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

### 1. Clonar el repositorio

```bash
git clone https://github.com/Zephyrodes/Pipeline-Machine-Learning-sobre-Churn.git
cd Pipeline-Machine-Learning-sobre-Churn
```

### 2. Aprovisionar la VM

```bash
sudo ./scripts/provision_vm.sh
```

Instala las dependencias del sistema, registra los servicios en systemd
(MinIO, MLflow, Airflow, FastAPI) y configura el firewall.
**No arranca los servicios** — eso ocurre después de configurar Vault.

### 3. Configurar Vault

```bash
sudo ./scripts/vault/setup_vault.sh
```

Instala Vault, lo inicializa, habilita el motor KV v2, crea la política
`mlops-services` y genera un AppRole por servicio. Las unseal keys y el
root token se guardan en `/etc/mlops/vault-init/init.json` con permisos `600`.

### 4. Escribir los secretos en Vault

Completa el `.env` con tus credenciales y ejecuta:

```bash
sudo VAULT_TOKEN=$(python3 -c "import json; \
  print(json.load(open('/etc/mlops/vault-init/init.json'))['root_token'])") \
  ./scripts/vault/write_secrets.sh
```

Lee el `.env` y escribe las credenciales en los paths del KV:
`mlops/minio`, `mlops/airflow`, `mlops/mlflow`, `mlops/fastapi`.

### 5. Iniciar los servicios

```bash
sudo systemctl start minio mlflow-server airflow-webserver airflow-scheduler mlops-api
sudo systemctl status minio mlflow-server airflow-webserver airflow-scheduler mlops-api
```

Cada servicio ejecuta `fetch_secrets.sh` como `ExecStartPre=`, autentica
con Vault via AppRole y deposita las credenciales en `/run/mlops-secrets/<servicio>/`
(tmpfs). `LoadCredential=` las entrega al proceso sin exponerlas en el entorno.

---

## Configuración de DVC

```bash
./scripts/setup_dvc.sh
```

Crea los buckets `dvc-data` y `mlflow-artifacts` en MinIO, inicializa DVC y
configura el remote. Las credenciales quedan en `.dvc/config.local`, excluido de git.

### Dataset

Coloca el archivo `CustomerChurn.csv` en `data/raw/`:

```bash
cp /ruta/a/tu/CustomerChurn.csv data/raw/CustomerChurn.csv
```

```bash
dvc add data/raw/CustomerChurn.csv
git add data/raw/CustomerChurn.csv.dvc data/raw/.gitignore
git commit -m "data: IBM CustomerChurn dataset v1"
dvc push
```

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