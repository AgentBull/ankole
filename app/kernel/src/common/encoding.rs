use base64_simd::URL_SAFE_NO_PAD;
use std::fs::File;
use std::io::Read;
use std::path::Path;
use xxhash_rust::xxh3::{Xxh3, xxh3_128};

use crate::common::crypto::parse_hex_32;
use crate::common::{KernelError, KernelResult};

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

/// Computes the non-cryptographic XXH3 128-bit observation fingerprint.
///
/// This is for change detection and file observations. It is intentionally not
/// a security digest or provenance checksum.
pub fn xxh3_128_hex(input: &[u8]) -> String {
    format!("{:032x}", xxh3_128(input))
}

/// Streams one file through XXH3 128-bit without materializing it in JS/Elixir.
pub fn xxh3_128_file_hex(path: &Path) -> KernelResult<String> {
    let mut file = File::open(path).map_err(|error| KernelError::new(error.to_string()))?;
    let mut hasher = Xxh3::new();
    let mut buffer = [0_u8; 1024 * 1024];

    loop {
        let read = file
            .read(&mut buffer)
            .map_err(|error| KernelError::new(error.to_string()))?;
        if read == 0 {
            break;
        }
        hasher.update(&buffer[..read]);
    }

    Ok(format!("{:032x}", hasher.digest128()))
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
