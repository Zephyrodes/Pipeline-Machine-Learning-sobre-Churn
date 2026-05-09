"""
Entrenamiento del modelo RandomForestClassifier con tracking completo en MLflow.
Registra: parámetros, métricas de entrenamiento, artefactos y el modelo serializado.
"""

from __future__ import annotations

import logging
import os
from pathlib import Path
from typing import Any

import mlflow
import mlflow.sklearn
import numpy as np
import pandas as pd
from sklearn.ensemble import RandomForestClassifier
from sklearn.metrics import (
    accuracy_score,
    f1_score,
    roc_auc_score,
)

logger = logging.getLogger(__name__)

# Configuración de MLflow desde variables de entorno
MLFLOW_TRACKING_URI = os.getenv("MLFLOW_TRACKING_URI", "http://127.0.0.1:5000")
TARGET_COLUMN       = "Churn"

# Archivo de credenciales que fetch_secrets.sh escribe para el servicio mlflow.
# Contiene AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY, MLFLOW_S3_ENDPOINT_URL, etc.
# Se usa como fuente de respaldo si el entorno del worker de Airflow no tiene
# las variables S3 inyectadas por el unit de systemd.
_MLFLOW_SECRETS_FILE = "/run/mlops-secrets/minio/credentials"


def _bootstrap_s3_credentials() -> None:
    """
    Garantiza que las variables de entorno necesarias para boto3/MinIO estén
    presentes en el proceso actual antes de iniciar cualquier operación MLflow
    que implique subida de artefactos a S3.

    Orden de precedencia (mayor a menor):
      1. Variables ya presentes en os.environ — no se sobreescriben.
      2. Archivo de credenciales de MinIO en tmpfs (/run/mlops-secrets/minio/).
      3. Error explícito si ninguna fuente está disponible.

    Variables que boto3 necesita para autenticarse contra MinIO:
      - AWS_ACCESS_KEY_ID
      - AWS_SECRET_ACCESS_KEY
      - MLFLOW_S3_ENDPOINT_URL   (apunta a http://127.0.0.1:9000)
      - AWS_DEFAULT_REGION       (MinIO ignora el valor pero boto3 lo exige)
    """
    required = ["AWS_ACCESS_KEY_ID", "AWS_SECRET_ACCESS_KEY"]

    if all(os.getenv(k) for k in required):
        logger.info(
            "Credenciales S3/MinIO presentes en el entorno del proceso (vía systemd EnvironmentFile)"
        )
        return

    logger.warning(
        "Credenciales S3/MinIO no encontradas en el entorno — "
        "intentando cargar desde %s", _MLFLOW_SECRETS_FILE
    )

    secrets_path = Path(_MLFLOW_SECRETS_FILE)
    if not secrets_path.exists():
        raise EnvironmentError(
            f"No se encontraron credenciales S3/MinIO ni en el entorno ni en "
            f"{_MLFLOW_SECRETS_FILE}. "
            "Verifica que:\n"
            "  1. El unit systemd de airflow-scheduler tiene EnvironmentFile=-/run/mlops-secrets/minio/credentials\n"
            "  2. fetch_secrets.sh minio se ejecutó correctamente (make vault-unseal && make start)\n"
            "  3. MinIO está activo: sudo systemctl status minio"
        )

    # Parsear el archivo de credenciales (formato KEY=VALUE, una por línea)
    loaded: list[str] = []
    for line in secrets_path.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, _, value = line.partition("=")
        key   = key.strip()
        value = value.strip().strip('"').strip("'")
        if key and key not in os.environ:
            os.environ[key] = value
            loaded.append(key)

    if not all(os.getenv(k) for k in required):
        raise EnvironmentError(
            f"El archivo {_MLFLOW_SECRETS_FILE} no contiene las claves requeridas: "
            f"{required}. Revisa que fetch_secrets.sh minio escribe esas variables."
        )

    logger.info(
        "Credenciales S3/MinIO cargadas desde %s: %s",
        _MLFLOW_SECRETS_FILE, loaded
    )


