"""
DAG principal de Apache Airflow que orquesta el pipeline completo de predicción
de churn de clientes.

Flujo del pipeline:
    ingesta_datos → preprocesamiento → entrenamiento → evaluacion → registro_modelo

Cada tarea corresponde a un paso del ciclo MLOps y registra métricas en MLflow.
Los datos son versionados con DVC antes del entrenamiento.
"""

from __future__ import annotations

import os
import logging
from datetime import datetime, timedelta

from airflow import DAG
from airflow.operators.python import PythonOperator
from airflow.utils.dates import days_ago

# Los módulos del proyecto (ingest, preprocess, train, evaluate, register)
# importan mlflow y otras librerías pesadas en su cabecera. Si se importan
# aquí al nivel del módulo, Airflow falla al parsear el DAG con:
#   ModuleNotFoundError: No module named 'pkg_resources'
# porque el parser ejecuta estos imports antes de que cualquier tarea corra.
#
# Solución: lazy imports — cada callable importa su función justo antes de
# usarla. El DAG se parsea sin tocar mlflow; las dependencias solo se cargan
# en el worker cuando la tarea realmente se ejecuta.
import sys
sys.path.insert(0, "/opt/airflow/dags/src")


def _run_ingestion(**context):
    from data.ingest import run_data_ingestion
    return run_data_ingestion(**context)


def _run_preprocessing(**context):
    from data.preprocess import run_preprocessing
    return run_preprocessing(**context)


def _run_training(**context):
    from models.train import run_training
    return run_training(**context)


def _run_evaluation(**context):
    from models.evaluate import run_evaluation
    return run_evaluation(**context)


def _run_model_registration(**context):
    from models.register import run_model_registration
    return run_model_registration(**context)

logger = logging.getLogger(__name__)

# ──────────────────────────────────────────────
# Argumentos por defecto del DAG
# ──────────────────────────────────────────────
default_args = {
    "owner"           : "mlops-team",
    "depends_on_past" : False,
    "email"           : ["zephyrodes@github.com"],
    "email_on_failure": True,
    "email_on_retry"  : False,
    "retries"         : 2,
    "retry_delay"     : timedelta(minutes=5),
}

