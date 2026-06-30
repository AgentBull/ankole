use std::collections::VecDeque;
use std::future::Future;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};

use downstream::{DownstreamChunk, DownstreamEncoder};
use error::StreamError;
use futures_util::future::{AbortHandle, Abortable};
use futures_util::{SinkExt, StreamExt};
use serde_json::{Value, json};
use tokio::sync::mpsc;
use tokio::time::timeout;
use tokio_tungstenite::tungstenite::Message;

pub use spec::{
    DownstreamKind, ModelRequestSpec, RawRequestSpec, ApiResolverKind, StreamLimits,
    StreamSpec, UpstreamKind,
};

use crate::common::{KernelError, KernelResult};

pub type EventSink = Arc<dyn Fn(StreamEvent) + Send + Sync + 'static>;

#[derive(Debug)]
pub enum StreamEvent {
    Ready(Value),
    Chunk {
        seq: u64,
        kind: DownstreamKind,
        bytes: Vec<u8>,
    },
    Done(Value),
    Error(Value),
    Aborted,
}

#[derive(Debug)]
enum StreamCommand {
    Demand(u64),
    Cancel,
}

const COMMAND_QUEUE_CAPACITY: usize = 64;

pub struct StreamHandle {
    command_tx: mpsc::Sender<StreamCommand>,
    abort_handle: AbortHandle,
    sink: EventSink,
    aborted_sent: Arc<AtomicBool>,
}

impl StreamHandle {
    pub fn read(&self, count: u64) -> KernelResult<()> {
        if count == 0 {
            return Ok(());
        }

        self.command_tx
            .try_send(StreamCommand::Demand(count))
            .map_err(command_send_error)
    }

    pub fn cancel(&self) -> KernelResult<()> {
        let send_result = self.command_tx.try_send(StreamCommand::Cancel);
        let sink = self.sink.clone();
        let aborted_sent = self.aborted_sent.clone();
        let abort_handle = self.abort_handle.clone();
        runtime::runtime()?.spawn(async move {
            send_aborted_once(&sink, &aborted_sent);
            abort_handle.abort();
        });

        match send_result {
            Ok(()) | Err(mpsc::error::TrySendError::Full(_)) => Ok(()),
            Err(mpsc::error::TrySendError::Closed(_)) => {
                Err(KernelError::new("universal AI client stream is closed"))
            }
        }
    }
}

impl Drop for StreamHandle {
    fn drop(&mut self) {
        let _ = self.command_tx.try_send(StreamCommand::Cancel);
        self.abort_handle.abort();
    }
}

pub fn start_stream(encoded_spec: &str, sink: EventSink) -> KernelResult<StreamHandle> {
    let spec = StreamSpec::from_json(encoded_spec)?;
    let runtime = runtime::runtime()?;
    let (command_tx, command_rx) = mpsc::channel(COMMAND_QUEUE_CAPACITY);
    let (abort_handle, abort_registration) = AbortHandle::new_pair();
    let aborted_sent = Arc::new(AtomicBool::new(false));

    runtime.spawn(Abortable::new(
        run_stream(spec, command_rx, sink.clone(), aborted_sent.clone()),
        abort_registration,
    ));

    Ok(StreamHandle {
        command_tx,
        abort_handle,
        sink,
        aborted_sent,
    })
}

pub fn send_model_request(encoded_spec: &str) -> Result<Value, StreamError> {
    let spec = ModelRequestSpec::from_json(encoded_spec)
        .map_err(|reason| StreamError::new("invalid_spec", "spec", reason.to_string()))?;
    let runtime = runtime::runtime()
        .map_err(|reason| StreamError::new("runtime_unavailable", "runtime", reason.to_string()))?;

    runtime.block_on(async move { run_model_request(spec).await })
}

pub fn send_raw_request(encoded_spec: &str) -> Result<Value, StreamError> {
    let spec = RawRequestSpec::from_json(encoded_spec)
        .map_err(|reason| StreamError::new("invalid_spec", "spec", reason.to_string()))?;
    let runtime = runtime::runtime()
        .map_err(|reason| StreamError::new("runtime_unavailable", "runtime", reason.to_string()))?;

    runtime.block_on(async move { run_raw_request(spec).await })
}

async fn run_model_request(spec: ModelRequestSpec) -> Result<Value, StreamError> {
    let upstream = request_builder::prepare_model_upstream(&spec)?;
    let response = transport::send_http_request(&upstream, spec.limits.max_response_bytes).await?;
    if !(200..300).contains(&response.status) {
        return Err(StreamError::new(
            "provider_status_rejected",
            "connect",
            format!("upstream returned HTTP status {}", response.status),
        )
        .provider_status(response.status)
        .provider_body_excerpt(&response.body));
    }

    let body = decode_response_body(&response.body)?;
    let mut resolver = api_resolver::ApiResolver::new(
        spec.api_resolver,
        spec.response_context.clone(),
    );
    let normalized_body = resolver.normalize_body(response.status, body)?;

    Ok(json!({
        "status": response.status,
        "headers": response.headers,
        "body": normalized_body,
        "raw_body_bytes": response.body.len(),
        "http_version": response.version,
        "http_negotiation": response.negotiation
    }))
}

async fn run_raw_request(spec: RawRequestSpec) -> Result<Value, StreamError> {
    let upstream = spec.stream_upstream();
    let response = transport::send_http_request(&upstream, spec.limits.max_response_bytes).await?;
    let body = decode_raw_response_body(&response.body);

    Ok(json!({
        "status": response.status,
        "headers": response.headers,
        "body": body,
        "raw_body_bytes": response.body.len(),
        "http_version": response.version,
        "http_negotiation": response.negotiation
    }))
}
