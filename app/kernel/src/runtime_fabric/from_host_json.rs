use serde_json::{Map, Value};

use crate::common::{KernelError, KernelResult};

use super::{
    PROTOCOL_VERSION,
    body::BodyKind,
    enums::{durability_from_json, lane_from_json, turn_completion_outcome_from_json},
    json::*,
    proto,
};
use proto::envelope::Body::{
    RpcError as RPCErrorBody, RpcRequest as RPCRequestBody, RpcResponse as RPCResponseBody,
};

pub(super) fn envelope_from_json(value: &Value) -> KernelResult<proto::Envelope> {
    let object = object(value, "envelope")?;
    let body = body_from_json(object)?;

    Ok(proto::Envelope {
        protocol_version: optional_u32(object, "protocol_version")?.unwrap_or(PROTOCOL_VERSION),
        message_id: required_string(object, "message_id")?,
        correlation_id: optional_string(object, "correlation_id")?.unwrap_or_default(),
        lane: lane_from_json(required_value(object, "lane")?)? as i32,
        sent_at_unix_ms: optional_i64(object, "sent_at_unix_ms")?.unwrap_or_default(),
        durability: durability_from_json(required_value(object, "durability")?)? as i32,
        body: Some(body),
    })
}

// Accepts the canonical typed host shape: `body.type + body[type]`.
fn body_from_json(object: &Map<String, Value>) -> KernelResult<proto::envelope::Body> {
    match object.get("body") {
        Some(Value::Object(body)) => typed_body_from_json(body),
        Some(_value) => Err(KernelError::new("body must be an object")),
        None => Err(KernelError::new("envelope body is required")),
    }
}

fn typed_body_from_json(body: &Map<String, Value>) -> KernelResult<proto::envelope::Body> {
    let body_type = required_string(body, "type")?;
    let payload = required_value(body, &body_type)?;

    named_body_from_json(&body_type, payload)
}

fn named_body_from_json(name: &str, payload: &Value) -> KernelResult<proto::envelope::Body> {
    match BodyKind::from_name(name)? {
        BodyKind::WorkerReady => Ok(proto::envelope::Body::WorkerReady(worker_ready_from_json(
            payload,
        )?)),
        BodyKind::WorkerHeartbeat => Ok(proto::envelope::Body::WorkerHeartbeat(
            worker_heartbeat_from_json(payload)?,
        )),
        BodyKind::WorkerCapacity => Ok(proto::envelope::Body::WorkerCapacity(
            worker_capacity_from_json(payload)?,
        )),
        BodyKind::TurnStart => Ok(proto::envelope::Body::TurnStart(turn_start_from_json(
            payload,
        )?)),
        BodyKind::MailboxUpdated => Ok(proto::envelope::Body::MailboxUpdated(
            mailbox_updated_from_json(payload)?,
        )),
        BodyKind::TurnAccepted => Ok(proto::envelope::Body::TurnAccepted(
            turn_accepted_from_json(payload)?,
        )),
        BodyKind::TurnControl => Ok(proto::envelope::Body::TurnControl(turn_control_from_json(
            payload,
        )?)),
        BodyKind::WorkerProgress => Ok(proto::envelope::Body::WorkerProgress(
            worker_progress_from_json(payload)?,
        )),
        BodyKind::TurnError => Ok(proto::envelope::Body::TurnError(turn_error_from_json(
            payload,
        )?)),
        BodyKind::TurnNoopCompleted => Ok(proto::envelope::Body::TurnNoopCompleted(
            turn_noop_completed_from_json(payload)?,
        )),
        BodyKind::TurnCompleted => Ok(proto::envelope::Body::TurnCompleted(
            turn_completed_from_json(payload)?,
        )),
        BodyKind::ControlShutdown => Ok(proto::envelope::Body::ControlShutdown(
            control_shutdown_from_json(payload)?,
        )),
        BodyKind::RPCRequest => Ok(RPCRequestBody(rpc_request_from_json(payload)?)),
        BodyKind::RPCResponse => Ok(RPCResponseBody(rpc_response_from_json(payload)?)),
        BodyKind::RPCError => Ok(RPCErrorBody(rpc_error_from_json(payload)?)),
    }
}

