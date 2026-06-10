//! DB-backed library-containers manager.
//!
//! TigerFS itself exposes PostgreSQL data as a filesystem. BullX needs a Hermes-shaped
//! writable tree (`SOUL.md`, `skills/*/SKILL.md`, `skills/*/AGENT_APPEND.md`) rather than
//! raw table/row paths, so the worker provides the writable mapping seam here:
//! materialize effective library state from PostgreSQL into the session directory, then
//! sync agent-owned writable files back to PostgreSQL after worker file/command writes.

use std::collections::BTreeSet;
use std::path::{Component, Path, PathBuf};

use tokio_postgres::{Client, NoTls};
use uuid::Uuid;

use crate::error::AppResult;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum MountBackend {
  /// Plain host directory without DB sync. Only used when tests construct it directly.
  #[allow(dead_code)]
  Directory,
  /// PostgreSQL-backed BullX library mapping, shaped for `/workspace/library-containers`.
  TigerFs,
}

#[derive(Clone, Debug)]
pub struct TigerFs {
  backend: MountBackend,
  database_url: Option<String>,
}

impl TigerFs {
  #[allow(dead_code)]
  pub fn directory() -> Self {
    Self {
      backend: MountBackend::Directory,
      database_url: None,
    }
  }

  pub fn postgres(database_url: String) -> Self {
    Self {
      backend: MountBackend::TigerFs,
      database_url: Some(database_url),
    }
  }

  /// Ensure `library-containers` for an agent is present and materialized at `mountpoint`.
  pub async fn ensure_mounted(&self, mountpoint: &Path, agent_uid: &str) -> AppResult<()> {
    tokio::fs::create_dir_all(mountpoint).await?;
    if self.backend == MountBackend::TigerFs {
      self.export_agent_library(mountpoint, agent_uid).await?;
    }
    tracing::debug!(%agent_uid, backend = ?self.backend, mountpoint = %mountpoint.display(), "library-containers ready");
    Ok(())
  }

  /// Import agent-owned writable files from the mounted tree back to PostgreSQL.
  pub async fn sync_from_mount(&self, mountpoint: &Path, agent_uid: &str) -> AppResult<()> {
    if self.backend != MountBackend::TigerFs {
      return Ok(());
    }
    let Some(database_url) = &self.database_url else {
      return Ok(());
    };
    let client = connect(database_url).await?;
    let files = scan_agent_writable_files(mountpoint)?;
    let mut seen_appends = BTreeSet::new();

    for (virtual_path, content) in &files {
      let source_kind = if virtual_path == "SOUL.md" {
        "soul"
      } else if let Some(skill_name) = append_skill_name(virtual_path) {
        if !skill_exists(&client, skill_name).await? {
          tracing::warn!(%agent_uid, %virtual_path, "ignoring append for unknown skill");
          continue;
        }
        seen_appends.insert(virtual_path.clone());
        "skill_append"
      } else {
        continue;
      };
      upsert_agent_entry(&client, agent_uid, virtual_path, source_kind, content).await?;
    }

    for path in existing_append_paths(&client, agent_uid).await? {
      if !seen_appends.contains(&path) {
        client
          .execute(
            "update agent_library_container_entries set enabled = false, deleted_at = now(), updated_at = now() where agent_uid = $1 and virtual_path = $2 and deleted_at is null",
            &[&agent_uid, &path],
          )
          .await?;
      }
    }

    Ok(())
  }

  async fn export_agent_library(&self, mountpoint: &Path, agent_uid: &str) -> AppResult<()> {
    let Some(database_url) = &self.database_url else {
      return Ok(());
    };
    let client = connect(database_url).await?;

    if tokio::fs::try_exists(mountpoint).await? {
      tokio::fs::remove_dir_all(mountpoint).await?;
    }
    tokio::fs::create_dir_all(mountpoint).await?;

    let agent_rows = client
      .query(
        "select virtual_path, content_text from agent_library_container_entries where agent_uid = $1 and enabled = true and deleted_at is null and content_text is not null and (virtual_path = 'SOUL.md' or virtual_path like 'skills/%/AGENT_APPEND.md') order by virtual_path",
        &[&agent_uid],
      )
      .await?;
    for row in agent_rows {
      let virtual_path: String = row.get(0);
      let content: String = row.get(1);
      write_virtual_file(mountpoint, &virtual_path, &content).await?;
    }

    let skill_rows = client
      .query(
        "select s.name, f.virtual_path, f.content_text from library_skills s join library_skill_files f on f.skill_id = s.id left join agent_skill_assignments a on a.agent_uid = $1 and a.skill_id = s.id where s.enabled = true and s.archived_at is null and coalesce(a.enabled, s.default_enabled) = true order by s.name, f.virtual_path",
        &[&agent_uid],
      )
      .await?;
    for row in skill_rows {
      let skill_name: String = row.get(0);
      let file_path: String = row.get(1);
      let content: String = row.get(2);
      let virtual_path = format!("skills/{skill_name}/{file_path}");
      write_virtual_file(mountpoint, &virtual_path, &content).await?;
    }

    Ok(())
  }
}

