defmodule Ankole.AIGateway.ImageModelCatalogTest do
  use Ankole.DataCase, async: false

  alias Ankole.AIGateway.ImageModelCatalog
  alias Ankole.AIGateway.HostedTools.ImageGeneration
  alias Ankole.AIGateway.ModelMetadata.Cache
  alias Ankole.AIGateway.ProviderConfigs
  alias Ankole.AIGateway.Providers

  setup do
    Cache.clear_for_test()

    provider_id = "openrouter-images-#{System.unique_integer([:positive])}"

    assert {:ok, provider} =
             ProviderConfigs.create_provider(%{
               provider_id: provider_id,
               provider_kind: "openrouter",
               credential_pool: %{
                 "entries" => [%{"label" => "Default", "api_key" => "sk-image-test"}]
               }
             })

    runtime = %{
      "provider_id" => provider.provider_id,
      "provider_kind" => provider.provider_kind,
      "provider" => provider,
      "model" => "openai/gpt-image-2"
    }

    %{runtime: runtime}
  end

  test "only OpenRouter declares image_generate in the current provider registry" do
    image_providers =
      Providers.all()
      |> Enum.filter(&Providers.supports_capability?(&1, "image_generate"))
      |> Enum.map(& &1.provider_kind)

    assert image_providers == ["openrouter"]
  end

  test "keeps compatible GPT Image endpoints eligible and preserves exact model IDs", %{
    runtime: runtime
  } do
    http_client = catalog_client()

    assert {:ok, selection} =
             ImageModelCatalog.select_endpoint(
               runtime,
               "gpt-image-2",
               %{
                 "quality" => "high",
                 "background" => "opaque",
                 "output_compression" => 80,
                 "moderation" => "low",
                 "partial_images" => 2
               },
               16,
               http_client: http_client,
               force_refresh: true
             )

    assert selection.model == "openai/gpt-image-2"
    assert selection.provider_slug == "openai"
    assert selection.provider_tag == "openai/gpt-image-2:openai"
    assert selection.provider_slugs == ["openai", "openai-backup"]

    assert selection.provider_tags == [
             "openai/gpt-image-2:openai",
             "openai/gpt-image-2:openai-backup"
           ]

    assert selection.supports_streaming

    assert {:error, missing} =
             ImageModelCatalog.select_endpoint(
               runtime,
               "openai/gpt-image-2-2099-01-01",
               %{},
               0,
               http_client: http_client,
               force_refresh: true
             )

    assert missing.param == "tools[0].model"
    assert missing.code == "model_not_found"
  end

  test "rejects unsupported fields and reference counts against definitive endpoints", %{
    runtime: runtime
  } do
    http_client = catalog_client()

    assert {:ok, gemini} =
             ImageModelCatalog.select_endpoint(
               runtime,
               "google/gemini-3.1-flash-lite-image",
               %{},
               14,
               http_client: http_client,
               force_refresh: true
             )

    refute gemini.supports_streaming

    for {tool, reference_count, expected_param} <- [
          {%{"quality" => "high"}, 0, "tools[0].quality"},
          {%{"background" => "opaque"}, 0, "tools[0].background"},
          {%{"output_compression" => 80}, 0, "tools[0].output_compression"},
          {%{"moderation" => "low"}, 0, "tools[0].moderation"},
          {%{"partial_images" => 1}, 0, "tools[0].partial_images"},
          {%{"size" => "1024x1024"}, 0, "tools[0].size"},
          {%{"output_format" => "png"}, 0, "tools[0].output_format"},
          {%{"input_fidelity" => "high"}, 0, "tools[0].input_fidelity"},
          {%{"input_image_mask" => %{"image_url" => "data:image/png;base64,AA=="}}, 0,
           "tools[0].input_image_mask"},
          {%{}, 15, "tools[0].input"}
        ] do
      assert {:error, error} =
               ImageModelCatalog.select_endpoint(
                 runtime,
                 "google/gemini-3.1-flash-lite-image",
                 tool,
                 reference_count,
                 http_client: http_client,
                 force_refresh: true
               )

      assert error.status == 400
      assert error.code == "unsupported_value"
      assert error.param == expected_param
      assert error.message == "Unsupported value for this image model."
    end

    for {tool, expected_param} <- [
          {%{"background" => "transparent"}, "tools[0].background"},
          {%{"size" => "1024x1024"}, "tools[0].size"},
          {%{"output_format" => "png"}, "tools[0].output_format"},
          {%{"input_fidelity" => "high"}, "tools[0].input_fidelity"},
          {%{"input_image_mask" => %{"image_url" => "data:image/png;base64,AA=="}},
           "tools[0].input_image_mask"}
        ] do
      assert {:error, error} =
               ImageModelCatalog.select_endpoint(
                 runtime,
                 "openai/gpt-image-2",
                 tool,
                 0,
                 http_client: http_client,
                 force_refresh: true
               )

      assert error.param == expected_param
      assert error.code == "unsupported_value"
      assert error.message == "Unsupported value for this image model."
    end
  end

  test "uses stale image metadata only after a failed refresh", %{runtime: runtime} do
    assert {:ok, initial} =
             ImageModelCatalog.select_endpoint(
               runtime,
               "openai/gpt-image-2",
               %{},
               0,
               http_client: catalog_client(),
               cache_ttl_ms: 0
             )

    failing_client = fn _request -> {:error, :catalog_offline} end

    assert {:ok, stale} =
             ImageModelCatalog.select_endpoint(
               runtime,
               "openai/gpt-image-2",
               %{},
               0,
               http_client: failing_client
             )

    assert stale.provider_tags == initial.provider_tags

    Cache.clear_for_test()

    assert {:error, unavailable} =
             ImageModelCatalog.select_endpoint(
               runtime,
               "openai/gpt-image-2",
               %{},
               0,
               http_client: failing_client
             )

    assert unavailable.status == 502
    assert unavailable.type == "server_error"
    assert unavailable.code == "upstream_error"
    assert unavailable.param == nil
  end

  test "maps image catalog rate limits, timeouts, credentials, and 5xx without leaking bodies", %{
    runtime: runtime
  } do
    cases = [
      {{:ok, %{"status" => 429, "body" => %{"secret" => "rate-body"}}},
       {429, "rate_limit_error", "rate_limit_exceeded"}},
      {{:ok, %{"status" => 504, "body" => "timeout-body"}},
       {504, "server_error", "upstream_timeout"}},
      {{:error, %{"code" => "total_timeout", "message" => "private timeout details"}},
       {504, "server_error", "upstream_timeout"}},
      {{:ok, %{"status" => 401, "body" => %{"key" => "sk-do-not-leak"}}},
       {502, "server_error", "upstream_error"}},
      {{:ok, %{"status" => 503, "body" => "provider internals"}},
       {502, "server_error", "upstream_error"}}
    ]

    for {client_result, {status, type, code}} <- cases do
      Cache.clear_for_test()
      client = fn _request -> client_result end

      assert {:error, error} =
               ImageModelCatalog.select_endpoint(
                 runtime,
                 "openai/gpt-image-2",
                 %{},
                 0,
                 http_client: client,
                 force_refresh: true
               )

      assert error.status == status
      assert error.type == type
      assert error.code == code
      assert error.param == nil
      refute error.message =~ "secret"
      refute error.message =~ "private"
      refute error.message =~ "provider internals"
    end
  end

  test "reports the actual image tool index in validation and capability errors", %{
    runtime: runtime
  } do
    request = %{
      "tools" => [
        %{"type" => "function", "name" => "lookup"},
        %{"type" => "image_generation", "unknown_option" => true}
      ]
    }

    assert {:error, validation_error} = ImageGeneration.prepare("agent_test", request)
    assert validation_error.param == "tools[1].unknown_option"

    assert {:error, capability_error} =
             ImageModelCatalog.select_endpoint(
               runtime,
               "google/gemini-3.1-flash-lite-image",
               %{"quality" => "high"},
               0,
               http_client: catalog_client(),
               force_refresh: true,
               tool_index: 1
             )

    assert capability_error.param == "tools[1].quality"
  end

  test "fails closed for unknown or untyped endpoint descriptors", %{runtime: runtime} do
    for descriptor <- [%{"type" => "future_descriptor"}, true] do
      Cache.clear_for_test()

      assert {:error, error} =
               ImageModelCatalog.select_endpoint(
                 runtime,
                 "openai/gpt-image-2",
                 %{"quality" => "high"},
                 0,
                 http_client: catalog_client(%{"quality" => descriptor}),
                 force_refresh: true
               )

      assert error.code == "unsupported_value"
      assert error.param == "tools[0].quality"
    end

    Cache.clear_for_test()

    assert {:ok, _selection} =
             ImageModelCatalog.select_endpoint(
               runtime,
               "openai/gpt-image-2",
               %{"input_image_mask" => %{"image_url" => "data:image/png;base64,AA=="}},
               0,
               http_client: catalog_client(%{"input_image_mask" => %{"type" => "boolean"}}),
               force_refresh: true
             )
  end

  test "configured profiles require a definitive usable endpoint", %{runtime: runtime} do
    client = fn request ->
      cond do
        String.ends_with?(request.url, "/images/models") ->
          {:ok,
           %{
             "status" => 200,
             "body" => %{
               "data" => [
                 %{"id" => "openrouter/auto"},
                 %{"id" => "google/gemini-3.1-flash-lite-image"}
               ]
             }
           }}

        String.ends_with?(request.url, "/images/models/openrouter/auto/endpoints") ->
          {:ok, %{"status" => 200, "body" => %{"endpoints" => []}}}

        String.ends_with?(
          request.url,
          "/images/models/google/gemini-3.1-flash-lite-image/endpoints"
        ) ->
          {:ok,
           %{
             "status" => 200,
             "body" => %{
               "endpoints" => [
                 %{
                   "provider_slug" => "google",
                   "provider_tag" => "google/gemini-3.1-flash-lite-image:google",
                   "supported_parameters" => %{}
                 }
               ]
             }
           }}
      end
    end

    provider = runtime["provider"]

    assert {:error, :image_model_unavailable} =
             ImageModelCatalog.validate_configured_model(provider, "openrouter/auto",
               http_client: client,
               force_refresh: true
             )

    assert :ok =
             ImageModelCatalog.validate_configured_model(
               provider,
               "google/gemini-3.1-flash-lite-image",
               http_client: client,
               force_refresh: true
             )

    Cache.clear_for_test()

    assert {:error, :image_model_catalog_unavailable} =
             ImageModelCatalog.validate_configured_model(provider, "openrouter/auto",
               http_client: fn _request ->
                 {:ok,
                  %{
                    "status" => 404,
                    "body" => %{"error" => "private provider detail must not escape"}
                  }}
               end,
               force_refresh: true
             )
  end

  defp catalog_client(supported_overrides \\ %{}) do
    fn request ->
      assert {"authorization", "Bearer sk-image-test"} in request.headers

      cond do
        String.ends_with?(request.url, "/images/models") ->
          {:ok,
           %{
             "status" => 200,
             "body" => %{
               "data" => [
                 %{"id" => "openai/gpt-image-2"},
                 %{"id" => "google/gemini-3.1-flash-lite-image"}
               ]
             }
           }}

        String.ends_with?(request.url, "/images/models/openai/gpt-image-2/endpoints") ->
          supported_parameters =
            Map.merge(
              %{
                "input_references" => %{
                  "type" => "range",
                  "min" => 0,
                  "max" => 16
                },
                "quality" => %{
                  "type" => "enum",
                  "values" => ["auto", "low", "medium", "high"]
                },
                "background" => %{
                  "type" => "enum",
                  "values" => ["auto", "opaque"]
                },
                "output_compression" => %{
                  "type" => "range",
                  "min" => 0,
                  "max" => 100
                }
              },
              supported_overrides
            )

          {:ok,
           %{
             "status" => 200,
             "body" => %{
               "endpoints" => [
                 %{
                   "provider_slug" => "openai",
                   "provider_tag" => "openai/gpt-image-2:openai",
                   "supports_streaming" => true,
                   "allowed_passthrough_parameters" => ["moderation"],
                   "supported_parameters" => supported_parameters
                 },
                 %{
                   "provider_slug" => "openai-backup",
                   "provider_tag" => "openai/gpt-image-2:openai-backup",
                   "supports_streaming" => true,
                   "allowed_passthrough_parameters" => ["moderation"],
                   "supported_parameters" => supported_parameters
                 }
               ]
             }
           }}

        String.ends_with?(
          request.url,
          "/images/models/google/gemini-3.1-flash-lite-image/endpoints"
        ) ->
          {:ok,
           %{
             "status" => 200,
             "body" => %{
               "endpoints" => [
                 %{
                   "provider_slug" => "google",
                   "provider_tag" => "google/gemini-3.1-flash-lite-image:google",
                   "supports_streaming" => false,
                   "allowed_passthrough_parameters" => [],
                   "supported_parameters" => %{
                     "input_references" => %{"type" => "range", "min" => 0, "max" => 14}
                   }
                 }
               ]
             }
           }}

        true ->
          {:error, {:unexpected_catalog_request, request.url}}
      end
    end
  end
end
