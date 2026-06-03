use napi::bindgen_prelude::*;
use napi_derive::*;
use siphasher::sip::SipHasher24;
use std::convert::TryInto;

// siphash2_4(input, key, [hash])
// Calculate siphash2-4 hash of input
#[napi]
pub fn siphash24(input: Buffer, key: Buffer) -> Result<Buffer> {
  let key_slice: &[u8] = &key;
  let key_array: &[u8; 16] = key_slice.try_into().map_err(|_| {
    Error::new(
      Status::InvalidArg,
      "Key must be exactly 16 bytes long".to_string(),
    )
  })?;

  let input_slice: &[u8] = &input;

  // Use the one-shot hash method provided by SipHasher24
  let hasher = SipHasher24::new_with_key(key_array);
  let hash_value: u64 = hasher.hash(input_slice);

  // Convert u64 hash to Buffer (8 bytes, little-endian)
  let hash_bytes = hash_value.to_le_bytes();
  Ok(Buffer::from(hash_bytes.to_vec()))
}
