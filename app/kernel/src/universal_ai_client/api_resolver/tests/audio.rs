use super::super::*;

fn resolver(kind: APIResolverKind, model: &str, request: Value) -> APIResolver {
    APIResolver::new(
        kind,
        ResponseContext {
            model: model.to_string(),
            request,
            provider_options: json!({}),
            stream: None,
            include_model: false,
            ..ResponseContext::default()
        },
    )
}

#[test]
fn openrouter_speech_sends_the_public_fields_under_the_provider_model() {
    let body = resolver(
        APIResolverKind::OpenrouterSpeech,
        "openai/gpt-4o-mini-tts",
        json!({
            "model": "speech.default",
            "input": "Hello",
            "voice": "alloy",
            "response_format": "mp3",
            "speed": 1.25,
            "instructions": "Speak calmly."
        }),
    )
    .build_body()
    .unwrap();

    assert_eq!(
        Value::Object(body),
        json!({
            "model": "openai/gpt-4o-mini-tts",
            "input": "Hello",
            "voice": "alloy",
            "response_format": "mp3",
            "speed": 1.25,
            "instructions": "Speak calmly."
        })
    );
}

#[test]
fn cloudflare_speech_names_the_text_and_the_speaker() {
    let body = resolver(
        APIResolverKind::CloudflareSpeech,
        "@cf/deepgram/aura-1",
        json!({"model": "speech.default", "input": "Hello", "voice": "luna", "response_format": "mp3"}),
    )
    .build_body()
    .unwrap();

    assert_eq!(
        Value::Object(body),
        json!({"text": "Hello", "speaker": "luna"})
    );
}

#[test]
fn openrouter_transcription_reads_text_segments_and_usage() {
    let mut resolver = resolver(
        APIResolverKind::OpenrouterTranscription,
        "openai/whisper-large-v3",
        json!({
            "model": "transcription.default",
            "input_audio": {"data": "UklGRg==", "format": "wav"},
            "language": "en",
            "response_format": "verbose_json",
            "vad_filter": true
        }),
    );

    assert_eq!(
        Value::Object(resolver.build_body().unwrap()),
        json!({
            "model": "openai/whisper-large-v3",
            "input_audio": {"data": "UklGRg==", "format": "wav"},
            "language": "en",
            "response_format": "verbose_json"
        })
    );

    let body = resolver
        .normalize_body(
            200,
            json!({
                "text": "Hello there.",
                "language": "english",
                "duration": 9.2,
                "segments": [{"id": 0, "start": 0.0, "end": 9.2, "text": "Hello there.", "seek": 0}],
                "usage": {"seconds": 9.2, "cost": 0.000508}
            }),
        )
        .unwrap();

    assert_eq!(
        body,
        json!({
            "text": "Hello there.",
            "language": "english",
            "duration": 9.2,
            "segments": [{"start": 0.0, "end": 9.2, "text": "Hello there."}],
            "usage": {"seconds": 9.2, "cost": 0.000508}
        })
    );
}

#[test]
fn cloudflare_transcription_sends_base64_audio_and_reads_the_result_envelope() {
    let mut resolver = resolver(
        APIResolverKind::CloudflareTranscription,
        "@cf/openai/whisper-large-v3-turbo",
        json!({
            "model": "transcription.default",
            "input_audio": {"data": "UklGRg==", "format": "wav"},
            "language": "en",
            "vad_filter": true
        }),
    );

    assert_eq!(
        Value::Object(resolver.build_body().unwrap()),
        json!({"audio": "UklGRg==", "language": "en", "vad_filter": true})
    );

    let body = resolver
        .normalize_body(
            200,
            json!({
                "success": true,
                "result": {
                    "text": "Hello there.",
                    "word_count": 2,
                    "transcription_info": {"language": "en", "duration": 3.5},
                    "segments": [{"start": 0.0, "end": 3.5, "text": "Hello there.", "words": []}]
                }
            }),
        )
        .unwrap();

    assert_eq!(
        body,
        json!({
            "text": "Hello there.",
            "language": "en",
            "duration": 3.5,
            "segments": [{"start": 0.0, "end": 3.5, "text": "Hello there."}],
            "usage": {"seconds": 3.5}
        })
    );
}

#[test]
fn a_transcription_without_text_is_an_invalid_upstream_response() {
    let error = resolver(
        APIResolverKind::CloudflareTranscription,
        "@cf/openai/whisper-large-v3-turbo",
        json!({}),
    )
    .normalize_body(200, json!({"result": {"word_count": 0}}))
    .unwrap_err();

    assert_eq!(error.code, "invalid_upstream_response");
}
