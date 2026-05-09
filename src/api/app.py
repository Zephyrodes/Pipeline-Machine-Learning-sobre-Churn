"""
Servicio de inferencia FastAPI para el modelo de predicción de churn.
Administrado por systemd — sin contenedor, sin reverse proxy.

Endpoints:
  GET  /           → health check básico
  GET  /health     → estado del servicio y modelo cargado
  POST /predict    → predicción de churn para un cliente
  POST /predict/batch → predicción en lote (lista de clientes)
  GET  /model/info → información del modelo en producción
"""

from __future__ import annotations

import logging
import os
import time
from contextlib import asynccontextmanager
from typing import Any

import mlflow.sklearn
import numpy as np
import pandas as pd
from fastapi import FastAPI, HTTPException, status

from pydantic import BaseModel, Field, field_validator

# ──────────────────────────────────────────────
# Configuración de logging
# ──────────────────────────────────────────────
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s | %(levelname)s | %(name)s | %(message)s",
    datefmt="%Y-%m-%dT%H:%M:%S",
)
logger = logging.getLogger("mlops_api")

# ──────────────────────────────────────────────
# Variables de configuración (desde entorno)
# ──────────────────────────────────────────────
MLFLOW_TRACKING_URI    = os.getenv("MLFLOW_TRACKING_URI",    "http://127.0.0.1:5000")
MLFLOW_MODEL_NAME      = os.getenv("MLFLOW_MODEL_NAME",      "churn-predictor")
MLFLOW_MODEL_ALIAS     = os.getenv("MLFLOW_MODEL_ALIAS",     "Production")
MODEL_RELOAD_INTERVAL  = int(os.getenv("MODEL_RELOAD_INTERVAL", "300"))  # segundos

# ──────────────────────────────────────────────
# Estado global del modelo (se recarga periódicamente)
# ──────────────────────────────────────────────
_model_state: dict[str, Any] = {
    "model"       : None,
    "model_uri"   : None,
    "model_version": None,
    "loaded_at"   : None,
}


def load_production_model() -> None:
    """
    Carga el modelo marcado con el alias 'Production' desde MLflow Registry.
    Se invoca al inicio y puede ser llamada para recargar el modelo en caliente.
    """
    mlflow.set_tracking_uri(MLFLOW_TRACKING_URI)
    model_uri = f"models:/{MLFLOW_MODEL_NAME}@{MLFLOW_MODEL_ALIAS}"

    try:
        model = mlflow.sklearn.load_model(model_uri)
        client = mlflow.MlflowClient()
        model_version = client.get_model_version_by_alias(
            MLFLOW_MODEL_NAME, MLFLOW_MODEL_ALIAS
        )

        _model_state.update({
            "model"        : model,
            "model_uri"    : model_uri,
            "model_version": model_version.version,
            "loaded_at"    : time.time(),
        })
        logger.info(
            "Modelo '%s@%s' (v%s) cargado correctamente",
            MLFLOW_MODEL_NAME, MLFLOW_MODEL_ALIAS, model_version.version
        )
    except Exception as exc:
        logger.error("Error al cargar el modelo desde MLflow: %s", exc)
        raise


# ──────────────────────────────────────────────
# Lifecycle de la aplicación FastAPI
# ──────────────────────────────────────────────
@asynccontextmanager
async def lifespan(app: FastAPI):
    """Carga el modelo al arrancar el servicio y libera recursos al cerrar."""
    logger.info("Iniciando servicio de predicción de churn...")
    load_production_model()
    yield
    logger.info("Servicio detenido")


# ──────────────────────────────────────────────
# Definición de la aplicación
# ──────────────────────────────────────────────
app = FastAPI(
    title="MLOps Churn Prediction API",
    description=(
        "Servicio de inferencia para el modelo de predicción de churn de clientes. "
        "El modelo es entrenado por un pipeline de Airflow y registrado en MLflow."
    ),
    version="1.0.0",
    lifespan=lifespan,
    docs_url="/docs",
    redoc_url="/redoc",
)


