#![allow(dead_code)]

use std::collections::VecDeque;
use std::fmt;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Condvar, Mutex, mpsc};
use std::thread;
use std::time::{Duration, Instant};

use serde::Deserialize;

use crate::actor_bus;
use crate::core::{KernelError, KernelResult};

const ZAP_ENDPOINT: &str = "inproc://zeromq.zap.01";
const DEFAULT_ZAP_DOMAIN: &str = "ankole-actor-bus";
const DEFAULT_POLL_INTERVAL_MS: u64 = 10;
const DEFAULT_COMMAND_TIMEOUT_MS: u64 = 1_000;
const DEFAULT_IO_TIMEOUT_MS: i32 = 1_000;
const DEFAULT_HWM: i32 = 1_000;
const DEFAULT_LINGER_MS: i32 = 0;

#[derive(Clone, Debug, Deserialize)]
pub struct RouterConfig {
    #[serde(default)]
    pub endpoint: String,
    #[serde(default)]
    pub pre_auth_token: Option<String>,
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
        envelope_json: String,
    },
    DecodeFailed {
        transport_route: String,
        reason: String,
    },
    SocketError {
        reason: String,
    },
}

#[derive(Debug)]
pub enum DealerEvent {
    Received(Vec<u8>),
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
    Stop {
        reply: mpsc::Sender<Result<(), TransportError>>,
    },
}

enum DealerCommand {
    Send {
        payload: Vec<u8>,
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
    pub fn endpoint(&self) -> &str {
        &self.endpoint
    }

    pub fn send_mandatory(
        &self,
        transport_route: impl Into<String>,
        envelope_json: serde_json::Value,
    ) -> Result<SendOutcome, TransportError> {
        let payload =
            actor_bus::encode_envelope_json(envelope_json).map_err(TransportError::from)?;
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

pub struct DealerHandle {
    command_timeout: Duration,
    commands: mpsc::Sender<DealerCommand>,
    inbox: Arc<DealerInbox>,
    stop: Arc<AtomicBool>,
}

struct DealerInbox {
    queue: Mutex<VecDeque<DealerEvent>>,
    available: Condvar,
}

impl DealerInbox {
    fn new() -> Self {
        Self {
            queue: Mutex::new(VecDeque::new()),
            available: Condvar::new(),
        }
    }

    fn push(&self, event: DealerEvent) {
        if let Ok(mut queue) = self.queue.lock() {
            queue.push_back(event);
            self.available.notify_one();
        }
    }

    fn recv(&self, timeout: Duration) -> Result<Option<DealerEvent>, TransportError> {
        let mut queue = self
            .queue
            .lock()
            .map_err(|_| TransportError::SocketClosed)?;

        if let Some(event) = queue.pop_front() {
            return Ok(Some(event));
        }

        let (mut queue, wait_result) = self
            .available
            .wait_timeout(queue, timeout)
            .map_err(|_| TransportError::SocketClosed)?;

        if wait_result.timed_out() {
            Ok(None)
        } else {
            Ok(queue.pop_front())
        }
    }
}

impl DealerHandle {
    pub fn send_envelope(
        &self,
        envelope_json: serde_json::Value,
    ) -> Result<SendOutcome, TransportError> {
        let payload =
            actor_bus::encode_envelope_json(envelope_json).map_err(TransportError::from)?;
        self.send_payload(payload)
    }

    pub fn send_payload(&self, payload: Vec<u8>) -> Result<SendOutcome, TransportError> {
        let (reply_tx, reply_rx) = mpsc::channel();

        self.commands
            .send(DealerCommand::Send {
                payload,
                reply: reply_tx,
            })
            .map_err(|_| TransportError::SocketClosed)?;

        reply_rx
            .recv_timeout(self.command_timeout)
            .map_err(|_| TransportError::Timeout)?
    }

    pub fn recv(&self, timeout: Duration) -> Result<Option<DealerEvent>, TransportError> {
        self.inbox.recv(timeout)
    }

    pub fn stop(&self) -> Result<(), TransportError> {
        let (reply_tx, reply_rx) = mpsc::channel();

        self.commands
            .send(DealerCommand::Stop { reply: reply_tx })
            .map_err(|_| TransportError::SocketClosed)?;

        reply_rx
            .recv_timeout(self.command_timeout)
            .map_err(|_| TransportError::Timeout)?
    }
}

impl Drop for DealerHandle {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::SeqCst);
        let (reply_tx, _reply_rx) = mpsc::channel();
        let _ = self.commands.send(DealerCommand::Stop { reply: reply_tx });
    }
}

impl RouterConfig {
    pub fn from_json(json: &str) -> KernelResult<Self> {
        serde_json::from_str(json)
            .map_err(|error| KernelError::new(format!("invalid router config JSON: {error}")))
    }

