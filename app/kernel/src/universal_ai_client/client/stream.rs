async fn run_stream(
    spec: StreamSpec,
    command_rx: mpsc::Receiver<StreamCommand>,
    sink: EventSink,
    aborted_sent: Arc<AtomicBool>,
) {
    let spec = match request_builder::prepare_stream_spec(spec) {
        Ok(spec) => spec,
        Err(error) => {
            sink(StreamEvent::Error(error.to_json()));
            return;
        }
    };

    match spec.upstream.kind {
        UpstreamKind::HttpSse | UpstreamKind::HttpEventstream => {
            run_http_stream(spec, command_rx, sink, aborted_sent).await;
        }
        UpstreamKind::WebsocketText => {
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
        let error =
            provider_status_error(&spec, http_stream.0.status, &mut http_stream.0.body).await;
        sink(StreamEvent::Error(error.to_json()));
        return;
    }

    let encoder = DownstreamEncoder::new(spec.downstream);
    let mut resolver = api_resolver::ApiResolver::new(
        spec.api_resolver,
        spec.response_context.clone(),
    );
    let mut delivery = Delivery::new(
        http_stream.1,
        sink.clone(),
        encoder,
        aborted_sent,
        &spec.limits,
    );

    sink(StreamEvent::Ready(json!({
        "status": http_stream.0.status,
        "headers": http_stream.0.headers,
        "upstream_kind": spec.upstream.kind.as_str(),
        "downstream_kind": spec.downstream.as_str(),
        "api_resolver": spec.api_resolver.as_str(),
        "http_version": http_stream.0.version,
        "http_negotiation": http_stream.0.negotiation
    })));

    match spec.upstream.kind {
        UpstreamKind::HttpSse => {
            let mut parser = wire::SseParser::new(spec.limits.max_sse_event_bytes);
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
                            StreamError::new("upstream_read_failed", "read", reason.to_string());
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
                        );
                        finish_after_ready_error(delivery, &mut resolver, error).await;
                        return;
                    }
                }
            }
        }
        UpstreamKind::HttpEventstream => {
            let mut parser =
                wire::AwsEventStreamParser::new(spec.limits.max_eventstream_frame_bytes);
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
        UpstreamKind::WebsocketText => unreachable!("websocket stream is handled separately"),
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
    let (mut websocket, command_rx) = match opened {
        WebsocketOpenResult::Opened {
            websocket,
            command_rx,
        } => (websocket, command_rx),
        WebsocketOpenResult::Finished => return,
    };

    let websocket_initial_messages = websocket_initial_messages(&spec);
    for payload in &websocket_initial_messages {
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
    let mut resolver = api_resolver::ApiResolver::new(
        spec.api_resolver,
        spec.response_context.clone(),
    );
    let mut delivery = Delivery::new(
        command_rx,
        sink.clone(),
        encoder,
        aborted_sent,
        &spec.limits,
    );

    sink(StreamEvent::Ready(json!({
        "status": 101,
        "headers": [],
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
                    );
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
                let error = StreamError::new("websocket_read_failed", "read", reason.to_string());
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

enum OpenResult {
    Opened {
        stream: transport::HttpStream,
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

enum WebsocketOpenResult {
    Opened {
        websocket: transport::UpstreamWebSocket,
        command_rx: mpsc::Receiver<StreamCommand>,
    },
    Finished,
}

async fn wait_for_open_websocket(
    spec: &StreamSpec,
    mut command_rx: mpsc::Receiver<StreamCommand>,
    sink: EventSink,
    aborted_sent: Arc<AtomicBool>,
) -> WebsocketOpenResult {
    let open = transport::open_websocket(spec);
    tokio::pin!(open);

    loop {
        tokio::select! {
            result = &mut open => {
                return match result {
                    Ok((websocket, status)) if status == 101 => {
                        WebsocketOpenResult::Opened { websocket, command_rx }
                    }
                    Ok((_websocket, status)) => {
                        sink(StreamEvent::Error(StreamError::new(
                            "websocket_status_rejected",
                            "connect",
                            format!("upstream WebSocket returned status {status}"),
                        ).provider_status(status).to_json()));
                        WebsocketOpenResult::Finished
                    }
                    Err(error) => {
                        sink(StreamEvent::Error(error.to_json()));
                        WebsocketOpenResult::Finished
                    }
                };
            },
            command = command_rx.recv() => {
                if matches!(command, Some(StreamCommand::Cancel) | None) {
                    send_aborted_once(&sink, &aborted_sent);
                    return WebsocketOpenResult::Finished;
                }
            }
        }
    }
}

struct Delivery {
    command_rx: mpsc::Receiver<StreamCommand>,
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
    fn new(
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

    fn flush_pending_available(&mut self) {
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

    async fn finish_done(mut self, summary: Value) {
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

    async fn finish_error_events(mut self, events: Vec<Value>, error: StreamError) {
        if events.is_empty() {
            self.push_chunk(self.encoder.encode_error(&error));
        } else {
            self.push_events(events);
        }

        if let Some(chunk) = self.encoder.encode_done_sentinel() {
            self.push_chunk(chunk);
        }

        if self.flush_pending_blocking().await {
            (self.sink)(StreamEvent::Error(error.to_json()));
        }
    }

    fn handle_command(&mut self, command: Option<StreamCommand>) -> bool {
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
    resolver: &api_resolver::ApiResolver,
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

fn command_send_error(error: mpsc::error::TrySendError<StreamCommand>) -> KernelError {
    match error {
        mpsc::error::TrySendError::Full(_) => {
            KernelError::new("universal AI client command queue is full")
        }
        mpsc::error::TrySendError::Closed(_) => {
            KernelError::new("universal AI client stream is closed")
        }
    }
}

fn decode_response_body(body: &[u8]) -> Result<Value, StreamError> {
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

fn decode_raw_response_body(body: &[u8]) -> Value {
    sonic_rs::from_slice::<Value>(body).unwrap_or_else(|_| {
        String::from_utf8(body.to_vec())
            .map(Value::String)
            .unwrap_or_else(|_| Value::String(String::from_utf8_lossy(body).to_string()))
    })
}

fn send_aborted_once(sink: &EventSink, aborted_sent: &AtomicBool) {
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

async fn finish_after_ready_error(
    delivery: Delivery,
    resolver: &mut api_resolver::ApiResolver,
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
}
