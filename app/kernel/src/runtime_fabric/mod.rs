//! Runtime Fabric v1 protobuf envelope helpers.
//!
//! The host APIs pass JSON-shaped envelope maps, but this module owns the
//! protocol validation and protobuf bytes. That keeps Elixir and Bun bindings
//! thin while avoiding a second JSON wire protocol.

use prost::Message;
use serde_json::{Map, Value};

use crate::common::{KernelError, KernelResult};

pub mod proto {
    include!(concat!(env!("OUT_DIR"), "/ankole.runtime_fabric.v1.rs"));
}

pub mod transport;

const PROTOCOL_VERSION: u32 = 1;

/// Encodes a JSON-shaped Runtime Fabric envelope as protobuf bytes.
///
/// Hosts use JSON maps because both Elixir and Bun can build them cheaply. The
/// kernel still owns protobuf encoding and semantic validation so all hosts see
/// the same protocol errors.
pub fn encode_envelope_json(envelope: Value) -> KernelResult<Vec<u8>> {
    let envelope = envelope_from_json(&envelope)?;
    validate_envelope(&envelope)?;

    let mut bytes = Vec::with_capacity(envelope.encoded_len());
    envelope.encode(&mut bytes).map_err(|error| {
        KernelError::new(format!("failed to encode runtime fabric envelope: {error}"))
    })?;

    Ok(bytes)
}

/// Decodes protobuf bytes into the stable JSON-shaped host representation.
///
/// The returned JSON shape matches the control-plane envelope contract, not the
/// generated prost structs. That keeps native bindings thin and avoids leaking
/// Rust-specific protobuf details into Elixir or Bun code.
pub fn decode_envelope_json(bytes: &[u8]) -> KernelResult<Value> {
    let envelope = proto::Envelope::decode(bytes).map_err(|error| {
        KernelError::new(format!("failed to decode runtime fabric envelope: {error}"))
    })?;
    validate_envelope(&envelope)?;

    envelope_to_json(&envelope)
}

