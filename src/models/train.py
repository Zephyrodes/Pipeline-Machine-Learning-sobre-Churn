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