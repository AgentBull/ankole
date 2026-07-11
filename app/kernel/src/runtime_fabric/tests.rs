use super::*;
use prost::Message;
use serde_json::{Value, json};

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
                "actor_event": {
                    "actor_event_id": "00000000-0000-0000-0000-000000000001",
                    "queue_sequence": 1,
                    "type": "im.message.addressed",
                    "source_event_id": "event-1",
                    "source_entry_id": "msg-1",
                    "binding_name": "lark",
                    "signal_channel_id": "lark:chat:group-a",
                    "provider_thread_id": "thread-1",
                    "payload_json": {"text": "PING"}
                },
                "model_ref": {
                    "profile": "chat",
                    "provider_id": "openrouter-main",
                    "model": "openai/gpt-5.4-mini",
                    "provider_kind": "openrouter",
                    "input_modalities": ["text"],
                    "vision_fallback_model_ref": {
                        "profile": "vision_fallback",
                        "provider_id": "openai-vision",
                        "model": "gpt-5",
                        "provider_kind": "openai",
                        "input_modalities": ["text", "image"]
                    }
                },
                "request_context": {
                    "kind": "schedule",
                    "silent_success_allowed": true
                }
            }
        }
    });

    let encoded = encode_envelope(envelope).unwrap();
    let decoded = decode_envelope(&encoded).unwrap();

    assert_eq!(decoded["body"]["type"], "turn_start");
    assert_eq!(
        decoded["body"]["turn_start"]["actor_event"]["payload_json"]["text"],
        "PING"
    );
    assert_eq!(
        decoded["body"]["turn_start"]["actor_event"]["binding_name"],
        "lark"
    );
    assert_eq!(
        decoded["body"]["turn_start"]["actor_event"]["signal_channel_id"],
        "lark:chat:group-a"
    );
    assert_eq!(
        decoded["body"]["turn_start"]["actor_event"]["provider_thread_id"],
        "thread-1"
    );
    assert_eq!(
        decoded["body"]["turn_start"]["model_ref"]["provider_kind"],
        "openrouter"
    );
    assert_eq!(
        decoded["body"]["turn_start"]["model_ref"]["input_modalities"],
        json!(["text"])
    );
    assert_eq!(
        decoded["body"]["turn_start"]["model_ref"]["vision_fallback_model_ref"]["profile"],
        "vision_fallback"
    );
    assert_eq!(
        decoded["body"]["turn_start"]["model_ref"]["vision_fallback_model_ref"]["input_modalities"],
        json!(["text", "image"])
    );
    assert_eq!(
        decoded["body"]["turn_start"]["request_context"]["silent_success_allowed"],
        true
    );
}

#[test]
fn round_trips_mailbox_updated() {
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
                "reason": "command.steer",
                "actor_event": {
                    "actor_event_id": "22222222-2222-2222-2222-222222222222",
                    "queue_sequence": 2,
                    "type": "command.steer",
                    "source_event_id": "evt-steer-1",
                    "source_entry_id": "msg-steer-1",
                    "payload_json": {"text": "change course"}
                }
            }
        }
    });

    let encoded = encode_envelope(envelope).unwrap();
    let decoded = decode_envelope(&encoded).unwrap();

    assert_eq!(decoded["body"]["type"], "mailbox_updated");
    assert_eq!(
        decoded["body"]["mailbox_updated"]["turn"]["actor_event_id"],
        "11111111-1111-1111-1111-111111111111"
    );
    assert_eq!(
        decoded["body"]["mailbox_updated"]["reason"],
        "command.steer"
    );
    assert_eq!(
        decoded["body"]["mailbox_updated"]["actor_event"]["payload_json"]["text"],
        "change course"
    );
}

#[test]
fn rejects_mailbox_updated_without_actor_event() {
    let envelope = json!({
        "protocol_version": 1,
        "message_id": "mailbox-updated-missing-event",
        "correlation_id": "mailbox-updated-missing-event",
        "lane": "LANE_TURN",
        "durability": "CONTROL_EPHEMERAL",
        "body": {
            "type": "mailbox_updated",
            "mailbox_updated": {
                "turn": turn_ref(),
                "reason": "command.steer"
            }
        }
    });

    let error = encode_envelope(envelope).unwrap_err();
    assert!(
        error
            .to_string()
            .contains("mailbox_updated.actor_event is required")
    );
}

