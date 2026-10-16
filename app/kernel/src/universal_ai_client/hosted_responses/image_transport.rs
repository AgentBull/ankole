//! Image request construction, HTTP/SSE receive and decoded-size validation.
//! The enclosing hosted response owns the total deadline and public delivery.

use base64_simd::STANDARD;
use futures_util::StreamExt;
use serde_json::{Value, json};
use tokio::sync::mpsc;
use tokio::time::timeout;

use super::super::error::{PROVIDER_BODY_EXCERPT_LIMIT, StreamError};
use super::super::transport::SemanticIdle;
use super::{
    HostedImageGenerationSpec, HostedProgress, ImageResult, ModelRequestSpec, send_hosted_progress,
};

/// Keeps generated image payloads inside the AIGateway artifact limit.
const DEFAULT_MAX_DECODED_IMAGE_BYTES: u64 = 50 * 1024 * 1024;

pub(super) fn base64_decoded_len(value: &str) -> u64 {
    let padding = value
        .as_bytes()
        .iter()
        .rev()
        .take_while(|byte| **byte == b'=')
        .count();
    ((value.len() / 4) * 3).saturating_sub(padding) as u64
}

struct StreamingImageCall<'a> {
    prompt: &'a str,
    partial_limit: usize,
    default_mime_type: &'a str,
    max_image_bytes: u64,
    public_id: &'a str,
    output_index: usize,
    progress: Option<&'a mpsc::Sender<HostedProgress>>,
}

pub(super) async fn call_image(
    image_spec: &HostedImageGenerationSpec,
    prompt: &str,
    action: &str,
    selected_ids: &[String],
    public_id: &str,
    output_index: usize,
    progress: Option<&mpsc::Sender<HostedProgress>>,
) -> Result<ImageResult, StreamError> {
    let mut spec = (*image_spec.prepared_request).clone();
    spec.hosted_tools = None;
    let references = image_spec
        .resolved_references
        .iter()
        .filter(|reference| {
            reference
                .get("id")
                .and_then(Value::as_str)
                .is_some_and(|id| selected_ids.iter().any(|selected| selected == id))
        })
        .map(|reference| {
            json!({
                "type": "image_url",
                "image_url": {"url": reference.get("image_url").cloned().unwrap_or(Value::Null)}
            })
        })
        .collect::<Vec<_>>();
    let mut request = spec
        .response_context
        .request
        .as_object()
        .cloned()
        .unwrap_or_default();
    request.insert("prompt".to_string(), json!(prompt));
    request.insert("input_references".to_string(), Value::Array(references));
    if action == "generate" {
        request.remove("input_image_mask");
    }
    let stream = spec.response_context.stream == Some(true);
    request.insert("stream".to_string(), json!(stream));
    spec.response_context.request = Value::Object(request);
    spec.response_context.stream = Some(stream);

    if stream {
        return call_streaming_image(
            spec,
            StreamingImageCall {
                prompt,
                partial_limit: requested_partial_images(image_spec),
                default_mime_type: requested_output_mime(image_spec),
                max_image_bytes: max_decoded_image_bytes(image_spec),
                public_id,
                output_index,
                progress,
            },
        )
        .await;
    }

    let wrapper = super::super::client::run_model_request_once(spec).await?;
    let body = wrapper.get("body").ok_or_else(|| {
        StreamError::new(
            "invalid_image_response",
            "hosted_responses",
            "normalized image response did not contain a body",
        )
    })?;
    let result = body
        .get("result")
        .and_then(Value::as_str)
        .filter(|value| !value.is_empty())
        .ok_or_else(|| {
            StreamError::new(
                "invalid_image_response",
                "hosted_responses",
                "normalized image response did not contain image bytes",
            )
        })?
        .to_string();
    validate_image_base64(&result, max_decoded_image_bytes(image_spec))?;
    send_hosted_progress(
        progress,
        HostedProgress::ImageStarted {
            id: public_id.to_string(),
            output_index,
        },
    )
    .await?;

    Ok(ImageResult {
        result,
        mime_type: body
            .get("mime_type")
            .and_then(Value::as_str)
            .unwrap_or_else(|| requested_output_mime(image_spec))
            .to_string(),
        revised_prompt: body
            .get("revised_prompt")
            .and_then(Value::as_str)
            .unwrap_or(prompt)
            .to_string(),
        usage: body.get("usage").cloned().unwrap_or_else(|| json!({})),
        partial_images: Vec::new(),
        partial_image_count: 0,
    })
}

