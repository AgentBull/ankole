//! Session manager: one sticky session per `agent_uid`, holding the persistent
//! shell and the command registry, backed by the agent's workspace directories.

use std::collections::BTreeMap;
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
  shell: AsyncMutex<Option<PersistentShell>>,
  launcher: Launcher,
}

impl SessionHandle {
  pub fn last_used_at(&self) -> DateTime<Utc> {
    *self.last_used_at.lock().unwrap()
  }

  pub fn touch(&self) {
    *self.last_used_at.lock().unwrap() = Utc::now();
  }

  /// Run a command in the persistent shell. cwd/env are applied as `cd`/`export`
  /// prefixes so they persist for subsequent calls.
  pub async fn shell_run(
    &self,
    command: &str,
    cwd: Option<&str>,
    env: &BTreeMap<String, String>,
    timeout: Duration,
  ) -> AppResult<ShellResult> {
    let mut guard = self.shell.lock().await;
    if guard.is_none() {
      let shell = PersistentShell::start(self.launcher.shell_command(&self.paths)).await?;
      *guard = Some(shell);
    }
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
    let shell = guard.as_mut().expect("shell just initialized");
    let result = shell.run(&effective, timeout).await;
    match result {
      Ok(result) => {
        if result.timed_out {
          // The command may still have been running when the protocol marker timed
          // out. The shell was killed by PersistentShell::run; drop the handle so
          // the next call starts with a synchronized bash.
          *guard = None;
        }
        Ok(result)
      }
      Err(error) => {
        // The shell died — drop it so the next call restarts a fresh one.
        *guard = None;
        Err(error)
      }
    }
  }

  pub async fn reset_shell(&self) -> AppResult<()> {
    let mut guard = self.shell.lock().await;
    if let Some(shell) = guard.take() {
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
    let mut guard = self.shell.lock().await;
    if let Some(shell) = guard.take() {
      shell.shutdown().await;
    }
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

    let paths = WorkspacePaths::new(&self.config.workspace_root, agent_uid);
    tokio::fs::create_dir_all(&paths.user_files).await?;
    tokio::fs::create_dir_all(&paths.temp).await?;
    self
      .tigerfs
      .ensure_mounted(&paths.library_containers, agent_uid)
      .await?;
    let terminals = TmuxManager::new(paths.clone(), self.launcher);

    let handle = Arc::new(SessionHandle {
      agent_uid: agent_uid.to_string(),
      session_id: Uuid::new_v4(),
      paths,
      commands: CommandRegistry::new(),
      terminals,
      created_at: Utc::now(),
      last_used_at: Mutex::new(Utc::now()),
      shell: AsyncMutex::new(None),
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
