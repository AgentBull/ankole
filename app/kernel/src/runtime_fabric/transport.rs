#![allow(dead_code)]

use std::collections::{HashMap, VecDeque};
use std::fmt;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Condvar, Mutex, mpsc};
use std::thread;
use std::time::{Duration, Instant};

use serde::Deserialize;

use crate::core::{KernelError, KernelResult};
use crate::runtime_fabric;

const ZAP_ENDPOINT: &str = "inproc://zeromq.zap.01";
const DEFAULT_ZAP_DOMAIN: &str = "ankole-runtime-fabric";
const DEFAULT_POLL_INTERVAL_MS: u64 = 10;
const DEFAULT_COMMAND_TIMEOUT_MS: u64 = 1_000;
const DEFAULT_IO_TIMEOUT_MS: i32 = 1_000;
const DEFAULT_HWM: i32 = 1_000;
const DEFAULT_LINGER_MS: i32 = 0;
const FILE_TRANSFER_PROTOCOL: &[u8] = b"ANKOLE_FILE/1";

/// Configuration for the control-plane ROUTER socket.
///
/// The router owns worker routes and uses mandatory send so unknown routes can
/// become retry signals instead of silent message loss.
#[derive(Clone, Debug, Deserialize)]
pub struct RouterConfig {
    #[serde(default)]
    pub endpoint: String,
    #[serde(default)]
    pub worker_auth_key: Option<String>,
    #[serde(default)]
    pub zap_domain: Option<String>,
    #[serde(default)]
    pub sndhwm: Option<i32>,
    #[serde(default)]
    pub rcvhwm: Option<i32>,
    #[serde(default)]
    pub linger_ms: Option<i32>,
    #[serde(default)]
    pub sndtimeo_ms: Option<i32>,
    #[serde(default)]
    pub rcvtimeo_ms: Option<i32>,
    #[serde(default)]
    pub poll_interval_ms: Option<u64>,
    #[serde(default)]
    pub command_timeout_ms: Option<u64>,
}

/// Configuration for one computer-worker DEALER socket.
///
/// The DEALER identity is the worker connection route seen by the control plane.
#[derive(Clone, Debug, Deserialize)]
pub struct DealerConfig {
    pub endpoint: String,
    pub identity: String,
    pub username: String,
    pub password: String,
    #[serde(default)]
    pub sndhwm: Option<i32>,
    #[serde(default)]
    pub rcvhwm: Option<i32>,
    #[serde(default)]
    pub linger_ms: Option<i32>,
    #[serde(default)]
    pub sndtimeo_ms: Option<i32>,
    #[serde(default)]
    pub rcvtimeo_ms: Option<i32>,
    #[serde(default)]
    pub poll_interval_ms: Option<u64>,
    #[serde(default)]
    pub command_timeout_ms: Option<u64>,
}

#[derive(Clone, Debug)]
pub enum RouterEvent {
    Received {
        transport_route: String,
        authenticated_worker_id: Option<String>,
        authenticated_key_revision: Option<i64>,
        envelope_json: String,
    },
    FileFrame {
        transport_route: String,
        authenticated_worker_id: Option<String>,
        authenticated_key_revision: Option<i64>,
        frames: Vec<Vec<u8>>,
    },
    DecodeFailed {
        transport_route: String,
        reason: String,
    },
    SocketError {
        reason: String,
    },
}

#[derive(Clone, Debug)]
struct AuthenticatedWorker {
    worker_id: String,
    key_revision: i64,
}

#[derive(Debug, Default)]
struct AuthenticatedRouteState {
    routes: HashMap<String, AuthenticatedWorker>,
    pending_by_worker_id: HashMap<String, VecDeque<AuthenticatedWorker>>,
}

type AuthenticatedRoutes = Arc<Mutex<AuthenticatedRouteState>>;

#[derive(Debug)]
pub enum DealerEvent {
    Received(Vec<u8>),
    FileFrame(Vec<Vec<u8>>),
    DecodeFailed(String),
    SocketError(String),
}

#[derive(Debug)]
pub enum SendOutcome {
    SentOrQueued,
}

#[derive(Clone, Debug)]
pub enum TransportError {
    UnknownRoute,
    Backpressure,
    Timeout,
    SocketClosed,
    InvalidFrame(String),
    Zmq(String),
}

impl fmt::Display for TransportError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::UnknownRoute => write!(f, "unknown_route"),
            Self::Backpressure => write!(f, "backpressure"),
            Self::Timeout => write!(f, "timeout"),
            Self::SocketClosed => write!(f, "socket_closed"),
            Self::InvalidFrame(reason) => write!(f, "invalid_frame: {reason}"),
            Self::Zmq(reason) => write!(f, "zmq: {reason}"),
        }
    }
}

impl std::error::Error for TransportError {}

impl From<TransportError> for KernelError {
    fn from(error: TransportError) -> Self {
        KernelError::new(error.to_string())
    }
}

