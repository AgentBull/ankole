use super::super::*;

pub(super) fn reasoning_source_context(
    provider_type: &str,
    model: &str,
    mut request: Value,
) -> ResponseContext {
    request.as_object_mut().unwrap().insert(
        "__ankole_reasoning_source".to_string(),
        json!({"provider_type": provider_type, "model_id": model}),
    );

    ResponseContext {
        model: model.to_string(),
        request,
        provider_options: json!({}),
        stream: Some(false),
        include_model: true,
    }
}
