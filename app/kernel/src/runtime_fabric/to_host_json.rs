use serde_json::{Map, Value};

use crate::common::{KernelError, KernelResult};

use super::{
    body::body_kind,
    enums::{durability_to_json, lane_to_json, turn_completion_outcome_to_json},
    json::*,
    proto,
};
use proto::envelope::Body::{
    RpcError as RPCErrorBody, RpcRequest as RPCRequestBody, RpcResponse as RPCResponseBody,
};

// Converts prost structs back to the canonical host JSON shape. The nested
// `body.type` form keeps dispatch simple in Elixir and TypeScript.
pub(super) fn envelope_to_json(envelope: &proto::Envelope) -> KernelResult<Value> {
    let mut object = Map::new();
    object.insert(
        "protocol_version".into(),
        Value::from(envelope.protocol_version),
    );
    object.insert(
        "message_id".into(),
        Value::from(envelope.message_id.clone()),
    );
    object.insert(
        "correlation_id".into(),
        Value::from(envelope.correlation_id.clone()),
    );
    object.insert("lane".into(), Value::from(lane_to_json(envelope.lane)?));
    object.insert(
        "sent_at_unix_ms".into(),
        Value::from(envelope.sent_at_unix_ms),
    );
    object.insert(
        "durability".into(),
        Value::from(durability_to_json(envelope.durability)?),
    );
    object.insert("body".into(), body_to_json(envelope.body.as_ref())?);

    Ok(Value::Object(object))
}

fn body_to_json(body: Option<&proto::envelope::Body>) -> KernelResult<Value> {
    let body = body.ok_or_else(|| KernelError::new("envelope body is required"))?;
    let body_type = body_kind(body).name();
    let payload = match body {
        proto::envelope::Body::WorkerReady(payload) => worker_ready_to_json(payload),
        proto::envelope::Body::WorkerHeartbeat(payload) => worker_heartbeat_to_json(payload),
        proto::envelope::Body::WorkerCapacity(payload) => worker_capacity_to_json(payload),
        proto::envelope::Body::TurnStart(payload) => turn_start_to_json(payload),
        proto::envelope::Body::MailboxUpdated(payload) => mailbox_updated_to_json(payload),
        proto::envelope::Body::TurnAccepted(payload) => turn_accepted_to_json(payload),
        proto::envelope::Body::TurnControl(payload) => turn_control_to_json(payload),
        proto::envelope::Body::WorkerProgress(payload) => worker_progress_to_json(payload),
        proto::envelope::Body::TurnError(payload) => turn_error_to_json(payload),
        proto::envelope::Body::TurnNoopCompleted(payload) => turn_noop_completed_to_json(payload),
        proto::envelope::Body::TurnCompleted(payload) => turn_completed_to_json(payload),
        proto::envelope::Body::ControlShutdown(payload) => control_shutdown_to_json(payload),
        RPCRequestBody(payload) => rpc_request_to_json(payload),
        RPCResponseBody(payload) => rpc_response_to_json(payload),
        RPCErrorBody(payload) => rpc_error_to_json(payload),
    }?;

    let mut object = Map::new();
    object.insert("type".into(), Value::from(body_type));
    object.insert(body_type.into(), payload);

    Ok(Value::Object(object))
}

fn worker_ready_to_json(payload: &proto::AgentComputerWorkerReady) -> KernelResult<Value> {
    Ok(json_object([
        ("worker_id", Value::from(payload.worker_id.clone())),
        ("runtime", Value::from(payload.runtime.clone())),
        ("version", Value::from(payload.version.clone())),
        ("capacity_json", bytes_to_json(&payload.capacity_json)?),
    ]))
}

fn worker_heartbeat_to_json(payload: &proto::AgentComputerWorkerHeartbeat) -> KernelResult<Value> {
    Ok(json_object([
        ("worker_id", Value::from(payload.worker_id.clone())),
        ("monotonic_ms", Value::from(payload.monotonic_ms)),
        ("load_json", bytes_to_json(&payload.load_json)?),
    ]))
}