fn envelope_from_json(value: &Value) -> KernelResult<proto::Envelope> {
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

// Validates protocol invariants that must be identical for Elixir and Bun
// callers. Host code should not need to duplicate lane, durability, or
// correlation rules.
fn validate_envelope(envelope: &proto::Envelope) -> KernelResult<()> {
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

#[derive(Clone, Copy)]
struct BodySpec {
    name: &'static str,
    lane: proto::Lane,
    durability: proto::DurabilityClass,
    requires_correlation_id: bool,
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

fn body_spec(body: &proto::envelope::Body) -> BodySpec {
    // Exhaustive on purpose: a new body variant must force a lane, durability,
    // and correlation decision instead of inheriting defaults.
    match body {
        proto::envelope::Body::WorkerReady(_) => BodySpec {
            name: "worker_ready",
            lane: proto::Lane::Control,
            durability: proto::DurabilityClass::ControlEphemeral,
            requires_correlation_id: false,
        },
        proto::envelope::Body::WorkerHeartbeat(_) => BodySpec {
            name: "worker_heartbeat",
            lane: proto::Lane::Control,
            durability: proto::DurabilityClass::ControlEphemeral,
            requires_correlation_id: false,
        },
        proto::envelope::Body::WorkerCapacity(_) => BodySpec {
            name: "worker_capacity",
            lane: proto::Lane::Control,
            durability: proto::DurabilityClass::ControlEphemeral,
            requires_correlation_id: false,
        },
        proto::envelope::Body::TurnStart(_) => BodySpec {
            name: "turn_start",
            lane: proto::Lane::Turn,
            durability: proto::DurabilityClass::ControlReplayable,
            requires_correlation_id: true,
        },
        proto::envelope::Body::MailboxUpdated(_) => BodySpec {
            name: "mailbox_updated",
            lane: proto::Lane::Turn,
            durability: proto::DurabilityClass::ControlEphemeral,
            requires_correlation_id: true,
        },
        proto::envelope::Body::TurnAccepted(_) => BodySpec {
            name: "turn_accepted",
            lane: proto::Lane::Turn,
            durability: proto::DurabilityClass::ControlReplayable,
            requires_correlation_id: true,
        },
        proto::envelope::Body::TurnControl(_) => BodySpec {
            name: "turn_control",
            lane: proto::Lane::Control,
            durability: proto::DurabilityClass::ControlDurable,
            requires_correlation_id: true,
        },
        proto::envelope::Body::WorkerProgress(_) => BodySpec {
            name: "worker_progress",
            lane: proto::Lane::Progress,
            durability: proto::DurabilityClass::ControlEphemeral,
            requires_correlation_id: true,
        },
        proto::envelope::Body::TurnFinalProposal(_) => BodySpec {
            name: "turn_final_proposal",
            lane: proto::Lane::Turn,
            durability: proto::DurabilityClass::ControlDurable,
            requires_correlation_id: true,
        },
        proto::envelope::Body::TurnError(_) => BodySpec {
            name: "turn_error",
            lane: proto::Lane::Turn,
            durability: proto::DurabilityClass::ControlReplayable,
            requires_correlation_id: true,
        },
        proto::envelope::Body::ControlShutdown(_) => BodySpec {
            name: "control_shutdown",
            lane: proto::Lane::Control,
            durability: proto::DurabilityClass::ControlEphemeral,
            requires_correlation_id: false,
        },
        proto::envelope::Body::RpcRequest(_) => BodySpec {
            name: "rpc_request",
            lane: proto::Lane::Rpc,
            durability: proto::DurabilityClass::ControlEphemeral,
            requires_correlation_id: true,
        },
        proto::envelope::Body::RpcResponse(_) => BodySpec {
            name: "rpc_response",
            lane: proto::Lane::Rpc,
            durability: proto::DurabilityClass::ControlEphemeral,
            requires_correlation_id: true,
        },
        proto::envelope::Body::RpcError(_) => BodySpec {
            name: "rpc_error",
            lane: proto::Lane::Rpc,
            durability: proto::DurabilityClass::ControlEphemeral,
            requires_correlation_id: true,
        },
    }
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
            validate_actor_inputs(&payload.inputs, "turn_start.inputs")?;
            validate_optional_model_ref(payload.model_ref.as_ref(), "turn_start.model_ref")
        }
        proto::envelope::Body::MailboxUpdated(payload) => {
            validate_actor_key(payload.actor.as_ref(), "mailbox_updated.actor")?;
            require_non_empty(&payload.activation_uid, "mailbox_updated.activation_uid")?;
            require_positive_u64(payload.actor_epoch, "mailbox_updated.actor_epoch")?;
            let turn = validate_turn_ref(payload.turn.as_ref(), "mailbox_updated.turn")?;
            validate_mailbox_turn_mirror(payload, turn)?;
            validate_actor_inputs(&payload.inputs, "mailbox_updated.inputs")
        }
        proto::envelope::Body::TurnAccepted(payload) => {
            validate_turn_ref(payload.turn.as_ref(), "turn_accepted.turn")?;
            validate_non_empty_strings(
                &payload.accepted_actor_input_ids,
                "turn_accepted.accepted_actor_input_ids",
            )
        }
        proto::envelope::Body::TurnControl(payload) => {
            validate_turn_ref(payload.turn.as_ref(), "turn_control.turn")?;
            require_non_empty(&payload.command, "turn_control.command")
        }
        proto::envelope::Body::WorkerProgress(payload) => {
            validate_turn_ref(payload.turn.as_ref(), "worker_progress.turn")?;
            require_non_empty(&payload.kind, "worker_progress.kind")
        }
        proto::envelope::Body::TurnFinalProposal(payload) => {
            validate_turn_ref(payload.turn.as_ref(), "turn_final_proposal.turn")?;
            for (index, message) in payload.messages.iter().enumerate() {
                require_non_empty(
                    &message.role,
                    &format!("turn_final_proposal.messages[{index}].role"),
                )?;
            }
            validate_proposed_reply(payload.reply.as_ref(), "turn_final_proposal.reply")
        }
        proto::envelope::Body::TurnError(payload) => {
            validate_turn_ref(payload.turn.as_ref(), "turn_error.turn")?;
            require_non_empty(&payload.code, "turn_error.code")
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

fn validate_actor_inputs(inputs: &[proto::ActorInputEnvelope], field: &str) -> KernelResult<()> {
    for (index, input) in inputs.iter().enumerate() {
        require_non_empty(
            &input.actor_input_id,
            &format!("{field}[{index}].actor_input_id"),
        )?;
        require_positive_u64(
            input.live_queue_sequence,
            &format!("{field}[{index}].live_queue_sequence"),
        )?;
        require_non_empty(&input.r#type, &format!("{field}[{index}].type"))?;
        require_non_empty(
            &input.ingress_event_id,
            &format!("{field}[{index}].ingress_event_id"),
        )?;
    }

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
    require_non_empty(&turn.llm_turn_id, &format!("{field}.llm_turn_id"))?;
    Ok(turn)
}

fn validate_actor_key(actor: Option<&proto::ActorKey>, field: &str) -> KernelResult<()> {
    let actor = actor.ok_or_else(|| KernelError::new(format!("{field} is required")))?;
    require_non_empty(&actor.agent_uid, &format!("{field}.agent_uid"))?;
    require_non_empty(&actor.session_id, &format!("{field}.session_id"))
}

fn validate_mailbox_turn_mirror(
    mailbox: &proto::MailboxUpdated,
    turn: &proto::ActorTurnRef,
) -> KernelResult<()> {
    if mailbox.actor.as_ref() != turn.actor.as_ref() {
        return Err(KernelError::new(
            "mailbox_updated actor must match mailbox_updated.turn.actor",
        ));
    }

    if mailbox.activation_uid != turn.activation_uid {
        return Err(KernelError::new(
            "mailbox_updated activation_uid must match mailbox_updated.turn.activation_uid",
        ));
    }

    if mailbox.actor_epoch != turn.actor_epoch {
        return Err(KernelError::new(
            "mailbox_updated actor_epoch must match mailbox_updated.turn.actor_epoch",
        ));
    }

    Ok(())
}

fn validate_optional_model_ref(
    model_ref: Option<&proto::TurnModelRef>,
    field: &str,
) -> KernelResult<()> {
    if let Some(model_ref) = model_ref {
        require_non_empty(&model_ref.profile, &format!("{field}.profile"))?;
        require_non_empty(&model_ref.provider_id, &format!("{field}.provider_id"))?;
        require_non_empty(&model_ref.model, &format!("{field}.model"))?;
    }

    Ok(())
}

fn validate_proposed_reply(reply: Option<&proto::ProposedReply>, field: &str) -> KernelResult<()> {
    let reply = reply.ok_or_else(|| KernelError::new(format!("{field} is required")))?;
    require_non_empty(&reply.text, &format!("{field}.text"))?;

    for (index, attachment) in reply.attachments.iter().enumerate() {
        validate_proposed_reply_attachment(attachment, &format!("{field}.attachments[{index}]"))?;
    }

    Ok(())
}

fn validate_proposed_reply_attachment(
    attachment: &proto::ProposedReplyAttachment,
    field: &str,
) -> KernelResult<()> {
    if attachment.agent_computer_path.trim().is_empty()
        && attachment.user_files_relative_path.trim().is_empty()
    {
        return Err(KernelError::new(format!(
            "{field} must include agent_computer_path or user_files_relative_path"
        )));
    }

    Ok(())
}

fn validate_non_empty_strings(values: &[String], field: &str) -> KernelResult<()> {
    for (index, value) in values.iter().enumerate() {
        require_non_empty(value, &format!("{field}[{index}]"))?;
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

// Steering must be journaled as actor input instead of hidden in a turn-control
// payload. That preserves the user-visible input stream as the replay source.
fn validate_turn_control(control: &proto::TurnControl) -> KernelResult<()> {
    if control.command == "steer" && !empty_json_payload(&control.payload_json) {
        return Err(KernelError::new(
            "turn_control steer payload must be empty and journaled as actor input",
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

fn empty_json_payload(bytes: &[u8]) -> bool {
    bytes.is_empty() || bytes == b"{}" || bytes == b"null"
}

fn lane_name(lane: proto::Lane) -> &'static str {
    match lane {
        proto::Lane::Control => "LANE_CONTROL",
        proto::Lane::Turn => "LANE_TURN",
        proto::Lane::Progress => "LANE_PROGRESS",
        proto::Lane::Rpc => "LANE_RPC",
        proto::Lane::Unspecified => "LANE_UNSPECIFIED",
    }
}

fn durability_name(durability: proto::DurabilityClass) -> &'static str {
    match durability {
        proto::DurabilityClass::ControlDurable => "CONTROL_DURABLE",
        proto::DurabilityClass::ControlReplayable => "CONTROL_REPLAYABLE",
        proto::DurabilityClass::ControlEphemeral => "CONTROL_EPHEMERAL",
        proto::DurabilityClass::DurabilityUnspecified => "DURABILITY_UNSPECIFIED",
    }
}

// Converts prost structs back to the canonical host JSON shape. The nested
// `body.type` form keeps dispatch simple in Elixir and TypeScript.
fn envelope_to_json(envelope: &proto::Envelope) -> KernelResult<Value> {
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

fn lane_from_json(value: &Value) -> KernelResult<proto::Lane> {
    match normalized_enum(value)?.as_str() {
        "lane_control" | "control" => Ok(proto::Lane::Control),
        "lane_turn" | "turn" => Ok(proto::Lane::Turn),
        "lane_progress" | "progress" => Ok(proto::Lane::Progress),
        "lane_rpc" | "rpc" => Ok(proto::Lane::Rpc),
        other => Err(KernelError::new(format!("unsupported lane: {other}"))),
    }
}

fn durability_from_json(value: &Value) -> KernelResult<proto::DurabilityClass> {
    match normalized_enum(value)?.as_str() {
        "control_durable" | "durable" => Ok(proto::DurabilityClass::ControlDurable),
        "control_replayable" | "replayable" => Ok(proto::DurabilityClass::ControlReplayable),
        "control_ephemeral" | "ephemeral" => Ok(proto::DurabilityClass::ControlEphemeral),
        other => Err(KernelError::new(format!("unsupported durability: {other}"))),
    }
}

fn lane_to_json(lane: i32) -> KernelResult<String> {
    match proto::Lane::try_from(lane).unwrap_or(proto::Lane::Unspecified) {
        proto::Lane::Unspecified => Err(KernelError::new("lane must be specified")),
        lane => Ok(lane_name(lane).to_string()),
    }
}

fn durability_to_json(durability: i32) -> KernelResult<String> {
    match proto::DurabilityClass::try_from(durability)
        .unwrap_or(proto::DurabilityClass::DurabilityUnspecified)
    {
        proto::DurabilityClass::DurabilityUnspecified => {
            Err(KernelError::new("durability must be specified"))
        }
        durability => Ok(durability_name(durability).to_string()),
    }
}

fn object<'a>(value: &'a Value, field: &str) -> KernelResult<&'a Map<String, Value>> {
    match value {
        Value::Object(object) => Ok(object),
        _value => Err(KernelError::new(format!("{field} must be an object"))),
    }
}

fn required_value<'a>(object: &'a Map<String, Value>, field: &str) -> KernelResult<&'a Value> {
    object
        .get(field)
        .ok_or_else(|| KernelError::new(format!("{field} is required")))
}

fn required_string(object: &Map<String, Value>, field: &str) -> KernelResult<String> {
    match required_value(object, field)? {
        Value::String(value) if !value.trim().is_empty() => Ok(value.clone()),
        _value => Err(KernelError::new(format!(
            "{field} must be a non-empty string"
        ))),
    }
}

fn optional_string(object: &Map<String, Value>, field: &str) -> KernelResult<Option<String>> {
    match object.get(field) {
        Some(Value::String(value)) => Ok(Some(value.clone())),
        Some(Value::Null) | None => Ok(None),
        Some(_value) => Err(KernelError::new(format!("{field} must be a string"))),
    }
}

fn required_u64(object: &Map<String, Value>, field: &str) -> KernelResult<u64> {
    optional_u64(object, field)?.ok_or_else(|| KernelError::new(format!("{field} is required")))
}

fn optional_u64(object: &Map<String, Value>, field: &str) -> KernelResult<Option<u64>> {
    match object.get(field) {
        Some(Value::Number(value)) => number_to_u64(value, field).map(Some),
        Some(Value::Null) | None => Ok(None),
        Some(_value) => Err(KernelError::new(format!(
            "{field} must be an unsigned integer"
        ))),
    }
}

fn required_u32(object: &Map<String, Value>, field: &str) -> KernelResult<u32> {
    let value = required_u64(object, field)?;

    u32::try_from(value).map_err(|_| KernelError::new(format!("{field} is outside u32 range")))
}

fn optional_u32(object: &Map<String, Value>, field: &str) -> KernelResult<Option<u32>> {
    optional_u64(object, field)?
        .map(|value| {
            u32::try_from(value)
                .map_err(|_| KernelError::new(format!("{field} is outside u32 range")))
        })
        .transpose()
}

fn optional_i64(object: &Map<String, Value>, field: &str) -> KernelResult<Option<i64>> {
    match object.get(field) {
        Some(Value::Number(value)) => number_to_i64(value, field).map(Some),
        Some(Value::Null) | None => Ok(None),
        Some(_value) => Err(KernelError::new(format!("{field} must be an integer"))),
    }
}

fn number_to_u64(value: &serde_json::Number, field: &str) -> KernelResult<u64> {
    if let Some(value) = value.as_u64() {
        return Ok(value);
    }

    match value.as_f64() {
        Some(value)
            if value.is_finite()
                && value.fract() == 0.0
                && value >= 0.0
                && value <= u64::MAX as f64 =>
        {
            Ok(value as u64)
        }
        _value => Err(KernelError::new(format!(
            "{field} must be an unsigned integer"
        ))),
    }
}

fn number_to_i64(value: &serde_json::Number, field: &str) -> KernelResult<i64> {
    if let Some(value) = value.as_i64() {
        return Ok(value);
    }

    match value.as_f64() {
        Some(value)
            if value.is_finite()
                && value.fract() == 0.0
                && value >= i64::MIN as f64
                && value <= i64::MAX as f64 =>
        {
            Ok(value as i64)
        }
        _value => Err(KernelError::new(format!("{field} must be an integer"))),
    }
}

fn string_list(value: Option<&Value>) -> KernelResult<Vec<String>> {
    array(value, "string array")?
        .into_iter()
        .map(|value| match value {
            Value::String(text) => Ok(text.clone()),
            _value => Err(KernelError::new("array values must be strings")),
        })
        .collect()
}

fn array<'a>(value: Option<&'a Value>, field: &str) -> KernelResult<Vec<&'a Value>> {
    match value {
        Some(Value::Array(values)) => Ok(values.iter().collect()),
        Some(Value::Null) | None => Ok(Vec::new()),
        Some(_value) => Err(KernelError::new(format!("{field} must be an array"))),
    }
}

fn optional_message<T>(
    value: Option<&Value>,
    parser: fn(&Value) -> KernelResult<T>,
) -> KernelResult<Option<T>> {
    match value {
        Some(Value::Null) | None => Ok(None),
        Some(value) => parser(value).map(Some),
    }
}

// Stores arbitrary JSON payload fields as bytes inside protobuf messages. This
// keeps the protocol typed where it matters and flexible for provider-specific
// payloads that the kernel should not understand.
fn json_bytes(value: Option<&Value>) -> KernelResult<Option<Vec<u8>>> {
    match value {
        Some(Value::Null) | None => Ok(None),
        Some(value) => serde_json::to_vec(value)
            .map(Some)
            .map_err(|error| KernelError::new(format!("failed to encode JSON bytes: {error}"))),
    }
}

// Decodes JSON payload bytes when possible and falls back to a string for
// legacy or debugging payloads that are not valid JSON.
fn bytes_to_json(bytes: &[u8]) -> KernelResult<Value> {
    if bytes.is_empty() {
        return Ok(Value::Null);
    }

    match serde_json::from_slice(bytes) {
        Ok(value) => Ok(value),
        Err(_error) => Ok(Value::String(String::from_utf8_lossy(bytes).to_string())),
    }
}

fn normalized_enum(value: &Value) -> KernelResult<String> {
    match value {
        Value::String(text) => Ok(normalized_name(text)),
        _value => Err(KernelError::new("enum value must be a string")),
    }
}

// Normalizes enum-like input from both generated names and human-friendly names
// without accepting arbitrary body types.
fn normalized_name(value: &str) -> String {
    value.trim().to_ascii_lowercase().replace('-', "_")
}

fn json_object<const N: usize>(entries: [(&str, Value); N]) -> Value {
    Value::Object(
        entries
            .into_iter()
            .map(|(key, value)| (key.to_string(), value))
            .collect(),
    )
}

fn string_array(values: &[String]) -> Value {
    Value::Array(
        values
            .iter()
            .map(|value| Value::from(value.clone()))
            .collect(),
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn round_trips_turn_start() {
        let envelope = json!({
            "protocol_version": 1,
            "message_id": "msg-1",
            "correlation_id": "corr-1",
            "lane": "LANE_TURN",
            "sent_at_unix_ms": 1782300000000_i64,
            "durability": "CONTROL_REPLAYABLE",
            "body": {
                "type": "turn_start",
                "turn_start": {
                    "turn": turn_ref(),
                    "inputs": [{
                        "actor_input_id": "input-1",
                        "live_queue_sequence": 1,
                        "type": "im.message.addressed",
                        "ingress_event_id": "event-1",
                        "provider_entry_id": "msg-1",
                        "payload_json": {"text": "PING"}
                    }]
                }
            }
        });

        let encoded = encode_envelope_json(envelope).unwrap();
        let decoded = decode_envelope_json(&encoded).unwrap();

        assert_eq!(decoded["body"]["type"], "turn_start");
        assert_eq!(
            decoded["body"]["turn_start"]["inputs"][0]["payload_json"]["text"],
            "PING"
        );
    }

    #[test]
    fn round_trips_mailbox_updated_with_turn_inputs() {
        let envelope = json!({
            "protocol_version": 1,
            "message_id": "mailbox-updated-1",
            "correlation_id": "mailbox-updated-1",
            "lane": "LANE_TURN",
            "durability": "CONTROL_EPHEMERAL",
            "body": {
                "type": "mailbox_updated",
                "mailbox_updated": {
                    "turn": turn_ref(),
                    "inputs": [{
                        "actor_input_id": "steer-1",
                        "live_queue_sequence": 2,
                        "type": "command.steer",
                        "ingress_event_id": "event-steer-1",
                        "payload_json": {"data": {"command": {"argsText": "change course"}}}
                    }],
                    "reason": "command.steer"
                }
            }
        });

        let encoded = encode_envelope_json(envelope).unwrap();
        let decoded = decode_envelope_json(&encoded).unwrap();

        assert_eq!(decoded["body"]["type"], "mailbox_updated");
        assert_eq!(
            decoded["body"]["mailbox_updated"]["turn"]["llm_turn_id"],
            "11111111-1111-1111-1111-111111111111"
        );
        assert_eq!(
            decoded["body"]["mailbox_updated"]["inputs"][0]["payload_json"]["data"]["command"]["argsText"],
            "change course"
        );
    }

    #[test]
    fn round_trips_turn_final_proposal_telemetry() {
        let envelope = json!({
            "protocol_version": 1,
            "message_id": "turn-final-1",
            "correlation_id": "turn-start-1",
            "lane": "LANE_TURN",
            "durability": "CONTROL_DURABLE",
            "body": {
                "type": "turn_final_proposal",
                "turn_final_proposal": {
                    "turn": turn_ref(),
                    "messages": [],
                    "reply": {
                        "text": "done",
                        "attachments": [{
                            "agent_computer_path": "/workspace/user-files/reports/a.txt",
                            "user_files_relative_path": "reports/a.txt",
                            "name": "report.txt",
                            "mime_type": "text/plain",
                            "size": 16,
                            "xxh3_128": "abc123"
                        }]
                    },
                    "usage_json": {
                        "input": 11,
                        "output": 7,
                        "totalTokens": 18
                    },
                    "provider_metadata_json": {
                        "response_id": "resp_123",
                        "response_model": "google/gemini-3.5-flash"
                    },
                    "stop_reason": "stop",
                    "tool_results_json": [{
                        "tool_call_id": "call_1",
                        "tool_name": "command",
                        "is_error": false
                    }]
                }
            }
        });

        let encoded = encode_envelope_json(envelope).unwrap();
        let decoded = decode_envelope_json(&encoded).unwrap();
        let proposal = &decoded["body"]["turn_final_proposal"];

        assert_eq!(decoded["body"]["type"], "turn_final_proposal");
        assert_eq!(proposal["usage_json"]["input"], 11);
        assert_eq!(proposal["usage_json"]["totalTokens"], 18);
        assert_eq!(
            proposal["provider_metadata_json"]["response_id"],
            "resp_123"
        );
        assert_eq!(proposal["stop_reason"], "stop");
        assert_eq!(proposal["tool_results_json"][0]["tool_name"], "command");
        assert_eq!(
            proposal["reply"]["attachments"][0]["user_files_relative_path"],
            "reports/a.txt"
        );
        assert_eq!(proposal["reply"]["attachments"][0]["size"], 16);
    }

    #[test]
    fn json_byte_fields_preserve_json_strings() {
        let envelope = json!({
            "protocol_version": 1,
            "message_id": "msg-1",
            "correlation_id": "corr-1",
            "lane": "LANE_TURN",
            "sent_at_unix_ms": 1782300000000_i64,
            "durability": "CONTROL_REPLAYABLE",
            "body": {
                "type": "turn_start",
                "turn_start": {
                    "turn": turn_ref(),
                    "inputs": [{
                        "actor_input_id": "input-1",
                        "live_queue_sequence": 1,
                        "type": "im.message.addressed",
                        "ingress_event_id": "event-1",
                        "payload_json": "null"
                    }]
                }
            }
        });

        let encoded = encode_envelope_json(envelope).unwrap();
        let decoded = decode_envelope_json(&encoded).unwrap();

        assert_eq!(
            decoded["body"]["turn_start"]["inputs"][0]["payload_json"],
            "null"
        );
    }

    #[test]
    fn rejects_steer_with_inline_payload() {
        let envelope = json!({
            "protocol_version": 1,
            "message_id": "msg-1",
            "correlation_id": "steer-1",
            "lane": "LANE_CONTROL",
            "durability": "CONTROL_DURABLE",
            "body": {
                "type": "turn_control",
                "turn_control": {
                    "turn": turn_ref(),
                    "command": "steer",
                    "payload_json": {"text": "do not inline"}
                }
            }
        });

        let error = encode_envelope_json(envelope).unwrap_err().to_string();

        assert!(error.contains("steer payload must be empty"));
    }

    #[test]
    fn rejects_turn_start_with_wrong_lane_or_durability() {
        let envelope = json!({
            "protocol_version": 1,
            "message_id": "msg-1",
            "lane": "LANE_CONTROL",
            "durability": "CONTROL_EPHEMERAL",
            "body": {
                "type": "turn_start",
                "turn_start": {
                    "turn": turn_ref(),
                    "inputs": [{
                        "actor_input_id": "input-1",
                        "live_queue_sequence": 1,
                        "type": "im.message.addressed",
                        "ingress_event_id": "event-1"
                    }]
                }
            }
        });

        let error = encode_envelope_json(envelope).unwrap_err().to_string();

        assert!(error.contains("turn_start must use lane LANE_TURN"));
    }

    #[test]
    fn rejects_worker_progress_internal_event_kinds() {
        let envelope = json!({
            "protocol_version": 1,
            "message_id": "progress-1",
            "correlation_id": "progress-1",
            "lane": "LANE_PROGRESS",
            "durability": "CONTROL_EPHEMERAL",
            "body": {
                "type": "worker_progress",
                "worker_progress": {
                    "turn": turn_ref(),
                    "kind": "tool_call_chunk",
                    "summary": "internal AI SDK stream chunk"
                }
            }
        });

        let error = encode_envelope_json(envelope).unwrap_err().to_string();

        assert!(error.contains("worker_progress kind"));
    }

    #[test]
    fn rejects_actor_key_profile_fields() {
        let mut turn = turn_ref();
        turn["actor"]["display_name"] = json!("ReleaseBot");

        let envelope = json!({
            "protocol_version": 1,
            "message_id": "turn-start-1",
            "correlation_id": "turn-start-1",
            "lane": "LANE_TURN",
            "durability": "CONTROL_REPLAYABLE",
            "body": {
                "type": "turn_start",
                "turn_start": {
                    "turn": turn,
                    "inputs": []
                }
            }
        });

        let error = encode_envelope_json(envelope).unwrap_err().to_string();

        assert!(error.contains("ActorKey must not carry display_name"));
    }

    #[test]
    fn round_trips_rpc_request() {
        let envelope = json!({
            "protocol_version": 1,
            "message_id": "rpc-conversation-context-1",
            "correlation_id": "rpc-conversation-context-1",
            "lane": "LANE_RPC",
            "durability": "CONTROL_EPHEMERAL",
            "body": {
                "type": "rpc_request",
                "rpc_request": {
                    "request_id": "rpc-conversation-context-1",
                    "method": "agent_conversation.context.resolve",
                    "deadline_unix_ms": 1782300001000_i64,
                    "payload_json": {
                        "turn": {
                            "actor": {
                                "agent_uid": "agent-1",
                                "session_id": "signal-channel:lark:dm:1"
                            }
                        }
                    }
                }
            }
        });

        let encoded = encode_envelope_json(envelope).unwrap();
        let decoded = decode_envelope_json(&encoded).unwrap();

        assert_eq!(decoded["body"]["type"], "rpc_request");
        assert_eq!(
            decoded["body"]["rpc_request"]["method"],
            "agent_conversation.context.resolve"
        );
        assert_eq!(
            decoded["body"]["rpc_request"]["payload_json"]["turn"]["actor"]["agent_uid"],
            "agent-1"
        );
    }

    #[test]
    fn rejects_rpc_correlation_mismatch() {
        let envelope = json!({
            "protocol_version": 1,
            "message_id": "rpc-1",
            "correlation_id": "other",
            "lane": "LANE_RPC",
            "durability": "CONTROL_EPHEMERAL",
            "body": {
                "type": "rpc_response",
                "rpc_response": {
                    "request_id": "rpc-1",
                    "payload_json": {"ok": true}
                }
            }
        });

        let error = encode_envelope_json(envelope).unwrap_err().to_string();

        assert!(error.contains("correlation_id must equal request_id"));
    }

    #[test]
    fn worker_ready_does_not_require_actor_fields() {
        let envelope = json!({
            "protocol_version": 1,
            "message_id": "ready-1",
            "lane": "LANE_CONTROL",
            "durability": "CONTROL_EPHEMERAL",
            "body": {
                "type": "worker_ready",
                "worker_ready": {
                    "worker_id": "worker-a",
                    "runtime": "bun",
                    "version": "0.1.0",
                    "capacity_json": {"turn_slots": 2}
                }
            }
        });

        let encoded = encode_envelope_json(envelope).unwrap();
        let decoded = decode_envelope_json(&encoded).unwrap();

        assert_eq!(decoded["body"]["type"], "worker_ready");
        assert!(
            decoded["body"]["worker_ready"]
                .get("capabilities")
                .is_none()
        );
    }

    #[test]
    fn rejects_top_level_body_shape() {
        let envelope = json!({
            "protocol_version": 1,
            "message_id": "ready-1",
            "lane": "LANE_CONTROL",
            "durability": "CONTROL_EPHEMERAL",
            "worker_ready": {
                "worker_id": "worker-a",
                "runtime": "bun",
                "version": "0.1.0"
            }
        });

        let error = encode_envelope_json(envelope).unwrap_err().to_string();

        assert!(error.contains("envelope body is required"));
    }

    #[test]
    fn rejects_decoded_protobuf_missing_required_nested_fields() {
        let heartbeat = proto::Envelope {
            protocol_version: 1,
            message_id: "heartbeat-1".into(),
            correlation_id: String::new(),
            lane: proto::Lane::Control as i32,
            sent_at_unix_ms: 0,
            durability: proto::DurabilityClass::ControlEphemeral as i32,
            body: Some(proto::envelope::Body::WorkerHeartbeat(
                proto::AgentComputerWorkerHeartbeat::default(),
            )),
        };
        let mut bytes = Vec::new();
        heartbeat.encode(&mut bytes).unwrap();

        let error = decode_envelope_json(&bytes).unwrap_err().to_string();

        assert!(error.contains("worker_heartbeat.worker_id is required"));

        let rpc_request = proto::Envelope {
            protocol_version: 1,
            message_id: "rpc-1".into(),
            correlation_id: "rpc-1".into(),
            lane: proto::Lane::Rpc as i32,
            sent_at_unix_ms: 0,
            durability: proto::DurabilityClass::ControlEphemeral as i32,
            body: Some(proto::envelope::Body::RpcRequest(proto::RpcRequest {
                request_id: "rpc-1".into(),
                ..Default::default()
            })),
        };
        let mut bytes = Vec::new();
        rpc_request.encode(&mut bytes).unwrap();

        let error = decode_envelope_json(&bytes).unwrap_err().to_string();

        assert!(error.contains("rpc_request.method is required"));
    }

    fn turn_ref() -> Value {
        json!({
            "actor": {
                "agent_uid": "agent-1",
                "session_id": "signal-channel:lark:dm:1"
            },
            "activation_uid": "activation-1",
            "actor_epoch": 1,
            "llm_turn_id": "11111111-1111-1111-1111-111111111111",
            "revision": 0
        })
    }
}
