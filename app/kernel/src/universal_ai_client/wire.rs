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
    stream_start: bool,
    pending_lf: bool,
}

impl SSEParser {
    pub fn new(max_event_bytes: usize) -> Self {
        Self {
            buffer: Vec::new(),
            max_event_bytes: max_event_bytes.max(1),
            scan_from: 0,
            stream_start: true,
            pending_lf: false,
        }
    }

    pub fn push(&mut self, bytes: &[u8]) -> Result<Vec<SSEEvent>, StreamError> {
        let bytes = if self.pending_lf && !bytes.is_empty() {
            self.pending_lf = false;
            bytes.strip_prefix(b"\n").unwrap_or(bytes)
        } else {
            bytes
        };
        self.buffer.extend_from_slice(bytes);
        if self.stream_start {
            const BOM: &[u8] = b"\xef\xbb\xbf";
            if self.buffer.len() < BOM.len() && BOM.starts_with(&self.buffer) {
                return Ok(Vec::new());
            }
            if self.buffer.starts_with(BOM) {
                self.buffer.drain(..BOM.len());
            }
            self.stream_start = false;
        }
        let mut events = Vec::new();

        while let Some((index, boundary_len)) = find_sse_boundary(&self.buffer, self.scan_from) {
            if index > self.max_event_bytes {
                return Err(StreamError::new(
                    "sse_event_too_large",
                    "wire",
                    format!("upstream SSE event exceeded {} bytes", self.max_event_bytes),
                ));
            }

            // A trailing CR ends the event immediately; its optional LF may
            // arrive in the next network chunk and belongs to this boundary.
            self.pending_lf =
                self.buffer.len() == index + boundary_len && self.buffer.last() == Some(&b'\r');
            let mut raw = &self.buffer[..index];
            while let Some(stripped) = raw.strip_suffix(b"\n").or_else(|| raw.strip_suffix(b"\r")) {
                raw = stripped;
            }
            let event = parse_sse_event(raw);
            self.buffer.drain(..index + boundary_len);
            self.scan_from = 0;

            if let Some(event) = event {
                events.push(event);
            }
        }

        // The final line ending may be the first half of an event boundary.
        // Count the same event content whether that boundary is split or whole.
        let suffix = if self.buffer.ends_with(b"\r\n") {
            2
        } else if self.buffer.ends_with(b"\r") || self.buffer.ends_with(b"\n") {
            1
        } else {
            0
        };
        if self.buffer.len() - suffix > self.max_event_bytes {
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
        if buffer[index] == b'\n' && index > 0 && buffer[index - 1] == b'\r' {
            return None;
        }
        let first = line_ending_len(&buffer[index..]);
        if first == 0 {
            return None;
        }
        let second = line_ending_len(&buffer[index + first..]);
        (second > 0).then_some((index, first + second))
    })
}

fn line_ending_len(bytes: &[u8]) -> usize {
    if bytes.starts_with(b"\r\n") {
        2
    } else if bytes.starts_with(b"\r") || bytes.starts_with(b"\n") {
        1
    } else {
        0
    }
}

fn parse_sse_event(raw: &[u8]) -> Option<SSEEvent> {
    let text = String::from_utf8_lossy(raw);
    let mut event = None;
    let mut data_lines = Vec::new();

    for line in text.split(['\r', '\n']) {
        if line.is_empty() || line.starts_with(':') {
            continue;
        }
        let (field, value) = line.split_once(':').unwrap_or((line, ""));
        let value = value.strip_prefix(' ').unwrap_or(value);
        match field {
            "event" => event = Some(value.to_string()),
            "data" => data_lines.push(value.to_string()),
            _ => {}
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

            let headers_start = 12;
            let headers_end = headers_start + headers_length;
            let payload_end = total_length - 4;
            let result = {
                let frame = &self.buffer[..total_length];
                validate_crc(frame).and_then(|()| {
                    let mut message =
                        parse_eventstream_headers(&frame[headers_start..headers_end])?;
                    message.payload = frame[headers_end..payload_end].to_vec();
                    Ok(message)
                })
            };
            self.buffer.drain(..total_length);
            messages.push(result?);
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
    fn sse_boundaries_bom_and_limit_are_independent_of_network_chunks() {
        for ending in ["\n", "\r", "\r\n"] {
            let input = format!("\u{feff}data:  x{ending}{ending}data:{ending}{ending}");
            for split in 0..=input.len() {
                let mut parser = SSEParser::new(8);
                let mut events = parser.push(&input.as_bytes()[..split]).unwrap();
                events.extend(parser.push(&input.as_bytes()[split..]).unwrap());
                assert_eq!(
                    events.iter().map(|e| e.data.as_str()).collect::<Vec<_>>(),
                    [" x", ""]
                );
                parser.finish().unwrap();
            }
            let input = format!("data: 12{ending}{ending}");
            for split in 0..=input.len() {
                let mut parser = SSEParser::new(8);
                let mut events = parser.push(&input.as_bytes()[..split]).unwrap();
                events.extend(parser.push(&input.as_bytes()[split..]).unwrap());
                assert_eq!(events.len(), 1);
                parser.finish().unwrap();
            }
        }
    }

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
        let events = parser.push(b"\r").unwrap();
        assert!(parser.push(b"\n").unwrap().is_empty());

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
