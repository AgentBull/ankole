//! Worker Git SSH identity provisioning.
//!
//! The BullX app owns key generation and stores a sealed OpenSSH identity in
//! app_configure. Workers unseal it with BULLX_COMPUTER_TOKEN, write it under
//! /etc, and expose it read-only to sandboxed commands through the existing
//! system-directory bind mounts.

use std::path::{Path, PathBuf};

use anyhow::{Context, Result};
use base64::Engine;
use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use chacha20poly1305::aead::{Aead, KeyInit};
use chacha20poly1305::{Key, XChaCha20Poly1305, XNonce};
use serde::Deserialize;
use tokio_postgres::NoTls;

const COMPUTER_GIT_SSH_IDENTITY_KEY: &str = "computer.git_ssh_identity.v1";
const KDF_CONTEXT: &str = "[subKeyId=computer_git_ssh_identity] [extra=v1]";
const DEFAULT_SSH_DIR: &str = "/etc/bullx-computer/ssh";
const DEFAULT_SSH_CONFIG: &str = "/etc/ssh/ssh_config.d/bullx-computer-github.conf";

#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct ComputerGitSshIdentity {
  private_key_open_ssh: String,
  public_key_open_ssh: String,
}

#[derive(Deserialize)]
struct StoredEnvelope {
  #[serde(rename = "type")]
  value_type: String,
  value: SealedIdentity,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct SealedIdentity {
  version: u8,
  public_key_open_ssh: String,
  sealed: String,
}

pub async fn provision_if_available(database_url: &str, computer_token: &str) -> Result<bool> {
  let Some(identity) = load_identity(database_url, computer_token).await? else {
    tracing::warn!(
      key = COMPUTER_GIT_SSH_IDENTITY_KEY,
      "computer Git SSH identity is missing; worker will start without GitHub SSH identity"
    );
    return Ok(false);
  };
  write_identity(&identity).await?;
  Ok(true)
}

async fn load_identity(
  database_url: &str,
  computer_token: &str,
) -> Result<Option<ComputerGitSshIdentity>> {
  let (client, connection) = tokio_postgres::connect(database_url, NoTls)
    .await
    .context("connect PostgreSQL for computer Git SSH identity")?;
  tokio::spawn(async move {
    if let Err(error) = connection.await {
      tracing::warn!(%error, "PostgreSQL Git SSH identity connection task ended");
    }
  });
  let Some(row) = client
    .query_opt(
      "select value from app_configure where key = $1 limit 1",
      &[&COMPUTER_GIT_SSH_IDENTITY_KEY],
    )
    .await
    .context("read computer Git SSH identity from app_configure")?
  else {
    return Ok(None);
  };

  let envelope: serde_json::Value = row.get(0);
  let envelope: StoredEnvelope =
    serde_json::from_value(envelope).context("decode computer Git SSH app-config envelope")?;
  anyhow::ensure!(
    envelope.value_type == "plaintext",
    "computer Git SSH identity must be stored as plaintext sealed envelope"
  );
  anyhow::ensure!(
    envelope.value.version == 1,
    "unsupported computer Git SSH identity version"
  );

  let plain = decrypt_identity(&envelope.value.sealed, computer_token)?;
  let identity: ComputerGitSshIdentity =
    serde_json::from_slice(&plain).context("decode unsealed computer Git SSH identity")?;
  anyhow::ensure!(
    identity.public_key_open_ssh == envelope.value.public_key_open_ssh,
    "computer Git SSH identity public key mismatch"
  );
  Ok(Some(identity))
}

async fn write_identity(identity: &ComputerGitSshIdentity) -> Result<()> {
  let ssh_dir = env_path("BULLX_COMPUTER_GIT_SSH_DIR", DEFAULT_SSH_DIR);
  let private_key_path = ssh_dir.join("id_ed25519");
  let public_key_path = ssh_dir.join("id_ed25519.pub");
  let config_path = env_path("BULLX_COMPUTER_GIT_SSH_CONFIG", DEFAULT_SSH_CONFIG);

  tokio::fs::create_dir_all(&ssh_dir)
    .await
    .with_context(|| format!("create Git SSH identity dir {}", ssh_dir.display()))?;
  write_file(&private_key_path, &identity.private_key_open_ssh, 0o600).await?;
  write_file(&public_key_path, &identity.public_key_open_ssh, 0o644).await?;

  if let Some(parent) = config_path.parent() {
    tokio::fs::create_dir_all(parent)
      .await
      .with_context(|| format!("create SSH config dir {}", parent.display()))?;
  }
  write_file(&config_path, &ssh_config(&private_key_path), 0o644).await?;

  tracing::info!(
    private_key = %private_key_path.display(),
    public_key = %public_key_path.display(),
    ssh_config = %config_path.display(),
    "computer Git SSH identity provisioned"
  );
  Ok(())
}

async fn write_file(path: &Path, content: &str, mode: u32) -> Result<()> {
  tokio::fs::write(path, content)
    .await
    .with_context(|| format!("write {}", path.display()))?;
  set_mode(path, mode).await?;
  Ok(())
}

#[cfg(unix)]
async fn set_mode(path: &Path, mode: u32) -> Result<()> {
  use std::os::unix::fs::PermissionsExt;

  let permissions = std::fs::Permissions::from_mode(mode);
  tokio::fs::set_permissions(path, permissions)
    .await
    .with_context(|| format!("chmod {:o} {}", mode, path.display()))
}

#[cfg(not(unix))]
async fn set_mode(_path: &Path, _mode: u32) -> Result<()> {
  Ok(())
}

fn ssh_config(private_key_path: &Path) -> String {
  let mut lines = vec![
    "Host github.com".to_string(),
    format!("  IdentityFile {}", private_key_path.display()),
    "  IdentitiesOnly yes".to_string(),
    "  StrictHostKeyChecking accept-new".to_string(),
  ];
  if env_bool("BULLX_COMPUTER_GITHUB_SSH_OVER_HTTPS") {
    lines.push("  HostName ssh.github.com".to_string());
    lines.push("  Port 443".to_string());
  }
  lines.push(String::new());
  lines.join("\n")
}

fn env_path(key: &str, default: &str) -> PathBuf {
  std::env::var(key)
    .ok()
    .filter(|value| !value.trim().is_empty())
    .map(PathBuf::from)
    .unwrap_or_else(|| PathBuf::from(default))
}

fn env_bool(key: &str) -> bool {
  matches!(
    std::env::var(key)
      .ok()
      .map(|value| value.trim().to_ascii_lowercase()),
    Some(value) if matches!(value.as_str(), "1" | "true" | "yes" | "on")
  )
}

fn decrypt_identity(sealed: &str, token: &str) -> Result<Vec<u8>> {
  let (nonce, ciphertext) = sealed
    .split_once('.')
    .context("invalid sealed computer Git SSH identity")?;
  let nonce = URL_SAFE_NO_PAD
    .decode(nonce)
    .context("decode computer Git SSH identity nonce")?;
  let ciphertext = URL_SAFE_NO_PAD
    .decode(ciphertext)
    .context("decode computer Git SSH identity ciphertext")?;
  let key = blake3::derive_key(KDF_CONTEXT, token.as_bytes());
  let aead = XChaCha20Poly1305::new(Key::from_slice(&key));
  aead
    .decrypt(XNonce::from_slice(&nonce), ciphertext.as_ref())
    .map_err(|error| anyhow::anyhow!("decrypt computer Git SSH identity: {error}"))
}
