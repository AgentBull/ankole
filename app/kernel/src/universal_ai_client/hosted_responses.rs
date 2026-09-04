use std::collections::{BTreeMap, BTreeSet};
use std::time::Instant;

use base64_simd::STANDARD;
use futures_util::StreamExt;
use serde_json::{Map, Value, json};
use std::sync::Arc;
use tokio::sync::mpsc;
use tokio::time::{Instant as TokioInstant, timeout, timeout_at};
use uuid::Uuid as UUID;

use super::api_resolver;
use super::client::{Delivery, EventSink, StreamCommand};
use super::downstream::DownstreamEncoder;
use super::error::{PROVIDER_BODY_EXCERPT_LIMIT, StreamError};
use super::spec::{
    DownstreamKind, HostedImageGenerationSpec, HostedToolsSpec, ModelRequestSpec,
    PreparedHTTPRequestSpec, RequestLimits, ResponseContext, StreamSpec, UpstreamKind,
};

mod events;
mod public_error;
mod size_budget;

#[cfg(test)]
use events::image_item_events;
use events::{
    image_completed_events, image_started_events, output_item_events, stream_event,
    terminal_stream_events,
};
use public_error::{normalize_image_error, redact_hosted_error, to_public_openai_error_json};
use size_budget::{HostedResponseSizeBudget, ensure_public_response_size};

/// Keeps generated image payloads inside the AIGateway artifact limit.
const DEFAULT_MAX_DECODED_IMAGE_BYTES: u64 = 50 * 1024 * 1024;

/// Stops a hidden tool loop from amplifying one public Response without a bound.
const MAX_MAIN_MODEL_ROUNDS: u64 = 16;

#[derive(Debug)]
struct HostedExecution {
    wrapper: Value,
    final_body: Value,
    metrics: Value,
}

#[derive(Debug)]
struct ImageResult {
    result: String,
    mime_type: String,
    revised_prompt: String,
    usage: Value,
    partial_images: Vec<String>,
    partial_image_count: usize,
}

#[derive(Debug)]
enum HiddenCallResult {
    Generated {
        public_item: Value,
        internal_output: Value,
        usage: Value,
        metrics: ImageCallMetrics,
    },
    Invalid {
        internal_output: Value,
    },
}

#[derive(Debug)]
enum HostedProgress {
    MainModelRound,
    ImageStarted {
        id: String,
        output_index: usize,
    },
    ImagePartial {
        id: String,
        output_index: usize,
        partial_image_index: usize,
        partial_image_b64: String,
    },
    ImageCompleted {
        output_index: usize,
        item: Value,
        metrics: ImageCallMetrics,
    },
    PublicItem {
        output_index: usize,
        item: Value,
    },
}

#[derive(Debug, Clone, Default)]
struct StreamedHostedOutput {
    items: BTreeMap<usize, Value>,
    active_image: Option<(usize, String)>,
    hosted_tool_calls: u64,
    successful_image_calls: u64,
    main_model_rounds: u64,
    image_latency_ms: u64,
    input_bytes: u64,
    output_bytes: u64,
    partial_images: u64,
    provider_cost: f64,
}

impl StreamedHostedOutput {
    fn output(&self) -> Vec<Value> {
        self.items.values().cloned().collect()
    }
}

#[derive(Debug, Clone)]
struct ImageCallMetrics {
    latency_ms: u64,
    input_bytes: u64,
    output_bytes: u64,
    partial_images: u64,
    provider_cost: f64,
}

#[derive(Debug, Clone, Default)]
struct ImageReferenceAliases {
    values: Vec<(String, String)>,
}

impl ImageReferenceAliases {
    fn from_spec(image_spec: &HostedImageGenerationSpec) -> Self {
        let mut values = Vec::new();

        for reference in &image_spec.resolved_references {
            if mask_reference(reference) {
                continue;
            }
            let Some(id) = reference.get("id").and_then(Value::as_str) else {
                continue;
            };
            if values.iter().any(|(_, existing_id)| existing_id == id) {
                continue;
            }
            values.push((format!("img_{}", values.len() + 1), id.to_string()));
        }

        Self { values }
    }

    fn alias_for_id(&self, id: &str) -> Option<&str> {
        self.values
            .iter()
            .find_map(|(alias, stored_id)| (stored_id == id).then_some(alias.as_str()))
    }

    fn id_for_alias(&self, alias: &str) -> Option<&str> {
        self.values
            .iter()
            .find_map(|(stored_alias, id)| (stored_alias == alias).then_some(id.as_str()))
    }

    fn aliases(&self) -> impl Iterator<Item = &str> {
        self.values.iter().map(|(alias, _id)| alias.as_str())
    }
}

struct StreamingImageCall<'a> {
    prompt: &'a str,
    partial_limit: usize,
    default_mime_type: &'a str,
    max_image_bytes: u64,
    public_id: &'a str,
    output_index: usize,
    progress: Option<&'a mpsc::Sender<HostedProgress>>,
}

pub(super) async fn run_hosted_model_request(
    mut spec: ModelRequestSpec,
) -> Result<Value, StreamError> {
    let hosted = spec.hosted_tools.take().ok_or_else(|| {
        StreamError::new(
            "invalid_hosted_tool_spec",
            "hosted_responses",
            "hosted image generation spec was missing",
        )
    })?;
    let execution = execute_hosted_with_timeout(&spec, None, &hosted, None)
        .await
        .map_err(redact_hosted_error)?;
    let mut wrapper = execution.wrapper;
    wrapper["hosted_tool_metadata"] = execution.metrics;
    wrapper["body"] = execution.final_body;
    Ok(wrapper)
}

pub(super) async fn run_hosted_stream(
    mut spec: StreamSpec,
    command_rx: tokio::sync::mpsc::Receiver<StreamCommand>,
    sink: EventSink,
    aborted_sent: Arc<std::sync::atomic::AtomicBool>,
) {
    let Some(hosted) = spec.hosted_tools.take() else {
        return;
    };
    let response_id = api_resolver::generated_id("resp");
    let base_spec = stream_model_spec(&spec);
    let public_context = ResponseContext {
        model: base_spec.response_context.model.clone(),
        request: hosted.public_request.clone(),
        provider_options: Value::Null,
        stream: Some(true),
        include_model: true,
    };
    let mut sequence = 0u64;
    let created_response = api_resolver::complete_response_resource(
        &public_context,
        json!({
            "id": response_id,
            "status": "in_progress",
            "completed_at": null,
            "output": [],
            "usage": null,
            "error": null
        }),
    );
    let response_created_at = created_response.get("created_at").cloned();
    let encoder = DownstreamEncoder::new(spec.downstream);
    let mut delivery = Delivery::new(
        command_rx,
        sink.clone(),
        encoder,
        aborted_sent,
        &spec.limits,
    );

    sink(super::StreamEvent::Ready(json!({
        "status": 200,
        "headers": [],
        "upstream_kind": "hosted_responses",
        "downstream_kind": spec.downstream.as_str(),
        "api_resolver": "hosted_responses"
    })));
    let initial_events = vec![
        stream_event(
            &mut sequence,
            "response.created",
            json!({"response": created_response.clone()}),
        ),
        stream_event(
            &mut sequence,
            "response.in_progress",
            json!({"response": created_response}),
        ),
    ];
    for event in &initial_events {
        if let Err(error) = ensure_downstream_event_size(&spec, encoder, event) {
            let error = redact_hosted_error(error);
            delivery
                .finish_error_events_with_metadata(
                    Vec::new(),
                    error.clone(),
                    Some(hosted_failure_metadata(&hosted, &error, None)),
                )
                .await;
            return;
        }
    }
    match delivery.push_events_bounded(initial_events).await {
        Ok(true) => {}
        Ok(false) => return,
        Err(error) => {
            let error = redact_hosted_error(error);
            delivery
                .finish_error_events_with_metadata(
                    Vec::new(),
                    error.clone(),
                    Some(hosted_failure_metadata(&hosted, &error, None)),
                )
                .await;
            return;
        }
    }

    let (progress_tx, mut progress_rx) = mpsc::channel(1);
    let hosted_deadline = base_spec
        .upstream
        .timeout
        .total_duration()
        .map(|duration| TokioInstant::now() + duration);
    let mut streamed_output = StreamedHostedOutput::default();
    let mut progress_open = true;
    let websocket_spec = (spec.upstream.kind == UpstreamKind::WebSocketText).then_some(&spec);

    let mut result = {
        let execution =
            execute_hosted_with_timeout(&base_spec, websocket_spec, &hosted, Some(progress_tx));
        tokio::pin!(execution);

        loop {
            tokio::select! {
                result = &mut execution => break result,
                progress = progress_rx.recv(), if progress_open => {
                    match progress {
                        Some(progress) => {
                            match deliver_hosted_progress_before_deadline(
                                &mut delivery,
                                &mut sequence,
                                &mut streamed_output,
                                progress,
                                hosted_deadline,
                            )
                            .await
                            {
                                Ok(true) => {}
                                Ok(false) => return,
                                Err(error) => break Err(error),
                            }
                        }
                        None => progress_open = false,
                    }
                }
                command = delivery.command_rx.recv() => {
                    if !delivery.handle_command(command) {
                        return;
                    }
                    delivery.flush_pending_available();
                }
            }
        }
    };

    while let Ok(progress) = progress_rx.try_recv() {
        match deliver_hosted_progress(&mut delivery, &mut sequence, &mut streamed_output, progress)
            .await
        {
            Ok(true) => {}
            Ok(false) => return,
            Err(error) => {
                result = Err(error);
                break;
            }
        }
    }

    match result {
        Ok(execution) => {
            let mut final_body = execution.final_body;
            final_body["id"] = json!(response_id);
            if let Some(created_at) = &response_created_at {
                final_body["created_at"] = created_at.clone();
            }
            let events = terminal_stream_events(&mut sequence, &final_body);
            match delivery.push_events_bounded(events).await {
                Ok(true) => {}
                Ok(false) => return,
                Err(error) => {
                    let error = redact_hosted_error(error);
                    let metadata = hosted_failure_metadata(&hosted, &error, Some(&streamed_output));
                    delivery
                        .finish_error_events_with_metadata(Vec::new(), error, Some(metadata))
                        .await;
                    return;
                }
            }
            delivery
                .finish_done(json!({
                    "reason": "hosted_completed",
                    "hosted_tool_metadata": execution.metrics
                }))
                .await;
        }
        Err(error) => {
            let pool_retryable = error.can_retry_through_credential_pool();
            let error = redact_hosted_error(error);

            if pool_retryable && no_public_hosted_progress(&streamed_output) {
                let metadata = hosted_failure_metadata(&hosted, &error, Some(&streamed_output));
                delivery
                    .finish_native_error_with_metadata(error, Some(metadata))
                    .await;
                return;
            }

            let mut failure_events = Vec::new();

            if let Some((output_index, id)) = streamed_output.active_image.take() {
                let failed_item = json!({
                    "id": id,
                    "type": "image_generation_call",
                    "status": "failed",
                    "result": null
                });
                streamed_output
                    .items
                    .insert(output_index, failed_item.clone());
                failure_events.push(stream_event(
                    &mut sequence,
                    "response.output_item.done",
                    json!({"output_index": output_index, "item": failed_item}),
                ));
            }

            let mut failed_response = api_resolver::complete_response_resource(
                &public_context,
                json!({
                    "id": response_id,
                    "status": "failed",
                    "completed_at": null,
                    "output": streamed_output.output(),
                    "usage": empty_usage(),
                    "error": to_public_openai_error_json(&error)
                }),
            );
            if let Some(created_at) = &response_created_at {
                failed_response["created_at"] = created_at.clone();
            }
            failure_events.extend(terminal_stream_events(&mut sequence, &failed_response));
            let metadata = hosted_failure_metadata(&hosted, &error, Some(&streamed_output));
            delivery
                .finish_error_events_with_metadata(failure_events, error, Some(metadata))
                .await;
        }
    }
}

fn no_public_hosted_progress(output: &StreamedHostedOutput) -> bool {
    output.items.is_empty() && output.active_image.is_none() && output.partial_images == 0
}

fn hosted_failure_metadata(
    hosted: &HostedToolsSpec,
    error: &StreamError,
    output: Option<&StreamedHostedOutput>,
) -> Value {
    let output = output.cloned().unwrap_or_default();

    json!({
        "result": "failure",
        "failure_reason": to_public_openai_error_json(error)["code"],
        "hosted_tool_calls": output.hosted_tool_calls,
        "successful_image_calls": output.successful_image_calls,
        "main_model_rounds": output.main_model_rounds,
        "image_latency_ms": output.image_latency_ms,
        "input_bytes": output.input_bytes,
        "output_bytes": output.output_bytes,
        "partial_images": output.partial_images,
        "provider_cost": output.provider_cost,
        "model": &hosted.image_generation.selected_model,
        "provider_tag": &hosted.image_generation.provider_tag,
        "provider_slug": &hosted.image_generation.provider_slug
    })
}

fn ensure_downstream_event_size(
    spec: &StreamSpec,
    encoder: DownstreamEncoder,
    event: &Value,
) -> Result<(), StreamError> {
    let event_limit = match spec.downstream {
        DownstreamKind::SSE => spec.limits.max_sse_event_bytes,
        DownstreamKind::WebSocketText => spec.limits.max_websocket_text_bytes,
    };
    let encoded_bytes = encoder.encode_event(event).bytes.len();

    if encoded_bytes <= event_limit && encoded_bytes <= spec.limits.max_pending_bytes {
        Ok(())
    } else {
        Err(StreamError::new(
            "response_body_too_large",
            "hosted_responses",
            "public hosted event exceeded configured response byte limit",
        ))
    }
}

async fn execute_hosted_with_timeout(
    base_spec: &ModelRequestSpec,
    websocket_spec: Option<&StreamSpec>,
    hosted: &HostedToolsSpec,
    progress: Option<mpsc::Sender<HostedProgress>>,
) -> Result<HostedExecution, StreamError> {
    match base_spec.upstream.timeout.total_duration() {
        Some(duration) => timeout(
            duration,
            execute_hosted(base_spec, websocket_spec, hosted, progress.as_ref()),
        )
        .await
        .map_err(|_| hosted_total_timeout_error())?,
        None => execute_hosted(base_spec, websocket_spec, hosted, progress.as_ref()).await,
    }
}

