use super::*;
use prost::Message;
use proto::Lane::Rpc as RPCLane;
use proto::envelope::Body::{RpcRequest as RPCRequestBody, RpcResponse as RPCResponseBody};

#[test]
fn accepts_and_round_trips_turn_start() {
    let envelope = base_envelope(
        "msg-1",
        "corr-1",
        proto::Lane::Turn,
        proto::DurabilityClass::ControlReplayable,
        proto::envelope::Body::TurnStart(proto::TurnStart {
            turn: Some(turn_ref()),
            actor_event: Some(actor_event()),
            model_ref: Some(proto::TurnModelRef {
                profile: "chat".into(),
                provider_id: "openrouter-main".into(),
                model: "openai/gpt-5.4-mini".into(),
                provider_kind: "openrouter".into(),
                input_modalities: vec!["text".into()],
                vision_fallback_model_ref: Some(Box::new(proto::TurnModelRef {
                    profile: "vision_fallback".into(),
                    provider_id: "openai-vision".into(),
                    model: "gpt-5".into(),
                    provider_kind: "openai".into(),
                    input_modalities: vec!["text".into(), "image".into()],
                    vision_fallback_model_ref: None,
                    max_completion_tokens: None,
                    provider_options_json: Vec::new(),
                    supports_parallel_tool_calls: false,
                    context_length: None,
                })),
                max_completion_tokens: Some(32_000),
                provider_options_json: br#"{"reasoningEffort":"high"}"#.to_vec(),
                supports_parallel_tool_calls: true,
                context_length: Some(262_144),
            }),
            request_context_json: br#"{"kind":"schedule","silent_success_allowed":true}"#.to_vec(),
            hosted_tools_json: br#"[{"type":"image_generation"}]"#.to_vec(),
            runtime_env: [(
                "ANKOLE_RUNTIME_CURRENT_ACTOR_SENDER_PRINCIPAL".into(),
                "human-alice".into(),
            )]
            .into(),
            workspace_id: 10_000,
        }),
    );

    let bytes = envelope.encode_to_vec();
    validate_envelope_bytes(&bytes).expect("turn_start must validate");

    let decoded = proto::Envelope::decode(bytes.as_slice()).expect("turn_start must decode");
    assert_eq!(decoded, envelope);
}

#[test]
fn rejects_turn_start_without_a_model_safe_workspace_id() {
    let mut envelope = golden_turn_start(None);
    if let Some(proto::envelope::Body::TurnStart(turn_start)) = envelope.body.as_mut() {
        turn_start.workspace_id = 9_999;
    }

    let error = validate_error(envelope);
    assert!(error.contains("workspace_id must be a model-safe integer starting at 10000"));
}

#[test]
fn accepts_mailbox_updated_and_rejects_missing_actor_event() {
    let mut mailbox_updated = proto::MailboxUpdated {
        reason: "command.steer".into(),
        turn: Some(turn_ref()),
        actor_event: Some(actor_event()),
    };

    let envelope = base_envelope(
        "mailbox-updated-1",
        "mailbox-updated-1",
        proto::Lane::Turn,
        proto::DurabilityClass::ControlEphemeral,
        proto::envelope::Body::MailboxUpdated(mailbox_updated.clone()),
    );
    validate_envelope_bytes(&envelope.encode_to_vec()).expect("mailbox_updated must validate");

    mailbox_updated.actor_event = None;
    let error = validate_error(base_envelope(
        "mailbox-updated-missing-event",
        "mailbox-updated-missing-event",
        proto::Lane::Turn,
        proto::DurabilityClass::ControlEphemeral,
        proto::envelope::Body::MailboxUpdated(mailbox_updated),
    ));
    assert!(error.contains("mailbox_updated.actor_event is required"));
}

