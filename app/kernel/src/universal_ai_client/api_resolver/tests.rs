#[cfg(test)]
mod tests {
    use serde_json::json;

    use super::*;

    #[test]
    fn openai_responses_passthrough_adds_zero_based_sequence() {
        let mut resolver = ApiResolver::new(
            ApiResolverKind::OpenaiResponses,
            ResponseContext::default(),
        );

        let events = resolver
            .ingest(json!({"type": "response.created"}))
            .unwrap();

        assert_eq!(events[0]["type"], "response.created");
        assert_eq!(events[0]["sequence_number"], 0);
    }

    #[test]
    fn openai_responses_requires_terminal_event_on_finish() {
        let mut resolver = ApiResolver::new(
            ApiResolverKind::OpenaiResponses,
            ResponseContext::default(),
        );

        let error = resolver.finish().unwrap_err();

        assert_eq!(error.code, "upstream_stream_closed_before_terminal_event");
    }

    #[test]
    fn openai_responses_error_event_is_not_terminal_by_itself() {
        let mut resolver = ApiResolver::new(
            ApiResolverKind::OpenaiResponses,
            ResponseContext::default(),
        );

        resolver
            .ingest(json!({"type": "error", "error": {"code": "boom"}}))
            .unwrap();

        let error = resolver.finish().unwrap_err();
        assert_eq!(error.code, "upstream_stream_closed_before_terminal_event");
    }

    #[test]
    fn openai_chat_accumulates_text_usage_and_terminal_response() {
        let mut resolver = ApiResolver::new(
            ApiResolverKind::OpenaiChatCompletions,
            ResponseContext {
                model: "gpt-test".to_string(),
                request: json!({"input": "hi"}),
                provider_options: json!({}),
                stream: None,
                include_model: true,
            },
        );

        let events = resolver
            .ingest(json!({
                "id": "chatcmpl_1",
                "created": 10,
                "model": "gpt-test",
                "choices": [{"delta": {"content": "hello"}, "finish_reason": null}]
            }))
            .unwrap();
        assert!(
            events
                .iter()
                .any(|event| event["type"] == "response.output_text.delta")
        );

        let events = resolver
            .ingest(json!({
                "usage": {"prompt_tokens": 2, "completion_tokens": 3, "total_tokens": 5},
                "choices": [{"delta": {}, "finish_reason": "stop"}]
            }))
            .unwrap();
        let terminal = events.last().unwrap();

        assert_eq!(terminal["type"], "response.completed");
        assert_eq!(
            terminal["response"]["output"][0]["content"][0]["text"],
            "hello"
        );
        assert_eq!(terminal["response"]["usage"]["total_tokens"], 5);
    }

    #[test]
    fn openai_chat_accumulates_tool_calls() {
        let mut resolver = ApiResolver::new(
            ApiResolverKind::OpenaiChatCompletions,
            ResponseContext::default(),
        );

        resolver
            .ingest(json!({
                "choices": [{
                    "delta": {"tool_calls": [{
                        "index": 0,
                        "id": "call_1",
                        "function": {"name": "get_weather", "arguments": "{\"city\""}
                    }]},
                    "finish_reason": null
                }]
            }))
            .unwrap();
        let events = resolver
            .ingest(json!({
                "choices": [{
                    "delta": {"tool_calls": [{
                        "index": 0,
                        "function": {"arguments": ":\"Shanghai\"}"}
                    }]},
                    "finish_reason": "tool_calls"
                }]
            }))
            .unwrap();
        let terminal = events.last().unwrap();
        let call = terminal["response"]["output"]
            .as_array()
            .unwrap()
            .iter()
            .find(|item| item["type"] == "function_call")
            .unwrap();

        assert_eq!(call["name"], "get_weather");
        assert_eq!(call["arguments"], "{\"city\":\"Shanghai\"}");
    }

