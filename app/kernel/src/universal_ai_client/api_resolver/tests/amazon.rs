use super::super::*;

fn resolver(kind: APIResolverKind, model: &str, request: Value) -> APIResolver {
    APIResolver::new(
        kind,
        ResponseContext {
            model: model.to_string(),
            request,
            provider_options: json!({"voice": "Joanna"}),
            stream: None,
            include_model: false,
            ..ResponseContext::default()
        },
    )
}

#[test]
fn polly_takes_the_engine_from_the_model_and_the_voice_from_the_request_or_the_profile() {
    let body = |request: Value| {
        Value::Object(
            resolver(APIResolverKind::AmazonPollySpeech, "neural", request)
                .build_body()
                .unwrap(),
        )
    };

    assert_eq!(
        body(
            json!({"model": "speech.default", "input": "Hello", "voice": "Matthew", "response_format": "pcm"})
        ),
        json!({"Engine": "neural", "Text": "Hello", "VoiceId": "Matthew", "OutputFormat": "pcm"})
    );
    // The profile's voice serves a request that names none.
    assert_eq!(
        body(json!({"input": "Hello", "response_format": "mp3"})),
        json!({"Engine": "neural", "Text": "Hello", "VoiceId": "Joanna", "OutputFormat": "mp3"})
    );
}

#[test]
fn textract_sends_bare_base64_and_groups_lines_by_page() {
    let mut resolver = resolver(
        APIResolverKind::AmazonTextractOcr,
        "detect-document-text",
        json!({"model": "ocr.default", "document": "data:image/png;base64,iVBORw0="}),
    );

    assert_eq!(
        Value::Object(resolver.build_body().unwrap()),
        json!({"Document": {"Bytes": "iVBORw0="}})
    );

    let body = resolver
        .normalize_body(
            200,
            json!({
                "DocumentMetadata": {"Pages": 1},
                "DetectDocumentTextModelVersion": "1.0",
                "Blocks": [
                    {"BlockType": "PAGE", "Page": 1},
                    {"BlockType": "LINE", "Page": 1, "Text": "Invoice 42", "Confidence": 99.1},
                    {"BlockType": "WORD", "Page": 1, "Text": "Invoice"},
                    {"BlockType": "LINE", "Page": 1, "Text": "Total: 10"}
                ]
            }),
        )
        .unwrap();

    assert_eq!(
        body,
        json!({
            "model": "1.0",
            "pages": [{"index": 0, "markdown": "Invoice 42\nTotal: 10"}],
            "usage": {"pages": 1}
        })
    );
}

#[test]
fn a_textract_page_without_lines_is_an_empty_page() {
    let body = resolver(
        APIResolverKind::AmazonTextractOcr,
        "detect-document-text",
        json!({}),
    )
    .normalize_body(
        200,
        json!({"DocumentMetadata": {"Pages": 1}, "Blocks": [{"BlockType": "PAGE"}]}),
    )
    .unwrap();

    assert_eq!(body["pages"], json!([{"index": 0, "markdown": ""}]));
}

#[test]
fn a_textract_response_without_blocks_is_an_invalid_upstream_response() {
    let error = resolver(
        APIResolverKind::AmazonTextractOcr,
        "detect-document-text",
        json!({}),
    )
    .normalize_body(200, json!({"DocumentMetadata": {"Pages": 1}}))
    .unwrap_err();

    assert_eq!(error.code, "invalid_upstream_response");
}

#[test]
fn textract_sparse_blocks_ignore_inflated_document_metadata_page_count() {
    let body = resolver(
        APIResolverKind::AmazonTextractOcr,
        "detect-document-text",
        json!({}),
    )
    .normalize_body(
        200,
        json!({
            "DocumentMetadata": {"Pages": 1_000_000_000_u64},
            "Blocks": [
                {"BlockType": "LINE", "Page": 3, "Text": "Sparse page"}
            ]
        }),
    )
    .unwrap();

    assert_eq!(
        body["pages"],
        json!([{"index": 2, "markdown": "Sparse page"}])
    );
}
