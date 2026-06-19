//! `bullx-computerd` — the BullX Computer worker daemon.
//!
//! Hosts a per-agent persistent shell + one-shot command execution inside
//! bubblewrap (Linux) or directly (dev), a Vercel-like command/file h2 mTLS API,
//! and worker registry/heartbeat through PostgreSQL.

mod api;
mod auth;
mod command;
mod config;
mod error;
mod fs;
mod git_ssh_identity;
mod isolation;
mod ndjson;
mod paths;
mod sealed;
mod session;
mod shell;
mod shutdown;
mod state;
mod telemetry;
mod tigerfs;
mod tls_config;
mod tmux;
mod worker;

use std::net::SocketAddr;
use std::sync::Arc;

use axum_server::Handle;
use axum_server::tls_rustls::RustlsConfig;
use clap::Parser;
use tokio::time::Duration;

use crate::config::Config;
use crate::state::AppState;
use crate::tls_config::rustls_server_config;

/// BullX Computer worker daemon.
#[derive(Debug, Parser)]
#[command(
  name = "bullx-computerd",
  version,
  about = "BullX Computer worker daemon"
)]
struct Cli {
  /// TCP port to listen on (overrides BULLX_COMPUTER_PORT).
  #[arg(long, env = "BULLX_COMPUTER_PORT", default_value_t = 8787)]
  port: u16,
}

#[tokio::main]
async fn main() -> anyhow::Result<()> {
  let cli = Cli::parse();
  telemetry::init();

  let config = Arc::new(Config::from_env(cli.port).await?);
  tracing::info!(
    worker_id = %config.worker_id,
    instance_id = %config.instance_id,
    isolation = ?config.isolation,
    workspace_root = %config.workspace_root.display(),
    user_files_root = %config.user_files_root.display(),
    temp_root = %config.temp_root.display(),
    library_containers_root = %config.library_containers_root.display(),
    "starting bullx-computerd"
  );

  let _ = tokio::fs::remove_file(&config.ready_file).await;
  if let Err(error) =
    git_ssh_identity::provision_if_available(&config.database_url, &config.computer_token).await
  {
    tracing::warn!(%error, "failed to provision computer Git SSH identity");
  }
  let state = AppState::new(config.clone()).await?;
  let worker_task = worker::start(state.clone());

  let app = api::router(state.clone());
  let addr = SocketAddr::from(([0, 0, 0, 0], config.port));
  let tls_config = RustlsConfig::from_config(Arc::new(rustls_server_config(&config.tls)?));
  let handle = Handle::new();
  let shutdown_handle = handle.clone();
  let ready_file = config.ready_file.clone();
  tokio::spawn(async move {
    shutdown::signal().await;
    shutdown_handle.graceful_shutdown(Some(Duration::from_secs(30)));
  });
  tokio::fs::write(&ready_file, b"ready\n").await?;
  tracing::info!(port = config.port, ready_file = %ready_file.display(), "listening with h2 mTLS");

  axum_server::bind_rustls(addr, tls_config)
    .handle(handle)
    .serve(app.into_make_service())
    .await?;

  let _ = tokio::fs::remove_file(&config.ready_file).await;
  worker_task.abort();
  state.sessions.shutdown_all().await;
  tracing::info!("bullx-computerd stopped");
  Ok(())
}
