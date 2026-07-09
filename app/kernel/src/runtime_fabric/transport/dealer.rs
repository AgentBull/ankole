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
use super::framing::validate_file_transfer_frames;
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
        if let Ok(mut state) = self.state.lock()
            && !state.closed
        {
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

    fn close(&self) {
        if let Ok(mut state) = self.state.lock() {
            state.closed = true;
            self.available.notify_all();
        }
    }

    pub(super) fn recv(&self, timeout: Duration) -> Result<Option<DealerEvent>, TransportError> {
        let mut state = self
            .state
            .lock()
            .map_err(|_| TransportError::SocketClosed)?;

        loop {
            match state.queue.front() {
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

fn dealer_event_size(event: &DealerEvent) -> usize {
    match event {
        DealerEvent::RawFrames(frames) => frames.iter().map(Vec::len).sum(),
        DealerEvent::SocketError(reason) => reason.len(),
    }
}

impl DealerHandle {
    /// Sends a JSON-shaped RuntimeFabric envelope from the worker to the control plane.
    pub fn send_envelope(
        &self,
        envelope_json: serde_json::Value,
    ) -> Result<SendOutcome, TransportError> {
        let payload = runtime_fabric::encode_envelope(envelope_json)
            .map_err(TransportError::invalid_envelope)?;
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

/// Starts a computer-worker DEALER socket on its own thread.
///
/// The handle exposes a blocking inbox so the Bun worker can run a simple loop
/// without knowing about ZeroMQ polling.
pub fn start_dealer(config: DealerConfig) -> KernelResult<DealerHandle> {
    config
        .validate()
        .map_err(|error| KernelError::new(error.ffi_message()))?;

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
        .map_err(|error| KernelError::new(error.ffi_message()))?;

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
            Err(zmq::Error::EAGAIN) => match commands.recv_timeout(poll_interval) {
                Ok(command) => {
                    if !handle_dealer_command(&socket, command) {
                        stop.store(true, Ordering::SeqCst);
                        break;
                    }
                }
                Err(mpsc::RecvTimeoutError::Timeout) => {}
                Err(mpsc::RecvTimeoutError::Disconnected) => break,
            },
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
        if !handle_dealer_command(socket, command) {
            return false;
        }
    }

    true
}

fn handle_dealer_command(socket: &zmq::Socket, command: DealerCommand) -> bool {
    match command {
        DealerCommand::Send { payload, reply } => {
            let outcome = send_dealer_frames(socket, vec![payload]);
            let _ = reply.send(outcome);
            true
        }
        DealerCommand::SendFileFrame { frames, reply } => {
            let outcome = send_dealer_frames(socket, frames);
            let _ = reply.send(outcome);
            true
        }
        DealerCommand::Stop { reply } => {
            let _ = reply.send(Ok(()));
            false
        }
    }
}

// Worker-to-control sends stay non-blocking so the Bun host adapter can own the
// bounded retry policy. A freshly connected or saturated DEALER therefore
// reports backpressure immediately instead of hiding it behind a native wait;
// the native command timeout remains a lifecycle guard, not retry policy.
fn send_dealer_frames(
    socket: &zmq::Socket,
    frames: Vec<Vec<u8>>,
) -> Result<SendOutcome, TransportError> {
    socket
        .send_multipart(frames, zmq::DONTWAIT)
        .map(|_| SendOutcome::SentOrQueued)
        .map_err(map_send_error)
}

// Stores inbound control-plane frames without classifying them. The Bun host
// adapter owns envelope-vs-worker-file classification and protobuf decoding.
pub(super) fn emit_dealer_frames(inbox: &DealerInbox, frames: Vec<Vec<u8>>) {
    inbox.push(DealerEvent::RawFrames(frames));
}
