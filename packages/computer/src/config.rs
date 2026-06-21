//! Worker configuration, derived entirely from the container environment.
//! The daemon never invents its own stable identity — `BULLX_COMPUTER_WORKER_ID`
//! is required and comes from the deployment (StatefulSet pod name in K8s).

use std::path::{Path, PathBuf};

use anyhow::{Context, Result};

use crate::tls_config::{ComputerTlsMaterial, load_computer_tls_material};

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
  pub tls: ComputerTlsMaterial,
  pub computer_token: String,
  /// Shared PostgreSQL database used by the Bun app and DB-backed library-containers.
  pub database_url: String,
  pub workspace_root: PathBuf,
  pub user_files_root: PathBuf,
  pub temp_root: PathBuf,
  pub library_containers_root: PathBuf,
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
  pub ready_file: PathBuf,
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
  /// Builds the worker configuration from process environment and sealed app
  /// state.
  ///
  /// The worker intentionally fails fast on identity, database, token, and TLS
  /// inputs. Those values define the trust boundary with the BullX app, so a
  /// guessed fallback would make deployment mistakes look like runtime bugs.
  pub async fn from_env(port: u16) -> Result<Self> {
    load_dev_env_files();
    let worker_id = env_opt("BULLX_COMPUTER_WORKER_ID")
      .context("BULLX_COMPUTER_WORKER_ID is required (K8s: fieldRef metadata.name)")?;
    let database_url = env_opt("DATABASE_URL")
      .context("DATABASE_URL is required for DB-backed library-containers")?;
    let instance_id = env_opt("BULLX_COMPUTER_INSTANCE_ID").unwrap_or_else(|| worker_id.clone());
    let base_url =
      env_opt("BULLX_COMPUTER_BASE_URL").unwrap_or_else(|| format!("https://localhost:{port}"));
    let computer_token =
      env_opt("BULLX_COMPUTER_TOKEN").context("BULLX_COMPUTER_TOKEN is required")?;
    let tls = load_computer_tls_material(&database_url, &computer_token).await?;

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
          "python".to_string(),
          "jupyter".to_string(),
          "bun".to_string(),
          "browser".to_string(),
        ]
      });

    let workspace_root = PathBuf::from(env_or("BULLX_COMPUTER_WORKSPACE_ROOT", "/workspaces"));
    let user_files_root = env_opt("BULLX_COMPUTER_USER_FILES_ROOT")
      .map(PathBuf::from)
      .unwrap_or_else(|| workspace_root.clone());
    let temp_root = env_opt("BULLX_COMPUTER_TEMP_ROOT")
      .map(PathBuf::from)
      .unwrap_or_else(|| workspace_root.clone());
    let library_containers_root = env_opt("BULLX_COMPUTER_LIBRARY_CONTAINERS_ROOT")
      .map(PathBuf::from)
      .unwrap_or_else(|| workspace_root.clone());

    Ok(Self {
      worker_id,
      instance_id,
      base_url,
      tls,
      computer_token,
      database_url,
      workspace_root,
      user_files_root,
      temp_root,
      library_containers_root,
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
      ready_file: env_opt("BULLX_COMPUTER_READY_FILE")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("/tmp/bullx-computerd.ready")),
    })
  }
}

/// Loads local `.env*` files only for developer runs.
///
/// Bun loads env files for the app, but the Rust worker can be started directly
/// during smoke tests. This small loader keeps that path ergonomic while
/// avoiding production surprises: it stops when `DATABASE_URL` is already set
/// and is disabled under `NODE_ENV=production`.
fn load_dev_env_files() {
  if env_opt("NODE_ENV").as_deref() == Some("production") || env_opt("DATABASE_URL").is_some() {
    return;
  }
  for path in [
    ".env.local",
    ".env.development",
    ".env",
    "packages/computer/.env.local",
    "packages/computer/.env.development",
    "packages/computer/.env",
    "app/.env.local",
    "app/.env.development",
    "../app/.env.local",
    "../app/.env.development",
    "../../app/.env.local",
    "../../app/.env.development",
  ] {
    load_dev_env_file(Path::new(path));
    if env_opt("DATABASE_URL").is_some() {
      return;
    }
  }
}

/// Applies one simple dotenv-style file without overriding real environment.
///
/// This is intentionally not a full dotenv parser. The worker only needs the
/// local repo files used by BullX dev scripts, and a small parser keeps startup
/// dependency-free.
fn load_dev_env_file(path: &Path) {
  let Ok(content) = std::fs::read_to_string(path) else {
    return;
  };
  for line in content.lines() {
    let trimmed = line.trim();
    if trimmed.is_empty() || trimmed.starts_with('#') {
      continue;
    }
    let Some((name, value)) = trimmed.split_once('=') else {
      continue;
    };
    let name = name.trim();
    if name.is_empty() || std::env::var_os(name).is_some() {
      continue;
    }
    let value = value.trim().trim_matches('"').trim_matches('\'');
    // Rust 2024 makes environment mutation unsafe because it is process-global.
    // This runs during single-threaded startup before Tokio starts worker tasks.
    unsafe {
      std::env::set_var(name, value);
    }
  }
}
