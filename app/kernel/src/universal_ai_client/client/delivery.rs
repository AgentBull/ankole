use super::core::{ChunkOrigin, EventSink, StreamCommand, StreamEvent};
use super::stream::send_aborted_once;
use crate::universal_ai_client::{
    api_resolver,
    downstream::{DownstreamChunk, DownstreamEncoder},
    error::StreamError,
    spec::StreamLimits,
};
use serde_json::{Value, json};
use std::collections::VecDeque;
use std::future::Future;
use std::sync::{Arc, atomic::AtomicBool};
use tokio::sync::mpsc;

pub(in crate::universal_ai_client) struct Delivery {
    pub(in crate::universal_ai_client) command_rx: mpsc::Receiver<StreamCommand>,
    sink: EventSink,
    encoder: DownstreamEncoder,
    pending: VecDeque<(DownstreamChunk, ChunkOrigin)>,
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

    // Terminal batches can exceed the pending byte window for a long response.
    // They still consume read credit. Only mid-stream batches use that window.
    pub(super) fn push_events(&mut self, events: Vec<Value>) {
        for event in events {
            self.push_chunk(self.encoder.encode_event(&event), ChunkOrigin::Provider);
        }
    }

    fn has_response_events(&self) -> bool {
        // Queued events belong to this attempt before read credit arrives.
        self.seq > 0 || !self.pending.is_empty()
    }

    /// `Ok(false)` means that downstream cancellation was already reported.
    pub(in crate::universal_ai_client) async fn push_events_bounded(
        &mut self,
        events: Vec<Value>,
        origin: ChunkOrigin,
    ) -> Result<bool, StreamError> {
        for event in events {
            let chunk = self.encoder.encode_event(&event);

            if chunk.bytes.len() > self.max_pending_bytes {
                return Err(StreamError::new(
                    "response_body_too_large",
                    "downstream",
                    format!(
                        "downstream event of {} bytes exceeded the pending byte limit of {}",
                        chunk.bytes.len(),
                        self.max_pending_bytes
                    ),
                ));
            }

            if !self.push_chunk_when_capacity(chunk, origin).await {
                return Ok(false);
            }
        }

        Ok(true)
    }

    async fn push_chunk_when_capacity(
        &mut self,
        chunk: DownstreamChunk,
        origin: ChunkOrigin,
    ) -> bool {
        self.flush_pending_available();
        while !self.has_capacity_for(chunk.bytes.len()) {
            let command = self.command_rx.recv().await;
            if !self.handle_command(command) {
                return false;
            }
            self.flush_pending_available();
        }

        self.push_chunk(chunk, origin);
        self.flush_pending_available();
        true
    }

    fn push_chunk(&mut self, chunk: DownstreamChunk, origin: ChunkOrigin) {
        self.pending_bytes = self.pending_bytes.saturating_add(chunk.bytes.len());
        self.pending.push_back((chunk, origin));
    }

    pub(super) async fn wait_for_read_capacity(&mut self) -> bool {
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

    pub(super) async fn wait_upstream<F, T>(&mut self, future: F) -> Option<T>
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
        let Some((chunk, origin)) = self.pending.pop_front() else {
            return;
        };
        self.pending_bytes = self.pending_bytes.saturating_sub(chunk.bytes.len());
        self.credit = self.credit.saturating_sub(1);
        self.seq += 1;
        (self.sink)(StreamEvent::Chunk {
            seq: self.seq,
            origin,
            bytes: chunk.bytes,
        });
    }

    pub(in crate::universal_ai_client) async fn finish_done(mut self, summary: Value) {
        let _ = self.finish_done_pending(summary).await;
    }

