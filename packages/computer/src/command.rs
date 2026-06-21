//! One-shot process commands + their tracked output buffers.
//!
//! Each command (whether a real spawned process or a captured shell result) gets a
//! `CommandHandle` in the session's registry. Output is appended to an
//! `OutputBuffer` that supports replay + live follow (`tail -f` semantics) and
//! records the terminal status + exit code.

use std::process::ExitStatus;
use std::sync::{Arc, Mutex};

use bytes::Bytes;
use chrono::{DateTime, Utc};
use dashmap::DashMap;
use futures::Stream;
use serde::Serialize;
use tokio::io::AsyncReadExt;
use tokio::process::Command as TokioCommand;
use tokio::sync::Notify;
use uuid::Uuid;

use crate::error::{AppError, AppResult};

/// Per-command output cap; output beyond this is dropped (marked truncated).
/// A hard ceiling so one chatty command cannot grow the in-memory buffer without
/// bound. The whole buffer lives in RAM, so this is a memory-safety limit, not a
/// display nicety.
const MAX_OUTPUT_BYTES: usize = 8 * 1024 * 1024;

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum CommandStatus {
  Running,
  Finished,
  /// Set on the timeout path; the kill flow otherwise reports the process exit.
  #[allow(dead_code)]
  Killed,
  Error,
}

impl CommandStatus {
  pub fn as_str(self) -> &'static str {
    match self {
      CommandStatus::Running => "running",
      CommandStatus::Finished => "finished",
      CommandStatus::Killed => "killed",
      CommandStatus::Error => "error",
    }
  }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum LogStream {
  Stdout,
  Stderr,
}

impl LogStream {
  pub fn as_str(self) -> &'static str {
    match self {
      LogStream::Stdout => "stdout",
      LogStream::Stderr => "stderr",
    }
  }
}

#[derive(Clone)]
pub struct LogEvent {
  pub stream: LogStream,
  pub data: Bytes,
}

#[derive(Clone, Copy)]
struct Done {
  status: CommandStatus,
  exit_code: Option<i32>,
}

struct BufferInner {
  events: Vec<LogEvent>,
  done: Option<Done>,
  bytes: usize,
  truncated: bool,
}

/// Append-only record of a command's output plus its terminal status.
///
/// Events are retained (not consumed) so a late or reconnecting reader can replay
/// from the start and then follow live output — the `tail -f`-like contract the
/// logs endpoint exposes. `notify` wakes followers when new output lands or the
/// command finishes, avoiding a polling loop.
pub struct OutputBuffer {
  inner: Mutex<BufferInner>,
  notify: Notify,
}

impl OutputBuffer {
  fn new() -> Arc<Self> {
    Arc::new(Self {
      inner: Mutex::new(BufferInner {
        events: Vec::new(),
        done: None,
        bytes: 0,
        truncated: false,
      }),
      notify: Notify::new(),
    })
  }

  /// Appends one chunk of output and wakes any followers.
  ///
  /// Once the cap is reached the chunk is discarded and the buffer is flagged
  /// truncated; the command keeps running and finishing normally, it just stops
  /// recording. Dropping new output (rather than evicting old) keeps the head of
  /// the log — usually the most diagnostic part — intact.
  fn push(&self, stream: LogStream, data: Bytes) {
    {
      let mut guard = self.inner.lock().unwrap();
      if guard.bytes >= MAX_OUTPUT_BYTES {
        guard.truncated = true;
        return;
      }
      guard.bytes += data.len();
      guard.events.push(LogEvent { stream, data });
    }
    self.notify.notify_waiters();
  }

  /// Records the terminal status once and wakes followers so they can stop.
  ///
  /// First writer wins: the `is_none()` guard makes this idempotent, so a kill
  /// racing with the natural process-exit reporter cannot overwrite an already
  /// recorded result.
  fn finish(&self, status: CommandStatus, exit_code: Option<i32>) {
    {
      let mut guard = self.inner.lock().unwrap();
      if guard.done.is_none() {
        guard.done = Some(Done { status, exit_code });
      }
    }
    self.notify.notify_waiters();
  }

