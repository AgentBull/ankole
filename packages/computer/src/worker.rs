//! Worker registration + heartbeat through PostgreSQL.
//!
//! The worker no longer calls the BullX app over an internal HTTP endpoint.
//! It shares the database with the app, records its own presence there, and the
//! app resolver reads the same `computer_workers` table.

use std::time::Duration;

use serde_json::json;
use tokio_postgres::{Client, NoTls};

use crate::state::AppState;

pub fn start(state: AppState) -> tokio::task::JoinHandle<()> {
  tokio::spawn(async move { run(state).await })
}

async fn run(state: AppState) {
  // Register, retrying until PostgreSQL accepts us.
  loop {
    match register(&state).await {
      Ok(()) => {
        tracing::info!(worker_id = %state.config.worker_id, "registered in PostgreSQL");
        break;
      }
      Err(error) => {
        tracing::warn!(%error, "worker registration failed; retrying");
        tokio::time::sleep(Duration::from_secs(3)).await;
      }
    }
  }

  let mut ticker = tokio::time::interval(Duration::from_secs(state.config.heartbeat_secs));
  loop {
    ticker.tick().await;
    if let Err(error) = heartbeat(&state).await {
      tracing::warn!(%error, "heartbeat failed");
    }
  }
}

async fn register(state: &AppState) -> anyhow::Result<()> {
  let client = connect(&state.config.database_url).await?;
  let config = &state.config;
  let features = json!(config.features);
  let capacity = json!({ "maxAgents": config.max_agents, "maxCommands": config.max_commands });
  let metadata = json!({
    "podName": config.pod_name,
    "namespace": config.namespace,
    "nodeName": config.node_name,
    "transport": "h2-mtls"
  });
  client
    .execute(
      "insert into computer_workers (worker_id, instance_id, base_url, status, version, features, capacity, metadata, last_heartbeat_at, updated_at) values ($1, $2, $3, 'ready', $4, $5, $6, $7, now(), now()) on conflict (worker_id) do update set instance_id = excluded.instance_id, base_url = excluded.base_url, status = 'ready', version = excluded.version, features = excluded.features, capacity = excluded.capacity, metadata = excluded.metadata, last_heartbeat_at = now(), updated_at = now()",
      &[&config.worker_id, &config.instance_id, &config.base_url, &config.version, &features, &capacity, &metadata],
    )
    .await?;
  Ok(())
}

async fn heartbeat(state: &AppState) -> anyhow::Result<()> {
  let client = connect(&state.config.database_url).await?;
  let config = &state.config;
  let load = json!({
    "cpu": 0.0,
    "memoryBytes": memory_bytes(),
    "runningSessions": state.sessions.count(),
    "runningCommands": state.sessions.running_commands()
  });
  let updated = client
    .execute(
      "update computer_workers set instance_id = $2, status = 'ready', load = $3, last_heartbeat_at = now(), updated_at = now() where worker_id = $1",
      &[&config.worker_id, &config.instance_id, &load],
    )
    .await?;
  if updated == 0 {
    register(state).await?;
  }
  Ok(())
}

async fn connect(database_url: &str) -> anyhow::Result<Client> {
  let (client, connection) = tokio_postgres::connect(database_url, NoTls).await?;
  tokio::spawn(async move {
    if let Err(error) = connection.await {
      tracing::warn!(%error, "PostgreSQL worker connection task ended");
    }
  });
  Ok(client)
}

#[cfg(target_os = "linux")]
fn memory_bytes() -> u64 {
  // RSS pages from /proc/self/statm * page size.
  let Ok(statm) = std::fs::read_to_string("/proc/self/statm") else {
    return 0;
  };
  let rss_pages: u64 = statm
    .split_whitespace()
    .nth(1)
    .and_then(|value| value.parse().ok())
    .unwrap_or(0);
  rss_pages.saturating_mul(4096)
}

#[cfg(not(target_os = "linux"))]
fn memory_bytes() -> u64 {
  0
}
