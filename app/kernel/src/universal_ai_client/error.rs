use serde::Serialize;
use serde_json::{Map, Value, json};

use crate::common::KernelError;

pub const PROVIDER_BODY_EXCERPT_LIMIT: usize = 4096;

#[derive(Debug, Clone, Copy)]
pub enum StreamErrorCode {
    ProviderTerminalRejected,
}

impl StreamErrorCode {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::ProviderTerminalRejected => "provider_terminal_rejected",
        }
    }
}

impl From<StreamErrorCode> for String {
    fn from(value: StreamErrorCode) -> Self {
        value.as_str().to_string()
    }
}

#[derive(Debug, Clone, Serialize)]
pub struct StreamError {
    pub code: String,
    pub stage: String,
    pub message: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub provider_status: Option<u16>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub provider_body_excerpt: Option<Box<str>>,
    #[serde(skip_serializing_if = "Vec::is_empty")]
    pub provider_headers: Vec<(String, String)>,
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
            provider_headers: Vec::new(),
        }
    }

    pub fn provider_status(mut self, status: u16) -> Self {
        self.provider_status = Some(status);
        self
    }

    pub fn provider_body_excerpt(mut self, body: impl AsRef<[u8]>) -> Self {
        let bytes = body.as_ref();
        let limit = bytes.len().min(PROVIDER_BODY_EXCERPT_LIMIT);
        self.provider_body_excerpt = Some(
            String::from_utf8_lossy(&bytes[..limit])
                .into_owned()
                .into_boxed_str(),
        );
        self
    }

    pub fn provider_headers(mut self, headers: &[(String, String)]) -> Self {
        self.provider_headers = super::transport::codex_response_headers(headers);
        self
    }

    pub fn to_json(&self) -> Value {
        sonic_rs::to_string(self)
            .ok()
            .and_then(|encoded| sonic_rs::from_str::<Value>(&encoded).ok())
            .unwrap_or_else(error_encoding_failed)
    }

    pub fn to_openai_error_json(&self) -> Value {
        let mut object = Map::new();
        object.insert("message".to_string(), Value::String(self.message.clone()));
        object.insert(
            "type".to_string(),
            Value::String("server_error".to_string()),
        );
        object.insert("param".to_string(), Value::Null);
        object.insert("code".to_string(), Value::String(self.code.clone()));

        if let Some(status) = self.provider_status {
            object.insert("status".to_string(), json!(status));
        }

        let details = self.openai_error_details_json();
        if !details.is_empty() {
            object.insert("details_json".to_string(), Value::Object(details));
        }

        Value::Object(object)
    }

    fn openai_error_details_json(&self) -> Map<String, Value> {
        let mut details = Map::new();
        details.insert("stage".to_string(), Value::String(self.stage.clone()));

        if let Some(status) = self.provider_status {
            details.insert("provider_status".to_string(), json!(status));
        }

        if let Some(excerpt) = &self.provider_body_excerpt {
            details.insert(
                "provider_body_excerpt".to_string(),
                Value::String(excerpt.to_string()),
            );
        }

        if !self.provider_headers.is_empty() {
            details.insert("provider_headers".to_string(), json!(self.provider_headers));
        }

        details
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