async fn connect(database_url: &str) -> AppResult<Client> {
  let (client, connection) = tokio_postgres::connect(database_url, NoTls).await?;
  tokio::spawn(async move {
    if let Err(error) = connection.await {
      tracing::warn!(%error, "PostgreSQL connection task ended");
    }
  });
  Ok(client)
}

async fn skill_exists(client: &Client, skill_name: &str) -> AppResult<bool> {
  let row = client
    .query_opt(
      "select 1 from library_skills where name = $1 and enabled = true and archived_at is null limit 1",
      &[&skill_name],
    )
    .await?;
  Ok(row.is_some())
}

async fn upsert_agent_entry(
  client: &Client,
  agent_uid: &str,
  virtual_path: &str,
  source_kind: &str,
  content: &str,
) -> AppResult<()> {
  let id = Uuid::new_v4();
  let content_hash = blake3_hex(content.as_bytes());
  let media_type = media_type(virtual_path);
  // Mirrors the app-side upsert in app/src/ai-agent/library/service.ts
  // (upsertAgentTextEntry): same conflict target and version bump. Schema
  // changes must update both.
  client
    .execute(
      "insert into agent_library_container_entries (id, agent_uid, virtual_path, entry_kind, source_kind, source_ref, content_text, content_bytes, content_media_type, content_blake3, metadata, enabled, version, created_at, updated_at, deleted_at) values ($1, $2, $3, 'file', $4, '{}'::jsonb, $5, null, $6, $7, '{}'::jsonb, true, '1', now(), now(), null) on conflict (agent_uid, virtual_path) where deleted_at is null do update set source_kind = excluded.source_kind, content_text = excluded.content_text, content_bytes = null, content_media_type = excluded.content_media_type, content_blake3 = excluded.content_blake3, enabled = true, version = ((agent_library_container_entries.version)::int + 1)::text, deleted_at = null, updated_at = now()",
      &[&id, &agent_uid, &virtual_path, &source_kind, &content, &media_type, &content_hash],
    )
    .await?;
  Ok(())
}

async fn existing_append_paths(client: &Client, agent_uid: &str) -> AppResult<Vec<String>> {
  let rows = client
    .query(
      "select virtual_path from agent_library_container_entries where agent_uid = $1 and source_kind = 'skill_append' and deleted_at is null",
      &[&agent_uid],
    )
    .await?;
  Ok(rows.into_iter().map(|row| row.get(0)).collect())
}

fn scan_agent_writable_files(root: &Path) -> AppResult<Vec<(String, String)>> {
  let mut out = Vec::new();
  scan_dir(root, root, &mut out)?;
  Ok(out)
}

fn scan_dir(root: &Path, dir: &Path, out: &mut Vec<(String, String)>) -> AppResult<()> {
  if !dir.exists() {
    return Ok(());
  }
  for entry in std::fs::read_dir(dir)? {
    let entry = entry?;
    let path = entry.path();
    let file_type = entry.file_type()?;
    if file_type.is_dir() {
      scan_dir(root, &path, out)?;
      continue;
    }
    if !file_type.is_file() {
      continue;
    }
    let Some(virtual_path) = path.strip_prefix(root).ok().and_then(path_to_virtual) else {
      continue;
    };
    if virtual_path == "SOUL.md" || append_skill_name(&virtual_path).is_some() {
      let content = std::fs::read_to_string(&path)?;
      out.push((virtual_path, content));
    }
  }
  Ok(())
}

fn path_to_virtual(path: &Path) -> Option<String> {
  let mut parts = Vec::new();
  for component in path.components() {
    match component {
      Component::Normal(part) => parts.push(part.to_string_lossy().to_string()),
      Component::CurDir => {}
      Component::ParentDir | Component::RootDir | Component::Prefix(_) => return None,
    }
  }
  if parts.is_empty() {
    None
  } else {
    Some(parts.join("/"))
  }
}

fn append_skill_name(virtual_path: &str) -> Option<&str> {
  let parts: Vec<&str> = virtual_path.split('/').collect();
  if parts.len() == 3 && parts[0] == "skills" && parts[2] == "AGENT_APPEND.md" {
    Some(parts[1])
  } else {
    None
  }
}

async fn write_virtual_file(root: &Path, virtual_path: &str, content: &str) -> AppResult<()> {
  let path = resolve_virtual_path(root, virtual_path)?;
  if let Some(parent) = path.parent() {
    tokio::fs::create_dir_all(parent).await?;
  }
  tokio::fs::write(path, content).await?;
  Ok(())
}

fn resolve_virtual_path(root: &Path, virtual_path: &str) -> AppResult<PathBuf> {
  let mut out = root.to_path_buf();
  for part in virtual_path.split('/') {
    if part.is_empty() || part == "." || part == ".." {
      return Err(anyhow::anyhow!("invalid library virtual path: {virtual_path}").into());
    }
    out.push(part);
  }
  Ok(out)
}

fn blake3_hex(bytes: &[u8]) -> String {
  blake3::hash(bytes).to_hex().to_string()
}

fn media_type(path: &str) -> &'static str {
  if path.ends_with(".md") {
    "text/markdown"
  } else if path.ends_with(".json") {
    "application/json"
  } else if path.ends_with(".yaml") || path.ends_with(".yml") {
    "application/yaml"
  } else {
    "text/plain"
  }
}
