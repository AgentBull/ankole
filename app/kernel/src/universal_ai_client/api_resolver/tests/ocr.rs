use super::super::*;

fn resolver(request: Value) -> APIResolver {
    APIResolver::new(
        APIResolverKind::MistralOcr,
        ResponseContext {
            model: "mistral-ocr-latest".to_string(),
            request,
            provider_options: json!({}),
            stream: None,
            include_model: false,
            ..ResponseContext::default()
        },
    )
}

#[test]
fn a_pdf_is_sent_as_a_document_link_with_its_pages() {
    let body = resolver(json!({
        "model": "ocr.default",
        "document": "data:application/pdf;base64,JVBERi0=",
        "pages": [0, 3]
    }))
    .build_body()
    .unwrap();

    assert_eq!(
        Value::Object(body),
        json!({
            "model": "mistral-ocr-latest",
            "document": {
                "type": "document_url",
                "document_url": "data:application/pdf;base64,JVBERi0="
            },
            "pages": [0, 3]
        })
    );
}

#[test]
fn an_image_is_sent_as_an_image_link() {
    let body = resolver(json!({"document": "data:image/png;base64,iVBORw0="}))
        .build_body()
        .unwrap();

    assert_eq!(
        Value::Object(body),
        json!({
            "model": "mistral-ocr-latest",
            "document": {"type": "image_url", "image_url": "data:image/png;base64,iVBORw0="}
        })
    );
}

#[test]
fn the_response_keeps_each_page_index_and_markdown_and_counts_the_pages() {
    let body = resolver(json!({}))
        .normalize_body(
            200,
            json!({
                "pages": [
                    {
                        "index": 0,
                        "markdown": "# Invoice\n\n![img-0.jpeg](img-0.jpeg)\n\nTotal: 42",
                        "images": [{"id": "img-0.jpeg", "top_left_x": 10}],
                        "dimensions": {"dpi": 200}
                    },
                    {"index": 3, "markdown": "", "images": []}
                ],
                "model": "mistral-ocr-2503-completion",
                "usage_info": {"pages_processed": 2, "doc_size_bytes": null}
            }),
        )
        .unwrap();

    assert_eq!(
        body,
        json!({
            "model": "mistral-ocr-2503-completion",
            // The picture's placeholder is gone, because the gateway returns no pictures.
            "pages": [
                {"index": 0, "markdown": "# Invoice\n\nTotal: 42"},
                {"index": 3, "markdown": ""}
            ],
            "usage": {"pages": 2}
        })
    );
}

#[test]
fn a_response_without_pages_is_an_invalid_upstream_response() {
    let error = resolver(json!({}))
        .normalize_body(200, json!({"model": "mistral-ocr-latest"}))
        .unwrap_err();

    assert_eq!(error.code, "invalid_upstream_response");
}
