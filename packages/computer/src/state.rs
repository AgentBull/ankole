//! Shared application state injected into every handler.

use std::sync::Arc;

use anyhow::Result;
use chrono::{DateTime, Utc};

use crate::config::Config;
use crate::isolation::Launcher;
use crate::session::SessionManager;
use crate::tigerfs::{MountBackend, TigerFs};

#[derive(Clone)]
pub struct AppState {
  pub config: Arc<Config>,
  pub sessions: Arc<SessionManager>,
  pub tigerfs: Arc<TigerFs>,
  pub started_at: DateTime<Utc>,
}

impl AppState {
  pub async fn new(config: Arc<Config>) -> Result<Self> {
    tokio::fs::create_dir_all(&config.workspace_root).await?;
    // v1 always uses the directory-backed mount; the real TigerFS backend is a
    // future drop-in behind the same MountBackend seam.
    let tigerfs = Arc::new(TigerFs::new(MountBackend::Directory));
    let launcher = Launcher::new(config.isolation);
    let sessions = Arc::new(SessionManager::new(
      config.clone(),
      launcher,
      tigerfs.clone(),
    ));
    Ok(Self {
      config,
      sessions,
      tigerfs,
      started_at: Utc::now(),
    })
  }
}
