use crate::common::{KernelError, KernelResult};

use super::{
    PROTOCOL_VERSION,
    enums::{durability_name, lane_name},
    json::normalized_name,
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