    #[test]
    fn jina_embeddings_preserves_multivector_items() {
        let mut resolver = ApiResolver::new(
            ApiResolverKind::JinaEmbeddings,
            ResponseContext {
                model: "jina-embeddings-v4".to_string(),
                request: json!({}),
                provider_options: json!({}),
                stream: None,
                include_model: true,
            },
        );

        let body = resolver
            .normalize_body(
                200,
                json!({
                    "model": "jina-embeddings-v4",
                    "data": [{
                        "embeddings": [[0.1, 0.2], [0.3, 0.4]],
                        "tokenized_input": ["hello", "world"]
                    }],
                    "usage": {"total_tokens": 2}
                }),
            )
            .unwrap();

        assert_eq!(body["data"][0]["index"], 0);
        assert_eq!(body["data"][0]["object"], "embedding");
        assert_eq!(body["data"][0]["embeddings"], json!([[0.1, 0.2], [0.3, 0.4]]));
        assert!(body["data"][0].get("embedding").is_none());
    }

    #[test]
    fn jina_embeddings_preserves_string_embedding_and_multimodal_usage() {
        let mut resolver = ApiResolver::new(
            ApiResolverKind::JinaEmbeddings,
            ResponseContext {
                model: "jina-embeddings-v4".to_string(),
                request: json!({}),
                provider_options: json!({}),
                stream: None,
                include_model: true,
            },
        );

        let body = resolver
            .normalize_body(
                200,
                json!({
                    "model": "jina-embeddings-v4",
                    "object": "list",
                    "usage": {
                        "total_tokens": 5,
                        "prompt_tokens": 2,
                        "image_tokens": 1,
                        "audio_tokens": 1,
                        "video_tokens": 1
                    },
                    "data": [{
                        "object": "embedding",
                        "embedding": "base64-embedding"
                    }]
                }),
            )
            .unwrap();

        assert_eq!(body["object"], "list");
        assert_eq!(body["data"][0]["index"], 0);
        assert_eq!(body["data"][0]["embedding"], "base64-embedding");
        assert_eq!(body["usage"]["image_tokens"], 1);
        assert_eq!(body["usage"]["audio_tokens"], 1);
        assert_eq!(body["usage"]["video_tokens"], 1);
    }

    #[test]
    fn anthropic_text_stream_accumulates_response_body() {
        let mut resolver = ApiResolver::new(
            ApiResolverKind::AnthropicMessages,
            ResponseContext {
                model: "claude-test".to_string(),
                request: json!({}),
                provider_options: json!({}),
                stream: None,
                include_model: true,
            },
        );

        resolver
            .ingest(json!({
                "type": "message_start",
                "message": {"id": "msg_1", "model": "claude-test", "usage": {"input_tokens": 1}}
            }))
            .unwrap();
        resolver
            .ingest(json!({
                "type": "content_block_start",
                "index": 0,
                "content_block": {"type": "text"}
            }))
            .unwrap();
        resolver
            .ingest(json!({
                "type": "content_block_delta",
                "index": 0,
                "delta": {"type": "text_delta", "text": "hello"}
            }))
            .unwrap();
        resolver
            .ingest(json!({
                "type": "message_delta",
                "delta": {"stop_reason": "end_turn"},
                "usage": {"output_tokens": 2}
            }))
            .unwrap();
        let events = resolver.ingest(json!({"type": "message_stop"})).unwrap();
        let terminal = events.last().unwrap();

        assert_eq!(terminal["type"], "response.completed");
        assert_eq!(
            terminal["response"]["output"][0]["content"][0]["text"],
            "hello"
        );
        assert_eq!(terminal["response"]["usage"]["total_tokens"], 3);
    }

    #[test]
    fn anthropic_message_stop_closes_open_text_block() {
        let mut resolver = ApiResolver::new(
            ApiResolverKind::AnthropicMessages,
            ResponseContext {
                model: "claude-test".to_string(),
                request: json!({}),
                provider_options: json!({}),
                stream: None,
                include_model: true,
            },
        );

        resolver
            .ingest(json!({
                "type": "message_start",
                "message": {"id": "msg_1", "model": "claude-test"}
            }))
            .unwrap();
        resolver
            .ingest(json!({
                "type": "content_block_start",
                "index": 0,
                "content_block": {"type": "text"}
            }))
            .unwrap();
        resolver
            .ingest(json!({
                "type": "content_block_delta",
                "index": 0,
                "delta": {"type": "text_delta", "text": "hello"}
            }))
            .unwrap();

        let events = resolver
            .ingest(json!({
                "type": "message_stop"
            }))
            .unwrap();

        assert!(
            events
                .iter()
                .any(|event| event["type"] == "response.output_text.done")
        );
        assert!(
            events
                .iter()
                .any(|event| event["type"] == "response.content_part.done")
        );
        assert_eq!(events.last().unwrap()["type"], "response.completed");
    }

