"""
Preprocesamiento del dataset IBM Telco Customer Churn.

Responsabilidades:
  - Eliminar columnas de identificación (LoyaltyID, CustomerID)
  - Limpiar tipos y valores nulos
  - Codificar variables categóricas con LabelEncoder
  - Escalar variables numéricas con StandardScaler (ajustado solo en train)
  - División train/test estratificada
  - Serialización a Parquet + versionado DVC
"""

from __future__ import annotations

import logging
import subprocess
from pathlib import Path
from typing import Any

import numpy as np
import pandas as pd
from sklearn.model_selection import train_test_split
from sklearn.preprocessing import LabelEncoder, StandardScaler
import joblib

logger = logging.getLogger(__name__)

# Columnas a eliminar — identificadores sin valor predictivo
COLUMNS_TO_DROP = ["LoyaltyID", "CustomerID"]

# Columnas categóricas con más de 2 valores
CATEGORICAL_COLUMNS = [
    "MultipleLines",
    "InternetService",
    "OnlineSecurity",
    "OnlineBackup",
    "DeviceProtection",
    "TechSupport",
    "StreamingTV",
    "StreamingMovies",
    "Contract",
    "PaymentMethod",
]

# Columnas numéricas a escalar
NUMERIC_COLUMNS = ["tenure", "MonthlyCharges", "TotalCharges", "SeniorCitizen"]

TARGET_COLUMN = "Churn"


def clean_data(df: pd.DataFrame) -> pd.DataFrame:
    """
    Limpia el DataFrame: elimina IDs, corrige tipos y maneja nulos.

    Args:
        df: DataFrame normalizado desde ingest.py

    Returns:
        DataFrame limpio.
    """
    df = df.copy()

    # Eliminar columnas de identificación
    cols_to_drop = [c for c in COLUMNS_TO_DROP if c in df.columns]
    df.drop(columns=cols_to_drop, inplace=True)

    # TotalCharges puede tener espacios en blanco en clientes con tenure=0
    df["TotalCharges"] = pd.to_numeric(df["TotalCharges"], errors="coerce")
    df["TotalCharges"].fillna(df["MonthlyCharges"], inplace=True)

    logger.info("Limpieza completada. Forma del dataset: %s", df.shape)
    return df


def encode_features(df: pd.DataFrame) -> tuple[pd.DataFrame, dict]:
    """
    Codifica variables categóricas con LabelEncoder y el target a 0/1.

    Args:
        df: DataFrame limpio.

    Returns:
        Tupla (DataFrame codificado, diccionario de encoders).
    """
    df = df.copy()
    encoders: dict[str, LabelEncoder] = {}

    for col in CATEGORICAL_COLUMNS:
        if col in df.columns:
            le = LabelEncoder()
            df[col] = le.fit_transform(df[col].astype(str))
            encoders[col] = le

    # Target: Yes → 1, No → 0
    if TARGET_COLUMN in df.columns:
        df[TARGET_COLUMN] = df[TARGET_COLUMN].map({"Yes": 1, "No": 0})

    # Columnas binarias restantes (Yes/No, No phone service, etc.)
    binary_map = {
        "Yes": 1, "No": 0,
        "No phone service": 0,
        "No internet service": 0,
    }
    for col in df.columns:
        if df[col].dtype == object:
            df[col] = df[col].map(binary_map).fillna(0).astype(int)

    logger.info("Codificación completada. Columnas: %d", len(df.columns))
    return df, encoders


def scale_features(
    X_train: pd.DataFrame,
    X_test: pd.DataFrame,
) -> tuple[pd.DataFrame, pd.DataFrame, StandardScaler]:
    """
    Escala variables numéricas con StandardScaler ajustado solo en train.

    Args:
        X_train: Features de entrenamiento.
        X_test: Features de evaluación.

    Returns:
        Tupla (X_train_scaled, X_test_scaled, scaler).
    """
    scaler = StandardScaler()
    numeric_cols = [c for c in NUMERIC_COLUMNS if c in X_train.columns]

    X_train_scaled = X_train.copy()
    X_test_scaled  = X_test.copy()

    X_train_scaled[numeric_cols] = scaler.fit_transform(X_train[numeric_cols])
    X_test_scaled[numeric_cols]  = scaler.transform(X_test[numeric_cols])

    logger.info("Escalado aplicado a: %s", numeric_cols)
    return X_train_scaled, X_test_scaled, scaler


def run_preprocessing(
    input_path: str,
    output_train_path: str,
    output_test_path: str,
    test_size: float = 0.2,
    random_state: int = 42,
    **context: Any,
) -> dict[str, Any]:
    """
    Función principal de preprocesamiento. Llamada por Airflow PythonOperator.

    Args:
        input_path: Ruta al CSV normalizado desde ingest.py
        output_train_path: Ruta de salida para datos de entrenamiento (Parquet).
        output_test_path: Ruta de salida para datos de evaluación (Parquet).
        test_size: Proporción del conjunto de test (default 0.2).
        random_state: Semilla para reproducibilidad.
        **context: Contexto de Airflow.

    Returns:
        Metadata del preprocesamiento.
    """
    logger.info("═══ Iniciando preprocesamiento ═══")

    Path(output_train_path).parent.mkdir(parents=True, exist_ok=True)
    Path(output_test_path).parent.mkdir(parents=True, exist_ok=True)

    df = pd.read_csv(input_path)
    logger.info("Dataset cargado: %d filas × %d columnas", *df.shape)

    df_clean          = clean_data(df)
    df_encoded, encoders = encode_features(df_clean)

    X = df_encoded.drop(columns=[TARGET_COLUMN])
    y = df_encoded[TARGET_COLUMN]

    X_train, X_test, y_train, y_test = train_test_split(
        X, y,
        test_size=test_size,
        random_state=random_state,
        stratify=y,
    )

    X_train_scaled, X_test_scaled, scaler = scale_features(X_train, X_test)

    train_df = X_train_scaled.copy()
    train_df[TARGET_COLUMN] = y_train.values
    train_df.to_parquet(output_train_path, index=False)

    test_df = X_test_scaled.copy()
    test_df[TARGET_COLUMN] = y_test.values
    test_df.to_parquet(output_test_path, index=False)

    # Guardar artefactos de preprocesamiento para el servicio de inferencia
    artifacts_dir = Path(output_train_path).parent / "preprocessing_artifacts"
    artifacts_dir.mkdir(parents=True, exist_ok=True)
    joblib.dump(encoders, artifacts_dir / "encoders.joblib")
    joblib.dump(scaler,   artifacts_dir / "scaler.joblib")

    # Versionar datos procesados con DVC
    for path in [output_train_path, output_test_path]:
        try:
            subprocess.run(["dvc", "add", path], capture_output=True, check=False)
        except FileNotFoundError:
            logger.warning("DVC no disponible en PATH, saltando versionado")

    metadata = {
        "train_rows"      : len(train_df),
        "test_rows"       : len(test_df),
        "num_features"    : len(X_train_scaled.columns),
        "feature_names"   : list(X_train_scaled.columns),
        "train_churn_rate": round(float(y_train.mean()) * 100, 2),
        "test_churn_rate" : round(float(y_test.mean()) * 100, 2),
    }

    if "ti" in context:
        context["ti"].xcom_push(key="preprocessing_metadata", value=metadata)

    logger.info(
        "Preprocesamiento completo: train=%d | test=%d | features=%d",
        metadata["train_rows"], metadata["test_rows"], metadata["num_features"]
    )
    logger.info("═══ Preprocesamiento finalizado ═══")
    return metadata