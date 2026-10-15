use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};

use futures_util::{SinkExt, StreamExt};
use serde_json::{Value, json};
use tokio::sync::mpsc;
use tokio::time::timeout;
use tokio_tungstenite::tungstenite::error::CapacityError;
use tokio_tungstenite::tungstenite::protocol::frame::coding::CloseCode;
use tokio_tungstenite::tungstenite::{Error as WebSocketError, Message};

use super::core::{EventSink, StreamCommand, StreamEvent};
use super::delivery::{Delivery, finish_after_ready_error, ingest_resolver_event, summary};
use crate::universal_ai_client::downstream::DownstreamEncoder;
use crate::universal_ai_client::error::StreamError;
use crate::universal_ai_client::spec::{StreamSpec, UpstreamKind};
use crate::universal_ai_client::transport::SemanticIdle;
use crate::universal_ai_client::{
    api_resolver, hosted_responses, request_builder, transport, wire,
};

pub(super) async fn run_stream(
    spec: StreamSpec,
    command_rx: mpsc::Receiver<StreamCommand>,
    sink: EventSink,
    aborted_sent: Arc<AtomicBool>,
) {
    if spec.hosted_tools.is_some() {
        hosted_responses::run_hosted_stream(spec, command_rx, sink, aborted_sent).await;
        return;
    }

    let spec = match request_builder::prepare_stream_spec(spec) {
        Ok(spec) => spec,
        Err(error) => {
            sink(StreamEvent::Error(error.to_json()));
            return;
        }
    };

    match spec.upstream.kind {
        UpstreamKind::HTTPSSE | UpstreamKind::HTTPEventstream => {
            run_http_stream(spec, command_rx, sink, aborted_sent).await;
        }
        UpstreamKind::WebSocketText => {
            run_websocket_stream(spec, command_rx, sink, aborted_sent).await;
        }
    }
}

