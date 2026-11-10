use super::*;
use crate::common::{base64_url_safe_decode, base64_url_safe_encode};

/// Two provider rows of the same type share an envelope when they use the same
/// model ID (and matching `account_id` when account binding is specified).
#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) struct ReasoningSource {
    provider_type: String,
    model_id: String,
    account_id: Option<String>,
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
        let explicit_account = first_non_empty_string([
            source.get("account_id"),
            context.request.get("__ankole_account_id"),
            context.request.get("account_id"),
            context.provider_options.get("account_id"),
        ]);

        let account_id = explicit_account.or_else(|| {
            let provider_id = first_non_empty_string([
                source.get("provider_id"),
                context.request.get("provider_id"),
                context.provider_options.get("provider_id"),
            ]);
            let credential_id = first_non_empty_string([
                source.get("credential_id"),
                context.request.get("credential_id"),
                context.provider_options.get("credential_id"),
            ]);

            match (provider_id, credential_id) {
                (Some(provider), Some(credential)) => Some(format!("{provider}:{credential}")),
                (None, Some(credential)) => Some(credential),
                (Some(provider), None) => Some(provider),
                (None, None) => None,
            }
        });

        Some(Self {
            provider_type: provider_type.to_string(),
            model_id: model_id.to_string(),
            account_id,
        })
    }
}

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
    if let Some(account_id) = source.account_id {
        payload.insert("account_id".to_string(), json!(account_id));
    }

    let encoded = Value::Object(payload).to_string();
    Some(format!(
        "{prefix}{}",
        base64_url_safe_encode(encoded.as_bytes())
    ))
}

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
    let value: Value = sonic_rs::from_slice(&decoded).ok()?;
    let object = value.as_object()?;

    let envelope_account_id = object
        .get("account_id")
        .or_else(|| object.get("credential_id"))
        .or_else(|| object.get("provider_id"))
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .map(str::to_string);
    let source = ReasoningSource {
        provider_type: object.get("provider_type")?.as_str()?.to_string(),
        model_id: object.get("model_id")?.as_str()?.to_string(),
        account_id: envelope_account_id,
    };
    if source != current_source {
        return None;
    }

    Some(object.clone())
}

fn first_non_empty_string<'a>(
    values: impl IntoIterator<Item = Option<&'a Value>>,
) -> Option<String> {
    values
        .into_iter()
        .flatten()
        .filter_map(Value::as_str)
        .map(str::trim)
        .find(|value| !value.is_empty())
        .map(str::to_string)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn context_with_source(source: Value, provider_options: Value) -> ResponseContext {
        ResponseContext {
            request: json!({ "__ankole_reasoning_source": source }),
            provider_options,
            ..ResponseContext::default()
        }
    }

    #[test]
    fn account_identifier_skips_blank_values() {
        let context = context_with_source(
            json!({"provider_type": "openai", "model_id": "model", "account_id": ""}),
            json!({"account_id": "acct-b"}),
        );

        assert_eq!(
            ReasoningSource::from_context(&context)
                .expect("source")
                .account_id
                .as_deref(),
            Some("acct-b")
        );
    }

    #[test]
    fn account_identifier_binds_provider_to_credential() {
        let context = context_with_source(
            json!({
                "provider_type": "openai",
                "model_id": "model",
                "provider_id": "prov",
                "credential_id": "cred"
            }),
            json!({}),
        );

        assert_eq!(
            ReasoningSource::from_context(&context)
                .expect("source")
                .account_id
                .as_deref(),
            Some("prov:cred")
        );
    }
}
