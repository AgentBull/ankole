use std::collections::{HashMap, VecDeque};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, mpsc};
use std::thread;
use std::time::{Duration, Instant};

use super::config::{RouterConfig, validate_config_non_empty};
use super::error::{TransportError, transport_error};

const ZAP_ENDPOINT: &str = "inproc://zeromq.zap.01";

#[derive(Clone, Debug)]
pub(super) struct AuthenticatedWorker {
    pub(super) worker_id: String,
    // ZAP exposes authentication identity plus key revision as route metadata.
    // The current global worker key has one revision; keep the field even while
    // it is constant so the transport/auth boundary does not lose that fact.
    pub(super) key_revision: i64,
}

#[derive(Debug, Default)]
pub(super) struct AuthenticatedRouteState {
    routes: HashMap<String, AuthenticatedWorker>,
    pending_by_worker_id: HashMap<String, VecDeque<AuthenticatedWorker>>,
}

pub(super) type AuthenticatedRoutes = Arc<Mutex<AuthenticatedRouteState>>;
pub(super) type ZapErrorSink = Arc<dyn Fn(String) + Send + Sync + 'static>;

#[derive(Clone, Debug)]
pub(super) enum ZapAuthConfig {
    GlobalWorkerKey { worker_auth_key: String },
}

pub(super) fn zap_auth_config(config: &RouterConfig) -> Option<ZapAuthConfig> {
    config
        .worker_auth_key
        .clone()
        .map(|worker_auth_key| ZapAuthConfig::GlobalWorkerKey { worker_auth_key })
}

pub(super) fn authenticated_route(
    auth_routes: &AuthenticatedRoutes,
    route: &str,
) -> Option<AuthenticatedWorker> {
    let state = auth_routes.lock().ok()?;

    state.routes.get(route).cloned()
}

pub(super) fn authenticated_envelope_route(
    auth_routes: &AuthenticatedRoutes,
    route: &str,
    worker_ready_id: Option<&str>,
) -> Option<AuthenticatedWorker> {
    if let Some(authenticated) = authenticated_route(auth_routes, route) {
        if let Some(worker_id) = worker_ready_id {
            return (authenticated.worker_id == worker_id).then_some(authenticated);
        }

        return Some(authenticated);
    }

    let worker_id = worker_ready_id?;
    bind_authenticated_ready_route(auth_routes, route, worker_id)
}

fn bind_authenticated_ready_route(
    auth_routes: &AuthenticatedRoutes,
    route: &str,
    worker_id: &str,
) -> Option<AuthenticatedWorker> {
    let mut state = auth_routes.lock().ok()?;

    if let Some(authenticated) = state.routes.get(route) {
        return (authenticated.worker_id == worker_id).then(|| authenticated.clone());
    }

    let (authenticated, remove_pending_key) = {
        let pending = state.pending_by_worker_id.get_mut(worker_id)?;
        let authenticated = pending.pop_front()?;

        if authenticated.worker_id != worker_id {
            return None;
        }

        (authenticated, pending.is_empty())
    };

    if remove_pending_key {
        state.pending_by_worker_id.remove(worker_id);
    }

    state
        .routes
        .insert(route.to_string(), authenticated.clone());
    Some(authenticated)
}

// Starts the inproc ZAP server used by ZeroMQ PLAIN auth. This is a pre-auth
// token gate for worker bootstrap, not a user authorization system.
pub(super) fn start_zap_server(
    context: &zmq::Context,
    domain: String,
    auth: ZapAuthConfig,
    auth_routes: AuthenticatedRoutes,
    error_sink: ZapErrorSink,
    stop: Arc<AtomicBool>,
) -> Result<Option<ZapGuard>, TransportError> {
    validate_config_non_empty("zap_domain", &domain)?;

    let context = context.clone();
    let (init_tx, init_rx) = mpsc::sync_channel(1);
    let thread_stop = Arc::clone(&stop);

    let handle = thread::Builder::new()
        .name("ankole-runtime-fabric-zap".to_string())
        .spawn(move || {
            run_zap_server(
                context,
                domain,
                auth,
                auth_routes,
                error_sink,
                thread_stop,
                init_tx,
            )
        })
        .map_err(|error| TransportError::Zmq(format!("failed to spawn ZAP thread: {error}")))?;

    let init_result = match init_rx.recv_timeout(Duration::from_secs(1)) {
        Ok(result) => result.map(|_| ()),
        Err(_) => Err(TransportError::Timeout),
    };

    match init_result {
        Ok(()) => Ok(Some(ZapGuard {
            stop,
            handle: Some(handle),
        })),
        Err(error) => {
            stop.store(true, Ordering::SeqCst);
            let _ = handle.join();
            Err(error)
        }
    }
}

