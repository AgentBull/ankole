use base64_simd::STANDARD;

use super::super::*;

fn resolver(
    kind: APIResolverKind,
    model: &str,
    request: Value,
    provider_options: Value,
) -> APIResolver {
    APIResolver::new(
        kind,
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
fn alibaba_dashscope_speech_builds_multimodal_payload_and_normalizes_inline_or_url_audio() {
    let mut tts = resolver(
        APIResolverKind::AlibabaDashscopeSpeech,
        "qwen3-tts-flash",
        json!({"model": "speech.default", "input": "你好，百炼。", "instructions": "自然亲切"}),
        json!({"voice": "Ethan"}),
    );

    assert_eq!(
        Value::Object(tts.build_body().unwrap()),
        json!({
            "model": "qwen3-tts-flash",
            "input": {
                "text": "你好，百炼。",
                "voice": "Ethan",
                "instructions": "自然亲切"
            }
        })
    );

    let url_result = tts
        .normalize_body(
            200,
            json!({
                "output": {
                    "audio": {
                        "url": "https://dashscope-result.oss-cn-beijing.aliyuncs.com/out.wav",
                        "data": ""
                    }
                },
                "usage": {"characters": 6}
            }),
        )
        .unwrap();
    assert_eq!(
        url_result,
        json!({
            "audio_url": "https://dashscope-result.oss-cn-beijing.aliyuncs.com/out.wav",
            "content_type": "audio/wav",
            "usage": {"characters": 6}
        })
    );

    let inline_result = tts
        .normalize_body(
            200,
            json!({
                "output": {"audio": {"data": "UklGRg=="}},
                "usage": {"characters": 6}
            }),
        )
        .unwrap();
    assert_eq!(
        inline_result,
        json!({
            "audio": "UklGRg==",
            "content_type": "audio/wav",
            "usage": {"characters": 6}
        })
    );
}

#[test]
fn alibaba_dashscope_transcription_wraps_audio_data_url_and_reads_multimodal_choices() {
    let mut asr = resolver(
        APIResolverKind::AlibabaDashscopeTranscription,
        "qwen3-asr-flash",
        json!({
            "input_audio": {"data": "UklGRg==", "format": "mp3"},
            "language": "zh"
        }),
        json!({}),
    );

    assert_eq!(
        Value::Object(asr.build_body().unwrap()),
        json!({
            "model": "qwen3-asr-flash",
            "input": {
                "messages": [
                    {
                        "role": "user",
                        "content": [{"audio": "data:audio/mpeg;base64,UklGRg=="}]
                    }
                ]
            },
            "parameters": {
                "asr_options": {"enable_itn": true, "language": "zh"}
            }
        })
    );

    let normalized = asr
        .normalize_body(
            200,
            json!({
                "output": {
                    "choices": [
                        {
                            "message": {
                                "annotations": [{"language": "zh", "type": "audio_info"}],
                                "content": [{"text": "你好世界。"}]
                            }
                        }
                    ]
                },
                "usage": {"seconds": 4}
            }),
        )
        .unwrap();

    assert_eq!(
        normalized,
        json!({
            "text": "你好世界。",
            "language": "zh",
            "duration": 4.0,
            "usage": {"seconds": 4.0}
        })
    );
}

#[test]
fn alibaba_dashscope_ocr_sends_pixel_bounds_and_unfences_markdown() {
    let mut ocr = resolver(
        APIResolverKind::AlibabaDashscopeOcr,
        "qwen-vl-ocr",
        json!({"document": "data:image/png;base64,iVBORw0="}),
        json!({}),
    );

    let built = Value::Object(ocr.build_body().unwrap());
    assert_eq!(built["model"], "qwen-vl-ocr");
    assert_eq!(built["stream"], false);
    assert_eq!(
        built["messages"][0]["content"][0]["image_url"]["url"],
        "data:image/png;base64,iVBORw0="
    );
    assert_eq!(
        built["messages"][0]["content"][0]["image_url"]["min_pixels"],
        3136
    );

    let normalized = ocr
        .normalize_body(
            200,
            json!({
                "model": "qwen-vl-ocr-2025-11-20",
                "choices": [
                    {
                        "message": {
                            "content": "```markdown\n# 发票\n\n金额：100.00\n```"
                        }
                    }
                ]
            }),
        )
        .unwrap();

    assert_eq!(
        normalized,
        json!({
            "model": "qwen-vl-ocr-2025-11-20",
            "pages": [{"index": 0, "markdown": "# 发票\n\n金额：100.00"}],
            "usage": {"pages": 1}
        })
    );
}

#[test]
fn volcengine_speech_concatenates_ndjson_audio_chunks_and_rejects_error_codes() {
    let mut tts = resolver(
        APIResolverKind::VolcengineSpeech,
        "seed-tts-2.0",
        json!({"input": "你好火山", "speed": 1.25}),
        json!({"voice": "zh_female_vv_uranus_bigtts"}),
    );

    assert_eq!(
        Value::Object(tts.build_body().unwrap()),
        json!({
            "user": {"uid": "ankole"},
            "req_params": {
                "text": "你好火山",
                "speaker": "zh_female_vv_uranus_bigtts",
                "audio_params": {
                    "format": "mp3",
                    "sample_rate": 24000,
                    "speech_rate": 25
                }
            }
        })
    );

    let chunk1 = STANDARD.encode_to_string(b"part-one-");
    let chunk2 = STANDARD.encode_to_string(b"part-two");
    let normalized = tts
        .normalize_body(
            200,
            json!([
                {"code": 0, "data": chunk1},
                {"code": 0, "data": chunk2},
                {"code": 20000000, "data": null, "message": "ok"}
            ]),
        )
        .unwrap();

    let combined = STANDARD
        .decode_to_vec(normalized["audio"].as_str().unwrap())
        .unwrap();
    assert_eq!(combined, b"part-one-part-two");
    assert_eq!(normalized["content_type"], "audio/mpeg");

    let err = tts
        .normalize_body(
            200,
            json!([{"code": 45000001, "message": "invalid speaker"}]),
        )
        .unwrap_err();
    assert_eq!(err.provider_status, Some(400));

    let raw_ndjson = format!(
        "{{\"code\":0,\"data\":\"{chunk1}\"}}\n{{\"code\":0,\"data\":\"{chunk2}\"}}\n{{\"code\":20000000,\"data\":null}}\n"
    );
    let wire_normalized = tts
        .normalize_http_response(
            200,
            &[("x-api-status-code".to_string(), "20000000".to_string())],
            raw_ndjson.as_bytes(),
        )
        .unwrap();
    assert_eq!(wire_normalized["audio"], normalized["audio"]);

    let header_err = tts
        .normalize_http_response(
            200,
            &[
                ("x-api-status-code".to_string(), "45000010".to_string()),
                (
                    "x-api-message".to_string(),
                    "invalid access key".to_string(),
                ),
            ],
            b"{}",
        )
        .unwrap_err();
    assert_eq!(header_err.code, "provider_status_rejected");
    assert_eq!(header_err.provider_status, Some(401));
    assert!(header_err.message.contains("invalid access key"));

    let rate_limit_err = tts
        .normalize_http_response(
            200,
            &[("x-api-status-code".to_string(), "50429".to_string())],
            b"",
        )
        .unwrap_err();
    assert_eq!(rate_limit_err.provider_status, Some(429));
}

#[test]
fn volcengine_transcription_converts_millisecond_durations_and_utterances_to_seconds() {
    let mut asr = resolver(
        APIResolverKind::VolcengineTranscription,
        "volc.bigasr.auc_turbo",
        json!({"input_audio": {"data": "UklGRg==", "format": "wav"}}),
        json!({}),
    );

    assert_eq!(
        Value::Object(asr.build_body().unwrap()),
        json!({
            "user": {"uid": "ankole"},
            "audio": {"data": "UklGRg==", "format": "wav"},
            "request": {
                "model_name": "bigmodel",
                "enable_itn": true,
                "enable_punc": true,
                "show_utterances": true
            }
        })
    );

    let normalized = asr
        .normalize_body(
            200,
            json!({
                "audio_info": {"duration": 3500},
                "result": {
                    "text": "早上好。",
                    "utterances": [
                        {"start_time": 200, "end_time": 3500, "text": "早上好。"}
                    ]
                }
            }),
        )
        .unwrap();

    assert_eq!(
        normalized,
        json!({
            "text": "早上好。",
            "duration": 3.5,
            "segments": [{"start": 0.2, "end": 3.5, "text": "早上好。"}],
            "usage": {"seconds": 3.5}
        })
    );
}

#[test]
fn volcengine_visual_ocr_encodes_urlencoded_form_and_parses_image_lines_or_pdf_markdown() {
    let mut image_ocr = resolver(
        APIResolverKind::VolcengineVisualOcr,
        "ocr-normal",
        json!({"document": "data:image/png;base64,a+b/c="}),
        json!({}),
    );
    let raw = image_ocr.build_raw_body().unwrap().unwrap();
    assert_eq!(raw.content_type, "application/x-www-form-urlencoded");
    assert_eq!(raw.bytes, b"image_base64=a%2Bb%2Fc%3D");

    let image_result = image_ocr
        .normalize_body(
            200,
            json!({
                "code": 10000,
                "data": {"line_texts": ["第一行", "第二行"]}
            }),
        )
        .unwrap();
    assert_eq!(
        image_result,
        json!({
            "model": "ocr-normal",
            "pages": [{"index": 0, "markdown": "第一行\n第二行"}],
            "usage": {"pages": 1}
        })
    );

    let mut pdf_ocr = resolver(
        APIResolverKind::VolcengineVisualOcr,
        "ocr-pdf",
        json!({"document": "data:application/pdf;base64,JVBERi0="}),
        json!({}),
    );
    let pdf_raw = pdf_ocr.build_raw_body().unwrap().unwrap();
    assert_eq!(
        pdf_raw.bytes,
        b"image_base64=JVBERi0%3D&file_type=pdf&version=v3"
    );

    let pdf_result = pdf_ocr
        .normalize_body(
            200,
            json!({
                "code": 10000,
                "data": {
                    "page_infos": [
                        {"page_id": 1, "markdown": "# Page 1"},
                        {"page_id": 2, "markdown": "## Page 2"}
                    ]
                }
            }),
        )
        .unwrap();
    assert_eq!(
        pdf_result,
        json!({
            "model": "ocr-pdf",
            "pages": [
                {"index": 0, "markdown": "# Page 1"},
                {"index": 1, "markdown": "## Page 2"}
            ],
            "usage": {"pages": 2}
        })
    );
}

#[test]
fn deepseek_speech_transcription_and_ocr_build_expected_json_and_multipart_wire_bodies() {
    let mut tts = resolver(
        APIResolverKind::DeepseekSpeech,
        "deepseek-tts",
        json!({"input": "你好 DeepSeek"}),
        json!({"filter_markdown": true}),
    );
    assert_eq!(
        Value::Object(tts.build_body().unwrap()),
        json!({
            "text": "你好 DeepSeek",
            "voice_id": "stella",
            "format": "wav",
            "filter_markdown": true
        })
    );
    let octets_normalized = tts
        .normalize_body(
            200,
            json!({"audio": "UklGRg==", "content_type": "application/octet-stream", "usage": {}}),
        )
        .unwrap();
    assert_eq!(octets_normalized["content_type"], "audio/wav");

    let non_utf8_wav = [0x52_u8, 0x49, 0x46, 0x46, 0xFF, 0xFE, 0x00, 0x01];
    let mut asr = resolver(
        APIResolverKind::DeepseekTranscription,
        "deepseek-asr",
        json!({
            "input_audio": {
                "data": STANDARD.encode_to_string(non_utf8_wav),
                "format": "wav"
            }
        }),
        json!({}),
    );
    let asr_raw = asr.build_raw_body().unwrap().unwrap();
    assert!(
        asr_raw
            .content_type
            .starts_with("multipart/form-data; boundary=")
    );
    assert!(
        asr_raw
            .bytes
            .windows(non_utf8_wav.len())
            .any(|window| window == non_utf8_wav)
    );

    let asr_normalized = asr
        .normalize_body(
            200,
            json!({"request_id": "req_1", "text": "识别文本", "duration_ms": 2400}),
        )
        .unwrap();
    assert_eq!(
        asr_normalized,
        json!({
            "text": "识别文本",
            "duration": 2.4,
            "usage": {"seconds": 2.4}
        })
    );

    let pdf_bytes = b"%PDF-1.7\n\xFF\xD8binary";
    let mut ocr = resolver(
        APIResolverKind::DeepseekOcr,
        "deepseek-ocr",
        json!({
            "document": format!("data:application/pdf;base64,{}", STANDARD.encode_to_string(pdf_bytes))
        }),
        json!({"purpose": "rich_layout_recognition"}),
    );
    let ocr_raw = ocr.build_raw_body().unwrap().unwrap();
    assert!(
        ocr_raw
            .content_type
            .starts_with("multipart/form-data; boundary=")
    );
    let ocr_ascii = String::from_utf8_lossy(&ocr_raw.bytes);
    assert!(ocr_ascii.contains("name=\"purpose\"\r\n\r\nrich_layout_recognition\r\n"));
    assert!(ocr_ascii.contains("filename=\"document.pdf\""));
    assert!(
        ocr_raw
            .bytes
            .windows(pdf_bytes.len())
            .any(|window| window == pdf_bytes)
    );

    let ocr_normalized = ocr
        .normalize_body(
            200,
            json!({
                "id": "ocr_1",
                "object": "ocr.result",
                "page_count": 2,
                "pages": [
                    {"index": 0, "text": "# Title\n\nBody", "finish_reason": "stop"},
                    {"index": 1, "text": "Second page", "finish_reason": "stop"}
                ]
            }),
        )
        .unwrap();
    assert_eq!(
        ocr_normalized,
        json!({
            "model": "deepseek-ocr",
            "pages": [
                {"index": 0, "markdown": "# Title\n\nBody"},
                {"index": 1, "markdown": "Second page"}
            ],
            "usage": {"pages": 2}
        })
    );
}
