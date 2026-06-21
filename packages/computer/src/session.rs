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

/// Everything one agent owns on this worker: its workspace paths, tracked
/// commands, tmux terminals, and the per-scope persistent shells. One of these is
/// created on first access and lives until the session is explicitly stopped or
/// the daemon shuts down — this is the "sticky session per agent_uid" the README
/// describes.
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

  /// Stamps the session as just-used. Currently this only feeds the value the
  /// session-describe endpoint returns; there is no in-daemon idle evictor yet,
  /// so nothing here reaps a session on staleness.
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

  /// Shut down every scope's persistent shell, dropping all cwd/env/alias state.
  ///
  /// The map is drained first so new calls immediately start fresh shells while
  /// the old ones are torn down. A shell still held by an in-flight `shell_run`
  /// (Arc not uniquely owned) is skipped rather than waited on: it will run its
  /// command to completion and be dropped normally, so reset never blocks on a
  /// busy command.
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

  /// Spawn a one-shot process (not the persistent shell) in this session's
  /// computer. Unlike `shell_run`, each call is an independent process and carries
  /// no cwd/env state forward; the recorded cwd defaults to `/workspace` only for
  /// the snapshot shown to callers.
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

  /// Tear the session down: kill tracked processes, stop every shell, then kill
  /// the tmux keeper. Ordered so processes die before the shells and terminals
  /// that may have parented them.
  async fn teardown(&self) {
    self.commands.kill_all();
    let _ = self.reset_shell().await;
    self.terminals.shutdown().await;
  }
}

/// Prefix the user command with `cd` + `export` lines so per-call cwd/env take
/// effect inside the persistent shell and persist for later calls in the scope.
///
/// `cd ... || true` deliberately does not abort the command on a bad directory —
/// the command itself then runs from the previous cwd and reports its own error,
/// which is friendlier than swallowing the request. Values are single-quoted so a
/// path or env value with spaces or shell metacharacters cannot break out.
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

/// Wrap a value in single quotes for safe inclusion in a bash command, using the
/// standard `'\''` trick to embed a literal single quote.
fn shell_quote(value: &str) -> String {
  format!("'{}'", value.replace('\'', "'\\''"))
}

/// Owns every live session on this worker, keyed by `agent_uid`, and enforces the
/// agent-capacity limit. The single source of truth for "which agents are active
/// here"; the heartbeat reads its counts for load reporting.
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

  /// Return the agent's session, creating and provisioning it on first access.
  ///
  /// The bool is true only when this call created the session. Creation does the
  /// expensive one-time setup — making the workspace dirs, mounting TigerFS, and
  /// laying down the `/workspace` symlink view — outside the map lock so two
  /// concurrent first-access requests do not serialize on it. The final
  /// `entry()` then resolves the race: if a rival inserted first, the freshly
  /// built handle is dropped and the existing one wins, so an agent never ends up
  /// with two sessions.
  pub async fn get_or_create(&self, agent_uid: &str) -> AppResult<(Arc<SessionHandle>, bool)> {
    if let Some(handle) = self.get(agent_uid) {
      handle.touch();
      return Ok((handle, false));
    }
    // Capacity is checked before the costly provisioning below. This is a soft
    // pre-check, not a reservation, so a burst of new agents can briefly overrun
    // the limit; the worker's load reporting plus app-side placement keep this in
    // check rather than a hard lock here.
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

  /// Remove and fully tear down an agent's session. Removed from the map first so
  /// no new request can grab it mid-teardown; returns the handle (or `None` if
  /// there was no session) for the caller to report on.
  pub async fn stop(&self, agent_uid: &str) -> Option<Arc<SessionHandle>> {
    let removed = self.sessions.remove(agent_uid).map(|(_, handle)| handle);
    if let Some(handle) = &removed {
      handle.teardown().await;
      tracing::info!(%agent_uid, "session stopped");
    }
    removed
  }

  /// Flush the agent's `library-containers` mount back to its PostgreSQL backing
  /// store. Called after commands/shell runs so edits to skills/memory/settings
  /// are durable. A missing session is a no-op: nothing ran, so there is nothing
  /// to persist.
  pub async fn sync_library_containers(&self, agent_uid: &str) -> AppResult<()> {
    let Some(handle) = self.get(agent_uid) else {
      return Ok(());
    };
    self
      .tigerfs
      .sync_from_mount(&handle.paths.library_containers, agent_uid)
      .await
  }

  /// Stop every session. Used on daemon shutdown after the server has drained.
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

/// Build the unified `/workspace/<agent>` view by symlinking the three backing
/// roots into it. The backing roots can live on separate storage (PVC, tmpfs, DB
/// projection), but the computer always sees one stable tree — this is what keeps
/// the public `/workspace` shape constant while deployments vary the storage.
async fn ensure_workspace_view(paths: &WorkspacePaths) -> AppResult<()> {
  ensure_workspace_entry(&paths.root.join("user-files"), &paths.user_files).await?;
  ensure_workspace_entry(&paths.root.join("temp"), &paths.temp).await?;
  ensure_workspace_entry(
    &paths.root.join("library-containers"),
    &paths.library_containers,
  )
  .await?;
  ensure_codex_agent_skills_mount(paths).await?;
  Ok(())
}

/// Expose `library-containers/skills` at `temp/.agents/skills` as well.
///
/// Codex-style agents look for skills under `$HOME/.agents/skills` (HOME is the
/// temp dir), so this links the canonical skills directory there instead of
/// duplicating its contents.
async fn ensure_codex_agent_skills_mount(paths: &WorkspacePaths) -> AppResult<()> {
  let agents_dir = paths.temp.join(".agents");
  let library_skills = paths.library_containers.join("skills");
  let agent_skills = agents_dir.join("skills");

  tokio::fs::create_dir_all(&agents_dir).await?;
  ensure_workspace_entry(&agent_skills, &library_skills).await
}

/// Idempotently make `link_path` a symlink to `target`, reconciling whatever is
/// already there.
///
/// Runs on every session creation, so it must converge from any prior state: a
/// correct symlink is left alone; a symlink to the wrong place, a stray file, or
/// an empty directory is removed and recreated. A *non-empty* directory is the
/// one case it refuses — that holds real data (likely a misconfigured backing
/// root), and silently deleting it would lose the agent's files, so it errors
/// out instead. When the backing root equals the view (single-root dev layout)
/// the link would point at itself, so that case is skipped up front.
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

  // Non-unix has no symlinks here; fall back to a plain directory so the path at
  // least exists. The split-root layout is a Linux/production concern anyway.
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
