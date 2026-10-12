use super::stream::{websocket_initial_messages, websocket_read_error};
use crate::universal_ai_client::transport::SemanticIdle;
use crate::universal_ai_client::{
    api_resolver,
    error::StreamError,
    request_builder,
    spec::{StreamSpec, UpstreamKind},
    transport,
};
use futures_util::{SinkExt, StreamExt};
use serde_json::{Value, json};
use std::collections::BTreeMap;
use tokio_tungstenite::tungstenite::{Message, protocol::frame::coding::CloseCode};

pub(in crate::universal_ai_client) struct CollectedWebSocketModelResponse {
    pub wrapper: Value,
    pub completed_items: BTreeMap<usize, Value>,
}

pub(in crate::universal_ai_client) async fn run_websocket_model_request_once(
    mut spec: StreamSpec,
) -> Result<CollectedWebSocketModelResponse, StreamError> {
    if spec.upstream.kind != UpstreamKind::WebSocketText {
        return Err(StreamError::new(
            "invalid_websocket_model_request",
            "hosted_responses",
            "hosted WebSocket model execution requires a websocket_text upstream",
        ));
    }

    spec.hosted_tools = None;
    let spec = request_builder::prepare_stream_spec(spec)?;
    let (mut websocket, status, response_headers) = transport::open_websocket(&spec).await?;

    if status != 101 {
        return Err(StreamError::new(
            "websocket_status_rejected",
            "connect",
            format!("upstream WebSocket returned status {status}"),
        )
        .provider_status(status)
        .provider_headers(&response_headers));
    }

    let initial_messages = websocket_initial_messages(&spec);
    for payload in &initial_messages {
        if payload.len() > spec.limits.max_websocket_text_bytes {
            return Err(StreamError::new(
                "websocket_message_too_large",
                "connect",
                format!(
                    "initial WebSocket text payload exceeded {} bytes",
                    spec.limits.max_websocket_text_bytes
                ),
            )
            .provider_status(413));
        }

        websocket
            .send(Message::text(payload.clone()))
            .await
            .map_err(|reason| {
                StreamError::new(
                    "websocket_send_failed",
                    "connect",
                    format!("failed to send initial WebSocket payload: {reason}"),
                )
            })?;
    }

    let mut resolver =
        api_resolver::APIResolver::new(spec.api_resolver, spec.response_context.clone());
    let mut completed_items = BTreeMap::new();
    let mut raw_body_bytes = 0usize;

    let mut idle = SemanticIdle::new(spec.upstream.timeout.idle_duration());
    loop {
        let next = idle.wait(websocket.next()).await;
        match next {
            Ok(Some(Ok(Message::Text(text)))) => {
                idle.progressed();
                if text.len() > spec.limits.max_websocket_text_bytes {
                    return Err(StreamError::new(
                        "websocket_message_too_large",
                        "wire",
                        format!(
                            "upstream WebSocket text payload exceeded {} bytes",
                            spec.limits.max_websocket_text_bytes
                        ),
                    )
                    .provider_status(413));
                }

                raw_body_bytes = raw_body_bytes.saturating_add(text.len());
                if text == "[DONE]" {
                    resolver.finish()?;
                    return Err(missing_websocket_terminal_error());
                }

                let value = sonic_rs::from_str::<Value>(&text).map_err(|reason| {
                    StreamError::new(
                        "invalid_provider_event",
                        "api_resolver",
                        format!("WebSocket text payload was not valid JSON: {reason}"),
                    )
                })?;
                let events = resolver.ingest(value)?;
                remember_completed_items(&events, &mut completed_items);

                if let Some(body) = collected_terminal_body(&events) {
                    ensure_collected_body_size(&body, spec.limits.max_pending_bytes)?;
                    ensure_collected_body_size(
                        &Value::Array(completed_items.values().cloned().collect()),
                        spec.limits.max_pending_bytes,
                    )?;
                    return Ok(CollectedWebSocketModelResponse {
                        wrapper: json!({
                        "status": status,
                        "headers": response_headers,
                        "body": body,
                        "raw_body_bytes": raw_body_bytes,
                        "upstream_kind": spec.upstream.kind.as_str(),
                        "websocket_initial_messages": initial_messages.len()
                        }),
                        completed_items,
                    });
                }
            }
            Ok(Some(Ok(Message::Close(Some(frame))))) if frame.code == CloseCode::Size => {
                return Err(StreamError::new(
                    "websocket_message_too_large",
                    "wire",
                    "upstream WebSocket closed because a message was too large",
                )
                .provider_status(413));
            }
            Ok(Some(Ok(Message::Close(_)))) | Ok(None) => {
                resolver.finish()?;
                return Err(missing_websocket_terminal_error());
            }
            Ok(Some(Ok(Message::Ping(_)))) | Ok(Some(Ok(Message::Pong(_)))) => {}
            Ok(Some(Ok(Message::Binary(bytes)))) => {
                return Err(StreamError::new(
                    "unsupported_websocket_frame",
                    "wire",
                    format!(
                        "upstream WebSocket binary frame is unsupported ({} bytes)",
                        bytes.len()
                    ),
                ));
            }
            Ok(Some(Ok(Message::Frame(_)))) => {}
            Ok(Some(Err(reason))) => return Err(websocket_read_error(reason)),
            Err(_) => {
                return Err(StreamError::new(
                    "idle_timeout",
                    "read",
                    "upstream WebSocket idle timeout",
                ));
            }
        }
    }
}

fn remember_completed_items(events: &[Value], completed_items: &mut BTreeMap<usize, Value>) {
    for event in events {
        if event.get("type").and_then(Value::as_str) != Some("response.output_item.done") {
            continue;
        }
        let Some(output_index) = event
            .get("output_index")
            .and_then(Value::as_u64)
            .and_then(|value| usize::try_from(value).ok())
        else {
            continue;
        };
        let Some(item) = event.get("item").filter(|item| item.is_object()) else {
            continue;
        };
        completed_items.insert(output_index, item.clone());
    }
}

fn collected_terminal_body(events: &[Value]) -> Option<Value> {
    events.iter().find_map(|event| {
        let event_type = event.get("type").and_then(Value::as_str)?;
        if !matches!(
            event_type,
            "response.completed" | "response.failed" | "response.incomplete"
        ) {
            return None;
        }

        Some(
            event
                .get("response")
                .filter(|value| value.is_object())?
                .clone(),
        )
    })
}

fn ensure_collected_body_size(body: &Value, max_response_bytes: usize) -> Result<(), StreamError> {
    let body_bytes = sonic_rs::to_vec(body).map_err(|reason| {
        StreamError::new(
            "response_encode_failed",
            "hosted_responses",
            format!("collected WebSocket response could not be encoded: {reason}"),
        )
    })?;
    if body_bytes.len() <= max_response_bytes.max(1) {
        Ok(())
    } else {
        Err(StreamError::new(
            "response_body_too_large",
            "hosted_responses",
            "collected WebSocket response exceeded the configured response byte limit",
        ))
    }
}

fn missing_websocket_terminal_error() -> StreamError {
    StreamError::new(
        "upstream_stream_closed_before_terminal_event",
        "api_resolver",
        "upstream WebSocket closed before a terminal response event",
    )
}
