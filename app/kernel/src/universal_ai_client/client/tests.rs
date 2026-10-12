use std::io::{Read, Write};
use std::net::TcpListener as StdTCPListener;
use std::sync::{Arc, mpsc};
use std::thread;
use std::time::{Duration, Instant};

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
fn semantic_idle_sse_comments_do_not_reset_the_timeout() {
    let (handle, events) = idle_http_stream("http_sse", move |mut socket| {
        let until = Instant::now() + Duration::from_secs(3);
        while Instant::now() < until {
            if write_http_chunk(&mut socket, b": keepalive\n\n").is_err() {
                break;
            }
            thread::sleep(Duration::from_millis(20));
        }
    });

    assert_idle_stream_timeout(handle, events);
}

#[test]
fn semantic_idle_sse_partial_events_do_not_reset_the_timeout() {
    let (handle, events) = idle_http_stream("http_sse", move |mut socket| {
        let until = Instant::now() + Duration::from_secs(3);
        while Instant::now() < until {
            if write_http_chunk(&mut socket, b"data: ").is_err() {
                break;
            }
            thread::sleep(Duration::from_millis(20));
        }
    });

    assert_idle_stream_timeout(handle, events);
}

#[test]
fn semantic_idle_eventstream_partial_frames_do_not_reset_the_timeout() {
    let (handle, events) = idle_http_stream("http_eventstream", move |mut socket| {
        let frame = bedrock_event(
            "contentBlockDelta",
            &format!(
                r#"{{"contentBlockIndex":0,"delta":{{"text":"{}"}}}}"#,
                "x".repeat(256)
            ),
        );
        for byte in frame {
            if write_http_chunk(&mut socket, &[byte]).is_err() {
                break;
            }
            thread::sleep(Duration::from_millis(20));
        }
    });

    assert_idle_stream_timeout(handle, events);
}

#[test]
fn semantic_idle_sse_complete_events_reset_the_timeout_among_comments() {
    let (handle, events) = idle_http_stream("http_sse", move |mut socket| {
        for event in [
            r#"{"type":"response.created","response":{"id":"resp_idle","status":"in_progress","output":[]}}"#,
            r#"{"type":"response.in_progress","response":{"id":"resp_idle","status":"in_progress","output":[]}}"#,
            r#"{"type":"response.completed","response":{"id":"resp_idle","status":"completed","output":[],"usage":{}}}"#,
        ] {
            let until = Instant::now() + Duration::from_millis(150);
            while Instant::now() < until {
                write_http_chunk(&mut socket, b": keepalive\n\n").unwrap();
                thread::sleep(Duration::from_millis(20));
            }
            write_http_chunk(&mut socket, format!("data: {event}\n\n").as_bytes()).unwrap();
        }
        thread::sleep(Duration::from_millis(300));
    });

    handle.read(64).unwrap();
    let started = Instant::now();
    loop {
        match events.recv_timeout(Duration::from_secs(2)).unwrap() {
            StreamEvent::Chunk { .. } => {}
            StreamEvent::Done(meta) => {
                assert_eq!(meta["reason"], "provider_terminal");
                assert!(started.elapsed() >= Duration::from_millis(400));
                break;
            }
            event => panic!("expected a complete stream, got {event:?}"),
        }
    }
}

