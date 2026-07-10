use prost::Message;
use serde_json::Value;

use crate::common::{KernelError, KernelResult};

use super::{
    from_host_json::envelope_from_json, proto, to_host_json::envelope_to_json,
    validate::validate_envelope,
};

pub(crate) struct DecodedEnvelope {
    envelope: proto::Envelope,
}

impl DecodedEnvelope {
    pub(crate) fn host_json(&self) -> KernelResult<Value> {
        envelope_to_json(&self.envelope)
    }

    pub(crate) fn worker_lifecycle_id(&self) -> Option<&str> {
        match self.envelope.body.as_ref()? {
            proto::envelope::Body::WorkerReady(payload) => Some(payload.worker_id.as_str()),
            proto::envelope::Body::WorkerHeartbeat(payload) => Some(payload.worker_id.as_str()),
            proto::envelope::Body::WorkerCapacity(payload) => Some(payload.worker_id.as_str()),
            _body => None,
        }
    }
}

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
    decode_envelope_view(bytes)?.host_json()
}

pub(crate) fn decode_envelope_view(bytes: &[u8]) -> KernelResult<DecodedEnvelope> {
    let envelope = proto::Envelope::decode(bytes).map_err(|error| {
        KernelError::new(format!("failed to decode runtime fabric envelope: {error}"))
    })?;
    validate_envelope(&envelope)?;

    Ok(DecodedEnvelope { envelope })
}
