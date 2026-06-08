//! Command + persistent-shell endpoints (NDJSON streaming).

use std::collections::BTreeMap;
use std::time::Duration;

use axum::Json;
use axum::extract::{Path, Query, State};
use axum::response::Response;
use futures::{Stream, StreamExt};
use serde::Deserialize;
use serde_json::{Value, json};

use crate::auth::Authenticated;
use crate::command::{CommandSnapshot, LogEvent, follow};
use crate::error::{AppError, AppResult};
use crate::ndjson::ndjson_stream;
use crate::state::AppState;

const DEFAULT_TIMEOUT_MS: u64 = 60_000;

#[derive(Deserialize)]
pub struct CommandBody {
  command: String,
  #[serde(default)]
  args: Vec<String>,
  #[serde(default)]
  cwd: Option<String>,
  #[serde(default)]
  env: BTreeMap<String, String>,
  #[serde(default)]
  sudo: bool,
  #[serde(default = "default_wait")]
  wait: bool,
  #[serde(default)]
  timeout: Option<u64>,
}

#[derive(Deserialize)]
pub struct ShellBody {
  command: String,
  #[serde(default)]
  cwd: Option<String>,
  #[serde(default)]
  env: BTreeMap<String, String>,
  #[serde(default)]
  timeout: Option<u64>,
}

#[derive(Deserialize)]
pub struct KillBody {
  #[serde(default)]
  signal: Option<Value>,
}

fn default_wait() -> bool {
  true
}

fn running_line(snapshot: &CommandSnapshot) -> Value {
  json!({ "command": { "id": snapshot.id, "status": "running", "cwd": snapshot.cwd } })
}

pub async fn run_command(
  State(state): State<AppState>,
  Path(agent_uid): Path<String>,
  auth: Authenticated,
  Json(body): Json<CommandBody>,
) -> AppResult<Response> {
  auth.require_agent(&agent_uid)?;
  if body.sudo {
    return Err(AppError::bad_request(
      "unsupported_sudo",
      "sudo is not supported in this computer version",
    ));
  }
  let session = state
    .sessions
    .get(&agent_uid)
    .ok_or_else(|| AppError::not_found("session_not_found", "no session; call PUT first"))?;
  if session.commands.running() >= state.config.max_commands {
    return Err(AppError::unavailable(
      "too_many_commands",
      "command concurrency limit reached",
    ));
  }

  let handle = session.spawn_command(
    &body.command,
    &body.args,
    body.cwd.as_deref(),
    &body.env,
    !body.wait,
  )?;
  let snapshot = handle.snapshot();
  let first = running_line(&snapshot);

  if !body.wait {
    return Ok(ndjson_stream(futures::stream::once(async move { first })));
  }

  let id = handle.id.clone();
  let output = handle.output.clone();
  let timeout = Duration::from_millis(body.timeout.unwrap_or(DEFAULT_TIMEOUT_MS));
  let commands_session = session.clone();

  let stream = async_stream::stream! {
    yield first;
    match tokio::time::timeout(timeout, output.wait_done()).await {
      Ok((status, exit_code)) => {
        yield json!({ "command": { "id": id, "status": status.as_str(), "exitCode": exit_code } });
      }
      Err(_) => {
        let _ = commands_session.commands.kill(&id, Some("SIGKILL"));
        yield json!({ "command": { "id": id, "status": "killed", "exitCode": 124 } });
      }
    }
  };
  Ok(ndjson_stream(stream))
}

