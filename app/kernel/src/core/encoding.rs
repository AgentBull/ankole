use base64_simd::URL_SAFE_NO_PAD;
use crc32fast::Hasher;

use crate::core::crypto::parse_hex_32;
use crate::core::{KernelError, KernelResult};

/// Converts Unicode text into a best-effort ASCII representation.
///
/// This is useful for stable slugs, search keys, and display fallbacks. It is not
/// reversible, so callers should not use it as a storage encoding.
pub fn any_ascii(input: &str) -> String {
    any_ascii::any_ascii(input)
}

/// Encodes bytes as Base58 for compact, human-copyable identifiers.
pub fn base58_encode(input: &[u8]) -> String {
    bs58::encode(input).into_string()
}

/// Decodes Base58 text back into bytes.
pub fn base58_decode(input: &str) -> KernelResult<Vec<u8>> {
    bs58::decode(input)
        .into_vec()
        .map_err(|error| KernelError::new(error.to_string()))
}

/// Encodes bytes with the URL-safe Base64 alphabet and no padding.
///
/// No padding is intentional: it keeps generated tokens short and avoids `=`
/// characters in places where callers often paste identifiers into URLs or config.
pub fn base64_url_safe_encode(input: &[u8]) -> String {
    URL_SAFE_NO_PAD.encode_to_string(input)
}

/// Decodes the padding-free URL-safe Base64 form used by kernel wire tokens.
pub fn base64_url_safe_decode(input: &str) -> KernelResult<Vec<u8>> {
    URL_SAFE_NO_PAD
        .decode_to_vec(input)
        .map_err(|error| KernelError::new(error.to_string()))
}

/// Hashes data with BLAKE3 and returns the digest in Base58 form.
///
/// When a salt is supplied it is treated as a 32-byte hex key, not arbitrary text.
/// Failing closed here avoids silently accepting weak or differently encoded keyed
/// hash material across runtimes.
pub fn bs58_hash(data: &[u8], salt: Option<&str>) -> KernelResult<String> {
    match salt {
        Some(salt) => {
            let key = parse_hex_32(salt, "salt")?;
            Ok(bs58::encode(blake3::keyed_hash(&key, data).as_bytes()).into_string())
        }
        None => Ok(bs58::encode(blake3::hash(data).as_bytes()).into_string()),
    }
}

/// Computes CRC32 over a byte slice, optionally continuing from a prior state.
///
/// The optional state keeps compatibility with callers that process a stream in
/// chunks but still want one final checksum value.
pub fn crc32(input: &[u8], initial_state: Option<u32>) -> u32 {
    let mut hasher = Hasher::new_with_initial(initial_state.unwrap_or(0));
    hasher.update(input);
    hasher.finalize()
}

/// Computes CRC32 and formats it as lowercase hexadecimal text.
pub fn crc32_hex(input: &[u8], initial_state: Option<u32>) -> String {
    let hash = crc32(input, initial_state);
    format!("{hash:x}")
}

/// Hashes data with BLAKE3 and returns the digest as lowercase hexadecimal text.
///
/// A supplied salt is a keyed-hash key and must be a 64-character hex string.
/// That keeps the JS and Elixir APIs aligned on one exact key representation.
pub fn generic_hash(data: &[u8], salt: Option<&str>) -> KernelResult<String> {
    match salt {
        Some(salt) => {
            let key = parse_hex_32(salt, "salt")?;
            Ok(blake3::keyed_hash(&key, data).to_hex().to_string())
        }
        None => Ok(blake3::hash(data).to_hex().to_string()),
    }
}