#[test]
fn seals_headers_from_the_body_spec() {
    // A host supplies only ids, send time, and body. The seal writes lane,
    // durability, and protocol version from the BodySpec table, and it also
    // overwrites a host-set value, so the table stays the only owner.
    let mut envelope = base_envelope(
        "seal-1",
        "seal-1",
        proto::Lane::Unspecified,
        proto::DurabilityClass::DurabilityUnspecified,
        proto::envelope::Body::TurnAccepted(proto::TurnAccepted {
            turn: Some(turn_ref()),
        }),
    );
    envelope.protocol_version = 0;

    let sealed_bytes = seal_envelope_bytes(&envelope.encode_to_vec()).expect("seal must succeed");
    let sealed = proto::Envelope::decode(sealed_bytes.as_slice()).expect("sealed must decode");
    assert_eq!(sealed.protocol_version, PROTOCOL_VERSION);
    assert_eq!(sealed.lane, proto::Lane::Turn as i32);
    assert_eq!(
        sealed.durability,
        proto::DurabilityClass::ControlReplayable as i32
    );
    validate_envelope_bytes(&sealed_bytes).expect("sealed envelope must validate");

    let mut wrong = envelope.clone();
    wrong.lane = proto::Lane::Control as i32;
    let corrected = proto::Envelope::decode(
        seal_envelope_bytes(&wrong.encode_to_vec())
            .expect("seal must correct a wrong host lane")
            .as_slice(),
    )
    .expect("corrected envelope must decode");
    assert_eq!(corrected.lane, proto::Lane::Turn as i32);

    let bodyless = proto::Envelope {
        body: None,
        ..envelope
    };
    let error = seal_envelope_bytes(&bodyless.encode_to_vec()).expect_err("bodyless must fail");
    assert!(error.to_string().contains("envelope body is required"));
}

#[test]
fn rejects_body_lane_and_durability_mismatches() {
    let wrong_lane = validate_error(base_envelope(
        "turn-accepted-wrong-lane",
        "turn-start-1",
        proto::Lane::Progress,
        proto::DurabilityClass::ControlEphemeral,
        proto::envelope::Body::TurnAccepted(proto::TurnAccepted {
            turn: Some(turn_ref()),
        }),
    ));
    assert!(wrong_lane.contains("turn_accepted must use lane LANE_TURN"));

    let wrong_durability = validate_error(base_envelope(
        "turn-accepted-wrong-durability",
        "turn-start-1",
        proto::Lane::Turn,
        proto::DurabilityClass::ControlEphemeral,
        proto::envelope::Body::TurnAccepted(proto::TurnAccepted {
            turn: Some(turn_ref()),
        }),
    ));
    assert!(wrong_durability.contains("turn_accepted must use durability CONTROL_REPLAYABLE"));

    let wrong_turn_start_lane = validate_error(base_envelope(
        "turn-start-wrong-lane",
        "turn-start-1",
        proto::Lane::Control,
        proto::DurabilityClass::ControlEphemeral,
        proto::envelope::Body::TurnStart(proto::TurnStart {
            turn: Some(turn_ref()),
            actor_event: Some(actor_event()),
            model_ref: None,
            request_context_json: Vec::new(),
            hosted_tools_json: Vec::new(),
            runtime_env: Default::default(),
            workspace_id: 10_000,
        }),
    ));
    assert!(wrong_turn_start_lane.contains("turn_start must use lane LANE_TURN"));
}

#[test]
fn rejects_model_ref_with_zero_max_completion_tokens() {
    let error = validate_error(base_envelope(
        "turn-start-zero-max-completion",
        "turn-start-1",
        proto::Lane::Turn,
        proto::DurabilityClass::ControlReplayable,
        proto::envelope::Body::TurnStart(proto::TurnStart {
            turn: Some(turn_ref()),
            actor_event: Some(actor_event()),
            model_ref: Some(proto::TurnModelRef {
                profile: "chat".into(),
                provider_id: "openrouter-main".into(),
                model: "openai/gpt-5.4-mini".into(),
                provider_kind: String::new(),
                input_modalities: Vec::new(),
                vision_fallback_model_ref: None,
                max_completion_tokens: Some(0),
                provider_options_json: Vec::new(),
                supports_parallel_tool_calls: false,
                context_length: None,
            }),
            request_context_json: Vec::new(),
            hosted_tools_json: Vec::new(),
            runtime_env: Default::default(),
            workspace_id: 10_000,
        }),
    ));

    assert!(
        error.contains("max_completion_tokens must be greater than 0"),
        "unexpected error: {error}"
    );
}

#[test]
fn rejects_steer_with_inline_payload() {
    let error = validate_error(base_envelope(
        "msg-1",
        "steer-1",
        proto::Lane::Control,
        proto::DurabilityClass::ControlDurable,
        proto::envelope::Body::TurnControl(proto::TurnControl {
            turn: Some(turn_ref()),
            command: "steer".into(),
            payload_json: br#"{"text":"do not inline"}"#.to_vec(),
        }),
    ));

    assert!(error.contains("steer payload must be empty"));
}