type RouterEventSink = Arc<dyn Fn(RouterEvent) + Send + Sync + 'static>;

enum RouterCommand {
    Send {
        route: String,
        payload: Vec<u8>,
        reply: mpsc::Sender<Result<SendOutcome, TransportError>>,
    },
    SendFileFrame {
        route: String,
        frames: Vec<Vec<u8>>,
        reply: mpsc::Sender<Result<SendOutcome, TransportError>>,
    },
    Stop {
        reply: mpsc::Sender<Result<(), TransportError>>,
    },
}

enum DealerCommand {
    Send {
        payload: Vec<u8>,
        reply: mpsc::Sender<Result<SendOutcome, TransportError>>,
    },
    SendFileFrame {
        frames: Vec<Vec<u8>>,
        reply: mpsc::Sender<Result<SendOutcome, TransportError>>,
    },
    Stop {
        reply: mpsc::Sender<Result<(), TransportError>>,
    },
}

pub struct RouterHandle {
    endpoint: String,
    command_timeout: Duration,
    commands: mpsc::Sender<RouterCommand>,
    stop: Arc<AtomicBool>,
}

impl RouterHandle {
    /// Returns the endpoint actually bound by the ROUTER socket.
    pub fn endpoint(&self) -> &str {
        &self.endpoint
    }

    /// Sends an envelope to one worker route and reports mandatory-send errors.
    ///
    /// The payload is encoded through the RuntimeFabric codec before it reaches
    /// the socket thread, so transport code never sees partially valid envelopes.
    pub fn send_mandatory(
        &self,
        transport_route: impl Into<String>,
        envelope_json: serde_json::Value,
    ) -> Result<SendOutcome, TransportError> {
        let payload =
            runtime_fabric::encode_envelope_json(envelope_json).map_err(TransportError::from)?;
        let (reply_tx, reply_rx) = mpsc::channel();

        self.commands
            .send(RouterCommand::Send {
                route: transport_route.into(),
                payload,
                reply: reply_tx,
            })
            .map_err(|_| TransportError::SocketClosed)?;

        reply_rx
            .recv_timeout(self.command_timeout)
            .map_err(|_| TransportError::Timeout)?
    }

    /// Sends one raw worker-file frame set to a worker route.
    ///
    /// File transfer frames are RuntimeFabric data-plane traffic. They are raw
    /// ZeroMQ multipart frames and intentionally bypass the protobuf envelope
    /// codec used by the actor and RPC lanes.
    pub fn send_file_frame(
        &self,
        transport_route: impl Into<String>,
        frames: Vec<Vec<u8>>,
    ) -> Result<SendOutcome, TransportError> {
        validate_file_transfer_frames(&frames)?;
        let (reply_tx, reply_rx) = mpsc::channel();

        self.commands
            .send(RouterCommand::SendFileFrame {
                route: transport_route.into(),
                frames,
                reply: reply_tx,
            })
            .map_err(|_| TransportError::SocketClosed)?;

        reply_rx
            .recv_timeout(self.command_timeout)
            .map_err(|_| TransportError::Timeout)?
    }

    /// Stops the router thread and waits for the socket loop to acknowledge it.
    pub fn stop(&self) -> Result<(), TransportError> {
        let (reply_tx, reply_rx) = mpsc::channel();

        self.commands
            .send(RouterCommand::Stop { reply: reply_tx })
            .map_err(|_| TransportError::SocketClosed)?;

        reply_rx
            .recv_timeout(self.command_timeout)
            .map_err(|_| TransportError::Timeout)?
    }
}

impl Drop for RouterHandle {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::SeqCst);
        let (reply_tx, _reply_rx) = mpsc::channel();
        let _ = self.commands.send(RouterCommand::Stop { reply: reply_tx });
    }
}

#[derive(Clone)]
pub struct DealerHandle {
    inner: Arc<DealerHandleInner>,
}

// Async N-API receive tasks need to hold a temporary clone while JS continues
// using the worker transport. The underlying DEALER must therefore be closed by
// the last shared handle, not by every clone that leaves a native worker thread.
struct DealerHandleInner {
    command_timeout: Duration,
    commands: mpsc::Sender<DealerCommand>,
    inbox: Arc<DealerInbox>,
    stop: Arc<AtomicBool>,
}

struct DealerInbox {
    state: Mutex<DealerInboxState>,
    available: Condvar,
}

struct DealerInboxState {
    queue: VecDeque<DealerEvent>,
    closed: bool,
}

impl DealerInbox {
    fn new() -> Self {
        Self {
            state: Mutex::new(DealerInboxState {
                queue: VecDeque::new(),
                closed: false,
            }),
            available: Condvar::new(),
        }
    }

    fn push(&self, event: DealerEvent) {
        if let Ok(mut state) = self.state.lock() {
            if !state.closed {
                state.queue.push_back(event);
                self.available.notify_one();
            }
        }
    }

    fn close(&self) {
        if let Ok(mut state) = self.state.lock() {
            state.closed = true;
            self.available.notify_all();
        }
    }