async fn run_http_stream(
    spec: StreamSpec,
    command_rx: mpsc::Receiver<StreamCommand>,
    sink: EventSink,
    aborted_sent: Arc<AtomicBool>,
) {
    let mut http_stream =
        match wait_for_open_http(&spec, command_rx, sink.clone(), aborted_sent.clone()).await {
            OpenResult::Opened { stream, command_rx } => (stream, command_rx),
            OpenResult::Finished => return,
        };

    if !(200..300).contains(&http_stream.0.status) {
        let error = provider_status_error(
            &spec,
            http_stream.0.status,
            &http_stream.0.headers,
            &mut http_stream.0.body,
        )
        .await;
        sink(StreamEvent::Error(error.to_json()));
        return;
    }

    let encoder = DownstreamEncoder;
    let mut resolver =
        api_resolver::APIResolver::new(spec.api_resolver, spec.response_context.clone());
    let mut delivery = Delivery::new(
        http_stream.1,
        sink.clone(),
        encoder,
        aborted_sent,
        &spec.limits,
    );

    sink(StreamEvent::Ready(json!({
        "status": http_stream.0.status,
        "headers": transport::safe_response_headers(&http_stream.0.headers),
        "upstream_kind": spec.upstream.kind.as_str(),
        "api_resolver": spec.api_resolver.as_str(),
    })));

    match spec.upstream.kind {
        UpstreamKind::HTTPSSE => {
            let mut parser = wire::SSEParser::new(spec.limits.max_sse_event_bytes);
            let mut idle = SemanticIdle::new(spec.upstream.timeout.idle_duration());
            loop {
                if !delivery.wait_for_read_capacity().await {
                    return;
                }

                let Some(next) = delivery
                    .wait_upstream(idle.wait(http_stream.0.body.next()))
                    .await
                else {
                    return;
                };
                match next {
                    Ok(Some(Ok(bytes))) => {
                        let events = match parser.push(&bytes) {
                            Ok(events) => events,
                            Err(error) => {
                                finish_after_ready_error(delivery, &mut resolver, error).await;
                                return;
                            }
                        };

                        if !events.is_empty() {
                            idle.progressed();
                        }
                        for event in events {
                            if event.data == "[DONE]" {
                                match resolver.finish() {
                                    Ok(events) => delivery.push_events(events),
                                    Err(error) => {
                                        finish_after_ready_error(delivery, &mut resolver, error)
                                            .await;
                                        return;
                                    }
                                }
                                delivery.finish_done(summary("provider_done")).await;
                                return;
                            }

                            match sonic_rs::from_str::<Value>(&event.data) {
                                Ok(value) => {
                                    match ingest_resolver_event(&mut delivery, &mut resolver, value)
                                        .await
                                    {
                                        Ok(true) => {}
                                        Ok(false) => return,
                                        Err(error) => {
                                            finish_after_ready_error(
                                                delivery,
                                                &mut resolver,
                                                error,
                                            )
                                            .await;
                                            return;
                                        }
                                    }
                                }
                                Err(reason) => {
                                    let error = StreamError::new(
                                        "invalid_provider_event",
                                        "api_resolver",
                                        format!("SSE data was not valid JSON: {reason}"),
                                    );
                                    finish_after_ready_error(delivery, &mut resolver, error).await;
                                    return;
                                }
                            }
                        }
                    }
                    Ok(Some(Err(reason))) => {
                        let error =
                            StreamError::new("upstream_read_failed", "read", reason.to_string());
                        finish_after_ready_error(delivery, &mut resolver, error).await;
                        return;
                    }
                    Ok(None) => {
                        if let Err(error) = parser.finish() {
                            finish_after_ready_error(delivery, &mut resolver, error).await;
                            return;
                        }
                        match resolver.finish() {
                            Ok(events) => delivery.push_events(events),
                            Err(error) => {
                                finish_after_ready_error(delivery, &mut resolver, error).await;
                                return;
                            }
                        }
                        delivery.finish_done(summary("upstream_closed")).await;
                        return;
                    }
                    Err(_) => {
                        let error = StreamError::new(
                            "idle_timeout",
                            "read",
                            "upstream stream idle timeout",
                        );
                        finish_after_ready_error(delivery, &mut resolver, error).await;
                        return;
                    }
                }
            }
        }
        UpstreamKind::HTTPEventstream => {
            let mut parser =
                wire::AWSEventStreamParser::new(spec.limits.max_eventstream_frame_bytes);
            let mut idle = SemanticIdle::new(spec.upstream.timeout.idle_duration());
            loop {
                if !delivery.wait_for_read_capacity().await {
                    return;
                }

                let Some(next) = delivery
                    .wait_upstream(idle.wait(http_stream.0.body.next()))
                    .await
                else {
                    return;
                };
                match next {
                    Ok(Some(Ok(bytes))) => match parser.push(&bytes) {
                        Ok(messages) => {
                            if !messages.is_empty() {
                                idle.progressed();
                            }
                            for message in messages {
                                if matches!(
                                    message.message_type.as_deref(),
                                    Some("exception" | "error")
                                ) {
                                    let error = eventstream_provider_error(&message, &resolver);
                                    finish_after_ready_error(delivery, &mut resolver, error).await;
                                    return;
                                }

                                let event = match eventstream_event(message) {
                                    Ok(event) => event,
                                    Err(error) => {
                                        finish_after_ready_error(delivery, &mut resolver, error)
                                            .await;
                                        return;
                                    }
                                };
                                match ingest_resolver_event(&mut delivery, &mut resolver, event)
                                    .await
                                {
                                    Ok(true) => {}
                                    Ok(false) => return,
                                    Err(error) => {
                                        finish_after_ready_error(delivery, &mut resolver, error)
                                            .await;
                                        return;
                                    }
                                }
                            }
                        }
                        Err(error) => {
                            finish_after_ready_error(delivery, &mut resolver, error).await;
                            return;
                        }
                    },
                    Ok(Some(Err(reason))) => {
                        let error =
                            StreamError::new("upstream_read_failed", "read", reason.to_string());
                        finish_after_ready_error(delivery, &mut resolver, error).await;
                        return;
                    }
                    Ok(None) => {
                        if let Err(error) = parser.finish() {
                            finish_after_ready_error(delivery, &mut resolver, error).await;
                            return;
                        }

                        match resolver.finish() {
                            Ok(events) => delivery.push_events(events),
                            Err(error) => {
                                finish_after_ready_error(delivery, &mut resolver, error).await;
                                return;
                            }
                        }
                        delivery.finish_done(summary("upstream_closed")).await;
                        return;
                    }
                    Err(_) => {
                        let error = StreamError::new(
                            "idle_timeout",
                            "read",
                            "upstream eventstream idle timeout",
                        );
                        finish_after_ready_error(delivery, &mut resolver, error).await;
                        return;
                    }
                }
            }
        }
        UpstreamKind::WebSocketText => unreachable!("websocket stream is handled separately"),
    }
}

