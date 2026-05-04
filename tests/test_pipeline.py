"""
Tests unitarios para los módulos de ingesta, preprocesamiento y API.
Dataset de referencia: IBM Telco Customer Churn (CustomerChurn.csv)

Ejecutar con: pytest tests/ -v
"""

from __future__ import annotations

from pathlib import Path
from unittest.mock import MagicMock, patch

import numpy as np
import pandas as pd
import pytest


# ──────────────────────────────────────────────
# Fixtures — estructura real del dataset IBM
# ──────────────────────────────────────────────

@pytest.fixture
def sample_ibm_raw_df() -> pd.DataFrame:
    """DataFrame con las columnas exactas del CustomerChurn.csv de IBM."""
    return pd.DataFrame({
        "LoyaltyID"         : ["LOY-001", "LOY-002", "LOY-003"],
        "Customer ID"       : ["1234-AAAAA", "5678-BBBBB", "9012-CCCCC"],
        "Senior Citizen"    : [0, 1, 0],
        "Partner"           : ["Yes", "No", "Yes"],
        "Dependents"        : ["No", "No", "Yes"],
        "Tenure"            : [12, 36, 5],
        "Phone Service"     : ["Yes", "Yes", "No"],
        "Multiple Lines"    : ["Yes", "No", "No phone service"],
        "Internet Service"  : ["DSL", "Fiber optic", "No"],
        "Online Security"   : ["No", "Yes", "No internet service"],
        "Online Backup"     : ["Yes", "No", "No internet service"],
        "Device Protection" : ["No", "Yes", "No internet service"],
        "Tech Support"      : ["No", "No", "No internet service"],
        "Streaming TV"      : ["No", "Yes", "No internet service"],
        "Streaming Movies"  : ["No", "Yes", "No internet service"],
        "Contract"          : ["Month-to-month", "One year", "Two year"],
        "Paperless Billing" : ["Yes", "Yes", "No"],
        "Payment Method"    : ["Electronic check", "Bank transfer (automatic)", "Mailed check"],
        "Monthly Charges"   : [65.5, 89.1, 20.0],
        "Total Charges"     : ["786.0", "3207.6", "100.0"],
        "Churn"             : ["No", "No", "Yes"],
    })


@pytest.fixture
def sample_normalized_df(sample_ibm_raw_df) -> pd.DataFrame:
    """DataFrame ya normalizado (como sale de ingest.py)."""
    from src.data.ingest import normalize_columns
    return normalize_columns(sample_ibm_raw_df)


@pytest.fixture
def temp_raw_csv(sample_ibm_raw_df, tmp_path) -> Path:
    """CSV temporal con el formato IBM."""
    csv_path = tmp_path / "CustomerChurn.csv"
    sample_ibm_raw_df.to_csv(csv_path, index=False)
    return csv_path


@pytest.fixture
def temp_normalized_csv(sample_normalized_df, tmp_path) -> Path:
    """CSV temporal ya normalizado."""
    csv_path = tmp_path / "churn_normalized.csv"
    sample_normalized_df.to_csv(csv_path, index=False)
    return csv_path


# ──────────────────────────────────────────────
# Tests de ingesta
# ──────────────────────────────────────────────

