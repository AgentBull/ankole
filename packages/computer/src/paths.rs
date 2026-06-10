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
  pub fn resolve(&self, cwd: Option<&str>, path: &str) -> AppResult<PathBuf> {
    let cwd = cwd.filter(|c| !c.is_empty()).unwrap_or(WORKSPACE_MOUNT);
    let combined = if path.starts_with('/') {
      path.to_string()
    } else {
      format!("{}/{}", cwd.trim_end_matches('/'), path)
    };

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
      Some(Component::Normal(segment)) => {
        let mut out = self.root.clone();
        out.push(segment);
        (out, self.root.clone())
      }
      Some(Component::RootDir | Component::CurDir) => (self.root.clone(), self.root.clone()),
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