pub(super) struct ZapGuard {
    stop: Arc<AtomicBool>,
    handle: Option<thread::JoinHandle<()>>,
}

impl Drop for ZapGuard {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::SeqCst);

        if let Some(handle) = self.handle.take() {
            let start = Instant::now();
            while !handle.is_finished() && start.elapsed() < Duration::from_millis(500) {
                thread::sleep(Duration::from_millis(5));
            }

            if handle.is_finished() {
                let _ = handle.join();
            }
        }
    }
}

fn run_zap_server(
    context: zmq::Context,
    domain: String,
    auth: ZapAuthConfig,
    auth_routes: AuthenticatedRoutes,
    error_sink: ZapErrorSink,
    stop: Arc<AtomicBool>,
    init: mpsc::SyncSender<Result<(), TransportError>>,
) {
    let socket = match context.socket(zmq::REP).map_err(transport_error) {
        Ok(socket) => socket,
        Err(error) => {
            let _ = init.send(Err(error));
            return;
        }
    };

    if let Err(error) = socket.set_rcvtimeo(50).map_err(transport_error) {
        let _ = init.send(Err(error));
        return;
    }

    if let Err(error) = socket.bind(ZAP_ENDPOINT).map_err(transport_error) {
        let _ = init.send(Err(error));
        return;
    }

    let _ = init.send(Ok(()));

    while !stop.load(Ordering::SeqCst) {
        match socket.recv_multipart(0) {
            Ok(frames) => {
                let response = zap_response(&domain, &auth, &auth_routes, &frames);
                let _ = socket.send_multipart(response, 0);
            }
            Err(zmq::Error::EAGAIN) => {}
            Err(zmq::Error::ETERM) => break,
            Err(error) => {
                error_sink(format!("zap auth socket error: {error}"));
                stop.store(true, Ordering::SeqCst);
                break;
            }
        }
    }
}

// Implements the small ZAP response needed for PLAIN worker authentication.
// The PLAIN username is the worker process id; the password must match the
// control-plane supplied global worker auth key.
fn zap_response(
    domain: &str,
    auth: &ZapAuthConfig,
    auth_routes: &AuthenticatedRoutes,
    frames: &[Vec<u8>],
) -> Vec<Vec<u8>> {
    let sequence = frames.get(1).cloned().unwrap_or_default();
    let request_domain = frame_string(frames.get(2));
    let route_identity = frame_string(frames.get(4));
    let mechanism = frame_string(frames.get(5));
    let username = frame_string(frames.get(6));
    let password = frame_string(frames.get(7));

    let accepted_auth = if request_domain.as_deref() == Some(domain)
        && mechanism.as_deref() == Some("PLAIN")
    {
        match (username.as_deref(), password.as_deref()) {
            (Some(username), Some(password)) => verify_zap_credentials(auth, username, password),
            _ => None,
        }
    } else {
        None
    };

    if let Some(authenticated) = accepted_auth {
        record_authenticated_route(
            auth_routes,
            route_identity.as_deref().unwrap_or_default(),
            authenticated.clone(),
        );

        vec![
            b"1.0".to_vec(),
            sequence,
            b"200".to_vec(),
            b"OK".to_vec(),
            authenticated.worker_id.into_bytes(),
            Vec::new(),
        ]
    } else {
        if let Some(route_identity) = route_identity.as_deref().filter(|value| !value.is_empty()) {
            forget_authenticated_route(auth_routes, route_identity);
        }

        vec![
            b"1.0".to_vec(),
            sequence,
            b"400".to_vec(),
            b"Invalid pre-auth token".to_vec(),
            Vec::new(),
            Vec::new(),
        ]
    }
}

