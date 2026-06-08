//! First-class tmux terminal endpoints.

use axum::Json;
use axum::extract::{Path, Query, State};
use serde::Deserialize;
use serde_json::{Value, json};

use crate::auth::Authenticated;
use crate::error::{AppError, AppResult};
use crate::state::AppState;

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct StartTerminalBody {
  #[serde(default)]
  command: Option<String>,
  #[serde(default)]
  cwd: Option<String>,
  #[serde(default = "default_cols")]
  cols: u16,
  #[serde(default = "default_rows")]
  rows: u16,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SendTerminalBody {
  #[serde(default)]
  input: Option<String>,
  #[serde(default)]
  keys: Vec<String>,
  #[serde(default)]
  enter: Option<bool>,
}

#[derive(Deserialize)]
pub struct CaptureQuery {
  #[serde(default)]
  lines: Option<u16>,
}

fn default_cols() -> u16 {
  140
}

fn default_rows() -> u16 {
  40
}

pub async fn list_terminals(
  State(state): State<AppState>,
  Path(agent_uid): Path<String>,
  auth: Authenticated,
) -> AppResult<Json<Value>> {
  auth.require_agent(&agent_uid)?;
  let session = state
    .sessions
    .get(&agent_uid)
    .ok_or_else(|| AppError::not_found("session_not_found", "no session; call PUT first"))?;
  let terminals = session.terminals.list().await?;
  Ok(Json(json!({ "terminals": terminals })))
}

pub async fn start_terminal(
  State(state): State<AppState>,
  Path((agent_uid, name)): Path<(String, String)>,
  auth: Authenticated,
  Json(body): Json<StartTerminalBody>,
) -> AppResult<Json<Value>> {
  auth.require_agent(&agent_uid)?;
  let session = state
    .sessions
    .get(&agent_uid)
    .ok_or_else(|| AppError::not_found("session_not_found", "no session; call PUT first"))?;
  let cols = body.cols.clamp(40, 300);
  let rows = body.rows.clamp(10, 100);
  let terminal = session
    .terminals
    .start(
      &name,
      body.command.as_deref(),
      body.cwd.as_deref(),
      cols,
      rows,
    )
    .await?;
  Ok(Json(json!(terminal)))
}

pub async fn send_terminal(
  State(state): State<AppState>,
  Path((agent_uid, name)): Path<(String, String)>,
  auth: Authenticated,
  Json(body): Json<SendTerminalBody>,
) -> AppResult<Json<Value>> {
  auth.require_agent(&agent_uid)?;
  let session = state
    .sessions
    .get(&agent_uid)
    .ok_or_else(|| AppError::not_found("session_not_found", "no session; call PUT first"))?;
  let enter = body.enter.unwrap_or(body.input.is_some());
  let terminal = session
    .terminals
    .send(&name, body.input.as_deref(), &body.keys, enter)
    .await?;
  Ok(Json(json!(terminal)))
}

pub async fn capture_terminal(
  State(state): State<AppState>,
  Path((agent_uid, name)): Path<(String, String)>,
  auth: Authenticated,
  Query(query): Query<CaptureQuery>,
) -> AppResult<Json<Value>> {
  auth.require_agent(&agent_uid)?;
  let session = state
    .sessions
    .get(&agent_uid)
    .ok_or_else(|| AppError::not_found("session_not_found", "no session; call PUT first"))?;
  let lines = query.lines.unwrap_or(80).clamp(1, 2000);
  let capture = session.terminals.capture(&name, lines).await?;
  Ok(Json(json!(capture)))
}

pub async fn kill_terminal(
  State(state): State<AppState>,
  Path((agent_uid, name)): Path<(String, String)>,
  auth: Authenticated,
) -> AppResult<Json<Value>> {
  auth.require_agent(&agent_uid)?;
  let session = state
    .sessions
    .get(&agent_uid)
    .ok_or_else(|| AppError::not_found("session_not_found", "no session; call PUT first"))?;
  let terminal = session.terminals.kill(&name).await?;
  Ok(Json(json!(terminal)))
}
