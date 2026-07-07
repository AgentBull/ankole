use crate::common::{KernelError, KernelResult};

use super::{
    PROTOCOL_VERSION,
    body::body_spec,
    enums::{durability_name, lane_name},
    json::{empty_json_payload_bytes, normalized_name},
    proto,
};

// Validates protocol invariants that must be identical for Elixir and Bun
// callers. Host code should not need to duplicate lane, durability, or
// correlation rules.
pub(super) fn validate_envelope(envelope: &proto::Envelope) -> KernelResult<()> {
    if envelope.protocol_version != PROTOCOL_VERSION {
        return Err(KernelError::new(format!(
            "unsupported runtime fabric protocol version: {}",
            envelope.protocol_version
        )));
    }

    if envelope.message_id.trim().is_empty() {
        return Err(KernelError::new("message_id is required"));
    }

    let lane = proto::Lane::try_from(envelope.lane).unwrap_or(proto::Lane::Unspecified);

    if lane == proto::Lane::Unspecified {
        return Err(KernelError::new("lane must be specified"));
    }

    let durability = proto::DurabilityClass::try_from(envelope.durability)
        .unwrap_or(proto::DurabilityClass::DurabilityUnspecified);

    if durability == proto::DurabilityClass::DurabilityUnspecified {
        return Err(KernelError::new("durability must be specified"));
    }

    match &envelope.body {
        Some(body) => {
            validate_body_required_fields(body)?;
            validate_body_semantics(body, lane, durability)?;
            validate_correlation_id(envelope, body)?;

            match body {
                proto::envelope::Body::TurnControl(control) => validate_turn_control(control),
                proto::envelope::Body::WorkerProgress(progress) => {
                    validate_worker_progress(progress)
                }
                proto::envelope::Body::RpcRequest(request) => {
                    validate_rpc_correlation(&envelope.correlation_id, &request.request_id)
                }
                proto::envelope::Body::RpcResponse(response) => {
                    validate_rpc_correlation(&envelope.correlation_id, &response.request_id)
                }
                proto::envelope::Body::RpcError(error) => {
                    validate_rpc_correlation(&envelope.correlation_id, &error.request_id)
                }
                _body => Ok(()),
            }
        }
        None => Err(KernelError::new("envelope body is required")),
    }
}

// Requires correlation ids only for envelopes that belong to a specific turn or
// request/reply chain. Worker lifecycle envelopes are intentionally ephemeral.
fn validate_correlation_id(
    envelope: &proto::Envelope,
    body: &proto::envelope::Body,
) -> KernelResult<()> {
    let spec = body_spec(body);

    if !spec.requires_correlation_id {
        return Ok(());
    }

    if envelope.correlation_id.trim().is_empty() {
        return Err(KernelError::new(format!(
            "{} requires correlation_id",
            spec.name
        )));
    }

    Ok(())
}

// Keeps lane and durability tied to the body type. This prevents callers from
// accidentally making a retryable turn-start look like an ephemeral control
// message, or making worker progress durable when it is only observational.
fn validate_body_semantics(
    body: &proto::envelope::Body,
    lane: proto::Lane,
    durability: proto::DurabilityClass,
) -> KernelResult<()> {
    let spec = body_spec(body);

    if lane != spec.lane {
        return Err(KernelError::new(format!(
            "{} must use lane {}",
            spec.name,
            lane_name(spec.lane)
        )));
    }

    if durability != spec.durability {
        return Err(KernelError::new(format!(
            "{} must use durability {}",
            spec.name,
            durability_name(spec.durability)
        )));
    }

    Ok(())
}

fn validate_body_required_fields(body: &proto::envelope::Body) -> KernelResult<()> {
    match body {
        proto::envelope::Body::WorkerReady(payload) => {
            require_non_empty(&payload.worker_id, "worker_ready.worker_id")?;
            require_non_empty(&payload.runtime, "worker_ready.runtime")?;
            require_non_empty(&payload.version, "worker_ready.version")
        }
        proto::envelope::Body::WorkerHeartbeat(payload) => {
            require_non_empty(&payload.worker_id, "worker_heartbeat.worker_id")
        }
        proto::envelope::Body::WorkerCapacity(payload) => {
            require_non_empty(&payload.worker_id, "worker_capacity.worker_id")
        }
        proto::envelope::Body::TurnStart(payload) => {
            validate_turn_ref(payload.turn.as_ref(), "turn_start.turn")?;
            validate_actor_event(payload.actor_event.as_ref(), "turn_start.actor_event")?;
            validate_optional_model_ref(payload.model_ref.as_ref(), "turn_start.model_ref")
        }
        proto::envelope::Body::MailboxUpdated(payload) => {
            validate_turn_ref(payload.turn.as_ref(), "mailbox_updated.turn")?;
            validate_actor_event(payload.actor_event.as_ref(), "mailbox_updated.actor_event")
        }
        proto::envelope::Body::TurnAccepted(payload) => {
            validate_turn_ref(payload.turn.as_ref(), "turn_accepted.turn")?;
            Ok(())
        }
        proto::envelope::Body::TurnControl(payload) => {
            validate_turn_ref(payload.turn.as_ref(), "turn_control.turn")?;
            require_non_empty(&payload.command, "turn_control.command")
        }
        proto::envelope::Body::WorkerProgress(payload) => {
            validate_turn_ref(payload.turn.as_ref(), "worker_progress.turn")?;
            require_non_empty(&payload.kind, "worker_progress.kind")
        }
        proto::envelope::Body::TurnError(payload) => {
            validate_turn_ref(payload.turn.as_ref(), "turn_error.turn")?;
            require_non_empty(&payload.code, "turn_error.code")
        }
        proto::envelope::Body::TurnNoopCompleted(payload) => {
            validate_turn_ref(payload.turn.as_ref(), "turn_noop_completed.turn")?;
            Ok(())
        }
        proto::envelope::Body::ControlShutdown(_payload) => Ok(()),
        proto::envelope::Body::RpcRequest(payload) => {
            require_non_empty(&payload.request_id, "rpc_request.request_id")?;
            require_non_empty(&payload.method, "rpc_request.method")
        }
        proto::envelope::Body::RpcResponse(payload) => {
            require_non_empty(&payload.request_id, "rpc_response.request_id")
        }
        proto::envelope::Body::RpcError(payload) => {
            require_non_empty(&payload.request_id, "rpc_error.request_id")?;
            require_non_empty(&payload.code, "rpc_error.code")
        }
    }
}

