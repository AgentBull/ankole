//! Session-token verification. The control plane mints a short-lived HS256 JWT per
//! resolve; the worker verifies signature + expiry + `workerId`, and handlers check
//! the path `agent_uid` matches the token. When no shared secret is configured
//! (dev), auth is disabled.

use axum::extract::FromRequestParts;
use axum::http::header::AUTHORIZATION;
use axum::http::request::Parts;
use jsonwebtoken::{Algorithm, DecodingKey, Validation, decode};
use serde::Deserialize;

use crate::error::AppError;
use crate::state::AppState;

#[derive(Debug, Clone, Deserialize)]
pub struct SessionClaims {
  #[serde(rename = "agentUid")]
  pub agent_uid: String,
  #[serde(rename = "workerId")]
  pub worker_id: String,
  #[serde(rename = "instanceId", default)]
  #[allow(dead_code)]
  pub instance_id: Option<String>,
  #[allow(dead_code)]
  pub exp: usize,
}

pub fn verify_session_token(
  token: &str,
  secret: &str,
  expected_worker_id: &str,
) -> Result<SessionClaims, AppError> {
  let mut validation = Validation::new(Algorithm::HS256);
  validation.set_required_spec_claims(&["exp"]);
  validation.validate_exp = true;
  let data = decode::<SessionClaims>(
    token,
    &DecodingKey::from_secret(secret.as_bytes()),
    &validation,
  )
  .map_err(|error| AppError::unauthorized(format!("invalid session token: {error}")))?;
  if data.claims.worker_id != expected_worker_id {
    return Err(AppError::forbidden(
      "worker_mismatch",
      "token is not for this worker",
    ));
  }
  Ok(data.claims)
}

/// Extractor that yields the verified claims, or `None` when auth is disabled (dev).
pub struct Authenticated(pub Option<SessionClaims>);

impl Authenticated {
  /// Assert the authenticated agent matches the path `agent_uid` (no-op in dev).
  pub fn require_agent(&self, agent_uid: &str) -> Result<(), AppError> {
    if let Some(claims) = &self.0
      && claims.agent_uid != agent_uid
    {
      return Err(AppError::forbidden(
        "agent_mismatch",
        "token agent does not match session",
      ));
    }
    Ok(())
  }
}

impl FromRequestParts<AppState> for Authenticated {
  type Rejection = AppError;

  async fn from_request_parts(
    parts: &mut Parts,
    state: &AppState,
  ) -> Result<Self, Self::Rejection> {
    let Some(secret) = state.config.token.as_deref() else {
      return Ok(Authenticated(None));
    };
    let header = parts
      .headers
      .get(AUTHORIZATION)
      .and_then(|value| value.to_str().ok())
      .ok_or_else(|| AppError::unauthorized("missing Authorization header"))?;
    let token = header
      .strip_prefix("Bearer ")
      .ok_or_else(|| AppError::unauthorized("expected Bearer token"))?;
    let claims = verify_session_token(token, secret, &state.config.worker_id)?;
    Ok(Authenticated(Some(claims)))
  }
}