fn requested_partial_images(image_spec: &HostedImageGenerationSpec) -> usize {
    image_spec
        .tool_config
        .get("partial_images")
        .and_then(Value::as_u64)
        .unwrap_or(0)
        .min(3) as usize
}

fn requested_output_mime(image_spec: &HostedImageGenerationSpec) -> &'static str {
    match image_spec
        .tool_config
        .get("output_format")
        .and_then(Value::as_str)
    {
        Some("jpeg") => "image/jpeg",
        Some("webp") => "image/webp",
        _format => "image/png",
    }
}

async fn call_streaming_image(
    spec: ModelRequestSpec,
    call: StreamingImageCall<'_>,
) -> Result<ImageResult, StreamError> {
    let mut upstream = super::super::request_builder::prepare_model_upstream(&spec)?;
    upstream
        .headers
        .retain(|(name, _value)| !name.eq_ignore_ascii_case("accept"));
    upstream
        .headers
        .push(("accept".to_string(), "text/event-stream".to_string()));

    let mut response = super::super::transport::open_http_stream_for_upstream(&upstream).await?;
    if !(200..300).contains(&response.status) {
        let mut excerpt = Vec::new();
        while excerpt.len() < PROVIDER_BODY_EXCERPT_LIMIT {
            let next = timeout(upstream.timeout.idle_duration(), response.body.next()).await;
            let Ok(Some(Ok(bytes))) = next else {
                break;
            };
            let remaining = PROVIDER_BODY_EXCERPT_LIMIT.saturating_sub(excerpt.len());
            excerpt.extend_from_slice(&bytes[..bytes.len().min(remaining)]);
        }

        return Err(StreamError::new(
            "provider_status_rejected",
            "image_generation",
            format!("image provider returned HTTP status {}", response.status),
        )
        .provider_status(response.status)
        .provider_body_excerpt(&excerpt)
        .provider_headers(&response.headers));
    }

    send_hosted_progress(
        call.progress,
        HostedProgress::ImageStarted {
            id: call.public_id.to_string(),
            output_index: call.output_index,
        },
    )
    .await?;

    let max_event_bytes = spec.limits.max_response_bytes;
    let mut parser = super::super::wire::SSEParser::new(max_event_bytes);
    let mut state = ImageStreamState::default();
    let mut idle = SemanticIdle::new(upstream.timeout.idle_duration());

    'read: loop {
        let next = idle.wait(response.body.next()).await.map_err(|_| {
            StreamError::new("idle_timeout", "read", "image provider stream idle timeout")
        })?;

        match next {
            Some(Ok(bytes)) => {
                let events = parser.push(&bytes)?;
                if !events.is_empty() {
                    idle.progressed();
                }
                for event in events {
                    if ingest_streaming_image_event(
                        &mut state,
                        &event.data,
                        call.partial_limit,
                        call.max_image_bytes,
                        call.public_id,
                        call.output_index,
                        call.progress,
                    )
                    .await?
                    {
                        break 'read;
                    }
                }
            }
            Some(Err(reason)) => {
                return Err(StreamError::new(
                    "response_body_read_failed",
                    "image_generation",
                    format!("image provider stream read failed: {reason}"),
                ));
            }
            None => {
                parser.finish()?;
                break;
            }
        }
    }

    image_result_from_stream(state, call.prompt, call.default_mime_type)
}

