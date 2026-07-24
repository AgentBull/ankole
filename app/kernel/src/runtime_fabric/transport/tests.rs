use std::collections::VecDeque;
use std::sync::{Arc, Condvar, Mutex};
use std::time::Duration;

use prost::Message;

use crate::runtime_fabric::{PROTOCOL_VERSION, proto};

use super::dealer::{DealerInbox, emit_dealer_frames};
use super::framing::FILE_TRANSFER_PROTOCOL;
use super::router::RouterEventSink;
use super::*;

#[test]
fn transport_errors_expose_stable_ffi_messages() {
    assert_eq!(TransportError::UnknownRoute.code(), "unknown_route");
    assert_eq!(TransportError::UnknownRoute.ffi_message(), "unknown_route");
    assert_eq!(TransportError::Backpressure.code(), "backpressure");
    assert_eq!(TransportError::Backpressure.ffi_message(), "backpressure");
    assert_eq!(TransportError::Timeout.ffi_message(), "timeout");
    assert_eq!(TransportError::SocketClosed.ffi_message(), "socket_closed");
    assert_eq!(
        TransportError::InvalidEnvelope("bad body".to_string()).ffi_message(),
        "invalid_envelope: bad body"
    );
}

#[test]
fn validates_transport_config_bounds() {
    let mut router = router_config();
    router.poll_interval_ms = Some(0);
    assert!(matches!(
        router.validate(),
        Err(TransportError::InvalidConfig(reason)) if reason.contains("poll_interval_ms")
    ));

    let mut router = router_config();
    router.socket.linger_ms = Some(-2);
    assert!(matches!(
        router.validate(),
        Err(TransportError::InvalidConfig(reason)) if reason.contains("linger_ms")
    ));

    let mut dealer = dealer_config("tcp://127.0.0.1:1");
    dealer.inbox_max_events = Some(0);
    assert!(matches!(
        dealer.validate(),
        Err(TransportError::InvalidConfig(reason)) if reason.contains("inbox_max_events")
    ));

    let mut router = router_config();
    router.socket.sndtimeo_ms = Some(-1);
    assert!(router.validate().is_ok());
}

#[test]
fn dealer_inbox_overflow_reports_error_and_closes() {
    let inbox = DealerInbox::new(1, 1024);
    inbox.push(DealerEvent::RawFrames(vec![vec![1, 2, 3]]));
    inbox.push(DealerEvent::RawFrames(vec![vec![4, 5, 6]]));

    match inbox
        .recv(Duration::from_millis(1))
        .expect("overflow event")
    {
        Some(DealerEvent::SocketError(reason)) => {
            assert!(reason.contains("dealer inbox overflow"));
        }
        other => panic!("unexpected dealer event: {other:?}"),
    }

    assert!(matches!(
        inbox.recv(Duration::from_millis(1)),
        Err(TransportError::SocketClosed)
    ));
}

#[test]
fn dealer_preserves_raw_non_marker_multipart_for_host_classification() {
    let inbox = DealerInbox::new(8, 1024);
    emit_dealer_frames(&inbox, vec![b"envelope".to_vec(), b"unexpected".to_vec()]);

    match inbox.recv(Duration::from_millis(1)).expect("raw recv") {
        Some(DealerEvent::RawFrames(frames)) => {
            assert_eq!(frames, vec![b"envelope".to_vec(), b"unexpected".to_vec()]);
        }
        other => panic!("unexpected dealer event: {other:?}"),
    }
}

