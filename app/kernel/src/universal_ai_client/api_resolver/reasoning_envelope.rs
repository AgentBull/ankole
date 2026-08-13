use super::*;
use crate::common::{base64_url_safe_decode, base64_url_safe_encode};

/// Upstream identity that an AIGateway reasoning envelope is bound to.
///
/// Two provider rows of the same type share an envelope when they use the same
/// model ID; a provider-row ID is deliberately not part of the scope.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) struct ReasoningSource {
    provider_type: String,
    model_id: String,
}

impl ReasoningSource {
    pub(super) fn from_context(context: &ResponseContext) -> Option<Self> {
        let source = context
            .request
            .get("__ankole_reasoning_source")?
            .as_object()?;
        let provider_type = source.get("provider_type")?.as_str()?.trim();
        let model_id = source.get("model_id")?.as_str()?.trim();
        if provider_type.is_empty() || model_id.is_empty() {
            return None;
        }

        Some(Self {
            provider_type: provider_type.to_string(),
            model_id: model_id.to_string(),
        })
    }
}

/// Encodes one provider's private reasoning state as a reversible AIGateway
/// transport value bound to the upstream that produced it.
///
/// The value rides in a Responses `reasoning` item's `encrypted_content`, so a
/// provider's private state needs no new public item type.
pub(super) fn encode(
    prefix: &str,
    context: &ResponseContext,
    mut payload: Map<String, Value>,
) -> Option<String> {
    let source = ReasoningSource::from_context(context)?;
    payload.insert("provider_type".to_string(), json!(source.provider_type));
    payload.insert("model_id".to_string(), json!(source.model_id));

    let encoded = Value::Object(payload).to_string();
    Some(format!(
        "{prefix}{}",
        base64_url_safe_encode(encoded.as_bytes())
    ))
}

/// Returns the payload of an envelope that this request may replay.
///
/// A missing, corrupt, old, or mismatched envelope returns `None`. Dropping only
/// the private reasoning state keeps the visible assistant message and tool
/// history, and never sends one upstream's reasoning to another.
pub(super) fn decode(
    prefix: &str,
    context: &ResponseContext,
    encoded: &str,
) -> Option<Map<String, Value>> {
    let current_source = ReasoningSource::from_context(context)?;
    let payload = encoded.strip_prefix(prefix)?;
    let decoded = base64_url_safe_decode(payload).ok()?;
    let value: Value = serde_json::from_slice(&decoded).ok()?;
    let object = value.as_object()?;

    let source = ReasoningSource {
        provider_type: object.get("provider_type")?.as_str()?.to_string(),
        model_id: object.get("model_id")?.as_str()?.to_string(),
    };
    if source != current_source {
        return None;
    }

    Some(object.clone())
}
