//! AEAD (Authenticated Encryption with Associated Data) using
//! XChaCha20-Poly1305. The 24-byte extended nonce is wide enough to be
//! randomly generated per call without birthday-bound concerns on a
//! long-lived key.

use chacha20poly1305::aead::{Aead, KeyInit};
use chacha20poly1305::{Key, XChaCha20Poly1305, XNonce};
use hex::FromHex;
use rand::rngs::SysRng;
use rand::{RngExt, SeedableRng};
use rustler::{NifResult, OwnedBinary, Term};

use crate::encoding::base64::{url_safe_decode, url_safe_encode};
use crate::encoding::{binary_from_vec, decode_binary, decode_string, error};

const KEY_LEN: usize = 32;
const NONCE_LEN: usize = 24;

/// Encrypt with XChaCha20-Poly1305 using a fresh random 24-byte nonce.
///
/// Output format is `"<base64url(nonce)>.<base64url(ciphertext)>"` so the
/// nonce travels alongside the ciphertext as a single string.
#[rustler::nif(schedule = "DirtyCpu")]
pub fn aead_encrypt(plaintext: Term<'_>, key: Term<'_>) -> NifResult<String> {
  let plaintext = decode_binary(plaintext, "plaintext")?;
  let key = decode_string(key, "key")?;

  encrypt_payload(plaintext.as_slice(), &key).map_err(error)
}

#[rustler::nif(schedule = "DirtyCpu")]
pub fn aead_decrypt(ciphertext: Term<'_>, key: Term<'_>) -> NifResult<OwnedBinary> {
  let ciphertext = decode_string(ciphertext, "ciphertext")?;
  let key = decode_string(key, "key")?;

  decrypt_payload(&ciphertext, &key)
    .map_err(error)
    .and_then(binary_from_vec)
}

fn encrypt_payload(plaintext: &[u8], key: &str) -> Result<String, String> {
  let key = parse_key(key)?;
  let nonce = generate_nonce()?;
  let cipher = XChaCha20Poly1305::new(Key::from_slice(&key));
  let ciphertext = cipher
    .encrypt(XNonce::from_slice(&nonce), plaintext)
    .map_err(|_| "encryption failed".to_owned())?;

  Ok(format!(
    "{}.{}",
    url_safe_encode(&nonce),
    url_safe_encode(&ciphertext)
  ))
}

fn decrypt_payload(sealed: &str, key: &str) -> Result<Vec<u8>, String> {
  let key = parse_key(key)?;
  let (nonce, ciphertext) = split_ciphertext(sealed)?;
  let nonce = parse_nonce(&nonce)?;
  let cipher = XChaCha20Poly1305::new(Key::from_slice(&key));

  cipher
    .decrypt(XNonce::from_slice(&nonce), ciphertext.as_slice())
    .map_err(|_| "decryption failed".to_owned())
}

fn parse_key(key: &str) -> Result<[u8; KEY_LEN], String> {
  if key.len() != KEY_LEN * 2 {
    return Err("key must be a 64-character hex string".to_owned());
  }

  <[u8; KEY_LEN]>::from_hex(key).map_err(|error| format!("invalid key: {error}"))
}

fn generate_nonce() -> Result<[u8; NONCE_LEN], String> {
  let mut sys_rng = SysRng;

  rand_chacha::ChaCha12Rng::try_from_rng(&mut sys_rng)
    .map_err(|error| format!("failed to initialize rng: {error}"))
    .map(|mut rng| rng.random::<[u8; NONCE_LEN]>())
}

fn split_ciphertext(sealed: &str) -> Result<(Vec<u8>, Vec<u8>), String> {
  let mut parts = sealed.split('.');

  match (parts.next(), parts.next(), parts.next()) {
    (Some(nonce), Some(ciphertext), None) if !nonce.is_empty() && !ciphertext.is_empty() => {
      let nonce = url_safe_decode(nonce).map_err(|_| "invalid nonce base64url".to_owned())?;
      let ciphertext =
        url_safe_decode(ciphertext).map_err(|_| "invalid ciphertext base64url".to_owned())?;

      Ok((nonce, ciphertext))
    }
    _ => Err("ciphertext must be '<base64url(nonce)>.<base64url(ciphertext)>'".to_owned()),
  }
}

fn parse_nonce(nonce: &[u8]) -> Result<[u8; NONCE_LEN], String> {
  nonce
    .try_into()
    .map_err(|_| "nonce must decode to 24 bytes".to_owned())
}

#[cfg(test)]
mod tests {
  use super::*;

  const KEY: &str = "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f";
  const WRONG_KEY: &str = "1f1e1d1c1b1a191817161514131211100f0e0d0c0b0a09080706050403020100";

  #[test]
  fn payload_round_trip_preserves_binary() {
    let plaintext = b"api-key-\0-with-bytes";
    let encrypted = encrypt_payload(plaintext, KEY).unwrap();

    assert_eq!(decrypt_payload(&encrypted, KEY).unwrap(), plaintext);
  }

  #[test]
  fn encrypting_same_plaintext_uses_fresh_nonce() {
    let left = encrypt_payload(b"same plaintext", KEY).unwrap();
    let right = encrypt_payload(b"same plaintext", KEY).unwrap();

    assert_ne!(left, right);
  }

  #[test]
  fn wrong_key_fails_authentication() {
    let encrypted = encrypt_payload(b"secret", KEY).unwrap();

    assert_eq!(
      decrypt_payload(&encrypted, WRONG_KEY),
      Err("decryption failed".to_owned())
    );
  }

  #[test]
  fn malformed_ciphertext_is_rejected() {
    assert!(decrypt_payload("not-a-valid-payload", KEY).is_err());
    assert!(decrypt_payload("a.b.c", KEY).is_err());
  }
}