    pub(super) async fn finish_done_pending(&mut self, summary: Value) -> bool {
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
        for event in events {
            self.push_chunk(self.encoder.encode_event(&event), ChunkOrigin::Client);
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

pub(super) fn summary(reason: &str) -> Value {
    json!({ "reason": reason })
}

pub(super) async fn ingest_resolver_event(
    delivery: &mut Delivery,
    resolver: &mut api_resolver::APIResolver,
    value: Value,
) -> Result<bool, StreamError> {
    let events = resolver.ingest(value)?;
    flush_resolver_events(delivery, resolver, events).await
}

pub(super) async fn flush_resolver_events(
    delivery: &mut Delivery,
    resolver: &api_resolver::APIResolver,
    events: Vec<Value>,
) -> Result<bool, StreamError> {
    if resolver.is_terminal() {
        delivery.push_events(events);
        delivery
            .finish_done_pending(summary("provider_terminal"))
            .await;
        Ok(false)
    } else {
        delivery
            .push_events_bounded(events, ChunkOrigin::Provider)
            .await
    }
}

pub(super) async fn finish_after_ready_error(
    delivery: Delivery,
    resolver: &mut api_resolver::APIResolver,
    error: StreamError,
) {
    if !delivery.has_response_events() {
        delivery
            .finish_native_error_with_metadata(error, None)
            .await;
        return;
    }

    let events = resolver.fail(&error);
    delivery.finish_error_events(events, error).await;
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::universal_ai_client::spec::{APIResolverKind, ResponseContext};
    use std::time::Duration;
    fn test_delivery(
        limits: &StreamLimits,
    ) -> (
        mpsc::Sender<StreamCommand>,
        std::sync::mpsc::Receiver<StreamEvent>,
        Delivery,
    ) {
        let (command_tx, command_rx) = mpsc::channel(8);
        let (event_tx, event_rx) = std::sync::mpsc::channel();
        let sink: EventSink = Arc::new(move |event| {
            let _ = event_tx.send(event);
        });
        let delivery = Delivery::new(
            command_rx,
            sink,
            DownstreamEncoder,
            Arc::new(AtomicBool::new(false)),
            limits,
        );
        (command_tx, event_rx, delivery)
    }

    #[tokio::test]
    async fn failures_before_response_events_stay_native_without_read_credit() {
        for status in [400, 429, 529] {
            let (_command_tx, event_rx, delivery) = test_delivery(&StreamLimits::default());
            let mut resolver = api_resolver::APIResolver::new(
                APIResolverKind::OpenAIResponses,
                ResponseContext::default(),
            );
            let error = StreamError::new("provider_stream_error", "read", "provider failed")
                .provider_status(status);

            tokio::time::timeout(
                Duration::from_secs(1),
                finish_after_ready_error(delivery, &mut resolver, error),
            )
            .await
            .unwrap();

            match event_rx.try_recv().unwrap() {
                StreamEvent::Error(error) => assert_eq!(error["provider_status"], status),
                event => panic!("expected native failure before any response event, got {event:?}"),
            }
            assert!(event_rx.try_recv().is_err());
        }
    }

    #[tokio::test]
    async fn buffered_response_events_close_the_native_failure_window() {
        for status in [400, 429, 529] {
            let (command_tx, event_rx, mut delivery) = test_delivery(&StreamLimits::default());
            let mut resolver = api_resolver::APIResolver::new(
                APIResolverKind::OpenAIResponses,
                ResponseContext::default(),
            );
            let events = resolver
                .ingest(json!({
                    "type": "response.created",
                    "response": {"id": "resp_buffered", "status": "in_progress", "output": []}
                }))
                .unwrap();
            delivery.push_events(events);
            let error = StreamError::new("provider_stream_error", "read", "provider failed")
                .provider_status(status)
                .provider_error_type("provider_failure");
            let finish = finish_after_ready_error(delivery, &mut resolver, error);
            tokio::pin!(finish);

            assert!(
                tokio::time::timeout(Duration::from_millis(50), finish.as_mut())
                    .await
                    .is_err()
            );
            assert!(event_rx.try_recv().is_err());

            command_tx.send(StreamCommand::Demand(1)).await.unwrap();
            assert!(
                tokio::time::timeout(Duration::from_millis(50), finish.as_mut())
                    .await
                    .is_err()
            );
            let StreamEvent::Chunk {
                seq: 1,
                origin: ChunkOrigin::Provider,
                bytes,
            } = event_rx.try_recv().unwrap()
            else {
                panic!("the original response event must precede its failure");
            };
            assert_eq!(
                sonic_rs::from_slice::<Value>(&bytes).unwrap()["type"],
                "response.created"
            );
            assert!(event_rx.try_recv().is_err());

            command_tx.send(StreamCommand::Demand(1)).await.unwrap();
            tokio::time::timeout(Duration::from_secs(1), finish.as_mut())
                .await
                .unwrap();
            let StreamEvent::Chunk {
                seq: 2,
                origin: ChunkOrigin::Client,
                bytes,
            } = event_rx.try_recv().unwrap()
            else {
                panic!("expected one normalized failure terminal");
            };
            let terminal = sonic_rs::from_slice::<Value>(&bytes).unwrap();
            assert_eq!(terminal["type"], "response.failed");
            assert_eq!(terminal["response"]["id"], "resp_buffered");
            assert_eq!(terminal["response"]["error"]["status"], status);
            assert_eq!(
                terminal["response"]["error"]["details_json"]["provider_error_type"],
                "provider_failure"
            );
            assert!(matches!(event_rx.try_recv(), Ok(StreamEvent::Error(_))));
            assert!(event_rx.try_recv().is_err());
        }
    }

    #[tokio::test]
    async fn terminal_batches_keep_complete_output_beyond_the_pending_byte_window() {
        let limits = StreamLimits {
            max_pending_bytes: 2048,
            ..StreamLimits::default()
        };
        let (command_tx, event_rx, mut delivery) = test_delivery(&limits);
        let mut resolver = api_resolver::APIResolver::new(
            APIResolverKind::OpenAIResponses,
            ResponseContext::default(),
        );
        let created = resolver
            .ingest(json!({"type": "response.created", "response": {
                "id": "resp_large", "status": "in_progress", "output": []
            }}))
            .unwrap();
        assert!(
            flush_resolver_events(&mut delivery, &resolver, created)
                .await
                .unwrap()
        );

        let text = "x".repeat(4096);
        let terminal = resolver.ingest(json!({"type": "response.completed", "response": {
            "id": "resp_large", "status": "completed", "output": [{
                "id": "msg_large", "type": "message", "role": "assistant", "status": "completed",
                "content": [{"type": "output_text", "text": text, "annotations": []}]
            }]
        }})).unwrap();
        assert!(sonic_rs::to_vec(&terminal[0]).unwrap().len() > limits.max_pending_bytes);
        let flush = flush_resolver_events(&mut delivery, &resolver, terminal);
        tokio::pin!(flush);
        assert!(
            tokio::time::timeout(Duration::from_millis(50), flush.as_mut())
                .await
                .is_err()
        );
        assert!(event_rx.try_recv().is_err());

        command_tx.send(StreamCommand::Demand(1)).await.unwrap();
        assert!(
            tokio::time::timeout(Duration::from_millis(50), flush.as_mut())
                .await
                .is_err()
        );
        let StreamEvent::Chunk {
            seq: 1,
            origin: ChunkOrigin::Provider,
            bytes,
        } = event_rx.try_recv().unwrap()
        else {
            panic!("the created event must precede the terminal");
        };
        assert_eq!(
            sonic_rs::from_slice::<Value>(&bytes).unwrap()["type"],
            "response.created"
        );
        assert!(event_rx.try_recv().is_err());

        command_tx.send(StreamCommand::Demand(1)).await.unwrap();
        assert!(
            !tokio::time::timeout(Duration::from_secs(1), flush.as_mut())
                .await
                .unwrap()
                .unwrap()
        );
        let StreamEvent::Chunk {
            seq: 2,
            origin: ChunkOrigin::Provider,
            bytes,
        } = event_rx.try_recv().unwrap()
        else {
            panic!("the complete terminal must consume its own read credit");
        };
        let terminal = sonic_rs::from_slice::<Value>(&bytes).unwrap();
        assert_eq!(terminal["type"], "response.completed");
        assert_eq!(
            terminal["response"]["output"][0]["content"][0]["text"],
            text
        );
        assert!(matches!(event_rx.try_recv(), Ok(StreamEvent::Done(_))));
        assert!(event_rx.try_recv().is_err());
    }

    #[tokio::test]
    async fn mid_stream_batches_wait_for_credit_under_the_pending_limit() {
        let limits = StreamLimits {
            max_pending_chunks: 2,
            ..StreamLimits::default()
        };
        let (command_tx, event_rx, mut delivery) = test_delivery(&limits);
        let resolver = api_resolver::APIResolver::new(
            APIResolverKind::OpenAIResponses,
            ResponseContext::default(),
        );
        let events = (0..5)
            .map(|index| {
                json!({"type": "response.output_text.delta", "delta": format!("chunk {index}")})
            })
            .collect::<Vec<_>>();

        let flush = flush_resolver_events(&mut delivery, &resolver, events);
        tokio::pin!(flush);

        assert!(
            tokio::time::timeout(Duration::from_millis(50), flush.as_mut())
                .await
                .is_err()
        );
        assert!(event_rx.try_recv().is_err());

        command_tx.send(StreamCommand::Demand(1)).await.unwrap();
        assert!(
            tokio::time::timeout(Duration::from_millis(50), flush.as_mut())
                .await
                .is_err()
        );
        assert!(matches!(
            event_rx.try_recv(),
            Ok(StreamEvent::Chunk { seq: 1, .. })
        ));
        assert!(event_rx.try_recv().is_err());

        command_tx.send(StreamCommand::Demand(16)).await.unwrap();
        let completed = tokio::time::timeout(Duration::from_secs(1), flush.as_mut())
            .await
            .unwrap()
            .unwrap();

        assert!(completed);
        assert_eq!(std::iter::from_fn(|| event_rx.try_recv().ok()).count(), 4);
    }

    #[tokio::test]
    async fn an_event_beyond_the_pending_byte_limit_fails_loudly() {
        let limits = StreamLimits {
            max_pending_bytes: 128,
            ..StreamLimits::default()
        };
        let (_command_tx, _event_rx, mut delivery) = test_delivery(&limits);
        let resolver = api_resolver::APIResolver::new(
            APIResolverKind::OpenAIResponses,
            ResponseContext::default(),
        );
        let events = vec![json!({
            "type": "response.output_text.delta",
            "delta": "x".repeat(4096)
        })];

        let error = flush_resolver_events(&mut delivery, &resolver, events)
            .await
            .unwrap_err();

        assert_eq!(error.code, "response_body_too_large");
        assert!(error.message.contains("pending byte limit"));
    }
}