async fn run_websocket_stream(
    spec: StreamSpec,
    command_rx: mpsc::Receiver<StreamCommand>,
    sink: EventSink,
    aborted_sent: Arc<AtomicBool>,
) {
    let opened =
        wait_for_open_websocket(&spec, command_rx, sink.clone(), aborted_sent.clone()).await;
    let (mut websocket, response_headers, command_rx) = match opened {
        WebSocketOpenResult::Opened {
            websocket,
            headers,
            command_rx,
        } => (websocket, headers, command_rx),
        WebSocketOpenResult::Finished => return,
    };

    let websocket_initial_messages = websocket_initial_messages(&spec);
    for payload in &websocket_initial_messages {
        if payload.len() > spec.limits.max_websocket_text_bytes {
            sink(StreamEvent::Error(
                StreamError::new(
                    "websocket_message_too_large",
                    "connect",
                    format!(
                        "initial WebSocket text payload exceeded {} bytes",
                        spec.limits.max_websocket_text_bytes
                    ),
                )
                .provider_status(413)
                .to_json(),
            ));
            return;
        }

        if let Err(reason) = websocket.send(Message::text(payload.clone())).await {
            sink(StreamEvent::Error(
                StreamError::new(
                    "websocket_send_failed",
                    "connect",
                    format!("failed to send initial WebSocket payload: {reason}"),
                )
                .to_json(),
            ));
            return;
        }
    }

    let encoder = DownstreamEncoder;
    let mut resolver =
        api_resolver::APIResolver::new(spec.api_resolver, spec.response_context.clone());
    let mut delivery = Delivery::new(
        command_rx,
        sink.clone(),
        encoder,
        aborted_sent,
        &spec.limits,
    );

    sink(StreamEvent::Ready(json!({
        "status": 101,
        "headers": response_headers,
        "upstream_kind": spec.upstream.kind.as_str(),
        "api_resolver": spec.api_resolver.as_str(),
        "websocket_initial_messages": websocket_initial_messages.len()
    })));

    let mut idle = SemanticIdle::new(spec.upstream.timeout.idle_duration());
    loop {
        if !delivery.wait_for_read_capacity().await {
            return;
        }

        let Some(next) = delivery.wait_upstream(idle.wait(websocket.next())).await else {
            return;
        };
        match next {
            Ok(Some(Ok(Message::Text(text)))) => {
                idle.progressed();
                if text.len() > spec.limits.max_websocket_text_bytes {
                    let error = StreamError::new(
                        "websocket_message_too_large",
                        "wire",
                        format!(
                            "upstream WebSocket text payload exceeded {} bytes",
                            spec.limits.max_websocket_text_bytes
                        ),
                    )
                    .provider_status(413);
                    finish_after_ready_error(delivery, &mut resolver, error).await;
                    return;
                }

                if text == "[DONE]" {
                    match resolver.finish() {
                        Ok(events) => delivery.push_events(events),
                        Err(error) => {
                            finish_after_ready_error(delivery, &mut resolver, error).await;
                            return;
                        }
                    }
                    delivery.finish_done(summary("provider_done")).await;
                    return;
                }

                match sonic_rs::from_str::<Value>(&text) {
                    Ok(value) => {
                        match ingest_resolver_event(&mut delivery, &mut resolver, value).await {
                            Ok(true) => {}
                            Ok(false) => return,
                            Err(error) => {
                                finish_after_ready_error(delivery, &mut resolver, error).await;
                                return;
                            }
                        }
                    }
                    Err(reason) => {
                        let error = StreamError::new(
                            "invalid_provider_event",
                            "api_resolver",
                            format!("WebSocket text payload was not valid JSON: {reason}"),
                        );
                        finish_after_ready_error(delivery, &mut resolver, error).await;
                        return;
                    }
                }
            }
            Ok(Some(Ok(Message::Close(Some(frame))))) if frame.code == CloseCode::Size => {
                let error = StreamError::new(
                    "websocket_message_too_large",
                    "wire",
                    "upstream WebSocket closed because a message was too large",
                )
                .provider_status(413);
                finish_after_ready_error(delivery, &mut resolver, error).await;
                return;
            }
            Ok(Some(Ok(Message::Close(_)))) | Ok(None) => {
                match resolver.finish() {
                    Ok(events) => delivery.push_events(events),
                    Err(error) => {
                        finish_after_ready_error(delivery, &mut resolver, error).await;
                        return;
                    }
                }
                delivery.finish_done(summary("upstream_closed")).await;
                return;
            }
            Ok(Some(Ok(Message::Ping(_)))) | Ok(Some(Ok(Message::Pong(_)))) => {}
            Ok(Some(Ok(Message::Binary(bytes)))) => {
                let error = StreamError::new(
                    "unsupported_websocket_frame",
                    "wire",
                    format!(
                        "upstream WebSocket binary frame is unsupported ({} bytes)",
                        bytes.len()
                    ),
                );
                finish_after_ready_error(delivery, &mut resolver, error).await;
                return;
            }
            Ok(Some(Ok(Message::Frame(_)))) => {}
            Ok(Some(Err(reason))) => {
                let error = websocket_read_error(reason);
                finish_after_ready_error(delivery, &mut resolver, error).await;
                return;
            }
            Err(_) => {
                let error =
                    StreamError::new("idle_timeout", "read", "upstream WebSocket idle timeout");
                finish_after_ready_error(delivery, &mut resolver, error).await;
                return;
            }
        }
    }
}

