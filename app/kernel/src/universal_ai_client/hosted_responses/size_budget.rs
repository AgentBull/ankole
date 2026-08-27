//! Public-response size accounting for hosted Responses.
//!
//! The budget projects the terminal public Response while hidden tool rounds
//! still run, so an over-limit response fails at the item that crosses the
//! limit instead of after the whole hosted execution.

use std::io::{self, Write};

use serde_json::{Map, Value, json};

use super::super::api_resolver;
use super::super::error::StreamError;
use super::super::spec::{ModelRequestSpec, ResponseContext};
use super::empty_usage;
use super::events::{strip_internal_image_fields, strip_internal_output_fields};

/// Counts encoded JSON without keeping a second copy of large image data.
#[derive(Default)]
struct JsonByteCounter {
    bytes: usize,
}

impl Write for JsonByteCounter {
    fn write(&mut self, buffer: &[u8]) -> io::Result<usize> {
        self.bytes = self.bytes.saturating_add(buffer.len());
        Ok(buffer.len())
    }

    fn flush(&mut self) -> io::Result<()> {
        Ok(())
    }
}

/// Tracks the public fields that grow while hosted output becomes visible.
/// The fixed Response shape is normalized once, so one new item does not copy
/// earlier images or the public request history.
pub(super) struct HostedResponseSizeBudget {
    fixed_body_bytes: usize,
    terminal_overhead_bytes: usize,
    output_bytes: usize,
    output_items: usize,
    max_bytes: usize,
}

impl HostedResponseSizeBudget {
    pub(super) fn new(
        base_spec: &ModelRequestSpec,
        public_request: &Map<String, Value>,
        outer_stream: bool,
    ) -> Self {
        let usage = empty_usage();
        let tool_usage = json!({"image_gen": empty_usage()});
        let context = ResponseContext {
            model: base_spec.response_context.model.clone(),
            request: Value::Object(public_request.clone()),
            provider_options: Value::Null,
            stream: Some(false),
            include_model: true,
        };
        let response = api_resolver::complete_response_resource(
            &context,
            json!({
                "id": api_resolver::generated_id("resp"),
                "model": base_spec.response_context.model,
                "status": "completed",
                "incomplete_details": null,
                "output": [],
                "usage": usage,
                "tool_usage": tool_usage,
                "error": null
            }),
        );
        let public_response = strip_internal_output_fields(response);
        let body_bytes = serialized_json_size(&public_response);
        let output_bytes = serialized_json_size(&public_response["output"]);
        let usage_bytes = serialized_json_size(&public_response["usage"]);
        let tool_usage_bytes = serialized_json_size(&public_response["tool_usage"]);
        let fixed_body_bytes = body_bytes
            .saturating_sub(output_bytes)
            .saturating_sub(usage_bytes)
            .saturating_sub(tool_usage_bytes);
        let terminal_overhead_bytes = if outer_stream {
            serialized_json_size(&json!({
                "type": "response.completed",
                "sequence_number": u64::MAX,
                "response": public_response
            }))
            .saturating_sub(body_bytes)
        } else {
            0
        };

        Self {
            fixed_body_bytes,
            terminal_overhead_bytes,
            output_bytes,
            output_items: 0,
            max_bytes: base_spec.limits.max_response_bytes,
        }
    }

    pub(super) fn admit(
        &mut self,
        candidate: &Value,
        usage: &Value,
        image_usage: &Value,
    ) -> Result<(), StreamError> {
        let public_item = api_resolver::normalize_output_item(candidate);
        let public_item =
            if public_item.get("type").and_then(Value::as_str) == Some("image_generation_call") {
                strip_internal_image_fields(public_item)
            } else {
                public_item
            };
        let separator_bytes = usize::from(self.output_items > 0);
        let next_output_bytes = self
            .output_bytes
            .saturating_add(separator_bytes)
            .saturating_add(serialized_json_size(&public_item));
        let public_usage = api_resolver::normalize_response_usage(usage);
        let tool_usage = json!({"image_gen": image_usage});
        let body_bytes = self
            .fixed_body_bytes
            .saturating_add(next_output_bytes)
            .saturating_add(serialized_json_size(&public_usage))
            .saturating_add(serialized_json_size(&tool_usage));
        let terminal_bytes = body_bytes.saturating_add(self.terminal_overhead_bytes);

        if body_bytes > self.max_bytes || terminal_bytes > self.max_bytes {
            return Err(public_response_too_large());
        }

        self.output_bytes = next_output_bytes;
        self.output_items = self.output_items.saturating_add(1);
        Ok(())
    }
}