    fn recv(&self, timeout: Duration) -> Result<Option<DealerEvent>, TransportError> {
        let mut state = self
            .state
            .lock()
            .map_err(|_| TransportError::SocketClosed)?;

        loop {
            if let Some(event) = state.queue.pop_front() {
                return Ok(Some(event));
            }

            if state.closed {
                return Err(TransportError::SocketClosed);
            }

            let (next_state, wait_result) = self
                .available
                .wait_timeout(state, timeout)
                .map_err(|_| TransportError::SocketClosed)?;

            state = next_state;

            if wait_result.timed_out() {
                return Ok(None);
            }
        }
    }
}

impl DealerHandle {
    /// Sends a JSON-shaped RuntimeFabric envelope from the worker to the control plane.
    pub fn send_envelope(
        &self,
        envelope_json: serde_json::Value,
    ) -> Result<SendOutcome, TransportError> {
        let payload =
            runtime_fabric::encode_envelope_json(envelope_json).map_err(TransportError::from)?;
        self.send_payload(payload)
    }

    /// Sends already encoded protobuf bytes from the worker socket.
    pub fn send_payload(&self, payload: Vec<u8>) -> Result<SendOutcome, TransportError> {
        let (reply_tx, reply_rx) = mpsc::channel();

        self.inner
            .commands
            .send(DealerCommand::Send {
                payload,
                reply: reply_tx,
            })
            .map_err(|_| TransportError::SocketClosed)?;

        reply_rx
            .recv_timeout(self.inner.command_timeout)
            .map_err(|_| TransportError::Timeout)?
    }

    /// Sends one raw worker-file frame set from the worker socket.
    pub fn send_file_frame(&self, frames: Vec<Vec<u8>>) -> Result<SendOutcome, TransportError> {
        validate_file_transfer_frames(&frames)?;
        let (reply_tx, reply_rx) = mpsc::channel();

        self.inner
            .commands
            .send(DealerCommand::SendFileFrame {
                frames,
                reply: reply_tx,
            })
            .map_err(|_| TransportError::SocketClosed)?;

        reply_rx
            .recv_timeout(self.inner.command_timeout)
            .map_err(|_| TransportError::Timeout)?
    }

    /// Receives the next control-plane event for the worker.
    ///
    /// A timeout returns `Ok(None)` so the worker loop can also send heartbeats
    /// and observe shutdown signals.
    pub fn recv(&self, timeout: Duration) -> Result<Option<DealerEvent>, TransportError> {
        self.inner.inbox.recv(timeout)
    }

    /// Stops the dealer thread and closes the worker transport.
    pub fn stop(&self) -> Result<(), TransportError> {
        let (reply_tx, reply_rx) = mpsc::channel();

        let command_result = self
            .inner
            .commands
            .send(DealerCommand::Stop { reply: reply_tx })
            .map_err(|_| TransportError::SocketClosed)
            .and_then(|_| {
                reply_rx
                    .recv_timeout(self.inner.command_timeout)
                    .map_err(|_| TransportError::Timeout)?
            });

        self.inner.inbox.close();
        command_result
    }
}

impl Drop for DealerHandleInner {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::SeqCst);
        let (reply_tx, _reply_rx) = mpsc::channel();
        let _ = self.commands.send(DealerCommand::Stop { reply: reply_tx });
        self.inbox.close();
    }
}

impl RouterConfig {
    /// Parses router config from a JSON string passed through a host binding.
    pub fn from_json(json: &str) -> KernelResult<Self> {
        serde_json::from_str(json)
            .map_err(|error| KernelError::new(format!("invalid router config JSON: {error}")))
    }

    fn validate(&self) -> Result<(), TransportError> {
        validate_non_empty("endpoint", &self.endpoint)?;
        if let Some(key) = &self.worker_auth_key {
            validate_non_empty("worker_auth_key", key)?;
        }
        validate_optional_positive("sndhwm", self.sndhwm)?;
        validate_optional_positive("rcvhwm", self.rcvhwm)?;
        Ok(())
    }

    fn zap_domain(&self) -> String {
        self.zap_domain
            .clone()
            .unwrap_or_else(|| DEFAULT_ZAP_DOMAIN.to_string())
    }

    fn command_timeout(&self) -> Duration {
        Duration::from_millis(
            self.command_timeout_ms
                .unwrap_or(DEFAULT_COMMAND_TIMEOUT_MS),
        )
    }

    fn poll_interval(&self) -> Duration {
        Duration::from_millis(self.poll_interval_ms.unwrap_or(DEFAULT_POLL_INTERVAL_MS))
    }
}

impl DealerConfig {
    /// Parses dealer config from a JSON string passed through a host binding.
    pub fn from_json(json: &str) -> KernelResult<Self> {
        serde_json::from_str(json)
            .map_err(|error| KernelError::new(format!("invalid dealer config JSON: {error}")))
    }