    fn validate(&self) -> Result<(), TransportError> {
        validate_non_empty("endpoint", &self.endpoint)?;
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

pub fn start_router(config: RouterConfig, sink: RouterEventSink) -> KernelResult<RouterHandle> {
    config.validate().map_err(KernelError::from)?;

    let (command_tx, command_rx) = mpsc::channel();
    let (init_tx, init_rx) = mpsc::sync_channel(1);
    let stop = Arc::new(AtomicBool::new(false));
    let thread_stop = Arc::clone(&stop);
    let command_timeout = config.command_timeout();

    thread::Builder::new()
        .name("ankole-actor-bus-router".to_string())
        .spawn(move || run_router(config, command_rx, init_tx, sink, thread_stop))
        .map_err(|error| KernelError::new(format!("failed to spawn router thread: {error}")))?;

    let endpoint = init_rx
        .recv_timeout(command_timeout)
        .map_err(|_| KernelError::new("timed out starting actor bus router"))?
        .map_err(KernelError::from)?;

    Ok(RouterHandle {
        endpoint,
        command_timeout,
        commands: command_tx,
        stop,
    })
}

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
        .name("ankole-actor-bus-dealer".to_string())
        .spawn(move || run_dealer(config, command_rx, init_tx, thread_inbox, thread_stop))
        .map_err(|error| KernelError::new(format!("failed to spawn dealer thread: {error}")))?;

    init_rx
        .recv_timeout(command_timeout)
        .map_err(|_| KernelError::new("timed out starting actor bus dealer"))?
        .map_err(KernelError::from)?;

    Ok(DealerHandle {
        command_timeout,
        commands: command_tx,
        inbox,
        stop,
    })
}

fn run_router(
    config: RouterConfig,
    commands: mpsc::Receiver<RouterCommand>,
    init: mpsc::SyncSender<Result<String, TransportError>>,
    sink: RouterEventSink,
    stop: Arc<AtomicBool>,
) {
    let context = zmq::Context::new();
    let zap_stop = Arc::clone(&stop);
    let zap_guard = match &config.pre_auth_token {
        Some(token) => start_zap_server(&context, config.zap_domain(), token.clone(), zap_stop),
        None => Ok(None),
    };

    let socket_result = zap_guard.and_then(|zap| {
        let socket = context.socket(zmq::ROUTER).map_err(transport_error)?;
        configure_common_socket(&socket, &config)?;
        socket.set_router_mandatory(true).map_err(transport_error)?;

        if config.pre_auth_token.is_some() {
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
            Ok(frames) => emit_router_frames(&sink, frames),
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
                let outcome = socket
                    .send_multipart(vec![payload], zmq::DONTWAIT)
                    .map(|_| SendOutcome::SentOrQueued)
                    .map_err(map_send_error);
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

fn emit_router_frames(sink: &RouterEventSink, frames: Vec<Vec<u8>>) {
    match parse_router_frames(frames) {
        Ok((route, payload)) => match actor_bus::decode_envelope_json(&payload) {
            Ok(envelope_json) => sink(RouterEvent::Received {
                transport_route: route,
                envelope_json: envelope_json.to_string(),
            }),
            Err(error) => sink(RouterEvent::DecodeFailed {
                transport_route: route,
                reason: error.to_string(),
            }),
        },
        Err((route, error)) => sink(RouterEvent::DecodeFailed {
            transport_route: route.unwrap_or_default(),
            reason: error.to_string(),
        }),
    }
}

fn emit_dealer_frames(inbox: &DealerInbox, frames: Vec<Vec<u8>>) {
    match parse_dealer_frames(frames) {
        Ok(payload) => inbox.push(DealerEvent::Received(payload)),
        Err(error) => inbox.push(DealerEvent::DecodeFailed(error.to_string())),
    }
}

fn parse_router_frames(
    frames: Vec<Vec<u8>>,
) -> Result<(String, Vec<u8>), (Option<String>, TransportError)> {
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

    Ok((route, frames[payload_index].clone()))
}

fn parse_dealer_frames(frames: Vec<Vec<u8>>) -> Result<Vec<u8>, TransportError> {
    match frames.as_slice() {
        [payload] => Ok(payload.clone()),
        [delimiter, payload, ..] if delimiter.is_empty() => Ok(payload.clone()),
        [] => Err(TransportError::InvalidFrame(
            "dealer message must include a payload".into(),
        )),
        [_first, payload, ..] => Ok(payload.clone()),
    }
}

fn start_zap_server(
    context: &zmq::Context,
    domain: String,
    password: String,
    stop: Arc<AtomicBool>,
) -> Result<Option<ZapGuard>, TransportError> {
    validate_non_empty("zap_domain", &domain)?;
    validate_non_empty("pre_auth_token", &password)?;

    let context = context.clone();
    let (init_tx, init_rx) = mpsc::sync_channel(1);

    let handle = thread::Builder::new()
        .name("ankole-actor-bus-zap".to_string())
        .spawn(move || run_zap_server(context, domain, password, stop, init_tx))
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
    password: String,
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
                let response = zap_response(&domain, &password, &frames);
                let _ = socket.send_multipart(response, 0);
            }
            Err(zmq::Error::EAGAIN) => {}
            Err(zmq::Error::ETERM) => break,
            Err(_) => {}
        }
    }
}

fn zap_response(domain: &str, expected_password: &str, frames: &[Vec<u8>]) -> Vec<Vec<u8>> {
    let sequence = frames.get(1).cloned().unwrap_or_default();
    let request_domain = frame_string(frames.get(2));
    let mechanism = frame_string(frames.get(5));
    let username = frame_string(frames.get(6));
    let password = frame_string(frames.get(7));

    let accepted = request_domain.as_deref() == Some(domain)
        && mechanism.as_deref() == Some("PLAIN")
        && username.as_deref().is_some_and(|value| !value.is_empty())
        && password.as_deref() == Some(expected_password);

    if accepted {
        vec![
            b"1.0".to_vec(),
            sequence,
            b"200".to_vec(),
            b"OK".to_vec(),
            username
                .unwrap_or_else(|| "worker".to_string())
                .into_bytes(),
            Vec::new(),
        ]
    } else {
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

fn validate_optional_positive(field: &str, value: Option<i32>) -> Result<(), TransportError> {
    match value {
        Some(value) if value <= 0 => Err(TransportError::InvalidFrame(format!(
            "{field} must be positive"
        ))),
        _ => Ok(()),
    }
}

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
                pre_auth_token: Some("test-token".to_string()),
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

        dealer
            .send_envelope(worker_ready_envelope())
            .expect("ready sends");

        let ready = wait_for_router_event(&events).expect("ready event");
        match ready {
            RouterEvent::Received {
                transport_route,
                envelope_json,
            } => {
                let envelope: serde_json::Value =
                    serde_json::from_str(&envelope_json).expect("decoded JSON");
                assert_eq!(transport_route, "worker-instance-a");
                assert_eq!(envelope["body"]["type"], "worker_ready");
            }
            other => panic!("unexpected router event: {other:?}"),
        }

        router
            .send_mandatory("worker-instance-a", turn_start_envelope())
            .expect("turn.start sends");

        let payload = wait_for_dealer_payload(&dealer).expect("dealer payload");
        let envelope = actor_bus::decode_envelope_json(&payload).expect("turn.start decodes");
        assert_eq!(envelope["body"]["type"], "turn_start");

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
                    "worker_instance_id": "worker-instance-a",
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
