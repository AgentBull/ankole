defmodule Ankole.AIGateway.Providers.OpenRouter do
  @moduledoc """
  OpenRouter provider backed by its OpenAI-compatible API surface.
  https://openrouter.ai/docs/api/reference/overview
  """

  use Ankole.AIGateway.ProviderDSL

  alias Ankole.AIGateway.OpenAIError
  alias Ankole.AIGateway.ReasoningEffort
  alias Ankole.AIGateway.RequestContext
  alias Ankole.AIGateway.UniversalAIRequest

  @default_referer "https://github.com/agentbull/ankole"
  @default_title "Ankole"
  @max_session_id_length 256

  provider :openrouter do
    label(%{"default" => "OpenRouter", "zh-Hans-CN" => "OpenRouter"})
    base_url("https://openrouter.ai/api/v1", advanced: true)

    setting(:api_key, encrypted: true, scope: :credential)
    setting(:headers, type: :map, advanced: true)
    setting(:query_params, type: :map, advanced: true)
    setting(:app_referer, default: @default_referer, advanced: true)
    setting(:app_title, default: @default_title, advanced: true)

    # The speech and transcription requests send their own fields only, and a
    # decision request rejects these options, so their model profiles do not
    # offer them. Embedding, rerank, and image requests copy their options into
    # the body unchanged, so only the language model reads reasoning effort and
    # verbosity, which its prepare function maps to OpenRouter's field names.
    @option_capabilities [:language_model, :embedding_model, :rerank_model, :image_generate]

    setting(:user, scope: :request, advanced: true, capabilities: @option_capabilities)

    setting(:reasoningEffort,
      type: :select,
      options: ReasoningEffort.Levels.values(),
      scope: :request,
      capabilities: [:language_model]
    )

    setting(:textVerbosity, scope: :request, capabilities: [:language_model])

    # OpenRouter provider routing preferences (`order`, `only`, `ignore`,
    # `allow_fallbacks`, `require_parameters`, ...). The map goes to the request
    # body as `provider`, so a profile can keep a model away from an upstream
    # that truncates its output.
    setting(:provider,
      type: :map,
      scope: :request,
      advanced: true,
      capabilities: [:decision_model | @option_capabilities]
    )

    language_model do
      api_resolver(:openai_chat_completions)
      prepare(:prepare_language_model)
      supports_parallel_tool_calls()
    end

    embedding_model do
      api_resolver(:openrouter_embeddings)
      prepare(:prepare_embedding_model)
    end

    rerank_model do
      api_resolver(:openrouter_rerank)
      prepare(:prepare_rerank_model)
    end

    image_generate do
      api_resolver(:openrouter_images)
      timeout_ms(300_000)
      prepare(:prepare_image_generate)
    end

    decision_model do
      api_resolver(:systemone_decision)
      prepare(:prepare_decision_model)
    end

    speech_model do
      api_resolver(:openrouter_speech)
      timeout_ms(300_000)
      prepare(:prepare_speech_model)
    end

    transcription_model do
      api_resolver(:openrouter_transcription)
      timeout_ms(300_000)
      prepare(:prepare_transcription_model)
    end

    video_model do
      api_resolver(:openrouter_video)
      timeout_ms(300_000)
      prepare(:prepare_video_model)
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
    |> UniversalAIRequest.rename_provider_option("textVerbosity", "verbosity")
    |> put_prompt_cache_key(ctx)
    |> put_session_id(ctx)
    |> put_anthropic_cache_control(ctx)
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

  # `session_id` keeps one conversation on the same OpenRouter provider from
  # its first successful request. It is separate from `prompt_cache_key`, which
  # groups requests that can share a prompt prefix. AIGateway supplies its
  # durable Conversation ID only after it resolves stateful history.
  defp put_session_id({:error, _reason} = error, _ctx), do: error

  defp put_session_id(%UniversalAIRequest{} = request, ctx) do
    with {:ok, session_id} <- session_id(ctx) do
      case session_id do
        nil ->
          request

        session_id ->
          UniversalAIRequest.put_provider_options(
            request,
            Map.put(request.provider_options, "session_id", session_id)
          )
      end
    end
  end

  defp session_id(ctx) do
    case Map.fetch(ctx.request, "session_id") do
      {:ok, value} -> validate_session_id(value)
      :error -> validate_optional_session_id(context_session_id(ctx.request_context))
    end
  end

  defp context_session_id(request_context) do
    headers = Map.get(request_context, "headers", %{})

    Enum.find_value(RequestContext.session_header_names(), &Map.get(headers, &1)) ||
      Map.get(request_context, "conversation_id")
  end

  defp validate_optional_session_id(nil), do: {:ok, nil}
  defp validate_optional_session_id(value), do: validate_session_id(value)

  defp validate_session_id(value) when is_binary(value) do
    cond do
      String.trim(value) == "" ->
        {:error,
         OpenAIError.invalid(
           "session_id",
           "invalid_value",
           "session_id must not be empty or contain only whitespace."
         )}

      String.length(value) > @max_session_id_length ->
        {:error,
         OpenAIError.invalid(
           "session_id",
           "invalid_value",
           "session_id must contain at most 256 characters."
         )}

      true ->
        {:ok, value}
    end
  end

  defp validate_session_id(_value) do
    {:error,
     OpenAIError.invalid(
       "session_id",
       "invalid_type",
       "session_id must be a string."
     )}
  end

  # Anthropic-family upstreams cache a prompt only when the request carries an
  # explicit cache annotation, so a request without one repays the full prompt
  # prefix every turn. The top-level `cache_control` field selects OpenRouter
  # automatic caching: OpenRouter puts the breakpoint on the last cacheable
  # block and moves it forward as the conversation grows, on each Anthropic
  # host it routes to (Anthropic, Bedrock, Vertex, Azure). This stays an
  # OpenRouter-scoped rule keyed on the OpenRouter author segment; other
  # OpenAI-compatible upstreams may reject the field.
  defp put_anthropic_cache_control({:error, _reason} = error, _ctx), do: error

  defp put_anthropic_cache_control(%UniversalAIRequest{} = request, ctx) do
    provider_options = request.provider_options || %{}

    if anthropic_model?(ctx.model) and not Map.has_key?(provider_options, "cache_control") do
      UniversalAIRequest.put_provider_options(
        request,
        Map.put(provider_options, "cache_control", %{"type" => "ephemeral"})
      )
    else
      request
    end
  end

  defp anthropic_model?(model) when is_binary(model) do
    model
    |> String.trim_leading("~")
    |> String.starts_with?("anthropic/")
  end

  defp anthropic_model?(_model), do: false

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

  @decision_unsupported_options ~w(user reasoningEffort textVerbosity)

  @doc "Builds an OpenRouter SystemOne decision-model request."
  def prepare_decision_model(ctx) do
    with :ok <- validate_decision_options(ctx.provider_options),
         :ok <- validate_decision_images(ctx) do
      ctx
      |> UniversalAIRequest.new("systemone", :systemone_decision)
      |> common_headers(ctx)
      |> UniversalAIRequest.put_client_identity_headers(ctx)
      |> UniversalAIRequest.bearer_auth()
      |> maybe_put_decision_images_header(ctx.request)
    end
  end

  defp validate_decision_options(options) when is_map(options) do
    case Enum.find(@decision_unsupported_options, &Map.has_key?(options, &1)) do
      nil -> :ok
      option -> {:error, {:unsupported_provider_option, option, "decisions"}}
    end
  end

  defp validate_decision_options(_options), do: :ok

  defp validate_decision_images(ctx) do
    images = Map.get(ctx.request, "images", [])

    cond do
      images != [] and not jev_model?(ctx.model) ->
        unsupported_decision_images("The configured decision model does not accept images.")

      Enum.any?(images, &String.starts_with?(&1, "data:image/webp;base64,")) ->
        unsupported_decision_images("SystemOne decision models accept only PNG and JPEG images.")

      true ->
        :ok
    end
  end

  defp jev_model?(model) when is_binary(model), do: String.starts_with?(model, "typesafe/jev")
  defp jev_model?(_model), do: false

  defp unsupported_decision_images(message) do
    {:error, OpenAIError.invalid("images", "unsupported_value", message)}
  end

  defp maybe_put_decision_images_header(request, %{"images" => images})
       when is_list(images) and images != [],
       do: UniversalAIRequest.put_header(request, "TypeSafe-Danger-Zone-Images", "true")

  defp maybe_put_decision_images_header(request, _request), do: request

  @doc "Builds an OpenRouter `/audio/speech` request, which answers with audio bytes."
  def prepare_speech_model(ctx) do
    ctx
    |> UniversalAIRequest.new("audio/speech", :openrouter_speech, include_model: false)
    |> common_headers(ctx)
    |> UniversalAIRequest.bearer_auth()
  end

  @doc "Builds an OpenRouter `/audio/transcriptions` request with base64 audio."
  def prepare_transcription_model(ctx) do
    ctx
    |> UniversalAIRequest.new("audio/transcriptions", :openrouter_transcription,
      include_model: false
    )
    |> common_headers(ctx)
    |> UniversalAIRequest.bearer_auth()
  end

  @doc """
  Builds an OpenRouter `/videos` request. A request with `job_id` reads the
  state of that generation; any other request submits a generation, which
  OpenRouter answers before the video exists.
  """
  def prepare_video_model(ctx) do
    {path, method} =
      case ctx.request do
        %{"job_id" => job_id} -> {"videos/" <> URI.encode(job_id, &URI.char_unreserved?/1), "GET"}
        _submission -> {"videos", "POST"}
      end

    ctx
    |> UniversalAIRequest.new(path, :openrouter_video, method: method, include_model: false)
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
