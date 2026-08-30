use super::proto;
use proto::Lane::Rpc as RPCLane;
use proto::envelope::Body::{
    RpcError as RPCErrorBody, RpcRequest as RPCRequestBody, RpcResponse as RPCResponseBody,
};

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
    ControlShutdown,
    RPCRequest,
    RPCResponse,
    RPCError,
}

#[derive(Clone, Copy, Debug)]
pub(super) struct BodySpec {
    pub(super) name: &'static str,
    pub(super) lane: proto::Lane,
    pub(super) durability: proto::DurabilityClass,
    pub(super) requires_correlation_id: bool,
}

impl BodyKind {
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
            Self::ControlShutdown => BodySpec {
                name: "control_shutdown",
                lane: proto::Lane::Control,
                durability: proto::DurabilityClass::ControlEphemeral,
                requires_correlation_id: false,
            },
            Self::RPCRequest => BodySpec {
                name: "rpc_request",
                lane: RPCLane,
                durability: proto::DurabilityClass::ControlEphemeral,
                requires_correlation_id: true,
            },
            Self::RPCResponse => BodySpec {
                name: "rpc_response",
                lane: RPCLane,
                durability: proto::DurabilityClass::ControlEphemeral,
                requires_correlation_id: true,
            },
            Self::RPCError => BodySpec {
                name: "rpc_error",
                lane: RPCLane,
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
        proto::envelope::Body::ControlShutdown(_) => BodyKind::ControlShutdown,
        RPCRequestBody(_) => BodyKind::RPCRequest,
        RPCResponseBody(_) => BodyKind::RPCResponse,
        RPCErrorBody(_) => BodyKind::RPCError,
    }
}

pub(super) fn body_spec(body: &proto::envelope::Body) -> BodySpec {
    body_kind(body).spec()
}
