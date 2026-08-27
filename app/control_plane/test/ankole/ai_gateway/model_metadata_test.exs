defmodule Ankole.AIGateway.ModelMetadataTest do
  use Ankole.DataCase, async: false

  alias Ankole.AIGateway.ModelMetadata
  alias Ankole.AIGateway.ProviderConfigs

  setup do
    ModelMetadata.Cache.clear_for_test()
    :ok
  end

  test "providers without metadata hook use llm_db by convention" do
    assert {:ok, openai} =
             ProviderConfigs.create_provider(%{
               provider_id: "openai-metadata-source",
               provider_kind: "openai",
               credential_pool: %{
                 "entries" => [%{"label" => "Default", "api_key" => "sk-openai"}]
               }
             })

    assert {:ok, openai_metadata} = ModelMetadata.model_metadata(openai, "gpt-4o-mini")
    assert openai_metadata["context_length"] == 128_000

    assert {:ok, claude} =
             ProviderConfigs.create_provider(%{
               provider_id: "claude-metadata-source",
               provider_kind: "claude",
               credential_pool: %{
                 "entries" => [%{"label" => "Default", "api_key" => "sk-anthropic"}]
               }
             })

    assert {:ok, claude_metadata} = ModelMetadata.model_metadata(claude, "claude-sonnet-4-6")

    assert get_in(claude_metadata, ["architecture", "input_modalities"]) == [
             "text",
             "image",
             "pdf"
           ]
  end

  test "china-market provider metadata uses explicit aliases and static sources" do
    assert {:ok, xiaomi} =
             ProviderConfigs.create_provider(%{
               provider_id: "xiaomi-metadata-source",
               provider_kind: "xiaomi_mimo",
               credential_pool: %{"entries" => [%{"label" => "Default", "api_key" => "mimo-key"}]}
             })

    assert {:ok, xiaomi_metadata} = ModelMetadata.model_metadata(xiaomi, "mimo-v2.5")
    assert xiaomi_metadata["context_length"] == 1_048_576

    assert {:ok, volcengine} =
             ProviderConfigs.create_provider(%{
               provider_id: "volcengine-metadata-source",
               provider_kind: "volcengine_ark",
               credential_pool: %{"entries" => [%{"label" => "Default", "api_key" => "ark-key"}]}
             })

    assert {:ok, doubao_metadata} =
             ModelMetadata.model_metadata(volcengine, "doubao-seed-1-6")

    assert doubao_metadata["context_length"] == 256_000
    assert get_in(doubao_metadata, ["top_provider", "max_completion_tokens"]) == 32_000
  end

  test "provider metadata hook is used when present" do
    assert {:ok, openrouter} =
             ProviderConfigs.create_provider(%{
               provider_id: "openrouter-metadata-source",
               provider_kind: "openrouter",
               credential_pool: %{
                 "entries" => [%{"label" => "Default", "api_key" => "sk-openrouter"}]
               }
             })

    http_client = fn request ->
      send(self(), {:metadata_hook_request, request.url})
      {:ok, %{"status" => 200, "body" => %{"data" => [%{"id" => "openai/gpt-4"}]}}}
    end

    assert {:ok, [%{"id" => "openai/gpt-4"}]} =
             ModelMetadata.list_provider_model_metadata(openrouter, http_client: http_client)

    assert_receive {:metadata_hook_request,
                    "https://openrouter.ai/api/v1/models?output_modalities=all"}
  end

  test "unknown llm_db provider falls back without blocking metadata lookup" do
    assert {:ok, provider} =
             ProviderConfigs.create_provider(%{
               provider_id: "compatible-metadata-source",
               provider_kind: "openai_compatible",
               base_url: "https://compatible.test/v1",
               credential_pool: %{
                 "entries" => [%{"label" => "Default", "api_key" => "sk-compatible"}]
               }
             })

    assert {:ok, []} = ModelMetadata.list_provider_model_metadata(provider)

    assert {:ok, metadata} =
             ModelMetadata.model_metadata(provider, "local-model", capability: "llm")

    assert metadata["id"] == "local-model"
    assert metadata["context_length"] == 0
    assert get_in(metadata, ["architecture", "output_modalities"]) == ["text"]
  end

  test "llm_db metadata maps to OpenRouter-style fields" do
    assert {:ok, provider} =
             ProviderConfigs.create_provider(%{
               provider_id: "openai-llmdb-metadata",
               provider_kind: "openai",
               credential_pool: %{
                 "entries" => [%{"label" => "Default", "api_key" => "sk-openai"}]
               }
             })

    assert {:ok, metadata} = ModelMetadata.model_metadata(provider, "gpt-4o-mini")

    assert metadata["id"] == "gpt-4o-mini"
    assert metadata["name"] == "GPT-4o mini"
    assert metadata["context_length"] == 128_000
    assert get_in(metadata, ["top_provider", "max_completion_tokens"]) == 16_384
    assert get_in(metadata, ["architecture", "input_modalities"]) == ["text", "image", "pdf"]
    assert get_in(metadata, ["architecture", "output_modalities"]) == ["text"]
    assert metadata["pricing"]["prompt"] == "0.00000015"
    assert "tools" in metadata["supported_parameters"]
  end

  test "OpenRouter metadata source normalizes and caches responses" do
    assert {:ok, provider} =
             ProviderConfigs.create_provider(%{
               provider_id: "openrouter-cache-source",
               provider_kind: "openrouter",
               credential_pool: %{
                 "entries" => [%{"label" => "Default", "api_key" => "sk-openrouter"}]
               }
             })

    http_client = fn request ->
      send(self(), {:openrouter_request, request})

      {:ok,
       %{
         "status" => 200,
         "body" => %{
           "data" => [
             %{
               "id" => "openai/gpt-4",
               "name" => "GPT-4",
               "context_length" => 8192,
               "created" => 1_692_901_234,
               "architecture" => %{
                 "input_modalities" => ["text"],
                 "output_modalities" => ["text"],
                 "modality" => "text->text",
                 "instruct_type" => "chatml",
                 "tokenizer" => "GPT"
               },
               "pricing" => %{
                 "prompt" => "0.00003",
                 "completion" => "0.00006",
                 "image" => "0",
                 "request" => "0"
               },
               "supported_parameters" => ["temperature", "top_p", "max_tokens"],
               "top_provider" => %{
                 "is_moderated" => true,
                 "context_length" => 8192,
                 "max_completion_tokens" => 4096
               }
             }
           ]
         }
       }}
    end

    opts = [http_client: http_client, cache_ttl_ms: 60_000]

    assert {:ok, [metadata]} = ModelMetadata.list_provider_model_metadata(provider, opts)
    assert_receive {:openrouter_request, request}
    assert request.url == "https://openrouter.ai/api/v1/models?output_modalities=all"
    assert {"authorization", "Bearer sk-openrouter"} in request.headers

    assert metadata["id"] == "openai/gpt-4"
    assert metadata["context_length"] == 8192
    assert get_in(metadata, ["top_provider", "max_completion_tokens"]) == 4096
    assert get_in(metadata, ["architecture", "tokenizer"]) == "GPT"

    assert {:ok, [cached]} = ModelMetadata.list_provider_model_metadata(provider, opts)
    assert cached["id"] == "openai/gpt-4"
    refute_receive {:openrouter_request, _request}, 50
  end

  test "OpenRouter metadata source returns stale cache on refresh failure" do
    assert {:ok, provider} =
             ProviderConfigs.create_provider(%{
               provider_id: "openrouter-stale-source",
               provider_kind: "openrouter",
               credential_pool: %{
                 "entries" => [%{"label" => "Default", "api_key" => "sk-openrouter"}]
               }
             })

    success_client = fn request ->
      send(self(), {:stale_source_request, request.url})

      {:ok,
       %{
         "status" => 200,
         "body" => %{"data" => [%{"id" => "openai/stale", "context_length" => 1024}]}
       }}
    end

    assert {:ok, [%{"id" => "openai/stale"}]} =
             ModelMetadata.list_provider_model_metadata(provider,
               http_client: success_client,
               cache_ttl_ms: 0
             )

    assert_receive {:stale_source_request,
                    "https://openrouter.ai/api/v1/models?output_modalities=all"}

    failing_client = fn request ->
      send(self(), {:stale_source_refresh, request.url})
      {:error, :upstream_down}
    end

    assert {:ok, [%{"id" => "openai/stale"}]} =
             ModelMetadata.list_provider_model_metadata(provider,
               http_client: failing_client,
               cache_ttl_ms: 0
             )

    assert_receive {:stale_source_refresh,
                    "https://openrouter.ai/api/v1/models?output_modalities=all"}
  end

  test "ChatGPT subscription metadata lists the account's visible API models" do
    assert {:ok, provider} =
             ProviderConfigs.create_provider(%{
               provider_id: "chatgpt-metadata-source",
               provider_kind: "chatgpt_subscription",
               credential_pool: %{
                 "entries" => [
                   %{
                     "label" => "Default",
                     "access_token" => "chatgpt-access",
                     "refresh_token" => "chatgpt-refresh",
                     "id_token" => "chatgpt-id",
                     "account_id" => "chatgpt-account",
                     "auth_type" => "oauth"
                   }
                 ]
               }
             })

    http_client = fn request ->
      send(self(), {:chatgpt_metadata_request, request})

      {:ok,
       %{
         "status" => 200,
         "body" => %{
           "models" => [
             %{
               "slug" => "gpt-5.6-sol",
               "display_name" => "GPT-5.6 Sol",
               "description" => "Frontier coding model.",
               "visibility" => "list",
               "supported_in_api" => true,
               "context_window" => 400_000,
               "input_modalities" => ["text", "image"]
             },
             %{
               "slug" => "hidden-model",
               "display_name" => "Hidden Model",
               "visibility" => "hide",
               "supported_in_api" => true
             },
             %{
               "slug" => "unsupported-model",
               "display_name" => "Unsupported Model",
               "visibility" => "list",
               "supported_in_api" => false
             }
           ]
         }
       }}
    end

    opts = [http_client: http_client, cache_ttl_ms: 60_000]

    assert {:ok, [metadata]} = ModelMetadata.list_provider_model_metadata(provider, opts)
    assert_receive {:chatgpt_metadata_request, request}

    assert request.url ==
             "https://chatgpt.com/backend-api/codex/models?client_version=0.150.1"

    assert {"Authorization", "Bearer chatgpt-access"} in request.headers
    assert {"ChatGPT-Account-ID", "chatgpt-account"} in request.headers
    assert {"Originator", "codex_cli_rs"} in request.headers
    assert metadata["id"] == "gpt-5.6-sol"
    assert metadata["name"] == "GPT-5.6 Sol"
    assert metadata["context_length"] == 400_000
    assert get_in(metadata, ["architecture", "input_modalities"]) == ["text", "image"]
    assert get_in(metadata, ["architecture", "output_modalities"]) == ["text"]

    assert {:ok, [%{"id" => "gpt-5.6-sol"}]} =
             ModelMetadata.list_provider_model_metadata(provider, opts)

    refute_receive {:chatgpt_metadata_request, _request}, 50
  end
end
