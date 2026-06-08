//! tmux-backed terminal management for an agent workplace.
//!
//! This is the default interactive terminal foundation for the BullX Computer:
//! Codex, Claude, REPLs, and installers should live in tmux windows so an agent
//! can reattach across tool calls and HTTP disconnects on the same sticky worker.

use std::collections::BTreeMap;
use std::time::Duration;

use serde::Serialize;
use tokio::process::Command;

use crate::config::IsolationMode;
use crate::error::{AppError, AppResult};
use crate::isolation::Launcher;
use crate::paths::{WORKSPACE_MOUNT, WorkspacePaths};

const TMUX_SOCKET_FILE: &str = ".bullx-computer.tmux.sock";
const TMUX_TIMEOUT: Duration = Duration::from_secs(10);

#[derive(Clone)]
pub struct TmuxManager {
  paths: WorkspacePaths,
  launcher: Launcher,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct TerminalInfo {
  pub name: String,
  pub windows: u32,
  pub attached: bool,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct TerminalStatus {
  pub name: String,
  pub status: &'static str,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct TerminalCapture {
  pub name: String,
  pub screen: String,
}

impl TmuxManager {
  pub fn new(paths: WorkspacePaths, launcher: Launcher) -> Self {
    Self { paths, launcher }
  }

  pub async fn list(&self) -> AppResult<Vec<TerminalInfo>> {
    let output = self
      .run_tmux(&[
        "list-sessions".to_string(),
        "-F".to_string(),
        "#S\t#{session_windows}\t#{session_attached}".to_string(),
      ])
      .await?;
    if !output.status.success() {
      let stderr = String::from_utf8_lossy(&output.stderr);
      if is_missing_server(&stderr) {
        return Ok(Vec::new());
      }
      return Err(tmux_error("terminal_list_failed", output));
    }
    let stdout = String::from_utf8_lossy(&output.stdout);
    Ok(stdout.lines().filter_map(parse_terminal_info).collect())
  }

  pub async fn start(
    &self,
    name: &str,
    command: Option<&str>,
    cwd: Option<&str>,
    cols: u16,
    rows: u16,
  ) -> AppResult<TerminalStatus> {
    validate_name(name)?;
    if self.has_session(name).await? {
      return Ok(TerminalStatus {
        name: name.to_string(),
        status: "exists",
      });
    }

    let command = command
      .map(str::trim)
      .filter(|value| !value.is_empty())
      .unwrap_or("bash");
    let cwd = self.tmux_cwd(cwd)?;
    let args = vec![
      "new-session".to_string(),
      "-d".to_string(),
      "-s".to_string(),
      name.to_string(),
      "-x".to_string(),
      cols.to_string(),
      "-y".to_string(),
      rows.to_string(),
      "-c".to_string(),
      cwd,
      "--".to_string(),
      "bash".to_string(),
      "-lc".to_string(),
      command.to_string(),
    ];
    let output = self.run_tmux(&args).await?;
    if !output.status.success() {
      return Err(tmux_error("terminal_start_failed", output));
    }
    Ok(TerminalStatus {
      name: name.to_string(),
      status: "started",
    })
  }

  pub async fn send(
    &self,
    name: &str,
    input: Option<&str>,
    keys: &[String],
    enter: bool,
  ) -> AppResult<TerminalStatus> {
    validate_name(name)?;
    if input.is_none() && keys.is_empty() && !enter {
      return Err(AppError::bad_request(
        "terminal_empty_input",
        "input or keys is required",
      ));
    }

    if let Some(input) = input {
      let args = vec![
        "send-keys".to_string(),
        "-t".to_string(),
        name.to_string(),
        "-l".to_string(),
        "--".to_string(),
        input.to_string(),
      ];
      self.ensure_success("terminal_send_failed", self.run_tmux(&args).await?)?;
    }

    if !keys.is_empty() || enter {
      let mut args = vec!["send-keys".to_string(), "-t".to_string(), name.to_string()];
      args.extend(keys.iter().cloned());
      if enter {
        args.push("Enter".to_string());
      }
      self.ensure_success("terminal_send_failed", self.run_tmux(&args).await?)?;
    }

    Ok(TerminalStatus {
      name: name.to_string(),
      status: "sent",
    })
  }

  pub async fn capture(&self, name: &str, lines: u16) -> AppResult<TerminalCapture> {
    validate_name(name)?;
    let args = vec![
      "capture-pane".to_string(),
      "-t".to_string(),
      name.to_string(),
      "-p".to_string(),
      "-J".to_string(),
      "-S".to_string(),
      format!("-{lines}"),
    ];
    let output = self.run_tmux(&args).await?;
    if !output.status.success() {
      return Err(tmux_error("terminal_capture_failed", output));
    }
    Ok(TerminalCapture {
      name: name.to_string(),
      screen: String::from_utf8_lossy(&output.stdout).into_owned(),
    })
  }

  pub async fn kill(&self, name: &str) -> AppResult<TerminalStatus> {
    validate_name(name)?;
    let output = self
      .run_tmux(&[
        "kill-session".to_string(),
        "-t".to_string(),
        name.to_string(),
      ])
      .await?;
    if !output.status.success() {
      return Err(tmux_error("terminal_kill_failed", output));
    }
    Ok(TerminalStatus {
      name: name.to_string(),
      status: "killed",
    })
  }

  async fn has_session(&self, name: &str) -> AppResult<bool> {
    let output = self
      .run_tmux(&[
        "has-session".to_string(),
        "-t".to_string(),
        name.to_string(),
      ])
      .await?;
    if output.status.success() {
      return Ok(true);
    }
    let stderr = String::from_utf8_lossy(&output.stderr);
    if is_missing_server(&stderr) || stderr.contains("can't find session") {
      return Ok(false);
    }
    Err(tmux_error("terminal_lookup_failed", output))
  }

  async fn run_tmux(&self, args: &[String]) -> AppResult<std::process::Output> {
    tokio::fs::create_dir_all(&self.paths.temp).await?;
    let socket = self.socket_path();
    let mut full_args = vec!["-S".to_string(), socket];
    full_args.extend(args.iter().cloned());
    let mut command = self.launcher.exec_command(
      &self.paths,
      "tmux",
      &full_args,
      Some(WORKSPACE_MOUNT),
      &BTreeMap::new(),
    );
    command.kill_on_drop(true);
    output_with_timeout(command).await
  }

  fn socket_path(&self) -> String {
    match self.launcher.mode() {
      IsolationMode::Bwrap => format!("{WORKSPACE_MOUNT}/temp/{TMUX_SOCKET_FILE}"),
      IsolationMode::Direct => self
        .paths
        .temp
        .join(TMUX_SOCKET_FILE)
        .to_string_lossy()
        .into_owned(),
    }
  }

  fn tmux_cwd(&self, cwd: Option<&str>) -> AppResult<String> {
    let raw = cwd
      .map(str::trim)
      .filter(|value| !value.is_empty())
      .unwrap_or(WORKSPACE_MOUNT);
    let resolved = self.paths.resolve(None, raw)?;
    match self.launcher.mode() {
      IsolationMode::Direct => Ok(resolved.to_string_lossy().into_owned()),
      IsolationMode::Bwrap => {
        if raw.starts_with('/') {
          Ok(raw.to_string())
        } else {
          Ok(format!(
            "{WORKSPACE_MOUNT}/{}",
            raw.trim_start_matches("./")
          ))
        }
      }
    }
  }

  fn ensure_success(&self, code: &'static str, output: std::process::Output) -> AppResult<()> {
    if output.status.success() {
      return Ok(());
    }
    Err(tmux_error(code, output))
  }
}

async fn output_with_timeout(mut command: Command) -> AppResult<std::process::Output> {
  match tokio::time::timeout(TMUX_TIMEOUT, command.output()).await {
    Ok(Ok(output)) => Ok(output),
    Ok(Err(error)) => Err(AppError::internal("tmux_exec_failed", error.to_string())),
    Err(_) => Err(AppError::internal("tmux_timeout", "tmux command timed out")),
  }
}

fn parse_terminal_info(line: &str) -> Option<TerminalInfo> {
  let mut parts = line.split('\t');
  let name = parts.next()?.to_string();
  let windows = parts
    .next()
    .and_then(|value| value.parse::<u32>().ok())
    .unwrap_or(0);
  let attached = parts.next() == Some("1");
  Some(TerminalInfo {
    name,
    windows,
    attached,
  })
}

fn validate_name(name: &str) -> AppResult<()> {
  let valid_len = !name.is_empty() && name.len() <= 64;
  let valid_chars = name
    .bytes()
    .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'_' | b'.' | b'-'));
  if valid_len && valid_chars {
    return Ok(());
  }
  Err(AppError::bad_request(
    "invalid_terminal_name",
    "terminal name must match /^[A-Za-z0-9_.-]{1,64}$/",
  ))
}

