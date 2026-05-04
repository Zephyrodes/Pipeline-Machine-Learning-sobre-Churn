"""
Evaluación del modelo entrenado sobre el conjunto de test.
Genera métricas completas, curva ROC y matriz de confusión como artefactos MLflow.
"""

from __future__ import annotations

import logging
import os
from pathlib import Path
from typing import Any

import matplotlib
matplotlib.use("Agg")  # Sin display (servidor headless)
import matplotlib.pyplot as plt
import mlflow
import mlflow.sklearn
import numpy as np
import pandas as pd
from sklearn.metrics import (
    ConfusionMatrixDisplay,
    RocCurveDisplay,
    accuracy_score,
    classification_report,
    f1_score,
    precision_score,
    recall_score,
    roc_auc_score,
)

logger = logging.getLogger(__name__)

MLFLOW_TRACKING_URI = os.getenv("MLFLOW_TRACKING_URI", "http://127.0.0.1:5000")
TARGET_COLUMN       = "Churn"
PLOTS_DIR           = Path("/tmp/mlops_plots")


def plot_roc_curve(
    y_true: np.ndarray,
    y_prob: np.ndarray,
    auc_score: float,
    output_path: Path,
) -> None:
    """Genera y guarda la curva ROC como PNG."""
    fig, ax = plt.subplots(figsize=(7, 5))
    RocCurveDisplay.from_predictions(y_true, y_prob, ax=ax)
    ax.set_title(f"Curva ROC — AUC = {auc_score:.4f}")
    ax.grid(alpha=0.3)
    plt.tight_layout()
    plt.savefig(output_path, dpi=120)
    plt.close(fig)


def plot_confusion_matrix(
    y_true: np.ndarray,
    y_pred: np.ndarray,
    output_path: Path,
) -> None:
    """Genera y guarda la matriz de confusión normalizada como PNG."""
    fig, ax = plt.subplots(figsize=(5, 4))
    ConfusionMatrixDisplay.from_predictions(
        y_true, y_pred,
        display_labels=["No Churn", "Churn"],
        normalize="true",
        ax=ax,
    )
    ax.set_title("Matriz de Confusión (normalizada)")
    plt.tight_layout()
    plt.savefig(output_path, dpi=120)
    plt.close(fig)


def run_evaluation(
    test_path: str,
    promotion_threshold_auc: float = 0.75,
    **context: Any,
) -> dict[str, Any]:
    """
    Evalúa el modelo del run activo de MLflow contra el test set.

    Args:
        test_path: Ruta al Parquet del conjunto de test.
        promotion_threshold_auc: AUC mínimo para que el modelo sea candidato a registro.
        **context: Contexto Airflow (contiene ti con run_id del paso anterior).

    Returns:
        Diccionario con métricas de evaluación y decisión de promoción.
    """
    logger.info("═══ Iniciando evaluación del modelo ═══")

    mlflow.set_tracking_uri(MLFLOW_TRACKING_URI)

    # Obtener run_id del paso de entrenamiento via XCom
    run_id = None
    if "ti" in context:
        run_id = context["ti"].xcom_pull(
            task_ids="entrenamiento", key="mlflow_run_id"
        )
    if not run_id:
        raise ValueError(
            "No se encontró run_id en XCom. "
            "Asegúrate de que la tarea 'entrenamiento' se ejecutó correctamente."
        )

    logger.info("Evaluando run de MLflow: %s", run_id)

    # ── Cargar datos de test ───────────────────────────────────────────────
    df_test = pd.read_parquet(test_path)
    X_test  = df_test.drop(columns=[TARGET_COLUMN])
    y_test  = df_test[TARGET_COLUMN].values

    # ── Cargar el modelo desde MLflow ─────────────────────────────────────
    model_uri = f"runs:/{run_id}/model"
    model = mlflow.sklearn.load_model(model_uri)
    logger.info("Modelo cargado desde: %s", model_uri)

    # ── Predicciones ───────────────────────────────────────────────────────
    y_pred      = model.predict(X_test)
    y_pred_prob = model.predict_proba(X_test)[:, 1]

    # ── Calcular métricas de evaluación ───────────────────────────────────
    eval_metrics = {
        "test_accuracy" : round(float(accuracy_score(y_test, y_pred)), 4),
        "test_f1"       : round(float(f1_score(y_test, y_pred)), 4),
        "test_precision": round(float(precision_score(y_test, y_pred)), 4),
        "test_recall"   : round(float(recall_score(y_test, y_pred)), 4),
        "test_auc_roc"  : round(float(roc_auc_score(y_test, y_pred_prob)), 4),
    }
    logger.info("Métricas de evaluación (test set): %s", eval_metrics)

    # Verificar si el modelo supera el umbral de promoción
    is_promotable = eval_metrics["test_auc_roc"] >= promotion_threshold_auc
    eval_metrics["is_promotable"] = is_promotable

    # ── Registrar métricas y artefactos en el run de MLflow ───────────────
    PLOTS_DIR.mkdir(parents=True, exist_ok=True)
    roc_path = PLOTS_DIR / "roc_curve.png"
    cm_path  = PLOTS_DIR / "confusion_matrix.png"

    plot_roc_curve(y_test, y_pred_prob, eval_metrics["test_auc_roc"], roc_path)
    plot_confusion_matrix(y_test, y_pred, cm_path)

    # Reporte de clasificación como artefacto de texto
    report_path = PLOTS_DIR / "classification_report.txt"
    report = classification_report(y_test, y_pred, target_names=["No Churn", "Churn"])
    report_path.write_text(report)

    with mlflow.start_run(run_id=run_id):
        mlflow.log_metrics({k: v for k, v in eval_metrics.items() if isinstance(v, float)})
        mlflow.log_artifact(str(roc_path),    artifact_path="evaluation_plots")
        mlflow.log_artifact(str(cm_path),     artifact_path="evaluation_plots")
        mlflow.log_artifact(str(report_path), artifact_path="evaluation_reports")
        mlflow.set_tag("is_promotable", str(is_promotable))
        mlflow.set_tag("promotion_threshold_auc", str(promotion_threshold_auc))

    logger.info(
        "AUC-ROC=%.4f | Umbral=%.2f | ¿Candidato a producción? %s",
        eval_metrics["test_auc_roc"], promotion_threshold_auc,
        "SÍ ✓" if is_promotable else "NO ✗"
    )

    if "ti" in context:
        context["ti"].xcom_push(key="evaluation_metrics", value=eval_metrics)
        context["ti"].xcom_push(key="is_promotable",      value=is_promotable)

    logger.info("═══ Evaluación finalizada ═══")
    return eval_metrics