use std::collections::VecDeque;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Condvar, Mutex, mpsc};
use std::thread;
use std::time::Duration;

use crate::common::{KernelError, KernelResult};
use crate::runtime_fabric;

use super::config::{
    DEFAULT_DEALER_INBOX_MAX_BYTES, DEFAULT_DEALER_INBOX_MAX_EVENTS, DealerConfig,
    configure_common_socket,
};
use super::error::{TransportError, map_send_error, transport_error};
use super::framing::{DealerInbound, parse_dealer_frames, validate_file_transfer_frames};
use super::types::{DealerEvent, SendOutcome};

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

#[derive(Clone)]
pub struct DealerHandle {
    inner: Arc<DealerHandleInner>,
}

// Async N-API receive tasks need to hold a temporary clone while JS continues
// using the worker transport. The underlying DEALER must therefore be closed by
// the last shared handle, not by every clone that leaves a native worker thread.
pub(super) struct DealerHandleInner {
    command_timeout: Duration,
    commands: mpsc::Sender<DealerCommand>,
    inbox: Arc<DealerInbox>,
    stop: Arc<AtomicBool>,
}

pub(super) struct DealerInbox {
    state: Mutex<DealerInboxState>,
    available: Condvar,
    max_events: usize,
    max_bytes: usize,
}

pub(super) struct DealerInboxState {
    queue: VecDeque<DealerEvent>,
    queued_bytes: usize,
    closed: bool,
}

impl DealerInbox {
    pub(super) fn new(max_events: usize, max_bytes: usize) -> Self {
        Self {
            state: Mutex::new(DealerInboxState {
                queue: VecDeque::new(),
                queued_bytes: 0,
                closed: false,
            }),
            available: Condvar::new(),
            max_events,
            max_bytes,
        }
    }

    pub(super) fn push(&self, event: DealerEvent) {
        if let Ok(mut state) = self.state.lock() {
            if !state.closed {
                let event_size = dealer_event_size(&event);

                if state.queue.len() >= self.max_events
                    || state.queued_bytes.saturating_add(event_size) > self.max_bytes
                {
                    state.queue.clear();
                    state.queued_bytes = 0;
                    state.closed = true;
                    let error = DealerEvent::SocketError(format!(
                        "dealer inbox overflow: max_events={}, max_bytes={}",
                        self.max_events, self.max_bytes
                    ));
                    state.queued_bytes = dealer_event_size(&error);
                    state.queue.push_back(error);
                    self.available.notify_all();
                    return;
                }

                state.queued_bytes = state.queued_bytes.saturating_add(event_size);
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

    pub(super) fn recv(&self, timeout: Duration) -> Result<Option<DealerEvent>, TransportError> {
        self.recv_with_mode(timeout, DealerRecvMode::Any)
    }

    pub(super) fn recv_envelope(
        &self,
        timeout: Duration,
    ) -> Result<Option<DealerEvent>, TransportError> {
        self.recv_with_mode(timeout, DealerRecvMode::EnvelopeOnly)
    }

    fn recv_with_mode(
        &self,
        timeout: Duration,
        mode: DealerRecvMode,
    ) -> Result<Option<DealerEvent>, TransportError> {
        let mut state = self
            .state
            .lock()
            .map_err(|_| TransportError::SocketClosed)?;

        loop {
            match state.queue.front() {
                Some(DealerEvent::FileFrame(_)) if mode == DealerRecvMode::EnvelopeOnly => {
                    return Err(TransportError::InvalidFrame(
                        "received worker file lane frame; use recvRaw".into(),
                    ));
                }
                Some(_event) => return Ok(state.pop_front()),
                None => {}
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

impl DealerInboxState {
    fn pop_front(&mut self) -> Option<DealerEvent> {
        let event = self.queue.pop_front()?;
        self.queued_bytes = self.queued_bytes.saturating_sub(dealer_event_size(&event));
        Some(event)
    }
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum DealerRecvMode {
    Any,
    EnvelopeOnly,
}

fn dealer_event_size(event: &DealerEvent) -> usize {
    match event {
        DealerEvent::Received(payload) => payload.len(),
        DealerEvent::FileFrame(frames) => frames.iter().map(Vec::len).sum(),
        DealerEvent::DecodeFailed(reason) | DealerEvent::SocketError(reason) => reason.len(),
    }
}

impl DealerHandle {
    /// Sends a JSON-shaped RuntimeFabric envelope from the worker to the control plane.
    pub fn send_envelope(
        &self,
        envelope_json: serde_json::Value,
    ) -> Result<SendOutcome, TransportError> {
        let payload =
            runtime_fabric::encode_envelope(envelope_json).map_err(TransportError::from)?;
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

    /// Receives the next protobuf envelope without consuming worker-file frames.
    ///
    /// JS callers using `recv()` should not lose file-transfer data by accident;
    /// if a file frame is at the head of the queue this returns an error and
    /// leaves the frame available for `recvRaw`.
    pub fn recv_envelope(&self, timeout: Duration) -> Result<Option<DealerEvent>, TransportError> {
        self.inner.inbox.recv_envelope(timeout)
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

/// Starts a computer-worker DEALER socket on its own thread.
///
/// The handle exposes a blocking inbox so the Bun worker can run a simple loop
/// without knowing about ZeroMQ polling.
pub fn start_dealer(config: DealerConfig) -> KernelResult<DealerHandle> {
    config.validate().map_err(KernelError::from)?;

    let (command_tx, command_rx) = mpsc::channel();
    let (init_tx, init_rx) = mpsc::sync_channel(1);
    let inbox = Arc::new(DealerInbox::new(
        config
            .inbox_max_events
            .unwrap_or(DEFAULT_DEALER_INBOX_MAX_EVENTS),
        config
            .inbox_max_bytes
            .unwrap_or(DEFAULT_DEALER_INBOX_MAX_BYTES),
    ));
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
            configure_common_socket(&socket, &config.socket)?;
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

// Stores inbound control-plane frames for the worker loop. Decode errors stay
// visible so the worker can log them or fail tests deterministically.
fn emit_dealer_frames(inbox: &DealerInbox, frames: Vec<Vec<u8>>) {
    match parse_dealer_frames(frames) {
        Ok(DealerInbound::Envelope(payload)) => inbox.push(DealerEvent::Received(payload)),
        Ok(DealerInbound::FileFrame(frames)) => inbox.push(DealerEvent::FileFrame(frames)),
        Err(error) => inbox.push(DealerEvent::DecodeFailed(error.to_string())),
    }
}
