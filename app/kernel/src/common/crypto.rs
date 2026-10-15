use chacha20poly1305::aead::{Aead, KeyInit};
use chacha20poly1305::{Key, XChaCha20Poly1305, XNonce};
use hex::{FromHex, ToHex};

use crate::common::{KernelError, KernelResult, base64_url_safe_decode, base64_url_safe_encode};

const AEAD_KEY_LEN: usize = 32;
const AEAD_NONCE_LEN: usize = 24;
const AEAD_SEPARATOR: &str = ".";
const GENERATE_KEY_CONTEXT: &str = "[extra=generateKey()]";

/// The token passes through URLs and host strings without extra escaping.
pub fn aead_encrypt(plaintext: &[u8], key: &str) -> KernelResult<String> {
    let key = parse_hex_32(key, "key")?;
    let nonce = rand::random::<[u8; AEAD_NONCE_LEN]>();
    let cipher = XChaCha20Poly1305::new(&Key::from(key));
    let ciphertext = cipher
        .encrypt(&XNonce::from(nonce), plaintext)
        .map_err(|error| KernelError::new(format!("encryption failed: {error}")))?;

    Ok(format!(
        "{}{}{}",
        base64_url_safe_encode(&nonce),
        AEAD_SEPARATOR,
        base64_url_safe_encode(&ciphertext)
    ))
}

pub fn aead_decrypt(ciphertext: &str, key: &str) -> KernelResult<Vec<u8>> {
    let key = parse_hex_32(key, "key")?;
    let (nonce, ciphertext) = split_aead_ciphertext(ciphertext)?;
    let nonce = parse_nonce(&nonce)?;
    let cipher = XChaCha20Poly1305::new(&Key::from(key));

    cipher
        .decrypt(&XNonce::from(nonce), ciphertext.as_slice())
        .map_err(|error| KernelError::new(format!("decryption failed: {error}")))
}

/// The `subKeyId` and `extra` labels keep derivation sites from colliding across host runtimes.
pub fn derive_key(key_seed: &[u8], sub_key_id: &str, extra_context: Option<&str>) -> String {
    let context = derive_key_context(sub_key_id, extra_context);
    blake3::derive_key(&context, key_seed).encode_hex()
}

/// Uses a BLAKE3 context that `derive_key` does not share.
pub fn generate_key() -> String {
    let seed = rand::random::<[u8; blake3::KEY_LEN]>();
    blake3::derive_key(GENERATE_KEY_CONTEXT, &seed).encode_hex()
}

/// AEAD and keyed BLAKE3 both require 32 bytes.
pub(crate) fn parse_hex_32(input: &str, label: &str) -> KernelResult<[u8; 32]> {
    if input.len() != AEAD_KEY_LEN * 2 {
        return Err(KernelError::new(format!(
            "{label} must be a 64-character hex string"
        )));
    }

    <[u8; 32]>::from_hex(input)
        .map_err(|error| KernelError::new(format!("invalid {label}: {error}")))
}

/// The square-bracket labels are the derivation contract.
fn derive_key_context(sub_key_id: &str, extra_context: Option<&str>) -> String {
    let sub_key = format!("[subKeyId={sub_key_id}]");

    match extra_context {
        Some(context) => format!("{sub_key} [extra={context}]"),
        None => sub_key,
    }
}

fn parse_nonce(nonce: &[u8]) -> KernelResult<[u8; AEAD_NONCE_LEN]> {
    nonce
        .try_into()
        .map_err(|_| KernelError::new("nonce must decode to 24 bytes"))
}

/// Base64url never emits `.`, so a third segment is rejected instead of joined.
fn split_aead_ciphertext(sealed: &str) -> KernelResult<(Vec<u8>, Vec<u8>)> {
    let mut parts = sealed.split(AEAD_SEPARATOR);

    match (parts.next(), parts.next(), parts.next()) {
        (Some(nonce), Some(ciphertext), None) if !nonce.is_empty() && !ciphertext.is_empty() => {
            let nonce = base64_url_safe_decode(nonce)
                .map_err(|error| KernelError::new(format!("invalid nonce base64url: {error}")))?;
            let ciphertext = base64_url_safe_decode(ciphertext).map_err(|error| {
                KernelError::new(format!("invalid ciphertext base64url: {error}"))
            })?;

            Ok((nonce, ciphertext))
        }
        _ => Err(KernelError::new(
            "ciphertext must be '<base64url(nonce)>.<base64url(ciphertext)>'",
        )),
    }
}