pub(super) fn websocket_read_error(reason: WebSocketError) -> StreamError {
    match reason {
        WebSocketError::Capacity(CapacityError::MessageTooLong { size, max_size }) => {
            StreamError::new(
                "websocket_message_too_large",
                "wire",
                format!("upstream WebSocket message exceeded {max_size} bytes ({size} bytes)"),
            )
            .provider_status(413)
        }
        reason => StreamError::new("websocket_read_failed", "read", reason.to_string()),
    }
}

enum OpenResult {
    Opened {
        stream: transport::HTTPStream,
        command_rx: mpsc::Receiver<StreamCommand>,
    },
    Finished,
}

async fn wait_for_open_http(
    spec: &StreamSpec,
    mut command_rx: mpsc::Receiver<StreamCommand>,
    sink: EventSink,
    aborted_sent: Arc<AtomicBool>,
) -> OpenResult {
    let open = transport::open_http_stream(spec);
    tokio::pin!(open);

    loop {
        tokio::select! {
            result = &mut open => {
                return match result {
                    Ok(stream) => OpenResult::Opened { stream, command_rx },
                    Err(error) => {
                        sink(StreamEvent::Error(error.to_json()));
                        OpenResult::Finished
                    }
                };
            },
            command = command_rx.recv() => {
                if matches!(command, Some(StreamCommand::Cancel) | None) {
                    send_aborted_once(&sink, &aborted_sent);
                    return OpenResult::Finished;
                }
            }
        }
    }
}