    fn validate(&self) -> Result<(), TransportError> {
        validate_non_empty("endpoint", &self.endpoint)?;
        validate_non_empty("identity", &self.identity)?;
        validate_non_empty("username", &self.username)?;
        validate_non_empty("password", &self.password)?;
        validate_optional_positive("sndhwm", self.sndhwm)?;
        validate_optional_positive("rcvhwm", self.rcvhwm)?;
        Ok(())
    }

    fn command_timeout(&self) -> Duration {
        Duration::from_millis(
            self.command_timeout_ms
                .unwrap_or(DEFAULT_COMMAND_TIMEOUT_MS),
        )
    }

    fn poll_interval(&self) -> Duration {
        Duration::from_millis(self.poll_interval_ms.unwrap_or(DEFAULT_POLL_INTERVAL_MS))
    }
}

#[derive(Clone, Debug)]
enum ZapAuthConfig {
    GlobalWorkerKey { worker_auth_key: String },
}

fn zap_auth_config(config: &RouterConfig) -> Option<ZapAuthConfig> {
    config
        .worker_auth_key
        .clone()
        .map(|worker_auth_key| ZapAuthConfig::GlobalWorkerKey { worker_auth_key })
}

/// Starts the control-plane ROUTER socket on its own thread.
///
/// ZeroMQ sockets are thread-affine. Commands cross into the socket thread over
/// channels, while received envelopes return to the host through the sink.
pub fn start_router(config: RouterConfig, sink: RouterEventSink) -> KernelResult<RouterHandle> {
    config.validate().map_err(KernelError::from)?;

    let (command_tx, command_rx) = mpsc::channel();
    let (init_tx, init_rx) = mpsc::sync_channel(1);
    let stop = Arc::new(AtomicBool::new(false));
    let thread_stop = Arc::clone(&stop);
    let command_timeout = config.command_timeout();

    thread::Builder::new()
        .name("ankole-runtime-fabric-router".to_string())
        .spawn(move || run_router(config, command_rx, init_tx, sink, thread_stop))
        .map_err(|error| KernelError::new(format!("failed to spawn router thread: {error}")))?;

    let endpoint = init_rx
        .recv_timeout(command_timeout)
        .map_err(|_| KernelError::new("timed out starting actor lane router"))?
        .map_err(KernelError::from)?;

    Ok(RouterHandle {
        endpoint,
        command_timeout,
        commands: command_tx,
        stop,
    })
}

/// Starts a computer-worker DEALER socket on its own thread.
///
/// The handle exposes a blocking inbox so the Bun worker can run a simple loop
/// without knowing about ZeroMQ polling.
pub fn start_dealer(config: DealerConfig) -> KernelResult<DealerHandle> {
    config.validate().map_err(KernelError::from)?;

    let (command_tx, command_rx) = mpsc::channel();
    let (init_tx, init_rx) = mpsc::sync_channel(1);
    let inbox = Arc::new(DealerInbox::new());
    let thread_inbox = Arc::clone(&inbox);
    let stop = Arc::new(AtomicBool::new(false));
    let thread_stop = Arc::clone(&stop);
    let command_timeout = config.command_timeout();

    thread::Builder::new()
        .name("ankole-runtime-fabric-dealer".to_string())
        .spawn(move || run_dealer(config, command_rx, init_tx, thread_inbox, thread_stop))
        .map_err(|error| KernelError::new(format!("failed to spawn dealer thread: {error}")))?;

    init_rx
        .recv_timeout(command_timeout)
        .map_err(|_| KernelError::new("timed out starting actor lane dealer"))?
        .map_err(KernelError::from)?;

    Ok(DealerHandle {
        inner: Arc::new(DealerHandleInner {
            command_timeout,
            commands: command_tx,
            inbox,
            stop,
        }),
    })
}

