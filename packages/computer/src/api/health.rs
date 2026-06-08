//! Liveness / readiness / worker-info endpoints.

use axum::Json;
use axum::extract::State;
use serde_json::{Value, json};

use crate::config::IsolationMode;
use crate::state::AppState;

pub async fn healthz() -> Json<Value> {
  Json(json!({ "status": "ok" }))
}

pub async fn readyz(State(state): State<AppState>) -> Json<Value> {
  let tigerfs_ok = state.tigerfs.healthy().await;
  Json(json!({
    "status": if tigerfs_ok { "ready" } else { "degraded" },
    "tigerfs": tigerfs_ok,
    "uptimeSeconds": (chrono::Utc::now() - state.started_at).num_seconds(),
  }))
}

pub async fn worker_info(State(state): State<AppState>) -> Json<Value> {
  let config = &state.config;
  Json(json!({
    "workerId": config.worker_id,
    "instanceId": config.instance_id,
    "version": config.version,
    "features": config.features,
    "capacity": { "maxAgents": config.max_agents, "maxCommands": config.max_commands },
    "status": "ready",
    "isolation": match config.isolation { IsolationMode::Bwrap => "bwrap", IsolationMode::Direct => "direct" },
    "runningSessions": state.sessions.count(),
    "runningCommands": state.sessions.running_commands(),
  }))
}
