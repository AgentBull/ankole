use serde::Serialize;
use serde_json::Value;

use super::error::StreamError;
use super::spec::ConversionPolicy;

#[derive(Debug, Clone)]
pub(crate) struct DownstreamChunk {
    pub(crate) bytes: Vec<u8>,
}

#[derive(Debug, Clone, Copy)]
pub(crate) struct DownstreamEncoder;

impl DownstreamEncoder {
    pub(crate) fn encode_event(self, event: &Value) -> DownstreamChunk {
        self.encode_event_with_policy(event, ConversionPolicy::Tolerant)
            .unwrap_or_else(|_| DownstreamChunk {
                bytes: b"{}".to_vec(),
            })
    }

    pub(crate) fn encode_event_with_policy(
        self,
        event: &Value,
        policy: ConversionPolicy,
    ) -> Result<DownstreamChunk, StreamError> {
        self.encode_serializable_with_policy(event, policy)
    }

    pub(crate) fn encode_serializable_with_policy<T: Serialize + ?Sized>(
        self,
        value: &T,
        policy: ConversionPolicy,
    ) -> Result<DownstreamChunk, StreamError> {
        match sonic_rs::to_vec(value) {
            Ok(bytes) => Ok(DownstreamChunk { bytes }),
            Err(reason) if policy == ConversionPolicy::Strict => Err(StreamError::new(
                "downstream_encode_failed",
                "downstream",
                format!("downstream event could not be encoded as JSON: {reason}"),
            )),
            Err(_reason) => Ok(DownstreamChunk {
                bytes: b"{}".to_vec(),
            }),
        }
    }
}
