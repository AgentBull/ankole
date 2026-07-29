defmodule Ankole.AIGateway.Providers.OpenRouter do
  @moduledoc """
  OpenRouter provider backed by its OpenAI-compatible API surface.
  https://openrouter.ai/docs/api/reference/overview
  """

  use Ankole.AIGateway.ProviderDSL

  alias Ankole.AIGateway.ProviderConnectionCheck
  alias Ankole.AIGateway.ReasoningEffort
  alias Ankole.AIGateway.UniversalAIRequest

  @default_referer "https://github.com/agentbull/ankole"
  @default_title "Ankole"

  provider :openrouter do
    label(%{"default" => "OpenRouter", "zh-Hans-CN" => "OpenRouter"})
    base_url("https://openrouter.ai/api/v1", advanced: true)

    setting(:api_key, encrypted: true, scope: :credential)
    setting(:headers, type: :map, advanced: true)
    setting(:query_params, type: :map, advanced: true)
    setting(:app_referer, default: @default_referer, advanced: true)
    setting(:app_title, default: @default_title, advanced: true)

    setting(:user, scope: :request, advanced: true)

    setting(:reasoningEffort,
      type: :select,
      default: ReasoningEffort.default(),
      options: ReasoningEffort.values(),
      scope: :request
    )

    setting(:textVerbosity, scope: :request)
    setting(:strictJSONSchema, type: :boolean, scope: :request, advanced: true)

    language_model do
      upstream(:sse)
      api_resolver(:openai_chat_completions)
      prepare(:prepare_language_model)
      supports_parallel_tool_calls()
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

    image_generate do
      upstream(:json)
      api_resolver(:openrouter_images)
      timeout_ms(300_000)
      prepare(:prepare_image_generate)
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
    |> ReasoningEffort.put_provider_options(ctx, target: :reasoning)
    |> put_prompt_cache_key(ctx)
  end

  # OpenAI requires `prompt_cache_key` for reliable prompt-cache routing on
  # GPT-5.6+ models, and OpenRouter forwards the field to the upstream
  # provider. The chat resolver builds the provider body from provider
  # options, so the public request value is copied here. This stays an
  # OpenRouter-scoped rule: other OpenAI-compatible upstreams may reject the
  # field.
  defp put_prompt_cache_key({:error, _reason} = error, _ctx), do: error

  defp put_prompt_cache_key(%UniversalAIRequest{} = request, ctx) do
    case Map.get(ctx.request, "prompt_cache_key") do
      key when is_binary(key) and key != "" ->
        UniversalAIRequest.put_provider_options(
          request,
          Map.put(request.provider_options, "prompt_cache_key", key)
        )

      _value ->
        request
    end
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

  @doc """
  Builds the stable OpenRouter `/images` request used by the Responses hosted
  image-generation executor.

  Endpoint selection and request-field validation happen before this boundary;
  this function only applies the selected connection, credentials, and
  OpenRouter attribution headers.
  """
  def prepare_image_generate(ctx) do
    ctx
    |> UniversalAIRequest.new("images", :openrouter_images)
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

  @doc false
  @spec image_models_metadata_source(map()) :: {:ok, map()}
  def image_models_metadata_source(ctx) when is_map(ctx) do
    headers =
      ctx
      |> UniversalAIRequest.raw_headers()
      |> common_headers(ctx)
      |> UniversalAIRequest.bearer_auth(ctx.settings[:api_key])

    {:ok,
     %{
       ctx: ctx,
       models_path: "images/models",
       headers: headers,
       cache_key: "images/models"
     }}
  end

  @doc """
  Prepares an OpenRouter connection check through a provider-owned model catalog endpoint.
  """
  @impl true
  def prepare_connection_check(ctx) when is_map(ctx) do
    path =
      case Map.get(ctx, :capability) || Map.get(ctx, "capability") do
        capability when capability in ["embedding", :embedding, :embedding_model] ->
          "embeddings/models"

        capability when capability in ["image_generate", :image_generate] ->
          "images/models"

        _capability ->
          "models"
      end

    headers =
      ctx
      |> UniversalAIRequest.raw_headers()
      |> common_headers(ctx)
      |> UniversalAIRequest.bearer_auth(ctx.settings[:api_key])

    ProviderConnectionCheck.get(ctx, path, headers: headers)
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
      ctx.settings[:app_referer] || @default_referer,
      ctx.settings[:app_title] || @default_title
    }
  end
end