pub async fn run_shell(
  State(state): State<AppState>,
  Path(agent_uid): Path<String>,
  auth: Authenticated,
  Json(body): Json<ShellBody>,
) -> AppResult<Response> {
  auth.require_agent(&agent_uid)?;
  let session = state
    .sessions
    .get(&agent_uid)
    .ok_or_else(|| AppError::not_found("session_not_found", "no session; call PUT first"))?;

  let timeout = Duration::from_millis(body.timeout.unwrap_or(DEFAULT_TIMEOUT_MS));
  let result = session
    .shell_run(&body.command, body.cwd.as_deref(), &body.env, timeout)
    .await?;
  if result.timed_out {
    tracing::warn!(%agent_uid, "persistent shell command timed out");
  }
  let cwd = result.cwd.clone();
  let exit_code = result.exit_code;
  let handle = session
    .commands
    .insert_finished(result.output, exit_code, cwd.clone());
  let id = handle.id.clone();

  let lines = vec![
    json!({ "command": { "id": id, "status": "running", "cwd": cwd } }),
    json!({ "command": { "id": id, "status": "finished", "exitCode": exit_code } }),
  ];
  Ok(ndjson_stream(futures::stream::iter(lines)))
}

pub async fn list_commands(
  State(state): State<AppState>,
  Path(agent_uid): Path<String>,
  auth: Authenticated,
) -> AppResult<Json<Value>> {
  auth.require_agent(&agent_uid)?;
  let session = state
    .sessions
    .get(&agent_uid)
    .ok_or_else(|| AppError::not_found("session_not_found", "no session"))?;
  Ok(Json(json!({ "commands": session.commands.list() })))
}

pub async fn get_command(
  State(state): State<AppState>,
  Path((agent_uid, cmd_id)): Path<(String, String)>,
  auth: Authenticated,
) -> AppResult<Json<CommandSnapshot>> {
  auth.require_agent(&agent_uid)?;
  let session = state
    .sessions
    .get(&agent_uid)
    .ok_or_else(|| AppError::not_found("session_not_found", "no session"))?;
  let handle = session
    .commands
    .get(&cmd_id)
    .ok_or_else(|| AppError::not_found("command_not_found", "no such command"))?;
  Ok(Json(handle.snapshot()))
}

#[derive(Deserialize)]
pub struct LogsQuery {
  /// When `false`, return the buffered output and close instead of following to completion.
  #[serde(default)]
  follow: Option<bool>,
}

fn log_line(event: LogEvent) -> Value {
  json!({ "stream": event.stream.as_str(), "data": String::from_utf8_lossy(&event.data).into_owned() })
}

pub async fn command_logs(
  State(state): State<AppState>,
  Path((agent_uid, cmd_id)): Path<(String, String)>,
  auth: Authenticated,
  Query(query): Query<LogsQuery>,
) -> AppResult<Response> {
  auth.require_agent(&agent_uid)?;
  let session = state
    .sessions
    .get(&agent_uid)
    .ok_or_else(|| AppError::not_found("session_not_found", "no session"))?;
  let handle = session
    .commands
    .get(&cmd_id)
    .ok_or_else(|| AppError::not_found("command_not_found", "no such command"))?;

  let stream: std::pin::Pin<Box<dyn Stream<Item = Value> + Send>> = if query.follow == Some(false) {
    Box::pin(futures::stream::iter(handle.output.snapshot_events()).map(log_line))
  } else {
    Box::pin(follow(handle.output.clone()).map(log_line))
  };
  Ok(ndjson_stream(stream))
}

pub async fn kill_command(
  State(state): State<AppState>,
  Path((agent_uid, cmd_id)): Path<(String, String)>,
  auth: Authenticated,
  body: Option<Json<KillBody>>,
) -> AppResult<Json<Value>> {
  auth.require_agent(&agent_uid)?;
  let session = state
    .sessions
    .get(&agent_uid)
    .ok_or_else(|| AppError::not_found("session_not_found", "no session"))?;
  let signal = body
    .and_then(|Json(body)| body.signal)
    .and_then(signal_to_string);
  session.commands.kill(&cmd_id, signal.as_deref())?;
  Ok(Json(json!({ "ok": true })))
}

fn signal_to_string(value: Value) -> Option<String> {
  match value {
    Value::String(text) => Some(text),
    Value::Number(number) => Some(number.to_string()),
    _ => None,
  }
}