async fn ingest_streaming_image_event(
    state: &mut ImageStreamState,
    data: &str,
    partial_limit: usize,
    max_image_bytes: u64,
    public_id: &str,
    output_index: usize,
    progress: Option<&mpsc::Sender<HostedProgress>>,
) -> Result<bool, StreamError> {
    let previous_partial_count = state.partial_image_count;
    let finished = ingest_image_stream_data(state, data, partial_limit, max_image_bytes)?;

    if state.partial_image_count > previous_partial_count {
        let partial_image_index = state.partial_image_count - 1;
        let partial_image_b64 = state
            .partial_images
            .pop()
            .expect("accepted partial image must have bytes");
        send_hosted_progress(
            progress,
            HostedProgress::ImagePartial {
                id: public_id.to_string(),
                output_index,
                partial_image_index,
                partial_image_b64,
            },
        )
        .await?;
    }

    Ok(finished)
}

#[derive(Debug, Default)]
struct ImageStreamState {
    partial_images: Vec<String>,
    partial_image_count: usize,
    completed: Option<Value>,
}

#[cfg(test)]
fn parse_streaming_image_response(
    body: &[u8],
    prompt: &str,
    partial_limit: usize,
    default_mime_type: &str,
) -> Result<ImageResult, StreamError> {
    let mut parser = super::super::wire::SSEParser::new(body.len().max(1));
    let mut state = ImageStreamState::default();
    for event in parser.push(body)? {
        if ingest_image_stream_data(
            &mut state,
            &event.data,
            partial_limit,
            DEFAULT_MAX_DECODED_IMAGE_BYTES,
        )? {
            break;
        }
    }
    parser.finish()?;
    image_result_from_stream(state, prompt, default_mime_type)
}

fn ingest_image_stream_data(
    state: &mut ImageStreamState,
    data: &str,
    partial_limit: usize,
    max_image_bytes: u64,
) -> Result<bool, StreamError> {
    if data == "[DONE]" {
        return Ok(true);
    }

    let event: Value = sonic_rs::from_str(data).map_err(|_| {
        StreamError::new(
            "invalid_image_response",
            "image_generation",
            "image provider returned invalid SSE JSON",
        )
    })?;

    match event.get("type").and_then(Value::as_str) {
        Some("image_generation.partial_image") => {
            if state.partial_image_count < partial_limit
                && let Some(image) = event.get("b64_json").and_then(Value::as_str)
                && !image.is_empty()
            {
                validate_image_base64(image, max_image_bytes)?;
                state.partial_images.push(image.to_string());
                state.partial_image_count = state.partial_image_count.saturating_add(1);
            }
        }
        Some("image_generation.completed") => {
            if let Some(image) = event.get("b64_json").and_then(Value::as_str) {
                validate_image_base64(image, max_image_bytes)?;
            }
            state.completed = Some(event);
        }
        Some("error") => {
            let error = event.get("error").unwrap_or(&event);
            let message = error
                .get("message")
                .and_then(Value::as_str)
                .unwrap_or("Image generation failed.");
            let provider_status = error
                .get("status")
                .and_then(Value::as_u64)
                .or_else(|| error.get("code").and_then(Value::as_u64))
                .and_then(|status| u16::try_from(status).ok())
                .filter(|status| (400..=599).contains(status));
            let error_type = error
                .get("error_type")
                .or_else(|| {
                    error
                        .get("metadata")
                        .and_then(|metadata| metadata.get("error_type"))
                })
                .or_else(|| event.get("error_type"))
                .and_then(Value::as_str);
            let code = match (provider_status, error_type) {
                (Some(429), _) => "provider_status_rejected",
                (Some(408 | 504), _) | (_, Some("timeout")) => "total_timeout",
                (_, Some(error_type)) => error_type,
                _ => error
                    .get("code")
                    .and_then(Value::as_str)
                    .unwrap_or("image_generation_failed"),
            };
            let mut stream_error = StreamError::new(code, "image_generation", message);
            if let Some(status) = provider_status {
                stream_error = stream_error.provider_status(status);
            }
            return Err(stream_error);
        }
        _event => {}
    }

    Ok(false)
}

