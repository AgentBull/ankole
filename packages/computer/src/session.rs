//! Session manager: one sticky session per `agent_uid`, holding the persistent
//! shell and the command registry, backed by the agent's workspace directories.

use std::collections::{BTreeMap, HashMap};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use chrono::{DateTime, Utc};
use dashmap::DashMap;
use dashmap::mapref::entry::Entry;
use tokio::sync::Mutex as AsyncMutex;
use uuid::Uuid;

use crate::command::{CommandHandle, CommandRegistry};
use crate::config::{Config, IsolationMode};
use crate::error::{AppError, AppResult};
use crate::isolation::Launcher;
use crate::paths::{WORKSPACE_MOUNT, WorkspacePaths};
use crate::shell::{PersistentShell, ShellResult};
use crate::tigerfs::TigerFs;
use crate::tmux::TmuxManager;

pub struct SessionHandle {
  pub agent_uid: String,
  pub session_id: Uuid,
  pub paths: WorkspacePaths,
  pub commands: CommandRegistry,
  pub terminals: TmuxManager,
  pub created_at: DateTime<Utc>,
  last_used_at: Mutex<DateTime<Utc>>,
  /// Persistent shells keyed by execution scope (conversation); "" is the agent-shared default scope.
  shells: AsyncMutex<HashMap<String, Arc<AsyncMutex<PersistentShell>>>>,
  launcher: Launcher,
}

impl SessionHandle {
  pub fn last_used_at(&self) -> DateTime<Utc> {
    *self.last_used_at.lock().unwrap()
  }

  pub fn touch(&self) {
    *self.last_used_at.lock().unwrap() = Utc::now();
  }

  /// Run a command in the scope's persistent shell. cwd/env are applied as
  /// `cd`/`export` prefixes so they persist for subsequent calls in that scope.
  /// Scopes (one per conversation) get independent shells so concurrent
  /// conversations of the same agent cannot leak cwd/env into each other.
  pub async fn shell_run(
    &self,
    scope: &str,
    command: &str,
    cwd: Option<&str>,
    env: &BTreeMap<String, String>,
    timeout: Duration,
  ) -> AppResult<ShellResult> {
    let shell_arc = {
      let mut shells = self.shells.lock().await;
      match shells.get(scope) {
        Some(existing) => Arc::clone(existing),
        None => {
          let shell = PersistentShell::start(self.launcher.shell_command(&self.paths)).await?;
          let arc = Arc::new(AsyncMutex::new(shell));
          shells.insert(scope.to_string(), Arc::clone(&arc));
          arc
        }
      }
    };
    let mut guard = shell_arc.lock().await;
    // In bwrap, `/workspace` is real inside the namespace; in direct mode it isn't,
    // so translate the cwd option to its host path for the `cd` prefix.
    let cd_target = match (cwd.filter(|value| !value.is_empty()), self.launcher.mode()) {
      (Some(dir), IsolationMode::Direct) => self
        .paths
        .resolve(None, dir)
        .ok()
        .map(|path| path.to_string_lossy().into_owned()),
      (Some(dir), IsolationMode::Bwrap) => Some(dir.to_string()),
      (None, _) => None,
    };
    let effective = build_shell_command(cd_target.as_deref(), command, env);
    let result = guard.run(&effective, timeout).await;
    let drop_shell = match &result {
      // The command may still have been running when the protocol marker timed
      // out. The shell was killed by PersistentShell::run; drop the handle so
      // the next call starts with a synchronized bash.
      Ok(result) => result.timed_out,
      // The shell died — drop it so the next call restarts a fresh one.
      Err(_) => true,
    };
    if drop_shell {
      drop(guard);
      self.shells.lock().await.remove(scope);
    }
    result
  }

  /// Shut down every scope's persistent shell.
  pub async fn reset_shell(&self) -> AppResult<()> {
    let shells: Vec<_> = {
      let mut guard = self.shells.lock().await;
      guard.drain().map(|(_, shell)| shell).collect()
    };
    for shell_arc in shells {
      let shell = AsyncMutex::into_inner(match Arc::try_unwrap(shell_arc) {
        Ok(mutex) => mutex,
        Err(_busy) => continue,
      });
      shell.shutdown().await;
    }
    Ok(())
  }

  pub fn spawn_command(
    &self,
    program: &str,
    args: &[String],
    cwd: Option<&str>,
    env: &BTreeMap<String, String>,
    detached: bool,
  ) -> AppResult<Arc<CommandHandle>> {
    let command = self
      .launcher
      .exec_command(&self.paths, program, args, cwd, env);
    let resolved_cwd = cwd
      .map(|value| value.to_string())
      .or_else(|| Some(WORKSPACE_MOUNT.to_string()));
    self.commands.spawn(command, resolved_cwd, detached)
  }

  async fn teardown(&self) {
    self.commands.kill_all();
    let _ = self.reset_shell().await;
    self.terminals.shutdown().await;
  }
}

fn build_shell_command(
  cd_target: Option<&str>,
  command: &str,
  env: &BTreeMap<String, String>,
) -> String {
  let mut prefix = String::new();
  if let Some(dir) = cd_target {
    prefix.push_str(&format!("cd {} || true; ", shell_quote(dir)));
  }
  for (key, value) in env {
    prefix.push_str(&format!("export {key}={}; ", shell_quote(value)));
  }
  format!("{prefix}{command}")
}

