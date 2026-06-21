//! Request authentication marker.
//!
//! `bullx-computerd` now authenticates the BullX app at the TLS layer with
//! required client certificates. Handlers keep this extractor so route signatures
//! stay explicit about the authenticated boundary, but per-request JWT/session
//! claims are gone.

use axum::extract::FromRequestParts;
use axum::http::request::Parts;

use crate::state::AppState;

pub struct Authenticated;

impl Authenticated {
  /// Keeps handler code explicit about agent-scoped access checks.
  ///
  /// Today the worker trusts the app-level mTLS client certificate and the app
  /// performs session-to-worker routing. The method remains as a narrow seam for
  /// future per-agent claims without spreading that TODO across every handler.
  pub fn require_agent(&self, _agent_uid: &str) -> Result<(), crate::error::AppError> {
    Ok(())
  }
}

impl FromRequestParts<AppState> for Authenticated {
  type Rejection = crate::error::AppError;

  async fn from_request_parts(
    _parts: &mut Parts,
    _state: &AppState,
  ) -> Result<Self, Self::Rejection> {
    Ok(Authenticated)
  }
}