# ──────────────────────────────────────────────
# Definición del DAG
# ──────────────────────────────────────────────
with DAG(
    dag_id="churn_prediction_pipeline",
    default_args=default_args,
    description="Pipeline completo MLOps: ingesta → preproceso → entrenamiento → evaluación → registro",
    schedule_interval="@weekly",          # Ejecuta cada semana (o manual)
    start_date=days_ago(1),
    catchup=False,
    max_active_runs=1,
    tags=["mlops", "churn", "scikit-learn", "mlflow"],
    doc_md="""
    ## Pipeline de Predicción de Churn
    Este DAG implementa el ciclo completo de MLOps para el modelo de predicción
    de abandono de clientes (customer churn).

    ### Pasos del pipeline
    1. **ingesta_datos**: Descarga / copia el CSV de origen y lo versiona con DVC
    2. **preprocesamiento**: Limpieza, feature engineering, train/test split
    3. **entrenamiento**: Entrena un RandomForestClassifier con MLflow tracking
    4. **evaluacion**: Calcula métricas AUC-ROC, F1, precisión en test set
    5. **registro_modelo**: Promueve el modelo a Staging/Production en MLflow Registry

    ### Herramientas
    - **DVC**: versiona los datos raw y procesados
    - **MLflow**: trackea experimentos y actúa como model registry
    - **MinIO**: backend de artefactos S3-compatible
    """,
) as dag:

    # ── Tarea 1: Ingesta de datos ──────────────────────────────────────────
    tarea_ingesta = PythonOperator(
        task_id="ingesta_datos",
        python_callable=_run_ingestion,
        op_kwargs={
            "source_path" : "/opt/mlops/data/raw/telco_churn.csv",
            "output_path" : "/opt/mlops/data/raw/telco_churn_latest.csv",
        },
        doc_md="""
        ### Ingesta de datos
        - Copia el archivo CSV fuente al directorio de datos raw
        - Valida que el archivo tenga las columnas esperadas
        - Ejecuta `dvc add` para versionar los datos en DVC
        - Registra la fecha y hash del dataset en XCom para las tareas siguientes
        """,
    )

    # ── Tarea 2: Preprocesamiento ──────────────────────────────────────────
    tarea_preproceso = PythonOperator(
        task_id="preprocesamiento",
        python_callable=_run_preprocessing,
        op_kwargs={
            "input_path"      : "/opt/mlops/data/raw/telco_churn_latest.csv",
            "output_train_path": "/opt/mlops/data/processed/train.parquet",
            "output_test_path" : "/opt/mlops/data/processed/test.parquet",
            "test_size"        : 0.2,
            "random_state"     : 42,
        },
        doc_md="""
        ### Preprocesamiento de datos
        - Elimina columnas con alta cardinalidad (customer_id)
        - Imputa valores nulos con estrategia de mediana / moda
        - Codifica variables categóricas con LabelEncoder
        - Escala variables numéricas con StandardScaler
        - Divide en conjuntos train/test y guarda en formato Parquet
        - Versiona los datos procesados con DVC
        """,
    )

    # ── Tarea 3: Entrenamiento ─────────────────────────────────────────────
    tarea_entrenamiento = PythonOperator(
        task_id="entrenamiento",
        python_callable=_run_training,
        op_kwargs={
            "train_path"       : "/opt/mlops/data/processed/train.parquet",
            "model_output_path": "/opt/mlops/models/",
            "mlflow_experiment": "churn-prediction",
            "hyperparams": {
                "n_estimators"  : 200,
                "max_depth"     : 10,
                "min_samples_split": 5,
                "class_weight"  : "balanced",
                "random_state"  : 42,
            },
        },
        doc_md="""
        ### Entrenamiento del modelo
        - Carga los datos de entrenamiento desde Parquet
        - Entrena un RandomForestClassifier con los hiperparámetros dados
        - Registra en MLflow: parámetros, métricas de train, artefactos
        - Guarda el modelo serializado como artefacto en MinIO
        """,
    )

    # ── Tarea 4: Evaluación ────────────────────────────────────────────────
    tarea_evaluacion = PythonOperator(
        task_id="evaluacion",
        python_callable=_run_evaluation,
        op_kwargs={
            "test_path"       : "/opt/mlops/data/processed/test.parquet",
            "promotion_threshold_auc": 0.75,    # AUC mínimo para promover
        },
        doc_md="""
        ### Evaluación del modelo
        - Carga el modelo del run activo de MLflow
        - Evalúa contra el test set (AUC-ROC, F1, accuracy, recall)
        - Registra todas las métricas en el run de MLflow
        - Genera la curva ROC y la matriz de confusión como artefactos
        - Pasa el run_id al XCom para la tarea de registro
        """,
    )

    # ── Tarea 5: Registro del modelo ───────────────────────────────────────
    tarea_registro = PythonOperator(
        task_id="registro_modelo",
        python_callable=_run_model_registration,
        op_kwargs={
            "model_name"        : "churn-predictor",
            "staging_alias"     : "Staging",
            "production_alias"  : "Production",
            "min_auc_production": 0.80,    # AUC mínimo para Production
        },
        doc_md="""
        ### Registro del modelo en MLflow Registry
        - Registra el modelo en el MLflow Model Registry
        - Asigna la etiqueta 'Staging' si supera el umbral mínimo de AUC
        - Promueve a 'Production' si supera el umbral de producción
        - Archiva el modelo anterior de Production automáticamente
        - Notifica el nuevo modelo disponible vía log de Airflow
        """,
    )

    # ── Definición de dependencias (orden de ejecución) ───────────────────
    tarea_ingesta >> tarea_preproceso >> tarea_entrenamiento >> tarea_evaluacion >> tarea_registro