# ──────────────────────────────────────────────
# Schemas de request/response (Pydantic)
# ──────────────────────────────────────────────
class CustomerFeatures(BaseModel):
    """
    Features de un cliente para predicción de churn.

    Nota: el campo 'gender' fue eliminado deliberadamente.
    El dataset fuente IBM Telco no incluye gender en el esquema interno
    del pipeline (ver COLUMN_RENAME_MAP en ingest.py y COLUMNS_TO_DROP en
    preprocess.py). El modelo entrenado no recibe ese campo, por lo que
    incluirlo en el payload causaría un desajuste de dimensiones en predict().
    """
    SeniorCitizen    : int   = Field(..., ge=0, le=1,   description="¿Es adulto mayor?")
    Partner          : int   = Field(..., ge=0, le=1,   description="¿Tiene pareja?")
    Dependents       : int   = Field(..., ge=0, le=1,   description="¿Tiene dependientes?")
    tenure           : float = Field(..., ge=0,          description="Meses como cliente")
    PhoneService     : int   = Field(..., ge=0, le=1)
    MultipleLines    : int   = Field(..., ge=0, le=2)
    InternetService  : int   = Field(..., ge=0, le=2)
    OnlineSecurity   : int   = Field(..., ge=0, le=2)
    OnlineBackup     : int   = Field(..., ge=0, le=2)
    DeviceProtection : int   = Field(..., ge=0, le=2)
    TechSupport      : int   = Field(..., ge=0, le=2)
    StreamingTV      : int   = Field(..., ge=0, le=2)
    StreamingMovies  : int   = Field(..., ge=0, le=2)
    Contract         : int   = Field(..., ge=0, le=2,   description="0=M2M, 1=1yr, 2=2yr")
    PaperlessBilling : int   = Field(..., ge=0, le=1)
    PaymentMethod    : int   = Field(..., ge=0, le=3)
    MonthlyCharges   : float = Field(..., ge=0,          description="Cargo mensual en USD")
    TotalCharges     : float = Field(..., ge=0,          description="Cargo total acumulado")

    model_config = {"json_schema_extra": {
        "example": {
            "SeniorCitizen": 0, "Partner": 1, "Dependents": 0,
            "tenure": 12.0, "PhoneService": 1, "MultipleLines": 0,
            "InternetService": 1, "OnlineSecurity": 0, "OnlineBackup": 0,
            "DeviceProtection": 0, "TechSupport": 0, "StreamingTV": 1,
            "StreamingMovies": 1, "Contract": 0, "PaperlessBilling": 1,
            "PaymentMethod": 2, "MonthlyCharges": 65.50, "TotalCharges": 786.0,
        }
    }}


class PredictionResponse(BaseModel):
    """Respuesta de predicción de churn."""
    churn_prediction  : int   = Field(..., description="1=Churn, 0=No Churn")
    churn_probability : float = Field(..., description="Probabilidad de churn (0-1)")
    risk_level        : str   = Field(..., description="bajo | medio | alto")
    model_version     : str   = Field(..., description="Versión del modelo en producción")


class BatchPredictionRequest(BaseModel):
    """Request de predicción en lote."""
    customers: list[CustomerFeatures] = Field(..., min_length=1, max_length=500)


# ──────────────────────────────────────────────
# Helpers
# ──────────────────────────────────────────────
def get_risk_level(probability: float) -> str:
    """Clasifica la probabilidad de churn en niveles de riesgo."""
    if probability >= 0.70:
        return "alto"
    elif probability >= 0.40:
        return "medio"
    return "bajo"


def features_to_dataframe(customer: CustomerFeatures) -> pd.DataFrame:
    """Convierte un objeto CustomerFeatures a DataFrame compatible con el modelo."""
    return pd.DataFrame([customer.model_dump()])


# ──────────────────────────────────────────────
# Endpoints
# ──────────────────────────────────────────────
@app.get("/", include_in_schema=False)
async def root():
    return {"service": "MLOps Churn API", "status": "running", "docs": "/docs"}


