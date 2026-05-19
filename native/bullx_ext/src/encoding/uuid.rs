use rustler::{NifResult, Term};
use uuid::Uuid;

use crate::encoding::{decode_string, error};

const BASE36_DIGITS: &[u8; 36] = b"0123456789abcdefghijklmnopqrstuvwxyz";

#[rustler::nif]
pub fn uuid_shorten(uuid_v4: Term<'_>) -> NifResult<String> {
  let uuid_v4 = decode_string(uuid_v4, "uuid_v4")?;

  shorten_uuid_str(&uuid_v4)
}

#[rustler::nif]
pub fn gen_uuid() -> String {
  Uuid::new_v4().to_string()
}

#[rustler::nif]
pub fn gen_uuid_v7() -> String {
  Uuid::now_v7().to_string()
}

#[rustler::nif]
pub fn gen_base36_uuid() -> String {
  encode_base36(Uuid::new_v4().as_u128())
}

#[rustler::nif]
pub fn short_uuid_expand(short_uuid: Term<'_>) -> NifResult<String> {
  let short_uuid = decode_string(short_uuid, "short_uuid")?;

  expand_short_uuid_str(&short_uuid)
}

fn shorten_uuid_str(uuid_v4: &str) -> NifResult<String> {
  let uuid = Uuid::parse_str(uuid_v4).map_err(|parse_error| error(parse_error.to_string()))?;

  Ok(shorten_uuid(uuid))
}

fn shorten_uuid(uuid: Uuid) -> String {
  bs58::encode(uuid.as_bytes()).into_string()
}

fn expand_short_uuid_str(short_uuid: &str) -> NifResult<String> {
  let decoded = bs58::decode(short_uuid)
    .into_vec()
    .map_err(|decode_error| error(decode_error.to_string()))?;
  let uuid = Uuid::from_slice(&decoded).map_err(|parse_error| error(parse_error.to_string()))?;

  Ok(uuid.hyphenated().to_string())
}

fn encode_base36(mut value: u128) -> String {
  if value == 0 {
    return "0".to_owned();
  }

  // u128 in base 36 fits in 25 digits (log_36(2^128) ≈ 24.78).
  let mut buffer = [0_u8; 26];
  let mut cursor = buffer.len();

  while value > 0 {
    cursor -= 1;
    buffer[cursor] = BASE36_DIGITS[(value % 36) as usize];
    value /= 36;
  }

  std::str::from_utf8(&buffer[cursor..])
    .expect("known valid: base36 digit table is ASCII")
    .to_owned()
}

#[cfg(test)]
mod tests {
  use super::*;

  #[test]
  fn short_uuid_round_trip_restores_the_canonical_uuid() {
    let uuid = "550e8400-e29b-41d4-a716-446655440000";
    let short = shorten_uuid_str(uuid).unwrap();

    assert_eq!(expand_short_uuid_str(&short).unwrap(), uuid);
  }

  #[test]
  fn base36_encoder_uses_lowercase_digits() {
    assert_eq!(encode_base36(35), "z");
    assert_eq!(encode_base36(36), "10");
  }

  #[test]
  fn short_uuid_expand_rejects_invalid_payloads() {
    assert!(expand_short_uuid_str("not-valid$$").is_err());
  }
}