class TestDataIngestion:

    def test_normalize_columns_renombra_correctamente(self, sample_ibm_raw_df):
        """normalize_columns convierte los nombres IBM al esquema interno."""
        from src.data.ingest import normalize_columns
        df = normalize_columns(sample_ibm_raw_df)
        assert "SeniorCitizen"  in df.columns
        assert "tenure"         in df.columns
        assert "PhoneService"   in df.columns
        assert "MonthlyCharges" in df.columns
        assert "Customer ID"    not in df.columns
        assert "Senior Citizen" not in df.columns

    def test_normalize_columns_no_elimina_ids(self, sample_ibm_raw_df):
        """normalize_columns no elimina LoyaltyID ni CustomerID — eso es tarea de preprocess."""
        from src.data.ingest import normalize_columns
        df = normalize_columns(sample_ibm_raw_df)
        assert "LoyaltyID"  in df.columns
        assert "CustomerID" in df.columns

    def test_validate_schema_correcto(self, sample_normalized_df):
        """validate_schema no lanza excepción con un DataFrame normalizado válido."""
        from src.data.ingest import validate_schema
        # Necesita >= 100 filas para pasar la validación de tamaño
        big_df = pd.concat([sample_normalized_df] * 40, ignore_index=True)
        validate_schema(big_df)

    def test_validate_schema_falta_columna(self, sample_normalized_df):
        """validate_schema lanza ValueError si falta una columna requerida."""
        from src.data.ingest import validate_schema
        big_df = pd.concat([sample_normalized_df] * 40, ignore_index=True)
        big_df = big_df.drop(columns=["Churn"])
        with pytest.raises(ValueError, match="columnas requeridas"):
            validate_schema(big_df)

    def test_compute_file_hash_consistente(self, temp_raw_csv):
        """El mismo archivo siempre produce el mismo hash SHA-256."""
        from src.data.ingest import compute_file_hash
        assert compute_file_hash(temp_raw_csv) == compute_file_hash(temp_raw_csv)

    def test_compute_file_hash_longitud(self, temp_raw_csv):
        """El hash SHA-256 tiene exactamente 64 caracteres hexadecimales."""
        from src.data.ingest import compute_file_hash
        assert len(compute_file_hash(temp_raw_csv)) == 64

    @patch("src.data.ingest.dvc_add_and_push")
    def test_run_data_ingestion_retorna_metadata(self, mock_dvc, sample_ibm_raw_df, tmp_path):
        """run_data_ingestion retorna metadata con las claves esperadas."""
        from src.data.ingest import run_data_ingestion

        big_df = pd.concat([sample_ibm_raw_df] * 40, ignore_index=True)
        source = tmp_path / "CustomerChurn.csv"
        output = tmp_path / "out" / "churn.csv"
        big_df.to_csv(source, index=False)

        result = run_data_ingestion(str(source), str(output))

        assert "dataset_hash"  in result
        assert "num_rows"      in result
        assert "churn_rate"    in result
        assert result["num_rows"] == len(big_df)
        assert mock_dvc.called

    def test_gender_no_esta_en_columnas(self, sample_ibm_raw_df):
        """El dataset IBM no tiene columna gender — verificar que el pipeline no la requiere."""
        from src.data.ingest import normalize_columns, REQUIRED_COLUMNS
        df = normalize_columns(sample_ibm_raw_df)
        assert "gender" not in df.columns
        assert "gender" not in REQUIRED_COLUMNS


# ──────────────────────────────────────────────
# Tests de preprocesamiento
# ──────────────────────────────────────────────

class TestPreprocessing:

    def test_clean_data_elimina_ids(self, sample_normalized_df):
        """clean_data elimina LoyaltyID y CustomerID."""
        from src.data.preprocess import clean_data
        result = clean_data(sample_normalized_df)
        assert "LoyaltyID"  not in result.columns
        assert "CustomerID" not in result.columns

    def test_clean_data_convierte_totalcharges(self, sample_normalized_df):
        """clean_data convierte TotalCharges a numérico y rellena nulos."""
        from src.data.preprocess import clean_data
        df = sample_normalized_df.copy()
        df.loc[0, "Total Charges"] = " "
        result = clean_data(df)
        assert pd.api.types.is_numeric_dtype(result["TotalCharges"])
        assert result["TotalCharges"].isnull().sum() == 0

    def test_clean_data_no_tiene_gender(self, sample_normalized_df):
        """Verificar que gender no aparece en ningún momento del preprocesamiento."""
        from src.data.preprocess import clean_data, CATEGORICAL_COLUMNS, NUMERIC_COLUMNS
        result = clean_data(sample_normalized_df)
        assert "gender" not in result.columns
        assert "gender" not in CATEGORICAL_COLUMNS
        assert "gender" not in NUMERIC_COLUMNS

    def test_encode_features_target_binario(self, sample_normalized_df):
        """encode_features convierte Churn a 0/1."""
        from src.data.preprocess import clean_data, encode_features
        df_clean = clean_data(sample_normalized_df)
        df_encoded, _ = encode_features(df_clean)
        assert set(df_encoded["Churn"].unique()).issubset({0, 1})

    def test_scale_features_sin_data_leakage(self):
        """El scaler se ajusta solo en train — sus parámetros reflejan el train set."""
        from src.data.preprocess import scale_features
        X_train = pd.DataFrame({
            "tenure"         : [1.0, 2.0, 3.0],
            "MonthlyCharges" : [10.0, 20.0, 30.0],
            "TotalCharges"   : [100.0, 200.0, 300.0],
            "SeniorCitizen"  : [0.0, 0.0, 1.0],
        })
        X_test = pd.DataFrame({
            "tenure"         : [10.0, 20.0],
            "MonthlyCharges" : [100.0, 200.0],
            "TotalCharges"   : [1000.0, 2000.0],
            "SeniorCitizen"  : [0.0, 1.0],
        })
        _, _, scaler = scale_features(X_train, X_test)
        assert abs(scaler.mean_[0] - X_train["tenure"].mean()) < 1e-6


