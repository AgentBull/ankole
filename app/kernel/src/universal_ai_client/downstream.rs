use serde_json::Value;

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
