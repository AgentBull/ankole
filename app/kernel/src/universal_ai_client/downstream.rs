use serde_json::{Value, json};

use super::error::StreamError;

#[derive(Debug, Clone)]
pub struct DownstreamChunk {
    pub bytes: Vec<u8>,
}

#[derive(Debug, Clone, Copy)]
pub struct DownstreamEncoder;

impl DownstreamEncoder {
    pub fn encode_event(self, event: &Value) -> DownstreamChunk {
        DownstreamChunk {
            bytes: sonic_rs::to_vec(event).unwrap_or_else(|_| b"{}".to_vec()),
        }
    }

    pub fn encode_error(self, error: &StreamError) -> DownstreamChunk {
        self.encode_event(&json!({
            "type": "error",
            "sequence_number": 0,
            "error": error.to_openai_error_json()
        }))
    }
}

#[cfg(test)]
mod tests {
    use serde_json::json;

    use super::*;

    #[test]
    fn encoder_returns_one_complete_json_text_event() {
        let event = json!({"type": "response.completed"});
        let chunk = DownstreamEncoder.encode_event(&event);
        assert_eq!(sonic_rs::from_slice::<Value>(&chunk.bytes).unwrap(), event);
    }
}
