//! Workspace path layout + the lexical path-traversal guard.
//!
//! On the host, each agent owns a workspace view plus storage-specific backing
//! roots for `user-files/`, `temp/`, and `library-containers/`. Inside the
//! computer these are mounted under `/workspace`. Worker-side file ops operate
//! on host paths; this module translates a computer path into a host path and
//! refuses direct `..` / absolute path escapes. It does not canonicalize symlinks.

use std::path::{Component, Path, PathBuf};

use crate::error::{AppError, AppResult};

pub const WORKSPACE_MOUNT: &str = "/workspace";

/// Host-side path set for one agent. `root` is the `/workspace` view directory;
/// the three named roots are where each top-level workspace folder actually
/// lives on disk. They can point at the same place (unified dev layout) or at
/// separate backing volumes (deployment), which is why they are stored
/// individually rather than derived from `root`.
#[derive(Clone, Debug)]
pub struct WorkspacePaths {
  pub agent_uid: String,
  pub root: PathBuf,
  pub user_files: PathBuf,
  pub temp: PathBuf,
  pub library_containers: PathBuf,
}

impl WorkspacePaths {
  #[cfg(test)]
  pub fn new(workspace_root: &Path, agent_uid: &str) -> Self {
    Self::with_roots(
      workspace_root,
      workspace_root,
      workspace_root,
      workspace_root,
      agent_uid,
    )
  }

  /// Build the path set from the four (possibly distinct) backing roots.
  ///
  /// When every root is the same directory, the three folders are nested under
  /// the per-agent `root` (`root/user-files`, etc.) and the `/workspace` view is
  /// the agent root itself. When the roots differ, each folder is `root/agent_uid`
  /// of its own backing volume and the `root` view directory only holds symlinks
  /// into them (see `ensure_workspace_view` in session.rs). The two cases produce
  /// different on-disk layouts but the same `/workspace` shape callers see.
  pub fn with_roots(
    workspace_root: &Path,
    user_files_root: &Path,
    temp_root: &Path,
    library_containers_root: &Path,
    agent_uid: &str,
  ) -> Self {
    let root = workspace_root.join(agent_uid);
    if workspace_root == user_files_root
      && workspace_root == temp_root
      && workspace_root == library_containers_root
    {
      return Self {
        user_files: root.join("user-files"),
        temp: root.join("temp"),
        library_containers: root.join("library-containers"),
        root,
        agent_uid: agent_uid.to_string(),
      };
    }

    Self {
      user_files: user_files_root.join(agent_uid),
      temp: temp_root.join(agent_uid),
      library_containers: library_containers_root.join(agent_uid),
      root,
      agent_uid: agent_uid.to_string(),
    }
  }

