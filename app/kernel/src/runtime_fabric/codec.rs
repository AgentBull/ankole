use prost::Message;

use crate::common::{KernelError, KernelResult};

use super::{proto, validate::validate_envelope};

pub(crate) struct DecodedEnvelope {
    envelope: proto::Envelope,
}

impl DecodedEnvelope {
    pub(crate) fn worker_lifecycle_id(&self) -> Option<&str> {
        match self.envelope.body.as_ref()? {
            proto::envelope::Body::WorkerReady(payload) => Some(payload.worker_id.as_str()),
            proto::envelope::Body::WorkerHeartbeat(payload) => Some(payload.worker_id.as_str()),
            proto::envelope::Body::WorkerCapacity(payload) => Some(payload.worker_id.as_str()),
            _body => None,
        }
    }
}

/// Checks protocol invariants on host-encoded envelope bytes.
///
/// Hosts encode envelopes with codecs generated from `envelope.proto`, so the
/// kernel no longer owns a structural mapping. It stays the single semantic
/// checker: every envelope passes this check before it is sent or handed to a
/// host, and both runtimes see the same protocol errors.
pub fn validate_envelope_bytes(bytes: &[u8]) -> KernelResult<()> {
    decode_envelope_view(bytes).map(|_envelope| ())
}

/// Seals host-encoded envelope bytes for the wire.
///
/// The `BodySpec` table is the only owner of lane, durability, and protocol
/// version, so the kernel writes those header fields from the body and hosts
/// supply only the body, the ids, and the send time. The sealed envelope then
/// passes the same validation the receive path applies.
pub fn seal_envelope_bytes(bytes: &[u8]) -> KernelResult<Vec<u8>> {
    let mut envelope = proto::Envelope::decode(bytes).map_err(|error| {
        KernelError::new(format!("failed to decode runtime fabric envelope: {error}"))
    })?;

    let body = envelope
        .body
        .as_ref()
        .ok_or_else(|| KernelError::new("envelope body is required"))?;
    let spec = super::body::body_spec(body);

    envelope.protocol_version = super::PROTOCOL_VERSION;
    envelope.lane = spec.lane.into();
    envelope.durability = spec.durability.into();

    validate_envelope(&envelope)?;
    Ok(envelope.encode_to_vec())
}

pub(crate) fn decode_envelope_view(bytes: &[u8]) -> KernelResult<DecodedEnvelope> {
    let envelope = proto::Envelope::decode(bytes).map_err(|error| {
        KernelError::new(format!("failed to decode runtime fabric envelope: {error}"))
    })?;
    validate_envelope(&envelope)?;

    Ok(DecodedEnvelope { envelope })
}