fn shell_quote(value: &str) -> String {
  format!("'{}'", value.replace('\'', "'\\''"))
}

pub struct SessionManager {
  sessions: DashMap<String, Arc<SessionHandle>>,
  config: Arc<Config>,
  launcher: Launcher,
  tigerfs: Arc<TigerFs>,
}

impl SessionManager {
  pub fn new(config: Arc<Config>, launcher: Launcher, tigerfs: Arc<TigerFs>) -> Self {
    Self {
      sessions: DashMap::new(),
      config,
      launcher,
      tigerfs,
    }
  }

  pub fn get(&self, agent_uid: &str) -> Option<Arc<SessionHandle>> {
    self.sessions.get(agent_uid).map(|handle| handle.clone())
  }

  pub fn count(&self) -> usize {
    self.sessions.len()
  }

  pub fn running_commands(&self) -> usize {
    self
      .sessions
      .iter()
      .map(|session| session.commands.running())
      .sum()
  }

  pub async fn get_or_create(&self, agent_uid: &str) -> AppResult<(Arc<SessionHandle>, bool)> {
    if let Some(handle) = self.get(agent_uid) {
      handle.touch();
      return Ok((handle, false));
    }
    if self.sessions.len() >= self.config.max_agents {
      return Err(AppError::unavailable(
        "at_capacity",
        "worker is at its agent capacity",
      ));
    }

    let paths = WorkspacePaths::with_roots(
      &self.config.workspace_root,
      &self.config.user_files_root,
      &self.config.temp_root,
      &self.config.library_containers_root,
      agent_uid,
    );
    tokio::fs::create_dir_all(&paths.root).await?;
    tokio::fs::create_dir_all(&paths.user_files).await?;
    tokio::fs::create_dir_all(&paths.temp).await?;
    self
      .tigerfs
      .ensure_mounted(&paths.library_containers, agent_uid)
      .await?;
    ensure_workspace_view(&paths).await?;
    let terminals = TmuxManager::new(paths.clone(), self.launcher);

    let handle = Arc::new(SessionHandle {
      agent_uid: agent_uid.to_string(),
      session_id: Uuid::new_v4(),
      paths,
      commands: CommandRegistry::new(),
      terminals,
      created_at: Utc::now(),
      last_used_at: Mutex::new(Utc::now()),
      shells: AsyncMutex::new(HashMap::new()),
      launcher: self.launcher,
    });

    match self.sessions.entry(agent_uid.to_string()) {
      Entry::Occupied(existing) => Ok((existing.get().clone(), false)),
      Entry::Vacant(slot) => {
        slot.insert(handle.clone());
        tracing::info!(%agent_uid, "session created");
        Ok((handle, true))
      }
    }
  }

  pub async fn stop(&self, agent_uid: &str) -> Option<Arc<SessionHandle>> {
    let removed = self.sessions.remove(agent_uid).map(|(_, handle)| handle);
    if let Some(handle) = &removed {
      handle.teardown().await;
      tracing::info!(%agent_uid, "session stopped");
    }
    removed
  }

  pub async fn sync_library_containers(&self, agent_uid: &str) -> AppResult<()> {
    let Some(handle) = self.get(agent_uid) else {
      return Ok(());
    };
    self
      .tigerfs
      .sync_from_mount(&handle.paths.library_containers, agent_uid)
      .await
  }

  pub async fn shutdown_all(&self) {
    let agents: Vec<String> = self
      .sessions
      .iter()
      .map(|session| session.agent_uid.clone())
      .collect();
    for agent in agents {
      self.stop(&agent).await;
    }
  }
}

async fn ensure_workspace_view(paths: &WorkspacePaths) -> AppResult<()> {
  ensure_workspace_entry(&paths.root.join("user-files"), &paths.user_files).await?;
  ensure_workspace_entry(&paths.root.join("temp"), &paths.temp).await?;
  ensure_workspace_entry(
    &paths.root.join("library-containers"),
    &paths.library_containers,
  )
  .await?;
  Ok(())
}

async fn ensure_workspace_entry(
  link_path: &std::path::Path,
  target: &std::path::Path,
) -> AppResult<()> {
  if link_path == target {
    return Ok(());
  }

  if let Ok(metadata) = tokio::fs::symlink_metadata(link_path).await {
    if metadata.file_type().is_symlink() {
      if tokio::fs::read_link(link_path).await? == target {
        return Ok(());
      }
      tokio::fs::remove_file(link_path).await?;
    } else if metadata.is_dir() {
      let mut entries = tokio::fs::read_dir(link_path).await?;
      if entries.next_entry().await?.is_some() {
        return Err(AppError::internal(
          "workspace_entry_conflict",
          format!(
            "workspace entry is a non-empty directory: {}",
            link_path.display()
          ),
        ));
      }
      tokio::fs::remove_dir(link_path).await?;
    } else {
      tokio::fs::remove_file(link_path).await?;
    }
  }

  #[cfg(unix)]
  {
    std::os::unix::fs::symlink(target, link_path)?;
    Ok(())
  }

  #[cfg(not(unix))]
  {
    tokio::fs::create_dir_all(link_path).await?;
    Ok(())
  }
}
