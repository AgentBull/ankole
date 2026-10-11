use std::io::{Read, Write};
use std::net::TcpListener as StdTCPListener;
use std::sync::{Arc, mpsc};
use std::thread;
use std::time::Duration;

use super::*;
use crate::universal_ai_client::wire::tests::eventstream_frame;
use serde_json::Value;
use tokio_tungstenite::tungstenite::protocol::frame::coding::CloseCode;
use tokio_tungstenite::tungstenite::{Message, accept};

#[test]
fn stream_spec_parses_prepared_request_contract() {
    let spec = StreamSpec::from_json(
        r#"{
              "api_resolver": "openai_chat_completions",
              "upstream": {
                "kind": "http_sse",
                "method": "POST",
                "url": "https://example.test/v1/chat/completions",
                "headers": [["authorization", "Bearer test"]],
                "body": "{\"stream\":true}",
                "timeout": {"connect_ms": 1, "first_byte_ms": 1, "idle_ms": 1},
                "transport": {}
              },
              "response_context": {"model": "gpt-test", "request": {"input": "hi"}}
            }"#,
    )
    .unwrap();

    assert_eq!(spec.api_resolver, APIResolverKind::OpenAIChatCompletions);
    assert_eq!(spec.upstream.kind, UpstreamKind::HTTPSSE);
    assert_eq!(spec.upstream.headers[0].0, "authorization");
}

#[test]
fn websocket_stream_sends_body_as_initial_response_create_message() {
    let listener = StdTCPListener::bind("127.0.0.1:0").unwrap();
    let address = listener.local_addr().unwrap();
    let (initial_tx, initial_rx) = mpsc::channel::<String>();

    thread::spawn(move || {
        let (socket, _) = listener.accept().unwrap();
        let mut websocket = accept(socket).unwrap();

        if let Ok(Message::Text(text)) = websocket.read() {
            initial_tx.send(text.to_string()).unwrap();
        }

        websocket
                .send(Message::Text(
                    r#"{"type":"response.created","response":{"id":"resp_ws","object":"response","status":"in_progress","output":[],"usage":{}}}"#.into(),
                ))
                .unwrap();
        websocket
                .send(Message::Text(
                    r#"{"type":"response.completed","response":{"id":"resp_ws","object":"response","status":"completed","output":[],"usage":{}}}"#.into(),
                ))
                .unwrap();
    });

    let (event_tx, event_rx) = mpsc::channel();
    let sink: EventSink = Arc::new(move |event| {
        event_tx.send(event).unwrap();
    });

    let spec = format!(
        r#"{{
              "api_resolver": "openai_responses",
              "upstream": {{
                "kind": "websocket_text",
                "method": "GET",
                "url": "ws://{address}/v1/responses",
                "headers": [],
                "timeout": {{"connect_ms": 1000, "first_byte_ms": 1000, "idle_ms": 1000}},
                "transport": {{}}
              }},
              "response_context": {{"model": "gpt-test", "request": {{"input": "hi"}}}}
            }}"#
    );

    let handle = start_stream(&spec, sink).unwrap();
    let initial: Value =
        sonic_rs::from_str(&initial_rx.recv_timeout(Duration::from_secs(1)).unwrap()).unwrap();
    assert_eq!(initial["type"], "response.create");
    assert_eq!(initial["model"], "gpt-test");
    assert_eq!(initial["input"], "hi");

    match event_rx.recv_timeout(Duration::from_secs(1)).unwrap() {
        StreamEvent::Ready(meta) => {
            assert_eq!(meta["upstream_kind"], "websocket_text");
            assert_eq!(meta["websocket_initial_messages"], 1);
        }
        event => panic!("expected ready event, got {event:?}"),
    }

    handle.read(2).unwrap();
    let first = chunk_event(&event_rx);
    let second = chunk_event(&event_rx);

    assert_eq!(first["type"], "response.created");
    assert_eq!(second["type"], "response.completed");

    match event_rx.recv_timeout(Duration::from_secs(1)).unwrap() {
        StreamEvent::Done(summary) => assert_eq!(summary["reason"], "provider_terminal"),
        event => panic!("expected done event, got {event:?}"),
    }
}

