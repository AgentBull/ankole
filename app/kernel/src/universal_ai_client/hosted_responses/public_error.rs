use serde_json::{Map, Value, json};

use super::super::error::StreamError;

const IMAGE_USER_ERROR_CODES: &[&str] = &[
    "content_policy_violation",
    "image_generation_user_error",
    "image_too_large",
    "image_too_small",
    "invalid_image",
    "unsupported_image_format",
    "image_not_found",
    "image_download_failed",
    "refusal",
    "moderation_blocked",
];

pub(super) fn normalize_image_error(error: StreamError) -> StreamError {
    let provider_code = provider_error_code(&error);
    let user_code = if image_user_error_code(&error.code) {
        Some(error.code.clone())
    } else {
        provider_code.filter(|code| image_user_error_code(code))
    };

    let mut normalized = match user_code {
        Some(code) => {
            let mut normalized =
                StreamError::new(code, "image_generation", "The image request was rejected.");
            normalized.provider_status = error.provider_status;
            normalized
        }
        None => error,
    };
    normalized.stage = "image_generation".to_string();
    normalized
}

pub(super) fn redact_hosted_error(mut error: StreamError) -> StreamError {
    let stable_code = image_user_error_code(&error.code)
        || matches!(
            error.code.as_str(),
            "first_byte_timeout"
                | "idle_timeout"
                | "total_timeout"
                | "response_body_too_large"
                | "sse_event_too_large"
                | "eventstream_frame_too_large"
                | "websocket_message_too_large"
                | "upstream_error"
        );

    match error.provider_status {
        Some(429) => {}
        Some(408 | 504) => error.code = "total_timeout".to_string(),
        _status if !stable_code => error.code = "upstream_error".to_string(),
        _status => {}
    }
    error.provider_body_excerpt = None;
    error.message = public_message(&error).to_string();
    error
}

pub(super) fn to_public_openai_error_json(error: &StreamError) -> Value {
    let mut object = Map::new();
    object.insert(
        "message".to_string(),
        Value::String(public_message(error).to_string()),
    );
    let (error_type, code) = public_kind(error);
    object.insert("type".to_string(), Value::String(error_type.to_string()));
    object.insert("param".to_string(), Value::Null);
    object.insert("code".to_string(), Value::String(code.to_string()));
    if let Some(status) = error.provider_status {
        object.insert("status".to_string(), Value::from(status));
        object.insert(
            "details_json".to_string(),
            json!({"provider_status": status}),
        );
    }
    Value::Object(object)
}

fn provider_error_code(error: &StreamError) -> Option<String> {
    error
        .provider_body_excerpt
        .as_deref()
        .and_then(|excerpt| sonic_rs::from_str::<Value>(excerpt).ok())
        .and_then(|body| {
            body.get("error")
                .and_then(|value| {
                    value
                        .get("code")
                        .or_else(|| value.get("type"))
                        .or_else(|| value.get("error_type"))
                })
                .or_else(|| body.get("code"))
                .or_else(|| body.get("error_type"))
                .and_then(Value::as_str)
                .map(str::to_string)
        })
}

fn image_user_error_code(code: &str) -> bool {
    IMAGE_USER_ERROR_CODES.contains(&code)
}

fn public_message(error: &StreamError) -> &'static str {
    if error.provider_status == Some(429) {
        return "The image generation provider rate limit was exceeded.";
    }
    if image_user_error_code(&error.code) {
        return "The image request was rejected.";
    }
    if matches!(
        error.code.as_str(),
        "first_byte_timeout" | "idle_timeout" | "total_timeout"
    ) {
        return "The image generation provider timed out.";
    }
    if matches!(
        error.code.as_str(),
        "response_body_too_large"
            | "sse_event_too_large"
            | "eventstream_frame_too_large"
            | "websocket_message_too_large"
    ) {
        return "The generated response exceeded 128 MiB.";
    }

    "The hosted image generation request failed."
}

fn public_kind(error: &StreamError) -> (&'static str, &str) {
    if error.provider_status == Some(429) {
        return ("rate_limit_error", "rate_limit_exceeded");
    }
    if image_user_error_code(&error.code) {
        return ("image_generation_user_error", error.code.as_str());
    }
    if matches!(
        error.code.as_str(),
        "first_byte_timeout" | "idle_timeout" | "total_timeout"
    ) {
        return ("server_error", "upstream_timeout");
    }
    if matches!(
        error.code.as_str(),
        "response_body_too_large"
            | "sse_event_too_large"
            | "eventstream_frame_too_large"
            | "websocket_message_too_large"
    ) {
        return ("server_error", "response_too_large");
    }

    ("server_error", error.code.as_str())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn preserves_specific_image_user_error_code() {
        let error = StreamError::new(
            "provider_status_rejected",
            "image_generation",
            "private provider message",
        )
        .provider_status(400)
        .provider_body_excerpt(
            br#"{"error":{"type":"image_generation_user_error","code":"moderation_blocked"}}"#,
        );

        let normalized = normalize_image_error(error);
        let public = to_public_openai_error_json(&normalized);

        assert_eq!(public["type"], "image_generation_user_error");
        assert_eq!(public["code"], "moderation_blocked");
        assert_eq!(public["message"], "The image request was rejected.");
        assert_eq!(public["status"], 400);
        assert_eq!(public["details_json"]["provider_status"], 400);
    }

    #[test]
    fn normalizes_every_image_failure_to_the_image_stage() {
        let error = StreamError::new(
            "provider_status_rejected",
            "connect",
            "private provider message",
        )
        .provider_status(503);

        let normalized = normalize_image_error(error);

        assert_eq!(normalized.stage, "image_generation");
    }

    #[test]
    fn hosted_redaction_keeps_the_attempt_stage() {
        let error = StreamError::new(
            "provider_status_rejected",
            "connect",
            "private provider message",
        )
        .provider_status(503);

        let redacted = redact_hosted_error(error);

        assert_eq!(redacted.stage, "connect");
    }
}
