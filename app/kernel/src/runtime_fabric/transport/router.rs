use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, mpsc};
use std::thread;
use std::time::Duration;

use crate::common::{KernelError, KernelResult};
use crate::runtime_fabric;

use super::auth::{
    AuthenticatedRouteState, AuthenticatedRoutes, ZapErrorSink, authenticated_envelope_route,
    authenticated_route, start_zap_server, zap_auth_config,
};
use super::config::{RouterConfig, configure_common_socket};
use super::error::{TransportError, map_send_error, transport_error};
use super::framing::{RouterInbound, parse_router_frames, validate_file_transfer_frames};
use super::types::{RouterEvent, SendOutcome};

pub type RouterEventSink = Arc<dyn Fn(RouterEvent) + Send + Sync + 'static>;

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

pub struct RouterHandle {
    endpoint: String,
    command_timeout: Duration,
    commands: mpsc::Sender<RouterCommand>,
    stop: Arc<AtomicBool>,
}

impl std::fmt::Debug for RouterHandle {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("RouterHandle")
            .field("endpoint", &self.endpoint)
            .finish_non_exhaustive()
    }
}

impl RouterHandle {
    /// Returns the endpoint actually bound by the ROUTER socket.
    pub fn endpoint(&self) -> &str {
        &self.endpoint
    }