#[test]
fn worker_progress_kinds_are_bounded() {
    let error = validate_error(base_envelope(
        "progress-1",
        "progress-1",
        proto::Lane::Progress,
        proto::DurabilityClass::ControlEphemeral,
        proto::envelope::Body::WorkerProgress(proto::WorkerProgress {
            turn: Some(turn_ref()),
            kind: "tool_call_chunk".into(),
            summary: "internal AI SDK stream chunk".into(),
            refs_json: Vec::new(),
        }),
    ));
    assert!(error.contains("worker_progress kind"));

    let accepted = base_envelope(
        "progress-presentation-1",
        "turn-start-1",
        proto::Lane::Progress,
        proto::DurabilityClass::ControlEphemeral,
        proto::envelope::Body::WorkerProgress(proto::WorkerProgress {
            turn: Some(turn_ref()),
            kind: "reply_presentation".into(),
            summary: "reply presentation updated".into(),
            refs_json: br#"{"presentation_event":{"kind":"plan.snapshot"}}"#.to_vec(),
        }),
    );
    validate_envelope_bytes(&accepted.encode_to_vec())
        .expect("reply presentation progress must validate");
}

#[test]
fn accepts_rpc_request_and_rejects_correlation_mismatch() {
    let envelope = base_envelope(
        "rpc-conversation-context-1",
        "rpc-conversation-context-1",
        RPCLane,
        proto::DurabilityClass::ControlEphemeral,
        RPCRequestBody(proto::RpcRequest {
            request_id: "rpc-conversation-context-1".into(),
            method: "agent_conversation.context.resolve".into(),
            deadline_unix_ms: 1_782_300_001_000,
            ..Default::default()
        }),
    );
    validate_envelope_bytes(&envelope.encode_to_vec()).expect("rpc_request must validate");

    let error = validate_error(base_envelope(
        "rpc-1",
        "other",
        RPCLane,
        proto::DurabilityClass::ControlEphemeral,
        RPCResponseBody(proto::RpcResponse {
            request_id: "rpc-1".into(),
            payload: b"\x0a\x02ok".to_vec(),
        }),
    ));
    assert!(error.contains("correlation_id must equal request_id"));
}

#[test]
fn turn_lane_bodies_require_correlation_id() {
    let error = validate_error(base_envelope(
        "turn-start-no-corr",
        "",
        proto::Lane::Turn,
        proto::DurabilityClass::ControlReplayable,
        proto::envelope::Body::TurnStart(proto::TurnStart {
            turn: Some(turn_ref()),
            actor_event: Some(actor_event()),
            model_ref: None,
            request_context_json: Vec::new(),
            hosted_tools_json: Vec::new(),
            runtime_env: Default::default(),
            workspace_id: 10_000,
        }),
    ));

    assert!(error.contains("turn_start requires correlation_id"));
}

#[test]
fn rejects_envelope_header_violations() {
    let mut wrong_version = base_envelope(
        "version-1",
        "",
        proto::Lane::Control,
        proto::DurabilityClass::ControlEphemeral,
        proto::envelope::Body::ControlShutdown(proto::ControlShutdown::default()),
    );
    wrong_version.protocol_version = 1;
    assert!(validate_error(wrong_version).contains("unsupported runtime fabric protocol version"));

    let missing_message_id = base_envelope(
        " ",
        "",
        proto::Lane::Control,
        proto::DurabilityClass::ControlEphemeral,
        proto::envelope::Body::ControlShutdown(proto::ControlShutdown::default()),
    );
    assert!(validate_error(missing_message_id).contains("message_id is required"));

    let unspecified_lane = base_envelope(
        "lane-unspecified",
        "",
        proto::Lane::Unspecified,
        proto::DurabilityClass::ControlEphemeral,
        proto::envelope::Body::ControlShutdown(proto::ControlShutdown::default()),
    );
    assert!(validate_error(unspecified_lane).contains("lane must be specified"));

    let mut missing_body = base_envelope(
        "missing-body",
        "",
        proto::Lane::Control,
        proto::DurabilityClass::ControlEphemeral,
        proto::envelope::Body::ControlShutdown(proto::ControlShutdown::default()),
    );
    missing_body.body = None;
    assert!(validate_error(missing_body).contains("envelope body is required"));
}