#[test]
fn round_trips_turn_noop_completed() {
    let envelope = json!({
        "protocol_version": 1,
        "message_id": "turn-noop-completed-1",
        "correlation_id": "turn-noop-completed-1",
        "lane": "LANE_TURN",
        "durability": "CONTROL_REPLAYABLE",
        "body": {
            "type": "turn_noop_completed",
            "turn_noop_completed": {
                "turn": turn_ref(),
                "reason": "ambient_silent"
            }
        }
    });

    let encoded = encode_envelope(envelope).unwrap();
    let decoded = decode_envelope(&encoded).unwrap();

    assert_eq!(decoded["body"]["type"], "turn_noop_completed");
    assert_eq!(
        decoded["body"]["turn_noop_completed"]["turn"]["actor_event_id"],
        "11111111-1111-1111-1111-111111111111"
    );
    assert_eq!(
        decoded["body"]["turn_noop_completed"]["reason"],
        "ambient_silent"
    );
}

#[test]
fn round_trips_turn_completed() {
    let envelope = json!({
        "protocol_version": 1,
        "message_id": "turn-completed-1",
        "correlation_id": "turn-start-1",
        "lane": "LANE_TURN",
        "durability": "CONTROL_REPLAYABLE",
        "body": {
            "type": "turn_completed",
            "turn_completed": {
                "turn": turn_ref(),
                "final_response_id": "resp_final_1",
                "outcome": "TURN_COMPLETION_OUTCOME_ITERATION_EXHAUSTED"
            }
        }
    });

    let encoded = encode_envelope(envelope).unwrap();
    let decoded = decode_envelope(&encoded).unwrap();

    assert_eq!(decoded["body"]["type"], "turn_completed");
    assert_eq!(
        decoded["body"]["turn_completed"]["final_response_id"],
        "resp_final_1"
    );
    assert_eq!(
        decoded["body"]["turn_completed"]["outcome"],
        "iteration_exhausted"
    );
}

#[test]
fn rejects_invalid_turn_completed_payloads() {
    for (final_response_id, outcome, expected_error) in [
        (
            "response-final",
            "loop_finished",
            "final_response_id must start with resp_",
        ),
        (
            "resp_final_1",
            "unspecified",
            "unsupported turn completion outcome",
        ),
    ] {
        let envelope = json!({
            "protocol_version": 1,
            "message_id": "turn-completed-invalid",
            "correlation_id": "turn-start-1",
            "lane": "LANE_TURN",
            "durability": "CONTROL_REPLAYABLE",
            "body": {
                "type": "turn_completed",
                "turn_completed": {
                    "turn": turn_ref(),
                    "final_response_id": final_response_id,
                    "outcome": outcome
                }
            }
        });

        let error = encode_envelope(envelope).unwrap_err().to_string();
        assert!(error.contains(expected_error), "unexpected error: {error}");
    }
}

#[test]
fn rejects_turn_completed_without_required_fields() {
    let payloads = [
        (
            json!({
                "final_response_id": "resp_final_1",
                "outcome": "loop_finished"
            }),
            "turn is required",
        ),
        (
            json!({
                "turn": turn_ref(),
                "outcome": "loop_finished"
            }),
            "final_response_id is required",
        ),
        (
            json!({
                "turn": turn_ref(),
                "final_response_id": "resp_final_1"
            }),
            "outcome is required",
        ),
    ];

    for (payload, expected_error) in payloads {
        let envelope = json!({
            "protocol_version": 1,
            "message_id": "turn-completed-missing-field",
            "correlation_id": "turn-start-1",
            "lane": "LANE_TURN",
            "durability": "CONTROL_REPLAYABLE",
            "body": {
                "type": "turn_completed",
                "turn_completed": payload
            }
        });

        let error = encode_envelope(envelope).unwrap_err().to_string();
        assert!(error.contains(expected_error), "unexpected error: {error}");
    }
}

