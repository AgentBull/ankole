use serde_json::{Value, json};

use super::error::StreamError;
use super::spec::DownstreamKind;

#[derive(Debug, Clone)]
pub struct DownstreamChunk {
    pub kind: DownstreamKind,
    pub bytes: Vec<u8>,
}

#[derive(Debug, Clone, Copy)]
pub struct DownstreamEncoder {
    kind: DownstreamKind,
}

impl DownstreamEncoder {
    pub fn new(kind: DownstreamKind) -> Self {
        Self { kind }
    }

    pub fn encode_event(self, event: &Value) -> DownstreamChunk {
        let bytes = match self.kind {
            DownstreamKind::Sse => encode_sse_event(event),
            DownstreamKind::WebsocketText => {
                sonic_rs::to_vec(event).unwrap_or_else(|_| b"{}".to_vec())
            }
        };

        DownstreamChunk {
            kind: self.kind,
            bytes,
        }
    }

    pub fn encode_error(self, error: &StreamError) -> DownstreamChunk {
        self.encode_event(&json!({
            "type": "error",
            "sequence_number": 0,
            "error": {
                "message": error.message,
                "type": "server_error",
                "param": null,
                "code": error.code
            }
        }))
    }

    pub fn encode_done_sentinel(self) -> Option<DownstreamChunk> {
        match self.kind {
            DownstreamKind::Sse => Some(DownstreamChunk {
                kind: self.kind,
                bytes: b"data: [DONE]\n\n".to_vec(),
            }),
            DownstreamKind::WebsocketText => None,
        }
    }
}

fn encode_sse_event(event: &Value) -> Vec<u8> {
    let event_type = event
        .get("type")
        .and_then(Value::as_str)
        .unwrap_or("response.event");
    let data = sonic_rs::to_string(event).unwrap_or_else(|_| "{}".to_string());
    let mut encoded = Vec::with_capacity(event_type.len() + data.len() + 16);
    encoded.extend_from_slice(b"event: ");
    encoded.extend_from_slice(event_type.as_bytes());
    encoded.extend_from_slice(b"\n");
    encoded.extend_from_slice(b"data: ");
    encoded.extend_from_slice(data.as_bytes());
    encoded.extend_from_slice(b"\n\n");
    encoded
}

#[cfg(test)]
mod tests {
    use serde_json::json;

    use super::*;

    #[test]
    fn sse_encoder_returns_complete_sse_bytes() {
        let chunk = DownstreamEncoder::new(DownstreamKind::Sse).encode_event(&json!({
            "type": "response.output_text.delta",
            "delta": "hello"
        }));

        assert_eq!(chunk.kind, DownstreamKind::Sse);
        assert!(
            String::from_utf8(chunk.bytes)
                .unwrap()
                .starts_with("event: response.output_text.delta\ndata: ")
        );
    }

    #[test]
    fn websocket_encoder_returns_text_payload_bytes() {
        let chunk = DownstreamEncoder::new(DownstreamKind::WebsocketText).encode_event(&json!({
            "type": "response.completed"
        }));

        assert_eq!(chunk.kind, DownstreamKind::WebsocketText);
        assert_eq!(
            sonic_rs::from_slice::<Value>(&chunk.bytes).unwrap()["type"],
            "response.completed"
        );
    }

    #[test]
    fn sse_done_sentinel_is_a_complete_sse_chunk() {
        let chunk = DownstreamEncoder::new(DownstreamKind::Sse)
            .encode_done_sentinel()
            .unwrap();

        assert_eq!(chunk.kind, DownstreamKind::Sse);
        assert_eq!(chunk.bytes, b"data: [DONE]\n\n");
    }
}
