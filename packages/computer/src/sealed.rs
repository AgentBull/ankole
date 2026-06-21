//! Worker-side decryption of secrets the BullX app sealed for it.
//!
//! The app encrypts things like the computer TLS bundle and the Git SSH identity and
//! stores them in PostgreSQL; the worker holds only `BULLX_COMPUTER_TOKEN` (the key
//! seed) and unseals them here, without needing the app's full `BULLX_SECRET_BASE`.
//! The scheme is XChaCha20-Poly1305 over a per-purpose key that BLAKE3 derives from the
//! seed. This must stay byte-compatible with the app's sealing side — the KDF context,
//! the `nonce.ciphertext` wire shape, and the AEAD choice are a shared contract, not
//! local implementation detail.

use anyhow::{Context, Result};
use base64::Engine;
use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use chacha20poly1305::aead::{Aead, KeyInit};
use chacha20poly1305::{Key, XChaCha20Poly1305, XNonce};

/// Decrypt one sealed value.
///
/// `sealed` is the `base64url(nonce).base64url(ciphertext)` envelope. `key_seed` is the
/// shared token; `sub_key_id` (plus optional `context`) namespaces the derived key so
/// each kind of secret gets a distinct key from the same seed. `label` only flavors
/// error messages. Authentication is built in: a wrong key or tampered ciphertext fails
/// the Poly1305 tag and returns an error rather than garbage plaintext.
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
  // XChaCha20 takes a 192-bit (24-byte) nonce; reject anything else before handing it
  // to the cipher, which would otherwise panic on a wrong-sized slice.
  anyhow::ensure!(nonce.len() == 24, "{label} nonce must be 24 bytes");

  // Derive the actual cipher key from the seed and a domain-separation string, so two
  // secrets sealed under the same token never share a key.
  let key = blake3::derive_key(&kdf_context(sub_key_id, context), key_seed.as_bytes());
  let aead = XChaCha20Poly1305::new(Key::from_slice(&key));
  aead
    .decrypt(XNonce::from_slice(&nonce), ciphertext.as_ref())
    .map_err(|error| anyhow::anyhow!("decrypt {label}: {error}"))
}

/// Build the BLAKE3 derivation context string. The exact format
/// (`[subKeyId=...] [extra=...]`) is part of the cross-language contract with the app's
/// sealer; changing it would silently break decryption of already-stored secrets.
fn kdf_context(sub_key_id: &str, context: Option<&str>) -> String {
  let sub_key = format!("[subKeyId={sub_key_id}]");
  match context {
    Some(context) => format!("{sub_key} [extra={context}]"),
    None => sub_key,
  }
}
