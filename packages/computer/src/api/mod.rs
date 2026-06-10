//! Router assembly for the worker h2/mTLS API.

pub mod commands;
pub mod files;
pub mod sessions;
pub mod terminals;

use axum::Router;
use axum::routing::{delete, get, post, put};

use crate::state::AppState;

pub fn router(state: AppState) -> Router {
  Router::new()
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
    .route("/v1/sessions/{agent_uid}/fs/mkdir", post(files::mkdir))
    .route("/v1/sessions/{agent_uid}/fs/write", post(files::write))
    .route("/v1/sessions/{agent_uid}/fs/read", post(files::read))
    .route("/v1/sessions/{agent_uid}/fs/stat", post(files::stat))
    .route("/v1/sessions/{agent_uid}/fs/readdir", post(files::readdir))
    .with_state(state)
}