    #[test]
    fn gemini_generate_content_accumulates_text_tool_and_usage() {
        let mut resolver = ApiResolver::new(
            ApiResolverKind::GeminiGenerateContent,
            ResponseContext {
                model: "gemini-test".to_string(),
                request: json!({}),
                provider_options: json!({}),
                stream: None,
                include_model: true,
            },
        );

        let events = resolver
            .ingest(json!({
                "candidates": [{
                    "content": {
                        "parts": [
                            {"text": "hello gemini"},
                            {"functionCall": {"name": "lookup", "args": {"query": "weather"}}}
                        ]
                    },
                    "finishReason": "STOP"
                }],
                "usageMetadata": {
                    "promptTokenCount": 4,
                    "candidatesTokenCount": 6,
                    "totalTokenCount": 10
                }
            }))
            .unwrap();
        let terminal = events.last().unwrap();
        let output = terminal["response"]["output"].as_array().unwrap();

        assert_eq!(terminal["type"], "response.completed");
        assert_eq!(output[0]["content"][0]["text"], "hello gemini");
        assert!(
            output
                .iter()
                .any(|item| item["type"] == "function_call" && item["name"] == "lookup")
        );
        assert_eq!(terminal["response"]["usage"]["total_tokens"], 10);
    }

    #[test]
    fn bedrock_converse_accumulates_eventstream_text_and_usage() {
        let mut resolver = ApiResolver::new(
            ApiResolverKind::BedrockConverse,
            ResponseContext {
                model: "bedrock-test".to_string(),
                request: json!({}),
                provider_options: json!({}),
                stream: None,
                include_model: true,
            },
        );

        resolver
            .ingest(json!({
                "contentBlockDelta": {"delta": {"text": "hello bedrock"}}
            }))
            .unwrap();
        resolver
            .ingest(json!({
                "metadata": {
                    "usage": {"inputTokens": 3, "outputTokens": 5, "totalTokens": 8}
                }
            }))
            .unwrap();
        let events = resolver.ingest(json!({"messageStop": {}})).unwrap();
        let terminal = events.last().unwrap();

        assert_eq!(terminal["type"], "response.completed");
        assert_eq!(
            terminal["response"]["output"][0]["content"][0]["text"],
            "hello bedrock"
        );
        assert_eq!(terminal["response"]["usage"]["total_tokens"], 8);
    }

    #[test]
    fn openrouter_embeddings_normalizes_openrouter_body() {
        let mut resolver = ApiResolver::new(
            ApiResolverKind::OpenrouterEmbeddings,
            ResponseContext {
                model: "openai/text-embedding-3-small".to_string(),
                request: json!({}),
                provider_options: json!({}),
                stream: None,
                include_model: true,
            },
        );

        let body = resolver
            .normalize_body(
                200,
                json!({
                    "data": [{
                        "embedding": [0.1, 0.2],
                        "object": "embedding"
                    }],
                    "object": "list",
                    "usage": {"prompt_tokens": 2, "total_tokens": 2}
                }),
            )
            .unwrap();

        assert_eq!(body["model"], "openai/text-embedding-3-small");
        assert_eq!(body["data"][0]["index"], 0);
        assert_eq!(body["data"][0]["embedding"], json!([0.1, 0.2]));
        assert_eq!(body["usage"]["total_tokens"], 2);
    }

    #[test]
    fn google_embeddings_normalizes_native_embed_content_body() {
        let mut resolver = ApiResolver::new(
            ApiResolverKind::GoogleEmbeddings,
            ResponseContext {
                model: "gemini-embedding-001".to_string(),
                request: json!({}),
                provider_options: json!({}),
                stream: None,
                include_model: true,
            },
        );

        let body = resolver
            .normalize_body(200, json!({"embedding": {"values": [0.1, 0.2]}}))
            .unwrap();

        assert_eq!(body["object"], "list");
        assert_eq!(body["model"], "gemini-embedding-001");
        assert_eq!(body["data"][0]["object"], "embedding");
        assert_eq!(body["data"][0]["embedding"], json!([0.1, 0.2]));
        assert_eq!(body["data"][0]["index"], 0);
    }

