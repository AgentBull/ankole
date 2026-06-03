use crc32fast::Hasher;
use napi::bindgen_prelude::*;
use napi_derive::*;

// Calculate CRC32 hash of input, output is a decimal number
#[napi]
pub fn crc32(input: Either<&[u8], String>, initial_state: Option<u32>) -> u32 {
  let mut hasher = Hasher::new_with_initial(initial_state.unwrap_or(0));
  hasher.update(input.as_ref());
  hasher.finalize()
}

// Calculate CRC32 hash of input, output is a hex string
#[napi]
pub fn crc32_hex(input: Either<&[u8], String>, initial_state: Option<u32>) -> String {
  let hash = crc32(input, initial_state);
  format!("{:x}", hash)
}