// Worker ready records runtime identity and capacity only. Per-worker feature
// negotiation is not part of the protocol because workers are homogeneous by image.
fn worker_ready_from_json(value: &Value) -> KernelResult<proto::AgentComputerWorkerReady> {
    let object = object(value, "worker_ready")?;

    Ok(proto::AgentComputerWorkerReady {
        worker_id: required_string(object, "worker_id")?,
        runtime: required_string(object, "runtime")?,
        version: required_string(object, "version")?,
        capacity_json: json_bytes(object.get("capacity_json"))?.unwrap_or_default(),
        incarnation_id: required_string(object, "incarnation_id")?,
    })
}

fn worker_heartbeat_from_json(value: &Value) -> KernelResult<proto::AgentComputerWorkerHeartbeat> {
    let object = object(value, "worker_heartbeat")?;

    Ok(proto::AgentComputerWorkerHeartbeat {
        worker_id: required_string(object, "worker_id")?,
        monotonic_ms: optional_i64(object, "monotonic_ms")?.unwrap_or_default(),
        load_json: json_bytes(object.get("load_json"))?.unwrap_or_default(),
        incarnation_id: required_string(object, "incarnation_id")?,
    })
}

fn worker_capacity_from_json(value: &Value) -> KernelResult<proto::AgentComputerWorkerCapacity> {
    let object = object(value, "worker_capacity")?;

    Ok(proto::AgentComputerWorkerCapacity {
        worker_id: required_string(object, "worker_id")?,
        capacity_json: json_bytes(object.get("capacity_json"))?.unwrap_or_default(),
        load_json: json_bytes(object.get("load_json"))?.unwrap_or_default(),
        available_turn_slots: optional_u32(object, "available_turn_slots")?.unwrap_or_default(),
        incarnation_id: required_string(object, "incarnation_id")?,
    })
}

// Turn start carries a single actor event to the computer worker. One worker
// run handles exactly one actor_event_id.
fn turn_start_from_json(value: &Value) -> KernelResult<proto::TurnStart> {
    let object = object(value, "turn_start")?;

    Ok(proto::TurnStart {
        turn: Some(turn_ref_from_json(required_value(object, "turn")?)?),
        actor_event: optional_message(object.get("actor_event"), actor_event_from_json)?,
        model_ref: optional_message(object.get("model_ref"), turn_model_ref_from_json)?,
        request_context_json: json_bytes(object.get("request_context"))?.unwrap_or_default(),
    })
}

fn mailbox_updated_from_json(value: &Value) -> KernelResult<proto::MailboxUpdated> {
    let object = object(value, "mailbox_updated")?;

    Ok(proto::MailboxUpdated {
        reason: optional_string(object, "reason")?.unwrap_or_default(),
        turn: optional_message(object.get("turn"), turn_ref_from_json)?,
        actor_event: optional_message(object.get("actor_event"), actor_event_from_json)?,
    })
}

fn turn_accepted_from_json(value: &Value) -> KernelResult<proto::TurnAccepted> {
    let object = object(value, "turn_accepted")?;

    Ok(proto::TurnAccepted {
        turn: Some(turn_ref_from_json(required_value(object, "turn")?)?),
    })
}

fn turn_control_from_json(value: &Value) -> KernelResult<proto::TurnControl> {
    let object = object(value, "turn_control")?;

    Ok(proto::TurnControl {
        turn: Some(turn_ref_from_json(required_value(object, "turn")?)?),
        command: required_string(object, "command")?,
        payload_json: json_bytes(object.get("payload_json"))?.unwrap_or_default(),
    })
}

fn worker_progress_from_json(value: &Value) -> KernelResult<proto::WorkerProgress> {
    let object = object(value, "worker_progress")?;

    Ok(proto::WorkerProgress {
        turn: Some(turn_ref_from_json(required_value(object, "turn")?)?),
        kind: required_string(object, "kind")?,
        summary: optional_string(object, "summary")?.unwrap_or_default(),
        refs_json: json_bytes(object.get("refs_json"))?.unwrap_or_default(),
    })
}

fn turn_error_from_json(value: &Value) -> KernelResult<proto::TurnError> {
    let object = object(value, "turn_error")?;

    Ok(proto::TurnError {
        turn: Some(turn_ref_from_json(required_value(object, "turn")?)?),
        code: required_string(object, "code")?,
        message: optional_string(object, "message")?.unwrap_or_default(),
        details_json: json_bytes(object.get("details_json"))?.unwrap_or_default(),
    })
}

fn turn_noop_completed_from_json(value: &Value) -> KernelResult<proto::TurnNoopCompleted> {
    let object = object(value, "turn_noop_completed")?;

    Ok(proto::TurnNoopCompleted {
        turn: Some(turn_ref_from_json(required_value(object, "turn")?)?),
        reason: optional_string(object, "reason")?.unwrap_or_default(),
    })
}