fn hosted_total_timeout_error() -> StreamError {
    StreamError::new(
        "total_timeout",
        "hosted_responses",
        "hosted response exceeded the total request timeout",
    )
    .retry_through_credential_pool()
}

async fn deliver_hosted_progress_before_deadline(
    delivery: &mut Delivery,
    sequence: &mut u64,
    output: &mut StreamedHostedOutput,
    progress: HostedProgress,
    deadline: Option<TokioInstant>,
) -> Result<bool, StreamError> {
    let delivery = deliver_hosted_progress(delivery, sequence, output, progress);

    match deadline {
        Some(deadline) => timeout_at(deadline, delivery)
            .await
            .map_err(|_| hosted_total_timeout_error())?,
        None => delivery.await,
    }
}

fn stream_model_spec(spec: &StreamSpec) -> ModelRequestSpec {
    ModelRequestSpec {
        api_resolver: spec.api_resolver,
        upstream: PreparedHTTPRequestSpec {
            method: spec.upstream.method.clone(),
            url: spec.upstream.url.clone(),
            headers: spec.upstream.headers.clone(),
            body: spec.upstream.body.clone(),
            timeout: spec.upstream.timeout.clone(),
            transport: spec.upstream.transport.clone(),
        },
        response_context: spec.response_context.clone(),
        limits: RequestLimits {
            max_response_bytes: spec.limits.max_pending_bytes,
        },
        hosted_tools: None,
    }
}

async fn deliver_hosted_progress(
    delivery: &mut Delivery,
    sequence: &mut u64,
    output: &mut StreamedHostedOutput,
    progress: HostedProgress,
) -> Result<bool, StreamError> {
    match progress {
        HostedProgress::MainModelRound => {
            output.main_model_rounds = output.main_model_rounds.saturating_add(1);
        }
        HostedProgress::ImageStarted { id, output_index } => {
            let events = image_started_events(sequence, output_index, &id);
            if !delivery.push_events_bounded(events).await? {
                return Ok(false);
            }
            output.active_image = Some((output_index, id));
            output.hosted_tool_calls = output.hosted_tool_calls.saturating_add(1);
        }
        HostedProgress::ImagePartial {
            id,
            output_index,
            partial_image_index,
            partial_image_b64,
        } => {
            let event = stream_event(
                sequence,
                "response.image_generation_call.partial_image",
                json!({
                    "item_id": id,
                    "output_index": output_index,
                    "partial_image_index": partial_image_index,
                    "partial_image_b64": partial_image_b64
                }),
            );
            if !delivery.push_events_bounded(vec![event]).await? {
                return Ok(false);
            }
            output.partial_images = output.partial_images.saturating_add(1);
        }
        HostedProgress::ImageCompleted {
            output_index,
            item,
            metrics,
        } => {
            let events = image_completed_events(sequence, output_index, &item);
            if !delivery.push_events_bounded(events).await? {
                return Ok(false);
            }
            output.active_image = None;
            output.items.insert(output_index, item);
            output.successful_image_calls = output.successful_image_calls.saturating_add(1);
            output.image_latency_ms = output.image_latency_ms.saturating_add(metrics.latency_ms);
            output.input_bytes = output.input_bytes.saturating_add(metrics.input_bytes);
            output.output_bytes = output.output_bytes.saturating_add(metrics.output_bytes);
            output.provider_cost += metrics.provider_cost;
        }
        HostedProgress::PublicItem { output_index, item } => {
            let events = output_item_events(sequence, output_index, &item);
            if !delivery.push_events_bounded(events).await? {
                return Ok(false);
            }
            output.items.insert(output_index, item);
        }
    }

    Ok(true)
}

async fn execute_hosted(
    base_spec: &ModelRequestSpec,
    websocket_spec: Option<&StreamSpec>,
    hosted: &HostedToolsSpec,
    progress: Option<&mpsc::Sender<HostedProgress>>,
) -> Result<HostedExecution, StreamError> {
    let public_request = hosted.public_request.as_object().cloned().ok_or_else(|| {
        StreamError::new(
            "invalid_hosted_tool_spec",
            "hosted_responses",
            "hosted_tools.public_request must be an object",
        )
    })?;
    let hidden_name = hidden_tool_name(&public_request);
    let outer_stream = progress.is_some();
    let prepared_main_request = base_spec
        .response_context
        .request
        .as_object()
        .cloned()
        .unwrap_or_else(|| public_request.clone());
    let mut private_request = lower_prepared_main_request(
        &prepared_main_request,
        &hidden_name,
        &hosted.image_generation,
    )?;
    let max_calls = public_request
        .get("max_tool_calls")
        .and_then(Value::as_u64)
        .map(|value| value as usize);
    if max_calls == Some(0) {
        disable_hidden_tool(&mut private_request, &hidden_name);
    }
    let mut total_tool_calls = 0usize;
    let mut main_model_rounds = 0u64;
    let mut successful_image_calls = 0u64;
    let mut image_latency_ms = 0u64;
    let mut input_bytes = 0u64;
    let mut output_bytes = 0u64;
    let mut partial_images = 0u64;
    let mut provider_cost = 0.0f64;
    let mut visible_output = Vec::new();
    let mut aggregate_usage = empty_usage();
    let mut aggregate_image_usage = empty_usage();
    let mut response_size_budget =
        HostedResponseSizeBudget::new(base_spec, &public_request, outer_stream);

    let (wrapper, final_body) = loop {
        if main_model_rounds >= MAX_MAIN_MODEL_ROUNDS {
            return Err(StreamError::new(
                "hosted_round_limit_exceeded",
                "hosted_responses",
                format!(
                    "hosted response exceeded the internal round limit of \
                     {MAX_MAIN_MODEL_ROUNDS} main-model rounds"
                ),
            ));
        }
        main_model_rounds = main_model_rounds.saturating_add(1);
        send_hosted_progress(progress, HostedProgress::MainModelRound).await?;
        let (wrapper, recorded_output) = match websocket_spec {
            Some(websocket_spec) => {
                let mut round_spec = websocket_spec.clone();
                round_spec.hosted_tools = None;
                round_spec.response_context.request = Value::Object(private_request.clone());
                round_spec.response_context.stream = Some(true);
                let collected = super::client::run_websocket_model_request_once(round_spec).await?;
                let contiguous = collected
                    .completed_items
                    .keys()
                    .copied()
                    .eq(0..collected.completed_items.len());
                let recorded_output = (!collected.completed_items.is_empty() && contiguous)
                    .then(|| collected.completed_items.into_values().collect::<Vec<_>>());
                (collected.wrapper, recorded_output)
            }
            None => {
                let mut round_spec = base_spec.clone();
                round_spec.hosted_tools = None;
                round_spec.response_context.request = Value::Object(private_request.clone());
                round_spec.response_context.stream = Some(false);
                (
                    super::client::run_model_request_once(round_spec).await?,
                    None,
                )
            }
        };
        let body = wrapper.get("body").cloned().ok_or_else(|| {
            StreamError::new(
                "invalid_main_model_response",
                "hosted_responses",
                "normalized main-model response did not contain a body",
            )
        })?;
        add_usage(
            &mut aggregate_usage,
            body.get("usage").unwrap_or(&Value::Null),
        );
        let round_output = recorded_output.unwrap_or_else(|| {
            body.get("output")
                .and_then(Value::as_array)
                .cloned()
                .unwrap_or_default()
        });
        let hidden_calls = round_output
            .iter()
            .filter(|item| hidden_function_call(item, &hidden_name))
            .count();

        if hidden_calls == 0 {
            for item in round_output {
                let output_index = visible_output.len();
                response_size_budget.admit(&item, &aggregate_usage, &aggregate_image_usage)?;
                send_hosted_progress(
                    progress,
                    HostedProgress::PublicItem {
                        output_index,
                        item: item.clone(),
                    },
                )
                .await?;
                visible_output.push(item);
            }
            break (wrapper, body);
        }

        let mut internal_outputs = Vec::new();
        let mut public_function_present = false;
        let mut remaining_calls = max_calls
            .map(|limit| limit.saturating_sub(total_tool_calls))
            .unwrap_or(usize::MAX);

        for item in &round_output {
            if hidden_function_call(item, &hidden_name) {
                if remaining_calls == 0 {
                    internal_outputs.push(hidden_max_tool_calls_output(item));
                    continue;
                }

                remaining_calls = remaining_calls.saturating_sub(1);
                total_tool_calls = total_tool_calls.saturating_add(1);
                let output_index = visible_output.len();
                match execute_hidden_call(item, &hosted.image_generation, output_index, progress)
                    .await?
                {
                    HiddenCallResult::Generated {
                        public_item,
                        internal_output,
                        usage,
                        metrics,
                    } => {
                        add_usage(&mut aggregate_usage, &usage);
                        add_usage(&mut aggregate_image_usage, &usage);
                        successful_image_calls = successful_image_calls.saturating_add(1);
                        image_latency_ms = image_latency_ms.saturating_add(metrics.latency_ms);
                        input_bytes = input_bytes.saturating_add(metrics.input_bytes);
                        output_bytes = output_bytes.saturating_add(metrics.output_bytes);
                        partial_images = partial_images.saturating_add(metrics.partial_images);
                        provider_cost += metrics.provider_cost;
                        response_size_budget.admit(
                            &public_item,
                            &aggregate_usage,
                            &aggregate_image_usage,
                        )?;
                        send_hosted_progress(
                            progress,
                            HostedProgress::ImageCompleted {
                                output_index,
                                item: public_item.clone(),
                                metrics: metrics.clone(),
                            },
                        )
                        .await?;
                        visible_output.push(public_item);
                        internal_outputs.push(internal_output);
                    }
                    HiddenCallResult::Invalid { internal_output } => {
                        internal_outputs.push(internal_output);
                    }
                }
            } else {
                if item.get("type").and_then(Value::as_str) == Some("function_call") {
                    public_function_present = true;
                }
                let output_index = visible_output.len();
                response_size_budget.admit(item, &aggregate_usage, &aggregate_image_usage)?;
                send_hosted_progress(
                    progress,
                    HostedProgress::PublicItem {
                        output_index,
                        item: item.clone(),
                    },
                )
                .await?;
                visible_output.push(item.clone());
            }
        }

        if public_function_present {
            break (wrapper, body);
        }

        append_round_history(&mut private_request, &round_output, internal_outputs);
        private_request.insert("tool_choice".to_string(), json!("auto"));
        if max_calls.is_some_and(|limit| total_tool_calls >= limit) {
            disable_hidden_tool(&mut private_request, &hidden_name);
        }
    };
    let public_body = json!({
        "id": api_resolver::generated_id("resp"),
        "model": base_spec.response_context.model,
        "status": final_body.get("status").cloned().unwrap_or_else(|| json!("completed")),
        "completed_at": final_body.get("completed_at").cloned().unwrap_or(Value::Null),
        "incomplete_details": final_body.get("incomplete_details").cloned().unwrap_or(Value::Null),
        "output": visible_output,
        "usage": aggregate_usage,
        "tool_usage": {"image_gen": aggregate_image_usage},
        "error": final_body.get("error").cloned().unwrap_or(Value::Null)
    });

    let public_context = ResponseContext {
        model: base_spec.response_context.model.clone(),
        request: Value::Object(public_request),
        provider_options: Value::Null,
        stream: Some(false),
        include_model: true,
    };
    let final_body = api_resolver::complete_response_resource(&public_context, public_body);
    ensure_public_response_size(
        &final_body,
        base_spec.limits.max_response_bytes,
        outer_stream,
    )?;
    let metrics = json!({
        "result": "success",
        "failure_reason": null,
        "hosted_tool_calls": total_tool_calls,
        "successful_image_calls": successful_image_calls,
        "main_model_rounds": main_model_rounds,
        "image_latency_ms": image_latency_ms,
        "input_bytes": input_bytes,
        "output_bytes": output_bytes,
        "partial_images": partial_images,
        "provider_cost": provider_cost,
        "model": hosted.image_generation.selected_model,
        "provider_tag": hosted.image_generation.provider_tag,
        "provider_slug": hosted.image_generation.provider_slug
    });

    Ok(HostedExecution {
        wrapper,
        final_body,
        metrics,
    })
}

async fn send_hosted_progress(
    progress: Option<&mpsc::Sender<HostedProgress>>,
    event: HostedProgress,
) -> Result<(), StreamError> {
    let Some(progress) = progress else {
        return Ok(());
    };

    progress.send(event).await.map_err(|_| {
        StreamError::new(
            "hosted_stream_cancelled",
            "hosted_responses",
            "hosted response downstream closed",
        )
    })
}

fn hidden_tool_name(public_request: &Map<String, Value>) -> String {
    let existing = public_request
        .get("tools")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter(|tool| tool.get("type").and_then(Value::as_str) == Some("function"))
        .filter_map(|tool| tool.get("name").and_then(Value::as_str))
        .collect::<BTreeSet<_>>();
    let base = "__ankole_hosted_image_generation";

    if !existing.contains(base) {
        return base.to_string();
    }

    for suffix in 2usize.. {
        let candidate = format!("{base}_{suffix}");
        if !existing.contains(candidate.as_str()) {
            return candidate;
        }
    }

    unreachable!("usize image tool suffix space is exhausted")
}

fn lower_prepared_main_request(
    public_request: &Map<String, Value>,
    hidden_name: &str,
    image_spec: &HostedImageGenerationSpec,
) -> Result<Map<String, Value>, StreamError> {
    let mut request = public_request.clone();
    let references = ImageReferenceAliases::from_spec(image_spec);
    request.insert("stream".to_string(), json!(false));
    resolve_private_request_references(&mut request, image_spec, &references);
    let tools = public_request
        .get("tools")
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default();
    let hidden_tool = hidden_function_tool(hidden_name, image_spec, &references);
    let mut lowered_tools = tools
        .iter()
        .map(|tool| {
            if tool.get("type").and_then(Value::as_str) == Some("image_generation") {
                hidden_tool.clone()
            } else {
                tool.clone()
            }
        })
        .collect::<Vec<_>>();
    let lowered_choice = lower_tool_choice(
        public_request.get("tool_choice"),
        hidden_name,
        &mut lowered_tools,
    )?;
    request.insert("tools".to_string(), Value::Array(lowered_tools));
    request.insert("tool_choice".to_string(), lowered_choice);
    Ok(request)
}

