use super::error::StreamError;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SSEEvent {
    pub event: Option<String>,
    pub data: String,
}

#[derive(Debug, Default)]
pub struct SSEParser {
    buffer: Vec<u8>,
    max_event_bytes: usize,
    // Start the next scan at a byte that can begin a split boundary.
    scan_from: usize,
}

impl SSEParser {
    pub fn new(max_event_bytes: usize) -> Self {
        Self {
            buffer: Vec::new(),
            max_event_bytes: max_event_bytes.max(1),
            scan_from: 0,
        }
    }

    pub fn push(&mut self, bytes: &[u8]) -> Result<Vec<SSEEvent>, StreamError> {
        self.buffer.extend_from_slice(bytes);
        let mut events = Vec::new();

        while let Some((index, boundary_len)) = find_sse_boundary(&self.buffer, self.scan_from) {
            if index > self.max_event_bytes {
                return Err(StreamError::new(
                    "sse_event_too_large",
                    "wire",
                    format!("upstream SSE event exceeded {} bytes", self.max_event_bytes),
                ));
            }

            let mut raw = self.buffer.drain(..index).collect::<Vec<_>>();
            self.buffer.drain(..boundary_len);
            self.scan_from = 0;

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

        self.scan_from = self.buffer.len().saturating_sub(b"\r\n\r\n".len() - 1);
        Ok(events)
    }

    pub fn finish(&mut self) -> Result<(), StreamError> {
        if self.buffer.iter().all(|byte| byte.is_ascii_whitespace()) {
            self.buffer.clear();
            self.scan_from = 0;
            Ok(())
        } else {
            Err(StreamError::new(
                "incomplete_sse_event",
                "wire",
                "upstream SSE stream closed with an incomplete event",
            ))
        }
    }
}

fn find_sse_boundary(buffer: &[u8], start: usize) -> Option<(usize, usize)> {
    (start.min(buffer.len())..buffer.len()).find_map(|index| {
        let remaining = &buffer[index..];
        if remaining.starts_with(b"\r\n\r\n") {
            Some((index, b"\r\n\r\n".len()))
        } else if remaining.starts_with(b"\n\n") {
            Some((index, b"\n\n".len()))
        } else {
            None
        }
    })
}

fn parse_sse_event(raw: &[u8]) -> Option<SSEEvent> {
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

    Some(SSEEvent {
        event,
        data: data_lines.join("\n"),
    })
}

#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct EventStreamMessage {
    pub message_type: Option<String>,
    pub event_type: Option<String>,
    pub exception_type: Option<String>,
    pub error_code: Option<String>,
    pub error_message: Option<String>,
    pub payload: Vec<u8>,
}

#[derive(Debug, Default)]
pub struct AWSEventStreamParser {
    buffer: Vec<u8>,
    max_frame_bytes: usize,
}

