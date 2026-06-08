//! TigerFS mount manager for `library-containers`.
//!
//! TigerFS (PG + object-store backed) is external and Linux-only. v1 treats the
//! mountpoint as read-only and provides a directory-backed fallback for dev so the
//! rest of the daemon can run anywhere. The real mounter is a documented seam:
//! `MountBackend::Directory` simply ensures the directory exists; a future
//! `MountBackend::TigerFs` would invoke the TigerFS client to mount it.

use std::path::Path;

use crate::error::AppResult;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum MountBackend {
  /// Plain host directory (dev / when TigerFS is unavailable).
  Directory,
  /// Real TigerFS mount (reserved — falls back to Directory until wired).
  #[allow(dead_code)]
  TigerFs,
}

#[derive(Clone, Debug)]
pub struct TigerFs {
  backend: MountBackend,
}

impl TigerFs {
  pub fn new(backend: MountBackend) -> Self {
    Self { backend }
  }

  /// Ensure `library-containers` for an agent is present and readable at `mountpoint`.
  pub async fn ensure_mounted(&self, mountpoint: &Path, agent_uid: &str) -> AppResult<()> {
    match self.backend {
      MountBackend::Directory | MountBackend::TigerFs => {
        // Directory fallback: the mountpoint must exist so bwrap can ro-bind it.
        // The real TigerFS backend would mount here instead of just creating it.
        tokio::fs::create_dir_all(mountpoint).await?;
        tracing::debug!(%agent_uid, backend = ?self.backend, mountpoint = %mountpoint.display(), "library-containers ready");
        Ok(())
      }
    }
  }

  /// Liveness probe for the mount layer (always healthy for the directory backend).
  pub async fn healthy(&self) -> bool {
    true
  }
}