fn worker_capacity_to_json(payload: &proto::AgentComputerWorkerCapacity) -> KernelResult<Value> {
    Ok(json_object([
        ("worker_id", Value::from(payload.worker_id.clone())),
        ("capacity_json", bytes_to_json(&payload.capacity_json)?),
        ("load_json", bytes_to_json(&payload.load_json)?),
        (
            "available_turn_slots",
            Value::from(payload.available_turn_slots),
        ),
    ]))
}

fn turn_start_to_json(payload: &proto::TurnStart) -> KernelResult<Value> {
    Ok(json_object([
        ("turn", turn_ref_to_json(payload.turn.as_ref())?),
        (
            "actor_event",
            match payload.actor_event.as_ref() {
                Some(event) => actor_event_to_json(event)?,
                None => Value::Null,
            },
        ),
        (
            "model_ref",
            turn_model_ref_to_json(payload.model_ref.as_ref())?,
        ),
        (
            "request_context",
            bytes_to_json(&payload.request_context_json)?,
        ),
    ]))
}

fn mailbox_updated_to_json(payload: &proto::MailboxUpdated) -> KernelResult<Value> {
    Ok(json_object([
        ("reason", Value::from(payload.reason.clone())),
        ("turn", turn_ref_to_json(payload.turn.as_ref())?),
        (
            "actor_event",
            optional_actor_event_to_json(payload.actor_event.as_ref())?,
        ),
    ]))
}

fn turn_accepted_to_json(payload: &proto::TurnAccepted) -> KernelResult<Value> {
    Ok(json_object([(
        "turn",
        turn_ref_to_json(payload.turn.as_ref())?,
    )]))
}

fn turn_control_to_json(payload: &proto::TurnControl) -> KernelResult<Value> {
    Ok(json_object([
        ("turn", turn_ref_to_json(payload.turn.as_ref())?),
        ("command", Value::from(payload.command.clone())),
        ("payload_json", bytes_to_json(&payload.payload_json)?),
    ]))
}

fn worker_progress_to_json(payload: &proto::WorkerProgress) -> KernelResult<Value> {
    Ok(json_object([
        ("turn", turn_ref_to_json(payload.turn.as_ref())?),
        ("kind", Value::from(payload.kind.clone())),
        ("summary", Value::from(payload.summary.clone())),
        ("refs_json", bytes_to_json(&payload.refs_json)?),
    ]))
}

fn turn_error_to_json(payload: &proto::TurnError) -> KernelResult<Value> {
    Ok(json_object([
        ("turn", turn_ref_to_json(payload.turn.as_ref())?),
        ("code", Value::from(payload.code.clone())),
        ("message", Value::from(payload.message.clone())),
        ("details_json", bytes_to_json(&payload.details_json)?),
    ]))
}

fn turn_noop_completed_to_json(payload: &proto::TurnNoopCompleted) -> KernelResult<Value> {
    Ok(json_object([
        ("turn", turn_ref_to_json(payload.turn.as_ref())?),
        ("reason", Value::from(payload.reason.clone())),
    ]))
}

fn turn_completed_to_json(payload: &proto::TurnCompleted) -> KernelResult<Value> {
    Ok(json_object([
        ("turn", turn_ref_to_json(payload.turn.as_ref())?),
        (
            "final_response_id",
            Value::from(payload.final_response_id.clone()),
        ),
        (
            "outcome",
            Value::from(turn_completion_outcome_to_json(payload.outcome)?),
        ),
    ]))
}

fn control_shutdown_to_json(payload: &proto::ControlShutdown) -> KernelResult<Value> {
    Ok(json_object([(
        "reason",
        Value::from(payload.reason.clone()),
    )]))
}

