use serde_json::{Map, Value};

use crate::common::{KernelError, KernelResult};

use super::{
    PROTOCOL_VERSION,
    enums::{durability_from_json, lane_from_json},
    json::*,
    proto,
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
    match normalized_name(name).as_str() {
        "worker_ready" => Ok(proto::envelope::Body::WorkerReady(worker_ready_from_json(
            payload,
        )?)),
        "worker_heartbeat" => Ok(proto::envelope::Body::WorkerHeartbeat(
            worker_heartbeat_from_json(payload)?,
        )),
        "worker_capacity" => Ok(proto::envelope::Body::WorkerCapacity(
            worker_capacity_from_json(payload)?,
        )),
        "turn_start" => Ok(proto::envelope::Body::TurnStart(turn_start_from_json(
            payload,
        )?)),
        "mailbox_updated" => Ok(proto::envelope::Body::MailboxUpdated(
            mailbox_updated_from_json(payload)?,
        )),
        "turn_accepted" => Ok(proto::envelope::Body::TurnAccepted(
            turn_accepted_from_json(payload)?,
        )),
        "turn_control" => Ok(proto::envelope::Body::TurnControl(turn_control_from_json(
            payload,
        )?)),
        "worker_progress" => Ok(proto::envelope::Body::WorkerProgress(
            worker_progress_from_json(payload)?,
        )),
        "turn_final_proposal" => Ok(proto::envelope::Body::TurnFinalProposal(
            turn_final_proposal_from_json(payload)?,
        )),
        "turn_error" => Ok(proto::envelope::Body::TurnError(turn_error_from_json(
            payload,
        )?)),
        "control_shutdown" => Ok(proto::envelope::Body::ControlShutdown(
            control_shutdown_from_json(payload)?,
        )),
        "rpc_request" => Ok(proto::envelope::Body::RpcRequest(rpc_request_from_json(
            payload,
        )?)),
        "rpc_response" => Ok(proto::envelope::Body::RpcResponse(rpc_response_from_json(
            payload,
        )?)),
        "rpc_error" => Ok(proto::envelope::Body::RpcError(rpc_error_from_json(
            payload,
        )?)),
        other => Err(KernelError::new(format!(
            "unsupported runtime fabric body: {other}"
        ))),
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
    })
}

fn worker_heartbeat_from_json(value: &Value) -> KernelResult<proto::AgentComputerWorkerHeartbeat> {
    let object = object(value, "worker_heartbeat")?;

    Ok(proto::AgentComputerWorkerHeartbeat {
        worker_id: required_string(object, "worker_id")?,
        monotonic_ms: optional_i64(object, "monotonic_ms")?.unwrap_or_default(),
        load_json: json_bytes(object.get("load_json"))?.unwrap_or_default(),
    })
}

fn worker_capacity_from_json(value: &Value) -> KernelResult<proto::AgentComputerWorkerCapacity> {
    let object = object(value, "worker_capacity")?;

    Ok(proto::AgentComputerWorkerCapacity {
        worker_id: required_string(object, "worker_id")?,
        capacity_json: json_bytes(object.get("capacity_json"))?.unwrap_or_default(),
        load_json: json_bytes(object.get("load_json"))?.unwrap_or_default(),
        available_turn_slots: optional_u32(object, "available_turn_slots")?.unwrap_or_default(),
    })
}

// Turn start carries actor inputs to the computer worker. It does not carry
// pre-rendered LLM requests because the complete computer owns the local AI loop.
fn turn_start_from_json(value: &Value) -> KernelResult<proto::TurnStart> {
    let object = object(value, "turn_start")?;

    Ok(proto::TurnStart {
        turn: Some(turn_ref_from_json(required_value(object, "turn")?)?),
        inputs: actor_inputs_from_json(object.get("inputs"))?,
        model_ref: optional_message(object.get("model_ref"), turn_model_ref_from_json)?,
    })
}