  /// Map a computer path (relative to `cwd`, or absolute under `/workspace`) onto a
  /// host path under the agent root. Rejects `..` and absolute paths outside
  /// `/workspace`; existing symlinks are intentionally left to the OS.
  ///
  /// This is a purely *lexical* check: it normalizes the string and validates the
  /// components, but never touches the filesystem (no `realpath`/canonicalize). It
  /// stops the two cheap escapes — a literal `..` segment and an absolute path that
  /// leaves `/workspace` — which is the threat this trusted environment cares about.
  /// It deliberately does NOT defend against a symlink already inside the workspace
  /// that points elsewhere; following those is a chosen "useful over strict" tradeoff
  /// (see the module doc and README trust boundary). Doing realpath here would also
  /// reject not-yet-created paths (mkdir/write targets), so the layer above keeps it
  /// lexical and lets the OS resolve links.
  pub fn resolve(&self, cwd: Option<&str>, path: &str) -> AppResult<PathBuf> {
    // An absolute input ignores cwd and is taken as a `/workspace`-rooted path;
    // anything relative is joined onto cwd (which defaults to the mount root).
    let cwd = cwd.filter(|c| !c.is_empty()).unwrap_or(WORKSPACE_MOUNT);
    let combined = if path.starts_with('/') {
      path.to_string()
    } else {
      format!("{}/{}", cwd.trim_end_matches('/'), path)
    };

    // Phase 1: the combined path must name the mount itself or sit under it. The
    // trailing-slash strip is what makes `/workspace-evil` fail instead of matching
    // a bare `/workspace` prefix.
    let relative = if combined == WORKSPACE_MOUNT {
      ""
    } else if let Some(rest) = combined.strip_prefix("/workspace/") {
      rest
    } else {
      return Err(AppError::forbidden(
        "path_outside_workspace",
        format!("path escapes {WORKSPACE_MOUNT}: {combined}"),
      ));
    };

    // Phase 2: walk the path component by component. The first segment is special:
    // it picks which backing root the path lives on (user-files / temp /
    // library-containers may each be a separate volume), so it is matched by name
    // and the rest is appended to that root. `base` records the root we landed on
    // and is used as the final containment check below.
    let mut components = Path::new(relative).components();
    let first = components.next();
    let (mut out, base) = match first {
      None => (self.root.clone(), self.root.clone()),
      Some(Component::Normal(segment)) if segment == "user-files" => {
        (self.user_files.clone(), self.user_files.clone())
      }
      Some(Component::Normal(segment)) if segment == "temp" => {
        (self.temp.clone(), self.temp.clone())
      }
      Some(Component::Normal(segment)) if segment == "library-containers" => (
        self.library_containers.clone(),
        self.library_containers.clone(),
      ),
      // Any other first segment is a plain file/dir directly under the view root.
      Some(Component::Normal(segment)) => {
        let mut out = self.root.clone();
        out.push(segment);
        (out, self.root.clone())
      }
      Some(Component::RootDir | Component::CurDir) => (self.root.clone(), self.root.clone()),
      // A leading `..` would climb above the workspace before we even start.
      Some(Component::ParentDir) => {
        return Err(AppError::forbidden(
          "path_traversal",
          format!("'..' is not allowed: {combined}"),
        ));
      }
      Some(Component::Prefix(_)) => {
        return Err(AppError::forbidden(
          "path_traversal",
          "drive prefixes are not allowed",
        ));
      }
    };

    // Remaining components: normal segments extend the path, `.`/leading-slash are
    // no-ops, and `..`/drive-prefix are rejected outright. Rejecting (rather than
    // popping) `..` is intentional — it keeps the rule trivial to reason about and
    // refuses anything that even looks like an escape attempt.
    for component in components {
      match component {
        Component::Normal(segment) => out.push(segment),
        Component::RootDir | Component::CurDir => {}
        Component::ParentDir => {
          return Err(AppError::forbidden(
            "path_traversal",
            format!("'..' is not allowed: {combined}"),
          ));
        }
        Component::Prefix(_) => {
          return Err(AppError::forbidden(
            "path_traversal",
            "drive prefixes are not allowed",
          ));
        }
      }
    }

    // Belt-and-suspenders: since `..` is already rejected the assembled path cannot
    // climb out, but this re-asserts containment against the chosen backing root in
    // case the component logic above ever changes.
    if !out.starts_with(&base) {
      return Err(AppError::forbidden(
        "path_escape",
        "resolved path escapes the workspace",
      ));
    }
    Ok(out)
  }
}

#[cfg(test)]
mod tests {
  use super::*;

  fn ws() -> WorkspacePaths {
    WorkspacePaths::new(Path::new("/workspaces"), "agent_1")
  }

  fn split_ws() -> WorkspacePaths {
    WorkspacePaths::with_roots(
      Path::new("/workspaces/view"),
      Path::new("/workspaces/user-files"),
      Path::new("/workspaces/temp"),
      Path::new("/workspaces/library-containers"),
      "agent_1",
    )
  }

  #[test]
  fn resolves_relative_against_default_cwd() {
    let path = ws().resolve(None, "user-files/x.pdf").unwrap();
    assert_eq!(path, PathBuf::from("/workspaces/agent_1/user-files/x.pdf"));
  }

  #[test]
  fn resolves_absolute_workspace_path() {
    let path = ws()
      .resolve(Some("/workspace"), "/workspace/temp/a")
      .unwrap();
    assert_eq!(path, PathBuf::from("/workspaces/agent_1/temp/a"));
  }

  #[test]
  fn rejects_parent_traversal() {
    assert!(ws().resolve(None, "user-files/../../etc/passwd").is_err());
  }

  #[test]
  fn rejects_absolute_escape() {
    assert!(ws().resolve(None, "/etc/passwd").is_err());
  }

  #[test]
  fn rejects_workspace_lookalike_prefix() {
    assert!(ws().resolve(Some("/workspace-evil"), "x").is_err());
  }

  #[test]
  fn split_roots_resolve_public_workspace_paths_to_backing_roots() {
    assert_eq!(
      split_ws().resolve(None, "user-files/x.pdf").unwrap(),
      PathBuf::from("/workspaces/user-files/agent_1/x.pdf")
    );
    assert_eq!(
      split_ws()
        .resolve(Some("/workspace"), "/workspace/library-containers/SOUL.md")
        .unwrap(),
      PathBuf::from("/workspaces/library-containers/agent_1/SOUL.md")
    );
  }
}