// Validates the single actor-event envelope carried by turn_start.
fn validate_actor_event(
    event: Option<&proto::ActorEventEnvelope>,
    field: &str,
) -> KernelResult<()> {
    let event = event.ok_or_else(|| KernelError::new(format!("{field} is required")))?;

    require_non_empty(&event.actor_event_id, &format!("{field}.actor_event_id"))?;
    require_positive_u64(event.queue_sequence, &format!("{field}.queue_sequence"))?;
    require_non_empty(&event.r#type, &format!("{field}.type"))?;
    require_non_empty(&event.source_event_id, &format!("{field}.source_event_id"))?;

    Ok(())
}

fn validate_turn_ref<'a>(
    turn: Option<&'a proto::ActorTurnRef>,
    field: &str,
) -> KernelResult<&'a proto::ActorTurnRef> {
    let turn = turn.ok_or_else(|| KernelError::new(format!("{field} is required")))?;
    validate_actor_key(turn.actor.as_ref(), &format!("{field}.actor"))?;
    require_non_empty(&turn.activation_uid, &format!("{field}.activation_uid"))?;
    require_positive_u64(turn.actor_epoch, &format!("{field}.actor_epoch"))?;
    require_non_empty(&turn.actor_event_id, &format!("{field}.actor_event_id"))?;
    Ok(turn)
}

fn validate_actor_key(actor: Option<&proto::ActorKey>, field: &str) -> KernelResult<()> {
    let actor = actor.ok_or_else(|| KernelError::new(format!("{field} is required")))?;
    require_non_empty(&actor.agent_uid, &format!("{field}.agent_uid"))?;
    require_non_empty(&actor.session_id, &format!("{field}.session_id"))
}

fn validate_optional_model_ref(
    model_ref: Option<&proto::TurnModelRef>,
    field: &str,
) -> KernelResult<()> {
    if let Some(model_ref) = model_ref {
        require_non_empty(&model_ref.profile, &format!("{field}.profile"))?;
        require_non_empty(&model_ref.provider_id, &format!("{field}.provider_id"))?;
        require_non_empty(&model_ref.model, &format!("{field}.model"))?;
        for (index, modality) in model_ref.input_modalities.iter().enumerate() {
            require_non_empty(modality, &format!("{field}.input_modalities[{index}]"))?;
        }
        validate_optional_model_ref(
            model_ref.vision_fallback_model_ref.as_deref(),
            &format!("{field}.vision_fallback_model_ref"),
        )?;
    }

    Ok(())
}

fn require_non_empty(value: &str, field: &str) -> KernelResult<()> {
    if value.trim().is_empty() {
        return Err(KernelError::new(format!("{field} is required")));
    }

    Ok(())
}

fn require_positive_u64(value: u64, field: &str) -> KernelResult<()> {
    if value == 0 {
        return Err(KernelError::new(format!("{field} must be greater than 0")));
    }

    Ok(())
}

// Steering must be journaled as an actor event instead of hidden in a
// turn-control payload. That preserves the user-visible event stream as the
// replay source.
fn validate_turn_control(control: &proto::TurnControl) -> KernelResult<()> {
    if control.command == "steer" && !empty_json_payload_bytes(&control.payload_json) {
        return Err(KernelError::new(
            "turn_control steer payload must be empty and journaled as actor event",
        ));
    }

    Ok(())
}

// Allows only progress classes that the control plane can surface without
// changing durable actor state.
fn validate_worker_progress(progress: &proto::WorkerProgress) -> KernelResult<()> {
    match normalized_name(&progress.kind).as_str() {
        "summary"
        | "checkpoint"
        | "artifact_ref"
        | "cancellation_observed"
        | "retryable_error"
        | "final_error" => Ok(()),
        other => Err(KernelError::new(format!(
            "worker_progress kind is not a control-plane-visible progress class: {other}"
        ))),
    }
}

fn validate_rpc_correlation(correlation_id: &str, request_id: &str) -> KernelResult<()> {
    if correlation_id != request_id {
        return Err(KernelError::new(
            "rpc envelope correlation_id must equal request_id",
        ));
    }

    Ok(())
}
