//! Actor Bus v1 protobuf envelope helpers.
//!
//! The host APIs pass JSON-shaped envelope maps, but this module owns the
//! protocol validation and protobuf bytes. That keeps Elixir and Bun bindings
//! thin while avoiding a second JSON wire protocol.

use prost::Message;
use serde_json::{Map, Value};

use crate::core::{KernelError, KernelResult};

pub mod proto {
    include!(concat!(env!("OUT_DIR"), "/ankole.actor_bus.v1.rs"));
}

pub mod transport;

const PROTOCOL_VERSION: u32 = 1;

/// Encodes a JSON-shaped Actor Bus envelope as protobuf bytes.
pub fn encode_envelope_json(envelope: Value) -> KernelResult<Vec<u8>> {
    let envelope = envelope_from_json(&envelope)?;
    validate_envelope(&envelope)?;

    let mut bytes = Vec::with_capacity(envelope.encoded_len());
    envelope.encode(&mut bytes).map_err(|error| {
        KernelError::new(format!("failed to encode actor bus envelope: {error}"))
    })?;

    Ok(bytes)
}

/// Decodes protobuf bytes into the stable JSON-shaped host representation.
pub fn decode_envelope_json(bytes: &[u8]) -> KernelResult<Value> {
    let envelope = proto::Envelope::decode(bytes).map_err(|error| {
        KernelError::new(format!("failed to decode actor bus envelope: {error}"))
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
        seq: optional_u64(object, "seq")?.unwrap_or_default(),
        lane: lane_from_json(required_value(object, "lane")?)? as i32,
        sent_at_unix_ms: optional_i64(object, "sent_at_unix_ms")?.unwrap_or_default(),
        durability: durability_from_json(required_value(object, "durability")?)? as i32,
        body: Some(body),
    })
}

fn body_from_json(object: &Map<String, Value>) -> KernelResult<proto::envelope::Body> {
    match object.get("body") {
        Some(Value::Object(body)) => typed_body_from_json(body),
        Some(_value) => Err(KernelError::new("body must be an object")),
        None => top_level_body_from_json(object),
    }
}

fn typed_body_from_json(body: &Map<String, Value>) -> KernelResult<proto::envelope::Body> {
    let body_type = required_string(body, "type")?;
    let payload = required_value(body, &body_type)?;

    named_body_from_json(&body_type, payload)
}

fn top_level_body_from_json(object: &Map<String, Value>) -> KernelResult<proto::envelope::Body> {
    let matches: Vec<(&str, &Value)> = [
        "worker_ready",
        "worker_heartbeat",
        "worker_capacity",
        "turn_start",
        "mailbox_updated",
        "turn_accepted",
        "turn_control",
        "worker_progress",
        "turn_final_proposal",
        "turn_error",
        "control_shutdown",
        "ack",
        "nack",
    ]
    .into_iter()
    .filter_map(|key| object.get(key).map(|value| (key, value)))
    .collect();

    match matches.as_slice() {
        [(name, payload)] => named_body_from_json(name, payload),
        [] => Err(KernelError::new("envelope body is required")),
        _matches => Err(KernelError::new("envelope must contain exactly one body")),
    }
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
        "ack" => Ok(proto::envelope::Body::Ack(ack_from_json(payload)?)),
        "nack" => Ok(proto::envelope::Body::Nack(nack_from_json(payload)?)),
        other => Err(KernelError::new(format!(
            "unsupported actor bus body: {other}"
        ))),
    }
}

fn worker_ready_from_json(value: &Value) -> KernelResult<proto::AgentComputerWorkerReady> {
    let object = object(value, "worker_ready")?;

    Ok(proto::AgentComputerWorkerReady {
        worker_id: required_string(object, "worker_id")?,
        worker_instance_id: required_string(object, "worker_instance_id")?,
        runtime: required_string(object, "runtime")?,
        version: required_string(object, "version")?,
        capacity_json: json_bytes(object.get("capacity_json"))?.unwrap_or_default(),
    })
}

fn worker_heartbeat_from_json(value: &Value) -> KernelResult<proto::AgentComputerWorkerHeartbeat> {
    let object = object(value, "worker_heartbeat")?;

    Ok(proto::AgentComputerWorkerHeartbeat {
        worker_id: required_string(object, "worker_id")?,
        worker_instance_id: required_string(object, "worker_instance_id")?,
        monotonic_ms: optional_i64(object, "monotonic_ms")?.unwrap_or_default(),
        load_json: json_bytes(object.get("load_json"))?.unwrap_or_default(),
    })
}

