use std::future::Future;
use std::panic::AssertUnwindSafe;
use std::sync::Arc;
use std::sync::atomic::AtomicBool;

use base64_simd::STANDARD;
use futures_util::FutureExt;
use futures_util::future::{AbortHandle, Abortable};
use serde_json::{Value, json};
use tokio::sync::mpsc;

use super::stream::{
    decode_raw_response_body, decode_response_body, run_stream, send_aborted_once,
};
use crate::common::{KernelError, KernelResult, io_runtime, validate_web_url};
use crate::universal_ai_client::{
    api_resolver, error::StreamError, hosted_responses, request_builder, transport,
};

use crate::universal_ai_client::spec::{APIResolverKind, UpstreamSpec};
pub(super) use crate::universal_ai_client::spec::{ModelRequestSpec, RawRequestSpec, StreamSpec};

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
        match self.command_tx.try_send(StreamCommand::Cancel) {
            Ok(()) | Err(mpsc::error::TrySendError::Full(_)) => {
                let sink = self.sink.clone();
                let aborted_sent = self.aborted_sent.clone();
                let abort_handle = self.abort_handle.clone();
                io_runtime::runtime()?.spawn(async move {
                    send_aborted_once(&sink, &aborted_sent);
                    abort_handle.abort();
                });
                Ok(())
            }
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

/// Keeps one non-streaming request bound to its host owner's lifetime.
pub struct RequestHandle(AbortHandle);

impl RequestHandle {
    pub fn cancel(&self) {
        self.0.abort();
    }
}

impl Drop for RequestHandle {
    fn drop(&mut self) {
        self.cancel();
    }
}

pub fn start_model_request(
    encoded_spec: &str,
    deliver: RequestResultSink,
) -> Result<RequestHandle, StreamError> {
    let spec = ModelRequestSpec::from_json(encoded_spec)
        .map_err(|reason| StreamError::new("invalid_spec", "spec", reason.to_string()))?;
    let runtime = io_runtime::runtime()
        .map_err(|reason| StreamError::new("runtime_unavailable", "runtime", reason.to_string()))?;

    let (handle, registration) = AbortHandle::new_pair();
    runtime.spawn(Abortable::new(
        deliver_request_result(run_model_request(spec), deliver),
        registration,
    ));
    Ok(RequestHandle(handle))
}

pub fn start_raw_request(
    encoded_spec: &str,
    deliver: RequestResultSink,
) -> Result<RequestHandle, StreamError> {
    let spec = RawRequestSpec::from_json(encoded_spec)
        .map_err(|reason| StreamError::new("invalid_spec", "spec", reason.to_string()))?;
    let runtime = io_runtime::runtime()
        .map_err(|reason| StreamError::new("runtime_unavailable", "runtime", reason.to_string()))?;

    let (handle, registration) = AbortHandle::new_pair();
    runtime.spawn(Abortable::new(
        deliver_request_result(run_raw_request(spec), deliver),
        registration,
    ));
    Ok(RequestHandle(handle))
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

    let body = if spec.api_resolver.answers_with_audio() {
        audio_body(&response)?
    } else {
        decode_response_body(&response.body)?
    };
    let mut resolver =
        api_resolver::APIResolver::new(spec.api_resolver, spec.response_context.clone());
    let mut normalized_body = resolver.normalize_body(response.status, body)?;
    // Only the Cloudflare image resolver writes `result_url`. In any other
    // resolver's body the field is the provider's own and stays untouched.
    if spec.api_resolver == APIResolverKind::CloudflareImages {
        download_result_url(
            &upstream,
            &mut normalized_body,
            spec.limits.max_response_bytes,
        )
        .await?;
    }

    Ok(json!({
        "status": response.status,
        "headers": transport::safe_response_headers(&response.headers),
        "body": normalized_body,
        "raw_body_bytes": response.body.len(),
    }))
}

/// A Cloudflare image model can answer with a link to the generated file in
/// `result_url`. The client downloads it, so every caller receives the bytes
/// in `result`. The link carries its own signature, so the request sends no
/// provider credential.
///
/// A failed download reports no provider status. The provider has already
/// generated and billed the image, so the caller must neither rotate the
/// credential nor send the request again.
async fn download_result_url(
    upstream: &UpstreamSpec,
    body: &mut Value,
    max_response_bytes: usize,
) -> Result<(), StreamError> {
    let Some(url) = body
        .get("result_url")
        .and_then(Value::as_str)
        .map(str::to_owned)
    else {
        return Ok(());
    };
    let failed = |message: String| StreamError::new("transport_failed", "result_download", message);
    if validate_web_url(&url, &["https", "http"], false).is_err() {
        return Err(failed(
            "the result link is not a web URL that the client fetches".to_string(),
        ));
    }
    let mut download = upstream.clone();
    download.method = "GET".to_string();
    download.url = url;
    download.headers = Vec::new();
    download.body = None;

    let response = transport::send_http_request(&download, max_response_bytes)
        .await
        .map_err(|error| failed(error.message))?;
    if !(200..300).contains(&response.status) {
        return Err(failed(format!(
            "result download returned HTTP status {}",
            response.status
        )));
    }

    if let Some(object) = body.as_object_mut() {
        object.remove("result_url");
        if let Some(mime_type) = api_resolver::image_mime(&response.body) {
            object.insert("mime_type".to_string(), json!(mime_type));
        }
        object.insert(
            "result".to_string(),
            json!(STANDARD.encode_to_string(&response.body)),
        );
    }
    Ok(())
}

/// Hands a speech provider's audio to the resolver as base64 next to the
/// media type that the provider declared. A 2xx body that is not audio is the
/// provider's own error report, so the request fails with its excerpt.
fn audio_body(response: &transport::HTTPResponse) -> Result<Value, StreamError> {
    let media_type = response
        .headers
        .iter()
        .find(|(name, _value)| name.eq_ignore_ascii_case("content-type"))
        .and_then(|(_name, value)| value.split(';').next())
        .map(|media_type| media_type.trim().to_ascii_lowercase())
        .unwrap_or_default();

    if response.body.is_empty()
        || !(media_type.starts_with("audio/") || media_type == "application/octet-stream")
    {
        return Err(StreamError::new(
            "invalid_upstream_response",
            "api_resolver",
            "upstream speech response must contain audio",
        )
        .provider_status(response.status)
        .provider_body_excerpt(&response.body));
    }

    Ok(json!({
        "audio": STANDARD.encode_to_string(&response.body),
        "content_type": media_type,
        "usage": {}
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
    async fn late_cancel_does_not_emit_another_terminal() {
        let (command_tx, command_rx) = mpsc::channel(1);
        let (abort_handle, _registration) = AbortHandle::new_pair();
        let (event_tx, event_rx) = std::sync::mpsc::channel();
        let stream = StreamHandle {
            command_tx,
            abort_handle,
            sink: Arc::new(move |event| event_tx.send(event).unwrap()),
            aborted_sent: Arc::new(AtomicBool::new(false)),
        };

        drop(command_rx);
        assert!(stream.cancel().is_err());
        tokio::task::yield_now().await;
        assert!(event_rx.try_recv().is_err());
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
