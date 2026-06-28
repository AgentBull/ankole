defmodule Ankole.AIGateway.VectorTest do
  use Ankole.AIGatewayCase

  test "embeddings and rerank normalize public response shapes" do
    %{principal: agent} = agent_fixture()

    assert {:ok, _openrouter} =
             ProviderConfigs.create_provider(%{
               provider_id: "openrouter-vector",
               provider_kind: "openrouter",
               credential: "sk-openrouter",
               base_url: "https://openrouter.ai/api/v1",
               connection_options: %{}
             })

    assert {:ok, embedding} =
             AIGateway.create_embeddings(
               agent.uid,
               %{
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
               },
               http_client: fn request ->
                 assert request.url == "https://openrouter.ai/api/v1/embeddings"
                 assert request.body["model"] == "openai/text-embedding-3-small"
                 assert request.body["dimensions"] == 1536
                 assert request.body["encoding_format"] == "float"
                 assert [%{"content" => content}] = request.body["input"]
                 assert Enum.any?(content, &(&1["type"] == "image_url"))

                 {:ok,
                  %{
                    status: 200,
                    body: %{
                      "data" => [%{"embedding" => [0.1]}],
                      "usage" => %{"prompt_tokens" => 3, "total_tokens" => 3}
                    }
                  }}
               end
             )

    assert embedding.body["model"] == "openai/text-embedding-3-small"
    assert [%{"embedding" => [0.1], "index" => 0}] = embedding.body["data"]
    assert embedding.body["usage"] == %{"prompt_tokens" => 3, "total_tokens" => 3}

    assert {:ok, rerank} =
             AIGateway.create_rerank(
               agent.uid,
               %{
                 "model" => "openrouter-vector/cohere/rerank-v3.5",
                 "query" => "capital",
                 "documents" => [
                   "Paris is the capital of France.",
                   %{"text" => "Berlin is the capital of Germany."},
                   %{"image" => "https://example.com/map.png"}
                 ],
                 "top_n" => 2
               },
               http_client: fn request ->
                 assert request.url == "https://openrouter.ai/api/v1/rerank"
                 assert request.body["model"] == "cohere/rerank-v3.5"
                 assert request.body["query"] == "capital"
                 assert request.body["top_n"] == 2

                 assert [
                          "Paris is the capital of France.",
                          %{"text" => "Berlin is the capital of Germany."},
                          %{"image" => "https://example.com/map.png"}
                        ] = request.body["documents"]

                 {:ok,
                  %{
                    status: 200,
                    body: %{
                      "provider" => "cohere",
                      "results" => [
                        %{
                          "document" => %{"text" => "Paris is the capital of France."},
                          "index" => 0,
                          "relevance_score" => 0.98
                        },
                        %{
                          "text" => "Berlin is the capital of Germany.",
                          "score" => 0.12
                        }
                      ],
                      "usage" => %{"search_units" => 1, "total_tokens" => 150}
                    }
                  }}
               end
             )

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

    assert {:ok, _jina} =
             ProviderConfigs.create_provider(%{
               provider_id: "jina-rerank-no-documents",
               provider_kind: "jina",
               credential: "jina-key",
               base_url: "https://api.jina.ai/v1",
               connection_options: %{}
             })

    assert {:ok, response} =
             AIGateway.create_rerank(
               agent.uid,
               %{
                 "model" => "jina-rerank-no-documents/jina-reranker-v3",
                 "query" => "capital of France",
                 "documents" => [
                   "Paris is the capital of France.",
                   %{"text" => "Berlin is the capital of Germany."}
                 ],
                 "return_documents" => false,
                 "top_n" => 1
               },
               http_client: fn request ->
                 assert request.path == "rerank"
                 assert request.body["return_documents"] == false

                 {:ok,
                  %{
                    status: 200,
                    body: %{
                      "results" => [%{"index" => 1, "relevance_score" => 0.31}],
                      "usage" => %{"total_tokens" => 12}
                    }
                  }}
               end
             )

    assert [
             %{
               "document" => %{"text" => "Berlin is the capital of Germany."},
               "index" => 1,
               "relevance_score" => 0.31
             }
           ] = response.body["results"]
  end

  test "embeddings and rerank return structured errors for upstream non-2xx" do
    %{principal: agent} = agent_fixture()

    assert {:ok, _openrouter} =
             ProviderConfigs.create_provider(%{
               provider_id: "openrouter-vector-upstream-error",
               provider_kind: "openrouter",
               credential: "sk-openrouter",
               base_url: "https://openrouter.ai/api/v1",
               connection_options: %{}
             })

    assert {:error,
            {:upstream_response_failed, 400,
             %{"error" => %{"message" => "invalid embedding request"}}}} =
             AIGateway.create_embeddings(
               agent.uid,
               %{
                 "model" => "openrouter-vector-upstream-error/openai/text-embedding-3-small",
                 "input" => "hello"
               },
               http_client: fn request ->
                 assert request.path == "embeddings"

                 {:ok,
                  %{status: 400, body: %{"error" => %{"message" => "invalid embedding request"}}}}
               end
             )

    assert {:error,
            {:upstream_response_failed, 500,
             %{"error" => %{"message" => "rerank provider unavailable"}}}} =
             AIGateway.create_rerank(
               agent.uid,
               %{
                 "model" => "openrouter-vector-upstream-error/cohere/rerank-v3.5",
                 "query" => "capital",
                 "documents" => ["Paris"]
               },
               http_client: fn request ->
                 assert request.path == "rerank"

                 {:ok,
                  %{
                    status: 500,
                    body: %{"error" => %{"message" => "rerank provider unavailable"}}
                  }}
               end
             )
  end

  test "embeddings and rerank treat 2xx top-level provider error bodies as failures" do
    %{principal: agent} = agent_fixture()

    assert {:ok, _openrouter} =
             ProviderConfigs.create_provider(%{
               provider_id: "openrouter-vector-body-error",
               provider_kind: "openrouter",
               credential: "sk-openrouter",
               base_url: "https://openrouter.ai/api/v1",
               connection_options: %{}
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
             AIGateway.create_embeddings(
               agent.uid,
               %{
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
               },
               http_client: fn request ->
                 assert request.path == "embeddings"

                 {:ok,
                  %{
                    status: 200,
                    body: %{
                      "data" => [],
                      "error" => %{
                        "code" => 400,
                        "message" => "Perplexity embeddings do not support image_url inputs"
                      }
                    }
                  }}
               end
             )

    assert {:error,
            {:upstream_response_failed, 502,
             %{"error" => %{"code" => "provider_error", "message" => "rerank failed"}}}} =
             AIGateway.create_rerank(
               agent.uid,
               %{
                 "model" => "openrouter-vector-body-error/cohere/rerank-4-fast",
                 "query" => "capital",
                 "documents" => ["Paris"]
               },
               http_client: fn request ->
                 assert request.path == "rerank"

                 {:ok,
                  %{
                    status: 200,
                    body: %{
                      "error" => %{"code" => "provider_error", "message" => "rerank failed"}
                    }
                  }}
               end
             )
  end

  test "embeddings and rerank reject requests outside the OpenRouter contract" do
    %{principal: agent} = agent_fixture()

    assert {:ok, _openrouter} =
             ProviderConfigs.create_provider(%{
               provider_id: "openrouter-invalid-vector",
               provider_kind: "openrouter",
               credential: "sk-openrouter",
               base_url: "https://openrouter.ai/api/v1",
               connection_options: %{}
             })

    assert {:error, :missing_input} =
             AIGateway.create_embeddings(
               agent.uid,
               %{"model" => "openrouter-invalid-vector/openai/text-embedding-3-small"},
               http_client: fn _request ->
                 flunk("invalid embedding request should not dispatch")
               end
             )

    assert {:error, :invalid_documents} =
             AIGateway.create_rerank(
               agent.uid,
               %{
                 "model" => "openrouter-invalid-vector/cohere/rerank-v3.5",
                 "query" => "capital",
                 "documents" => []
               },
               http_client: fn _request -> flunk("invalid rerank request should not dispatch") end
             )

    assert {:error, :invalid_top_n} =
             AIGateway.create_rerank(
               agent.uid,
               %{
                 "model" => "openrouter-invalid-vector/cohere/rerank-v3.5",
                 "query" => "capital",
                 "documents" => ["Paris"],
                 "top_n" => 0
               },
               http_client: fn _request -> flunk("invalid rerank request should not dispatch") end
             )
  end

  test "selector and capability failures fail closed before provider dispatch" do
    %{principal: agent} = agent_fixture()

    assert {:ok, _provider} =
             ProviderConfigs.create_provider(%{
               provider_id: "openai-llm-only",
               provider_kind: "openai",
               credential: "sk-openai",
               base_url: "https://api.openai.test/v1",
               connection_options: %{}
             })

    dispatch = fn _request -> flunk("selector or capability errors must not dispatch") end

    assert {:error, {:unknown_model_selector, "llm", "missing-alias"}} =
             AIGateway.create_response(
               agent.uid,
               %{"model" => "missing-alias", "input" => "hello"},
               http_client: dispatch
             )

    assert {:error, {:unsupported_capability, "embedding"}} =
             AIGateway.create_embeddings(
               agent.uid,
               %{"model" => "openai-llm-only/text-embedding-3-small", "input" => "hello"},
               http_client: dispatch
             )
  end
end