#[test]
fn http_sse_stream_finishes_on_terminal_event_without_done_or_close() {
    let listener = StdTCPListener::bind("127.0.0.1:0").unwrap();
    let address = listener.local_addr().unwrap();

    thread::spawn(move || {
        let (mut socket, _) = listener.accept().unwrap();
        let mut buffer = [0_u8; 1024];
        let _ = socket.read(&mut buffer).unwrap();

        let body = concat!(
            "event: response.completed\n",
            "data: {\"type\":\"response.completed\",\"response\":{\"id\":\"resp_sse\",\"object\":\"response\",\"status\":\"completed\",\"output\":[],\"usage\":{}}}\n\n"
        );
        let chunk = format!("{:x}\r\n{}\r\n", body.len(), body);
        socket
                .write_all(
                    format!(
                        "HTTP/1.1 200 OK\r\ncontent-type: text/event-stream\r\ntransfer-encoding: chunked\r\n\r\n{chunk}"
                    )
                    .as_bytes(),
                )
                .unwrap();
        socket.flush().unwrap();
        thread::sleep(Duration::from_secs(2));
    });

    let (event_tx, event_rx) = mpsc::channel();
    let sink: EventSink = Arc::new(move |event| {
        event_tx.send(event).unwrap();
    });

    let spec = format!(
        r#"{{
              "api_resolver": "openai_responses",
              "upstream": {{
                "kind": "http_sse",
                "method": "POST",
                "url": "http://{address}/v1/responses",
                "headers": [],
                "body": "{{\"stream\":true}}",
                "timeout": {{"connect_ms": 1000, "first_byte_ms": 1000, "idle_ms": 5000}},
                "transport": {{}}
              }},
              "response_context": {{"model": "gpt-test", "request": {{}}}}
            }}"#
    );

    let handle = start_stream(&spec, sink).unwrap();

    match event_rx.recv_timeout(Duration::from_secs(1)).unwrap() {
        StreamEvent::Ready(meta) => assert_eq!(meta["upstream_kind"], "http_sse"),
        event => panic!("expected ready event, got {event:?}"),
    }

    handle.read(2).unwrap();
    let first = chunk_event(&event_rx);
    assert_eq!(first["type"], "response.completed");

    match event_rx.recv_timeout(Duration::from_secs(1)).unwrap() {
        StreamEvent::Done(summary) => assert_eq!(summary["reason"], "provider_terminal"),
        event => panic!("expected done event, got {event:?}"),
    }
}

#[test]
fn http_sse_stream_reads_ahead_but_waits_for_downstream_demand() {
    let listener = StdTCPListener::bind("127.0.0.1:0").unwrap();
    let address = listener.local_addr().unwrap();

    thread::spawn(move || {
        let (mut socket, _) = listener.accept().unwrap();
        let mut buffer = [0_u8; 1024];
        let _ = socket.read(&mut buffer).unwrap();

        let body = concat!(
            "event: response.completed\n",
            "data: {\"type\":\"response.completed\",\"response\":{\"id\":\"resp_sse\",\"object\":\"response\",\"status\":\"completed\",\"output\":[],\"usage\":{}}}\n\n"
        );
        let chunk = format!("{:x}\r\n{}\r\n", body.len(), body);
        socket
                .write_all(
                    format!(
                        "HTTP/1.1 200 OK\r\ncontent-type: text/event-stream\r\ntransfer-encoding: chunked\r\n\r\n{chunk}"
                    )
                    .as_bytes(),
                )
                .unwrap();
        socket.flush().unwrap();
        thread::sleep(Duration::from_millis(300));
    });

    let (event_tx, event_rx) = mpsc::channel();
    let sink: EventSink = Arc::new(move |event| {
        event_tx.send(event).unwrap();
    });

    let spec = format!(
        r#"{{
              "api_resolver": "openai_responses",
              "upstream": {{
                "kind": "http_sse",
                "method": "POST",
                "url": "http://{address}/v1/responses",
                "headers": [],
                "body": "{{\"stream\":true}}",
                "timeout": {{"connect_ms": 1000, "first_byte_ms": 1000, "idle_ms": 5000}},
                "transport": {{}}
              }},
              "response_context": {{"model": "gpt-test", "request": {{}}}},
              "limits": {{"max_pending_chunks": 8, "max_pending_bytes": 4096}}
            }}"#
    );

    let handle = start_stream(&spec, sink).unwrap();

    match event_rx.recv_timeout(Duration::from_secs(1)).unwrap() {
        StreamEvent::Ready(meta) => assert_eq!(meta["upstream_kind"], "http_sse"),
        event => panic!("expected ready event, got {event:?}"),
    }

    assert!(event_rx.recv_timeout(Duration::from_millis(100)).is_err());

    handle.read(2).unwrap();
    assert_eq!(chunk_event(&event_rx)["type"], "response.completed");

    match event_rx.recv_timeout(Duration::from_secs(1)).unwrap() {
        StreamEvent::Done(summary) => assert_eq!(summary["reason"], "provider_terminal"),
        event => panic!("expected done event, got {event:?}"),
    }
}

