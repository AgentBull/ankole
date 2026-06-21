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
///
/// These carry the worker image's baseline (interpreters, system tools, certs).
/// They are mounted read-only so agent processes can *use* the toolchain but cannot
/// mutate it — the baseline is part of the image, not per-agent state. This is a real
/// integrity guard; it is not a confidentiality boundary (the agent can still read
/// everything under these paths, which is intended for trusted work).
const RO_SYSTEM_DIRS: &[&str] = &["/usr", "/bin", "/sbin", "/lib", "/lib64", "/etc", "/opt"];

/// Chooses how a command becomes an OS process: through bubblewrap (Linux/prod) or
/// straight on the host (dev/macOS). The mode is fixed for the worker's lifetime, so
/// this is a cheap `Copy` value threaded into every session.
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
  ///
  /// `--noprofile --norc` keeps the shell deterministic: no host dotfiles leak in, so
  /// every agent starts from the same known environment regardless of the image's
  /// `/etc/profile` contents.
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
    set_process_group(&mut command);
    command
  }

  /// Build a one-shot process command inside the computer.
  ///
  /// Unlike the persistent shell this keeps stdout and stderr on separate pipes so the
  /// caller can label each stream in the NDJSON log, and nulls stdin since a one-shot
  /// command has no interactive input.
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
    set_process_group(&mut command);
    command
  }

  /// Direct (non-isolating) launch used on macOS/dev, where bubblewrap is absent.
  ///
  /// There is no `/workspace` mount here, so the computer-facing cwd is translated to
  /// its real host path and HOME/env are set directly on the child process. This path
  /// provides NO isolation — it exists only so the API and shell can be exercised
  /// locally; the real boundary is the bwrap path in production.
  fn apply_direct(
    &self,
    command: &mut Command,
    ws: &WorkspacePaths,
    env: &BTreeMap<String, String>,
    cwd: Option<&str>,
  ) {
    // A bad/relative cwd falls back to the agent root rather than failing the spawn —
    // the goal in dev is to keep things runnable, not to police paths.
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

  /// Assemble the shared `bwrap ... --` prefix that every isolated command runs behind.
  ///
  /// The flags give a lightweight FS/PID *view*, not a strong sandbox (see README trust
  /// boundary). Specifically:
  /// - `--unshare-pid` + `--proc /proc`: the agent gets its own PID namespace, so it
  ///   cannot see or signal host/other-agent processes. (PID isolation only — not a
  ///   full container; no network/user-namespace hardening here.)
  /// - `--new-session`: detaches from the controlling terminal so the child can't inject
  ///   keystrokes into the parent's TTY (the classic `TIOCSTI` trick).
  /// - `--die-with-parent`: if the worker dies, the sandboxed tree is torn down with it,
  ///   so a crash cannot leave orphaned agent processes running.
  /// - `--dev /dev` + `--tmpfs /tmp`: a minimal device set and a private, throwaway
  ///   `/tmp` that does not touch the host's.
  /// What it does NOT provide: defense against a malicious image, kernel-level
  /// containment, or protection from symlinks already inside the bound workspace.
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

    // Toolchain dirs are mounted read-only and only when present, so the same flag list
    // works across images that ship a different subset of these paths.
    for dir in RO_SYSTEM_DIRS {
      if Path::new(dir).exists() {
        command.arg("--ro-bind").arg(dir).arg(dir);
      }
    }

    // The three workspace folders are bound read-write at their stable `/workspace`
    // locations regardless of where they live on the host. This is the seam that makes
    // the public `/workspace` shape identical to the Direct path above.
    command
      .arg("--bind")
      .arg(&ws.user_files)
      .arg("/workspace/user-files");
    command.arg("--bind").arg(&ws.temp).arg("/workspace/temp");
    command
      .arg("--bind")
      .arg(&ws.library_containers)
      .arg("/workspace/library-containers");
    // HOME points at temp so dotfiles/caches land in scratch, not in durable user-files.
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

/// Put the child in its own process group so a timeout/kill can signal the whole tree
/// at once (`kill(-pgid, ...)`), catching grandchildren the command spawned rather than
/// just the immediate process. No-op off Unix, where the concept does not apply.
#[cfg(unix)]
fn set_process_group(command: &mut Command) {
  command.process_group(0);
}

#[cfg(not(unix))]
fn set_process_group(_command: &mut Command) {}