fn resolve_private_request_references(
    request: &mut Map<String, Value>,
    image_spec: &HostedImageGenerationSpec,
    references: &ImageReferenceAliases,
) {
    let Some(input) = request.get_mut("input") else {
        return;
    };

    match input {
        Value::Array(items) => {
            for (item_index, item) in items.iter_mut().enumerate() {
                resolve_private_input_item(item, image_spec, references, Some(item_index));
            }
        }
        Value::Object(_object) => resolve_private_input_item(input, image_spec, references, None),
        _input => {}
    }
}

fn resolve_private_input_item(
    item: &mut Value,
    image_spec: &HostedImageGenerationSpec,
    references: &ImageReferenceAliases,
    item_index: Option<usize>,
) {
    let generated_id = item
        .get("type")
        .and_then(Value::as_str)
        .filter(|item_type| *item_type == "image_generation_call")
        .and_then(|_| item.get("id"))
        .and_then(Value::as_str)
        .map(str::to_string);

    if let Some(id) = generated_id
        && resolved_reference_url(image_spec, &id).is_some()
        && let Some(alias) = references.alias_for_id(&id)
    {
        *item = private_reference_message(alias);
        return;
    }

    let Some(content) = item.get_mut("content").and_then(Value::as_array_mut) else {
        resolve_private_image_part(item, image_spec);
        return;
    };

    let mut resolved_content = Vec::with_capacity(content.len());
    for (content_index, mut part) in std::mem::take(content).into_iter().enumerate() {
        let reference_id = private_image_reference_id(&part, image_spec, item_index, content_index);
        if let Some(id) = reference_id
            && resolved_reference_url(image_spec, &id).is_some()
            && let Some(alias) = references.alias_for_id(&id)
        {
            resolved_content.push(json!({
                "type": "input_text",
                "text": format!("Image reference: {alias}")
            }));
            resolve_private_image_part(&mut part, image_spec);
        }
        resolved_content.push(part);
    }
    *content = resolved_content;
}

fn private_image_reference_id(
    part: &Value,
    image_spec: &HostedImageGenerationSpec,
    item_index: Option<usize>,
    content_index: usize,
) -> Option<String> {
    if part.get("type").and_then(Value::as_str) != Some("input_image") {
        return None;
    }

    if let Some(file_id) = part.get("file_id").and_then(Value::as_str)
        && resolved_reference_url(image_spec, file_id).is_some()
    {
        return Some(file_id.to_string());
    }

    let image_url = part.get("image_url")?;
    if let Some(item_index) = item_index {
        let path = format!("input[{item_index}].content[{content_index}]");
        if resolved_reference_url(image_spec, &path) == Some(image_url) {
            return Some(path);
        }
    }

    image_spec.resolved_references.iter().find_map(|reference| {
        (!mask_reference(reference) && reference.get("image_url") == Some(image_url))
            .then(|| reference.get("id").and_then(Value::as_str))
            .flatten()
            .map(str::to_string)
    })
}

fn resolve_private_image_part(part: &mut Value, image_spec: &HostedImageGenerationSpec) {
    if part.get("type").and_then(Value::as_str) != Some("input_image") {
        return;
    }
    let Some(id) = part
        .get("file_id")
        .and_then(Value::as_str)
        .map(str::to_string)
    else {
        return;
    };
    let Some(image_url) = resolved_reference_url(image_spec, &id) else {
        return;
    };
    let Some(object) = part.as_object_mut() else {
        return;
    };
    object.remove("file_id");
    object.insert("image_url".to_string(), image_url.clone());
}

fn resolved_reference_url<'a>(
    image_spec: &'a HostedImageGenerationSpec,
    id: &str,
) -> Option<&'a Value> {
    image_spec.resolved_references.iter().find_map(|reference| {
        (reference.get("id").and_then(Value::as_str) == Some(id))
            .then(|| reference.get("image_url"))
            .flatten()
    })
}

fn private_reference_message(alias: &str) -> Value {
    json!({
        "role": "user",
        "content": [
            {"type": "input_text", "text": format!("Previously generated image reference: {alias}")}
        ]
    })
}

fn hidden_function_tool(
    hidden_name: &str,
    image_spec: &HostedImageGenerationSpec,
    references: &ImageReferenceAliases,
) -> Value {
    let reference_aliases = references
        .aliases()
        .map(|alias| json!(alias))
        .collect::<Vec<_>>();
    let configured_action = image_spec
        .tool_config
        .get("action")
        .and_then(Value::as_str)
        .unwrap_or("auto");
    let actions = match configured_action {
        "generate" => vec![json!("generate")],
        "edit" => vec![json!("edit")],
        _action if reference_aliases.is_empty() => vec![json!("generate")],
        _action => vec![json!("generate"), json!("edit")],
    };
    let input_image_items = if reference_aliases.is_empty() {
        json!({"type": "string"})
    } else {
        json!({"type": "string", "enum": reference_aliases})
    };
    let input_image_refs = if references.values.is_empty() || configured_action == "generate" {
        json!({"type": "array", "items": input_image_items, "maxItems": 0})
    } else {
        json!({"type": "array", "items": input_image_items})
    };

    json!({
        "type": "function",
        "name": hidden_name,
        "description": "Generate or edit one image. Write a complete standalone prompt. Select only the img_N references needed for this call.",
        "strict": true,
        "parameters": {
            "type": "object",
            "properties": {
                "prompt": {"type": "string", "minLength": 1},
                "action": {"type": "string", "enum": actions},
                "input_image_refs": input_image_refs
            },
            "required": ["prompt", "action", "input_image_refs"],
            "additionalProperties": false
        }
    })
}

fn lower_tool_choice(
    choice: Option<&Value>,
    hidden_name: &str,
    tools: &mut Vec<Value>,
) -> Result<Value, StreamError> {
    let choice = choice.cloned().unwrap_or_else(|| json!("auto"));
    let Some(object) = choice.as_object() else {
        return Ok(choice);
    };

    match object.get("type").and_then(Value::as_str) {
        Some("image_generation") => Ok(json!({"type": "function", "name": hidden_name})),
        Some("function") => Ok(choice),
        Some("allowed_tools") => lower_allowed_tools(object, hidden_name, tools),
        _type => Err(StreamError::new(
            "invalid_tool_choice",
            "hosted_responses",
            "unsupported tool_choice object",
        )),
    }
}

fn lower_allowed_tools(
    choice: &Map<String, Value>,
    hidden_name: &str,
    tools: &mut Vec<Value>,
) -> Result<Value, StreamError> {
    let allowed = choice
        .get("tools")
        .and_then(Value::as_array)
        .ok_or_else(|| {
            StreamError::new(
                "invalid_tool_choice",
                "hosted_responses",
                "allowed_tools.tools must be an array",
            )
        })?;
    let allowed_image = allowed
        .iter()
        .any(|tool| tool.get("type").and_then(Value::as_str) == Some("image_generation"));
    let allowed_functions = allowed
        .iter()
        .filter(|tool| tool.get("type").and_then(Value::as_str) == Some("function"))
        .filter_map(|tool| tool.get("name").and_then(Value::as_str))
        .collect::<BTreeSet<_>>();

    tools.retain(|tool| match tool.get("type").and_then(Value::as_str) {
        Some("function") => {
            let name = tool.get("name").and_then(Value::as_str).unwrap_or_default();
            (name == hidden_name && allowed_image) || allowed_functions.contains(name)
        }
        _type => false,
    });

    let mode = choice.get("mode").and_then(Value::as_str).unwrap_or("auto");
    if mode == "required" && tools.len() == 1 {
        let name = tools[0]
            .get("name")
            .and_then(Value::as_str)
            .unwrap_or(hidden_name);
        Ok(json!({"type": "function", "name": name}))
    } else {
        Ok(json!(mode))
    }
}

fn hidden_function_call(item: &Value, hidden_name: &str) -> bool {
    item.get("type").and_then(Value::as_str) == Some("function_call")
        && item.get("name").and_then(Value::as_str) == Some(hidden_name)
}

fn disable_hidden_tool(request: &mut Map<String, Value>, hidden_name: &str) {
    let remaining_tools = request
        .get_mut("tools")
        .and_then(Value::as_array_mut)
        .map(|tools| {
            tools.retain(|tool| tool.get("name").and_then(Value::as_str) != Some(hidden_name));
            tools.len()
        })
        .unwrap_or(0);
    let hidden_choice = request
        .get("tool_choice")
        .and_then(Value::as_object)
        .is_some_and(|choice| {
            choice.get("type").and_then(Value::as_str) == Some("function")
                && choice.get("name").and_then(Value::as_str) == Some(hidden_name)
        });

    if hidden_choice || remaining_tools == 0 {
        request.insert(
            "tool_choice".to_string(),
            json!(if remaining_tools == 0 { "none" } else { "auto" }),
        );
    }
}

fn hidden_max_tool_calls_output(call: &Value) -> Value {
    let call_id = call
        .get("call_id")
        .and_then(Value::as_str)
        .unwrap_or("call");
    hidden_error_output(
        call_id,
        "This built-in tool call was ignored because max_tool_calls was reached.",
    )
}

async fn execute_hidden_call(
    call: &Value,
    image_spec: &HostedImageGenerationSpec,
    output_index: usize,
    progress: Option<&mpsc::Sender<HostedProgress>>,
) -> Result<HiddenCallResult, StreamError> {
    let references = ImageReferenceAliases::from_spec(image_spec);
    let call_id = call
        .get("call_id")
        .and_then(Value::as_str)
        .unwrap_or("call")
        .to_string();
    let arguments = call
        .get("arguments")
        .and_then(Value::as_str)
        .and_then(|arguments| sonic_rs::from_str::<Value>(arguments).ok());
    let Some(arguments) = arguments.and_then(|value| value.as_object().cloned()) else {
        return Ok(HiddenCallResult::Invalid {
            internal_output: hidden_error_output(
                &call_id,
                "Arguments must be a valid JSON object.",
            ),
        });
    };
    let prompt = arguments
        .get("prompt")
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|prompt| !prompt.is_empty());
    let Some(prompt) = prompt else {
        return Ok(HiddenCallResult::Invalid {
            internal_output: hidden_error_output(&call_id, "prompt must be non-empty."),
        });
    };
    let action = arguments
        .get("action")
        .and_then(Value::as_str)
        .unwrap_or("generate");
    if !matches!(action, "generate" | "edit") {
        return Ok(HiddenCallResult::Invalid {
            internal_output: hidden_error_output(&call_id, "action must be generate or edit."),
        });
    }
    let configured_action = image_spec
        .tool_config
        .get("action")
        .and_then(Value::as_str)
        .unwrap_or("auto");
    if configured_action != "auto" && action != configured_action {
        return Ok(HiddenCallResult::Invalid {
            internal_output: hidden_error_output(
                &call_id,
                &format!("action must be {configured_action} for this image_generation tool."),
            ),
        });
    }
    let selected_ids = match selected_reference_ids(&arguments, &references) {
        Ok(ids) => ids,
        Err(message) => {
            return Ok(HiddenCallResult::Invalid {
                internal_output: hidden_error_output(&call_id, &message),
            });
        }
    };
    if action == "edit" && selected_ids.is_empty() {
        return Ok(HiddenCallResult::Invalid {
            internal_output: hidden_error_output(
                &call_id,
                "edit requires at least one input_image_ref.",
            ),
        });
    }
    if action == "generate" && !selected_ids.is_empty() {
        return Ok(HiddenCallResult::Invalid {
            internal_output: hidden_error_output(
                &call_id,
                "generate does not accept input_image_refs; use edit for referenced images.",
            ),
        });
    }

    let id = format!("ig_{}", UUID::now_v7());
    let started_at = Instant::now();
    let input_bytes = if action == "edit" {
        selected_reference_bytes(image_spec, &selected_ids)
    } else {
        0
    };
    let image = call_image(
        image_spec,
        prompt,
        action,
        &selected_ids,
        &id,
        output_index,
        progress,
    )
    .await
    .map_err(normalize_image_error)?;
    let metrics = ImageCallMetrics {
        latency_ms: started_at.elapsed().as_millis().min(u128::from(u64::MAX)) as u64,
        input_bytes,
        output_bytes: base64_decoded_len(&image.result),
        partial_images: image.partial_image_count as u64,
        provider_cost: image
            .usage
            .get("cost")
            .and_then(Value::as_f64)
            .unwrap_or(0.0),
    };
    let public_item = json!({
        "id": id,
        "type": "image_generation_call",
        "status": "completed",
        "result": image.result,
        "revised_prompt": image.revised_prompt,
        "mime_type": image.mime_type,
        "partial_images": image.partial_images
    });
    let internal_output = json!({
        "type": "function_call_output",
        "call_id": call_id,
        "output": sonic_rs::to_string(&json!({
            "status": "completed",
            "mime_type": public_item["mime_type"]
        })).unwrap_or_else(|_| "{\"status\":\"completed\"}".to_string())
    });

    Ok(HiddenCallResult::Generated {
        public_item,
        internal_output,
        usage: image.usage,
        metrics,
    })
}

fn selected_reference_bytes(
    image_spec: &HostedImageGenerationSpec,
    selected_ids: &[String],
) -> u64 {
    image_spec
        .resolved_references
        .iter()
        .filter(|reference| {
            mask_reference(reference)
                || reference
                    .get("id")
                    .and_then(Value::as_str)
                    .is_some_and(|id| selected_ids.iter().any(|selected| selected == id))
        })
        .filter_map(|reference| reference.get("image_url").and_then(Value::as_str))
        .filter_map(|url| {
            url.strip_prefix("data:")
                .and_then(|data| data.split_once(','))
                .map(|(_, encoded)| encoded)
        })
        .map(base64_decoded_len)
        .fold(0u64, u64::saturating_add)
}

