use chacha20poly1305::aead::{Aead, KeyInit};
use chacha20poly1305::{Key, XChaCha20Poly1305, XNonce};
use hex::{FromHex, ToHex};

use crate::common::{KernelError, KernelResult, base64_url_safe_decode, base64_url_safe_encode};

const AEAD_KEY_LEN: usize = 32;
const AEAD_NONCE_LEN: usize = 24;
const AEAD_SEPARATOR: &str = ".";
const GENERATE_KEY_CONTEXT: &str = "[extra=generateKey()]";

/// Encrypts a binary payload with XChaCha20-Poly1305.
///
/// The returned token is `<base64url(nonce)>.<base64url(ciphertext)>` without
/// padding. That shape stays compact and can pass through URLs, environment
/// variables, JS strings, and Elixir strings without extra escaping.
pub fn aead_encrypt(plaintext: &[u8], key: &str) -> KernelResult<String> {
    let key = parse_hex_32(key, "key")?;
    let nonce = rand::random::<[u8; AEAD_NONCE_LEN]>();
    let cipher = XChaCha20Poly1305::new(Key::from_slice(&key));
    let ciphertext = cipher
        .encrypt(XNonce::from_slice(&nonce), plaintext)
        .map_err(|error| KernelError::new(format!("encryption failed: {error}")))?;

    Ok(format!(
        "{}{}{}",
        base64_url_safe_encode(&nonce),
        AEAD_SEPARATOR,
        base64_url_safe_encode(&ciphertext)
    ))
}

/// Decrypts the compact AEAD token produced by [`aead_encrypt`].
///
/// The function validates the token shape before calling the cipher. That gives
/// callers a useful format error when the token was truncated, copied with the
/// wrong separator, or encoded with the wrong base64 variant.
pub fn aead_decrypt(ciphertext: &str, key: &str) -> KernelResult<Vec<u8>> {
    let key = parse_hex_32(key, "key")?;
    let (nonce, ciphertext) = split_aead_ciphertext(ciphertext)?;
    let nonce = parse_nonce(&nonce)?;
    let cipher = XChaCha20Poly1305::new(Key::from_slice(&key));

    cipher
        .decrypt(XNonce::from_slice(&nonce), ciphertext.as_slice())
        .map_err(|error| KernelError::new(format!("decryption failed: {error}")))
}

/// Derives a deterministic 32-byte sub-key from a seed and labeled context.
///
/// BLAKE3 derives keys from a context string. The explicit `subKeyId` and
/// `extra` labels make collisions less likely when different host runtimes add
/// new derivation sites over time.
pub fn derive_key(key_seed: &[u8], sub_key_id: &str, extra_context: Option<&str>) -> String {
    let context = derive_key_context(sub_key_id, extra_context);
    blake3::derive_key(&context, key_seed).encode_hex()
}

/// Generates a random 32-byte hex key for kernel cryptographic helpers.
///
/// The random seed is passed through a dedicated BLAKE3 derivation context so this
/// API does not share a context string with application-level `derive_key` calls.
pub fn generate_key() -> String {
    let seed = rand::random::<[u8; blake3::KEY_LEN]>();
    blake3::derive_key(GENERATE_KEY_CONTEXT, &seed).encode_hex()
}

/// Parses a host-supplied 32-byte key encoded as 64 lowercase or uppercase hex chars.
///
/// AEAD and BLAKE3 keyed hashing both require exactly 32 bytes. Checking length
/// before decoding produces clearer errors and prevents accidentally accepting
/// shortened key material.
pub(crate) fn parse_hex_32(input: &str, label: &str) -> KernelResult<[u8; 32]> {
    if input.len() != AEAD_KEY_LEN * 2 {
        return Err(KernelError::new(format!(
            "{label} must be a 64-character hex string"
        )));
    }

    <[u8; 32]>::from_hex(input)
        .map_err(|error| KernelError::new(format!("invalid {label}: {error}")))
}

/// Builds the BLAKE3 context string used for deterministic sub-key derivation.
///
/// The square-bracket labels are part of the contract. They separate values by
/// role instead of relying on positional concatenation, which is easier to break
/// when new optional context is added later.
fn derive_key_context(sub_key_id: &str, extra_context: Option<&str>) -> String {
    let sub_key = format!("[subKeyId={sub_key_id}]");

    match extra_context {
        Some(context) => format!("{sub_key} [extra={context}]"),
        None => sub_key,
    }
}

/// Converts the decoded nonce into the exact XChaCha20-Poly1305 nonce length.
fn parse_nonce(nonce: &[u8]) -> KernelResult<[u8; AEAD_NONCE_LEN]> {
    nonce
        .try_into()
        .map_err(|_| KernelError::new("nonce must decode to 24 bytes"))
}

/// Splits and decodes the kernel AEAD token format.
///
/// The parser requires exactly two non-empty segments. Base64url never emits `.`,
/// so the dot separator is safe and malformed extra segments are rejected instead
/// of being silently joined.
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
