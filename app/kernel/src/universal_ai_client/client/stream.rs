use std::collections::{BTreeMap, VecDeque};
use std::future::Future;
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
use crate::common::KernelError;
use crate::universal_ai_client::downstream::{DownstreamChunk, DownstreamEncoder};
use crate::universal_ai_client::error::StreamError;
use crate::universal_ai_client::spec::{StreamLimits, StreamSpec, UpstreamKind};
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

    let encoder = DownstreamEncoder::new(spec.downstream);
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
        "headers": transport::codex_response_headers(&http_stream.0.headers),
        "upstream_kind": spec.upstream.kind.as_str(),
        "downstream_kind": spec.downstream.as_str(),
        "api_resolver": spec.api_resolver.as_str(),
        "http_version": http_stream.0.version,
        "http_negotiation": http_stream.0.negotiation
    })));

    match spec.upstream.kind {
        UpstreamKind::HTTPSSE => {
            let mut parser = wire::SSEParser::new(spec.limits.max_sse_event_bytes);
            loop {
                if !delivery.wait_for_read_capacity().await {
                    return;
                }

                let next = timeout(
                    spec.upstream.timeout.idle_duration(),
                    http_stream.0.body.next(),
                );
                let Some(next) = delivery.wait_upstream(next).await else {
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
                                Ok(value) => match resolver.ingest(value) {
                                    Ok(events) => {
                                        if !flush_resolver_events(&mut delivery, &resolver, events)
                                            .await
                                        {
                                            return;
                                        }
                                    }
                                    Err(error) => {
                                        finish_after_ready_error(delivery, &mut resolver, error)
                                            .await;
                                        return;
                                    }
                                },
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
                            StreamError::new("upstream_read_failed", "read", reason.to_string())
                                .retry_through_credential_pool();
                        finish_after_ready_error(delivery, &mut resolver, error).await;
                        return;
                    }
                    Ok(None) => match parser.finish() {
                        Ok(events) => {
                            for event in events {
                                match sonic_rs::from_str::<Value>(&event.data) {
                                    Ok(value) => match resolver.ingest(value) {
                                        Ok(events) => {
                                            if !flush_resolver_events(
                                                &mut delivery,
                                                &resolver,
                                                events,
                                            )
                                            .await
                                            {
                                                return;
                                            }
                                        }
                                        Err(error) => {
                                            finish_after_ready_error(
                                                delivery,
                                                &mut resolver,
                                                error,
                                            )
                                            .await;
                                            return;
                                        }
                                    },
                                    Err(reason) => {
                                        let error = StreamError::new(
                                            "invalid_provider_event",
                                            "api_resolver",
                                            format!("SSE data was not valid JSON: {reason}"),
                                        );
                                        finish_after_ready_error(delivery, &mut resolver, error)
                                            .await;
                                        return;
                                    }
                                }
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
                        Err(error) => {
                            finish_after_ready_error(delivery, &mut resolver, error).await;
                            return;
                        }
                    },
                    Err(_) => {
                        let error = StreamError::new(
                            "idle_timeout",
                            "read",
                            "upstream stream idle timeout",
                        )
                        .retry_through_credential_pool();
                        finish_after_ready_error(delivery, &mut resolver, error).await;
                        return;
                    }
                }
            }
        }
        UpstreamKind::HTTPEventstream => {
            let mut parser =
                wire::AWSEventStreamParser::new(spec.limits.max_eventstream_frame_bytes);
            loop {
                if !delivery.wait_for_read_capacity().await {
                    return;
                }

                let next = timeout(
                    spec.upstream.timeout.idle_duration(),
                    http_stream.0.body.next(),
                );
                let Some(next) = delivery.wait_upstream(next).await else {
                    return;
                };
                match next {
                    Ok(Some(Ok(bytes))) => match parser.push(&bytes) {
                        Ok(messages) => {
                            for message in messages {
                                if matches!(
                                    message.message_type.as_deref(),
                                    Some("exception" | "error")
                                ) {
                                    let error = eventstream_provider_error(&message);
                                    finish_after_ready_error(delivery, &mut resolver, error).await;
                                    return;
                                }

                                match sonic_rs::from_slice::<Value>(&message.payload) {
                                    Ok(value) => match resolver.ingest(value) {
                                        Ok(events) => {
                                            if !flush_resolver_events(
                                                &mut delivery,
                                                &resolver,
                                                events,
                                            )
                                            .await
                                            {
                                                return;
                                            }
                                        }
                                        Err(error) => {
                                            finish_after_ready_error(
                                                delivery,
                                                &mut resolver,
                                                error,
                                            )
                                            .await;
                                            return;
                                        }
                                    },
                                    Err(reason) => {
                                        let error = StreamError::new(
                                            "invalid_provider_event",
                                            "api_resolver",
                                            format!(
                                                "AWS eventstream payload was not valid JSON: {reason}"
                                            ),
                                        );
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
                            StreamError::new("upstream_read_failed", "read", reason.to_string())
                                .retry_through_credential_pool();
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
                        )
                        .retry_through_credential_pool();
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

    let encoder = DownstreamEncoder::new(spec.downstream);
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
        "downstream_kind": spec.downstream.as_str(),
        "api_resolver": spec.api_resolver.as_str(),
        "websocket_initial_messages": websocket_initial_messages.len()
    })));

    loop {
        if !delivery.wait_for_read_capacity().await {
            return;
        }

        let next = timeout(spec.upstream.timeout.idle_duration(), websocket.next());
        let Some(next) = delivery.wait_upstream(next).await else {
            return;
        };
        match next {
            Ok(Some(Ok(Message::Text(text)))) => {
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
                    Ok(value) => match resolver.ingest(value) {
                        Ok(events) => {
                            if !flush_resolver_events(&mut delivery, &resolver, events).await {
                                return;
                            }
                        }
                        Err(error) => {
                            finish_after_ready_error(delivery, &mut resolver, error).await;
                            return;
                        }
                    },
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
                    StreamError::new("idle_timeout", "read", "upstream WebSocket idle timeout")
                        .retry_through_credential_pool();
                finish_after_ready_error(delivery, &mut resolver, error).await;
                return;
            }
        }
    }
}

pub(in crate::universal_ai_client) async fn run_websocket_model_request_once(
    mut spec: StreamSpec,
) -> Result<Value, StreamError> {
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

    loop {
        match timeout(spec.upstream.timeout.idle_duration(), websocket.next()).await {
            Ok(Some(Ok(Message::Text(text)))) => {
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

                if let Some(body) = collected_terminal_body(&events, &completed_items) {
                    ensure_collected_body_size(&body, spec.limits.max_pending_bytes)?;
                    return Ok(json!({
                        "status": status,
                        "headers": response_headers,
                        "body": body,
                        "raw_body_bytes": raw_body_bytes,
                        "upstream_kind": spec.upstream.kind.as_str(),
                        "websocket_initial_messages": initial_messages.len()
                    }));
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
                )
                .retry_through_credential_pool());
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

fn collected_terminal_body(
    events: &[Value],
    completed_items: &BTreeMap<usize, Value>,
) -> Option<Value> {
    events.iter().find_map(|event| {
        let event_type = event.get("type").and_then(Value::as_str)?;
        if !matches!(
            event_type,
            "response.completed" | "response.failed" | "response.incomplete"
        ) {
            return None;
        }

        let mut response = event
            .get("response")
            .filter(|value| value.is_object())?
            .clone();
        reconcile_terminal_items(&mut response, completed_items);
        Some(response)
    })
}

fn reconcile_terminal_items(response: &mut Value, completed_items: &BTreeMap<usize, Value>) {
    let Some(response) = response.as_object_mut() else {
        return;
    };
    let items = response
        .entry("output".to_string())
        .or_insert_with(|| Value::Array(Vec::new()));
    let Some(items) = items.as_array_mut() else {
        return;
    };

    for (output_index, item) in items.iter_mut().enumerate() {
        let Some(recorded_item) = completed_items.get(&output_index) else {
            continue;
        };
        if terminal_item_subset(item, recorded_item) {
            *item = recorded_item.clone();
        }
    }

    while let Some(recorded_item) = completed_items.get(&items.len()) {
        items.push(recorded_item.clone());
    }
}

fn terminal_item_subset(item: &Value, recorded_item: &Value) -> bool {
    let (Some(item), Some(recorded_item)) = (item.as_object(), recorded_item.as_object()) else {
        return false;
    };
    if item.get("id").and_then(Value::as_str).is_some() {
        return false;
    }
    let Some(item_type) = item.get("type").and_then(Value::as_str) else {
        return false;
    };
    if recorded_item.get("type").and_then(Value::as_str) != Some(item_type) {
        return false;
    }

    let snapshot = item
        .iter()
        .filter(|(key, _value)| key.as_str() != "id")
        .collect::<Vec<_>>();
    !snapshot.is_empty()
        && snapshot
            .into_iter()
            .all(|(key, value)| recorded_item.get(key) == Some(value))
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

fn websocket_read_error(reason: WebSocketError) -> StreamError {
    match reason {
        WebSocketError::Capacity(CapacityError::MessageTooLong { size, max_size }) => {
            StreamError::new(
                "websocket_message_too_large",
                "wire",
                format!("upstream WebSocket message exceeded {max_size} bytes ({size} bytes)"),
            )
            .provider_status(413)
        }
        reason => StreamError::new("websocket_read_failed", "read", reason.to_string())
            .retry_through_credential_pool(),
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

pub(in crate::universal_ai_client) struct Delivery {
    pub(in crate::universal_ai_client) command_rx: mpsc::Receiver<StreamCommand>,
    sink: EventSink,
    encoder: DownstreamEncoder,
    pending: VecDeque<DownstreamChunk>,
    pending_bytes: usize,
    max_pending_chunks: usize,
    max_pending_bytes: usize,
    credit: u64,
    seq: u64,
    aborted_sent: Arc<AtomicBool>,
}

impl Delivery {
    pub(in crate::universal_ai_client) fn new(
        command_rx: mpsc::Receiver<StreamCommand>,
        sink: EventSink,
        encoder: DownstreamEncoder,
        aborted_sent: Arc<AtomicBool>,
        limits: &StreamLimits,
    ) -> Self {
        Self {
            command_rx,
            sink,
            encoder,
            pending: VecDeque::new(),
            pending_bytes: 0,
            max_pending_chunks: limits.max_pending_chunks.max(1),
            max_pending_bytes: limits.max_pending_bytes.max(1),
            credit: 0,
            seq: 0,
            aborted_sent,
        }
    }

    fn push_events(&mut self, events: Vec<Value>) {
        for event in events {
            self.push_chunk(self.encoder.encode_event(&event));
        }
    }

    pub(in crate::universal_ai_client) async fn push_events_bounded(
        &mut self,
        events: Vec<Value>,
    ) -> bool {
        for event in events {
            let chunk = self.encoder.encode_event(&event);

            if chunk.bytes.len() > self.max_pending_bytes {
                return false;
            }

            self.flush_pending_available();
            while !self.has_capacity_for(chunk.bytes.len()) {
                let command = self.command_rx.recv().await;
                if !self.handle_command(command) {
                    return false;
                }
                self.flush_pending_available();
            }

            self.push_chunk(chunk);
            self.flush_pending_available();
        }

        true
    }

    fn push_chunk(&mut self, chunk: DownstreamChunk) {
        self.pending_bytes = self.pending_bytes.saturating_add(chunk.bytes.len());
        self.pending.push_back(chunk);
    }

    async fn wait_for_read_capacity(&mut self) -> bool {
        self.flush_pending_available();

        while !self.has_pending_capacity() {
            let command = self.command_rx.recv().await;
            if !self.handle_command(command) {
                return false;
            }
            self.flush_pending_available();
        }

        true
    }

    fn has_pending_capacity(&self) -> bool {
        self.pending.is_empty()
            || (self.pending.len() < self.max_pending_chunks
                && self.pending_bytes < self.max_pending_bytes)
    }

    fn has_capacity_for(&self, bytes: usize) -> bool {
        self.pending.len() < self.max_pending_chunks
            && self.pending_bytes.saturating_add(bytes) <= self.max_pending_bytes
    }

    async fn wait_upstream<F, T>(&mut self, future: F) -> Option<T>
    where
        F: Future<Output = T>,
    {
        tokio::pin!(future);

        loop {
            tokio::select! {
                result = &mut future => return Some(result),
                command = self.command_rx.recv() => {
                    if !self.handle_command(command) {
                        return None;
                    }
                    self.flush_pending_available();
                }
            }
        }
    }

    pub(in crate::universal_ai_client) fn flush_pending_available(&mut self) {
        while self.credit > 0 && !self.pending.is_empty() {
            self.deliver_next_chunk();
        }
    }

    async fn flush_pending_blocking(&mut self) -> bool {
        loop {
            self.flush_pending_available();
            if self.pending.is_empty() {
                return true;
            }

            if self.credit == 0 {
                let command = self.command_rx.recv().await;
                if !self.handle_command(command) {
                    return false;
                }
                continue;
            }
        }
    }

    fn deliver_next_chunk(&mut self) {
        let Some(chunk) = self.pending.pop_front() else {
            return;
        };
        self.pending_bytes = self.pending_bytes.saturating_sub(chunk.bytes.len());
        self.credit = self.credit.saturating_sub(1);
        self.seq += 1;
        (self.sink)(StreamEvent::Chunk {
            seq: self.seq,
            kind: chunk.kind,
            bytes: chunk.bytes,
        });
    }

    pub(in crate::universal_ai_client) async fn finish_done(mut self, summary: Value) {
        let _ = self.finish_done_pending(summary).await;
    }

    async fn finish_done_pending(&mut self, summary: Value) -> bool {
        if let Some(chunk) = self.encoder.encode_done_sentinel() {
            self.push_chunk(chunk);
        }

        if self.flush_pending_blocking().await {
            (self.sink)(StreamEvent::Done(summary));
            true
        } else {
            false
        }
    }

    async fn finish_error_events(self, events: Vec<Value>, error: StreamError) {
        self.finish_error_events_with_metadata(events, error, None)
            .await;
    }

    pub(in crate::universal_ai_client) async fn finish_error_events_with_metadata(
        mut self,
        events: Vec<Value>,
        error: StreamError,
        metadata: Option<Value>,
    ) {
        if events.is_empty() {
            self.push_chunk(self.encoder.encode_error(&error));
        } else {
            self.push_events(events);
        }

        if let Some(chunk) = self.encoder.encode_done_sentinel() {
            self.push_chunk(chunk);
        }

        if self.flush_pending_blocking().await {
            let mut error_json = error.to_json();
            if let Some(metadata) = metadata {
                error_json["hosted_tool_metadata"] = metadata;
            }
            (self.sink)(StreamEvent::Error(error_json));
        }
    }

    pub(in crate::universal_ai_client) async fn finish_native_error_with_metadata(
        mut self,
        error: StreamError,
        metadata: Option<Value>,
    ) {
        if self.flush_pending_blocking().await {
            let mut error_json = error.to_json();
            if let Some(metadata) = metadata {
                error_json["hosted_tool_metadata"] = metadata;
            }
            (self.sink)(StreamEvent::Error(error_json));
        }
    }

    pub(in crate::universal_ai_client) fn handle_command(
        &mut self,
        command: Option<StreamCommand>,
    ) -> bool {
        match command {
            Some(StreamCommand::Demand(count)) => {
                self.credit = self.credit.saturating_add(count);
                true
            }
            Some(StreamCommand::Cancel) | None => {
                send_aborted_once(&self.sink, &self.aborted_sent);
                false
            }
        }
    }
}

fn summary(reason: &str) -> Value {
    json!({ "reason": reason })
}

async fn flush_resolver_events(
    delivery: &mut Delivery,
    resolver: &api_resolver::APIResolver,
    events: Vec<Value>,
) -> bool {
    delivery.push_events(events);

    if resolver.is_terminal() {
        delivery
            .finish_done_pending(summary("provider_terminal"))
            .await;
        false
    } else {
        delivery.flush_pending_available();
        true
    }
}

pub(super) fn command_send_error(error: mpsc::error::TrySendError<StreamCommand>) -> KernelError {
    match error {
        mpsc::error::TrySendError::Full(_) => {
            KernelError::new("universal AI client command queue is full")
        }
        mpsc::error::TrySendError::Closed(_) => {
            KernelError::new("universal AI client stream is closed")
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

fn websocket_initial_messages(spec: &StreamSpec) -> Vec<String> {
    if spec.upstream.websocket_initial_messages.is_empty() {
        spec.upstream.body.clone().into_iter().collect()
    } else {
        spec.upstream.websocket_initial_messages.clone()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn terminal_output_uses_completed_items_when_the_provider_omits_it() {
        let completed_items = BTreeMap::from([
            (
                0,
                json!({
                    "id": "msg_complete",
                    "type": "message",
                    "role": "assistant",
                    "status": "completed",
                    "content": [{"type": "output_text", "text": "done"}]
                }),
            ),
            (
                1,
                json!({
                    "id": "fc_complete",
                    "type": "function_call",
                    "call_id": "call_complete",
                    "name": "command",
                    "arguments": "{}",
                    "status": "completed"
                }),
            ),
        ]);
        let mut response = json!({"id": "resp_complete", "status": "completed", "output": []});

        reconcile_terminal_items(&mut response, &completed_items);

        assert_eq!(response["output"].as_array().unwrap().len(), 2);
        assert_eq!(response["output"][0], completed_items[&0]);
        assert_eq!(response["output"][1], completed_items[&1]);
    }

    #[test]
    fn terminal_output_does_not_replace_a_conflicting_authoritative_item() {
        let completed_items = BTreeMap::from([(
            0,
            json!({
                "id": "msg_streamed",
                "type": "message",
                "role": "assistant",
                "status": "completed",
                "content": [{"type": "output_text", "text": "streamed"}]
            }),
        )]);
        let terminal_item = json!({
            "id": "msg_terminal",
            "type": "message",
            "role": "assistant",
            "status": "completed",
            "content": [{"type": "output_text", "text": "terminal"}]
        });
        let mut response = json!({"output": [terminal_item.clone()]});

        reconcile_terminal_items(&mut response, &completed_items);

        assert_eq!(response["output"][0], terminal_item);
    }
}

async fn finish_after_ready_error(
    delivery: Delivery,
    resolver: &mut api_resolver::APIResolver,
    error: StreamError,
) {
    let events = resolver.fail(&error);
    delivery.finish_error_events(events, error).await;
}

fn eventstream_provider_error(message: &wire::EventStreamMessage) -> StreamError {
    let provider_message = sonic_rs::from_slice::<Value>(&message.payload)
        .ok()
        .and_then(|value| {
            value
                .get("message")
                .or_else(|| value.get("Message"))
                .or_else(|| value.get("error"))
                .and_then(Value::as_str)
                .map(ToOwned::to_owned)
        })
        .unwrap_or_else(|| {
            message
                .event_type
                .as_deref()
                .unwrap_or("AWS eventstream error")
                .to_string()
        });

    StreamError::new("provider_eventstream_error", "read", provider_message)
        .provider_body_excerpt(&message.payload)
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

    StreamError::new(
        "provider_status_rejected",
        "connect",
        format!("upstream returned HTTP status {status}"),
    )
    .provider_status(status)
    .provider_body_excerpt(excerpt)
    .provider_headers(headers)
}