fn image_result_from_stream(
    state: ImageStreamState,
    prompt: &str,
    default_mime_type: &str,
) -> Result<ImageResult, StreamError> {
    let completed = state.completed.ok_or_else(|| {
        StreamError::new(
            "invalid_image_response",
            "image_generation",
            "image provider stream ended without a completed image",
        )
    })?;
    let result = completed
        .get("b64_json")
        .and_then(Value::as_str)
        .filter(|value| !value.is_empty())
        .ok_or_else(|| {
            StreamError::new(
                "invalid_image_response",
                "image_generation",
                "image provider completed event did not contain image bytes",
            )
        })?;

    Ok(ImageResult {
        result: result.to_string(),
        mime_type: completed
            .get("media_type")
            .and_then(Value::as_str)
            .unwrap_or(default_mime_type)
            .to_string(),
        revised_prompt: completed
            .get("revised_prompt")
            .and_then(Value::as_str)
            .unwrap_or(prompt)
            .to_string(),
        usage: completed.get("usage").cloned().unwrap_or_else(|| json!({})),
        partial_images: state.partial_images,
        partial_image_count: state.partial_image_count,
    })
}

fn max_decoded_image_bytes(image_spec: &HostedImageGenerationSpec) -> u64 {
    image_spec
        .limits
        .get("max_decoded_image_bytes")
        .and_then(Value::as_u64)
        .unwrap_or(DEFAULT_MAX_DECODED_IMAGE_BYTES)
}

fn validate_image_base64(image: &str, max_bytes: u64) -> Result<u64, StreamError> {
    let image = image.as_bytes();
    let decoded_bytes = STANDARD.decoded_length(image).map_err(|_| {
        StreamError::new(
            "invalid_image_response",
            "image_generation",
            "image provider returned invalid base64 image bytes",
        )
    })? as u64;
    if decoded_bytes > max_bytes {
        return Err(StreamError::new(
            "response_body_too_large",
            "image_generation",
            "generated image exceeded configured decoded image byte limit",
        ));
    }

    STANDARD.check(image).map_err(|_| {
        StreamError::new(
            "invalid_image_response",
            "image_generation",
            "image provider returned invalid base64 image bytes",
        )
    })?;

    Ok(decoded_bytes)
}

#[cfg(test)]
mod tests {
    use super::super::public_error::{
        normalize_image_error, redact_hosted_error, to_public_openai_error_json,
    };
    use super::super::test_support::*;
    use super::super::{empty_usage, ensure_public_response_size};
    use super::*;
    use std::io::Write;
    use std::net::TcpListener as TCPListener;
    use std::sync::mpsc;
    use std::thread;
    use std::time::{Duration, Instant};

    #[tokio::test]
    async fn semantic_idle_hosted_image_sse_comments_do_not_reset_the_timeout() {
        let listener = TCPListener::bind("127.0.0.1:0").unwrap();
        let address = listener.local_addr().unwrap();
        thread::spawn(move || {
            let (mut stream, _body) = read_http_request(&listener);
            write!(stream, "HTTP/1.1 200 OK\r\ncontent-type: text/event-stream\r\ntransfer-encoding: chunked\r\n\r\n").unwrap();
            let until = Instant::now() + Duration::from_secs(3);
            while Instant::now() < until {
                if write!(stream, "d\r\n: keepalive\n\n\r\n")
                    .and_then(|()| stream.flush())
                    .is_err()
                {
                    break;
                }
                thread::sleep(Duration::from_millis(20));
            }
        });
        let mut image_spec = test_image_spec(&format!("http://{address}/images"));
        image_spec.prepared_request.response_context.stream = Some(true);
        image_spec.prepared_request.upstream.timeout.idle_ms = 200;
        let started = Instant::now();
        let error = timeout(
            Duration::from_secs(2),
            call_image(&image_spec, "A lake", "generate", &[], "ig_idle", 0, None),
        )
        .await
        .expect("SSE comments must not prevent the hosted image idle timeout")
        .unwrap_err();
        assert_eq!(error.code, "idle_timeout");
        assert_eq!(error.stage, "read");
        assert!(started.elapsed() >= Duration::from_millis(150));
        assert!(started.elapsed() < Duration::from_secs(1));
    }

