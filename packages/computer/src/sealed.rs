use anyhow::{Context, Result};
use base64::Engine;
use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use chacha20poly1305::aead::{Aead, KeyInit};
use chacha20poly1305::{Key, XChaCha20Poly1305, XNonce};

pub fn unseal(
  sealed: &str,
  key_seed: &str,
  sub_key_id: &str,
  context: Option<&str>,
  label: &str,
) -> Result<Vec<u8>> {
  let (nonce, ciphertext) = sealed
    .split_once('.')
    .with_context(|| format!("invalid sealed {label}"))?;
  let nonce = URL_SAFE_NO_PAD
    .decode(nonce)
    .with_context(|| format!("decode {label} nonce"))?;
  let ciphertext = URL_SAFE_NO_PAD
    .decode(ciphertext)
    .with_context(|| format!("decode {label} ciphertext"))?;
  anyhow::ensure!(nonce.len() == 24, "{label} nonce must be 24 bytes");

  let key = blake3::derive_key(&kdf_context(sub_key_id, context), key_seed.as_bytes());
  let aead = XChaCha20Poly1305::new(Key::from_slice(&key));
  aead
    .decrypt(XNonce::from_slice(&nonce), ciphertext.as_ref())
    .map_err(|error| anyhow::anyhow!("decrypt {label}: {error}"))
}

fn kdf_context(sub_key_id: &str, context: Option<&str>) -> String {
  let sub_key = format!("[subKeyId={sub_key_id}]");
  match context {
    Some(context) => format!("{sub_key} [extra={context}]"),
    None => sub_key,
  }
}
