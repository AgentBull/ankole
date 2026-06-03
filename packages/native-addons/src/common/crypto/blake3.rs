use hex::{FromHex, ToHex};
use napi::bindgen_prelude::*;
use napi_derive::napi;

/// Computes a fixed-length fingerprint of a string.
/// Suitable for most use cases other than hashing passwords.
/// @param data Message String or Buffer to hash.
/// @param salt 32 bytes hex string. (string length must be 64)
/// @returns hex string
#[napi(ts_args_type = "data: string | Buffer, salt?: string")]
pub fn generic_hash(data: Either<String, Buffer>, salt: Either<String, ()>) -> Result<String> {
  match data {
    Either::A(s) => blake3_hash_str(s.as_bytes(), salt),
    Either::B(b) => blake3_hash_str(b.as_ref(), salt),
  }
}

#[napi(ts_args_type = "data: string | Buffer, salt?: string")]
pub fn bs58_hash(data: Either<String, Buffer>, salt: Either<String, ()>) -> Result<String> {
  match data {
    Either::A(s) => blake3_hash_bytes(s.as_bytes(), salt),
    Either::B(b) => blake3_hash_bytes(b.as_ref(), salt),
  }
}

fn blake3_hash_str(input: &[u8], salt: Either<String, ()>) -> Result<String> {
  match salt {
    Either::A(salt) => <[u8; blake3::KEY_LEN]>::from_hex(salt)
      .map(|key| blake3::keyed_hash(&key, input).to_hex().to_string())
      .map_err(|e| Error::new(Status::GenericFailure, format!("Error salt: {}", e))),
    Either::B(_) => Ok(blake3::hash(input).to_string()),
  }
}

fn blake3_hash_bytes(input: &[u8], salt: Either<String, ()>) -> Result<String> {
  match salt {
    Either::A(salt) => <[u8; blake3::KEY_LEN]>::from_hex(salt)
      .map(|key| bs58::encode(blake3::keyed_hash(&key, input).as_bytes()).into_string())
      .map_err(|e| Error::new(Status::GenericFailure, format!("Error salt: {}", e))),
    Either::B(_) => Ok(bs58::encode(blake3::hash(input).as_bytes()).into_string()),
  }
}

/// Derive a new key from a master key.
/// @param keySeed - master key
/// @param subKeyId - sub key id (used verbatim, case-sensitive)
/// @param context - It don't have to be secret and can have a low entropy
#[napi(ts_args_type = "keySeed: string | Buffer, subKeyId: string, context?: string")]
pub fn derive_key(
  key_seed: Either<String, Buffer>,
  sub_key_id: String,
  extra_context: Either<String, ()>,
) -> String {
  let ctx = gen_context(&sub_key_id, extra_context);
  let seed = match key_seed {
    Either::A(s) => s.as_bytes().to_vec(),
    Either::B(b) => b.to_vec(),
  };
  blake3::derive_key(&ctx, &seed).encode_hex()
}

/// Generate context for key derivation.
/// `sub_key_id` is used verbatim and remains case-sensitive.
fn gen_context(sub_key_id: &str, context: Either<String, ()>) -> String {
  let sub_key = format!("[subKeyId={sub_key_id}]");
  match context {
    Either::A(c) => format!("{sub_key} [extra={c}]"),
    Either::B(_) => sub_key,
  }
}

/// Generate a new master key.
/// @returns hex encoded string
#[napi]
pub fn generate_key() -> String {
  let seed = rand::random::<[u8; blake3::KEY_LEN]>();
  blake3::derive_key("[extra=generateKey()]", &seed).encode_hex()
}