  pub fn status(&self) -> (CommandStatus, Option<i32>) {
    let guard = self.inner.lock().unwrap();
    match guard.done {
      Some(done) => (done.status, done.exit_code),
      None => (CommandStatus::Running, None),
    }
  }

  #[allow(dead_code)]
  pub fn is_truncated(&self) -> bool {
    self.inner.lock().unwrap().truncated
  }

  /// Current buffered events without waiting for completion (non-following logs).
  pub fn snapshot_events(&self) -> Vec<LogEvent> {
    self.inner.lock().unwrap().events.clone()
  }

  /// Awaits the command's terminal status, returning immediately if already done.
  ///
  /// The `notified()` future is created before the flag is checked on purpose: it
  /// registers interest first, so a `finish` that fires in the gap between the
  /// check and the await is not lost (the classic notify-after-check race).
  pub async fn wait_done(&self) -> (CommandStatus, Option<i32>) {
    loop {
      let notified = self.notify.notified();
      if let Some(done) = self.inner.lock().unwrap().done {
        return (done.status, done.exit_code);
      }
      notified.await;
    }
  }
}

#[derive(Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct CommandSnapshot {
  pub id: String,
  pub status: CommandStatus,
  pub detached: bool,
  #[serde(skip_serializing_if = "Option::is_none")]
  pub cwd: Option<String>,
  #[serde(skip_serializing_if = "Option::is_none")]
  pub exit_code: Option<i32>,
  #[serde(skip_serializing_if = "Option::is_none")]
  pub pid: Option<u32>,
}

pub struct CommandHandle {
  pub id: String,
  pub cwd: Option<String>,
  pub detached: bool,
  pub pid: Option<u32>,
  pub output: Arc<OutputBuffer>,
  #[allow(dead_code)]
  pub created_at: DateTime<Utc>,
}

impl CommandHandle {
  pub fn snapshot(&self) -> CommandSnapshot {
    let (status, exit_code) = self.output.status();
    CommandSnapshot {
      id: self.id.clone(),
      status,
      detached: self.detached,
      cwd: self.cwd.clone(),
      exit_code,
      pid: self.pid,
    }
  }
}

/// Per-session table of every command ever started, keyed by command id.
///
/// Handles are kept after the process exits so callers can still fetch the final
/// status and replay logs; the table is bounded by session lifetime, not pruned
/// per command.
pub struct CommandRegistry {
  commands: DashMap<String, Arc<CommandHandle>>,
}

impl CommandRegistry {
  pub fn new() -> Self {
    Self {
      commands: DashMap::new(),
    }
  }

  pub fn get(&self, id: &str) -> Option<Arc<CommandHandle>> {
    self.commands.get(id).map(|handle| handle.clone())
  }

  pub fn list(&self) -> Vec<CommandSnapshot> {
    let mut snapshots: Vec<CommandSnapshot> = self
      .commands
      .iter()
      .map(|handle| handle.snapshot())
      .collect();
    snapshots.sort_by(|a, b| a.id.cmp(&b.id));
    snapshots
  }

  pub fn running(&self) -> usize {
    self
      .commands
      .iter()
      .filter(|handle| matches!(handle.output.status().0, CommandStatus::Running))
      .count()
  }

