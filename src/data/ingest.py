"""
Módulo de ingesta de datos para el pipeline de churn.
Dataset fuente: IBM Telco Customer Churn (CustomerChurn.csv)

Responsabilidades:
  - Normalizar los nombres de columnas del CSV de IBM (espacios → CamelCase)
  - Validar el esquema del dataset de entrada
  - Copiar el archivo raw al directorio de trabajo
  - Versionar los datos con DVC (dvc add + dvc push)
  - Registrar metadata en Airflow XCom
"""

from __future__ import annotations

import hashlib
import logging
import os
import shutil
import subprocess
from datetime import datetime
from pathlib import Path
from typing import Any

import pandas as pd

logger = logging.getLogger(__name__)

# Mapa de nombres del CSV IBM → nombres internos del pipeline
# LoyaltyID y Customer ID se eliminan antes de entrenar (alta cardinalidad)
COLUMN_RENAME_MAP = {
    "LoyaltyID"         : "LoyaltyID",          # se elimina en preprocess
    "Customer ID"       : "CustomerID",          # se elimina en preprocess
    "Senior Citizen"    : "SeniorCitizen",
    "Partner"           : "Partner",
    "Dependents"        : "Dependents",
    "Tenure"            : "tenure",
    "Phone Service"     : "PhoneService",
    "Multiple Lines"    : "MultipleLines",
    "Internet Service"  : "InternetService",
    "Online Security"   : "OnlineSecurity",
    "Online Backup"     : "OnlineBackup",
    "Device Protection" : "DeviceProtection",
    "Tech Support"      : "TechSupport",
    "Streaming TV"      : "StreamingTV",
    "Streaming Movies"  : "StreamingMovies",
    "Contract"          : "Contract",
    "Paperless Billing" : "PaperlessBilling",
    "Payment Method"    : "PaymentMethod",
    "Monthly Charges"   : "MonthlyCharges",
    "Total Charges"     : "TotalCharges",
    "Churn"             : "Churn",
}

# Columnas requeridas tras el renombrado (sin gender, sin IDs)
REQUIRED_COLUMNS = [
    "SeniorCitizen",
    "Partner",
    "Dependents",
    "tenure",
    "PhoneService",
    "MultipleLines",
    "InternetService",
    "OnlineSecurity",
    "OnlineBackup",
    "DeviceProtection",
    "TechSupport",
    "StreamingTV",
    "StreamingMovies",
    "Contract",
    "PaperlessBilling",
    "PaymentMethod",
    "MonthlyCharges",
    "TotalCharges",
    "Churn",
]


def normalize_columns(df: pd.DataFrame) -> pd.DataFrame:
    """
    Renombra las columnas del CSV de IBM al esquema interno del pipeline.
    Las columnas no presentes en el mapa se mantienen tal cual.

    Args:
        df: DataFrame cargado directamente desde CustomerChurn.csv

    Returns:
        DataFrame con columnas renombradas.
    """
    df = df.rename(columns=COLUMN_RENAME_MAP)
    logger.info("Columnas normalizadas: %s", list(df.columns))
    return df


def validate_schema(df: pd.DataFrame) -> None:
    """
    Valida que el DataFrame contenga todas las columnas requeridas
    tras la normalización.

    Args:
        df: DataFrame normalizado.

    Raises:
        ValueError: Si falta alguna columna requerida o el dataset es demasiado pequeño.
    """
    missing = set(REQUIRED_COLUMNS) - set(df.columns)
    if missing:
        raise ValueError(
            f"El dataset no tiene las columnas requeridas: {missing}"
        )

    if df["Churn"].isnull().all():
        raise ValueError("La columna 'Churn' está completamente vacía")

    if len(df) < 100:
        raise ValueError(
            f"El dataset tiene solo {len(df)} filas — se requieren al menos 100."
        )

    logger.info(
        "Esquema validado: %d filas, %d columnas",
        len(df), len(df.columns)
    )


def compute_file_hash(file_path: str | Path) -> str:
    """
    Calcula el hash SHA-256 de un archivo para detectar cambios de datos.

    Args:
        file_path: Ruta al archivo.

    Returns:
        String hexadecimal del hash SHA-256.
    """
    sha256 = hashlib.sha256()
    with open(file_path, "rb") as f:
        for chunk in iter(lambda: f.read(8192), b""):
            sha256.update(chunk)
    return sha256.hexdigest()


def dvc_add_and_push(file_path: str | Path, remote: str = "minio") -> None:
    """
    Agrega un archivo al tracking de DVC y lo sube al remote configurado.

    Args:
        file_path: Ruta del archivo a versionar.
        remote: Nombre del remote DVC configurado.

    Raises:
        subprocess.CalledProcessError: Si dvc add falla.
    """
    file_path = Path(file_path)
    logger.info("Versionando %s con DVC...", file_path.name)

    result = subprocess.run(
        ["dvc", "add", str(file_path)],
        capture_output=True, text=True,
        cwd=file_path.parent.parent.parent,
    )
    if result.returncode != 0:
        logger.error("dvc add falló: %s", result.stderr)
        raise subprocess.CalledProcessError(result.returncode, "dvc add", result.stderr)

    subprocess.run(
        ["dvc", "push", "-r", remote],
        capture_output=True, text=True,
        cwd=file_path.parent.parent.parent,
    )
    logger.info("Datos subidos al remote DVC '%s'", remote)