#[test]
fn websocket_binary_frame_after_ready_becomes_protocol_error_chunks() {
    let listener = StdTCPListener::bind("127.0.0.1:0").unwrap();
    let address = listener.local_addr().unwrap();

    thread::spawn(move || {
        let (socket, _) = listener.accept().unwrap();
        let mut websocket = accept(socket).unwrap();
        websocket
            .send(Message::Binary(vec![1_u8, 2, 3].into()))
            .unwrap();
    });

    let (event_tx, event_rx) = mpsc::channel();
    let sink: EventSink = Arc::new(move |event| {
        event_tx.send(event).unwrap();
    });

    let spec = format!(
        r#"{{
              "api_resolver": "openai_responses",
              "upstream": {{
                "kind": "websocket_text",
                "method": "GET",
                "url": "ws://{address}/v1/responses",
                "headers": [],
                "timeout": {{"connect_ms": 1000, "first_byte_ms": 1000, "idle_ms": 1000}},
                "transport": {{}}
              }},
              "response_context": {{"model": "gpt-test", "request": {{}}}}
            }}"#
    );

    let handle = start_stream(&spec, sink).unwrap();

    match event_rx.recv_timeout(Duration::from_secs(1)).unwrap() {
        StreamEvent::Ready(meta) => assert_eq!(meta["upstream_kind"], "websocket_text"),
        event => panic!("expected ready event, got {event:?}"),
    }

    handle.read(2).unwrap();
    let error_event = chunk_event(&event_rx);
    let failed_event = chunk_event(&event_rx);

    assert_eq!(error_event["type"], "error");
    assert_eq!(error_event["error"]["code"], "unsupported_websocket_frame");
    assert_eq!(failed_event["type"], "response.failed");

    match event_rx.recv_timeout(Duration::from_secs(1)).unwrap() {
        StreamEvent::Error(error) => {
            assert_eq!(error["code"], "unsupported_websocket_frame");
        }
        event => panic!("expected terminal error event, got {event:?}"),
    }
}

#[test]
fn websocket_message_too_big_close_maps_to_provider_status_413() {
    let listener = StdTCPListener::bind("127.0.0.1:0").unwrap();
    let address = listener.local_addr().unwrap();

    thread::spawn(move || {
        let (socket, _) = listener.accept().unwrap();
        let mut websocket = accept(socket).unwrap();
        websocket
            .send(Message::Close(Some(
                tokio_tungstenite::tungstenite::protocol::CloseFrame {
                    code: CloseCode::Size,
                    reason: "message too big".into(),
                },
            )))
            .unwrap();
    });

    let (event_tx, event_rx) = mpsc::channel();
    let sink: EventSink = Arc::new(move |event| {
        event_tx.send(event).unwrap();
    });

    let spec = format!(
        r#"{{
              "api_resolver": "openai_responses",
              "upstream": {{
                "kind": "websocket_text",
                "method": "GET",
                "url": "ws://{address}/v1/responses",
                "headers": [],
                "timeout": {{"connect_ms": 1000, "first_byte_ms": 1000, "idle_ms": 1000}},
                "transport": {{}}
              }},
              "response_context": {{"model": "gpt-test", "request": {{}}}}
            }}"#
    );

    let handle = start_stream(&spec, sink).unwrap();

    match event_rx.recv_timeout(Duration::from_secs(1)).unwrap() {
        StreamEvent::Ready(meta) => assert_eq!(meta["upstream_kind"], "websocket_text"),
        event => panic!("expected ready event, got {event:?}"),
    }

    handle.read(2).unwrap();
    let error_event = chunk_event(&event_rx);
    let failed_event = chunk_event(&event_rx);

    assert_eq!(error_event["type"], "error");
    assert_eq!(error_event["error"]["code"], "websocket_message_too_large");
    assert_eq!(failed_event["type"], "response.failed");

    match event_rx.recv_timeout(Duration::from_secs(1)).unwrap() {
        StreamEvent::Error(error) => {
            assert_eq!(error["code"], "websocket_message_too_large");
            assert_eq!(error["provider_status"], 413);
        }
        event => panic!("expected terminal error event, got {event:?}"),
    }
}

