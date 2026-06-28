use serde_json::{Map, Value};

use crate::common::{KernelError, KernelResult};

use super::{
    enums::{durability_to_json, lane_to_json},
    json::*,
    proto,
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
    let (body_type, payload) = match body {
        Some(proto::envelope::Body::WorkerReady(payload)) => {
            ("worker_ready", worker_ready_to_json(payload))
        }
        Some(proto::envelope::Body::WorkerHeartbeat(payload)) => {
            ("worker_heartbeat", worker_heartbeat_to_json(payload))
        }
        Some(proto::envelope::Body::WorkerCapacity(payload)) => {
            ("worker_capacity", worker_capacity_to_json(payload))
        }
        Some(proto::envelope::Body::TurnStart(payload)) => {
            ("turn_start", turn_start_to_json(payload))
        }
        Some(proto::envelope::Body::MailboxUpdated(payload)) => {
            ("mailbox_updated", mailbox_updated_to_json(payload))
        }
        Some(proto::envelope::Body::TurnAccepted(payload)) => {
            ("turn_accepted", turn_accepted_to_json(payload))
        }
        Some(proto::envelope::Body::TurnControl(payload)) => {
            ("turn_control", turn_control_to_json(payload))
        }
        Some(proto::envelope::Body::WorkerProgress(payload)) => {
            ("worker_progress", worker_progress_to_json(payload))
        }
        Some(proto::envelope::Body::TurnFinalProposal(payload)) => {
            ("turn_final_proposal", turn_final_proposal_to_json(payload))
        }
        Some(proto::envelope::Body::TurnError(payload)) => {
            ("turn_error", turn_error_to_json(payload))
        }
        Some(proto::envelope::Body::ControlShutdown(payload)) => {
            ("control_shutdown", control_shutdown_to_json(payload))
        }
        Some(proto::envelope::Body::RpcRequest(payload)) => {
            ("rpc_request", rpc_request_to_json(payload))
        }
        Some(proto::envelope::Body::RpcResponse(payload)) => {
            ("rpc_response", rpc_response_to_json(payload))
        }
        Some(proto::envelope::Body::RpcError(payload)) => ("rpc_error", rpc_error_to_json(payload)),
        None => return Err(KernelError::new("envelope body is required")),
    };

    let mut object = Map::new();
    object.insert("type".into(), Value::from(body_type));
    object.insert(body_type.into(), payload?);

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
            "inputs",
            Value::Array(
                payload
                    .inputs
                    .iter()
                    .map(actor_input_to_json)
                    .collect::<KernelResult<Vec<_>>>()?,
            ),
        ),
        (
            "model_ref",
            turn_model_ref_to_json(payload.model_ref.as_ref())?,
        ),
    ]))
}

fn mailbox_updated_to_json(payload: &proto::MailboxUpdated) -> KernelResult<Value> {
    Ok(json_object([
        ("actor", actor_key_to_json(payload.actor.as_ref())?),
        (
            "activation_uid",
            Value::from(payload.activation_uid.clone()),
        ),
        ("actor_epoch", Value::from(payload.actor_epoch)),
        ("reason", Value::from(payload.reason.clone())),
        ("turn", turn_ref_to_json(payload.turn.as_ref())?),
        (
            "inputs",
            Value::Array(
                payload
                    .inputs
                    .iter()
                    .map(actor_input_to_json)
                    .collect::<KernelResult<Vec<_>>>()?,
            ),
        ),
    ]))
}