fn base64_decoded_len(value: &str) -> u64 {
    let padding = value
        .as_bytes()
        .iter()
        .rev()
        .take_while(|byte| **byte == b'=')
        .count();
    ((value.len() / 4) * 3).saturating_sub(padding) as u64
}

fn selected_reference_ids(
    arguments: &Map<String, Value>,
    references: &ImageReferenceAliases,
) -> Result<Vec<String>, String> {
    let values = arguments
        .get("input_image_refs")
        .and_then(Value::as_array)
        .ok_or_else(|| "input_image_refs must be an array.".to_string())?;
    let mut selected = Vec::new();
    for value in values {
        let alias = value
            .as_str()
            .ok_or_else(|| "input_image_refs must contain strings.".to_string())?;
        let id = references
            .id_for_alias(alias)
            .ok_or_else(|| format!("Unknown input image reference: {alias}."))?;
        if !selected.iter().any(|selected_id| selected_id == id) {
            selected.push(id.to_string());
        }
    }
    Ok(selected)
}

fn mask_reference(reference: &Value) -> bool {
    if reference.get("mask").and_then(Value::as_bool) == Some(true) {
        return true;
    }

    reference
        .get("id")
        .and_then(Value::as_str)
        .is_some_and(|id| id.starts_with("tools[") && id.ends_with("].input_image_mask"))
}

async fn call_image(
    image_spec: &HostedImageGenerationSpec,
    prompt: &str,
    action: &str,
    selected_ids: &[String],
    public_id: &str,
    output_index: usize,
    progress: Option<&mpsc::Sender<HostedProgress>>,
) -> Result<ImageResult, StreamError> {
    let mut spec = (*image_spec.prepared_request).clone();
    spec.hosted_tools = None;
    let references = image_spec
        .resolved_references
        .iter()
        .filter(|reference| {
            reference
                .get("id")
                .and_then(Value::as_str)
                .is_some_and(|id| selected_ids.iter().any(|selected| selected == id))
        })
        .map(|reference| {
            json!({
                "type": "image_url",
                "image_url": {"url": reference.get("image_url").cloned().unwrap_or(Value::Null)}
            })
        })
        .collect::<Vec<_>>();
    let mut request = spec
        .response_context
        .request
        .as_object()
        .cloned()
        .unwrap_or_default();
    request.insert("prompt".to_string(), json!(prompt));
    request.insert("input_references".to_string(), Value::Array(references));
    if action == "generate" {
        request.remove("input_image_mask");
    }
    let stream = spec.response_context.stream == Some(true);
    request.insert("stream".to_string(), json!(stream));
    spec.response_context.request = Value::Object(request);
    spec.response_context.stream = Some(stream);

    if stream {
        return call_streaming_image(
            spec,
            StreamingImageCall {
                prompt,
                partial_limit: requested_partial_images(image_spec),
                default_mime_type: requested_output_mime(image_spec),
                max_image_bytes: max_decoded_image_bytes(image_spec),
                public_id,
                output_index,
                progress,
            },
        )
        .await;
    }

    let wrapper = super::client::run_model_request_once(spec).await?;
    let body = wrapper.get("body").ok_or_else(|| {
        StreamError::new(
            "invalid_image_response",
            "hosted_responses",
            "normalized image response did not contain a body",
        )
    })?;
    let result = body
        .get("result")
        .and_then(Value::as_str)
        .filter(|value| !value.is_empty())
        .ok_or_else(|| {
            StreamError::new(
                "invalid_image_response",
                "hosted_responses",
                "normalized image response did not contain image bytes",
            )
        })?
        .to_string();
    validate_image_base64(&result, max_decoded_image_bytes(image_spec))?;
    send_hosted_progress(
        progress,
        HostedProgress::ImageStarted {
            id: public_id.to_string(),
            output_index,
        },
    )
    .await?;

    Ok(ImageResult {
        result,
        mime_type: body
            .get("mime_type")
            .and_then(Value::as_str)
            .unwrap_or_else(|| requested_output_mime(image_spec))
            .to_string(),
        revised_prompt: body
            .get("revised_prompt")
            .and_then(Value::as_str)
            .unwrap_or(prompt)
            .to_string(),
        usage: body.get("usage").cloned().unwrap_or_else(|| json!({})),
        partial_images: Vec::new(),
        partial_image_count: 0,
    })
}

fn requested_partial_images(image_spec: &HostedImageGenerationSpec) -> usize {
    image_spec
        .tool_config
        .get("partial_images")
        .and_then(Value::as_u64)
        .unwrap_or(0)
        .min(3) as usize
}

fn requested_output_mime(image_spec: &HostedImageGenerationSpec) -> &'static str {
    match image_spec
        .tool_config
        .get("output_format")
        .and_then(Value::as_str)
    {
        Some("jpeg") => "image/jpeg",
        Some("webp") => "image/webp",
        _format => "image/png",
    }
}

async fn call_streaming_image(
    spec: ModelRequestSpec,
    call: StreamingImageCall<'_>,
) -> Result<ImageResult, StreamError> {
    let mut upstream = super::request_builder::prepare_model_upstream(&spec)?;
    upstream
        .headers
        .retain(|(name, _value)| !name.eq_ignore_ascii_case("accept"));
    upstream
        .headers
        .push(("accept".to_string(), "text/event-stream".to_string()));

    let mut response = super::transport::open_http_stream_for_upstream(&upstream).await?;
    if !(200..300).contains(&response.status) {
        let mut excerpt = Vec::new();
        while excerpt.len() < PROVIDER_BODY_EXCERPT_LIMIT {
            let next = timeout(upstream.timeout.idle_duration(), response.body.next()).await;
            let Ok(Some(Ok(bytes))) = next else {
                break;
            };
            let remaining = PROVIDER_BODY_EXCERPT_LIMIT.saturating_sub(excerpt.len());
            excerpt.extend_from_slice(&bytes[..bytes.len().min(remaining)]);
        }

        return Err(StreamError::new(
            "provider_status_rejected",
            "image_generation",
            format!("image provider returned HTTP status {}", response.status),
        )
        .provider_status(response.status)
        .provider_body_excerpt(&excerpt)
        .provider_headers(&response.headers));
    }

    send_hosted_progress(
        call.progress,
        HostedProgress::ImageStarted {
            id: call.public_id.to_string(),
            output_index: call.output_index,
        },
    )
    .await?;

    let max_event_bytes = spec.limits.max_response_bytes;
    let mut parser = super::wire::SSEParser::new(max_event_bytes);
    let mut state = ImageStreamState::default();

    'read: loop {
        let next = timeout(upstream.timeout.idle_duration(), response.body.next())
            .await
            .map_err(|_| {
                StreamError::new(
                    "idle_timeout",
                    "image_generation",
                    "image provider stream idle timeout",
                )
                .retry_through_credential_pool()
            })?;

        match next {
            Some(Ok(bytes)) => {
                for event in parser.push(&bytes)? {
                    if ingest_streaming_image_event(
                        &mut state,
                        &event.data,
                        call.partial_limit,
                        call.max_image_bytes,
                        call.public_id,
                        call.output_index,
                        call.progress,
                    )
                    .await?
                    {
                        break 'read;
                    }
                }
            }
            Some(Err(reason)) => {
                return Err(StreamError::new(
                    "response_body_read_failed",
                    "image_generation",
                    format!("image provider stream read failed: {reason}"),
                )
                .retry_through_credential_pool());
            }
            None => {
                for event in parser.finish()? {
                    if ingest_streaming_image_event(
                        &mut state,
                        &event.data,
                        call.partial_limit,
                        call.max_image_bytes,
                        call.public_id,
                        call.output_index,
                        call.progress,
                    )
                    .await?
                    {
                        break;
                    }
                }
                break;
            }
        }
    }

    image_result_from_stream(state, call.prompt, call.default_mime_type)
}

async fn ingest_streaming_image_event(
    state: &mut ImageStreamState,
    data: &str,
    partial_limit: usize,
    max_image_bytes: u64,
    public_id: &str,
    output_index: usize,
    progress: Option<&mpsc::Sender<HostedProgress>>,
) -> Result<bool, StreamError> {
    let previous_partial_count = state.partial_image_count;
    let finished = ingest_image_stream_data(state, data, partial_limit, max_image_bytes)?;

    if state.partial_image_count > previous_partial_count {
        let partial_image_index = state.partial_image_count - 1;
        let partial_image_b64 = state
            .partial_images
            .pop()
            .expect("accepted partial image must have bytes");
        send_hosted_progress(
            progress,
            HostedProgress::ImagePartial {
                id: public_id.to_string(),
                output_index,
                partial_image_index,
                partial_image_b64,
            },
        )
        .await?;
    }

    Ok(finished)
}

#[derive(Debug, Default)]
struct ImageStreamState {
    partial_images: Vec<String>,
    partial_image_count: usize,
    completed: Option<Value>,
}

#[cfg(test)]
fn parse_streaming_image_response(
    body: &[u8],
    prompt: &str,
    partial_limit: usize,
    default_mime_type: &str,
) -> Result<ImageResult, StreamError> {
    let mut parser = super::wire::SSEParser::new(body.len().max(1));
    let mut state = ImageStreamState::default();
    for event in parser.push(body)? {
        if ingest_image_stream_data(
            &mut state,
            &event.data,
            partial_limit,
            DEFAULT_MAX_DECODED_IMAGE_BYTES,
        )? {
            break;
        }
    }
    parser.finish()?;
    image_result_from_stream(state, prompt, default_mime_type)
}

fn ingest_image_stream_data(
    state: &mut ImageStreamState,
    data: &str,
    partial_limit: usize,
    max_image_bytes: u64,
) -> Result<bool, StreamError> {
    if data == "[DONE]" {
        return Ok(true);
    }

    let event: Value = sonic_rs::from_str(data).map_err(|_| {
        StreamError::new(
            "invalid_image_response",
            "image_generation",
            "image provider returned invalid SSE JSON",
        )
    })?;

    match event.get("type").and_then(Value::as_str) {
        Some("image_generation.partial_image") => {
            if state.partial_image_count < partial_limit
                && let Some(image) = event.get("b64_json").and_then(Value::as_str)
                && !image.is_empty()
            {
                validate_image_base64(image, max_image_bytes)?;
                state.partial_images.push(image.to_string());
                state.partial_image_count = state.partial_image_count.saturating_add(1);
            }
        }
        Some("image_generation.completed") => {
            if let Some(image) = event.get("b64_json").and_then(Value::as_str) {
                validate_image_base64(image, max_image_bytes)?;
            }
            state.completed = Some(event);
        }
        Some("error") => {
            let error = event.get("error").unwrap_or(&event);
            let message = error
                .get("message")
                .and_then(Value::as_str)
                .unwrap_or("Image generation failed.");
            let provider_status = error
                .get("status")
                .and_then(Value::as_u64)
                .or_else(|| error.get("code").and_then(Value::as_u64))
                .and_then(|status| u16::try_from(status).ok())
                .filter(|status| (400..=599).contains(status));
            let error_type = error
                .get("error_type")
                .or_else(|| {
                    error
                        .get("metadata")
                        .and_then(|metadata| metadata.get("error_type"))
                })
                .or_else(|| event.get("error_type"))
                .and_then(Value::as_str);
            let code = match (provider_status, error_type) {
                (Some(429), _) => "provider_status_rejected",
                (Some(408 | 504), _) | (_, Some("timeout")) => "total_timeout",
                (_, Some(error_type)) => error_type,
                _ => error
                    .get("code")
                    .and_then(Value::as_str)
                    .unwrap_or("image_generation_failed"),
            };
            let mut stream_error = StreamError::new(code, "image_generation", message);
            if code == "total_timeout" {
                stream_error = stream_error.retry_through_credential_pool();
            }
            if let Some(status) = provider_status {
                stream_error = stream_error.provider_status(status);
            }
            return Err(stream_error);
        }
        _event => {}
    }

    Ok(false)
}

fn image_result_from_stream(
    state: ImageStreamState,
    prompt: &str,
    default_mime_type: &str,
) -> Result<ImageResult, StreamError> {
    let completed = state.completed.ok_or_else(|| {
        StreamError::new(
            "invalid_image_response",
            "image_generation",
            "image provider stream ended without a completed image",
        )
    })?;
    let result = completed
        .get("b64_json")
        .and_then(Value::as_str)
        .filter(|value| !value.is_empty())
        .ok_or_else(|| {
            StreamError::new(
                "invalid_image_response",
                "image_generation",
                "image provider completed event did not contain image bytes",
            )
        })?;

    Ok(ImageResult {
        result: result.to_string(),
        mime_type: completed
            .get("media_type")
            .and_then(Value::as_str)
            .unwrap_or(default_mime_type)
            .to_string(),
        revised_prompt: completed
            .get("revised_prompt")
            .and_then(Value::as_str)
            .unwrap_or(prompt)
            .to_string(),
        usage: completed.get("usage").cloned().unwrap_or_else(|| json!({})),
        partial_images: state.partial_images,
        partial_image_count: state.partial_image_count,
    })
}

fn max_decoded_image_bytes(image_spec: &HostedImageGenerationSpec) -> u64 {
    image_spec
        .limits
        .get("max_decoded_image_bytes")
        .and_then(Value::as_u64)
        .unwrap_or(DEFAULT_MAX_DECODED_IMAGE_BYTES)
}

fn validate_image_base64(image: &str, max_bytes: u64) -> Result<u64, StreamError> {
    let image = image.as_bytes();
    let decoded_bytes = STANDARD.decoded_length(image).map_err(|_| {
        StreamError::new(
            "invalid_image_response",
            "image_generation",
            "image provider returned invalid base64 image bytes",
        )
    })? as u64;
    if decoded_bytes > max_bytes {
        return Err(StreamError::new(
            "response_body_too_large",
            "image_generation",
            "generated image exceeded configured decoded image byte limit",
        ));
    }

    STANDARD.check(image).map_err(|_| {
        StreamError::new(
            "invalid_image_response",
            "image_generation",
            "image provider returned invalid base64 image bytes",
        )
    })?;

    Ok(decoded_bytes)
}

