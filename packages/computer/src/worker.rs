//! Worker registration + heartbeat against the BullX control plane.
//! Skipped entirely when `BULLX_AGENT_URL` is unset (pure local dev).

use std::time::Duration;

use reqwest::Client;
use serde_json::json;

use crate::state::AppState;

pub fn start(state: AppState) -> tokio::task::JoinHandle<()> {
  tokio::spawn(async move { run(state).await })
}

async fn run(state: AppState) {
  let Some(agent_url) = state.config.agent_url.clone() else {
    tracing::warn!("BULLX_AGENT_URL not set — skipping worker registration / heartbeat");
    return;
  };
  let agent_url = agent_url.trim_end_matches('/').to_string();
  let client = Client::new();

  // Register, retrying until the control plane accepts us.
  loop {
    match register(&client, &agent_url, &state).await {
      Ok(()) => {
        tracing::info!(worker_id = %state.config.worker_id, "registered with control plane");
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
    if let Err(error) = heartbeat(&client, &agent_url, &state).await {
      tracing::warn!(%error, "heartbeat failed");
    }
  }
}

async fn register(client: &Client, agent_url: &str, state: &AppState) -> anyhow::Result<()> {
  let config = &state.config;
  let body = json!({
    "workerId": config.worker_id,
    "instanceId": config.instance_id,
    "baseUrl": config.base_url,
    "version": config.version,
    "features": config.features,
    "capacity": { "maxAgents": config.max_agents, "maxCommands": config.max_commands },
    "metadata": { "podName": config.pod_name, "namespace": config.namespace, "nodeName": config.node_name },
  });
  let mut request = client
    .post(format!("{agent_url}/internal/computer/workers/register"))
    .json(&body);
  if let Some(token) = &config.token {
    request = request.bearer_auth(token);
  }
  let response = request.send().await?;
  if !response.status().is_success() {
    anyhow::bail!("register returned HTTP {}", response.status());
  }
  Ok(())
}

async fn heartbeat(client: &Client, agent_url: &str, state: &AppState) -> anyhow::Result<()> {
  let config = &state.config;
  let body = json!({
    "workerId": config.worker_id,
    "instanceId": config.instance_id,
    "status": "ready",
    "runningSessions": state.sessions.count(),
    "runningCommands": state.sessions.running_commands(),
    "load": { "cpu": 0.0, "memoryBytes": memory_bytes() },
  });
  let mut request = client
    .post(format!("{agent_url}/internal/computer/workers/heartbeat"))
    .json(&body);
  if let Some(token) = &config.token {
    request = request.bearer_auth(token);
  }
  let response = request.send().await?;
  if !response.status().is_success() {
    anyhow::bail!("heartbeat returned HTTP {}", response.status());
  }
  Ok(())
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
