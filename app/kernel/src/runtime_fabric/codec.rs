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

pub(crate) fn decode_envelope_view(bytes: &[u8]) -> KernelResult<DecodedEnvelope> {
    let envelope = proto::Envelope::decode(bytes).map_err(|error| {
        KernelError::new(format!("failed to decode runtime fabric envelope: {error}"))
    })?;
    validate_envelope(&envelope)?;

    Ok(DecodedEnvelope { envelope })
}