#[test]
fn router_dealer_round_trip_with_plain_auth_and_mandatory_route() {
    let events = Arc::new((Mutex::new(VecDeque::new()), Condvar::new()));
    let sink_events = Arc::clone(&events);
    let sink: RouterEventSink = Arc::new(move |event| {
        let (lock, available) = &*sink_events;
        let mut events = lock.lock().expect("events lock");
        events.push_back(event);
        available.notify_one();
    });

    let router = start_router(router_config(), sink).expect("router starts");

    let dealer = start_dealer(dealer_config(router.endpoint())).expect("dealer starts");

    {
        let transient_recv_handle = dealer.clone();
        drop(transient_recv_handle);
    }

    dealer
        .send_payload(worker_ready_envelope_bytes())
        .expect("ready sends");

    let ready = wait_for_router_event(&events).expect("ready event");
    match ready {
        RouterEvent::Received {
            transport_route,
            authenticated_worker_id,
            envelope_bytes,
        } => {
            let envelope =
                proto::Envelope::decode(envelope_bytes.as_slice()).expect("decoded envelope");
            assert_eq!(transport_route, "worker-instance-a");
            assert_eq!(authenticated_worker_id.as_deref(), Some("worker-a"));
            assert!(matches!(
                envelope.body,
                Some(proto::envelope::Body::WorkerReady(_))
            ));
        }
        other => panic!("unexpected router event: {other:?}"),
    }

    router
        .send_mandatory("worker-instance-a", turn_start_envelope_bytes())
        .expect("turn.start sends");

    let payload = wait_for_dealer_payload(&dealer).expect("dealer payload");
    let envelope = proto::Envelope::decode(payload.as_slice()).expect("turn.start decodes");
    assert!(matches!(
        envelope.body,
        Some(proto::envelope::Body::TurnStart(_))
    ));

    dealer
        .send_file_frame(vec![
            FILE_TRANSFER_PROTOCOL.to_vec(),
            b"STAT_OK".to_vec(),
            b"transfer-a".to_vec(),
            b"/user_files/inbox/a.txt".to_vec(),
            b"file".to_vec(),
            1_u64.to_be_bytes().to_vec(),
            1_u64.to_be_bytes().to_vec(),
            Vec::new(),
        ])
        .expect("file frame sends to router");

    let file_event = wait_for_router_event(&events).expect("file frame event");
    match file_event {
        RouterEvent::FileFrame {
            transport_route,
            authenticated_worker_id,
            frames,
        } => {
            assert_eq!(transport_route, "worker-instance-a");
            assert_eq!(authenticated_worker_id.as_deref(), Some("worker-a"));
            assert_eq!(frames[0], FILE_TRANSFER_PROTOCOL);
            assert_eq!(frames[1], b"STAT_OK");
            assert_eq!(frames[2], b"transfer-a");
        }
        other => panic!("unexpected router event: {other:?}"),
    }

    router
        .send_file_frame(
            "worker-instance-a",
            vec![
                FILE_TRANSFER_PROTOCOL.to_vec(),
                b"READ_OPEN".to_vec(),
                b"transfer-b".to_vec(),
                b"/user_files/inbox/a.txt".to_vec(),
                b"xxh3_128".to_vec(),
            ],
        )
        .expect("file frame sends to dealer");

    let frames = wait_for_dealer_file_frame(&dealer).expect("dealer file frame");
    assert_eq!(frames[0], FILE_TRANSFER_PROTOCOL);
    assert_eq!(frames[1], b"READ_OPEN");
    assert_eq!(frames[2], b"transfer-b");

    let unknown = router
        .send_mandatory("missing-worker", turn_start_envelope_bytes())
        .expect_err("missing route fails");
    assert!(matches!(unknown, TransportError::UnknownRoute));

    let invalid = router
        .send_mandatory("worker-instance-a", vec![0xff, 0xff, 0xff])
        .expect_err("invalid envelope bytes fail validation");
    assert!(matches!(invalid, TransportError::InvalidEnvelope(_)));

    dealer.stop().expect("dealer stops");
    router.stop().expect("router stops");
}

#[test]
fn disconnected_dealer_reports_backpressure_at_its_send_bound() {
    let mut config = dealer_config("tcp://127.0.0.1:1");
    config.socket.sndhwm = Some(1);
    config.socket.sndtimeo_ms = Some(1);
    let dealer = start_dealer(config).expect("dealer starts before its peer is available");

    let mut backpressured = false;
    for _attempt in 0..8 {
        match dealer.send_payload(worker_ready_envelope_bytes()) {
            Ok(SendOutcome::SentOrQueued) => {}
            Err(TransportError::Backpressure) => {
                backpressured = true;
                break;
            }
            Err(error) => panic!("unexpected disconnected dealer error: {error}"),
        }
    }

    assert!(
        backpressured,
        "bounded dealer queue should surface backpressure"
    );
    dealer.stop().expect("dealer stops after backpressure");
}

