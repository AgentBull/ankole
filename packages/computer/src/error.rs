//! Uniform error type that renders to a JSON `{ code, message }` body.

use axum::Json;
use axum::http::StatusCode;
use axum::response::{IntoResponse, Response};
use serde_json::json;

#[derive(Debug, thiserror::Error)]
pub enum AppError {
  #[error("{message}")]
  Status {
    status: StatusCode,
    code: &'static str,
    message: String,
  },
  #[error(transparent)]
  Other(#[from] anyhow::Error),
}

impl AppError {
  /// Creates an HTTP-renderable worker error with a stable machine code.
  pub fn new(status: StatusCode, code: &'static str, message: impl Into<String>) -> Self {
    AppError::Status {
      status,
      code,
      message: message.into(),
    }
  }

  pub fn bad_request(code: &'static str, message: impl Into<String>) -> Self {
    Self::new(StatusCode::BAD_REQUEST, code, message)
  }

  pub fn forbidden(code: &'static str, message: impl Into<String>) -> Self {
    Self::new(StatusCode::FORBIDDEN, code, message)
  }

  pub fn not_found(code: &'static str, message: impl Into<String>) -> Self {
    Self::new(StatusCode::NOT_FOUND, code, message)
  }

  pub fn unavailable(code: &'static str, message: impl Into<String>) -> Self {
    Self::new(StatusCode::SERVICE_UNAVAILABLE, code, message)
  }

  pub fn internal(code: &'static str, message: impl Into<String>) -> Self {
    Self::new(StatusCode::INTERNAL_SERVER_ERROR, code, message)
  }
}

impl From<std::io::Error> for AppError {
  fn from(error: std::io::Error) -> Self {
    AppError::new(
      StatusCode::INTERNAL_SERVER_ERROR,
      "io_error",
      error.to_string(),
    )
  }
}

impl From<tokio_postgres::Error> for AppError {
  fn from(error: tokio_postgres::Error) -> Self {
    AppError::internal("postgres_error", error.to_string())
  }
}

impl IntoResponse for AppError {
  /// Converts worker errors into the small JSON shape consumed by the TS SDK.
  ///
  /// Only server errors are logged here. Client errors already become structured
  /// API responses, and logging every bad request would make operator logs noisy.
  fn into_response(self) -> Response {
    let (status, code, message) = match self {
      AppError::Status {
        status,
        code,
        message,
      } => (status, code, message),
      AppError::Other(error) => (
        StatusCode::INTERNAL_SERVER_ERROR,
        "internal",
        error.to_string(),
      ),
    };
    if status.is_server_error() {
      tracing::error!(%code, %message, "request failed");
    }
    (status, Json(json!({ "code": code, "message": message }))).into_response()
  }
}

pub type AppResult<T> = Result<T, AppError>;