#[test]
fn bedrock_eventstream_exception_reports_its_type_and_declared_status() {
    let (events, end) = bedrock_eventstream(&[eventstream_frame(
        &[
            (":message-type", "exception"),
            (":exception-type", "throttlingException"),
            (":content-type", "application/json"),
        ],
        br#"{"message":"Too many tokens, please wait before trying again."}"#,
    )]);

    let [error_event, failed_event] = events.as_slice() else {
        panic!("expected error and response.failed events, got {events:?}");
    };
    assert_eq!(error_event["type"], "error");
    assert_eq!(failed_event["type"], "response.failed");
    let failed_error = &failed_event["response"]["error"];
    assert_eq!(failed_error["code"], "provider_eventstream_error");
    assert_eq!(failed_error["status"], 429);
    assert_eq!(failed_error["details_json"]["provider_status"], 429);
    assert_eq!(
        failed_error["details_json"]["provider_error_type"],
        "throttlingException"
    );

    match end {
        StreamEvent::Error(error) => {
            assert_eq!(error["code"], "provider_eventstream_error");
            assert_eq!(
                error["message"],
                "Too many tokens, please wait before trying again."
            );
            assert_eq!(error["provider_status"], 429);
            assert_eq!(error["provider_error_type"], "throttlingException");
        }
        event => panic!("expected terminal error event, got {event:?}"),
    }
}