fn turn_completed_from_json(value: &Value) -> KernelResult<proto::TurnCompleted> {
    let object = object(value, "turn_completed")?;

    Ok(proto::TurnCompleted {
        turn: Some(turn_ref_from_json(required_value(object, "turn")?)?),
        final_response_id: required_string(object, "final_response_id")?,
        outcome: turn_completion_outcome_from_json(required_value(object, "outcome")?)? as i32,
    })
}

fn control_shutdown_from_json(value: &Value) -> KernelResult<proto::ControlShutdown> {
    let object = object(value, "control_shutdown")?;

    Ok(proto::ControlShutdown {
        reason: optional_string(object, "reason")?.unwrap_or_default(),
    })
}

fn rpc_request_from_json(value: &Value) -> KernelResult<proto::RPCRequest> {
    let object = object(value, "rpc_request")?;

    Ok(proto::RPCRequest {
        request_id: required_string(object, "request_id")?,
        method: required_string(object, "method")?,
        deadline_unix_ms: optional_i64(object, "deadline_unix_ms")?.unwrap_or_default(),
        payload_json: json_bytes(object.get("payload_json"))?.unwrap_or_default(),
    })
}

fn rpc_response_from_json(value: &Value) -> KernelResult<proto::RPCResponse> {
    let object = object(value, "rpc_response")?;

    Ok(proto::RPCResponse {
        request_id: required_string(object, "request_id")?,
        payload_json: json_bytes(object.get("payload_json"))?.unwrap_or_default(),
    })
}

fn rpc_error_from_json(value: &Value) -> KernelResult<proto::RPCError> {
    let object = object(value, "rpc_error")?;

    Ok(proto::RPCError {
        request_id: required_string(object, "request_id")?,
        code: required_string(object, "code")?,
        message: optional_string(object, "message")?.unwrap_or_default(),
        details_json: json_bytes(object.get("details_json"))?.unwrap_or_default(),
    })
}

// Parses the durable run fence echoed by worker replies. Every field is
// required so stale replies fail by equality checks in the control plane.
fn turn_ref_from_json(value: &Value) -> KernelResult<proto::ActorTurnRef> {
    let object = object(value, "turn")?;

    Ok(proto::ActorTurnRef {
        actor: Some(actor_key_from_json(required_value(object, "actor")?)?),
        activation_uid: required_string(object, "activation_uid")?,
        actor_epoch: required_u64(object, "actor_epoch")?,
        actor_event_id: required_string(object, "actor_event_id")?,
        revision: required_u32(object, "revision")?,
    })
}

fn actor_key_from_json(value: &Value) -> KernelResult<proto::ActorKey> {
    let object = object(value, "actor")?;

    Ok(proto::ActorKey {
        agent_uid: required_string(object, "agent_uid")?,
        session_id: required_string(object, "session_id")?,
    })
}

fn turn_model_ref_from_json(value: &Value) -> KernelResult<proto::TurnModelRef> {
    let object = object(value, "model_ref")?;

    Ok(proto::TurnModelRef {
        profile: required_string(object, "profile")?,
        provider_id: required_string(object, "provider_id")?,
        model: required_string(object, "model")?,
        provider_kind: optional_string(object, "provider_kind")?.unwrap_or_default(),
        input_modalities: optional_string_list(object, "input_modalities")?.unwrap_or_default(),
        vision_fallback_model_ref: optional_message(
            object.get("vision_fallback_model_ref"),
            turn_model_ref_from_json,
        )?
        .map(Box::new),
    })
}

// Parses the single actor-event envelope carried by actor-lane messages.
fn actor_event_from_json(value: &Value) -> KernelResult<proto::ActorEventEnvelope> {
    let object = object(value, "actor_event")?;

    Ok(proto::ActorEventEnvelope {
        actor_event_id: required_string(object, "actor_event_id")?,
        queue_sequence: required_u64(object, "queue_sequence")?,
        r#type: required_string(object, "type")?,
        source_event_id: required_string(object, "source_event_id")?,
        source_entry_id: optional_string(object, "source_entry_id")?.unwrap_or_default(),
        payload_json: json_bytes(object.get("payload_json"))?.unwrap_or_default(),
        binding_name: optional_string(object, "binding_name")?.unwrap_or_default(),
        signal_channel_id: optional_string(object, "signal_channel_id")?.unwrap_or_default(),
        provider_thread_id: optional_string(object, "provider_thread_id")?.unwrap_or_default(),
    })
}
