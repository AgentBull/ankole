use crate::common::{KernelError, KernelResult};

use super::{json::normalized_name, proto};

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(super) enum BodyKind {
    WorkerReady,
    WorkerHeartbeat,
    WorkerCapacity,
    TurnStart,
    MailboxUpdated,
    TurnAccepted,
    TurnControl,
    WorkerProgress,
    TurnError,
    TurnNoopCompleted,
    ControlShutdown,
    RpcRequest,
    RpcResponse,
    RpcError,
}

#[derive(Clone, Copy, Debug)]
pub(super) struct BodySpec {
    pub(super) name: &'static str,
    pub(super) lane: proto::Lane,
    pub(super) durability: proto::DurabilityClass,
    pub(super) requires_correlation_id: bool,
}

impl BodyKind {
    pub(super) fn from_name(name: &str) -> KernelResult<Self> {
        match normalized_name(name).as_str() {
            "worker_ready" => Ok(Self::WorkerReady),
            "worker_heartbeat" => Ok(Self::WorkerHeartbeat),
            "worker_capacity" => Ok(Self::WorkerCapacity),
            "turn_start" => Ok(Self::TurnStart),
            "mailbox_updated" => Ok(Self::MailboxUpdated),
            "turn_accepted" => Ok(Self::TurnAccepted),
            "turn_control" => Ok(Self::TurnControl),
            "worker_progress" => Ok(Self::WorkerProgress),
            "turn_error" => Ok(Self::TurnError),
            "turn_noop_completed" => Ok(Self::TurnNoopCompleted),
            "control_shutdown" => Ok(Self::ControlShutdown),
            "rpc_request" => Ok(Self::RpcRequest),
            "rpc_response" => Ok(Self::RpcResponse),
            "rpc_error" => Ok(Self::RpcError),
            other => Err(KernelError::new(format!(
                "unsupported runtime fabric body: {other}"
            ))),
        }
    }

    pub(super) fn name(self) -> &'static str {
        self.spec().name
    }

    pub(super) fn spec(self) -> BodySpec {
        match self {
            Self::WorkerReady => BodySpec {
                name: "worker_ready",
                lane: proto::Lane::Control,
                durability: proto::DurabilityClass::ControlEphemeral,
                requires_correlation_id: false,
            },
            Self::WorkerHeartbeat => BodySpec {
                name: "worker_heartbeat",
                lane: proto::Lane::Control,
                durability: proto::DurabilityClass::ControlEphemeral,
                requires_correlation_id: false,
            },
            Self::WorkerCapacity => BodySpec {
                name: "worker_capacity",
                lane: proto::Lane::Control,
                durability: proto::DurabilityClass::ControlEphemeral,
                requires_correlation_id: false,
            },
            Self::TurnStart => BodySpec {
                name: "turn_start",
                lane: proto::Lane::Turn,
                durability: proto::DurabilityClass::ControlReplayable,
                requires_correlation_id: true,
            },
            Self::MailboxUpdated => BodySpec {
                name: "mailbox_updated",
                lane: proto::Lane::Turn,
                durability: proto::DurabilityClass::ControlEphemeral,
                requires_correlation_id: true,
            },
            Self::TurnAccepted => BodySpec {
                name: "turn_accepted",
                lane: proto::Lane::Turn,
                durability: proto::DurabilityClass::ControlReplayable,
                requires_correlation_id: true,
            },
            Self::TurnControl => BodySpec {
                name: "turn_control",
                lane: proto::Lane::Control,
                durability: proto::DurabilityClass::ControlDurable,
                requires_correlation_id: true,
            },
            Self::WorkerProgress => BodySpec {
                name: "worker_progress",
                lane: proto::Lane::Progress,
                durability: proto::DurabilityClass::ControlEphemeral,
                requires_correlation_id: true,
            },
            Self::TurnError => BodySpec {
                name: "turn_error",
                lane: proto::Lane::Turn,
                durability: proto::DurabilityClass::ControlReplayable,
                requires_correlation_id: true,
            },
            Self::TurnNoopCompleted => BodySpec {
                name: "turn_noop_completed",
                lane: proto::Lane::Turn,
                durability: proto::DurabilityClass::ControlReplayable,
                requires_correlation_id: true,
            },
            Self::ControlShutdown => BodySpec {
                name: "control_shutdown",
                lane: proto::Lane::Control,
                durability: proto::DurabilityClass::ControlEphemeral,
                requires_correlation_id: false,
            },
            Self::RpcRequest => BodySpec {
                name: "rpc_request",
                lane: proto::Lane::Rpc,
                durability: proto::DurabilityClass::ControlEphemeral,
                requires_correlation_id: true,
            },
            Self::RpcResponse => BodySpec {
                name: "rpc_response",
                lane: proto::Lane::Rpc,
                durability: proto::DurabilityClass::ControlEphemeral,
                requires_correlation_id: true,
            },
            Self::RpcError => BodySpec {
                name: "rpc_error",
                lane: proto::Lane::Rpc,
                durability: proto::DurabilityClass::ControlEphemeral,
                requires_correlation_id: true,
            },
        }
    }
}

pub(super) fn body_kind(body: &proto::envelope::Body) -> BodyKind {
    match body {
        proto::envelope::Body::WorkerReady(_) => BodyKind::WorkerReady,
        proto::envelope::Body::WorkerHeartbeat(_) => BodyKind::WorkerHeartbeat,
        proto::envelope::Body::WorkerCapacity(_) => BodyKind::WorkerCapacity,
        proto::envelope::Body::TurnStart(_) => BodyKind::TurnStart,
        proto::envelope::Body::MailboxUpdated(_) => BodyKind::MailboxUpdated,
        proto::envelope::Body::TurnAccepted(_) => BodyKind::TurnAccepted,
        proto::envelope::Body::TurnControl(_) => BodyKind::TurnControl,
        proto::envelope::Body::WorkerProgress(_) => BodyKind::WorkerProgress,
        proto::envelope::Body::TurnError(_) => BodyKind::TurnError,
        proto::envelope::Body::TurnNoopCompleted(_) => BodyKind::TurnNoopCompleted,
        proto::envelope::Body::ControlShutdown(_) => BodyKind::ControlShutdown,
        proto::envelope::Body::RpcRequest(_) => BodyKind::RpcRequest,
        proto::envelope::Body::RpcResponse(_) => BodyKind::RpcResponse,
        proto::envelope::Body::RpcError(_) => BodyKind::RpcError,
    }
}

pub(super) fn body_spec(body: &proto::envelope::Body) -> BodySpec {
    body_kind(body).spec()
}