fn turn_accepted_to_json(payload: &proto::TurnAccepted) -> KernelResult<Value> {
    Ok(json_object([
        ("turn", turn_ref_to_json(payload.turn.as_ref())?),
        (
            "accepted_actor_input_ids",
            string_array(&payload.accepted_actor_input_ids),
        ),
    ]))
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

fn turn_final_proposal_to_json(payload: &proto::TurnFinalProposal) -> KernelResult<Value> {
    Ok(json_object([
        ("turn", turn_ref_to_json(payload.turn.as_ref())?),
        (
            "messages",
            Value::Array(
                payload
                    .messages
                    .iter()
                    .map(proposed_message_to_json)
                    .collect::<KernelResult<Vec<_>>>()?,
            ),
        ),
        ("reply", proposed_reply_to_json(payload.reply.as_ref())?),
        ("usage_json", bytes_to_json(&payload.usage_json)?),
        (
            "provider_metadata_json",
            bytes_to_json(&payload.provider_metadata_json)?,
        ),
        ("stop_reason", Value::from(payload.stop_reason.clone())),
        (
            "tool_results_json",
            bytes_to_json(&payload.tool_results_json)?,
        ),
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

fn control_shutdown_to_json(payload: &proto::ControlShutdown) -> KernelResult<Value> {
    Ok(json_object([(
        "reason",
        Value::from(payload.reason.clone()),
    )]))
}

fn rpc_request_to_json(payload: &proto::RpcRequest) -> KernelResult<Value> {
    Ok(json_object([
        ("request_id", Value::from(payload.request_id.clone())),
        ("method", Value::from(payload.method.clone())),
        ("deadline_unix_ms", Value::from(payload.deadline_unix_ms)),
        ("payload_json", bytes_to_json(&payload.payload_json)?),
    ]))
}

fn rpc_response_to_json(payload: &proto::RpcResponse) -> KernelResult<Value> {
    Ok(json_object([
        ("request_id", Value::from(payload.request_id.clone())),
        ("payload_json", bytes_to_json(&payload.payload_json)?),
    ]))
}

fn rpc_error_to_json(payload: &proto::RpcError) -> KernelResult<Value> {
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
        ("llm_turn_id", Value::from(turn.llm_turn_id.clone())),
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
        ])),
        None => Ok(Value::Null),
    }
}

fn actor_input_to_json(input: &proto::ActorInputEnvelope) -> KernelResult<Value> {
    Ok(json_object([
        ("actor_input_id", Value::from(input.actor_input_id.clone())),
        (
            "live_queue_sequence",
            Value::from(input.live_queue_sequence),
        ),
        ("type", Value::from(input.r#type.clone())),
        (
            "ingress_event_id",
            Value::from(input.ingress_event_id.clone()),
        ),
        (
            "provider_entry_id",
            Value::from(input.provider_entry_id.clone()),
        ),
        ("payload_json", bytes_to_json(&input.payload_json)?),
    ]))
}

fn proposed_message_to_json(message: &proto::ProposedMessage) -> KernelResult<Value> {
    Ok(json_object([
        ("role", Value::from(message.role.clone())),
        ("content_json", bytes_to_json(&message.content_json)?),
        ("metadata_json", bytes_to_json(&message.metadata_json)?),
    ]))
}

fn proposed_reply_to_json(reply: Option<&proto::ProposedReply>) -> KernelResult<Value> {
    match reply {
        Some(reply) => Ok(json_object([
            ("text", Value::from(reply.text.clone())),
            ("content_json", bytes_to_json(&reply.content_json)?),
            (
                "attachments",
                Value::Array(
                    reply
                        .attachments
                        .iter()
                        .map(proposed_reply_attachment_to_json)
                        .collect::<KernelResult<Vec<_>>>()?,
                ),
            ),
        ])),
        None => Ok(Value::Null),
    }
}

fn proposed_reply_attachment_to_json(
    attachment: &proto::ProposedReplyAttachment,
) -> KernelResult<Value> {
    let mut object = Map::new();
    object.insert(
        "agent_computer_path".into(),
        Value::from(attachment.agent_computer_path.clone()),
    );
    object.insert(
        "user_files_relative_path".into(),
        Value::from(attachment.user_files_relative_path.clone()),
    );

    if !attachment.name.is_empty() {
        object.insert("name".into(), Value::from(attachment.name.clone()));
    }

    if !attachment.mime_type.is_empty() {
        object.insert(
            "mime_type".into(),
            Value::from(attachment.mime_type.clone()),
        );
    }

    if let Some(size) = attachment.size {
        object.insert("size".into(), Value::from(size));
    }

    if !attachment.xxh3_128.is_empty() {
        object.insert("xxh3_128".into(), Value::from(attachment.xxh3_128.clone()));
    }

    Ok(Value::Object(object))
}
