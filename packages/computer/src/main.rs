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

/// Process entry point. Brings the daemon up in a fixed order — config, SSH
/// identity, shared state, background heartbeat, then the h2/mTLS server — and on
/// the way down drains in-flight work before exiting. The order matters: the
/// readiness file is only written once the listener is actually bound, so probes
/// never see "ready" before the API can accept a connection.
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

  // Clear any stale readiness file left by a previous crash, so a probe cannot
  // observe a "ready" marker that predates this process actually listening.
  let _ = tokio::fs::remove_file(&config.ready_file).await;
  // Best-effort: a missing Git SSH identity must not block the daemon from
  // serving. Agents that do not push over SSH are unaffected.
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
  // Watch for SIGINT/SIGTERM out of band. On signal, ask axum to stop accepting
  // and give in-flight requests up to 30s to finish before the bind future
  // returns; this is the command-drain window on pod termination.
  tokio::spawn(async move {
    shutdown::signal().await;
    shutdown_handle.graceful_shutdown(Some(Duration::from_secs(30)));
  });
  // Only now, with the listener bound, announce readiness to deployment probes.
  tokio::fs::write(&ready_file, b"ready\n").await?;
  tracing::info!(port = config.port, ready_file = %ready_file.display(), "listening with h2 mTLS");

  axum_server::bind_rustls(addr, tls_config)
    .handle(handle)
    .serve(app.into_make_service())
    .await?;

  // Past this point the server has drained and stopped. Retract readiness, stop
  // the heartbeat loop, then tear down every live session (kills tracked
  // processes, shells, and the tmux keeper) before the process exits.
  let _ = tokio::fs::remove_file(&config.ready_file).await;
  worker_task.abort();
  state.sessions.shutdown_all().await;
  tracing::info!("bullx-computerd stopped");
  Ok(())
}