// Runs the ROUTER loop. It drains control-plane commands first so sends and
// stops are not delayed behind an idle receive poll.
fn run_router(
    config: RouterConfig,
    commands: mpsc::Receiver<RouterCommand>,
    init: mpsc::SyncSender<Result<String, TransportError>>,
    sink: RouterEventSink,
    stop: Arc<AtomicBool>,
) {
    let context = zmq::Context::new();
    let zap_stop = Arc::clone(&stop);
    let auth_routes = Arc::new(Mutex::new(AuthenticatedRouteState::default()));
    let zap_auth = zap_auth_config(&config);
    let requires_auth = zap_auth.is_some();
    let zap_guard = match zap_auth {
        Some(auth) => start_zap_server(
            &context,
            config.zap_domain(),
            auth,
            Arc::clone(&auth_routes),
            zap_stop,
        ),
        None => Ok(None),
    };

    let socket_result = zap_guard.and_then(|zap| {
        let socket = context.socket(zmq::ROUTER).map_err(transport_error)?;
        configure_common_socket(&socket, &config)?;
        // Mandatory routing is the transport-level signal that a worker route
        // is gone. ActorRuntime turns that into stale worker state and
        // retryable delivery projections.
        socket.set_router_mandatory(true).map_err(transport_error)?;

        if requires_auth {
            socket.set_plain_server(true).map_err(transport_error)?;
            socket
                .set_zap_domain(&config.zap_domain())
                .map_err(transport_error)?;
        }

        socket.bind(&config.endpoint).map_err(transport_error)?;
        let endpoint = socket
            .get_last_endpoint()
            .map_err(transport_error)?
            .unwrap_or_else(|_| config.endpoint.clone());

        Ok((socket, endpoint, zap))
    });

    let (socket, endpoint, _zap) = match socket_result {
        Ok(value) => value,
        Err(error) => {
            let _ = init.send(Err(error));
            return;
        }
    };

    let _ = init.send(Ok(endpoint));
    let poll_interval = config.poll_interval();

    while !stop.load(Ordering::SeqCst) {
        if !drain_router_commands(&socket, &commands) {
            stop.store(true, Ordering::SeqCst);
            break;
        }

        match socket.recv_multipart(zmq::DONTWAIT) {
            Ok(frames) => emit_router_frames(&sink, requires_auth, &auth_routes, frames),
            Err(zmq::Error::EAGAIN) => thread::sleep(poll_interval),
            Err(zmq::Error::ETERM) => break,
            Err(error) => {
                sink(RouterEvent::SocketError {
                    reason: error.to_string(),
                });
                thread::sleep(poll_interval);
            }
        }
    }
}

// Runs the worker DEALER loop. The DEALER identity is the transport route used
// by the control plane after worker admission.
fn run_dealer(
    config: DealerConfig,
    commands: mpsc::Receiver<DealerCommand>,
    init: mpsc::SyncSender<Result<(), TransportError>>,
    inbox: Arc<DealerInbox>,
    stop: Arc<AtomicBool>,
) {
    let context = zmq::Context::new();
    let socket_result = context
        .socket(zmq::DEALER)
        .map_err(transport_error)
        .and_then(|socket| {
            configure_common_socket(&socket, &config)?;
            socket
                .set_identity(config.identity.as_bytes())
                .map_err(transport_error)?;
            socket
                .set_plain_username(Some(&config.username))
                .map_err(transport_error)?;
            socket
                .set_plain_password(Some(&config.password))
                .map_err(transport_error)?;
            socket.connect(&config.endpoint).map_err(transport_error)?;
            Ok(socket)
        });

    let socket = match socket_result {
        Ok(socket) => socket,
        Err(error) => {
            let _ = init.send(Err(error));
            return;
        }
    };

    let _ = init.send(Ok(()));
    let poll_interval = config.poll_interval();

    while !stop.load(Ordering::SeqCst) {
        if !drain_dealer_commands(&socket, &commands) {
            stop.store(true, Ordering::SeqCst);
            break;
        }

        match socket.recv_multipart(zmq::DONTWAIT) {
            Ok(frames) => emit_dealer_frames(&inbox, frames),
            Err(zmq::Error::EAGAIN) => thread::sleep(poll_interval),
            Err(zmq::Error::ETERM) => break,
            Err(error) => {
                inbox.push(DealerEvent::SocketError(error.to_string()));
                thread::sleep(poll_interval);
            }
        }
    }
}

fn drain_router_commands(socket: &zmq::Socket, commands: &mpsc::Receiver<RouterCommand>) -> bool {
    while let Ok(command) = commands.try_recv() {
        match command {
            RouterCommand::Send {
                route,
                payload,
                reply,
            } => {
                let outcome = send_router_payload(socket, route, payload);
                let _ = reply.send(outcome);
            }
            RouterCommand::SendFileFrame {
                route,
                frames,
                reply,
            } => {
                let outcome = send_router_file_frame(socket, route, frames);
                let _ = reply.send(outcome);
            }
            RouterCommand::Stop { reply } => {
                let _ = reply.send(Ok(()));
                return false;
            }
        }
    }

    true
}

fn drain_dealer_commands(socket: &zmq::Socket, commands: &mpsc::Receiver<DealerCommand>) -> bool {
    while let Ok(command) = commands.try_recv() {
        match command {
            DealerCommand::Send { payload, reply } => {
                let outcome = send_dealer_frames(socket, vec![payload]);
                let _ = reply.send(outcome);
            }
            DealerCommand::SendFileFrame { frames, reply } => {
                let outcome = send_dealer_frames(socket, frames);
                let _ = reply.send(outcome);
            }
            DealerCommand::Stop { reply } => {
                let _ = reply.send(Ok(()));
                return false;
            }
        }
    }

    true
}

// Worker-to-control sends are allowed to wait for the socket's bounded
// `sndtimeo`. A freshly connected DEALER can otherwise report EAGAIN before the
// ROUTER pipe is writable, which makes worker startup depend on a race. ROUTER
// mandatory sends below stay non-blocking because actor delivery needs immediate
// unknown-route/backpressure feedback.
fn send_dealer_frames(
    socket: &zmq::Socket,
    frames: Vec<Vec<u8>>,
) -> Result<SendOutcome, TransportError> {
    socket
        .send_multipart(frames, 0)
        .map(|_| SendOutcome::SentOrQueued)
        .map_err(map_send_error)
}