impl AWSEventStreamParser {
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
            let mut message = parse_eventstream_headers(&frame[headers_start..headers_end])?;
            message.payload = frame[headers_end..payload_end].to_vec();
            messages.push(message);
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

// Returns a message with its headers set and an empty payload. An exception
// frame names a modeled exception in `:exception-type`. An error frame names an
// unmodeled error in `:error-code` and `:error-message`.
fn parse_eventstream_headers(headers: &[u8]) -> Result<EventStreamMessage, StreamError> {
    let mut index = 0;
    let mut message = EventStreamMessage::default();

    while index < headers.len() {
        let name_len = headers[index] as usize;
        index += 1;
        if index + name_len + 1 > headers.len() {
            return Err(truncated_eventstream_header());
        }

        let name = &headers[index..index + name_len];
        index += name_len;
        let value_type = headers[index];
        index += 1;

        // The AWS eventstream header value types: 0 and 1 are booleans without
        // value bytes, 6 (bytes) and 7 (string) have a 2-byte length prefix,
        // and the other types have a fixed width.
        let value_len = match value_type {
            0 | 1 => 0,
            2 => 1,
            3 => 2,
            4 => 4,
            5 | 8 => 8,
            9 => 16,
            6 | 7 => {
                if index + 2 > headers.len() {
                    return Err(truncated_eventstream_header());
                }
                let len = u16::from_be_bytes([headers[index], headers[index + 1]]) as usize;
                index += 2;
                len
            }
            _ => {
                return Err(StreamError::new(
                    "unsupported_eventstream_header",
                    "wire",
                    format!("unsupported AWS eventstream header type {value_type}"),
                ));
            }
        };
        if index + value_len > headers.len() {
            return Err(truncated_eventstream_header());
        }
        let value = &headers[index..index + value_len];
        index += value_len;

        let field = match name {
            b":message-type" => &mut message.message_type,
            b":event-type" => &mut message.event_type,
            b":exception-type" => &mut message.exception_type,
            b":error-code" => &mut message.error_code,
            b":error-message" => &mut message.error_message,
            _header => continue,
        };
        if value_type == 7 {
            *field = Some(String::from_utf8_lossy(value).into_owned());
        }
    }

    Ok(message)
}

fn truncated_eventstream_header() -> StreamError {
    StreamError::new(
        "invalid_eventstream_headers",
        "wire",
        "AWS eventstream header is truncated",
    )
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;

    #[test]
    fn sse_parser_handles_split_events() {
        let mut parser = SSEParser::new(1024);

        assert!(
            parser
                .push(b"event: response.output_text.delta\ndata: {\"")
                .unwrap()
                .is_empty()
        );
        let events = parser.push(b"type\":\"x\"}\n\n").unwrap();

        assert_eq!(
            events,
            vec![SSEEvent {
                event: Some("response.output_text.delta".to_string()),
                data: "{\"type\":\"x\"}".to_string()
            }]
        );
    }

    #[test]
    fn sse_parser_uses_earliest_mixed_line_ending_boundary() {
        let mut parser = SSEParser::new(1024);

        let events = parser.push(b"data: first\n\ndata: second\r\n\r\n").unwrap();

        assert_eq!(
            events,
            vec![
                SSEEvent {
                    event: None,
                    data: "first".to_string()
                },
                SSEEvent {
                    event: None,
                    data: "second".to_string()
                }
            ]
        );
    }

    #[test]
    fn sse_parser_finds_crlf_boundary_across_chunks() {
        let mut parser = SSEParser::new(1024);

        assert!(parser.push(b"data: split\r\n").unwrap().is_empty());
        assert!(parser.push(b"\r").unwrap().is_empty());
        let events = parser.push(b"\n").unwrap();

        assert_eq!(
            events,
            vec![SSEEvent {
                event: None,
                data: "split".to_string()
            }]
        );
    }

    #[test]
    fn sse_finish_rejects_partial_event() {
        let mut parser = SSEParser::new(1024);
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
        let mut parser = SSEParser::new(8);

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
        let mut parser = AWSEventStreamParser::new(1024);
        let messages = parser.push(&frame).unwrap();

        assert_eq!(messages.len(), 1);
        assert_eq!(messages[0].message_type.as_deref(), Some("event"));
        assert_eq!(messages[0].event_type.as_deref(), Some("contentBlockDelta"));
        assert_eq!(messages[0].payload, br#"{"x":1}"#);
    }

    #[test]
    fn aws_eventstream_finish_rejects_partial_frame() {
        let frame = eventstream_frame(&[(":message-type", "event")], br#"{"x":1}"#);
        let mut parser = AWSEventStreamParser::new(1024);

        assert!(parser.push(&frame[..8]).unwrap().is_empty());
        let error = parser.finish().unwrap_err();

        assert_eq!(error.code, "incomplete_eventstream_frame");
    }

    #[test]
    fn aws_eventstream_parser_rejects_oversized_frame_length() {
        let mut parser = AWSEventStreamParser::new(32);
        let mut prelude = Vec::new();
        prelude.extend_from_slice(&64_u32.to_be_bytes());
        prelude.extend_from_slice(&0_u32.to_be_bytes());
        let crc = crc32fast::hash(&prelude);
        prelude.extend_from_slice(&crc.to_be_bytes());

        let error = parser.push(&prelude).unwrap_err();

        assert_eq!(error.code, "eventstream_frame_too_large");
    }

    #[test]
    fn aws_eventstream_parser_reads_exception_and_error_identity() {
        let exception = eventstream_frame(
            &[
                (":message-type", "exception"),
                (":exception-type", "throttlingException"),
                (":content-type", "application/json"),
            ],
            br#"{"message":"slow down"}"#,
        );
        let error = eventstream_frame(
            &[
                (":message-type", "error"),
                (":error-code", "InternalFailure"),
                (":error-message", "internal failure"),
            ],
            b"",
        );
        let mut parser = AWSEventStreamParser::new(1024);
        let messages = parser.push(&[exception, error].concat()).unwrap();

        assert_eq!(messages[0].message_type.as_deref(), Some("exception"));
        assert_eq!(
            messages[0].exception_type.as_deref(),
            Some("throttlingException")
        );
        assert_eq!(messages[0].payload, br#"{"message":"slow down"}"#);
        assert_eq!(messages[1].message_type.as_deref(), Some("error"));
        assert_eq!(messages[1].error_code.as_deref(), Some("InternalFailure"));
        assert_eq!(
            messages[1].error_message.as_deref(),
            Some("internal failure")
        );
    }

    #[test]
    fn aws_eventstream_parser_skips_every_header_value_type() {
        let mut headers = Vec::new();
        for (value_type, value) in [
            (0, vec![]),
            (1, vec![]),
            (2, vec![7]),
            (3, vec![0; 2]),
            (4, vec![0; 4]),
            (5, vec![0; 8]),
            (6, vec![0, 3, 1, 2, 3]),
            (8, vec![0; 8]),
            (9, vec![0; 16]),
        ] {
            headers.extend(eventstream_header(
                &format!("x-type-{value_type}"),
                value_type,
                &value,
            ));
        }
        headers.extend(string_header(":message-type", "exception"));
        headers.extend(string_header(":exception-type", "validationException"));
        let frame = eventstream_frame_with_headers(&headers, br#"{"message":"bad input"}"#);
        let mut parser = AWSEventStreamParser::new(1024);

        let messages = parser.push(&frame).unwrap();

        assert_eq!(messages[0].message_type.as_deref(), Some("exception"));
        assert_eq!(
            messages[0].exception_type.as_deref(),
            Some("validationException")
        );
        assert_eq!(messages[0].payload, br#"{"message":"bad input"}"#);
    }

    pub(crate) fn eventstream_frame(headers: &[(&str, &str)], payload: &[u8]) -> Vec<u8> {
        let encoded_headers = headers
            .iter()
            .flat_map(|(name, value)| string_header(name, value))
            .collect::<Vec<_>>();
        eventstream_frame_with_headers(&encoded_headers, payload)
    }

    fn string_header(name: &str, value: &str) -> Vec<u8> {
        let mut encoded = (value.len() as u16).to_be_bytes().to_vec();
        encoded.extend_from_slice(value.as_bytes());
        eventstream_header(name, 7, &encoded)
    }

    fn eventstream_header(name: &str, value_type: u8, value: &[u8]) -> Vec<u8> {
        let mut header = vec![name.len() as u8];
        header.extend_from_slice(name.as_bytes());
        header.push(value_type);
        header.extend_from_slice(value);
        header
    }

    fn eventstream_frame_with_headers(encoded_headers: &[u8], payload: &[u8]) -> Vec<u8> {
        let total_length = 16 + encoded_headers.len() + payload.len();
        let mut frame = Vec::new();
        frame.extend_from_slice(&(total_length as u32).to_be_bytes());
        frame.extend_from_slice(&(encoded_headers.len() as u32).to_be_bytes());
        let prelude_crc = crc32fast::hash(&frame);
        frame.extend_from_slice(&prelude_crc.to_be_bytes());
        frame.extend_from_slice(encoded_headers);
        frame.extend_from_slice(payload);
        let message_crc = crc32fast::hash(&frame);
        frame.extend_from_slice(&message_crc.to_be_bytes());
        frame
    }
}
