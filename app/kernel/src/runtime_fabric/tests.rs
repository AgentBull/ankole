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
fn round_trips_turn_final_proposal_without_reply_for_silent_commit() {
    let envelope = json!({
        "protocol_version": 1,
        "message_id": "turn-final-silent-1",
        "correlation_id": "turn-start-1",
        "lane": "LANE_TURN",
        "durability": "CONTROL_DURABLE",
        "body": {
            "type": "turn_final_proposal",
            "turn_final_proposal": {
                "turn": turn_ref(),
                "messages": []
            }
        }
    });

    let encoded = encode_envelope_json(envelope).unwrap();
    let decoded = decode_envelope_json(&encoded).unwrap();

    assert_eq!(decoded["body"]["type"], "turn_final_proposal");
    assert!(decoded["body"]["turn_final_proposal"]["reply"].is_null());
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