// Sends the ROUTER multipart frame shape: worker route identity followed by the
// protobuf envelope payload.
fn send_router_payload(
    socket: &zmq::Socket,
    route: String,
    payload: Vec<u8>,
) -> Result<SendOutcome, TransportError> {
    socket
        .send_multipart(vec![route.into_bytes(), payload], zmq::DONTWAIT)
        .map(|_| SendOutcome::SentOrQueued)
        .map_err(map_send_error)
}

fn send_router_file_frame(
    socket: &zmq::Socket,
    route: String,
    frames: Vec<Vec<u8>>,
) -> Result<SendOutcome, TransportError> {
    validate_file_transfer_frames(&frames)?;

    let mut routed_frames = Vec::with_capacity(frames.len() + 1);
    routed_frames.push(route.into_bytes());
    routed_frames.extend(frames);

    socket
        .send_multipart(routed_frames, zmq::DONTWAIT)
        .map(|_| SendOutcome::SentOrQueued)
        .map_err(map_send_error)
}

// Decodes inbound worker frames before crossing back into Elixir. Bad protobuf
// never reaches ActorRuntime handlers as a normal envelope.
fn emit_router_frames(
    sink: &RouterEventSink,
    requires_auth: bool,
    auth_routes: &AuthenticatedRoutes,
    frames: Vec<Vec<u8>>,
) {
    match parse_router_frames(frames) {
        Ok(RouterInbound::Envelope { route, payload }) => {
            match runtime_fabric::decode_envelope_json(&payload) {
                Ok(envelope_json) => {
                    let auth = if requires_auth {
                        match authenticated_envelope_route(auth_routes, &route, &envelope_json) {
                            Some(auth) => Some(auth),
                            None => {
                                sink(RouterEvent::DecodeFailed {
                                    transport_route: route,
                                    reason: "unauthenticated_route".to_string(),
                                });
                                return;
                            }
                        }
                    } else {
                        None
                    };

                    sink(RouterEvent::Received {
                        transport_route: route,
                        authenticated_worker_id: auth.as_ref().map(|auth| auth.worker_id.clone()),
                        authenticated_key_revision: auth.as_ref().map(|auth| auth.key_revision),
                        envelope_json: envelope_json.to_string(),
                    });
                }
                Err(error) => sink(RouterEvent::DecodeFailed {
                    transport_route: route,
                    reason: error.to_string(),
                }),
            }
        }
        Ok(RouterInbound::FileFrame { route, frames }) => {
            let auth = if requires_auth {
                match authenticated_route(auth_routes, &route) {
                    Some(auth) => Some(auth),
                    None => {
                        sink(RouterEvent::DecodeFailed {
                            transport_route: route,
                            reason: "unauthenticated_route".to_string(),
                        });
                        return;
                    }
                }
            } else {
                None
            };

            sink(RouterEvent::FileFrame {
                transport_route: route,
                authenticated_worker_id: auth.as_ref().map(|auth| auth.worker_id.clone()),
                authenticated_key_revision: auth.as_ref().map(|auth| auth.key_revision),
                frames,
            });
        }
        Err((route, error)) => sink(RouterEvent::DecodeFailed {
            transport_route: route.unwrap_or_default(),
            reason: error.to_string(),
        }),
    }
}

fn authenticated_route(
    auth_routes: &AuthenticatedRoutes,
    route: &str,
) -> Option<AuthenticatedWorker> {
    let state = auth_routes.lock().ok()?;

    state.routes.get(route).cloned()
}

fn authenticated_envelope_route(
    auth_routes: &AuthenticatedRoutes,
    route: &str,
    envelope_json: &serde_json::Value,
) -> Option<AuthenticatedWorker> {
    if let Some(authenticated) = authenticated_route(auth_routes, route) {
        if let Some(worker_id) = worker_ready_id(envelope_json) {
            return (authenticated.worker_id == worker_id).then_some(authenticated);
        }

        return Some(authenticated);
    }

    let worker_id = worker_ready_id(envelope_json)?;
    bind_authenticated_ready_route(auth_routes, route, worker_id)
}