enum WebSocketOpenResult {
    Opened {
        websocket: Box<transport::UpstreamWebSocket>,
        headers: Vec<(String, String)>,
        command_rx: mpsc::Receiver<StreamCommand>,
    },
    Finished,
}

async fn wait_for_open_websocket(
    spec: &StreamSpec,
    mut command_rx: mpsc::Receiver<StreamCommand>,
    sink: EventSink,
    aborted_sent: Arc<AtomicBool>,
) -> WebSocketOpenResult {
    let open = transport::open_websocket(spec);
    tokio::pin!(open);

    loop {
        tokio::select! {
            result = &mut open => {
                return match result {
                    Ok((websocket, 101, headers)) => {
                        WebSocketOpenResult::Opened {
                            websocket: Box::new(websocket),
                            headers,
                            command_rx
                        }
                    }
                    Ok((_websocket, status, headers)) => {
                        sink(StreamEvent::Error(StreamError::new(
                            "websocket_status_rejected",
                            "connect",
                            format!("upstream WebSocket returned status {status}"),
                        )
                        .provider_status(status)
                        .provider_headers(&headers)
                        .to_json()));
                        WebSocketOpenResult::Finished
                    }
                    Err(error) => {
                        sink(StreamEvent::Error(error.to_json()));
                        WebSocketOpenResult::Finished
                    }
                };
            },
            command = command_rx.recv() => {
                if matches!(command, Some(StreamCommand::Cancel) | None) {
                    send_aborted_once(&sink, &aborted_sent);
                    return WebSocketOpenResult::Finished;
                }
            }
        }
    }
}

pub(super) fn decode_response_body(body: &[u8]) -> Result<Value, StreamError> {
    sonic_rs::from_slice::<Value>(body).map_err(|reason| {
        StreamError::new(
            "invalid_upstream_response",
            "api_resolver",
            format!("upstream response body must contain valid JSON: {reason}"),
        )
        .provider_status(200)
        .provider_body_excerpt(body)
    })
}

pub(super) fn decode_raw_response_body(body: &[u8]) -> Value {
    sonic_rs::from_slice::<Value>(body).unwrap_or_else(|_| {
        String::from_utf8(body.to_vec())
            .map(Value::String)
            .unwrap_or_else(|_| Value::String(String::from_utf8_lossy(body).to_string()))
    })
}

pub(super) fn send_aborted_once(sink: &EventSink, aborted_sent: &AtomicBool) {
    if !aborted_sent.swap(true, Ordering::SeqCst) {
        sink(StreamEvent::Aborted);
    }
}

pub(super) fn websocket_initial_messages(spec: &StreamSpec) -> Vec<String> {
    if spec.upstream.websocket_initial_messages.is_empty() {
        spec.upstream.body.clone().into_iter().collect()
    } else {
        spec.upstream.websocket_initial_messages.clone()
    }
}

fn eventstream_event(message: wire::EventStreamMessage) -> Result<Value, StreamError> {
    let Some(event_type) = message.event_type else {
        return Err(StreamError::new(
            "invalid_provider_event",
            "api_resolver",
            "AWS eventstream event has no :event-type header",
        ));
    };
    let payload = sonic_rs::from_slice::<Value>(&message.payload).map_err(|reason| {
        StreamError::new(
            "invalid_provider_event",
            "api_resolver",
            format!("AWS eventstream payload was not valid JSON: {reason}"),
        )
    })?;
    Ok(json!({ event_type: payload }))
}