#[test]
fn worker_lifecycle_envelopes_expose_worker_id_for_route_auth() {
    let bodies = [
        proto::envelope::Body::WorkerReady(proto::AgentComputerWorkerReady {
            worker_id: "worker-a".into(),
            runtime: "bun".into(),
            version: "test".into(),
            max_turns: 1,
            incarnation_id: "incarnation-a".into(),
            available_turn_slots: 1,
        }),
        proto::envelope::Body::WorkerHeartbeat(proto::AgentComputerWorkerHeartbeat {
            worker_id: "worker-a".into(),
            monotonic_ms: 0,
            active_turns: 0,
            incarnation_id: "incarnation-a".into(),
            runtime: "bun".into(),
            version: "test".into(),
            max_turns: 1,
            available_turn_slots: 1,
        }),
        proto::envelope::Body::WorkerCapacity(proto::AgentComputerWorkerCapacity {
            worker_id: "worker-a".into(),
            max_turns: 1,
            active_turns: 0,
            available_turn_slots: 1,
            incarnation_id: "incarnation-a".into(),
        }),
    ];

    for (index, body) in bodies.into_iter().enumerate() {
        let envelope = base_envelope(
            &format!("worker-lifecycle-{index}"),
            "",
            proto::Lane::Control,
            proto::DurabilityClass::ControlEphemeral,
            body,
        );

        let decoded = decode_envelope_view(&envelope.encode_to_vec()).unwrap();
        assert_eq!(decoded.worker_lifecycle_id(), Some("worker-a"));
    }
}

#[test]
fn rejects_inconsistent_worker_capacity() {
    let missing_max = base_envelope(
        "worker-ready-missing-max",
        "",
        proto::Lane::Control,
        proto::DurabilityClass::ControlEphemeral,
        proto::envelope::Body::WorkerReady(proto::AgentComputerWorkerReady {
            worker_id: "worker-a".into(),
            runtime: "bun".into(),
            version: "test".into(),
            max_turns: 0,
            incarnation_id: "incarnation-a".into(),
            available_turn_slots: 0,
        }),
    );
    assert!(validate_error(missing_max).contains("worker_ready.max_turns must be positive"));

    let inconsistent = base_envelope(
        "worker-capacity-inconsistent",
        "",
        proto::Lane::Control,
        proto::DurabilityClass::ControlEphemeral,
        proto::envelope::Body::WorkerCapacity(proto::AgentComputerWorkerCapacity {
            worker_id: "worker-a".into(),
            max_turns: 4,
            active_turns: 2,
            available_turn_slots: 1,
            incarnation_id: "incarnation-a".into(),
        }),
    );
    assert!(
        validate_error(inconsistent)
            .contains("worker_capacity available and active turns must equal max_turns")
    );

    let incomplete_heartbeat = base_envelope(
        "worker-heartbeat-incomplete",
        "",
        proto::Lane::Control,
        proto::DurabilityClass::ControlEphemeral,
        proto::envelope::Body::WorkerHeartbeat(proto::AgentComputerWorkerHeartbeat {
            worker_id: "worker-a".into(),
            incarnation_id: "incarnation-a".into(),
            runtime: "bun".into(),
            version: "test".into(),
            max_turns: 4,
            active_turns: 2,
            available_turn_slots: 1,
            monotonic_ms: 0,
        }),
    );
    assert!(
        validate_error(incomplete_heartbeat)
            .contains("worker_heartbeat available and active turns must equal max_turns")
    );
}

#[test]
fn rejects_decoded_protobuf_missing_required_nested_fields() {
    let heartbeat = base_envelope(
        "heartbeat-1",
        "",
        proto::Lane::Control,
        proto::DurabilityClass::ControlEphemeral,
        proto::envelope::Body::WorkerHeartbeat(proto::AgentComputerWorkerHeartbeat::default()),
    );
    let error = validate_error(heartbeat);
    assert!(error.contains("worker_heartbeat.worker_id is required"));

    let rpc_request = base_envelope(
        "rpc-1",
        "rpc-1",
        RPCLane,
        proto::DurabilityClass::ControlEphemeral,
        RPCRequestBody(proto::RpcRequest {
            request_id: "rpc-1".into(),
            ..Default::default()
        }),
    );
    let error = validate_error(rpc_request);
    assert!(error.contains("rpc_request.method is required"));
}

