use std::collections::VecDeque;
use std::sync::{Arc, Condvar, Mutex};
use std::time::Duration;

use serde_json::json;

use crate::runtime_fabric;

use super::dealer::DealerInbox;
use super::framing::FILE_TRANSFER_PROTOCOL;
use super::router::RouterEventSink;
use super::*;

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
    inbox.push(DealerEvent::Received(vec![1, 2, 3]));
    inbox.push(DealerEvent::Received(vec![4, 5, 6]));

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
fn recv_envelope_does_not_consume_file_frames() {
    let inbox = DealerInbox::new(8, 1024);
    inbox.push(DealerEvent::FileFrame(vec![
        FILE_TRANSFER_PROTOCOL.to_vec(),
        b"READ_OPEN".to_vec(),
    ]));

    assert!(matches!(
        inbox.recv_envelope(Duration::from_millis(1)),
        Err(TransportError::InvalidFrame(reason)) if reason.contains("recvRaw")
    ));

    match inbox.recv(Duration::from_millis(1)).expect("raw recv") {
        Some(DealerEvent::FileFrame(frames)) => {
            assert_eq!(frames[0], FILE_TRANSFER_PROTOCOL);
            assert_eq!(frames[1], b"READ_OPEN");
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
        .send_envelope(worker_ready_envelope())
        .expect("ready sends");

    let ready = wait_for_router_event(&events).expect("ready event");
    match ready {
        RouterEvent::Received {
            transport_route,
            authenticated_worker_id,
            authenticated_key_revision,
            envelope_json,
        } => {
            let envelope: serde_json::Value =
                serde_json::from_str(&envelope_json).expect("decoded JSON");
            assert_eq!(transport_route, "worker-instance-a");
            assert_eq!(authenticated_worker_id.as_deref(), Some("worker-a"));
            assert_eq!(authenticated_key_revision, Some(1));
            assert_eq!(envelope["body"]["type"], "worker_ready");
        }
        other => panic!("unexpected router event: {other:?}"),
    }

    router
        .send_mandatory("worker-instance-a", turn_start_envelope())
        .expect("turn.start sends");

    let payload = wait_for_dealer_payload(&dealer).expect("dealer payload");
    let envelope = runtime_fabric::decode_envelope(&payload).expect("turn.start decodes");
    assert_eq!(envelope["body"]["type"], "turn_start");

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
            authenticated_key_revision,
            frames,
        } => {
            assert_eq!(transport_route, "worker-instance-a");
            assert_eq!(authenticated_worker_id.as_deref(), Some("worker-a"));
            assert_eq!(authenticated_key_revision, Some(1));
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
        .send_mandatory("missing-worker", turn_start_envelope())
        .expect_err("missing route fails");
    assert!(matches!(unknown, TransportError::UnknownRoute));

    dealer.stop().expect("dealer stops");
    router.stop().expect("router stops");
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
        Some(DealerEvent::Received(payload)) => Some(payload),
        Some(event) => panic!("unexpected dealer event: {event:?}"),
        None => None,
    }
}

fn wait_for_dealer_file_frame(dealer: &DealerHandle) -> Option<Vec<Vec<u8>>> {
    match dealer.recv(Duration::from_secs(2)).expect("dealer recv") {
        Some(DealerEvent::FileFrame(frames)) => Some(frames),
        Some(event) => panic!("unexpected dealer event: {event:?}"),
        None => None,
    }
}

fn worker_ready_envelope() -> serde_json::Value {
    json!({
        "protocol_version": 1,
        "message_id": "worker-ready-test",
        "lane": "LANE_CONTROL",
        "durability": "CONTROL_EPHEMERAL",
        "body": {
            "type": "worker_ready",
            "worker_ready": {
                "worker_id": "worker-a",
                "runtime": "bun",
                "version": "test",
                "capacity_json": {"available_turn_slots": 1}
            }
        }
    })
}

fn turn_start_envelope() -> serde_json::Value {
    json!({
        "protocol_version": 1,
        "message_id": "turn-start-test",
        "correlation_id": "turn-start-test",
        "lane": "LANE_TURN",
        "durability": "CONTROL_REPLAYABLE",
        "body": {
            "type": "turn_start",
            "turn_start": {
                "turn": {
                    "actor": {
                        "agent_uid": "agent-a",
                        "session_id": "signal-channel:test"
                    },
                    "activation_uid": "activation-a",
                    "actor_epoch": 1,
                    "llm_turn_id": "00000000-0000-0000-0000-000000000001",
                    "revision": 0
                },
                "inputs": [{
                    "actor_input_id": "00000000-0000-0000-0000-000000000002",
                    "live_queue_sequence": 1,
                    "type": "im.message.addressed",
                    "ingress_event_id": "event-a",
                    "payload_json": {"text": "PING"}
                }]
            }
        }
    })
}