fn eventstream_provider_error(
    message: &wire::EventStreamMessage,
    resolver: &api_resolver::APIResolver,
) -> StreamError {
    let provider_type = message
        .exception_type
        .as_deref()
        .or(message.error_code.as_deref());
    let provider_message = message
        .error_message
        .clone()
        .or_else(|| {
            sonic_rs::from_slice::<Value>(&message.payload)
                .ok()
                .and_then(|value| {
                    value
                        .get("message")
                        .or_else(|| value.get("Message"))
                        .or_else(|| value.get("error"))
                        .and_then(Value::as_str)
                        .map(ToOwned::to_owned)
                })
        })
        .or_else(|| provider_type.map(ToOwned::to_owned))
        .unwrap_or_else(|| "AWS eventstream error".to_string());

    let mut error = StreamError::new("provider_eventstream_error", "read", provider_message)
        .provider_body_excerpt(&message.payload);
    if let Some(provider_type) = provider_type {
        error = error.provider_error_type(provider_type);
    }
    if let Some(status) = message
        .exception_type
        .as_deref()
        .and_then(|exception_type| resolver.provider_exception_status(exception_type))
    {
        error = error.provider_status(status);
    }
    error
}

async fn provider_status_error(
    spec: &StreamSpec,
    status: u16,
    headers: &[(String, String)],
    body: &mut futures_util::stream::BoxStream<'static, Result<bytes::Bytes, reqwest::Error>>,
) -> StreamError {
    let mut excerpt = Vec::new();

    while excerpt.len() < 4096 {
        match timeout(spec.upstream.timeout.idle_duration(), body.next()).await {
            Ok(Some(Ok(bytes))) => {
                let remaining = 4096 - excerpt.len();
                excerpt.extend_from_slice(&bytes[..bytes.len().min(remaining)]);
            }
            _ => break,
        }
    }

    let resolver = api_resolver::APIResolver::new(spec.api_resolver, spec.response_context.clone());

    resolver
        .classify_provider_rejection(status, &excerpt)
        .unwrap_or_else(|| {
            StreamError::new(
                "provider_status_rejected",
                "connect",
                format!("upstream returned HTTP status {status}"),
            )
        })
        .provider_status(status)
        .provider_body_excerpt(excerpt)
        .provider_headers(headers)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::universal_ai_client::spec::{APIResolverKind, ResponseContext};

    #[test]
    fn bedrock_stream_exceptions_report_their_type_and_declared_status() {
        let resolver = api_resolver::APIResolver::new(
            APIResolverKind::BedrockConverse,
            ResponseContext::default(),
        );

        for (exception_type, status) in [
            ("internalServerException", Some(500)),
            ("modelStreamErrorException", Some(424)),
            ("serviceUnavailableException", Some(503)),
            ("throttlingException", Some(429)),
            ("validationException", Some(400)),
            ("undeclaredException", None),
        ] {
            let message = wire::EventStreamMessage {
                message_type: Some("exception".to_string()),
                exception_type: Some(exception_type.to_string()),
                payload: br#"{"message":"provider message"}"#.to_vec(),
                ..wire::EventStreamMessage::default()
            };

            let error = eventstream_provider_error(&message, &resolver);

            assert_eq!(error.code, "provider_eventstream_error");
            assert_eq!(error.message, "provider message");
            assert_eq!(error.provider_status, status, "{exception_type}");
            assert_eq!(error.provider_error_type.as_deref(), Some(exception_type));
        }
    }

    #[test]
    fn eventstream_error_frames_report_their_header_code_and_message() {
        let resolver = api_resolver::APIResolver::new(
            APIResolverKind::BedrockConverse,
            ResponseContext::default(),
        );
        let message = wire::EventStreamMessage {
            message_type: Some("error".to_string()),
            error_code: Some("InternalFailure".to_string()),
            error_message: Some("internal failure".to_string()),
            ..wire::EventStreamMessage::default()
        };

        let error = eventstream_provider_error(&message, &resolver);

        assert_eq!(error.message, "internal failure");
        assert_eq!(
            error.provider_error_type.as_deref(),
            Some("InternalFailure")
        );
        assert_eq!(error.provider_status, None);
    }
}