#[test]
fn rejects_undecodable_bytes() {
    let error = validate_envelope_bytes(&[0xff, 0xff, 0xff, 0xff])
        .unwrap_err()
        .to_string();

    assert!(error.contains("failed to decode runtime fabric envelope"));
}

fn base_envelope(
    message_id: &str,
    correlation_id: &str,
    lane: proto::Lane,
    durability: proto::DurabilityClass,
    body: proto::envelope::Body,
) -> proto::Envelope {
    proto::Envelope {
        protocol_version: PROTOCOL_VERSION,
        message_id: message_id.into(),
        correlation_id: correlation_id.into(),
        lane: lane as i32,
        sent_at_unix_ms: 1_782_300_000_000,
        durability: durability as i32,
        body: Some(body),
    }
}

fn turn_ref() -> proto::ActorTurnRef {
    proto::ActorTurnRef {
        actor: Some(proto::ActorKey {
            agent_uid: "agent-1".into(),
            session_id: "signal-channel:lark:dm:1".into(),
        }),
        activation_uid: "activation-1".into(),
        actor_epoch: 1,
        actor_event_id: "11111111-1111-1111-1111-111111111111".into(),
        revision: 0,
    }
}

fn actor_event() -> proto::ActorEventEnvelope {
    proto::ActorEventEnvelope {
        actor_event_id: "00000000-0000-0000-0000-000000000001".into(),
        queue_sequence: 1,
        r#type: "im.message.addressed".into(),
        source_event_id: "event-1".into(),
        source_entry_id: "msg-1".into(),
        payload_json: br#"{"text":"PING"}"#.to_vec(),
        binding_name: "lark".into(),
        signal_channel_id: "lark:chat:group-a".into(),
        provider_thread_id: "thread-1".into(),
    }
}

fn validate_error(envelope: proto::Envelope) -> String {
    validate_envelope_bytes(&envelope.encode_to_vec())
        .unwrap_err()
        .to_string()
}

// Golden fixtures anchor cross-language conformance: the committed bytes are
// decoded read-only by the Rust, Elixir, and TypeScript suites. Regenerate with
// `cargo test --no-default-features regenerate_golden_envelope_fixtures -- --ignored`
// after an intentional protocol change.
fn golden_dir() -> std::path::PathBuf {
    std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("proto")
        .join("golden")
}

fn golden_turn_start(max_completion_tokens: Option<u32>) -> proto::Envelope {
    base_envelope(
        "golden-turn-start-1",
        "golden-turn-start-1",
        proto::Lane::Turn,
        proto::DurabilityClass::ControlReplayable,
        proto::envelope::Body::TurnStart(proto::TurnStart {
            turn: Some(turn_ref()),
            actor_event: Some(actor_event()),
            model_ref: Some(proto::TurnModelRef {
                profile: "chat".into(),
                provider_id: "openrouter-main".into(),
                model: "openai/gpt-5.4-mini".into(),
                provider_kind: "openrouter".into(),
                input_modalities: vec!["text".into()],
                vision_fallback_model_ref: None,
                max_completion_tokens,
                provider_options_json: Vec::new(),
                supports_parallel_tool_calls: false,
                context_length: None,
            }),
            request_context_json: br#"{"kind":"schedule","silent_success_allowed":true}"#.to_vec(),
            hosted_tools_json: br#"[{"type":"image_generation"}]"#.to_vec(),
            runtime_env: Default::default(),
            workspace_id: 10_000,
        }),
    )
}

fn golden_worker_ready() -> proto::Envelope {
    base_envelope(
        "golden-worker-ready-1",
        "",
        proto::Lane::Control,
        proto::DurabilityClass::ControlEphemeral,
        proto::envelope::Body::WorkerReady(proto::AgentComputerWorkerReady {
            worker_id: "worker-golden".into(),
            runtime: "bun".into(),
            version: "test".into(),
            max_turns: 1,
            incarnation_id: "incarnation-golden".into(),
            available_turn_slots: 1,
        }),
    )
}

