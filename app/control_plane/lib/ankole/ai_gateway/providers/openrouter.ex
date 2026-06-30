defmodule Ankole.AIGateway.Providers.OpenRouter do
  @moduledoc """
  OpenRouter provider backed by its OpenAI-compatible API surface.
  https://openrouter.ai/docs/api/reference/overview
  """

  use Ankole.AIGateway.ProviderDSL

  alias Ankole.AIGateway.ReasoningEffort
  alias Ankole.AIGateway.UniversalAIRequest

  @default_referer "https://github.com/agentbull/ankole"
  @default_title "Ankole"

  provider :openrouter do
    label(%{"default" => "OpenRouter", "zh-Hans-CN" => "OpenRouter"})
    base_url("https://openrouter.ai/api/v1")

    setting(:api_key, encrypted: true)
    setting(:headers, type: :map)
    setting(:query_params, type: :map)
    setting(:include_usage, type: :boolean)
    setting(:supports_structured_outputs, type: :boolean)
    setting(:app_referer, default: @default_referer)
    setting(:app_title, default: @default_title)
    setting(:referer)
    setting(:title)

    setting(:user, scope: :request)
    setting(:reasoning, scope: :request)
    setting(:reasoningEffort, scope: :request)
    setting(:textVerbosity, scope: :request)
    setting(:strictJsonSchema, scope: :request)

    language_model do
      upstream(:sse)
      api_resolver(:openai_chat_completions)
      prepare(:prepare_language_model)
    end

    embedding_model do
      upstream(:json)
      api_resolver(:openrouter_embeddings)
      prepare(:prepare_embedding_model)
    end

    rerank_model do
      upstream(:json)
      api_resolver(:openrouter_rerank)
      prepare(:prepare_rerank_model)
    end
  end

  @doc """
  Builds an OpenRouter chat-completions request.

  OpenRouter exposes an OpenAI-compatible chat surface, so this provider only
  adds OpenRouter attribution headers before the native OpenAI resolver handles
  the response.
  """
  def prepare_language_model(ctx) do
    ctx
    |> UniversalAIRequest.new("chat/completions", :openai_chat_completions)
    |> common_headers(ctx)
    |> UniversalAIRequest.bearer_auth()
    |> ReasoningEffort.put_provider_options(ctx, skip_if_present: ["reasoning"])
  end

  @doc """
  Builds an OpenRouter embeddings request.

  OpenRouter has its own embedding catalog and response contract, even though
  it is close to the OpenAI embedding shape.
  """
  def prepare_embedding_model(ctx) do
    ctx
    |> UniversalAIRequest.new("embeddings", :openrouter_embeddings)
    |> common_headers(ctx)
    |> UniversalAIRequest.bearer_auth()
  end

  @doc """
  Builds an OpenRouter rerank request.

  OpenRouter rerank returns OpenRouter-style result metadata such as generated
  ids and search-unit usage.
  """
  def prepare_rerank_model(ctx) do
    ctx
    |> UniversalAIRequest.new("rerank", :openrouter_rerank)
    |> common_headers(ctx)
    |> UniversalAIRequest.bearer_auth()
  end

  @impl true
  def models_metadata_source(ctx) when is_map(ctx) do
    headers =
      ctx
      |> UniversalAIRequest.raw_headers()
      |> common_headers(ctx)
      |> UniversalAIRequest.bearer_auth(ctx.settings[:api_key])

    {:ok,
     {:openrouter,
      %{
        ctx: ctx,
        path: "models?output_modalities=all",
        headers: headers,
        cache_key: "models?output_modalities=all"
      }}}
  end

  @doc """
  Checks OpenRouter connectivity through a provider-owned model catalog endpoint.
  """
  @impl true
  def check_connection(ctx) when is_map(ctx) do
    path =
      case Map.get(ctx, :capability) || Map.get(ctx, "capability") do
        capability when capability in ["embedding", :embedding, :embedding_model] ->
          "embeddings/models"

        _capability ->
          "models"
      end

    headers =
      ctx
      |> UniversalAIRequest.raw_headers()
      |> common_headers(ctx)
      |> UniversalAIRequest.bearer_auth(ctx.settings[:api_key])

    with {:ok, %{"status" => status, "body" => body}} when status in 200..299 <-
           UniversalAIRequest.raw_get(ctx, path, headers: headers) do
      {:ok, body}
    else
      {:ok, %{"status" => status, "body" => body}} ->
        {:error, {:provider_connection_check_failed, status, body}}

      {:error, _reason} = error ->
        error
    end
  end

  # OpenRouter recommends attribution headers. `put_new` keeps explicit runtime
  # headers authoritative when an installation wants to override these defaults.
  defp common_headers(request, ctx) do
    {referer, title} = attribution(ctx)

    request
    |> UniversalAIRequest.put_new_header("HTTP-Referer", referer)
    |> UniversalAIRequest.put_new_header("X-Title", title)
    |> UniversalAIRequest.put_new_header("X-OpenRouter-Title", title)
  end

  defp attribution(ctx) do
    {
      ctx.settings[:app_referer] || ctx.settings[:referer] || @default_referer,
      ctx.settings[:app_title] || ctx.settings[:title] || @default_title
    }
  end
end