fn mailbox_updated_from_json(value: &Value) -> KernelResult<proto::MailboxUpdated> {
    let object = object(value, "mailbox_updated")?;
    let turn = optional_message(object.get("turn"), turn_ref_from_json)?;
    let actor = match object.get("actor") {
        Some(actor) => Some(actor_key_from_json(actor)?),
        None => turn.as_ref().and_then(|turn| turn.actor.clone()),
    };

    Ok(proto::MailboxUpdated {
        actor,
        activation_uid: optional_string(object, "activation_uid")?
            .or_else(|| turn.as_ref().map(|turn| turn.activation_uid.clone()))
            .unwrap_or_default(),
        actor_epoch: optional_u64(object, "actor_epoch")?
            .or_else(|| turn.as_ref().map(|turn| turn.actor_epoch))
            .unwrap_or_default(),
        reason: optional_string(object, "reason")?.unwrap_or_default(),
        turn,
        inputs: actor_inputs_from_json(object.get("inputs"))?,
    })
}

fn turn_accepted_from_json(value: &Value) -> KernelResult<proto::TurnAccepted> {
    let object = object(value, "turn_accepted")?;

    Ok(proto::TurnAccepted {
        turn: Some(turn_ref_from_json(required_value(object, "turn")?)?),
        accepted_actor_input_ids: string_list(object.get("accepted_actor_input_ids"))?,
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

// A final proposal is still only a proposal. The control plane must validate
// the turn fence and commit it before it becomes durable transcript state.
fn turn_final_proposal_from_json(value: &Value) -> KernelResult<proto::TurnFinalProposal> {
    let object = object(value, "turn_final_proposal")?;

    Ok(proto::TurnFinalProposal {
        turn: Some(turn_ref_from_json(required_value(object, "turn")?)?),
        messages: proposed_messages_from_json(object.get("messages"))?,
        reply: optional_message(object.get("reply"), proposed_reply_from_json)?,
        usage_json: json_bytes(object.get("usage_json"))?.unwrap_or_default(),
        provider_metadata_json: json_bytes(object.get("provider_metadata_json"))?
            .unwrap_or_default(),
        stop_reason: optional_string(object, "stop_reason")?.unwrap_or_default(),
        tool_results_json: json_bytes(object.get("tool_results_json"))?.unwrap_or_default(),
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

fn control_shutdown_from_json(value: &Value) -> KernelResult<proto::ControlShutdown> {
    let object = object(value, "control_shutdown")?;

    Ok(proto::ControlShutdown {
        reason: optional_string(object, "reason")?.unwrap_or_default(),
    })
}

fn rpc_request_from_json(value: &Value) -> KernelResult<proto::RpcRequest> {
    let object = object(value, "rpc_request")?;

    Ok(proto::RpcRequest {
        request_id: required_string(object, "request_id")?,
        method: required_string(object, "method")?,
        deadline_unix_ms: optional_i64(object, "deadline_unix_ms")?.unwrap_or_default(),
        payload_json: json_bytes(object.get("payload_json"))?.unwrap_or_default(),
    })
}

fn rpc_response_from_json(value: &Value) -> KernelResult<proto::RpcResponse> {
    let object = object(value, "rpc_response")?;

    Ok(proto::RpcResponse {
        request_id: required_string(object, "request_id")?,
        payload_json: json_bytes(object.get("payload_json"))?.unwrap_or_default(),
    })
}

fn rpc_error_from_json(value: &Value) -> KernelResult<proto::RpcError> {
    let object = object(value, "rpc_error")?;

    Ok(proto::RpcError {
        request_id: required_string(object, "request_id")?,
        code: required_string(object, "code")?,
        message: optional_string(object, "message")?.unwrap_or_default(),
        details_json: json_bytes(object.get("details_json"))?.unwrap_or_default(),
    })
}

// Parses the durable turn fence echoed by worker replies. Every field is
// required so stale replies fail by equality checks in the control plane.
fn turn_ref_from_json(value: &Value) -> KernelResult<proto::ActorTurnRef> {
    let object = object(value, "turn")?;

    Ok(proto::ActorTurnRef {
        actor: Some(actor_key_from_json(required_value(object, "actor")?)?),
        activation_uid: required_string(object, "activation_uid")?,
        actor_epoch: required_u64(object, "actor_epoch")?,
        llm_turn_id: required_string(object, "llm_turn_id")?,
        revision: required_u32(object, "revision")?,
    })
}

fn actor_key_from_json(value: &Value) -> KernelResult<proto::ActorKey> {
    let object = object(value, "actor")?;
    reject_actor_profile_field(object, "display_name")?;
    reject_actor_profile_field(object, "role")?;

    Ok(proto::ActorKey {
        agent_uid: required_string(object, "agent_uid")?,
        session_id: required_string(object, "session_id")?,
    })
}

fn reject_actor_profile_field(object: &Map<String, Value>, field: &str) -> KernelResult<()> {
    if object.contains_key(field) {
        return Err(KernelError::new(format!(
            "ActorKey must not carry {field}; resolve display identity through RPCLane"
        )));
    }

    Ok(())
}

fn turn_model_ref_from_json(value: &Value) -> KernelResult<proto::TurnModelRef> {
    let object = object(value, "model_ref")?;

    Ok(proto::TurnModelRef {
        profile: required_string(object, "profile")?,
        provider_id: required_string(object, "provider_id")?,
        model: required_string(object, "model")?,
    })
}

fn actor_inputs_from_json(value: Option<&Value>) -> KernelResult<Vec<proto::ActorInputEnvelope>> {
    array(value, "inputs")?
        .into_iter()
        .map(actor_input_from_json)
        .collect()
}

fn actor_input_from_json(value: &Value) -> KernelResult<proto::ActorInputEnvelope> {
    let object = object(value, "actor_input")?;

    Ok(proto::ActorInputEnvelope {
        actor_input_id: required_string(object, "actor_input_id")?,
        live_queue_sequence: required_u64(object, "live_queue_sequence")?,
        r#type: required_string(object, "type")?,
        ingress_event_id: required_string(object, "ingress_event_id")?,
        provider_entry_id: optional_string(object, "provider_entry_id")?.unwrap_or_default(),
        payload_json: json_bytes(object.get("payload_json"))?.unwrap_or_default(),
    })
}

fn proposed_messages_from_json(value: Option<&Value>) -> KernelResult<Vec<proto::ProposedMessage>> {
    array(value, "messages")?
        .into_iter()
        .map(proposed_message_from_json)
        .collect()
}

fn proposed_message_from_json(value: &Value) -> KernelResult<proto::ProposedMessage> {
    let object = object(value, "proposed_message")?;

    Ok(proto::ProposedMessage {
        role: required_string(object, "role")?,
        content_json: json_bytes(object.get("content_json"))?.unwrap_or_default(),
        metadata_json: json_bytes(object.get("metadata_json"))?.unwrap_or_default(),
    })
}

fn proposed_reply_from_json(value: &Value) -> KernelResult<proto::ProposedReply> {
    let object = object(value, "reply")?;

    Ok(proto::ProposedReply {
        text: optional_string(object, "text")?.unwrap_or_default(),
        content_json: json_bytes(object.get("content_json"))?.unwrap_or_default(),
        attachments: proposed_reply_attachments_from_json(object.get("attachments"))?,
    })
}

fn proposed_reply_attachments_from_json(
    value: Option<&Value>,
) -> KernelResult<Vec<proto::ProposedReplyAttachment>> {
    array(value, "attachments")?
        .into_iter()
        .map(proposed_reply_attachment_from_json)
        .collect()
}

fn proposed_reply_attachment_from_json(
    value: &Value,
) -> KernelResult<proto::ProposedReplyAttachment> {
    let object = object(value, "attachment")?;

    Ok(proto::ProposedReplyAttachment {
        agent_computer_path: optional_string(object, "agent_computer_path")?.unwrap_or_default(),
        user_files_relative_path: optional_string(object, "user_files_relative_path")?
            .unwrap_or_default(),
        name: optional_string(object, "name")?.unwrap_or_default(),
        mime_type: optional_string(object, "mime_type")?.unwrap_or_default(),
        size: optional_u64(object, "size")?,
        xxh3_128: optional_string(object, "xxh3_128")?.unwrap_or_default(),
    })
}
