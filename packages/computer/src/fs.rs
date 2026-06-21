//! Worker-side filesystem operations. Paths go through `WorkspacePaths::resolve`
//! for lexical `/workspace` mapping; existing symlinks are intentionally followed
//! because this computer is a trusted long-lived work environment, not a strict
//! security boundary.

use std::io::Read;

use bytes::Bytes;
use serde::Serialize;

use crate::error::{AppError, AppResult};
use crate::paths::WorkspacePaths;

// Upload guards against a hostile or runaway tar.gz ("tar bomb"): a cap on entry
// count, on total extracted size, and on any single entry. They bound disk use even
// though this is a trusted environment — a buggy client should not be able to fill the
// volume with one request.
const MAX_TAR_ENTRIES: usize = 50_000;
const MAX_TAR_EXTRACTED_BYTES: u64 = 512 * 1024 * 1024;
const MAX_TAR_ENTRY_BYTES: u64 = 256 * 1024 * 1024;

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct FileStat {
  pub path: String,
  pub kind: String,
  pub size: u64,
  pub mode: u32,
  pub modified_ms: i64,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct DirEntry {
  pub name: String,
  pub kind: String,
  pub size: u64,
}

pub struct WriteResult {
  pub files: usize,
}

pub async fn mkdir(
  ws: &WorkspacePaths,
  cwd: Option<&str>,
  path: &str,
  recursive: bool,
) -> AppResult<()> {
  let target = ws.resolve(cwd, path)?;
  if recursive {
    tokio::fs::create_dir_all(&target).await?;
  } else {
    tokio::fs::create_dir(&target).await?;
  }
  Ok(())
}

/// Report metadata for a path. Uses `symlink_metadata`, so the final component is NOT
/// followed: a symlink is described as a symlink (kind `"symlink"`) rather than as its
/// target. That lets callers see link structure; `open_read` below, by contrast, does
/// follow links because it wants the bytes.
pub async fn stat(ws: &WorkspacePaths, cwd: Option<&str>, path: &str) -> AppResult<FileStat> {
  let target = ws.resolve(cwd, path)?;
  let meta = tokio::fs::symlink_metadata(&target)
    .await
    .map_err(|_| AppError::not_found("not_found", format!("no such path: {path}")))?;
  Ok(FileStat {
    path: path.to_string(),
    kind: kind_of(&meta),
    size: meta.len(),
    mode: mode_of(&meta),
    modified_ms: modified_ms(&meta),
  })
}

pub async fn readdir(
  ws: &WorkspacePaths,
  cwd: Option<&str>,
  path: &str,
) -> AppResult<Vec<DirEntry>> {
  let target = ws.resolve(cwd, path)?;
  let mut reader = tokio::fs::read_dir(&target)
    .await
    .map_err(|_| AppError::not_found("not_found", format!("no such directory: {path}")))?;
  let mut entries = Vec::new();
  while let Some(entry) = reader.next_entry().await? {
    let meta = entry.metadata().await?;
    entries.push(DirEntry {
      name: entry.file_name().to_string_lossy().to_string(),
      kind: kind_of(&meta),
      size: meta.len(),
    });
  }
  entries.sort_by(|a, b| a.name.cmp(&b.name));
  Ok(entries)
}

/// Open a file for reading, returning `None` (→ 404) when it is missing or not a file.
pub async fn open_read(
  ws: &WorkspacePaths,
  cwd: Option<&str>,
  path: &str,
) -> AppResult<Option<(tokio::fs::File, u64)>> {
  let target = ws.resolve(cwd, path)?;
  match tokio::fs::metadata(&target).await {
    Ok(meta) if meta.is_file() => {
      let file = tokio::fs::File::open(&target).await?;
      Ok(Some((file, meta.len())))
    }
    _ => Ok(None),
  }
}

/// Unpack a gzipped tar into the workspace under `cwd`.
///
/// gzip inflate plus synchronous file writes are CPU/blocking work, so the whole unpack
/// runs on `spawn_blocking` to keep it off the async runtime's worker threads. A join
/// failure (panic in the blocking task) surfaces as a 500.
pub async fn write_tar_gz(
  ws: &WorkspacePaths,
  cwd: Option<&str>,
  body: Bytes,
) -> AppResult<WriteResult> {
  let ws = ws.clone();
  let cwd = cwd.map(|value| value.to_string());
  tokio::task::spawn_blocking(move || unpack(&ws, cwd.as_deref(), &body))
    .await
    .map_err(|error| AppError::internal("join_error", error.to_string()))?
}

/// Stream the archive entry by entry, validating each against the path guard and the
/// size/count caps before writing. Entries are read fully into memory one at a time
/// (bounded by `MAX_TAR_ENTRY_BYTES`) rather than streamed to disk, which keeps the
/// code simple at the cost of holding one entry's bytes transiently.
fn unpack(ws: &WorkspacePaths, cwd: Option<&str>, body: &[u8]) -> AppResult<WriteResult> {
  let decoder = flate2::read::GzDecoder::new(body);
  let mut archive = tar::Archive::new(decoder);
  let mut files = 0;
  let mut entry_count = 0usize;
  let mut extracted_bytes = 0u64;

  let entries = archive
    .entries()
    .map_err(|error| AppError::bad_request("bad_archive", format!("invalid tar.gz: {error}")))?;
  for entry in entries {
    entry_count += 1;
    if entry_count > MAX_TAR_ENTRIES {
      return Err(AppError::bad_request(
        "archive_too_large",
        format!("archive has more than {MAX_TAR_ENTRIES} entries"),
      ));
    }

    let mut entry =
      entry.map_err(|error| AppError::bad_request("bad_archive", error.to_string()))?;
    let entry_path = entry
      .path()
      .map_err(|error| AppError::bad_request("bad_archive", error.to_string()))?;
    let relative = entry_path.to_string_lossy().to_string();
    let mode = entry.header().mode().unwrap_or(0o644);
    let entry_type = entry.header().entry_type();
    let is_dir = entry_type.is_dir();
    // Each entry's path runs through the same lexical guard as every other file op, so a
    // tar holding `../` or absolute paths cannot write outside the workspace.
    let target = ws.resolve(cwd, &relative)?;

    if is_dir {
      std::fs::create_dir_all(&target)?;
      continue;
    }
    // Only directories and regular files are accepted. Symlink/hardlink/device entries
    // are refused here: an archived symlink is the one way a tar could still smuggle an
    // escape past the lexical check, so unpacking simply does not create them.
    if !entry_type.is_file() {
      return Err(AppError::bad_request(
        "unsafe_archive_entry",
        format!("archive entry is not a regular file: {relative}"),
      ));
    }
    if entry.size() > MAX_TAR_ENTRY_BYTES {
      return Err(AppError::bad_request(
        "archive_entry_too_large",
        format!("archive entry exceeds {MAX_TAR_ENTRY_BYTES} bytes: {relative}"),
      ));
    }
    if let Some(parent) = target.parent() {
      std::fs::create_dir_all(parent)?;
    }
    let mut data = Vec::new();
    entry
      .read_to_end(&mut data)
      .map_err(|error| AppError::bad_request("bad_archive", error.to_string()))?;
    // `checked_add` guards the running total itself: a header claiming an absurd size
    // cannot wrap the counter around and slip past the cap below.
    extracted_bytes = extracted_bytes
      .checked_add(data.len() as u64)
      .ok_or_else(|| {
        AppError::bad_request("archive_too_large", "archive extracted size overflow")
      })?;
    if extracted_bytes > MAX_TAR_EXTRACTED_BYTES {
      return Err(AppError::bad_request(
        "archive_too_large",
        format!("archive extracted bytes exceed {MAX_TAR_EXTRACTED_BYTES}"),
      ));
    }
    std::fs::write(&target, &data)?;
    set_mode(&target, mode)?;
    files += 1;
  }
  Ok(WriteResult { files })
}

fn kind_of(meta: &std::fs::Metadata) -> String {
  if meta.is_dir() {
    "dir"
  } else if meta.file_type().is_symlink() {
    "symlink"
  } else if meta.is_file() {
    "file"
  } else {
    "other"
  }
  .to_string()
}

fn modified_ms(meta: &std::fs::Metadata) -> i64 {
  meta
    .modified()
    .ok()
    .and_then(|time| time.duration_since(std::time::UNIX_EPOCH).ok())
    .map(|delta| delta.as_millis() as i64)
    .unwrap_or(0)
}

#[cfg(unix)]
fn mode_of(meta: &std::fs::Metadata) -> u32 {
  use std::os::unix::fs::PermissionsExt;
  meta.permissions().mode()
}

#[cfg(not(unix))]
fn mode_of(_meta: &std::fs::Metadata) -> u32 {
  0o644
}

/// Reapply the archive entry's stored permission bits after writing, so an executable
/// packed by the client stays executable on disk. No-op off Unix, where mode bits do
/// not carry the same meaning.
#[cfg(unix)]
fn set_mode(path: &std::path::Path, mode: u32) -> AppResult<()> {
  use std::os::unix::fs::PermissionsExt;
  std::fs::set_permissions(path, std::fs::Permissions::from_mode(mode))?;
  Ok(())
}

#[cfg(not(unix))]
fn set_mode(_path: &std::path::Path, _mode: u32) -> AppResult<()> {
  Ok(())
}

#[cfg(test)]
mod tests {
  use super::*;
  use crate::paths::WorkspacePaths;
  use tokio::io::AsyncReadExt;

  fn workspace(name: &str) -> (tempfile_like::TempDir, WorkspacePaths) {
    let temp = tempfile_like::TempDir::new(name);
    let ws = WorkspacePaths::new(temp.path(), "agent_1");
    std::fs::create_dir_all(&ws.user_files).unwrap();
    std::fs::create_dir_all(&ws.temp).unwrap();
    std::fs::create_dir_all(&ws.library_containers).unwrap();
    (temp, ws)
  }

  #[cfg(unix)]
  #[tokio::test]
  async fn read_follows_symlink_target() {
    let (_temp, ws) = workspace("read_follows_symlink");
    let outside = std::env::temp_dir().join(format!(
      "bullx-computer-outside-{}",
      uuid::Uuid::new_v4().simple()
    ));
    std::fs::write(&outside, b"outside").unwrap();
    let link = ws.temp.join("escape");
    std::os::unix::fs::symlink(&outside, &link).unwrap();

    let (mut file, _) = open_read(&ws, Some("/workspace"), "temp/escape")
      .await
      .unwrap()
      .unwrap();
    let mut data = String::new();
    file.read_to_string(&mut data).await.unwrap();
    assert_eq!(data, "outside");

    let _ = std::fs::remove_file(outside);
  }

  mod tempfile_like {
    use std::path::{Path, PathBuf};

    pub struct TempDir {
      path: PathBuf,
    }

    impl TempDir {
      pub fn new(name: &str) -> Self {
        let path = std::env::temp_dir().join(format!(
          "bullx-computer-test-{name}-{}",
          uuid::Uuid::new_v4().simple()
        ));
        std::fs::create_dir_all(&path).unwrap();
        Self { path }
      }

      pub fn path(&self) -> &Path {
        &self.path
      }
    }

    impl Drop for TempDir {
      fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.path);
      }
    }
  }
}
