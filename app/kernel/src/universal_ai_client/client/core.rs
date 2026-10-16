use std::future::Future;
use std::panic::AssertUnwindSafe;
use std::sync::Arc;
use std::sync::atomic::AtomicBool;

use futures_util::FutureExt;
use futures_util::future::{AbortHandle, Abortable};
use serde_json::{Value, json};
use tokio::sync::mpsc;

use super::stream::{
    decode_raw_response_body, decode_response_body, run_stream, send_aborted_once,
};
use crate::common::{KernelError, KernelResult, io_runtime};
use crate::universal_ai_client::{
    api_resolver, error::StreamError, hosted_responses, request_builder, transport,
};

pub use crate::universal_ai_client::spec::{
    APIResolverKind, ModelRequestSpec, RawRequestSpec, StreamLimits, StreamSpec, UpstreamKind,
};

pub type EventSink = Arc<dyn Fn(StreamEvent) + Send + Sync + 'static>;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ChunkOrigin {
    Provider,
    Client,
}

#[derive(Debug)]
pub enum StreamEvent {
    Ready(Value),
    Chunk {
        seq: u64,
        origin: ChunkOrigin,
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

        // A completed stream has already sent its terminal event.
        // Late credit must not replace that event with a read failure.
        match self.command_tx.try_send(StreamCommand::Demand(count)) {
            Ok(()) | Err(mpsc::error::TrySendError::Closed(_)) => Ok(()),
            Err(mpsc::error::TrySendError::Full(_)) => Err(KernelError::new(
                "universal AI client command queue is full",
            )),
        }
    }

    pub fn cancel(&self) -> KernelResult<()> {
        let send_result = self.command_tx.try_send(StreamCommand::Cancel);
        let sink = self.sink.clone();
        let aborted_sent = self.aborted_sent.clone();
        let abort_handle = self.abort_handle.clone();
        io_runtime::runtime()?.spawn(async move {
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
    let runtime = io_runtime::runtime()?;
    let (command_tx, command_rx) = mpsc::channel(COMMAND_QUEUE_CAPACITY);
    let (abort_handle, abort_registration) = AbortHandle::new_pair();
    let aborted_sent = Arc::new(AtomicBool::new(false));

    runtime.spawn(Abortable::new(
        report_stream_panic(
            run_stream(spec, command_rx, sink.clone(), aborted_sent.clone()),
            sink.clone(),
        ),
        abort_registration,
    ));

    Ok(StreamHandle {
        command_tx,
        abort_handle,
        sink,
        aborted_sent,
    })
}

async fn report_stream_panic(stream: impl Future<Output = ()>, sink: EventSink) {
    if let Err(panic) = AssertUnwindSafe(stream).catch_unwind().await {
        sink(StreamEvent::Error(
            native_panic_error("stream", panic).to_json(),
        ));
    }
}

pub type RequestResultSink = Box<dyn FnOnce(Result<Value, StreamError>) + Send + 'static>;

pub fn start_model_request(
    encoded_spec: &str,
    deliver: RequestResultSink,
) -> Result<(), StreamError> {
    let spec = ModelRequestSpec::from_json(encoded_spec)
        .map_err(|reason| StreamError::new("invalid_spec", "spec", reason.to_string()))?;
    let runtime = io_runtime::runtime()
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
    let runtime = io_runtime::runtime()
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
        .unwrap_or_else(|panic| Err(native_panic_error("request", panic)));

    deliver(result);
}

fn native_panic_error(kind: &str, panic: Box<dyn std::any::Any + Send>) -> StreamError {
    let message = panic
        .downcast_ref::<&'static str>()
        .copied()
        .or_else(|| panic.downcast_ref::<String>().map(String::as_str))
        .unwrap_or("unknown panic");
    StreamError::new(
        format!("native_{kind}_panicked"),
        "runtime",
        format!("universal AI client {kind} panicked: {message}"),
    )
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
        "headers": transport::safe_response_headers(&response.headers),
        "body": normalized_body,
        "raw_body_bytes": response.body.len(),
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
    }))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn late_credit_does_not_replace_the_native_terminal() {
        let (command_tx, command_rx) = mpsc::channel(1);
        let (abort_handle, _registration) = AbortHandle::new_pair();
        let stream = StreamHandle {
            command_tx,
            abort_handle,
            sink: Arc::new(|_| panic!("late credit must not send another event")),
            aborted_sent: Arc::new(AtomicBool::new(false)),
        };

        drop(command_rx);
        stream.read(1).unwrap();
    }

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

    #[tokio::test]
    async fn a_panicking_stream_notifies_its_owner() {
        let (event_tx, event_rx) = std::sync::mpsc::channel();
        let sink: EventSink = Arc::new(move |event| event_tx.send(event).unwrap());

        report_stream_panic(async { panic!("stream task exploded") }, sink).await;

        let StreamEvent::Error(error) = event_rx.recv().unwrap() else {
            panic!("expected a stream error");
        };
        assert_eq!(error["code"], "native_stream_panicked");
        assert_eq!(error["stage"], "runtime");
        assert!(
            error["message"]
                .as_str()
                .unwrap()
                .contains("stream task exploded")
        );
        assert!(event_rx.try_recv().is_err());
    }
}