fn router_config() -> RouterConfig {
    RouterConfig {
        endpoint: "tcp://127.0.0.1:*".to_string(),
        worker_auth_key: Some("test-token".to_string()),
        zap_domain: None,
        socket: SocketOptions::default(),
        poll_interval_ms: Some(1),
        command_timeout_ms: Some(1_000),
    }
}

fn dealer_config(endpoint: &str) -> DealerConfig {
    DealerConfig {
        endpoint: endpoint.to_string(),
        identity: "worker-instance-a".to_string(),
        username: "worker-a".to_string(),
        password: "test-token".to_string(),
        socket: SocketOptions::default(),
        poll_interval_ms: Some(1),
        command_timeout_ms: Some(1_000),
        inbox_max_events: None,
        inbox_max_bytes: None,
    }
}

fn wait_for_router_event(
    events: &Arc<(Mutex<VecDeque<RouterEvent>>, Condvar)>,
) -> Option<RouterEvent> {
    let (lock, available) = &**events;
    let queue = lock.lock().expect("events lock");
    let (mut queue, _) = available
        .wait_timeout(queue, Duration::from_secs(2))
        .expect("event wait");

    queue.pop_front()
}

fn wait_for_dealer_payload(dealer: &DealerHandle) -> Option<Vec<u8>> {
    match dealer.recv(Duration::from_secs(2)).expect("dealer recv") {
        Some(DealerEvent::RawFrames(mut frames)) if frames.len() == 1 => frames.pop(),
        Some(event) => panic!("unexpected dealer event: {event:?}"),
        None => None,
    }
}

fn wait_for_dealer_file_frame(dealer: &DealerHandle) -> Option<Vec<Vec<u8>>> {
    match dealer.recv(Duration::from_secs(2)).expect("dealer recv") {
        Some(DealerEvent::RawFrames(frames)) => Some(frames),
        Some(event) => panic!("unexpected dealer event: {event:?}"),
        None => None,
    }
}

fn worker_ready_envelope_bytes() -> Vec<u8> {
    proto::Envelope {
        protocol_version: PROTOCOL_VERSION,
        message_id: "worker-ready-test".to_string(),
        correlation_id: String::new(),
        lane: proto::Lane::Control as i32,
        sent_at_unix_ms: 0,
        durability: proto::DurabilityClass::ControlEphemeral as i32,
        body: Some(proto::envelope::Body::WorkerReady(
            proto::AgentComputerWorkerReady {
                worker_id: "worker-a".to_string(),
                runtime: "bun".to_string(),
                version: "test".to_string(),
                max_turns: 1,
                incarnation_id: "incarnation-a".to_string(),
                available_turn_slots: 1,
            },
        )),
    }
    .encode_to_vec()
}

fn turn_start_envelope_bytes() -> Vec<u8> {
    proto::Envelope {
        protocol_version: PROTOCOL_VERSION,
        message_id: "turn-start-test".to_string(),
        correlation_id: "turn-start-test".to_string(),
        lane: proto::Lane::Turn as i32,
        sent_at_unix_ms: 0,
        durability: proto::DurabilityClass::ControlReplayable as i32,
        body: Some(proto::envelope::Body::TurnStart(proto::TurnStart {
            turn: Some(proto::ActorTurnRef {
                actor: Some(proto::ActorKey {
                    agent_uid: "agent-a".to_string(),
                    session_id: "signal-channel:test".to_string(),
                }),
                activation_uid: "activation-a".to_string(),
                actor_epoch: 1,
                actor_event_id: "00000000-0000-0000-0000-000000000001".to_string(),
                revision: 0,
            }),
            actor_event: Some(proto::ActorEventEnvelope {
                actor_event_id: "00000000-0000-0000-0000-000000000002".to_string(),
                queue_sequence: 1,
                r#type: "im.message.addressed".to_string(),
                source_event_id: "event-a".to_string(),
                source_entry_id: String::new(),
                payload_json: br#"{"text":"PING"}"#.to_vec(),
                binding_name: String::new(),
                signal_channel_id: String::new(),
                provider_thread_id: String::new(),
            }),
            model_ref: None,
            request_context_json: Vec::new(),
            hosted_tools_json: Vec::new(),
            runtime_env: Default::default(),
        })),
    }
    .encode_to_vec()
}