#[test]
fn semantic_idle_eventstream_complete_frames_reset_the_timeout() {
    let (handle, events) = idle_http_stream("http_eventstream", move |mut socket| {
        for frame in [
            bedrock_event("messageStart", r#"{"role":"assistant"}"#),
            bedrock_event(
                "contentBlockDelta",
                r#"{"contentBlockIndex":0,"delta":{"text":"hello"}}"#,
            ),
            bedrock_event("messageStop", r#"{"stopReason":"end_turn"}"#),
            bedrock_event("metadata", BEDROCK_METADATA),
        ] {
            thread::sleep(Duration::from_millis(150));
            write_http_chunk(&mut socket, &frame).unwrap();
        }
        socket.write_all(b"0\r\n\r\n").unwrap();
        socket.flush().unwrap();
    });
    let started = Instant::now();
    handle.read(64).unwrap();
    let terminal = loop {
        match events.recv_timeout(Duration::from_secs(2)).unwrap() {
            StreamEvent::Chunk { bytes, .. } => {
                let event: Value = sonic_rs::from_slice(&bytes).unwrap();
                if event["type"] == "response.completed" {
                    break event;
                }
            }
            event => panic!("expected complete provider frames, got {event:?}"),
        }
    };
    assert_eq!(
        terminal["response"]["output"][0]["content"][0]["text"],
        "hello"
    );
    assert!(matches!(
        events.recv_timeout(Duration::from_secs(1)).unwrap(),
        StreamEvent::Done(_)
    ));
    assert!(started.elapsed() >= Duration::from_millis(500));
}

#[test]
fn semantic_idle_websocket_text_events_reset_both_stream_timeouts() {
    let runtime = crate::common::io_runtime::runtime().unwrap();
    for collected in [false, true] {
        let listener = StdTCPListener::bind("127.0.0.1:0").unwrap();
        let address = listener.local_addr().unwrap();
        thread::spawn(move || {
            let (socket, _) = listener.accept().unwrap();
            let mut websocket = accept(socket).unwrap();
            for event in [
                r#"{"type":"response.created","response":{"id":"resp_text","status":"in_progress","output":[]}}"#,
                r#"{"type":"response.in_progress","response":{"id":"resp_text","status":"in_progress","output":[]}}"#,
                r#"{"type":"response.completed","response":{"id":"resp_text","status":"completed","output":[],"usage":{}}}"#,
            ] {
                let until = Instant::now() + Duration::from_millis(150);
                while Instant::now() < until {
                    websocket.send(Message::Ping(vec![1].into())).unwrap();
                    thread::sleep(Duration::from_millis(20));
                }
                websocket.send(Message::text(event)).unwrap();
            }
            thread::sleep(Duration::from_millis(300));
        });

        let spec = idle_stream_spec("websocket_text", &format!("ws://{address}/responses"));
        let started = Instant::now();
        if collected {
            let spec = StreamSpec::from_json(&spec.to_string()).unwrap();
            let result = runtime.block_on(async {
                tokio::time::timeout(
                    Duration::from_secs(2),
                    super::websocket_model::run_websocket_model_request_once(spec),
                )
                .await
                .unwrap()
                .unwrap()
            });
            assert_eq!(result.wrapper["body"]["status"], "completed");
        } else {
            let (event_tx, events) = mpsc::channel();
            let sink: EventSink = Arc::new(move |event| {
                let _ = event_tx.send(event);
            });
            let handle = start_stream(&spec.to_string(), sink).unwrap();
            assert!(matches!(
                events.recv_timeout(Duration::from_secs(1)).unwrap(),
                StreamEvent::Ready(_)
            ));
            handle.read(64).unwrap();
            loop {
                match events.recv_timeout(Duration::from_secs(2)).unwrap() {
                    StreamEvent::Chunk { .. } => {}
                    StreamEvent::Done(_) => break,
                    event => panic!("expected complete provider Text events, got {event:?}"),
                }
            }
        }
        assert!(started.elapsed() >= Duration::from_millis(400));
    }
}

#[test]
fn semantic_idle_wait_for_downstream_capacity_does_not_spend_the_budget() {
    let listener = StdTCPListener::bind("127.0.0.1:0").unwrap();
    let address = listener.local_addr().unwrap();
    let (first_tx, first_rx) = mpsc::channel();
    let (release_tx, release_rx) = mpsc::channel();
    thread::spawn(move || {
        let (mut socket, _) = listener.accept().unwrap();
        let mut buffer = [0_u8; 1024];
        assert!(socket.read(&mut buffer).unwrap() > 0);
        socket.write_all(b"HTTP/1.1 200 OK\r\ncontent-type: text/event-stream\r\ntransfer-encoding: chunked\r\n\r\n").unwrap();
        write_http_chunk(&mut socket, b"data: {\"type\":\"response.created\",\"response\":{\"id\":\"resp_capacity\",\"status\":\"in_progress\",\"output\":[]}}\n\n").unwrap();
        first_tx.send(()).unwrap();
        release_rx.recv_timeout(Duration::from_secs(2)).unwrap();
        write_http_chunk(&mut socket, b"data: {\"type\":\"response.completed\",\"response\":{\"id\":\"resp_capacity\",\"status\":\"completed\",\"output\":[],\"usage\":{}}}\n\n").unwrap();
    });

    let (event_tx, events) = mpsc::channel();
    let sink: EventSink = Arc::new(move |event| {
        let _ = event_tx.send(event);
    });
    let mut spec = idle_stream_spec("http_sse", &format!("http://{address}/responses"));
    spec["limits"] = serde_json::json!({"max_pending_chunks": 1});
    let handle = start_stream(&spec.to_string(), sink).unwrap();
    assert!(matches!(
        events.recv_timeout(Duration::from_secs(1)).unwrap(),
        StreamEvent::Ready(_)
    ));
    first_rx.recv_timeout(Duration::from_secs(1)).unwrap();
    assert!(events.recv_timeout(Duration::from_millis(500)).is_err());
    release_tx.send(()).unwrap();
    handle.read(64).unwrap();
    assert_eq!(chunk_event(&events)["type"], "response.created");
    assert_eq!(chunk_event(&events)["type"], "response.completed");
    assert!(matches!(
        events.recv_timeout(Duration::from_secs(1)).unwrap(),
        StreamEvent::Done(_)
    ));
}

#[test]
fn semantic_idle_websocket_ping_does_not_reset_the_timeout() {
    let address = idle_websocket_server();
    let (event_tx, events) = mpsc::channel();
    let sink: EventSink = Arc::new(move |event| {
        let _ = event_tx.send(event);
    });
    let spec = idle_stream_spec("websocket_text", &format!("ws://{address}/responses"));
    let handle = start_stream(&spec.to_string(), sink).unwrap();
    assert!(matches!(
        events.recv_timeout(Duration::from_secs(1)).unwrap(),
        StreamEvent::Ready(_)
    ));

    assert_idle_stream_timeout(handle, events);
}

#[tokio::test]
async fn semantic_idle_collected_websocket_ping_does_not_reset_the_timeout() {
    let address = idle_websocket_server();
    let spec = StreamSpec::from_json(
        &idle_stream_spec("websocket_text", &format!("ws://{address}/responses")).to_string(),
    )
    .unwrap();
    let started = Instant::now();
    let error = match tokio::time::timeout(
        Duration::from_secs(2),
        super::websocket_model::run_websocket_model_request_once(spec),
    )
    .await
    .expect("Ping frames must not prevent the idle timeout")
    {
        Err(error) => error,
        Ok(_) => panic!("Ping frames must not produce a complete model response"),
    };
    assert_eq!(error.code, "idle_timeout");
    assert_eq!(error.stage, "read");
    assert!(started.elapsed() >= Duration::from_millis(150));
    assert!(started.elapsed() < Duration::from_secs(1));
}

fn idle_stream_spec(kind: &str, url: &str) -> Value {
    serde_json::json!({
        "api_resolver": if kind == "http_eventstream" { "bedrock_converse" } else { "openai_responses" },
        "upstream": {
            "kind": kind, "method": if kind == "websocket_text" { "GET" } else { "POST" },
            "url": url, "headers": [],
            "timeout": {"connect_ms": 1000, "first_byte_ms": 1000, "idle_ms": 200},
            "transport": {}
        },
        "response_context": {"model": "test-model", "request": {}}
    })
}

fn idle_http_stream(
    kind: &str,
    serve: impl FnOnce(std::net::TcpStream) + Send + 'static,
) -> (StreamHandle, mpsc::Receiver<StreamEvent>) {
    let listener = StdTCPListener::bind("127.0.0.1:0").unwrap();
    let address = listener.local_addr().unwrap();
    thread::spawn(move || {
        let (mut socket, _) = listener.accept().unwrap();
        let mut buffer = [0_u8; 1024];
        assert!(socket.read(&mut buffer).unwrap() > 0);
        socket
            .write_all(b"HTTP/1.1 200 OK\r\ntransfer-encoding: chunked\r\n\r\n")
            .unwrap();
        socket.flush().unwrap();
        serve(socket);
    });
    let (event_tx, events) = mpsc::channel();
    let sink: EventSink = Arc::new(move |event| {
        let _ = event_tx.send(event);
    });
    let spec = idle_stream_spec(kind, &format!("http://{address}/responses"));
    let handle = start_stream(&spec.to_string(), sink).unwrap();
    assert!(matches!(
        events.recv_timeout(Duration::from_secs(1)).unwrap(),
        StreamEvent::Ready(_)
    ));
    (handle, events)
}

fn write_http_chunk(socket: &mut std::net::TcpStream, bytes: &[u8]) -> std::io::Result<()> {
    write!(socket, "{:x}\r\n", bytes.len())?;
    socket.write_all(bytes)?;
    socket.write_all(b"\r\n")?;
    socket.flush()
}

fn idle_websocket_server() -> std::net::SocketAddr {
    let listener = StdTCPListener::bind("127.0.0.1:0").unwrap();
    let address = listener.local_addr().unwrap();
    thread::spawn(move || {
        let (socket, _) = listener.accept().unwrap();
        let mut websocket = accept(socket).unwrap();
        let until = Instant::now() + Duration::from_secs(3);
        while Instant::now() < until {
            if websocket.send(Message::Ping(vec![1].into())).is_err() {
                break;
            }
            thread::sleep(Duration::from_millis(20));
        }
    });
    address
}

fn assert_idle_stream_timeout(handle: StreamHandle, events: mpsc::Receiver<StreamEvent>) {
    handle.read(64).unwrap();
    let started = Instant::now();
    match events
        .recv_timeout(Duration::from_secs(2))
        .expect("Keepalive data must not prevent the idle timeout")
    {
        StreamEvent::Error(error) => {
            assert_eq!(error["code"], "idle_timeout");
            assert_eq!(error["stage"], "read");
            assert!(started.elapsed() >= Duration::from_millis(150));
            assert!(started.elapsed() < Duration::from_secs(1));
        }
        event => panic!("expected a native idle timeout without synthetic chunks, got {event:?}"),
    }
}

#[test]
fn websocket_binary_frame_before_response_events_stays_native() {
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

    match event_rx.recv_timeout(Duration::from_secs(1)).unwrap() {
        StreamEvent::Error(error) => {
            assert_eq!(error["code"], "unsupported_websocket_frame");
        }
        event => panic!("expected terminal error event, got {event:?}"),
    }
    assert!(handle.read(1).is_ok());
    assert!(event_rx.recv_timeout(Duration::from_millis(100)).is_err());
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

    match event_rx.recv_timeout(Duration::from_secs(1)).unwrap() {
        StreamEvent::Error(error) => {
            assert_eq!(error["code"], "websocket_message_too_large");
            assert_eq!(error["provider_status"], 413);
        }
        event => panic!("expected terminal error event, got {event:?}"),
    }
    handle.read(2).unwrap();
    assert!(event_rx.try_recv().is_err());
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

    assert!(
        events.is_empty(),
        "a failure before the first response event must stay native"
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