fn hidden_error_output(call_id: &str, message: &str) -> Value {
    json!({
        "type": "function_call_output",
        "call_id": call_id,
        "output": sonic_rs::to_string(&json!({
            "status": "error",
            "error": message
        })).unwrap_or_else(|_| "{\"status\":\"error\"}".to_string())
    })
}

fn append_round_history(
    request: &mut Map<String, Value>,
    round_output: &[Value],
    internal_outputs: Vec<Value>,
) {
    let mut input = canonical_input(request.get("input"));
    input.extend(round_output.iter().cloned().map(strip_item_id));
    input.extend(internal_outputs);
    request.insert("input".to_string(), Value::Array(input));
}

fn canonical_input(input: Option<&Value>) -> Vec<Value> {
    match input {
        Some(Value::Array(items)) => items.clone(),
        Some(Value::String(text)) => vec![json!({
            "role": "user",
            "content": [{"type": "input_text", "text": text}]
        })],
        Some(value) if !value.is_null() => vec![value.clone()],
        _input => Vec::new(),
    }
}

fn strip_item_id(mut item: Value) -> Value {
    if let Some(object) = item.as_object_mut() {
        object.remove("id");
    }
    item
}

fn empty_usage() -> Value {
    json!({
        "input_tokens": 0,
        "output_tokens": 0,
        "total_tokens": 0,
        "input_tokens_details": {"cached_tokens": 0},
        "output_tokens_details": {"reasoning_tokens": 0}
    })
}

fn add_usage(total: &mut Value, usage: &Value) {
    let normalized = api_resolver::normalize_response_usage(usage);
    for key in ["input_tokens", "output_tokens", "total_tokens"] {
        let value = normalized.get(key).and_then(Value::as_u64).unwrap_or(0);
        let current = total.get(key).and_then(Value::as_u64).unwrap_or(0);
        total[key] = json!(current.saturating_add(value));
    }

    add_nested_usage(total, &normalized, "input_tokens_details", "cached_tokens");
    add_nested_usage(
        total,
        &normalized,
        "output_tokens_details",
        "reasoning_tokens",
    );
}

fn add_nested_usage(total: &mut Value, usage: &Value, object_key: &str, value_key: &str) {
    let value = usage
        .get(object_key)
        .and_then(|details| details.get(value_key))
        .and_then(Value::as_u64)
        .unwrap_or(0);
    let current = total
        .get(object_key)
        .and_then(|details| details.get(value_key))
        .and_then(Value::as_u64)
        .unwrap_or(0);
    total[object_key][value_key] = json!(current.saturating_add(value));
}

#[cfg(test)]
mod tests {
    use std::io::{Read, Write};
    use std::net::{TcpListener as TCPListener, TcpStream as TCPStream};
    use std::sync::mpsc;
    use std::thread;
    use std::time::Duration;

    use super::*;
    use tokio_tungstenite::tungstenite::{Message, accept};

    /// Names the private fixture tool that must not enter public output.
    const HIDDEN_TOOL: &str = "__ankole_hosted_image_generation";

    #[test]
    fn exhausted_tool_budget_removes_only_the_hidden_image_tool() {
        let mut request = json!({
            "tools": [
                {"type": "function", "name": HIDDEN_TOOL},
                {"type": "function", "name": "lookup"}
            ],
            "tool_choice": {"type": "function", "name": HIDDEN_TOOL}
        })
        .as_object()
        .unwrap()
        .clone();

        disable_hidden_tool(&mut request, HIDDEN_TOOL);

        assert_eq!(
            request["tools"],
            json!([{"type": "function", "name": "lookup"}])
        );
        assert_eq!(request["tool_choice"], json!("auto"));

        disable_hidden_tool(&mut request, "lookup");
        assert_eq!(request["tools"], json!([]));
        assert_eq!(request["tool_choice"], json!("none"));
    }

    #[test]
    fn private_image_tool_name_uses_a_stable_collision_suffix() {
        assert_eq!(hidden_tool_name(&Map::new()), HIDDEN_TOOL);

        let request = json!({
            "tools": [
                {"type": "function", "name": HIDDEN_TOOL},
                {"type": "function", "name": format!("{HIDDEN_TOOL}_2")}
            ]
        })
        .as_object()
        .unwrap()
        .clone();

        assert_eq!(hidden_tool_name(&request), format!("{HIDDEN_TOOL}_3"));
    }

    #[tokio::test]
    async fn hosted_total_timeout_bounds_the_entire_main_image_loop() {
        let main_listener = TCPListener::bind("127.0.0.1:0").unwrap();
        let main_address = main_listener.local_addr().unwrap();
        thread::spawn(move || {
            let (_stream, _) = main_listener.accept().unwrap();
            thread::sleep(Duration::from_millis(200));
        });

        let public_request = json!({
            "model": "main-model",
            "input": "draw a lake",
            "tools": [{"type": "image_generation"}],
            "tool_choice": {"type": "image_generation"}
        });
        let mut base_spec = ModelRequestSpec::from_json(
            &json!({
                "api_resolver": "openai_chat_completions",
                "upstream": test_upstream(&format!("http://{main_address}/chat/completions")),
                "response_context": {
                    "model": "main-model",
                    "request": public_request
                }
            })
            .to_string(),
        )
        .unwrap();
        base_spec.upstream.timeout.total_ms = Some(25);
        let hosted = HostedToolsSpec {
            image_generation: test_image_spec("http://127.0.0.1:1/images"),
            public_request,
        };

        let error = execute_hosted_with_timeout(&base_spec, None, &hosted, None)
            .await
            .unwrap_err();

        assert_eq!(error.code, "total_timeout");
    }

    #[tokio::test]
    async fn hosted_round_limit_fails_an_endless_hidden_call_loop_explicitly() {
        let main_listener = TCPListener::bind("127.0.0.1:0").unwrap();
        let main_address = main_listener.local_addr().unwrap();
        let (round_tx, round_rx) = mpsc::channel();

        thread::spawn(move || {
            loop {
                let (stream, request) = read_http_request(&main_listener);
                let hidden_name = request["tools"]
                    .as_array()
                    .and_then(|tools| {
                        tools.iter().find_map(|tool| {
                            tool.get("function")
                                .and_then(|function| function.get("name"))
                                .and_then(Value::as_str)
                                .filter(|name| name.starts_with(HIDDEN_TOOL))
                        })
                    })
                    .expect("hosted executor must inject the private image function");
                let _ = round_tx.send(());
                write_json_response(
                    stream,
                    &json!({
                        "id": "chatcmpl_round_loop",
                        "model": "upstream-main",
                        "choices": [{
                            "index": 0,
                            "message": {
                                "role": "assistant",
                                "content": null,
                                "tool_calls": [{
                                    "id": "call_round_loop",
                                    "type": "function",
                                    "function": {"name": hidden_name, "arguments": "{}"}
                                }]
                            },
                            "finish_reason": "tool_calls"
                        }],
                        "usage": {"prompt_tokens": 1, "completion_tokens": 1, "total_tokens": 2}
                    }),
                );
            }
        });

        let public_request = json!({
            "model": "main-model",
            "input": "draw a lake",
            "tools": [{"type": "image_generation"}],
            "tool_choice": {"type": "image_generation"}
        });
        let mut base_spec = ModelRequestSpec::from_json(
            &json!({
                "api_resolver": "openai_chat_completions",
                "upstream": test_upstream(&format!("http://{main_address}/chat/completions")),
                "response_context": {
                    "model": "main-model",
                    "request": public_request
                }
            })
            .to_string(),
        )
        .unwrap();
        base_spec.upstream.timeout.total_ms = Some(30_000);
        let hosted = HostedToolsSpec {
            image_generation: test_image_spec("http://127.0.0.1:1/images"),
            public_request,
        };

        let error = execute_hosted_with_timeout(&base_spec, None, &hosted, None)
            .await
            .unwrap_err();

        assert_eq!(error.code, "hosted_round_limit_exceeded");
        assert!(error.message.contains("internal round limit"));
        assert_eq!(round_rx.try_iter().count(), 16);
    }

    #[test]
    fn hosted_stream_keeps_websocket_main_round_and_restores_terminal_tool_identity() {
        let main_listener = TCPListener::bind("127.0.0.1:0").unwrap();
        let main_address = main_listener.local_addr().unwrap();
        let (initial_tx, initial_rx) = mpsc::channel();

        thread::spawn(move || {
            let (stream, _) = main_listener.accept().unwrap();
            let mut websocket = accept(stream).unwrap();
            let Message::Text(initial) = websocket.read().unwrap() else {
                panic!("hosted main model must send a response.create message");
            };
            initial_tx.send(initial.to_string()).unwrap();

            websocket
                .send(Message::Text(
                    json!({
                        "type": "response.output_item.done",
                        "sequence_number": 0,
                        "output_index": 0,
                        "item": {
                            "id": "fc_command_once",
                            "type": "function_call",
                            "call_id": "call_command_once",
                            "name": "command",
                            "arguments": "{\"command\":\"true\"}",
                            "status": "completed"
                        }
                    })
                    .to_string()
                    .into(),
                ))
                .unwrap();
            websocket
                .send(Message::Text(
                    json!({
                        "type": "response.completed",
                        "sequence_number": 1,
                        "response": {
                            "id": "resp_command_once",
                            "status": "completed",
                            "output": [{
                                "type": "function_call",
                                "call_id": "call_command_once",
                                "name": "command",
                                "arguments": "{\"command\":\"true\"}"
                            }],
                            "usage": {
                                "input_tokens": 2,
                                "output_tokens": 1,
                                "total_tokens": 3
                            }
                        }
                    })
                    .to_string()
                    .into(),
                ))
                .unwrap();
        });

        let public_request = json!({
            "model": "main-model",
            "input": "Run one command.",
            "tools": [
                {"type": "function", "name": "command", "parameters": {"type": "object"}},
                {"type": "image_generation"}
            ],
            "tool_choice": {"type": "function", "name": "command"}
        });
        let spec = json!({
            "api_resolver": "openai_responses",
            "upstream": {
                "kind": "websocket_text",
                "method": "GET",
                "url": format!("ws://{main_address}/v1/responses"),
                "headers": [],
                "timeout": {
                    "connect_ms": 2_000,
                    "first_byte_ms": 2_000,
                    "idle_ms": 2_000,
                    "total_ms": 5_000
                },
                "transport": {"http_versions": ["h1"], "compression": []}
            },
            "downstream": "sse",
            "response_context": {
                "model": "main-model",
                "request": public_request,
                "provider_options": {"service_tier": "fast"},
                "stream": true
            },
            "limits": {
                "max_sse_event_bytes": 1_048_576,
                "max_websocket_text_bytes": 1_048_576,
                "max_pending_chunks": 32,
                "max_pending_bytes": 1_048_576
            },
            "hosted_tools": {
                "public_request": public_request,
                "image_generation": {
                    "tool_config": {"type": "image_generation"},
                    "selected_model": "openai/gpt-image-2",
                    "prepared_request": {
                        "api_resolver": "openrouter_images",
                        "upstream": test_upstream("http://127.0.0.1:1/images"),
                        "response_context": {
                            "model": "openai/gpt-image-2",
                            "request": {"n": 1}
                        },
                        "limits": {"max_response_bytes": 1_048_576}
                    },
                    "endpoint_capabilities": {},
                    "provider_tag": "openai/gpt-image-2:openai",
                    "provider_slug": "openai",
                    "resolved_references": [],
                    "limits": {}
                }
            }
        });
        let (event_tx, event_rx) = mpsc::channel();
        let sink: EventSink = Arc::new(move |event| {
            event_tx.send(event).unwrap();
        });
        let handle = super::super::start_stream(&spec.to_string(), sink).unwrap();

        assert!(matches!(
            event_rx.recv_timeout(Duration::from_secs(1)).unwrap(),
            super::super::StreamEvent::Ready(_)
        ));
        let initial: Value = sonic_rs::from_str(
            &initial_rx
                .recv_timeout(Duration::from_secs(1))
                .expect("hosted WebSocket must receive response.create"),
        )
        .unwrap();
        assert_eq!(initial["type"], "response.create");
        assert_eq!(initial["stream"], true);
        assert_eq!(initial["service_tier"], "fast");
        assert!(initial["tools"].as_array().unwrap().iter().any(|tool| {
            tool["name"]
                .as_str()
                .is_some_and(|name| name.starts_with(HIDDEN_TOOL))
        }));

        handle.read(32).unwrap();
        let mut events = Vec::new();
        loop {
            match event_rx.recv_timeout(Duration::from_secs(2)).unwrap() {
                super::super::StreamEvent::Chunk {
                    kind: super::super::DownstreamKind::SSE,
                    bytes,
                    ..
                } => {
                    if let Some(event) = parse_hosted_sse_chunk(&bytes) {
                        events.push(event);
                    }
                }
                super::super::StreamEvent::Done(summary) => {
                    assert_eq!(summary["reason"], "hosted_completed");
                    break;
                }
                event => panic!("expected hosted stream chunk or done, got {event:?}"),
            }
        }

        let done_items = events
            .iter()
            .filter(|event| event["type"] == "response.output_item.done")
            .collect::<Vec<_>>();
        assert_eq!(done_items.len(), 1);
        assert!(
            done_items[0]["item"]["id"]
                .as_str()
                .is_some_and(|id| id.starts_with("fc_"))
        );
        assert_eq!(done_items[0]["item"]["call_id"], "call_command_once");
        assert_eq!(done_items[0]["item"]["status"], "completed");

        let terminal = events
            .iter()
            .find(|event| event["type"] == "response.completed")
            .unwrap();
        assert_eq!(terminal["response"]["output"].as_array().unwrap().len(), 1);
        assert_eq!(terminal["response"]["output"][0], done_items[0]["item"]);
    }