    #[tokio::test]
    async fn semantic_idle_hosted_image_complete_events_reset_the_timeout() {
        let listener = TCPListener::bind("127.0.0.1:0").unwrap();
        let address = listener.local_addr().unwrap();
        thread::spawn(move || {
            let (mut stream, _body) = read_http_request(&listener);
            write!(stream, "HTTP/1.1 200 OK\r\ncontent-type: text/event-stream\r\ntransfer-encoding: chunked\r\n\r\n").unwrap();
            for event in [
                r#"{"type":"image_generation.partial_image","partial_image_index":0,"b64_json":"cGFydGlhbA=="}"#,
                r#"{"type":"image_generation.partial_image","partial_image_index":1,"b64_json":"cGFydGlhbA=="}"#,
                r#"{"type":"image_generation.completed","b64_json":"ZmluYWw=","media_type":"image/png"}"#,
            ] {
                let until = Instant::now() + Duration::from_millis(150);
                while Instant::now() < until {
                    write_sse_chunk(&mut stream, ": keepalive\n\n");
                    stream.flush().unwrap();
                    thread::sleep(Duration::from_millis(20));
                }
                write_sse_chunk(&mut stream, &format!("data: {event}\n\n"));
                stream.flush().unwrap();
            }
            write_sse_chunk(&mut stream, "data: [DONE]\n\n");
            write!(stream, "0\r\n\r\n").unwrap();
            stream.flush().unwrap();
        });
        let mut image_spec = test_image_spec(&format!("http://{address}/images"));
        image_spec.tool_config["partial_images"] = json!(2);
        image_spec.prepared_request.response_context.stream = Some(true);
        image_spec.prepared_request.upstream.timeout.idle_ms = 200;
        let started = Instant::now();
        let image = timeout(
            Duration::from_secs(2),
            call_image(&image_spec, "A lake", "generate", &[], "ig_idle", 0, None),
        )
        .await
        .unwrap()
        .unwrap();
        assert_eq!(image.result, "ZmluYWw=");
        assert_eq!(image.partial_image_count, 2);
        assert!(started.elapsed() >= Duration::from_millis(400));
    }

    #[test]
    fn streaming_image_response_keeps_requested_partials_and_final_image() {
        let body = concat!(
            "data: {\"type\":\"image_generation.partial_image\",\"partial_image_index\":0,\"b64_json\":\"cGFydGlhbC1h\"}\n\n",
            "data: {\"type\":\"image_generation.partial_image\",\"partial_image_index\":1,\"b64_json\":\"cGFydGlhbC1i\"}\n\n",
            "data: {\"type\":\"image_generation.partial_image\",\"partial_image_index\":2,\"b64_json\":\"cGFydGlhbC1j\"}\n\n",
            "data: {\"type\":\"image_generation.completed\",\"b64_json\":\"ZmluYWwtaW1hZ2U=\",\"media_type\":\"image/webp\",\"revised_prompt\":\"revised\",\"usage\":{\"input_tokens\":2}}\n\n",
            "data: [DONE]\n\n"
        );

        let result =
            parse_streaming_image_response(body.as_bytes(), "original", 2, "image/png").unwrap();

        assert_eq!(result.result, "ZmluYWwtaW1hZ2U=");
        assert_eq!(result.mime_type, "image/webp");
        assert_eq!(result.revised_prompt, "revised");
        assert_eq!(result.partial_images, ["cGFydGlhbC1h", "cGFydGlhbC1i"]);
        assert_eq!(result.partial_image_count, 2);
        assert_eq!(result.usage["input_tokens"], 2);
    }

    #[test]
    fn streaming_image_response_rejects_invalid_partial_base64_before_publication() {
        let body = concat!(
            "data: {\"type\":\"image_generation.partial_image\",\"partial_image_index\":0,\"b64_json\":\"%%%not-base64%%%\"}\n\n",
            "data: {\"type\":\"image_generation.completed\",\"b64_json\":\"ZmluYWw=\"}\n\n"
        );

        let error = parse_streaming_image_response(body.as_bytes(), "original", 1, "image/png")
            .unwrap_err();

        assert_eq!(error.code, "invalid_image_response");
    }