  /// Spawn a one-shot process and track its output until it exits.
  ///
  /// Returns as soon as the child is launched; output collection and exit
  /// reporting happen on detached tasks (one reader per stdout/stderr pipe, plus
  /// a waiter that records the exit code). Doing the wait off-thread is what lets
  /// a caller stream live logs while the process is still running, and lets a
  /// `detached` command outlive the request that started it.
  pub fn spawn(
    &self,
    mut command: TokioCommand,
    cwd: Option<String>,
    detached: bool,
  ) -> AppResult<Arc<CommandHandle>> {
    let mut child = command.spawn().map_err(|error| {
      AppError::bad_request("spawn_failed", format!("failed to spawn command: {error}"))
    })?;
    let id = format!("cmd_{}", Uuid::new_v4().simple());
    let pid = child.id();
    let output = OutputBuffer::new();
    let handle = Arc::new(CommandHandle {
      id: id.clone(),
      cwd,
      detached,
      pid,
      output: output.clone(),
      created_at: Utc::now(),
    });
    self.commands.insert(id, handle.clone());

    if let Some(stdout) = child.stdout.take() {
      spawn_reader(stdout, LogStream::Stdout, output.clone());
    }
    if let Some(stderr) = child.stderr.take() {
      spawn_reader(stderr, LogStream::Stderr, output.clone());
    }

    tokio::spawn(async move {
      match child.wait().await {
        Ok(status) => {
          let (command_status, exit_code) = classify_exit_status(status);
          output.finish(command_status, exit_code);
        }
        Err(_) => output.finish(CommandStatus::Error, None),
      }
    });
    Ok(handle)
  }

  /// Register an already-finished result (used by the persistent shell).
  ///
  /// The persistent shell runs its command synchronously and hands back a
  /// complete `ShellResult`, but the HTTP/SDK surface speaks in command ids and
  /// handles. Wrapping the result as a pre-finished command keeps that one shape,
  /// so a shell command and a spawned process look the same to callers (`list`,
  /// `get`, `logs`).
  pub fn insert_finished(
    &self,
    output: String,
    exit_code: i32,
    cwd: Option<String>,
  ) -> Arc<CommandHandle> {
    let id = format!("cmd_{}", Uuid::new_v4().simple());
    let buffer = OutputBuffer::new();
    if !output.is_empty() {
      buffer.push(LogStream::Stdout, Bytes::from(output.into_bytes()));
    }
    buffer.finish(CommandStatus::Finished, Some(exit_code));
    let handle = Arc::new(CommandHandle {
      id: id.clone(),
      cwd,
      detached: false,
      pid: None,
      output: buffer,
      created_at: Utc::now(),
    });
    self.commands.insert(id, handle.clone());
    handle
  }

  /// Signal a running command. A no-such-command is an error, but signalling a
  /// command that has already exited (or has no pid) is treated as success — the
  /// caller's goal, "this command is not running", is already true, so kill is
  /// idempotent and races between exit and kill stay quiet.
  pub fn kill(&self, id: &str, signal: Option<&str>) -> AppResult<()> {
    let handle = self
      .get(id)
      .ok_or_else(|| AppError::not_found("command_not_found", "no such command"))?;
    if !matches!(handle.output.status().0, CommandStatus::Running) {
      return Ok(());
    }
    let Some(pid) = handle.pid else {
      return Ok(());
    };
    kill_pid(pid, signal)
  }

  /// Force-kill every still-running command. Used on session teardown; failures
  /// are ignored because the session is going away regardless.
  pub fn kill_all(&self) {
    for handle in self.commands.iter() {
      if matches!(handle.output.status().0, CommandStatus::Running)
        && let Some(pid) = handle.pid
      {
        let _ = kill_pid(pid, Some("SIGKILL"));
      }
    }
  }
}

/// Translate an OS exit status into our status + numeric code.
///
/// A real exit code means the process returned normally. No code means it was
/// terminated by a signal, which we report as `Killed` with the conventional
/// `128 + signal` code so the number still carries the cause.
fn classify_exit_status(status: ExitStatus) -> (CommandStatus, Option<i32>) {
  if let Some(code) = status.code() {
    return (CommandStatus::Finished, Some(code));
  }
  (CommandStatus::Killed, signal_exit_code(&status))
}

#[cfg(unix)]
fn signal_exit_code(status: &ExitStatus) -> Option<i32> {
  use std::os::unix::process::ExitStatusExt;
  status.signal().map(|signal| 128 + signal)
}

#[cfg(not(unix))]
fn signal_exit_code(_status: &ExitStatus) -> Option<i32> {
  None
}