    #[test]
    fn google_embeddings_normalizes_native_batch_body() {
        let mut resolver = ApiResolver::new(
            ApiResolverKind::GoogleEmbeddings,
            ResponseContext {
                model: "gemini-embedding-001".to_string(),
                request: json!({}),
                provider_options: json!({}),
                stream: None,
                include_model: true,
            },
        );

        let body = resolver
            .normalize_body(
                200,
                json!({"embeddings": [{"values": [0.1]}, {"values": [0.2]}]}),
            )
            .unwrap();

        assert_eq!(body["data"][0]["embedding"], json!([0.1]));
        assert_eq!(body["data"][0]["index"], 0);
        assert_eq!(body["data"][1]["embedding"], json!([0.2]));
        assert_eq!(body["data"][1]["index"], 1);
    }

    #[test]
    fn openrouter_rerank_preserves_provider_and_results() {
        let mut resolver = ApiResolver::new(
            ApiResolverKind::OpenrouterRerank,
            ResponseContext {
                model: "cohere/rerank-v3.5".to_string(),
                request: json!({"documents": ["Paris", "Berlin"]}),
                provider_options: json!({}),
                stream: None,
                include_model: true,
            },
        );

        let body = resolver
            .normalize_body(
                200,
                json!({
                    "id": "gen-rerank-123",
                    "model": "cohere/rerank-v3.5",
                    "provider": "Cohere",
                    "results": [{
                        "document": {"text": "Paris"},
                        "index": 0,
                        "relevance_score": 0.98
                    }],
                    "usage": {"total_tokens": 12}
                }),
            )
            .unwrap();

        assert_eq!(body["id"], "gen-rerank-123");
        assert_eq!(body["provider"], "Cohere");
        assert_eq!(body["results"][0]["document"], json!({"text": "Paris"}));
        assert_eq!(body["results"][0]["relevance_score"], 0.98);
    }

    #[test]
    fn jina_rerank_reconstructs_document_when_omitted() {
        let mut resolver = ApiResolver::new(
            ApiResolverKind::JinaRerank,
            ResponseContext {
                model: "jina-reranker-v3".to_string(),
                request: json!({"documents": ["Paris", {"text": "Berlin"}]}),
                provider_options: json!({}),
                stream: None,
                include_model: true,
            },
        );

        let body = resolver
            .normalize_body(
                200,
                json!({
                    "model": "jina-reranker-v3",
                    "results": [{"index": 1, "relevance_score": 0.31}],
                    "usage": {"total_tokens": 12}
                }),
            )
            .unwrap();

        assert_eq!(body["results"][0]["document"], json!({"text": "Berlin"}));
        assert_eq!(body["results"][0]["index"], 1);
        assert_eq!(body["usage"]["total_tokens"], 12);
    }

    #[test]
    fn jina_rerank_normalizes_string_document_and_preserves_embedding() {
        let mut resolver = ApiResolver::new(
            ApiResolverKind::JinaRerank,
            ResponseContext {
                model: "jina-reranker-v3".to_string(),
                request: json!({"documents": ["Paris"]}),
                provider_options: json!({}),
                stream: None,
                include_model: true,
            },
        );

        let body = resolver
            .normalize_body(
                200,
                json!({
                    "model": "jina-reranker-v3",
                    "object": "list",
                    "results": [{
                        "index": 0,
                        "relevance_score": 0.99,
                        "document": "Paris is the capital of France.",
                        "embedding": [1]
                    }],
                    "usage": {"total_tokens": 1}
                }),
            )
            .unwrap();

        assert_eq!(body["object"], "list");
        assert_eq!(
            body["results"][0]["document"],
            json!({"text": "Paris is the capital of France."})
        );
        assert_eq!(body["results"][0]["embedding"], json!([1]));
        assert_eq!(body["usage"]["total_tokens"], 1);
    }

    #[test]
    fn native_error_events_use_openresponses_error_then_failed() {
        let mut resolver = ApiResolver::new(
            ApiResolverKind::OpenaiChatCompletions,
            ResponseContext::default(),
        );

        let events = resolver.fail(&StreamError::new(
            "invalid_provider_event",
            "api_resolver",
            "bad event",
        ));

        assert_eq!(events[0]["type"], "error");
        assert_eq!(events[1]["type"], "response.failed");
        assert_eq!(events[1]["response"]["status"], "failed");
    }
}