    /// Sends an envelope to one worker route and reports mandatory-send errors.
    ///
    /// The host-encoded payload is sealed before it reaches the socket thread:
    /// the kernel writes lane, durability, and protocol version from the body
    /// and validates the result, so transport code never sees partially valid
    /// envelopes. The caller's bytes are borrowed only until sealing creates the
    /// owned command payload.
    pub fn send_mandatory(
        &self,
        transport_route: impl Into<String>,
        payload: &[u8],
    ) -> Result<SendOutcome, TransportError> {
        let payload = runtime_fabric::seal_envelope_bytes(payload)
            .map_err(TransportError::invalid_envelope)?;
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

    /// Requests shutdown without waiting for the socket thread.
    ///
    /// Resource owner/down callbacks cannot block a BEAM scheduler while the
    /// ZeroMQ thread drains. The Elixir broker retries a transient rebind until
    /// this request has released the endpoint.
    pub fn request_stop(&self) {
        self.stop.store(true, Ordering::SeqCst);
        let (reply_tx, _reply_rx) = mpsc::channel();
        let _ = self.commands.send(RouterCommand::Stop { reply: reply_tx });
    }
}

impl Drop for RouterHandle {
    fn drop(&mut self) {
        self.request_stop();
    }
}

/// Starts the control-plane ROUTER socket on its own thread.
///
/// ZeroMQ sockets are thread-affine. Commands cross into the socket thread over
/// channels, while received envelopes return to the host through the sink.
pub fn start_router(config: RouterConfig, sink: RouterEventSink) -> KernelResult<RouterHandle> {
    start_router_with_runner(config, sink, run_router)
}

fn start_router_with_runner<Runner>(
    config: RouterConfig,
    sink: RouterEventSink,
    runner: Runner,
) -> KernelResult<RouterHandle>
where
    Runner: FnOnce(
            RouterConfig,
            mpsc::Receiver<RouterCommand>,
            mpsc::SyncSender<Result<String, TransportError>>,
            RouterEventSink,
            Arc<AtomicBool>,
        ) + Send
        + 'static,
{
    config
        .validate()
        .map_err(|error| KernelError::new(error.ffi_message()))?;

    let (command_tx, command_rx) = mpsc::channel();
    let (init_tx, init_rx) = mpsc::sync_channel(1);
    let stop = Arc::new(AtomicBool::new(false));
    let thread_stop = Arc::clone(&stop);
    let command_timeout = config.command_timeout();

    thread::Builder::new()
        .name("ankole-runtime-fabric-router".to_string())
        .spawn(move || runner(config, command_rx, init_tx, sink, thread_stop))
        .map_err(|error| KernelError::new(format!("failed to spawn router thread: {error}")))?;

    let endpoint = match init_rx.recv_timeout(command_timeout) {
        Ok(result) => result.map_err(|error| KernelError::new(error.ffi_message()))?,
        Err(mpsc::RecvTimeoutError::Timeout) => {
            stop.store(true, Ordering::SeqCst);
            return Err(KernelError::new("timed out starting actor lane router"));
        }
        Err(mpsc::RecvTimeoutError::Disconnected) => {
            stop.store(true, Ordering::SeqCst);
            return Err(KernelError::new(
                "actor lane router stopped before initialization",
            ));
        }
    };

    Ok(RouterHandle {
        endpoint,
        command_timeout,
        commands: command_tx,
        stop,
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
    if stop.load(Ordering::SeqCst) {
        return;
    }

    let context = zmq::Context::new();
    let zap_stop = Arc::clone(&stop);
    let auth_routes = Arc::new(Mutex::new(AuthenticatedRouteState::default()));
    let zap_auth = zap_auth_config(&config);
    let requires_auth = zap_auth.is_some();
    let zap_error_sink: ZapErrorSink = {
        let sink = Arc::clone(&sink);
        Arc::new(move |reason| sink(RouterEvent::SocketError { reason }))
    };
    let zap_guard = match zap_auth {
        Some(auth) => start_zap_server(
            &context,
            config.zap_domain(),
            auth,
            Arc::clone(&auth_routes),
            zap_error_sink,
            zap_stop,
        ),
        None => Ok(None),
    };

    let socket_result = zap_guard.and_then(|zap| {
        let socket = context.socket(zmq::ROUTER).map_err(transport_error)?;
        configure_common_socket(&socket, &config.socket)?;
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

    if stop.load(Ordering::SeqCst) {
        return;
    }

    let _ = init.send(Ok(endpoint));
    let poll_interval = config.poll_interval();

    while !stop.load(Ordering::SeqCst) {
        if !drain_router_commands(&socket, &commands) {
            stop.store(true, Ordering::SeqCst);
            break;
        }

        match socket.recv_multipart(zmq::DONTWAIT) {
            Ok(frames) => emit_router_frames(&sink, requires_auth, &auth_routes, frames),
            Err(zmq::Error::EAGAIN) => {
                if !wait_for_router_command(&socket, &commands, poll_interval) {
                    stop.store(true, Ordering::SeqCst);
                    break;
                }
            }
            Err(zmq::Error::ETERM) => break,
            Err(error) => {
                sink(RouterEvent::SocketError {
                    reason: error.to_string(),
                });
                if !wait_for_router_command(&socket, &commands, poll_interval) {
                    stop.store(true, Ordering::SeqCst);
                    break;
                }
            }
        }
    }
}

fn drain_router_commands(socket: &zmq::Socket, commands: &mpsc::Receiver<RouterCommand>) -> bool {
    loop {
        match commands.try_recv() {
            Ok(command) => {
                if !handle_router_command(socket, command) {
                    return false;
                }
            }
            Err(mpsc::TryRecvError::Empty) => return true,
            Err(mpsc::TryRecvError::Disconnected) => return false,
        }
    }
}

// Waits for one command at most. The next loop drains queued commands in order
// before it polls the socket again.
fn wait_for_router_command(
    socket: &zmq::Socket,
    commands: &mpsc::Receiver<RouterCommand>,
    timeout: Duration,
) -> bool {
    match commands.recv_timeout(timeout) {
        Ok(command) => handle_router_command(socket, command),
        Err(mpsc::RecvTimeoutError::Timeout) => true,
        Err(mpsc::RecvTimeoutError::Disconnected) => false,
    }
}

fn handle_router_command(socket: &zmq::Socket, command: RouterCommand) -> bool {
    match command {
        RouterCommand::Send {
            route,
            payload,
            reply,
        } => {
            let outcome = send_router_payload(socket, route, payload);
            let _ = reply.send(outcome);
            true
        }
        RouterCommand::SendFileFrame {
            route,
            frames,
            reply,
        } => {
            let outcome = send_router_file_frame(socket, route, frames);
            let _ = reply.send(outcome);
            true
        }
        RouterCommand::Stop { reply } => {
            let _ = reply.send(Ok(()));
            false
        }
    }
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
    // Frames are validated at the RouterHandle::send_file_frame entry point
    // before crossing into the socket thread, mirroring the dealer send path.
    let mut routed_frames = Vec::with_capacity(frames.len() + 1);
    routed_frames.push(route.into_bytes());
    routed_frames.extend(frames);

    socket
        .send_multipart(routed_frames, zmq::DONTWAIT)
        .map(|_| SendOutcome::SentOrQueued)
        .map_err(map_send_error)
}

// Validates inbound worker frames before crossing back into Elixir. Bad
// protobuf never reaches ActorRuntime handlers as a normal envelope; the host
// decodes the validated bytes with its generated codec.
fn emit_router_frames(
    sink: &RouterEventSink,
    requires_auth: bool,
    auth_routes: &AuthenticatedRoutes,
    frames: Vec<Vec<u8>>,
) {
    match parse_router_frames(frames) {
        Ok(RouterInbound::Envelope { route, payload }) => {
            match runtime_fabric::decode_envelope_view(&payload) {
                Ok(envelope) => {
                    let auth = if requires_auth {
                        match authenticated_envelope_route(
                            auth_routes,
                            &route,
                            envelope.worker_lifecycle_id(),
                        ) {
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
                        envelope_bytes: payload,
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
                frames,
            });
        }
        Err((route, error)) => sink(RouterEvent::DecodeFailed {
            transport_route: route.unwrap_or_default(),
            reason: error.to_string(),
        }),
    }
}

#[cfg(test)]
mod tests {
    use std::net::TcpListener;

    use super::*;
    use crate::runtime_fabric::transport::SocketOptions;

    #[test]
    fn initialization_timeout_stops_late_router_and_releases_endpoint() {
        let listener = TcpListener::bind("127.0.0.1:0").expect("reserve test port");
        let endpoint = format!(
            "tcp://127.0.0.1:{}",
            listener.local_addr().expect("test address").port()
        );
        drop(listener);

        let config = router_config(endpoint.clone());
        let mut replacement_config = config.clone();
        replacement_config.command_timeout_ms = Some(1_000);
        let (release_tx, release_rx) = mpsc::channel();
        let (finished_tx, finished_rx) = mpsc::channel();

        let result = start_router_with_runner(
            config,
            event_sink(),
            move |config, commands, init, sink, stop| {
                release_rx
                    .recv()
                    .expect("release delayed router initialization");
                run_router(config, commands, init, sink, stop);
                let _ = finished_tx.send(());
            },
        );

        let error = match result {
            Ok(router) => {
                let _ = router.stop();
                panic!("delayed router unexpectedly started")
            }
            Err(error) => error,
        };
        assert_eq!(error.to_string(), "timed out starting actor lane router");

        release_tx
            .send(())
            .expect("release delayed router initialization");
        finished_rx
            .recv_timeout(Duration::from_secs(1))
            .expect("timed-out router thread must stop");

        let replacement =
            start_router(replacement_config, event_sink()).expect("endpoint must be reusable");
        assert_eq!(replacement.endpoint(), endpoint);
        replacement.stop().expect("stop replacement router");
    }

    #[test]
    fn disconnected_command_channel_stops_router_loop() {
        let context = zmq::Context::new();
        let socket = context.socket(zmq::ROUTER).expect("router socket");
        let (command_tx, command_rx) = mpsc::channel();
        drop(command_tx);

        assert!(!drain_router_commands(&socket, &command_rx));
    }

    #[test]
    fn idle_command_wait_handles_stop_without_waiting_for_the_poll_timeout() {
        let context = zmq::Context::new();
        let socket = context.socket(zmq::ROUTER).expect("router socket");
        let (command_tx, command_rx) = mpsc::channel();
        let (reply_tx, reply_rx) = mpsc::channel();

        command_tx
            .send(RouterCommand::Stop { reply: reply_tx })
            .expect("queue stop command");

        assert!(!wait_for_router_command(
            &socket,
            &command_rx,
            Duration::from_secs(1)
        ));
        reply_rx
            .recv_timeout(Duration::from_millis(10))
            .expect("receive stop reply")
            .expect("stop succeeds");
    }

    fn router_config(endpoint: String) -> RouterConfig {
        RouterConfig {
            endpoint,
            worker_auth_key: None,
            zap_domain: None,
            socket: SocketOptions::default(),
            poll_interval_ms: Some(1),
            command_timeout_ms: Some(10),
        }
    }

    fn event_sink() -> RouterEventSink {
        Arc::new(|_event| {})
    }
}
