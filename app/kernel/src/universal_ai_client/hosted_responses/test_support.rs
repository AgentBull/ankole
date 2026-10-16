use std::io::{Read, Write};
use std::net::{TcpListener as TCPListener, TcpStream as TCPStream};

use super::{HostedImageGenerationSpec, ModelRequestSpec};
use serde_json::{Value, json};

pub(super) fn test_image_spec(url: &str) -> HostedImageGenerationSpec {
    let spec = json!({
        "api_resolver": "openrouter_images",
        "upstream": test_upstream(url),
        "response_context": {"model": "openai/gpt-image-2", "request": {"n": 1}}
    });

    HostedImageGenerationSpec {
        tool_config: json!({"type": "image_generation"}),
        selected_model: "openai/gpt-image-2".to_string(),
        prepared_request: Box::new(ModelRequestSpec::from_json(&spec.to_string()).unwrap()),
        endpoint_capabilities: json!({}),
        provider_tag: "openai/gpt-image-2:openai".to_string(),
        provider_slug: "openai".to_string(),
        resolved_references: vec![],
        limits: json!({}),
    }
}

pub(super) fn test_upstream(url: &str) -> Value {
    json!({
        "method": "POST",
        "url": url,
        "headers": [["content-type", "application/json"]],
        "timeout": {"connect_ms": 2_000, "first_byte_ms": 2_000, "idle_ms": 2_000, "total_ms": 5_000},
        "transport": {}
    })
}

pub(super) fn read_http_request(listener: &TCPListener) -> (TCPStream, Value) {
    let (mut stream, _) = listener.accept().unwrap();
    let mut bytes = Vec::new();
    let mut buffer = [0_u8; 4096];
    let header_end;
    loop {
        let read = stream.read(&mut buffer).unwrap();
        assert!(read > 0, "HTTP request ended before headers completed");
        bytes.extend_from_slice(&buffer[..read]);
        if let Some(index) = bytes.windows(4).position(|window| window == b"\r\n\r\n") {
            header_end = index + 4;
            break;
        }
    }
    let headers = String::from_utf8_lossy(&bytes[..header_end]);
    let content_length = headers
        .lines()
        .find_map(|line| {
            let (name, value) = line.split_once(':')?;
            name.eq_ignore_ascii_case("content-length")
                .then(|| value.trim().parse::<usize>().unwrap())
        })
        .unwrap_or(0);
    while bytes.len() < header_end + content_length {
        let read = stream.read(&mut buffer).unwrap();
        assert!(read > 0, "HTTP request ended before body completed");
        bytes.extend_from_slice(&buffer[..read]);
    }
    let body = sonic_rs::from_slice(&bytes[header_end..header_end + content_length]).unwrap();
    (stream, body)
}

pub(super) fn write_json_response(mut stream: TCPStream, body: &Value) {
    let body = body.to_string();
    write!(
        stream,
        "HTTP/1.1 200 OK\r\ncontent-type: application/json\r\ncontent-length: {}\r\nconnection: close\r\n\r\n{}",
        body.len(),
        body
    )
    .unwrap();
    stream.flush().unwrap();
}

pub(super) fn write_sse_chunk(stream: &mut TCPStream, body: &str) {
    write!(stream, "{:x}\r\n{}\r\n", body.len(), body).unwrap();
}
