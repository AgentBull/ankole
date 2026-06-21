//! Router assembly for the worker h2/mTLS API.

pub mod commands;
pub mod files;
pub mod sessions;
pub mod terminals;

use axum::Router;
use axum::routing::{delete, get, post, put};

use crate::state::AppState;

/// Assemble the full route table for the worker API.
///
/// Everything is keyed by `agent_uid`: a worker hosts many agents and the path segment
/// selects which one. The resource shape is intentionally REST-ish — PUT on the session
/// is the get-or-create entry point that all other routes assume has run first, and the
/// command/log/terminal endpoints stream over NDJSON (see the individual handlers).
pub fn router(state: AppState) -> Router {
  Router::new()
    // PUT creates-or-returns the session (idempotent); GET only reads it. Both live on
    // the same path because they address the same resource.
    .route(
      "/v1/sessions/{agent_uid}",
      put(sessions::put_session).get(sessions::get_session),
    )
    .route(
      "/v1/sessions/{agent_uid}/stop",
      post(sessions::stop_session),
    )
    .route(
      "/v1/sessions/{agent_uid}/reset-shell",
      post(sessions::reset_shell),
    )
    // POST starts a command; GET lists the ones already known to this session.
    .route(
      "/v1/sessions/{agent_uid}/cmd",
      post(commands::run_command).get(commands::list_commands),
    )
    .route(
      "/v1/sessions/{agent_uid}/cmd/{cmd_id}",
      get(commands::get_command),
    )
    .route(
      "/v1/sessions/{agent_uid}/cmd/{cmd_id}/logs",
      get(commands::command_logs),
    )
    .route(
      "/v1/sessions/{agent_uid}/cmd/{cmd_id}/kill",
      post(commands::kill_command),
    )
    .route("/v1/sessions/{agent_uid}/shell", post(commands::run_shell))
    .route(
      "/v1/sessions/{agent_uid}/terminals",
      get(terminals::list_terminals),
    )
    .route(
      "/v1/sessions/{agent_uid}/terminals/{name}/start",
      post(terminals::start_terminal),
    )
    .route(
      "/v1/sessions/{agent_uid}/terminals/{name}/send",
      post(terminals::send_terminal),
    )
    .route(
      "/v1/sessions/{agent_uid}/terminals/{name}/capture",
      get(terminals::capture_terminal),
    )
    .route(
      "/v1/sessions/{agent_uid}/terminals/{name}",
      delete(terminals::kill_terminal),
    )
    // The fs reads (read/stat/readdir) are POST, not GET: they take a path (and
    // sometimes a cwd) in the request body rather than encoding it in the URL, which
    // sidesteps path-escaping and length limits on the query string.
    .route("/v1/sessions/{agent_uid}/fs/mkdir", post(files::mkdir))
    .route("/v1/sessions/{agent_uid}/fs/write", post(files::write))
    .route("/v1/sessions/{agent_uid}/fs/read", post(files::read))
    .route("/v1/sessions/{agent_uid}/fs/stat", post(files::stat))
    .route("/v1/sessions/{agent_uid}/fs/readdir", post(files::readdir))
    .with_state(state)
}