pub(super) fn serialized_json_size(value: &Value) -> usize {
    let mut counter = JsonByteCounter::default();
    let writer = sonic_rs::writer::BufferedWriter::new(&mut counter);
    sonic_rs::to_writer(writer, value)
        .map(|_| counter.bytes)
        .unwrap_or(usize::MAX)
}

pub(super) fn ensure_public_response_size(
    response: &Value,
    max_bytes: usize,
    outer_stream: bool,
) -> Result<(), StreamError> {
    let public_response = strip_internal_output_fields(response.clone());
    let body_bytes = serialized_json_size(&public_response);
    let terminal_bytes = if outer_stream {
        serialized_json_size(&json!({
            "type": "response.completed",
            "sequence_number": u64::MAX,
            "response": public_response
        }))
    } else {
        body_bytes
    };

    if body_bytes <= max_bytes && terminal_bytes <= max_bytes {
        Ok(())
    } else {
        Err(public_response_too_large())
    }
}

pub(super) fn public_response_too_large() -> StreamError {
    StreamError::new(
        "response_body_too_large",
        "hosted_responses",
        "public hosted response exceeded configured response byte limit",
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    fn test_upstream(url: &str) -> Value {
        json!({
            "method": "POST",
            "url": url,
            "headers": [["content-type", "application/json"]],
            "timeout": {"connect_ms": 2_000, "first_byte_ms": 2_000, "idle_ms": 2_000, "total_ms": 5_000},
            "transport": {"http_versions": ["h1"], "compression": []}
        })
    }

    #[test]
    fn response_limit_counts_only_public_image_fields() {
        let response = json!({
            "id": "resp_limit",
            "output": [{
                "id": "ig_limit",
                "type": "image_generation_call",
                "status": "completed",
                "result": "ZmluYWw=",
                "revised_prompt": "A lake",
                "mime_type": "image/png",
                "partial_images": ["eA==".repeat(10_000)]
            }]
        });

        ensure_public_response_size(&response, 1_024, false).unwrap();
    }

    #[test]
    fn projected_response_budget_matches_the_complete_public_response() {
        let public_request = json!({
            "model": "main-model",
            "input": "Draw a lake",
            "tools": [{"type": "image_generation"}]
        });
        let output = vec![
            json!({
                "id": "ig_budget",
                "type": "image_generation_call",
                "status": "completed",
                "result": "ZmluYWw=",
                "revised_prompt": "A lake",
                "mime_type": "image/png",
                "partial_images": ["eA==".repeat(1_000)]
            }),
            json!({
                "id": "fc_budget",
                "type": "function_call",
                "call_id": "call_budget",
                "name": "lookup",
                "arguments": "{}",
                "status": "completed",
                "mime_type": "application/x-ankole-test",
                "partial_images": ["this field belongs to the public function item"]
            }),
        ];
        let usage = json!({
            "input_tokens": 12,
            "output_tokens": 3,
            "total_tokens": 15,
            "input_tokens_details": {"cached_tokens": 2},
            "output_tokens_details": {"reasoning_tokens": 1}
        });
        let image_usage = empty_usage();
        let context = ResponseContext {
            model: "main-model".to_string(),
            request: public_request.clone(),
            provider_options: Value::Null,
            stream: Some(false),
            include_model: true,
        };
        let response = api_resolver::complete_response_resource(
            &context,
            json!({
                "id": api_resolver::generated_id("resp"),
                "model": "main-model",
                "status": "completed",
                "incomplete_details": null,
                "output": output,
                "usage": usage,
                "tool_usage": {"image_gen": image_usage},
                "error": null
            }),
        );
        let exact_bytes = serialized_json_size(&strip_internal_output_fields(response));
        let spec_json = json!({
            "api_resolver": "openai_chat_completions",
            "upstream": test_upstream("http://127.0.0.1:1/chat/completions"),
            "response_context": {"model": "main-model", "request": public_request},
            "limits": {"max_response_bytes": exact_bytes}
        });
        let mut spec = ModelRequestSpec::from_json(&spec_json.to_string()).unwrap();
        let public_request = spec.response_context.request.as_object().unwrap().clone();
        let mut budget = HostedResponseSizeBudget::new(&spec, &public_request, false);

        budget.admit(&output[0], &usage, &image_usage).unwrap();
        budget.admit(&output[1], &usage, &image_usage).unwrap();

        spec.limits.max_response_bytes = exact_bytes - 1;
        let mut budget = HostedResponseSizeBudget::new(&spec, &public_request, false);
        budget.admit(&output[0], &usage, &image_usage).unwrap();
        assert_eq!(
            budget
                .admit(&output[1], &usage, &image_usage)
                .unwrap_err()
                .code,
            "response_body_too_large"
        );
    }
}