# ──────────────────────────────────────────────
# Tests de la API FastAPI
# ──────────────────────────────────────────────

class TestFastAPIEndpoints:

    @pytest.fixture(autouse=True)
    def mock_model_state(self):
        mock_model = MagicMock()
        mock_model.predict.return_value = np.array([1])
        mock_model.predict_proba.return_value = np.array([[0.22, 0.78]])
        mock_model.n_estimators = 200
        mock_model.max_depth = 10
        mock_model.n_features_in_ = 18  # 19 columnas originales - gender

        with patch("src.api.app._model_state", {
            "model"        : mock_model,
            "model_uri"    : "models:/churn-predictor@Production",
            "model_version": "3",
            "loaded_at"    : 1000000.0,
        }):
            yield mock_model

    @pytest.fixture
    def client(self):
        from fastapi.testclient import TestClient
        from src.api.app import app
        return TestClient(app)

    @pytest.fixture
    def valid_payload(self) -> dict:
        """Payload sin gender — columnas reales del dataset IBM."""
        return {
            "SeniorCitizen"   : 0,
            "Partner"         : 1,
            "Dependents"      : 0,
            "tenure"          : 12.0,
            "PhoneService"    : 1,
            "MultipleLines"   : 0,
            "InternetService" : 1,
            "OnlineSecurity"  : 0,
            "OnlineBackup"    : 0,
            "DeviceProtection": 0,
            "TechSupport"     : 0,
            "StreamingTV"     : 1,
            "StreamingMovies" : 1,
            "Contract"        : 0,
            "PaperlessBilling": 1,
            "PaymentMethod"   : 2,
            "MonthlyCharges"  : 65.50,
            "TotalCharges"    : 786.0,
        }

    def test_health_check(self, client):
        response = client.get("/health")
        assert response.status_code == 200
        assert response.json()["model_loaded"] is True

    def test_predict_estructura_respuesta(self, client, valid_payload):
        response = client.post("/predict", json=valid_payload)
        assert response.status_code == 200
        body = response.json()
        assert "churn_prediction"  in body
        assert "churn_probability" in body
        assert "risk_level"        in body
        assert "model_version"     in body

    def test_predict_riesgo_alto(self, client, valid_payload):
        """Con probabilidad 0.78 el nivel de riesgo debe ser 'alto'."""
        response = client.post("/predict", json=valid_payload)
        assert response.json()["risk_level"] == "alto"

    def test_predict_sin_gender(self, client, valid_payload):
        """El payload no incluye gender — la API no debe requerirlo."""
        assert "gender" not in valid_payload
        response = client.post("/predict", json=valid_payload)
        assert response.status_code == 200

    def test_predict_campos_requeridos(self, client):
        """Sin campos, la API retorna 422."""
        response = client.post("/predict", json={})
        assert response.status_code == 422