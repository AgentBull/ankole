use serde_json::Value;

use crate::common::{KernelError, KernelResult};

use super::{json::normalized_enum, proto};

pub(super) fn lane_from_json(value: &Value) -> KernelResult<proto::Lane> {
    match normalized_enum(value)?.as_str() {
        "lane_control" | "control" => Ok(proto::Lane::Control),
        "lane_turn" | "turn" => Ok(proto::Lane::Turn),
        "lane_progress" | "progress" => Ok(proto::Lane::Progress),
        "lane_rpc" | "rpc" => Ok(proto::Lane::Rpc),
        other => Err(KernelError::new(format!("unsupported lane: {other}"))),
    }
}

pub(super) fn durability_from_json(value: &Value) -> KernelResult<proto::DurabilityClass> {
    match normalized_enum(value)?.as_str() {
        "control_durable" | "durable" => Ok(proto::DurabilityClass::ControlDurable),
        "control_replayable" | "replayable" => Ok(proto::DurabilityClass::ControlReplayable),
        "control_ephemeral" | "ephemeral" => Ok(proto::DurabilityClass::ControlEphemeral),
        other => Err(KernelError::new(format!("unsupported durability: {other}"))),
    }
}

pub(super) fn lane_to_json(lane: i32) -> KernelResult<String> {
    match proto::Lane::try_from(lane).unwrap_or(proto::Lane::Unspecified) {
        proto::Lane::Unspecified => Err(KernelError::new("lane must be specified")),
        lane => Ok(lane_name(lane).to_string()),
    }
}

pub(super) fn durability_to_json(durability: i32) -> KernelResult<String> {
    match proto::DurabilityClass::try_from(durability)
        .unwrap_or(proto::DurabilityClass::DurabilityUnspecified)
    {
        proto::DurabilityClass::DurabilityUnspecified => {
            Err(KernelError::new("durability must be specified"))
        }
        durability => Ok(durability_name(durability).to_string()),
    }
}

pub(super) fn lane_name(lane: proto::Lane) -> &'static str {
    match lane {
        proto::Lane::Control => "LANE_CONTROL",
        proto::Lane::Turn => "LANE_TURN",
        proto::Lane::Progress => "LANE_PROGRESS",
        proto::Lane::Rpc => "LANE_RPC",
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