@app.get("/health", tags=["infraestructura"])
async def health_check():
    """Verifica que el servicio y el modelo están operativos."""
    model_loaded = _model_state["model"] is not None
    return {
        "status"        : "healthy" if model_loaded else "degraded",
        "model_loaded"  : model_loaded,
        "model_version" : _model_state.get("model_version"),
        "model_uri"     : _model_state.get("model_uri"),
        "loaded_seconds_ago": (
            round(time.time() - _model_state["loaded_at"])
            if _model_state["loaded_at"] else None
        ),
    }


@app.get("/model/info", tags=["modelo"])
async def model_info():
    """Retorna información del modelo actualmente cargado en producción."""
    if _model_state["model"] is None:
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail="El modelo no está cargado. Verifica MLflow.",
        )
    model = _model_state["model"]
    return {
        "model_name"    : MLFLOW_MODEL_NAME,
        "model_alias"   : MLFLOW_MODEL_ALIAS,
        "model_version" : _model_state["model_version"],
        "model_uri"     : _model_state["model_uri"],
        "n_estimators"  : getattr(model, "n_estimators", None),
        "max_depth"     : getattr(model, "max_depth", None),
        "num_features"  : getattr(model, "n_features_in_", None),
    }


@app.post("/predict", response_model=PredictionResponse, tags=["predicción"])
async def predict(customer: CustomerFeatures):
    """
    Predice si un cliente va a realizar churn.

    Retorna la predicción binaria, la probabilidad y el nivel de riesgo.
    """
    if _model_state["model"] is None:
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail="El modelo no está disponible. Intenta en unos momentos.",
        )

    try:
        X = features_to_dataframe(customer)
        model = _model_state["model"]

        prediction  = int(model.predict(X)[0])
        probability = float(model.predict_proba(X)[0][1])

        logger.info(
            "Predicción: churn=%d prob=%.4f risk=%s",
            prediction, probability, get_risk_level(probability)
        )

        return PredictionResponse(
            churn_prediction  = prediction,
            churn_probability = round(probability, 4),
            risk_level        = get_risk_level(probability),
            model_version     = str(_model_state.get("model_version", "unknown")),
        )

    except Exception as exc:
        logger.exception("Error en predicción: %s", exc)
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail=f"Error interno al procesar la predicción: {str(exc)}",
        )


@app.post("/predict/batch", tags=["predicción"])
async def predict_batch(request: BatchPredictionRequest):
    """
    Predicción en lote para hasta 500 clientes en una sola llamada.
    Útil para procesar segmentos completos de clientes.
    """
    if _model_state["model"] is None:
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail="El modelo no está disponible.",
        )
    try:
        X = pd.DataFrame([c.model_dump() for c in request.customers])
        model = _model_state["model"]

        predictions  = model.predict(X).tolist()
        probabilities = model.predict_proba(X)[:, 1].tolist()

        results = [
            {
                "index"            : i,
                "churn_prediction" : int(pred),
                "churn_probability": round(float(prob), 4),
                "risk_level"       : get_risk_level(prob),
            }
            for i, (pred, prob) in enumerate(zip(predictions, probabilities))
        ]

        churn_count = sum(r["churn_prediction"] for r in results)
        return {
            "total_customers"    : len(results),
            "predicted_churn"    : churn_count,
            "predicted_no_churn" : len(results) - churn_count,
            "churn_rate"         : round(churn_count / len(results) * 100, 2),
            "model_version"      : str(_model_state.get("model_version", "unknown")),
            "predictions"        : results,
        }

    except Exception as exc:
        logger.exception("Error en predicción batch: %s", exc)
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail=str(exc),
        )


@app.post("/model/reload", tags=["infraestructura"])
async def reload_model():
    """
    Recarga el modelo desde MLflow Registry (útil tras una promoción de versión).
    Permite zero-downtime model updates sin reiniciar el proceso systemd.
    """
    try:
        old_version = _model_state.get("model_version")
        load_production_model()
        new_version = _model_state.get("model_version")
        return {
            "message"      : "Modelo recargado correctamente",
            "old_version"  : old_version,
            "new_version"  : new_version,
        }
    except Exception as exc:
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail=f"No se pudo recargar el modelo: {str(exc)}",
        )