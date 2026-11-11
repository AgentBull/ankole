use super::super::*;

fn resolver(model: &str, request: Value, provider_options: Value) -> APIResolver {
    APIResolver::new(
        APIResolverKind::CloudflareImages,
        ResponseContext {
            model: model.to_string(),
            request,
            provider_options,
            stream: None,
            include_model: false,
            ..ResponseContext::default()
        },
    )
}

#[test]
fn partner_image_models_take_size_format_and_reference_images_inside_input() {
    let body = Value::Object(
        resolver(
            "black-forest-labs/flux-2-pro-preview",
            json!({
                "model": "image_generate.default",
                "prompt": "A lake at dawn",
                "n": 1,
                "stream": false,
                "size": "1024x768",
                "output_format": "png",
                "provider": {"only": ["cloudflare"]},
                "input_references": [
                    {"type": "image_url", "image_url": {"url": "data:image/png;base64,AAAA"}}
                ]
            }),
            json!({"seed": 7, "safety_tolerance": 2}),
        )
        .build_body()
        .unwrap(),
    );

    assert_eq!(
        body,
        json!({
            "model": "black-forest-labs/flux-2-pro-preview",
            "input": {
                "prompt": "A lake at dawn",
                "width": 1024,
                "height": 768,
                "output_format": "png",
                "seed": 7,
                "safety_tolerance": 2,
                "input_images": ["data:image/png;base64,AAAA"]
            }
        })
    );
}

#[test]
fn workers_ai_image_models_take_the_prompt_and_steps_at_the_top_level() {
    let body = Value::Object(
        resolver(
            "@cf/black-forest-labs/flux-1-schnell",
            json!({"prompt": "A lake at dawn", "n": 1, "size": "auto", "input_references": []}),
            json!({"steps": 6}),
        )
        .build_body()
        .unwrap(),
    );

    assert_eq!(body, json!({"prompt": "A lake at dawn", "steps": 6}));
}

#[test]
fn a_linked_image_is_left_for_the_client_to_download() {
    let body = resolver("black-forest-labs/flux-2-pro-preview", json!({}), json!({}))
        .normalize_body(
            200,
            json!({
                "state": "Completed",
                "result": {"image": "https://images.example.com/out.jpeg"}
            }),
        )
        .unwrap();

    assert_eq!(
        body,
        json!({"result_url": "https://images.example.com/out.jpeg", "usage": {}})
    );
}

#[test]
fn a_base64_image_names_the_format_that_its_bytes_identify() {
    // The first bytes of a JPEG file.
    let jpeg = "/9j/4AAQSkZJRgABAQAAAQABAAD/";
    let body = resolver("@cf/black-forest-labs/flux-1-schnell", json!({}), json!({}))
        .normalize_body(200, json!({"success": true, "result": {"image": jpeg}}))
        .unwrap();

    assert_eq!(
        body,
        json!({"result": jpeg, "mime_type": "image/jpeg", "usage": {}})
    );
}

#[test]
fn a_response_without_an_image_is_an_invalid_upstream_response() {
    let error = resolver("black-forest-labs/flux-2-pro-preview", json!({}), json!({}))
        .normalize_body(200, json!({"state": "Completed", "result": {}}))
        .unwrap_err();

    assert_eq!(error.code, "invalid_upstream_response");
}
