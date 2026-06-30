#[cfg(test)]
mod tests {
    use std::io::{Read, Write};
    use std::net::TcpListener as StdTcpListener;
    use std::sync::mpsc;
    use std::thread;
    use std::time::Duration;

    use super::*;
    use serde_json::Value;
    use tokio_tungstenite::tungstenite::accept;

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
                "transport": {"http_versions": ["h3", "h2", "h1"], "compression": ["zstd", "br", "gzip"]}
              },
              "downstream": "sse",
              "response_context": {"model": "gpt-test", "request": {"input": "hi"}}
            }"#,
        )
        .unwrap();

        assert_eq!(
            spec.api_resolver,
            ApiResolverKind::OpenaiChatCompletions
        );
        assert_eq!(spec.upstream.kind, UpstreamKind::HttpSse);
        assert_eq!(spec.downstream, DownstreamKind::Sse);
        assert_eq!(spec.upstream.headers[0].0, "authorization");
    }

    #[test]
    fn websocket_stream_sends_body_as_initial_response_create_message() {
        let listener = StdTcpListener::bind("127.0.0.1:0").unwrap();
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
                "transport": {{"http_versions": ["h1"], "compression": []}}
              }},
              "downstream": "websocket_text",
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
        let listener = StdTcpListener::bind("127.0.0.1:0").unwrap();
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
                "transport": {{"http_versions": ["h1"], "compression": []}}
              }},
              "downstream": "sse",
              "response_context": {{"model": "gpt-test", "request": {{}}}}
            }}"#
        );

        let handle = start_stream(&spec, sink).unwrap();

        match event_rx.recv_timeout(Duration::from_secs(1)).unwrap() {
            StreamEvent::Ready(meta) => assert_eq!(meta["upstream_kind"], "http_sse"),
            event => panic!("expected ready event, got {event:?}"),
        }

        handle.read(2).unwrap();
        let first = sse_chunk(&event_rx);
        let second = sse_chunk(&event_rx);

        assert!(first.starts_with("event: response.completed\ndata: "));
        assert_eq!(second, "data: [DONE]\n\n");

        match event_rx.recv_timeout(Duration::from_secs(1)).unwrap() {
            StreamEvent::Done(summary) => assert_eq!(summary["reason"], "provider_terminal"),
            event => panic!("expected done event, got {event:?}"),
        }
    }

    #[test]
    fn http_sse_stream_reads_ahead_but_waits_for_downstream_demand() {
        let listener = StdTcpListener::bind("127.0.0.1:0").unwrap();
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
                "transport": {{"http_versions": ["h1"], "compression": []}}
              }},
              "downstream": "sse",
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
        assert!(sse_chunk(&event_rx).starts_with("event: response.completed\ndata: "));
        assert_eq!(sse_chunk(&event_rx), "data: [DONE]\n\n");

        match event_rx.recv_timeout(Duration::from_secs(1)).unwrap() {
            StreamEvent::Done(summary) => assert_eq!(summary["reason"], "provider_terminal"),
            event => panic!("expected done event, got {event:?}"),
        }
    }

    #[test]
    fn websocket_binary_frame_after_ready_becomes_protocol_error_chunks() {
        let listener = StdTcpListener::bind("127.0.0.1:0").unwrap();
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
                "transport": {{"http_versions": ["h1"], "compression": []}}
              }},
              "downstream": "websocket_text",
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

    fn chunk_event(event_rx: &mpsc::Receiver<StreamEvent>) -> Value {
        match event_rx.recv_timeout(Duration::from_secs(1)).unwrap() {
            StreamEvent::Chunk {
                kind: DownstreamKind::WebsocketText,
                bytes,
                ..
            } => sonic_rs::from_slice(&bytes).unwrap(),
            event => panic!("expected websocket_text chunk, got {event:?}"),
        }
    }

    fn sse_chunk(event_rx: &mpsc::Receiver<StreamEvent>) -> String {
        match event_rx.recv_timeout(Duration::from_secs(1)).unwrap() {
            StreamEvent::Chunk {
                kind: DownstreamKind::Sse,
                bytes,
                ..
            } => String::from_utf8(bytes).unwrap(),
            event => panic!("expected sse chunk, got {event:?}"),
        }
    }
}
