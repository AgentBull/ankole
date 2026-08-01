use std::fs::File;
use std::io::Read;
use std::path::Path;

use xxhash_rust::xxh3::{Xxh3, xxh3_128};

use crate::common::crypto::parse_hex_32;
use crate::common::{KernelError, KernelResult};

const FILE_HASH_BUFFER_BYTES: usize = 64 * 1024;

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
    let mut buffer = vec![0_u8; FILE_HASH_BUFFER_BYTES];

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
