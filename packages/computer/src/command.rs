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
