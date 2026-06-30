defmodule Ankole.AIGateway.VectorTest do
  use Ankole.AIGatewayCase

  test "embeddings and rerank normalize public response shapes" do
    %{principal: agent} = agent_fixture()

    base_url =
      start_recording_upstream(self(), fn
        %{path: "embeddings"} ->
          {:json, 200,
           %{
             "data" => [%{"embedding" => [0.1]}],
             "usage" => %{"prompt_tokens" => 3, "total_tokens" => 3}
           }}

        %{path: "rerank"} ->
          {:json, 200,
           %{
             "provider" => "cohere",
             "results" => [
               %{
                 "document" => %{"text" => "Paris is the capital of France."},
                 "index" => 0,
                 "relevance_score" => 0.98
               },
               %{"text" => "Berlin is the capital of Germany.", "score" => 0.12}
             ],
             "usage" => %{"search_units" => 1, "total_tokens" => 150}
           }}
      end)

    assert {:ok, _openrouter} =
             ProviderConfigs.create_provider(%{
               provider_id: "openrouter-vector",
               provider_kind: "openrouter",
               base_url: base_url,
               connection_options: %{
                 "api_key" => "sk-openrouter",
                 "transport" => %{
                   "http_versions" => ["h1"],
                   "compression" => ["zstd", "br", "gzip"]
                 }
               }
             })

    assert {:ok, embedding} =
             AIGateway.create_embeddings(agent.uid, %{
               "model" => "openrouter-vector/openai/text-embedding-3-small",
               "input" => [
                 %{
                   "content" => [
                     %{"type" => "text", "text" => "hello"},
                     %{
                       "type" => "image_url",
                       "image_url" => %{"url" => "https://example.com/image.png"}
                     }
                   ]
                 }
               ],
               "dimensions" => 1536,
               "encoding_format" => "float"
             })

    assert_receive {:gateway_request, request}
    assert request.path == "embeddings"
    assert request.body["model"] == "openai/text-embedding-3-small"
    assert request.body["dimensions"] == 1536
    assert request.body["encoding_format"] == "float"
    assert [%{"content" => content}] = request.body["input"]
    assert Enum.any?(content, &(&1["type"] == "image_url"))

    assert embedding.body["model"] == "openai/text-embedding-3-small"
    assert [%{"embedding" => [0.1], "index" => 0}] = embedding.body["data"]
    assert embedding.body["usage"] == %{"prompt_tokens" => 3, "total_tokens" => 3}

    assert {:ok, rerank} =
             AIGateway.create_rerank(agent.uid, %{
               "model" => "openrouter-vector/cohere/rerank-v3.5",
               "query" => "capital",
               "documents" => [
                 "Paris is the capital of France.",
                 %{"text" => "Berlin is the capital of Germany."},
                 %{"image" => "https://example.com/map.png"}
               ],
               "top_n" => 2
             })

    assert_receive {:gateway_request, request}
    assert request.path == "rerank"
    assert request.body["model"] == "cohere/rerank-v3.5"
    assert request.body["query"] == "capital"
    assert request.body["top_n"] == 2

    assert [
             "Paris is the capital of France.",
             %{"text" => "Berlin is the capital of Germany."},
             %{"image" => "https://example.com/map.png"}
           ] = request.body["documents"]

    assert rerank.body["model"] == "cohere/rerank-v3.5"
    assert is_binary(rerank.body["id"])
    assert rerank.body["provider"] == "cohere"
    assert rerank.body["usage"] == %{"search_units" => 1, "total_tokens" => 150}

    assert [
             %{
               "document" => %{"text" => "Paris is the capital of France."},
               "index" => 0,
               "relevance_score" => 0.98
             },
             %{
               "document" => %{"text" => "Berlin is the capital of Germany."},
               "index" => 1,
               "relevance_score" => 0.12
             }
           ] = rerank.body["results"]

    refute Map.has_key?(List.last(rerank.body["results"]), "text")
    refute Map.has_key?(List.last(rerank.body["results"]), "score")
  end

  test "rerank normalization reconstructs document when upstream omits it" do
    %{principal: agent} = agent_fixture()

    base_url =
      start_recording_upstream(self(), fn _request ->
        {:json, 200,
         %{
           "results" => [%{"index" => 1, "relevance_score" => 0.31}],
           "usage" => %{"total_tokens" => 12}
         }}
      end)

    assert {:ok, _jina} =
             ProviderConfigs.create_provider(%{
               provider_id: "jina-rerank-no-documents",
               provider_kind: "jina",
               base_url: base_url,
               connection_options: %{
                 "api_key" => "jina-key",
                 "transport" => %{
                   "http_versions" => ["h1"],
                   "compression" => ["zstd", "br", "gzip"]
                 }
               }
             })

    assert {:ok, response} =
             AIGateway.create_rerank(agent.uid, %{
               "model" => "jina-rerank-no-documents/jina-reranker-v3",
               "query" => "capital of France",
               "documents" => [
                 "Paris is the capital of France.",
                 %{"text" => "Berlin is the capital of Germany."}
               ],
               "provider_options" => %{
                 "return_documents" => false,
                 "top_n" => 1
               }
             })

    assert_receive {:gateway_request, request}
    assert request.path == "rerank"
    assert request.body["return_documents"] == false
    assert request.body["top_n"] == 1
    refute Map.has_key?(request.body, "provider_options")

    assert [
             %{
               "document" => %{"text" => "Berlin is the capital of Germany."},
               "index" => 1,
               "relevance_score" => 0.31
             }
           ] = response.body["results"]
  end

  test "jina embeddings use Jina request options and response metadata" do
    %{principal: agent} = agent_fixture()

    base_url =
      start_recording_upstream(self(), fn %{path: "embeddings"} ->
        {:json, 200,
         %{
           "model" => "jina-embeddings-v4",
           "object" => "list",
           "usage" => %{
             "total_tokens" => 5,
             "prompt_tokens" => 2,
             "image_tokens" => 1,
             "audio_tokens" => 1,
             "video_tokens" => 1
           },
           "data" => [
             %{
               "object" => "embedding",
               "index" => 0,
               "embedding" => "base64-embedding"
             }
           ]
         }}
      end)

    assert {:ok, _jina} =
             ProviderConfigs.create_provider(%{
               provider_id: "jina-embeddings-base64",
               provider_kind: "jina",
               base_url: base_url,
               connection_options: %{
                 "api_key" => "jina-key",
                 "transport" => %{
                   "http_versions" => ["h1"],
                   "compression" => ["zstd", "br", "gzip"]
                 }
               }
             })

    assert {:ok, response} =
             AIGateway.create_embeddings(agent.uid, %{
               "model" => "jina-embeddings-base64/jina-embeddings-v4",
               "input" => [%{"text" => "hello"}, %{"image" => "https://example.com/image.png"}],
               "provider_options" => %{
                 "embedding_type" => "base64",
                 "task" => "retrieval.passage",
                 "normalized" => true
               }
             })

    assert_receive {:gateway_request, request}
    assert request.path == "embeddings"
    assert request.body["model"] == "jina-embeddings-v4"
    assert request.body["embedding_type"] == "base64"
    assert request.body["task"] == "retrieval.passage"
    assert request.body["normalized"] == true
    refute Map.has_key?(request.body, "provider_options")

    assert response.body["object"] == "list"
    assert response.body["usage"]["image_tokens"] == 1
    assert response.body["usage"]["audio_tokens"] == 1
    assert response.body["usage"]["video_tokens"] == 1

    assert [
             %{
               "object" => "embedding",
               "index" => 0,
               "embedding" => "base64-embedding"
             }
           ] = response.body["data"]
  end

  test "embeddings and rerank return structured errors for upstream non-2xx" do
    %{principal: agent} = agent_fixture()

    base_url =
      start_recording_upstream(self(), fn
        %{path: "embeddings"} ->
          {:json, 400, %{"error" => %{"message" => "invalid embedding request"}}}

        %{path: "rerank"} ->
          {:json, 500, %{"error" => %{"message" => "rerank provider unavailable"}}}
      end)

    assert {:ok, _openrouter} =
             ProviderConfigs.create_provider(%{
               provider_id: "openrouter-vector-upstream-error",
               provider_kind: "openrouter",
               base_url: base_url,
               connection_options: %{
                 "api_key" => "sk-openrouter",
                 "transport" => %{
                   "http_versions" => ["h1"],
                   "compression" => ["zstd", "br", "gzip"]
                 }
               }
             })

    assert {:error,
            {:upstream_response_failed, 400,
             %{"error" => %{"message" => "invalid embedding request"}}}} =
             AIGateway.create_embeddings(agent.uid, %{
               "model" => "openrouter-vector-upstream-error/openai/text-embedding-3-small",
               "input" => "hello"
             })

    assert_receive {:gateway_request, request}
    assert request.path == "embeddings"

    assert {:error,
            {:upstream_response_failed, 500,
             %{"error" => %{"message" => "rerank provider unavailable"}}}} =
             AIGateway.create_rerank(agent.uid, %{
               "model" => "openrouter-vector-upstream-error/cohere/rerank-v3.5",
               "query" => "capital",
               "documents" => ["Paris"]
             })

    assert_receive {:gateway_request, request}
    assert request.path == "rerank"
  end

  test "embeddings and rerank treat 2xx top-level provider error bodies as failures" do
    %{principal: agent} = agent_fixture()

    base_url =
      start_recording_upstream(self(), fn
        %{path: "embeddings"} ->
          {:json, 200,
           %{
             "data" => [],
             "error" => %{
               "code" => 400,
               "message" => "Perplexity embeddings do not support image_url inputs"
             }
           }}

        %{path: "rerank"} ->
          {:json, 200, %{"error" => %{"code" => "provider_error", "message" => "rerank failed"}}}
      end)

    assert {:ok, _openrouter} =
             ProviderConfigs.create_provider(%{
               provider_id: "openrouter-vector-body-error",
               provider_kind: "openrouter",
               base_url: base_url,
               connection_options: %{
                 "api_key" => "sk-openrouter",
                 "transport" => %{
                   "http_versions" => ["h1"],
                   "compression" => ["zstd", "br", "gzip"]
                 }
               }
             })

    assert {:error,
            {:upstream_response_failed, 400,
             %{
               "data" => [],
               "error" => %{
                 "code" => 400,
                 "message" => "Perplexity embeddings do not support image_url inputs"
               }
             }}} =
             AIGateway.create_embeddings(agent.uid, %{
               "model" => "openrouter-vector-body-error/perplexity/pplx-embed-v1-0.6b",
               "input" => [
                 %{
                   "content" => [
                     %{
                       "type" => "image_url",
                       "image_url" => %{"url" => "data:image/png;base64,x"}
                     }
                   ]
                 }
               ]
             })

    assert_receive {:gateway_request, request}
    assert request.path == "embeddings"

    assert {:error,
            {:upstream_response_failed, 502,
             %{"error" => %{"code" => "provider_error", "message" => "rerank failed"}}}} =
             AIGateway.create_rerank(agent.uid, %{
               "model" => "openrouter-vector-body-error/cohere/rerank-4-fast",
               "query" => "capital",
               "documents" => ["Paris"]
             })

    assert_receive {:gateway_request, request}
    assert request.path == "rerank"
  end

  test "embeddings and rerank reject requests outside the OpenRouter contract" do
    %{principal: agent} = agent_fixture()

    base_url =
      start_recording_upstream(self(), fn _request ->
        {:json, 500, %{"error" => %{"message" => "should not dispatch"}}}
      end)

    assert {:ok, _openrouter} =
             ProviderConfigs.create_provider(%{
               provider_id: "openrouter-invalid-vector",
               provider_kind: "openrouter",
               base_url: base_url,
               connection_options: %{
                 "api_key" => "sk-openrouter",
                 "transport" => %{
                   "http_versions" => ["h1"],
                   "compression" => ["zstd", "br", "gzip"]
                 }
               }
             })

    assert {:error, :missing_input} =
             AIGateway.create_embeddings(agent.uid, %{
               "model" => "openrouter-invalid-vector/openai/text-embedding-3-small"
             })

    assert {:error, :invalid_embedding_input} =
             AIGateway.create_embeddings(agent.uid, %{
               "model" => "openrouter-invalid-vector/openai/text-embedding-3-small",
               "input" => []
             })

    assert {:error, :missing_query} =
             AIGateway.create_rerank(agent.uid, %{
               "model" => "openrouter-invalid-vector/cohere/rerank-v3.5",
               "documents" => ["Paris"]
             })

    assert {:error, :invalid_documents} =
             AIGateway.create_rerank(agent.uid, %{
               "model" => "openrouter-invalid-vector/cohere/rerank-v3.5",
               "query" => "capital",
               "documents" => []
             })

    assert {:error, :invalid_top_n} =
             AIGateway.create_rerank(agent.uid, %{
               "model" => "openrouter-invalid-vector/cohere/rerank-v3.5",
               "query" => "capital",
               "documents" => ["Paris"],
               "top_n" => 0
             })

    refute_receive {:gateway_request, _request}, 100
  end

  test "selector and capability failures fail closed before provider dispatch" do
    %{principal: agent} = agent_fixture()

    base_url =
      start_recording_upstream(self(), fn _request ->
        {:json, 500, %{"error" => %{"message" => "should not dispatch"}}}
      end)

    assert {:ok, _provider} =
             ProviderConfigs.create_provider(%{
               provider_id: "openai-llm-only",
               provider_kind: "openai",
               base_url: base_url,
               connection_options: %{
                 "api_key" => "sk-openai",
                 "transport" => %{
                   "http_versions" => ["h1"],
                   "compression" => ["zstd", "br", "gzip"]
                 }
               }
             })

    assert {:error, {:unknown_model_selector, "llm", "missing-alias"}} =
             AIGateway.create_response(agent.uid, %{
               "model" => "missing-alias",
               "input" => "hello"
             })

    assert {:error, {:unsupported_capability, "embedding"}} =
             AIGateway.create_embeddings(agent.uid, %{
               "model" => "openai-llm-only/text-embedding-3-small",
               "input" => "hello"
             })

    refute_receive {:gateway_request, _request}, 100
  end

  defp start_recording_upstream(test_pid, response_fun) do
    start_upstream_server(fn request ->
      send(test_pid, {:gateway_request, request})
      response_fun.(request)
    end)
  end
end
