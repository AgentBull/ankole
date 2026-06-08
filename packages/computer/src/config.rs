//! Worker configuration, derived entirely from the container environment.
//! The daemon never invents its own stable identity — `BULLX_COMPUTER_WORKER_ID`
//! is required and comes from the deployment (StatefulSet pod name in K8s).

use std::path::PathBuf;

use anyhow::{Context, Result};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum IsolationMode {
  /// bubblewrap FS/PID-view isolation (Linux, production).
  Bwrap,
  /// No isolation — run directly on the host (dev/macOS fallback).
  Direct,
}

#[derive(Clone, Debug)]
pub struct Config {
  pub worker_id: String,
  pub instance_id: String,
  pub base_url: String,
  /// Control-plane base URL (`BULLX_AGENT_URL`) for register/heartbeat. None disables them.
  pub agent_url: Option<String>,
  /// Shared secret: control-plane bearer + HMAC key for session-token verification.
  pub token: Option<String>,
  pub workspace_root: PathBuf,
  pub port: u16,
  pub version: String,
  pub features: Vec<String>,
  pub max_agents: usize,
  pub max_commands: usize,
  pub isolation: IsolationMode,
  pub pod_name: Option<String>,
  pub namespace: Option<String>,
  pub node_name: Option<String>,
  pub heartbeat_secs: u64,
}

fn env_opt(key: &str) -> Option<String> {
  std::env::var(key)
    .ok()
    .filter(|value| !value.trim().is_empty())
}

fn env_or(key: &str, default: &str) -> String {
  env_opt(key).unwrap_or_else(|| default.to_string())
}

impl Config {
  pub fn from_env(port: u16) -> Result<Self> {
    let worker_id = env_opt("BULLX_COMPUTER_WORKER_ID")
      .context("BULLX_COMPUTER_WORKER_ID is required (K8s: fieldRef metadata.name)")?;
    let instance_id = env_opt("BULLX_COMPUTER_INSTANCE_ID").unwrap_or_else(|| worker_id.clone());
    let base_url =
      env_opt("BULLX_COMPUTER_BASE_URL").unwrap_or_else(|| format!("http://localhost:{port}"));

    let isolation = match env_opt("BULLX_COMPUTER_ISOLATION").as_deref() {
      Some("bwrap") => IsolationMode::Bwrap,
      Some("none") | Some("direct") => IsolationMode::Direct,
      _ if cfg!(target_os = "linux") => IsolationMode::Bwrap,
      _ => IsolationMode::Direct,
    };

    let features = env_opt("BULLX_COMPUTER_FEATURES")
      .map(|raw| {
        raw
          .split(',')
          .map(|f| f.trim().to_string())
          .filter(|f| !f.is_empty())
          .collect()
      })
      .unwrap_or_else(|| {
        vec![
          "bwrap".to_string(),
          "persistent-shell".to_string(),
          "tmux".to_string(),
          "tigerfs".to_string(),
        ]
      });

    Ok(Self {
      worker_id,
      instance_id,
      base_url,
      agent_url: env_opt("BULLX_AGENT_URL"),
      token: env_opt("BULLX_COMPUTER_TOKEN"),
      workspace_root: PathBuf::from(env_or("BULLX_COMPUTER_WORKSPACE_ROOT", "/workspaces")),
      port,
      version: env!("CARGO_PKG_VERSION").to_string(),
      features,
      max_agents: env_or("BULLX_COMPUTER_MAX_AGENTS", "128")
        .parse()
        .unwrap_or(128),
      max_commands: env_or("BULLX_COMPUTER_MAX_COMMANDS", "32")
        .parse()
        .unwrap_or(32),
      isolation,
      pod_name: env_opt("BULLX_COMPUTER_POD_NAME"),
      namespace: env_opt("BULLX_COMPUTER_POD_NAMESPACE"),
      node_name: env_opt("BULLX_COMPUTER_NODE_NAME"),
      heartbeat_secs: env_or("BULLX_COMPUTER_HEARTBEAT_SECS", "10")
        .parse()
        .unwrap_or(10),
    })
  }
}
