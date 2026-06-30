use serde::Serialize;
use serde_json::{Map, Value};

use crate::common::KernelError;

#[derive(Debug, Clone, Serialize)]
pub struct StreamError {
    pub code: String,
    pub stage: String,
    pub message: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub provider_status: Option<u16>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub provider_body_excerpt: Option<String>,
}

impl StreamError {
    pub fn new(
        code: impl Into<String>,
        stage: impl Into<String>,
        message: impl Into<String>,
    ) -> Self {
        Self {
            code: code.into(),
            stage: stage.into(),
            message: message.into(),
            provider_status: None,
            provider_body_excerpt: None,
        }
    }

    pub fn provider_status(mut self, status: u16) -> Self {
        self.provider_status = Some(status);
        self
    }

    pub fn provider_body_excerpt(mut self, body: impl AsRef<[u8]>) -> Self {
        let bytes = body.as_ref();
        let limit = bytes.len().min(4096);
        self.provider_body_excerpt = Some(String::from_utf8_lossy(&bytes[..limit]).to_string());
        self
    }

    pub fn to_json(&self) -> Value {
        sonic_rs::to_string(self)
            .ok()
            .and_then(|encoded| sonic_rs::from_str::<Value>(&encoded).ok())
            .unwrap_or_else(error_encoding_failed)
    }
}

fn error_encoding_failed() -> Value {
    let mut object = Map::new();
    object.insert(
        "code".to_string(),
        Value::String("error_encoding_failed".to_string()),
    );
    object.insert("stage".to_string(), Value::String("kernel".to_string()));
    object.insert(
        "message".to_string(),
        Value::String("failed to encode stream error".to_string()),
    );
    Value::Object(object)
}

impl std::fmt::Display for StreamError {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(formatter, "{}: {}", self.stage, self.message)
    }
}

impl From<StreamError> for KernelError {
    fn from(error: StreamError) -> Self {
        KernelError::new(error.to_string())
    }
}
