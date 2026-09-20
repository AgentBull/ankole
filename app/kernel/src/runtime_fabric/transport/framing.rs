use super::error::TransportError;

#[derive(Debug)]
pub(super) enum RouterInbound {
    Envelope { route: String, payload: Vec<u8> },
}

// Parses ROUTER frames from DEALER workers. A leading empty delimiter is
// tolerated so tests and proxies can use common multipart conventions.
pub(super) fn parse_router_frames(
    mut frames: Vec<Vec<u8>>,
) -> Result<RouterInbound, (Option<String>, TransportError)> {
    if frames.len() < 2 {
        return Err((
            None,
            TransportError::InvalidFrame("router message must include route and payload".into()),
        ));
    }

    let route_frame = frames.remove(0);
    let route = String::from_utf8(route_frame).map_err(|error| {
        (
            None,
            TransportError::InvalidFrame(format!("route identity must be UTF-8: {error}")),
        )
    })?;

    if frames.len() >= 2 && frames[0].is_empty() {
        frames.remove(0);
    }

    let payload = frames.remove(0);
    Ok(RouterInbound::Envelope { route, payload })
}