    #[test]
    fn image_sse_error_preserves_provider_status_for_public_mapping() {
        let mut state = ImageStreamState::default();
        let error = ingest_image_stream_data(
            &mut state,
            r#"{"type":"error","error":{"code":429,"metadata":{"error_type":"rate_limit_exceeded"},"message":"provider detail"}}"#,
            0,
            DEFAULT_MAX_DECODED_IMAGE_BYTES,
        )
        .unwrap_err();

        assert_eq!(error.provider_status, Some(429));
        let public = to_public_openai_error_json(&redact_hosted_error(error));
        assert_eq!(public["type"], "rate_limit_error");
        assert_eq!(public["code"], "rate_limit_exceeded");
        assert!(!public.to_string().contains("provider detail"));

        let policy_error = ingest_image_stream_data(
            &mut state,
            r#"{"type":"error","error":{"code":400,"metadata":{"error_type":"image_download_failed"},"message":"private URL detail"}}"#,
            0,
            DEFAULT_MAX_DECODED_IMAGE_BYTES,
        )
        .unwrap_err();
        let policy_public = to_public_openai_error_json(&normalize_image_error(policy_error));
        assert_eq!(policy_public["type"], "image_generation_user_error");
        assert_eq!(policy_public["code"], "image_download_failed");
        assert!(!policy_public.to_string().contains("private URL detail"));
    }

    #[tokio::test]
    async fn generate_removes_prepared_references_and_mask_from_the_image_request() {
        let image_listener = TCPListener::bind("127.0.0.1:0").unwrap();
        let image_address = image_listener.local_addr().unwrap();
        let (request_tx, request_rx) = mpsc::channel();
        thread::spawn(move || {
            let (stream, request) = read_http_request(&image_listener);
            request_tx.send(request).unwrap();
            write_json_response(
                stream,
                &json!({
                    "data": [{"b64_json": "ZmluYWw=", "media_type": "image/png"}],
                    "usage": {}
                }),
            );
        });

        let mut image_spec = test_image_spec(&format!("http://{image_address}/images"));
        image_spec.prepared_request.response_context.request = json!({
            "model": "openai/gpt-image-2",
            "n": 1,
            "input_references": [{
                "type": "image_url",
                "image_url": {"url": "data:image/png;base64,c291cmNl"}
            }],
            "input_image_mask": {
                "image_url": "data:image/png;base64,bWFzaw=="
            }
        });

        call_image(
            &image_spec,
            "A new lake",
            "generate",
            &[],
            "ig_generate",
            0,
            None,
        )
        .await
        .unwrap();

        let request = request_rx.recv().unwrap();
        assert_eq!(request["input_references"], json!([]));
        assert!(request.get("input_image_mask").is_none());
    }

    #[test]
    fn decoded_image_and_public_response_limits_accept_the_exact_boundary_only() {
        let exact_image = STANDARD.encode_to_string(vec![7_u8; 1_024]);
        assert_eq!(validate_image_base64(&exact_image, 1_024).unwrap(), 1_024);

        assert_eq!(
            validate_image_base64("AAAA*AAA", 1_024).unwrap_err().code,
            "invalid_image_response"
        );

        let oversized_image = STANDARD.encode_to_string(vec![7_u8; 1_025]);
        assert_eq!(
            validate_image_base64(&oversized_image, 1_024)
                .unwrap_err()
                .code,
            "response_body_too_large"
        );

        let response = json!({
            "id": "resp_exact_limit",
            "status": "completed",
            "output": [],
            "usage": empty_usage()
        });
        let exact_response_bytes = sonic_rs::to_vec(&response).unwrap().len();
        ensure_public_response_size(&response, exact_response_bytes, false).unwrap();
        assert_eq!(
            ensure_public_response_size(&response, exact_response_bytes - 1, false)
                .unwrap_err()
                .code,
            "response_body_too_large"
        );
    }
}
