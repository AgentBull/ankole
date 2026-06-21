//! Shared application state injected into every handler.

use std::sync::Arc;

use anyhow::Result;

use crate::config::Config;
use crate::isolation::Launcher;
use crate::session::SessionManager;
use crate::tigerfs::TigerFs;

/// The handle every request handler receives. `Arc` fields make `Clone` cheap so
/// axum can hand a copy to each connection without duplicating the session store.
#[derive(Clone)]
pub struct AppState {
  pub config: Arc<Config>,
  pub sessions: Arc<SessionManager>,
}

impl AppState {
  /// Creates the shared state: pre-creates the workspace backing roots and wires
  /// the launcher + TigerFS into a single `SessionManager`. Runs once at startup.
  pub async fn new(config: Arc<Config>) -> Result<Self> {
    tokio::fs::create_dir_all(&config.workspace_root).await?;
    tokio::fs::create_dir_all(&config.user_files_root).await?;
    tokio::fs::create_dir_all(&config.temp_root).await?;
    tokio::fs::create_dir_all(&config.library_containers_root).await?;
    let tigerfs = Arc::new(TigerFs::postgres(config.database_url.clone()));
    let launcher = Launcher::new(config.isolation);
    let sessions = Arc::new(SessionManager::new(
      config.clone(),
      launcher,
      tigerfs.clone(),
    ));
    Ok(Self { config, sessions })
  }
}
