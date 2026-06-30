use super::error::StreamError;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SseEvent {
    pub event: Option<String>,
    pub data: String,
}

#[derive(Debug, Default)]
pub struct SseParser {
    buffer: Vec<u8>,
    max_event_bytes: usize,
}

impl SseParser {
    pub fn new(max_event_bytes: usize) -> Self {
        Self {
            buffer: Vec::new(),
            max_event_bytes: max_event_bytes.max(1),
        }
    }

    pub fn push(&mut self, bytes: &[u8]) -> Result<Vec<SseEvent>, StreamError> {
        self.buffer.extend_from_slice(bytes);
        let mut events = Vec::new();

        while let Some(index) = find_sse_boundary(&self.buffer) {
            if index > self.max_event_bytes {
                return Err(StreamError::new(
                    "sse_event_too_large",
                    "wire",
                    format!("upstream SSE event exceeded {} bytes", self.max_event_bytes),
                ));
            }

            let mut raw = self.buffer.drain(..index).collect::<Vec<_>>();
            let boundary_len = if self.buffer.starts_with(b"\r\n\r\n") {
                4
            } else {
                2
            };
            self.buffer.drain(..boundary_len);

            while raw.ends_with(b"\n") || raw.ends_with(b"\r") {
                raw.pop();
            }

            if let Some(event) = parse_sse_event(&raw) {
                events.push(event);
            }
        }

        if self.buffer.len() > self.max_event_bytes {
            return Err(StreamError::new(
                "sse_event_too_large",
                "wire",
                format!(
                    "upstream SSE event exceeded {} bytes without a boundary",
                    self.max_event_bytes
                ),
            ));
        }

        Ok(events)
    }

    pub fn finish(&mut self) -> Result<Vec<SseEvent>, StreamError> {
        if self.buffer.iter().all(|byte| byte.is_ascii_whitespace()) {
            self.buffer.clear();
            Ok(Vec::new())
        } else {
            Err(StreamError::new(
                "incomplete_sse_event",
                "wire",
                "upstream SSE stream closed with an incomplete event",
            ))
        }
    }
}

fn find_sse_boundary(buffer: &[u8]) -> Option<usize> {
    buffer
        .windows(4)
        .position(|window| window == b"\r\n\r\n")
        .or_else(|| buffer.windows(2).position(|window| window == b"\n\n"))
}

