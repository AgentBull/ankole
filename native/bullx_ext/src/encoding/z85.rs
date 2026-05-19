//! Z85 — ZeroMQ's base85 variant. Encodes 4-byte blocks of binary into 5
//! ASCII characters using a URL/JSON-safe alphabet. Inputs that aren't a
//! multiple of 4 bytes are rejected rather than padded.

use rustler::{NifResult, OwnedBinary, Term};

use crate::encoding::{binary_from_vec, decode_binary, decode_string, error};

#[rustler::nif(schedule = "DirtyCpu")]
pub fn z85_encode(input: Term<'_>) -> NifResult<String> {
  let input = decode_binary(input, "input")?;

  encode_z85(input.as_slice())
}

#[rustler::nif(schedule = "DirtyCpu")]
pub fn z85_decode(input: Term<'_>) -> NifResult<OwnedBinary> {
  let input = decode_string(input, "input")?;

  decode_z85(&input).and_then(binary_from_vec)
}

fn encode_z85(input: &[u8]) -> NifResult<String> {
  if input.len() % 4 != 0 {
    return Err(error("input length must be divisible by 4"));
  }

  Ok(z85::encode(input))
}

fn decode_z85(input: &str) -> NifResult<Vec<u8>> {
  z85::decode(input).map_err(|decode_error| error(decode_error.to_string()))
}

#[cfg(test)]
mod tests {
  use super::*;

  #[test]
  fn z85_round_trip_preserves_binary_payload() {
    let payload = b"bull";
    let encoded = encode_z85(payload).unwrap();
    let decoded = decode_z85(&encoded).unwrap();

    assert_eq!(decoded, payload);
  }

  #[test]
  fn z85_encode_rejects_non_aligned_lengths() {
    assert!(encode_z85(b"abc").is_err());
  }
}
