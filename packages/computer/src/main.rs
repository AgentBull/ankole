//! `bullx-computerd` — the BullX Computer worker daemon.
//!
//! Hosts a per-agent persistent shell + one-shot command execution inside
//! bubblewrap (Linux) or directly (dev), a Vercel-like command/file HTTP API,
//! and worker registry/heartbeat against the BullX control plane.

mod api;
mod auth;
mod command;
mod config;
mod error;
mod fs;
mod isolation;
mod ndjson;
mod paths;
mod session;
mod shell;
mod shutdown;
mod state;
mod telemetry;
mod tigerfs;
mod tmux;
mod worker;

use std::sync::Arc;

use clap::Parser;
use tokio::net::TcpListener;

use crate::config::Config;
use crate::state::AppState;

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

  let config = Arc::new(Config::from_env(cli.port)?);
  tracing::info!(
    worker_id = %config.worker_id,
    instance_id = %config.instance_id,
    isolation = ?config.isolation,
    workspace_root = %config.workspace_root.display(),
    "starting bullx-computerd"
  );

  let state = AppState::new(config.clone()).await?;
  let worker_task = worker::start(state.clone());

  let app = api::router(state.clone());
  let listener = TcpListener::bind(("0.0.0.0", config.port)).await?;
  tracing::info!(port = config.port, "listening");

  axum::serve(listener, app)
    .with_graceful_shutdown(shutdown::signal())
    .await?;

  worker_task.abort();
  state.sessions.shutdown_all().await;
  tracing::info!("bullx-computerd stopped");
  Ok(())
}
