use super::proto;
use proto::Lane::Rpc as RPCLane;

pub(super) fn lane_name(lane: proto::Lane) -> &'static str {
    match lane {
        proto::Lane::Control => "LANE_CONTROL",
        proto::Lane::Turn => "LANE_TURN",
        proto::Lane::Progress => "LANE_PROGRESS",
        RPCLane => "LANE_RPC",
        proto::Lane::Unspecified => "LANE_UNSPECIFIED",
    }
}

pub(super) fn durability_name(durability: proto::DurabilityClass) -> &'static str {
    match durability {
        proto::DurabilityClass::ControlDurable => "CONTROL_DURABLE",
        proto::DurabilityClass::ControlReplayable => "CONTROL_REPLAYABLE",
        proto::DurabilityClass::ControlEphemeral => "CONTROL_EPHEMERAL",
        proto::DurabilityClass::DurabilityUnspecified => "DURABILITY_UNSPECIFIED",
    }
}