fn rpc_request_to_json(payload: &proto::RPCRequest) -> KernelResult<Value> {
    Ok(json_object([
        ("request_id", Value::from(payload.request_id.clone())),
        ("method", Value::from(payload.method.clone())),
        ("deadline_unix_ms", Value::from(payload.deadline_unix_ms)),
        ("payload_json", bytes_to_json(&payload.payload_json)?),
    ]))
}

fn rpc_response_to_json(payload: &proto::RPCResponse) -> KernelResult<Value> {
    Ok(json_object([
        ("request_id", Value::from(payload.request_id.clone())),
        ("payload_json", bytes_to_json(&payload.payload_json)?),
    ]))
}

fn rpc_error_to_json(payload: &proto::RPCError) -> KernelResult<Value> {
    Ok(json_object([
        ("request_id", Value::from(payload.request_id.clone())),
        ("code", Value::from(payload.code.clone())),
        ("message", Value::from(payload.message.clone())),
        ("details_json", bytes_to_json(&payload.details_json)?),
    ]))
}

fn turn_ref_to_json(turn: Option<&proto::ActorTurnRef>) -> KernelResult<Value> {
    let turn = turn.ok_or_else(|| KernelError::new("turn ref is required"))?;

    Ok(json_object([
        ("actor", actor_key_to_json(turn.actor.as_ref())?),
        ("activation_uid", Value::from(turn.activation_uid.clone())),
        ("actor_epoch", Value::from(turn.actor_epoch)),
        ("actor_event_id", Value::from(turn.actor_event_id.clone())),
        ("revision", Value::from(turn.revision)),
    ]))
}

fn actor_key_to_json(actor: Option<&proto::ActorKey>) -> KernelResult<Value> {
    let actor = actor.ok_or_else(|| KernelError::new("actor key is required"))?;

    let mut object = Map::new();
    object.insert(
        "agent_uid".to_string(),
        Value::from(actor.agent_uid.clone()),
    );
    object.insert(
        "session_id".to_string(),
        Value::from(actor.session_id.clone()),
    );
    Ok(Value::Object(object))
}

fn turn_model_ref_to_json(model_ref: Option<&proto::TurnModelRef>) -> KernelResult<Value> {
    match model_ref {
        Some(model_ref) => Ok(json_object([
            ("profile", Value::from(model_ref.profile.clone())),
            ("provider_id", Value::from(model_ref.provider_id.clone())),
            ("model", Value::from(model_ref.model.clone())),
            (
                "provider_kind",
                Value::from(model_ref.provider_kind.clone()),
            ),
            (
                "input_modalities",
                string_list_to_json(&model_ref.input_modalities),
            ),
            (
                "vision_fallback_model_ref",
                turn_model_ref_to_json(model_ref.vision_fallback_model_ref.as_deref())?,
            ),
        ])),
        None => Ok(Value::Null),
    }
}

fn actor_event_to_json(event: &proto::ActorEventEnvelope) -> KernelResult<Value> {
    Ok(json_object([
        ("actor_event_id", Value::from(event.actor_event_id.clone())),
        ("queue_sequence", Value::from(event.queue_sequence)),
        ("type", Value::from(event.r#type.clone())),
        (
            "source_event_id",
            Value::from(event.source_event_id.clone()),
        ),
        (
            "source_entry_id",
            Value::from(event.source_entry_id.clone()),
        ),
        ("payload_json", bytes_to_json(&event.payload_json)?),
        ("binding_name", Value::from(event.binding_name.clone())),
        (
            "signal_channel_id",
            Value::from(event.signal_channel_id.clone()),
        ),
        (
            "provider_thread_id",
            Value::from(event.provider_thread_id.clone()),
        ),
    ]))
}

fn optional_actor_event_to_json(event: Option<&proto::ActorEventEnvelope>) -> KernelResult<Value> {
    match event {
        Some(event) => actor_event_to_json(event),
        None => Ok(Value::Null),
    }
}