fn worker_ready_id(envelope_json: &serde_json::Value) -> Option<&str> {
    let body = envelope_json.get("body")?;

    if body.get("type")?.as_str()? != "worker_ready" {
        return None;
    }

    body.get("worker_ready")?.get("worker_id")?.as_str()
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

// Stores inbound control-plane frames for the worker loop. Decode errors stay
// visible so the worker can log them or fail tests deterministically.
fn emit_dealer_frames(inbox: &DealerInbox, frames: Vec<Vec<u8>>) {
    match parse_dealer_frames(frames) {
        Ok(DealerInbound::Envelope(payload)) => inbox.push(DealerEvent::Received(payload)),
        Ok(DealerInbound::FileFrame(frames)) => inbox.push(DealerEvent::FileFrame(frames)),
        Err(error) => inbox.push(DealerEvent::DecodeFailed(error.to_string())),
    }
}

#[derive(Debug)]
enum RouterInbound {
    Envelope { route: String, payload: Vec<u8> },
    FileFrame { route: String, frames: Vec<Vec<u8>> },
}

#[derive(Debug)]
enum DealerInbound {
    Envelope(Vec<u8>),
    FileFrame(Vec<Vec<u8>>),
}

// Parses ROUTER frames from DEALER workers. A leading empty delimiter is
// tolerated so tests and proxies can use common multipart conventions.
fn parse_router_frames(
    frames: Vec<Vec<u8>>,
) -> Result<RouterInbound, (Option<String>, TransportError)> {
    if frames.len() < 2 {
        return Err((
            None,
            TransportError::InvalidFrame("router message must include route and payload".into()),
        ));
    }

    let route = String::from_utf8(frames[0].clone()).map_err(|error| {
        (
            None,
            TransportError::InvalidFrame(format!("route identity must be UTF-8: {error}")),
        )
    })?;
    let payload_index = if frames.len() >= 3 && frames[1].is_empty() {
        2
    } else {
        1
    };

    if frames[payload_index].as_slice() == FILE_TRANSFER_PROTOCOL {
        Ok(RouterInbound::FileFrame {
            route,
            frames: frames[payload_index..].to_vec(),
        })
    } else {
        Ok(RouterInbound::Envelope {
            route,
            payload: frames[payload_index].clone(),
        })
    }
}

// Parses worker-side frames. ROUTER sends usually arrive as one payload frame,
// but delimiter and extra identity frames are tolerated for interoperability.
fn parse_dealer_frames(frames: Vec<Vec<u8>>) -> Result<DealerInbound, TransportError> {
    if frames.is_empty() {
        return Err(TransportError::InvalidFrame(
            "dealer message must include a payload".into(),
        ));
    }

    if frames[0].as_slice() == FILE_TRANSFER_PROTOCOL {
        return Ok(DealerInbound::FileFrame(frames));
    }

    if frames.len() >= 2 && frames[0].is_empty() {
        if frames[1].as_slice() == FILE_TRANSFER_PROTOCOL {
            return Ok(DealerInbound::FileFrame(frames[1..].to_vec()));
        }

        return Ok(DealerInbound::Envelope(frames[1].clone()));
    }

    if frames.len() >= 2 && frames[1].as_slice() == FILE_TRANSFER_PROTOCOL {
        return Ok(DealerInbound::FileFrame(frames[1..].to_vec()));
    }

    Ok(DealerInbound::Envelope(frames[0].clone()))
}

// Starts the inproc ZAP server used by ZeroMQ PLAIN auth. This is a pre-auth
// token gate for worker bootstrap, not a user authorization system.
fn start_zap_server(
    context: &zmq::Context,
    domain: String,
    auth: ZapAuthConfig,
    auth_routes: AuthenticatedRoutes,
    stop: Arc<AtomicBool>,
) -> Result<Option<ZapGuard>, TransportError> {
    validate_non_empty("zap_domain", &domain)?;

    let context = context.clone();
    let (init_tx, init_rx) = mpsc::sync_channel(1);

    let handle = thread::Builder::new()
        .name("ankole-runtime-fabric-zap".to_string())
        .spawn(move || run_zap_server(context, domain, auth, auth_routes, stop, init_tx))
        .map_err(|error| TransportError::Zmq(format!("failed to spawn ZAP thread: {error}")))?;

    init_rx
        .recv_timeout(Duration::from_secs(1))
        .map_err(|_| TransportError::Timeout)?
        .map(|_| {
            Some(ZapGuard {
                handle: Some(handle),
            })
        })
}

struct ZapGuard {
    handle: Option<thread::JoinHandle<()>>,
}

impl Drop for ZapGuard {
    fn drop(&mut self) {
        if let Some(handle) = self.handle.take() {
            let start = Instant::now();
            while !handle.is_finished() && start.elapsed() < Duration::from_millis(100) {
                thread::sleep(Duration::from_millis(5));
            }
        }
    }
}

fn run_zap_server(
    context: zmq::Context,
    domain: String,
    auth: ZapAuthConfig,
    auth_routes: AuthenticatedRoutes,
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
            Err(_) => {}
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
            state
                .routes
                .insert(route.to_string(), authenticated.clone());
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

trait CommonSocketConfig {
    fn sndhwm(&self) -> Option<i32>;
    fn rcvhwm(&self) -> Option<i32>;
    fn linger_ms(&self) -> Option<i32>;
    fn sndtimeo_ms(&self) -> Option<i32>;
    fn rcvtimeo_ms(&self) -> Option<i32>;
}

impl CommonSocketConfig for RouterConfig {
    fn sndhwm(&self) -> Option<i32> {
        self.sndhwm
    }

    fn rcvhwm(&self) -> Option<i32> {
        self.rcvhwm
    }

    fn linger_ms(&self) -> Option<i32> {
        self.linger_ms
    }

    fn sndtimeo_ms(&self) -> Option<i32> {
        self.sndtimeo_ms
    }

    fn rcvtimeo_ms(&self) -> Option<i32> {
        self.rcvtimeo_ms
    }
}

impl CommonSocketConfig for DealerConfig {
    fn sndhwm(&self) -> Option<i32> {
        self.sndhwm
    }

    fn rcvhwm(&self) -> Option<i32> {
        self.rcvhwm
    }

    fn linger_ms(&self) -> Option<i32> {
        self.linger_ms
    }

    fn sndtimeo_ms(&self) -> Option<i32> {
        self.sndtimeo_ms
    }

    fn rcvtimeo_ms(&self) -> Option<i32> {
        self.rcvtimeo_ms
    }
}

// Applies bounded queues and timeouts to both socket roles. Defaults favor
// predictable shutdown and backpressure over unbounded buffering.
fn configure_common_socket<T: CommonSocketConfig>(
    socket: &zmq::Socket,
    config: &T,
) -> Result<(), TransportError> {
    socket
        .set_sndhwm(config.sndhwm().unwrap_or(DEFAULT_HWM))
        .map_err(transport_error)?;
    socket
        .set_rcvhwm(config.rcvhwm().unwrap_or(DEFAULT_HWM))
        .map_err(transport_error)?;
    socket
        .set_linger(config.linger_ms().unwrap_or(DEFAULT_LINGER_MS))
        .map_err(transport_error)?;
    socket
        .set_sndtimeo(config.sndtimeo_ms().unwrap_or(DEFAULT_IO_TIMEOUT_MS))
        .map_err(transport_error)?;
    socket
        .set_rcvtimeo(config.rcvtimeo_ms().unwrap_or(DEFAULT_IO_TIMEOUT_MS))
        .map_err(transport_error)?;
    Ok(())
}

fn validate_non_empty(field: &str, value: &str) -> Result<(), TransportError> {
    if value.trim().is_empty() {
        Err(TransportError::InvalidFrame(format!(
            "{field} must not be empty"
        )))
    } else {
        Ok(())
    }
}

fn validate_file_transfer_frames(frames: &[Vec<u8>]) -> Result<(), TransportError> {
    match frames.first() {
        Some(protocol) if protocol.as_slice() == FILE_TRANSFER_PROTOCOL => Ok(()),
        Some(_) => Err(TransportError::InvalidFrame(
            "worker file frames must start with ANKOLE_FILE/1".into(),
        )),
        None => Err(TransportError::InvalidFrame(
            "worker file frame set must not be empty".into(),
        )),
    }
}

fn validate_optional_positive(field: &str, value: Option<i32>) -> Result<(), TransportError> {
    match value {
        Some(value) if value <= 0 => Err(TransportError::InvalidFrame(format!(
            "{field} must be positive"
        ))),
        _ => Ok(()),
    }
}

// Maps ZeroMQ send failures into actor-runtime scheduling language.
fn map_send_error(error: zmq::Error) -> TransportError {
    match error {
        zmq::Error::EHOSTUNREACH => TransportError::UnknownRoute,
        zmq::Error::EAGAIN => TransportError::Backpressure,
        zmq::Error::ETERM => TransportError::SocketClosed,
        error => transport_error(error),
    }
}

fn transport_error(error: zmq::Error) -> TransportError {
    TransportError::Zmq(error.to_string())
}

impl From<KernelError> for TransportError {
    fn from(error: KernelError) -> Self {
        TransportError::Zmq(error.to_string())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

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

        let router = start_router(
            RouterConfig {
                endpoint: "tcp://127.0.0.1:*".to_string(),
                worker_auth_key: Some("test-token".to_string()),
                zap_domain: None,
                sndhwm: None,
                rcvhwm: None,
                linger_ms: None,
                sndtimeo_ms: None,
                rcvtimeo_ms: None,
                poll_interval_ms: Some(1),
                command_timeout_ms: Some(1_000),
            },
            sink,
        )
        .expect("router starts");

        let dealer = start_dealer(DealerConfig {
            endpoint: router.endpoint().to_string(),
            identity: "worker-instance-a".to_string(),
            username: "worker-a".to_string(),
            password: "test-token".to_string(),
            sndhwm: None,
            rcvhwm: None,
            linger_ms: None,
            sndtimeo_ms: None,
            rcvtimeo_ms: None,
            poll_interval_ms: Some(1),
            command_timeout_ms: Some(1_000),
        })
        .expect("dealer starts");

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
        let envelope = runtime_fabric::decode_envelope_json(&payload).expect("turn.start decodes");
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
            "seq": 0,
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
                        "broker_sequence": 1,
                        "type": "im.message.addressed",
                        "ingress_event_id": "event-a",
                        "payload_json": {"text": "PING"}
                    }]
                }
            }
        })
    }
}
