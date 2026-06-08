//! Session lifecycle endpoints.

use axum::Json;
use axum::extract::{Path, State};
use serde::Serialize;
use serde_json::{Value, json};

use crate::auth::Authenticated;
use crate::error::{AppError, AppResult};
use crate::session::SessionHandle;
use crate::state::AppState;

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Workspace {
  library_containers: String,
  user_files: String,
  temp: String,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SessionResponse {
  session_id: String,
  agent_uid: String,
  worker_id: String,
  created: bool,
  workspace: Workspace,
  created_at: String,
  last_used_at: String,
}

fn workspace() -> Workspace {
  Workspace {
    library_containers: "/workspace/library-containers".to_string(),
    user_files: "/workspace/user-files".to_string(),
    temp: "/workspace/temp".to_string(),
  }
}

fn describe(handle: &SessionHandle, worker_id: &str, created: bool) -> SessionResponse {
  SessionResponse {
    session_id: handle.session_id.to_string(),
    agent_uid: handle.agent_uid.clone(),
    worker_id: worker_id.to_string(),
    created,
    workspace: workspace(),
    created_at: handle.created_at.to_rfc3339(),
    last_used_at: handle.last_used_at().to_rfc3339(),
  }
}

pub async fn put_session(
  State(state): State<AppState>,
  Path(agent_uid): Path<String>,
  auth: Authenticated,
) -> AppResult<Json<SessionResponse>> {
  auth.require_agent(&agent_uid)?;
  let (handle, created) = state.sessions.get_or_create(&agent_uid).await?;
  Ok(Json(describe(&handle, &state.config.worker_id, created)))
}

pub async fn get_session(
  State(state): State<AppState>,
  Path(agent_uid): Path<String>,
  auth: Authenticated,
) -> AppResult<Json<SessionResponse>> {
  auth.require_agent(&agent_uid)?;
  let handle = state.sessions.get(&agent_uid).ok_or_else(|| {
    AppError::not_found("session_not_found", "no session for agent; call PUT first")
  })?;
  Ok(Json(describe(&handle, &state.config.worker_id, false)))
}

pub async fn stop_session(
  State(state): State<AppState>,
  Path(agent_uid): Path<String>,
  auth: Authenticated,
) -> AppResult<Json<Value>> {
  auth.require_agent(&agent_uid)?;
  let handle = state
    .sessions
    .stop(&agent_uid)
    .await
    .ok_or_else(|| AppError::not_found("session_not_found", "no session to stop"))?;
  Ok(Json(json!({
    "sessionId": handle.session_id.to_string(),
    "agentUid": agent_uid,
    "workerId": state.config.worker_id,
    "stoppedAt": chrono::Utc::now().to_rfc3339(),
  })))
}

pub async fn reset_shell(
  State(state): State<AppState>,
  Path(agent_uid): Path<String>,
  auth: Authenticated,
) -> AppResult<Json<Value>> {
  auth.require_agent(&agent_uid)?;
  let handle = state
    .sessions
    .get(&agent_uid)
    .ok_or_else(|| AppError::not_found("session_not_found", "no session for agent"))?;
  handle.reset_shell().await?;
  Ok(Json(json!({ "ok": true })))
}
