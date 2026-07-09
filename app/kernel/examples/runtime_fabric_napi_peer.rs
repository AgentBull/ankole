use std::env;
use std::fs;
use std::io;
use std::sync::mpsc;
use std::time::Duration;

use ankole_kernel::runtime_fabric::transport::{
    RouterConfig, RouterEvent, RouterEventSink, SocketOptions, start_router,
};
use serde_json::json;

const WORKER_ROUTE: &str = "worker-binding-roundtrip";
const WORKER_AUTH_KEY: &str = "binding-secret";

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let endpoint_path = env::args().nth(1).ok_or("missing endpoint file path")?;
    let (event_tx, event_rx) = mpsc::channel();
    let sink: RouterEventSink = std::sync::Arc::new(move |event| {
        let _ = event_tx.send(event);
    });
    let router = start_router(
        RouterConfig {
            endpoint: "tcp://127.0.0.1:*".to_string(),
            worker_auth_key: Some(WORKER_AUTH_KEY.to_string()),
            zap_domain: None,
            socket: SocketOptions::default(),
            poll_interval_ms: Some(1),
            command_timeout_ms: Some(2_000),
        },
        sink,
    )?;
    fs::write(&endpoint_path, router.endpoint())?;

    match event_rx.recv_timeout(Duration::from_secs(10))? {
        RouterEvent::Received {
            transport_route, ..
        } if transport_route == WORKER_ROUTE => {}
        event => return Err(format!("unexpected initial router event: {event:?}").into()),
    }

    router.send_mandatory(
        WORKER_ROUTE,
        json!({
            "protocol_version": 1,
            "message_id": "binding-roundtrip-envelope",
            "lane": "LANE_CONTROL",
            "durability": "CONTROL_EPHEMERAL",
            "body": {
                "type": "worker_ready",
                "worker_ready": {
                    "worker_id": "fixture",
                    "runtime": "rust",
                    "version": "test",
                    "capacity_json": {"available_turn_slots": 1}
                }
            }
        }),
    )?;
    router.send_file_frame(
        WORKER_ROUTE,
        vec![
            b"ANKOLE_FILE/1".to_vec(),
            b"READ_OPEN".to_vec(),
            b"binding-transfer".to_vec(),
        ],
    )?;

    let mut stop = String::new();
    io::stdin().read_line(&mut stop)?;
    router.stop()?;
    Ok(())
}