#[test]
#[ignore = "writes the committed golden fixtures; run explicitly after protocol changes"]
fn regenerate_golden_envelope_fixtures() {
    let dir = golden_dir();
    std::fs::create_dir_all(&dir).expect("golden dir");

    std::fs::write(
        dir.join("turn_start.v4.bin"),
        golden_turn_start(Some(32_000)).encode_to_vec(),
    )
    .expect("turn_start fixture");
    std::fs::write(
        dir.join("worker_ready.v4.bin"),
        golden_worker_ready().encode_to_vec(),
    )
    .expect("worker_ready fixture");
}

#[test]
fn golden_fixtures_stay_valid_and_decode_to_the_expected_structs() {
    let with_field =
        std::fs::read(golden_dir().join("turn_start.v4.bin")).expect("turn_start fixture");
    validate_envelope_bytes(&with_field).expect("turn_start fixture must validate");
    assert_eq!(
        proto::Envelope::decode(with_field.as_slice()).expect("turn_start fixture decodes"),
        golden_turn_start(Some(32_000))
    );

    let worker_ready =
        std::fs::read(golden_dir().join("worker_ready.v4.bin")).expect("worker_ready fixture");
    validate_envelope_bytes(&worker_ready).expect("worker_ready fixture must validate");
    assert_eq!(
        proto::Envelope::decode(worker_ready.as_slice()).expect("worker_ready fixture decodes"),
        golden_worker_ready()
    );

    // Older versions remain structurally decodable by Protobuf, but the semantic
    // validator must reject them before an old worker can enter the ready pool or
    // exchange typed RPC payloads with a version 4 control plane.
    let version_3_turn =
        std::fs::read(golden_dir().join("turn_start.v3.bin")).expect("version 3 turn fixture");
    assert_eq!(
        proto::Envelope::decode(version_3_turn.as_slice())
            .expect("version 3 turn fixture decodes structurally")
            .protocol_version,
        3
    );
    assert!(
        validate_envelope_bytes(&version_3_turn)
            .unwrap_err()
            .to_string()
            .contains("unsupported runtime fabric protocol version: 3")
    );

    let version_3_worker =
        std::fs::read(golden_dir().join("worker_ready.v3.bin")).expect("version 3 worker fixture");
    assert!(
        validate_envelope_bytes(&version_3_worker)
            .unwrap_err()
            .to_string()
            .contains("unsupported runtime fabric protocol version: 3")
    );

    let version_2_turn =
        std::fs::read(golden_dir().join("turn_start.v2.bin")).expect("version 2 turn fixture");
    assert_eq!(
        proto::Envelope::decode(version_2_turn.as_slice())
            .expect("version 2 turn fixture decodes structurally")
            .protocol_version,
        2
    );
    assert!(
        validate_envelope_bytes(&version_2_turn)
            .unwrap_err()
            .to_string()
            .contains("unsupported runtime fabric protocol version: 2")
    );

    let version_2_worker =
        std::fs::read(golden_dir().join("worker_ready.v2.bin")).expect("version 2 worker fixture");
    assert!(
        validate_envelope_bytes(&version_2_worker)
            .unwrap_err()
            .to_string()
            .contains("unsupported runtime fabric protocol version: 2")
    );

    let legacy_turn =
        std::fs::read(golden_dir().join("turn_start.v1.bin")).expect("legacy turn fixture");
    assert_eq!(
        proto::Envelope::decode(legacy_turn.as_slice())
            .expect("legacy turn fixture decodes structurally")
            .protocol_version,
        1
    );
    assert!(
        validate_envelope_bytes(&legacy_turn)
            .unwrap_err()
            .to_string()
            .contains("unsupported runtime fabric protocol version: 1")
    );

    let pre_field = std::fs::read(golden_dir().join("turn_start.pre_max_completion_tokens.v1.bin"))
        .expect("pre-field fixture");
    let pre_field = proto::Envelope::decode(pre_field.as_slice())
        .expect("pre-field fixture decodes structurally");
    assert_eq!(pre_field.protocol_version, 1);
    assert_eq!(
        pre_field
            .body
            .and_then(|body| match body {
                proto::envelope::Body::TurnStart(turn_start) => turn_start.model_ref,
                _ => None,
            })
            .and_then(|model_ref| model_ref.max_completion_tokens),
        None
    );

    let legacy_worker =
        std::fs::read(golden_dir().join("worker_ready.v1.bin")).expect("legacy worker fixture");
    assert!(
        validate_envelope_bytes(&legacy_worker)
            .unwrap_err()
            .to_string()
            .contains("unsupported runtime fabric protocol version: 1")
    );
}
