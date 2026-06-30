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
            runtime_fabric::encode_envelope(envelope_json).map_err(TransportError::from)?;
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
            match runtime_fabric::decode_envelope(&payload) {
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
