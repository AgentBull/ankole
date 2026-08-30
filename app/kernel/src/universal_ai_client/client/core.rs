use std::future::Future;
use std::panic::AssertUnwindSafe;
use std::sync::Arc;
use std::sync::atomic::AtomicBool;

use futures_util::FutureExt;
use futures_util::future::{AbortHandle, Abortable};
use serde_json::{Value, json};
use tokio::sync::mpsc;

use super::stream::{
    command_send_error, decode_raw_response_body, decode_response_body, run_stream,
    send_aborted_once,
};
use crate::common::{KernelError, KernelResult};
use crate::universal_ai_client::{
    api_resolver, error::StreamError, hosted_responses, request_builder, runtime, transport,
};

pub use crate::universal_ai_client::spec::{
    APIResolverKind, DownstreamKind, ModelRequestSpec, RawRequestSpec, StreamLimits, StreamSpec,
    UpstreamKind,
};

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
pub(in crate::universal_ai_client) enum StreamCommand {
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

impl std::fmt::Debug for StreamHandle {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("StreamHandle")
            .finish_non_exhaustive()
    }
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

pub type RequestResultSink = Box<dyn FnOnce(Result<Value, StreamError>) + Send + 'static>;

pub fn start_model_request(
    encoded_spec: &str,
    deliver: RequestResultSink,
) -> Result<(), StreamError> {
    let spec = ModelRequestSpec::from_json(encoded_spec)
        .map_err(|reason| StreamError::new("invalid_spec", "spec", reason.to_string()))?;
    let runtime = runtime::runtime()
        .map_err(|reason| StreamError::new("runtime_unavailable", "runtime", reason.to_string()))?;

    runtime.spawn(deliver_request_result(run_model_request(spec), deliver));
    Ok(())
}

pub fn start_raw_request(
    encoded_spec: &str,
    deliver: RequestResultSink,
) -> Result<(), StreamError> {
    let spec = RawRequestSpec::from_json(encoded_spec)
        .map_err(|reason| StreamError::new("invalid_spec", "spec", reason.to_string()))?;
    let runtime = runtime::runtime()
        .map_err(|reason| StreamError::new("runtime_unavailable", "runtime", reason.to_string()))?;

    runtime.spawn(deliver_request_result(run_raw_request(spec), deliver));
    Ok(())
}

// A panic inside the request future becomes an error result, so the owner that
// waits for the delivery message always receives exactly one message.
async fn deliver_request_result(
    request: impl Future<Output = Result<Value, StreamError>>,
    deliver: RequestResultSink,
) {
    let result = AssertUnwindSafe(request)
        .catch_unwind()
        .await
        .unwrap_or_else(|panic| {
            let message = panic
                .downcast_ref::<&'static str>()
                .copied()
                .or_else(|| panic.downcast_ref::<String>().map(String::as_str))
                .unwrap_or("unknown panic");
            Err(StreamError::new(
                "native_request_panicked",
                "runtime",
                format!("universal AI client request panicked: {message}"),
            ))
        });

    deliver(result);
}

async fn run_model_request(spec: ModelRequestSpec) -> Result<Value, StreamError> {
    if spec.hosted_tools.is_some() {
        return hosted_responses::run_hosted_model_request(spec).await;
    }

    run_model_request_once(spec).await
}

pub(in crate::universal_ai_client) async fn run_model_request_once(
    spec: ModelRequestSpec,
) -> Result<Value, StreamError> {
    let upstream = request_builder::prepare_model_upstream(&spec)?;
    let response = transport::send_http_request(&upstream, spec.limits.max_response_bytes).await?;
    if !(200..300).contains(&response.status) {
        return Err(StreamError::new(
            "provider_status_rejected",
            "connect",
            format!("upstream returned HTTP status {}", response.status),
        )
        .provider_status(response.status)
        .provider_body_excerpt(&response.body)
        .provider_headers(&response.headers));
    }

    let body = decode_response_body(&response.body)?;
    let mut resolver =
        api_resolver::APIResolver::new(spec.api_resolver, spec.response_context.clone());
    let normalized_body = resolver.normalize_body(response.status, body)?;

    Ok(json!({
        "status": response.status,
        "headers": transport::codex_response_headers(&response.headers),
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

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn a_panicking_request_future_delivers_an_error_result() {
        let (result_tx, result_rx) = std::sync::mpsc::channel();
        let deliver: RequestResultSink = Box::new(move |result| {
            result_tx.send(result).unwrap();
        });

        deliver_request_result(
            async {
                panic!("request task exploded");
            },
            deliver,
        )
        .await;

        let error = result_rx.recv().unwrap().unwrap_err();
        assert_eq!(error.code, "native_request_panicked");
        assert!(error.message.contains("request task exploded"));
    }
}
