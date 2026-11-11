use super::super::*;

fn resolver(kind: APIResolverKind, model: &str, request: Value) -> APIResolver {
    APIResolver::new(
        kind,
        ResponseContext {
            model: model.to_string(),
            request,
            stream: None,
            include_model: false,
            ..ResponseContext::default()
        },
    )
}

#[test]
fn openrouter_video_sends_frames_and_reads_the_state_of_a_generation() {
    let mut resolver = resolver(
        APIResolverKind::OpenrouterVideo,
        "google/veo-3.1",
        json!({
            "model": "video.default",
            "prompt": "A red kite over a beach",
            "duration": 8,
            "aspect_ratio": "16:9",
            "first_frame": "https://example.test/kite.png"
        }),
    );

    assert_eq!(
        Value::Object(resolver.build_body().unwrap()),
        json!({
            "model": "google/veo-3.1",
            "prompt": "A red kite over a beach",
            "duration": 8,
            "aspect_ratio": "16:9",
            "frame_images": [{
                "type": "image_url",
                "image_url": {"url": "https://example.test/kite.png"},
                "frame_type": "first_frame"
            }]
        })
    );

    assert_eq!(
        resolver
            .normalize_body(
                202,
                json!({"id": "gen-1", "polling_url": "https://example.test/gen-1", "status": "pending"})
            )
            .unwrap(),
        json!({"status": "in_progress", "job_id": "gen-1", "usage": {}})
    );
    assert_eq!(
        resolver
            .normalize_body(
                200,
                json!({
                    "id": "gen-1",
                    "status": "completed",
                    "unsigned_urls": ["https://openrouter.ai/api/v1/videos/gen-1/content?index=0"],
                    "urls": ["https://cdn.example.test/gen-1.mp4?sig=1"],
                    "usage": {"cost": 0.4, "is_byok": false}
                })
            )
            .unwrap(),
        json!({
            "status": "completed",
            "job_id": "gen-1",
            "url": "https://openrouter.ai/api/v1/videos/gen-1/content?index=0",
            "usage": {"cost": 0.4, "is_byok": false}
        })
    );
    assert_eq!(
        resolver
            .normalize_body(
                200,
                json!({"id": "gen-1", "status": "expired", "error": "The generation expired."})
            )
            .unwrap(),
        json!({
            "status": "failed",
            "job_id": "gen-1",
            "error": "The generation expired.",
            "usage": {}
        })
    );
    assert!(
        resolver
            .normalize_body(200, json!({"id": "gen-1"}))
            .is_err()
    );
}

#[test]
fn cloudflare_music_names_each_partner_fields_and_reads_the_audio_link() {
    let body = |model: &str, request: Value| {
        Value::Object(
            resolver(APIResolverKind::CloudflareMusic, model, request)
                .build_body()
                .unwrap(),
        )
    };

    assert_eq!(
        body("minimax/music-2.6", json!({"prompt": "Slow piano"})),
        json!({
            "model": "minimax/music-2.6",
            "input": {"prompt": "Slow piano", "is_instrumental": false, "lyrics_optimizer": true}
        })
    );
    assert_eq!(
        body(
            "minimax/music-2.6",
            json!({"prompt": "Slow piano", "lyrics": "La la", "instrumental": false})
        ),
        json!({
            "model": "minimax/music-2.6",
            "input": {
                "prompt": "Slow piano",
                "lyrics": "La la",
                "is_instrumental": false,
                "lyrics_optimizer": false
            }
        })
    );
    assert_eq!(
        body(
            "elevenlabs/music-v2",
            json!({"prompt": "Slow piano", "instrumental": true, "duration": 30})
        ),
        json!({
            "model": "elevenlabs/music-v2",
            "input": {"prompt": "Slow piano", "force_instrumental": true, "music_length_ms": 30000}
        })
    );

    let mut resolver = resolver(
        APIResolverKind::CloudflareMusic,
        "minimax/music-2.6",
        json!({}),
    );
    let completed =
        json!({"status": "completed", "url": "https://cdn.example.test/song.mp3", "usage": {}});
    assert_eq!(
        resolver
            .normalize_body(
                200,
                json!({"state": "Completed", "result": {"audio": "https://cdn.example.test/song.mp3"}})
            )
            .unwrap(),
        completed
    );
    assert_eq!(
        resolver
            .normalize_body(
                200,
                json!({
                    "success": true,
                    "result": {
                        "state": "Completed",
                        "result": {"audio": "https://cdn.example.test/song.mp3"}
                    }
                })
            )
            .unwrap(),
        completed
    );
    assert!(
        resolver
            .normalize_body(200, json!({"state": "Failed"}))
            .is_err()
    );
}

#[test]
fn a_get_request_sends_no_body() {
    use crate::universal_ai_client::request_builder::prepare_model_upstream;
    use crate::universal_ai_client::spec::ModelRequestSpec;

    let spec = |method: &str| -> ModelRequestSpec {
        serde_json::from_value(json!({
            "api_resolver": "openrouter_video",
            "upstream": {"method": method, "url": "https://example.test/videos/gen-1"},
            "response_context": {"model": "google/veo-3.1", "request": {"prompt": "A kite"}}
        }))
        .unwrap()
    };

    assert!(prepare_model_upstream(&spec("GET")).unwrap().body.is_none());
    assert!(
        prepare_model_upstream(&spec("POST"))
            .unwrap()
            .body
            .is_some()
    );
}