/// Drain one child pipe (stdout or stderr) into the buffer on its own task.
///
/// Reads in fixed chunks and forwards bytes as-is — no line buffering — so partial
/// lines and binary output stream through unchanged. Any read error simply ends
/// the task; the waiter task is what records the command's final status.
fn spawn_reader<R>(mut reader: R, stream: LogStream, output: Arc<OutputBuffer>)
where
  R: AsyncReadExt + Unpin + Send + 'static,
{
  tokio::spawn(async move {
    let mut buffer = [0u8; 8192];
    loop {
      match reader.read(&mut buffer).await {
        Ok(0) | Err(_) => break,
        Ok(read) => output.push(stream, Bytes::copy_from_slice(&buffer[..read])),
      }
    }
  });
}

/// Stream a command's logs: replay everything buffered so far, then follow until done.
///
/// `idx` is the cursor into the retained event log, so a follower that connects
/// late still gets the full history before live output. Seeing `done` is not
/// enough to stop: output written just before completion may still sit past
/// `idx`, so the loop only breaks once every buffered event has been yielded —
/// otherwise the final lines of a fast command would be dropped. As in
/// `wait_done`, `notified()` is taken before reading state to avoid a lost
/// wakeup.
pub fn follow(output: Arc<OutputBuffer>) -> impl Stream<Item = LogEvent> {
  async_stream::stream! {
    let mut idx = 0usize;
    loop {
      let notified = output.notify.notified();
      let (batch, done): (Vec<LogEvent>, bool) = {
        let guard = output.inner.lock().unwrap();
        (guard.events[idx..].to_vec(), guard.done.is_some())
      };
      idx += batch.len();
      for event in batch {
        yield event;
      }
      if done {
        let drained = { output.inner.lock().unwrap().events.len() <= idx };
        if drained {
          break;
        }
        continue;
      }
      notified.await;
    }
  }
}

/// Send a signal to a spawned command, preferring its whole process group.
///
/// Commands are launched in their own process group (see `set_process_group` in
/// `isolation`), so signalling the negative pid hits the leader and all its
/// children — without this, a shell that forked workers would leave orphans
/// behind. Falls back to the single pid when the group send fails (e.g. the
/// leader already reaped its group).
#[cfg(unix)]
fn kill_pid(pid: u32, signal: Option<&str>) -> AppResult<()> {
  use nix::sys::signal::kill;
  use nix::unistd::Pid;

  let sig = parse_signal(signal)?;
  if kill(Pid::from_raw(-(pid as i32)), sig).is_ok() {
    return Ok(());
  }
  kill(Pid::from_raw(pid as i32), sig)
    .map_err(|error| AppError::internal("kill_failed", format!("kill failed: {error}")))
}

#[cfg(unix)]
fn parse_signal(signal: Option<&str>) -> AppResult<nix::sys::signal::Signal> {
  use nix::sys::signal::Signal;

  let Some(raw) = signal else {
    return Ok(Signal::SIGTERM);
  };
  let upper = raw.trim().to_uppercase();
  let name = upper.strip_prefix("SIG").unwrap_or(&upper);
  Ok(match name {
    "TERM" | "15" => Signal::SIGTERM,
    "KILL" | "9" => Signal::SIGKILL,
    "INT" | "2" => Signal::SIGINT,
    "HUP" | "1" => Signal::SIGHUP,
    "QUIT" | "3" => Signal::SIGQUIT,
    "USR1" => Signal::SIGUSR1,
    "USR2" => Signal::SIGUSR2,
    other => {
      return Err(AppError::bad_request(
        "invalid_signal",
        format!("unsupported signal: {other}"),
      ));
    }
  })
}

#[cfg(not(unix))]
fn kill_pid(_pid: u32, _signal: Option<&str>) -> AppResult<()> {
  Ok(())
}

#[cfg(test)]
mod tests {
  use super::*;

  #[cfg(unix)]
  #[test]
  fn classifies_signal_exit_as_killed() {
    let status = std::process::Command::new("sh")
      .args(["-c", "kill -TERM $$"])
      .status()
      .unwrap();

    let (command_status, exit_code) = classify_exit_status(status);
    assert_eq!(command_status, CommandStatus::Killed);
    assert_eq!(exit_code, Some(143));
  }
}