fn is_missing_server(stderr: &str) -> bool {
  stderr.contains("no server running")
    || stderr.contains("failed to connect")
    || stderr.contains("No such file or directory")
}

fn tmux_error(code: &'static str, output: std::process::Output) -> AppError {
  let stderr = String::from_utf8_lossy(&output.stderr);
  let stdout = String::from_utf8_lossy(&output.stdout);
  let message = if stderr.trim().is_empty() {
    stdout.trim().to_string()
  } else {
    stderr.trim().to_string()
  };
  AppError::bad_request(
    code,
    if message.is_empty() {
      format!("tmux exited with {}", output.status)
    } else {
      message
    },
  )
}

#[cfg(test)]
mod tests {
  use super::*;
  use crate::config::IsolationMode;
  use uuid::Uuid;

  fn tmux_available() -> bool {
    std::process::Command::new("tmux")
      .arg("-V")
      .status()
      .map(|status| status.success())
      .unwrap_or(false)
  }

  async fn test_manager() -> (TmuxManager, std::path::PathBuf) {
    // tmux uses a Unix socket, which has a short path limit on macOS. Keep the
    // integration-test root short while preserving the workplace-relative socket.
    let root = std::path::PathBuf::from(format!("/tmp/bxc-{}", Uuid::new_v4().simple()));
    let paths = WorkspacePaths::new(&root, "agent_1");
    tokio::fs::create_dir_all(&paths.user_files).await.unwrap();
    tokio::fs::create_dir_all(&paths.temp).await.unwrap();
    tokio::fs::create_dir_all(&paths.library_containers)
      .await
      .unwrap();
    (
      TmuxManager::new(paths, Launcher::new(IsolationMode::Direct)),
      root,
    )
  }

  #[tokio::test]
  async fn starts_lists_sends_captures_and_kills_terminal() {
    if !tmux_available() {
      return;
    }
    let (manager, root) = test_manager().await;
    let name = format!("term_{}", Uuid::new_v4().simple());

    let started = manager
      .start(&name, Some("bash"), None, 100, 30)
      .await
      .unwrap();
    assert_eq!(started.status, "started");

    let sessions = manager.list().await.unwrap();
    assert!(sessions.iter().any(|session| session.name == name));

    manager
      .send(&name, Some("echo READY"), &[], true)
      .await
      .unwrap();
    tokio::time::sleep(Duration::from_millis(200)).await;
    let capture = manager.capture(&name, 80).await.unwrap();
    assert!(capture.screen.contains("READY"), "{}", capture.screen);

    let killed = manager.kill(&name).await.unwrap();
    assert_eq!(killed.status, "killed");
    let _ = tokio::fs::remove_dir_all(root).await;
  }
}
