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
/// Grace period between the polite SIGTERM and the forced SIGKILL when a command
/// overruns its timeout, giving it a moment to exit and flush before it is hard-killed.
const KILL_GRACE_MS: u64 = 3_000;

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
  /// Execution scope (conversation) owning the persistent shell; empty = agent-shared.
  #[serde(default)]
  scope: Option<String>,
}

#[derive(Deserialize)]
pub struct KillBody {
  /// Untyped so the client may send a signal either by name ("SIGTERM") or by number;
  /// `signal_to_string` below normalizes both forms.
  #[serde(default)]
  signal: Option<Value>,
}

/// Commands wait for completion by default; callers opt into fire-and-forget with
/// `wait: false`.
fn default_wait() -> bool {
  true
}

/// The first NDJSON line every command stream emits, announcing the spawned command's id
/// and cwd before any output. Lets the client learn the id immediately, even for a
/// fire-and-forget command it will never get a terminal status for.
fn running_line(snapshot: &CommandSnapshot) -> Value {
  json!({ "command": { "id": snapshot.id, "status": "running", "cwd": snapshot.cwd } })
}

/// Spawn a one-shot command and stream its lifecycle as NDJSON.
///
/// The response always opens with a `running` line carrying the command id, then — when
/// `wait` is set — a terminal `finished`/`killed` line once the process exits or the
/// timeout fires. With `wait: false` the stream is just that single `running` line and
/// the command keeps running detached; the client polls or follows logs separately. The
/// stream is built up front and returned immediately so the HTTP response starts flowing
/// before the command finishes.
pub async fn run_command(
  State(state): State<AppState>,
  Path(agent_uid): Path<String>,
  auth: Authenticated,
  Json(body): Json<CommandBody>,
) -> AppResult<Response> {
  auth.require_agent(&agent_uid)?;
  // sudo is rejected outright rather than ignored, so a client relying on privilege
  // escalation fails loudly instead of silently running unprivileged.
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
  // Reject once the per-worker concurrency budget is full instead of queuing, so a
  // runaway caller cannot pile up unbounded processes; the client sees a 503 and retries.
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

  let timeout_ms = body.timeout.unwrap_or(DEFAULT_TIMEOUT_MS);
  tracing::info!(
    %agent_uid,
    cmd_id = %snapshot.id,
    wait = body.wait,
    timeout_ms,
    command = %body.command.chars().take(200).collect::<String>(),
    "command spawned"
  );

  // Fire-and-forget: emit only the `running` line and let the process run on. `!body.wait`
  // was passed to `spawn_command` as `detached`, so the registry keeps it alive.
  if !body.wait {
    return Ok(ndjson_stream(futures::stream::once(async move { first })));
  }

  let id = handle.id.clone();
  let output = handle.output.clone();
  let timeout = Duration::from_millis(timeout_ms);
  let commands_session = session.clone();

  let stream = async_stream::stream! {
    yield first;
    match tokio::time::timeout(timeout, output.wait_done()).await {
      Ok((status, exit_code)) => {
        tracing::info!(%agent_uid, cmd_id = %id, status = status.as_str(), exit_code, "command finished");
        // A command may have created or edited library files; resync to PG before
        // reporting completion so the durable state matches what the client just ran.
        // A sync failure is logged but not surfaced — the command itself did succeed.
        if let Err(error) = state.sessions.sync_library_containers(&agent_uid).await {
          tracing::warn!(%agent_uid, %error, "failed to sync library-containers after command");
        }
        yield json!({ "command": { "id": id, "status": status.as_str(), "exitCode": exit_code } });
      }
      Err(_) => {
        // Timeout escalation: SIGTERM first for a clean exit, wait the grace period, then
        // SIGKILL whatever is left. Exit code 124 mirrors coreutils `timeout`. Both kills
        // ignore errors because the process may already be gone between the two signals.
        tracing::warn!(%agent_uid, cmd_id = %id, timeout_ms, "command timed out; killing");
        let _ = commands_session.commands.kill(&id, Some("SIGTERM"));
        tokio::time::sleep(Duration::from_millis(KILL_GRACE_MS)).await;
        let _ = commands_session.commands.kill(&id, Some("SIGKILL"));
        yield json!({ "command": { "id": id, "status": "killed", "exitCode": 124 } });
      }
    }
  };
  Ok(ndjson_stream(stream))
}

/// Run a command in the agent's *persistent* shell (state survives across calls).
///
/// Unlike `run_command`, this runs to completion synchronously inside the scope's shell —
/// cwd/env set here persist for later calls in the same scope (see `SessionHandle::shell_run`).
/// The result is then recorded as an already-finished command and replayed as the same
/// two-line `running` + `finished` NDJSON shape `run_command` produces, so a client can
/// treat both endpoints identically and still fetch the output by command id afterward.
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
  // An empty scope is the agent-shared default shell; a named scope (one per
  // conversation) gets its own shell so concurrent conversations don't share cwd/env.
  let result = session
    .shell_run(
      body.scope.as_deref().unwrap_or(""),
      &body.command,
      body.cwd.as_deref(),
      &body.env,
      timeout,
    )
    .await?;
  if let Err(error) = state.sessions.sync_library_containers(&agent_uid).await {
    tracing::warn!(%agent_uid, %error, "failed to sync library-containers after shell command");
  }
  if result.timed_out {
    tracing::warn!(%agent_uid, "persistent shell command timed out");
  }
  let cwd = result.cwd.clone();
  let exit_code = result.exit_code;
  // Register the completed run in the command registry so it is listable and its logs
  // are fetchable by id, exactly like a `run_command` invocation.
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

/// Render one captured output chunk as an NDJSON log line, tagged with its stream
/// (`stdout`/`stderr`). `from_utf8_lossy` is deliberate: command output is not guaranteed
/// to be valid UTF-8, and replacing bad bytes keeps the JSON line well-formed instead of
/// failing the whole stream.
fn log_line(event: LogEvent) -> Value {
  json!({ "stream": event.stream.as_str(), "data": String::from_utf8_lossy(&event.data).into_owned() })
}

/// Stream a command's output log as NDJSON.
///
/// Two modes share one endpoint. `follow=false` returns the buffer captured so far and
/// closes — a one-shot snapshot. Otherwise it tails the command live, emitting chunks as
/// they arrive and ending when the command finishes (see `follow` in command.rs, which is
/// careful not to drop output buffered between its snapshot and the done-flag). Following
/// is the default so a reconnecting client resumes the live tail without asking.
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

  // Boxed because the two arms have different concrete stream types but one return type.
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

/// Coerce the untyped `signal` field into the string form the kill path expects,
/// accepting both a name ("SIGTERM") and a numeric code; any other JSON shape yields
/// `None`, which lets the caller fall back to a default signal.
fn signal_to_string(value: Value) -> Option<String> {
  match value {
    Value::String(text) => Some(text),
    Value::Number(number) => Some(number.to_string()),
    _ => None,
  }
}