#[test]
fn bedrock_eventstream_completes_with_text_and_usage() {
    let (events, end) = bedrock_eventstream(&[
        bedrock_event(
            "messageStart",
            r#"{"p":"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0","role":"assistant"}"#,
        ),
        bedrock_event(
            "contentBlockDelta",
            r#"{"contentBlockIndex":0,"delta":{"text":"hello "},"p":"abcd"}"#,
        ),
        bedrock_event(
            "contentBlockDelta",
            r#"{"contentBlockIndex":0,"delta":{"text":"bedrock"},"p":"abcdefghijklmnopqrstu"}"#,
        ),
        bedrock_event("contentBlockStop", r#"{"contentBlockIndex":0}"#),
        bedrock_event("messageStop", r#"{"stopReason":"end_turn"}"#),
        bedrock_event("metadata", BEDROCK_METADATA),
    ]);

    assert_eq!(
        events
            .iter()
            .map(|event| event["type"].as_str().unwrap())
            .collect::<Vec<_>>(),
        [
            "response.created",
            "response.output_item.added",
            "response.content_part.added",
            "response.output_text.delta",
            "response.output_text.delta",
            "response.output_text.done",
            "response.content_part.done",
            "response.output_item.done",
            "response.completed",
        ]
    );
    assert_eq!(events[3]["delta"], "hello ");
    assert_eq!(events[4]["delta"], "bedrock");
    let response = &events[8]["response"];
    assert_eq!(response["output"][0]["content"][0]["text"], "hello bedrock");
    assert_eq!(response["usage"]["input_tokens"], 3);
    assert_eq!(response["usage"]["output_tokens"], 5);
    assert_eq!(response["usage"]["total_tokens"], 8);
    assert!(matches!(end, StreamEvent::Done(_)), "{end:?}");
}

#[test]
fn bedrock_eventstream_finishes_with_the_message_stop_reason() {
    let (events, _end) = bedrock_eventstream(&[
        bedrock_event(
            "contentBlockDelta",
            r#"{"contentBlockIndex":0,"delta":{"text":"truncated"}}"#,
        ),
        bedrock_event("messageStop", r#"{"stopReason":"max_tokens"}"#),
        bedrock_event("metadata", BEDROCK_METADATA),
    ]);
    let terminal = events.last().unwrap();
    assert_eq!(terminal["type"], "response.incomplete");
    assert_eq!(
        terminal["response"]["incomplete_details"]["reason"],
        "max_output_tokens"
    );
    assert_eq!(terminal["response"]["usage"]["total_tokens"], 8);

    let (events, _end) = bedrock_eventstream(&[
        bedrock_event("messageStop", r#"{"stopReason":"content_filtered"}"#),
        bedrock_event("metadata", BEDROCK_METADATA),
    ]);
    let terminal = events.last().unwrap();
    assert_eq!(terminal["type"], "response.failed");
    assert_eq!(
        terminal["response"]["error"]["code"],
        "provider_terminal_rejected"
    );

    let (events, _end) = bedrock_eventstream(&[bedrock_event(
        "contentBlockDelta",
        r#"{"contentBlockIndex":0,"delta":{"text":"cut"}}"#,
    )]);
    let terminal = events.last().unwrap();
    assert_eq!(terminal["type"], "response.incomplete");
    assert_eq!(
        terminal["response"]["incomplete_details"]["reason"],
        "upstream_stream_closed"
    );
}

const BEDROCK_METADATA: &str =
    r#"{"metrics":{"latencyMs":42},"usage":{"inputTokens":3,"outputTokens":5,"totalTokens":8}}"#;

fn bedrock_event(event_type: &str, payload: &str) -> Vec<u8> {
    eventstream_frame(
        &[
            (":event-type", event_type),
            (":content-type", "application/json"),
            (":message-type", "event"),
        ],
        payload.as_bytes(),
    )
}

// Serves the frames as the body of one ConverseStream HTTP response, and
// returns the Responses events of the stream and the event that ends it.
fn bedrock_eventstream(frames: &[Vec<u8>]) -> (Vec<Value>, StreamEvent) {
    let listener = StdTCPListener::bind("127.0.0.1:0").unwrap();
    let address = listener.local_addr().unwrap();
    let body = frames.concat();

    thread::spawn(move || {
        let (mut socket, _) = listener.accept().unwrap();
        let mut buffer = [0_u8; 1024];
        let _ = socket.read(&mut buffer).unwrap();

        let mut response = format!(
            "HTTP/1.1 200 OK\r\ncontent-type: application/vnd.amazon.eventstream\r\ncontent-length: {}\r\n\r\n",
            body.len()
        )
        .into_bytes();
        response.extend_from_slice(&body);
        socket.write_all(&response).unwrap();
        socket.flush().unwrap();
        thread::sleep(Duration::from_millis(300));
    });

    let (event_tx, event_rx) = mpsc::channel();
    let sink: EventSink = Arc::new(move |event| {
        event_tx.send(event).unwrap();
    });

    let spec = format!(
        r#"{{
              "api_resolver": "bedrock_converse",
              "upstream": {{
                "kind": "http_eventstream",
                "method": "POST",
                "url": "http://{address}/model/bedrock-test/converse-stream",
                "headers": [],
                "timeout": {{"connect_ms": 1000, "first_byte_ms": 1000, "idle_ms": 1000}},
                "transport": {{}}
              }},
              "response_context": {{"model": "bedrock-test", "request": {{}}}}
            }}"#
    );

    let handle = start_stream(&spec, sink).unwrap();

    match event_rx.recv_timeout(Duration::from_secs(1)).unwrap() {
        StreamEvent::Ready(meta) => assert_eq!(meta["upstream_kind"], "http_eventstream"),
        event => panic!("expected ready event, got {event:?}"),
    }

    handle.read(64).unwrap();
    let mut events = Vec::new();
    loop {
        match event_rx.recv_timeout(Duration::from_secs(1)).unwrap() {
            StreamEvent::Chunk { bytes, .. } => events.push(sonic_rs::from_slice(&bytes).unwrap()),
            event => return (events, event),
        }
    }
}

fn chunk_event(event_rx: &mpsc::Receiver<StreamEvent>) -> Value {
    match event_rx.recv_timeout(Duration::from_secs(1)).unwrap() {
        StreamEvent::Chunk { bytes, .. } => sonic_rs::from_slice(&bytes).unwrap(),
        event => panic!("expected JSON text chunk, got {event:?}"),
    }
}