def run_training(
    train_path: str,
    model_output_path: str,
    mlflow_experiment: str,
    hyperparams: dict[str, Any],
    **context: Any,
) -> dict[str, Any]:
    """
    Entrena un RandomForestClassifier y registra el experimento en MLflow.

    Args:
        train_path: Ruta al archivo Parquet de entrenamiento.
        model_output_path: Directorio local donde se guardará el modelo.
        mlflow_experiment: Nombre del experimento en MLflow.
        hyperparams: Diccionario de hiperparámetros para RandomForest.
        **context: Contexto de Airflow.

    Returns:
        Diccionario con run_id de MLflow y métricas de entrenamiento.
    """
    logger.info("═══ Iniciando entrenamiento del modelo ═══")

    # ── Bootstrap de credenciales S3/MinIO ───────────────────────────────
    # mlflow.log_artifact() usa boto3 internamente para subir artefactos al
    # backend S3 (MinIO). boto3 busca las credenciales en el entorno del
    # proceso actual (el worker/scheduler de Airflow), NO en el proceso de
    # mlflow-server. Si los units de systemd de Airflow no inyectan las
    # variables AWS_*, boto3 lanza NoCredentialsError al primer log_artifact.
    #
    # Este bloque actúa como red de seguridad: si las variables no están en
    # el entorno (porque el unit de systemd es antiguo o estamos en desarrollo
    # local), las carga desde el archivo de credenciales de mlflow en tmpfs.
    # En producción con el unit actualizado, ya estarán en el entorno y el
    # bloque hace un simple log de confirmación sin tocar nada.
    _bootstrap_s3_credentials()

    # ── Configurar MLflow ─────────────────────────────────────────────────
    mlflow.set_tracking_uri(MLFLOW_TRACKING_URI)
    mlflow.set_experiment(mlflow_experiment)

    # ── Cargar datos de entrenamiento ─────────────────────────────────────
    df_train = pd.read_parquet(train_path)
    X_train = df_train.drop(columns=[TARGET_COLUMN])
    y_train = df_train[TARGET_COLUMN]

    logger.info(
        "Datos de entrenamiento cargados: %d muestras × %d features",
        len(X_train), len(X_train.columns)
    )

    # ── Iniciar run de MLflow ─────────────────────────────────────────────
    with mlflow.start_run(run_name="churn_rf_training") as run:
        run_id = run.info.run_id
        logger.info("MLflow Run ID: %s", run_id)

        # Registrar tags descriptivos del run
        mlflow.set_tags({
            "model_type"     : "RandomForestClassifier",
            "framework"      : "scikit-learn",
            "pipeline_step"  : "training",
            "dataset_version": "latest",
            "team"           : "mlops",
        })

        # ── Registrar hiperparámetros ──────────────────────────────────────
        mlflow.log_params(hyperparams)
        mlflow.log_param("train_samples", len(X_train))
        mlflow.log_param("num_features",  len(X_train.columns))

        # ── Entrenar el modelo ─────────────────────────────────────────────
        logger.info("Entrenando RandomForestClassifier con: %s", hyperparams)
        model = RandomForestClassifier(**hyperparams)
        model.fit(X_train, y_train)
        logger.info("Entrenamiento completado")

        # ── Métricas sobre el conjunto de entrenamiento ────────────────────
        y_train_pred      = model.predict(X_train)
        y_train_pred_prob = model.predict_proba(X_train)[:, 1]

        train_metrics = {
            "train_accuracy" : round(accuracy_score(y_train, y_train_pred), 4),
            "train_f1"       : round(f1_score(y_train, y_train_pred), 4),
            "train_auc_roc"  : round(roc_auc_score(y_train, y_train_pred_prob), 4),
        }
        mlflow.log_metrics(train_metrics)
        logger.info("Métricas de entrenamiento: %s", train_metrics)

        # ── Feature importance como artefacto ─────────────────────────────
        feature_importance_df = pd.DataFrame({
            "feature"   : X_train.columns,
            "importance": model.feature_importances_,
        }).sort_values("importance", ascending=False)

        importance_path = Path(model_output_path) / "feature_importance.csv"
        importance_path.parent.mkdir(parents=True, exist_ok=True)
        feature_importance_df.to_csv(importance_path, index=False)
        mlflow.log_artifact(str(importance_path), artifact_path="feature_analysis")

        # ── Registrar el modelo serializado en MLflow ──────────────────────
        # Incluye la firma del modelo (schema de input/output) para validación
        from mlflow.models.signature import infer_signature
        signature = infer_signature(X_train, model.predict(X_train))

        mlflow.sklearn.log_model(
            sk_model         = model,
            artifact_path    = "model",
            signature        = signature,
            input_example    = X_train.head(5),
            registered_model_name=None,  # El registro se hace en la tarea siguiente
        )

        logger.info(
            "Modelo registrado en MLflow. Artefactos guardados en MinIO."
        )

    result = {
        "run_id"          : run_id,
        "experiment_name" : mlflow_experiment,
        **train_metrics,
    }

    # Pasar run_id a tareas siguientes por XCom
    if "ti" in context:
        context["ti"].xcom_push(key="mlflow_run_id", value=run_id)
        context["ti"].xcom_push(key="training_metrics", value=train_metrics)

    logger.info("═══ Entrenamiento finalizado. Run ID: %s ═══", run_id)
    return result