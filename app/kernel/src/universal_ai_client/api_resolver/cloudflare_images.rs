use base64_simd::STANDARD;

use super::*;

/// Cloudflare image models: FLUX.1 [schnell] on Workers AI, and Black Forest
/// Labs models behind the unified `ai/run` endpoint.
#[derive(Debug)]
pub(super) struct CloudflareImages;

impl APIProtocol for CloudflareImages {
    fn build_body(&self, context: &ResponseContext) -> Result<Map<String, Value>, StreamError> {
        let request = context.resolved_provider_request_object();
        let mut input = Map::new();
        maybe_put_from(&mut input, &request, "prompt");

        // A Workers AI model takes its fields at the top level and has no
        // image input.
        if context.model.starts_with("@cf/") {
            maybe_put_from(&mut input, &request, "steps");
            return Ok(input);
        }

        if let Some((width, height)) = requested_size(&request) {
            input.insert("width".to_string(), json!(width));
            input.insert("height".to_string(), json!(height));
        }
        for key in ["output_format", "seed", "safety_tolerance"] {
            maybe_put_from(&mut input, &request, key);
        }
        let images: Vec<Value> = request
            .get("input_references")
            .and_then(Value::as_array)
            .into_iter()
            .flatten()
            .filter_map(|reference| reference.pointer("/image_url/url").cloned())
            .collect();
        if !images.is_empty() {
            input.insert("input_images".to_string(), Value::Array(images));
        }

        let mut body = Map::new();
        body.insert("model".to_string(), json!(context.model));
        body.insert("input".to_string(), Value::Object(input));
        Ok(body)
    }

    fn on_provider_body(
        &mut self,
        _context: &ResponseContext,
        status: u16,
        body: Value,
    ) -> Result<Value, StreamError> {
        let object = provider_object_body(status, body, "Cloudflare Images")?;
        let payload = cloudflare_result(object);
        let Some(image) = payload
            .get("image")
            .and_then(Value::as_str)
            .filter(|image| !image.is_empty())
        else {
            return Err(invalid_upstream_body_error(
                status,
                payload,
                "Cloudflare Images response did not contain an image",
            ));
        };

        // A partner model answers with a link to the image, which the client
        // downloads; a Workers AI model answers with the base64 bytes.
        if image.starts_with("https://") || image.starts_with("http://") {
            return Ok(json!({"result_url": image, "usage": {}}));
        }

        let mut result = Map::new();
        result.insert("result".to_string(), json!(image));
        if let Some(mime_type) = base64_image_mime(image) {
            result.insert("mime_type".to_string(), json!(mime_type));
        }
        result.insert("usage".to_string(), json!({}));
        Ok(Value::Object(result))
    }
}

fn requested_size(request: &Map<String, Value>) -> Option<(u64, u64)> {
    let (width, height) = request.get("size")?.as_str()?.split_once('x')?;
    Some((width.parse().ok()?, height.parse().ok()?))
}

fn base64_image_mime(image: &str) -> Option<&'static str> {
    // Sixteen base64 characters hold the twelve bytes that identify the format.
    let head = image.get(..16)?;
    image_mime(&STANDARD.decode_to_vec(head).ok()?)
}

/// Names the image format that the leading bytes identify.
pub(crate) fn image_mime(bytes: &[u8]) -> Option<&'static str> {
    if bytes.starts_with(b"\x89PNG") {
        Some("image/png")
    } else if bytes.starts_with(&[0xFF, 0xD8, 0xFF]) {
        Some("image/jpeg")
    } else if bytes.starts_with(b"RIFF") && bytes.get(8..12) == Some(b"WEBP".as_slice()) {
        Some("image/webp")
    } else if bytes.starts_with(b"GIF8") {
        Some("image/gif")
    } else {
        None
    }
}
