defmodule Ankole.AIGateway.CreateImageTest do
  use Ankole.AIGatewayCase

  alias Ankole.AIGateway.ModelMetadata.Cache, as: ModelMetadataCache
  alias Ankole.AIGateway.Schemas.{Artifact, UsageRecord}

  @png_base64 "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
  @png_bytes Base.decode64!(@png_base64)

  test "create_image uses native Responses image_generation without persisting Artifact rows when provider_hosted.image_generate is true" do
    %{principal: agent} = agent_fixture()
    test_pid = self()
    provider_id = "native-img-#{System.unique_integer([:positive])}"

    base_url =
      start_upstream_server(fn request ->
        send(test_pid, {:native_responses_request, request})

        {:json, 200,
         %{
           "id" => "resp_native_img",
           "object" => "response",
           "status" => "completed",
           "output" => [
             %{
               "id" => "ig_native_1",
               "type" => "image_generation_call",
               "status" => "completed",
               "result" => @png_base64,
               "mime_type" => "image/png",
               "revised_prompt" => "A crisp geometric logo on white"
             }
           ],
           "usage" => %{"input_tokens" => 14, "output_tokens" => 6, "total_tokens" => 20}
         }}
      end)

    assert {:ok, _provider} =
             ProviderConfigs.create_provider(%{
               provider_id: provider_id,
               provider_kind: "openai",
               base_url: base_url <> "/v1",
               credential_pool: %{
                 "entries" => [%{"label" => "Main", "api_key" => "sk-native"}]
               },
               connection_options: %{"transport" => %{}}
             })

    assert {:ok, _profile} =
             ModelProfiles.put_model_profile(agent.uid, "primary", %{
               provider_id: provider_id,
               model: "gpt-5"
             })

    assert {:ok, %{body: body}} =
             AIGateway.create_image(
               agent.uid,
               %{
                 "prompt" => "Draw a geometric logo",
                 "size" => "1024x1024",
                 "quality" => "high",
                 "output_format" => "png"
               },
               caller: "pod_applet"
             )

    assert_receive {:native_responses_request, %{path: "v1/responses", body: req_body}}
    assert req_body["tool_choice"] == %{"type" => "image_generation"}

    assert [
             %{
               "type" => "image_generation",
               "size" => "1024x1024",
               "quality" => "high",
               "output_format" => "png"
             }
           ] = req_body["tools"]

    assert body["bytes"] == @png_bytes
    assert body["mime_type"] == "image/png"
    assert body["revised_prompt"] == "A crisp geometric logo on white"
    assert %{"input_tokens" => 14, "output_tokens" => 6, "total_tokens" => 20} = body["usage"]

    assert Repo.aggregate(Artifact, :count) == 0

    assert [%{subject_uid: subject_uid, origin: :applet, input_tokens: 14, output_tokens: 6}] =
             Repo.all(from(r in UsageRecord, where: r.model == ^"#{provider_id}/gpt-5"))

    assert subject_uid == agent.uid
  end

  test "create_image returns model_profile_not_configured when provider_hosted.image_generate is true and primary lacks native image generation" do
    %{principal: agent} = agent_fixture()
    test_pid = self()
    provider_id = "non-native-primary-#{System.unique_integer([:positive])}"

    base_url =
      start_upstream_server(fn request ->
        send(test_pid, {:unexpected_upstream_request, request})
        {:json, 500, %{"error" => "should not be called"}}
      end)

    assert {:ok, _provider} =
             ProviderConfigs.create_provider(%{
               provider_id: provider_id,
               provider_kind: "openai",
               base_url: base_url <> "/v1",
               credential_pool: %{
                 "entries" => [%{"label" => "Main", "api_key" => "sk-chat"}]
               },
               connection_options: %{"endpoint_kind" => "chat_completions", "transport" => %{}}
             })

    assert {:ok, _profile} =
             ModelProfiles.put_model_profile(agent.uid, "primary", %{
               provider_id: provider_id,
               model: "gpt-4.1"
             })

    assert {:error, :model_profile_not_configured} =
             AIGateway.create_image(agent.uid, %{"prompt" => "Draw a lighthouse"},
               caller: "pod_applet"
             )

    refute_receive {:unexpected_upstream_request, _}
  end

  test "create_image calls direct /images endpoint without invoking primary LLM when provider_hosted.image_generate is false" do
    %{principal: agent} = agent_fixture()
    test_pid = self()
    provider_id = "direct-openrouter-img-#{System.unique_integer([:positive])}"

    base_url =
      start_upstream_server(fn request ->
        send(test_pid, {:direct_image_request, request.path, request.body})

        {:json, 200,
         %{
           "data" => [
             %{
               "b64_json" => @png_base64,
               "media_type" => "image/png",
               "revised_prompt" => "Direct endpoint mountain sunrise"
             }
           ],
           "usage" => %{"input_tokens" => 9, "output_tokens" => 4, "total_tokens" => 13}
         }}
      end)

    assert {:ok, provider} =
             ProviderConfigs.create_provider(%{
               provider_id: provider_id,
               provider_kind: "openrouter",
               base_url: base_url <> "/api/v1",
               credential_pool: %{
                 "entries" => [%{"label" => "ImagePool", "api_key" => "sk-or-img"}]
               },
               connection_options: %{"transport" => %{}}
             })

    :ok =
      ModelMetadataCache.put(
        {:image_model_catalog, provider_id, provider.updated_at, "images/models"},
        [%{"id" => "openai/gpt-image-1"}],
        60_000
      )

    :ok =
      ModelMetadataCache.put(
        {:image_model_endpoints, provider_id, provider.updated_at,
         "images/models/openai/gpt-image-1/endpoints"},
        [
          %{
            "provider_slug" => "openai",
            "provider_tag" => "openai/gpt-image-1:openai",
            "supported_parameters" => %{
              "size" => %{"type" => "enum", "values" => ["1024x1024"]},
              "quality" => %{"type" => "enum", "values" => ["low", "medium", "high", "auto"]}
            }
          }
        ],
        60_000
      )

    assert {:ok, _} =
             ModelProfiles.put_provider_hosted_capabilities(agent.uid, %{
               "image_generate" => false
             })

    assert {:ok, _profile} =
             ModelProfiles.put_model_profile(agent.uid, "image_generate", %{
               provider_id: provider_id,
               model: "openai/gpt-image-1"
             })

    assert {:ok, %{body: body}} =
             AIGateway.create_image(
               agent.uid,
               %{
                 "prompt" => "Mountain sunrise",
                 "size" => "1024x1024",
                 "quality" => "medium"
               },
               caller: "pod_applet"
             )

    assert_receive {:direct_image_request, "api/v1/images", image_req_body}
    assert image_req_body["prompt"] == "Mountain sunrise"
    refute image_req_body["stream"] == true
    refute_receive {:direct_image_request, _, _}

    assert body["bytes"] == @png_bytes
    assert body["mime_type"] == "image/png"
    assert body["revised_prompt"] == "Direct endpoint mountain sunrise"
    assert body["usage"] == %{"input_tokens" => 9, "output_tokens" => 4, "total_tokens" => 13}
    assert Repo.aggregate(Artifact, :count) == 0
  end

  test "create_web_search with respect_provider_hosted?: true switches between native Responses search and standalone search provider" do
    %{principal: agent} = agent_fixture()
    test_pid = self()
    llm_provider_id = "native-search-llm-#{System.unique_integer([:positive])}"
    search_provider_id = "standalone-search-#{System.unique_integer([:positive])}"

    base_url =
      start_upstream_server(fn
        %{path: "v1/responses"} = req ->
          send(test_pid, {:native_search_req, req.body})

          {:json, 200,
           %{
             "id" => "resp_search_1",
             "object" => "response",
             "status" => "completed",
             "output" => [
               %{
                 "id" => "ws_1",
                 "type" => "web_search_call",
                 "status" => "completed",
                 "action" => %{
                   "type" => "search",
                   "sources" => [
                     %{
                       "url" => "https://example.com/native-doc",
                       "title" => "Native Search Doc",
                       "snippet" => "Hosted search excerpt"
                     }
                   ]
                 }
               },
               %{
                 "id" => "msg_1",
                 "type" => "message",
                 "role" => "assistant",
                 "content" => [%{"type" => "output_text", "text" => "Found Native Search Doc."}]
               }
             ],
             "usage" => %{"input_tokens" => 12, "output_tokens" => 8}
           }}

        %{path: "web-search/v1/search"} = req ->
          send(test_pid, {:standalone_search_req, req.body})

          {:json, 200,
           %{
             "query" => "ankole docs",
             "sources" => ["exa"],
             "items" => [
               %{
                 "title" => "Standalone Search Doc",
                 "url" => "https://example.com/standalone-doc",
                 "snippet" => "Standalone search excerpt",
                 "publishedAt" => "2026-10-01T00:00:00Z",
                 "rerankScore" => 0.95
               }
             ]
           }}
      end)

    assert {:ok, _} =
             ProviderConfigs.create_provider(%{
               provider_id: llm_provider_id,
               provider_kind: "openai",
               base_url: base_url <> "/v1",
               credential_pool: %{"entries" => [%{"label" => "LLM", "api_key" => "sk-llm"}]},
               connection_options: %{"transport" => %{}}
             })

    assert {:ok, _} =
             ProviderConfigs.create_provider(%{
               provider_id: search_provider_id,
               provider_kind: "agentbull_cloud",
               base_url: base_url,
               credential_pool: %{
                 "entries" => [%{"label" => "Search", "api_key" => "sk-search"}]
               },
               connection_options: %{"transport" => %{}}
             })

    assert {:ok, _} =
             ModelProfiles.put_model_profile(agent.uid, "primary", %{
               provider_id: llm_provider_id,
               model: "gpt-5"
             })

    assert {:ok, _} =
             ModelProfiles.put_model_profile(agent.uid, "web_search", %{
               provider_id: search_provider_id,
               model: "default"
             })

    # Default provider_hosted.web_search == true -> uses primary's native Responses web_search
    assert {:ok, %{body: %{"results" => [native_hit]}}} =
             AIGateway.create_web_search(
               agent.uid,
               %{"model" => "web_search.default", "query" => "ankole docs", "limit" => 3},
               respect_provider_hosted?: true,
               caller: "pod_applet"
             )

    assert_receive {:native_search_req, native_body}
    assert native_body["tools"] == [%{"type" => "web_search"}]
    assert native_body["tool_choice"] == "required"
    assert native_hit["url"] == "https://example.com/native-doc"
    assert native_hit["title"] == "Native Search Doc"
    assert native_hit["snippet"] == "Hosted search excerpt"

    # Flip provider_hosted.web_search == false -> uses standalone web_search profile
    assert {:ok, _} =
             ModelProfiles.put_provider_hosted_capabilities(agent.uid, %{"web_search" => false})

    assert {:ok, %{body: %{"results" => [standalone_hit]}}} =
             AIGateway.create_web_search(
               agent.uid,
               %{"model" => "web_search.default", "query" => "ankole docs", "limit" => 3},
               respect_provider_hosted?: true,
               caller: "pod_applet"
             )

    assert_receive {:standalone_search_req, _}
    assert standalone_hit["url"] == "https://example.com/standalone-doc"
    assert standalone_hit["title"] == "Standalone Search Doc"
  end
end