    #[test]
    fn hosted_stream_timeout_aborts_an_image_request_during_credit_starvation() {
        let main_listener = TCPListener::bind("127.0.0.1:0").unwrap();
        let main_address = main_listener.local_addr().unwrap();
        let image_listener = TCPListener::bind("127.0.0.1:0").unwrap();
        let image_address = image_listener.local_addr().unwrap();
        let (image_request_tx, image_request_rx) = mpsc::channel();
        let (image_closed_tx, image_closed_rx) = mpsc::channel();

        thread::spawn(move || {
            let (stream, request) = read_http_request(&main_listener);
            let hidden_name = request["tools"]
                .as_array()
                .and_then(|tools| {
                    tools.iter().find_map(|tool| {
                        tool.get("function")
                            .and_then(|function| function.get("name"))
                            .and_then(Value::as_str)
                            .filter(|name| name.starts_with(HIDDEN_TOOL))
                    })
                })
                .expect("hosted executor must inject the private image function");
            write_json_response(
                stream,
                &json!({
                    "id": "chatcmpl_credit_starvation",
                    "model": "upstream-main",
                    "choices": [{
                        "index": 0,
                        "message": {
                            "role": "assistant",
                            "content": null,
                            "tool_calls": [{
                                "id": "call_credit_starvation",
                                "type": "function",
                                "function": {
                                    "name": hidden_name,
                                    "arguments": "{\"prompt\":\"A lake\",\"action\":\"generate\",\"input_image_refs\":[]}"
                                }
                            }]
                        },
                        "finish_reason": "tool_calls"
                    }],
                    "usage": {"prompt_tokens": 1, "completion_tokens": 1, "total_tokens": 2}
                }),
            );
        });

        thread::spawn(move || {
            let (mut stream, request) = read_http_request(&image_listener);
            write!(
                stream,
                "HTTP/1.1 200 OK\r\ncontent-type: text/event-stream\r\ntransfer-encoding: chunked\r\nconnection: keep-alive\r\n\r\n"
            )
            .unwrap();
            write_sse_chunk(
                &mut stream,
                "data: {\"type\":\"image_generation.partial_image\",\"partial_image_index\":0,\"b64_json\":\"cGFydGlhbA==\"}\n\n",
            );
            stream.flush().unwrap();
            image_request_tx.send(request).unwrap();
            stream
                .set_read_timeout(Some(Duration::from_secs(2)))
                .unwrap();
            let mut byte = [0_u8; 1];
            let closed = match stream.read(&mut byte) {
                Ok(0) => true,
                Err(error) => matches!(
                    error.kind(),
                    std::io::ErrorKind::ConnectionReset
                        | std::io::ErrorKind::UnexpectedEof
                        | std::io::ErrorKind::BrokenPipe
                ),
                _result => false,
            };
            image_closed_tx.send(closed).unwrap();
        });

        let mut main_upstream = test_upstream(&format!("http://{main_address}/chat/completions"));
        main_upstream["kind"] = json!("http_sse");
        main_upstream["timeout"]["total_ms"] = json!(1_000);
        let public_request = json!({
            "model": "main-model",
            "input": "Draw a lake",
            "tools": [{"type": "image_generation", "model": "openai/gpt-image-2"}],
            "tool_choice": {"type": "image_generation"}
        });
        let spec = json!({
            "api_resolver": "openai_chat_completions",
            "upstream": main_upstream,
            "downstream": "sse",
            "response_context": {
                "model": "main-model",
                "request": public_request,
                "stream": true
            },
            "limits": {
                "max_sse_event_bytes": 1_048_576,
                "max_pending_chunks": 5,
                "max_pending_bytes": 1_048_576
            },
            "hosted_tools": {
                "public_request": public_request,
                "image_generation": {
                    "tool_config": {
                        "type": "image_generation",
                        "model": "openai/gpt-image-2",
                        "action": "generate",
                        "partial_images": 1
                    },
                    "selected_model": "openai/gpt-image-2",
                    "prepared_request": {
                        "api_resolver": "openrouter_images",
                        "upstream": test_upstream(&format!("http://{image_address}/images")),
                        "response_context": {
                            "model": "openai/gpt-image-2",
                            "request": {"n": 1},
                            "stream": true
                        },
                        "limits": {"max_response_bytes": 1_048_576}
                    },
                    "endpoint_capabilities": {},
                    "provider_tag": "openai/gpt-image-2:openai",
                    "provider_slug": "openai",
                    "resolved_references": [],
                    "limits": {}
                }
            }
        });
        let (event_tx, event_rx) = mpsc::channel();
        let sink: EventSink = Arc::new(move |event| {
            event_tx.send(event).unwrap();
        });
        let handle = super::super::start_stream(&spec.to_string(), sink).unwrap();

        assert!(matches!(
            event_rx.recv_timeout(Duration::from_secs(1)).unwrap(),
            super::super::StreamEvent::Ready(_)
        ));
        let image_request = image_request_rx
            .recv_timeout(Duration::from_secs(1))
            .expect("image request must be in flight before downstream starvation");
        assert_eq!(image_request["prompt"], "A lake");
        assert!(
            image_closed_rx
                .recv_timeout(Duration::from_secs(2))
                .expect("total timeout must close the in-flight image request")
        );

        handle.read(32).unwrap();
        let mut public_events = Vec::new();
        let error = loop {
            match event_rx.recv_timeout(Duration::from_secs(2)).unwrap() {
                super::super::StreamEvent::Chunk {
                    kind: super::super::DownstreamKind::SSE,
                    bytes,
                    ..
                } => {
                    if let Some(event) = parse_hosted_sse_chunk(&bytes) {
                        public_events.push(event);
                    }
                }
                super::super::StreamEvent::Error(error) => break error,
                event => panic!("expected hosted stream chunk or error, got {event:?}"),
            }
        };

        assert_eq!(error["code"], "total_timeout");
        let failed = public_events
            .iter()
            .find(|event| event["type"] == "response.failed")
            .expect("the public stream must finish with response.failed");
        assert_eq!(failed["response"]["error"]["type"], "server_error");
        assert_eq!(failed["response"]["error"]["code"], "upstream_timeout");
        assert!(!public_events.iter().any(|event| {
            event["type"] == "response.image_generation_call.completed"
                || event["type"] == "response.completed"
        }));
    }

    #[test]
    fn streaming_image_response_keeps_requested_partials_and_final_image() {
        let body = concat!(
            "data: {\"type\":\"image_generation.partial_image\",\"partial_image_index\":0,\"b64_json\":\"cGFydGlhbC1h\"}\n\n",
            "data: {\"type\":\"image_generation.partial_image\",\"partial_image_index\":1,\"b64_json\":\"cGFydGlhbC1i\"}\n\n",
            "data: {\"type\":\"image_generation.partial_image\",\"partial_image_index\":2,\"b64_json\":\"cGFydGlhbC1j\"}\n\n",
            "data: {\"type\":\"image_generation.completed\",\"b64_json\":\"ZmluYWwtaW1hZ2U=\",\"media_type\":\"image/webp\",\"revised_prompt\":\"revised\",\"usage\":{\"input_tokens\":2}}\n\n",
            "data: [DONE]\n\n"
        );

        let result =
            parse_streaming_image_response(body.as_bytes(), "original", 2, "image/png").unwrap();

        assert_eq!(result.result, "ZmluYWwtaW1hZ2U=");
        assert_eq!(result.mime_type, "image/webp");
        assert_eq!(result.revised_prompt, "revised");
        assert_eq!(result.partial_images, ["cGFydGlhbC1h", "cGFydGlhbC1i"]);
        assert_eq!(result.partial_image_count, 2);
        assert_eq!(result.usage["input_tokens"], 2);
    }

    #[test]
    fn streaming_image_response_rejects_invalid_partial_base64_before_publication() {
        let body = concat!(
            "data: {\"type\":\"image_generation.partial_image\",\"partial_image_index\":0,\"b64_json\":\"%%%not-base64%%%\"}\n\n",
            "data: {\"type\":\"image_generation.completed\",\"b64_json\":\"ZmluYWw=\"}\n\n"
        );

        let error = parse_streaming_image_response(body.as_bytes(), "original", 1, "image/png")
            .unwrap_err();

        assert_eq!(error.code, "invalid_image_response");
    }

    #[test]
    fn image_stream_events_match_openai_order_and_hide_internal_fields() {
        let mut sequence = 7;
        let events = image_item_events(
            &mut sequence,
            2,
            &json!({
                "id": "ig_test",
                "type": "image_generation_call",
                "status": "completed",
                "result": "final",
                "revised_prompt": "revised",
                "mime_type": "image/png",
                "partial_images": ["partial"]
            }),
        );

        assert_eq!(
            events
                .iter()
                .map(|event| event["type"].as_str().unwrap())
                .collect::<Vec<_>>(),
            [
                "response.output_item.added",
                "response.image_generation_call.in_progress",
                "response.image_generation_call.generating",
                "response.image_generation_call.partial_image",
                "response.image_generation_call.completed",
                "response.output_item.done"
            ]
        );
        assert_eq!(
            events
                .iter()
                .map(|event| event["sequence_number"].as_u64().unwrap())
                .collect::<Vec<_>>(),
            [7, 8, 9, 10, 11, 12]
        );
        assert_eq!(events[3]["partial_image_index"], 0);
        assert_eq!(events[3]["partial_image_b64"], "partial");
        assert!(events[0]["item"].get("mime_type").is_none());
        assert!(events[5]["item"].get("partial_images").is_none());
    }

    #[test]
    fn image_policy_errors_use_the_stable_public_error_without_provider_details() {
        let error = StreamError::new(
            "provider_status_rejected",
            "api_resolver",
            "upstream returned HTTP status 400",
        )
        .provider_status(400)
        .provider_body_excerpt(
            br#"{"error":{"code":"content_policy_violation","message":"sensitive detail"}}"#,
        );

        let normalized = normalize_image_error(error);
        let public = to_public_openai_error_json(&normalized);

        assert_eq!(normalized.code, "content_policy_violation");
        assert_eq!(public["type"], "image_generation_user_error");
        assert_eq!(public["code"], "content_policy_violation");
        assert!(!public.to_string().contains("sensitive detail"));

        let reference_error = StreamError::new(
            "provider_status_rejected",
            "api_resolver",
            "upstream returned HTTP status 400",
        )
        .provider_status(400)
        .provider_body_excerpt(
            br#"{"error_type":"image_download_failed","message":"private URL detail"}"#,
        );
        let reference_public = to_public_openai_error_json(&normalize_image_error(reference_error));
        assert_eq!(reference_public["type"], "image_generation_user_error");
        assert_eq!(reference_public["code"], "image_download_failed");
        assert!(!reference_public.to_string().contains("private URL detail"));
    }

    #[test]
    fn hosted_provider_failures_use_stable_public_codes() {
        for (status, expected_type, expected_code) in [
            (401, "server_error", "upstream_error"),
            (503, "server_error", "upstream_error"),
            (504, "server_error", "upstream_timeout"),
            (429, "rate_limit_error", "rate_limit_exceeded"),
        ] {
            let error = redact_hosted_error(
                StreamError::new(
                    "provider_status_rejected",
                    "image_generation",
                    "provider detail",
                )
                .provider_status(status)
                .provider_body_excerpt(b"credential detail"),
            );
            let public = to_public_openai_error_json(&error);

            assert_eq!(public["type"], expected_type);
            assert_eq!(public["code"], expected_code);
            assert_eq!(public["status"], status);
            assert_eq!(public["details_json"]["provider_status"], status);
            assert!(error.provider_body_excerpt.is_none());
            assert!(!public.to_string().contains("provider detail"));
            assert!(!public.to_string().contains("credential detail"));
        }
    }

    #[test]
    fn image_sse_error_preserves_provider_status_for_public_mapping() {
        let mut state = ImageStreamState::default();
        let error = ingest_image_stream_data(
            &mut state,
            r#"{"type":"error","error":{"code":429,"metadata":{"error_type":"rate_limit_exceeded"},"message":"provider detail"}}"#,
            0,
            DEFAULT_MAX_DECODED_IMAGE_BYTES,
        )
        .unwrap_err();

        assert_eq!(error.provider_status, Some(429));
        let public = to_public_openai_error_json(&redact_hosted_error(error));
        assert_eq!(public["type"], "rate_limit_error");
        assert_eq!(public["code"], "rate_limit_exceeded");
        assert!(!public.to_string().contains("provider detail"));

        let policy_error = ingest_image_stream_data(
            &mut state,
            r#"{"type":"error","error":{"code":400,"metadata":{"error_type":"image_download_failed"},"message":"private URL detail"}}"#,
            0,
            DEFAULT_MAX_DECODED_IMAGE_BYTES,
        )
        .unwrap_err();
        let policy_public = to_public_openai_error_json(&normalize_image_error(policy_error));
        assert_eq!(policy_public["type"], "image_generation_user_error");
        assert_eq!(policy_public["code"], "image_download_failed");
        assert!(!policy_public.to_string().contains("private URL detail"));
    }

    #[tokio::test]
    async fn hidden_call_rejects_an_action_that_conflicts_with_the_public_tool() {
        let mut image_spec = test_image_spec("http://127.0.0.1:1/images");
        image_spec.tool_config = json!({"type": "image_generation", "action": "edit"});
        let call = json!({
            "type": "function_call",
            "call_id": "call_wrong_action",
            "name": HIDDEN_TOOL,
            "arguments": "{\"prompt\":\"A lake\",\"action\":\"generate\",\"input_image_refs\":[]}"
        });

        let result = execute_hidden_call(&call, &image_spec, 0, None)
            .await
            .unwrap();
        let HiddenCallResult::Invalid { internal_output } = result else {
            panic!("conflicting action must be returned to the main model for correction");
        };

        assert_eq!(internal_output["call_id"], "call_wrong_action");
        assert!(
            internal_output["output"]
                .as_str()
                .unwrap()
                .contains("action must be edit")
        );
    }

    #[tokio::test]
    async fn hidden_generate_call_cannot_select_edit_references() {
        let mut image_spec = test_image_spec("http://127.0.0.1:1/images");
        image_spec.tool_config = json!({"type": "image_generation", "action": "generate"});
        image_spec.resolved_references = vec![json!({
            "id": "file_source",
            "image_url": "data:image/png;base64,c291cmNl"
        })];
        let references = ImageReferenceAliases::from_spec(&image_spec);
        let schema = hidden_function_tool(HIDDEN_TOOL, &image_spec, &references);
        assert_eq!(
            schema["parameters"]["properties"]["input_image_refs"]["maxItems"],
            0
        );

        let call = json!({
            "type": "function_call",
            "call_id": "call_generate_with_reference",
            "name": HIDDEN_TOOL,
            "arguments": "{\"prompt\":\"A lake\",\"action\":\"generate\",\"input_image_refs\":[\"img_1\"]}"
        });

        let result = execute_hidden_call(&call, &image_spec, 0, None)
            .await
            .unwrap();
        let HiddenCallResult::Invalid { internal_output } = result else {
            panic!("generate with a reference must be returned for correction");
        };
        assert!(
            internal_output["output"]
                .as_str()
                .unwrap()
                .contains("generate does not accept input_image_refs")
        );
    }