#[test]
fn rejects_turn_completed_with_wrong_lane() {
    let envelope = json!({
        "protocol_version": 1,
        "message_id": "turn-completed-wrong-lane",
        "correlation_id": "turn-start-1",
        "lane": "LANE_PROGRESS",
        "durability": "CONTROL_EPHEMERAL",
        "body": {
            "type": "turn_completed",
            "turn_completed": {
                "turn": turn_ref(),
                "final_response_id": "resp_final_1",
                "outcome": "loop_finished"
            }
        }
    });

    let error = encode_envelope(envelope).unwrap_err().to_string();
    assert!(error.contains("turn_completed must use lane LANE_TURN"));
}

#[test]
fn rejects_turn_completed_with_wrong_durability_on_turn_lane() {
    let envelope = json!({
        "protocol_version": 1,
        "message_id": "turn-completed-wrong-durability",
        "correlation_id": "turn-start-1",
        "lane": "LANE_TURN",
        "durability": "CONTROL_EPHEMERAL",
        "body": {
            "type": "turn_completed",
            "turn_completed": {
                "turn": turn_ref(),
                "final_response_id": "resp_final_1",
                "outcome": "loop_finished"
            }
        }
    });

    let error = encode_envelope(envelope).unwrap_err().to_string();
    assert!(error.contains("turn_completed must use durability CONTROL_REPLAYABLE"));
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
                "actor_event": {
                    "actor_event_id": "00000000-0000-0000-0000-000000000001",
                    "queue_sequence": 1,
                    "type": "im.message.addressed",
                    "source_event_id": "event-1",
                    "payload_json": "null"
                }
            }
        }
    });

    let encoded = encode_envelope(envelope).unwrap();
    let decoded = decode_envelope(&encoded).unwrap();

    assert_eq!(
        decoded["body"]["turn_start"]["actor_event"]["payload_json"],
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

    let error = encode_envelope(envelope).unwrap_err().to_string();

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
                "actor_event": {
                    "actor_event_id": "00000000-0000-0000-0000-000000000001",
                    "queue_sequence": 1,
                    "type": "im.message.addressed",
                    "source_event_id": "event-1"
                }
            }
        }
    });

    let error = encode_envelope(envelope).unwrap_err().to_string();

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

    let error = encode_envelope(envelope).unwrap_err().to_string();

    assert!(error.contains("worker_progress kind"));
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

    let encoded = encode_envelope(envelope).unwrap();
    let decoded = decode_envelope(&encoded).unwrap();

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

    let error = encode_envelope(envelope).unwrap_err().to_string();

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

    let encoded = encode_envelope(envelope).unwrap();
    let decoded = decode_envelope(&encoded).unwrap();

    assert_eq!(decoded["body"]["type"], "worker_ready");
    assert!(
        decoded["body"]["worker_ready"]
            .get("capabilities")
            .is_none()
    );
}

#[test]
fn worker_lifecycle_envelopes_expose_worker_id_for_route_auth() {
    let bodies = [
        json!({
            "type": "worker_ready",
            "worker_ready": {
                "worker_id": "worker-a",
                "runtime": "bun",
                "version": "test"
            }
        }),
        json!({
            "type": "worker_heartbeat",
            "worker_heartbeat": {"worker_id": "worker-a"}
        }),
        json!({
            "type": "worker_capacity",
            "worker_capacity": {"worker_id": "worker-a"}
        }),
    ];

    for (index, body) in bodies.into_iter().enumerate() {
        let encoded = encode_envelope(json!({
            "protocol_version": 1,
            "message_id": format!("worker-lifecycle-{index}"),
            "lane": "LANE_CONTROL",
            "durability": "CONTROL_EPHEMERAL",
            "body": body
        }))
        .unwrap();

        let decoded = decode_envelope_view(&encoded).unwrap();
        assert_eq!(decoded.worker_lifecycle_id(), Some("worker-a"));
    }
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

    let error = encode_envelope(envelope).unwrap_err().to_string();

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

    let error = decode_envelope(&bytes).unwrap_err().to_string();

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

    let error = decode_envelope(&bytes).unwrap_err().to_string();

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
        "actor_event_id": "11111111-1111-1111-1111-111111111111",
        "revision": 0
    })
}