def run_data_ingestion(
    source_path: str,
    output_path: str,
    **context: Any,
) -> dict[str, Any]:
    """
    Función principal de ingesta. Llamada por Airflow PythonOperator.

    Args:
        source_path: Ruta al CustomerChurn.csv fuente.
        output_path: Ruta destino donde se copiará el archivo normalizado.
        **context: Contexto de Airflow.

    Returns:
        Diccionario con metadata del dataset.
    """
    logger.info("═══ Iniciando ingesta de datos ═══")

    source_path = Path(source_path)
    output_path = Path(output_path)

    if not source_path.exists():
        raise FileNotFoundError(
            f"Archivo fuente no encontrado: {source_path}. "
            "Coloca CustomerChurn.csv en data/raw/ antes de ejecutar el DAG."
        )

    output_path.parent.mkdir(parents=True, exist_ok=True)

    # ── Detección de formato y carga resiliente ───────────────────────────
    # El archivo puede ser un CSV de texto plano o un Excel (.xlsx/.xls)
    # renombrado con extensión .csv. Se detecta el tipo real leyendo los
    # primeros bytes (magic bytes) en lugar de confiar en la extensión:
    #
    #   50 4B 03 04  →  ZIP → XLSX (Office Open XML)
    #   D0 CF 11 E0  →  CFB → XLS  (formato binario Excel 97-2003)
    #   Cualquier otro → tratar como CSV de texto
    #
    # Esto evita el ParserError que ocurre cuando pandas intenta leer
    # bytes binarios como si fueran texto CSV.
    XLSX_MAGIC = b"PK\x03\x04"
    XLS_MAGIC  = b"\xd0\xcf\x11\xe0"

    with open(source_path, "rb") as _fh:
        file_magic = _fh.read(4)

    df = None

    if file_magic[:4] == XLSX_MAGIC[:4] or file_magic[:4] == XLS_MAGIC:
        # ── Rama Excel ────────────────────────────────────────────────────
        engine = "openpyxl" if file_magic[:4] == XLSX_MAGIC[:4] else "xlrd"
        logger.info(
            "Archivo detectado como Excel (magic=%s) — usando read_excel(engine='%s')",
            file_magic[:4].hex(), engine,
        )
        try:
            df = pd.read_excel(source_path, engine=engine)
            logger.info(
                "Excel cargado correctamente: %d filas × %d columnas",
                len(df), len(df.columns),
            )
        except Exception as exc:
            raise ValueError(
                f"No se pudo leer el archivo Excel {source_path}: {exc}"
            ) from exc

    else:
        # ── Rama CSV ──────────────────────────────────────────────────────
        # Se prueban tres encodings en orden de probabilidad.
        # sep=None + engine='python' auto-detecta el delimitador (coma,
        # punto y coma, tabulación, etc.) inspeccionando las primeras líneas,
        # evitando el ParserError "Expected N fields, saw M".
        # on_bad_lines='warn' omite líneas malformadas sin abortar la carga.
        ENCODINGS = ["utf-8", "cp1252", "latin-1"]
        for enc in ENCODINGS:
            try:
                df = pd.read_csv(
                    source_path,
                    encoding=enc,
                    sep=None,               # auto-detecta el delimitador
                    engine="python",        # requerido por sep=None
                    on_bad_lines="warn",    # omite líneas malformadas sin abortar
                )
                logger.info(
                    "CSV cargado con encoding '%s' | %d filas × %d columnas",
                    enc, len(df), len(df.columns),
                )
                break
            except UnicodeDecodeError:
                logger.debug("Encoding '%s' falló — probando siguiente...", enc)
            except Exception as parse_err:
                logger.debug("Encoding '%s' — error de parseo: %s", enc, parse_err)

        if df is None:
            raise ValueError(
                f"No se pudo leer el archivo {source_path} como CSV con ninguno "
                f"de los encodings probados: {ENCODINGS}. "
                "Verifica que el archivo sea un CSV o Excel válido."
            )

    df = normalize_columns(df)
    validate_schema(df)
    df.to_csv(output_path, index=False)

    logger.info("Archivo normalizado guardado en: %s", output_path)

    file_hash = compute_file_hash(output_path)

    try:
        dvc_add_and_push(output_path)
    except Exception as e:
        logger.warning("DVC versionado no completó: %s", str(e))

    churn_rate = round(
        df["Churn"].map({"Yes": 1, "No": 0}).mean() * 100, 2
    )

    metadata = {
        "dataset_path" : str(output_path),
        "dataset_hash" : file_hash,
        "ingestion_ts" : datetime.utcnow().isoformat(),
        "num_rows"     : len(df),
        "num_cols"     : len(df.columns),
        "churn_rate"   : churn_rate,
    }

    if "ti" in context:
        context["ti"].xcom_push(key="ingestion_metadata", value=metadata)

    logger.info(
        "Ingesta completada: %d filas | churn rate=%.2f%%",
        metadata["num_rows"], metadata["churn_rate"]
    )
    logger.info("═══ Ingesta finalizada ═══")
    return metadata