fn verify_zap_credentials(
    auth: &ZapAuthConfig,
    username: &str,
    password: &str,
) -> Option<AuthenticatedWorker> {
    if username.is_empty() || password.is_empty() {
        return None;
    }

    match auth {
        ZapAuthConfig::GlobalWorkerKey { worker_auth_key } => {
            (password == worker_auth_key).then(|| AuthenticatedWorker {
                worker_id: username.to_string(),
                key_revision: 1,
            })
        }
    }
}

fn record_authenticated_route(
    auth_routes: &AuthenticatedRoutes,
    route: &str,
    authenticated: AuthenticatedWorker,
) {
    if let Ok(mut state) = auth_routes.lock() {
        if !route.is_empty() {
            state.routes.insert(route.to_string(), authenticated);
            return;
        }
        state
            .pending_by_worker_id
            .entry(authenticated.worker_id.clone())
            .or_default()
            .push_back(authenticated);
    }
}

fn forget_authenticated_route(auth_routes: &AuthenticatedRoutes, route: &str) {
    if let Ok(mut state) = auth_routes.lock() {
        state.routes.remove(route);
    }
}

fn frame_string(frame: Option<&Vec<u8>>) -> Option<String> {
    frame.and_then(|bytes| String::from_utf8(bytes.clone()).ok())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn zap_success_with_route_identity_does_not_enqueue_pending_worker() {
        let auth_routes = authenticated_routes();
        let auth = zap_auth();
        let frames = zap_plain_frames("worker-instance-a", "worker-a", "test-token");

        for _ in 0..3 {
            let response = zap_response("ankole", &auth, &auth_routes, &frames);
            assert_eq!(response[2], b"200");
        }

        let state = auth_routes.lock().expect("auth routes lock");
        assert_eq!(state.routes.len(), 1);
        assert_eq!(
            state
                .routes
                .get("worker-instance-a")
                .map(|worker| worker.worker_id.as_str()),
            Some("worker-a")
        );
        assert!(state.pending_by_worker_id.is_empty());
    }

    #[test]
    fn zap_success_without_route_identity_can_bind_from_worker_ready() {
        let auth_routes = authenticated_routes();
        let auth = zap_auth();
        let frames = zap_plain_frames("", "worker-a", "test-token");

        let response = zap_response("ankole", &auth, &auth_routes, &frames);
        assert_eq!(response[2], b"200");

        let authenticated =
            authenticated_envelope_route(&auth_routes, "worker-instance-a", Some("worker-a"))
                .expect("pending auth binds to ready route");

        assert_eq!(authenticated.worker_id, "worker-a");

        let state = auth_routes.lock().expect("auth routes lock");
        assert_eq!(state.routes.len(), 1);
        assert!(state.pending_by_worker_id.is_empty());
    }

    fn authenticated_routes() -> AuthenticatedRoutes {
        Arc::new(Mutex::new(AuthenticatedRouteState::default()))
    }

    fn zap_auth() -> ZapAuthConfig {
        ZapAuthConfig::GlobalWorkerKey {
            worker_auth_key: "test-token".to_owned(),
        }
    }

    fn zap_plain_frames(route_identity: &str, username: &str, password: &str) -> Vec<Vec<u8>> {
        vec![
            b"1.0".to_vec(),
            b"1".to_vec(),
            b"ankole".to_vec(),
            b"127.0.0.1".to_vec(),
            route_identity.as_bytes().to_vec(),
            b"PLAIN".to_vec(),
            username.as_bytes().to_vec(),
            password.as_bytes().to_vec(),
        ]
    }
}
