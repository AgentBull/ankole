defmodule Ankole.AIGateway.AgentBullCloudEndpointsTest do
  use ExUnit.Case, async: true

  alias Ankole.AIGateway.PrepareContext
  alias Ankole.AIGateway.Providers.AgentBullCloud
  alias Ankole.AIGateway.UniversalAIRequest

  @default_root "https://cloudapis.agentbull.com/v1"

  test "default configuration places every endpoint under the default API root" do
    assert prepared_url(:language_model, :prepare_language_model, %{}, %{"input" => "hello"}) ==
             @default_root <> "/responses"

    assert prepared_url(
             :language_model,
             :prepare_language_model,
             %{"endpoint_kind" => "chat_completions"},
             %{"input" => "hello"}
           ) == @default_root <> "/chat/completions"

    assert prepared_url(:embedding_model, :prepare_embedding_model, %{}, %{
             "input" => "hello"
           }) == @default_root <> "/embeddings"

    assert prepared_url(:rerank_model, :prepare_rerank_model, %{}, %{
             "query" => "capital",
             "documents" => ["Berlin", "Paris"]
           }) == @default_root <> "/rerank"

    assert prepared_url(:image_generate, :prepare_image_generate, %{}, %{
             "prompt" => "a cat",
             "n" => 1
           }) == @default_root <> "/images"
  end

  test "web search stays on the host root instead of the API root" do
    assert prepared_url(:web_search, :prepare_web_search, %{}, %{"query" => "hello"}) ==
             "https://cloudapis.agentbull.com/web-search/v1/search"
  end

  test "websocket transport uses the secure WebSocket scheme under the default root" do
    ctx =
      build(:language_model, %{"upstream_transport" => "websocket"}, %{"input" => "hello"},
        stream?: true
      )

    assert ctx
           |> AgentBullCloud.prepare_language_model()
           |> spec_url() == "wss://cloudapis.agentbull.com/v1/responses"
  end

  test "catalog sources resolve under the default root" do
    ctx = build(:language_model, %{}, %{"input" => "hello"})

    assert {:ok, {:openrouter, source}} = AgentBullCloud.models_metadata_source(ctx)
    assert catalog_url(ctx, source.path) == @default_root <> "/models?output_modalities=all"

    assert {:ok, image_source} = AgentBullCloud.image_models_metadata_source(ctx)
    assert catalog_url(ctx, image_source.models_path) == @default_root <> "/images/models"
  end

  test "trailing slashes in base_url do not duplicate the API root" do
    for base_url <- [@default_root, @default_root <> "/"] do
      ctx = build(:language_model, %{"base_url" => base_url}, %{"input" => "hello"})

      assert ctx
             |> AgentBullCloud.prepare_language_model()
             |> spec_url() == @default_root <> "/responses"
    end
  end

  defp prepared_url(capability, prepare, connection_overrides, request) do
    capability
    |> build(connection_overrides, request)
    |> then(&apply(AgentBullCloud, prepare, [&1]))
    |> spec_url()
  end

  defp build(capability, connection_overrides, request, opts \\ []) do
    assert {:ok, ctx} =
             PrepareContext.build(
               AgentBullCloud.provider_definition(),
               capability,
               %{
                 "model" => "test-model",
                 "provider_options" => %{},
                 "connection_options" =>
                   Map.merge(%{"api_key" => "sk-test"}, connection_overrides)
               },
               request,
               stream?: Keyword.get(opts, :stream?, false)
             )

    ctx
  end

  defp spec_url(prepared) do
    assert {:ok, spec} = UniversalAIRequest.to_spec(prepared)
    spec.upstream.url
  end

  defp catalog_url(ctx, path) do
    ctx
    |> UniversalAIRequest.new(path, :openrouter_images)
    |> spec_url()
  end
end