    #[tokio::test]
    async fn generate_removes_prepared_references_and_mask_from_the_image_request() {
        let image_listener = TCPListener::bind("127.0.0.1:0").unwrap();
        let image_address = image_listener.local_addr().unwrap();
        let (request_tx, request_rx) = mpsc::channel();
        thread::spawn(move || {
            let (stream, request) = read_http_request(&image_listener);
            request_tx.send(request).unwrap();
            write_json_response(
                stream,
                &json!({
                    "data": [{"b64_json": "ZmluYWw=", "media_type": "image/png"}],
                    "usage": {}
                }),
            );
        });

        let mut image_spec = test_image_spec(&format!("http://{image_address}/images"));
        image_spec.prepared_request.response_context.request = json!({
            "model": "openai/gpt-image-2",
            "n": 1,
            "input_references": [{
                "type": "image_url",
                "image_url": {"url": "data:image/png;base64,c291cmNl"}
            }],
            "input_image_mask": {
                "image_url": "data:image/png;base64,bWFzaw=="
            }
        });

        call_image(
            &image_spec,
            "A new lake",
            "generate",
            &[],
            "ig_generate",
            0,
            None,
        )
        .await
        .unwrap();

        let request = request_rx.recv().unwrap();
        assert_eq!(request["input_references"], json!([]));
        assert!(request.get("input_image_mask").is_none());
    }

    #[test]
    fn decoded_image_and_public_response_limits_accept_the_exact_boundary_only() {
        let exact_image = STANDARD.encode_to_string(vec![7_u8; 1_024]);
        assert_eq!(validate_image_base64(&exact_image, 1_024).unwrap(), 1_024);

        assert_eq!(
            validate_image_base64("AAAA*AAA", 1_024).unwrap_err().code,
            "invalid_image_response"
        );

        let oversized_image = STANDARD.encode_to_string(vec![7_u8; 1_025]);
        assert_eq!(
            validate_image_base64(&oversized_image, 1_024)
                .unwrap_err()
                .code,
            "response_body_too_large"
        );

        let response = json!({
            "id": "resp_exact_limit",
            "status": "completed",
            "output": [],
            "usage": empty_usage()
        });
        let exact_response_bytes = sonic_rs::to_vec(&response).unwrap().len();
        ensure_public_response_size(&response, exact_response_bytes, false).unwrap();
        assert_eq!(
            ensure_public_response_size(&response, exact_response_bytes - 1, false)
                .unwrap_err()
                .code,
            "response_body_too_large"
        );
    }

    #[test]
    fn created_event_obeys_downstream_event_and_pending_limits() {
        let mut upstream = test_upstream("http://127.0.0.1:1/chat/completions");
        upstream["kind"] = json!("http_sse");
        let spec = StreamSpec::from_json(
            &json!({
                "api_resolver": "openai_chat_completions",
                "upstream": upstream,
                "downstream": "sse",
                "response_context": {"model": "main-model", "request": {}},
                "limits": {
                    "max_sse_event_bytes": 256,
                    "max_pending_bytes": 128
                }
            })
            .to_string(),
        )
        .unwrap();
        let event = json!({
            "type": "response.created",
            "sequence_number": 0,
            "response": {"input": "x".repeat(256)}
        });

        let error = ensure_downstream_event_size(
            &spec,
            DownstreamEncoder::new(DownstreamKind::SSE),
            &event,
        )
        .unwrap_err();

        assert_eq!(error.code, "response_body_too_large");
        assert_eq!(
            to_public_openai_error_json(&error)["code"],
            "response_too_large"
        );
    }

    #[test]
    fn tool_choice_lowering_covers_all_supported_public_forms() {
        let image_spec = test_image_spec("http://127.0.0.1:1/images");
        let base_tools = json!([
            {"type": "image_generation"},
            {"type": "function", "name": "lookup", "description": "lookup", "parameters": {"type": "object"}}
        ]);

        for choice in ["auto", "required", "none"] {
            let lowered = lower_prepared_main_request(
                json!({"tools": base_tools, "tool_choice": choice})
                    .as_object()
                    .unwrap(),
                HIDDEN_TOOL,
                &image_spec,
            )
            .unwrap();
            assert_eq!(lowered["tool_choice"], choice);
        }

        let forced_function = lower_prepared_main_request(
            json!({
                "tools": base_tools,
                "tool_choice": {"type": "function", "name": "lookup"}
            })
            .as_object()
            .unwrap(),
            HIDDEN_TOOL,
            &image_spec,
        )
        .unwrap();
        assert_eq!(
            forced_function["tool_choice"],
            json!({"type": "function", "name": "lookup"})
        );

        let forced = lower_prepared_main_request(
            json!({"tools": base_tools, "tool_choice": {"type": "image_generation"}})
                .as_object()
                .unwrap(),
            HIDDEN_TOOL,
            &image_spec,
        )
        .unwrap();
        assert_eq!(
            forced["tool_choice"],
            json!({"type": "function", "name": HIDDEN_TOOL})
        );

        let allowed = lower_prepared_main_request(
            json!({
                "tools": base_tools,
                "tool_choice": {
                    "type": "allowed_tools",
                    "mode": "required",
                    "tools": [
                        {"type": "image_generation"},
                        {"type": "function", "name": "lookup"}
                    ]
                }
            })
            .as_object()
            .unwrap(),
            HIDDEN_TOOL,
            &image_spec,
        )
        .unwrap();
        assert_eq!(allowed["tool_choice"], "required");
        assert_eq!(allowed["tools"].as_array().unwrap().len(), 2);
        assert!(
            allowed["tools"]
                .as_array()
                .unwrap()
                .iter()
                .any(|tool| tool["name"] == HIDDEN_TOOL)
        );

        let allowed_image_only = lower_prepared_main_request(
            json!({
                "tools": base_tools,
                "tool_choice": {
                    "type": "allowed_tools",
                    "mode": "required",
                    "tools": [{"type": "image_generation"}]
                }
            })
            .as_object()
            .unwrap(),
            HIDDEN_TOOL,
            &image_spec,
        )
        .unwrap();
        assert_eq!(
            allowed_image_only["tool_choice"],
            json!({"type": "function", "name": HIDDEN_TOOL})
        );
        assert_eq!(allowed_image_only["tools"].as_array().unwrap().len(), 1);

        let allowed_function_only = lower_prepared_main_request(
            json!({
                "tools": base_tools,
                "tool_choice": {
                    "type": "allowed_tools",
                    "mode": "auto",
                    "tools": [{"type": "function", "name": "lookup"}]
                }
            })
            .as_object()
            .unwrap(),
            HIDDEN_TOOL,
            &image_spec,
        )
        .unwrap();
        assert_eq!(allowed_function_only["tool_choice"], "auto");
        assert_eq!(
            allowed_function_only["tools"],
            json!([{
                "type": "function",
                "name": "lookup",
                "description": "lookup",
                "parameters": {"type": "object"}
            }])
        );
    }

    #[test]
    fn private_main_request_labels_every_selectable_image_and_excludes_masks() {
        let mut image_spec = test_image_spec("http://127.0.0.1:1/images");
        image_spec.resolved_references = vec![
            json!({
                "id": "file_source",
                "image_url": "data:image/png;base64,c291cmNl",
                "source": "artifact"
            }),
            json!({
                "id": "ig_previous",
                "image_url": "data:image/webp;base64,cHJldmlvdXM=",
                "source": "artifact"
            }),
            json!({
                "id": "input[0].content[2]",
                "image_url": "https://example.test/reference.png",
                "source": "external"
            }),
            json!({
                "id": "file_mask",
                "image_url": "data:image/png;base64,bWFzaw==",
                "source": "artifact",
                "mask": true
            }),
        ];
        let public_request = json!({
            "input": [
                {
                    "role": "user",
                    "content": [
                        {"type": "input_text", "text": "Edit the source"},
                        {"type": "input_image", "file_id": "file_source", "detail": "high"},
                        {"type": "input_image", "image_url": "https://example.test/reference.png"}
                    ]
                },
                {
                    "id": "ig_previous",
                    "type": "image_generation_call",
                    "status": "completed",
                    "result": null
                }
            ],
            "tools": [{"type": "image_generation"}],
            "tool_choice": "auto"
        })
        .as_object()
        .unwrap()
        .clone();

        let lowered =
            lower_prepared_main_request(&public_request, HIDDEN_TOOL, &image_spec).unwrap();

        let file_content = lowered["input"][0]["content"].as_array().unwrap();
        assert_eq!(
            file_content[0],
            json!({"type": "input_text", "text": "Edit the source"})
        );
        assert_eq!(file_content[1]["type"], "input_text");
        assert!(file_content[1]["text"].as_str().unwrap().contains("img_1"));
        assert_eq!(
            file_content[2],
            json!({
                "type": "input_image",
                "image_url": "data:image/png;base64,c291cmNl",
                "detail": "high"
            })
        );
        assert_eq!(file_content[3]["type"], "input_text");
        assert!(file_content[3]["text"].as_str().unwrap().contains("img_3"));
        assert_eq!(
            file_content[4],
            json!({
                "type": "input_image",
                "image_url": "https://example.test/reference.png"
            })
        );

        let generated_content = lowered["input"][1]["content"].as_array().unwrap();
        assert_eq!(lowered["input"][1]["role"], "user");
        assert_eq!(generated_content[0]["type"], "input_text");
        assert!(
            generated_content[0]["text"]
                .as_str()
                .unwrap()
                .contains("img_2")
        );
        assert_eq!(generated_content.len(), 1);
        assert_eq!(
            public_request["input"][0]["content"][1]["file_id"],
            "file_source"
        );
        assert_eq!(public_request["input"][1]["id"], "ig_previous");

        let selectable_refs =
            lowered["tools"][0]["parameters"]["properties"]["input_image_refs"]["items"]["enum"]
                .as_array()
                .unwrap();
        assert_eq!(
            selectable_refs,
            &vec![json!("img_1"), json!("img_2"), json!("img_3")]
        );

        let lowered_json = Value::Object(lowered).to_string();
        assert!(!lowered_json.contains("file_source"));
        assert!(!lowered_json.contains("ig_previous"));
        assert!(!lowered_json.contains("input[0].content[2]"));
        assert!(!lowered_json.contains("file_mask"));
    }