fn worker_capacity_from_json(value: &Value) -> KernelResult<proto::AgentComputerWorkerCapacity> {
    let object = object(value, "worker_capacity")?;

    Ok(proto::AgentComputerWorkerCapacity {
        worker_id: required_string(object, "worker_id")?,
        worker_instance_id: required_string(object, "worker_instance_id")?,
        capacity_json: json_bytes(object.get("capacity_json"))?.unwrap_or_default(),
        load_json: json_bytes(object.get("load_json"))?.unwrap_or_default(),
        available_turn_slots: optional_u32(object, "available_turn_slots")?.unwrap_or_default(),
    })
}

fn turn_start_from_json(value: &Value) -> KernelResult<proto::TurnStart> {
    let object = object(value, "turn_start")?;

    Ok(proto::TurnStart {
        turn: Some(turn_ref_from_json(required_value(object, "turn")?)?),
        inputs: actor_inputs_from_json(object.get("inputs"))?,
    })
}

fn mailbox_updated_from_json(value: &Value) -> KernelResult<proto::MailboxUpdated> {
    let object = object(value, "mailbox_updated")?;

    Ok(proto::MailboxUpdated {
        actor: Some(actor_key_from_json(required_value(object, "actor")?)?),
        activation_uid: optional_string(object, "activation_uid")?.unwrap_or_default(),
        actor_epoch: optional_u64(object, "actor_epoch")?.unwrap_or_default(),
        reason: optional_string(object, "reason")?.unwrap_or_default(),
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

fn turn_final_proposal_from_json(value: &Value) -> KernelResult<proto::TurnFinalProposal> {
    let object = object(value, "turn_final_proposal")?;

    Ok(proto::TurnFinalProposal {
        turn: Some(turn_ref_from_json(required_value(object, "turn")?)?),
        messages: proposed_messages_from_json(object.get("messages"))?,
        reply: optional_message(object.get("reply"), proposed_reply_from_json)?,
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

fn ack_from_json(value: &Value) -> KernelResult<proto::Ack> {
    let object = object(value, "ack")?;

    Ok(proto::Ack {
        acked_message_id: required_string(object, "acked_message_id")?,
    })
}

fn nack_from_json(value: &Value) -> KernelResult<proto::Nack> {
    let object = object(value, "nack")?;

    Ok(proto::Nack {
        nacked_message_id: required_string(object, "nacked_message_id")?,
        code: required_string(object, "code")?,
        message: optional_string(object, "message")?.unwrap_or_default(),
    })
}

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

    Ok(proto::ActorKey {
        agent_uid: required_string(object, "agent_uid")?,
        session_id: required_string(object, "session_id")?,
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
        broker_sequence: required_u64(object, "broker_sequence")?,
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
    })
}

fn validate_envelope(envelope: &proto::Envelope) -> KernelResult<()> {
    if envelope.protocol_version != PROTOCOL_VERSION {
        return Err(KernelError::new(format!(
            "unsupported actor bus protocol version: {}",
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
            validate_body_semantics(body, lane, durability)?;
            validate_correlation_id(envelope, body)?;

            match body {
                proto::envelope::Body::TurnControl(control) => validate_turn_control(control),
                proto::envelope::Body::WorkerProgress(progress) => {
                    validate_worker_progress(progress)
                }
                _body => Ok(()),
            }
        }
        None => Err(KernelError::new("envelope body is required")),
    }
}

fn validate_correlation_id(
    envelope: &proto::Envelope,
    body: &proto::envelope::Body,
) -> KernelResult<()> {
    if !body_requires_correlation_id(body) {
        return Ok(());
    }

    if envelope.correlation_id.trim().is_empty() {
        return Err(KernelError::new(format!(
            "{} requires correlation_id",
            body_name(body)
        )));
    }

    Ok(())
}

fn body_requires_correlation_id(body: &proto::envelope::Body) -> bool {
    matches!(
        body,
        proto::envelope::Body::TurnStart(_)
            | proto::envelope::Body::MailboxUpdated(_)
            | proto::envelope::Body::TurnAccepted(_)
            | proto::envelope::Body::TurnControl(_)
            | proto::envelope::Body::WorkerProgress(_)
            | proto::envelope::Body::TurnFinalProposal(_)
            | proto::envelope::Body::TurnError(_)
            | proto::envelope::Body::Ack(_)
            | proto::envelope::Body::Nack(_)
    )
}

fn validate_body_semantics(
    body: &proto::envelope::Body,
    lane: proto::Lane,
    durability: proto::DurabilityClass,
) -> KernelResult<()> {
    let (body_name, expected_lane, expected_durability) = match body {
        proto::envelope::Body::WorkerReady(_) => (
            "worker_ready",
            proto::Lane::Control,
            proto::DurabilityClass::ControlEphemeral,
        ),
        proto::envelope::Body::WorkerHeartbeat(_) => (
            "worker_heartbeat",
            proto::Lane::Control,
            proto::DurabilityClass::ControlEphemeral,
        ),
        proto::envelope::Body::WorkerCapacity(_) => (
            "worker_capacity",
            proto::Lane::Control,
            proto::DurabilityClass::ControlEphemeral,
        ),
        proto::envelope::Body::TurnStart(_) => (
            "turn_start",
            proto::Lane::Turn,
            proto::DurabilityClass::ControlReplayable,
        ),
        proto::envelope::Body::MailboxUpdated(_) => (
            "mailbox_updated",
            proto::Lane::Turn,
            proto::DurabilityClass::ControlEphemeral,
        ),
        proto::envelope::Body::TurnAccepted(_) => (
            "turn_accepted",
            proto::Lane::Turn,
            proto::DurabilityClass::ControlReplayable,
        ),
        proto::envelope::Body::TurnControl(_) => (
            "turn_control",
            proto::Lane::Control,
            proto::DurabilityClass::ControlDurable,
        ),
        proto::envelope::Body::WorkerProgress(_) => (
            "worker_progress",
            proto::Lane::Progress,
            proto::DurabilityClass::ControlEphemeral,
        ),
        proto::envelope::Body::TurnFinalProposal(_) => (
            "turn_final_proposal",
            proto::Lane::Turn,
            proto::DurabilityClass::ControlDurable,
        ),
        proto::envelope::Body::TurnError(_) => (
            "turn_error",
            proto::Lane::Turn,
            proto::DurabilityClass::ControlReplayable,
        ),
        proto::envelope::Body::ControlShutdown(_) => (
            "control_shutdown",
            proto::Lane::Control,
            proto::DurabilityClass::ControlEphemeral,
        ),
        proto::envelope::Body::Ack(_) => (
            "ack",
            proto::Lane::Control,
            proto::DurabilityClass::ControlEphemeral,
        ),
        proto::envelope::Body::Nack(_) => (
            "nack",
            proto::Lane::Control,
            proto::DurabilityClass::ControlEphemeral,
        ),
    };

    if lane != expected_lane {
        return Err(KernelError::new(format!(
            "{body_name} must use lane {}",
            lane_name(expected_lane)
        )));
    }

    if durability != expected_durability {
        return Err(KernelError::new(format!(
            "{body_name} must use durability {}",
            durability_name(expected_durability)
        )));
    }

    Ok(())
}

fn body_name(body: &proto::envelope::Body) -> &'static str {
    match body {
        proto::envelope::Body::WorkerReady(_) => "worker_ready",
        proto::envelope::Body::WorkerHeartbeat(_) => "worker_heartbeat",
        proto::envelope::Body::WorkerCapacity(_) => "worker_capacity",
        proto::envelope::Body::TurnStart(_) => "turn_start",
        proto::envelope::Body::MailboxUpdated(_) => "mailbox_updated",
        proto::envelope::Body::TurnAccepted(_) => "turn_accepted",
        proto::envelope::Body::TurnControl(_) => "turn_control",
        proto::envelope::Body::WorkerProgress(_) => "worker_progress",
        proto::envelope::Body::TurnFinalProposal(_) => "turn_final_proposal",
        proto::envelope::Body::TurnError(_) => "turn_error",
        proto::envelope::Body::ControlShutdown(_) => "control_shutdown",
        proto::envelope::Body::Ack(_) => "ack",
        proto::envelope::Body::Nack(_) => "nack",
    }
}

fn validate_turn_control(control: &proto::TurnControl) -> KernelResult<()> {
    if control.command == "steer" && !empty_json_payload(&control.payload_json) {
        return Err(KernelError::new(
            "turn_control steer payload must be empty and journaled as actor input",
        ));
    }

    Ok(())
}

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
    object.insert("seq".into(), Value::from(envelope.seq));
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
        Some(proto::envelope::Body::Ack(payload)) => ("ack", ack_to_json(payload)),
        Some(proto::envelope::Body::Nack(payload)) => ("nack", nack_to_json(payload)),
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
        (
            "worker_instance_id",
            Value::from(payload.worker_instance_id.clone()),
        ),
        ("runtime", Value::from(payload.runtime.clone())),
        ("version", Value::from(payload.version.clone())),
        ("capacity_json", bytes_to_json(&payload.capacity_json)?),
    ]))
}

fn worker_heartbeat_to_json(payload: &proto::AgentComputerWorkerHeartbeat) -> KernelResult<Value> {
    Ok(json_object([
        ("worker_id", Value::from(payload.worker_id.clone())),
        (
            "worker_instance_id",
            Value::from(payload.worker_instance_id.clone()),
        ),
        ("monotonic_ms", Value::from(payload.monotonic_ms)),
        ("load_json", bytes_to_json(&payload.load_json)?),
    ]))
}

fn worker_capacity_to_json(payload: &proto::AgentComputerWorkerCapacity) -> KernelResult<Value> {
    Ok(json_object([
        ("worker_id", Value::from(payload.worker_id.clone())),
        (
            "worker_instance_id",
            Value::from(payload.worker_instance_id.clone()),
        ),
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

fn ack_to_json(payload: &proto::Ack) -> KernelResult<Value> {
    Ok(json_object([(
        "acked_message_id",
        Value::from(payload.acked_message_id.clone()),
    )]))
}

fn nack_to_json(payload: &proto::Nack) -> KernelResult<Value> {
    Ok(json_object([
        (
            "nacked_message_id",
            Value::from(payload.nacked_message_id.clone()),
        ),
        ("code", Value::from(payload.code.clone())),
        ("message", Value::from(payload.message.clone())),
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

    Ok(json_object([
        ("agent_uid", Value::from(actor.agent_uid.clone())),
        ("session_id", Value::from(actor.session_id.clone())),
    ]))
}

fn actor_input_to_json(input: &proto::ActorInputEnvelope) -> KernelResult<Value> {
    Ok(json_object([
        ("actor_input_id", Value::from(input.actor_input_id.clone())),
        ("broker_sequence", Value::from(input.broker_sequence)),
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
        ])),
        None => Ok(Value::Null),
    }
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
        proto::Lane::Control => Ok("LANE_CONTROL".into()),
        proto::Lane::Turn => Ok("LANE_TURN".into()),
        proto::Lane::Progress => Ok("LANE_PROGRESS".into()),
        proto::Lane::Rpc => Ok("LANE_RPC".into()),
        proto::Lane::Unspecified => Err(KernelError::new("lane must be specified")),
    }
}

fn durability_to_json(durability: i32) -> KernelResult<String> {
    match proto::DurabilityClass::try_from(durability)
        .unwrap_or(proto::DurabilityClass::DurabilityUnspecified)
    {
        proto::DurabilityClass::ControlDurable => Ok("CONTROL_DURABLE".into()),
        proto::DurabilityClass::ControlReplayable => Ok("CONTROL_REPLAYABLE".into()),
        proto::DurabilityClass::ControlEphemeral => Ok("CONTROL_EPHEMERAL".into()),
        proto::DurabilityClass::DurabilityUnspecified => {
            Err(KernelError::new("durability must be specified"))
        }
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

fn json_bytes(value: Option<&Value>) -> KernelResult<Option<Vec<u8>>> {
    match value {
        Some(Value::Null) | None => Ok(None),
        Some(Value::String(text)) => Ok(Some(text.as_bytes().to_vec())),
        Some(value) => serde_json::to_vec(value)
            .map(Some)
            .map_err(|error| KernelError::new(format!("failed to encode JSON bytes: {error}"))),
    }
}

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
            "seq": 1,
            "lane": "LANE_TURN",
            "sent_at_unix_ms": 1782300000000_i64,
            "durability": "CONTROL_REPLAYABLE",
            "body": {
                "type": "turn_start",
                "turn_start": {
                    "turn": turn_ref(),
                    "inputs": [{
                        "actor_input_id": "input-1",
                        "broker_sequence": 1,
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
    fn rejects_steer_with_inline_payload() {
        let envelope = json!({
            "protocol_version": 1,
            "message_id": "msg-1",
            "correlation_id": "steer-1",
            "lane": "LANE_CONTROL",
            "durability": "CONTROL_DURABLE",
            "turn_control": {
                "turn": turn_ref(),
                "command": "steer",
                "payload_json": {"text": "do not inline"}
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
            "turn_start": {
                "turn": turn_ref(),
                "inputs": [{
                    "actor_input_id": "input-1",
                    "broker_sequence": 1,
                    "type": "im.message.addressed",
                    "ingress_event_id": "event-1"
                }]
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
            "worker_progress": {
                "turn": turn_ref(),
                "kind": "tool_call_chunk",
                "summary": "internal AI SDK stream chunk"
            }
        });

        let error = encode_envelope_json(envelope).unwrap_err().to_string();

        assert!(error.contains("worker_progress kind"));
    }

    #[test]
    fn worker_ready_does_not_require_actor_fields() {
        let envelope = json!({
            "protocol_version": 1,
            "message_id": "ready-1",
            "lane": "LANE_CONTROL",
            "durability": "CONTROL_EPHEMERAL",
            "worker_ready": {
                "worker_id": "worker-a",
                "worker_instance_id": "instance-a",
                "runtime": "bun",
                "version": "0.1.0",
                "capacity_json": {"turn_slots": 2}
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
