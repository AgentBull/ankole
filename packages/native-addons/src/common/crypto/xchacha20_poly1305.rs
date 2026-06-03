use crate::common::encoding::base64;
use chacha20poly1305::aead::{Aead, KeyInit};
use chacha20poly1305::{Key, XChaCha20Poly1305, XNonce};
use hex::FromHex;
use napi::bindgen_prelude::*;
use napi_derive::napi;

/// Char `.` not included in base64 url safe alphabet.
/// So it is safe to use it as a separator.
const B58_SAFE_SEPARATOR: &str = ".";

fn xchacha20_cipher(key: String) -> Result<XChaCha20Poly1305> {
  let key_bytes = <[u8; 32]>::from_hex(key)
    .map_err(|e| Error::new(Status::InvalidArg, format!("Invalid key: {e}")))?;

  Ok(XChaCha20Poly1305::new(Key::from_slice(&key_bytes)))
}

/// Encrypts a message using XChaCha20-Poly1305-IETF
/// @param plain - plaintext
/// @param key - 32bytes encryption key
/// @returns ciphertext - base64 url-safe encoded ciphertext with nonce
#[napi]
pub fn aead_encrypt(plain: Either<String, Buffer>, key: String) -> Result<String> {
  let nonce_bytes = rand::random::<[u8; 24]>();
  let nonce = XNonce::from_slice(&nonce_bytes);
  let plain_buf = match plain {
    Either::A(s) => s.as_bytes().to_vec(),
    Either::B(b) => b.to_vec(),
  };
  let encrypted = xchacha20_cipher(key)?
    .encrypt(nonce, &plain_buf[..])
    .map_err(|e| Error::new(Status::GenericFailure, format!("Error encrypt: {e}")))?;

  let cipher = base64::url_safe_encode(encrypted.as_ref());
  let nonce_str = base64::url_safe_encode(nonce);
  Ok(format!("{}{}{}", nonce_str, B58_SAFE_SEPARATOR, cipher))
}

/// Decrypts a message using XChaCha20-Poly1305-IETF
/// @param cipher - base64 url-safe encoded ciphertext with nonce
/// @param key - 32bytes encryption key
/// @returns plaintext buffer
#[napi]
pub fn aead_decrypt(cipher: String, key: String) -> Result<Buffer> {
  let cipher_parts: Vec<&str> = cipher.split(B58_SAFE_SEPARATOR).collect();
  if cipher_parts.len() != 2 {
    return Err(Error::new(
      Status::InvalidArg,
      "Invalid ciphertext".to_string(),
    ));
  };
  let nonce = base64::url_safe_decode(&cipher_parts[0].to_string())
    .map_err(|e| Error::new(Status::InvalidArg, format!("Invalid nonce in input: {e}")))?;
  let cipher = base64::url_safe_decode(&cipher_parts[1].to_string()).map_err(|e| {
    Error::new(
      Status::InvalidArg,
      format!("Invalid ciphertext in input: {e}"),
    )
  })?;
  let decrypted = xchacha20_cipher(key)?
    .decrypt(XNonce::from_slice(&nonce), cipher.as_ref())
    .map_err(|e| Error::new(Status::GenericFailure, format!("Error decrypt: {e}")))?;
  Ok(Buffer::from(decrypted))
}