    #[test]
    fn hosted_stream_delivers_partial_image_before_provider_completion() {
        let main_listener = TCPListener::bind("127.0.0.1:0").unwrap();
        let main_address = main_listener.local_addr().unwrap();
        let image_listener = TCPListener::bind("127.0.0.1:0").unwrap();
        let image_address = image_listener.local_addr().unwrap();
        let (partial_sent_tx, partial_sent_rx) = mpsc::channel();
        let (finish_image_tx, finish_image_rx) = mpsc::channel();

        thread::spawn(move || {
            let (first_stream, first_body) = read_http_request(&main_listener);
            let hidden_name = first_body["tools"]
                .as_array()
                .and_then(|tools| {
                    tools.iter().find_map(|tool| {
                        tool.get("function")
                            .and_then(|function| function.get("name"))
                            .and_then(Value::as_str)
                            .filter(|name| name.starts_with(HIDDEN_TOOL))
                    })
                })
                .expect("hosted executor must inject the private image function")
                .to_string();
            write_json_response(
                first_stream,
                &json!({
                    "id": "chatcmpl_hidden_stream",
                    "model": "upstream-main",
                    "choices": [{
                        "index": 0,
                        "message": {
                            "role": "assistant",
                            "content": null,
                            "tool_calls": [{
                                "id": "call_hidden_stream",
                                "type": "function",
                                "function": {
                                    "name": hidden_name,
                                    "arguments": "{\"prompt\":\"A moonlit lake\",\"action\":\"generate\",\"input_image_refs\":[]}"
                                }
                            }]
                        },
                        "finish_reason": "tool_calls"
                    }],
                    "usage": {"prompt_tokens": 4, "completion_tokens": 2, "total_tokens": 6}
                }),
            );

            let (second_stream, _second_body) = read_http_request(&main_listener);
            write_json_response(
                second_stream,
                &json!({
                    "id": "chatcmpl_final_stream",
                    "model": "upstream-main",
                    "choices": [{
                        "index": 0,
                        "message": {"role": "assistant", "content": "The image is ready."},
                        "finish_reason": "stop"
                    }],
                    "usage": {"prompt_tokens": 8, "completion_tokens": 3, "total_tokens": 11}
                }),
            );
        });

        thread::spawn(move || {
            let (mut stream, _body) = read_http_request(&image_listener);
            write!(
                stream,
                "HTTP/1.1 200 OK\r\ncontent-type: text/event-stream\r\ntransfer-encoding: chunked\r\nconnection: close\r\n\r\n"
            )
            .unwrap();
            write_sse_chunk(
                &mut stream,
                "data: {\"type\":\"image_generation.partial_image\",\"partial_image_index\":0,\"b64_json\":\"cGFydGlhbA==\"}\n\n",
            );
            stream.flush().unwrap();
            partial_sent_tx.send(()).unwrap();

            finish_image_rx
                .recv_timeout(Duration::from_secs(2))
                .expect("test must observe the partial before releasing the final image");
            write_sse_chunk(
                &mut stream,
                concat!(
                    "data: {\"type\":\"image_generation.completed\",\"b64_json\":\"ZmluYWw=\",\"media_type\":\"image/png\",\"revised_prompt\":\"A moonlit lake\",\"usage\":{\"input_tokens\":1,\"output_tokens\":1,\"total_tokens\":2}}\n\n",
                    "data: [DONE]\n\n"
                ),
            );
            write!(stream, "0\r\n\r\n").unwrap();
            stream.flush().unwrap();
        });

        let mut main_upstream = test_upstream(&format!("http://{main_address}/chat/completions"));
        main_upstream["kind"] = json!("http_sse");
        let public_request = json!({
            "model": "main-model",
            "input": "Draw a lake",
            "tools": [{
                "type": "image_generation",
                "model": "openai/gpt-image-2",
                "partial_images": 1
            }],
            "tool_choice": {"type": "image_generation"}
        });
        let spec = json!({
            "api_resolver": "openai_chat_completions",
            "upstream": main_upstream,
            "downstream": "sse",
            "response_context": {
                "model": "main-model",
                "request": public_request,
                "stream": true
            },
            "limits": {
                "max_sse_event_bytes": 1_048_576,
                "max_pending_chunks": 32,
                "max_pending_bytes": 1_048_576
            },
            "hosted_tools": {
                "public_request": public_request,
                "image_generation": {
                    "tool_config": {
                        "type": "image_generation",
                        "model": "openai/gpt-image-2",
                        "action": "generate",
                        "partial_images": 1
                    },
                    "selected_model": "openai/gpt-image-2",
                    "prepared_request": {
                        "api_resolver": "openrouter_images",
                        "upstream": test_upstream(&format!("http://{image_address}/images")),
                        "response_context": {
                            "model": "openai/gpt-image-2",
                            "request": {"n": 1},
                            "stream": true
                        },
                        "limits": {"max_response_bytes": 1_048_576}
                    },
                    "endpoint_capabilities": {},
                    "provider_tag": "openai/gpt-image-2:openai",
                    "provider_slug": "openai",
                    "resolved_references": [],
                    "limits": {}
                }
            }
        });
        let (event_tx, event_rx) = mpsc::channel();
        let sink: EventSink = Arc::new(move |event| {
            event_tx.send(event).unwrap();
        });
        let handle = super::super::start_stream(&spec.to_string(), sink).unwrap();

        match event_rx.recv_timeout(Duration::from_secs(1)).unwrap() {
            super::super::StreamEvent::Ready(metadata) => {
                assert_eq!(metadata["upstream_kind"], "hosted_responses");
                assert_eq!(metadata["api_resolver"], "hosted_responses");
            }
            event => panic!("expected ready event, got {event:?}"),
        }
        partial_sent_rx
            .recv_timeout(Duration::from_secs(1))
            .expect("image provider must send a partial image");

        handle.read(6).unwrap();
        let first_events = (0..6)
            .map(|_| hosted_sse_event(&event_rx).expect("expected hosted SSE event"))
            .collect::<Vec<_>>();
        assert_eq!(
            first_events
                .iter()
                .map(|event| event["type"].as_str().unwrap())
                .collect::<Vec<_>>(),
            [
                "response.created",
                "response.in_progress",
                "response.output_item.added",
                "response.image_generation_call.in_progress",
                "response.image_generation_call.generating",
                "response.image_generation_call.partial_image"
            ]
        );
        assert_eq!(first_events[5]["partial_image_index"], 0);
        assert_eq!(first_events[5]["partial_image_b64"], "cGFydGlhbA==");
        assert!(event_rx.recv_timeout(Duration::from_millis(50)).is_err());

        finish_image_tx.send(()).unwrap();
        handle.read(16).unwrap();
        let mut remaining_events = Vec::new();
        loop {
            match event_rx.recv_timeout(Duration::from_secs(2)).unwrap() {
                super::super::StreamEvent::Chunk {
                    kind: super::super::DownstreamKind::SSE,
                    bytes,
                    ..
                } => {
                    if let Some(event) = parse_hosted_sse_chunk(&bytes) {
                        remaining_events.push(event);
                    }
                }
                super::super::StreamEvent::Done(summary) => {
                    assert_eq!(summary["reason"], "hosted_completed");
                    break;
                }
                event => panic!("expected hosted stream chunk or done, got {event:?}"),
            }
        }

        let all_events = first_events
            .iter()
            .chain(remaining_events.iter())
            .collect::<Vec<_>>();
        assert_eq!(
            all_events
                .iter()
                .enumerate()
                .map(|(index, event)| (index as u64, event["sequence_number"].as_u64().unwrap()))
                .collect::<Vec<_>>(),
            (0..all_events.len() as u64)
                .map(|index| (index, index))
                .collect::<Vec<_>>()
        );
        assert!(
            remaining_events
                .iter()
                .any(|event| event["type"] == "response.image_generation_call.completed")
        );
        assert_eq!(
            remaining_events.last().unwrap()["type"],
            "response.completed"
        );
        assert_eq!(
            first_events[0]["response"]["id"],
            remaining_events.last().unwrap()["response"]["id"]
        );
        assert_eq!(
            first_events[0]["response"]["created_at"],
            remaining_events.last().unwrap()["response"]["created_at"]
        );
        assert!(!all_events.iter().any(|event| {
            let encoded = event.to_string();
            encoded.contains(HIDDEN_TOOL) || encoded.contains("call_hidden_stream")
        }));
    }

    #[tokio::test]
    async fn hosted_executor_hides_private_function_and_continues_main_model() {
        let main_listener = TCPListener::bind("127.0.0.1:0").unwrap();
        let main_address = main_listener.local_addr().unwrap();
        let image_listener = TCPListener::bind("127.0.0.1:0").unwrap();
        let image_address = image_listener.local_addr().unwrap();
        let (main_request_tx, main_request_rx) = mpsc::channel();
        let (image_request_tx, image_request_rx) = mpsc::channel();

        thread::spawn(move || {
            let (first_stream, first_body) = read_http_request(&main_listener);
            let hidden_name = first_body["tools"]
                .as_array()
                .and_then(|tools| {
                    tools.iter().find_map(|tool| {
                        tool.get("function")
                            .and_then(|function| function.get("name"))
                            .and_then(Value::as_str)
                            .filter(|name| name.starts_with(HIDDEN_TOOL))
                    })
                })
                .expect("hosted executor must inject the private image function")
                .to_string();
            main_request_tx.send(first_body).unwrap();
            write_json_response(
                first_stream,
                &json!({
                    "id": "chatcmpl_hidden",
                    "model": "upstream-main",
                    "choices": [{
                        "index": 0,
                        "message": {
                            "role": "assistant",
                            "content": null,
                            "tool_calls": [
                                {
                                    "id": "call_hidden",
                                    "type": "function",
                                    "function": {
                                        "name": hidden_name,
                                        "arguments": "{\"prompt\":\"Turn the source into a moonlit lake\",\"action\":\"edit\",\"input_image_refs\":[\"img_1\"]}"
                                    }
                                },
                                {
                                    "id": "call_hidden_ignored",
                                    "type": "function",
                                    "function": {
                                        "name": hidden_name,
                                        "arguments": "{\"prompt\":\"Make a second image\",\"action\":\"generate\",\"input_image_refs\":[]}"
                                    }
                                }
                            ]
                        },
                        "finish_reason": "tool_calls"
                    }],
                    "usage": {"prompt_tokens": 10, "completion_tokens": 3, "total_tokens": 13}
                }),
            );

            let (second_stream, second_body) = read_http_request(&main_listener);
            main_request_tx.send(second_body).unwrap();
            write_json_response(
                second_stream,
                &json!({
                    "id": "chatcmpl_final",
                    "model": "upstream-main",
                    "choices": [{
                        "index": 0,
                        "message": {"role": "assistant", "content": "The image is ready."},
                        "finish_reason": "stop"
                    }],
                    "usage": {"prompt_tokens": 20, "completion_tokens": 4, "total_tokens": 24}
                }),
            );
        });

        thread::spawn(move || {
            let (stream, body) = read_http_request(&image_listener);
            image_request_tx.send(body).unwrap();
            write_json_response(
                stream,
                &json!({
                    "data": [{
                        "b64_json": "aW1hZ2U=",
                        "media_type": "image/png",
                        "revised_prompt": "A calm lake beneath a full moon"
                    }],
                    "usage": {"input_tokens": 2, "output_tokens": 1, "total_tokens": 3}
                }),
            );
        });

        let spec_json = json!({
            "api_resolver": "openai_chat_completions",
            "upstream": test_upstream(&format!("http://{main_address}/chat/completions")),
            "response_context": {
                "model": "main-model",
                "request": {
                    "input": "Draw a lake",
                    "temperature": 0.25,
                    "max_tool_calls": 1,
                    "tools": [{"type": "image_generation", "model": "openai/gpt-image-2"}],
                    "tool_choice": {"type": "image_generation"}
                }
            },
            "limits": {"max_response_bytes": 1_048_576},
            "hosted_tools": {
                "public_request": {
                    "model": "main-model",
                    "input": "Draw a lake",
                    "service_tier": "priority",
                    "max_tool_calls": 1,
                    "tools": [{"type": "image_generation", "model": "openai/gpt-image-2"}],
                    "tool_choice": {"type": "image_generation"}
                },
                "image_generation": {
                    "tool_config": {"type": "image_generation", "model": "openai/gpt-image-2", "action": "edit"},
                    "selected_model": "openai/gpt-image-2",
                    "prepared_request": {
                        "api_resolver": "openrouter_images",
                        "upstream": test_upstream(&format!("http://{image_address}/images")),
                        "response_context": {
                            "model": "openai/gpt-image-2",
                            "request": {
                                "n": 1,
                                "provider": {
                                    "only": ["openai"],
                                    "allow_fallbacks": false,
                                    "require_parameters": true
                                }
                            }
                        },
                        "limits": {"max_response_bytes": 1_048_576}
                    },
                    "endpoint_capabilities": {},
                    "provider_tag": "openai/gpt-image-2:openai",
                    "provider_slug": "openai",
                    "resolved_references": [{
                        "id": "file_source",
                        "image_url": "data:image/png;base64,c291cmNl",
                        "source": "artifact"
                    }],
                    "limits": {}
                }
            }
        });
        let spec = ModelRequestSpec::from_json(&spec_json.to_string()).unwrap();

        let wrapper = run_hosted_model_request(spec).await.unwrap();
        let body = &wrapper["body"];
        let encoded_body = body.to_string();

        assert_eq!(wrapper["hosted_tool_metadata"]["hosted_tool_calls"], 1);
        assert_eq!(wrapper["hosted_tool_metadata"]["successful_image_calls"], 1);
        assert_eq!(wrapper["hosted_tool_metadata"]["main_model_rounds"], 2);
        assert_eq!(wrapper["hosted_tool_metadata"]["input_bytes"], 6);
        assert_eq!(wrapper["hosted_tool_metadata"]["output_bytes"], 5);

        assert_eq!(body["model"], "main-model");
        assert_eq!(body["status"], "completed");
        assert_eq!(body["output"][0]["type"], "image_generation_call");
        assert_eq!(body["output"][0]["result"], "aW1hZ2U=");
        assert_eq!(
            body["output"][0]["revised_prompt"],
            "A calm lake beneath a full moon"
        );
        assert!(body["output"][0]["id"].as_str().unwrap().starts_with("ig_"));
        assert_eq!(body["output"][1]["type"], "message");
        assert!(!encoded_body.contains(HIDDEN_TOOL));
        assert!(!encoded_body.contains("call_hidden"));
        assert_eq!(body["usage"]["input_tokens"], 32);
        assert_eq!(body["usage"]["output_tokens"], 8);
        assert_eq!(body["usage"]["total_tokens"], 40);

        let first_main = main_request_rx.recv().unwrap();
        let second_main = main_request_rx.recv().unwrap();
        let image_request = image_request_rx.recv().unwrap();

        let first_main_json = first_main.to_string();
        assert!(!first_main_json.contains("\"type\":\"image_generation\""));
        assert!(first_main_json.contains(HIDDEN_TOOL));
        assert_eq!(first_main["temperature"], 0.25);
        assert!(first_main.get("service_tier").is_none());
        let second_main_json = second_main.to_string();
        assert!(second_main_json.contains("call_hidden"));
        assert!(second_main_json.contains("call_hidden_ignored"));
        assert!(second_main_json.contains("max_tool_calls was reached"));
        assert!(!second_main_json.contains("ig_"));
        assert!(second_main.get("tools").is_none());
        assert_eq!(second_main["tool_choice"], json!("none"));
        assert_eq!(image_request["model"], "openai/gpt-image-2");
        assert_eq!(
            image_request["prompt"],
            "Turn the source into a moonlit lake"
        );
        assert_eq!(image_request["n"], 1);
        assert_eq!(image_request["provider"]["only"], json!(["openai"]));
        assert_eq!(
            image_request["input_references"],
            json!([{
                "type": "image_url",
                "image_url": {"url": "data:image/png;base64,c291cmNl"}
            }])
        );
    }

    fn test_image_spec(url: &str) -> HostedImageGenerationSpec {
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

    fn test_upstream(url: &str) -> Value {
        json!({
            "method": "POST",
            "url": url,
            "headers": [["content-type", "application/json"]],
            "timeout": {"connect_ms": 2_000, "first_byte_ms": 2_000, "idle_ms": 2_000, "total_ms": 5_000},
            "transport": {"http_versions": ["h1"], "compression": []}
        })
    }

    fn read_http_request(listener: &TCPListener) -> (TCPStream, Value) {
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

    fn write_json_response(mut stream: TCPStream, body: &Value) {
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

    fn write_sse_chunk(stream: &mut TCPStream, body: &str) {
        write!(stream, "{:x}\r\n{}\r\n", body.len(), body).unwrap();
    }

    fn hosted_sse_event(event_rx: &mpsc::Receiver<super::super::StreamEvent>) -> Option<Value> {
        match event_rx.recv_timeout(Duration::from_secs(1)).unwrap() {
            super::super::StreamEvent::Chunk {
                kind: super::super::DownstreamKind::SSE,
                bytes,
                ..
            } => parse_hosted_sse_chunk(&bytes),
            event => panic!("expected hosted SSE chunk, got {event:?}"),
        }
    }

    fn parse_hosted_sse_chunk(bytes: &[u8]) -> Option<Value> {
        let chunk = String::from_utf8(bytes.to_vec()).unwrap();
        let data = chunk.lines().find_map(|line| line.strip_prefix("data: "))?;
        (data != "[DONE]").then(|| sonic_rs::from_str(data).unwrap())
    }
}
