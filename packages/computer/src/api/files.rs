//! File endpoints: mkdir / write (tar.gz) / read (octet-stream) / stat / readdir.

use axum::Json;
use axum::body::{Body, Bytes};
use axum::extract::{Path, State};
use axum::http::HeaderMap;
use axum::http::header::CONTENT_TYPE;
use axum::response::{IntoResponse, Response};
use serde::Deserialize;
use serde_json::{Value, json};
use tokio_util::io::ReaderStream;

use crate::auth::Authenticated;
use crate::error::{AppError, AppResult};
use crate::fs;
use crate::state::AppState;

#[derive(Deserialize)]
pub struct PathBody {
  path: String,
  #[serde(default)]
  cwd: Option<String>,
  #[serde(default)]
  recursive: Option<bool>,
}

fn session(
  state: &AppState,
  agent_uid: &str,
) -> AppResult<std::sync::Arc<crate::session::SessionHandle>> {
  state
    .sessions
    .get(agent_uid)
    .ok_or_else(|| AppError::not_found("session_not_found", "no session; call PUT first"))
}

pub async fn mkdir(
  State(state): State<AppState>,
  Path(agent_uid): Path<String>,
  auth: Authenticated,
  Json(body): Json<PathBody>,
) -> AppResult<Json<Value>> {
  auth.require_agent(&agent_uid)?;
  let handle = session(&state, &agent_uid)?;
  fs::mkdir(
    &handle.paths,
    body.cwd.as_deref(),
    &body.path,
    body.recursive.unwrap_or(true),
  )
  .await?;
  Ok(Json(json!({ "ok": true })))
}

/// Write files by uploading a gzipped tar in the raw request body.
///
/// A tar.gz lets one request create many files and directories atomically and preserve
/// modes, which a JSON-per-file API could not do cheaply. The base cwd rides in the
/// `x-cwd` header rather than the body because the body is the binary archive. After
/// extracting, the library-containers tree is synced back to PG in case the upload
/// touched the agent's writable library files (SOUL / skill appends).
pub async fn write(
  State(state): State<AppState>,
  Path(agent_uid): Path<String>,
  auth: Authenticated,
  headers: HeaderMap,
  body: Bytes,
) -> AppResult<Json<Value>> {
  auth.require_agent(&agent_uid)?;
  let handle = session(&state, &agent_uid)?;
  let cwd = headers.get("x-cwd").and_then(|value| value.to_str().ok());
  let result = fs::write_tar_gz(&handle.paths, cwd, body).await?;
  state.sessions.sync_library_containers(&agent_uid).await?;
  Ok(Json(json!({ "ok": true, "files": result.files })))
}

/// Read a single file, streaming its bytes back as `application/octet-stream`.
///
/// The file is streamed rather than buffered so large artifacts do not have to fit in
/// memory. A missing file or non-file path comes back from `open_read` as `None`, which
/// is mapped to a 404 here; the size from `open_read` is unused because the stream sets
/// its own framing.
pub async fn read(
  State(state): State<AppState>,
  Path(agent_uid): Path<String>,
  auth: Authenticated,
  Json(body): Json<PathBody>,
) -> AppResult<Response> {
  auth.require_agent(&agent_uid)?;
  let handle = session(&state, &agent_uid)?;
  match fs::open_read(&handle.paths, body.cwd.as_deref(), &body.path).await? {
    Some((file, _size)) => {
      let stream = ReaderStream::new(file);
      Ok(
        (
          [(CONTENT_TYPE, "application/octet-stream")],
          Body::from_stream(stream),
        )
          .into_response(),
      )
    }
    None => Err(AppError::not_found(
      "not_found",
      format!("no such file: {}", body.path),
    )),
  }
}

pub async fn stat(
  State(state): State<AppState>,
  Path(agent_uid): Path<String>,
  auth: Authenticated,
  Json(body): Json<PathBody>,
) -> AppResult<Json<fs::FileStat>> {
  auth.require_agent(&agent_uid)?;
  let handle = session(&state, &agent_uid)?;
  Ok(Json(
    fs::stat(&handle.paths, body.cwd.as_deref(), &body.path).await?,
  ))
}

pub async fn readdir(
  State(state): State<AppState>,
  Path(agent_uid): Path<String>,
  auth: Authenticated,
  Json(body): Json<PathBody>,
) -> AppResult<Json<Value>> {
  auth.require_agent(&agent_uid)?;
  let handle = session(&state, &agent_uid)?;
  let entries = fs::readdir(&handle.paths, body.cwd.as_deref(), &body.path).await?;
  Ok(Json(json!({ "entries": entries })))
}