fn parse_sse_event(raw: &[u8]) -> Option<SseEvent> {
    let text = String::from_utf8_lossy(raw);
    let mut event = None;
    let mut data_lines = Vec::new();

    for line in text.lines() {
        let line = line.trim_end_matches('\r');
        if line.is_empty() || line.starts_with(':') {
            continue;
        }

        if let Some(rest) = line.strip_prefix("event:") {
            event = Some(rest.trim_start().to_string());
        } else if let Some(rest) = line.strip_prefix("data:") {
            data_lines.push(rest.trim_start().to_string());
        }
    }

    if event.is_none() && data_lines.is_empty() {
        return None;
    }

    Some(SseEvent {
        event,
        data: data_lines.join("\n"),
    })
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct EventStreamMessage {
    pub message_type: Option<String>,
    pub event_type: Option<String>,
    pub payload: Vec<u8>,
}

#[derive(Debug, Default)]
pub struct AwsEventStreamParser {
    buffer: Vec<u8>,
    max_frame_bytes: usize,
}

impl AwsEventStreamParser {
    pub fn new(max_frame_bytes: usize) -> Self {
        Self {
            buffer: Vec::new(),
            max_frame_bytes: max_frame_bytes.max(16),
        }
    }

    pub fn push(&mut self, bytes: &[u8]) -> Result<Vec<EventStreamMessage>, StreamError> {
        self.buffer.extend_from_slice(bytes);
        if self.buffer.len() > self.max_frame_bytes && self.buffer.len() < 12 {
            return Err(StreamError::new(
                "eventstream_frame_too_large",
                "wire",
                format!(
                    "AWS eventstream frame exceeded {} bytes before the prelude completed",
                    self.max_frame_bytes
                ),
            ));
        }
        let mut messages = Vec::new();

        loop {
            if self.buffer.len() < 12 {
                break;
            }

            let total_length = u32::from_be_bytes([
                self.buffer[0],
                self.buffer[1],
                self.buffer[2],
                self.buffer[3],
            ]) as usize;
            let headers_length = u32::from_be_bytes([
                self.buffer[4],
                self.buffer[5],
                self.buffer[6],
                self.buffer[7],
            ]) as usize;

            if total_length < 16 || headers_length + 16 > total_length {
                return Err(StreamError::new(
                    "invalid_eventstream_frame",
                    "wire",
                    "AWS eventstream frame has invalid lengths",
                ));
            }

            if total_length > self.max_frame_bytes {
                return Err(StreamError::new(
                    "eventstream_frame_too_large",
                    "wire",
                    format!(
                        "AWS eventstream frame length {total_length} exceeded {} bytes",
                        self.max_frame_bytes
                    ),
                ));
            }

            if self.buffer.len() < total_length {
                break;
            }

            let frame = self.buffer.drain(..total_length).collect::<Vec<_>>();
            validate_crc(&frame)?;

            let headers_start = 12;
            let headers_end = headers_start + headers_length;
            let payload_end = total_length - 4;
            let headers = parse_eventstream_headers(&frame[headers_start..headers_end])?;
            messages.push(EventStreamMessage {
                message_type: headers.message_type,
                event_type: headers.event_type,
                payload: frame[headers_end..payload_end].to_vec(),
            });
        }

        Ok(messages)
    }

    pub fn finish(&mut self) -> Result<(), StreamError> {
        if self.buffer.is_empty() {
            Ok(())
        } else {
            Err(StreamError::new(
                "incomplete_eventstream_frame",
                "wire",
                "upstream AWS eventstream closed with an incomplete frame",
            ))
        }
    }
}

fn validate_crc(frame: &[u8]) -> Result<(), StreamError> {
    let expected_prelude_crc = u32::from_be_bytes([frame[8], frame[9], frame[10], frame[11]]);
    let actual_prelude_crc = crc32fast::hash(&frame[..8]);
    if expected_prelude_crc != actual_prelude_crc {
        return Err(StreamError::new(
            "invalid_eventstream_crc",
            "wire",
            "AWS eventstream prelude CRC mismatch",
        ));
    }

    let len = frame.len();
    let expected_message_crc = u32::from_be_bytes([
        frame[len - 4],
        frame[len - 3],
        frame[len - 2],
        frame[len - 1],
    ]);
    let actual_message_crc = crc32fast::hash(&frame[..len - 4]);
    if expected_message_crc != actual_message_crc {
        return Err(StreamError::new(
            "invalid_eventstream_crc",
            "wire",
            "AWS eventstream message CRC mismatch",
        ));
    }

    Ok(())
}

#[derive(Debug, Default)]
struct EventStreamHeaders {
    message_type: Option<String>,
    event_type: Option<String>,
}

fn parse_eventstream_headers(headers: &[u8]) -> Result<EventStreamHeaders, StreamError> {
    let mut index = 0;
    let mut parsed = EventStreamHeaders::default();

    while index < headers.len() {
        let name_len = headers[index] as usize;
        index += 1;
        if index + name_len + 1 > headers.len() {
            return Err(StreamError::new(
                "invalid_eventstream_headers",
                "wire",
                "AWS eventstream header is truncated",
            ));
        }

        let name = String::from_utf8_lossy(&headers[index..index + name_len]).to_string();
        index += name_len;
        let value_type = headers[index];
        index += 1;

        let value = match value_type {
            7 => {
                if index + 2 > headers.len() {
                    return Err(StreamError::new(
                        "invalid_eventstream_headers",
                        "wire",
                        "AWS eventstream string header length is truncated",
                    ));
                }
                let len = u16::from_be_bytes([headers[index], headers[index + 1]]) as usize;
                index += 2;
                if index + len > headers.len() {
                    return Err(StreamError::new(
                        "invalid_eventstream_headers",
                        "wire",
                        "AWS eventstream string header value is truncated",
                    ));
                }
                let value = String::from_utf8_lossy(&headers[index..index + len]).to_string();
                index += len;
                Some(value)
            }
            6 => {
                if index + 1 > headers.len() {
                    return Err(StreamError::new(
                        "invalid_eventstream_headers",
                        "wire",
                        "AWS eventstream byte header is truncated",
                    ));
                }
                index += 1;
                None
            }
            8 => {
                if index + 8 > headers.len() {
                    return Err(StreamError::new(
                        "invalid_eventstream_headers",
                        "wire",
                        "AWS eventstream timestamp header is truncated",
                    ));
                }
                index += 8;
                None
            }
            _ => {
                return Err(StreamError::new(
                    "unsupported_eventstream_header",
                    "wire",
                    format!("unsupported AWS eventstream header type {value_type}"),
                ));
            }
        };

        match name.as_str() {
            ":message-type" => parsed.message_type = value,
            ":event-type" => parsed.event_type = value,
            _header => {}
        }
    }

    Ok(parsed)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn sse_parser_handles_split_events() {
        let mut parser = SseParser::new(1024);

        assert!(
            parser
                .push(b"event: response.output_text.delta\ndata: {\"")
                .unwrap()
                .is_empty()
        );
        let events = parser.push(b"type\":\"x\"}\n\n").unwrap();

        assert_eq!(
            events,
            vec![SseEvent {
                event: Some("response.output_text.delta".to_string()),
                data: "{\"type\":\"x\"}".to_string()
            }]
        );
    }

    #[test]
    fn sse_finish_rejects_partial_event() {
        let mut parser = SseParser::new(1024);
        assert!(
            parser
                .push(b"data: {\"type\":\"response.created\"}")
                .unwrap()
                .is_empty()
        );

        let error = parser.finish().unwrap_err();
        assert_eq!(error.code, "incomplete_sse_event");
    }

    #[test]
    fn sse_parser_rejects_unbounded_event_buffer() {
        let mut parser = SseParser::new(8);

        let error = parser.push(b"data: 123456789").unwrap_err();

        assert_eq!(error.code, "sse_event_too_large");
    }

    #[test]
    fn aws_eventstream_parser_decodes_payload_and_header() {
        let frame = eventstream_frame(
            &[
                (":message-type", "event"),
                (":event-type", "contentBlockDelta"),
            ],
            br#"{"x":1}"#,
        );
        let mut parser = AwsEventStreamParser::new(1024);
        let messages = parser.push(&frame).unwrap();

        assert_eq!(messages.len(), 1);
        assert_eq!(messages[0].message_type.as_deref(), Some("event"));
        assert_eq!(messages[0].event_type.as_deref(), Some("contentBlockDelta"));
        assert_eq!(messages[0].payload, br#"{"x":1}"#);
    }

    #[test]
    fn aws_eventstream_finish_rejects_partial_frame() {
        let frame = eventstream_frame(&[(":message-type", "event")], br#"{"x":1}"#);
        let mut parser = AwsEventStreamParser::new(1024);

        assert!(parser.push(&frame[..8]).unwrap().is_empty());
        let error = parser.finish().unwrap_err();

        assert_eq!(error.code, "incomplete_eventstream_frame");
    }

    #[test]
    fn aws_eventstream_parser_rejects_oversized_frame_length() {
        let mut parser = AwsEventStreamParser::new(32);
        let mut prelude = Vec::new();
        prelude.extend_from_slice(&64_u32.to_be_bytes());
        prelude.extend_from_slice(&0_u32.to_be_bytes());
        let crc = crc32fast::hash(&prelude);
        prelude.extend_from_slice(&crc.to_be_bytes());

        let error = parser.push(&prelude).unwrap_err();

        assert_eq!(error.code, "eventstream_frame_too_large");
    }

    fn eventstream_frame(headers: &[(&str, &str)], payload: &[u8]) -> Vec<u8> {
        let mut encoded_headers = Vec::new();
        for (header_name, header_value) in headers {
            encoded_headers.push(header_name.len() as u8);
            encoded_headers.extend_from_slice(header_name.as_bytes());
            encoded_headers.push(7);
            encoded_headers.extend_from_slice(&(header_value.len() as u16).to_be_bytes());
            encoded_headers.extend_from_slice(header_value.as_bytes());
        }

        let total_length = 16 + encoded_headers.len() + payload.len();
        let mut frame = Vec::new();
        frame.extend_from_slice(&(total_length as u32).to_be_bytes());
        frame.extend_from_slice(&(encoded_headers.len() as u32).to_be_bytes());
        let prelude_crc = crc32fast::hash(&frame);
        frame.extend_from_slice(&prelude_crc.to_be_bytes());
        frame.extend_from_slice(&encoded_headers);
        frame.extend_from_slice(payload);
        let message_crc = crc32fast::hash(&frame);
        frame.extend_from_slice(&message_crc.to_be_bytes());
        frame
    }
}
