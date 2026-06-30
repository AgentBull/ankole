use prost::Message;
use serde_json::Value;

use crate::common::{KernelError, KernelResult};

use super::{
    decode::envelope_from_json, encode::envelope_to_json, proto, validate::validate_envelope,
};

/// Encodes a JSON-shaped Runtime Fabric envelope as protobuf bytes.
///
/// Hosts use JSON maps because both Elixir and Bun can build them cheaply. The
/// kernel still owns protobuf encoding and semantic validation so all hosts see
/// the same protocol errors.
pub fn encode_envelope(envelope: Value) -> KernelResult<Vec<u8>> {
    let envelope = envelope_from_json(&envelope)?;
    validate_envelope(&envelope)?;

    let mut bytes = Vec::with_capacity(envelope.encoded_len());
    envelope.encode(&mut bytes).map_err(|error| {
        KernelError::new(format!("failed to encode runtime fabric envelope: {error}"))
    })?;

    Ok(bytes)
}

/// Decodes protobuf bytes into the stable JSON-shaped host representation.
///
/// The returned JSON shape matches the control-plane envelope contract, not the
/// generated prost structs. That keeps native bindings thin and avoids leaking
/// Rust-specific protobuf details into Elixir or Bun code.
pub fn decode_envelope(bytes: &[u8]) -> KernelResult<Value> {
    let envelope = proto::Envelope::decode(bytes).map_err(|error| {
        KernelError::new(format!("failed to decode runtime fabric envelope: {error}"))
    })?;
    validate_envelope(&envelope)?;

    envelope_to_json(&envelope)
}
