use super::*;

/// Cloudflare decision models: Clef on Workers AI and partner models such as
/// Jev behind the unified `ai/run` endpoint.
#[derive(Debug)]
pub(super) struct CloudflareDecision;

impl APIProtocol for CloudflareDecision {
    fn build_body(&self, context: &ResponseContext) -> Result<Map<String, Value>, StreamError> {
        let request = context.resolved_provider_request_object();
        let mut input = Map::new();

        // `state` is required and may be null, so it is copied as given.
        input.insert(
            "state".to_string(),
            request.get("state").cloned().unwrap_or(Value::Null),
        );
        maybe_put_from(&mut input, &request, "questions");
        maybe_put_from(&mut input, &request, "images");

        // Workers AI models take the fields at the top level and name the model
        // by its short id; partner models take them inside `input`.
        Ok(match context.model.strip_prefix("@cf/") {
            Some(workers_model) => {
                let short_model = workers_model.rsplit('/').next().unwrap_or(workers_model);
                input.insert("model".to_string(), json!(short_model));
                input
            }
            None => {
                let mut body = Map::new();
                body.insert("model".to_string(), json!(context.model));
                body.insert("input".to_string(), Value::Object(input));
                body
            }
        })
    }

    fn on_provider_body(
        &mut self,
        context: &ResponseContext,
        status: u16,
        body: Value,
    ) -> Result<Value, StreamError> {
        let object = provider_object_body(status, body, "Cloudflare decision")?;
        let payload = cloudflare_result(object);

        match payload.get("answers") {
            Some(answers) if answers.is_object() => Ok(json!({
                "model": payload.get("model").and_then(Value::as_str).unwrap_or(&context.model),
                "answers": answers,
                "usage": payload
                    .get("usage")
                    .filter(|usage| usage.is_object())
                    .cloned()
                    .unwrap_or_else(|| json!({}))
            })),
            _answers => Err(invalid_upstream_body_error(
                status,
                payload,
                "Cloudflare decision response did not contain answers",
            )),
        }
    }
}
