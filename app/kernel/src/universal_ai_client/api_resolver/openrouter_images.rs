use super::*;

#[derive(Debug)]
pub(super) struct OpenrouterImages;

impl APIProtocol for OpenrouterImages {
    fn build_body(&self, context: &ResponseContext) -> Result<Map<String, Value>, StreamError> {
        Ok(context.resolved_provider_request_object())
    }

    fn on_provider_body(
        &mut self,
        context: &ResponseContext,
        status: u16,
        body: Value,
    ) -> Result<Value, StreamError> {
        if !(200..300).contains(&status) {
            return Err(provider_body_error(status, body));
        }
        reject_provider_body_error(status, &body)?;

        let object = provider_object_body(status, body, "OpenRouter Images")?;
        let image = object
            .get("data")
            .and_then(Value::as_array)
            .and_then(|images| images.first())
            .and_then(Value::as_object)
            .ok_or_else(|| {
                invalid_upstream_body_error(
                    status,
                    object.clone(),
                    "OpenRouter Images response did not contain data[0]",
                )
            })?;
        let result = image
            .get("b64_json")
            .and_then(Value::as_str)
            .filter(|value| !value.is_empty())
            .ok_or_else(|| {
                invalid_upstream_body_error(
                    status,
                    object.clone(),
                    "OpenRouter Images response did not contain base64 image bytes",
                )
            })?;

        let default_mime_type = match context.request.get("output_format").and_then(Value::as_str) {
            Some("jpeg") => "image/jpeg",
            Some("webp") => "image/webp",
            _format => "image/png",
        };

        Ok(json!({
            "result": result,
            "mime_type": image.get("media_type").and_then(Value::as_str).unwrap_or(default_mime_type),
            "revised_prompt": image.get("revised_prompt").and_then(Value::as_str),
            "usage": object.get("usage").cloned().unwrap_or_else(|| json!({}))
        }))
    }
}
