//! The launcher seam: build the OS process for a command, either inside bubblewrap
//! (Linux/production) or directly on the host (dev/macOS). Mirrors hermes-agent's
//! backend-environment abstraction — every command flows through one of these.

use std::collections::BTreeMap;
use std::path::Path;
use std::process::Stdio;

use tokio::process::Command;

use crate::config::IsolationMode;
use crate::paths::{WORKSPACE_MOUNT, WorkspacePaths};

/// Host directories bind-mounted read-only into the computer (when they exist).
const RO_SYSTEM_DIRS: &[&str] = &["/usr", "/bin", "/sbin", "/lib", "/lib64", "/etc"];

#[derive(Clone, Copy, Debug)]
pub struct Launcher {
  mode: IsolationMode,
}

impl Launcher {
  pub fn new(mode: IsolationMode) -> Self {
    Self { mode }
  }

  pub fn mode(&self) -> IsolationMode {
    self.mode
  }

  /// Build the long-lived persistent shell (`bash --noprofile --norc`).
  pub fn shell_command(&self, ws: &WorkspacePaths) -> Command {
    let mut command = match self.mode {
      IsolationMode::Bwrap => {
        let mut c = self.bwrap_base(ws, &BTreeMap::new(), Some(WORKSPACE_MOUNT));
        c.args(["bash", "--noprofile", "--norc"]);
        c
      }
      IsolationMode::Direct => {
        let mut c = Command::new("bash");
        c.args(["--noprofile", "--norc"]);
        self.apply_direct(&mut c, ws, &BTreeMap::new(), Some(WORKSPACE_MOUNT));
        c
      }
    };
    // stderr is merged into stdout inside the shell via `exec 2>&1`, so null it here.
    command
      .stdin(Stdio::piped())
      .stdout(Stdio::piped())
      .stderr(Stdio::null());
    command
  }

  /// Build a one-shot process command inside the computer.
  pub fn exec_command(
    &self,
    ws: &WorkspacePaths,
    program: &str,
    args: &[String],
    cwd: Option<&str>,
    env: &BTreeMap<String, String>,
  ) -> Command {
    let mut command = match self.mode {
      IsolationMode::Bwrap => {
        let mut c = self.bwrap_base(ws, env, cwd.or(Some(WORKSPACE_MOUNT)));
        c.arg(program).args(args);
        c
      }
      IsolationMode::Direct => {
        let mut c = Command::new(program);
        c.args(args);
        self.apply_direct(&mut c, ws, env, cwd);
        c
      }
    };
    command
      .stdin(Stdio::null())
      .stdout(Stdio::piped())
      .stderr(Stdio::piped());
    command
  }

  fn apply_direct(
    &self,
    command: &mut Command,
    ws: &WorkspacePaths,
    env: &BTreeMap<String, String>,
    cwd: Option<&str>,
  ) {
    let host_cwd = cwd
      .and_then(|c| ws.resolve(None, c).ok())
      .unwrap_or_else(|| ws.root.clone());
    command.current_dir(host_cwd);
    command.env("HOME", &ws.temp);
    command.env("BULLX_AGENT_UID", &ws.agent_uid);
    for (key, value) in env {
      command.env(key, value);
    }
  }

  fn bwrap_base(
    &self,
    ws: &WorkspacePaths,
    env: &BTreeMap<String, String>,
    chdir: Option<&str>,
  ) -> Command {
    let mut command = Command::new("bwrap");
    command
      .arg("--unshare-pid")
      .arg("--new-session")
      .arg("--die-with-parent")
      .args(["--proc", "/proc"])
      .args(["--dev", "/dev"])
      .args(["--tmpfs", "/tmp"]);

    for dir in RO_SYSTEM_DIRS {
      if Path::new(dir).exists() {
        command.arg("--ro-bind").arg(dir).arg(dir);
      }
    }

    command
      .arg("--bind")
      .arg(&ws.user_files)
      .arg("/workspace/user-files");
    command.arg("--bind").arg(&ws.temp).arg("/workspace/temp");
    command
      .arg("--ro-bind")
      .arg(&ws.library_containers)
      .arg("/workspace/library-containers");
    command.args(["--setenv", "HOME", "/workspace/temp"]);
    command
      .arg("--setenv")
      .arg("BULLX_AGENT_UID")
      .arg(&ws.agent_uid);
    for (key, value) in env {
      command.arg("--setenv").arg(key).arg(value);
    }
    if let Some(dir) = chdir {
      command.args(["--chdir", dir]);
    }
    command.arg("--");
    command
  }
}
