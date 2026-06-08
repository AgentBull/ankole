//! The long-lived per-agent persistent shell.
//!
//! A single `bash --noprofile --norc` runs (inside bwrap on Linux). State —
//! `cd`, `export`, `alias`, shell functions — survives across calls because every
//! command runs in the same bash. `exec 2>&1` merges stderr into stdout; each
//! command is followed by a unique marker line carrying its exit code and `$PWD`,
//! which we read to know the command finished.

use std::time::Duration;

use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::process::{Child, ChildStdin, ChildStdout, Command};
use uuid::Uuid;

use crate::error::{AppError, AppResult};

pub struct ShellResult {
  pub output: String,
  pub exit_code: i32,
  pub cwd: Option<String>,
  pub timed_out: bool,
}

pub struct PersistentShell {
  child: Child,
  stdin: ChildStdin,
  reader: BufReader<ChildStdout>,
  marker: String,
}

impl PersistentShell {
  pub async fn start(mut command: Command) -> AppResult<Self> {
    let mut child = command.spawn().map_err(|error| {
      AppError::internal("shell_spawn", format!("failed to start shell: {error}"))
    })?;
    let stdin = child
      .stdin
      .take()
      .ok_or_else(|| AppError::internal("shell_io", "shell stdin unavailable"))?;
    let stdout = child
      .stdout
      .take()
      .ok_or_else(|| AppError::internal("shell_io", "shell stdout unavailable"))?;
    let marker = format!("__BULLX_{}__", Uuid::new_v4().simple());

    let mut shell = Self {
      child,
      stdin,
      reader: BufReader::new(stdout),
      marker,
    };
    // Merge stderr into stdout for the whole session.
    shell.stdin.write_all(b"exec 2>&1\n").await?;
    shell.stdin.flush().await?;
    Ok(shell)
  }

  pub async fn run(&mut self, command: &str, timeout: Duration) -> AppResult<ShellResult> {
    let payload = format!(
      "{command}\nprintf '\\n%s %s %s\\n' '{marker}' \"$?\" \"$PWD\"\n",
      marker = self.marker
    );
    self.stdin.write_all(payload.as_bytes()).await?;
    self.stdin.flush().await?;

    let marker_prefix = format!("{} ", self.marker);
    let reader = &mut self.reader;
    let mut output = String::new();

    let read = async {
      loop {
        let mut line = String::new();
        let bytes = reader.read_line(&mut line).await?;
        if bytes == 0 {
          return Err(AppError::internal(
            "shell_closed",
            "persistent shell exited unexpectedly",
          ));
        }
        if let Some(rest) = line.strip_prefix(&marker_prefix) {
          let mut parts = rest.trim_end().splitn(2, ' ');
          let exit_code = parts
            .next()
            .and_then(|value| value.parse().ok())
            .unwrap_or(-1);
          let cwd = parts
            .next()
            .filter(|value| !value.is_empty())
            .map(|value| value.to_string());
          return Ok::<(i32, Option<String>), AppError>((exit_code, cwd));
        }
        output.push_str(&line);
      }
    };

    match tokio::time::timeout(timeout, read).await {
      Ok(Ok((exit_code, cwd))) => {
        // Drop the trailing newline injected by our marker printf.
        if output.ends_with('\n') {
          output.pop();
        }
        Ok(ShellResult {
          output,
          exit_code,
          cwd,
          timed_out: false,
        })
      }
      Ok(Err(error)) => Err(error),
      Err(_) => {
        let _ = self.child.start_kill();
        let _ = self.child.wait().await;
        Ok(ShellResult {
          output,
          exit_code: 124,
          cwd: None,
          timed_out: true,
        })
      }
    }
  }

  pub async fn shutdown(mut self) {
    let _ = self.stdin.write_all(b"exit\n").await;
    let _ = self.child.start_kill();
    let _ = self.child.wait().await;
  }
}

#[cfg(test)]
mod tests {
  use super::*;

  #[tokio::test]
  async fn timeout_kills_the_persistent_shell() {
    let mut command = Command::new("bash");
    command
      .args(["--noprofile", "--norc"])
      .stdin(std::process::Stdio::piped())
      .stdout(std::process::Stdio::piped())
      .stderr(std::process::Stdio::null());
    let mut shell = PersistentShell::start(command).await.unwrap();

    let timed_out = shell
      .run("sleep 1; echo OLD", Duration::from_millis(50))
      .await
      .unwrap();
    assert!(timed_out.timed_out);
    assert_eq!(timed_out.exit_code, 124);

    let next = shell.run("echo NEW", Duration::from_secs(1)).await;
    assert!(next.is_err());
  }
}
