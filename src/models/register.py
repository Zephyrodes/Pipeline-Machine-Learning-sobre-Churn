"""
Registro del modelo en MLflow Model Registry y promoción automática
a Staging / Production según las métricas de evaluación.
"""

from __future__ import annotations

import logging
import os
from typing import Any

import mlflow
from mlflow import MlflowClient

logger = logging.getLogger(__name__)

MLFLOW_TRACKING_URI = os.getenv("MLFLOW_TRACKING_URI", "http://127.0.0.1:5000")


def run_model_registration(
    model_name: str,
    staging_alias: str,
    production_alias: str,
    min_auc_production: float = 0.80,
    **context: Any,
) -> dict[str, Any]:
    """
    Registra el modelo en MLflow Registry y lo promueve según las métricas.

    Lógica de promoción:
        AUC >= min_auc_production → Production  (archiva el anterior)
        AUC >= 0.75               → Staging
        AUC <  0.75               → Solo registrado, sin alias activo

    Args:
        model_name: Nombre del modelo en MLflow Registry.
        staging_alias: Alias a asignar para Staging (ej. "Staging").
        production_alias: Alias a asignar para Production (ej. "Production").
        min_auc_production: AUC mínimo para promoción a Production.
        **context: Contexto de Airflow.

    Returns:
        Diccionario con versión registrada y etapa asignada.
    """
    logger.info("═══ Iniciando registro del modelo en MLflow Registry ═══")

    mlflow.set_tracking_uri(MLFLOW_TRACKING_URI)
    client = MlflowClient()

    # ── Recuperar run_id y métricas vía XCom ──────────────────────────────
    run_id         = None
    eval_metrics   = {}
    is_promotable  = False

    if "ti" in context:
        run_id        = context["ti"].xcom_pull(task_ids="entrenamiento",  key="mlflow_run_id")
        eval_metrics  = context["ti"].xcom_pull(task_ids="evaluacion",     key="evaluation_metrics") or {}
        is_promotable = context["ti"].xcom_pull(task_ids="evaluacion",     key="is_promotable") or False

    if not run_id:
        raise ValueError("run_id no disponible en XCom. El entrenamiento no completó correctamente.")

    auc_score = eval_metrics.get("test_auc_roc", 0.0)

    # ── Registrar el modelo en el Registry ───────────────────────────────
    model_uri  = f"runs:/{run_id}/model"
    model_version_info = mlflow.register_model(
        model_uri  = model_uri,
        name       = model_name,
    )
    version = model_version_info.version
    logger.info(
        "Modelo '%s' registrado como versión %s (run_id: %s)",
        model_name, version, run_id
    )

    # Agregar descripción y tags a la versión
    client.update_model_version(
        name        = model_name,
        version     = version,
        description = (
            f"AUC-ROC={auc_score:.4f} | "
            f"F1={eval_metrics.get('test_f1', 0):.4f} | "
            f"Accuracy={eval_metrics.get('test_accuracy', 0):.4f}"
        ),
    )
    client.set_model_version_tag(model_name, version, "run_id",   run_id)
    client.set_model_version_tag(model_name, version, "auc_roc",  str(auc_score))

    # ── Lógica de promoción ────────────────────────────────────────────────
    assigned_stage = "registered_only"

    if auc_score >= min_auc_production:
        # Promover a Production y archivar el anterior
        _promote_to_production(
            client, model_name, version, production_alias
        )
        assigned_stage = "Production"
        logger.info(
            "✅ Modelo v%s promovido a PRODUCTION (AUC=%.4f ≥ %.2f)",
            version, auc_score, min_auc_production
        )

    elif is_promotable:
        # Promover a Staging
        client.set_registered_model_alias(model_name, staging_alias, version)
        assigned_stage = "Staging"
        logger.info(
            "⏳ Modelo v%s promovido a STAGING (AUC=%.4f < %.2f para Production)",
            version, auc_score, min_auc_production
        )

    else:
        logger.warning(
            "⚠️  Modelo v%s NO promovido (AUC=%.4f está por debajo del umbral mínimo)",
            version, auc_score
        )

    result = {
        "model_name"     : model_name,
        "model_version"  : version,
        "assigned_stage" : assigned_stage,
        "auc_roc"        : auc_score,
    }

    if "ti" in context:
        context["ti"].xcom_push(key="registration_result", value=result)

    logger.info("═══ Registro finalizado: versión=%s | etapa=%s ═══", version, assigned_stage)
    return result


def _promote_to_production(
    client: MlflowClient,
    model_name: str,
    new_version: str,
    production_alias: str,
) -> None:
    """
    Promueve la nueva versión a Production y registra la transición en el modelo anterior.

    Args:
        client: Instancia de MlflowClient.
        model_name: Nombre del modelo en el registry.
        new_version: Versión a promover.
        production_alias: Alias de producción (ej. "Production").
    """
    # Buscar la versión actualmente en Production para agregar tag de archivado
    try:
        current_prod = client.get_model_version_by_alias(model_name, production_alias)
        client.set_model_version_tag(
            model_name,
            current_prod.version,
            "archived_by",
            f"v{new_version}",
        )
        logger.info(
            "Versión anterior en Production (v%s) marcada como archivada",
            current_prod.version,
        )
    except mlflow.exceptions.MlflowException:
        logger.info("No hay versión anterior en Production para archivar")

    # Asignar el alias de Production a la nueva versión
    client.set_registered_model_alias(model_name, production_alias, new_version)